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

	screen._set_stage(screen.Stage.TERRAIN)
	screen._update_stage_progress(screen.Stage.TERRAIN, 50.0, "terrain half")
	var terrain_snapshot: Dictionary = screen.get_loading_progress_snapshot()
	if not _expect(float(terrain_snapshot.get("progress_percent", 0.0)) == 35.0, "terrain should map to weighted progress"):
		return 1

	screen._set_stage(screen.Stage.WORLD_CONTENT)
	screen._update_stage_progress(screen.Stage.WORLD_CONTENT, 0.0, "world content start")
	var content_snapshot: Dictionary = screen.get_loading_progress_snapshot()
	if not _expect(float(content_snapshot.get("progress_percent", 0.0)) == 70.0, "world content should start at weighted boundary"):
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
