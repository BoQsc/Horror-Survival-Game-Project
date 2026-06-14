extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")
const WorldMapData = preload("res://world_map_data/world_map_data.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var manager = _manager()
	var world_path := "user://worlds/terrain_world_artifact_path_%d" % Time.get_ticks_usec()
	var global_artifact_path := "user://terrain_world_artifact_path_global_%d" % Time.get_ticks_usec()
	manager.terrain_artifact_disk_cache_path = global_artifact_path
	manager.terrain_artifact_disk_cache_entries_per_world = 128
	manager.terrain_artifact_disk_cache_budget_mb = 1
	manager.terrain_artifact_cache_entry_limit = 128

	if not _expect(
		manager.get_effective_terrain_artifact_disk_cache_path() == global_artifact_path,
		"procedural/no-world terrain should use the global terrain artifact cache path"
	):
		return _cleanup(manager, 1)

	manager.world_definition_path = world_path
	manager.world_map_active = true
	manager._sync_terrain_artifact_disk_store_configuration()
	var world_artifact_path := WorldMapData.get_world_terrain_artifact_root(world_path)
	if not _expect(
		manager.get_effective_terrain_artifact_disk_cache_path() == world_artifact_path,
		"world-map terrain should use the world-local terrain artifact path"
	):
		return _cleanup(manager, 1)

	var readiness: Dictionary = manager.get_startup_readiness_snapshot()
	var details: Dictionary = readiness.get("details", {})
	if not _expect(
		str(details.get("artifact_effective_disk_cache_path", "")) == world_artifact_path,
		"startup readiness details should expose the effective world-local artifact path"
	):
		return _cleanup(manager, 1)

	manager._refresh_terrain_artifact_settings_signature()
	var compact_signature := str(manager._terrain_artifact_settings_signature)
	manager.terrain_artifact_store_ready_mesh_resources = not manager.terrain_artifact_store_ready_mesh_resources
	manager._refresh_terrain_artifact_settings_signature()
	var ready_resource_signature := str(manager._terrain_artifact_settings_signature)
	if not _expect(
		compact_signature == ready_resource_signature,
		"artifact signature should not change when only ready-resource storage changes"
	):
		return _cleanup(manager, 1)

	var queued: int = manager.request_terrain_artifact_bake(Vector3.ZERO, 1, &"contract")
	if not _expect(queued == 5, "default terrain artifact bake should use one-layer disk coverage"):
		return _cleanup(manager, 1)
	var task_counts: Dictionary = manager._get_task_queue_type_counts()
	if not _expect(int(task_counts.get("generate", 0)) == 5, "cold default artifact bake should queue only efficient missing chunks"):
		return _cleanup(manager, 1)
	if not _expect(int(task_counts.get("restore_artifact", 0)) == 0, "cold artifact bake should not claim disk restores"):
		return _cleanup(manager, 1)
	if not _expect(manager.initial_load_target_chunks == 5, "artifact bake should set an efficient initial-load target"):
		return _cleanup(manager, 1)

	manager.active_chunks.clear()
	manager.task_queue.clear()
	manager.priority_task_queue.clear()
	manager.clear_terrain_artifact_bake_pins()
	var efficient_queued: int = manager.request_terrain_artifact_bake(Vector3.ZERO, 2, &"efficient_contract", 0, true)
	if not _expect(efficient_queued == 13, "efficient world-map bake should use one-layer disk coverage matching startup render radius"):
		return _cleanup(manager, 1)
	if not _expect(manager.initial_load_target_chunks == 13, "efficient artifact bake should set the disk-shaped initial-load target"):
		return _cleanup(manager, 1)

	manager.terrain_artifact_use_world_local_disk_cache = false
	manager._sync_terrain_artifact_disk_store_configuration()
	if not _expect(
		manager.get_effective_terrain_artifact_disk_cache_path() == global_artifact_path,
		"world-local artifact cache should be opt-out for diagnostics"
	):
		return _cleanup(manager, 1)

	print("[TERRAIN_WORLD_ARTIFACT_PATH_TEST] PASS")
	return _cleanup(manager, 0)


func _manager():
	var manager := ChunkManagerScript.new()
	manager.mutex = Mutex.new()
	manager.semaphore = Semaphore.new()
	manager.pending_nodes_mutex = Mutex.new()
	manager.cpu_mutex = Mutex.new()
	manager.completed_generation_mutex = Mutex.new()
	manager.stored_modifications_mutex = Mutex.new()
	manager._sync_terrain_artifact_cache_configuration()
	manager._sync_terrain_artifact_disk_store_configuration()
	return manager


func _cleanup(manager: Node, exit_code: int) -> int:
	manager._terrain_artifact_disk_store.clear_all()
	manager.free()
	return exit_code


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_WORLD_ARTIFACT_PATH_TEST] FAIL: %s" % message)
	return false
