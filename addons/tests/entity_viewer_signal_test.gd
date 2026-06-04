extends SceneTree

const EntityManagerScript := preload("res://game/entities/entity_manager.gd")


class SignalViewer:
	extends Node3D

	signal viewer_position_changed(previous_position: Vector3, current_position: Vector3)


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := await _run()
	quit(exit_code)


func _run() -> int:
	var manager = EntityManagerScript.new()
	var viewer := SignalViewer.new()
	viewer.add_to_group("player")
	manager.procedural_spawning_enabled = false
	manager.entity_render_prewarm_frames = 0
	manager.spawn_queue_update_interval = 0.10
	manager.dormant_respawn_update_interval = 0.25
	manager.entity_viewer_position_signal_fallback_interval = 1.0
	manager.entity_viewer_position_signal_min_distance = 8.0
	root.add_child(viewer)
	root.add_child(manager)
	await process_frame

	if not _expect(manager._viewer_position_signal_connected, "viewer signal should connect from player group"):
		return 1

	manager.dormant_entities.append({
		"position": Vector3(64.0, 0.0, 0.0),
		"scene_path": "",
		"health": -1,
		"state": ""
	})
	manager._sync_entity_maintenance_driver()
	if not _expect(is_equal_approx(manager._get_entity_maintenance_timer_interval(), 1.0), "dormant-only work should use slower signal fallback"):
		return 1

	manager._last_viewer_position_signal_wake_pos = Vector3.ZERO
	manager._last_viewer_position_signal_wake_chunk = Vector2i.ZERO
	var previous_position := viewer.position
	viewer.position = Vector3(2.0, 0.0, 0.0)
	viewer.viewer_position_changed.emit(previous_position, viewer.position)
	if not _expect(manager._viewer_position_signal_count == 1, "small viewer movement should still be counted"):
		return 1
	if not _expect(manager._viewer_position_signal_wake_count == 0, "small movement should not wake entity maintenance"):
		return 1

	previous_position = viewer.position
	viewer.position = Vector3(32.0, 0.0, 0.0)
	viewer.viewer_position_changed.emit(previous_position, viewer.position)
	if not _expect(manager._viewer_position_signal_count == 2, "second viewer movement should be counted"):
		return 1
	if not _expect(manager._viewer_position_signal_wake_count == 1, "threshold movement should wake entity maintenance"):
		return 1
	if not _expect(manager._entity_maintenance_deferred_pending, "movement wake should schedule a deferred maintenance tick"):
		return 1
	if not _expect(manager._dormant_respawn_update_accumulator >= manager.dormant_respawn_update_interval, "movement wake should mark dormant respawn work due"):
		return 1

	await process_frame
	if not _expect(manager._entity_maintenance_deferred_tick_count >= 1, "deferred maintenance tick should run"):
		return 1

	var telemetry: Dictionary = manager.get_telemetry_snapshot()
	if not _expect(bool(telemetry.get("viewer_position_signal_connected", false)), "telemetry should expose signal connection"):
		return 1
	if not _expect(int(telemetry.get("viewer_position_signal_wake_count", 0)) == 1, "telemetry should expose wake count"):
		return 1

	manager.queue_free()
	viewer.queue_free()
	print("[ENTITY_VIEWER_SIGNAL_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[ENTITY_VIEWER_SIGNAL_TEST] FAIL: %s" % message)
	return false
