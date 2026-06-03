extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")


class SignalViewer:
	extends Node3D
	signal viewer_position_changed(previous_position: Vector3, current_position: Vector3)


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var manager := ChunkManagerScript.new()
	manager.mutex = Mutex.new()
	manager.cpu_mutex = Mutex.new()
	manager.completed_generation_mutex = Mutex.new()
	manager.viewer = SignalViewer.new()
	manager.render_distance = 0
	manager.initial_load_phase = false
	manager.initial_load_target_chunks = 0
	manager.terrain_event_driven_process_sleep_enabled = true
	manager.terrain_event_driven_idle_sleep_frames = 2
	manager.active_chunks[Vector3i.ZERO] = {}
	manager._modification_coord_cache_dirty = false
	manager._connect_terrain_viewer_activity_source()
	manager._record_terrain_stream_update_key()
	if not _expect(bool(manager._terrain_viewer_position_signal_connected), "viewer activity signal should connect"):
		return 1

	manager._maybe_sleep_terrain_process_loop()
	if not _expect(not bool(manager._terrain_process_sleeping), "first idle frame should not sleep yet"):
		return 1
	manager._maybe_sleep_terrain_process_loop()
	if not _expect(bool(manager._terrain_process_sleeping), "second idle frame should sleep"):
		return 1
	if not _expect(int(manager._terrain_process_sleep_count) == 1, "sleep count should increment"):
		return 1

	manager._wake_terrain_process_loop("test_work")
	if not _expect(not bool(manager._terrain_process_sleeping), "explicit wake should resume"):
		return 1
	if not _expect(int(manager._terrain_process_resume_count) == 1, "resume count should increment"):
		return 1

	manager._maybe_sleep_terrain_process_loop()
	manager._maybe_sleep_terrain_process_loop()
	if not _expect(bool(manager._terrain_process_sleeping), "manager should sleep again after idle"):
		return 1
	var previous_position := manager.viewer.position
	manager.viewer.position = Vector3(float(manager.CHUNK_STRIDE) * 2.0, 0.0, 0.0)
	manager.viewer.viewer_position_changed.emit(previous_position, manager.viewer.position)
	if not _expect(not bool(manager._terrain_process_sleeping), "viewer chunk signal should wake terrain immediately"):
		return 1
	if not _expect(str(manager._terrain_process_last_wake_reason) == "viewer_chunk_changed_signal", "signal wake reason should be recorded"):
		return 1
	if not _expect(int(manager._terrain_viewer_chunk_change_signal_count) == 1, "viewer chunk signal should be counted"):
		return 1

	manager._record_terrain_stream_update_key()
	manager._maybe_sleep_terrain_process_loop()
	manager._maybe_sleep_terrain_process_loop()
	if not _expect(bool(manager._terrain_process_sleeping), "manager should sleep after signal-driven stream key is recorded"):
		return 1
	manager.viewer.position = Vector3(float(manager.CHUNK_STRIDE) * 4.0, 0.0, 0.0)
	manager._on_terrain_process_idle_poll_timeout()
	if not _expect(not bool(manager._terrain_process_sleeping), "idle poll should wake on viewer chunk movement"):
		return 1
	if not _expect(str(manager._terrain_process_last_wake_reason).begins_with("idle_poll_viewer_chunk_changed"), "wake reason should include viewer movement"):
		return 1

	manager.viewer.free()
	manager.free()
	print("[TERRAIN_PROCESS_SLEEP_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_PROCESS_SLEEP_TEST] FAIL: %s" % message)
	return false
