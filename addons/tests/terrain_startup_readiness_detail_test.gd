extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var manager = ChunkManagerScript.new()
	manager.mutex = Mutex.new()
	manager.semaphore = Semaphore.new()
	manager.cpu_mutex = Mutex.new()
	manager.cpu_semaphore = Semaphore.new()
	manager.pending_nodes_mutex = Mutex.new()
	manager.completed_generation_mutex = Mutex.new()
	manager.stored_modifications_mutex = Mutex.new()
	manager.initial_load_phase = false
	manager.initial_load_target_chunks = 10
	manager.chunks_loaded_initial = 10
	manager.startup_require_preheat_before_play = true
	var cache_signature := "startup-detail-cache"
	var cache_artifact := _artifact(cache_signature)
	manager._terrain_artifact_cache.configure(true, 1024, 8)
	manager._terrain_artifact_cache.store(Vector3i(20, 0, 1), cache_artifact)
	manager._terrain_artifact_cache.lookup(Vector3i(20, 0, 1), cache_signature, 0)
	manager._terrain_artifact_cache.lookup(Vector3i(21, 0, 1), cache_signature, 0)
	manager._terrain_artifact_cache.record_restore(1.5, true)
	var disk_root := "user://terrain_startup_readiness_detail_artifacts_%d" % Time.get_ticks_usec()
	manager._terrain_artifact_disk_store.configure(true, disk_root, 8, 4096)
	manager._terrain_artifact_disk_store.store(Vector3i(22, 0, 1), cache_signature, cache_artifact)
	manager._terrain_artifact_disk_store.lookup(Vector3i(22, 0, 1), cache_signature)
	manager._terrain_artifact_disk_store.lookup(Vector3i(23, 0, 1), cache_signature)

	manager.priority_task_queue.append({"type": "restore_artifact", "coord": Vector3i(1, 0, 1)})
	manager.task_queue.append({"type": "generate", "coord": Vector3i(2, 0, 1)})
	manager.cpu_task_queue.append({"coord": Vector3i(3, 0, 1), "native_cpu_meshing": true})
	manager.cpu_task_queue.append({"type": "terrain_visual_batch", "batch_key": Vector2i(1, 1)})
	manager.completed_generation_queue.append({"coord": Vector3i(4, 0, 1), "artifact_restore": true})
	manager.completed_generation_queue.append({"coord": Vector3i(5, 0, 1)})
	manager.pending_nodes.append({"type": "final_terrain", "coord": Vector3i(6, 0, 1), "artifact_restore": true})
	manager.pending_nodes.append({"type": "final_water", "coord": Vector3i(7, 0, 1), "artifact_restore": false})
	_inject_pending_disk_write(manager, Vector3i(8, 0, 1))

	var snapshot: Dictionary = manager.get_startup_readiness_snapshot()
	var details: Dictionary = snapshot.get("details", {})
	if not _expect(not bool(snapshot.get("ready", true)), "seeded startup work should not be ready"):
		return 1
	if not _expect(float(snapshot.get("progress", 1.0)) < 1.0, "progress must stay below 100% while startup work is pending"):
		return 1
	if not _expect(int(snapshot.get("completed", 1000)) < int(snapshot.get("total", 1000)), "completed count must stay below total while startup work is pending"):
		return 1
	if not _expect(bool(manager._use_startup_pending_node_finalize_budget()), "startup finalization should keep startup node budget after chunk target is reached"):
		return 1
	if not _expect(str(snapshot.get("message", "")).begins_with("Finalizing restored terrain artifacts"), "message should prefer artifact finalization when restore nodes are pending"):
		return 1
	if not _expect(int(details.get("artifact_restore_queue_count", 0)) == 1, "details should count GPU artifact restore tasks"):
		return 1
	if not _expect(int(details.get("generation_queue_count", 0)) == 1, "details should count GPU generation misses"):
		return 1
	if not _expect(int(details.get("cpu_mesh_queue_count", 0)) == 1, "details should count CPU mesh queue"):
		return 1
	if not _expect(int(details.get("native_cpu_mesh_queue_count", 0)) == 1, "details should count native CPU mesh queue"):
		return 1
	if not _expect(int(details.get("terrain_visual_batch_cpu_queue_count", 0)) == 1, "details should count visual batch CPU queue"):
		return 1
	if not _expect(int(details.get("completed_artifact_restore_count", 0)) == 1, "details should count completed artifact restores awaiting drain"):
		return 1
	if not _expect(int(details.get("completed_generated_count", 0)) == 1, "details should count completed generated misses awaiting drain"):
		return 1
	if not _expect(int(details.get("pending_artifact_restore_node_count", 0)) == 1, "details should count artifact restore finalization nodes"):
		return 1
	if not _expect(int(details.get("pending_generated_node_count", 0)) == 1, "details should count generated finalization nodes"):
		return 1
	if not _expect(int(details.get("artifact_disk_write_pending_entries", 0)) == 1, "details should count pending disk artifact writes"):
		return 1
	if not _expect(int(details.get("artifact_disk_write_pending_bytes", 0)) == 128, "details should count pending disk artifact write bytes"):
		return 1
	if not _expect(int(details.get("artifact_cache_entry_count", 0)) == 1, "details should expose session artifact cache entries"):
		return 1
	if not _expect(int(details.get("artifact_cache_hit_count", 0)) == 1, "details should expose session artifact cache hits"):
		return 1
	if not _expect(int(details.get("artifact_cache_miss_count", 0)) == 1, "details should expose session artifact cache misses"):
		return 1
	if not _expect(int(details.get("artifact_cache_store_count", 0)) == 1, "details should expose session artifact cache stores"):
		return 1
	if not _expect(int(details.get("artifact_cache_restore_count", 0)) == 1, "details should expose session artifact restores"):
		return 1
	if not _expect(int(details.get("artifact_disk_cache_hit_count", 0)) == 1, "details should expose disk artifact cache hits"):
		return 1
	if not _expect(int(details.get("artifact_disk_cache_miss_count", 0)) == 1, "details should expose disk artifact cache misses"):
		return 1
	if not _expect(int(details.get("artifact_disk_cache_store_count", 0)) == 1, "details should expose disk artifact cache stores"):
		return 1
	if not _expect(int(details.get("artifact_disk_cache_last_signature_bytes", 0)) > 0, "details should expose disk artifact cache bytes"):
		return 1

	manager._terrain_artifact_disk_store.clear_all()
	manager.free()
	print("[TERRAIN_STARTUP_READINESS_DETAIL_TEST] PASS")
	return 0


func _artifact(signature: String) -> Dictionary:
	return {
		"byte_size": 64,
		"settings_signature": signature,
		"stored_mod_version": 0,
		"result_t": {},
		"result_w": {}
	}


func _inject_pending_disk_write(manager: Node, coord: Vector3i) -> void:
	manager._terrain_artifact_disk_write_queue.configure(true, 8, 1024, 0)
	var key := "test:%s" % str(coord)
	manager._terrain_artifact_disk_write_queue._pending_by_key[key] = {
		"coord": coord,
		"settings_signature": "test",
		"artifact": {
			"byte_size": 128,
			"settings_signature": "test"
		},
		"byte_size": 128,
		"sequence": 1
	}
	manager._terrain_artifact_disk_write_queue._pending_order.append(key)
	manager._terrain_artifact_disk_write_queue._pending_bytes = 128


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_STARTUP_READINESS_DETAIL_TEST] FAIL: %s" % message)
	return false
