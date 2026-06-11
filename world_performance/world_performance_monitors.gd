extends Node
## Registers cheap live custom monitors for startup, terrain cache, and runtime idle state.

@export_range(0.05, 2.0, 0.05) var sample_interval_s: float = 0.25
@export var custom_monitors_enabled: bool = true

const MONITOR_IDS: Array[StringName] = [
	&"WorldStartup/OverallProgress",
	&"WorldStartup/Active",
	&"WorldStartup/Failed",
	&"WorldStartup/Cancelled",
	&"WorldStartup/PlayableReady",
	&"TerrainArtifactCache/Entries",
	&"TerrainArtifactCache/Bytes",
	&"TerrainArtifactCache/ByteBudgetRatio",
	&"TerrainArtifactCache/HitRatio",
	&"TerrainArtifactCache/Evictions",
	&"TerrainArtifactDiskCache/Bytes",
	&"TerrainArtifactDiskCache/ByteBudgetRatio",
	&"TerrainArtifactCache/DiskHits",
	&"TerrainArtifactCache/ReadyResourceRestores",
	&"TerrainArtifactDiskCache/Evictions",
	&"TerrainArtifactDiskWriteQueue/PendingBytes",
	&"TerrainArtifactDiskWriteQueue/PendingEntries",
	&"TerrainArtifactDiskWriteQueue/CompletedBytes",
	&"TerrainArtifactDiskWriteQueue/RateLimitWaitMs",
	&"TerrainGeneration/GpuSyncMs",
	&"TerrainGeneration/ReadbackMs",
	&"TerrainFinalization/Pending",
	&"WorldRuntime/TerrainProcessAwake",
	&"WorldRuntime/BuildingProcessAwake",
	&"WorldRuntime/PrefabProcessAwake",
	&"WorldRuntime/VegetationProcessAwake",
	&"WorldRuntime/EntityMaintenanceAwake",
	&"WorldRuntime/AwakeProcessCount",
	&"WorldRuntime/Idle",
	&"WorldRuntime/PendingWork"
]

var _values: Dictionary = {}
var _sample_accumulator_s: float = 0.0
var _pending_work_total: float = 0.0


func _ready() -> void:
	add_to_group("world_performance_monitors")
	if custom_monitors_enabled:
		_register_monitors()
	_refresh_cached_values()
	set_process(true)


func _exit_tree() -> void:
	if custom_monitors_enabled:
		_unregister_monitors()


func _process(delta: float) -> void:
	_sample_accumulator_s += maxf(delta, 0.0)
	if _sample_accumulator_s < sample_interval_s:
		return
	_sample_accumulator_s = 0.0
	_refresh_cached_values()


func get_registered_monitor_ids() -> Array[StringName]:
	return MONITOR_IDS.duplicate()


func get_cached_monitor_value(id: StringName) -> float:
	return float(_values.get(id, 0.0))


func _register_monitors() -> void:
	for id in MONITOR_IDS:
		if Performance.has_custom_monitor(id):
			Performance.remove_custom_monitor(id)
		Performance.add_custom_monitor(id, Callable(self, "_get_monitor_value"), [id])
		_values[id] = 0.0


func _unregister_monitors() -> void:
	for id in MONITOR_IDS:
		if Performance.has_custom_monitor(id):
			Performance.remove_custom_monitor(id)


func _get_monitor_value(id: StringName) -> float:
	return maxf(float(_values.get(id, 0.0)), 0.0)


func _refresh_cached_values() -> void:
	for id in MONITOR_IDS:
		_values[id] = 0.0
	_pending_work_total = 0.0

	_capture_startup_values()
	_capture_terrain_values()
	_capture_building_values()
	_capture_prefab_values()
	_capture_vegetation_values()
	_capture_entity_values()
	_capture_pending_work_value()


func _capture_startup_values() -> void:
	var coordinator := _get_node_from_root_or_group("/root/WorldStartupCoordinator", "world_startup_coordinator")
	var snapshot := _get_snapshot(coordinator)
	if snapshot.is_empty():
		return
	_values[&"WorldStartup/OverallProgress"] = clampf(float(snapshot.get("overall_progress_percent", 0.0)), 0.0, 100.0)
	_values[&"WorldStartup/Active"] = _bool_to_float(bool(snapshot.get("active", false)))
	_values[&"WorldStartup/Failed"] = _bool_to_float(bool(snapshot.get("failed", false)))
	_values[&"WorldStartup/Cancelled"] = _bool_to_float(bool(snapshot.get("cancelled", false)))
	_values[&"WorldStartup/PlayableReady"] = _bool_to_float(bool(snapshot.get("playable_ready", false)))


func _capture_terrain_values() -> void:
	var terrain_manager := _get_node_from_group("terrain_manager")
	var snapshot := _get_snapshot(terrain_manager)
	if snapshot.is_empty():
		return
	var memory_cache := _get_dictionary(snapshot, "terrain_artifact_cache")
	var disk_cache := _get_dictionary(snapshot, "terrain_artifact_disk_cache")
	_values[&"TerrainArtifactCache/Entries"] = _number_from_keys(memory_cache, ["entry_count"], _number_from_keys(snapshot, ["terrain_artifact_cache_entries", "artifact_cache_entries"], 0.0))
	_values[&"TerrainArtifactCache/Bytes"] = _number_from_keys(memory_cache, ["total_bytes"], _number_from_keys(snapshot, ["terrain_artifact_cache_bytes", "artifact_cache_bytes"], 0.0))
	_values[&"TerrainArtifactCache/ByteBudgetRatio"] = clampf(_number_from_keys(memory_cache, ["byte_budget_used_ratio"], _number_from_keys(snapshot, ["terrain_artifact_cache_byte_budget_used_ratio", "artifact_cache_byte_budget_used_ratio"], 0.0)), 0.0, 1.0)
	_values[&"TerrainArtifactCache/HitRatio"] = clampf(_number_from_keys(memory_cache, ["hit_ratio"], _number_from_keys(snapshot, ["terrain_artifact_cache_hit_ratio", "artifact_cache_hit_ratio"], 0.0)), 0.0, 1.0)
	_values[&"TerrainArtifactCache/Evictions"] = _number_from_keys(memory_cache, ["eviction_count"], _number_from_keys(snapshot, ["terrain_artifact_cache_evictions", "artifact_cache_evictions"], 0.0))
	_values[&"TerrainArtifactDiskCache/Bytes"] = _number_from_keys(disk_cache, ["last_signature_bytes"], _number_from_keys(snapshot, ["terrain_artifact_disk_cache_bytes", "disk_artifact_cache_bytes"], 0.0))
	_values[&"TerrainArtifactDiskCache/ByteBudgetRatio"] = clampf(_number_from_keys(disk_cache, ["last_signature_byte_budget_used_ratio"], _number_from_keys(snapshot, ["terrain_artifact_disk_cache_byte_budget_used_ratio", "disk_artifact_cache_byte_budget_used_ratio"], 0.0)), 0.0, 1.0)
	_values[&"TerrainArtifactCache/DiskHits"] = _number_from_keys(disk_cache, ["hit_count"], _number_from_keys(snapshot, ["terrain_artifact_disk_cache_hits", "disk_artifact_restores"], 0.0))
	_values[&"TerrainArtifactCache/ReadyResourceRestores"] = _number_from_keys(snapshot, ["terrain_artifact_ready_resource_restore_count"], 0.0)
	_values[&"TerrainArtifactDiskCache/Evictions"] = _number_from_keys(disk_cache, ["eviction_count"], _number_from_keys(snapshot, ["terrain_artifact_disk_cache_evictions", "disk_artifact_cache_evictions"], 0.0))
	_values[&"TerrainGeneration/GpuSyncMs"] = (
		_number_from_keys(snapshot, ["last_gpu_generation_mod_sync_ms"], 0.0)
		+ _number_from_keys(snapshot, ["last_gpu_generation_sync_ms"], 0.0)
		+ _number_from_keys(snapshot, ["last_gpu_meshing_sync_ms"], 0.0)
		+ _number_from_keys(snapshot, ["last_gpu_mesh_slice_max_sync_ms"], 0.0)
	)
	_values[&"TerrainGeneration/ReadbackMs"] = _number_from_keys(snapshot, ["last_gpu_mesh_readback_ms"], 0.0)
	_values[&"TerrainFinalization/Pending"] = _number_from_keys(snapshot, ["pending_node_count", "pending_nodes"], 0.0)
	var terrain_pending_work: float = _values[&"TerrainFinalization/Pending"] \
		+ _number_from_keys(snapshot, ["task_queue_count"], 0.0) \
		+ _number_from_keys(snapshot, ["cpu_task_queue_count"], 0.0) \
		+ _number_from_keys(snapshot, ["completed_generation_queue_count"], 0.0) \
		+ _number_from_keys(snapshot, ["pending_batch_count"], 0.0) \
		+ _number_from_keys(snapshot, ["pending_spawn_zone_count"], 0.0) \
		+ _number_from_keys(snapshot, ["world_map_lod_pending_candidate_count"], 0.0) \
		+ _bool_to_float(bool(snapshot.get("initial_load_phase", false))) \
		+ _bool_to_float(bool(snapshot.get("render_resource_prewarm_active", false)))

	var write_queue := _get_dictionary(snapshot, "terrain_artifact_disk_write_queue")
	if not write_queue.is_empty():
		_values[&"TerrainArtifactDiskWriteQueue/PendingBytes"] = _number_from_keys(write_queue, ["pending_bytes"], 0.0)
		_values[&"TerrainArtifactDiskWriteQueue/PendingEntries"] = _number_from_keys(write_queue, ["pending_entries"], 0.0)
		_values[&"TerrainArtifactDiskWriteQueue/CompletedBytes"] = _number_from_keys(write_queue, ["completed_bytes"], 0.0)
		_values[&"TerrainArtifactDiskWriteQueue/RateLimitWaitMs"] = _number_from_keys(write_queue, ["rate_limit_total_wait_ms"], 0.0)
		terrain_pending_work += _values[&"TerrainArtifactDiskWriteQueue/PendingEntries"]
	_values[&"WorldRuntime/TerrainProcessAwake"] = _bool_to_float(
		bool(snapshot.get("terrain_process_loop_awake", snapshot.get("process_loop_awake", false)))
		and terrain_pending_work > 0.0
	)
	_add_pending_work(terrain_pending_work)


func _capture_building_values() -> void:
	var building_manager := _get_node_from_group("building_manager")
	var snapshot := _get_snapshot(building_manager)
	if snapshot.is_empty():
		return
	var building_pending_work: float = _number_from_keys(snapshot, ["pending_world_map_baked_building_apply_phases"], 0.0) \
		+ _number_from_keys(snapshot, ["pending_object_collision_jobs"], 0.0) \
		+ _number_from_keys(snapshot, ["pending_world_map_baked_object_spawns"], 0.0) \
		+ _number_from_keys(snapshot, ["pending_visual_batch_rebuilds"], 0.0) \
		+ _number_from_keys(snapshot, ["dirty_visible_chunk_count", "dirty_chunk_count"], 0.0) \
		+ _bool_to_float(bool(snapshot.get("object_render_prewarm_active", false)))
	_values[&"WorldRuntime/BuildingProcessAwake"] = _bool_to_float(bool(snapshot.get("process_loop_awake", false)) and building_pending_work > 0.0)
	_add_pending_work(building_pending_work)


func _capture_prefab_values() -> void:
	var prefab_spawner := _get_node_from_group("prefab_spawner")
	var snapshot := _get_snapshot(prefab_spawner)
	if snapshot.is_empty():
		return
	var prefab_pending_work: float = _number_from_keys(snapshot, ["pending_spawn_jobs"], 0.0) \
		+ _number_from_keys(snapshot, ["pending_world_map_baked_payload_build_jobs"], 0.0) \
		+ _number_from_keys(snapshot, ["pending_world_map_baked_payload_jobs"], 0.0)
	_values[&"WorldRuntime/PrefabProcessAwake"] = _bool_to_float(bool(snapshot.get("process_loop_awake", false)) and prefab_pending_work > 0.0)
	_add_pending_work(prefab_pending_work)


func _capture_vegetation_values() -> void:
	var vegetation_manager := _get_node_from_group("vegetation_manager")
	var snapshot := _get_snapshot(vegetation_manager)
	if snapshot.is_empty():
		return
	var vegetation_pending_work: float = _number_from_keys(snapshot, ["pending_chunks_count", "pending_chunks"], 0.0) \
		+ _number_from_keys(snapshot, ["pending_collider_adds"], 0.0) \
		+ _number_from_keys(snapshot, ["pending_collider_removes"], 0.0) \
		+ _number_from_keys(snapshot, ["global_render_dirty_cluster_count"], 0.0) \
		+ _bool_to_float(bool(snapshot.get("vegetation_render_prewarm_active", false)))
	_values[&"WorldRuntime/VegetationProcessAwake"] = _bool_to_float(bool(snapshot.get("process_loop_awake", false)) and vegetation_pending_work > 0.0)
	_add_pending_work(vegetation_pending_work)


func _capture_entity_values() -> void:
	var entity_manager := _get_node_from_group("entity_manager")
	var snapshot := _get_snapshot(entity_manager)
	if snapshot.is_empty():
		return
	var entity_pending_work: float = 0.0
	if snapshot.has("startup_pending_total"):
		entity_pending_work = _number_from_keys(snapshot, ["startup_pending_total"], 0.0)
	else:
		entity_pending_work = _number_from_keys(snapshot, ["pending_spawns"], 0.0) \
			+ _number_from_keys(snapshot, ["deferred_spawn_chunks"], 0.0) \
			+ _number_from_keys(snapshot, ["deferred_spawn_plans"], 0.0)
	entity_pending_work += _bool_to_float(bool(snapshot.get("entity_render_prewarm_active", false)))
	var awake := bool(snapshot.get("physics_process_enabled", false)) \
		or entity_pending_work > 0.0 \
		or bool(snapshot.get("spawn_queue_maintenance_work", false))
	_values[&"WorldRuntime/EntityMaintenanceAwake"] = _bool_to_float(awake)
	_add_pending_work(entity_pending_work)


func _capture_pending_work_value() -> void:
	var pending := _pending_work_total
	var awake_count := 0.0
	for id in [
		&"WorldRuntime/TerrainProcessAwake",
		&"WorldRuntime/BuildingProcessAwake",
		&"WorldRuntime/PrefabProcessAwake",
		&"WorldRuntime/VegetationProcessAwake",
		&"WorldRuntime/EntityMaintenanceAwake"
	]:
		awake_count += float(_values.get(id, 0.0))
	pending += awake_count
	_values[&"WorldRuntime/AwakeProcessCount"] = awake_count
	_values[&"WorldRuntime/PendingWork"] = pending
	_values[&"WorldRuntime/Idle"] = 1.0 if pending <= 0.0 else 0.0


func _get_snapshot(node: Node) -> Dictionary:
	if not node or not is_instance_valid(node):
		return {}
	var snapshot_variant: Variant = {}
	if node.has_method("get_telemetry_snapshot"):
		snapshot_variant = node.call("get_telemetry_snapshot")
	elif node.has_method("get_snapshot"):
		snapshot_variant = node.call("get_snapshot")
	if snapshot_variant is Dictionary:
		return snapshot_variant
	return {}


func _get_node_from_group(group_name: StringName) -> Node:
	if not is_inside_tree():
		return null
	return get_tree().get_first_node_in_group(group_name)


func _get_node_from_root_or_group(root_path: NodePath, group_name: StringName) -> Node:
	if not is_inside_tree():
		return null
	var node := get_node_or_null(root_path)
	if node:
		return node
	return _get_node_from_group(group_name)


func _bool_to_float(value: bool) -> float:
	return 1.0 if value else 0.0


func _get_dictionary(source: Dictionary, key: String) -> Dictionary:
	var value: Variant = source.get(key, {})
	if value is Dictionary:
		return value
	return {}


func _number_from_keys(source: Dictionary, keys: Array, default_value: float = 0.0) -> float:
	for key in keys:
		if source.has(key):
			return maxf(float(source.get(key, default_value)), 0.0)
	return maxf(default_value, 0.0)


func _add_pending_work(value: float) -> void:
	_pending_work_total += maxf(value, 0.0)
