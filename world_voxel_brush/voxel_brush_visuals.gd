extends Node
## VoxelBrushVisuals - Centralized visualization for terrain brushes

var selection_box: MeshInstance3D = null
var grid_visualizer: MeshInstance3D = null

func _ready() -> void:
	_create_selection_box()
	_create_grid_visualizer()

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
	
	add_child(selection_box)

func _create_grid_visualizer() -> void:
	grid_visualizer = MeshInstance3D.new()
	grid_visualizer.mesh = ImmediateMesh.new()
	
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	grid_visualizer.material_override = material
	grid_visualizer.visible = false
	
	add_child(grid_visualizer)

func update_visuals(pos: Vector3, is_blocky: bool, color: Color = Color(0, 0.5, 1, 0.5)) -> void:
	if is_blocky:
		var snapped_pos = Vector3(floor(pos.x), floor(pos.y), floor(pos.z))
		selection_box.global_position = snapped_pos + Vector3(0.5, 0.5, 0.5)
		selection_box.visible = true
		if selection_box.material_override:
			selection_box.material_override.albedo_color = color
		_update_grid_visualizer(snapped_pos)
	else:
		selection_box.visible = false
		grid_visualizer.visible = false

func hide_visuals() -> void:
	selection_box.visible = false
	grid_visualizer.visible = false

func _update_grid_visualizer(center: Vector3) -> void:
	grid_visualizer.visible = true
	grid_visualizer.global_position = Vector3.ZERO # Reset to world origin for absolute positioning
	var mesh = grid_visualizer.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
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
