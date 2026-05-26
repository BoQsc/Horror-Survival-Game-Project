extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	root.add_child(manager)

	manager._record_vegetation_generation_backend("grass", "native", "height_map", 42, 2500)
	manager._record_vegetation_generation_backend("grass", "native", "height_map", 24, 4000)

	var telemetry := manager.get_telemetry_snapshot()
	var counts: Dictionary = telemetry.get("vegetation_generation_backend_counts", {})
	var time_counts: Dictionary = telemetry.get("vegetation_generation_time_backend_counts", {})

	if not _expect(int(counts.get("grass_native_chunks", 0)) == 2, "generation telemetry should count chunks"):
		return 1
	if not _expect(int(counts.get("grass_native_instances", 0)) == 66, "generation telemetry should count instances"):
		return 1
	if not _expect(int(time_counts.get("grass_native_timed_calls", 0)) == 2, "generation timing should count calls"):
		return 1
	if not _expect(int(time_counts.get("grass_native_us", 0)) == 6500, "generation timing should accumulate microseconds"):
		return 1
	if not _expect(int(time_counts.get("grass_native_max_us", 0)) == 4000, "generation timing should track max microseconds"):
		return 1
	if not _expect(is_equal_approx(float(telemetry.get("last_vegetation_generation_ms", 0.0)), 4.0), "last generation ms should be exposed"):
		return 1
	if not _expect(int(telemetry.get("last_vegetation_generation_instance_count", 0)) == 24, "last generation instance count should be exposed"):
		return 1
	if not _expect(is_equal_approx(float(telemetry.get("max_vegetation_generation_ms", 0.0)), 4.0), "max generation ms should be exposed"):
		return 1

	root.remove_child(manager)
	manager.free()
	print("[VEGETATION_GENERATION_TIMING_TELEMETRY_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_GENERATION_TIMING_TELEMETRY_TEST] FAIL: %s" % message)
	return false
