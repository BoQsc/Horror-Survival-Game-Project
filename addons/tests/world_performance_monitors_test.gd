extends SceneTree

const MonitorScript = preload("res://world_performance/world_performance_monitors.gd")


class SnapshotNode:
	extends Node

	var snapshot: Dictionary = {}

	func _init(group_name: StringName, telemetry: Dictionary) -> void:
		snapshot = telemetry
		if not String(group_name).is_empty():
			add_to_group(group_name)

	func get_telemetry_snapshot() -> Dictionary:
		return snapshot.duplicate(true)

	func get_snapshot() -> Dictionary:
		return snapshot.duplicate(true)


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var autoload_monitor := get_root().get_node_or_null("WorldPerformanceMonitors")
	if not _expect(autoload_monitor != null, "WorldPerformanceMonitors autoload should be present"):
		return 1
	if not _expect(Performance.has_custom_monitor(&"WorldStartup/OverallProgress"), "autoload should register custom monitors"):
		return 1

	var fake_nodes: Array[Node] = []
	_prepare_startup_coordinator(fake_nodes)
	_add_fake_manager(fake_nodes, &"terrain_manager", {
		"terrain_artifact_cache": {
			"entry_count": 4,
			"total_bytes": 2048,
			"byte_budget_used_ratio": 0.5,
			"hit_ratio": 0.75,
			"eviction_count": 2
		},
		"terrain_artifact_disk_cache": {
			"hit_count": 3,
			"last_signature_bytes": 4096,
			"last_signature_byte_budget_used_ratio": 0.25,
			"eviction_count": 1
		},
		"terrain_artifact_disk_write_queue": {
			"pending_bytes": 512,
			"pending_entries": 2,
			"completed_bytes": 1024,
			"rate_limit_total_wait_ms": 6.5
		},
		"last_gpu_generation_mod_sync_ms": 1.25,
		"last_gpu_generation_sync_ms": 2.0,
		"last_gpu_meshing_sync_ms": 3.0,
		"last_gpu_mesh_slice_max_sync_ms": 0.5,
		"last_gpu_mesh_readback_ms": 4.5,
		"pending_node_count": 5,
		"terrain_process_loop_awake": true,
		"task_queue_count": 7,
		"cpu_task_queue_count": 11,
		"completed_generation_queue_count": 13,
		"pending_batch_count": 17,
		"pending_spawn_zone_count": 19,
		"world_map_lod_pending_candidate_count": 23
	})
	_add_fake_manager(fake_nodes, &"building_manager", {
		"process_loop_awake": true,
		"pending_world_map_baked_building_apply_phases": 3,
		"pending_object_collision_jobs": 4,
		"pending_world_map_baked_object_spawns": 5,
		"pending_visual_batch_rebuilds": 6,
		"dirty_visible_chunk_count": 7,
		"object_render_prewarm_active": true
	})
	_add_fake_manager(fake_nodes, &"prefab_spawner", {
		"process_loop_awake": true,
		"pending_spawn_jobs": 8,
		"pending_world_map_baked_payload_build_jobs": 9,
		"pending_world_map_baked_payload_jobs": 10
	})
	_add_fake_manager(fake_nodes, &"vegetation_manager", {
		"process_loop_awake": true,
		"pending_chunks_count": 12,
		"pending_collider_adds": 13,
		"pending_collider_removes": 14,
		"global_render_dirty_cluster_count": 15,
		"vegetation_render_prewarm_active": true
	})
	_add_fake_manager(fake_nodes, &"entity_manager", {
		"physics_process_enabled": true,
		"entity_maintenance_timer_active": false,
		"pending_spawns": 16,
		"deferred_spawn_chunks": 17,
		"deferred_spawn_plans": 18
	})

	var monitor := MonitorScript.new()
	monitor.custom_monitors_enabled = false
	get_root().add_child(monitor)
	monitor._refresh_cached_values()

	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldStartup/OverallProgress"), 42.5), "startup progress should be cached"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldStartup/Active"), 1.0), "startup active flag should be cached"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldStartup/PlayableReady"), 1.0), "startup playable flag should be cached"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainArtifactCache/Entries"), 4.0), "terrain memory cache entries should come from nested telemetry"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainArtifactCache/Bytes"), 2048.0), "terrain memory cache bytes should come from nested telemetry"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainArtifactCache/ByteBudgetRatio"), 0.5), "terrain memory cache budget ratio should come from nested telemetry"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainArtifactCache/HitRatio"), 0.75), "terrain cache hit ratio should come from nested telemetry"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainArtifactCache/Evictions"), 2.0), "terrain memory cache evictions should come from nested telemetry"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainArtifactDiskCache/Bytes"), 4096.0), "terrain disk cache bytes should come from nested telemetry"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainArtifactDiskCache/ByteBudgetRatio"), 0.25), "terrain disk cache budget ratio should come from nested telemetry"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainArtifactCache/DiskHits"), 3.0), "terrain disk cache hits should come from nested telemetry"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainArtifactDiskCache/Evictions"), 1.0), "terrain disk cache evictions should come from nested telemetry"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainArtifactDiskWriteQueue/PendingBytes"), 512.0), "disk writer pending bytes should be cached"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainGeneration/GpuSyncMs"), 6.75), "GPU sync monitor should aggregate last sync stages"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"TerrainGeneration/ReadbackMs"), 4.5), "GPU readback monitor should be cached"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/BuildingProcessAwake"), 1.0), "building awake state should be cached"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/PrefabProcessAwake"), 1.0), "prefab awake state should be cached"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/VegetationProcessAwake"), 1.0), "vegetation awake state should be cached"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/EntityMaintenanceAwake"), 1.0), "entity maintenance awake state should be cached"):
		return _cleanup_and_fail(monitor, fake_nodes)
	var pending_work_value := monitor.get_cached_monitor_value(&"WorldRuntime/PendingWork")
	if not _expect(is_equal_approx(pending_work_value, 261.0), "pending work should aggregate manager queues and awake flags, got %.2f" % pending_work_value):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/AwakeProcessCount"), 5.0), "awake process count should aggregate awake runtime managers"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/Idle"), 0.0), "busy runtime should not report idle"):
		return _cleanup_and_fail(monitor, fake_nodes)

	for node in fake_nodes:
		if node is SnapshotNode:
			if node.is_in_group("entity_manager"):
				(node as SnapshotNode).snapshot = {
					"physics_process_enabled": false,
					"entity_maintenance_timer_active": false,
					"pending_spawns": 72,
					"deferred_spawn_chunks": 187,
					"deferred_spawn_plans": 402,
					"startup_pending_total": 0,
					"background_spawn_backlog": 661,
					"spawn_queue_background_only": true
				}
			else:
				(node as SnapshotNode).snapshot = {}
	monitor._refresh_cached_values()
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/PendingWork"), 0.0), "background-only entity backlog should not count as active runtime pending work"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/Idle"), 1.0), "background-only entity backlog should still allow idle verdict"):
		return _cleanup_and_fail(monitor, fake_nodes)

	for node in fake_nodes:
		if node is SnapshotNode:
			if node.is_in_group("terrain_manager"):
				(node as SnapshotNode).snapshot = {
					"terrain_process_loop_awake": true
				}
			elif node.is_in_group("building_manager") or node.is_in_group("prefab_spawner") or node.is_in_group("vegetation_manager"):
				(node as SnapshotNode).snapshot = {
					"process_loop_awake": true
				}
			elif node.is_in_group("entity_manager"):
				(node as SnapshotNode).snapshot = {
					"physics_process_enabled": false,
					"entity_maintenance_timer_active": true,
					"active_entities": 34,
					"startup_pending_total": 0,
					"spawn_queue_maintenance_work": false
				}
	monitor._refresh_cached_values()
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/PendingWork"), 0.0), "timer/process loops without pending work should not count as runtime pending work"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/AwakeProcessCount"), 0.0), "timer/process loops without pending work should not count as awake runtime managers"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/Idle"), 1.0), "timer/process loops without pending work should still allow idle verdict"):
		return _cleanup_and_fail(monitor, fake_nodes)

	for node in fake_nodes:
		if node is SnapshotNode:
			(node as SnapshotNode).snapshot = {}
	monitor._refresh_cached_values()
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/PendingWork"), 0.0), "idle runtime should report zero aggregate pending work"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/AwakeProcessCount"), 0.0), "idle runtime should report zero awake managers"):
		return _cleanup_and_fail(monitor, fake_nodes)
	if not _expect(is_equal_approx(monitor.get_cached_monitor_value(&"WorldRuntime/Idle"), 1.0), "idle runtime should expose a cached idle verdict"):
		return _cleanup_and_fail(monitor, fake_nodes)

	_cleanup(monitor, fake_nodes)
	print("[WORLD_PERFORMANCE_MONITORS_TEST] PASS")
	return 0


func _prepare_startup_coordinator(fake_nodes: Array[Node]) -> void:
	var coordinator := get_root().get_node_or_null("WorldStartupCoordinator")
	if coordinator and coordinator.has_method("get_snapshot"):
		coordinator.set("_overall_progress_percent", 42.5)
		coordinator.set("_active", true)
		coordinator.set("_failed", false)
		coordinator.set("_cancelled", false)
		coordinator.set("_playable_ready_emitted", true)
		return
	_add_fake_manager(fake_nodes, &"world_startup_coordinator", {
		"overall_progress_percent": 42.5,
		"active": true,
		"failed": false,
		"cancelled": false,
		"playable_ready": true
	})


func _add_fake_manager(fake_nodes: Array[Node], group_name: StringName, telemetry: Dictionary) -> void:
	var node := SnapshotNode.new(group_name, telemetry)
	get_root().add_child(node)
	fake_nodes.append(node)


func _cleanup_and_fail(monitor: Node, fake_nodes: Array[Node]) -> int:
	_cleanup(monitor, fake_nodes)
	return 1


func _cleanup(monitor: Node, fake_nodes: Array[Node]) -> void:
	if monitor and is_instance_valid(monitor):
		monitor.free()
	for node in fake_nodes:
		if node and is_instance_valid(node):
			node.free()


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_PERFORMANCE_MONITORS_TEST] FAIL: %s" % message)
	return false
