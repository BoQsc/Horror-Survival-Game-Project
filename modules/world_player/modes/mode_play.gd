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
var block_damage: Dictionary = {} # Vector3i -> accumulated damage
var object_damage: Dictionary = {} # RID -> accumulated damage
var tree_damage: Dictionary = {} # collider RID -> accumulated damage
var durability_target: Variant = null # Current target being damaged (RID or Vector3i)

# Prop holding state
var held_prop_instance: Node3D = null
var held_prop_id: int = -1
var held_prop_rotation: int = 0

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
	
	print("ModePlay: Initialized")
	print("  - Player: %s" % ("OK" if player else "MISSING"))
	print("  - Hotbar: %s" % ("OK" if hotbar else "MISSING"))
	print("  - TerrainManager: %s" % ("OK" if terrain_manager else "NOT FOUND"))
	print("  - VegetationManager: %s" % ("OK" if vegetation_manager else "NOT FOUND"))
	print("  - BuildingManager: %s" % ("OK" if building_manager else "NOT FOUND"))

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
				print("PropGrab: Starting grab")
				_try_grab_prop()
		else:
			# T released - drop prop
			if is_grabbing_prop():
				print("PropGrab: Dropping")
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
	print("ModePlay: handle_primary called with item: %s" % item.get("name", "unknown"))
	
	# If grabbing a prop, don't do other actions
	if is_grabbing_prop():
		print("ModePlay: Grabbing prop, ignoring primary action")
		return
	
	if attack_cooldown > 0:
		print("ModePlay: Still on cooldown (%.2f)" % attack_cooldown)
		return
	
	var category = item.get("category", 0)
	print("ModePlay: Category = %d" % category)
	
	match category:
		0: # NONE - Fists
			_do_punch(item)
		1: # TOOL
			_do_tool_attack(item)
		2: # BUCKET
			_do_bucket_collect(item)
		3: # RESOURCE
			pass # No primary action for resources

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

## Punch attack with fists
func _do_punch(item: Dictionary) -> void:
	if not player:
		return
	
	attack_cooldown = ATTACK_COOLDOWN_TIME
	
	# Use collide_with_areas=true to detect grass/rocks (Area3D)
	# Use exclude_water=true to pierce through water surfaces
	var hit = player.raycast(5.0, 0xFFFFFFFF, true, true)
	if hit.is_empty():
		print("ModePlay: Punch - miss")
		return
	
	var damage = item.get("damage", 1)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	print("ModePlay: Punch - hit %s" % (target.name if target else "nothing"))
	
	# Check for damageable target (direct or parent with take_damage)
	var damageable = _find_damageable(target)
	if damageable:
		damageable.take_damage(damage)
		print("ModePlay: Punched %s for %d damage" % [damageable.name, damage])
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
			print("ModePlay: Hit tree (%d/%d)" % [tree_damage[tree_rid], TREE_HP])
			PlayerSignals.durability_hit.emit(current_hp, TREE_HP, "Tree")
			if tree_damage[tree_rid] >= TREE_HP:
				vegetation_manager.chop_tree_by_collider(target)
				tree_damage.erase(tree_rid)
				PlayerSignals.durability_cleared.emit()
				print("ModePlay: Tree chopped!")
			return
		elif target.is_in_group("grass"):
			vegetation_manager.harvest_grass_by_collider(target)
			print("ModePlay: Punched grass")
			return
		elif target.is_in_group("rocks"):
			vegetation_manager.harvest_rock_by_collider(target)
			print("ModePlay: Punched rock")
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
		print("ModePlay: Hit object (%d/%d)" % [object_damage[obj_rid], OBJECT_HP])
		PlayerSignals.durability_hit.emit(current_hp, OBJECT_HP, target.name)
		if object_damage[obj_rid] >= OBJECT_HP:
			# Remove via building manager
			if target.has_meta("anchor") and target.has_meta("chunk"):
				var anchor = target.get_meta("anchor")
				var chunk = target.get_meta("chunk")
				chunk.remove_object(anchor)
				print("ModePlay: Object destroyed!")
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
			print("ModePlay: Hit block at %s (%d/%d)" % [block_pos, block_damage[block_pos], BLOCK_HP])
			PlayerSignals.durability_hit.emit(current_hp, BLOCK_HP, "Block")
			if block_damage[block_pos] >= BLOCK_HP:
				# Remove the block
				var voxel_pos = position - hit.get("normal", Vector3.ZERO) * 0.1
				building_manager.set_voxel(Vector3(floor(voxel_pos.x), floor(voxel_pos.y), floor(voxel_pos.z)), 0.0)
				block_damage.erase(block_pos)
				PlayerSignals.durability_cleared.emit()
				print("ModePlay: Block destroyed!")
			return
	
	# Default - hit terrain (modify it)
	if terrain_manager and terrain_manager.has_method("modify_terrain"):
		var strength = item.get("mining_strength", 0.5)
		if strength > 0:
			# material_id=-1 preserves existing terrain material
			terrain_manager.modify_terrain(position, strength, 1.0, 0, 0, -1)
			print("ModePlay: Punched terrain at %s (strength: %.1f)" % [position, strength])
		else:
			print("ModePlay: Item has no mining strength")
	else:
		print("ModePlay: No terrain_manager or missing modify_terrain method")

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
func _check_durability_target() -> void:
	if durability_target == null:
		return
	
	if not player:
		return
	
	# Raycast to see what we're looking at
	var hit = player.raycast(5.0, 0xFFFFFFFF, true, true)
	if hit.is_empty():
		# Looking at nothing - clear target
		durability_target = null
		PlayerSignals.durability_cleared.emit()
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
	
	# Different target or no match - clear UI
	durability_target = null
	PlayerSignals.durability_cleared.emit()

## Tool attack/mine
func _do_tool_attack(item: Dictionary) -> void:
	if not player:
		print("ModePlay: Tool attack - no player!")
		return
	
	attack_cooldown = ATTACK_COOLDOWN_TIME
	
	var hit = player.raycast(3.5) # Tool range
	if hit.is_empty():
		print("ModePlay: Tool attack - no hit")
		return
	
	var damage = item.get("damage", 1)
	var mining_strength = item.get("mining_strength", 1.0)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	print("ModePlay: Tool hit %s at %s (mining_strength: %.1f)" % [target.name if target else "nothing", position, mining_strength])
	
	# Priority 1: Damage enemies
	if target and target.is_in_group("enemies") and target.has_method("take_damage"):
		target.take_damage(damage)
		print("ModePlay: Hit enemy for %d damage" % damage)
		PlayerSignals.damage_dealt.emit(target, damage)
		return
	
	# Priority 2: Harvest vegetation
	if target and vegetation_manager:
		if target.is_in_group("trees"):
			vegetation_manager.chop_tree_by_collider(target)
			print("ModePlay: Chopped tree with %s" % item.get("name", "tool"))
			return
		elif target.is_in_group("grass"):
			vegetation_manager.harvest_grass_by_collider(target)
			print("ModePlay: Harvested grass")
			return
		elif target.is_in_group("rocks"):
			vegetation_manager.harvest_rock_by_collider(target)
			print("ModePlay: Mined rock")
			return
	
	# Priority 3: Mine terrain
	print("ModePlay: Trying to mine terrain... terrain_manager=%s" % (terrain_manager != null))
	if terrain_manager:
		print("ModePlay: terrain_manager.has_method('modify_terrain')=%s" % terrain_manager.has_method("modify_terrain"))
		if terrain_manager.has_method("modify_terrain"):
			print("ModePlay: Calling modify_terrain(%s, %.1f, 1.0, 0, 0)" % [position, mining_strength])
			terrain_manager.modify_terrain(position, mining_strength, 1.0, 0, 0)
			print("ModePlay: Mined terrain at %s (strength: %.1f)" % [position, mining_strength])
		else:
			print("ModePlay: terrain_manager missing modify_terrain method!")
	else:
		print("ModePlay: terrain_manager is NULL!")

## Collect water with bucket
func _do_bucket_collect(_item: Dictionary) -> void:
	if not player or not terrain_manager:
		return
	
	# Use EXACT same position calculation as placement
	if not has_target:
		return
	
	var center = current_target_pos + Vector3(0.5, 0.5, 0.5)
	terrain_manager.modify_terrain(center, 0.6, 0.5, 1, 1) # Same as placement but positive value
	print("ModePlay: Collected water at %s" % current_target_pos)
	# TODO: Switch bucket from empty to full

## Place water from bucket
func _do_bucket_place(_item: Dictionary) -> void:
	if not player or not terrain_manager:
		return
	
	# Use grid-aligned position if targeting is active
	if has_target:
		var center = current_target_pos + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(center, 0.6, -0.5, 1, 1) # Box shape, fill, water layer
		print("ModePlay: Placed water at %s" % current_target_pos)
	else:
		var hit = player.raycast(5.0)
		if hit.is_empty():
			return
		var pos = hit.position + hit.normal * 0.5
		terrain_manager.modify_terrain(pos, 0.6, -0.5, 1, 1)
		print("ModePlay: Placed water at %s" % pos)
	# TODO: Switch bucket from full to empty

## Place resource (terrain material)
func _do_resource_place(item: Dictionary) -> void:
	if not player or not terrain_manager:
		return
	
	# Use grid-aligned position if targeting is active
	if has_target:
		var center = current_target_pos + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(center, 0.6, -0.5, 1, 0) # Box shape, fill, terrain layer
		print("ModePlay: Placed %s at %s" % [item.get("name", "resource"), current_target_pos])
	else:
		var hit = player.raycast(5.0)
		if hit.is_empty():
			return
		var pos = hit.position + hit.normal * 0.5
		terrain_manager.modify_terrain(pos, 0.6, -0.5, 1, 0)
		print("ModePlay: Placed %s at %s" % [item.get("name", "resource"), pos])

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
		print("PropHold: WARNING - No camera found!")
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
		print("PropHold: Prop at %s (visible: %s)" % [held_prop_instance.global_position, held_prop_instance.visible])

## Find a prop that can be picked up
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
		if col.is_in_group("placed_objects") and col.has_meta("anchor"):
			print("PropPickup: Direct hit on %s" % col.name)
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
		if col.is_in_group("placed_objects") and col.has_meta("anchor"):
			var d = col.global_position.distance_to(search_origin)
			if d < best_dist:
				best_dist = d
				best_target = col
	
	if best_target:
		print("PropPickup: Assisted hit on %s" % best_target.name)
	return best_target

## Try to grab a prop
func _try_grab_prop() -> void:
	var target = _get_pickup_target()
	if not target:
		return
	
	print("PropGrab: Trying to grab %s" % target.name)
	var anchor = target.get_meta("anchor")
	var chunk = target.get_meta("chunk")
	
	if not chunk or not chunk.objects.has(anchor):
		print("PropPickup: No object data at anchor")
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
			print("PropPickup: Picked up prop ID %d at %s" % [held_prop_id, held_prop_instance.global_position])
		else:
			print("PropPickup: WARNING - No camera, prop may be mispositioned")

## Drop the grabbed prop
func _drop_grabbed_prop() -> void:
	if not held_prop_instance:
		return
	
	print("PropDrop: Dropping prop")
	
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
	
	print("PropDrop: building_manager = %s" % building_manager)
	print("PropDrop: Drop at %s, adjusted = %s" % [drop_pos, adjusted_drop_pos])
	
	# Try placement via building manager
	var success = false
	if building_manager and building_manager.has_method("place_object"):
		success = building_manager.place_object(adjusted_drop_pos, held_prop_id, held_prop_rotation)
		print("PropDrop: place_object returned %s" % success)
	else:
		print("PropDrop: No building_manager or no place_object method!")
	
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
							
							print("PropDrop: Placed at nearby anchor %s" % try_anchor)
							success = true
							break
					if success: break
				if success: break
	
	if not success:
		print("PropDrop: Placement failed, prop lost")
	else:
		print("PropDrop: Placed successfully")
	
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
		print("ItemPickup: Unknown item: %s" % target.name)
		return
	
	# Try to add to hotbar
	if hotbar.add_item(item_data):
		print("ItemPickup: Picked up %s" % item_data.get("name", "item"))
		# Remove from world
		target.queue_free()
		# Hide the interaction prompt
		PlayerSignals.interaction_unavailable.emit()
	else:
		print("ItemPickup: Hotbar full, cannot pick up %s" % item_data.get("name", "item"))

## Get item data dictionary from a pickup target
func _get_item_data_from_pickup(target: Node) -> Dictionary:
	var name_lower = target.name.to_lower()
	
	# Pistol variants
	if "pistol" in name_lower:
		return {
			"id": "pistol",
			"name": "Pistol",
			"category": 1, # TOOL
			"damage": 25,
			"mining_strength": 0.0,
			"stack_size": 1
		}
	
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
		# Small offset INTO the terrain to ensure we sample the solid voxel
		var sample_pos = hit_pos - hit_normal * 0.1
		var mat_id = _get_material_at(sample_pos)
		material_name = MATERIAL_NAMES.get(mat_id, "Unknown (%d)" % mat_id)
		
		# Debug logging (only when digging/clicking)
		if mat_debug_on_click:
			print("[MAT_DEBUG] hit_pos=%.1f,%.1f,%.1f normal=%.2f,%.2f,%.2f" % [
				hit_pos.x, hit_pos.y, hit_pos.z,
				hit_normal.x, hit_normal.y, hit_normal.z
			])
			print("[MAT_DEBUG] sample_pos=%.1f,%.1f,%.1f mat_id=%d (%s)" % [
				sample_pos.x, sample_pos.y, sample_pos.z, mat_id, material_name
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

## Get material ID at a given world position (uses chunk_manager's accurate lookup)
func _get_material_at(pos: Vector3) -> int:
	if terrain_manager and terrain_manager.has_method("get_material_at"):
		return terrain_manager.get_material_at(pos)
	return -1 # Unknown

#endregion
