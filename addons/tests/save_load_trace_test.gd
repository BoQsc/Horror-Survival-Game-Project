extends SceneTree


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var manager := get_root().get_node_or_null("SaveManager")
	if not _expect(manager != null, "SaveManager autoload should be available"):
		return 1
	manager._begin_load_trace("user://test-save.json")
	manager._emit_load_step("Loading terrain", 6, 10)
	manager._complete_load_trace(true, {"path": "user://test-save.json"})

	var telemetry: Dictionary = manager.get_telemetry_snapshot()
	var trace: Dictionary = telemetry.get("load_trace", {})
	var event_counts: Dictionary = trace.get("event_counts", {})
	if not _expect(bool(telemetry.get("load_trace_last_success", false)), "successful load should be reported"):
		return 1
	if not _expect(int(event_counts.get("load_step_started", 0)) == 1, "load step start should be traced"):
		return 1
	if not _expect(int(event_counts.get("load_step_completed", 0)) == 1, "load step completion should be traced"):
		return 1
	if not _expect(str(trace.get("last_event", "")) == "load_completed", "load completion should be the final event"):
		return 1

	print("[SAVE_LOAD_TRACE_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[SAVE_LOAD_TRACE_TEST] FAIL: %s" % message)
	return false
