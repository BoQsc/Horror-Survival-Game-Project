extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	var mesh := _build_alpha_mesh()
	var stats := manager._get_mesh_render_stats(mesh)

	if not _expect(int(stats.get("mesh_primitives", 0)) == 1, "mesh primitive count should be tracked"):
		return 1
	if not _expect(int(stats.get("alpha_mesh_primitives", 0)) == 1, "alpha primitive count should include transparent surface"):
		return 1
	if not _expect(int(stats.get("alpha_mesh_surfaces", 0)) == 1, "alpha surface count should include transparent surface"):
		return 1
	var coverage := float(stats.get("alpha_texture_coverage_ratio", 0.0))
	if not _expect(is_equal_approx(coverage, 0.5), "alpha coverage ratio should come from texture threshold"):
		return 1

	manager.grass_mesh = mesh
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.mesh = mesh
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh.instance_count = 4
	manager._global_grass_render_clusters[Vector2i.ZERO] = mmi
	var render_stats := manager._get_global_render_kind_telemetry("grass")
	if not _expect(int(render_stats.get("estimated_alpha_primitives", 0)) == 4, "alpha primitives should scale by instance count"):
		return 1
	if not _expect(is_equal_approx(float(render_stats.get("estimated_alpha_empty_primitive_equivalent", 0.0)), 2.0), "alpha empty equivalent should scale by uncovered texture ratio"):
		return 1

	mmi.free()
	manager.free()
	print("[VEGETATION_ALPHA_TELEMETRY_TEST] PASS")
	return 0

func _build_alpha_mesh() -> ArrayMesh:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color(1, 1, 1, 1))
	image.set_pixel(1, 0, Color(1, 1, 1, 1))
	image.set_pixel(0, 1, Color(1, 1, 1, 0))
	image.set_pixel(1, 1, Color(1, 1, 1, 0))
	var texture := ImageTexture.create_from_image(image)

	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.5
	material.albedo_texture = texture

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(0, 1, 0)
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 0),
		Vector2(1, 0),
		Vector2(0, 1)
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_ALPHA_TELEMETRY_TEST] FAIL: %s" % message)
	return false
