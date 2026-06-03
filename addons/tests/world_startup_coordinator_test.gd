extends SceneTree

const CoordinatorScript = preload("res://world_performance/world_startup_coordinator.gd")


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := await _run()
	quit(exit_code)


func _run() -> int:
	var coordinator := CoordinatorScript.new()
	get_root().add_child(coordinator)
	var events: Array[String] = []
	coordinator.load_started.connect(func(_load_id: String) -> void:
		events.append("load_started")
	)
	coordinator.stage_started.connect(func(_load_id: String, stage_id: StringName, _label: String, _weight: float) -> void:
		events.append("stage_started:%s" % str(stage_id))
	)
	coordinator.playable_ready.connect(func(_load_id: String, _duration_ms: float) -> void:
		events.append("playable_ready")
	)
	coordinator.load_completed.connect(func(_load_id: String, _duration_ms: float) -> void:
		events.append("load_completed")
	)
	coordinator.load_failed.connect(func(_load_id: String, stage_id: StringName, _message: String) -> void:
		events.append("load_failed:%s" % str(stage_id))
	)
	coordinator.load_cancelled.connect(func(load_id: String, reason: String) -> void:
		events.append("load_cancelled:%s:%s" % [load_id, reason])
	)

	coordinator.begin_load("coordinator-test", {"source": "test"})
	coordinator.start_stage(&"save_load")
	coordinator.update_stage_progress(&"save_load", 1, 4, {"message": "quarter"})
	var quarter_snapshot: Dictionary = coordinator.get_snapshot()
	var quarter_progress := float(quarter_snapshot.get("overall_progress_percent", 0.0))
	coordinator.update_stage_progress(&"save_load", 0, 4, {"message": "stale"})
	if not _expect(float(coordinator.get_snapshot().get("overall_progress_percent", 0.0)) == quarter_progress, "overall progress should be monotonic"):
		return 1
	coordinator.complete_stage(&"save_load")
	coordinator.request_load_completion({"source": "test"})
	coordinator.start_world_startup_monitoring()
	await process_frame
	await process_frame

	var completed_snapshot: Dictionary = coordinator.get_snapshot()
	if not _expect(not bool(completed_snapshot.get("active", true)), "no-manager startup monitor should complete"):
		return 1
	if not _expect(bool(completed_snapshot.get("playable_ready", false)), "playable readiness should be reported"):
		return 1
	if not _expect(float(completed_snapshot.get("overall_progress_percent", 0.0)) == 100.0, "completed load should report 100 percent"):
		return 1
	if not _expect(events.has("load_started"), "load_started signal should emit"):
		return 1
	if not _expect(events.has("playable_ready"), "playable_ready signal should emit"):
		return 1
	if not _expect(events.has("load_completed"), "load_completed signal should emit"):
		return 1

	coordinator.begin_load("coordinator-superseded-old", {"source": "test"})
	coordinator.start_stage(&"terrain")
	coordinator.begin_load("coordinator-superseded-new", {"source": "test"})
	var superseded_snapshot: Dictionary = coordinator.get_snapshot()
	if not _expect(bool(superseded_snapshot.get("active", false)), "replacement load should be active"):
		return 1
	if not _expect(not bool(superseded_snapshot.get("cancelled", true)), "replacement load should start with a clean cancellation state"):
		return 1
	if not _expect(events.has("load_cancelled:coordinator-superseded-old:superseded"), "superseded load should emit cancellation"):
		return 1
	var last_cancellation: Dictionary = superseded_snapshot.get("last_cancellation", {})
	if not _expect(str(last_cancellation.get("load_id", "")) == "coordinator-superseded-old", "superseded cancellation should remain in telemetry"):
		return 1

	coordinator.cancel_load("test cancellation", {"source": "test"})
	var cancelled_snapshot: Dictionary = coordinator.get_snapshot()
	if not _expect(bool(cancelled_snapshot.get("cancelled", false)), "explicit cancellation state should be retained"):
		return 1
	if not _expect(not bool(cancelled_snapshot.get("active", true)), "cancelled load should no longer be active"):
		return 1
	if not _expect(str(cancelled_snapshot.get("cancellation_reason", "")) == "test cancellation", "cancellation reason should be retained"):
		return 1
	if not _expect(coordinator.ensure_load("late_loading_screen") == "coordinator-superseded-new", "late UI attachment should retain a cancelled load"):
		return 1

	coordinator.begin_load("coordinator-failure-test", {"source": "test"})
	coordinator.fail_load(&"terrain", "test failure")
	var failed_snapshot: Dictionary = coordinator.get_snapshot()
	if not _expect(bool(failed_snapshot.get("failed", false)), "failure state should be retained"):
		return 1
	if not _expect(str(failed_snapshot.get("failure_message", "")) == "test failure", "failure message should be retained"):
		return 1
	if not _expect(events.has("load_failed:terrain"), "load_failed signal should emit"):
		return 1
	if not _expect(coordinator.ensure_load("late_loading_screen") == "coordinator-failure-test", "late UI attachment should retain the failed load"):
		return 1
	if not _expect(bool(coordinator.get_snapshot().get("failed", false)), "ensure_load should not clear a visible failure"):
		return 1

	coordinator.queue_free()
	print("[WORLD_STARTUP_COORDINATOR_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_STARTUP_COORDINATOR_TEST] FAIL: %s" % message)
	return false
