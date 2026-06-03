extends SceneTree

const VegetationManagerScript := preload("res://world_vegetation/vegetation_manager.gd")


class FakeTerrainManager:
	extends Node3D

	const CHUNK_STRIDE := 31


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
	var manager: VegetationManager = VegetationManagerScript.new()
	var terrain := FakeTerrainManager.new()
	var viewer := SignalViewer.new()
	var fake_vehicle_manager := Node.new()
	root.add_child(terrain)
	root.add_child(viewer)
	manager.terrain_manager = terrain
	manager.player = viewer
	manager._cached_vehicle_manager = fake_vehicle_manager
	manager._last_collider_update_chunk = Vector2i.ZERO
	manager._last_collider_update_pos = Vector3.ZERO
	manager._connect_viewer_position_signal()

	if not _expect(manager._viewer_position_signal_connected, "viewer signal should connect"):
		return 1
	if not _expect(is_equal_approx(manager._get_collider_update_timer_interval(), manager.vegetation_viewer_position_signal_fallback_interval), "connected signal should use the slower fallback interval"):
		return 1

	var previous_position := viewer.position
	viewer.position = Vector3(32.0, 0.0, 0.0)
	viewer.viewer_position_changed.emit(previous_position, viewer.position)
	if not _expect(manager._collider_refresh_dirty, "chunk-changing viewer movement should mark collider refresh dirty"):
		return 1
	if not _expect(manager._viewer_position_signal_count == 1, "viewer signals should be counted"):
		return 1
	if not _expect(manager._viewer_position_signal_refresh_count == 1, "refresh-triggering signals should be counted"):
		return 1

	manager._collider_refresh_dirty = false
	manager._last_collider_update_chunk = Vector2i(1, 0)
	manager._last_collider_update_pos = viewer.position
	previous_position = viewer.position
	viewer.position = Vector3(33.0, 0.0, 0.0)
	viewer.viewer_position_changed.emit(previous_position, viewer.position)
	if not _expect(not manager._collider_refresh_dirty, "small movement inside the same chunk should not trigger refresh"):
		return 1
	if not _expect(manager._viewer_position_signal_count == 2, "all viewer signals should be counted"):
		return 1
	if not _expect(manager._viewer_position_signal_refresh_count == 1, "non-refreshing signals should not increment refresh count"):
		return 1

	var telemetry := manager.get_telemetry_snapshot()
	if not _expect(bool(telemetry.get("viewer_position_signal_connected", false)), "telemetry should expose signal connection"):
		return 1
	if not _expect(int(telemetry.get("viewer_position_signal_count", 0)) == 2, "telemetry should expose signal count"):
		return 1

	manager._disconnect_viewer_position_signal()
	manager.free()
	root.remove_child(terrain)
	root.remove_child(viewer)
	terrain.free()
	viewer.free()
	fake_vehicle_manager.free()
	print("[VEGETATION_VIEWER_SIGNAL_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_VIEWER_SIGNAL_TEST] FAIL: %s" % message)
	return false
