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

# Preload item definitions
const ItemDefs = preload("res://modules/world_player_v2/features/inventory/item_definitions.gd")

func _ready() -> void:
	# Try to find local signals node
	signals = get_node_or_null("../signals")
	if not signals:
		signals = get_node_or_null("signals")
	
	# Connect to weapon ready signals (backward compat)
	if has_node("/root/PlayerSignals"):
		PlayerSignals.punch_ready.connect(_on_punch_ready)
		PlayerSignals.pistol_fire_ready.connect(_on_pistol_fire_ready)
		PlayerSignals.axe_ready.connect(_on_axe_ready)
	
	DebugSettings.log_player("CombatSystemFeature: Initialized")

func _process(delta: float) -> void:
	if attack_cooldown > 0:
		attack_cooldown -= delta
	
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

## Handle primary action (left click) - mode dispatch
func handle_primary(item: Dictionary) -> void:
	var category = item.get("category", 0)
	
	match category:
		0:  # NONE - Fists
			do_punch(item)
		1:  # TOOL
			do_tool_attack(item)
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

var held_prop_instance: Node3D = null
var held_prop_id: int = -1
var held_prop_rotation: int = 0
var mode_manager: Node = null

func _input(event: InputEvent) -> void:
	# Only process in PLAY mode
	if mode_manager and not mode_manager.is_play_mode():
		return
	
	# T key for prop grab/drop
	if event is InputEventKey and event.keycode == KEY_T:
		if event.pressed and not event.echo:
			_try_grab_prop()
		elif not event.pressed:
			if held_prop_instance:
				_drop_grabbed_prop()

func _update_held_prop(_delta: float) -> void:
	if not held_prop_instance or not is_instance_valid(held_prop_instance):
		return
	
	var cam: Camera3D = null
	if player and player.has_node("Camera3D"):
		cam = player.get_node("Camera3D")
	else:
		cam = get_viewport().get_camera_3d()
	
	if not cam:
		return
	
	var origin = cam.global_position
	var forward = -cam.global_transform.basis.z
	var hold_distance = 2.0
	
	held_prop_instance.global_position = origin + forward * hold_distance
	held_prop_instance.rotation_degrees.y = cam.rotation_degrees.y + held_prop_rotation * 90

func _try_grab_prop() -> void:
	if held_prop_instance:
		return
	
	var target = _get_pickup_target()
	if not target:
		return
	
	# Check for dropped physics prop
	if target.has_meta("item_data") and not target.has_meta("anchor"):
		target.queue_free()
		return
	
	# Check for building object
	if not target.has_meta("anchor") or not target.has_meta("chunk"):
		return
	
	var anchor = target.get_meta("anchor")
	var chunk = target.get_meta("chunk")
	
	if not chunk.objects.has(anchor):
		return
	
	var data = chunk.objects[anchor]
	held_prop_id = data["object_id"]
	held_prop_rotation = data.get("rotation", 0)
	
	chunk.remove_object(anchor)
	
	# Spawn temp held visual
	if has_node("/root/ObjectRegistry"):
		var obj_def = ObjectRegistry.get_object(held_prop_id)
		if obj_def and obj_def.get("scene"):
			var scene = load(obj_def["scene"])
			if scene:
				held_prop_instance = scene.instantiate()
				get_tree().root.add_child(held_prop_instance)
				_disable_preview_collisions(held_prop_instance)

func _drop_grabbed_prop() -> void:
	if not held_prop_instance or held_prop_id < 0:
		return
	
	var drop_pos = held_prop_instance.global_position
	
	if building_manager and building_manager.has_method("place_object"):
		building_manager.place_object(drop_pos, held_prop_id, held_prop_rotation)
	
	if held_prop_instance:
		held_prop_instance.queue_free()
	held_prop_instance = null
	held_prop_id = -1
	held_prop_rotation = 0

func _get_pickup_target() -> Node:
	var cam = get_viewport().get_camera_3d()
	if not cam:
		return null
	
	var origin = cam.global_position
	var forward = -cam.global_transform.basis.z
	
	var space_state = cam.get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(origin, origin + forward * 3.0)
	if player:
		query.exclude = [player.get_rid()]
	
	var result = space_state.intersect_ray(query)
	if result.is_empty():
		return null
	
	var collider = result.get("collider")
	if collider and (collider.is_in_group("placed_objects") or collider.has_meta("item_data")):
		return collider
	
	return null

func _disable_preview_collisions(node: Node) -> void:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		node.disabled = true
	for child in node.get_children():
		_disable_preview_collisions(child)

func is_grabbing_prop() -> bool:
	return held_prop_instance != null and is_instance_valid(held_prop_instance)

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
