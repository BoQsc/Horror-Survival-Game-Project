extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	manager.vegetation_render_prewarm_frames = 0
	root.add_child(manager)

	if not _expect(not _mesh_surface_is_opaque(manager.tree_mesh), "tree alpha-cutout material must not be forced opaque"):
		manager.free()
		return 1
	if not _expect(not _mesh_surface_is_opaque(manager.grass_mesh), "grass alpha-cutout material must not be forced opaque"):
		manager.free()
		return 1
	if not _expect(_mesh_surface_is_opaque(manager.rock_mesh), "rock material should remain opaque"):
		manager.free()
		return 1

	var telemetry := manager.get_telemetry_snapshot()
	if not _expect(telemetry.has("last_global_render_upload_bytes"), "telemetry should expose last render upload bytes"):
		manager.free()
		return 1
	if not _expect(int(telemetry.get("tree_mesh_primitives", 0)) > 0, "telemetry should report cached tree mesh primitive count"):
		manager.free()
		return 1
	var counts: Dictionary = telemetry.get("vegetation_opaque_material_optimization_counts", {})
	if not _expect(int(counts.get("tree_scanned_surfaces", 0)) == 1, "tree scanned surface count mismatch"):
		manager.free()
		return 1
	if not _expect(int(counts.get("grass_scanned_surfaces", 0)) == 1, "grass scanned surface count mismatch"):
		manager.free()
		return 1
	if not _expect(int(counts.get("rock_scanned_surfaces", 0)) == 1, "rock scanned surface count mismatch"):
		manager.free()
		return 1
	if not _expect(int(counts.get("tree_optimized_surfaces", 0)) == 0, "tree alpha surface should not be optimized"):
		manager.free()
		return 1
	if not _expect(int(counts.get("grass_optimized_surfaces", 0)) == 0, "grass alpha surface should not be optimized"):
		manager.free()
		return 1
	if not _expect(int(counts.get("rock_optimized_surfaces", 0)) == 0, "rock should not need optimization"):
		manager.free()
		return 1

	manager.free()
	print("[VEGETATION_OPAQUE_MATERIAL_OPTIMIZATION_TEST] PASS")
	return 0

func _mesh_surface_is_opaque(mesh: Mesh) -> bool:
	if mesh == null or mesh.get_surface_count() <= 0:
		return false
	var material := mesh.surface_get_material(0)
	if material is not BaseMaterial3D:
		return false
	return (material as BaseMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_DISABLED

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_OPAQUE_MATERIAL_OPTIMIZATION_TEST] FAIL: %s" % message)
	return false
