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
	if not _expect(int(manager.runtime_power_active_max_fps) == 60, "runtime power active default should be 60 FPS"):
		return 1
	if not _expect(int(manager.runtime_power_idle_max_fps) == 30, "runtime power idle default should be 30 FPS"):
		return 1
	if not _expect(int(manager.runtime_power_deep_idle_max_fps) == 15, "runtime power deep-idle default should be 15 FPS"):
		return 1
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

	manager.pending_nodes.append({"type": "final_terrain", "coord": Vector3i.ZERO})
	if not _expect(manager._runtime_power_terrain_busy(), "pending terrain nodes should count as terrain work"):
		return 1
	if not _expect(manager._runtime_power_foreground_terrain_busy(true), "pending terrain nodes should keep runtime power foreground-active"):
		return 1
	manager.pending_nodes.clear()
	manager.pending_terrain_collision_creates[Vector3i.ZERO] = true
	if not _expect(manager._runtime_power_foreground_terrain_busy(true), "pending terrain collision should keep runtime power foreground-active"):
		return 1
	manager.pending_terrain_collision_creates.clear()
	manager._terrain_visual_batch_dirty[Vector3i.ZERO] = true
	if not _expect(manager._runtime_power_terrain_busy(), "dirty visual batches should still count as terrain work"):
		return 1
	if not _expect(not manager._runtime_power_foreground_terrain_busy(true), "dirty visual batches alone should remain background work"):
		return 1
	manager._terrain_visual_batch_dirty.clear()

	var original_engine_max_fps := Engine.max_fps
	manager.runtime_power_allow_unattended_render_suspend = false
	manager.runtime_power_low_fps_requires_render_suspend = true
	manager._apply_runtime_power_fps("deep_idle", manager.runtime_power_deep_idle_max_fps)
	if not _expect(int(manager._runtime_power_requested_target_fps) == int(manager.runtime_power_deep_idle_max_fps), "runtime power should retain requested deep-idle cap for telemetry"):
		return 1
	if not _expect(int(manager._runtime_power_target_fps) == int(manager.runtime_power_active_max_fps), "visible gameplay should keep active FPS when render-loop suspension is blocked"):
		return 1
	if not _expect(int(Engine.max_fps) == int(manager.runtime_power_active_max_fps), "Engine max FPS should not drop to visible deep-idle FPS while render loop is active"):
		return 1
	if not _expect(str(manager._runtime_power_render_loop_suspend_gate) == "blocked_requires_menu_or_unattended_env", "blocked render-loop suspension should be recorded"):
		return 1

	manager.runtime_power_low_fps_requires_render_suspend = false
	manager._apply_runtime_power_fps("deep_idle", manager.runtime_power_deep_idle_max_fps)
	if not _expect(int(manager._runtime_power_target_fps) == int(manager.runtime_power_deep_idle_max_fps), "explicit low-FPS opt-in should still apply deep-idle cap"):
		return 1
	Engine.max_fps = original_engine_max_fps

	manager.viewer.free()
	manager.free()
	print("[TERRAIN_PROCESS_SLEEP_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_PROCESS_SLEEP_TEST] FAIL: %s" % message)
	return false
