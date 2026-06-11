extends Node
class_name WorldTerrainArtifactBaker
## Pre-game terrain artifact bake runner.
##
## This runs the same marching-cubes terrain path as gameplay in an isolated
## ChunkManager, but before play starts and with world-local synchronous disk
## persistence. Runtime startup can then restore artifacts instead of generating
## the same chunks again.

signal progress_changed(profile: Dictionary)
signal bake_completed(profile: Dictionary)
signal bake_failed(profile: Dictionary)

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")
const WorldMapData = preload("res://world_map_data/world_map_data.gd")

const MANIFEST_MAGIC := "world_terrain_artifact_bake"
const MANIFEST_VERSION := 1

@export_range(0, 16, 1) var bake_radius_chunks: int = 10
@export_range(0.0, 3600.0, 1.0) var timeout_seconds: float = 900.0
@export var store_ready_mesh_resources: bool = true
@export var synchronous_disk_writes: bool = true
@export var high_throughput_budgets: bool = true
@export var offline_cpu_fallback_enabled: bool = true
@export_range(1, 64, 1) var offline_cpu_chunks_per_frame: int = 2

var _manager = null
var _root: Node3D = null
var _viewer: Node3D = null
var _world_path: String = ""
var _origin: Vector3 = Vector3.ZERO
var _origins: Array[Vector3] = []
var _radius: int = 0
var _expected_chunks: int = 0
var _requested_chunks: int = 0
var _bake_coords: Array[Vector3i] = []
var _started_usec: int = 0
var _last_progress_emit_usec: int = 0
var _last_stage: String = ""
var _running: bool = false
var _final_profile: Dictionary = {}
var _offline_cpu_bake_active: bool = false
var _offline_cpu_bake_coords: Array[Vector3i] = []
var _offline_cpu_bake_index: int = 0
var _offline_cpu_bake_stored_count: int = 0
var _offline_cpu_bake_reused_count: int = 0
var _offline_cpu_bake_skipped_count: int = 0
var _offline_cpu_bake_failure_count: int = 0
var _offline_cpu_bake_reason: String = ""
var _offline_cpu_bake_builder: Object = null
var _offline_cpu_bake_last_coord: Vector3i = Vector3i.ZERO
var _offline_cpu_bake_total_generation_ms: float = 0.0
var _offline_cpu_bake_total_mesh_ms: float = 0.0
var _offline_cpu_bake_total_store_ms: float = 0.0


func _ready() -> void:
	set_process(false)


func start_bake(world_path: String, origin: Vector3 = Vector3.ZERO, radius_chunks: int = -1, options: Dictionary = {}) -> bool:
	if _running:
		return false
	_world_path = world_path.strip_edges()
	if _world_path.is_empty():
		_fail_bake("missing_world_path")
		return false

	_origins = _normalize_bake_origins(origin, options)
	_origin = _origins[0] if not _origins.is_empty() else origin
	_radius = maxi(int(options.get("radius_chunks", radius_chunks if radius_chunks >= 0 else bake_radius_chunks)), 0)
	_bake_coords = _build_bake_coords_for_origins(_origins, _radius)
	_expected_chunks = _bake_coords.size()
	_requested_chunks = 0
	_started_usec = Time.get_ticks_usec()
	_last_progress_emit_usec = 0
	_last_stage = ""
	_final_profile = {}

	store_ready_mesh_resources = bool(options.get("store_ready_mesh_resources", store_ready_mesh_resources))
	synchronous_disk_writes = bool(options.get("synchronous_disk_writes", synchronous_disk_writes))
	high_throughput_budgets = bool(options.get("high_throughput_budgets", high_throughput_budgets))
	offline_cpu_fallback_enabled = bool(options.get("offline_cpu_fallback_enabled", offline_cpu_fallback_enabled))
	offline_cpu_chunks_per_frame = maxi(int(options.get("offline_cpu_chunks_per_frame", offline_cpu_chunks_per_frame)), 1)

	_create_manager()
	_running = true
	set_process(true)
	call_deferred("_request_bake")
	print("[WorldTerrainArtifactBaker] starting world=%s origins=%d radius=%d expected_chunks=%d artifact_root=%s ready_resources=%s sync_writes=%s" % [
		_world_path,
		_origins.size(),
		_radius,
		_expected_chunks,
		WorldMapData.get_world_terrain_artifact_root(_world_path),
		str(store_ready_mesh_resources),
		str(synchronous_disk_writes)
	])
	_emit_progress("initializing")
	return true


func cancel_bake(reason: String = "cancelled") -> Dictionary:
	var profile := _build_profile(reason)
	profile["cancelled"] = true
	_running = false
	set_process(false)
	_cleanup_manager()
	_final_profile = profile
	progress_changed.emit(profile)
	return profile


func get_profile() -> Dictionary:
	if not _final_profile.is_empty():
		return _final_profile.duplicate(true)
	if _offline_cpu_bake_active:
		return _build_offline_cpu_bake_profile(_last_stage if not _last_stage.is_empty() else "offline native marching-cubes terrain artifact bake")
	return _build_profile(_last_stage if not _last_stage.is_empty() else "idle")


func _normalize_bake_origins(primary_origin: Vector3, options: Dictionary) -> Array[Vector3]:
	var origins: Array[Vector3] = []
	var seen := {}
	if bool(options.get("include_primary_origin", true)):
		_append_unique_bake_origin(origins, seen, primary_origin)
	var origin_variants: Variant = options.get("bake_origins", [])
	if origin_variants is Array:
		for origin_variant in origin_variants:
			var parsed := _try_read_bake_origin(origin_variant)
			if bool(parsed.get("valid", false)):
				var parsed_origin: Vector3 = parsed.get("origin", Vector3.ZERO)
				_append_unique_bake_origin(origins, seen, parsed_origin)
	if origins.is_empty():
		_append_unique_bake_origin(origins, seen, primary_origin)
	return origins


func _try_read_bake_origin(value: Variant) -> Dictionary:
	if value is Vector3:
		return {"valid": true, "origin": value}
	if value is Vector2:
		return {"valid": true, "origin": Vector3(value.x, 0.0, value.y)}
	if value is Dictionary:
		var data: Dictionary = value
		if data.has("x") and data.has("z"):
			return {
				"valid": true,
				"origin": Vector3(
					float(data.get("x", 0.0)),
					float(data.get("y", 0.0)),
					float(data.get("z", 0.0))
				)
			}
	return {"valid": false}


func _append_unique_bake_origin(origins: Array[Vector3], seen: Dictionary, origin: Vector3) -> void:
	var key := _bake_origin_chunk_key(origin)
	if seen.has(key):
		return
	seen[key] = true
	origins.append(origin)


func _bake_origin_chunk_key(origin: Vector3) -> String:
	return "%d:%d:%d" % [
		int(floor(origin.x / float(ChunkManagerScript.CHUNK_STRIDE))),
		int(floor(origin.y / float(ChunkManagerScript.CHUNK_STRIDE))),
		int(floor(origin.z / float(ChunkManagerScript.CHUNK_STRIDE)))
	]


func _create_manager() -> void:
	_root = Node3D.new()
	_root.name = "TerrainArtifactBakeRoot"
	add_child(_root)

	_viewer = Node3D.new()
	_viewer.name = "TerrainArtifactBakeViewer"
	_viewer.position = _origin
	_root.add_child(_viewer)

	_manager = ChunkManagerScript.new()
	_manager.name = "TerrainArtifactBakeChunkManager"
	_manager.viewer = _viewer
	_manager.world_definition_path = _world_path
	_manager.world_map_active = true
	_manager.render_distance = 0
	_manager.collision_distance = 0
	_manager.collision_prewarm_distance = 0
	_manager.shared_terrain_collision_body_enabled = false
	_manager.terrain_collision_body_cache_limit = 0
	_manager.startup_preheat_radius_chunks = _radius
	_manager.startup_require_preheat_before_play = false
	_manager.terrain_artifact_cache_enabled = true
	_manager.terrain_artifact_cache_memory_budget_mb = 1024
	_manager.terrain_artifact_cache_entry_limit = maxi(_expected_chunks * 2, 64)
	_manager.terrain_artifact_disk_cache_enabled = true
	_manager.terrain_artifact_use_world_local_disk_cache = true
	_manager.terrain_artifact_disk_store_runtime_chunks = true
	_manager.terrain_artifact_disk_async_writes_enabled = not synchronous_disk_writes
	_manager.terrain_artifact_disk_cache_entries_per_world = maxi(_expected_chunks * 2, 64)
	_manager.terrain_artifact_disk_cache_budget_mb = 8192
	_manager.terrain_artifact_store_ready_mesh_resources = store_ready_mesh_resources
	_manager.render_resource_prewarm_frames = 0
	_manager.distant_world_map_lod_enabled = false
	_manager.terrain_event_driven_process_sleep_enabled = false
	_manager.runtime_power_mode_enabled = false
	if high_throughput_budgets:
		_manager.completed_generation_drain_limit_per_frame = 256
		_manager.completed_generation_drain_budget_ms = 12.0
		_manager.pending_node_initial_finalize_max_per_frame = 256
		_manager.pending_node_finalize_max_per_frame = 128
		_manager.spawn_zone_pending_node_finalize_max_per_frame = 128
		_manager.pending_node_runtime_render_commits_per_frame = 64
		_manager.chunks_per_frame_limit = 32
		_manager.adaptive_frame_budget_ms = 12.0
		_manager.terrain_force_pending_node_finalization_for_test = true
	_root.add_child(_manager)


func _request_bake() -> void:
	if not _running or _manager == null or not is_instance_valid(_manager):
		return
	if "_native_backends_ready" in _manager and not bool(_manager._native_backends_ready):
		_fail_bake("native_backends_not_ready")
		return
	if not _manager.has_method("request_terrain_artifact_bake_many"):
		_fail_bake("missing_chunk_manager_bake_api")
		return
	_requested_chunks = int(_manager.request_terrain_artifact_bake_many(_origins, _radius, &"map_generation_terrain_artifact_bake"))
	print("[WorldTerrainArtifactBaker] requested_chunks=%d origins=%d" % [_requested_chunks, _origins.size()])
	_emit_progress("baking terrain mesh artifacts")


func _process(_delta: float) -> void:
	if not _running:
		return
	if timeout_seconds > 0.0:
		var elapsed_s := float(Time.get_ticks_usec() - _started_usec) / 1000000.0
		if elapsed_s >= timeout_seconds:
			_fail_bake("timeout")
			return

	if _offline_cpu_bake_active:
		_process_offline_cpu_bake()
		return

	var profile := _build_profile(_current_stage())
	if _should_switch_to_offline_cpu_bake(profile):
		_start_offline_cpu_bake("compute_device_failed")
		return
	if _should_emit_progress(profile):
		progress_changed.emit(profile)
	if _is_bake_complete(profile):
		_complete_bake(profile)


func _should_switch_to_offline_cpu_bake(profile: Dictionary) -> bool:
	var event_counts: Dictionary = profile.get("terrain_trace_event_counts", {})
	if int(event_counts.get("compute_device_failed", 0)) <= 0:
		return false
	if not offline_cpu_fallback_enabled:
		_fail_bake("compute_device_failed")
		return false
	return true


func _emit_progress(stage: String) -> void:
	var profile := _build_profile(stage)
	_last_stage = stage
	_last_progress_emit_usec = Time.get_ticks_usec()
	progress_changed.emit(profile)


func _current_stage() -> String:
	if _manager == null or not is_instance_valid(_manager):
		return "initializing terrain bake"
	var snapshot: Dictionary = _manager.get_startup_readiness_snapshot()
	var details: Dictionary = snapshot.get("details", {})
	var queued_generates := int(details.get("generation_queue_count", 0))
	var queued_restores := int(details.get("artifact_restore_queue_count", 0))
	var pending_nodes := int(details.get("pending_nodes", 0))
	var cpu_tasks := int(details.get("cpu_task_queue_count", 0))
	if queued_restores > 0:
		return "restoring baked terrain artifacts"
	if queued_generates > 0 or cpu_tasks > 0:
		return "generating marching-cubes terrain artifacts"
	if pending_nodes > 0:
		return "finalizing baked terrain artifacts"
	return "verifying terrain artifact bake"


func _are_bake_coords_ready() -> bool:
	if _manager == null or not is_instance_valid(_manager):
		return false
	if _bake_coords.is_empty():
		return false
	for coord in _bake_coords:
		if not _manager.active_chunks.has(coord):
			return false
		if _manager.active_chunks[coord] == null:
			return false
	return true


func _build_profile(stage: String) -> Dictionary:
	var artifact_root := WorldMapData.get_world_terrain_artifact_root(_world_path)
	var manifest_path := WorldMapData.get_world_terrain_artifact_manifest_path(_world_path)
	var elapsed_ms := 0.0
	if _started_usec > 0:
		elapsed_ms = float(Time.get_ticks_usec() - _started_usec) / 1000.0

	if _manager == null or not is_instance_valid(_manager):
		return {
			"stage": stage,
			"progress_percent": 0.0,
			"world_path": _world_path,
			"artifact_root": artifact_root,
			"manifest_path": manifest_path,
			"elapsed_ms": elapsed_ms,
			"origin": _origin,
			"origins": _origins_to_manifest(),
			"origin_count": _origins.size(),
			"expected_chunks": _expected_chunks,
			"requested_chunks": _requested_chunks
		}

	var readiness: Dictionary = _manager.get_startup_readiness_snapshot()
	var details: Dictionary = readiness.get("details", {})
	var telemetry: Dictionary = _manager.get_telemetry_snapshot()
	var disk_cache: Dictionary = telemetry.get("terrain_artifact_disk_cache", {})
	var write_queue: Dictionary = telemetry.get("terrain_artifact_disk_write_queue", {})
	var terrain_trace: Dictionary = telemetry.get("terrain_trace", {})
	var loaded_chunks := int(telemetry.get("loaded_chunk_count", 0))
	var store_count := int(disk_cache.get("store_count", 0))
	var hit_count := int(disk_cache.get("hit_count", 0))
	var semantic_artifacts := store_count + hit_count
	var chunk_progress := float(mini(maxi(loaded_chunks, semantic_artifacts), _expected_chunks)) / float(maxi(_expected_chunks, 1))
	var progress_percent := clampf(chunk_progress * 100.0, 0.0, 100.0)
	var pending_work := _pending_work_without_spawn_zone(details)
	var writes_pending := int(write_queue.get("pending_entries", 0))
	var writes_in_flight := bool(write_queue.get("in_flight", false))
	var chunks_ready := _are_bake_coords_ready()

	return {
		"stage": stage,
		"progress_percent": progress_percent,
		"world_path": _world_path,
		"origin": _origin,
		"origins": _origins_to_manifest(),
		"origin_count": _origins.size(),
		"radius_chunks": _radius,
		"expected_chunks": _expected_chunks,
		"requested_chunks": _requested_chunks,
		"ready_chunks_estimate": mini(loaded_chunks, _expected_chunks),
		"chunks_ready": chunks_ready,
		"stored_artifact_count": store_count,
		"reused_disk_artifact_count": hit_count,
		"artifact_count": semantic_artifacts,
		"artifact_root": artifact_root,
		"resolved_artifact_root": ProjectSettings.globalize_path(artifact_root),
		"manifest_path": manifest_path,
		"resolved_manifest_path": ProjectSettings.globalize_path(manifest_path),
		"pending_work": pending_work,
		"disk_write_pending_entries": writes_pending,
		"disk_write_in_flight": writes_in_flight,
		"native_backends_ready": bool(telemetry.get("native_backends_ready", false)),
		"gpu_generation_batch_count": int(telemetry.get("gpu_generation_batch_count", 0)),
		"gpu_generation_batch_chunk_total": int(telemetry.get("gpu_generation_batch_chunk_total", 0)),
		"cpu_task_queue_count": int(details.get("cpu_task_queue_count", 0)),
		"completed_generation_queue_count": int(details.get("completed_generation_queue_count", 0)),
		"pending_nodes": int(details.get("pending_nodes", 0)),
		"terrain_trace_event_counts": terrain_trace.get("event_counts", {}),
		"elapsed_ms": elapsed_ms,
		"store_ready_mesh_resources": store_ready_mesh_resources,
		"synchronous_disk_writes": synchronous_disk_writes,
		"manager_readiness": readiness,
		"manager_telemetry": telemetry
	}


func _pending_work_without_spawn_zone(details: Dictionary) -> int:
	return (
		int(details.get("pending_nodes", 0))
		+ int(details.get("task_queue_count", 0))
		+ int(details.get("cpu_task_queue_count", 0))
		+ int(details.get("completed_generation_queue_count", 0))
	)


func _should_emit_progress(profile: Dictionary) -> bool:
	var now_usec := Time.get_ticks_usec()
	var stage := str(profile.get("stage", ""))
	if stage != _last_stage:
		_last_stage = stage
		_last_progress_emit_usec = now_usec
		print("[WorldTerrainArtifactBaker] %s %.1f%% artifacts=%d/%d pending=%d" % [
			stage,
			float(profile.get("progress_percent", 0.0)),
			int(profile.get("artifact_count", 0)),
			int(profile.get("expected_chunks", 0)),
			int(profile.get("pending_work", 0))
		])
		return true
	if _last_progress_emit_usec <= 0 or now_usec - _last_progress_emit_usec >= 250000:
		_last_progress_emit_usec = now_usec
		return true
	return false


func _is_bake_complete(profile: Dictionary) -> bool:
	if _expected_chunks <= 0:
		return false
	var artifact_count := int(profile.get("artifact_count", 0))
	return (
		bool(profile.get("chunks_ready", false))
		and int(profile.get("pending_work", 1)) <= 0
		and artifact_count >= _expected_chunks
		and int(profile.get("disk_write_pending_entries", 0)) <= 0
		and not bool(profile.get("disk_write_in_flight", false))
	)


func _start_offline_cpu_bake(reason: String) -> void:
	if not offline_cpu_fallback_enabled:
		_fail_bake(reason)
		return
	if _manager == null or not is_instance_valid(_manager):
		_fail_bake("offline_cpu_missing_chunk_manager")
		return
	if not ClassDB.class_exists("MeshBuilder"):
		_fail_bake("offline_cpu_missing_mesh_builder")
		return

	_offline_cpu_bake_builder = ClassDB.instantiate("MeshBuilder")
	if _offline_cpu_bake_builder == null:
		_fail_bake("offline_cpu_mesh_builder_instantiate_failed")
		return
	if (
		_offline_cpu_bake_builder.has_method("has_marching_cubes_tables")
		and not bool(_offline_cpu_bake_builder.has_marching_cubes_tables())
	):
		_fail_bake("offline_cpu_missing_marching_cubes_tables")
		return
	if not _offline_cpu_bake_builder.has_method("build_density_marching_cubes_mesh_data_height_map"):
		_fail_bake("offline_cpu_missing_density_mesher")
		return

	if _manager.has_method("_prepare_world_definition_cpu_state"):
		_manager._prepare_world_definition_cpu_state("offline_terrain_artifact_bake")
	if not bool(_manager.world_map_active):
		_fail_bake("offline_cpu_requires_world_map_data")
		return
	if _manager._world_map_heightmap_data.is_empty() or _manager._world_map_heightmap_width <= 0 or _manager._world_map_heightmap_height <= 0:
		_fail_bake("offline_cpu_missing_heightmap")
		return

	_manager.terrain_artifact_store_ready_mesh_resources = store_ready_mesh_resources
	_manager.terrain_artifact_disk_async_writes_enabled = false
	_manager.terrain_artifact_disk_store_runtime_chunks = true
	_manager.terrain_artifact_use_world_local_disk_cache = true
	_manager.terrain_artifact_cache_enabled = true
	_manager.terrain_artifact_cache_entry_limit = maxi(_expected_chunks * 2, 64)
	_manager.terrain_artifact_disk_cache_entries_per_world = maxi(_expected_chunks * 2, 64)
	_manager.terrain_artifact_disk_cache_budget_mb = 8192
	_manager.initial_load_phase = true
	_manager.initial_load_target_chunks = _expected_chunks
	_manager.chunks_loaded_initial = 0
	_manager._sync_terrain_artifact_cache_configuration()
	_manager._sync_terrain_artifact_disk_store_configuration()
	_manager._refresh_terrain_artifact_settings_signature()

	_offline_cpu_bake_coords = _bake_coords.duplicate()
	if _offline_cpu_bake_coords.is_empty():
		_offline_cpu_bake_coords = _build_bake_coords_for_origins(_origins, _radius)
	_expected_chunks = _offline_cpu_bake_coords.size()
	_offline_cpu_bake_index = 0
	_offline_cpu_bake_stored_count = 0
	_offline_cpu_bake_reused_count = 0
	_offline_cpu_bake_skipped_count = 0
	_offline_cpu_bake_failure_count = 0
	_offline_cpu_bake_total_generation_ms = 0.0
	_offline_cpu_bake_total_mesh_ms = 0.0
	_offline_cpu_bake_total_store_ms = 0.0
	_offline_cpu_bake_reason = reason
	_offline_cpu_bake_active = true
	_requested_chunks = _offline_cpu_bake_coords.size()
	print("[WorldTerrainArtifactBaker] switching to offline CPU/native bake reason=%s chunks=%d" % [
		reason,
		_offline_cpu_bake_coords.size()
	])
	_emit_progress("offline native marching-cubes terrain artifact bake")


func _process_offline_cpu_bake() -> void:
	var processed := 0
	var chunk_budget := maxi(offline_cpu_chunks_per_frame, 1)
	while processed < chunk_budget and _offline_cpu_bake_index < _offline_cpu_bake_coords.size():
		var coord := _offline_cpu_bake_coords[_offline_cpu_bake_index]
		_offline_cpu_bake_last_coord = coord
		_offline_cpu_bake_index += 1
		processed += 1
		var result := _bake_offline_cpu_chunk(coord)
		match str(result.get("status", "")):
			"stored":
				_offline_cpu_bake_stored_count += 1
			"reused":
				_offline_cpu_bake_reused_count += 1
			"skipped":
				_offline_cpu_bake_skipped_count += 1
			_:
				_offline_cpu_bake_failure_count += 1
		_offline_cpu_bake_total_generation_ms += float(result.get("density_generation_ms", 0.0))
		_offline_cpu_bake_total_mesh_ms += float(result.get("mesh_build_ms", 0.0))
		_offline_cpu_bake_total_store_ms += float(result.get("store_ms", 0.0))

	var profile := _build_offline_cpu_bake_profile("offline native marching-cubes terrain artifact bake")
	if _should_emit_progress(profile):
		progress_changed.emit(profile)

	if _offline_cpu_bake_index < _offline_cpu_bake_coords.size():
		return

	if _offline_cpu_bake_failure_count > 0:
		_fail_bake("offline_cpu_artifact_store_failed")
		return

	_offline_cpu_bake_active = false
	_running = false
	set_process(false)
	profile = _build_offline_cpu_bake_profile("terrain artifact bake complete")
	profile["progress_percent"] = 100.0
	profile["completed"] = true
	profile["manifest_written"] = _write_manifest(profile)
	_final_profile = profile.duplicate(true)
	print("[WorldTerrainArtifactBaker] offline CPU/native complete artifacts=%d stored=%d reused=%d manifest=%s elapsed_ms=%.0f" % [
		int(profile.get("artifact_count", 0)),
		int(profile.get("stored_artifact_count", 0)),
		int(profile.get("reused_disk_artifact_count", 0)),
		str(profile.get("manifest_path", "")),
		float(profile.get("elapsed_ms", 0.0))
	])
	progress_changed.emit(_final_profile)
	bake_completed.emit(_final_profile)
	call_deferred("_cleanup_manager")


func _build_bake_coords(origin: Vector3, radius: int) -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	radius = maxi(radius, 0)
	var chunk_x := int(floor(origin.x / float(ChunkManagerScript.CHUNK_STRIDE)))
	var chunk_y := int(floor(origin.y / float(ChunkManagerScript.CHUNK_STRIDE)))
	var chunk_z := int(floor(origin.z / float(ChunkManagerScript.CHUNK_STRIDE)))
	for dx in range(-radius, radius + 1):
		for dy in range(-1, 2):
			for dz in range(-radius, radius + 1):
				coords.append(Vector3i(chunk_x + dx, chunk_y + dy, chunk_z + dz))
	return coords


func _build_bake_coords_for_origins(origins: Array[Vector3], radius: int) -> Array[Vector3i]:
	var unique_coords := {}
	for origin in origins:
		for coord in _build_bake_coords(origin, radius):
			unique_coords[coord] = true
	var coords: Array[Vector3i] = []
	for coord_variant in unique_coords.keys():
		if coord_variant is Vector3i:
			coords.append(coord_variant)
	return coords


func _bake_offline_cpu_chunk(coord: Vector3i) -> Dictionary:
	var chunk_pos := Vector3(
		coord.x * ChunkManagerScript.CHUNK_STRIDE,
		coord.y * ChunkManagerScript.CHUNK_STRIDE,
		coord.z * ChunkManagerScript.CHUNK_STRIDE
	)
	var request_task: Dictionary = _manager._build_chunk_request_task(coord, chunk_pos)
	if str(request_task.get("type", "")) == "restore_artifact":
		return {"status": "reused"}

	var density_start_us := Time.get_ticks_usec()
	var density_payload := _build_offline_world_map_density_payload(coord)
	var density_generation_ms := float(Time.get_ticks_usec() - density_start_us) / 1000.0
	if density_payload.is_empty():
		return {
			"status": "failed",
			"density_generation_ms": density_generation_ms
		}

	var terrain_density_bytes: PackedByteArray = density_payload.get("density_bytes_terrain", PackedByteArray())
	var water_density_bytes: PackedByteArray = density_payload.get("density_bytes_water", PackedByteArray())
	var material_bytes: PackedByteArray = density_payload.get("material_bytes_terrain", PackedByteArray())

	var mesh_start_us := Time.get_ticks_usec()
	var result_t: Dictionary = _offline_cpu_bake_builder.build_density_marching_cubes_mesh_data_height_map(
		terrain_density_bytes,
		material_bytes,
		ChunkManagerScript.DENSITY_GRID_SIZE,
		ChunkManagerScript.CHUNK_SIZE,
		ChunkManagerScript.CHUNK_STRIDE
	)
	var result_w: Dictionary = {}
	if bool(density_payload.get("water_surface_possible", false)):
		if _offline_cpu_bake_builder.has_method("build_density_marching_cubes_mesh_data"):
			result_w = _offline_cpu_bake_builder.build_density_marching_cubes_mesh_data(
				water_density_bytes,
				material_bytes,
				ChunkManagerScript.DENSITY_GRID_SIZE,
				ChunkManagerScript.CHUNK_SIZE
			)
	if result_w.is_empty():
		result_w = {
			"deferred_mesh_data": true,
			"arrays": [],
			"faces": PackedVector3Array()
		}
	result_w["generated_density"] = true
	var mesh_build_ms := float(Time.get_ticks_usec() - mesh_start_us) / 1000.0

	var height_map_t: PackedFloat32Array = result_t.get("height_map", PackedFloat32Array())
	var store_start_us := Time.get_ticks_usec()
	_manager._store_terrain_artifact_from_generation(
		coord,
		result_t,
		result_w,
		PackedFloat32Array(),
		PackedFloat32Array(),
		height_map_t,
		PackedByteArray(),
		0,
		{
			"artifact_density_bytes_terrain": terrain_density_bytes,
			"artifact_density_bytes_water": water_density_bytes,
			"artifact_material_bytes_terrain": material_bytes
		}
	)
	var store_ms := float(Time.get_ticks_usec() - store_start_us) / 1000.0
	var artifact_path: String = _manager._terrain_artifact_disk_store._artifact_path(coord, _manager._terrain_artifact_settings_signature)
	return {
		"status": "stored" if FileAccess.file_exists(artifact_path) else "failed",
		"density_generation_ms": density_generation_ms,
		"mesh_build_ms": mesh_build_ms,
		"store_ms": store_ms
	}


func _build_offline_world_map_density_payload(coord: Vector3i) -> Dictionary:
	if _manager == null or not is_instance_valid(_manager):
		return {}
	var grid_size: int = ChunkManagerScript.DENSITY_GRID_SIZE
	var sample_count := grid_size * grid_size * grid_size
	var terrain_density := PackedFloat32Array()
	var water_density := PackedFloat32Array()
	var material_bytes := PackedByteArray()
	terrain_density.resize(sample_count)
	water_density.resize(sample_count)
	material_bytes.resize(sample_count * 4)

	var base_x := coord.x * ChunkManagerScript.CHUNK_STRIDE
	var base_y := coord.y * ChunkManagerScript.CHUNK_STRIDE
	var base_z := coord.z * ChunkManagerScript.CHUNK_STRIDE
	var water_surface_possible := _offline_chunk_may_have_water_surface(coord)
	var excavation_mask: PackedByteArray = _manager._world_map_excavation_masks.get(coord, PackedByteArray())

	for local_z in range(grid_size):
		var world_z := float(base_z + local_z)
		for local_y in range(grid_size):
			var world_y := float(base_y + local_y)
			for local_x in range(grid_size):
				var world_x := float(base_x + local_x)
				var index := local_x + (local_y * grid_size) + (local_z * grid_size * grid_size)
				var material_height := _offline_world_map_material_height(world_x, world_z)
				var density := _offline_world_map_density(world_x, world_y, world_z, material_height)
				if _offline_is_excavated_density_point(excavation_mask, local_x, local_y, local_z):
					density = 10.0
				terrain_density[index] = density
				water_density[index] = _offline_world_map_water_density(world_x, world_y, world_z)
				material_bytes.encode_u32(index * 4, _offline_world_map_material(world_x, world_y, world_z, material_height))

	return {
		"density_bytes_terrain": terrain_density.to_byte_array(),
		"density_bytes_water": water_density.to_byte_array(),
		"material_bytes_terrain": material_bytes,
		"water_surface_possible": water_surface_possible
	}


func _offline_world_map_material_height(world_x: float, world_z: float) -> float:
	if _offline_world_map_is_boundary_wall(world_x, world_z):
		return 28.0
	return _offline_sample_world_map_height(world_x, world_z)


func _offline_world_map_density(world_x: float, world_y: float, world_z: float, map_height: float) -> float:
	var edge_margin := 4.0
	var map_half := float(_manager.world_map_half)
	var dist_to_edge_x := minf(world_x + map_half, map_half - world_x)
	var dist_to_edge_z := minf(world_z + map_half, map_half - world_z)
	var dist_to_edge := minf(dist_to_edge_x, dist_to_edge_z)
	if dist_to_edge <= 0.0:
		return -10.0
	if dist_to_edge < edge_margin:
		var wall_blend := 1.0 - (dist_to_edge / edge_margin)
		var wall_height := lerpf(28.0, 32.0, wall_blend)
		if world_y > wall_height:
			return world_y - wall_height
		return -10.0 * wall_blend
	return world_y - map_height


func _offline_world_map_is_boundary_wall(world_x: float, world_z: float) -> bool:
	var map_half := float(_manager.world_map_half)
	var dist_to_edge_x := minf(world_x + map_half, map_half - world_x)
	var dist_to_edge_z := minf(world_z + map_half, map_half - world_z)
	return minf(dist_to_edge_x, dist_to_edge_z) < 4.0


func _offline_sample_world_map_height(world_x: float, world_z: float) -> float:
	var width := int(_manager._world_map_heightmap_width)
	var height := int(_manager._world_map_heightmap_height)
	var data: PackedByteArray = _manager._world_map_heightmap_data
	if width <= 0 or height <= 0 or data.size() < width * height:
		return 1.0
	var map_half := float(_manager.world_map_half)
	var px := clampf(world_x + map_half, 0.0, float(width - 1))
	var pz := clampf(world_z + map_half, 0.0, float(height - 1))
	var x0 := int(floor(px))
	var z0 := int(floor(pz))
	var x1 := mini(x0 + 1, width - 1)
	var z1 := mini(z0 + 1, height - 1)
	var tx := px - float(x0)
	var tz := pz - float(z0)
	var h00 := float(_offline_read_r8(data, width, height, x0, z0)) / 255.0
	var h10 := float(_offline_read_r8(data, width, height, x1, z0)) / 255.0
	var h01 := float(_offline_read_r8(data, width, height, x0, z1)) / 255.0
	var h11 := float(_offline_read_r8(data, width, height, x1, z1)) / 255.0
	var h0 := lerpf(h00, h10, tx)
	var h1 := lerpf(h01, h11, tx)
	return clampf(lerpf(h0, h1, tz) * float(_manager.world_map_max_height), 1.0, 28.0)


func _offline_world_map_water_density(world_x: float, world_y: float, world_z: float) -> float:
	if _offline_world_map_water_active(world_x, world_z):
		return world_y - float(_manager.water_level)
	return 100.0


func _offline_chunk_may_have_water_surface(coord: Vector3i) -> bool:
	if _manager._world_map_water_image == null:
		return false
	var chunk_min_y := float(coord.y * ChunkManagerScript.CHUNK_STRIDE)
	var chunk_max_y := chunk_min_y + float(ChunkManagerScript.CHUNK_SIZE)
	var water_level := float(_manager.water_level)
	if water_level < chunk_min_y - 0.5 or water_level > chunk_max_y + 0.5:
		return false
	var base_x := coord.x * ChunkManagerScript.CHUNK_STRIDE
	var base_z := coord.z * ChunkManagerScript.CHUNK_STRIDE
	for local_x in range(ChunkManagerScript.DENSITY_GRID_SIZE):
		var world_x := float(base_x + local_x)
		for local_z in range(ChunkManagerScript.DENSITY_GRID_SIZE):
			if _offline_world_map_water_active(world_x, float(base_z + local_z)):
				return true
	return false


func _offline_world_map_water_active(world_x: float, world_z: float) -> bool:
	if _manager._world_map_water_image == null:
		return false
	var width := int(_manager._world_map_water_image.get_width())
	var height := int(_manager._world_map_water_image.get_height())
	if width <= 0 or height <= 0:
		return false
	var data: PackedByteArray = _manager._world_map_water_data
	var map_half := float(_manager.world_map_half)
	var px := clampi(int(world_x + map_half), 0, width - 1)
	var pz := clampi(int(world_z + map_half), 0, height - 1)
	if data.size() >= width * height:
		return _offline_read_r8(data, width, height, px, pz) > 128
	return _manager._world_map_water_image.get_pixel(px, pz).r > 0.5019608


func _offline_world_map_material(world_x: float, world_y: float, world_z: float, terrain_height_at_pos: float) -> int:
	var depth := terrain_height_at_pos - world_y
	if depth > 10.0:
		var world_pos := Vector3(world_x, world_y, world_z)
		var ore_noise := _offline_noise3d(world_pos * 0.15)
		if ore_noise > 0.75 and depth > 8.0:
			return 2
		var stone_var := _offline_fbm3d(world_pos * 0.02)
		if stone_var > 0.25:
			return 9
		return 1

	var biome_id := _offline_sample_world_map_biome(world_x, world_z)
	var road_data := _offline_sample_world_map_road(world_x, world_z)
	if (road_data.x > 128.0 or biome_id == 6) and depth < 2.0:
		return 6
	return _offline_normalize_world_biome_material(biome_id)


func _offline_sample_world_map_biome(world_x: float, world_z: float) -> int:
	if _manager._world_map_biome_image == null:
		return 0
	var width := int(_manager._world_map_biome_image.get_width())
	var height := int(_manager._world_map_biome_image.get_height())
	if width <= 0 or height <= 0:
		return 0
	var data: PackedByteArray = _manager.gpu_biome_map
	var map_half := float(_manager.world_map_half)
	var px := clampi(int(world_x + map_half), 0, width - 1)
	var pz := clampi(int(world_z + map_half), 0, height - 1)
	if data.size() >= width * height:
		return _offline_read_r8(data, width, height, px, pz)
	return int(round(_manager._world_map_biome_image.get_pixel(px, pz).r * 255.0))


func _offline_sample_world_map_road(world_x: float, world_z: float) -> Vector2:
	if _manager._world_map_road_image == null:
		return Vector2.ZERO
	var width := int(_manager._world_map_road_image.get_width())
	var height := int(_manager._world_map_road_image.get_height())
	if width <= 0 or height <= 0:
		return Vector2.ZERO
	var map_half := float(_manager.world_map_half)
	var px := clampi(int(world_x + map_half), 0, width - 1)
	var pz := clampi(int(world_z + map_half), 0, height - 1)
	var data: PackedByteArray = _manager._world_map_road_data
	var byte_index := (pz * width + px) * 2
	if data.size() >= byte_index + 2:
		return Vector2(float(data[byte_index]), float(data[byte_index + 1]))
	var pixel: Color = _manager._world_map_road_image.get_pixel(px, pz)
	return Vector2(pixel.r * 255.0, pixel.g * 255.0)


func _offline_normalize_world_biome_material(biome_id: int) -> int:
	if biome_id == 0 or biome_id == 3 or biome_id == 4 or biome_id == 5:
		return biome_id
	return 0


func _offline_is_excavated_density_point(mask: PackedByteArray, local_x: int, local_y: int, local_z: int) -> bool:
	if mask.size() != ChunkManagerScript.EXCAVATION_MASK_BYTE_COUNT:
		return false
	var bit_index := local_x + (local_y * ChunkManagerScript.DENSITY_GRID_SIZE) + (local_z * ChunkManagerScript.DENSITY_GRID_SIZE * ChunkManagerScript.DENSITY_GRID_SIZE)
	var byte_index := int(bit_index / 8)
	if byte_index < 0 or byte_index >= mask.size():
		return false
	return ((mask[byte_index] >> (bit_index % 8)) & 1) != 0


func _offline_read_r8(data: PackedByteArray, width: int, height: int, x: int, y: int) -> int:
	x = clampi(x, 0, width - 1)
	y = clampi(y, 0, height - 1)
	var index := y * width + x
	if index < 0 or index >= data.size():
		return 0
	return int(data[index])


func _offline_noise3d(value: Vector3) -> float:
	var i := Vector3(floor(value.x), floor(value.y), floor(value.z))
	var f := Vector3(value.x - i.x, value.y - i.y, value.z - i.z)
	var smooth := Vector3(
		f.x * f.x * (3.0 - 2.0 * f.x),
		f.y * f.y * (3.0 - 2.0 * f.y),
		f.z * f.z * (3.0 - 2.0 * f.z)
	)
	return lerpf(
		lerpf(
			lerpf(_offline_hash3(i + Vector3(0, 0, 0)), _offline_hash3(i + Vector3(1, 0, 0)), smooth.x),
			lerpf(_offline_hash3(i + Vector3(0, 1, 0)), _offline_hash3(i + Vector3(1, 1, 0)), smooth.x),
			smooth.y
		),
		lerpf(
			lerpf(_offline_hash3(i + Vector3(0, 0, 1)), _offline_hash3(i + Vector3(1, 0, 1)), smooth.x),
			lerpf(_offline_hash3(i + Vector3(0, 1, 1)), _offline_hash3(i + Vector3(1, 1, 1)), smooth.x),
			smooth.y
		),
		smooth.z
	)


func _offline_hash3(value: Vector3) -> float:
	var p := Vector3(
		_offline_fract(value.x * 0.3183099 + 0.1),
		_offline_fract(value.y * 0.3183099 + 0.1),
		_offline_fract(value.z * 0.3183099 + 0.1)
	)
	p *= 17.0
	return _offline_fract(p.x * p.y * p.z * (p.x + p.y + p.z))


func _offline_fbm3d(value: Vector3) -> float:
	var total := 0.0
	var weight := 0.5
	var p := value
	for _i in range(3):
		total += weight * _offline_noise3d(p)
		p *= 2.0
		weight *= 0.5
	return total


func _offline_fract(value: float) -> float:
	return value - floor(value)


func _build_offline_cpu_bake_profile(stage: String) -> Dictionary:
	var artifact_root := WorldMapData.get_world_terrain_artifact_root(_world_path)
	var manifest_path := WorldMapData.get_world_terrain_artifact_manifest_path(_world_path)
	var elapsed_ms := 0.0
	if _started_usec > 0:
		elapsed_ms = float(Time.get_ticks_usec() - _started_usec) / 1000.0
	var expected := maxi(_offline_cpu_bake_coords.size(), _expected_chunks)
	var artifact_count := _offline_cpu_bake_stored_count + _offline_cpu_bake_reused_count
	var processed := _offline_cpu_bake_index
	var progress_percent := clampf(float(processed) / float(maxi(expected, 1)) * 100.0, 0.0, 100.0)
	var telemetry: Dictionary = {}
	var readiness: Dictionary = {}
	var event_counts: Dictionary = {}
	var disk_cache: Dictionary = {}
	if _manager != null and is_instance_valid(_manager):
		telemetry = _manager.get_telemetry_snapshot()
		readiness = _manager.get_startup_readiness_snapshot()
		var terrain_trace: Dictionary = telemetry.get("terrain_trace", {})
		event_counts = terrain_trace.get("event_counts", {})
		disk_cache = telemetry.get("terrain_artifact_disk_cache", {})
	return {
		"stage": stage,
		"progress_percent": progress_percent,
		"world_path": _world_path,
		"origin": _origin,
		"origins": _origins_to_manifest(),
		"origin_count": _origins.size(),
		"radius_chunks": _radius,
		"expected_chunks": expected,
		"requested_chunks": _requested_chunks,
		"ready_chunks_estimate": artifact_count,
		"chunks_ready": artifact_count >= expected,
		"stored_artifact_count": _offline_cpu_bake_stored_count,
		"reused_disk_artifact_count": _offline_cpu_bake_reused_count,
		"artifact_count": artifact_count,
		"artifact_root": artifact_root,
		"resolved_artifact_root": ProjectSettings.globalize_path(artifact_root),
		"manifest_path": manifest_path,
		"resolved_manifest_path": ProjectSettings.globalize_path(manifest_path),
		"pending_work": maxi(expected - processed, 0),
		"disk_write_pending_entries": 0,
		"disk_write_in_flight": false,
		"native_backends_ready": bool(telemetry.get("native_backends_ready", true)),
		"offline_cpu_fallback": true,
		"offline_cpu_fallback_reason": _offline_cpu_bake_reason,
		"offline_cpu_chunks_per_frame": offline_cpu_chunks_per_frame,
		"offline_cpu_processed_chunks": processed,
		"offline_cpu_skipped_count": _offline_cpu_bake_skipped_count,
		"offline_cpu_failure_count": _offline_cpu_bake_failure_count,
		"offline_cpu_last_coord": str(_offline_cpu_bake_last_coord),
		"offline_cpu_total_density_generation_ms": _offline_cpu_bake_total_generation_ms,
		"offline_cpu_total_mesh_build_ms": _offline_cpu_bake_total_mesh_ms,
		"offline_cpu_total_store_ms": _offline_cpu_bake_total_store_ms,
		"gpu_generation_batch_count": int(telemetry.get("gpu_generation_batch_count", 0)),
		"gpu_generation_batch_chunk_total": int(telemetry.get("gpu_generation_batch_chunk_total", 0)),
		"cpu_task_queue_count": 0,
		"completed_generation_queue_count": 0,
		"pending_nodes": 0,
		"terrain_trace_event_counts": event_counts,
		"elapsed_ms": elapsed_ms,
		"store_ready_mesh_resources": store_ready_mesh_resources,
		"synchronous_disk_writes": true,
		"disk_store_count": int(disk_cache.get("store_count", 0)),
		"manager_readiness": readiness,
		"manager_telemetry": telemetry
	}


func _complete_bake(profile: Dictionary) -> void:
	_running = false
	set_process(false)
	profile["stage"] = "terrain artifact bake complete"
	profile["progress_percent"] = 100.0
	profile["completed"] = true
	profile["manifest_written"] = _write_manifest(profile)
	_final_profile = profile.duplicate(true)
	print("[WorldTerrainArtifactBaker] complete artifacts=%d manifest=%s elapsed_ms=%.0f" % [
		int(profile.get("artifact_count", 0)),
		str(profile.get("manifest_path", "")),
		float(profile.get("elapsed_ms", 0.0))
	])
	progress_changed.emit(_final_profile)
	bake_completed.emit(_final_profile)
	_clear_manager_bake_pins()
	call_deferred("_cleanup_manager")


func _fail_bake(reason: String) -> void:
	_running = false
	set_process(false)
	var profile := _build_profile("terrain artifact bake failed")
	profile["failed"] = true
	profile["failure_reason"] = reason
	_final_profile = profile.duplicate(true)
	print("[WorldTerrainArtifactBaker] failed reason=%s artifacts=%d pending=%d" % [
		reason,
		int(profile.get("artifact_count", 0)),
		int(profile.get("pending_work", 0))
	])
	bake_failed.emit(_final_profile)
	_clear_manager_bake_pins()
	call_deferred("_cleanup_manager")


func _write_manifest(profile: Dictionary) -> bool:
	var manifest_path := WorldMapData.get_world_terrain_artifact_manifest_path(_world_path)
	if manifest_path.is_empty():
		return false
	if DirAccess.make_dir_recursive_absolute(manifest_path.get_base_dir()) != OK:
		return false
	var manifest := {
		"magic": MANIFEST_MAGIC,
		"version": MANIFEST_VERSION,
		"world_path": _world_path,
		"artifact_root": WorldMapData.get_world_terrain_artifact_root(_world_path),
		"origin": _vector3_to_manifest(_origin),
		"origins": _origins_to_manifest(),
		"origin_count": _origins.size(),
		"radius_chunks": _radius,
		"expected_chunks": _expected_chunks,
		"artifact_count": int(profile.get("artifact_count", 0)),
		"stored_artifact_count": int(profile.get("stored_artifact_count", 0)),
		"reused_disk_artifact_count": int(profile.get("reused_disk_artifact_count", 0)),
		"store_ready_mesh_resources": store_ready_mesh_resources,
		"synchronous_disk_writes": synchronous_disk_writes,
		"elapsed_ms": float(profile.get("elapsed_ms", 0.0)),
		"completed_at_unix": Time.get_unix_time_from_system()
	}
	var file := FileAccess.open(manifest_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(manifest, "\t"))
	file.close()
	return FileAccess.file_exists(manifest_path)


func _origins_to_manifest() -> Array:
	var result: Array = []
	for origin in _origins:
		result.append(_vector3_to_manifest(origin))
	return result


func _vector3_to_manifest(value: Vector3) -> Dictionary:
	return {
		"x": value.x,
		"y": value.y,
		"z": value.z
	}


func _cleanup_manager() -> void:
	if _root and is_instance_valid(_root):
		_root.queue_free()
	_root = null
	_viewer = null
	_manager = null


func _clear_manager_bake_pins() -> void:
	if _manager != null and is_instance_valid(_manager) and _manager.has_method("clear_terrain_artifact_bake_pins"):
		_manager.clear_terrain_artifact_bake_pins()


func _count_square_preheat_chunks(radius: int) -> int:
	radius = maxi(radius, 0)
	return (radius * 2 + 1) * (radius * 2 + 1) * 3
