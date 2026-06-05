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
	manager.collision_distance = 1
	manager.initial_load_phase = false
	manager.initial_load_target_chunks = 0
	manager.terrain_event_driven_process_sleep_enabled = true
	manager.terrain_event_driven_idle_sleep_frames = 1
	_populate_active_chunk_disk(manager, 2)
	manager._modification_coord_cache_dirty = false
	manager._record_terrain_stream_update_key()

	manager._maybe_sleep_terrain_process_loop()
	if not _expect(bool(manager._terrain_process_sleeping), "terrain should enter sleep before setting change"):
		return _cleanup_and_fail(manager)

	manager.set_render_distance(2)
	if not _expect(not bool(manager._terrain_process_sleeping), "render distance change should wake sleeping terrain"):
		return _cleanup_and_fail(manager)
	if not _expect(str(manager._terrain_process_last_wake_reason) == "terrain_setting_changed_render_distance", "render distance wake reason should be recorded"):
		return _cleanup_and_fail(manager)
	if not _expect(int(manager._terrain_runtime_setting_change_count) == 1, "setting change count should increment for render distance"):
		return _cleanup_and_fail(manager)
	if not _expect(int(manager._last_terrain_stream_update_render_distance) == -1, "render distance change should invalidate stream key"):
		return _cleanup_and_fail(manager)
	if not _expect(manager._terrain_stream_update_needed(), "render distance change should make stream update necessary"):
		return _cleanup_and_fail(manager)
	if not _expect(str(manager._last_terrain_stream_update_gate_reason) == "render_distance_changed", "stream gate should report render distance change"):
		return _cleanup_and_fail(manager)

	manager._record_terrain_stream_update_key()
	manager._maybe_sleep_terrain_process_loop()
	if not _expect(bool(manager._terrain_process_sleeping), "terrain should sleep again after render setting is recorded"):
		return _cleanup_and_fail(manager)

	manager.set_collision_distance(4)
	if not _expect(not bool(manager._terrain_process_sleeping), "collision distance change should wake sleeping terrain"):
		return _cleanup_and_fail(manager)
	if not _expect(str(manager._terrain_process_last_wake_reason) == "terrain_setting_changed_collision_distance", "collision distance wake reason should be recorded"):
		return _cleanup_and_fail(manager)
	if not _expect(int(manager._terrain_runtime_setting_change_count) == 2, "setting change count should increment for collision distance"):
		return _cleanup_and_fail(manager)

	manager.set_collision_distance(4)
	if not _expect(int(manager._terrain_runtime_setting_change_count) == 2, "unchanged collision distance should not emit a setting event"):
		return _cleanup_and_fail(manager)

	manager.terrain_artifact_cache_memory_budget_mb = 1
	manager.terrain_artifact_cache_entry_limit = 4
	manager._sync_terrain_artifact_cache_configuration()
	manager._refresh_terrain_artifact_settings_signature()
	var original_signature := str(manager._terrain_artifact_settings_signature)
	if not _expect(_store_test_artifact(manager, Vector3i(5, 0, 5), original_signature), "test artifact should store before signed setting change"):
		return _cleanup_and_fail(manager)
	if not _expect(int(manager._terrain_artifact_cache.get_snapshot().get("entry_count", 0)) == 1, "test artifact should be present before signed setting change"):
		return _cleanup_and_fail(manager)
	_inject_pending_disk_write(manager, Vector3i(5, 0, 5), original_signature)
	if not _expect(int(manager._terrain_artifact_disk_write_queue.get_snapshot().get("pending_entries", 0)) == 1, "test disk write should be pending before signed setting change"):
		return _cleanup_and_fail(manager)

	manager.set_terrain_height(12.5, false)
	if not _expect(str(manager._last_terrain_runtime_setting_changed) == "terrain_height", "terrain height setter should record setting telemetry"):
		return _cleanup_and_fail(manager)
	if not _expect(str(manager._terrain_process_last_wake_reason) == "terrain_setting_changed_terrain_height", "terrain height setter should wake terrain"):
		return _cleanup_and_fail(manager)
	if not _expect(str(manager._terrain_artifact_settings_signature) != original_signature, "terrain height setter should refresh artifact signature"):
		return _cleanup_and_fail(manager)
	if not _expect(int(manager._terrain_artifact_cache.get_snapshot().get("entry_count", 0)) == 0, "signed setting change should clear stale session artifacts"):
		return _cleanup_and_fail(manager)
	var disk_write_snapshot: Dictionary = manager._terrain_artifact_disk_write_queue.get_snapshot()
	if not _expect(int(disk_write_snapshot.get("pending_entries", 0)) == 0, "signed setting change should clear pending disk artifact writes"):
		return _cleanup_and_fail(manager)
	var disk_write_drop_reasons: Dictionary = disk_write_snapshot.get("drop_reasons", {})
	if not _expect(int(disk_write_drop_reasons.get("settings_changed", 0)) == 1, "signed setting change should report stale disk write drop reason"):
		return _cleanup_and_fail(manager)

	var previous_change_count := int(manager._terrain_runtime_setting_change_count)
	manager.set_terrain_height(12.5, false)
	if not _expect(int(manager._terrain_runtime_setting_change_count) == previous_change_count, "unchanged terrain height should not emit a setting event"):
		return _cleanup_and_fail(manager)

	manager.set_water_level(14.0, false)
	manager.set_noise_frequency(0.2, false)
	manager.set_procedural_roads_enabled(false, false)
	manager.set_procedural_road_wide_shoulders(true, false)
	manager.set_procedural_road_spacing(120.0, false)
	manager.set_procedural_road_width(10.0, false)
	if not _expect(int(manager._terrain_runtime_setting_change_count) == previous_change_count + 6, "signed generation setters should each emit one setting event"):
		return _cleanup_and_fail(manager)
	if not _expect(str(manager._last_terrain_runtime_setting_changed) == "procedural_road_width", "last signed setting should be tracked"):
		return _cleanup_and_fail(manager)

	var telemetry: Dictionary = manager.get_telemetry_snapshot()
	if not _expect(int(telemetry.get("terrain_runtime_setting_change_count", 0)) == previous_change_count + 6, "telemetry should expose runtime setting change count"):
		return _cleanup_and_fail(manager)
	if not _expect(str(telemetry.get("last_terrain_runtime_setting_changed", "")) == "procedural_road_width", "telemetry should expose last setting name"):
		return _cleanup_and_fail(manager)

	_cleanup(manager)
	print("[TERRAIN_RUNTIME_SETTING_WAKE_TEST] PASS")
	return 0


func _cleanup_and_fail(manager: Node) -> int:
	_cleanup(manager)
	return 1


func _cleanup(manager: Node) -> void:
	if manager:
		var viewer := manager.get("viewer") as Node
		if viewer and is_instance_valid(viewer):
			viewer.free()
		manager.free()


func _populate_active_chunk_disk(manager: Node, radius: int) -> void:
	var radius_sq := radius * radius
	for x in range(-radius, radius + 1):
		for z in range(-radius, radius + 1):
			if x * x + z * z <= radius_sq:
				manager.active_chunks[Vector3i(x, 0, z)] = ChunkManagerScript.ChunkData.new()


func _store_test_artifact(manager: Node, coord: Vector3i, signature: String) -> bool:
	return manager._terrain_artifact_cache.store(coord, {
		"settings_signature": signature,
		"stored_mod_version": 0,
		"byte_size": 64
	})


func _inject_pending_disk_write(manager: Node, coord: Vector3i, signature: String) -> void:
	var key := "test|%s|%d|%d|%d" % [signature.sha256_text(), coord.x, coord.y, coord.z]
	manager._terrain_artifact_disk_write_queue._pending_by_key[key] = {
		"coord": coord,
		"settings_signature": signature,
		"artifact": {
			"settings_signature": signature,
			"stored_mod_version": 0,
			"byte_size": 64
		},
		"byte_size": 64,
		"queued_at_usec": Time.get_ticks_usec()
	}
	manager._terrain_artifact_disk_write_queue._pending_order.append(key)
	manager._terrain_artifact_disk_write_queue._pending_bytes += 64


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_RUNTIME_SETTING_WAKE_TEST] FAIL: %s" % message)
	return false
