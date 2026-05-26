extends SceneTree

const MODEL_PATHS := {
	"tree": "res://models/tree/1/pine_tree_-_ps1_low_poly.glb",
	"grass": "res://models/grass/2/grass_lowpoly.glb",
	"rock": "res://models/small_rock/simple_rock_-_ps1_low_poly.glb"
}
const ALPHA_TRIANGLE_SAMPLE_STEPS := 12

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
			var alpha_triangles := _describe_surface_alpha_triangles(mesh, surface_index, material)
			if not alpha_triangles.is_empty():
				print("[VEGETATION_MATERIAL_INSPECT] %s surface=%d alpha_triangles=%s" % [
					kind,
					surface_index,
					alpha_triangles
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

func _describe_surface_alpha_triangles(mesh: Mesh, surface_index: int, material: Material) -> String:
	if not (material is BaseMaterial3D):
		return ""
	var base := material as BaseMaterial3D
	if base.albedo_texture == null:
		return ""
	if base.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
		return ""

	var threshold := base.alpha_scissor_threshold
	if threshold <= 0.0:
		threshold = 0.5

	var image := base.albedo_texture.get_image()
	if image == null or image.is_empty():
		return "unreadable_texture"
	if image.is_compressed():
		var decompress_error := image.decompress()
		if decompress_error != OK:
			return "compressed_texture:%s" % str(decompress_error)

	var arrays := mesh.surface_get_arrays(surface_index)
	if arrays.size() <= Mesh.ARRAY_TEX_UV or arrays.size() <= Mesh.ARRAY_VERTEX:
		return ""
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if vertices.is_empty() or uvs.is_empty():
		return ""

	var indices := PackedInt32Array()
	if arrays.size() > Mesh.ARRAY_INDEX:
		indices = arrays[Mesh.ARRAY_INDEX]

	var triangle_count := int((indices.size() if indices.size() > 0 else vertices.size()) / 3)
	if triangle_count <= 0:
		return ""

	var all_sampled_transparent := 0
	var all_vertices_transparent := 0
	var all_sampled_opaque := 0
	var mixed_or_covered := 0
	var alpha_sum := 0.0
	var alpha_sample_count := 0
	for triangle_index in range(triangle_count):
		var i0 := _surface_triangle_vertex_index(indices, triangle_index * 3, vertices.size())
		var i1 := _surface_triangle_vertex_index(indices, triangle_index * 3 + 1, vertices.size())
		var i2 := _surface_triangle_vertex_index(indices, triangle_index * 3 + 2, vertices.size())
		if i0 < 0 or i1 < 0 or i2 < 0 or i0 >= uvs.size() or i1 >= uvs.size() or i2 >= uvs.size():
			continue

		var uv0 := uvs[i0]
		var uv1 := uvs[i1]
		var uv2 := uvs[i2]
		var samples := _build_triangle_uv_samples(uv0, uv1, uv2, ALPHA_TRIANGLE_SAMPLE_STEPS)

		var vertex_below := 0
		var all_below := true
		var all_opaque := true
		for sample_index in range(samples.size()):
			var alpha := _sample_texture_alpha_conservative(image, samples[sample_index])
			alpha_sum += alpha
			alpha_sample_count += 1
			if alpha < threshold:
				if sample_index < 3:
					vertex_below += 1
				all_opaque = false
			else:
				all_below = false

		if all_below:
			all_sampled_transparent += 1
		elif all_opaque:
			all_sampled_opaque += 1
		else:
			mixed_or_covered += 1
		if vertex_below == 3:
			all_vertices_transparent += 1

	var average_alpha := alpha_sum / float(alpha_sample_count) if alpha_sample_count > 0 else 0.0
	return "total=%d sample_steps=%d sampled_transparent_candidate=%d(%.1f%%) vertex_transparent=%d(%.1f%%) sampled_opaque=%d(%.1f%%) mixed=%d(%.1f%%) avg_sample_alpha=%.3f threshold=%.3f" % [
		triangle_count,
		ALPHA_TRIANGLE_SAMPLE_STEPS,
		all_sampled_transparent,
		100.0 * float(all_sampled_transparent) / float(triangle_count),
		all_vertices_transparent,
		100.0 * float(all_vertices_transparent) / float(triangle_count),
		all_sampled_opaque,
		100.0 * float(all_sampled_opaque) / float(triangle_count),
		mixed_or_covered,
		100.0 * float(mixed_or_covered) / float(triangle_count),
		average_alpha,
		threshold
	]

func _build_triangle_uv_samples(uv0: Vector2, uv1: Vector2, uv2: Vector2, steps: int) -> Array[Vector2]:
	var samples: Array[Vector2] = []
	steps = maxi(steps, 1)
	for a in range(steps + 1):
		for b in range(steps + 1 - a):
			var weight0 := float(a) / float(steps)
			var weight1 := float(b) / float(steps)
			var weight2 := 1.0 - weight0 - weight1
			samples.append(uv0 * weight0 + uv1 * weight1 + uv2 * weight2)
	return samples

func _surface_triangle_vertex_index(indices: PackedInt32Array, packed_index: int, vertex_count: int) -> int:
	if indices.size() > 0:
		if packed_index < 0 or packed_index >= indices.size():
			return -1
		return indices[packed_index]
	if packed_index < 0 or packed_index >= vertex_count:
		return -1
	return packed_index

func _sample_texture_alpha_conservative(image: Image, uv: Vector2) -> float:
	# GLB importers and texture sources may disagree on vertical origin. Use the
	# larger of both samples so "sampled_transparent" stays conservative.
	return maxf(
		_sample_texture_alpha(image, uv, false),
		_sample_texture_alpha(image, uv, true)
	)

func _sample_texture_alpha(image: Image, uv: Vector2, flip_v: bool) -> float:
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return 1.0
	var u := fposmod(uv.x, 1.0)
	var v := fposmod(uv.y, 1.0)
	if flip_v:
		v = 1.0 - v
	var x := clampi(int(floor(u * float(width))), 0, width - 1)
	var y := clampi(int(floor(v * float(height))), 0, height - 1)
	return image.get_pixel(x, y).a

func _fail(message: String) -> int:
	printerr("[VEGETATION_MATERIAL_INSPECT] FAIL: %s" % message)
	return 1
