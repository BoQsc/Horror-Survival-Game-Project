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

	var telemetry := manager.get_telemetry_snapshot()
	var counts: Dictionary = telemetry.get("vegetation_mesh_lod_counts", {})
	var material_counts: Dictionary = telemetry.get("vegetation_opaque_material_optimization_counts", {})
	if not _expect(not counts.is_empty(), "mesh LOD telemetry should be populated"):
		manager.free()
		return 1

	for kind in ["tree", "grass", "rock"]:
		if not _expect(bool(counts.get("%s_source_imported_mesh_lod_candidate" % kind, false)), "%s should be treated as an imported mesh LOD candidate" % kind):
			manager.free()
			return 1
		var source_levels := int(counts.get("%s_source_lod_levels" % kind, 0))
		var generated_levels := int(counts.get("%s_generated_lod_levels" % kind, 0))
		var prepared_levels := int(counts.get("%s_prepared_lod_levels" % kind, -1))
		if not _expect(prepared_levels >= 0, "%s prepared LOD telemetry is missing" % kind):
			manager.free()
			return 1
		if source_levels > 0 and not _expect(prepared_levels == source_levels, "%s imported LOD levels were not preserved" % kind):
			manager.free()
			return 1
		if kind == "tree":
			if not _expect(generated_levels > 0, "tree should generate Godot mesh LOD levels"):
				manager.free()
				return 1
			if not _expect(prepared_levels == generated_levels, "tree prepared mesh should preserve generated Godot LOD levels"):
				manager.free()
				return 1
		else:
			if not _expect(bool(counts.get("%s_generate_skipped_below_min_primitives" % kind, false)), "%s should skip LOD generation because the mesh is already tiny" % kind):
				manager.free()
				return 1
		if not _expect(int(material_counts.get("%s_alpha_split_lod_preserved_surfaces" % kind, 0)) > 0, "%s imported mesh should bypass alpha split rebuilding" % kind):
			manager.free()
			return 1

	print("[VEGETATION_MESH_LOD_PRESERVATION_TEST] counts=%s" % JSON.stringify(counts))
	manager.free()
	print("[VEGETATION_MESH_LOD_PRESERVATION_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_MESH_LOD_PRESERVATION_TEST] FAIL: %s" % message)
	return false
