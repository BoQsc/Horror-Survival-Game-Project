extends Node
class_name CombatSystemFeature
## CombatSystem - Extracted combat and durability logic from ModePlay
## Handles damage dealing, durability tracking, and resource collection

# Local signals reference
var signals: Node = null

# References (set by parent)
var player: Node = null
var terrain_manager: Node = null
var vegetation_manager: Node = null
var building_manager: Node = null
var terrain_interaction: Node = null
var hotbar: Node = null

# Combat state
var attack_cooldown: float = 0.0
const ATTACK_COOLDOWN_TIME: float = 0.3

# Durability system - blocks/objects require multiple hits
const BLOCK_HP: int = 10  # Building blocks take 10 damage to destroy
const OBJECT_HP: int = 5   # Placed objects take 5 damage to destroy
const TREE_HP: int = 8     # Trees take 8 damage to chop
const TERRAIN_HP: int = 5  # Terrain takes 5 punches to break a grid cube

var block_damage: Dictionary = {}    # Vector3i -> accumulated damage
var object_damage: Dictionary = {}   # RID -> accumulated damage
var tree_damage: Dictionary = {}     # collider RID -> accumulated damage
var terrain_damage: Dictionary = {}  # Vector3i -> accumulated damage for terrain
var durability_target: Variant = null # Current target being damaged

# Weapon readiness state
var fist_punch_ready: bool = true
var pistol_fire_ready: bool = true
var axe_ready: bool = true
var is_reloading: bool = false

# Mode manager reference
var mode_manager: Node = null

# Prop grab/drop system
var held_prop_instance: Node = null
var held_prop_id: int = -1
var held_prop_rotation: int = 0

# Preload item definitions
const ItemDefs = preload("res://modules/world_player_v2/features/inventory/item_definitions.gd")

func _ready() -> void:
	# Try to find local signals node
	signals = get_node_or_null("../signals")
	if not signals:
		signals = get_node_or_null("signals")
	
	# Auto-discover player (CombatSystem is at Modes/CombatSystem, parent.parent = WorldPlayerV2)
	player = get_parent().get_parent()
	
	# Auto-discover mode manager
	if player:
		mode_manager = player.get_node_or_null("Systems/ModeManager")
		hotbar = player.get_node_or_null("Systems/Hotbar")
	
	# Find managers via groups (deferred)
	call_deferred("_find_managers")
	
	# Connect to weapon ready signals (backward compat)
	if has_node("/root/PlayerSignals"):
		PlayerSignals.punch_ready.connect(_on_punch_ready)
		PlayerSignals.pistol_fire_ready.connect(_on_pistol_fire_ready)
		PlayerSignals.axe_ready.connect(_on_axe_ready)
	
	DebugSettings.log_player("CombatSystemFeature: Initialized")

func _find_managers() -> void:
	if not terrain_manager:
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if not vegetation_manager:
		vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	if not building_manager:
		building_manager = get_tree().get_first_node_in_group("building_manager")
	if not terrain_interaction and player:
		terrain_interaction = player.get_node_or_null("Modes/TerrainInteraction")

func _process(delta: float) -> void:
	if attack_cooldown > 0:
		attack_cooldown -= delta
	
	_update_held_prop(delta)
	_check_durability_target()

## Initialize references (called by parent after scene ready)
func initialize(p_player: Node, p_terrain: Node, p_vegetation: Node, p_building: Node, p_hotbar: Node) -> void:
	player = p_player
	terrain_manager = p_terrain
	vegetation_manager = p_vegetation
	building_manager = p_building
	hotbar = p_hotbar
	
	# Find mode manager
	mode_manager = player.get_node_or_null("Systems/ModeManager") if player else null

# ============================================================================
# MODE INTERFACE (called by ModeManager)
# ============================================================================

## Handle primary action (left click) - mode dispatch (V1 EXACT)
func handle_primary(item: Dictionary) -> void:
	var category = item.get("category", 0)
	
	match category:
		0:  # NONE - Fists
			do_punch(item)
		1:  # TOOL
			do_tool_attack(item)
		2:  # BUCKET - V1 routes to _do_bucket_collect
			if terrain_interaction and terrain_interaction.has_method("do_bucket_collect"):
				terrain_interaction.do_bucket_collect()
		3:  # RESOURCE - no primary action (V1: pass)
			pass
		6:  # PROP (pistol, etc.)
			_do_prop_primary(item)
		_:
			# Other categories handled by terrain_interaction or building
			pass

## Handle secondary action (right click) - no combat secondary
func handle_secondary(_item: Dictionary) -> void:
	# Combat system has no secondary action
	# Resource/bucket placement is handled by terrain_interaction
	pass

## Handle PROP primary action (pistol, etc.)
func _do_prop_primary(item: Dictionary) -> void:
	var item_id = item.get("id", "")
	if item_id == "heavy_pistol":
		do_pistol_fire()

# ============================================================================
# PROP GRAB/DROP SYSTEM
# ============================================================================

func _input(event: InputEvent) -> void:
	# Only process in PLAY mode (if mode_manager is null, assume PLAY mode)
	if mode_manager and not mode_manager.is_play_mode():
		return
	
	# Also try to find mode_manager if not set
	if not mode_manager and player:
		mode_manager = player.get_node_or_null("Systems/ModeManager")
	
	# T key for prop grab/drop
	if event is InputEventKey and event.keycode == KEY_T:
		# Ignore echo (key repeat) events
		if event.echo:
			return
		
		if event.pressed:
			# T pressed down - grab prop
			if not is_grabbing_prop():
				print("CombatSystem: T pressed - attempting grab")
				_try_grab_prop()
		else:
			# T released - drop prop
			if is_grabbing_prop():
				print("CombatSystem: T released - dropping")
				_drop_grabbed_prop()
## Update held prop position (follows camera) - V1 port with smooth lerp
func _update_held_prop(delta: float) -> void:
	if not held_prop_instance or not is_instance_valid(held_prop_instance):
		return
	
	# Get camera from player - V1 uses "Head/Camera3D" path
	var cam: Camera3D = null
	if player and player.has_node("Head/Camera3D"):
		cam = player.get_node("Head/Camera3D")
	if not cam and player and player.has_node("Camera3D"):
		cam = player.get_node("Camera3D")
	if not cam:
		cam = get_viewport().get_camera_3d()
	if not cam:
		return
	
	# Float 2 meters in front of camera
	var target_pos = cam.global_position - cam.global_transform.basis.z * 2.0
	# Smoothly interpolate position (V1 uses delta * 15.0)
	held_prop_instance.global_position = held_prop_instance.global_position.lerp(target_pos, delta * 15.0)
	# Match camera rotation (yaw only) with smooth interpolation
	var cam_rot_y = cam.global_rotation.y
	held_prop_instance.rotation.y = lerp_angle(held_prop_instance.rotation.y, cam_rot_y + deg_to_rad(held_prop_rotation * 90.0), delta * 10.0)
	
	# V1 debug every 60 frames
	if Engine.get_process_frames() % 60 == 0:
		print("PropHold: Prop at %s (visible: %s)" % [held_prop_instance.global_position, held_prop_instance.visible])

## Try to grab a prop (building_manager object OR dropped physics prop) - V1 EXACT
func _try_grab_prop() -> void:
	var target = _get_pickup_target()
	if not target:
		return
	
	DebugSettings.log_player("PropGrab: Trying to grab %s" % target.name)
	
	# Check if this is a dropped physics prop (has item_data OR is interactable RigidBody3D)
	# V1: Routes ALL RigidBody3D through _grab_dropped_prop for proper collision handling
	if target is RigidBody3D and (target.has_meta("item_data") or target.is_in_group("interactable")):
		_grab_dropped_prop(target)
		return
	
	# Otherwise, try building_manager object path
	if not target.has_meta("anchor") or not target.has_meta("chunk"):
		DebugSettings.log_player("PropGrab: Target has no anchor/chunk metadata")
		return
	
	var anchor = target.get_meta("anchor")
	var chunk = target.get_meta("chunk")
	
	if not chunk or not chunk.objects.has(anchor):
		DebugSettings.log_player("PropPickup: No object data at anchor")
		return
	
	# Read object data before removing
	var data = chunk.objects[anchor]
	held_prop_id = data["object_id"]
	held_prop_rotation = data.get("rotation", 0)
	
	# Remove from world
	chunk.remove_object(anchor)
	
	# Spawn temporary held visual
	var obj_def = ObjectRegistry.get_object(held_prop_id)
	if obj_def.has("scene"):
		var packed = load(obj_def.scene)
		held_prop_instance = packed.instantiate()
		
		# Strip physics for holding
		if held_prop_instance is RigidBody3D:
			held_prop_instance.freeze = true
			held_prop_instance.collision_layer = 0
			held_prop_instance.collision_mask = 0
		
		# Disable all collisions
		_disable_preview_collisions(held_prop_instance)
		
		get_tree().root.add_child(held_prop_instance)
		
		# Position at camera
		var cam: Camera3D = null
		if player and player.has_node("Head/Camera3D"):
			cam = player.get_node("Head/Camera3D")
		if not cam and player and player.has_node("Camera3D"):
			cam = player.get_node("Camera3D")
		if not cam:
			cam = get_viewport().get_camera_3d()
		if cam:
			held_prop_instance.global_position = cam.global_position - cam.global_transform.basis.z * 2.0
			DebugSettings.log_player("PropPickup: Picked up prop ID %d at %s" % [held_prop_id, held_prop_instance.global_position])
		else:
			DebugSettings.log_player("PropPickup: WARNING - No camera, prop may be mispositioned")

## Grab a dropped physics prop (RigidBody3D with item_data meta) - V1 port
func _grab_dropped_prop(target: RigidBody3D) -> void:
	# Store reference directly - don't need to respawn, just move it (V1 approach)
	held_prop_instance = target
	held_prop_id = -1  # No object registry ID for dropped items
	held_prop_rotation = 0
	
	# Store item data for later drop (V1: grabbed_item_data)
	if target.has_meta("item_data"):
		held_prop_instance.set_meta("grabbed_item_data", target.get_meta("item_data"))
	
	# Freeze physics and disable collisions for holding (V1 sets layer/mask to 0)
	target.freeze = true
	target.collision_layer = 0
	target.collision_mask = 0
	_disable_preview_collisions(target)
	
	# Position at camera immediately
	var cam = get_viewport().get_camera_3d()
	if cam:
		held_prop_instance.global_position = cam.global_position - cam.global_transform.basis.z * 2.0
		print("CombatSystem: Grabbed dropped prop %s" % target.name)
	else:
		print("CombatSystem: WARNING - No camera for initial prop position")

## Drop the grabbed prop - V1 port with collision layer restore
func _drop_grabbed_prop() -> void:
	if not held_prop_instance:
		return
	
	print("CombatSystem: Dropping prop (held_prop_id=%d)" % held_prop_id)
	
	# Check if this was a grabbed dropped prop (not a building_manager object)
	if held_prop_id == -1:
		# Re-enable physics and drop naturally (V1 approach)
		if held_prop_instance is RigidBody3D:
			# Re-enable collision shapes first!
			_enable_preview_collisions(held_prop_instance)
			held_prop_instance.freeze = false
			held_prop_instance.collision_layer = 1  # Default layer (V1)
			held_prop_instance.collision_mask = 1   # Default mask (V1)
			# Give a small drop velocity (V1)
			held_prop_instance.linear_velocity = Vector3(0, -1, 0)
			print("CombatSystem: Released dropped prop with physics")
		held_prop_instance = null
		held_prop_id = -1
		held_prop_rotation = 0
		return
	
	# For building objects, place via building_manager
	var drop_pos = held_prop_instance.global_position
	
	if building_manager and building_manager.has_method("place_object"):
		building_manager.place_object(drop_pos, held_prop_id, held_prop_rotation)
		print("CombatSystem: Placed building object via building_manager")
	else:
		print("CombatSystem: No building_manager - placement failed")
	
	# Cleanup held prop
	if held_prop_instance:
		held_prop_instance.queue_free()
	held_prop_instance = null
	held_prop_id = -1
	held_prop_rotation = 0

## Find a prop that can be picked up (building_manager objects OR dropped physics props)
func _get_pickup_target() -> Node:
	var cam = get_viewport().get_camera_3d()
	if not cam:
		print("CombatSystem: _get_pickup_target - no camera")
		return null
	
	var origin = cam.global_position
	var forward = -cam.global_transform.basis.z
	
	# Option A: Precise raycast using player.raycast
	var hit = player.raycast(5.0) if player and player.has_method("raycast") else {}
	
	if hit and hit.has("collider"):
		var col = hit.collider
		# Check for building_manager placed objects
		if col.is_in_group("placed_objects") and col.has_meta("anchor"):
			print("CombatSystem: Direct hit on placed object %s" % col.name)
			return col
		# Check for dropped physics props (RigidBody3D with item_data or interactable)
		if col is RigidBody3D and (col.has_meta("item_data") or col.is_in_group("interactable")):
			print("CombatSystem: Direct hit on dropped prop %s" % col.name)
			return col
	
	# Option B: Sphere assist for forgiveness
	var search_origin = hit.position if hit and hit.has("position") else (origin + forward * 2.0)
	
	var space_state = cam.get_world_3d().direct_space_state
	var params = PhysicsShapeQueryParameters3D.new()
	params.shape = SphereShape3D.new()
	params.shape.radius = 0.4 # 40cm forgiveness
	params.transform = Transform3D(Basis(), search_origin)
	params.collision_mask = 0xFFFFFFFF
	if player:
		params.exclude = [player.get_rid()]
	
	var results = space_state.intersect_shape(params, 5)
	var best_target = null
	var best_dist = 999.0
	
	for result in results:
		var col = result.collider
		var is_valid = false
		# Check for building_manager placed objects
		if col.is_in_group("placed_objects") and col.has_meta("anchor"):
			is_valid = true
		# Check for dropped physics props
		elif col is RigidBody3D and (col.has_meta("item_data") or col.is_in_group("interactable")):
			is_valid = true
		
		if is_valid:
			var d = col.global_position.distance_to(search_origin)
			if d < best_dist:
				best_dist = d
				best_target = col
	
	if best_target:
		print("CombatSystem: Assisted hit on %s" % best_target.name)
	else:
		print("CombatSystem: No pickup target found")
	return best_target

func _disable_preview_collisions(node: Node) -> void:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		node.disabled = true
	for child in node.get_children():
		_disable_preview_collisions(child)

func _enable_preview_collisions(node: Node) -> void:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		node.disabled = false
	for child in node.get_children():
		_enable_preview_collisions(child)

func is_grabbing_prop() -> bool:
	return held_prop_instance != null and is_instance_valid(held_prop_instance)

func _exit_tree() -> void:
	# Cleanup held props
	if held_prop_instance and is_instance_valid(held_prop_instance):
		held_prop_instance.queue_free()

# ============================================================================
# WEAPON READY CALLBACKS
# ============================================================================

func _on_punch_ready() -> void:
	fist_punch_ready = true

func _on_pistol_fire_ready() -> void:
	pistol_fire_ready = true

func _on_axe_ready() -> void:
	axe_ready = true

# ============================================================================
# PRIMARY ACTIONS
# ============================================================================

## Punch attack with fists (synced with animation)
func do_punch(item: Dictionary) -> void:
	if not player:
		return
	
	if not fist_punch_ready:
		return
	
	fist_punch_ready = false
	_emit_punch_triggered()
	
	var hit = _raycast(5.0, true, true)
	if hit.is_empty():
		DebugSettings.log_player("CombatSystem: Punch - miss")
		return
	
	var damage = item.get("damage", 1)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	# Try to damage entity
	var damageable = _find_damageable(target)
	if damageable:
		damageable.take_damage(damage)
		durability_target = target.get_rid()
		_emit_damage_dealt(damageable, damage)
		return
	
	# Try vegetation
	if _try_harvest_vegetation(target, item, position):
		return
	
	# Try placed objects
	if _try_damage_placed_object(target, item, position):
		return
	
	# Try building blocks
	if _try_damage_building_block(target, item, position, hit):
		return
	
	# Default: terrain with durability
	_do_terrain_punch(item, position)

## Tool attack/mine
func do_tool_attack(item: Dictionary) -> void:
	if not player:
		return
	
	attack_cooldown = ATTACK_COOLDOWN_TIME
	
	var item_id = item.get("id", "")
	
	# Handle axe animations
	if "axe" in item_id and not "pickaxe" in item_id:
		if not axe_ready:
			return
		axe_ready = false
		_emit_axe_fired()
	
	var hit = _raycast(3.5, true, true)
	if hit.is_empty():
		return
	
	var damage = item.get("damage", 1)
	var mining_strength = item.get("mining_strength", 1.0)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	# Priority 1: Generic Damageable
	var damageable = _find_damageable(target)
	if damageable:
		if "axe" in item_id and damageable.is_in_group("zombies"):
			damage = 10  # Axe bonus vs zombies
		damageable.take_damage(damage)
		durability_target = target.get_rid()
		_emit_damage_dealt(damageable, damage)
		return
	
	# Priority 2: Vegetation
	if _try_harvest_vegetation(target, item, position):
		return
	
	# Priority 3: Placed objects
	if _try_damage_placed_object(target, item, position):
		return
	
	# Priority 4: Building blocks
	if _try_damage_building_block(target, item, position, hit):
		return
	
	# Priority 5: Terrain instant mine
	if terrain_manager and terrain_manager.has_method("modify_terrain"):
		var mat_id = -1
		if terrain_manager.has_method("get_material_at"):
			mat_id = terrain_manager.get_material_at(position)
		
		var actual_radius = max(mining_strength, 0.8)
		terrain_manager.modify_terrain(position, actual_radius, 1.0, 0, 0)
		
		if mat_id >= 0:
			_collect_terrain_resource(mat_id)

## Pistol fire
func do_pistol_fire() -> void:
	if not player:
		return
	
	if not pistol_fire_ready or is_reloading:
		return
	
	pistol_fire_ready = false
	_emit_pistol_fired()
	
	var hit = _raycast(50.0, true, true)
	if hit.is_empty():
		return
	
	var target = hit.get("collider", null)
	var position = hit.get("position", Vector3.ZERO)
	
	_spawn_pistol_hit_effect(position)
	
	if target and target.is_in_group("zombies") and target.has_method("take_damage"):
		target.take_damage(5)
		_emit_damage_dealt(target, 5)
		return
	
	if target and target.is_in_group("blocks") and target.has_method("take_damage"):
		target.take_damage(2)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

func _raycast(distance: float, collide_with_areas: bool, exclude_water: bool) -> Dictionary:
	if player and player.has_method("raycast"):
		return player.raycast(distance, 0xFFFFFFFF, collide_with_areas, exclude_water)
	return {}

func _find_damageable(target: Node) -> Node:
	if not target:
		return null
	
	if target.has_method("take_damage"):
		return target
	
	var node = target.get_parent()
	while node:
		if node.has_method("take_damage"):
			return node
		node = node.get_parent()
	
	return null

func _try_harvest_vegetation(target: Node, item: Dictionary, _position: Vector3) -> bool:
	if not target or not vegetation_manager:
		return false
	
	var damage = item.get("damage", 1)
	var item_id = item.get("id", "")
	
	if target.is_in_group("trees"):
		var tree_dmg = damage
		if "axe" in item_id:
			tree_dmg = 3
		
		var tree_rid = target.get_rid()
		tree_damage[tree_rid] = tree_damage.get(tree_rid, 0) + tree_dmg
		var current_hp = TREE_HP - tree_damage[tree_rid]
		durability_target = tree_rid
		
		_emit_durability_hit(current_hp, TREE_HP, "Tree", durability_target)
		
		if tree_damage[tree_rid] >= TREE_HP:
			vegetation_manager.chop_tree_by_collider(target)
			tree_damage.erase(tree_rid)
			_emit_durability_cleared()
			_collect_vegetation_resource("wood")
		return true
	
	elif target.is_in_group("grass"):
		vegetation_manager.harvest_grass_by_collider(target)
		_collect_vegetation_resource("fiber")
		return true
	
	elif target.is_in_group("rocks"):
		vegetation_manager.harvest_rock_by_collider(target)
		_collect_vegetation_resource("rock")
		return true
	
	return false

func _try_damage_placed_object(target: Node, item: Dictionary, _position: Vector3) -> bool:
	if not target or not target.is_in_group("placed_objects") or not building_manager:
		return false
	
	var obj_rid = target.get_rid()
	var obj_dmg = item.get("damage", 1)
	var item_id = item.get("id", "")
	
	if "pickaxe" in item_id:
		obj_dmg = 5
	
	object_damage[obj_rid] = object_damage.get(obj_rid, 0) + obj_dmg
	var current_hp = OBJECT_HP - object_damage[obj_rid]
	durability_target = obj_rid
	
	_emit_durability_hit(current_hp, OBJECT_HP, target.name, durability_target)
	
	if object_damage[obj_rid] >= OBJECT_HP:
		if target.has_meta("anchor") and target.has_meta("chunk"):
			var anchor = target.get_meta("anchor")
			var chunk = target.get_meta("chunk")
			chunk.remove_object(anchor)
		object_damage.erase(obj_rid)
		_emit_durability_cleared()
	
	return true

func _try_damage_building_block(target: Node, item: Dictionary, position: Vector3, hit: Dictionary) -> bool:
	if not target or not building_manager:
		return false
	
	var chunk = _find_building_chunk(target)
	if not chunk:
		return false
	
	var block_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
	var blk_dmg = item.get("damage", 1)
	var item_id = item.get("id", "")
	
	if "pickaxe" in item_id:
		blk_dmg = 5
	
	block_damage[block_pos] = block_damage.get(block_pos, 0) + blk_dmg
	var current_hp = BLOCK_HP - block_damage[block_pos]
	durability_target = block_pos
	
	_emit_durability_hit(current_hp, BLOCK_HP, "Block", durability_target)
	
	if block_damage[block_pos] >= BLOCK_HP:
		var voxel_pos = position - hit.get("normal", Vector3.ZERO) * 0.1
		var voxel_coord = Vector3(floor(voxel_pos.x), floor(voxel_pos.y), floor(voxel_pos.z))
		
		var voxel_id = 0
		if building_manager.has_method("get_voxel"):
			voxel_id = building_manager.get_voxel(voxel_pos)
		
		building_manager.set_voxel(voxel_coord, 0.0)
		block_damage.erase(block_pos)
		_emit_durability_cleared()
		
		if voxel_id > 0:
			_collect_building_resource(voxel_id)
	
	return true

func _find_building_chunk(collider: Node) -> Node:
	if not collider:
		return null
	
	if collider.is_in_group("building_chunks"):
		return collider
	
	var node = collider.get_parent()
	while node:
		if node.is_in_group("building_chunks"):
			return node
		node = node.get_parent()
	
	return null

func _do_terrain_punch(item: Dictionary, position: Vector3) -> void:
	if not terrain_manager or not terrain_manager.has_method("modify_terrain"):
		return
	
	var punch_dmg = item.get("damage", 1)
	var terrain_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
	
	terrain_damage[terrain_pos] = terrain_damage.get(terrain_pos, 0) + punch_dmg
	var current_hp = TERRAIN_HP - terrain_damage[terrain_pos]
	durability_target = terrain_pos
	
	_emit_durability_hit(current_hp, TERRAIN_HP, "Terrain", durability_target)
	
	if terrain_damage[terrain_pos] >= TERRAIN_HP:
		var mat_id = -1
		if terrain_manager.has_method("get_material_at"):
			mat_id = terrain_manager.get_material_at(position)
		
		var center = Vector3(terrain_pos) + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(center, 0.6, 1.0, 1, 0, -1)
		
		if mat_id >= 0:
			_collect_terrain_resource(mat_id)
		
		terrain_damage.erase(terrain_pos)
		_emit_durability_cleared()

func _check_durability_target() -> void:
	if durability_target == null or not player:
		return
	
	var hit = _raycast(5.0, true, true)
	if hit.is_empty():
		durability_target = null
		return
	
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	if durability_target is RID:
		if target and target.get_rid() == durability_target:
			return
	elif durability_target is Vector3i:
		var block_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
		if block_pos == durability_target:
			return
	
	durability_target = null

func _spawn_pistol_hit_effect(pos: Vector3) -> void:
	var mesh_instance = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.05
	sphere.height = 0.1
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color.RED
	mat.emission_enabled = true
	mat.emission = Color.RED
	mat.emission_energy_multiplier = 2.0
	
	mesh_instance.mesh = sphere
	mesh_instance.material_override = mat
	
	get_tree().root.add_child(mesh_instance)
	mesh_instance.global_position = pos
	
	await get_tree().create_timer(2.0).timeout
	if is_instance_valid(mesh_instance):
		mesh_instance.queue_free()

# ============================================================================
# RESOURCE COLLECTION
# ============================================================================

func _collect_terrain_resource(mat_id: int) -> void:
	var resource_item = ItemDefs.get_resource_for_material(mat_id)
	if resource_item.is_empty():
		return
	
	if hotbar and hotbar.has_method("add_item"):
		hotbar.add_item(resource_item)

func _collect_vegetation_resource(veg_type: String) -> void:
	var resource_item = ItemDefs.get_vegetation_resource(veg_type)
	if resource_item.is_empty():
		return
	
	if hotbar and hotbar.has_method("add_item"):
		hotbar.add_item(resource_item)

func _collect_building_resource(voxel_id: int) -> void:
	var resource_item = ItemDefs.get_item_for_block(voxel_id)
	if resource_item.is_empty():
		return
	
	if hotbar and hotbar.has_method("add_item"):
		hotbar.add_item(resource_item)

# ============================================================================
# SIGNAL EMISSION (Local + Backward Compat)
# ============================================================================

func _emit_punch_triggered() -> void:
	if signals and signals.has_signal("punch_triggered"):
		signals.punch_triggered.emit()
	if has_node("/root/PlayerSignals"):
		PlayerSignals.punch_triggered.emit()

func _emit_pistol_fired() -> void:
	if signals and signals.has_signal("pistol_fired"):
		signals.pistol_fired.emit()
	if has_node("/root/PlayerSignals"):
		PlayerSignals.pistol_fired.emit()

func _emit_axe_fired() -> void:
	if signals and signals.has_signal("axe_fired"):
		signals.axe_fired.emit()
	if has_node("/root/PlayerSignals"):
		PlayerSignals.axe_fired.emit()

func _emit_damage_dealt(target: Node, amount: int) -> void:
	if signals and signals.has_signal("damage_dealt"):
		signals.damage_dealt.emit(target, amount)
	if has_node("/root/PlayerSignals"):
		PlayerSignals.damage_dealt.emit(target, amount)

func _emit_durability_hit(current_hp: int, max_hp: int, target_name: String, target_ref: Variant) -> void:
	if signals and signals.has_signal("durability_hit"):
		signals.durability_hit.emit(current_hp, max_hp, target_name, target_ref)
	if has_node("/root/PlayerSignals"):
		PlayerSignals.durability_hit.emit(current_hp, max_hp, target_name, target_ref)

func _emit_durability_cleared() -> void:
	if signals and signals.has_signal("durability_cleared"):
		signals.durability_cleared.emit()
	if has_node("/root/PlayerSignals"):
		PlayerSignals.durability_cleared.emit()
