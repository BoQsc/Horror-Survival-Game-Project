extends SceneTree

const BuildingManagerScript = preload("res://world_building_system/building_manager.gd")


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var manager = BuildingManagerScript.new()
	var viewer := Node3D.new()
	var mesh := BoxMesh.new()
	get_root().add_child(manager)
	get_root().add_child(viewer)
	manager.viewer = viewer
	manager.render_distance = 8
	manager.world_map_global_visual_spatial_batches_enabled = true
	manager.world_map_global_visual_batch_cluster_size_chunks = 2
	manager.world_map_global_visual_spatial_batch_min_instances_per_object = 1
	manager._last_global_visual_batch_center_chunk = Vector3i.ZERO

	if not manager.register_global_visual_batch(Vector3i(1, 0, 1), 777, Transform3D(Basis.IDENTITY, Vector3(1, 0, 1)), mesh):
		return _fail("first spatial visual registration should succeed")
	if not manager.register_global_visual_batch(Vector3i(64, 0, 1), 777, Transform3D(Basis.IDENTITY, Vector3(64, 0, 1)), mesh):
		return _fail("second spatial visual registration should succeed")

	var telemetry := manager.get_telemetry_snapshot()
	if not _expect(bool(telemetry.get("world_map_global_visual_spatial_batches_enabled", false)), "spatial batching telemetry should be enabled"):
		return 1
	if not _expect(int(telemetry.get("total_global_visual_object_types", 0)) == 1, "one object type should be tracked"):
		return 1
	if not _expect(int(telemetry.get("total_global_visual_batches", 0)) == 2, "two visible clusters should create two batch nodes"):
		return 1
	if not _expect(int(telemetry.get("visible_global_visual_instances", 0)) == 2, "both clustered instances should be visible"):
		return 1

	manager.render_distance = 1
	manager._update_global_visual_batch_visibility(Vector3i(1, 0, 0))
	telemetry = manager.get_telemetry_snapshot()
	if not _expect(int(telemetry.get("total_global_visual_batches", 0)) == 1, "out-of-range cluster node should be removed"):
		return 1
	if not _expect(int(telemetry.get("total_global_visual_instances", 0)) == 2, "all registered instances should remain authoritative"):
		return 1
	if not _expect(int(telemetry.get("visible_global_visual_instances", 0)) == 1, "only the in-range cluster should stay visible"):
		return 1

	manager.clear_global_visual_batches()
	manager.world_map_global_visual_spatial_batches_enabled = false
	manager.render_distance = 8
	manager._last_global_visual_batch_center_chunk = Vector3i.ZERO
	manager.register_global_visual_batch(Vector3i(1, 0, 1), 777, Transform3D(Basis.IDENTITY, Vector3(1, 0, 1)), mesh)
	manager.register_global_visual_batch(Vector3i(64, 0, 1), 777, Transform3D(Basis.IDENTITY, Vector3(64, 0, 1)), mesh)
	telemetry = manager.get_telemetry_snapshot()
	if not _expect(int(telemetry.get("total_global_visual_batches", 0)) == 1, "legacy mode should keep one batch node per object type"):
		return 1
	if not _expect(int(telemetry.get("visible_global_visual_instances", 0)) == 2, "legacy mode should still render visible instances"):
		return 1

	manager.clear_global_visual_batches()
	manager.world_map_global_visual_spatial_batches_enabled = true
	manager.world_map_global_visual_spatial_batch_min_instances_per_object = 96
	manager._last_global_visual_batch_center_chunk = Vector3i.ZERO
	manager.register_global_visual_batch(Vector3i(1, 0, 1), 777, Transform3D(Basis.IDENTITY, Vector3(1, 0, 1)), mesh)
	manager.register_global_visual_batch(Vector3i(64, 0, 1), 777, Transform3D(Basis.IDENTITY, Vector3(64, 0, 1)), mesh)
	telemetry = manager.get_telemetry_snapshot()
	if not _expect(int(telemetry.get("total_global_visual_batches", 0)) == 1, "small object populations should use legacy batching despite spatial mode"):
		return 1
	if not _expect(int(telemetry.get("world_map_global_visual_spatial_batch_min_instances_per_object", 0)) == 96, "telemetry should expose spatial minimum threshold"):
		return 1

	manager.queue_free()
	viewer.queue_free()
	print("[BUILDING_GLOBAL_VISUAL_SPATIAL_BATCH_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[BUILDING_GLOBAL_VISUAL_SPATIAL_BATCH_TEST] FAIL: %s" % message)
	return false


func _fail(message: String) -> int:
	printerr("[BUILDING_GLOBAL_VISUAL_SPATIAL_BATCH_TEST] FAIL: %s" % message)
	return 1
