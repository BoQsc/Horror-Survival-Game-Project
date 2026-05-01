extends Node

const PREWARM_VIEWPORT_SIZE := Vector2i(128, 128)
const DEFAULT_PREWARM_FRAMES := 12

var _viewport: SubViewport = null
var _frames_remaining: int = DEFAULT_PREWARM_FRAMES

func configure(materials: Array, frames: int = DEFAULT_PREWARM_FRAMES) -> void:
	var unique_materials := _unique_materials(materials)
	if unique_materials.is_empty():
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

	for index in range(unique_materials.size()):
		var material: Material = unique_materials[index]
		var column := index % 4
		var row := index / 4
		var position := Vector3(float(column) * 1.8 - 2.7, float(row) * -1.5 + 1.5, 0.0)
		_add_mesh_instance(root, surface_mesh, material, position)
		_add_multimesh_instance(root, box_mesh, material, position + Vector3(0.0, 0.0, -1.6))

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

func _add_mesh_instance(parent: Node3D, mesh: Mesh, material: Material, position: Vector3) -> void:
	var instance := MeshInstance3D.new()
	instance.name = "PrewarmMesh"
	instance.mesh = mesh
	instance.position = position
	instance.material_override = material
	parent.add_child(instance)

func _add_multimesh_instance(parent: Node3D, mesh: Mesh, material: Material, position: Vector3) -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = 2
	multimesh.set_instance_transform(0, Transform3D(Basis(), position))
	multimesh.set_instance_transform(1, Transform3D(Basis().scaled(Vector3(0.6, 0.6, 0.6)), position + Vector3(0.8, 0.0, 0.0)))

	var instance := MultiMeshInstance3D.new()
	instance.name = "PrewarmMultiMesh"
	instance.multimesh = multimesh
	instance.material_override = material
	parent.add_child(instance)

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
