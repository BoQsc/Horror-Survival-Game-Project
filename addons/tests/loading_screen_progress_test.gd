extends SceneTree

const LoadingScreenScript = preload("res://modules/world_player_v2/features/ui_loading_screen/loading_screen.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var screen: LoadingScreen = LoadingScreenScript.new()
	screen.loading_start_msec = Time.get_ticks_msec()
	screen._loading_trace.begin("loading-screen-test")

	screen._on_load_step("Loading prefabs", 1, 10)
	var save_load_snapshot: Dictionary = screen.get_loading_progress_snapshot()
	if not _expect(float(save_load_snapshot.get("progress_percent", 0.0)) == 0.5, "save-load step should use its small weighted range"):
		return 1
	if not _expect(float(save_load_snapshot.get("stage_progress_percent", 0.0)) == 10.0, "save-load snapshot should expose stage-local progress"):
		return 1
	if not _expect(str(save_load_snapshot.get("stage_detail_text", "")).contains("step 1/10"), "save-load detail text should expose step counts"):
		return 1

	screen._set_stage(screen.Stage.TERRAIN)
	screen._update_stage_progress(screen.Stage.TERRAIN, 50.0, "terrain half")
	var terrain_snapshot: Dictionary = screen.get_loading_progress_snapshot()
	if not _expect(float(terrain_snapshot.get("progress_percent", 0.0)) == 35.0, "terrain should map to weighted progress"):
		return 1
	if not _expect(str(terrain_snapshot.get("stage_label", "")) == "Preparing terrain", "terrain snapshot should expose a stage label"):
		return 1
	if not _expect(float(terrain_snapshot.get("stage_progress_percent", 0.0)) == 50.0, "terrain snapshot should expose stage-local progress"):
		return 1
	var terrain_detail_summary := screen._build_stage_details_summary({
		"artifact_restore_queue_count": 2,
		"generation_queue_count": 3,
		"cpu_mesh_queue_count": 4,
		"artifact_disk_write_pending_entries": 1
	})
	if not _expect(terrain_detail_summary.contains("restoring artifacts 2"), "terrain detail summary should expose artifact restores"):
		return 1
	if not _expect(terrain_detail_summary.contains("generating misses 3"), "terrain detail summary should expose generation misses"):
		return 1
	if not _expect(terrain_detail_summary.contains("meshing 4"), "terrain detail summary should expose CPU mesh queue"):
		return 1
	var terrain_cache_summary := screen._build_stage_details_summary({
		"artifact_cache_hit_count": 5,
		"artifact_cache_miss_count": 2,
		"artifact_cache_restore_count": 4,
		"artifact_disk_cache_hit_count": 3
	})
	if not _expect(terrain_cache_summary.contains("cache H/M 5/2"), "terrain detail summary should expose artifact cache hit/miss counts"):
		return 1
	if not _expect(terrain_cache_summary.contains("restored 4"), "terrain detail summary should expose restored artifact count"):
		return 1
	if not _expect(terrain_cache_summary.contains("disk hits 3"), "terrain detail summary should expose disk artifact hits"):
		return 1

	screen._set_stage(screen.Stage.WORLD_CONTENT)
	screen._update_stage_progress(screen.Stage.WORLD_CONTENT, 0.0, "world content start")
	var content_snapshot: Dictionary = screen.get_loading_progress_snapshot()
	if not _expect(float(content_snapshot.get("progress_percent", 0.0)) == 70.0, "world content should start at weighted boundary"):
		return 1
	screen._sync_stage_status_from_coordinator_snapshot({
		"current_stage_label": "Preparing world content",
		"current_stage_progress_percent": 40.0,
		"current_stage_completed": 4,
		"current_stage_total": 10,
		"current_stage_details": {
			"message": "Preparing entities: 6 startup pending",
			"blocking_component": "entity_manager",
			"blocking_component_pending": 6
		}
	}, &"world_content")
	var coordinator_stage_snapshot: Dictionary = screen.get_loading_progress_snapshot()
	if not _expect(int(coordinator_stage_snapshot.get("stage_completed", 0)) == 4, "coordinator stage snapshot should expose completed count"):
		return 1
	if not _expect(str(coordinator_stage_snapshot.get("stage_detail_text", "")).contains("blocked by entity_manager (6)"), "coordinator stage detail should expose blocking subsystem"):
		return 1

	screen.update_progress(10.0, "stale lower progress")
	var monotonic_snapshot: Dictionary = screen.get_loading_progress_snapshot()
	if not _expect(float(monotonic_snapshot.get("progress_percent", 0.0)) == 70.0, "progress should not move backward"):
		return 1

	screen._set_stage(screen.Stage.VEGETATION)
	screen._update_stage_progress(screen.Stage.VEGETATION, 50.0, "vegetation half")
	var vegetation_snapshot: Dictionary = screen.get_loading_progress_snapshot()
	if not _expect(float(vegetation_snapshot.get("progress_percent", 0.0)) == 95.0, "vegetation should map to final weighted range"):
		return 1

	screen._mark_failed("test failure")
	var failed_snapshot: Dictionary = screen.get_loading_progress_snapshot()
	if not _expect(str(failed_snapshot.get("stage", "")) == "failed", "failure should be visible in snapshot"):
		return 1
	if not _expect(str(failed_snapshot.get("failure_message", "")) == "test failure", "failure message should be retained"):
		return 1

	screen._mark_cancelled("test cancellation")
	var cancelled_snapshot: Dictionary = screen.get_loading_progress_snapshot()
	if not _expect(str(cancelled_snapshot.get("stage", "")) == "cancelled", "cancellation should be visible in snapshot"):
		return 1
	if not _expect(str(cancelled_snapshot.get("cancellation_message", "")) == "test cancellation", "cancellation message should be retained"):
		return 1
	if not _expect(str(cancelled_snapshot.get("failure_message", "")) == "", "cancellation should not be reported as failure"):
		return 1

	screen.free()
	print("[LOADING_SCREEN_PROGRESS_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[LOADING_SCREEN_PROGRESS_TEST] FAIL: %s" % message)
	return false
