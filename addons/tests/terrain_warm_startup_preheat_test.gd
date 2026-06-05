extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var manager = ChunkManagerScript.new()
	manager.mutex = Mutex.new()
	manager.semaphore = Semaphore.new()
	manager.pending_nodes_mutex = Mutex.new()
	manager.cpu_mutex = Mutex.new()
	manager.completed_generation_mutex = Mutex.new()
	manager.stored_modifications_mutex = Mutex.new()
	manager.startup_preheat_radius_chunks = 1
	manager.startup_require_preheat_before_play = true
	manager.terrain_artifact_cache_enabled = true
	manager.terrain_artifact_cache_memory_budget_mb = 1
	manager.terrain_artifact_cache_entry_limit = 64
	manager.terrain_artifact_disk_cache_enabled = true
	manager.terrain_artifact_disk_cache_path = "user://terrain_warm_startup_preheat_artifacts_%d" % Time.get_ticks_usec()
	manager.terrain_artifact_disk_cache_entries_per_world = 64
	manager.terrain_artifact_disk_cache_budget_mb = 1
	manager._sync_terrain_artifact_cache_configuration()
	manager._sync_terrain_artifact_disk_store_configuration()
	manager._refresh_terrain_artifact_settings_signature()

	var signature: String = manager._terrain_artifact_settings_signature
	for coord in _spawn_preheat_coords(Vector3i.ZERO, 1):
		if not _expect(
			manager._terrain_artifact_disk_store.store(coord, signature, _artifact(signature)),
			"test setup should seed disk artifact for %s" % str(coord)
		):
			return _cleanup(manager, 1)

	var pending_count: int = manager.request_startup_preheat(Vector3.ZERO)
	if not _expect(pending_count == 27, "warm startup preheat should request the configured spawn radius"):
		return _cleanup(manager, 1)

	var type_counts: Dictionary = manager._get_task_queue_type_counts()
	if not _expect(int(type_counts.get("restore_artifact", 0)) == 27, "warm startup should queue preheat chunks as artifact restores"):
		return _cleanup(manager, 1)
	if not _expect(int(type_counts.get("generate", 0)) == 0, "warm startup should not queue generation when all spawn artifacts exist"):
		return _cleanup(manager, 1)

	for task_variant in manager.priority_task_queue:
		var task: Dictionary = task_variant
		if not _expect(str(task.get("type", "")) == "restore_artifact", "preheat queue should contain only artifact restores"):
			return _cleanup(manager, 1)
		if not _expect(str(task.get("artifact_source", "")) == "disk", "warm startup preheat should restore from disk artifacts"):
			return _cleanup(manager, 1)

	var readiness: Dictionary = manager.get_startup_readiness_snapshot()
	var details: Dictionary = readiness.get("details", {})
	if not _expect(not bool(readiness.get("ready", true)), "queued preheat restore work should keep terrain startup pending"):
		return _cleanup(manager, 1)
	if not _expect(str(readiness.get("message", "")).begins_with("Restoring terrain artifacts"), "startup message should explain artifact restore work"):
		return _cleanup(manager, 1)
	if not _expect(int(details.get("artifact_restore_queue_count", 0)) == 27, "startup details should expose queued artifact restores"):
		return _cleanup(manager, 1)
	if not _expect(int(details.get("generation_queue_count", -1)) == 0, "startup details should expose zero generation misses"):
		return _cleanup(manager, 1)
	if not _expect(int(details.get("artifact_disk_cache_hit_count", 0)) == 27, "startup details should expose disk artifact hits"):
		return _cleanup(manager, 1)
	if not _expect(is_equal_approx(float(details.get("artifact_disk_cache_hit_ratio", 0.0)), 1.0), "disk artifact hit ratio should be complete for seeded warm startup"):
		return _cleanup(manager, 1)

	print("[TERRAIN_WARM_STARTUP_PREHEAT_TEST] PASS")
	return _cleanup(manager, 0)


func _spawn_preheat_coords(center: Vector3i, radius: int) -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	for dx in range(-radius, radius + 1):
		for dy in range(-1, 2):
			for dz in range(-radius, radius + 1):
				coords.append(Vector3i(center.x + dx, center.y + dy, center.z + dz))
	return coords


func _artifact(signature: String) -> Dictionary:
	return {
		"byte_size": 64,
		"settings_signature": signature,
		"stored_mod_version": 0,
		"result_t": {"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array()},
		"result_w": {"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array()}
	}


func _cleanup(manager: Node, exit_code: int) -> int:
	manager._terrain_artifact_disk_store.clear_all()
	manager.free()
	return exit_code


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_WARM_STARTUP_PREHEAT_TEST] FAIL: %s" % message)
	return false
