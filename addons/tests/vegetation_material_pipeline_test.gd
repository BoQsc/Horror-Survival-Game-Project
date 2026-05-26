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

	binary_material = null
	antialiased_material = null
	binary_mesh = null
	optimized_binary_mesh = null
	antialiased_mesh = null
	optimized_antialiased_mesh = null
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

func _make_alpha_material(texture: Texture2D) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
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

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_MATERIAL_PIPELINE_TEST] FAIL: %s" % message)
	return false
