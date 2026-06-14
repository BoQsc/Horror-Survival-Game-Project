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
const MaterialRegistry = preload("res://modules/world_generation/material_registry.gd")

const MANIFEST_MAGIC := "world_terrain_artifact_bake"
const MANIFEST_VERSION := 1

@export_range(0, 16, 1) var bake_radius_chunks: int = 10
@export_range(0.0, 3600.0, 1.0) var timeout_seconds: float = 900.0
@export var store_ready_mesh_resources: bool = false
@export var store_source_buffers: bool = false
@export var store_collision_faces: bool = false
@export var synchronous_disk_writes: bool = true
@export var high_throughput_budgets: bool = true
@export var require_chunk_finalization_for_manifest: bool = false
@export var offline_cpu_fallback_enabled: bool = true
@export var prefer_offline_cpu_bake: bool = true
@export_range(1, 64, 1) var offline_cpu_chunks_per_frame: int = 16
@export var offline_cpu_parallel_bake_enabled: bool = true
@export_range(0, 16, 1) var offline_cpu_worker_count: int = 0
@export_range(0, 8, 1) var vertical_layer_radius: int = 0
@export var use_disk_radius_shape: bool = true

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
var _uses_explicit_bake_coords: bool = false
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
var _offline_cpu_bake_native_density_count: int = 0
var _offline_cpu_bake_gdscript_density_count: int = 0
var _offline_cpu_bake_reason: String = ""
var _offline_cpu_bake_builder: Object = null
var _offline_cpu_density_builder: Object = null
var _offline_cpu_bake_last_coord: Vector3i = Vector3i.ZERO
var _offline_cpu_bake_total_generation_ms: float = 0.0
var _offline_cpu_bake_total_mesh_ms: float = 0.0
var _offline_cpu_bake_total_store_ms: float = 0.0
var _offline_cpu_density_context: Dictionary = {}
var _offline_cpu_artifact_settings_signature: String = ""
var _offline_cpu_parallel_threads: Array[Thread] = []
var _offline_cpu_parallel_started: bool = false
var _offline_cpu_parallel_results_collected: bool = false
var _offline_cpu_parallel_worker_count: int = 0
var _offline_cpu_parallel_launch_usec: int = 0
var _offline_cpu_parallel_wall_ms: float = 0.0
var _offline_cpu_parallel_generated_count: int = 0
var _offline_cpu_parallel_worker_error_count: int = 0
var _offline_cpu_pending_store_results: Array[Dictionary] = []
var _offline_cpu_pending_store_index: int = 0
var _offline_cpu_parallel_mutex: Mutex = Mutex.new()


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
	_requested_chunks = 0
	_started_usec = Time.get_ticks_usec()
	_last_progress_emit_usec = 0
	_last_stage = ""
	_final_profile = {}

	store_ready_mesh_resources = bool(options.get("store_ready_mesh_resources", store_ready_mesh_resources))
	store_source_buffers = bool(options.get("store_source_buffers", store_source_buffers))
	store_collision_faces = bool(options.get("store_collision_faces", store_collision_faces))
	synchronous_disk_writes = bool(options.get("synchronous_disk_writes", synchronous_disk_writes))
	high_throughput_budgets = bool(options.get("high_throughput_budgets", high_throughput_budgets))
	require_chunk_finalization_for_manifest = bool(options.get("require_chunk_finalization_for_manifest", require_chunk_finalization_for_manifest))
	offline_cpu_fallback_enabled = bool(options.get("offline_cpu_fallback_enabled", offline_cpu_fallback_enabled))
	prefer_offline_cpu_bake = bool(options.get("prefer_offline_cpu_bake", prefer_offline_cpu_bake))
	offline_cpu_chunks_per_frame = maxi(int(options.get("offline_cpu_chunks_per_frame", offline_cpu_chunks_per_frame)), 1)
	offline_cpu_parallel_bake_enabled = bool(options.get("offline_cpu_parallel_bake_enabled", offline_cpu_parallel_bake_enabled))
	offline_cpu_worker_count = clampi(int(options.get("offline_cpu_worker_count", offline_cpu_worker_count)), 0, 16)
	vertical_layer_radius = maxi(int(options.get("vertical_layer_radius", vertical_layer_radius)), 0)
	use_disk_radius_shape = bool(options.get("use_disk_radius_shape", use_disk_radius_shape))
	_bake_coords = _normalize_bake_coords(options.get("bake_coords", []))
	_uses_explicit_bake_coords = not _bake_coords.is_empty()
	if not _uses_explicit_bake_coords:
		_bake_coords = _build_bake_coords_for_origins(_origins, _radius, vertical_layer_radius, use_disk_radius_shape)
	_expected_chunks = _bake_coords.size()

	_create_manager(not prefer_offline_cpu_bake)
	_running = true
	set_process(true)
	if prefer_offline_cpu_bake:
		call_deferred("_start_offline_cpu_bake", "preferred_offline_native")
	else:
		call_deferred("_request_bake")
	print("[WorldTerrainArtifactBaker] starting world=%s coord_mode=%s origins=%d radius=%d vertical=%d disk_shape=%s expected_chunks=%d artifact_root=%s ready_resources=%s source_buffers=%s collision_faces=%s sync_writes=%s offline_preferred=%s" % [
		_world_path,
		"explicit" if _uses_explicit_bake_coords else "origins_radius",
		_origins.size(),
		_radius,
		vertical_layer_radius,
		str(use_disk_radius_shape),
		_expected_chunks,
		WorldMapData.get_world_terrain_artifact_root(_world_path),
		str(store_ready_mesh_resources),
		str(store_source_buffers),
		str(store_collision_faces),
		str(synchronous_disk_writes),
		str(prefer_offline_cpu_bake)
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


func _normalize_bake_coords(value: Variant) -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	if not (value is Array):
		return coords
	var seen := {}
	for coord_variant in value:
		var coord := Vector3i.ZERO
		if coord_variant is Vector3i:
			coord = coord_variant
		elif coord_variant is Vector3:
			var position: Vector3 = coord_variant
			coord = Vector3i(
				int(floor(position.x / float(ChunkManagerScript.CHUNK_STRIDE))),
				int(floor(position.y / float(ChunkManagerScript.CHUNK_STRIDE))),
				int(floor(position.z / float(ChunkManagerScript.CHUNK_STRIDE)))
			)
		else:
			continue
		if seen.has(coord):
			continue
		seen[coord] = true
		coords.append(coord)
	return coords


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


func _create_manager(add_manager_to_tree: bool = true) -> void:
	if add_manager_to_tree:
		_root = Node3D.new()
		_root.name = "TerrainArtifactBakeRoot"
		add_child(_root)

		_viewer = Node3D.new()
		_viewer.name = "TerrainArtifactBakeViewer"
		_viewer.position = _origin
		_root.add_child(_viewer)
	else:
		_root = null
		_viewer = Node3D.new()
		_viewer.name = "TerrainArtifactBakeViewer"
		_viewer.position = _origin

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
	_manager.terrain_artifact_store_source_buffers = store_source_buffers
	_manager.terrain_artifact_store_collision_faces = store_collision_faces
	_manager.render_resource_prewarm_frames = 0
	_manager.distant_world_map_lod_enabled = false
	_manager.terrain_event_driven_process_sleep_enabled = false
	_manager.runtime_power_mode_enabled = false
	if high_throughput_budgets:
		_manager.completed_generation_drain_limit_per_frame = 512
		_manager.completed_generation_drain_budget_ms = 48.0
		_manager.pending_node_initial_finalize_max_per_frame = 512
		_manager.pending_node_finalize_max_per_frame = 512
		_manager.spawn_zone_pending_node_finalize_max_per_frame = 512
		_manager.pending_node_runtime_render_commits_per_frame = 512
		_manager.chunks_per_frame_limit = 64
		_manager.adaptive_frame_budget_ms = 24.0
		_manager.terrain_force_pending_node_finalization_for_test = true
	if add_manager_to_tree:
		_root.add_child(_manager)
	else:
		_initialize_off_tree_manager_runtime()


func _initialize_off_tree_manager_runtime() -> void:
	if _manager == null or not is_instance_valid(_manager):
		return
	if _manager.mutex == null:
		_manager.mutex = Mutex.new()
	if _manager.semaphore == null:
		_manager.semaphore = Semaphore.new()
	if _manager.pending_nodes_mutex == null:
		_manager.pending_nodes_mutex = Mutex.new()
	if _manager.cpu_mutex == null:
		_manager.cpu_mutex = Mutex.new()
	if _manager.cpu_semaphore == null:
		_manager.cpu_semaphore = Semaphore.new()
	if _manager.completed_generation_mutex == null:
		_manager.completed_generation_mutex = Mutex.new()
	if _manager.stored_modifications_mutex == null:
		_manager.stored_modifications_mutex = Mutex.new()
	if _manager._completed_terrain_visual_batch_mutex == null:
		_manager._completed_terrain_visual_batch_mutex = Mutex.new()
	if ClassDB.class_exists("TerrainGrid") and (_manager.terrain_grid == null or not is_instance_valid(_manager.terrain_grid)):
		_manager.terrain_grid = ClassDB.instantiate("TerrainGrid")
		if _manager.terrain_grid != null:
			_manager._sync_terrain_grid_options()
	if ClassDB.class_exists("MeshBuilder") and _manager.terrain_grid != null:
		_manager._native_backends_ready = true


func _request_bake() -> void:
	if not _running or _manager == null or not is_instance_valid(_manager):
		return
	if "_native_backends_ready" in _manager and not bool(_manager._native_backends_ready):
		_fail_bake("native_backends_not_ready")
		return
	if _uses_explicit_bake_coords:
		if not _manager.has_method("request_terrain_artifact_bake_coords"):
			_fail_bake("missing_chunk_manager_explicit_bake_api")
			return
		_requested_chunks = int(_manager.request_terrain_artifact_bake_coords(
			_bake_coords,
			&"map_generation_terrain_artifact_bake"
		))
	else:
		if not _manager.has_method("request_terrain_artifact_bake_many"):
			_fail_bake("missing_chunk_manager_bake_api")
			return
		_requested_chunks = int(_manager.request_terrain_artifact_bake_many(
			_origins,
			_radius,
			&"map_generation_terrain_artifact_bake",
			vertical_layer_radius,
			use_disk_radius_shape
		))
	print("[WorldTerrainArtifactBaker] requested_chunks=%d coord_mode=%s origins=%d" % [
		_requested_chunks,
		"explicit" if _uses_explicit_bake_coords else "origins_radius",
		_origins.size()
	])
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
	var profile := _build_offline_cpu_bake_profile(stage) if _offline_cpu_bake_active else _build_profile(stage)
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
	return "waiting for terrain artifact manifest readiness"


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
			"coord_mode": "explicit" if _uses_explicit_bake_coords else "origins_radius",
			"explicit_coord_count": _bake_coords.size() if _uses_explicit_bake_coords else 0,
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
		"coord_mode": "explicit" if _uses_explicit_bake_coords else "origins_radius",
		"explicit_coord_count": _bake_coords.size() if _uses_explicit_bake_coords else 0,
		"radius_chunks": _radius,
		"vertical_layer_radius": vertical_layer_radius,
		"use_disk_radius_shape": use_disk_radius_shape,
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
		"task_queue_count": int(details.get("task_queue_count", 0)),
		"generation_queue_count": int(details.get("generation_queue_count", 0)),
		"artifact_restore_queue_count": int(details.get("artifact_restore_queue_count", 0)),
		"completed_generation_queue_count": int(details.get("completed_generation_queue_count", 0)),
		"pending_nodes": int(details.get("pending_nodes", 0)),
		"terrain_trace_event_counts": terrain_trace.get("event_counts", {}),
		"elapsed_ms": elapsed_ms,
		"store_ready_mesh_resources": store_ready_mesh_resources,
		"store_source_buffers": store_source_buffers,
		"store_collision_faces": store_collision_faces,
		"synchronous_disk_writes": synchronous_disk_writes,
		"prefer_offline_cpu_bake": prefer_offline_cpu_bake,
		"require_chunk_finalization_for_manifest": require_chunk_finalization_for_manifest,
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
	if artifact_count < _expected_chunks:
		return false
	if int(profile.get("disk_write_pending_entries", 0)) > 0 or bool(profile.get("disk_write_in_flight", false)):
		return false
	if bool(profile.get("require_chunk_finalization_for_manifest", false)):
		return bool(profile.get("chunks_ready", false)) and int(profile.get("pending_work", 1)) <= 0
	var generation_work := (
		int(profile.get("task_queue_count", 0))
		+ int(profile.get("cpu_task_queue_count", 0))
		+ int(profile.get("completed_generation_queue_count", 0))
	)
	return generation_work <= 0


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
	if ClassDB.class_exists("TerrainGrid"):
		_offline_cpu_density_builder = ClassDB.instantiate("TerrainGrid")
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
	_manager.terrain_artifact_store_source_buffers = store_source_buffers
	_manager.terrain_artifact_store_collision_faces = store_collision_faces
	_manager.terrain_artifact_disk_async_writes_enabled = false
	_manager.terrain_artifact_disk_store_runtime_chunks = true
	_manager.terrain_artifact_use_world_local_disk_cache = true
	_manager.terrain_artifact_cache_enabled = false
	_manager.terrain_artifact_cache_entry_limit = maxi(_expected_chunks * 2, 64)
	_manager.terrain_artifact_disk_cache_entries_per_world = maxi(_expected_chunks * 2, 64)
	_manager.terrain_artifact_disk_cache_budget_mb = 8192
	_manager.initial_load_phase = true
	_manager.initial_load_target_chunks = _expected_chunks
	_manager.chunks_loaded_initial = 0
	_manager._sync_terrain_artifact_cache_configuration()
	_manager._sync_terrain_artifact_disk_store_configuration()
	_manager._refresh_terrain_artifact_settings_signature()
	_manager.terrain_artifact_store_configuration_locked = true
	if _manager._terrain_artifact_disk_store != null:
		_manager._terrain_artifact_disk_store.begin_bulk_store(_manager._terrain_artifact_settings_signature)
	_offline_cpu_density_context = _build_offline_cpu_density_context()
	_offline_cpu_artifact_settings_signature = _manager._terrain_artifact_settings_signature

	_offline_cpu_bake_coords = _bake_coords.duplicate()
	if _offline_cpu_bake_coords.is_empty():
		_offline_cpu_bake_coords = _build_bake_coords_for_origins(_origins, _radius, vertical_layer_radius, use_disk_radius_shape)
	_expected_chunks = _offline_cpu_bake_coords.size()
	_offline_cpu_bake_index = 0
	_offline_cpu_bake_stored_count = 0
	_offline_cpu_bake_reused_count = 0
	_offline_cpu_bake_skipped_count = 0
	_offline_cpu_bake_failure_count = 0
	_offline_cpu_bake_native_density_count = 0
	_offline_cpu_bake_gdscript_density_count = 0
	_offline_cpu_bake_total_generation_ms = 0.0
	_offline_cpu_bake_total_mesh_ms = 0.0
	_offline_cpu_bake_total_store_ms = 0.0
	_offline_cpu_parallel_started = false
	_offline_cpu_parallel_results_collected = false
	_offline_cpu_parallel_worker_count = 0
	_offline_cpu_parallel_launch_usec = 0
	_offline_cpu_parallel_wall_ms = 0.0
	_offline_cpu_parallel_generated_count = 0
	_offline_cpu_parallel_worker_error_count = 0
	_offline_cpu_pending_store_results.clear()
	_offline_cpu_pending_store_index = 0
	_join_offline_cpu_worker_threads()
	_offline_cpu_bake_reason = reason
	_offline_cpu_bake_active = true
	_requested_chunks = _offline_cpu_bake_coords.size()
	print("[WorldTerrainArtifactBaker] switching to offline CPU/native bake reason=%s chunks=%d" % [
		reason,
		_offline_cpu_bake_coords.size()
	])
	_emit_progress("offline native marching-cubes terrain artifact bake")


func _process_offline_cpu_bake() -> void:
	if _should_use_parallel_offline_cpu_bake():
		_process_parallel_offline_cpu_bake()
		return

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
		if str(result.get("density_backend", "")) == "native":
			_offline_cpu_bake_native_density_count += 1
		elif str(result.get("density_backend", "")) == "gdscript":
			_offline_cpu_bake_gdscript_density_count += 1

	var profile := _build_offline_cpu_bake_profile("offline native marching-cubes terrain artifact bake")
	if _should_emit_progress(profile):
		progress_changed.emit(profile)

	if _offline_cpu_bake_index < _offline_cpu_bake_coords.size():
		return

	if _offline_cpu_bake_failure_count > 0:
		_fail_bake("offline_cpu_artifact_store_failed")
		return
	if _manager != null and _manager._terrain_artifact_disk_store != null:
		if not _manager._terrain_artifact_disk_store.finish_bulk_store():
			_fail_bake("offline_cpu_artifact_pack_store_failed")
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


func _should_use_parallel_offline_cpu_bake() -> bool:
	return (
		offline_cpu_parallel_bake_enabled
		and not store_collision_faces
		and _offline_cpu_bake_coords.size() > 1
		and ClassDB.class_exists("MeshBuilder")
		and ClassDB.class_exists("TerrainGrid")
		and not _offline_cpu_density_context.is_empty()
	)


func _process_parallel_offline_cpu_bake() -> void:
	if not _offline_cpu_parallel_started:
		_start_parallel_offline_cpu_workers()
		var launch_profile := _build_offline_cpu_bake_profile("parallel native marching-cubes terrain artifact bake")
		progress_changed.emit(launch_profile)
		return

	if _offline_cpu_pending_store_results.is_empty() and _offline_cpu_parallel_threads_active():
		var running_profile := _build_offline_cpu_bake_profile("parallel native marching-cubes terrain artifact bake")
		if _should_emit_progress(running_profile):
			progress_changed.emit(running_profile)
		return

	if _offline_cpu_pending_store_results.is_empty() and not _offline_cpu_parallel_results_collected:
		_collect_parallel_offline_cpu_results()
		var collect_profile := _build_offline_cpu_bake_profile("storing parallel terrain artifacts")
		progress_changed.emit(collect_profile)
		if _offline_cpu_bake_failure_count > 0 and _offline_cpu_pending_store_results.is_empty():
			_fail_bake("offline_cpu_parallel_artifact_generation_failed")
			return

	var processed := 0
	var chunk_budget := maxi(offline_cpu_chunks_per_frame, 1)
	while processed < chunk_budget and _offline_cpu_pending_store_index < _offline_cpu_pending_store_results.size():
		var generated: Dictionary = _offline_cpu_pending_store_results[_offline_cpu_pending_store_index]
		_offline_cpu_pending_store_index += 1
		processed += 1
		_store_parallel_offline_cpu_result(generated)

	var profile := _build_offline_cpu_bake_profile("storing parallel terrain artifacts")
	if _should_emit_progress(profile):
		progress_changed.emit(profile)

	if _offline_cpu_pending_store_index < _offline_cpu_pending_store_results.size():
		return

	if _offline_cpu_bake_failure_count > 0:
		_fail_bake("offline_cpu_artifact_store_failed")
		return
	if _manager != null and _manager._terrain_artifact_disk_store != null:
		if not _manager._terrain_artifact_disk_store.finish_bulk_store():
			_fail_bake("offline_cpu_artifact_pack_store_failed")
			return

	_offline_cpu_bake_active = false
	_running = false
	set_process(false)
	profile = _build_offline_cpu_bake_profile("terrain artifact bake complete")
	profile["progress_percent"] = 100.0
	profile["completed"] = true
	profile["manifest_written"] = _write_manifest(profile)
	_final_profile = profile.duplicate(true)
	print("[WorldTerrainArtifactBaker] parallel offline CPU/native complete artifacts=%d stored=%d reused=%d workers=%d manifest=%s elapsed_ms=%.0f" % [
		int(profile.get("artifact_count", 0)),
		int(profile.get("stored_artifact_count", 0)),
		int(profile.get("reused_disk_artifact_count", 0)),
		int(profile.get("offline_cpu_parallel_worker_count", 0)),
		str(profile.get("manifest_path", "")),
		float(profile.get("elapsed_ms", 0.0))
	])
	progress_changed.emit(_final_profile)
	bake_completed.emit(_final_profile)
	call_deferred("_cleanup_manager")


func _start_parallel_offline_cpu_workers() -> void:
	_offline_cpu_parallel_started = true
	_offline_cpu_parallel_results_collected = false
	_offline_cpu_parallel_threads.clear()
	_offline_cpu_pending_store_results.clear()
	_offline_cpu_pending_store_index = 0
	_offline_cpu_parallel_generated_count = 0
	_offline_cpu_parallel_worker_error_count = 0
	_offline_cpu_parallel_launch_usec = Time.get_ticks_usec()
	var work_coords: Array[Vector3i] = []
	for coord in _offline_cpu_bake_coords:
		var chunk_pos := Vector3(
			coord.x * ChunkManagerScript.CHUNK_STRIDE,
			coord.y * ChunkManagerScript.CHUNK_STRIDE,
			coord.z * ChunkManagerScript.CHUNK_STRIDE
		)
		var request_task: Dictionary = _manager._build_chunk_request_task(coord, chunk_pos)
		if str(request_task.get("type", "")) == "restore_artifact":
			_offline_cpu_bake_reused_count += 1
			_offline_cpu_bake_index += 1
		else:
			work_coords.append(coord)
	if work_coords.is_empty():
		_offline_cpu_parallel_worker_count = 0
		_offline_cpu_parallel_wall_ms = 0.0
		return

	var worker_count := _resolve_offline_cpu_worker_count(work_coords.size())
	_offline_cpu_parallel_worker_count = worker_count
	var buckets: Array = []
	buckets.resize(worker_count)
	for worker_index in range(worker_count):
		buckets[worker_index] = []
	for index in range(work_coords.size()):
		var bucket: Array = buckets[index % worker_count]
		bucket.append(work_coords[index])

	for bucket_variant in buckets:
		var bucket_coords: Array = bucket_variant
		if bucket_coords.is_empty():
			continue
		var thread := Thread.new()
		var error := thread.start(Callable(self, "_parallel_offline_cpu_worker").bind(bucket_coords))
		if error != OK:
			_offline_cpu_parallel_worker_error_count += bucket_coords.size()
			_offline_cpu_bake_failure_count += bucket_coords.size()
			continue
		_offline_cpu_parallel_threads.append(thread)


func _resolve_offline_cpu_worker_count(coord_count: int) -> int:
	if coord_count <= 1:
		return 1
	if offline_cpu_worker_count > 0:
		return clampi(offline_cpu_worker_count, 1, coord_count)
	var processor_count := maxi(OS.get_processor_count(), 1)
	var auto_count := clampi(processor_count - 1, 1, 4)
	return mini(auto_count, coord_count)


func _parallel_offline_cpu_worker(coords: Array) -> Array:
	var results: Array[Dictionary] = []
	var mesh_builder: Object = null
	var density_builder: Object = null
	if ClassDB.class_exists("MeshBuilder"):
		mesh_builder = ClassDB.instantiate("MeshBuilder")
	if ClassDB.class_exists("TerrainGrid"):
		density_builder = ClassDB.instantiate("TerrainGrid")
	if mesh_builder == null or density_builder == null:
		for coord_variant in coords:
			results.append({
				"status": "failed",
				"failure_reason": "worker_missing_native_builder",
				"coord": coord_variant
			})
			_note_parallel_offline_cpu_generated()
		return results
	for coord_variant in coords:
		var coord: Vector3i = coord_variant
		var result := _bake_offline_cpu_chunk(coord, density_builder, mesh_builder, true)
		results.append(result)
		_note_parallel_offline_cpu_generated()
	return results


func _note_parallel_offline_cpu_generated() -> void:
	_offline_cpu_parallel_mutex.lock()
	_offline_cpu_parallel_generated_count += 1
	_offline_cpu_bake_index += 1
	_offline_cpu_parallel_mutex.unlock()


func _offline_cpu_parallel_threads_active() -> bool:
	for thread in _offline_cpu_parallel_threads:
		if thread != null and thread.is_alive():
			return true
	return false


func _collect_parallel_offline_cpu_results() -> void:
	if _offline_cpu_parallel_results_collected:
		return
	_offline_cpu_parallel_results_collected = true
	if _offline_cpu_parallel_launch_usec > 0:
		_offline_cpu_parallel_wall_ms = float(Time.get_ticks_usec() - _offline_cpu_parallel_launch_usec) / 1000.0
	for thread in _offline_cpu_parallel_threads:
		var worker_result_variant: Variant = thread.wait_to_finish()
		if worker_result_variant is Array:
			for result_variant in worker_result_variant:
				if result_variant is Dictionary:
					_offline_cpu_pending_store_results.append(result_variant)
				else:
					_offline_cpu_parallel_worker_error_count += 1
					_offline_cpu_bake_failure_count += 1
		else:
			_offline_cpu_parallel_worker_error_count += 1
			_offline_cpu_bake_failure_count += 1
	_offline_cpu_parallel_threads.clear()


func _store_parallel_offline_cpu_result(result: Dictionary) -> void:
	var coord: Vector3i = result.get("coord", Vector3i.ZERO)
	_offline_cpu_bake_last_coord = coord
	_offline_cpu_bake_total_generation_ms += float(result.get("density_generation_ms", 0.0))
	_offline_cpu_bake_total_mesh_ms += float(result.get("mesh_build_ms", 0.0))
	if str(result.get("density_backend", "")) == "native":
		_offline_cpu_bake_native_density_count += 1
	elif str(result.get("density_backend", "")) == "gdscript":
		_offline_cpu_bake_gdscript_density_count += 1
	var status := str(result.get("status", ""))
	if status != "generated" and status != "generated_artifact":
		_offline_cpu_bake_failure_count += 1
		return
	var store_start_us := Time.get_ticks_usec()
	var stored := false
	if status == "generated_artifact":
		var artifact: Dictionary = result.get("artifact", {})
		if store_ready_mesh_resources:
			_prepare_parallel_ready_mesh_artifact(artifact)
		stored = _manager._terrain_artifact_disk_store.store(coord, _offline_cpu_artifact_settings_signature, artifact)
		if stored:
			if bool(artifact.get("source_buffers_stored", false)):
				_manager._terrain_artifact_source_buffer_store_count += 1
			else:
				_manager._terrain_artifact_mesh_only_store_count += 1
	else:
		stored = _manager._store_terrain_artifact_from_generation(
			coord,
			result.get("result_t", {}),
			result.get("result_w", {}),
			PackedFloat32Array(),
			PackedFloat32Array(),
			result.get("height_map_t", PackedFloat32Array()),
			PackedByteArray(),
			0,
			result.get("artifact_payload", {})
		)
	_offline_cpu_bake_total_store_ms += float(Time.get_ticks_usec() - store_start_us) / 1000.0
	if stored:
		_offline_cpu_bake_stored_count += 1
	else:
		_offline_cpu_bake_failure_count += 1


func _join_offline_cpu_worker_threads() -> void:
	for thread in _offline_cpu_parallel_threads:
		if thread != null:
			thread.wait_to_finish()
	_offline_cpu_parallel_threads.clear()


func _build_bake_coords(
	origin: Vector3,
	radius: int,
	bake_vertical_layer_radius: int = 0,
	bake_disk_radius_shape: bool = true
) -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	radius = maxi(radius, 0)
	bake_vertical_layer_radius = maxi(bake_vertical_layer_radius, 0)
	var radius_sq := radius * radius
	var chunk_x := int(floor(origin.x / float(ChunkManagerScript.CHUNK_STRIDE)))
	var chunk_y := int(floor(origin.y / float(ChunkManagerScript.CHUNK_STRIDE)))
	var chunk_z := int(floor(origin.z / float(ChunkManagerScript.CHUNK_STRIDE)))
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			if bake_disk_radius_shape and dx * dx + dz * dz > radius_sq:
				continue
			for dy in range(-bake_vertical_layer_radius, bake_vertical_layer_radius + 1):
				coords.append(Vector3i(chunk_x + dx, chunk_y + dy, chunk_z + dz))
	return coords


func _build_bake_coords_for_origins(
	origins: Array[Vector3],
	radius: int,
	bake_vertical_layer_radius: int = 0,
	bake_disk_radius_shape: bool = true
) -> Array[Vector3i]:
	var unique_coords := {}
	for origin in origins:
		for coord in _build_bake_coords(origin, radius, bake_vertical_layer_radius, bake_disk_radius_shape):
			unique_coords[coord] = true
	var coords: Array[Vector3i] = []
	for coord_variant in unique_coords.keys():
		if coord_variant is Vector3i:
			coords.append(coord_variant)
	return coords


func _bake_offline_cpu_chunk(
	coord: Vector3i,
	density_builder: Object = null,
	mesh_builder: Object = null,
	defer_store: bool = false
) -> Dictionary:
	var chunk_pos := Vector3(
		coord.x * ChunkManagerScript.CHUNK_STRIDE,
		coord.y * ChunkManagerScript.CHUNK_STRIDE,
		coord.z * ChunkManagerScript.CHUNK_STRIDE
	)
	if not defer_store:
		var request_task: Dictionary = _manager._build_chunk_request_task(coord, chunk_pos)
		if str(request_task.get("type", "")) == "restore_artifact":
			return {"status": "reused", "coord": coord}

	var density_start_us := Time.get_ticks_usec()
	var density_payload := _build_offline_world_map_density_payload(coord, density_builder)
	var density_generation_ms := float(Time.get_ticks_usec() - density_start_us) / 1000.0
	if density_payload.is_empty():
		return {
			"status": "failed",
			"coord": coord,
			"density_generation_ms": density_generation_ms
		}

	var terrain_density_bytes: PackedByteArray = density_payload.get("density_bytes_terrain", PackedByteArray())
	var water_density_bytes: PackedByteArray = density_payload.get("density_bytes_water", PackedByteArray())
	var material_bytes: PackedByteArray = density_payload.get("material_bytes_terrain", PackedByteArray())
	var water_surface_possible := bool(density_payload.get("water_surface_possible", false))
	if not water_surface_possible and store_source_buffers and water_density_bytes.is_empty():
		water_density_bytes = _build_dry_water_density_bytes()

	var mesh_start_us := Time.get_ticks_usec()
	var result_t: Dictionary = {}
	var active_mesh_builder := mesh_builder if mesh_builder != null else _offline_cpu_bake_builder
	if active_mesh_builder == null:
		return {
			"status": "failed",
			"coord": coord,
			"density_backend": str(density_payload.get("density_backend", "")),
			"density_generation_ms": density_generation_ms
		}
	if store_ready_mesh_resources and not defer_store and active_mesh_builder.has_method("build_density_marching_cubes_mesh_collision_height_map"):
		result_t = active_mesh_builder.build_density_marching_cubes_mesh_collision_height_map(
			terrain_density_bytes,
			material_bytes,
			ChunkManagerScript.DENSITY_GRID_SIZE,
			ChunkManagerScript.CHUNK_SIZE,
			ChunkManagerScript.CHUNK_STRIDE
		)
	else:
		result_t = active_mesh_builder.build_density_marching_cubes_mesh_data_height_map(
			terrain_density_bytes,
			material_bytes,
			ChunkManagerScript.DENSITY_GRID_SIZE,
			ChunkManagerScript.CHUNK_SIZE,
			ChunkManagerScript.CHUNK_STRIDE
		)
	var result_w: Dictionary = {}
	if water_surface_possible:
		if store_ready_mesh_resources and not defer_store and active_mesh_builder.has_method("build_density_marching_cubes_mesh_and_collision"):
			result_w = active_mesh_builder.build_density_marching_cubes_mesh_and_collision(
				water_density_bytes,
				material_bytes,
				ChunkManagerScript.DENSITY_GRID_SIZE,
				ChunkManagerScript.CHUNK_SIZE
			)
		elif active_mesh_builder.has_method("build_density_marching_cubes_mesh_data"):
			result_w = active_mesh_builder.build_density_marching_cubes_mesh_data(
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
	var generated_artifact_payload := {
		"artifact_density_bytes_terrain": terrain_density_bytes,
		"artifact_density_bytes_water": water_density_bytes,
		"artifact_material_bytes_terrain": material_bytes
	}
	if defer_store:
		var artifact := _build_parallel_worker_artifact(
			result_t,
			result_w,
			height_map_t,
			terrain_density_bytes,
			water_density_bytes,
			material_bytes
		)
		return {
			"status": "generated_artifact",
			"coord": coord,
			"density_backend": str(density_payload.get("density_backend", "")),
			"density_generation_ms": density_generation_ms,
			"mesh_build_ms": mesh_build_ms,
			"artifact": artifact
		}
	var store_start_us := Time.get_ticks_usec()
	var stored: bool = _manager._store_terrain_artifact_from_generation(
		coord,
		result_t,
		result_w,
		PackedFloat32Array(),
		PackedFloat32Array(),
		height_map_t,
		PackedByteArray(),
		0,
		generated_artifact_payload
	)
	var store_ms := float(Time.get_ticks_usec() - store_start_us) / 1000.0
	return {
		"status": "stored" if stored else "failed",
		"coord": coord,
		"density_backend": str(density_payload.get("density_backend", "")),
		"density_generation_ms": density_generation_ms,
		"mesh_build_ms": mesh_build_ms,
		"store_ms": store_ms
	}


func _build_offline_cpu_density_context() -> Dictionary:
	if _manager == null or not is_instance_valid(_manager):
		return {}
	var biome_width := 0
	var biome_height := 0
	if _manager._world_map_biome_image != null:
		biome_width = int(_manager._world_map_biome_image.get_width())
		biome_height = int(_manager._world_map_biome_image.get_height())
	var road_width := 0
	var road_height := 0
	if _manager._world_map_road_image != null:
		road_width = int(_manager._world_map_road_image.get_width())
		road_height = int(_manager._world_map_road_image.get_height())
	var water_width := 0
	var water_height := 0
	if _manager._world_map_water_image != null:
		water_width = int(_manager._world_map_water_image.get_width())
		water_height = int(_manager._world_map_water_image.get_height())
	return {
		"heightmap_data": _manager._world_map_heightmap_data,
		"heightmap_width": int(_manager._world_map_heightmap_width),
		"heightmap_height": int(_manager._world_map_heightmap_height),
		"biome_data": _manager.gpu_biome_map,
		"biome_width": biome_width,
		"biome_height": biome_height,
		"road_data": _manager._world_map_road_data,
		"road_width": road_width,
		"road_height": road_height,
		"water_data": _manager._world_map_water_data,
		"water_width": water_width,
		"water_height": water_height,
		"excavation_masks": _manager._world_map_excavation_masks.duplicate(true),
		"world_map_half": float(_manager.world_map_half),
		"world_map_max_height": float(_manager.world_map_max_height),
		"water_level": float(_manager.water_level)
	}


func _build_dry_water_density_bytes() -> PackedByteArray:
	var sample_count := ChunkManagerScript.DENSITY_GRID_SIZE * ChunkManagerScript.DENSITY_GRID_SIZE * ChunkManagerScript.DENSITY_GRID_SIZE
	var values := PackedFloat32Array()
	values.resize(sample_count)
	for index in range(sample_count):
		values[index] = 100.0
	return values.to_byte_array()


func _build_parallel_worker_artifact(
	result_t: Dictionary,
	result_w: Dictionary,
	height_map_t: PackedFloat32Array,
	density_bytes_terrain: PackedByteArray,
	density_bytes_water: PackedByteArray,
	material_bytes_terrain: PackedByteArray
) -> Dictionary:
	var terrain_result := _mesh_result_to_parallel_artifact_data(result_t)
	var water_result := _mesh_result_to_parallel_artifact_data(result_w)
	var expected_buffer_bytes := ChunkManagerScript.DENSITY_GRID_SIZE * ChunkManagerScript.DENSITY_GRID_SIZE * ChunkManagerScript.DENSITY_GRID_SIZE * 4
	var artifact_stores_source_buffers := (
		store_source_buffers
		and density_bytes_terrain.size() == expected_buffer_bytes
		and density_bytes_water.size() == expected_buffer_bytes
		and material_bytes_terrain.size() == expected_buffer_bytes
	)
	var artifact := {
		"schema_version": ChunkManagerScript.TERRAIN_ARTIFACT_SCHEMA_VERSION,
		"generator_version": ChunkManagerScript.TERRAIN_GENERATOR_VERSION,
		"mesher_version": ChunkManagerScript.TERRAIN_MESHER_VERSION,
		"artifact_lod_level": ChunkManagerScript.TERRAIN_ARTIFACT_LOD_LEVEL,
		"material_registry_version": MaterialRegistry.MATERIAL_REGISTRY_VERSION,
		"settings_signature": _offline_cpu_artifact_settings_signature,
		"stored_mod_version": 0,
		"edit_signature": "base",
		"result_t": terrain_result,
		"result_w": water_result,
		"height_map_t": height_map_t,
		"source_buffers_stored": artifact_stores_source_buffers
	}
	if artifact_stores_source_buffers:
		artifact["density_bytes_terrain"] = density_bytes_terrain
		artifact["density_bytes_water"] = density_bytes_water
		artifact["material_bytes_terrain"] = material_bytes_terrain
		artifact["cpu_dens_w"] = PackedFloat32Array()
		artifact["cpu_dens_t"] = PackedFloat32Array()
		artifact["cpu_mat_t"] = PackedByteArray()
	artifact["byte_size"] = (
		height_map_t.size() * 4
		+ _estimate_mesh_artifact_result_bytes(terrain_result)
		+ _estimate_mesh_artifact_result_bytes(water_result)
	)
	if artifact_stores_source_buffers:
		artifact["byte_size"] += (
			density_bytes_terrain.size()
			+ density_bytes_water.size()
			+ material_bytes_terrain.size()
		)
	return artifact


func _prepare_parallel_ready_mesh_artifact(artifact: Dictionary) -> void:
	if _manager == null or not is_instance_valid(_manager):
		return
	for result_key in ["result_t", "result_w"]:
		var result_variant: Variant = artifact.get(result_key, {})
		if not (result_variant is Dictionary):
			continue
		var result: Dictionary = result_variant
		if result.get("mesh_resource", null) is ArrayMesh:
			continue
		var materialized: Dictionary = _manager._materialize_deferred_mesh_result(result, null)
		var mesh_variant: Variant = materialized.get("mesh", null)
		if mesh_variant is ArrayMesh and (mesh_variant as ArrayMesh).get_surface_count() > 0:
			materialized["mesh_resource"] = mesh_variant
			materialized["ready_mesh_resource"] = true
		var shape_variant: Variant = materialized.get("shape", null)
		if shape_variant is ConcavePolygonShape3D:
			materialized["shape_resource"] = shape_variant
			materialized["ready_collision_resource"] = true
		artifact[result_key] = materialized


func _mesh_result_to_parallel_artifact_data(mesh_result: Dictionary) -> Dictionary:
	var arrays: Array = mesh_result.get("arrays", [])
	var artifact_result := {
		"deferred_mesh_data": true,
		"arrays": arrays.duplicate(false),
		"faces": PackedVector3Array(),
		"collision_faces_stored": false
	}
	if store_ready_mesh_resources:
		var mesh_variant: Variant = mesh_result.get("mesh", mesh_result.get("mesh_resource", null))
		if mesh_variant is ArrayMesh and (mesh_variant as ArrayMesh).get_surface_count() > 0:
			artifact_result["mesh_resource"] = mesh_variant
			artifact_result["ready_mesh_resource"] = true
		var shape_variant: Variant = mesh_result.get("shape", mesh_result.get("shape_resource", null))
		if shape_variant is ConcavePolygonShape3D:
			artifact_result["shape_resource"] = shape_variant
			artifact_result["ready_collision_resource"] = true
	elif store_collision_faces:
		var faces: PackedVector3Array = mesh_result.get("faces", PackedVector3Array())
		if faces.is_empty() and mesh_result.get("shape", null) is ConcavePolygonShape3D:
			faces = (mesh_result.get("shape", null) as ConcavePolygonShape3D).get_faces()
		if not faces.is_empty():
			artifact_result["faces"] = faces
			artifact_result["collision_faces_stored"] = true
	for key in [
		"source_vertex_count",
		"source_index_count",
		"unique_vertex_count",
		"position_unique_vertex_count",
		"position_material_unique_vertex_count",
		"generated_density"
	]:
		if mesh_result.has(key):
			artifact_result[key] = mesh_result[key]
	return artifact_result


func _estimate_packed_variant_bytes(value: Variant) -> int:
	match typeof(value):
		TYPE_PACKED_BYTE_ARRAY:
			return (value as PackedByteArray).size()
		TYPE_PACKED_INT32_ARRAY:
			return (value as PackedInt32Array).size() * 4
		TYPE_PACKED_INT64_ARRAY:
			return (value as PackedInt64Array).size() * 8
		TYPE_PACKED_FLOAT32_ARRAY:
			return (value as PackedFloat32Array).size() * 4
		TYPE_PACKED_FLOAT64_ARRAY:
			return (value as PackedFloat64Array).size() * 8
		TYPE_PACKED_VECTOR2_ARRAY:
			return (value as PackedVector2Array).size() * 8
		TYPE_PACKED_VECTOR3_ARRAY:
			return (value as PackedVector3Array).size() * 12
		TYPE_PACKED_COLOR_ARRAY:
			return (value as PackedColorArray).size() * 16
		TYPE_ARRAY:
			var total := 0
			for item in value as Array:
				total += _estimate_packed_variant_bytes(item)
			return total
	return 0


func _estimate_mesh_artifact_result_bytes(mesh_result: Dictionary) -> int:
	return (
		_estimate_packed_variant_bytes(mesh_result.get("arrays", []))
		+ _estimate_packed_variant_bytes(mesh_result.get("faces", PackedVector3Array()))
	)


func _build_offline_world_map_density_payload(coord: Vector3i, density_builder: Object = null) -> Dictionary:
	if _manager == null or not is_instance_valid(_manager):
		return {}
	var active_density_builder := density_builder if density_builder != null else _offline_cpu_density_builder
	if (
		active_density_builder != null
		and active_density_builder.has_method("build_world_map_density_payload")
	):
		var context := _offline_cpu_density_context
		if context.is_empty():
			context = _build_offline_cpu_density_context()
		var native_payload: Dictionary = active_density_builder.build_world_map_density_payload(
			context.get("heightmap_data", PackedByteArray()),
			int(context.get("heightmap_width", 0)),
			int(context.get("heightmap_height", 0)),
			context.get("biome_data", PackedByteArray()),
			int(context.get("biome_width", 0)),
			int(context.get("biome_height", 0)),
			context.get("road_data", PackedByteArray()),
			int(context.get("road_width", 0)),
			int(context.get("road_height", 0)),
			context.get("water_data", PackedByteArray()),
			int(context.get("water_width", 0)),
			int(context.get("water_height", 0)),
			(context.get("excavation_masks", {}) as Dictionary).get(coord, PackedByteArray()),
			coord,
			ChunkManagerScript.DENSITY_GRID_SIZE,
			ChunkManagerScript.CHUNK_STRIDE,
			ChunkManagerScript.CHUNK_SIZE,
			float(context.get("world_map_half", 0.0)),
			float(context.get("world_map_max_height", 0.0)),
			float(context.get("water_level", 0.0))
		)
		if not native_payload.is_empty():
			native_payload["density_backend"] = "native"
			return native_payload
	if not Thread.is_main_thread():
		return {}
	var grid_size: int = ChunkManagerScript.DENSITY_GRID_SIZE
	var sample_count := grid_size * grid_size * grid_size
	var terrain_density := PackedFloat32Array()
	var water_density := PackedFloat32Array()
	var material_bytes := PackedByteArray()
	terrain_density.resize(sample_count)
	material_bytes.resize(sample_count * 4)

	var base_x := coord.x * ChunkManagerScript.CHUNK_STRIDE
	var base_y := coord.y * ChunkManagerScript.CHUNK_STRIDE
	var base_z := coord.z * ChunkManagerScript.CHUNK_STRIDE
	var water_surface_possible := _offline_chunk_may_have_water_surface(coord)
	var build_water_density := water_surface_possible or store_source_buffers
	if build_water_density:
		water_density.resize(sample_count)
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
				if build_water_density:
					water_density[index] = _offline_world_map_water_density(world_x, world_y, world_z) if water_surface_possible else 100.0
				material_bytes.encode_u32(index * 4, _offline_world_map_material(world_x, world_y, world_z, material_height))

	return {
		"density_bytes_terrain": terrain_density.to_byte_array(),
		"density_bytes_water": water_density.to_byte_array(),
		"material_bytes_terrain": material_bytes,
		"water_surface_possible": water_surface_possible,
		"density_backend": "gdscript"
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
	if _offline_cpu_parallel_started:
		_offline_cpu_parallel_mutex.lock()
		processed = maxi(processed, _offline_cpu_bake_reused_count + _offline_cpu_parallel_generated_count)
		_offline_cpu_parallel_mutex.unlock()
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
		"coord_mode": "explicit" if _uses_explicit_bake_coords else "origins_radius",
		"explicit_coord_count": _bake_coords.size() if _uses_explicit_bake_coords else 0,
		"radius_chunks": _radius,
		"vertical_layer_radius": vertical_layer_radius,
		"use_disk_radius_shape": use_disk_radius_shape,
		"expected_chunks": expected,
		"requested_chunks": _requested_chunks,
		"ready_chunks_estimate": artifact_count,
		"chunks_ready": artifact_count >= expected,
		"stored_artifact_count": _offline_cpu_bake_stored_count,
		"reused_disk_artifact_count": _offline_cpu_bake_reused_count,
		"native_density_payload_count": _offline_cpu_bake_native_density_count,
		"gdscript_density_payload_count": _offline_cpu_bake_gdscript_density_count,
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
		"offline_cpu_parallel_bake_enabled": offline_cpu_parallel_bake_enabled,
		"offline_cpu_parallel_started": _offline_cpu_parallel_started,
		"offline_cpu_parallel_worker_count": _offline_cpu_parallel_worker_count,
		"offline_cpu_parallel_generated_count": _offline_cpu_parallel_generated_count,
		"offline_cpu_parallel_worker_error_count": _offline_cpu_parallel_worker_error_count,
		"offline_cpu_parallel_wall_ms": _offline_cpu_parallel_wall_ms,
		"offline_cpu_pending_store_count": maxi(_offline_cpu_pending_store_results.size() - _offline_cpu_pending_store_index, 0),
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
		"store_source_buffers": store_source_buffers,
		"store_collision_faces": store_collision_faces,
		"synchronous_disk_writes": true,
		"prefer_offline_cpu_bake": prefer_offline_cpu_bake,
		"require_chunk_finalization_for_manifest": require_chunk_finalization_for_manifest,
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
	var profile := _build_offline_cpu_bake_profile("terrain artifact bake failed") if _offline_cpu_bake_active else _build_profile("terrain artifact bake failed")
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
		"coord_mode": "explicit" if _uses_explicit_bake_coords else "origins_radius",
		"explicit_coord_count": _bake_coords.size() if _uses_explicit_bake_coords else 0,
		"radius_chunks": _radius,
		"vertical_layer_radius": vertical_layer_radius,
		"use_disk_radius_shape": use_disk_radius_shape,
		"expected_chunks": _expected_chunks,
		"artifact_count": int(profile.get("artifact_count", 0)),
		"stored_artifact_count": int(profile.get("stored_artifact_count", 0)),
		"reused_disk_artifact_count": int(profile.get("reused_disk_artifact_count", 0)),
		"store_ready_mesh_resources": store_ready_mesh_resources,
		"store_source_buffers": store_source_buffers,
		"store_collision_faces": store_collision_faces,
		"synchronous_disk_writes": synchronous_disk_writes,
		"prefer_offline_cpu_bake": prefer_offline_cpu_bake,
		"require_chunk_finalization_for_manifest": require_chunk_finalization_for_manifest,
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
	_join_offline_cpu_worker_threads()
	if _root and is_instance_valid(_root):
		_root.queue_free()
	elif _manager != null and is_instance_valid(_manager):
		_manager.free()
	if _viewer != null and is_instance_valid(_viewer) and not _viewer.is_inside_tree():
		_viewer.free()
	_root = null
	_viewer = null
	_manager = null
	_offline_cpu_bake_builder = null
	_offline_cpu_density_builder = null
	_offline_cpu_density_context.clear()
	_offline_cpu_pending_store_results.clear()
	_offline_cpu_pending_store_index = 0


func _clear_manager_bake_pins() -> void:
	if _manager != null and is_instance_valid(_manager) and _manager.has_method("clear_terrain_artifact_bake_pins"):
		_manager.clear_terrain_artifact_bake_pins()


func _count_square_preheat_chunks(radius: int) -> int:
	radius = maxi(radius, 0)
	return (radius * 2 + 1) * (radius * 2 + 1) * 3
