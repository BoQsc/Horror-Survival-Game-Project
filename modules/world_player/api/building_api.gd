extends Node
class_name BuildingAPI
## BuildingAPI - Block and object placement functions for BUILD mode
## Ported from legacy player_interaction.gd

# Manager references
var building_manager: Node = null
var terrain_manager: Node = null
var player: Node = null

# Block State
var current_block_id: int = 1 # 1=Cube, 2=Ramp, 3=Sphere, 4=Stairs
var current_rotation: int = 0 # 0-3 (0°, 90°, 180°, 270°)

# Object State (ported from legacy)
var current_object_id: int = 1 # From ObjectRegistry
var current_object_rotation: int = 0

# Targeting state
var current_voxel_pos: Vector3 = Vector3.ZERO
var current_remove_voxel_pos: Vector3 = Vector3.ZERO
var current_precise_hit_y: float = 0.0 # Fractional Y for objects (sits on terrain)
var has_target: bool = false

# Freestyle placement (Hold E/MMB for exact placement, legacy port)
var is_freestyle: bool = false
var smart_surface_align: bool = true # Sample terrain corners for anti-clip
var freestyle_rotation_offset: float = 0.0 # Fine rotation in freestyle mode

# Object Preview System (ported from legacy)
var preview_instance: Node3D = null
var preview_object_id: int = -1 # Track which object the preview is for
var preview_valid: bool = true # Whether current placement is valid (green/red)
var object_show_grid: bool = false # Toggle grid visibility in OBJECT mode (default off)

# Selection box and grid
var selection_box: MeshInstance3D = null
var grid_visualizer: MeshInstance3D = null

# Placement modes
enum PlacementMode {SNAP, EMBED, AUTO, FILL}
var placement_mode: PlacementMode = PlacementMode.AUTO
var placement_y_offset: int = 0
var auto_embed_threshold: float = 0.2

# FILL mode: Track terrain fills for undo on block removal
# Key = Vector3 position string, Value = {terrain_y: float, fill_amount: float}
var fill_info: Dictionary = {}

# Block names for UI
const BLOCK_NAMES = ["", "Cube", "Ramp", "Sphere", "Stairs"]

signal block_placed(position: Vector3, block_id: int, rotation: int)
signal block_removed(position: Vector3)
signal object_placed(position: Vector3, object_id: int, rotation: int)

func _ready() -> void:
	# Find managers via groups
	await get_tree().process_frame
	building_manager = get_tree().get_first_node_in_group("building_manager")
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	# Create selection box
	_create_selection_box()
	_create_grid_visualizer()
	
	print("BuildingAPI: Initialized (building_manager: %s)" % ("OK" if building_manager else "MISSING"))

## Initialize with player reference
func initialize(player_node: Node) -> void:
	player = player_node

## Create the selection box mesh
func _create_selection_box() -> void:
	selection_box = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.01, 1.01, 1.01)
	selection_box.mesh = box_mesh
	
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.2, 0.8, 0.2, 0.5) # Green for building
	selection_box.material_override = material
	selection_box.visible = false
	
	get_tree().root.add_child.call_deferred(selection_box)

## Create the grid visualizer mesh
func _create_grid_visualizer() -> void:
	grid_visualizer = MeshInstance3D.new()
	grid_visualizer.mesh = ImmediateMesh.new()
	
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	grid_visualizer.material_override = material
	grid_visualizer.visible = false
	
	get_tree().root.add_child.call_deferred(grid_visualizer)

## Set current block type (1-4)
func set_block_id(id: int) -> void:
	current_block_id = clampi(id, 1, 4)
	print("BuildingAPI: Block -> %s" % get_block_name())

## Get current block name
func get_block_name() -> String:
	if current_block_id >= 1 and current_block_id <= 4:
		return BLOCK_NAMES[current_block_id]
	return "Unknown"

## Rotate current block
func rotate_block(direction: int = 1) -> void:
	current_rotation = (current_rotation + direction + 4) % 4
	print("BuildingAPI: Rotation -> %d° (%d)" % [current_rotation * 90, current_rotation])

## Cycle placement mode
func cycle_placement_mode() -> void:
	placement_mode = ((placement_mode + 1) % 4) as PlacementMode
	var mode_names = ["SNAP", "EMBED", "AUTO", "FILL"]
	print("BuildingAPI: Placement mode -> %s" % mode_names[placement_mode])

## Adjust Y offset
func adjust_y_offset(delta: int) -> void:
	placement_y_offset += delta
	print("BuildingAPI: Y offset -> %d" % placement_y_offset)

## Update targeting from raycast hit
func update_targeting(hit: Dictionary) -> void:
	if hit.is_empty():
		selection_box.visible = false
		grid_visualizer.visible = false
		has_target = false
		return
	
	has_target = true
	
	var pos = hit.position
	var normal = hit.normal
	
	# Store fractional Y for object placement (legacy port)
	current_precise_hit_y = pos.y
	
	# Check what we hit (legacy port line 706-707)
	var hit_building = hit.collider and _is_building_chunk(hit.collider)
	var hit_placed_object = hit.collider and hit.collider.is_in_group("placed_objects")
	
	# Round normal to nearest grid axis
	var grid_normal = _round_to_axis(normal)
	
	var voxel_x: int
	var voxel_y: int
	var voxel_z: int
	
	# Freestyle mode: use exact hit position (legacy port)
	if is_freestyle:
		current_voxel_pos = pos # Exact position
		current_remove_voxel_pos = Vector3(floor(pos.x), floor(pos.y), floor(pos.z))
		
		# Apply smart surface align if enabled
		if smart_surface_align:
			current_precise_hit_y = apply_smart_surface_align(pos, current_object_id, current_object_rotation)
			current_voxel_pos.y = current_precise_hit_y
		
		# Apply Y offset (finer for freestyle: 0.1 steps)
		if placement_y_offset != 0:
			current_precise_hit_y += float(placement_y_offset) * 0.1
			current_voxel_pos.y = current_precise_hit_y
	elif hit_building or hit_placed_object:
		# Hit a building block OR placed object: place ADJACENT (legacy line 824-836)
		var inside_pos = pos - normal * 0.01
		voxel_x = int(floor(inside_pos.x))
		voxel_y = int(floor(inside_pos.y))
		voxel_z = int(floor(inside_pos.z))
		current_remove_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
		
		# Place adjacent to the hit block/object
		current_voxel_pos = current_remove_voxel_pos + grid_normal
		current_precise_hit_y = current_voxel_pos.y # Integer Y when placing on building/object
	else:
		# Hit terrain: use placement mode
		if placement_mode == PlacementMode.EMBED:
			# EMBED: place at hit position (inside terrain)
			voxel_x = int(floor(pos.x))
			voxel_y = int(floor(pos.y))
			voxel_z = int(floor(pos.z))
		elif placement_mode == PlacementMode.AUTO or placement_mode == PlacementMode.FILL:
			# AUTO/FILL: Pure raycast-based placement on surface
			# Same as SNAP mode - offset from hit point by normal
			var offset_pos = pos + normal * 0.6
			voxel_x = int(floor(offset_pos.x))
			voxel_y = int(floor(offset_pos.y)) + placement_y_offset
			voxel_z = int(floor(offset_pos.z))
		else:
			# SNAP: use normal offset from hit point
			var offset_pos = pos + normal * 0.6
			voxel_x = int(floor(offset_pos.x))
			voxel_y = int(floor(offset_pos.y)) + placement_y_offset
			voxel_z = int(floor(offset_pos.z))
		
		current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
		current_remove_voxel_pos = current_voxel_pos
		# Keep fractional Y from raycast for objects
	
	# Safety: Never allow placing inside an existing block
	if building_manager and building_manager.has_method("get_voxel"):
		if building_manager.get_voxel(current_voxel_pos) > 0:
			selection_box.visible = false
			has_target = false
			return
	
	selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
	selection_box.visible = true
	
	_update_grid_visualizer()

## Place block at current target position
func place_block() -> bool:
	if not has_target or not building_manager:
		return false
	
	# FILL mode: Fill terrain gap before placing block
	print("BuildingAPI.place_block: mode=%d (FILL=%d), tm=%s" % [placement_mode, PlacementMode.FILL, "OK" if terrain_manager else "NULL"])
	if placement_mode == PlacementMode.FILL and terrain_manager:
		var terrain_y = _get_terrain_height_at(
			current_voxel_pos.x + 0.5,
			current_voxel_pos.z + 0.5
		)
		var block_bottom = float(int(current_voxel_pos.y))
		var gap = block_bottom - terrain_y
		print("BuildingAPI.place_block FILL: terrain_y=%.2f block_bottom=%.2f gap=%.2f" % [terrain_y, block_bottom, gap])
		
		# If there's a gap (block above terrain), fill it
		if gap > 0.1:
			# Use fill_column for precise vertical fill from terrain to block
			print("BuildingAPI: terrain_manager=%s has_method=%s" % [terrain_manager.name if terrain_manager else "NULL", terrain_manager.has_method("fill_column") if terrain_manager else false])
			if terrain_manager.has_method("fill_column"):
				terrain_manager.fill_column(
					current_voxel_pos.x + 0.5, # X center
					current_voxel_pos.z + 0.5, # Z center
					terrain_y, # Y from (terrain surface)
					block_bottom, # Y to (block bottom)
					-0.8, # Fill value
					0 # Terrain layer
				)
			
			# Store fill info for undo
			var pos_key = str(current_voxel_pos)
			fill_info[pos_key] = {
				"terrain_y": terrain_y,
				"block_bottom": block_bottom,
				"fill_amount": gap
			}
			print("BuildingAPI: Column fill from %.2f to %.2f at %s" % [terrain_y, block_bottom, current_voxel_pos])
	
	if building_manager.has_method("set_voxel"):
		building_manager.set_voxel(current_voxel_pos, current_block_id, current_rotation)
		block_placed.emit(current_voxel_pos, current_block_id, current_rotation)
		print("BuildingAPI: Placed %s at %s (rot: %d)" % [get_block_name(), current_voxel_pos, current_rotation])
		return true
	
	return false

## Remove block at raycast hit (physics-based, accurate for ramps)
func remove_block(hit: Dictionary) -> bool:
	if hit.is_empty() or not building_manager:
		return false
	
	if not hit.collider or not _is_building_chunk(hit.collider):
		return false
	
	# Move slightly into the object to find the voxel
	var remove_pos = hit.position - hit.normal * 0.01
	var voxel_pos = Vector3(floor(remove_pos.x), floor(remove_pos.y), floor(remove_pos.z))
	
	if building_manager.has_method("set_voxel"):
		building_manager.set_voxel(voxel_pos, 0.0)
		block_removed.emit(voxel_pos)
		print("BuildingAPI: Removed block at %s" % voxel_pos)
		
		# FILL mode undo: Restore original terrain by digging filled area
		var pos_key = str(voxel_pos)
		if fill_info.has(pos_key) and terrain_manager:
			var info = fill_info[pos_key]
			var terrain_y = info.get("terrain_y", 0.0)
			var block_bottom = info.get("block_bottom", 0.0)
			var fill_amount = info.get("fill_amount", 0.0)
			
			if fill_amount > 0.1:
				# Use fill_column with positive value to dig out the filled area
				if terrain_manager.has_method("fill_column"):
					terrain_manager.fill_column(
						voxel_pos.x + 0.5, # X center
						voxel_pos.z + 0.5, # Z center
						terrain_y, # Y from
						block_bottom, # Y to
						0.8, # Positive = dig
						0 # Terrain layer
					)
				print("BuildingAPI: Undid column fill at %s (from %.2f to %.2f)" % [voxel_pos, terrain_y, block_bottom])
			
			fill_info.erase(pos_key)
		
		return true
	
	return false

## Check if collider belongs to the building system (walk up tree)
func _is_building_chunk(collider: Node) -> bool:
	var node = collider
	for i in range(6):
		if not node:
			break
		# Check if this node is the building_manager
		if node == building_manager or "BuildingManager" in str(node):
			return true
		# Check for BuildingChunk script
		if node.get_script() and ("BuildingChunk" in str(node.get_script()) or "building_chunk" in str(node.get_script())):
			return true
		node = node.get_parent()
	return false

## Round normal to nearest axis
func _round_to_axis(normal: Vector3) -> Vector3:
	var abs_normal = normal.abs()
	if abs_normal.x >= abs_normal.y and abs_normal.x >= abs_normal.z:
		return Vector3(sign(normal.x), 0, 0)
	elif abs_normal.y >= abs_normal.z:
		return Vector3(0, sign(normal.y), 0)
	else:
		return Vector3(0, 0, sign(normal.z))

## Get terrain height at position
func _get_terrain_height_at(x: float, z: float) -> float:
	if terrain_manager and terrain_manager.has_method("get_terrain_height"):
		return terrain_manager.get_terrain_height(x, z)
	return 0.0

## Update the 3D grid visualization
func _update_grid_visualizer() -> void:
	if not has_target:
		grid_visualizer.visible = false
		return
	
	grid_visualizer.visible = true
	var mesh = grid_visualizer.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	var center = floor(current_voxel_pos)
	var radius = 1
	var color = Color(0.3, 0.7, 0.3, 0.4) # Green tint
	
	# Draw grid lines
	for x in range(-radius, radius + 2):
		for y in range(-radius, radius + 2):
			mesh.surface_set_color(color)
			mesh.surface_add_vertex(center + Vector3(x, y, -radius))
			mesh.surface_add_vertex(center + Vector3(x, y, radius + 1))
	
	for x in range(-radius, radius + 2):
		for z in range(-radius, radius + 2):
			mesh.surface_set_color(color)
			mesh.surface_add_vertex(center + Vector3(x, -radius, z))
			mesh.surface_add_vertex(center + Vector3(x, radius + 1, z))
	
	for y in range(-radius, radius + 2):
		for z in range(-radius, radius + 2):
			mesh.surface_set_color(color)
			mesh.surface_add_vertex(center + Vector3(-radius, y, z))
			mesh.surface_add_vertex(center + Vector3(radius + 1, y, z))
	
	mesh.surface_end()

## Hide all visuals
func hide_visuals() -> void:
	if selection_box:
		selection_box.visible = false
	if grid_visualizer:
		grid_visualizer.visible = false
	has_target = false

## Place object with fractional Y (ported from legacy handle_object_input)
## Uses: current_voxel_pos (X/Z grid), current_precise_hit_y (fractional Y)
## Supports: freestyle placement, smart surface align, retry logic
func place_object(object_id: int, rotation: int) -> bool:
	if not building_manager:
		print("BuildingAPI: No building_manager")
		return false
	
	# Build position: grid X/Z, fractional Y
	var final_pos: Vector3
	
	if is_freestyle:
		# Freestyle: use exact hit position with size compensation
		var obj_size = _get_object_size(object_id, rotation)
		var offset_x = float(obj_size.x) / 2.0
		var offset_z = float(obj_size.z) / 2.0
		var compensation = Vector3(offset_x, 0, offset_z)
		final_pos = current_voxel_pos - compensation
	else:
		# Grid snap: X/Z floored, Y fractional
		final_pos = Vector3(
			floor(current_voxel_pos.x),
			current_precise_hit_y,
			floor(current_voxel_pos.z)
		)
	
	print("BuildingAPI: place_object freestyle=%s pos=%s voxel=%s preciseY=%s" % [is_freestyle, final_pos, current_voxel_pos, current_precise_hit_y])
	
	# Try placement
	if building_manager.has_method("place_object"):
		var success = building_manager.place_object(final_pos, object_id, rotation)
		if success:
			print("BuildingAPI: Placed object %d at %s" % [object_id, final_pos])
			object_placed.emit(final_pos, object_id, rotation)
			return true
		
		# Retry logic for freestyle: search for nearby empty anchor cell
		if is_freestyle:
			success = _retry_object_placement(final_pos, object_id, rotation)
			if success:
				return true
	
	print("BuildingAPI: Cannot place object - cells occupied")
	return false

## Get object size from ObjectRegistry
func _get_object_size(object_id: int, rotation: int) -> Vector3i:
	# Try ObjectRegistry if available
	if has_node("/root/ObjectRegistry"):
		var registry = get_node("/root/ObjectRegistry")
		if registry.has_method("get_rotated_size"):
			return registry.get_rotated_size(object_id, rotation)
	
	# Try static class
	if ClassDB.class_exists("ObjectRegistry"):
		return ObjectRegistry.get_rotated_size(object_id, rotation)
	
	# Fallback
	return Vector3i(1, 1, 1)

## Retry object placement by searching nearby cells (legacy freestyle retry)
func _retry_object_placement(target_pos: Vector3, object_id: int, rotation: int) -> bool:
	if not building_manager or not "CHUNK_SIZE" in building_manager:
		return false
	
	var chunk_size = building_manager.CHUNK_SIZE
	var chunk_x = int(floor(target_pos.x / chunk_size))
	var chunk_y = int(floor(target_pos.y / chunk_size))
	var chunk_z = int(floor(target_pos.z / chunk_size))
	var chunk_key = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not building_manager.chunks.has(chunk_key):
		return false
	
	var chunk = building_manager.chunks[chunk_key]
	
	# Calculate local coord
	var local_x = int(floor(target_pos.x)) % chunk_size
	var local_y = int(floor(target_pos.y)) % chunk_size
	var local_z = int(floor(target_pos.z)) % chunk_size
	if local_x < 0: local_x += chunk_size
	if local_y < 0: local_y += chunk_size
	if local_z < 0: local_z += chunk_size
	
	var base_anchor = Vector3i(local_x, local_y, local_z)
	
	# Search 2-block radius (5x5x5 volume)
	var range_r = 2
	for dx in range(-range_r, range_r + 1):
		for dy in range(-range_r, range_r + 1):
			for dz in range(-range_r, range_r + 1):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				
				var try_anchor = base_anchor + Vector3i(dx, dy, dz)
				if chunk.has_method("is_cell_available") and chunk.is_cell_available(try_anchor):
					# Found free cell - try placement there
					var anchor_world = Vector3(chunk_key) * chunk_size + Vector3(try_anchor)
					if building_manager.place_object(anchor_world, object_id, rotation):
						print("BuildingAPI: Freestyle retry succeeded at %s" % try_anchor)
						return true
	
	return false

## Get physics surface height at X,Z by raycast down (for smart surface align)
func _get_physics_height_at(x: float, z: float, start_y: float) -> float:
	if not player:
		return start_y
	
	var space_state = player.get_world_3d().direct_space_state
	var from = Vector3(x, start_y + 10.0, z)
	var to = Vector3(x, start_y - 100.0, z)
	
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player.get_rid()] if player.has_method("get_rid") else []
	
	var result = space_state.intersect_ray(query)
	if result:
		return result.position.y
	
	return start_y

## Apply smart surface align: sample corners and use highest Y
func apply_smart_surface_align(center: Vector3, object_id: int, rotation: int) -> float:
	if not smart_surface_align:
		return center.y
	
	var obj_size = _get_object_size(object_id, rotation)
	var half_x = float(obj_size.x) / 2.0
	var half_z = float(obj_size.z) / 2.0
	
	# Sample 5 points: center + 4 corners
	var points = [
		center,
		Vector3(center.x - half_x, 0, center.z - half_z),
		Vector3(center.x + half_x, 0, center.z - half_z),
		Vector3(center.x - half_x, 0, center.z + half_z),
		Vector3(center.x + half_x, 0, center.z + half_z)
	]
	
	var max_y = -999.0
	for p in points:
		var h = _get_physics_height_at(p.x, p.z, center.y)
		if h > max_y:
			max_y = h
	
	if max_y > -900:
		return max_y + 0.02 # Small margin
	return center.y

## Toggle freestyle mode
func set_freestyle(enabled: bool) -> void:
	is_freestyle = enabled
	print("BuildingAPI: Freestyle %s" % ("ON" if enabled else "OFF"))

# ============== OBJECT PREVIEW SYSTEM ==============
# Ported from legacy player_interaction.gd lines 1494-1666

## Create or update preview for the current object
## Call this in _process when in OBJECT/BUILD mode with an object selected
func update_or_create_preview() -> void:
	# Check if we need to create a new preview (object changed)
	if preview_object_id != current_object_id or preview_instance == null:
		destroy_preview()
		_create_preview()
	
	# Update preview position and rotation
	if preview_instance and has_target:
		var size = ObjectRegistry.get_rotated_size(current_object_id, current_object_rotation)
		var offset_x = float(size.x) / 2.0
		var offset_z = float(size.z) / 2.0
		
		if is_freestyle:
			# Freestyle: Preview matches exact hit position
			preview_instance.position = current_voxel_pos
			
			# Apply fine rotation
			var base_rot = current_object_rotation * 90
			preview_instance.rotation_degrees.y = base_rot + freestyle_rotation_offset
		else:
			# Snapped: Preview matches grid position + centering
			preview_instance.position = Vector3(
				current_voxel_pos.x + offset_x,
				current_precise_hit_y,
				current_voxel_pos.z + offset_z
			)
			preview_instance.rotation_degrees.y = current_object_rotation * 90
			
		preview_instance.visible = true
		
		# Check validity
		if is_freestyle:
			# Freestyle is valid (physics will handle collision)
			set_preview_validity(true)
		else:
			# Standard grid check
			var check_pos = Vector3(floor(current_voxel_pos.x), floor(current_precise_hit_y), floor(current_voxel_pos.z))
			var can_place = building_manager.can_place_object(
				check_pos,
				current_object_id,
				current_object_rotation
			) if building_manager else true
			set_preview_validity(can_place)
	elif preview_instance:
		preview_instance.visible = false

## Create a preview instance for the current object
func _create_preview() -> void:
	var obj_def = ObjectRegistry.get_object(current_object_id)
	if obj_def.is_empty():
		return
	
	var packed = load(obj_def.scene) as PackedScene
	if not packed:
		return
	
	preview_instance = packed.instantiate()
	preview_object_id = current_object_id
	
	# Add to scene (not as child of anything specific, just to world)
	get_tree().root.add_child(preview_instance)
	
	# Apply transparent preview material to all meshes
	_apply_preview_material(preview_instance)
	
	# Disable collisions on preview (it shouldn't interact with physics)
	_disable_preview_collisions(preview_instance)

## Destroy the current preview instance
func destroy_preview() -> void:
	if preview_instance and is_instance_valid(preview_instance):
		preview_instance.queue_free()
	preview_instance = null
	preview_object_id = -1

## Set preview color based on validity (green = valid, red = invalid)
func set_preview_validity(valid: bool) -> void:
	preview_valid = valid
	var color = Color(0.2, 1.0, 0.3, 0.5) if valid else Color(1.0, 0.2, 0.2, 0.5)
	_set_preview_color(preview_instance, color)

## Apply semi-transparent preview material to all MeshInstance3D children
func _apply_preview_material(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst = node as MeshInstance3D
		var mat = StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.2, 1.0, 0.3, 0.5) # Green, semi-transparent
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true # Render on top
		mesh_inst.material_override = mat
	
	for child in node.get_children():
		_apply_preview_material(child)

## Recursively set preview color on all materials
func _set_preview_color(node: Node, color: Color) -> void:
	if not node:
		return
	if node is MeshInstance3D:
		var mesh_inst = node as MeshInstance3D
		if mesh_inst.material_override is StandardMaterial3D:
			mesh_inst.material_override.albedo_color = color
	
	for child in node.get_children():
		_set_preview_color(child, color)

## Disable all collisions on the preview node
func _disable_preview_collisions(node: Node) -> void:
	if node is CollisionShape3D:
		node.disabled = true
	elif node is StaticBody3D or node is CharacterBody3D or node is RigidBody3D:
		node.collision_layer = 0
		node.collision_mask = 0
	
	for child in node.get_children():
		_disable_preview_collisions(child)

## Cleanup
func _exit_tree() -> void:
	if selection_box and is_instance_valid(selection_box):
		selection_box.queue_free()
	if grid_visualizer and is_instance_valid(grid_visualizer):
		grid_visualizer.queue_free()
	destroy_preview()
