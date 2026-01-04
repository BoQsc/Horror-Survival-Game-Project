extends Node
class_name ModePlay
## ModePlay - Handles PLAY mode behaviors
## Combat, mining terrain, harvesting vegetation

# References
var player: WorldPlayer = null
var hotbar: Node = null
var mode_manager: Node = null

# Manager references
var terrain_manager: Node = null
var vegetation_manager: Node = null
var building_manager: Node = null

# Selection box for RESOURCE/BUCKET placement
var selection_box: MeshInstance3D = null
var current_target_pos: Vector3 = Vector3.ZERO
var has_target: bool = false

# Combat state
var attack_cooldown: float = 0.0
const ATTACK_COOLDOWN_TIME: float = 0.3

# Durability system - blocks/objects require multiple hits
const BLOCK_HP: int = 10 # Building blocks take 10 damage to destroy
const OBJECT_HP: int = 5 # Placed objects take 5 damage to destroy
const TREE_HP: int = 8 # Trees take 8 damage to chop
const TERRAIN_HP: int = 5 # Terrain takes 5 punches to break a grid cube
var block_damage: Dictionary = {} # Vector3i -> accumulated damage
var object_damage: Dictionary = {} # RID -> accumulated damage
var tree_damage: Dictionary = {} # collider RID -> accumulated damage
var terrain_damage: Dictionary = {} # Vector3i -> accumulated damage for terrain
var durability_target: Variant = null # Current target being damaged (RID or Vector3i)

# Prop holding state
var held_prop_instance: Node3D = null
var held_prop_id: int = -1
var held_prop_rotation: int = 0

# Fist punch sync - wait for animation to finish before next punch
var fist_punch_ready: bool = true

# Pistol fire sync - wait for animation to finish before next shot
var pistol_fire_ready: bool = true

var is_reloading: bool = false

# Axe swing sync
var axe_ready: bool = true

# Material display - lookup and tracking
const MATERIAL_NAMES = {
	-1: "Unknown",
	0: "Grass",
	1: "Stone",
	2: "Ore",
	3: "Sand",
	4: "Gravel",
	5: "Snow",
	6: "Road",
	9: "Granite",
	100: "[P] Grass",
	101: "[P] Stone",
	102: "[P] Sand",
	103: "[P] Snow"
}
var last_target_material: String = ""
var material_target_marker: MeshInstance3D = null
var mat_debug_on_click: bool = false # Only log when clicking

func _ready() -> void:
	# Find player - ModePlay is child of Modes which is child of WorldPlayer
	player = get_parent().get_parent() as WorldPlayer
	
	# Find hotbar - go up to WorldPlayer, then down to Systems/Hotbar
	hotbar = get_node_or_null("../../Systems/Hotbar")
	mode_manager = get_node_or_null("../../Systems/ModeManager")
	
	# Find managers via groups
	await get_tree().process_frame
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	building_manager = get_tree().get_first_node_in_group("building_manager")
	
	# Create selection box for terrain resource placement
	_create_selection_box()
	
	# Create debug marker for material targeting
	_create_material_target_marker()
	
	DebugManager.log_player("ModePlay: Initialized")
	DebugManager.log_player("  - Player: %s" % ("OK" if player else "MISSING"))
	DebugManager.log_player("  - Hotbar: %s" % ("OK" if hotbar else "MISSING"))
	DebugManager.log_player("  - TerrainManager: %s" % ("OK" if terrain_manager else "NOT FOUND"))
	DebugManager.log_player("  - VegetationManager: %s" % ("OK" if vegetation_manager else "NOT FOUND"))
	DebugManager.log_player("  - BuildingManager: %s" % ("OK" if building_manager else "NOT FOUND"))
	
	# Connect to punch ready signal for animation-synced attacks
	# Connect to punch ready signal for animation-synced attacks
	PlayerSignals.punch_ready.connect(_on_punch_ready)
	PlayerSignals.pistol_fire_ready.connect(_on_pistol_fire_ready)
	PlayerSignals.axe_ready.connect(_on_axe_ready)

func _create_selection_box() -> void:
	selection_box = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.01, 1.01, 1.01)
	selection_box.mesh = box_mesh
	
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.4, 0.8, 0.3, 0.5) # Green/brown for terrain
	selection_box.material_override = material
	selection_box.visible = false
	
	get_tree().root.add_child.call_deferred(selection_box)

func _process(delta: float) -> void:
	if attack_cooldown > 0:
		attack_cooldown -= delta
	
	# Update held prop position (if holding one)
	_update_held_prop(delta)
	
	# Update selection box for RESOURCE/BUCKET items
	_update_terrain_targeting()
	
	# Check if still looking at durability target
	_check_durability_target()
	
	# Update target material display
	_update_target_material()

func _input(event: InputEvent) -> void:
	# Only process in PLAY mode
	if mode_manager and not mode_manager.is_play_mode():
		return
	
	# T key for prop grab/drop (hold T to grab and move, release to drop)
	if event is InputEventKey and event.keycode == KEY_T:
		# Ignore echo (key repeat) events
		if event.echo:
			return
		
		if event.pressed:
			# T pressed down - grab prop
			if not is_grabbing_prop():
				DebugManager.log_player("PropGrab: Starting grab")
				_try_grab_prop()
		else:
			# T released - drop prop
			if is_grabbing_prop():
				DebugManager.log_player("PropGrab: Dropping")
				_drop_grabbed_prop()
	
	# E key for item pickup (adds to hotbar)
	if event is InputEventKey and event.keycode == KEY_E and event.pressed and not event.echo:
		_try_pickup_item()


func _update_terrain_targeting() -> void:
	if not player or not hotbar or not selection_box:
		return
	
	# Only show when in PLAY mode with RESOURCE or BUCKET selected
	if mode_manager and not mode_manager.is_play_mode():
		selection_box.visible = false
		has_target = false
		return
	
	var item = hotbar.get_selected_item()
	var category = item.get("category", 0)
	
	# Categories: 2=BUCKET, 3=RESOURCE
	if category != 2 and category != 3:
		selection_box.visible = false
		has_target = false
		return
	
	# Raycast to find target
	var hit = player.raycast(5.0)
	if hit.is_empty():
		selection_box.visible = false
		has_target = false
		return
	
	has_target = true
	
	# Calculate adjacent voxel position (where block will be placed)
	var pos = hit.position + hit.normal * 0.1
	current_target_pos = Vector3(floor(pos.x), floor(pos.y), floor(pos.z))
	
	# Update selection box position
	selection_box.global_position = current_target_pos + Vector3(0.5, 0.5, 0.5)
	selection_box.visible = true

## Handle primary action (left click) in PLAY mode
func handle_primary(item: Dictionary) -> void:
	mat_debug_on_click = true # Enable debug logging for this click
	DebugManager.log_player("ModePlay: handle_primary called with item: %s" % item.get("name", "unknown"))
	
	# If grabbing a prop, don't do other actions
	if is_grabbing_prop():
		DebugManager.log_player("ModePlay: Grabbing prop, ignoring primary action")
		return
	
	if attack_cooldown > 0:
		DebugManager.log_player("ModePlay: Still on cooldown (%.2f)" % attack_cooldown)
		return
	
	var category = item.get("category", 0)
	DebugManager.log_player("ModePlay: Category = %d" % category)
	
	match category:
		0: # NONE - Fists
			_do_punch(item)
		1: # TOOL
			_do_tool_attack(item)
		2: # BUCKET
			_do_bucket_collect(item)
		3: # RESOURCE
			pass # No primary action for resources
		6: # PROP - Pistol and other props
			DebugManager.log_player("ModePlay: PROP detected, id=%s" % item.get("id", "unknown"))
			_do_prop_primary(item)
		_:
			DebugManager.log_player("ModePlay: Unhandled category %d for item %s" % [category, item.get("name", "?")])

## Handle secondary action (right click) in PLAY mode
func handle_secondary(item: Dictionary) -> void:
	var category = item.get("category", 0)
	
	match category:
		0: # NONE - Fists
			pass # No secondary for fists
		1: # TOOL
			pass # No secondary for tools
		2: # BUCKET
			_do_bucket_place(item)
		3: # RESOURCE
			_do_resource_place(item)

## Callback when punch animation finishes
func _on_punch_ready() -> void:
	fist_punch_ready = true

## Callback when pistol fire animation finishes
func _on_pistol_fire_ready() -> void:
	pistol_fire_ready = true

## Callback when axe animation finishes
func _on_axe_ready() -> void:
	axe_ready = true

## Handle PROP primary action (pistol, etc.)
func _do_prop_primary(item: Dictionary) -> void:
	var item_id = item.get("id", "")
	if item_id == "heavy_pistol":
		_do_pistol_fire()

## Pistol fire - synced with animation
func _do_pistol_fire() -> void:
	if not player:
		return
	
	# Wait for animation to finish OR don't fire while reloading
	if not pistol_fire_ready or is_reloading:
		return
	
	# Block until animation finishes
	pistol_fire_ready = false
	
	# Emit signal for first-person pistol animation
	PlayerSignals.pistol_fired.emit()
	
	# Raycast for hit detection (longer range than fists)
	var hit = player.raycast(50.0, 0xFFFFFFFF, true, true)
	if hit.is_empty():
		DebugManager.log_player("ModePlay: Pistol - miss")
		return
	
	var target = hit.get("collider", null)
	var position = hit.get("position", Vector3.ZERO)
	
	# Spawn hit effect at impact point
	_spawn_pistol_hit_effect(position)
	
	# Deal damage to enemies
	if target and target.is_in_group("zombies") and target.has_method("take_damage"):
		target.take_damage(5)  # Pistol does 5 damage
		DebugManager.log_player("ModePlay: Pistol hit zombie for 5 damage")
		PlayerSignals.damage_dealt.emit(target, 5)
		return
	
	# Deal damage to blocks
	if target and target.is_in_group("blocks") and target.has_method("take_damage"):
		target.take_damage(2)
		DebugManager.log_player("ModePlay: Pistol hit block")
		return
	
	DebugManager.log_player("ModePlay: Pistol hit at %s" % position)

## Spawn red emissive sphere at hit point (matches original project)
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
	
	# Destroy after 2 seconds
	await get_tree().create_timer(2.0).timeout
	if is_instance_valid(mesh_instance):
		mesh_instance.queue_free()

## Punch attack with fists (synced with animation)
func _do_punch(item: Dictionary) -> void:
	if not player:
		return
	
	# Wait for animation to finish before allowing next punch
	if not fist_punch_ready:
		return
	
	# Block until animation finishes
	fist_punch_ready = false
	
	# Emit signal for first-person arms animation
	PlayerSignals.punch_triggered.emit()
	
	# Use collide_with_areas=true to detect grass/rocks (Area3D)
	# Use exclude_water=true to pierce through water surfaces
	var hit = player.raycast(5.0, 0xFFFFFFFF, true, true)
	if hit.is_empty():
		DebugManager.log_player("ModePlay: Punch - miss")
		return
	
	var damage = item.get("damage", 1)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	DebugManager.log_player("ModePlay: Punch - hit %s" % (target.name if target else "nothing"))
	
	# Check for damageable target (direct or parent with take_damage)
	var damageable = _find_damageable(target)
	if damageable:
		damageable.take_damage(damage)
		durability_target = target.get_rid()
		DebugManager.log_player("ModePlay: Punched %s for %d damage" % [damageable.name, damage])
		PlayerSignals.damage_dealt.emit(damageable, damage)
		return
	
	# Check for harvestable vegetation (with durability for trees)
	if target and vegetation_manager:
		if target.is_in_group("trees"):
			# Trees have durability - axes do 8 damage, fists do 1
			var tree_dmg = damage
			var item_id = item.get("id", "")
			if "axe" in item_id:
				tree_dmg = 8 # One-shot with axe
			var tree_rid = target.get_rid()
			tree_damage[tree_rid] = tree_damage.get(tree_rid, 0) + tree_dmg
			var current_hp = TREE_HP - tree_damage[tree_rid]
			durability_target = tree_rid # Track for look-away clearing
			DebugManager.log_player("ModePlay: Hit tree (%d/%d)" % [tree_damage[tree_rid], TREE_HP])
			PlayerSignals.durability_hit.emit(current_hp, TREE_HP, "Tree", durability_target)
			if tree_damage[tree_rid] >= TREE_HP:
				vegetation_manager.chop_tree_by_collider(target)
				tree_damage.erase(tree_rid)
				PlayerSignals.durability_cleared.emit()
				_collect_vegetation_resource("wood")
				DebugManager.log_player("ModePlay: Tree chopped!")
			return
		elif target.is_in_group("grass"):
			vegetation_manager.harvest_grass_by_collider(target)
			_collect_vegetation_resource("fiber")
			DebugManager.log_player("ModePlay: Punched grass")
			return
		elif target.is_in_group("rocks"):
			vegetation_manager.harvest_rock_by_collider(target)
			_collect_vegetation_resource("rock")
			DebugManager.log_player("ModePlay: Punched rock")
			return
	
	# Check for placed objects (furniture, etc.)
	if target and target.is_in_group("placed_objects") and building_manager:
		var obj_rid = target.get_rid()
		var obj_dmg = damage
		var item_id = item.get("id", "")
		if "pickaxe" in item_id:
			obj_dmg = 5 # Pickaxe one-shots objects
		object_damage[obj_rid] = object_damage.get(obj_rid, 0) + obj_dmg
		var current_hp = OBJECT_HP - object_damage[obj_rid]
		durability_target = obj_rid # Track for look-away clearing
		DebugManager.log_player("ModePlay: Hit object (%d/%d)" % [object_damage[obj_rid], OBJECT_HP])
		PlayerSignals.durability_hit.emit(current_hp, OBJECT_HP, target.name, durability_target)
		if object_damage[obj_rid] >= OBJECT_HP:
			# Remove via building manager
			if target.has_meta("anchor") and target.has_meta("chunk"):
				var anchor = target.get_meta("anchor")
				var chunk = target.get_meta("chunk")
				chunk.remove_object(anchor)
				DebugManager.log_player("ModePlay: Object destroyed!")
			object_damage.erase(obj_rid)
			PlayerSignals.durability_cleared.emit()
		return
	
	# Check for building blocks (voxels) - need to hit BuildingChunk mesh
	if target and building_manager:
		# Try to find if this is a building chunk
		var chunk = _find_building_chunk(target)
		if chunk:
			var block_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
			var blk_dmg = damage
			var item_id = item.get("id", "")
			if "pickaxe" in item_id:
				blk_dmg = 5 # Pickaxe does 5 damage
			block_damage[block_pos] = block_damage.get(block_pos, 0) + blk_dmg
			var current_hp = BLOCK_HP - block_damage[block_pos]
			durability_target = block_pos # Track for look-away clearing (Vector3i)
			DebugManager.log_player("ModePlay: Hit block at %s (%d/%d)" % [block_pos, block_damage[block_pos], BLOCK_HP])
			PlayerSignals.durability_hit.emit(current_hp, BLOCK_HP, "Block", durability_target)
			if block_damage[block_pos] >= BLOCK_HP:
				# Remove the block
				var voxel_pos = position - hit.get("normal", Vector3.ZERO) * 0.1
				var voxel_coord = Vector3(floor(voxel_pos.x), floor(voxel_pos.y), floor(voxel_pos.z))
				
				# Get voxel ID before destroying (to collect)
				var voxel_id = 0
				if building_manager.has_method("get_voxel"):
					voxel_id = building_manager.get_voxel(voxel_pos)
				
				building_manager.set_voxel(voxel_coord, 0.0)
				block_damage.erase(block_pos)
				PlayerSignals.durability_cleared.emit()
				DebugManager.log_player("ModePlay: Block destroyed!")
				
				# Collect resource
				if voxel_id > 0:
					_collect_building_resource(voxel_id)
			return
	
	# Default - hit terrain with durability system (grid-aligned breaking)
	if terrain_manager and terrain_manager.has_method("modify_terrain"):
		var punch_dmg = item.get("damage", 1)
		
		# Calculate grid position for this terrain cell
		var terrain_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
		
		# Accumulate damage on this grid cell
		terrain_damage[terrain_pos] = terrain_damage.get(terrain_pos, 0) + punch_dmg
		var current_hp = TERRAIN_HP - terrain_damage[terrain_pos]
		durability_target = terrain_pos # Track for look-away clearing
		
		DebugManager.log_player("ModePlay: Hit terrain at %s (%d/%d)" % [terrain_pos, terrain_damage[terrain_pos], TERRAIN_HP])
		PlayerSignals.durability_hit.emit(current_hp, TERRAIN_HP, "Terrain", durability_target)
		
		# Check if block should break
		if terrain_damage[terrain_pos] >= TERRAIN_HP:
			# Get material ID before breaking (for resource collection)
			var mat_id = -1
			if terrain_manager.has_method("get_material_at"):
				mat_id = terrain_manager.get_material_at(position)
			
			# Break a full 1x1x1 cube at grid center
			var center = Vector3(terrain_pos) + Vector3(0.5, 0.5, 0.5)
			terrain_manager.modify_terrain(center, 0.6, 1.0, 1, 0, -1) # Box shape, dig, terrain layer
			
			DebugManager.log_player("ModePlay: Terrain block broken at %s (mat: %d)" % [terrain_pos, mat_id])
			
			# Add collected resource to inventory
			if mat_id >= 0:
				_collect_terrain_resource(mat_id)
			
			# Clear tracking
			terrain_damage.erase(terrain_pos)
			PlayerSignals.durability_cleared.emit()
	else:
		DebugManager.log_player("ModePlay: No terrain_manager or missing modify_terrain method")

## Find BuildingChunk from a collider (check parent hierarchy)
func _find_building_chunk(collider: Node) -> Node:
	if not collider:
		return null
	
	# Check if collider itself is a BuildingChunk
	if collider.is_in_group("building_chunks"):
		return collider
	
	# Check parent chain
	var node = collider.get_parent()
	while node:
		if node.is_in_group("building_chunks"):
			return node
		node = node.get_parent()
	
	return null

## Find a node with take_damage method (check target and parent hierarchy)
func _find_damageable(target: Node) -> Node:
	if not target:
		return null
	
	# Direct check
	if target.has_method("take_damage"):
		return target
	
	# Check parent chain (for doors with sub-colliders like ClosedDoorBlocker)
	var node = target.get_parent()
	while node:
		if node.has_method("take_damage"):
			return node
		node = node.get_parent()
	
	return null

## Check if player is still looking at the durability target
## NOTE: This only clears durability_target for ModePlay's internal tracking.
## The UI persistence is handled by PlayerHUD._update_durability_visibility()
## durability_cleared is NOT emitted here - only when target is destroyed (HP=0)
func _check_durability_target() -> void:
	if durability_target == null:
		return
	
	if not player:
		return
	
	# Raycast to see what we're looking at
	var hit = player.raycast(5.0, 0xFFFFFFFF, true, true)
	if hit.is_empty():
		# Looking at nothing - clear internal target (but DON'T emit cleared signal)
		durability_target = null
		return
	
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	# Check if it's the same target based on type
	if durability_target is RID:
		# Tree or object - compare RID
		if target and target.get_rid() == durability_target:
			return # Still looking at same target
	elif durability_target is Vector3i:
		# Block - compare position
		var block_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
		if block_pos == durability_target:
			return # Still looking at same block
	
	# Different target or no match - clear internal target (but DON'T emit cleared signal)
	durability_target = null

## Tool attack/mine
func _do_tool_attack(item: Dictionary) -> void:
	if not player:
		DebugManager.log_player("ModePlay: Tool attack - no player!")
		return
	
	attack_cooldown = ATTACK_COOLDOWN_TIME
	
	# Special handling for Axe animations (sync with visual)
	var item_id = item.get("id", "")
	if "axe" in item_id and not "pickaxe" in item_id:
		# Wait for animation to finish
		if not axe_ready:
			return
		
		# Block until animation finishes
		axe_ready = false
		
		# Emit signal for first-person axe animation
		PlayerSignals.axe_fired.emit()
	
	# Use collide_with_areas=true to hit vegetation (grass)
	# Use exclude_water=true
	var hit = player.raycast(3.5, 0xFFFFFFFF, true, true) # Tool range
	if hit.is_empty():
		DebugManager.log_player("ModePlay: Tool attack - no hit")
		return
	
	var damage = item.get("damage", 1)
	var mining_strength = item.get("mining_strength", 1.0)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	DebugManager.log_player("ModePlay: Tool hit %s at %s (mining_strength: %.1f)" % [target.name if target else "nothing", position, mining_strength])
	
	# Priority 1: Generic Damageable (Enemies, Doors, etc.)
	# This covers Enemies (have take_damage) and Doors (have take_damage)
	# Prioritizing this ensures we interact with complex entities first
	var damageable = _find_damageable(target)
	if damageable:
		# Axe Bonus vs Zombies
		if "axe" in item.get("id", "") and damageable.is_in_group("zombies"):
			damage = 10 # 1-hit kill guarantee
			DebugManager.log_player("ModePlay: Axe Zombie Bonus Applied!")
			
		damageable.take_damage(damage)
		durability_target = target.get_rid() # Track for look-away clearing
		DebugManager.log_player("ModePlay: Tool hit damageable %s for %d damage" % [damageable.name, damage])
		PlayerSignals.damage_dealt.emit(damageable, damage)
		return
	
	# Priority 2: Harvest vegetation
	if target and vegetation_manager:
		if target.is_in_group("trees"):
			var tree_dmg = damage
			# Axe does 3 damage to trees (requires 3 hits for 8 HP)
			if "axe" in item.get("id", ""):
				tree_dmg = 3
				
			var tree_rid = target.get_rid()
			tree_damage[tree_rid] = tree_damage.get(tree_rid, 0) + tree_dmg
			var current_hp = TREE_HP - tree_damage[tree_rid]
			
			durability_target = tree_rid
			DebugManager.log_player("ModePlay: Hit tree (%d/%d)" % [tree_damage[tree_rid], TREE_HP])
			PlayerSignals.durability_hit.emit(current_hp, TREE_HP, "Tree", durability_target)
			
			if tree_damage[tree_rid] >= TREE_HP:
				vegetation_manager.chop_tree_by_collider(target)
				tree_damage.erase(tree_rid)
				PlayerSignals.durability_cleared.emit()
				_collect_vegetation_resource("wood")
				DebugManager.log_player("ModePlay: Tree chopped!")
			return
		elif target.is_in_group("grass"):
			vegetation_manager.harvest_grass_by_collider(target)
			_collect_vegetation_resource("fiber")
			DebugManager.log_player("ModePlay: Harvested grass")
			return
		elif target.is_in_group("rocks"):
			vegetation_manager.harvest_rock_by_collider(target)
			_collect_vegetation_resource("rock")
			DebugManager.log_player("ModePlay: Mined rock")
			return
	
	# Priority 3: Break placed objects (with durability)
	if target and target.is_in_group("placed_objects") and building_manager:
		var obj_rid = target.get_rid()
		var obj_dmg = damage
		# item_id already defined at top of function
		if "pickaxe" in item_id:
			obj_dmg = 5 # Pickaxe one-shots objects
		object_damage[obj_rid] = object_damage.get(obj_rid, 0) + obj_dmg
		var current_hp = OBJECT_HP - object_damage[obj_rid]
		durability_target = obj_rid
		DebugManager.log_player("ModePlay: Tool hit object (%d/%d)" % [object_damage[obj_rid], OBJECT_HP])
		PlayerSignals.durability_hit.emit(current_hp, OBJECT_HP, target.name, durability_target)
		if object_damage[obj_rid] >= OBJECT_HP:
			if target.has_meta("anchor") and target.has_meta("chunk"):
				var anchor = target.get_meta("anchor")
				var chunk = target.get_meta("chunk")
				chunk.remove_object(anchor)
				DebugManager.log_player("ModePlay: Object destroyed with tool!")
			object_damage.erase(obj_rid)
			PlayerSignals.durability_cleared.emit()
		return
	
	# Priority 4: Break building blocks (with durability)
	if target and building_manager:
		var chunk = _find_building_chunk(target)
		if chunk:
			var block_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
			var blk_dmg = damage
			# item_id already defined at top of function
			if "pickaxe" in item_id:
				blk_dmg = 5 # Pickaxe does 5 damage
			block_damage[block_pos] = block_damage.get(block_pos, 0) + blk_dmg
			var current_hp = BLOCK_HP - block_damage[block_pos]
			durability_target = block_pos
			DebugManager.log_player("ModePlay: Tool hit block at %s (%d/%d)" % [block_pos, block_damage[block_pos], BLOCK_HP])
			PlayerSignals.durability_hit.emit(current_hp, BLOCK_HP, "Block", durability_target)
			if block_damage[block_pos] >= BLOCK_HP:
				var voxel_pos = position - hit.get("normal", Vector3.ZERO) * 0.1
				var voxel_coord = Vector3(floor(voxel_pos.x), floor(voxel_pos.y), floor(voxel_pos.z))
				
				# Get voxel ID before destroying (to collect)
				var voxel_id = 0
				if building_manager.has_method("get_voxel"):
					voxel_id = building_manager.get_voxel(voxel_pos)
					DebugManager.log_player("ModePlay: Destroying block at %s. Voxel ID: %d" % [voxel_pos, voxel_id])
				
				building_manager.set_voxel(voxel_coord, 0.0)
				block_damage.erase(block_pos)
				PlayerSignals.durability_cleared.emit()
				DebugManager.log_player("ModePlay: Block destroyed with tool!")
				
				# Collect resource
				if voxel_id > 0:
					_collect_building_resource(voxel_id)
				else:
					DebugManager.log_player("ModePlay: WARNING - Voxel ID was 0, no collection!")
			return
	
	# Priority 5: Mine terrain (instant with mining_strength)
	DebugManager.log_player("ModePlay: Trying to mine terrain... terrain_manager=%s" % (terrain_manager != null))
	if terrain_manager:
		DebugManager.log_player("ModePlay: terrain_manager.has_method('modify_terrain')=%s" % terrain_manager.has_method("modify_terrain"))
		if terrain_manager.has_method("modify_terrain"):
			# Get material ID BEFORE digging (to collect what was there)
			var mat_id = -1
			if terrain_manager.has_method("get_material_at"):
				mat_id = terrain_manager.get_material_at(position)
			
			DebugManager.log_player("ModePlay: Calling modify_terrain(%s, %.1f, 1.0, 0, 0)" % [position, mining_strength])
			# Minimum radius of 0.8 to guarantee visible terrain change
			var actual_radius = max(mining_strength, 0.8)
			terrain_manager.modify_terrain(position, actual_radius, 1.0, 0, 0)
			DebugManager.log_player("ModePlay: Mined terrain at %s (strength: %.1f, radius: %.1f)" % [position, mining_strength, actual_radius])
			
			# Collect resource
			if mat_id >= 0:
				_collect_terrain_resource(mat_id)
		else:
			DebugManager.log_player("ModePlay: terrain_manager missing modify_terrain method!")
	else:
		DebugManager.log_player("ModePlay: terrain_manager is NULL!")

## Collect water with bucket
func _do_bucket_collect(_item: Dictionary) -> void:
	if not player or not terrain_manager:
		return
	
	# Use EXACT same position calculation as placement
	if not has_target:
		return
	
	var center = current_target_pos + Vector3(0.5, 0.5, 0.5)
	terrain_manager.modify_terrain(center, 0.6, 0.5, 1, 1) # Same as placement but positive value
	DebugManager.log_player("ModePlay: Collected water at %s" % current_target_pos)
	# TODO: Switch bucket from empty to full

## Place water from bucket
func _do_bucket_place(_item: Dictionary) -> void:
	if not player or not terrain_manager:
		return
	
	# Use grid-aligned position if targeting is active
	if has_target:
		var center = current_target_pos + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(center, 0.6, -0.5, 1, 1) # Box shape, fill, water layer
		DebugManager.log_player("ModePlay: Placed water at %s" % current_target_pos)
	else:
		var hit = player.raycast(5.0)
		if hit.is_empty():
			return
		var pos = hit.position + hit.normal * 0.5
		terrain_manager.modify_terrain(pos, 0.6, -0.5, 1, 1)
		DebugManager.log_player("ModePlay: Placed water at %s" % pos)
	# TODO: Switch bucket from full to empty

## Place resource (terrain material) - paints voxel with resource's material ID
## Also handles vegetation resource placement (fiber -> grass, rock -> rock)
func _do_resource_place(item: Dictionary) -> void:
	if not player:
		return
	
	var item_id = item.get("id", "")
	
	# Check if this is a vegetation resource
	if item_id == "veg_fiber":
		_do_vegetation_place("grass")
		return
	elif item_id == "veg_rock":
		_do_vegetation_place("rock")
		return
	
	# Otherwise it's a terrain resource - need terrain_manager
	if not terrain_manager:
		return
	
	# Get material ID from resource item (legacy: 100=Grass, 101=Stone, 102=Sand, 103=Snow)
	# Item definitions use mat_id field (0=Grass, 1=Sand, etc) - need to check both formats
	var mat_id = item.get("mat_id", -1)
	DebugManager.log_player("ModePlay: _do_resource_place item=%s mat_id_raw=%d" % [item, mat_id])
	if mat_id < 0:
		# Fallback: check if it has a material_id field
		mat_id = item.get("material_id", 0)
		DebugManager.log_player("ModePlay: Fallback to material_id field, mat_id=%d" % mat_id)
	
	# CRITICAL: Add 100 offset for player-placed materials!
	# The terrain shader only skips biome blending for mat_id >= 100
	# Legacy system used: 100=Grass, 101=Stone, 102=Sand, 103=Snow
	if mat_id < 100:
		mat_id += 100
		DebugManager.log_player("ModePlay: Converted to player-placed mat_id=%d" % mat_id)
	
	# Use grid-aligned position if targeting is active
	if has_target:
		var center = current_target_pos
		# Fixed 0.25 brush size (Single Vertex), Precise Box shape (3), terrain layer (0), with mat_id
		# Use -10.0 density for "Hard Place" (Instant Isosurface Snap)
		terrain_manager.modify_terrain(center, 0.25, -10.0, 3, 0, mat_id)
		_consume_selected_item()
		DebugManager.log_player("ModePlay: Placed %s (mat:%d) at %s (Hard)" % [item.get("name", "resource"), mat_id, current_target_pos])
	else:
		var hit = player.raycast(5.0)
		if hit.is_empty():
			return
		# Target voxel outside terrain (adjacent to hit surface)
		var p = hit.position + hit.normal * 0.1
		var target_pos = Vector3(floor(p.x), floor(p.y), floor(p.z))
		# Hard Place (Single Vertex)
		terrain_manager.modify_terrain(target_pos, 0.25, -10.0, 3, 0, mat_id)
		_consume_selected_item()
		DebugManager.log_player("ModePlay: Placed %s (mat:%d) at %s (Hard Fallback)" % [item.get("name", "resource"), mat_id, target_pos])

## Place vegetation (grass or rock) at raycast hit position
func _do_vegetation_place(veg_type: String) -> void:
	if not player or not vegetation_manager:
		DebugManager.log_player("ModePlay: Cannot place vegetation - missing player or vegetation_manager")
		return
	
	var hit = player.raycast(5.0)
	if hit.is_empty():
		DebugManager.log_player("ModePlay: Cannot place vegetation - no hit")
		return
	
	if veg_type == "grass":
		vegetation_manager.place_grass(hit.position)
		_consume_selected_item()
		DebugManager.log_player("ModePlay: Placed grass at %s" % hit.position)
	elif veg_type == "rock":
		vegetation_manager.place_rock(hit.position)
		_consume_selected_item()
		DebugManager.log_player("ModePlay: Placed rock at %s" % hit.position)

func _exit_tree() -> void:
	if selection_box and is_instance_valid(selection_box):
		selection_box.queue_free()
	if held_prop_instance and is_instance_valid(held_prop_instance):
		held_prop_instance.queue_free()

#region Prop Pickup/Drop System

## Update held prop position (follows camera)
func _update_held_prop(delta: float) -> void:
	if not held_prop_instance or not is_instance_valid(held_prop_instance):
		return
	
	# Get camera from player
	var cam: Camera3D = null
	if player and player.has_node("Head/Camera3D"):
		cam = player.get_node("Head/Camera3D")
	if not cam:
		cam = get_viewport().get_camera_3d()
	if not cam:
		DebugManager.log_player("PropHold: WARNING - No camera found!")
		return
	
	# Float 2 meters in front of camera
	var target_pos = cam.global_position - cam.global_transform.basis.z * 2.0
	# Smoothly interpolate
	held_prop_instance.global_position = held_prop_instance.global_position.lerp(target_pos, delta * 15.0)
	# Match camera rotation (yaw only)
	var cam_rot_y = cam.global_rotation.y
	held_prop_instance.rotation.y = lerp_angle(held_prop_instance.rotation.y, cam_rot_y + deg_to_rad(held_prop_rotation * 90.0), delta * 10.0)
	
	# Debug every 60 frames
	if Engine.get_process_frames() % 60 == 0:
		DebugManager.log_player("PropHold: Prop at %s (visible: %s)" % [held_prop_instance.global_position, held_prop_instance.visible])

## Find a prop that can be picked up (building_manager objects OR dropped physics props)
func _get_pickup_target() -> Node:
	var cam = get_viewport().get_camera_3d()
	if not cam:
		return null
	
	var origin = cam.global_position
	var forward = - cam.global_transform.basis.z
	
	# Option A: Precise raycast
	var hit = player.raycast(5.0) if player else {}
	
	if hit and hit.has("collider"):
		var col = hit.collider
		# Check for building_manager placed objects
		if col.is_in_group("placed_objects") and col.has_meta("anchor"):
			DebugManager.log_player("PropPickup: Direct hit on placed object %s" % col.name)
			return col
		# Check for dropped physics props (RigidBody3D with item_data or interactable)
		if col is RigidBody3D and (col.has_meta("item_data") or col.is_in_group("interactable")):
			DebugManager.log_player("PropPickup: Direct hit on dropped prop %s" % col.name)
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
		DebugManager.log_player("PropPickup: Assisted hit on %s" % best_target.name)
	return best_target

## Try to grab a prop (building_manager object OR dropped physics prop)
func _try_grab_prop() -> void:
	var target = _get_pickup_target()
	if not target:
		return
	
	DebugManager.log_player("PropGrab: Trying to grab %s" % target.name)
	
	# Check if this is a dropped physics prop (has item_data, no anchor/chunk)
	if target is RigidBody3D and target.has_meta("item_data"):
		_grab_dropped_prop(target)
		return
	
	# Otherwise, try building_manager object path
	if not target.has_meta("anchor") or not target.has_meta("chunk"):
		DebugManager.log_player("PropGrab: Target has no anchor/chunk metadata")
		return
	
	var anchor = target.get_meta("anchor")
	var chunk = target.get_meta("chunk")
	
	if not chunk or not chunk.objects.has(anchor):
		DebugManager.log_player("PropPickup: No object data at anchor")
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
		if not cam:
			cam = get_viewport().get_camera_3d()
		if cam:
			held_prop_instance.global_position = cam.global_position - cam.global_transform.basis.z * 2.0
			DebugManager.log_player("PropPickup: Picked up prop ID %d at %s" % [held_prop_id, held_prop_instance.global_position])
		else:
			DebugManager.log_player("PropPickup: WARNING - No camera, prop may be mispositioned")

## Grab a dropped physics prop (RigidBody3D with item_data meta)
func _grab_dropped_prop(target: RigidBody3D) -> void:
	# Store reference directly - don't need to respawn, just move it
	held_prop_instance = target
	held_prop_id = -1  # No object registry ID for dropped items
	held_prop_rotation = 0
	
	# Store item data for later drop
	if target.has_meta("item_data"):
		held_prop_instance.set_meta("grabbed_item_data", target.get_meta("item_data"))
	
	# Freeze physics and disable collisions for holding
	target.freeze = true
	target.collision_layer = 0
	target.collision_mask = 0
	_disable_preview_collisions(target)
	
	# Position at camera
	var cam = get_viewport().get_camera_3d()
	if cam:
		held_prop_instance.global_position = cam.global_position - cam.global_transform.basis.z * 2.0
		DebugManager.log_player("PropGrab: Grabbed dropped prop %s" % target.name)
	else:
		DebugManager.log_player("PropGrab: WARNING - No camera")

## Drop the grabbed prop
func _drop_grabbed_prop() -> void:
	if not held_prop_instance:
		return
	
	DebugManager.log_player("PropDrop: Dropping prop")
	
	# Check if this was a grabbed dropped prop (not a building_manager object)
	if held_prop_id == -1:
		# Re-enable physics and drop naturally
		if held_prop_instance is RigidBody3D:
			# Re-enable collision shapes first!
			_enable_preview_collisions(held_prop_instance)
			held_prop_instance.freeze = false
			held_prop_instance.collision_layer = 1  # Default layer
			held_prop_instance.collision_mask = 1  # Default mask
			# Give a small drop velocity
			held_prop_instance.linear_velocity = Vector3(0, -1, 0)
			DebugManager.log_player("PropDrop: Released dropped prop with physics")
		held_prop_instance = null
		held_prop_id = -1
		held_prop_rotation = 0
		return
	
	var drop_pos = held_prop_instance.global_position
	
	# Compensate for chunk centering offset
	var drop_obj_def = ObjectRegistry.get_object(held_prop_id)
	var obj_size = drop_obj_def.get("size", Vector3i(1, 1, 1))
	var offset_x = float(obj_size.x) / 2.0
	var offset_z = float(obj_size.z) / 2.0
	
	if held_prop_rotation == 1 or held_prop_rotation == 3:
		var temp = offset_x
		offset_x = offset_z
		offset_z = temp
	
	var center_offset = Vector3(offset_x, 0, offset_z)
	var adjusted_drop_pos = drop_pos - center_offset
	
	DebugManager.log_player("PropDrop: building_manager = %s" % building_manager)
	DebugManager.log_player("PropDrop: Drop at %s, adjusted = %s" % [drop_pos, adjusted_drop_pos])
	
	# Try placement via building manager
	var success = false
	if building_manager and building_manager.has_method("place_object"):
		success = building_manager.place_object(adjusted_drop_pos, held_prop_id, held_prop_rotation)
		DebugManager.log_player("PropDrop: place_object returned %s" % success)
	else:
		DebugManager.log_player("PropDrop: No building_manager or no place_object method!")
	
	# If direct placement failed, try "Smart Search" (find nearby available cell)
	if not success and building_manager:
		var chunk_size = building_manager.get("CHUNK_SIZE")
		if chunk_size == null:
			chunk_size = 16 # fallback
		
		var chunk_x = int(floor(drop_pos.x / chunk_size))
		var chunk_y = int(floor(drop_pos.y / chunk_size))
		var chunk_z = int(floor(drop_pos.z / chunk_size))
		var chunk_key = Vector3i(chunk_x, chunk_y, chunk_z)
		
		if building_manager.chunks.has(chunk_key):
			var chunk = building_manager.chunks[chunk_key]
			var local_x = int(floor(drop_pos.x)) % chunk_size
			var local_y = int(floor(drop_pos.y)) % chunk_size
			var local_z = int(floor(drop_pos.z)) % chunk_size
			if local_x < 0: local_x += chunk_size
			if local_y < 0: local_y += chunk_size
			if local_z < 0: local_z += chunk_size
			var base_anchor = Vector3i(local_x, local_y, local_z)
			
			var range_r = 2
			for dx in range(-range_r, range_r + 1):
				for dy in range(-range_r, range_r + 1):
					for dz in range(-range_r, range_r + 1):
						if dx == 0 and dy == 0 and dz == 0: continue
						var try_anchor = base_anchor + Vector3i(dx, dy, dz)
						if chunk.has_method("is_cell_available") and chunk.is_cell_available(try_anchor):
							var anchor_world_pos = Vector3(chunk_key) * chunk_size + Vector3(try_anchor)
							var new_fractional = drop_pos - anchor_world_pos
							var cells: Array[Vector3i] = [try_anchor]
							var obj_def = ObjectRegistry.get_object(held_prop_id)
							var packed = load(obj_def.scene)
							var instance = packed.instantiate()
							instance.position = Vector3(try_anchor) + new_fractional
							instance.rotation_degrees.y = held_prop_rotation * 90
							chunk.place_object(try_anchor, held_prop_id, held_prop_rotation, cells, instance, new_fractional)
							
							DebugManager.log_player("PropDrop: Placed at nearby anchor %s" % try_anchor)
							success = true
							break
					if success: break
				if success: break
	
	if not success:
		DebugManager.log_player("PropDrop: Placement failed, prop lost")
	else:
		DebugManager.log_player("PropDrop: Placed successfully")
	
	# Cleanup held prop
	if held_prop_instance:
		held_prop_instance.queue_free()
	held_prop_instance = null
	held_prop_id = -1
	held_prop_rotation = 0

## Recursively disable collisions on a node tree
func _disable_preview_collisions(node: Node) -> void:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		node.disabled = true
	for child in node.get_children():
		_disable_preview_collisions(child)

## Recursively re-enable collisions on a node tree
func _enable_preview_collisions(node: Node) -> void:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		node.disabled = false
	for child in node.get_children():
		_enable_preview_collisions(child)

## Check if currently grabbing a prop
func is_grabbing_prop() -> bool:
	return held_prop_instance != null and is_instance_valid(held_prop_instance)

#endregion

#region Item Pickup (E key)

## Try to pick up an item and add it to hotbar
func _try_pickup_item() -> void:
	if not player or not hotbar:
		return
	
	# Raycast to find interactable items
	var hit = player.raycast(3.0, 0xFFFFFFFF, false, false)
	if hit.is_empty():
		return
	
	var target = hit.get("collider")
	if not target:
		return
	
	# Check if it's a pickupable item (interactable group)
	if not target.is_in_group("interactable"):
		# Check parent for interactable (collision shapes are children)
		var parent = target.get_parent()
		while parent:
			if parent.is_in_group("interactable"):
				target = parent
				break
			parent = parent.get_parent()
		if not target.is_in_group("interactable"):
			return
	
	# Determine item type from the target name
	var item_data = _get_item_data_from_pickup(target)
	if item_data.is_empty():
		DebugManager.log_player("ItemPickup: Unknown item: %s" % target.name)
		return
	
	# Try to add to hotbar
	if hotbar.add_item(item_data):
		DebugManager.log_player("ItemPickup: Picked up %s" % item_data.get("name", "item"))
		# Remove from world
		target.queue_free()
		# Hide the interaction prompt
		PlayerSignals.interaction_unavailable.emit()
	else:
		DebugManager.log_player("ItemPickup: Hotbar full, cannot pick up %s" % item_data.get("name", "item"))

## Get item data dictionary from a pickup target
func _get_item_data_from_pickup(target: Node) -> Dictionary:
	var name_lower = target.name.to_lower()
	
	# Pistol variants
	if "pistol" in name_lower:
		return ItemDefinitions.get_heavy_pistol_definition()
	
	# Add more pickupable items here as needed
	# Example: if "shotgun" in name_lower: ...
	
	return {}

#endregion

#region Material Display

## Create debug marker for material target visualization
func _create_material_target_marker() -> void:
	material_target_marker = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.15
	sphere.height = 0.3
	material_target_marker.mesh = sphere
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 0.3, 0.1, 1.0) # Orange-red
	material_target_marker.material_override = mat
	material_target_marker.visible = false
	
	get_tree().root.add_child.call_deferred(material_target_marker)

## Update target material display in HUD
func _update_target_material() -> void:
	if not player:
		return
	
	var hit = player.raycast(10.0, 0xFFFFFFFF, false, true) # Long range, exclude water
	if hit.is_empty():
		if material_target_marker:
			material_target_marker.visible = false
		if last_target_material != "":
			last_target_material = ""
			PlayerSignals.target_material_changed.emit("")
		return
	
	var target = hit.get("collider")
	var hit_pos = hit.get("position", Vector3.ZERO)
	var hit_normal = hit.get("normal", Vector3.UP)
	var material_name = ""
	
	# Update marker position
	if material_target_marker:
		material_target_marker.global_position = hit_pos
		material_target_marker.visible = true
	
	# Check if we hit terrain (StaticBody3D in 'terrain' group)
	if target and target.is_in_group("terrain"):
		# Try to get material from mesh vertex color (most accurate)
		var mat_id = _get_material_from_mesh(target, hit_pos)
		
		# Fallback to buffer sampling if mesh reading failed
		if mat_id < 0:
			var sample_pos = hit_pos - hit_normal * 0.1
			mat_id = _get_material_at(sample_pos)
		
		material_name = MATERIAL_NAMES.get(mat_id, "Unknown (%d)" % mat_id)
		
		# Debug logging (only when digging/clicking)
		if mat_debug_on_click:
			DebugManager.log_player("[MAT_DEBUG] hit_pos=%.1f,%.1f,%.1f mat_id=%d (%s)" % [
				hit_pos.x, hit_pos.y, hit_pos.z, mat_id, material_name
			])
			mat_debug_on_click = false
	elif target and target.is_in_group("building_chunks"):
		material_name = "Building Block"
	elif target and target.is_in_group("trees"):
		material_name = "Tree"
	elif target and target.is_in_group("placed_objects"):
		material_name = "Object"
	
	if material_name != last_target_material:
		last_target_material = material_name
		PlayerSignals.target_material_changed.emit(material_name)

## Get material ID from mesh vertex color at hit point (100% accurate)
## Finds the exact triangle containing the hit point and interpolates vertex colors
## Returns -1 if unable to read from mesh
func _get_material_from_mesh(terrain_node: Node, hit_pos: Vector3) -> int:
	# Find the MeshInstance3D child of the terrain node
	var mesh_instance: MeshInstance3D = null
	for child in terrain_node.get_children():
		if child is MeshInstance3D:
			mesh_instance = child
			break
	
	if not mesh_instance or not mesh_instance.mesh:
		return -1
	
	var mesh = mesh_instance.mesh
	if not mesh is ArrayMesh:
		return -1
	
	# Get mesh data
	var arrays = mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return -1
	
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	var colors = arrays[Mesh.ARRAY_COLOR]
	
	if vertices.is_empty() or colors.is_empty():
		return -1
	
	# Convert hit position to local mesh space
	var local_pos = mesh_instance.global_transform.affine_inverse() * hit_pos
	
	# Find the triangle containing the hit point
	# Mesh is triangle list, so every 3 vertices form a triangle
	var best_mat_id = -1
	var best_dist = INF
	
	for i in range(0, vertices.size(), 3):
		if i + 2 >= vertices.size():
			break
		
		var v0 = vertices[i]
		var v1 = vertices[i + 1]
		var v2 = vertices[i + 2]
		
		# Check distance from point to triangle plane first (quick rejection)
		var tri_center = (v0 + v1 + v2) / 3.0
		var dist_to_center = local_pos.distance_squared_to(tri_center)
		
		# Only check triangles within reasonable distance
		if dist_to_center > 4.0: # Skip triangles > 2 units away
			continue
		
		# Compute closest point on triangle to local_pos
		var closest_on_tri = _closest_point_on_triangle(local_pos, v0, v1, v2)
		var dist = local_pos.distance_squared_to(closest_on_tri)
		
		if dist < best_dist:
			best_dist = dist
			# Get barycentric coordinates for interpolation
			var bary = _barycentric(closest_on_tri, v0, v1, v2)
			var c0 = colors[i]
			var c1 = colors[i + 1]
			var c2 = colors[i + 2]
			# Interpolate color using barycentric weights
			var interp_color = c0 * bary.x + c1 * bary.y + c2 * bary.z
			best_mat_id = int(round(interp_color.r * 255.0))
	
	return best_mat_id

## Compute barycentric coordinates of point P in triangle (A, B, C)
func _barycentric(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 = b - a
	var v1 = c - a
	var v2 = p - a
	
	var d00 = v0.dot(v0)
	var d01 = v0.dot(v1)
	var d11 = v1.dot(v1)
	var d20 = v2.dot(v0)
	var d21 = v2.dot(v1)
	
	var denom = d00 * d11 - d01 * d01
	if abs(denom) < 0.00001:
		return Vector3(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0) # Degenerate - equal weights
	
	var v = (d11 * d20 - d01 * d21) / denom
	var w = (d00 * d21 - d01 * d20) / denom
	var u = 1.0 - v - w
	
	return Vector3(u, v, w)

## Find the closest point on a triangle to a given point
func _closest_point_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	# Check if P projects inside the triangle
	var ab = b - a
	var ac = c - a
	var ap = p - a
	
	var d1 = ab.dot(ap)
	var d2 = ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a # Closest to vertex A
	
	var bp = p - b
	var d3 = ab.dot(bp)
	var d4 = ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b # Closest to vertex B
	
	var vc = d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		var v = d1 / (d1 - d3)
		return a + ab * v # Closest to edge AB
	
	var cp = p - c
	var d5 = ab.dot(cp)
	var d6 = ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c # Closest to vertex C
	
	var vb = d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		var w = d2 / (d2 - d6)
		return a + ac * w # Closest to edge AC
	
	var va = d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		var w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w # Closest to edge BC
	
	# P projects inside the triangle
	var denom = 1.0 / (va + vb + vc)
	var v = vb * denom
	var w = vc * denom
	return a + ab * v + ac * w


## Get material ID at a given world position (fallback - uses chunk_manager's buffer lookup)
func _get_material_at(pos: Vector3) -> int:
	if terrain_manager and terrain_manager.has_method("get_material_at"):
		return terrain_manager.get_material_at(pos)
	return -1 # Unknown

## Collect terrain resource and add to hotbar/inventory
func _collect_terrain_resource(mat_id: int) -> void:
	# Get resource item from material ID
	const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")
	var resource_item = ItemDefs.get_resource_for_material(mat_id)
	
	if resource_item.get("id", "empty") == "empty":
		print("ModePlay: No resource for material ID %d" % mat_id)
		return
	
	# Try to add to hotbar first (for quick access)
	if hotbar and hotbar.has_method("add_item"):
		if hotbar.add_item(resource_item):
			DebugManager.log_player("ModePlay: Collected 1x %s to hotbar" % resource_item.get("name", "Resource"))
			return
	
	# Fall back to inventory if hotbar is full
	var inventory = player.get_node_or_null("Systems/Inventory") if player else null
	if not inventory or not inventory.has_method("add_item"):
		print("ModePlay: No inventory system found")
		return
	
	# Add to inventory
	var leftover = inventory.add_item(resource_item, 1)
	if leftover == 0:
		DebugManager.log_player("ModePlay: Collected 1x %s to inventory" % resource_item.get("name", "Resource"))
	else:
		DebugManager.log_player("ModePlay: Inventory full, dropped %s" % resource_item.get("name", "Resource"))

## Collect vegetation resource and add to hotbar/inventory
func _collect_vegetation_resource(veg_type: String) -> void:
	# Get resource item from vegetation type
	const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")
	var resource_item = ItemDefs.get_vegetation_resource(veg_type)
	
	if resource_item.is_empty():
		print("ModePlay: No resource for vegetation type '%s'" % veg_type)
		return
	
	# Try to add to hotbar first (for quick access)
	if hotbar and hotbar.has_method("add_item"):
		if hotbar.add_item(resource_item):
			DebugManager.log_player("ModePlay: Collected 1x %s to hotbar" % resource_item.get("name", "Resource"))
			return
	
	# Fall back to inventory if hotbar is full
	var inventory = player.get_node_or_null("Systems/Inventory") if player else null
	if not inventory or not inventory.has_method("add_item"):
		print("ModePlay: No inventory system found")
		return
	
	# Add to inventory
	var leftover = inventory.add_item(resource_item, 1)
	if leftover == 0:
		DebugManager.log_player("ModePlay: Collected 1x %s to inventory" % resource_item.get("name", "Resource"))
	else:
		DebugManager.log_player("ModePlay: Inventory full, dropped %s" % resource_item.get("name", "Resource"))

## Collect building block resource and add to hotbar/inventory
func _collect_building_resource(block_id: int) -> void:
	const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")
	var item_data = ItemDefs.get_item_for_block(block_id)
	
	if item_data.is_empty():
		DebugManager.log_player("ModePlay: No item found for block ID %d" % block_id)
		return

	# Try to add to hotbar first
	if hotbar and hotbar.has_method("add_item"):
		if hotbar.add_item(item_data):
			DebugManager.log_player("ModePlay: Collected 1x %s to hotbar" % item_data.get("name", "Block"))
			return
	
	# Fall back to inventory
	var inventory = player.get_node_or_null("Systems/Inventory") if player else null
	if not inventory or not inventory.has_method("add_item"):
		return
	
	var leftover = inventory.add_item(item_data, 1)
	if leftover == 0:
		DebugManager.log_player("ModePlay: Collected 1x %s to inventory" % item_data.get("name", "Block"))
	else:
		DebugManager.log_player("ModePlay: Inventory full, dropped %s" % item_data.get("name", "Block"))

## Consume 1 of the currently selected item from hotbar
## Decrements the stack count by 1, clearing the slot if count reaches 0
func _consume_selected_item() -> void:
	if not hotbar:
		return
	
	var item = hotbar.get_selected_item()
	var item_id = item.get("id", "empty")
	
	if item_id == "empty":
		return
	
	# Don't consume tools/fists (they don't deplete)
	var category = item.get("category", 0)
	if category == 0 or category == 1: # NONE (fists) or TOOL
		return
	
	# Decrement the stack count by 1
	var slot_idx = hotbar.get_selected_index()
	var remaining = hotbar.decrement_slot(slot_idx, 1)
	
	if remaining:
		var new_count = hotbar.get_count_at(slot_idx)
		DebugManager.log_player("ModePlay: Used 1x %s (remaining: %d)" % [item.get("name", "item"), new_count])
	else:
		DebugManager.log_player("ModePlay: Used last %s from slot %d" % [item.get("name", "item"), slot_idx])

#endregion
