extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var manager := ChunkManagerScript.new()
	manager._record_world_map_mask_sample_backend("road", "native", 16, 120)
	manager._record_world_map_mask_sample_backend("road", "native", 4, 30)
	manager._record_world_map_mask_sample_backend("water", "gdscript", 8, 55)

	var road_counts: Dictionary = manager._world_map_road_block_sample_backend_counts
	var water_counts: Dictionary = manager._world_map_water_block_sample_backend_counts
	if not _expect(int(road_counts.get("native_calls", 0)) == 2, "road native call count should accumulate"):
		return 1
	if not _expect(int(road_counts.get("native_samples", 0)) == 20, "road native sample count should accumulate"):
		return 1
	if not _expect(int(road_counts.get("native_us", 0)) == 150, "road native timing should accumulate"):
		return 1
	if not _expect(int(water_counts.get("gdscript_calls", 0)) == 1, "water fallback call count should accumulate"):
		return 1
	if not _expect(int(water_counts.get("gdscript_samples", 0)) == 8, "water fallback sample count should accumulate"):
		return 1
	if not _expect(int(water_counts.get("gdscript_us", 0)) == 55, "water fallback timing should accumulate"):
		return 1

	manager.free()
	print("[TERRAIN_MASK_SAMPLE_TELEMETRY_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_MASK_SAMPLE_TELEMETRY_TEST] FAIL: %s" % message)
	return false
