extends Node
class_name TerrainAPI
## TerrainAPI - Terrain sculpting functions for EDITOR mode
## Ported from legacy player_interaction.gd

# Manager reference
var terrain_manager: Node = null
var player: Node = null

# State
var blocky_mode: bool = true # Default to blocky
var brush_size: float = 4.0 # Smooth brush size
var brush_sizes: Array = [2.0, 4.0, 8.0] # Small, Medium, Large
var brush_index: int = 1 # Default medium

# Selection box and grid
var selection_box: MeshInstance3D = null
var grid_visualizer: MeshInstance3D = null
var current_voxel_pos: Vector3 = Vector3.ZERO
var has_target: bool = false

# Layer constants
const LAYER_TERRAIN: int = 0
const LAYER_WATER: int = 1

signal terrain_modified(position: Vector3, layer: int)

func _ready() -> void:
	# Find terrain manager via group
	await get_tree().process_frame
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	# Create selection box
	_create_selection_box()
	_create_grid_visualizer()
	
	print("TerrainAPI: Initialized (terrain_manager: %s)" % ("OK" if terrain_manager else "MISSING"))

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
	material.albedo_color = Color(0, 0.5, 1, 0.5)
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

## Toggle blocky mode
func toggle_blocky_mode() -> void:
	blocky_mode = not blocky_mode
	print("TerrainAPI: Blocky mode = %s" % blocky_mode)

## Cycle brush size
func cycle_brush_size() -> void:
	brush_index = (brush_index + 1) % brush_sizes.size()
	brush_size = brush_sizes[brush_index]
	print("TerrainAPI: Brush size = %.1f" % brush_size)

## Get current mode string for UI
func get_mode_string() -> String:
	if blocky_mode:
		return "Blocky"
	else:
		return "Smooth (%.0f)" % brush_size

## Update selection box position from raycast
func update_targeting(hit: Dictionary) -> void:
	if hit.is_empty():
		selection_box.visible = false
		grid_visualizer.visible = false
		has_target = false
		return
	
	has_target = true
	
	if blocky_mode:
		# Calculate voxel position (inside terrain)
		var pos = hit.position - hit.normal * 0.1
		current_voxel_pos = Vector3(floor(pos.x), floor(pos.y), floor(pos.z))
		
		selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
		selection_box.visible = true
		
		_update_grid_visualizer()
	else:
		# Smooth mode - just track hit position
		current_voxel_pos = hit.position
		selection_box.visible = false
		grid_visualizer.visible = false

## Update the 3D grid visualization
func _update_grid_visualizer() -> void:
	if not has_target or not blocky_mode:
		grid_visualizer.visible = false
		return
	
	grid_visualizer.visible = true
	var mesh = grid_visualizer.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	var center = floor(current_voxel_pos)
	var radius = 1
	var color = Color(0.5, 0.5, 0.5, 0.3)
	
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

## Dig terrain (left click)
func dig(hit: Dictionary, layer: int = LAYER_TERRAIN) -> bool:
	if not terrain_manager or hit.is_empty():
		return false
	
	if blocky_mode:
		# Blocky: dig single voxel
		var pos = hit.position - hit.normal * 0.1
		var target_pos = Vector3(floor(pos.x), floor(pos.y), floor(pos.z)) + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(target_pos, 0.6, 0.5, 1, layer) # Shape 1 = Box, 0.5 = dig
		terrain_modified.emit(target_pos, layer)
		print("TerrainAPI: Dig (blocky) at %s" % target_pos)
	else:
		# Smooth: dig sphere
		terrain_manager.modify_terrain(hit.position, brush_size, 1.0, 0, layer) # Shape 0 = Sphere
		terrain_modified.emit(hit.position, layer)
		print("TerrainAPI: Dig (smooth) at %s, radius %.1f" % [hit.position, brush_size])
	
	return true

## Raise terrain (right click)
func raise(hit: Dictionary, layer: int = LAYER_TERRAIN) -> bool:
	if not terrain_manager or hit.is_empty():
		return false
	
	if blocky_mode:
		# Blocky: place single voxel (adjacent to surface)
		var pos = hit.position + hit.normal * 0.1
		var target_pos = Vector3(floor(pos.x), floor(pos.y), floor(pos.z)) + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(target_pos, 0.6, -0.5, 1, layer) # -0.5 = fill
		terrain_modified.emit(target_pos, layer)
		print("TerrainAPI: Raise (blocky) at %s" % target_pos)
	else:
		# Smooth: raise sphere
		terrain_manager.modify_terrain(hit.position, brush_size, -1.0, 0, layer)
		terrain_modified.emit(hit.position, layer)
		print("TerrainAPI: Raise (smooth) at %s, radius %.1f" % [hit.position, brush_size])
	
	return true

## Hide all visuals (when leaving terrain mode)
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
