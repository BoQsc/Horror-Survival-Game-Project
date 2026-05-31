extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var exit_code := _run()
	await process_frame
	quit(exit_code)

func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	manager.vegetation_opaque_material_optimization_enabled = true

	var binary_mesh := _make_mesh(_make_alpha_material(_make_alpha_texture([0.0, 1.0, 1.0, 0.0])))
	var optimized_binary_mesh := manager._optimize_opaque_vegetation_mesh_materials("grass", binary_mesh)
	var binary_material := optimized_binary_mesh.surface_get_material(0) as BaseMaterial3D
	if not _expect(binary_material != null, "binary material should remain a BaseMaterial3D"):
		manager.free()
		return 1
	if not _expect(binary_material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, "binary alpha blend foliage should convert to alpha scissor"):
		manager.free()
		return 1

	var binary_stats := manager._get_mesh_render_stats(optimized_binary_mesh)
	var binary_pipeline: Dictionary = binary_stats.get("material_pipeline_counts", {})
	if not _expect(int(binary_pipeline.get("alpha_scissor_surfaces", 0)) == 1, "pipeline telemetry should count alpha scissor surfaces"):
		manager.free()
		return 1
	if not _expect(int(binary_pipeline.get("alpha_blend_surfaces", 0)) == 0, "converted binary foliage should not remain alpha blend"):
		manager.free()
		return 1

	var antialiased_mesh := _make_mesh(_make_alpha_material(_make_alpha_texture([0.0, 0.35, 1.0, 0.75])))
	var optimized_antialiased_mesh := manager._optimize_opaque_vegetation_mesh_materials("tree", antialiased_mesh)
	var antialiased_material := optimized_antialiased_mesh.surface_get_material(0) as BaseMaterial3D
	if not _expect(antialiased_material != null, "antialiased material should remain a BaseMaterial3D"):
		manager.free()
		return 1
	if not _expect(antialiased_material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA, "non-binary alpha should stay alpha blend to avoid visual edge changes"):
		manager.free()
		return 1

	var antialiased_stats := manager._get_mesh_render_stats(optimized_antialiased_mesh)
	var antialiased_pipeline: Dictionary = antialiased_stats.get("material_pipeline_counts", {})
	if not _expect(int(antialiased_pipeline.get("alpha_blend_surfaces", 0)) == 1, "pipeline telemetry should count preserved alpha blend surfaces"):
		manager.free()
		return 1

	manager.vegetation_split_alpha_scissor_opaque_surfaces_enabled = true
	manager.vegetation_cull_alpha_scissor_transparent_triangles_enabled = true
	manager.vegetation_alpha_split_min_opaque_fraction = 1.0
	var cull_only_mesh := manager._split_alpha_scissor_opaque_surfaces("test_cull", _make_three_triangle_alpha_scissor_mesh(), false)
	if not _expect(cull_only_mesh.get_surface_count() == 1, "transparent cull without opaque split should keep one visible surface"):
		manager.free()
		return 1
	if not _expect(manager._get_mesh_surface_primitive_count(cull_only_mesh, 0) == 2, "transparent cull should remove only the fully transparent triangle"):
		manager.free()
		return 1
	var cull_only_material := cull_only_mesh.surface_get_material(0) as BaseMaterial3D
	if not _expect(cull_only_material != null and cull_only_material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, "cull-only mesh should keep the alpha-scissor material"):
		manager.free()
		return 1

	manager.vegetation_alpha_split_min_opaque_fraction = 0.0
	var split_mesh := manager._split_alpha_scissor_opaque_surfaces("test_split", _make_three_triangle_alpha_scissor_mesh(), false)
	if not _expect(split_mesh.get_surface_count() == 2, "eligible mesh should split opaque and alpha surfaces after transparent cull"):
		manager.free()
		return 1
	if not _expect(_count_primitives_by_transparency(split_mesh, BaseMaterial3D.TRANSPARENCY_DISABLED) == 1, "split mesh should have one opaque primitive"):
		manager.free()
		return 1
	if not _expect(_count_primitives_by_transparency(split_mesh, BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR) == 1, "split mesh should have one alpha-scissor primitive"):
		manager.free()
		return 1
	var counts: Dictionary = manager._vegetation_opaque_material_optimization_counts
	if not _expect(int(counts.get("test_cull_alpha_split_culled_transparent_triangles", 0)) == 1, "cull-only telemetry should count one removed transparent triangle"):
		manager.free()
		return 1
	if not _expect(int(counts.get("test_split_alpha_split_culled_transparent_triangles", 0)) == 1, "split telemetry should count one removed transparent triangle"):
		manager.free()
		return 1
	var offset_uv_split := manager._split_alpha_scissor_surface_arrays(
		_make_alpha_scissor_material(_make_column_alpha_texture()),
		_make_single_triangle_arrays([
			Vector2(1.05, 0.10),
			Vector2(1.20, 0.10),
			Vector2(1.05, 0.35),
		])
	)
	if not _expect(int(offset_uv_split.get("transparent_triangles", 0)) == 1, "transparent cull should handle GLB UVs offset outside 0..1"):
		manager.free()
		return 1

	binary_material = null
	antialiased_material = null
	cull_only_material = null
	binary_mesh = null
	optimized_binary_mesh = null
	antialiased_mesh = null
	optimized_antialiased_mesh = null
	cull_only_mesh = null
	split_mesh = null
	manager.free()
	print("[VEGETATION_MATERIAL_PIPELINE_TEST] PASS")
	return 0

func _make_alpha_texture(alpha_values: Array[float]) -> Texture2D:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var index := 0
	for y in range(2):
		for x in range(2):
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha_values[index]))
			index += 1
	return ImageTexture.create_from_image(image)

func _make_column_alpha_texture() -> Texture2D:
	var image := Image.create(8, 4, false, Image.FORMAT_RGBA8)
	for y in range(4):
		for x in range(8):
			var alpha := 0.0 if x < 4 else 1.0
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	return ImageTexture.create_from_image(image)

func _make_alpha_material(texture: Texture2D) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.alpha_scissor_threshold = 0.5
	material.albedo_texture = texture
	return material

func _make_alpha_scissor_material(texture: Texture2D) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.5
	material.albedo_texture = texture
	return material

func _make_mesh(material: Material) -> Mesh:
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface_tool.set_material(material)
	surface_tool.add_vertex(Vector3.ZERO)
	surface_tool.add_vertex(Vector3.RIGHT)
	surface_tool.add_vertex(Vector3.UP)
	return surface_tool.commit()

func _make_three_triangle_alpha_scissor_mesh() -> Mesh:
	var material := _make_alpha_scissor_material(_make_column_alpha_texture())
	var vertices := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, 1.0, 0.0),
		Vector3(2.0, 0.0, 0.0),
		Vector3(3.0, 0.0, 0.0),
		Vector3(2.0, 1.0, 0.0),
		Vector3(4.0, 0.0, 0.0),
		Vector3(5.0, 0.0, 0.0),
		Vector3(4.0, 1.0, 0.0),
	])
	var uvs := PackedVector2Array([
		Vector2(0.05, 0.10),
		Vector2(0.20, 0.10),
		Vector2(0.05, 0.35),
		Vector2(0.75, 0.10),
		Vector2(0.95, 0.10),
		Vector2(0.75, 0.35),
		Vector2(0.30, 0.65),
		Vector2(0.70, 0.65),
		Vector2(0.30, 0.90),
	])
	var indices := PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7, 8])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh

func _make_single_triangle_arrays(uvs: Array[Vector2]) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3.ZERO,
		Vector3.RIGHT,
		Vector3.UP,
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(uvs)
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	return arrays

func _count_primitives_by_transparency(mesh: Mesh, transparency: int) -> int:
	var count := 0
	for surface_index in range(mesh.get_surface_count()):
		var material := mesh.surface_get_material(surface_index) as BaseMaterial3D
		if material == null or material.transparency != transparency:
			continue
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			count += int(indices.size() / 3)
		else:
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			count += int(vertices.size() / 3)
	return count

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_MATERIAL_PIPELINE_TEST] FAIL: %s" % message)
	return false
