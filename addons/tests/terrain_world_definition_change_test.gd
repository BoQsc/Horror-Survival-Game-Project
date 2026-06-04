extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")
const SaveManagerScript = preload("res://save_manager/save_manager_v2.gd")


class FakeChunkManager:
	extends Node

	var world_definition_path: String = "user://old_world"
	var world_map_active: bool = true
	var terrain_height: float = 10.0
	var world_map_max_height: float = 0.0
	var set_calls: int = 0
	var last_path: String = ""
	var last_reason: String = ""
	var last_reset_runtime: bool = true

	func set_world_definition_path(path: String, reason: String = "manual", reset_runtime: bool = true) -> void:
		set_calls += 1
		last_path = path
		last_reason = reason
		last_reset_runtime = reset_runtime
		world_definition_path = path
		world_map_active = not path.is_empty()


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	if not _test_terrain_world_definition_setter():
		return 1
	if not _test_save_manager_uses_world_definition_setter():
		return 1
	print("[TERRAIN_WORLD_DEFINITION_CHANGE_TEST] PASS")
	return 0


func _test_terrain_world_definition_setter() -> bool:
	var manager := ChunkManagerScript.new()
	manager.mutex = Mutex.new()
	manager.semaphore = Semaphore.new()
	manager.world_definition_path = "user://old_world"
	manager.world_map_active = true
	manager._refresh_terrain_artifact_settings_signature()

	var artifact_coord := Vector3i(1, 0, 1)
	manager._terrain_artifact_cache.configure(true, 1024 * 1024, 8)
	manager._terrain_artifact_cache.store(artifact_coord, {
		"settings_signature": manager._terrain_artifact_settings_signature,
		"stored_mod_version": 0,
		"byte_size": 16
	})
	if not _expect(int(manager._terrain_artifact_cache.get_snapshot().get("entry_count", 0)) == 1, "test artifact should be stored before world switch"):
		manager.free()
		return false

	manager.task_queue.append({"type": "generate", "coord": Vector3i.ZERO})
	manager.priority_task_queue.append({"type": "free", "rid": RID()})
	manager.set_world_definition_path("", "test_world_switch", false)

	if not _expect(manager.world_definition_path == "", "world definition path should update"):
		manager.free()
		return false
	if not _expect(not bool(manager.world_map_active), "empty world definition should disable world map mode"):
		manager.free()
		return false
	if not _expect(int(manager._terrain_artifact_cache.get_snapshot().get("entry_count", 0)) == 0, "world definition signature change should clear session artifacts"):
		manager.free()
		return false
	if not _expect(manager.task_queue.is_empty(), "stale generation tasks should be dropped on world switch"):
		manager.free()
		return false
	if not _expect(_has_reload_task(manager.priority_task_queue), "world switch should queue a GPU world-map reload task"):
		manager.free()
		return false
	if not _expect(int(manager._world_map_gpu_reload_request_count) == 1, "GPU reload request count should increment"):
		manager.free()
		return false
	if not _expect(int(manager._world_definition_change_count) == 1, "world definition change count should increment"):
		manager.free()
		return false
	if not _expect(str(manager._last_world_definition_change_reason) == "test_world_switch", "world definition change reason should be retained"):
		manager.free()
		return false
	if not _expect(str(manager._last_terrain_runtime_setting_changed) == "world_definition_path", "world definition setter should be tracked as a terrain runtime setting"):
		manager.free()
		return false

	manager.set_world_definition_path("", "unchanged", false)
	if not _expect(int(manager._world_definition_change_count) == 1, "unchanged world definition should not emit another event"):
		manager.free()
		return false

	var telemetry: Dictionary = manager.get_telemetry_snapshot()
	if not _expect(int(telemetry.get("world_definition_change_count", 0)) == 1, "telemetry should expose world definition changes"):
		manager.free()
		return false
	if not _expect(int(telemetry.get("world_map_gpu_reload_request_count", 0)) == 1, "telemetry should expose GPU reload requests"):
		manager.free()
		return false

	manager.free()
	return true


func _test_save_manager_uses_world_definition_setter() -> bool:
	var save_manager := SaveManagerScript.new()
	var fake_chunk_manager := FakeChunkManager.new()
	save_manager.chunk_manager = fake_chunk_manager
	save_manager._load_world_definition_path("user://new_world")

	if not _expect(fake_chunk_manager.set_calls == 1, "SaveManager should call the terrain world definition setter"):
		save_manager.free()
		fake_chunk_manager.free()
		return false
	if not _expect(fake_chunk_manager.last_path == "user://new_world", "SaveManager should pass the requested world path"):
		save_manager.free()
		fake_chunk_manager.free()
		return false
	if not _expect(fake_chunk_manager.last_reason == "save_load", "SaveManager should tag world definition changes as save-load work"):
		save_manager.free()
		fake_chunk_manager.free()
		return false
	if not _expect(not fake_chunk_manager.last_reset_runtime, "SaveManager should defer runtime reset to terrain data loading"):
		save_manager.free()
		fake_chunk_manager.free()
		return false

	save_manager.free()
	fake_chunk_manager.free()
	return true


func _has_reload_task(queue: Array) -> bool:
	for task_variant in queue:
		if task_variant is Dictionary and str(task_variant.get("type", "")) == "reload_world_map":
			return true
	return false


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_WORLD_DEFINITION_CHANGE_TEST] FAIL: %s" % message)
	return false
