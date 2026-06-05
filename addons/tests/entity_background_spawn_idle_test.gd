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
	var viewer := SignalViewer.new()
	viewer.add_to_group("player")
	root.add_child(viewer)

	var manager = EntityManagerScript.new()
	manager.procedural_spawning_enabled = false
	manager.entity_render_prewarm_frames = 0
	manager.spawn_radius = 50.0
	manager.spawn_queue_update_interval = 0.1
	manager.entity_viewer_position_signal_fallback_interval = 1.0
	manager.entity_viewer_position_signal_min_distance = 8.0
	root.add_child(manager)
	await process_frame

	if not _expect(manager._viewer_position_signal_connected, "viewer signal should connect"):
		return _cleanup(manager, viewer, 1)

	manager.pending_spawns.append({
		"position": Vector3(512.0, 0.0, 0.0),
		"procedural": true
	})
	manager.deferred_spawn_chunks[Vector2i(20, 0)] = {
		"coord": Vector3i(20, 0, 0),
		"spawns": [{"position": Vector3(630.0, 0.0, 0.0), "procedural": true}]
	}
	manager.deferred_spawn_chunk_keys.append(Vector2i(20, 0))
	manager._sync_entity_maintenance_driver()

	var far_telemetry: Dictionary = manager.get_telemetry_snapshot()
	if not _expect(not bool(far_telemetry.get("spawn_queue_maintenance_work", true)), "far spawn backlog should not be actionable while stationary"):
		return _cleanup(manager, viewer, 1)
	if not _expect(bool(far_telemetry.get("spawn_queue_background_only", false)), "far spawn backlog should be reported as background-only"):
		return _cleanup(manager, viewer, 1)
	if not _expect(not bool(far_telemetry.get("entity_maintenance_timer_active", true)), "background-only spawn backlog should not keep the maintenance timer awake"):
		return _cleanup(manager, viewer, 1)
	if not _expect(not bool(far_telemetry.get("physics_process_enabled", true)), "background-only spawn backlog should not force physics processing"):
		return _cleanup(manager, viewer, 1)

	var previous_position := viewer.position
	viewer.position = Vector3(620.0, 0.0, 0.0)
	viewer.viewer_position_changed.emit(previous_position, viewer.position)
	await process_frame

	var near_telemetry: Dictionary = manager.get_telemetry_snapshot()
	if not _expect(manager._entity_maintenance_deferred_tick_count >= 1, "movement into spawn range should run deferred maintenance"):
		return _cleanup(manager, viewer, 1)
	if not _expect(bool(near_telemetry.get("spawn_queue_maintenance_work", false)), "near spawn backlog should become actionable"):
		return _cleanup(manager, viewer, 1)
	if not _expect(bool(near_telemetry.get("entity_maintenance_timer_active", false)), "near spawn backlog should keep the fallback timer active"):
		return _cleanup(manager, viewer, 1)

	print("[ENTITY_BACKGROUND_SPAWN_IDLE_TEST] PASS")
	return _cleanup(manager, viewer, 0)


func _cleanup(manager: Node, viewer: Node, exit_code: int) -> int:
	if manager and is_instance_valid(manager):
		manager.queue_free()
	if viewer and is_instance_valid(viewer):
		viewer.queue_free()
	return exit_code


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[ENTITY_BACKGROUND_SPAWN_IDLE_TEST] FAIL: %s" % message)
	return false
