extends SceneTree

const MODEL_PATHS := {
	"tree": "res://models/tree/1/pine_tree_-_ps1_low_poly.glb",
	"grass": "res://models/grass/2/grass_lowpoly.glb",
	"rock": "res://models/small_rock/simple_rock_-_ps1_low_poly.glb"
}

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	for kind in MODEL_PATHS.keys():
		var path: String = MODEL_PATHS[kind]
		var packed_scene: PackedScene = load(path)
		if packed_scene == null:
			return _fail("could not load %s from %s" % [kind, path])
		var root := packed_scene.instantiate()
		var mesh_instance := _find_mesh_instance(root)
		if mesh_instance == null or mesh_instance.mesh == null:
			if root:
				root.free()
			return _fail("could not find mesh for %s" % kind)

		var mesh: Mesh = mesh_instance.mesh
		print("[VEGETATION_MATERIAL_INSPECT] %s path=%s mesh=%s surfaces=%d aabb=%s" % [
			kind,
			path,
			mesh.resource_path,
			mesh.get_surface_count(),
			str(mesh.get_aabb())
		])
		for surface_index in range(mesh.get_surface_count()):
			var material := mesh.surface_get_material(surface_index)
			var arrays := mesh.surface_get_arrays(surface_index)
			var vertex_count := 0
			var index_count := 0
			if arrays.size() > Mesh.ARRAY_VERTEX:
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				vertex_count = vertices.size()
			if arrays.size() > Mesh.ARRAY_INDEX:
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				index_count = indices.size()
			print("[VEGETATION_MATERIAL_INSPECT] %s surface=%d vertices=%d indices=%d primitives=%d material=%s" % [
				kind,
				surface_index,
				vertex_count,
				index_count,
				(index_count if index_count > 0 else vertex_count) / 3,
				_describe_material(material)
			])
		root.free()

	print("[VEGETATION_MATERIAL_INSPECT] PASS")
	return 0

func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var result := _find_mesh_instance(child)
		if result != null:
			return result
	return null

func _describe_material(material: Material) -> String:
	if material == null:
		return "<none>"
	var parts := [
		"class=%s" % material.get_class(),
		"path=%s" % material.resource_path
	]
	if material is BaseMaterial3D:
		var base := material as BaseMaterial3D
		parts.append("transparency=%d" % base.transparency)
		parts.append("alpha_scissor=%.3f" % base.alpha_scissor_threshold)
		parts.append("depth_draw=%d" % base.depth_draw_mode)
		parts.append("cull=%d" % base.cull_mode)
		parts.append("shading=%d" % base.shading_mode)
		parts.append("albedo=%s" % str(base.albedo_color))
		parts.append("albedo_tex=%s" % (base.albedo_texture.resource_path if base.albedo_texture else ""))
		if base.albedo_texture:
			parts.append("albedo_alpha=%s" % _describe_texture_alpha(base.albedo_texture, base.alpha_scissor_threshold))
		parts.append("normal_tex=%s" % (base.normal_texture.resource_path if base.normal_texture else ""))
		parts.append("roughness_tex=%s" % (base.roughness_texture.resource_path if base.roughness_texture else ""))
	return " ".join(parts)

func _describe_texture_alpha(texture: Texture2D, threshold: float) -> String:
	var image := texture.get_image()
	if image == null or image.is_empty():
		return "<unreadable>"
	if image.is_compressed():
		var decompress_error := image.decompress()
		if decompress_error != OK:
			return "<compressed:%s>" % str(decompress_error)
	var width := image.get_width()
	var height := image.get_height()
	var pixel_count := width * height
	if pixel_count <= 0:
		return "<empty>"
	var alpha_min := 1.0
	var alpha_max := 0.0
	var below_threshold := 0
	var partial := 0
	for y in range(height):
		for x in range(width):
			var alpha := image.get_pixel(x, y).a
			alpha_min = minf(alpha_min, alpha)
			alpha_max = maxf(alpha_max, alpha)
			if alpha < threshold:
				below_threshold += 1
			if alpha > 0.0 and alpha < 1.0:
				partial += 1
	return "size=%dx%d min=%.3f max=%.3f below_scissor=%.1f%% partial=%.1f%%" % [
		width,
		height,
		alpha_min,
		alpha_max,
		100.0 * float(below_threshold) / float(pixel_count),
		100.0 * float(partial) / float(pixel_count)
	]

func _fail(message: String) -> int:
	printerr("[VEGETATION_MATERIAL_INSPECT] FAIL: %s" % message)
	return 1
