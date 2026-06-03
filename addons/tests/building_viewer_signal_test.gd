extends SceneTree

const BuildingManagerScript = preload("res://world_building_system/building_manager.gd")


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
	var manager = BuildingManagerScript.new()
	var viewer := SignalViewer.new()
	var fake_vehicle_manager := Node.new()
	get_root().add_child(viewer)
	manager.viewer = viewer
	manager._cached_vehicle_manager = fake_vehicle_manager
	manager._last_building_viewer_chunk = Vector3i.ZERO
	manager._connect_viewer_position_signal()
	if not _expect(manager._viewer_position_signal_connected, "viewer signal should connect"):
		return 1

	var previous_position := viewer.position
	viewer.position = Vector3(17.0, 0.0, 0.0)
	viewer.viewer_position_changed.emit(previous_position, viewer.position)
	if not _expect(manager._last_building_viewer_chunk == Vector3i(1, 0, 0), "viewer signal should update building chunk immediately"):
		return 1
	if not _expect(manager._viewer_position_signal_chunk_change_count == 1, "chunk-changing signals should be counted"):
		return 1

	viewer.position = Vector3(33.0, 0.0, 0.0)
	manager._on_viewer_chunk_update_timer_timeout()
	if not _expect(manager._last_building_viewer_chunk == Vector3i(2, 0, 0), "fallback poll should retain custom-viewer correctness"):
		return 1
	if not _expect(manager._viewer_chunk_fallback_poll_count == 1, "fallback polls should be counted"):
		return 1

	var telemetry: Dictionary = manager.get_telemetry_snapshot()
	if not _expect(bool(telemetry.get("viewer_position_signal_connected", false)), "telemetry should expose signal connection"):
		return 1
	if not _expect(int(telemetry.get("viewer_position_signal_count", 0)) == 1, "telemetry should expose signal count"):
		return 1

	manager.free()
	viewer.free()
	fake_vehicle_manager.free()
	print("[BUILDING_VIEWER_SIGNAL_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[BUILDING_VIEWER_SIGNAL_TEST] FAIL: %s" % message)
	return false
