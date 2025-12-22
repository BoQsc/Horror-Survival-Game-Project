extends Node
class_name BuildingAPI
## BuildingAPI - Block placement functions for BUILD mode
## Ported from legacy player_interaction.gd

# Manager references
var building_manager: Node = null
var terrain_manager: Node = null
var player: Node = null

# State
var current_block_id: int = 1 # 1=Cube, 2=Ramp, 3=Sphere, 4=Stairs
var current_rotation: int = 0 # 0-3 (0°, 90°, 180°, 270°)

# Targeting state
var current_voxel_pos: Vector3 = Vector3.ZERO
var current_remove_voxel_pos: Vector3 = Vector3.ZERO
var has_target: bool = false

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
	
	# Check what we hit
	var hit_building = hit.collider and _is_building_chunk(hit.collider)
	
	# Round normal to nearest grid axis
	var grid_normal = _round_to_axis(normal)
	
	var voxel_x: int
	var voxel_y: int
	var voxel_z: int
	
	if hit_building:
		# Hit a building block: place ADJACENT
		var inside_pos = pos - normal * 0.01
		voxel_x = int(floor(inside_pos.x))
		voxel_y = int(floor(inside_pos.y))
		voxel_z = int(floor(inside_pos.z))
		current_remove_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
		
		# Place adjacent to the hit block
		current_voxel_pos = current_remove_voxel_pos + grid_normal
	else:
		# Hit terrain: use placement mode
		if placement_mode == PlacementMode.EMBED:
			# EMBED: place at hit position (inside terrain)
			voxel_x = int(floor(pos.x))
			voxel_y = int(floor(pos.y))
			voxel_z = int(floor(pos.z))
		elif placement_mode == PlacementMode.AUTO:
			# AUTO: Original raycast-based placement on surface
			var offset_pos = pos + normal * 0.6
			voxel_x = int(floor(offset_pos.x))
			voxel_y = int(floor(offset_pos.y)) + placement_y_offset
			voxel_z = int(floor(offset_pos.z))
			
			# Check if floating too much, snap down to terrain
			var terrain_y = _get_terrain_height_at(float(voxel_x) + 0.5, float(voxel_z) + 0.5)
			var float_distance = float(voxel_y) - terrain_y
			if float_distance > auto_embed_threshold:
				voxel_y = int(floor(terrain_y))
		elif placement_mode == PlacementMode.FILL:
			# FILL: Snap to terrain surface, future: fill gap with terrain
			voxel_x = int(floor(pos.x))
			voxel_z = int(floor(pos.z))
			var terrain_y = _get_terrain_height_at(float(voxel_x) + 0.5, float(voxel_z) + 0.5)
			# Start with floor - block may be partially submerged
			voxel_y = int(floor(terrain_y)) + placement_y_offset
			# If more than 40% would be submerged, snap UP
			var submergence = terrain_y - float(voxel_y)
			if submergence > 0.4:
				voxel_y = int(ceil(terrain_y)) + placement_y_offset
		else:
			# SNAP: use normal offset from hit point
			var offset_pos = pos + normal * 0.6
			voxel_x = int(floor(offset_pos.x))
			voxel_y = int(floor(offset_pos.y)) + placement_y_offset
			voxel_z = int(floor(offset_pos.z))
		
		current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
		current_remove_voxel_pos = current_voxel_pos
	
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
	if placement_mode == PlacementMode.FILL and terrain_manager:
		var terrain_y = _get_terrain_height_at(
			current_voxel_pos.x + 0.5,
			current_voxel_pos.z + 0.5
		)
		var block_bottom = float(int(current_voxel_pos.y))
		var gap = block_bottom - terrain_y
		
		# If there's a gap (block above terrain), fill it
		if gap > 0.1:
			# Fill terrain up to block bottom
			var fill_center = Vector3(
				current_voxel_pos.x + 0.5,
				terrain_y + gap * 0.5, # Center of gap
				current_voxel_pos.z + 0.5
			)
			# Use box shape for precise fill - minimum 0.6 radius for visible 1x1 column
			var fill_radius = max(0.6, gap * 0.6)
			terrain_manager.modify_terrain(fill_center, fill_radius, -1.5, 1, 0)
			
			# Store fill info for undo
			var pos_key = str(current_voxel_pos)
			fill_info[pos_key] = {
				"terrain_y": terrain_y,
				"fill_amount": gap,
				"fill_center": fill_center
			}
			print("BuildingAPI: Filled terrain gap of %.2f at %s" % [gap, current_voxel_pos])
	
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
			var fill_center = info.get("fill_center", Vector3.ZERO)
			var fill_amount = info.get("fill_amount", 0.0)
			
			if fill_center != Vector3.ZERO and fill_amount > 0.1:
				# Dig out the filled terrain
				terrain_manager.modify_terrain(fill_center, fill_amount * 0.6, 0.8, 1, 0)
				print("BuildingAPI: Undid terrain fill at %s (gap was %.2f)" % [voxel_pos, fill_amount])
			
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

## Cleanup
func _exit_tree() -> void:
	if selection_box and is_instance_valid(selection_box):
		selection_box.queue_free()
	if grid_visualizer and is_instance_valid(grid_visualizer):
		grid_visualizer.queue_free()
