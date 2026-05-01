extends Node

const PREWARM_VIEWPORT_SIZE := Vector2i(128, 128)
const DEFAULT_PREWARM_FRAMES := 12
const PREWARM_GRID_COLUMNS := 6
const PREWARM_GRID_SPACING := 1.8

var _viewport: SubViewport = null
var _frames_remaining: int = DEFAULT_PREWARM_FRAMES

func configure(materials: Array, frames: int = DEFAULT_PREWARM_FRAMES, mesh_entries: Array = []) -> void:
	var unique_materials := _unique_materials(materials)
	var unique_mesh_entries := _unique_mesh_entries(mesh_entries)
	if unique_materials.is_empty() and unique_mesh_entries.is_empty():
		queue_free()
		return

	_frames_remaining = maxi(frames, 1)
	process_mode = Node.PROCESS_MODE_ALWAYS

	_viewport = SubViewport.new()
	_viewport.name = "ResourcePrewarmViewport"
	_viewport.size = PREWARM_VIEWPORT_SIZE
	_viewport.disable_3d = false
	_viewport.world_3d = World3D.new()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	var root := Node3D.new()
	root.name = "ResourcePrewarmScene"
	_viewport.add_child(root)

	var camera := Camera3D.new()
	camera.name = "ResourcePrewarmCamera"
	camera.look_at_from_position(Vector3(0.0, 1.5, 8.0), Vector3(0.0, 0.0, 0.0), Vector3.UP)
	camera.current = true
	root.add_child(camera)

	var light := DirectionalLight3D.new()
	light.name = "ResourcePrewarmLight"
	light.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	root.add_child(light)

	var surface_mesh := _create_representative_surface_mesh()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(1.0, 1.0, 1.0)

	var slot_index := 0
	for index in range(unique_materials.size()):
		var material: Material = unique_materials[index]
		var position := _slot_position(slot_index)
		_add_mesh_instance(root, surface_mesh, material, Transform3D(Basis(), position), "PrewarmMaterialMesh")
		_add_multimesh_instance(root, box_mesh, material, Transform3D(Basis(), position + Vector3(0.0, 0.0, -1.6)), "PrewarmMaterialMultiMesh")
		slot_index += 1

	for mesh_entry_variant in unique_mesh_entries:
		var mesh_entry: Dictionary = mesh_entry_variant
		var mesh: Mesh = mesh_entry.get("mesh", null)
		if not mesh:
			continue

		var source_transform: Transform3D = mesh_entry.get("transform", Transform3D.IDENTITY)
		var position := _slot_position(slot_index)
		var mesh_transform := _mesh_slot_transform(mesh, position, source_transform)
		var multimesh_transform := _mesh_slot_transform(mesh, position + Vector3(0.0, 0.0, -1.6), source_transform)
		_add_mesh_instance(root, mesh, null, mesh_transform, "PrewarmResourceMesh")
		_add_multimesh_instance(root, mesh, null, multimesh_transform, "PrewarmResourceMultiMesh")
		slot_index += 1

func _process(_delta: float) -> void:
	_frames_remaining -= 1
	if _frames_remaining > 0:
		return

	if _viewport and is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	queue_free()

func get_frames_remaining() -> int:
	return maxi(_frames_remaining, 0)

func _unique_materials(materials: Array) -> Array:
	var unique: Array = []
	for material_variant in materials:
		if not material_variant is Material:
			continue
		var material: Material = material_variant
		if material and not unique.has(material):
			unique.append(material)
	return unique

func _unique_mesh_entries(mesh_entries: Array) -> Array:
	var unique: Array = []
	var unique_meshes: Array = []
	for entry_variant in mesh_entries:
		var mesh: Mesh = null
		var transform := Transform3D.IDENTITY

		if entry_variant is Mesh:
			mesh = entry_variant as Mesh
		elif entry_variant is Dictionary:
			var mesh_entry: Dictionary = entry_variant
			mesh = mesh_entry.get("mesh", null)
			var transform_variant = mesh_entry.get("transform", Transform3D.IDENTITY)
			if typeof(transform_variant) == TYPE_TRANSFORM3D:
				transform = transform_variant

		if mesh and not unique_meshes.has(mesh):
			unique_meshes.append(mesh)
			unique.append({
				"mesh": mesh,
				"transform": transform
			})
	return unique

func _slot_position(slot_index: int) -> Vector3:
	var column := slot_index % PREWARM_GRID_COLUMNS
	var row := slot_index / PREWARM_GRID_COLUMNS
	var horizontal_origin := -float(PREWARM_GRID_COLUMNS - 1) * PREWARM_GRID_SPACING * 0.5
	return Vector3(
		horizontal_origin + float(column) * PREWARM_GRID_SPACING,
		1.5 - float(row) * 1.5,
		0.0
	)

func _add_mesh_instance(parent: Node3D, mesh: Mesh, material: Material, transform: Transform3D, node_name: String) -> void:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.transform = transform
	if material:
		instance.material_override = material
	parent.add_child(instance)

func _add_multimesh_instance(parent: Node3D, mesh: Mesh, material: Material, transform: Transform3D, node_name: String) -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = 2
	multimesh.set_instance_transform(0, transform)

	var second_transform := transform
	second_transform.origin += Vector3(0.8, 0.0, 0.0)
	second_transform.basis = second_transform.basis.scaled(Vector3(0.6, 0.6, 0.6))
	multimesh.set_instance_transform(1, second_transform)

	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	if material:
		instance.material_override = material
	parent.add_child(instance)

func _mesh_slot_transform(mesh: Mesh, position: Vector3, source_transform: Transform3D) -> Transform3D:
	var bounds := _mesh_transformed_aabb(mesh, source_transform)
	var max_size := maxf(maxf(bounds.size.x, bounds.size.y), bounds.size.z)
	if max_size <= 0.001:
		return Transform3D(Basis(), position) * source_transform

	var fit_scale := clampf(1.2 / max_size, 0.05, 4.0)
	var bounds_center := bounds.position + bounds.size * 0.5
	var fit_transform := Transform3D(
		Basis().scaled(Vector3(fit_scale, fit_scale, fit_scale)),
		-bounds_center * fit_scale
	)
	return Transform3D(Basis(), position) * fit_transform * source_transform

func _mesh_transformed_aabb(mesh: Mesh, transform: Transform3D) -> AABB:
	var source_aabb := mesh.get_aabb()
	var min_corner := source_aabb.position
	var max_corner := source_aabb.position + source_aabb.size
	var corners := PackedVector3Array([
		Vector3(min_corner.x, min_corner.y, min_corner.z),
		Vector3(max_corner.x, min_corner.y, min_corner.z),
		Vector3(min_corner.x, max_corner.y, min_corner.z),
		Vector3(max_corner.x, max_corner.y, min_corner.z),
		Vector3(min_corner.x, min_corner.y, max_corner.z),
		Vector3(max_corner.x, min_corner.y, max_corner.z),
		Vector3(min_corner.x, max_corner.y, max_corner.z),
		Vector3(max_corner.x, max_corner.y, max_corner.z)
	])

	var bounds := AABB(transform * corners[0], Vector3.ZERO)
	for i in range(1, corners.size()):
		bounds = bounds.expand(transform * corners[i])
	return bounds

func _create_representative_surface_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array([
		Vector3(-0.8, -0.8, 0.0),
		Vector3(0.8, -0.8, 0.0),
		Vector3(0.8, 0.8, 0.0),
		Vector3(-0.8, 0.8, 0.0)
	])
	var normals := PackedVector3Array([
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0)
	])
	var uvs := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(1.0, 0.0),
		Vector2(1.0, 1.0),
		Vector2(0.0, 1.0)
	])
	var colors := PackedColorArray([
		Color(1.0 / 255.0, 2.0 / 255.0, 0.35, 1.0),
		Color(1.0 / 255.0, 2.0 / 255.0, 0.35, 1.0),
		Color(1.0 / 255.0, 2.0 / 255.0, 0.35, 1.0),
		Color(1.0 / 255.0, 2.0 / 255.0, 0.35, 1.0)
	])
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
