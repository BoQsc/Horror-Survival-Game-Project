extends Node

const WorldMapGenScript := preload("res://world_map_generator/world_map_generator.gd")
const GameScene: PackedScene = preload("res://modules/world_module/world_test_world_player_v2.tscn")
const BuildingAPIScript := preload("res://modules/world_player_v2/api/building_api.gd")
const SAVE_BASE := "user://worlds/"
const TELEPORT_MIN_DISTANCE := 200.0
const TELEPORT_HEIGHT_OFFSET := 8.0
const HOLD_SECONDS := 40.0
const REPEAT_ENTRY_FIRST_HOLD_SECONDS := 20.0
const REPEAT_ENTRY_RETURN_HOLD_SECONDS := 5.0
const REPEAT_ENTRY_SECOND_HOLD_SECONDS := 20.0
const WORLD_READY_TIMEOUT_SECONDS := 300.0
const AUTO_FLY_TIMEOUT_SECONDS := 840.0
const AUTO_FLY_SPEED := 24.0
const AUTO_FLY_ASCEND_MARGIN := 40.0
const AUTO_FLY_ARRIVAL_RADIUS := 12.0
const AUTO_FLY_ENTRY_CAPTURE_BUFFER := 64.0
const FRAME_BUDGET_MS := 1000.0 / 60.0
const TOWN_ENTRY_WINDOW_RECENT_LIMIT := 10
const PERFORMANCE_SNAPSHOT_DIR := "user://debug/performance"
const RENDER_DIAGNOSTIC_DEFAULT_LIMIT := 48
const RENDER_DIAGNOSTIC_DEFAULT_SCENE_DETAIL_LIMIT := 24
const RENDER_DIAGNOSTIC_DEFAULT_FRAME_SCENE_SCAN_LIMIT := 4
const PEAK_ENTRY_SAMPLE_LIMIT := 12
const HOLD_SNAPSHOT_INTERVAL_SECONDS := 5.0
const PREHOLD_SNAPSHOT_INTERVAL_SECONDS := 5.0
const HOLD_STREAM_READY_LOG_INTERVAL_SECONDS := 5.0
const HOLD_SETTLE_STABLE_FRAMES := 30
const HOLD_SETTLE_MAX_SECONDS := 8.0
const HOLD_SETTLE_POSITION_EPSILON := 0.05
const HOLD_SETTLE_VELOCITY_EPSILON := 0.15
const DIRECTIONAL_RENDER_SAMPLE_SECONDS := 4.0
const DIRECTIONAL_RENDER_SETTLE_SECONDS := 0.75

enum Phase {
	GENERATING,
	WAIT_WORLD_READY,
	TELEPORT,
	FLY_TO_TOWN,
	HOLD_FIRST,
	FLY_BACK_TO_ORIGIN,
	HOLD_RETURN,
	FLY_TO_TOWN_SECOND,
	HOLD_SECOND,
	DONE,
	FAILED
}

var phase: Phase = Phase.GENERATING
var phase_time: float = 0.0

var world_generator: WorldMapGenerator = null
var generation_thread: Thread = null
var generated_images: Dictionary = {}
var generated_towns: Array = []
var generated_world_path: String = ""
var generated_seed: int = 0
var selected_town: Dictionary = {}
var hold_started_logged: bool = false
var town_entry_capture_started: bool = false
var _town_entry_samples: Array[Dictionary] = []
var _town_entry_snapshot_stamp: String = ""
var _town_entry_capture_reason: String = ""
var _machine_state: Dictionary = {}
var _scope_states: Dictionary = {}
var _recent_scope_events: Array[Dictionary] = []
var _town_entry_latest_town_state: Dictionary = {}
var _town_entry_latest_entities_state: Dictionary = {}
var _previous_native_town_entry_sample: Dictionary = {}
var _render_diagnostic_samples: Array[Dictionary] = []
var _render_diagnostic_candidate_count: int = 0
var _render_diagnostic_skipped_count: int = 0
var _render_diagnostic_scene_scan_count: int = 0
var _hold_started_sample_index: int = -1
var _hold_completed_sample_index: int = -1
var runtime_mode: String = "unknown"
var auto_teleport_enabled: bool = true
var disable_buildings_enabled: bool = false
var disable_building_objects_enabled: bool = false
var disable_building_blocks_enabled: bool = false
var disable_building_chunk_mesh_render_enabled: bool = false
var disable_building_visual_batches_enabled: bool = false
var disable_building_carve_enabled: bool = false
var disable_building_object_collisions_enabled: bool = false
var disable_building_chunk_flush_enabled: bool = false
var disable_building_chunk_collisions_enabled: bool = false
var disable_terrain_chunk_updates_enabled: bool = false
var disable_terrain_manager_visuals_enabled: bool = false
var disable_vegetation_render_enabled: bool = false
var disable_glow_enabled: bool = false
var disable_water_render_enabled: bool = false
var instant_baked_buildings_enabled: bool = true
var baked_building_persistence_smoke_enabled: bool = false
var baked_building_persistence_smoke_started: bool = false
var baked_building_persistence_smoke_running: bool = false
var baked_building_persistence_smoke_timeout_seconds: float = 60.0
var baked_building_persistence_smoke_load_completed: bool = false
var baked_building_persistence_smoke_load_success: bool = false
var baked_building_persistence_smoke_load_path: String = ""
var disable_entities_enabled: bool = false
var repeat_entry_enabled: bool = false
var render_diagnostics_enabled: bool = false
var render_diagnostics_scene_scan_enabled: bool = false
var render_diagnostics_threshold_ms: float = FRAME_BUDGET_MS
var render_diagnostics_sample_limit: int = RENDER_DIAGNOSTIC_DEFAULT_LIMIT
var render_diagnostics_scene_detail_limit: int = RENDER_DIAGNOSTIC_DEFAULT_SCENE_DETAIL_LIMIT
var render_diagnostics_frame_scene_scan_limit: int = RENDER_DIAGNOSTIC_DEFAULT_FRAME_SCENE_SCAN_LIMIT
var directional_render_sampling_enabled: bool = false
var directional_render_sample_seconds: float = DIRECTIONAL_RENDER_SAMPLE_SECONDS
var directional_render_settle_seconds: float = DIRECTIONAL_RENDER_SETTLE_SECONDS
var directional_render_current_label: String = ""
var directional_render_current_segment_index: int = -1
var directional_render_started: bool = false
var directional_render_base_yaw: float = 0.0
var low_fps_abort_enabled: bool = true
var low_fps_abort_frame_ms: float = 120.0
var low_fps_abort_seconds: float = 8.0
var low_fps_abort_elapsed_seconds: float = 0.0
var low_fps_abort_sample_count: int = 0
var low_fps_abort_peak_ms: float = 0.0
var measure_full_flight_enabled: bool = false
var world_ready_timeout_seconds: float = WORLD_READY_TIMEOUT_SECONDS
var world_ready_status_log_interval_seconds: float = 5.0
var world_ready_last_status_log_seconds: float = -1000000.0
var configured_hold_seconds: float = HOLD_SECONDS
var fly_stage: int = 0
var fly_target: Vector3 = Vector3.ZERO
var fly_target_altitude: float = 0.0
var return_origin: Vector3 = Vector3.ZERO
var current_hold_seconds: float = HOLD_SECONDS
var next_hold_snapshot_phase_time: float = -1.0
var hold_periodic_snapshots_enabled: bool = false
var prehold_periodic_snapshots_enabled: bool = false
var prehold_snapshot_interval_seconds: float = PREHOLD_SNAPSHOT_INTERVAL_SECONDS
var next_prehold_snapshot_elapsed_seconds: float = -1.0
var town_entry_capture_elapsed_seconds: float = 0.0
var prehold_snapshot_write_count: int = 0
var last_prehold_snapshot_elapsed_seconds: float = -1.0
var hold_wait_stream_ready_enabled: bool = true
var hold_stream_ready_wait_logged: bool = false
var hold_stream_ready_last_log_seconds: float = -1000000.0
var hold_stream_ready_last_blockers: String = ""
var hold_settle_elapsed_seconds: float = 0.0
var hold_settle_stable_frames: int = 0
var hold_settle_timed_out: bool = false
var hold_settle_wait_logged: bool = false
var hold_settle_last_player_position: Vector3 = Vector3(1.0e20, 1.0e20, 1.0e20)

var game_root: Node3D = null
var terrain_manager: Node = null
var building_manager: Node = null
var entity_manager: Node = null
var vegetation_manager: Node = null
var chunk_manager: Node = null
var player: WorldPlayerV2 = null
var mode_manager: Node = null
var mode_editor: Node = null
var movement_component: Node = null
var loading_screen: Node = null
var pending_quit: bool = false
var pending_town_spawn_requested: bool = false
var pending_town_teleport_pos: Vector3 = Vector3.ZERO
var town_spawn_ready_settle_frames: int = 0
var town_terrain_stable_frames: int = 0
var town_terrain_stability_signature: String = ""
var town_entity_stable_frames: int = 0
var town_entity_stability_signature: String = ""

func _get_town_stall_seed() -> int:
	var seed_text := OS.get_environment("TOWN_STALL_SEED")
	if seed_text.is_valid_int():
		return int(seed_text)
	return 12345


func _get_dominant_bucket(bucket_counts: Dictionary) -> Dictionary:
	var dominant_bucket := "Unknown"
	var dominant_count := 0
	for bucket_variant in bucket_counts.keys():
		var bucket := str(bucket_variant)
		var count := int(bucket_counts.get(bucket_variant, 0))
		if count > dominant_count:
			dominant_bucket = bucket
			dominant_count = count
	return {
		"bucket": dominant_bucket,
		"count": dominant_count
	}


func _make_timestamp_slug() -> String:
	var timestamp := Time.get_datetime_string_from_system(true, true)
	return timestamp.replace(":", "-").replace(" ", "_").replace("/", "-")


func _parse_machine_state_env() -> Dictionary:
	var raw_state := OS.get_environment("TOWN_STALL_MACHINE_STATE_JSON").strip_edges()
	if raw_state.is_empty():
		return {}

	var parsed_state: Variant = JSON.parse_string(raw_state)
	if typeof(parsed_state) != TYPE_DICTIONARY:
		return {}

	return parsed_state


func _format_machine_state_summary(machine_state: Dictionary) -> String:
	if machine_state.is_empty():
		return "unavailable"

	var cpu_name := str(machine_state.get("cpu_name", "Unknown"))
	var current_clock_mhz := int(machine_state.get("current_clock_mhz", 0))
	var max_clock_mhz := int(machine_state.get("max_clock_mhz", 0))
	var processor_frequency_mhz := int(machine_state.get("processor_frequency_mhz", 0))
	var percent_processor_performance := int(machine_state.get("percent_processor_performance", 0))
	var percent_max_frequency := int(machine_state.get("percent_max_frequency", 0))
	var load_percentage := int(machine_state.get("load_percentage", 0))
	var estimated_effective_clock_mhz := int(machine_state.get("estimated_effective_clock_mhz", 0))
	var thermal_state := str(machine_state.get("thermal_state", "unavailable"))
	var thermal_c_variant: Variant = machine_state.get("thermal_c", null)
	var thermal_text := thermal_state
	if thermal_c_variant != null:
		thermal_text = "%s (%.1f C)" % [thermal_state, float(thermal_c_variant)]

	return "%s | current=%d MHz max=%d MHz freq=%d MHz perf=%d%% max=%d%% load=%d%% eff~%d MHz thermal=%s" % [
		cpu_name,
		current_clock_mhz,
		max_clock_mhz,
		processor_frequency_mhz,
		percent_processor_performance,
		percent_max_frequency,
		load_percentage,
		estimated_effective_clock_mhz,
		thermal_text
	]


func _get_positive_env_float(env_name: String, default_value: float) -> float:
	var raw_value := OS.get_environment(env_name).strip_edges()
	if raw_value.is_empty():
		return default_value

	if not raw_value.is_valid_float():
		return default_value

	var parsed_value := float(raw_value)
	if parsed_value <= 0.0:
		return default_value

	return parsed_value


func _get_positive_env_int(env_name: String, default_value: int) -> int:
	var raw_value := OS.get_environment(env_name).strip_edges()
	if raw_value.is_empty():
		return default_value

	if not raw_value.is_valid_int():
		return default_value

	var parsed_value := int(raw_value)
	if parsed_value <= 0:
		return default_value

	return parsed_value


func _emit_scope_state(scope: String, payload: Dictionary) -> void:
	if scope.is_empty():
		return

	var state := payload.duplicate(true)
	var frame_number := _get_current_frame_number()
	state["frame"] = frame_number
	state["timestamp"] = Time.get_ticks_msec()
	state["epoch"] = Time.get_unix_time_from_system()
	_scope_states[scope] = state
	if scope == "town" or scope == "town_stall_test":
		_town_entry_latest_town_state = state.duplicate(true)
	elif scope == "entities":
		_town_entry_latest_entities_state = state.duplicate(true)


func _emit_scope_event(scope: String, event_name: String, payload: Dictionary) -> void:
	if scope.is_empty() or event_name.is_empty():
		return

	var event := {
		"scope": scope,
		"label": event_name,
		"frame": _get_current_frame_number(),
		"timestamp": Time.get_ticks_msec(),
		"epoch": Time.get_unix_time_from_system()
	}
	if not payload.is_empty():
		event["details"] = payload.duplicate(true)

	_recent_scope_events.append(event)
	if _recent_scope_events.size() > 64:
		_recent_scope_events.pop_front()


func _reset_town_measurement_window(reason: String) -> void:
	_town_entry_samples.clear()
	_previous_native_town_entry_sample.clear()
	_render_diagnostic_samples.clear()
	_hold_started_sample_index = -1
	_hold_completed_sample_index = -1
	_reset_directional_render_sampling_state()
	_scope_states.clear()
	_recent_scope_events.clear()
	_town_entry_snapshot_stamp = ""
	_town_entry_capture_reason = reason
	town_entry_capture_started = true
	town_entry_capture_elapsed_seconds = 0.0
	prehold_snapshot_write_count = 0
	last_prehold_snapshot_elapsed_seconds = -1.0
	next_prehold_snapshot_elapsed_seconds = prehold_snapshot_interval_seconds if prehold_periodic_snapshots_enabled else -1.0
	_town_entry_latest_town_state.clear()
	_town_entry_latest_entities_state.clear()
	_emit_scope_state("town_stall_test", {
		"phase": "measurement_reset",
		"reason": reason,
		"world_path": generated_world_path
	})
	_emit_scope_event("town_stall_test", "measurement_reset", {
		"reason": reason,
		"world_path": generated_world_path
	})


func _get_current_frame_number() -> int:
	if Engine.has_method("get_process_frames"):
		return int(Engine.get_process_frames())
	return _town_entry_samples.size() + 1


func _capture_native_town_entry_sample(delta: float) -> void:
	if not town_entry_capture_started or pending_quit:
		return

	var sample := _build_native_town_entry_sample(delta)
	if sample.is_empty():
		return

	_enrich_sample_with_previous_delta(sample)
	_town_entry_samples.append(sample)
	_capture_render_diagnostic_sample(sample)
	_previous_native_town_entry_sample = sample.duplicate(false)
	town_entry_capture_elapsed_seconds += maxf(delta, 0.0)
	_maybe_write_prehold_snapshot()
	_check_low_fps_abort(sample)


func _check_low_fps_abort(sample: Dictionary) -> void:
	if not low_fps_abort_enabled or pending_quit:
		return

	var total_ms := float(sample.get("total_ms", 0.0))
	if total_ms >= low_fps_abort_frame_ms:
		low_fps_abort_elapsed_seconds += total_ms / 1000.0
		low_fps_abort_sample_count += 1
		low_fps_abort_peak_ms = maxf(low_fps_abort_peak_ms, total_ms)
	else:
		low_fps_abort_elapsed_seconds = 0.0
		low_fps_abort_sample_count = 0
		low_fps_abort_peak_ms = 0.0
		return

	if low_fps_abort_elapsed_seconds < low_fps_abort_seconds:
		return

	print("[TOWN_STALL_TEST] Low-FPS safety abort: %.1fs over %.1fms/frame, peak %.1fms" % [
		low_fps_abort_elapsed_seconds,
		low_fps_abort_frame_ms,
		low_fps_abort_peak_ms
	])
	_emit_scope_event("town_stall_test", "low_fps_safety_abort", {
		"elapsed_seconds": low_fps_abort_elapsed_seconds,
		"sample_count": low_fps_abort_sample_count,
		"threshold_ms": low_fps_abort_frame_ms,
		"peak_ms": low_fps_abort_peak_ms,
		"phase": str(phase)
	})
	_begin_shutdown()


func _build_native_town_entry_sample(delta: float) -> Dictionary:
	var frame_number := _get_current_frame_number()
	var fps := float(Performance.get_monitor(Performance.TIME_FPS))
	var total_ms := maxf(delta * 1000.0, 0.0)
	var process_monitor_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var navigation_ms := Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var primitives := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var vram_mb := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0)
	var pipeline_compilations := _collect_pipeline_compilation_monitor_snapshot()
	var monitor_sum_ms := process_monitor_ms + physics_ms + navigation_ms
	var other_ms := maxf(0.0, total_ms - monitor_sum_ms)
	var top_measure := _resolve_native_top_measure(total_ms, process_monitor_ms, physics_ms, navigation_ms, other_ms, draw_calls)
	var terrain_active_chunk_count := 0
	var terrain_native_grid_active_chunk_count := 0
	var terrain_pending_node_count := 0
	var terrain_last_pending_node_sort_ms := 0.0
	var terrain_last_pending_node_sort_count := 0
	var terrain_last_pending_node_sort_skipped := false
	var terrain_pending_collision_create_count := 0
	var terrain_last_gpu_generation_dispatch_ms := 0.0
	var terrain_last_gpu_generation_dispatch_coord := ""
	var terrain_last_gpu_generation_mod_sync_ms := 0.0
	var terrain_last_gpu_generation_batch_ms := 0.0
	var terrain_last_gpu_generation_batch_chunk_count := 0
	var terrain_last_gpu_generation_sync_ms := 0.0
	var terrain_last_gpu_meshing_dispatch_ms := 0.0
	var terrain_last_gpu_meshing_sync_ms := 0.0
	var terrain_last_gpu_mesh_readback_ms := 0.0
	var terrain_last_gpu_mesh_readback_chunk_count := 0
	var terrain_last_gpu_mesh_readback_terrain_vertices := 0
	var terrain_last_gpu_mesh_readback_water_vertices := 0
	var terrain_last_gpu_mesh_slice_count := 0
	var terrain_last_gpu_mesh_slice_max_sync_ms := 0.0
	var terrain_last_gpu_generation_batch_event_id := 0
	var terrain_last_cpu_mesh_build_ms := 0.0
	var terrain_last_cpu_mesh_build_terrain_ms := 0.0
	var terrain_last_cpu_mesh_build_water_ms := 0.0
	var terrain_last_cpu_mesh_build_queue_wait_ms := 0.0
	var terrain_last_cpu_mesh_build_terrain_vertices := 0
	var terrain_last_cpu_mesh_build_water_vertices := 0
	var terrain_last_cpu_mesh_build_coord := ""
	var terrain_last_cpu_mesh_build_event_id := 0
	var terrain_last_finalize_terrain_ms := 0.0
	var terrain_last_pending_node_process_ms := 0.0
	var terrain_last_collision_create_ms := 0.0
	var terrain_last_collision_create_count := 0
	var terrain_last_collision_proximity_update_ms := 0.0
	var terrain_last_collision_proximity_enable_count := 0
	var terrain_last_collision_proximity_disable_count := 0
	var terrain_last_collision_proximity_prewarm_queued := 0
	var terrain_collision_space_attached_chunk_count := 0
	var terrain_shared_collision_body_enabled := false
	var terrain_shared_collision_shape_count := 0
	var terrain_shared_collision_cluster_body_count := 0
	var terrain_collision_body_cache_count := 0
	var terrain_collision_body_cache_hits := 0
	var terrain_collision_body_cache_misses := 0
	var terrain_collision_body_cache_stores := 0
	var terrain_last_update_loads := 0
	var terrain_last_update_unloads := 0
	var terrain_last_fallback_unloads := 0
	var terrain_last_fallback_unload_ms := 0.0
	var terrain_last_world_map_lod_loads := 0
	var terrain_last_world_map_lod_unloads := 0
	var terrain_last_world_map_lod_update_ms := 0.0
	var terrain_runtime_power_world_work_suspended := false
	var terrain_runtime_power_render_loop_suspended := false
	var terrain_runtime_power_world_work_suspended_frame_count := 0
	var building_dirty_visible_chunk_count := 0
	var building_last_flush_dirty_chunks_ms := 0.0
	var building_last_apply_payload_ms := 0.0
	var building_last_apply_payload_object_ms := 0.0
	var building_last_apply_payload_visual_ms := 0.0
	var building_pending_baked_apply_phases := 0
	var building_last_baked_apply_queue_ms := 0.0
	var building_last_baked_apply_queue_count := 0
	var building_pending_visual_batch_rebuilds := 0
	var building_pending_baked_object_spawns := 0
	var building_last_baked_object_spawn_queue_ms := 0.0
	var building_last_baked_object_spawn_queue_count := 0
	var building_last_visibility_update_ms := 0.0
	var building_last_visibility_added := 0
	var building_last_visibility_removed := 0
	var building_last_visibility_target_visible := 0
	var building_last_visibility_total_roots := 0
	var building_visible_baked_visual_nodes := 0
	var building_visible_baked_visual_surfaces := 0
	var prefab_pending_baked_payload_build_jobs := 0
	var prefab_pending_baked_payload_jobs := 0
	var prefab_last_baked_payload_build_queue_ms := 0.0
	var prefab_last_baked_payload_build_queue_count := 0
	var prefab_last_baked_payload_build_queue_success_count := 0
	var prefab_last_baked_payload_apply_ms := 0.0
	var prefab_last_baked_payload_apply_count := 0
	var prefab_last_baked_payload_flush_ms := 0.0
	var entity_active_entities := 0
	var entity_frozen_entities := 0
	var entity_pending_spawns := 0
	var entity_dormant_entities := 0
	var entity_spawned_chunks := 0
	var entity_last_proximity_update_ms := 0.0
	var entity_last_spawn_queue_update_ms := 0.0
	var entity_last_spawn_queue_spawned := 0
	var terrain_visual_batch_node_count := 0
	var terrain_visual_batch_dirty_count := 0
	var terrain_last_visual_batch_rebuild_ms := 0.0
	var terrain_last_visual_batch_rebuild_count := 0
	var terrain_last_visual_batch_hidden_chunk_count := 0
	var terrain_last_visual_batch_vertex_count := 0
	var terrain_last_visual_batch_index_count := 0
	var terrain_last_visual_batch_skipped_heavy_count := 0
	var terrain_visual_batch_total_heavy_skips := 0
	var terrain_visual_batch_mesh_cache_count := 0
	var terrain_visual_batch_mesh_cache_hits := 0
	var terrain_visual_batch_mesh_cache_misses := 0
	var terrain_last_visual_batch_cached_rebuild_count := 0
	var terrain_last_visual_batch_cached_rebuild_ms := 0.0
	var terrain_last_visual_batch_cached_rebuild_attempts := 0
	var terrain_visual_batch_async_in_flight_count := 0
	var terrain_visual_batch_async_completed_count := 0
	var terrain_last_visual_batch_async_queued_count := 0
	var terrain_last_visual_batch_streaming_async_queued_count := 0
	var terrain_last_visual_batch_async_apply_count := 0
	var terrain_last_visual_batch_async_apply_ms := 0.0
	var terrain_last_visual_batch_async_stale_count := 0
	var terrain_visual_batch_stream_idle_frames := 0
	var vegetation_global_render_batch_count := 0
	var vegetation_last_global_render_sync_ms := 0.0
	var vegetation_last_global_render_collect_ms := 0.0
	var vegetation_last_global_render_pack_ms := 0.0
	var vegetation_last_global_render_sync_kind := ""
	var vegetation_last_global_render_sync_chunk_count := 0
	var vegetation_last_global_render_candidate_chunk_count := 0
	var vegetation_last_global_render_sync_instance_count := 0
	var vegetation_last_global_render_upload_bytes := 0
	var vegetation_max_global_render_upload_bytes := 0
	var vegetation_global_render_dirty_kind_count := 0
	if is_instance_valid(terrain_manager):
		terrain_active_chunk_count = int(terrain_manager.active_chunks.size())
		terrain_native_grid_active_chunk_count = int(terrain_manager._last_native_grid_active_chunk_count)
		terrain_pending_node_count = int(terrain_manager.pending_nodes.size())
		terrain_last_pending_node_sort_ms = float(terrain_manager._last_pending_node_sort_ms)
		terrain_last_pending_node_sort_count = int(terrain_manager._last_pending_node_sort_count)
		terrain_last_pending_node_sort_skipped = bool(terrain_manager._last_pending_node_sort_skipped)
		terrain_pending_collision_create_count = int(terrain_manager.pending_terrain_collision_creates.size())
		terrain_last_gpu_generation_dispatch_ms = float(terrain_manager._last_gpu_generation_dispatch_ms)
		terrain_last_gpu_generation_dispatch_coord = str(terrain_manager._last_gpu_generation_dispatch_coord)
		terrain_last_gpu_generation_mod_sync_ms = float(terrain_manager._last_gpu_generation_mod_sync_ms)
		terrain_last_gpu_generation_batch_ms = float(terrain_manager._last_gpu_generation_batch_ms)
		terrain_last_gpu_generation_batch_chunk_count = int(terrain_manager._last_gpu_generation_batch_chunk_count)
		terrain_last_gpu_generation_sync_ms = float(terrain_manager._last_gpu_generation_sync_ms)
		terrain_last_gpu_meshing_dispatch_ms = float(terrain_manager._last_gpu_meshing_dispatch_ms)
		terrain_last_gpu_meshing_sync_ms = float(terrain_manager._last_gpu_meshing_sync_ms)
		terrain_last_gpu_mesh_readback_ms = float(terrain_manager._last_gpu_mesh_readback_ms)
		terrain_last_gpu_mesh_readback_chunk_count = int(terrain_manager._last_gpu_mesh_readback_chunk_count)
		terrain_last_gpu_mesh_readback_terrain_vertices = int(terrain_manager._last_gpu_mesh_readback_terrain_vertices)
		terrain_last_gpu_mesh_readback_water_vertices = int(terrain_manager._last_gpu_mesh_readback_water_vertices)
		terrain_last_gpu_mesh_slice_count = int(terrain_manager._last_gpu_mesh_slice_count)
		terrain_last_gpu_mesh_slice_max_sync_ms = float(terrain_manager._last_gpu_mesh_slice_max_sync_ms)
		terrain_last_gpu_generation_batch_event_id = int(terrain_manager._last_gpu_generation_batch_event_id)
		terrain_last_cpu_mesh_build_ms = float(terrain_manager._last_cpu_mesh_build_ms)
		terrain_last_cpu_mesh_build_terrain_ms = float(terrain_manager._last_cpu_mesh_build_terrain_ms)
		terrain_last_cpu_mesh_build_water_ms = float(terrain_manager._last_cpu_mesh_build_water_ms)
		terrain_last_cpu_mesh_build_queue_wait_ms = float(terrain_manager._last_cpu_mesh_build_queue_wait_ms)
		terrain_last_cpu_mesh_build_terrain_vertices = int(terrain_manager._last_cpu_mesh_build_terrain_vertices)
		terrain_last_cpu_mesh_build_water_vertices = int(terrain_manager._last_cpu_mesh_build_water_vertices)
		terrain_last_cpu_mesh_build_coord = str(terrain_manager._last_cpu_mesh_build_coord)
		terrain_last_cpu_mesh_build_event_id = int(terrain_manager._last_cpu_mesh_build_event_id)
		terrain_last_finalize_terrain_ms = float(terrain_manager._last_finalize_terrain_ms)
		terrain_last_pending_node_process_ms = float(terrain_manager._last_pending_node_process_ms)
		terrain_last_collision_create_ms = float(terrain_manager._last_terrain_collision_create_ms)
		terrain_last_collision_create_count = int(terrain_manager._last_terrain_collision_create_count)
		terrain_last_collision_proximity_update_ms = float(terrain_manager._last_collision_proximity_update_ms)
		terrain_last_collision_proximity_enable_count = int(terrain_manager._last_collision_proximity_enable_count)
		terrain_last_collision_proximity_disable_count = int(terrain_manager._last_collision_proximity_disable_count)
		terrain_last_collision_proximity_prewarm_queued = int(terrain_manager._last_collision_proximity_prewarm_queued)
		terrain_collision_space_attached_chunk_count = int(terrain_manager._terrain_collision_space_attached_coords.size())
		terrain_shared_collision_body_enabled = bool(terrain_manager.shared_terrain_collision_body_enabled)
		terrain_shared_collision_shape_count = int(terrain_manager._shared_terrain_collision_shape_coords.size())
		terrain_shared_collision_cluster_body_count = int(terrain_manager._shared_terrain_collision_cluster_bodies.size())
		terrain_collision_body_cache_count = int(terrain_manager._terrain_collision_body_cache.size())
		terrain_collision_body_cache_hits = int(terrain_manager._terrain_collision_body_cache_hits)
		terrain_collision_body_cache_misses = int(terrain_manager._terrain_collision_body_cache_misses)
		terrain_collision_body_cache_stores = int(terrain_manager._terrain_collision_body_cache_stores)
		terrain_last_update_loads = int(terrain_manager._last_update_loads)
		terrain_last_update_unloads = int(terrain_manager._last_update_unloads)
		terrain_last_fallback_unloads = int(terrain_manager._last_fallback_unloads)
		terrain_last_fallback_unload_ms = float(terrain_manager._last_fallback_unload_ms)
		terrain_last_world_map_lod_loads = int(terrain_manager._last_world_map_lod_loads)
		terrain_last_world_map_lod_unloads = int(terrain_manager._last_world_map_lod_unloads)
		terrain_last_world_map_lod_update_ms = float(terrain_manager._last_world_map_lod_update_ms)
		if terrain_manager.has_method("is_world_work_suspended"):
			terrain_runtime_power_world_work_suspended = bool(terrain_manager.is_world_work_suspended())
		if "_runtime_power_render_loop_suspended" in terrain_manager:
			terrain_runtime_power_render_loop_suspended = bool(terrain_manager._runtime_power_render_loop_suspended)
		if "_runtime_power_world_work_suspended_frame_count" in terrain_manager:
			terrain_runtime_power_world_work_suspended_frame_count = int(terrain_manager._runtime_power_world_work_suspended_frame_count)
		terrain_visual_batch_node_count = int(terrain_manager._terrain_visual_batches.size())
		terrain_visual_batch_dirty_count = int(terrain_manager._terrain_visual_batch_dirty.size())
		terrain_last_visual_batch_rebuild_ms = float(terrain_manager._last_terrain_visual_batch_rebuild_ms)
		terrain_last_visual_batch_rebuild_count = int(terrain_manager._last_terrain_visual_batch_rebuild_count)
		terrain_last_visual_batch_hidden_chunk_count = int(terrain_manager._last_terrain_visual_batch_hidden_chunk_count)
		terrain_last_visual_batch_vertex_count = int(terrain_manager._last_terrain_visual_batch_vertex_count)
		terrain_last_visual_batch_index_count = int(terrain_manager._last_terrain_visual_batch_index_count)
		terrain_last_visual_batch_skipped_heavy_count = int(terrain_manager._last_terrain_visual_batch_skipped_heavy_count)
		terrain_visual_batch_total_heavy_skips = int(terrain_manager._terrain_visual_batch_total_heavy_skips)
		terrain_visual_batch_mesh_cache_count = int(terrain_manager._terrain_visual_batch_mesh_cache.size())
		terrain_visual_batch_mesh_cache_hits = int(terrain_manager._terrain_visual_batch_mesh_cache_hits)
		terrain_visual_batch_mesh_cache_misses = int(terrain_manager._terrain_visual_batch_mesh_cache_misses)
		terrain_last_visual_batch_cached_rebuild_count = int(terrain_manager._last_terrain_visual_batch_cached_rebuild_count)
		terrain_last_visual_batch_cached_rebuild_ms = float(terrain_manager._last_terrain_visual_batch_cached_rebuild_ms)
		terrain_last_visual_batch_cached_rebuild_attempts = int(terrain_manager._last_terrain_visual_batch_cached_rebuild_attempts)
		terrain_visual_batch_async_in_flight_count = int(terrain_manager._terrain_visual_batch_builds_in_flight.size())
		terrain_visual_batch_async_completed_count = int(terrain_manager._completed_terrain_visual_batch_builds.size())
		terrain_last_visual_batch_async_queued_count = int(terrain_manager._last_terrain_visual_batch_async_queued_count)
		terrain_last_visual_batch_streaming_async_queued_count = int(terrain_manager._last_terrain_visual_batch_streaming_async_queued_count)
		terrain_last_visual_batch_async_apply_count = int(terrain_manager._last_terrain_visual_batch_async_apply_count)
		terrain_last_visual_batch_async_apply_ms = float(terrain_manager._last_terrain_visual_batch_async_apply_ms)
		terrain_last_visual_batch_async_stale_count = int(terrain_manager._last_terrain_visual_batch_async_stale_count)
		terrain_visual_batch_stream_idle_frames = int(terrain_manager._terrain_visual_batch_stream_idle_frames)
	if not is_instance_valid(building_manager):
		building_manager = _find_manager_node("building_manager", "BuildingManager")
	if is_instance_valid(building_manager):
		building_dirty_visible_chunk_count = int(building_manager._dirty_visible_chunk_count)
		building_last_flush_dirty_chunks_ms = float(building_manager._last_flush_dirty_chunks_ms)
		building_last_apply_payload_ms = float(building_manager._last_apply_world_map_baked_building_payload_ms)
		building_last_apply_payload_object_ms = float(building_manager._last_apply_world_map_baked_building_payload_object_ms)
		building_last_apply_payload_visual_ms = float(building_manager._last_apply_world_map_baked_building_visual_ms)
		if "_pending_world_map_baked_building_apply_phases" in building_manager:
			building_pending_baked_apply_phases = int(building_manager._pending_world_map_baked_building_apply_phases.size())
		if "_last_world_map_baked_building_apply_queue_ms" in building_manager:
			building_last_baked_apply_queue_ms = float(building_manager._last_world_map_baked_building_apply_queue_ms)
		if "_last_world_map_baked_building_apply_queue_count" in building_manager:
			building_last_baked_apply_queue_count = int(building_manager._last_world_map_baked_building_apply_queue_count)
		building_pending_visual_batch_rebuilds = int(building_manager._dirty_global_visual_batch_object_ids.size())
		building_pending_baked_object_spawns = int(building_manager._pending_world_map_baked_object_spawns.size())
		building_last_baked_object_spawn_queue_ms = float(building_manager._last_world_map_baked_object_spawn_queue_ms)
		building_last_baked_object_spawn_queue_count = int(building_manager._last_world_map_baked_object_spawn_queue_count)
		building_last_visibility_update_ms = float(building_manager._last_world_map_baked_visibility_update_ms)
		building_last_visibility_added = int(building_manager._last_world_map_baked_visibility_added)
		building_last_visibility_removed = int(building_manager._last_world_map_baked_visibility_removed)
		building_last_visibility_target_visible = int(building_manager._last_world_map_baked_visibility_target_visible)
		building_last_visibility_total_roots = int(building_manager._last_world_map_baked_visibility_total_roots)
		building_visible_baked_visual_nodes = int(building_manager._count_visible_world_map_baked_building_visual_nodes())
		building_visible_baked_visual_surfaces = int(building_manager._count_visible_world_map_baked_building_visual_surfaces())
	var prefab_spawner_node := _find_manager_node("prefab_spawner", "PrefabSpawner")
	if is_instance_valid(prefab_spawner_node):
		if "_pending_world_map_baked_building_payload_builds" in prefab_spawner_node:
			prefab_pending_baked_payload_build_jobs = int(prefab_spawner_node._pending_world_map_baked_building_payload_builds.size())
		prefab_pending_baked_payload_jobs = int(prefab_spawner_node._pending_world_map_baked_building_payloads.size())
		if "_last_world_map_baked_payload_build_queue_ms" in prefab_spawner_node:
			prefab_last_baked_payload_build_queue_ms = float(prefab_spawner_node._last_world_map_baked_payload_build_queue_ms)
		if "_last_world_map_baked_payload_build_queue_count" in prefab_spawner_node:
			prefab_last_baked_payload_build_queue_count = int(prefab_spawner_node._last_world_map_baked_payload_build_queue_count)
		if "_last_world_map_baked_payload_build_queue_success_count" in prefab_spawner_node:
			prefab_last_baked_payload_build_queue_success_count = int(prefab_spawner_node._last_world_map_baked_payload_build_queue_success_count)
		prefab_last_baked_payload_apply_ms = float(prefab_spawner_node._last_world_map_baked_payload_apply_ms)
		prefab_last_baked_payload_apply_count = int(prefab_spawner_node._last_world_map_baked_payload_apply_count)
		prefab_last_baked_payload_flush_ms = float(prefab_spawner_node._last_world_map_baked_payload_flush_ms)
	if not is_instance_valid(vegetation_manager):
		vegetation_manager = _find_manager_node("vegetation_manager", "VegetationManager")
	if is_instance_valid(vegetation_manager):
		vegetation_global_render_batch_count = int(vegetation_manager._get_global_render_batch_count())
		vegetation_last_global_render_sync_ms = float(vegetation_manager._last_global_render_sync_ms)
		vegetation_last_global_render_collect_ms = float(vegetation_manager._last_global_render_collect_ms)
		vegetation_last_global_render_pack_ms = float(vegetation_manager._last_global_render_pack_ms)
		vegetation_last_global_render_sync_kind = str(vegetation_manager._last_global_render_sync_kind)
		vegetation_last_global_render_sync_chunk_count = int(vegetation_manager._last_global_render_sync_chunk_count)
		vegetation_last_global_render_candidate_chunk_count = int(vegetation_manager._last_global_render_candidate_chunk_count)
		vegetation_last_global_render_sync_instance_count = int(vegetation_manager._last_global_render_sync_instance_count)
		vegetation_last_global_render_upload_bytes = int(vegetation_manager._last_global_render_upload_bytes)
		vegetation_max_global_render_upload_bytes = int(vegetation_manager._max_global_render_upload_bytes)
		vegetation_global_render_dirty_kind_count = int(vegetation_manager._get_global_render_dirty_kinds().size())
	if not is_instance_valid(entity_manager):
		entity_manager = _find_manager_node("entity_manager", "EntityManager")
	if is_instance_valid(entity_manager):
		entity_active_entities = int(entity_manager.active_entities.size())
		entity_frozen_entities = int(entity_manager.frozen_entities.size())
		entity_pending_spawns = int(entity_manager.pending_spawns.size())
		entity_dormant_entities = int(entity_manager.dormant_entities.size())
		entity_spawned_chunks = int(entity_manager.spawned_chunks.size())
		entity_last_proximity_update_ms = float(entity_manager._last_proximity_update_ms)
		entity_last_spawn_queue_update_ms = float(entity_manager._last_spawn_queue_update_ms)
		entity_last_spawn_queue_spawned = int(entity_manager._last_spawn_queue_spawned)

	return {
		"frame": frame_number,
		"epoch": Time.get_unix_time_from_system(),
		"directional_render_label": directional_render_current_label if directional_render_sampling_enabled else "",
		"directional_render_segment_index": directional_render_current_segment_index if directional_render_sampling_enabled else -1,
		"fps": fps,
		"total_ms": total_ms,
		"frame_delta_ms": total_ms,
		"process_monitor_ms": process_monitor_ms,
		"monitor_sum_ms": monitor_sum_ms,
		"monitor_exceeds_frame_ms": maxf(0.0, monitor_sum_ms - total_ms),
		"draw_calls": draw_calls,
		"objects": objects,
		"primitives": primitives,
		"physics_ms": physics_ms,
		"navigation_ms": navigation_ms,
		"vram_mb": vram_mb,
		"pipeline_compilations_canvas": int(pipeline_compilations.get("canvas", 0)),
		"pipeline_compilations_mesh": int(pipeline_compilations.get("mesh", 0)),
		"pipeline_compilations_surface": int(pipeline_compilations.get("surface", 0)),
		"pipeline_compilations_draw": int(pipeline_compilations.get("draw", 0)),
		"pipeline_compilations_specialization": int(pipeline_compilations.get("specialization", 0)),
		"pipeline_compilations_total": int(pipeline_compilations.get("total", 0)),
		"other_ms": other_ms,
		"terrain_active_chunk_count": terrain_active_chunk_count,
		"terrain_native_grid_active_chunk_count": terrain_native_grid_active_chunk_count,
		"terrain_pending_node_count": terrain_pending_node_count,
		"terrain_last_pending_node_sort_ms": terrain_last_pending_node_sort_ms,
		"terrain_last_pending_node_sort_count": terrain_last_pending_node_sort_count,
		"terrain_last_pending_node_sort_skipped": terrain_last_pending_node_sort_skipped,
		"terrain_pending_collision_create_count": terrain_pending_collision_create_count,
		"terrain_last_gpu_generation_dispatch_ms": terrain_last_gpu_generation_dispatch_ms,
		"terrain_last_gpu_generation_dispatch_coord": terrain_last_gpu_generation_dispatch_coord,
		"terrain_last_gpu_generation_mod_sync_ms": terrain_last_gpu_generation_mod_sync_ms,
		"terrain_last_gpu_generation_batch_ms": terrain_last_gpu_generation_batch_ms,
		"terrain_last_gpu_generation_batch_chunk_count": terrain_last_gpu_generation_batch_chunk_count,
		"terrain_last_gpu_generation_sync_ms": terrain_last_gpu_generation_sync_ms,
		"terrain_last_gpu_meshing_dispatch_ms": terrain_last_gpu_meshing_dispatch_ms,
		"terrain_last_gpu_meshing_sync_ms": terrain_last_gpu_meshing_sync_ms,
		"terrain_last_gpu_mesh_readback_ms": terrain_last_gpu_mesh_readback_ms,
		"terrain_last_gpu_mesh_readback_chunk_count": terrain_last_gpu_mesh_readback_chunk_count,
		"terrain_last_gpu_mesh_readback_terrain_vertices": terrain_last_gpu_mesh_readback_terrain_vertices,
		"terrain_last_gpu_mesh_readback_water_vertices": terrain_last_gpu_mesh_readback_water_vertices,
		"terrain_last_gpu_mesh_slice_count": terrain_last_gpu_mesh_slice_count,
		"terrain_last_gpu_mesh_slice_max_sync_ms": terrain_last_gpu_mesh_slice_max_sync_ms,
		"terrain_last_gpu_generation_batch_event_id": terrain_last_gpu_generation_batch_event_id,
		"terrain_last_cpu_mesh_build_ms": terrain_last_cpu_mesh_build_ms,
		"terrain_last_cpu_mesh_build_terrain_ms": terrain_last_cpu_mesh_build_terrain_ms,
		"terrain_last_cpu_mesh_build_water_ms": terrain_last_cpu_mesh_build_water_ms,
		"terrain_last_cpu_mesh_build_queue_wait_ms": terrain_last_cpu_mesh_build_queue_wait_ms,
		"terrain_last_cpu_mesh_build_terrain_vertices": terrain_last_cpu_mesh_build_terrain_vertices,
		"terrain_last_cpu_mesh_build_water_vertices": terrain_last_cpu_mesh_build_water_vertices,
		"terrain_last_cpu_mesh_build_coord": terrain_last_cpu_mesh_build_coord,
		"terrain_last_cpu_mesh_build_event_id": terrain_last_cpu_mesh_build_event_id,
		"terrain_last_finalize_terrain_ms": terrain_last_finalize_terrain_ms,
		"terrain_last_pending_node_process_ms": terrain_last_pending_node_process_ms,
		"terrain_last_collision_create_ms": terrain_last_collision_create_ms,
		"terrain_last_collision_create_count": terrain_last_collision_create_count,
		"terrain_last_collision_proximity_update_ms": terrain_last_collision_proximity_update_ms,
		"terrain_last_collision_proximity_enable_count": terrain_last_collision_proximity_enable_count,
		"terrain_last_collision_proximity_disable_count": terrain_last_collision_proximity_disable_count,
		"terrain_last_collision_proximity_prewarm_queued": terrain_last_collision_proximity_prewarm_queued,
		"terrain_collision_space_attached_chunk_count": terrain_collision_space_attached_chunk_count,
		"terrain_shared_collision_body_enabled": terrain_shared_collision_body_enabled,
		"terrain_shared_collision_shape_count": terrain_shared_collision_shape_count,
		"terrain_shared_collision_cluster_body_count": terrain_shared_collision_cluster_body_count,
		"terrain_collision_body_cache_count": terrain_collision_body_cache_count,
		"terrain_collision_body_cache_hits": terrain_collision_body_cache_hits,
		"terrain_collision_body_cache_misses": terrain_collision_body_cache_misses,
		"terrain_collision_body_cache_stores": terrain_collision_body_cache_stores,
		"terrain_last_update_loads": terrain_last_update_loads,
		"terrain_last_update_unloads": terrain_last_update_unloads,
		"terrain_last_fallback_unloads": terrain_last_fallback_unloads,
		"terrain_last_fallback_unload_ms": terrain_last_fallback_unload_ms,
		"terrain_last_world_map_lod_loads": terrain_last_world_map_lod_loads,
		"terrain_last_world_map_lod_unloads": terrain_last_world_map_lod_unloads,
		"terrain_last_world_map_lod_update_ms": terrain_last_world_map_lod_update_ms,
		"terrain_runtime_power_world_work_suspended": terrain_runtime_power_world_work_suspended,
		"terrain_runtime_power_render_loop_suspended": terrain_runtime_power_render_loop_suspended,
		"terrain_runtime_power_world_work_suspended_frame_count": terrain_runtime_power_world_work_suspended_frame_count,
		"terrain_visual_batch_node_count": terrain_visual_batch_node_count,
		"terrain_visual_batch_dirty_count": terrain_visual_batch_dirty_count,
		"terrain_last_visual_batch_rebuild_ms": terrain_last_visual_batch_rebuild_ms,
		"terrain_last_visual_batch_rebuild_count": terrain_last_visual_batch_rebuild_count,
		"terrain_last_visual_batch_hidden_chunk_count": terrain_last_visual_batch_hidden_chunk_count,
		"terrain_last_visual_batch_vertex_count": terrain_last_visual_batch_vertex_count,
		"terrain_last_visual_batch_index_count": terrain_last_visual_batch_index_count,
		"terrain_last_visual_batch_skipped_heavy_count": terrain_last_visual_batch_skipped_heavy_count,
		"terrain_visual_batch_total_heavy_skips": terrain_visual_batch_total_heavy_skips,
		"terrain_visual_batch_mesh_cache_count": terrain_visual_batch_mesh_cache_count,
		"terrain_visual_batch_mesh_cache_hits": terrain_visual_batch_mesh_cache_hits,
		"terrain_visual_batch_mesh_cache_misses": terrain_visual_batch_mesh_cache_misses,
		"terrain_last_visual_batch_cached_rebuild_count": terrain_last_visual_batch_cached_rebuild_count,
		"terrain_last_visual_batch_cached_rebuild_ms": terrain_last_visual_batch_cached_rebuild_ms,
		"terrain_last_visual_batch_cached_rebuild_attempts": terrain_last_visual_batch_cached_rebuild_attempts,
		"terrain_visual_batch_async_in_flight_count": terrain_visual_batch_async_in_flight_count,
		"terrain_visual_batch_async_completed_count": terrain_visual_batch_async_completed_count,
		"terrain_last_visual_batch_async_queued_count": terrain_last_visual_batch_async_queued_count,
		"terrain_last_visual_batch_streaming_async_queued_count": terrain_last_visual_batch_streaming_async_queued_count,
		"terrain_last_visual_batch_async_apply_count": terrain_last_visual_batch_async_apply_count,
		"terrain_last_visual_batch_async_apply_ms": terrain_last_visual_batch_async_apply_ms,
		"terrain_last_visual_batch_async_stale_count": terrain_last_visual_batch_async_stale_count,
		"terrain_visual_batch_stream_idle_frames": terrain_visual_batch_stream_idle_frames,
		"building_dirty_visible_chunk_count": building_dirty_visible_chunk_count,
		"building_last_flush_dirty_chunks_ms": building_last_flush_dirty_chunks_ms,
		"building_last_apply_payload_ms": building_last_apply_payload_ms,
		"building_last_apply_payload_object_ms": building_last_apply_payload_object_ms,
		"building_last_apply_payload_visual_ms": building_last_apply_payload_visual_ms,
		"building_pending_baked_apply_phases": building_pending_baked_apply_phases,
		"building_last_baked_apply_queue_ms": building_last_baked_apply_queue_ms,
		"building_last_baked_apply_queue_count": building_last_baked_apply_queue_count,
		"building_pending_visual_batch_rebuilds": building_pending_visual_batch_rebuilds,
		"building_pending_baked_object_spawns": building_pending_baked_object_spawns,
		"building_last_baked_object_spawn_queue_ms": building_last_baked_object_spawn_queue_ms,
		"building_last_baked_object_spawn_queue_count": building_last_baked_object_spawn_queue_count,
		"building_last_visibility_update_ms": building_last_visibility_update_ms,
		"building_last_visibility_added": building_last_visibility_added,
		"building_last_visibility_removed": building_last_visibility_removed,
		"building_last_visibility_target_visible": building_last_visibility_target_visible,
		"building_last_visibility_total_roots": building_last_visibility_total_roots,
		"building_visible_baked_visual_nodes": building_visible_baked_visual_nodes,
		"building_visible_baked_visual_surfaces": building_visible_baked_visual_surfaces,
		"prefab_pending_baked_payload_build_jobs": prefab_pending_baked_payload_build_jobs,
		"prefab_pending_baked_payload_jobs": prefab_pending_baked_payload_jobs,
		"prefab_last_baked_payload_build_queue_ms": prefab_last_baked_payload_build_queue_ms,
		"prefab_last_baked_payload_build_queue_count": prefab_last_baked_payload_build_queue_count,
		"prefab_last_baked_payload_build_queue_success_count": prefab_last_baked_payload_build_queue_success_count,
		"prefab_last_baked_payload_apply_ms": prefab_last_baked_payload_apply_ms,
		"prefab_last_baked_payload_apply_count": prefab_last_baked_payload_apply_count,
		"prefab_last_baked_payload_flush_ms": prefab_last_baked_payload_flush_ms,
		"vegetation_global_render_batch_count": vegetation_global_render_batch_count,
		"vegetation_last_global_render_sync_ms": vegetation_last_global_render_sync_ms,
		"vegetation_last_global_render_collect_ms": vegetation_last_global_render_collect_ms,
		"vegetation_last_global_render_pack_ms": vegetation_last_global_render_pack_ms,
		"vegetation_last_global_render_sync_kind": vegetation_last_global_render_sync_kind,
		"vegetation_last_global_render_sync_chunk_count": vegetation_last_global_render_sync_chunk_count,
		"vegetation_last_global_render_candidate_chunk_count": vegetation_last_global_render_candidate_chunk_count,
		"vegetation_last_global_render_sync_instance_count": vegetation_last_global_render_sync_instance_count,
		"vegetation_last_global_render_upload_bytes": vegetation_last_global_render_upload_bytes,
		"vegetation_max_global_render_upload_bytes": vegetation_max_global_render_upload_bytes,
		"vegetation_global_render_dirty_kind_count": vegetation_global_render_dirty_kind_count,
		"entity_active_entities": entity_active_entities,
		"entity_frozen_entities": entity_frozen_entities,
		"entity_pending_spawns": entity_pending_spawns,
		"entity_dormant_entities": entity_dormant_entities,
		"entity_spawned_chunks": entity_spawned_chunks,
		"entity_last_proximity_update_ms": entity_last_proximity_update_ms,
		"entity_last_spawn_queue_update_ms": entity_last_spawn_queue_update_ms,
		"entity_last_spawn_queue_spawned": entity_last_spawn_queue_spawned,
		"top_measure_name": str(top_measure.get("name", "Unknown")),
		"top_measure_bucket": str(top_measure.get("bucket", "Unknown")),
		"top_measure_ms": float(top_measure.get("ms", 0.0)),
		"top_measure_pct": float(top_measure.get("pct", 0.0))
	}

func _enrich_sample_with_previous_delta(sample: Dictionary) -> void:
	if _previous_native_town_entry_sample.is_empty():
		sample["frame_delta"] = 0
		sample["total_ms_delta"] = 0.0
		sample["draw_calls_delta"] = 0
		sample["objects_delta"] = 0
		sample["primitives_delta"] = 0
		sample["vram_mb_delta"] = 0.0
		sample["pipeline_compilations_total_delta"] = 0
		return

	sample["frame_delta"] = int(sample.get("frame", 0)) - int(_previous_native_town_entry_sample.get("frame", 0))
	sample["total_ms_delta"] = float(sample.get("total_ms", 0.0)) - float(_previous_native_town_entry_sample.get("total_ms", 0.0))
	sample["draw_calls_delta"] = int(sample.get("draw_calls", 0)) - int(_previous_native_town_entry_sample.get("draw_calls", 0))
	sample["objects_delta"] = int(sample.get("objects", 0)) - int(_previous_native_town_entry_sample.get("objects", 0))
	sample["primitives_delta"] = int(sample.get("primitives", 0)) - int(_previous_native_town_entry_sample.get("primitives", 0))
	sample["vram_mb_delta"] = float(sample.get("vram_mb", 0.0)) - float(_previous_native_town_entry_sample.get("vram_mb", 0.0))
	sample["pipeline_compilations_total_delta"] = maxi(0, int(sample.get("pipeline_compilations_total", 0)) - int(_previous_native_town_entry_sample.get("pipeline_compilations_total", 0)))


func _collect_pipeline_compilation_monitor_snapshot() -> Dictionary:
	var canvas := int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS))
	var mesh := int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH))
	var surface := int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE))
	var draw := int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW))
	var specialization := int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SPECIALIZATION))
	return {
		"canvas": canvas,
		"mesh": mesh,
		"surface": surface,
		"draw": draw,
		"specialization": specialization,
		"total": canvas + mesh + surface + draw + specialization
	}


func _collect_render_monitor_snapshot() -> Dictionary:
	return {
		"object_count": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resource_count": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphan_node_count": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"render_objects_in_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"render_primitives_in_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"render_draw_calls_in_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"render_video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0),
		"render_texture_mem_mb": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / (1024.0 * 1024.0),
		"render_buffer_mem_mb": Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / (1024.0 * 1024.0),
		"physics_3d_active_objects": int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		"physics_3d_collision_pairs": int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		"physics_3d_islands": int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)),
		"pipeline_compilations": _collect_pipeline_compilation_monitor_snapshot()
	}


func _collect_render_features_snapshot() -> Dictionary:
	var features := {
		"expected_rendering_method": "forward_plus",
		"expected_rendering_driver": "vulkan",
		"vulkan_only_expected": true
	}
	if RenderingServer.has_method("get_current_rendering_method"):
		features["rendering_method"] = str(RenderingServer.call("get_current_rendering_method"))
	if RenderingServer.has_method("get_current_rendering_driver_name"):
		features["rendering_driver_name"] = str(RenderingServer.call("get_current_rendering_driver_name"))
	features["project_rendering_method"] = str(ProjectSettings.get_setting("rendering/renderer/rendering_method", ""))
	features["project_rendering_driver_windows"] = str(ProjectSettings.get_setting("rendering/rendering_device/driver.windows", ""))
	features["project_fallback_to_d3d12"] = bool(ProjectSettings.get_setting("rendering/rendering_device/fallback_to_d3d12", true))
	features["project_fallback_to_opengl3"] = bool(ProjectSettings.get_setting("rendering/rendering_device/fallback_to_opengl3", true))
	features["project_window_mode"] = int(ProjectSettings.get_setting("display/window/size/mode", -1))
	features["project_vsync_mode"] = int(ProjectSettings.get_setting("display/window/vsync/vsync_mode", -1))
	if DisplayServer.has_method("window_get_mode"):
		features["runtime_window_mode"] = int(DisplayServer.window_get_mode())
	if DisplayServer.has_method("window_get_size"):
		var window_size := DisplayServer.window_get_size()
		features["runtime_window_width"] = int(window_size.x)
		features["runtime_window_height"] = int(window_size.y)
	if DisplayServer.has_method("window_get_vsync_mode"):
		features["runtime_vsync_mode"] = int(DisplayServer.window_get_vsync_mode())
	if DisplayServer.has_method("window_get_current_screen") and DisplayServer.has_method("screen_get_size"):
		var screen_index := int(DisplayServer.window_get_current_screen())
		var screen_size := DisplayServer.screen_get_size(screen_index)
		features["runtime_screen_index"] = screen_index
		features["runtime_screen_width"] = int(screen_size.x)
		features["runtime_screen_height"] = int(screen_size.y)
	return features


func _parse_resolution_env(value: String) -> Vector2i:
	var text := value.strip_edges().to_lower()
	if text.is_empty():
		return Vector2i.ZERO
	var parts := text.split("x")
	if parts.size() != 2:
		return Vector2i.ZERO
	var width := int(parts[0])
	var height := int(parts[1])
	if width <= 0 or height <= 0:
		return Vector2i.ZERO
	return Vector2i(width, height)


func _apply_display_mode_override_from_env() -> void:
	var override_notes: Array[String] = []
	if OS.get_environment("TOWN_STALL_GODOT_WINDOWED") == "1":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		override_notes.append("windowed")
	var resolution := _parse_resolution_env(OS.get_environment("TOWN_STALL_GODOT_RESOLUTION"))
	if resolution.x > 0 and resolution.y > 0:
		DisplayServer.window_set_size(resolution)
		override_notes.append("size=%s" % str(DisplayServer.window_get_size()))
	if not override_notes.is_empty():
		print("[TOWN_STALL_TEST] Runtime display override: %s" % " ".join(override_notes))


func _collect_render_scene_scan() -> Dictionary:
	var counts := {
		"geometry_instances": 0,
		"visible_geometry_instances": 0,
		"mesh_instances": 0,
		"visible_mesh_instances": 0,
		"mesh_surface_count": 0,
		"visible_mesh_surface_count": 0,
		"mesh_vertex_count": 0,
		"visible_mesh_vertex_count": 0,
		"mesh_index_count": 0,
		"visible_mesh_index_count": 0,
		"mesh_triangle_count": 0,
		"visible_mesh_triangle_count": 0,
		"multimesh_instances": 0,
		"visible_multimesh_instances": 0,
		"multimesh_surface_count": 0,
		"visible_multimesh_surface_count": 0,
		"multimesh_instance_count": 0,
		"visible_multimesh_instance_count": 0,
		"multimesh_base_vertex_count": 0,
		"visible_multimesh_base_vertex_count": 0,
		"multimesh_rendered_vertex_count": 0,
		"visible_multimesh_rendered_vertex_count": 0,
		"multimesh_base_index_count": 0,
		"visible_multimesh_base_index_count": 0,
		"multimesh_rendered_index_count": 0,
		"visible_multimesh_rendered_index_count": 0,
		"multimesh_base_triangle_count": 0,
		"visible_multimesh_base_triangle_count": 0,
		"multimesh_rendered_triangle_count": 0,
		"visible_multimesh_rendered_triangle_count": 0,
		"frustum_geometry_instances": 0,
		"frustum_mesh_instances": 0,
		"frustum_mesh_triangle_count": 0,
		"frustum_mesh_vertex_count": 0,
		"frustum_multimesh_instances": 0,
		"frustum_multimesh_instance_count": 0,
		"frustum_multimesh_rendered_triangle_count": 0,
		"frustum_multimesh_rendered_vertex_count": 0,
		"terrain_geometry": 0,
		"visible_terrain_geometry": 0,
		"frustum_terrain_geometry": 0,
		"frustum_terrain_mesh_instances": 0,
		"frustum_terrain_mesh_triangle_count": 0,
		"frustum_terrain_mesh_vertex_count": 0,
		"frustum_terrain_multimesh_instances": 0,
		"frustum_terrain_multimesh_instance_count": 0,
		"frustum_terrain_multimesh_rendered_triangle_count": 0,
		"frustum_terrain_multimesh_rendered_vertex_count": 0,
		"building_geometry": 0,
		"visible_building_geometry": 0,
		"frustum_building_geometry": 0,
		"frustum_building_mesh_instances": 0,
		"frustum_building_mesh_triangle_count": 0,
		"frustum_building_mesh_vertex_count": 0,
		"frustum_building_multimesh_instances": 0,
		"frustum_building_multimesh_instance_count": 0,
		"frustum_building_multimesh_rendered_triangle_count": 0,
		"frustum_building_multimesh_rendered_vertex_count": 0,
		"vegetation_geometry": 0,
		"visible_vegetation_geometry": 0,
		"frustum_vegetation_geometry": 0,
		"frustum_vegetation_mesh_instances": 0,
		"frustum_vegetation_mesh_triangle_count": 0,
		"frustum_vegetation_mesh_vertex_count": 0,
		"frustum_vegetation_multimesh_instances": 0,
		"frustum_vegetation_multimesh_instance_count": 0,
		"frustum_vegetation_multimesh_rendered_triangle_count": 0,
		"frustum_vegetation_multimesh_rendered_vertex_count": 0,
		"entity_geometry": 0,
		"visible_entity_geometry": 0,
		"frustum_entity_geometry": 0,
		"frustum_entity_mesh_instances": 0,
		"frustum_entity_mesh_triangle_count": 0,
		"frustum_entity_mesh_vertex_count": 0,
		"frustum_entity_multimesh_instances": 0,
		"frustum_entity_multimesh_instance_count": 0,
		"frustum_entity_multimesh_rendered_triangle_count": 0,
		"frustum_entity_multimesh_rendered_vertex_count": 0,
		"other_geometry": 0,
		"visible_other_geometry": 0,
		"frustum_other_geometry": 0,
		"frustum_other_mesh_instances": 0,
		"frustum_other_mesh_triangle_count": 0,
		"frustum_other_mesh_vertex_count": 0,
		"frustum_other_multimesh_instances": 0,
		"frustum_other_multimesh_instance_count": 0,
		"frustum_other_multimesh_rendered_triangle_count": 0,
		"frustum_other_multimesh_rendered_vertex_count": 0
	}
	var visible_details: Array[Dictionary] = []
	var frustum_details: Array[Dictionary] = []
	var material_surface_counts := {}
	var camera := get_viewport().get_camera_3d()
	if not is_instance_valid(game_root):
		return counts

	_scan_render_node(game_root, counts, visible_details, frustum_details, material_surface_counts, camera)
	visible_details.sort_custom(Callable(self, "_compare_render_geometry_detail"))
	while visible_details.size() > render_diagnostics_scene_detail_limit:
		visible_details.remove_at(visible_details.size() - 1)
	frustum_details.sort_custom(Callable(self, "_compare_render_geometry_detail"))
	while frustum_details.size() > render_diagnostics_scene_detail_limit:
		frustum_details.remove_at(frustum_details.size() - 1)
	counts["top_visible_geometry"] = visible_details
	counts["top_frustum_geometry"] = frustum_details
	counts["visible_material_surface_counts"] = _sorted_render_count_entries(material_surface_counts, render_diagnostics_scene_detail_limit)
	return counts


func _scan_render_node(node: Node, counts: Dictionary, visible_details: Array[Dictionary], frustum_details: Array[Dictionary], material_surface_counts: Dictionary, camera: Camera3D) -> void:
	if node is GeometryInstance3D:
		var geometry := node as GeometryInstance3D
		var visible := geometry.is_visible_in_tree()
		var in_camera_frustum := visible and _is_geometry_in_camera_frustum(geometry, camera)
		_increment_render_count(counts, "geometry_instances")
		if visible:
			_increment_render_count(counts, "visible_geometry_instances")
		if in_camera_frustum:
			_increment_render_count(counts, "frustum_geometry_instances")

		var category := _get_render_diagnostic_node_category(geometry)
		var detail := _build_render_geometry_detail(geometry, category)
		detail["in_camera_frustum"] = in_camera_frustum
		if geometry is MeshInstance3D:
			_increment_render_count(counts, "mesh_instances")
			_increment_render_count(counts, "%s_mesh_instances" % category)
			_increment_render_count(counts, "mesh_surface_count", int(detail.get("surface_count", 0)))
			_increment_render_count(counts, "%s_mesh_surface_count" % category, int(detail.get("surface_count", 0)))
			_increment_render_count(counts, "mesh_vertex_count", int(detail.get("vertex_count", 0)))
			_increment_render_count(counts, "%s_mesh_vertex_count" % category, int(detail.get("vertex_count", 0)))
			_increment_render_count(counts, "mesh_index_count", int(detail.get("index_count", 0)))
			_increment_render_count(counts, "%s_mesh_index_count" % category, int(detail.get("index_count", 0)))
			_increment_render_count(counts, "mesh_triangle_count", int(detail.get("triangle_count", 0)))
			_increment_render_count(counts, "%s_mesh_triangle_count" % category, int(detail.get("triangle_count", 0)))
			if visible:
				_increment_render_count(counts, "visible_mesh_instances")
				_increment_render_count(counts, "visible_%s_mesh_instances" % category)
				_increment_render_count(counts, "visible_mesh_surface_count", int(detail.get("surface_count", 0)))
				_increment_render_count(counts, "visible_%s_mesh_surface_count" % category, int(detail.get("surface_count", 0)))
				_increment_render_count(counts, "visible_mesh_vertex_count", int(detail.get("vertex_count", 0)))
				_increment_render_count(counts, "visible_%s_mesh_vertex_count" % category, int(detail.get("vertex_count", 0)))
				_increment_render_count(counts, "visible_mesh_index_count", int(detail.get("index_count", 0)))
				_increment_render_count(counts, "visible_%s_mesh_index_count" % category, int(detail.get("index_count", 0)))
				_increment_render_count(counts, "visible_mesh_triangle_count", int(detail.get("triangle_count", 0)))
				_increment_render_count(counts, "visible_%s_mesh_triangle_count" % category, int(detail.get("triangle_count", 0)))
				_record_render_material_surfaces(geometry as MeshInstance3D, material_surface_counts)
			if in_camera_frustum:
				_increment_render_count(counts, "frustum_mesh_instances")
				_increment_render_count(counts, "frustum_%s_mesh_instances" % category)
				_increment_render_count(counts, "frustum_mesh_vertex_count", int(detail.get("vertex_count", 0)))
				_increment_render_count(counts, "frustum_%s_mesh_vertex_count" % category, int(detail.get("vertex_count", 0)))
				_increment_render_count(counts, "frustum_mesh_triangle_count", int(detail.get("triangle_count", 0)))
				_increment_render_count(counts, "frustum_%s_mesh_triangle_count" % category, int(detail.get("triangle_count", 0)))
		elif geometry is MultiMeshInstance3D:
			_increment_render_count(counts, "multimesh_instances")
			_increment_render_count(counts, "%s_multimesh_instances" % category)
			_increment_render_count(counts, "multimesh_surface_count", int(detail.get("surface_count", 0)))
			_increment_render_count(counts, "%s_multimesh_surface_count" % category, int(detail.get("surface_count", 0)))
			_increment_render_count(counts, "multimesh_instance_count", int(detail.get("instance_count", 0)))
			_increment_render_count(counts, "%s_multimesh_instance_count" % category, int(detail.get("instance_count", 0)))
			_increment_render_count(counts, "multimesh_base_vertex_count", int(detail.get("base_vertex_count", 0)))
			_increment_render_count(counts, "%s_multimesh_base_vertex_count" % category, int(detail.get("base_vertex_count", 0)))
			_increment_render_count(counts, "multimesh_rendered_vertex_count", int(detail.get("vertex_count", 0)))
			_increment_render_count(counts, "%s_multimesh_rendered_vertex_count" % category, int(detail.get("vertex_count", 0)))
			_increment_render_count(counts, "multimesh_base_index_count", int(detail.get("base_index_count", 0)))
			_increment_render_count(counts, "%s_multimesh_base_index_count" % category, int(detail.get("base_index_count", 0)))
			_increment_render_count(counts, "multimesh_rendered_index_count", int(detail.get("index_count", 0)))
			_increment_render_count(counts, "%s_multimesh_rendered_index_count" % category, int(detail.get("index_count", 0)))
			_increment_render_count(counts, "multimesh_base_triangle_count", int(detail.get("base_triangle_count", 0)))
			_increment_render_count(counts, "%s_multimesh_base_triangle_count" % category, int(detail.get("base_triangle_count", 0)))
			_increment_render_count(counts, "multimesh_rendered_triangle_count", int(detail.get("triangle_count", 0)))
			_increment_render_count(counts, "%s_multimesh_rendered_triangle_count" % category, int(detail.get("triangle_count", 0)))
			if visible:
				_increment_render_count(counts, "visible_multimesh_instances")
				_increment_render_count(counts, "visible_%s_multimesh_instances" % category)
				_increment_render_count(counts, "visible_multimesh_surface_count", int(detail.get("surface_count", 0)))
				_increment_render_count(counts, "visible_%s_multimesh_surface_count" % category, int(detail.get("surface_count", 0)))
				_increment_render_count(counts, "visible_multimesh_instance_count", int(detail.get("instance_count", 0)))
				_increment_render_count(counts, "visible_%s_multimesh_instance_count" % category, int(detail.get("instance_count", 0)))
				_increment_render_count(counts, "visible_multimesh_base_vertex_count", int(detail.get("base_vertex_count", 0)))
				_increment_render_count(counts, "visible_%s_multimesh_base_vertex_count" % category, int(detail.get("base_vertex_count", 0)))
				_increment_render_count(counts, "visible_multimesh_rendered_vertex_count", int(detail.get("vertex_count", 0)))
				_increment_render_count(counts, "visible_%s_multimesh_rendered_vertex_count" % category, int(detail.get("vertex_count", 0)))
				_increment_render_count(counts, "visible_multimesh_base_index_count", int(detail.get("base_index_count", 0)))
				_increment_render_count(counts, "visible_%s_multimesh_base_index_count" % category, int(detail.get("base_index_count", 0)))
				_increment_render_count(counts, "visible_multimesh_rendered_index_count", int(detail.get("index_count", 0)))
				_increment_render_count(counts, "visible_%s_multimesh_rendered_index_count" % category, int(detail.get("index_count", 0)))
				_increment_render_count(counts, "visible_multimesh_base_triangle_count", int(detail.get("base_triangle_count", 0)))
				_increment_render_count(counts, "visible_%s_multimesh_base_triangle_count" % category, int(detail.get("base_triangle_count", 0)))
				_increment_render_count(counts, "visible_multimesh_rendered_triangle_count", int(detail.get("triangle_count", 0)))
				_increment_render_count(counts, "visible_%s_multimesh_rendered_triangle_count" % category, int(detail.get("triangle_count", 0)))
			if in_camera_frustum:
				_increment_render_count(counts, "frustum_multimesh_instances")
				_increment_render_count(counts, "frustum_%s_multimesh_instances" % category)
				_increment_render_count(counts, "frustum_multimesh_instance_count", int(detail.get("instance_count", 0)))
				_increment_render_count(counts, "frustum_%s_multimesh_instance_count" % category, int(detail.get("instance_count", 0)))
				_increment_render_count(counts, "frustum_multimesh_rendered_vertex_count", int(detail.get("vertex_count", 0)))
				_increment_render_count(counts, "frustum_%s_multimesh_rendered_vertex_count" % category, int(detail.get("vertex_count", 0)))
				_increment_render_count(counts, "frustum_multimesh_rendered_triangle_count", int(detail.get("triangle_count", 0)))
				_increment_render_count(counts, "frustum_%s_multimesh_rendered_triangle_count" % category, int(detail.get("triangle_count", 0)))

		_increment_render_count(counts, "%s_geometry" % category)
		if visible:
			_increment_render_count(counts, "visible_%s_geometry" % category)
			visible_details.append(detail)
		if in_camera_frustum:
			_increment_render_count(counts, "frustum_%s_geometry" % category)
			frustum_details.append(detail)

	for child in node.get_children():
		_scan_render_node(child, counts, visible_details, frustum_details, material_surface_counts, camera)


func _increment_render_count(counts: Dictionary, key: String, amount: int = 1) -> void:
	counts[key] = int(counts.get(key, 0)) + amount


func _is_geometry_in_camera_frustum(geometry: GeometryInstance3D, camera: Camera3D) -> bool:
	if not is_instance_valid(geometry) or not geometry.is_inside_tree():
		return false
	if not is_instance_valid(camera) or not camera.is_inside_tree():
		return false

	var global_aabb := _get_geometry_global_aabb(geometry)
	if global_aabb.size == Vector3.ZERO:
		return camera.is_position_in_frustum(global_aabb.position)
	if global_aabb.has_point(camera.global_position):
		return true

	var center := global_aabb.position + global_aabb.size * 0.5
	if camera.is_position_in_frustum(center):
		return true

	for point in _get_aabb_sample_points(global_aabb):
		if camera.is_position_in_frustum(point):
			return true
	return false


func _get_geometry_global_aabb(geometry: GeometryInstance3D) -> AABB:
	var local_aabb := geometry.get_aabb()
	var transform := geometry.global_transform
	var bounds := AABB(transform * local_aabb.get_endpoint(0), Vector3.ZERO)
	for index in range(1, 8):
		bounds = bounds.expand(transform * local_aabb.get_endpoint(index))
	return bounds


func _get_aabb_sample_points(bounds: AABB) -> Array[Vector3]:
	var min_corner := bounds.position
	var max_corner := bounds.position + bounds.size
	var center := bounds.position + bounds.size * 0.5
	return [
		bounds.get_endpoint(0),
		bounds.get_endpoint(1),
		bounds.get_endpoint(2),
		bounds.get_endpoint(3),
		bounds.get_endpoint(4),
		bounds.get_endpoint(5),
		bounds.get_endpoint(6),
		bounds.get_endpoint(7),
		Vector3(center.x, center.y, min_corner.z),
		Vector3(center.x, center.y, max_corner.z),
		Vector3(center.x, min_corner.y, center.z),
		Vector3(center.x, max_corner.y, center.z),
		Vector3(min_corner.x, center.y, center.z),
		Vector3(max_corner.x, center.y, center.z)
	]


func _build_render_geometry_detail(geometry: GeometryInstance3D, category: String) -> Dictionary:
	var surface_count := 0
	var instance_count := 0
	var vertex_count := 0
	var index_count := 0
	var triangle_count := 0
	var base_vertex_count := 0
	var base_index_count := 0
	var base_triangle_count := 0
	var mesh_resource_path := ""
	var material_keys: Array[String] = []
	if geometry is MeshInstance3D:
		var mesh_instance := geometry as MeshInstance3D
		if mesh_instance.mesh != null:
			surface_count = mesh_instance.mesh.get_surface_count()
			mesh_resource_path = str(mesh_instance.mesh.resource_path)
			material_keys = _collect_render_material_keys(mesh_instance)
			var mesh_counts := _collect_mesh_geometry_counts(mesh_instance.mesh)
			vertex_count = int(mesh_counts.get("vertex_count", 0))
			index_count = int(mesh_counts.get("index_count", 0))
			triangle_count = int(mesh_counts.get("triangle_count", 0))
	elif geometry is MultiMeshInstance3D:
		var multimesh_instance := geometry as MultiMeshInstance3D
		if multimesh_instance.multimesh != null:
			instance_count = multimesh_instance.multimesh.instance_count
			if multimesh_instance.multimesh.mesh != null:
				surface_count = multimesh_instance.multimesh.mesh.get_surface_count()
				mesh_resource_path = str(multimesh_instance.multimesh.mesh.resource_path)
				var base_counts := _collect_mesh_geometry_counts(multimesh_instance.multimesh.mesh)
				base_vertex_count = int(base_counts.get("vertex_count", 0))
				base_index_count = int(base_counts.get("index_count", 0))
				base_triangle_count = int(base_counts.get("triangle_count", 0))
				vertex_count = base_vertex_count * maxi(instance_count, 1)
				index_count = base_index_count * maxi(instance_count, 1)
				triangle_count = base_triangle_count * maxi(instance_count, 1)

	var player_distance := -1.0
	var geometry_position := Vector3.ZERO
	var geometry_bounds_center := Vector3.ZERO
	var geometry_bounds_size := Vector3.ZERO
	if geometry.is_inside_tree():
		geometry_position = geometry.global_position
		var geometry_bounds := _get_geometry_global_aabb(geometry)
		geometry_bounds_center = geometry_bounds.position + geometry_bounds.size * 0.5
		geometry_bounds_size = geometry_bounds.size
	if is_instance_valid(player) and player.is_inside_tree() and geometry.is_inside_tree():
		player_distance = geometry_bounds_center.distance_to(player.global_position)

	return {
		"path": _get_render_node_path_text(geometry),
		"name": str(geometry.name),
		"class": geometry.get_class(),
		"category": category,
		"surface_count": surface_count,
		"instance_count": instance_count,
		"vertex_count": vertex_count,
		"index_count": index_count,
		"triangle_count": triangle_count,
		"base_vertex_count": base_vertex_count,
		"base_index_count": base_index_count,
		"base_triangle_count": base_triangle_count,
		"draw_proxy_score": maxi(surface_count, 1),
		"render_work_proxy_score": maxi(triangle_count, maxi(vertex_count, surface_count)),
		"distance_to_player_m": player_distance,
		"global_position": _vector3_to_snapshot(geometry_position),
		"bounds_center": _vector3_to_snapshot(geometry_bounds_center),
		"bounds_size": _vector3_to_snapshot(geometry_bounds_size),
		"mesh_resource_path": mesh_resource_path,
		"material_keys": material_keys
	}


func _collect_mesh_geometry_counts(mesh: Mesh) -> Dictionary:
	var counts := {
		"vertex_count": 0,
		"index_count": 0,
		"triangle_count": 0
	}
	if mesh == null:
		return counts

	for surface_index in range(mesh.get_surface_count()):
		var surface_vertex_count := 0
		var surface_index_count := 0
		var array_mesh := mesh as ArrayMesh
		if array_mesh != null:
			surface_vertex_count = int(array_mesh.surface_get_array_len(surface_index))
			surface_index_count = int(array_mesh.surface_get_array_index_len(surface_index))
		else:
			var arrays := mesh.surface_get_arrays(surface_index)
			if arrays.size() > Mesh.ARRAY_VERTEX:
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				surface_vertex_count = vertices.size()
			if arrays.size() > Mesh.ARRAY_INDEX:
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				surface_index_count = indices.size()
		var surface_triangle_count := 0
		if surface_index_count > 0:
			surface_triangle_count = int(surface_index_count / 3)
		else:
			surface_triangle_count = int(surface_vertex_count / 3)
		_increment_render_count(counts, "vertex_count", surface_vertex_count)
		_increment_render_count(counts, "index_count", surface_index_count)
		_increment_render_count(counts, "triangle_count", surface_triangle_count)
	return counts


func _compare_render_geometry_detail(left: Dictionary, right: Dictionary) -> bool:
	var left_triangles := int(left.get("triangle_count", 0))
	var right_triangles := int(right.get("triangle_count", 0))
	if left_triangles != right_triangles:
		return left_triangles > right_triangles

	var left_vertices := int(left.get("vertex_count", 0))
	var right_vertices := int(right.get("vertex_count", 0))
	if left_vertices != right_vertices:
		return left_vertices > right_vertices

	var left_draw := int(left.get("draw_proxy_score", 0))
	var right_draw := int(right.get("draw_proxy_score", 0))
	if left_draw != right_draw:
		return left_draw > right_draw

	var left_work := int(left.get("render_work_proxy_score", 0))
	var right_work := int(right.get("render_work_proxy_score", 0))
	if left_work != right_work:
		return left_work > right_work

	var left_distance := float(left.get("distance_to_player_m", 1.0e20))
	var right_distance := float(right.get("distance_to_player_m", 1.0e20))
	return left_distance < right_distance


func _record_render_material_surfaces(mesh_instance: MeshInstance3D, material_surface_counts: Dictionary) -> void:
	var material_keys := _collect_render_material_keys(mesh_instance)
	for material_key in material_keys:
		_increment_render_count(material_surface_counts, material_key)


func _collect_render_material_keys(mesh_instance: MeshInstance3D) -> Array[String]:
	var keys: Array[String] = []
	if mesh_instance.mesh == null:
		return keys

	var surface_count := mesh_instance.mesh.get_surface_count()
	for surface_index in range(surface_count):
		var material := mesh_instance.get_surface_override_material(surface_index)
		if material == null:
			material = mesh_instance.mesh.surface_get_material(surface_index)
		keys.append(_get_render_material_key(material))
	return keys


func _get_render_material_key(material: Material) -> String:
	if material == null:
		return "<null-material>"

	var resource_path := str(material.resource_path)
	if not resource_path.is_empty():
		return resource_path

	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		if shader_material.shader != null:
			var shader_path := str(shader_material.shader.resource_path)
			if not shader_path.is_empty():
				return "shader:%s" % shader_path

	return material.get_class()


func _sorted_render_count_entries(counts: Dictionary, limit: int) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for key in counts.keys():
		entries.append({
			"key": str(key),
			"count": int(counts.get(key, 0))
		})
	entries.sort_custom(Callable(self, "_compare_render_count_entry"))
	while entries.size() > limit:
		entries.remove_at(entries.size() - 1)
	return entries


func _compare_render_count_entry(left: Dictionary, right: Dictionary) -> bool:
	var left_count := int(left.get("count", 0))
	var right_count := int(right.get("count", 0))
	if left_count != right_count:
		return left_count > right_count
	return str(left.get("key", "")) < str(right.get("key", ""))


func _vector3_to_snapshot(value: Vector3) -> Dictionary:
	return {
		"x": value.x,
		"y": value.y,
		"z": value.z
	}


func _get_render_node_path_text(node: Node) -> String:
	if node.is_inside_tree():
		return str(node.get_path())
	return str(node.name)


func _get_render_diagnostic_node_category(node: Node) -> String:
	var path_text := _get_render_node_path_text(node).to_lower()
	var name_text := str(node.name).to_lower()
	if path_text.contains("chunkmanager") or path_text.contains("terrain") or name_text.contains("terrain") or name_text.contains("water"):
		return "terrain"
	if path_text.contains("buildingmanager") or name_text.contains("building") or name_text.contains("globalvisualbatch") or name_text.contains("prewarm"):
		return "building"
	if path_text.contains("vegetation") or name_text.contains("tree") or name_text.contains("grass") or name_text.contains("rock"):
		return "vegetation"
	if path_text.contains("entity") or name_text.contains("zombie") or name_text.contains("enemy"):
		return "entity"
	return "other"


func _capture_render_diagnostic_sample(sample: Dictionary) -> void:
	if not render_diagnostics_enabled:
		return
	var total_ms := float(sample.get("total_ms", 0.0))
	if total_ms < render_diagnostics_threshold_ms:
		return
	_render_diagnostic_candidate_count += 1
	if not _should_retain_render_diagnostic_sample(total_ms):
		_render_diagnostic_skipped_count += 1
		return

	var diagnostic := {
		"sample": sample.duplicate(true),
		"render_monitor": _collect_render_monitor_snapshot()
	}
	if render_diagnostics_scene_scan_enabled and _render_diagnostic_scene_scan_count < render_diagnostics_frame_scene_scan_limit:
		diagnostic["scene_scan"] = _collect_render_scene_scan()
		_render_diagnostic_scene_scan_count += 1

	_render_diagnostic_samples.append(diagnostic)
	_trim_render_diagnostic_samples()


func _should_retain_render_diagnostic_sample(total_ms: float) -> bool:
	if render_diagnostics_sample_limit <= 0:
		return false
	if _render_diagnostic_samples.size() < render_diagnostics_sample_limit:
		return true

	var lowest_ms := 1.0e20
	for diagnostic_variant in _render_diagnostic_samples:
		var diagnostic: Dictionary = diagnostic_variant
		var retained_sample: Dictionary = diagnostic.get("sample", {})
		lowest_ms = minf(lowest_ms, float(retained_sample.get("total_ms", 0.0)))
	return total_ms > lowest_ms


func _trim_render_diagnostic_samples() -> void:
	while _render_diagnostic_samples.size() > render_diagnostics_sample_limit:
		var lowest_index := 0
		var lowest_ms := 1.0e20
		for index in range(_render_diagnostic_samples.size()):
			var diagnostic: Dictionary = _render_diagnostic_samples[index]
			var sample: Dictionary = diagnostic.get("sample", {})
			var total_ms := float(sample.get("total_ms", 0.0))
			if total_ms < lowest_ms:
				lowest_ms = total_ms
				lowest_index = index
		_render_diagnostic_samples.remove_at(lowest_index)


func _resolve_native_top_measure(total_ms: float, process_monitor_ms: float, physics_ms: float, navigation_ms: float, other_ms: float, draw_calls: int) -> Dictionary:
	var top_name := "Unmeasured"
	var top_bucket := "Unmeasured"
	var top_ms := other_ms

	if process_monitor_ms >= physics_ms and process_monitor_ms >= navigation_ms and process_monitor_ms >= other_ms:
		top_name = "Engine: Process"
		top_bucket = top_name
		top_ms = process_monitor_ms
	elif physics_ms >= navigation_ms and physics_ms >= other_ms:
		top_name = "Engine: Physics"
		top_bucket = top_name
		top_ms = physics_ms
	elif navigation_ms >= physics_ms and navigation_ms >= other_ms:
		top_name = "Engine: Navigation"
		top_bucket = top_name
		top_ms = navigation_ms
	elif draw_calls > 0:
		top_name = "Unattributed/Render Wait (%d draws)" % draw_calls
		top_bucket = "Unattributed/Render Wait"

	return {
		"name": top_name,
		"bucket": top_bucket,
		"ms": top_ms,
		"pct": top_ms / total_ms * 100.0 if total_ms > 0.0 else 0.0
	}


func _build_empty_native_town_entry_window() -> Dictionary:
	return {
		"sample_count": 0,
		"start_frame": -1,
		"end_frame": -1,
		"avg_fps": 0.0,
		"avg_draw_calls": 0.0,
		"avg_objects": 0.0,
		"avg_primitives": 0.0,
		"avg_total_ms": 0.0,
		"avg_physics_ms": 0.0,
		"avg_navigation_ms": 0.0,
		"avg_vram_mb": 0.0,
		"avg_other_ms": 0.0,
		"max_total_ms": 0.0,
		"max_total_frame": -1,
		"frames_over_budget": 0,
		"frames_over_40ms": 0,
		"frames_over_50ms": 0,
		"stall_over_budget_ms": 0.0,
		"stall_over_40ms_ms": 0.0,
		"stall_over_50ms_ms": 0.0,
		"longest_over_budget_streak": 0,
		"longest_over_40ms_streak": 0,
		"longest_over_50ms_streak": 0,
		"peak_top_bucket": "Unknown",
		"peak_top_measure_name": "Unknown",
		"peak_top_measure_ms": 0.0,
		"peak_top_measure_pct": 0.0,
		"peak_entry_sample": {},
		"peak_entry_samples": [],
		"stable_top_bucket": "Unknown",
		"stable_top_bucket_count": 0,
		"top_bucket_counts": {},
		"baseline_comparison": {},
		"pipeline_compilations_canvas_delta": 0,
		"pipeline_compilations_mesh_delta": 0,
		"pipeline_compilations_surface_delta": 0,
		"pipeline_compilations_draw_delta": 0,
		"pipeline_compilations_specialization_delta": 0,
		"pipeline_compilations_total_delta": 0,
		"pipeline_compilations_total_start": 0,
		"pipeline_compilations_total_end": 0,
		"terrain_runtime_power_world_work_suspended_samples": 0,
		"terrain_runtime_power_render_loop_suspended_samples": 0,
		"render_active_sample_count": 0,
		"avg_fps_render_active": 0.0,
		"avg_draw_calls_render_active": 0.0,
		"avg_objects_render_active": 0.0,
		"avg_primitives_render_active": 0.0,
		"avg_total_ms_render_active": 0.0,
		"avg_physics_ms_render_active": 0.0,
		"avg_navigation_ms_render_active": 0.0,
		"avg_vram_mb_render_active": 0.0,
		"avg_other_ms_render_active": 0.0,
		"max_total_ms_render_active": 0.0,
		"frames_over_budget_render_active": 0,
		"frames_over_40ms_render_active": 0,
		"frames_over_50ms_render_active": 0,
		"latest_town_state": {},
		"latest_entities_state": {}
	}


func _build_native_town_entry_window(samples: Array[Dictionary], window_size: int) -> Dictionary:
	if samples.is_empty() or window_size <= 0:
		return _build_empty_native_town_entry_window()

	var sample_count := mini(window_size, samples.size())
	if sample_count <= 0:
		return _build_empty_native_town_entry_window()

	var start_index := samples.size() - sample_count
	var total_fps := 0.0
	var total_draw_calls := 0.0
	var total_objects := 0.0
	var total_primitives := 0.0
	var total_ms := 0.0
	var total_physics_ms := 0.0
	var total_navigation_ms := 0.0
	var total_vram_mb := 0.0
	var total_other_ms := 0.0
	var bucket_counts: Dictionary = {}
	var first_entry: Dictionary = {}
	var last_entry: Dictionary = {}
	var peak_entry: Dictionary = {}
	var peak_total_ms := -1.0
	var peak_frame := -1
	var peak_top_bucket := "Unknown"
	var peak_top_measure_name := "Unknown"
	var peak_top_measure_ms := 0.0
	var peak_top_measure_pct := 0.0
	var peak_entries: Array[Dictionary] = []
	var frames_over_budget := 0
	var frames_over_40ms := 0
	var frames_over_50ms := 0
	var total_over_budget_ms := 0.0
	var total_over_40ms_ms := 0.0
	var total_over_50ms_ms := 0.0
	var current_over_budget_streak := 0
	var current_over_40ms_streak := 0
	var current_over_50ms_streak := 0
	var longest_over_budget_streak := 0
	var longest_over_40ms_streak := 0
	var longest_over_50ms_streak := 0
	var terrain_runtime_power_world_work_suspended_samples := 0
	var terrain_runtime_power_render_loop_suspended_samples := 0
	var render_active_sample_count := 0
	var total_fps_render_active := 0.0
	var total_draw_calls_render_active := 0.0
	var total_objects_render_active := 0.0
	var total_primitives_render_active := 0.0
	var total_ms_render_active := 0.0
	var total_physics_ms_render_active := 0.0
	var total_navigation_ms_render_active := 0.0
	var total_vram_mb_render_active := 0.0
	var total_other_ms_render_active := 0.0
	var max_total_ms_render_active := 0.0
	var frames_over_budget_render_active := 0
	var frames_over_40ms_render_active := 0
	var frames_over_50ms_render_active := 0

	for index in range(start_index, samples.size()):
		var entry: Dictionary = samples[index]
		if index == start_index:
			first_entry = entry
		last_entry = entry
		total_fps += float(entry.get("fps", 0.0))
		total_draw_calls += float(entry.get("draw_calls", 0))
		total_objects += float(entry.get("objects", 0))
		total_primitives += float(entry.get("primitives", 0))
		total_ms += float(entry.get("total_ms", 0.0))
		total_physics_ms += float(entry.get("physics_ms", 0.0))
		total_navigation_ms += float(entry.get("navigation_ms", 0.0))
		total_vram_mb += float(entry.get("vram_mb", 0.0))
		total_other_ms += float(entry.get("other_ms", 0.0))

		var frame_total_ms := float(entry.get("total_ms", 0.0))
		if frame_total_ms > peak_total_ms:
			peak_total_ms = frame_total_ms
			peak_frame = int(entry.get("frame", 0))
			peak_entry = entry
			peak_top_bucket = str(entry.get("top_measure_bucket", "Unknown"))
			peak_top_measure_name = str(entry.get("top_measure_name", "Unknown"))
			peak_top_measure_ms = float(entry.get("top_measure_ms", 0.0))
			peak_top_measure_pct = float(entry.get("top_measure_pct", 0.0))
		_insert_peak_entry_sample(peak_entries, entry)

		if frame_total_ms >= FRAME_BUDGET_MS:
			frames_over_budget += 1
			total_over_budget_ms += frame_total_ms - FRAME_BUDGET_MS
			current_over_budget_streak += 1
		else:
			longest_over_budget_streak = maxi(longest_over_budget_streak, current_over_budget_streak)
			current_over_budget_streak = 0
		if frame_total_ms >= 40.0:
			frames_over_40ms += 1
			total_over_40ms_ms += frame_total_ms - 40.0
			current_over_40ms_streak += 1
		else:
			longest_over_40ms_streak = maxi(longest_over_40ms_streak, current_over_40ms_streak)
			current_over_40ms_streak = 0
		if frame_total_ms >= 50.0:
			frames_over_50ms += 1
			total_over_50ms_ms += frame_total_ms - 50.0
			current_over_50ms_streak += 1
		else:
			longest_over_50ms_streak = maxi(longest_over_50ms_streak, current_over_50ms_streak)
			current_over_50ms_streak = 0

		var bucket := str(entry.get("top_measure_bucket", "Unknown"))
		bucket_counts[bucket] = int(bucket_counts.get(bucket, 0)) + 1
		if bool(entry.get("terrain_runtime_power_world_work_suspended", false)):
			terrain_runtime_power_world_work_suspended_samples += 1
		var render_loop_suspended := bool(entry.get("terrain_runtime_power_render_loop_suspended", false))
		if render_loop_suspended:
			terrain_runtime_power_render_loop_suspended_samples += 1
		else:
			render_active_sample_count += 1
			total_fps_render_active += float(entry.get("fps", 0.0))
			total_draw_calls_render_active += float(entry.get("draw_calls", 0))
			total_objects_render_active += float(entry.get("objects", 0))
			total_primitives_render_active += float(entry.get("primitives", 0))
			total_ms_render_active += frame_total_ms
			total_physics_ms_render_active += float(entry.get("physics_ms", 0.0))
			total_navigation_ms_render_active += float(entry.get("navigation_ms", 0.0))
			total_vram_mb_render_active += float(entry.get("vram_mb", 0.0))
			total_other_ms_render_active += float(entry.get("other_ms", 0.0))
			max_total_ms_render_active = maxf(max_total_ms_render_active, frame_total_ms)
			if frame_total_ms >= FRAME_BUDGET_MS:
				frames_over_budget_render_active += 1
			if frame_total_ms >= 40.0:
				frames_over_40ms_render_active += 1
			if frame_total_ms >= 50.0:
				frames_over_50ms_render_active += 1

	longest_over_budget_streak = maxi(longest_over_budget_streak, current_over_budget_streak)
	longest_over_40ms_streak = maxi(longest_over_40ms_streak, current_over_40ms_streak)
	longest_over_50ms_streak = maxi(longest_over_50ms_streak, current_over_50ms_streak)

	var dominant_bucket := _get_dominant_bucket(bucket_counts)
	var avg_total_ms := total_ms / sample_count
	var avg_draw_calls := total_draw_calls / sample_count
	var avg_objects := total_objects / sample_count
	var avg_primitives := total_primitives / sample_count
	var avg_physics_ms := total_physics_ms / sample_count
	var avg_navigation_ms := total_navigation_ms / sample_count
	var avg_vram_mb := total_vram_mb / sample_count
	var avg_other_ms := total_other_ms / sample_count
	var avg_fps_render_active := total_fps_render_active / render_active_sample_count if render_active_sample_count > 0 else 0.0
	var avg_draw_calls_render_active := total_draw_calls_render_active / render_active_sample_count if render_active_sample_count > 0 else 0.0
	var avg_objects_render_active := total_objects_render_active / render_active_sample_count if render_active_sample_count > 0 else 0.0
	var avg_primitives_render_active := total_primitives_render_active / render_active_sample_count if render_active_sample_count > 0 else 0.0
	var avg_total_ms_render_active := total_ms_render_active / render_active_sample_count if render_active_sample_count > 0 else 0.0
	var avg_physics_ms_render_active := total_physics_ms_render_active / render_active_sample_count if render_active_sample_count > 0 else 0.0
	var avg_navigation_ms_render_active := total_navigation_ms_render_active / render_active_sample_count if render_active_sample_count > 0 else 0.0
	var avg_vram_mb_render_active := total_vram_mb_render_active / render_active_sample_count if render_active_sample_count > 0 else 0.0
	var avg_other_ms_render_active := total_other_ms_render_active / render_active_sample_count if render_active_sample_count > 0 else 0.0
	var latest_vs_window: Dictionary = {}
	if not last_entry.is_empty():
		latest_vs_window = {
			"total_ms": float(last_entry.get("total_ms", 0.0)) - avg_total_ms,
			"draw_calls": float(last_entry.get("draw_calls", 0)) - avg_draw_calls,
			"objects": float(last_entry.get("objects", 0)) - avg_objects,
			"primitives": float(last_entry.get("primitives", 0)) - avg_primitives,
			"physics_ms": float(last_entry.get("physics_ms", 0.0)) - avg_physics_ms,
			"navigation_ms": float(last_entry.get("navigation_ms", 0.0)) - avg_navigation_ms,
			"vram_mb": float(last_entry.get("vram_mb", 0.0)) - avg_vram_mb,
			"other_ms": float(last_entry.get("other_ms", 0.0)) - avg_other_ms
		}

	return {
		"sample_count": sample_count,
		"start_frame": int(first_entry.get("frame", -1)),
		"end_frame": int(last_entry.get("frame", -1)),
		"avg_fps": total_fps / sample_count,
		"avg_draw_calls": avg_draw_calls,
		"avg_objects": avg_objects,
		"avg_primitives": avg_primitives,
		"avg_total_ms": avg_total_ms,
		"avg_physics_ms": avg_physics_ms,
		"avg_navigation_ms": avg_navigation_ms,
		"avg_vram_mb": avg_vram_mb,
		"avg_other_ms": avg_other_ms,
		"max_total_ms": peak_total_ms if peak_total_ms >= 0.0 else 0.0,
		"max_total_frame": peak_frame,
		"frames_over_budget": frames_over_budget,
		"frames_over_40ms": frames_over_40ms,
		"frames_over_50ms": frames_over_50ms,
		"stall_over_budget_ms": total_over_budget_ms,
		"stall_over_40ms_ms": total_over_40ms_ms,
		"stall_over_50ms_ms": total_over_50ms_ms,
		"longest_over_budget_streak": longest_over_budget_streak,
		"longest_over_40ms_streak": longest_over_40ms_streak,
		"longest_over_50ms_streak": longest_over_50ms_streak,
		"peak_top_bucket": peak_top_bucket,
		"peak_top_measure_name": peak_top_measure_name,
		"peak_top_measure_ms": peak_top_measure_ms,
		"peak_top_measure_pct": peak_top_measure_pct,
		"peak_entry_sample": peak_entry.duplicate(true) if not peak_entry.is_empty() else {},
		"peak_entry_samples": _duplicate_peak_entry_samples(peak_entries),
		"stable_top_bucket": str(dominant_bucket.get("bucket", "Unknown")),
		"stable_top_bucket_count": int(dominant_bucket.get("count", 0)),
		"top_bucket_counts": bucket_counts,
		"baseline_comparison": latest_vs_window,
		"pipeline_compilations_canvas_delta": _pipeline_compilation_delta(first_entry, last_entry, "pipeline_compilations_canvas"),
		"pipeline_compilations_mesh_delta": _pipeline_compilation_delta(first_entry, last_entry, "pipeline_compilations_mesh"),
		"pipeline_compilations_surface_delta": _pipeline_compilation_delta(first_entry, last_entry, "pipeline_compilations_surface"),
		"pipeline_compilations_draw_delta": _pipeline_compilation_delta(first_entry, last_entry, "pipeline_compilations_draw"),
		"pipeline_compilations_specialization_delta": _pipeline_compilation_delta(first_entry, last_entry, "pipeline_compilations_specialization"),
		"pipeline_compilations_total_delta": _pipeline_compilation_delta(first_entry, last_entry, "pipeline_compilations_total"),
		"pipeline_compilations_total_start": int(first_entry.get("pipeline_compilations_total", 0)),
		"pipeline_compilations_total_end": int(last_entry.get("pipeline_compilations_total", 0)),
		"terrain_runtime_power_world_work_suspended_samples": terrain_runtime_power_world_work_suspended_samples,
		"terrain_runtime_power_render_loop_suspended_samples": terrain_runtime_power_render_loop_suspended_samples,
		"render_active_sample_count": render_active_sample_count,
		"avg_fps_render_active": avg_fps_render_active,
		"avg_draw_calls_render_active": avg_draw_calls_render_active,
		"avg_objects_render_active": avg_objects_render_active,
		"avg_primitives_render_active": avg_primitives_render_active,
		"avg_total_ms_render_active": avg_total_ms_render_active,
		"avg_physics_ms_render_active": avg_physics_ms_render_active,
		"avg_navigation_ms_render_active": avg_navigation_ms_render_active,
		"avg_vram_mb_render_active": avg_vram_mb_render_active,
		"avg_other_ms_render_active": avg_other_ms_render_active,
		"max_total_ms_render_active": max_total_ms_render_active,
		"frames_over_budget_render_active": frames_over_budget_render_active,
		"frames_over_40ms_render_active": frames_over_40ms_render_active,
		"frames_over_50ms_render_active": frames_over_50ms_render_active,
		"latest_town_state": _town_entry_latest_town_state.duplicate(true),
		"latest_entities_state": _town_entry_latest_entities_state.duplicate(true)
	}


func _pipeline_compilation_delta(first_entry: Dictionary, last_entry: Dictionary, key: String) -> int:
	if first_entry.is_empty() or last_entry.is_empty():
		return 0
	return maxi(0, int(last_entry.get(key, 0)) - int(first_entry.get(key, 0)))


func _build_native_town_entry_window_range(samples: Array[Dictionary], start_index: int, end_index: int) -> Dictionary:
	if samples.is_empty():
		return _build_empty_native_town_entry_window()
	var safe_start := clampi(start_index, 0, samples.size())
	var safe_end := clampi(end_index, safe_start, samples.size())
	var range_size := safe_end - safe_start
	if range_size <= 0:
		return _build_empty_native_town_entry_window()
	var sliced: Array[Dictionary] = []
	for index in range(safe_start, safe_end):
		var entry: Dictionary = samples[index]
		sliced.append(entry)
	return _build_native_town_entry_window(sliced, sliced.size())


func _maybe_write_prehold_snapshot() -> void:
	if not prehold_periodic_snapshots_enabled:
		return
	if _hold_started_sample_index >= 0 or pending_quit:
		return
	if next_prehold_snapshot_elapsed_seconds < 0.0:
		return
	if town_entry_capture_elapsed_seconds < next_prehold_snapshot_elapsed_seconds:
		return

	prehold_snapshot_write_count += 1
	last_prehold_snapshot_elapsed_seconds = town_entry_capture_elapsed_seconds
	_emit_scope_event("town_stall_test", "prehold_snapshot_written", {
		"capture_elapsed_seconds": town_entry_capture_elapsed_seconds,
		"write_count": prehold_snapshot_write_count,
		"phase": str(phase)
	})
	_write_native_town_entry_snapshot()
	next_prehold_snapshot_elapsed_seconds += prehold_snapshot_interval_seconds


func _get_directional_render_sequence() -> Array[Dictionary]:
	return [
		{"label": "forward", "yaw_degrees": 0.0, "pitch_degrees": 0.0},
		{"label": "right", "yaw_degrees": 90.0, "pitch_degrees": 0.0},
		{"label": "back", "yaw_degrees": 180.0, "pitch_degrees": 0.0},
		{"label": "left", "yaw_degrees": -90.0, "pitch_degrees": 0.0},
		{"label": "sky", "yaw_degrees": 0.0, "pitch_degrees": -55.0},
		{"label": "ground", "yaw_degrees": 0.0, "pitch_degrees": 35.0}
	]


func _reset_directional_render_sampling_state() -> void:
	directional_render_current_label = ""
	directional_render_current_segment_index = -1
	directional_render_started = false
	directional_render_base_yaw = 0.0


func _begin_directional_render_sampling() -> void:
	if not directional_render_sampling_enabled:
		return
	if is_instance_valid(player):
		directional_render_base_yaw = player.rotation.y
	else:
		directional_render_base_yaw = 0.0
	directional_render_started = true
	directional_render_current_label = ""
	directional_render_current_segment_index = -1
	_emit_scope_event("town_stall_test", "directional_render_sampling_started", {
		"sample_seconds": directional_render_sample_seconds,
		"settle_seconds": directional_render_settle_seconds,
		"sequence_count": _get_directional_render_sequence().size()
	})


func _update_directional_render_sampling() -> void:
	if not directional_render_sampling_enabled or not directional_render_started:
		return

	var sequence := _get_directional_render_sequence()
	if sequence.is_empty() or directional_render_sample_seconds <= 0.0:
		directional_render_current_label = ""
		directional_render_current_segment_index = -1
		return

	var segment_index := int(floor(phase_time / directional_render_sample_seconds))
	if segment_index < 0 or segment_index >= sequence.size():
		directional_render_current_label = ""
		directional_render_current_segment_index = -1
		return

	var segment: Dictionary = sequence[segment_index]
	var label := str(segment.get("label", ""))
	var yaw_degrees := float(segment.get("yaw_degrees", 0.0))
	var pitch_degrees := float(segment.get("pitch_degrees", 0.0))
	var segment_elapsed := phase_time - float(segment_index) * directional_render_sample_seconds

	if segment_index != directional_render_current_segment_index:
		directional_render_current_segment_index = segment_index
		_emit_scope_event("town_stall_test", "directional_render_segment_started", {
			"label": label,
			"segment_index": segment_index,
			"yaw_degrees": yaw_degrees,
			"pitch_degrees": pitch_degrees,
			"phase_time": phase_time
		})

	_set_directional_render_view(yaw_degrees, pitch_degrees)
	directional_render_current_label = label if segment_elapsed >= directional_render_settle_seconds else ""


func _set_directional_render_view(yaw_degrees: float, pitch_degrees: float) -> void:
	if not is_instance_valid(player):
		return

	var camera := player.get_node_or_null("Camera3D") as Camera3D
	if not is_instance_valid(camera):
		camera = get_viewport().get_camera_3d()
	if not is_instance_valid(camera):
		return

	player.rotation.y = directional_render_base_yaw + deg_to_rad(yaw_degrees)
	camera.rotation.x = clampf(deg_to_rad(pitch_degrees), deg_to_rad(-85.0), deg_to_rad(85.0))


func _build_directional_render_sampling_snapshot() -> Dictionary:
	var sequence := _get_directional_render_sequence()
	var windows: Dictionary = {}
	var completed_labels: Array[String] = []

	for segment in sequence:
		var segment_dict: Dictionary = segment
		var label := str(segment_dict.get("label", ""))
		if label.is_empty():
			continue
		var label_samples: Array[Dictionary] = []
		for sample in _town_entry_samples:
			var sample_dict: Dictionary = sample
			if str(sample_dict.get("directional_render_label", "")) == label:
				label_samples.append(sample_dict)
		if label_samples.is_empty():
			windows[label] = _build_empty_native_town_entry_window()
			continue
		var window := _build_native_town_entry_window(label_samples, label_samples.size())
		var first_sample: Dictionary = label_samples.front()
		var last_sample: Dictionary = label_samples.back()
		var start_epoch := float(first_sample.get("epoch", 0.0))
		var end_epoch := float(last_sample.get("epoch", 0.0))
		window["start_epoch"] = start_epoch
		window["end_epoch"] = end_epoch
		window["duration_seconds"] = maxf(0.0, end_epoch - start_epoch)
		window["yaw_degrees"] = float(segment_dict.get("yaw_degrees", 0.0))
		window["pitch_degrees"] = float(segment_dict.get("pitch_degrees", 0.0))
		windows[label] = window
		completed_labels.append(label)

	return {
		"enabled": true,
		"sample_seconds": directional_render_sample_seconds,
		"settle_seconds": directional_render_settle_seconds,
		"sequence": sequence,
		"completed_labels": completed_labels,
		"windows": windows
	}


func _insert_peak_entry_sample(peak_entries: Array[Dictionary], entry: Dictionary) -> void:
	if entry.is_empty():
		return

	peak_entries.append(entry)
	while peak_entries.size() > PEAK_ENTRY_SAMPLE_LIMIT:
		var lowest_index := 0
		var lowest_ms := 1.0e20
		for index in range(peak_entries.size()):
			var candidate: Dictionary = peak_entries[index]
			var candidate_ms := float(candidate.get("total_ms", 0.0))
			if candidate_ms < lowest_ms:
				lowest_ms = candidate_ms
				lowest_index = index
		peak_entries.remove_at(lowest_index)


func _duplicate_peak_entry_samples(peak_entries: Array[Dictionary]) -> Array:
	var output: Array = []
	var remaining := peak_entries.duplicate()
	while not remaining.is_empty():
		var highest_index := 0
		var highest_ms := -1.0
		for index in range(remaining.size()):
			var candidate: Dictionary = remaining[index]
			var candidate_ms := float(candidate.get("total_ms", 0.0))
			if candidate_ms > highest_ms:
				highest_ms = candidate_ms
				highest_index = index
		var selected: Dictionary = remaining[highest_index]
		output.append(selected.duplicate(true))
		remaining.remove_at(highest_index)
	return output


func _get_node_telemetry(node: Node) -> Dictionary:
	if not is_instance_valid(node):
		return {}

	var telemetry: Dictionary = {}
	if node.has_method("get_telemetry_snapshot"):
		var telemetry_snapshot: Variant = node.call("get_telemetry_snapshot")
		if typeof(telemetry_snapshot) == TYPE_DICTIONARY:
			telemetry = telemetry_snapshot
	if node.has_method("get_activity_snapshot"):
		var activity_snapshot: Variant = node.call("get_activity_snapshot")
		if typeof(activity_snapshot) == TYPE_DICTIONARY:
			telemetry["activity"] = activity_snapshot
	return telemetry


func _find_manager_node(group_name: String, fallback_name: String) -> Node:
	var node := get_tree().get_first_node_in_group(group_name)
	if is_instance_valid(node):
		return node

	if is_instance_valid(game_root):
		var fallback := game_root.find_child(fallback_name, true, false)
		if is_instance_valid(fallback):
			return fallback

	return null


func _collect_system_telemetry() -> Dictionary:
	var telemetry: Dictionary = {}

	var terrain_manager_node := _find_manager_node("terrain_manager", "TerrainManager")
	if terrain_manager_node:
		telemetry["terrain_manager"] = _get_node_telemetry(terrain_manager_node)

	var building_manager_node := _find_manager_node("building_manager", "BuildingManager")
	if building_manager_node:
		telemetry["building_manager"] = _get_node_telemetry(building_manager_node)

	var vegetation_manager_node := _find_manager_node("vegetation_manager", "VegetationManager")
	if vegetation_manager_node:
		telemetry["vegetation_manager"] = _get_node_telemetry(vegetation_manager_node)

	var prefab_spawner_node := _find_manager_node("prefab_spawner", "PrefabSpawner")
	if prefab_spawner_node:
		telemetry["prefab_spawner"] = _get_node_telemetry(prefab_spawner_node)

	var entity_manager_node := _find_manager_node("entity_manager", "EntityManager")
	if entity_manager_node:
		telemetry["entity_manager"] = _get_node_telemetry(entity_manager_node)

	var vehicle_manager_node := _find_manager_node("vehicle_manager", "VehicleManager")
	if vehicle_manager_node:
		telemetry["vehicle_manager"] = _get_node_telemetry(vehicle_manager_node)

	var player_hud_node := _find_manager_node("player_hud", "PlayerHUD")
	if player_hud_node:
		telemetry["player_hud"] = _get_node_telemetry(player_hud_node)

	var hud_minimap_node := _find_manager_node("hud_minimap", "Minimap")
	if hud_minimap_node:
		telemetry["hud_minimap"] = _get_node_telemetry(hud_minimap_node)

	var save_manager_node := get_node_or_null("/root/SaveManager")
	if save_manager_node:
		telemetry["save_manager"] = _get_node_telemetry(save_manager_node)

	var player_node := get_tree().get_first_node_in_group("player")
	if is_instance_valid(player_node):
		var player_interaction_node := player_node.get_node_or_null("Components/Interaction")
		if player_interaction_node:
			telemetry["player_interaction"] = _get_node_telemetry(player_interaction_node)
		var terrain_interaction_node := player_node.get_node_or_null("Modes/TerrainInteraction")
		if terrain_interaction_node:
			telemetry["terrain_interaction"] = _get_node_telemetry(terrain_interaction_node)

	return telemetry


func _build_pressure_entry(name: String, pressure_score: float, summary: String) -> Dictionary:
	return {
		"name": name,
		"pressure_score": pressure_score,
		"summary": summary
	}


func _sort_pressure_entry_desc(a: Dictionary, b: Dictionary) -> bool:
	var a_score := float(a.get("pressure_score", 0.0))
	var b_score := float(b.get("pressure_score", 0.0))
	if a_score == b_score:
		return str(a.get("name", "")) < str(b.get("name", ""))
	return a_score > b_score


func _build_system_pressure_ranking(system_telemetry: Dictionary, _town_window: Dictionary) -> Array[Dictionary]:
	var rankings: Array[Dictionary] = []

	var building: Dictionary = system_telemetry.get("building_manager", {})
	if not building.is_empty():
		var building_score := float(building.get("total_object_nodes", 0)) * 6.0 \
			+ float(building.get("total_global_visual_instances", 0)) * 1.0 \
			+ float(building.get("visible_global_visual_batch_surfaces", 0)) * 12.0 \
			+ float(building.get("visible_world_map_baked_building_visual_surfaces", 0)) * 8.0 \
			+ float(building.get("total_visual_batches", 0)) * 12.0 \
			+ float(building.get("total_object_collision_nodes", 0)) * 0.5 \
			+ float(building.get("total_collision_box_nodes", 0)) * 0.25 \
			+ float(building.get("pending_world_map_baked_building_apply_phases", 0)) * 8.0 \
			+ float(building.get("last_world_map_baked_building_apply_queue_ms", 0.0)) * 8.0 \
			+ float(building.get("pending_visual_batch_rebuilds", 0)) * 10.0 \
			+ float(building.get("pending_world_map_baked_object_spawns", 0)) * 6.0 \
			+ float(building.get("last_world_map_baked_object_spawn_queue_ms", 0.0)) * 8.0 \
			+ float(building.get("pending_object_collision_jobs", 0)) * 4.0 \
			+ float(building.get("dirty_visible_chunk_count", 0)) * 8.0
		rankings.append(_build_pressure_entry(
			"BuildingManager",
			building_score,
			"objects=%d object_nodes=%d visual_batches=%d global_instances=%d global_surfaces=%d baked_surfaces=%d baked_apply=%d/%d %.2fms baked_object_queue=%d/%d %.2fms dirty_visible=%d" % [
				int(building.get("total_objects", 0)),
				int(building.get("total_object_nodes", 0)),
				int(building.get("total_visual_batches", 0)),
				int(building.get("total_global_visual_instances", 0)),
				int(building.get("visible_global_visual_batch_surfaces", 0)),
				int(building.get("visible_world_map_baked_building_visual_surfaces", 0)),
				int(building.get("pending_world_map_baked_building_apply_phases", 0)),
				int(building.get("last_world_map_baked_building_apply_queue_count", 0)),
				float(building.get("last_world_map_baked_building_apply_queue_ms", 0.0)),
				int(building.get("pending_world_map_baked_object_spawns", 0)),
				int(building.get("last_world_map_baked_object_spawn_queue_count", 0)),
				float(building.get("last_world_map_baked_object_spawn_queue_ms", 0.0)),
				int(building.get("dirty_visible_chunk_count", 0))
			]
		))

	var terrain: Dictionary = system_telemetry.get("terrain_manager", {})
	if not terrain.is_empty():
		var terrain_score := float(terrain.get("rendered_terrain_chunk_count", 0)) * 6.0 \
			+ float(terrain.get("rendered_water_chunk_count", 0)) * 3.0 \
			+ float(terrain.get("active_chunk_count", 0)) * 2.0 \
			+ float(terrain.get("pending_chunk_count", 0)) * 8.0 \
			+ float(terrain.get("pending_node_count", 0)) * 5.0 \
			+ float(terrain.get("pending_batch_count", 0)) * 3.0 \
			+ float(terrain.get("task_queue_count", 0)) * 2.0 \
			+ float(terrain.get("cpu_task_queue_count", 0)) * 2.0 \
			+ float(terrain.get("pending_spawn_zone_count", 0)) * 6.0 \
			+ float(terrain.get("loaded_dirty_chunk_count", 0)) * 4.0
		rankings.append(_build_pressure_entry(
			"TerrainManager",
			terrain_score,
			"active_chunks=%d loaded=%d pending=%d rendered=%d/%d dirty=%d world_lod=%d far_lod=%d" % [
				int(terrain.get("active_chunk_count", 0)),
				int(terrain.get("loaded_chunk_count", 0)),
				int(terrain.get("pending_chunk_count", 0)),
				int(terrain.get("rendered_terrain_chunk_count", 0)),
				int(terrain.get("rendered_water_chunk_count", 0)),
				int(terrain.get("loaded_dirty_chunk_count", 0)),
				int(terrain.get("world_map_lod_chunk_count", 0)),
				int(terrain.get("world_map_terrain_batch_far_lod_chunk_count", 0))
			]
		))

	var vegetation: Dictionary = system_telemetry.get("vegetation_manager", {})
	if not vegetation.is_empty():
		var global_render_batches_enabled := bool(vegetation.get("global_render_batches_enabled", false))
		var global_render_dirty_kinds: Array = vegetation.get("global_render_dirty_kinds", [])
		var visual_chunk_pressure_scale := 0.25 if global_render_batches_enabled else 1.0
		var vegetation_score := float(vegetation.get("tree_chunk_count", 0)) * 4.0 * visual_chunk_pressure_scale \
			+ float(vegetation.get("grass_chunk_count", 0)) * 3.0 * visual_chunk_pressure_scale \
			+ float(vegetation.get("rock_chunk_count", 0)) * 2.0 * visual_chunk_pressure_scale \
			+ float(vegetation.get("active_tree_colliders", 0)) * 3.0 \
			+ float(vegetation.get("active_grass_colliders", 0)) * 2.0 \
			+ float(vegetation.get("active_rock_colliders", 0)) * 2.0 \
			+ float(vegetation.get("pending_chunks", 0)) * 4.0 \
			+ float(vegetation.get("pending_collider_adds", 0)) * 1.0 \
			+ float(vegetation.get("pending_collider_removes", 0)) * 1.0 \
			+ float(global_render_dirty_kinds.size()) * 20.0 \
			+ float(vegetation.get("last_global_render_sync_ms", 0.0)) * 8.0
		rankings.append(_build_pressure_entry(
			"VegetationManager",
			vegetation_score,
			"trees=%d grass=%d rocks=%d colliders=%d/%d/%d pending=%d global_batches=%d instances=%d/%d/%d dirty=%d last_global_sync=%.2fms" % [
				int(vegetation.get("tree_chunk_count", 0)),
				int(vegetation.get("grass_chunk_count", 0)),
				int(vegetation.get("rock_chunk_count", 0)),
				int(vegetation.get("active_tree_colliders", 0)),
				int(vegetation.get("active_grass_colliders", 0)),
				int(vegetation.get("active_rock_colliders", 0)),
				int(vegetation.get("pending_chunks", 0)),
				int(vegetation.get("global_render_batch_count", 0)),
				int(vegetation.get("global_tree_render_instances", 0)),
				int(vegetation.get("global_grass_render_instances", 0)),
				int(vegetation.get("global_rock_render_instances", 0)),
				global_render_dirty_kinds.size(),
				float(vegetation.get("last_global_render_sync_ms", 0.0))
			]
		))

	var prefab_spawner: Dictionary = system_telemetry.get("prefab_spawner", {})
	if not prefab_spawner.is_empty():
		var prefab_score := float(prefab_spawner.get("pending_spawn_jobs", 0)) * 10.0 \
			+ float(prefab_spawner.get("pending_spawn_keys", 0)) * 3.0 \
			+ float(prefab_spawner.get("pending_world_map_baked_payload_build_jobs", 0)) * 10.0 \
			+ float(prefab_spawner.get("last_world_map_baked_payload_build_queue_ms", 0.0)) * 8.0 \
			+ float(prefab_spawner.get("pending_world_map_baked_payload_jobs", 0)) * 12.0 \
			+ float(prefab_spawner.get("last_world_map_baked_payload_apply_ms", 0.0)) * 8.0 \
			+ float(prefab_spawner.get("last_world_map_baked_payload_flush_ms", 0.0)) * 8.0 \
			+ float(prefab_spawner.get("spawned_doors", 0)) * 0.5 \
			+ float(prefab_spawner.get("rotated_block_batches_cache_size", 0)) * 0.1
		rankings.append(_build_pressure_entry(
			"PrefabSpawner",
			prefab_score,
			"pending_jobs=%d pending_keys=%d baked_build=%d/%d %.2fms baked_queue=%d baked_apply=%d/%.2fms baked_flush=%.2fms spawned=%d doors=%d" % [
				int(prefab_spawner.get("pending_spawn_jobs", 0)),
				int(prefab_spawner.get("pending_spawn_keys", 0)),
				int(prefab_spawner.get("pending_world_map_baked_payload_build_jobs", 0)),
				int(prefab_spawner.get("last_world_map_baked_payload_build_queue_count", 0)),
				float(prefab_spawner.get("last_world_map_baked_payload_build_queue_ms", 0.0)),
				int(prefab_spawner.get("pending_world_map_baked_payload_jobs", 0)),
				int(prefab_spawner.get("last_world_map_baked_payload_apply_count", 0)),
				float(prefab_spawner.get("last_world_map_baked_payload_apply_ms", 0.0)),
				float(prefab_spawner.get("last_world_map_baked_payload_flush_ms", 0.0)),
				int(prefab_spawner.get("spawned_positions", 0)),
				int(prefab_spawner.get("spawned_doors", 0))
			]
		))

	var entities: Dictionary = system_telemetry.get("entity_manager", {})
	if not entities.is_empty():
		var active_physics_entities := maxi(0, int(entities.get("active_entities", 0)) - int(entities.get("frozen_entities", 0)))
		var entity_score := float(active_physics_entities) * 8.0 \
			+ float(entities.get("frozen_entities", 0)) * 1.0 \
			+ float(entities.get("dormant_entities", 0)) * 1.0 \
			+ float(entities.get("pending_spawns", 0)) * 8.0 \
			+ float(entities.get("last_proximity_update_ms", 0.0)) * 8.0 \
			+ float(entities.get("last_spawn_queue_update_ms", 0.0)) * 8.0 \
			+ float(entities.get("spawned_chunks", 0)) * 0.25 \
			+ float(entities.get("entity_pool_size", 0)) * 0.25
		rankings.append(_build_pressure_entry(
			"EntityManager",
			entity_score,
			"active=%d active_physics=%d frozen=%d dormant=%d pending=%d prox=%.2fms spawn_queue=%.2fms spawned_chunks=%d" % [
				int(entities.get("active_entities", 0)),
				active_physics_entities,
				int(entities.get("frozen_entities", 0)),
				int(entities.get("dormant_entities", 0)),
				int(entities.get("pending_spawns", 0)),
				float(entities.get("last_proximity_update_ms", 0.0)),
				float(entities.get("last_spawn_queue_update_ms", 0.0)),
				int(entities.get("spawned_chunks", 0))
			]
		))

	var vehicles: Dictionary = system_telemetry.get("vehicle_manager", {})
	if not vehicles.is_empty():
		var vehicle_score := float(vehicles.get("vehicle_count", 0)) * 2.0
		if bool(vehicles.get("current_player_vehicle_active", false)):
			vehicle_score += 5.0
		rankings.append(_build_pressure_entry(
			"VehicleManager",
			vehicle_score,
			"vehicles=%d current_player_vehicle=%s" % [
				int(vehicles.get("vehicle_count", 0)),
				"true" if bool(vehicles.get("current_player_vehicle_active", false)) else "false"
			]
		))

	rankings.sort_custom(Callable(self, "_sort_pressure_entry_desc"))
	return rankings


func _write_native_town_entry_snapshot() -> void:
	if _town_entry_snapshot_stamp.is_empty():
		_town_entry_snapshot_stamp = _make_timestamp_slug()

	var snapshot_dir := PERFORMANCE_SNAPSHOT_DIR if PERFORMANCE_SNAPSHOT_DIR.ends_with("/") else PERFORMANCE_SNAPSHOT_DIR + "/"
	if not DirAccess.dir_exists_absolute(snapshot_dir):
		var user_root := DirAccess.open("user://")
		if not user_root:
			push_warning("[TownStallTest] Failed to open user:// root for snapshot directory")
			return
		var debug_err := user_root.make_dir("debug")
		if debug_err != OK and debug_err != ERR_ALREADY_EXISTS:
			push_warning("[TownStallTest] Failed to create snapshot base user://debug (err %d)" % debug_err)
			return
		var debug_dir := DirAccess.open("user://debug")
		if not debug_dir:
			push_warning("[TownStallTest] Failed to open user://debug for snapshot directory")
			return
		var perf_err := debug_dir.make_dir("performance")
		if perf_err != OK and perf_err != ERR_ALREADY_EXISTS:
			push_warning("[TownStallTest] Failed to create snapshot directory: %s (err %d)" % [PERFORMANCE_SNAPSHOT_DIR, perf_err])
			return

	var town_window := _build_native_town_entry_window(_town_entry_samples, _town_entry_samples.size())
	var recent_window := _build_native_town_entry_window(_town_entry_samples, TOWN_ENTRY_WINDOW_RECENT_LIMIT)
	var moving_end_index := _hold_started_sample_index if _hold_started_sample_index >= 0 else _town_entry_samples.size()
	var hold_end_index := _hold_completed_sample_index if _hold_completed_sample_index >= 0 else _town_entry_samples.size()
	var moving_entry_window := _build_native_town_entry_window_range(_town_entry_samples, 0, moving_end_index)
	var stationary_hold_window := _build_native_town_entry_window_range(_town_entry_samples, moving_end_index, hold_end_index)
	var stable_bucket := str(town_window.get("stable_top_bucket", "Unknown"))
	var stable_bucket_count := int(town_window.get("stable_top_bucket_count", 0))
	if stable_bucket.is_empty() or stable_bucket == "Unknown":
		stable_bucket = str(recent_window.get("stable_top_bucket", "Unknown"))
		stable_bucket_count = int(recent_window.get("stable_top_bucket_count", 0))

	var system_telemetry := _collect_system_telemetry()
	var system_pressure_ranking := _build_system_pressure_ranking(system_telemetry, town_window)

	var snapshot := {
		"average_fps": town_window.get("avg_fps", 0.0),
		"avg_draw_calls": town_window.get("avg_draw_calls", 0.0),
		"avg_vram_mb": town_window.get("avg_vram_mb", 0.0),
		"avg_physics_ms": town_window.get("avg_physics_ms", 0.0),
		"avg_navigation_ms": town_window.get("avg_navigation_ms", 0.0),
		"max_frame_ms": town_window.get("max_total_ms", 0.0),
		"spike_count": int(town_window.get("frames_over_budget", 0)),
		"session_started_at": _town_entry_snapshot_stamp,
		"stable_top_bucket": stable_bucket,
		"stable_top_bucket_count": stable_bucket_count,
		"top_bucket_counts": town_window.get("top_bucket_counts", {}),
		"town_entry_capture_reason": _town_entry_capture_reason,
		"recent_spike_window": recent_window,
		"town_entry_window": town_window,
		"moving_entry_window": moving_entry_window,
		"stationary_hold_window": stationary_hold_window,
		"hold_started_sample_index": _hold_started_sample_index,
		"hold_completed_sample_index": _hold_completed_sample_index,
		"hold_settle_elapsed_seconds": hold_settle_elapsed_seconds,
		"hold_settle_stable_frames": hold_settle_stable_frames,
		"hold_settle_timed_out": hold_settle_timed_out,
		"latest_town_state": town_window.get("latest_town_state", {}),
		"baseline_comparison": town_window.get("baseline_comparison", recent_window.get("baseline_comparison", {})),
		"runtime_mode": runtime_mode,
		"render_features": _collect_render_features_snapshot(),
		"benchmark_phase": str(phase),
		"benchmark_phase_time": phase_time,
		"benchmark_hold_seconds": current_hold_seconds,
		"benchmark_pending_quit": pending_quit,
		"benchmark_hold_complete": _hold_completed_sample_index >= 0,
		"town_entry_capture_elapsed_seconds": town_entry_capture_elapsed_seconds,
		"prehold_periodic_snapshots": prehold_periodic_snapshots_enabled,
		"prehold_snapshot_interval_seconds": prehold_snapshot_interval_seconds,
		"prehold_snapshot_write_count": prehold_snapshot_write_count,
		"last_prehold_snapshot_elapsed_seconds": last_prehold_snapshot_elapsed_seconds,
		"machine_state": _machine_state.duplicate(true) if not _machine_state.is_empty() else {},
		"warmup_note": str(_machine_state.get("warmup_note", "")),
		"system_telemetry": system_telemetry,
		"system_pressure_ranking": system_pressure_ranking
	}

	if not _scope_states.is_empty():
		snapshot["scope_states"] = _scope_states.duplicate(true)
	if not _recent_scope_events.is_empty():
		snapshot["recent_scope_events"] = _recent_scope_events.duplicate(true)
	if directional_render_sampling_enabled:
		snapshot["directional_render_sampling"] = _build_directional_render_sampling_snapshot()
	if render_diagnostics_enabled:
		var render_diagnostics := {
			"enabled": true,
			"threshold_ms": render_diagnostics_threshold_ms,
			"scene_scan_enabled": render_diagnostics_scene_scan_enabled,
			"sample_limit": render_diagnostics_sample_limit,
			"scene_detail_limit": render_diagnostics_scene_detail_limit,
			"frame_scene_scan_limit": render_diagnostics_frame_scene_scan_limit,
			"candidate_count": _render_diagnostic_candidate_count,
			"skipped_count": _render_diagnostic_skipped_count,
			"scene_scan_count": _render_diagnostic_scene_scan_count,
			"sample_count": _render_diagnostic_samples.size(),
			"samples": _render_diagnostic_samples.duplicate(true)
		}
		if render_diagnostics_scene_scan_enabled:
			render_diagnostics["final_scene_scan"] = _collect_render_scene_scan()
			render_diagnostics["final_scene_scan_available"] = true
		snapshot["render_diagnostics"] = render_diagnostics

	_atomic_write_text_file("%ssnapshot_menu_%s.json" % [snapshot_dir, _town_entry_snapshot_stamp], JSON.stringify(snapshot, "\t"))


func _atomic_write_text_file(path: String, content: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[TownStallTest] Failed to open snapshot file for writing: %s" % path)
		return false

	file.store_string(content)
	file.close()

	return true

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	auto_teleport_enabled = OS.get_environment("TOWN_STALL_AUTO_TELEPORT") != "0"
	disable_buildings_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDINGS") == "1"
	disable_building_objects_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_OBJECTS") == "1"
	disable_building_blocks_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_BLOCKS") == "1"
	disable_building_chunk_mesh_render_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_CHUNK_MESH_RENDER") == "1"
	disable_building_visual_batches_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_VISUAL_BATCHES") == "1"
	disable_building_carve_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_CARVE") == "1"
	disable_building_object_collisions_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_OBJECT_COLLISIONS") == "1"
	disable_building_chunk_flush_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_CHUNK_FLUSH") == "1"
	disable_building_chunk_collisions_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_CHUNK_COLLISIONS") == "1"
	disable_terrain_chunk_updates_enabled = OS.get_environment("TOWN_STALL_DISABLE_TERRAIN_CHUNK_UPDATES") == "1"
	disable_terrain_manager_visuals_enabled = OS.get_environment("TOWN_STALL_DISABLE_TERRAIN_MANAGER_VISUALS") == "1"
	disable_vegetation_render_enabled = OS.get_environment("TOWN_STALL_DISABLE_VEGETATION_RENDER") == "1"
	disable_glow_enabled = OS.get_environment("TOWN_STALL_DISABLE_GLOW") == "1"
	disable_water_render_enabled = OS.get_environment("TOWN_STALL_DISABLE_WATER_RENDER") == "1"
	instant_baked_buildings_enabled = OS.get_environment("TOWN_STALL_INSTANT_BAKED_BUILDINGS") != "0"
	baked_building_persistence_smoke_enabled = OS.get_environment("TOWN_STALL_BAKED_BUILDING_PERSISTENCE_SMOKE") == "1"
	baked_building_persistence_smoke_timeout_seconds = _get_positive_env_float("TOWN_STALL_BAKED_BUILDING_PERSISTENCE_TIMEOUT", 60.0)
	disable_entities_enabled = OS.get_environment("TOWN_STALL_DISABLE_ENTITIES") == "1"
	repeat_entry_enabled = OS.get_environment("TOWN_STALL_REPEAT_ENTRY") == "1"
	runtime_mode = OS.get_environment("TOWN_STALL_RUNTIME_MODE").strip_edges()
	if runtime_mode.is_empty():
		runtime_mode = "unknown"
	render_diagnostics_enabled = OS.get_environment("TOWN_STALL_RENDER_DIAGNOSTICS") == "1"
	render_diagnostics_scene_scan_enabled = OS.get_environment("TOWN_STALL_RENDER_DIAGNOSTIC_SCENE_SCAN") == "1"
	render_diagnostics_threshold_ms = _get_positive_env_float("TOWN_STALL_RENDER_DIAGNOSTIC_THRESHOLD_MS", FRAME_BUDGET_MS)
	render_diagnostics_sample_limit = _get_positive_env_int("TOWN_STALL_RENDER_DIAGNOSTIC_LIMIT", RENDER_DIAGNOSTIC_DEFAULT_LIMIT)
	render_diagnostics_scene_detail_limit = _get_positive_env_int("TOWN_STALL_RENDER_DIAGNOSTIC_SCENE_DETAIL_LIMIT", RENDER_DIAGNOSTIC_DEFAULT_SCENE_DETAIL_LIMIT)
	render_diagnostics_frame_scene_scan_limit = _get_positive_env_int("TOWN_STALL_RENDER_DIAGNOSTIC_FRAME_SCENE_SCAN_LIMIT", RENDER_DIAGNOSTIC_DEFAULT_FRAME_SCENE_SCAN_LIMIT)
	directional_render_sampling_enabled = OS.get_environment("TOWN_STALL_DIRECTIONAL_RENDER_SAMPLING") == "1"
	directional_render_sample_seconds = _get_positive_env_float("TOWN_STALL_DIRECTIONAL_RENDER_SAMPLE_SECONDS", DIRECTIONAL_RENDER_SAMPLE_SECONDS)
	directional_render_settle_seconds = _get_positive_env_float("TOWN_STALL_DIRECTIONAL_RENDER_SETTLE_SECONDS", DIRECTIONAL_RENDER_SETTLE_SECONDS)
	low_fps_abort_enabled = OS.get_environment("TOWN_STALL_LOW_FPS_ABORT") != "0"
	low_fps_abort_frame_ms = _get_positive_env_float("TOWN_STALL_LOW_FPS_ABORT_FRAME_MS", 120.0)
	low_fps_abort_seconds = _get_positive_env_float("TOWN_STALL_LOW_FPS_ABORT_SECONDS", 8.0)
	measure_full_flight_enabled = OS.get_environment("TOWN_STALL_MEASURE_FULL_FLIGHT") == "1"
	world_ready_timeout_seconds = _get_positive_env_float("TOWN_STALL_WORLD_READY_TIMEOUT_SECONDS", WORLD_READY_TIMEOUT_SECONDS)
	world_ready_status_log_interval_seconds = _get_positive_env_float("TOWN_STALL_WORLD_READY_STATUS_LOG_INTERVAL_SECONDS", 5.0)
	hold_periodic_snapshots_enabled = OS.get_environment("TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS") == "1"
	prehold_periodic_snapshots_enabled = OS.get_environment("TOWN_STALL_PERIODIC_PREHOLD_SNAPSHOTS") == "1"
	prehold_snapshot_interval_seconds = _get_positive_env_float("TOWN_STALL_PREHOLD_SNAPSHOT_INTERVAL_SECONDS", PREHOLD_SNAPSHOT_INTERVAL_SECONDS)
	hold_wait_stream_ready_enabled = OS.get_environment("TOWN_STALL_WAIT_STREAM_READY_BEFORE_HOLD") != "0"
	configured_hold_seconds = _get_positive_env_float("TOWN_STALL_HOLD_SECONDS", HOLD_SECONDS)
	var max_fps_override := _get_positive_env_int("TOWN_STALL_MAX_FPS", 0)
	if max_fps_override > 0:
		Engine.max_fps = max_fps_override
	var mesh_lod_threshold_override := _get_positive_env_float("TOWN_STALL_MESH_LOD_THRESHOLD", 0.0)
	if mesh_lod_threshold_override > 0.0:
		get_tree().root.mesh_lod_threshold = mesh_lod_threshold_override
	_apply_display_mode_override_from_env()
	print("[TOWN_STALL_TEST] Harness starting")
	print("[TOWN_STALL_TEST] Auto teleport: %s" % ("ON" if auto_teleport_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable buildings: %s" % ("ON" if disable_buildings_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building objects: %s" % ("ON" if disable_building_objects_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building blocks: %s" % ("ON" if disable_building_blocks_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building chunk mesh render: %s" % ("ON" if disable_building_chunk_mesh_render_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building visual batches: %s" % ("ON" if disable_building_visual_batches_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building carve: %s" % ("ON" if disable_building_carve_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building object collisions: %s" % ("ON" if disable_building_object_collisions_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building chunk flush: %s" % ("ON" if disable_building_chunk_flush_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building chunk collisions: %s" % ("ON" if disable_building_chunk_collisions_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable terrain chunk updates: %s" % ("ON" if disable_terrain_chunk_updates_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable terrain manager visuals: %s" % ("ON" if disable_terrain_manager_visuals_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable vegetation render: %s" % ("ON" if disable_vegetation_render_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable glow: %s" % ("ON" if disable_glow_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable water render: %s" % ("ON" if disable_water_render_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Instant baked buildings: %s" % ("ON" if instant_baked_buildings_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Baked building persistence smoke: %s" % ("ON" if baked_building_persistence_smoke_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable entities: %s" % ("ON" if disable_entities_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Repeat entry: %s" % ("ON" if repeat_entry_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Measure full flight: %s" % ("ON" if measure_full_flight_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Periodic hold snapshots: %s" % ("ON" if hold_periodic_snapshots_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Periodic pre-hold snapshots: %s interval=%.1fs" % [
		"ON" if prehold_periodic_snapshots_enabled else "OFF",
		prehold_snapshot_interval_seconds
	])
	print("[TOWN_STALL_TEST] Wait stream ready before hold: %s" % ("ON" if hold_wait_stream_ready_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Runtime mode: %s" % runtime_mode)
	print("[TOWN_STALL_TEST] Engine max FPS: %d" % Engine.max_fps)
	print("[TOWN_STALL_TEST] Mesh LOD threshold: %.2f" % get_tree().root.mesh_lod_threshold)
	print("[TOWN_STALL_TEST] Render diagnostics: %s threshold=%.2f scene_scan=%s limit=%d scene_detail_limit=%d frame_scene_scan_limit=%d" % [
		"ON" if render_diagnostics_enabled else "OFF",
		render_diagnostics_threshold_ms,
		"ON" if render_diagnostics_scene_scan_enabled else "OFF",
		render_diagnostics_sample_limit,
		render_diagnostics_scene_detail_limit,
		render_diagnostics_frame_scene_scan_limit
	])
	print("[TOWN_STALL_TEST] Directional render sampling: %s sample=%.2fs settle=%.2fs" % [
		"ON" if directional_render_sampling_enabled else "OFF",
		directional_render_sample_seconds,
		directional_render_settle_seconds
	])
	print("[TOWN_STALL_TEST] Low-FPS safety abort: %s threshold=%.1fms seconds=%.1f" % [
		"ON" if low_fps_abort_enabled else "OFF",
		low_fps_abort_frame_ms,
		low_fps_abort_seconds
	])
	print("[TOWN_STALL_TEST] Hold seconds: %.1f" % configured_hold_seconds)
	_machine_state = _parse_machine_state_env()
	if not _machine_state.is_empty():
		print("[TOWN_STALL_TEST] Machine state: %s" % _format_machine_state_summary(_machine_state))
		var warmup_note := str(_machine_state.get("warmup_note", ""))
		if not warmup_note.is_empty():
			print("[TOWN_STALL_TEST] Warmup note: %s" % warmup_note)
	_emit_scope_state("town_stall_test", {
		"phase": "start",
		"auto_teleport": auto_teleport_enabled,
		"disable_buildings": disable_buildings_enabled,
		"disable_building_objects": disable_building_objects_enabled,
		"disable_building_blocks": disable_building_blocks_enabled,
		"disable_building_chunk_mesh_render": disable_building_chunk_mesh_render_enabled,
		"disable_building_visual_batches": disable_building_visual_batches_enabled,
		"disable_building_carve": disable_building_carve_enabled,
		"disable_building_object_collisions": disable_building_object_collisions_enabled,
		"disable_building_chunk_flush": disable_building_chunk_flush_enabled,
		"disable_building_chunk_collisions": disable_building_chunk_collisions_enabled,
		"disable_terrain_chunk_updates": disable_terrain_chunk_updates_enabled,
		"disable_terrain_manager_visuals": disable_terrain_manager_visuals_enabled,
		"disable_vegetation_render": disable_vegetation_render_enabled,
		"disable_glow": disable_glow_enabled,
		"disable_water_render": disable_water_render_enabled,
		"instant_baked_buildings": instant_baked_buildings_enabled,
		"baked_building_persistence_smoke": baked_building_persistence_smoke_enabled,
		"disable_entities": disable_entities_enabled,
		"repeat_entry": repeat_entry_enabled,
		"runtime_mode": runtime_mode,
		"render_diagnostics": render_diagnostics_enabled,
		"render_diagnostics_scene_scan": render_diagnostics_scene_scan_enabled,
		"render_diagnostics_threshold_ms": render_diagnostics_threshold_ms,
		"render_diagnostics_sample_limit": render_diagnostics_sample_limit,
		"render_diagnostics_scene_detail_limit": render_diagnostics_scene_detail_limit,
		"render_diagnostics_frame_scene_scan_limit": render_diagnostics_frame_scene_scan_limit,
		"directional_render_sampling": directional_render_sampling_enabled,
		"directional_render_sample_seconds": directional_render_sample_seconds,
		"directional_render_settle_seconds": directional_render_settle_seconds,
		"low_fps_abort_enabled": low_fps_abort_enabled,
		"low_fps_abort_frame_ms": low_fps_abort_frame_ms,
		"low_fps_abort_seconds": low_fps_abort_seconds,
		"measure_full_flight": measure_full_flight_enabled,
		"hold_periodic_snapshots": hold_periodic_snapshots_enabled,
		"prehold_periodic_snapshots": prehold_periodic_snapshots_enabled,
		"prehold_snapshot_interval_seconds": prehold_snapshot_interval_seconds,
		"hold_wait_stream_ready": hold_wait_stream_ready_enabled,
		"hold_seconds": configured_hold_seconds,
		"machine_state_available": not _machine_state.is_empty(),
		"warmup_note": str(_machine_state.get("warmup_note", ""))
	})
	_begin_generation()


func _process(delta: float) -> void:
	phase_time += delta
	if directional_render_sampling_enabled and hold_started_logged and (phase == Phase.HOLD_FIRST or phase == Phase.HOLD_RETURN or phase == Phase.HOLD_SECOND):
		_update_directional_render_sampling()
	if town_entry_capture_started and phase != Phase.DONE and phase != Phase.FAILED and not pending_quit:
		_capture_native_town_entry_sample(delta)

	match phase:
		Phase.WAIT_WORLD_READY:
			_poll_world_ready()
		Phase.TELEPORT:
			_teleport_into_town()
		Phase.FLY_TO_TOWN, Phase.FLY_BACK_TO_ORIGIN, Phase.FLY_TO_TOWN_SECOND:
			_fly_to_town(delta)
		Phase.HOLD_FIRST, Phase.HOLD_RETURN, Phase.HOLD_SECOND:
			_hold_in_town(delta)
		Phase.DONE, Phase.FAILED:
			pass
		_:
			pass


func _begin_generation() -> void:
	world_generator = WorldMapGenScript.new()
	generated_seed = _get_town_stall_seed()
	world_generator.world_seed = generated_seed
	world_generator.terrain_height = 10.0
	world_generator.water_level = 13.0
	world_generator.noise_freq = 0.1
	world_generator.road_spacing = 100.0
	world_generator.use_grid_roads = false
	world_generator.deep_lakes_enabled = true

	print("[TOWN_STALL_TEST] Generating world seed %d..." % generated_seed)
	_emit_scope_event("town_stall_test", "generation_start", {
		"seed": generated_seed
	})

	generation_thread = Thread.new()
	var err: int = generation_thread.start(Callable(self, "_threaded_generate_world"))
	if err != OK:
		_fail("Failed to start generation thread: %d" % err)


func _threaded_generate_world() -> void:
	var images: Dictionary = world_generator.generate_world()
	call_deferred("_on_world_generated", images)


func _on_world_generated(images: Dictionary) -> void:
	if generation_thread:
		generation_thread.wait_to_finish()
	generation_thread = null

	generated_images = images
	var towns_value: Variant = images.get("towns", [])
	if towns_value is Array:
		generated_towns = towns_value
	else:
		generated_towns = []

	if generated_towns.is_empty():
		_fail("World generation completed without towns")
		return

	generated_world_path = SAVE_BASE + "town_stall_%d_%d" % [generated_seed, Time.get_ticks_msec()]
	if not world_generator.save_world(generated_world_path, generated_images):
		_fail("Failed to save generated world to %s" % generated_world_path)
		return

	selected_town = _select_town(generated_towns)
	if selected_town.is_empty():
		_fail("No suitable town found in generated world")
		return

	_emit_scope_event("town_stall_test", "generation_complete", {
		"world_path": generated_world_path,
		"town_count": generated_towns.size(),
		"selected_town_x": float(selected_town.get("x", 0.0)),
		"selected_town_z": float(selected_town.get("z", 0.0)),
		"selected_town_buildings": int(selected_town.get("building_count", 0))
	})

	print("[TOWN_STALL_TEST] World saved to %s" % generated_world_path)
	print("[TOWN_STALL_TEST] Selected town: x=%.1f z=%.1f buildings=%d radius=%.1f" % [
		float(selected_town.get("x", 0.0)),
		float(selected_town.get("z", 0.0)),
		int(selected_town.get("building_count", 0)),
		float(selected_town.get("radius", 0.0))
	])

	_start_game_scene()


func _start_game_scene() -> void:
	var packed_scene := GameScene
	var instanced := packed_scene.instantiate()
	game_root = instanced as Node3D
	if game_root == null:
		_fail("Failed to instance game scene")
		return

	# Town stall tests use a wider default render window than gameplay.
	var render_distance_override := _get_positive_env_int("TOWN_STALL_RENDER_DISTANCE", 10)
	var terrain_render_distance_override := _get_positive_env_int("TOWN_STALL_TERRAIN_RENDER_DISTANCE", render_distance_override)
	var building_render_distance_override := _get_positive_env_int("TOWN_STALL_BUILDING_RENDER_DISTANCE", render_distance_override)
	var terrain_manager_override := game_root.find_child("TerrainManager", true, false)
	if terrain_render_distance_override > 0 and terrain_manager_override and "render_distance" in terrain_manager_override:
		terrain_manager_override.render_distance = terrain_render_distance_override
		print("[TOWN_STALL_TEST] Terrain render distance override: %d" % terrain_render_distance_override)
	var terrain_collision_distance_override := _get_positive_env_int("TOWN_STALL_TERRAIN_COLLISION_DISTANCE", 0)
	if terrain_collision_distance_override > 0 and terrain_manager_override and "collision_distance" in terrain_manager_override:
		terrain_manager_override.collision_distance = terrain_collision_distance_override
		print("[TOWN_STALL_TEST] Terrain collision distance override: %d" % terrain_collision_distance_override)
	var building_manager_override := game_root.find_child("BuildingManager", true, false)
	if building_render_distance_override > 0 and building_manager_override and "render_distance" in building_manager_override:
		building_manager_override.render_distance = building_render_distance_override
		print("[TOWN_STALL_TEST] Building render distance override: %d" % building_render_distance_override)
	var keep_disabled_collision_in_space_override := OS.get_environment("TOWN_STALL_KEEP_DISABLED_TERRAIN_COLLISION_IN_SPACE").strip_edges()
	if not keep_disabled_collision_in_space_override.is_empty():
		var terrain_manager_collision_override := game_root.find_child("TerrainManager", true, false)
		if terrain_manager_collision_override and "keep_disabled_terrain_collision_bodies_in_space" in terrain_manager_collision_override:
			terrain_manager_collision_override.keep_disabled_terrain_collision_bodies_in_space = keep_disabled_collision_in_space_override != "0"
			print("[TOWN_STALL_TEST] Keep disabled terrain collision bodies in space: %s" % ("ON" if terrain_manager_collision_override.keep_disabled_terrain_collision_bodies_in_space else "OFF"))
	var shared_collision_override := OS.get_environment("TOWN_STALL_SHARED_TERRAIN_COLLISION_BODY").strip_edges()
	if not shared_collision_override.is_empty():
		var terrain_manager_shared_collision_override := game_root.find_child("TerrainManager", true, false)
		if terrain_manager_shared_collision_override and "shared_terrain_collision_body_enabled" in terrain_manager_shared_collision_override:
			terrain_manager_shared_collision_override.shared_terrain_collision_body_enabled = shared_collision_override != "0"
			print("[TOWN_STALL_TEST] Shared terrain collision body: %s" % ("ON" if terrain_manager_shared_collision_override.shared_terrain_collision_body_enabled else "OFF"))
	var prefab_spawner_override := game_root.find_child("PrefabSpawner", true, false)
	if prefab_spawner_override and "instant_baked_buildings_enabled" in prefab_spawner_override:
		prefab_spawner_override.instant_baked_buildings_enabled = instant_baked_buildings_enabled
	if disable_water_render_enabled:
		var terrain_manager_water_override := game_root.find_child("TerrainManager", true, false)
		if terrain_manager_water_override and "water_render_enabled" in terrain_manager_water_override:
			terrain_manager_water_override.water_render_enabled = false
			_emit_scope_state("town_stall_test", {
				"phase": "water_render_disabled",
				"disable_water_render": true
			})
			print("[TOWN_STALL_TEST] Water rendering disabled for test isolation.")
	if disable_terrain_manager_visuals_enabled:
		_apply_terrain_manager_visuals_toggle()
	if disable_vegetation_render_enabled:
		_apply_vegetation_render_toggle()
	if disable_glow_enabled:
		_apply_render_feature_toggles()

	# Strip out the old test-only helpers so the harness owns the flow.
	for node_name in ["DebugTeleporter", "MovementBot"]:
		var helper := game_root.find_child(node_name, true, false)
		if helper:
			helper.free()
			print("[TOWN_STALL_TEST] Removed helper node: %s" % node_name)

	var save_manager: Node = get_node_or_null("/root/SaveManager")
	if not save_manager or not ("pending_world_definition_path" in save_manager):
		_fail("SaveManager autoload missing pending_world_definition_path")
		return

	save_manager.pending_world_definition_path = generated_world_path
	if save_manager.has_method("set_world_map_instant_baked_buildings_enabled"):
		save_manager.set_world_map_instant_baked_buildings_enabled(instant_baked_buildings_enabled)
	if disable_buildings_enabled and ("disable_buildings_for_test" in save_manager):
		save_manager.disable_buildings_for_test = true
		_apply_buildings_toggle()
	elif disable_building_objects_enabled:
		_apply_building_objects_toggle()
	elif disable_building_blocks_enabled:
		_apply_building_blocks_toggle()
	elif disable_building_chunk_mesh_render_enabled:
		_apply_building_chunk_mesh_render_toggle()
	elif disable_building_visual_batches_enabled:
		_apply_building_visual_batches_toggle()
	elif disable_building_carve_enabled:
		_apply_building_carve_toggle()
	elif disable_building_object_collisions_enabled:
		_apply_building_object_collisions_toggle()
	elif disable_building_chunk_flush_enabled:
		_apply_building_chunk_flush_toggle()
	elif disable_building_chunk_collisions_enabled:
		_apply_building_chunk_collisions_toggle()
	if disable_entities_enabled:
		_apply_entities_toggle()
	add_child(game_root)
	phase = Phase.WAIT_WORLD_READY
	phase_time = 0.0

	_emit_scope_state("town_stall_test", {
		"phase": "game_loaded",
		"world_path": generated_world_path
	})
	print("[TOWN_STALL_TEST] Game scene loaded, waiting for world to finish initial load...")


func _apply_buildings_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var building_manager := game_root.find_child("BuildingManager", true, false)
	if building_manager:
		building_manager.process_mode = Node.PROCESS_MODE_DISABLED
		if building_manager.has_method("set_process"):
			building_manager.set_process(false)
		if building_manager.has_method("set_physics_process"):
			building_manager.set_physics_process(false)

	var prefab_spawner := game_root.find_child("PrefabSpawner", true, false)
	if prefab_spawner:
		if "enabled" in prefab_spawner:
			prefab_spawner.enabled = false
		prefab_spawner.process_mode = Node.PROCESS_MODE_DISABLED
		if prefab_spawner.has_method("set_process"):
			prefab_spawner.set_process(false)
		if prefab_spawner.has_method("set_physics_process"):
			prefab_spawner.set_physics_process(false)

	var building_generator := game_root.find_child("BuildingGenerator", true, false)
	if building_generator:
		if "enabled" in building_generator:
			building_generator.enabled = false
		building_generator.process_mode = Node.PROCESS_MODE_DISABLED
		if building_generator.has_method("set_process"):
			building_generator.set_process(false)
		if building_generator.has_method("set_physics_process"):
			building_generator.set_physics_process(false)

	_emit_scope_state("town_stall_test", {
		"phase": "buildings_disabled",
		"disable_buildings": true
	})
	print("[TOWN_STALL_TEST] Buildings subsystem disabled for test isolation.")


func _apply_building_objects_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var prefab_spawner := game_root.find_child("PrefabSpawner", true, false)
	if prefab_spawner and "skip_object_spawns_for_test" in prefab_spawner:
		prefab_spawner.skip_object_spawns_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_objects_disabled",
		"disable_building_objects": true
	})
	print("[TOWN_STALL_TEST] Building objects disabled for test isolation.")


func _apply_building_blocks_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var prefab_spawner := game_root.find_child("PrefabSpawner", true, false)
	if prefab_spawner and "skip_block_placement_for_test" in prefab_spawner:
		prefab_spawner.skip_block_placement_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_blocks_disabled",
		"disable_building_blocks": true
	})
	print("[TOWN_STALL_TEST] Building blocks disabled for test isolation.")


func _apply_building_chunk_mesh_render_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var building_manager := game_root.find_child("BuildingManager", true, false)
	if building_manager and "skip_building_chunk_mesh_render_for_test" in building_manager:
		building_manager.skip_building_chunk_mesh_render_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_chunk_mesh_render_disabled",
		"disable_building_chunk_mesh_render": true
	})
	print("[TOWN_STALL_TEST] Building chunk mesh render disabled for test isolation.")


func _apply_building_visual_batches_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var building_manager := game_root.find_child("BuildingManager", true, false)
	if building_manager and "skip_building_visual_batches_for_test" in building_manager:
		building_manager.skip_building_visual_batches_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_visual_batches_disabled",
		"disable_building_visual_batches": true
	})
	print("[TOWN_STALL_TEST] Building visual batches disabled for test isolation.")


func _apply_building_carve_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var prefab_spawner := game_root.find_child("PrefabSpawner", true, false)
	if prefab_spawner and "skip_carving_for_test" in prefab_spawner:
		prefab_spawner.skip_carving_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_carve_disabled",
		"disable_building_carve": true
	})
	print("[TOWN_STALL_TEST] Building carve disabled for test isolation.")


func _apply_building_object_collisions_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var building_manager := game_root.find_child("BuildingManager", true, false)
	if building_manager and "skip_object_collisions_for_test" in building_manager:
		building_manager.skip_object_collisions_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_object_collisions_disabled",
		"disable_building_object_collisions": true
	})
	print("[TOWN_STALL_TEST] Building object collisions disabled for test isolation.")


func _apply_building_chunk_flush_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var prefab_spawner := game_root.find_child("PrefabSpawner", true, false)
	if prefab_spawner and "skip_chunk_flush_for_test" in prefab_spawner:
		prefab_spawner.skip_chunk_flush_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_chunk_flush_disabled",
		"disable_building_chunk_flush": true
	})
	print("[TOWN_STALL_TEST] Building chunk flush disabled for test isolation.")


func _apply_building_chunk_collisions_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var building_manager := game_root.find_child("BuildingManager", true, false)
	if building_manager and "skip_building_chunk_collisions_for_test" in building_manager:
		building_manager.skip_building_chunk_collisions_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_chunk_collisions_disabled",
		"disable_building_chunk_collisions": true
	})
	print("[TOWN_STALL_TEST] Building chunk collisions disabled for test isolation.")


func _apply_entities_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var entity_manager := game_root.find_child("EntityManager", true, false)
	if entity_manager:
		if "procedural_spawning_enabled" in entity_manager:
			entity_manager.procedural_spawning_enabled = false
		if "max_entities" in entity_manager:
			entity_manager.max_entities = 0
		entity_manager.process_mode = Node.PROCESS_MODE_DISABLED
		if entity_manager.has_method("set_process"):
			entity_manager.set_process(false)
		if entity_manager.has_method("set_physics_process"):
			entity_manager.set_physics_process(false)

	_emit_scope_state("town_stall_test", {
		"phase": "entities_disabled",
		"disable_entities": true
	})
	print("[TOWN_STALL_TEST] Entities disabled for test isolation.")


func _apply_terrain_manager_visuals_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var terrain_manager_node := game_root.find_child("TerrainManager", true, false)
	var terrain_visual_root := terrain_manager_node as Node3D
	if terrain_visual_root:
		terrain_visual_root.visible = false

	_emit_scope_state("town_stall_test", {
		"phase": "terrain_manager_visuals_disabled",
		"disable_terrain_manager_visuals": true
	})
	print("[TOWN_STALL_TEST] Terrain manager visuals disabled for test isolation.")


func _apply_vegetation_render_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var vegetation_manager_node := game_root.find_child("VegetationManager", true, false)
	var vegetation_visual_root := vegetation_manager_node as Node3D
	if vegetation_visual_root:
		vegetation_visual_root.visible = false

	_emit_scope_state("town_stall_test", {
		"phase": "vegetation_render_disabled",
		"disable_vegetation_render": true
	})
	print("[TOWN_STALL_TEST] Vegetation rendering disabled for test isolation.")


func _apply_render_feature_toggles() -> void:
	if not is_instance_valid(game_root):
		return

	var glow_count := 0
	if disable_glow_enabled:
		glow_count = _set_glow_enabled_recursive(game_root, false)

	_emit_scope_state("town_stall_test", {
		"phase": "render_features_toggled",
		"disable_glow": disable_glow_enabled,
		"glow_environment_count": glow_count
	})
	print("[TOWN_STALL_TEST] Render feature isolation toggles applied: glow_envs=%d" % glow_count)


func _set_glow_enabled_recursive(node: Node, enabled: bool) -> int:
	var changed := 0
	var world_environment := node as WorldEnvironment
	if world_environment:
		var environment := world_environment.environment
		if environment:
			var environment_copy := environment.duplicate() as Environment
			environment_copy.glow_enabled = enabled
			world_environment.environment = environment_copy
			changed += 1

	for child in node.get_children():
		changed += _set_glow_enabled_recursive(child, enabled)
	return changed


func _collect_world_ready_status(terrain_ready: bool, loading_screen_done: bool) -> Dictionary:
	var status := {
		"phase_time": phase_time,
		"terrain_ready": terrain_ready,
		"loading_screen_done": loading_screen_done,
		"terrain_manager_valid": is_instance_valid(terrain_manager),
		"chunk_manager_valid": is_instance_valid(chunk_manager),
		"player_valid": is_instance_valid(player),
		"loading_screen_valid": is_instance_valid(loading_screen)
	}

	if is_instance_valid(loading_screen):
		status["loading_screen_is_loading"] = bool(loading_screen.get("is_loading")) if "is_loading" in loading_screen else false
		status["loading_screen_stage"] = int(loading_screen.get("current_stage")) if "current_stage" in loading_screen else -1
		var status_label_variant: Variant = loading_screen.get("status_label") if "status_label" in loading_screen else null
		var progress_bar_variant: Variant = loading_screen.get("progress_bar") if "progress_bar" in loading_screen else null
		if status_label_variant is Label:
			status["loading_screen_text"] = str((status_label_variant as Label).text)
		if progress_bar_variant is ProgressBar:
			status["loading_screen_progress"] = float((progress_bar_variant as ProgressBar).value)

	if is_instance_valid(terrain_manager):
		status["terrain_initial_load_phase"] = bool(terrain_manager.get("initial_load_phase")) if "initial_load_phase" in terrain_manager else false
		status["terrain_chunks_loaded_initial"] = int(terrain_manager.get("chunks_loaded_initial")) if "chunks_loaded_initial" in terrain_manager else -1
		status["terrain_initial_load_target_chunks"] = int(terrain_manager.get("initial_load_target_chunks")) if "initial_load_target_chunks" in terrain_manager else -1
		status["terrain_active_chunk_count"] = int(terrain_manager.get("active_chunks").size()) if "active_chunks" in terrain_manager else -1
		status["terrain_pending_node_count"] = int(terrain_manager.call("get_pending_nodes_count")) if terrain_manager.has_method("get_pending_nodes_count") else -1
		status["terrain_loading_progress"] = float(terrain_manager.call("get_loading_progress")) if terrain_manager.has_method("get_loading_progress") else -1.0
		status["terrain_last_update_loads"] = int(terrain_manager.get("_last_update_loads")) if "_last_update_loads" in terrain_manager else -1
		status["terrain_last_update_backend"] = str(terrain_manager.get("_last_update_backend")) if "_last_update_backend" in terrain_manager else ""
		status["terrain_loading_paused"] = bool(terrain_manager.get("loading_paused")) if "loading_paused" in terrain_manager else false
		if is_instance_valid(player) and terrain_manager.has_method("ensure_collision_ready_at"):
			status["terrain_collision_ready_at_player"] = bool(terrain_manager.call("ensure_collision_ready_at", player.global_position, 1))

	var system_telemetry := _collect_system_telemetry()
	var building_telemetry: Dictionary = system_telemetry.get("building_manager", {})
	var prefab_telemetry: Dictionary = system_telemetry.get("prefab_spawner", {})
	var vegetation_telemetry: Dictionary = system_telemetry.get("vegetation_manager", {})
	status["building_pending_baked_apply_phases"] = int(building_telemetry.get("pending_world_map_baked_building_apply_phases", 0))
	status["building_pending_baked_object_spawns"] = int(building_telemetry.get("pending_world_map_baked_object_spawns", 0))
	status["building_dirty_visible_chunk_count"] = int(building_telemetry.get("dirty_visible_chunk_count", 0))
	status["prefab_pending_baked_payload_build_jobs"] = int(prefab_telemetry.get("pending_world_map_baked_payload_build_jobs", 0))
	status["prefab_pending_baked_payload_jobs"] = int(prefab_telemetry.get("pending_world_map_baked_payload_jobs", 0))
	status["vegetation_ready"] = bool(vegetation_telemetry.get("vegetation_ready", true))
	status["vegetation_pending_chunks"] = int(vegetation_telemetry.get("pending_chunks_count", vegetation_telemetry.get("pending_chunks", 0)))
	return status


func _maybe_log_world_ready_status(terrain_ready: bool, loading_screen_done: bool) -> void:
	if world_ready_status_log_interval_seconds <= 0.0:
		return
	if phase_time - world_ready_last_status_log_seconds < world_ready_status_log_interval_seconds:
		return

	world_ready_last_status_log_seconds = phase_time
	var status := _collect_world_ready_status(terrain_ready, loading_screen_done)
	_emit_scope_state("world_ready_wait", status)
	print("[TOWN_STALL_TEST] World wait %.1fs terrain_ready=%s loading_done=%s loading_stage=%d loading=%.1f%% '%s' terrain_initial=%s chunks=%d/%d pending_nodes=%d active=%d collision_ready=%s backend=%s loads=%d paused=%s building_apply=%d building_objects=%d prefab_build=%d prefab_apply=%d veg_ready=%s veg_pending=%d" % [
		float(status.get("phase_time", 0.0)),
		str(status.get("terrain_ready", false)),
		str(status.get("loading_screen_done", false)),
		int(status.get("loading_screen_stage", -1)),
		float(status.get("loading_screen_progress", -1.0)),
		str(status.get("loading_screen_text", "")),
		str(status.get("terrain_initial_load_phase", false)),
		int(status.get("terrain_chunks_loaded_initial", -1)),
		int(status.get("terrain_initial_load_target_chunks", -1)),
		int(status.get("terrain_pending_node_count", -1)),
		int(status.get("terrain_active_chunk_count", -1)),
		str(status.get("terrain_collision_ready_at_player", false)),
		str(status.get("terrain_last_update_backend", "")),
		int(status.get("terrain_last_update_loads", -1)),
		str(status.get("terrain_loading_paused", false)),
		int(status.get("building_pending_baked_apply_phases", 0)),
		int(status.get("building_pending_baked_object_spawns", 0)),
		int(status.get("prefab_pending_baked_payload_build_jobs", 0)),
		int(status.get("prefab_pending_baked_payload_jobs", 0)),
		str(status.get("vegetation_ready", true)),
		int(status.get("vegetation_pending_chunks", 0))
	])


func _poll_world_ready() -> void:
	if phase_time > world_ready_timeout_seconds:
		_maybe_log_world_ready_status(false, false)
		_fail("Timed out waiting for world to become ready")
		return

	if not is_instance_valid(game_root):
		return

	if terrain_manager == null:
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if chunk_manager == null:
		chunk_manager = terrain_manager
	if player == null:
		player = get_tree().get_first_node_in_group("player") as WorldPlayerV2
	if loading_screen == null or not is_instance_valid(loading_screen):
		loading_screen = game_root.find_child("LoadingScreen", true, false)

	if terrain_manager == null or chunk_manager == null or player == null:
		_maybe_log_world_ready_status(false, false)
		return

	var terrain_ready := false
	if terrain_manager.has_method("is_initial_load_complete"):
		terrain_ready = terrain_manager.is_initial_load_complete()

	var loading_screen_done := true
	if loading_screen and ("is_loading" in loading_screen):
		loading_screen_done = not bool(loading_screen.get("is_loading"))

	if not terrain_ready or not loading_screen_done:
		_maybe_log_world_ready_status(terrain_ready, loading_screen_done)
		return

	_emit_scope_event("town_stall_test", "world_ready", {
		"phase_time": phase_time,
		"world_path": generated_world_path
	})
	if auto_teleport_enabled:
		phase = Phase.TELEPORT
	else:
		_enter_fly_to_town()
	phase_time = 0.0


func _teleport_into_town() -> void:
	if not is_instance_valid(game_root) or not is_instance_valid(player) or not is_instance_valid(chunk_manager):
		_fail("Game scene references vanished before teleport")
		return

	var town_x: float = float(selected_town.get("x", 0.0))
	var town_z: float = float(selected_town.get("z", 0.0))
	var town_y: float = float(selected_town.get("terrain_y", 12.0))
	var teleport_pos := Vector3(town_x, town_y + TELEPORT_HEIGHT_OFFSET, town_z)

	if not pending_town_spawn_requested:
		_apply_terrain_chunk_updates_toggle()
		pending_town_teleport_pos = teleport_pos
		pending_town_spawn_requested = true
		_reset_town_stream_stability()
		_set_player_movement_enabled(false)
		player.global_position = teleport_pos
		player.velocity = Vector3.ZERO
		if chunk_manager.has_method("request_spawn_zone"):
			chunk_manager.request_spawn_zone(teleport_pos, 2)
		print("[TOWN_STALL_TEST] Preparing town terrain at (%.1f, %.1f, %.1f)..." % [teleport_pos.x, teleport_pos.y, teleport_pos.z])
		return

	if not _is_town_spawn_ready(pending_town_teleport_pos):
		town_spawn_ready_settle_frames = 0
		return

	if town_spawn_ready_settle_frames < 3:
		town_spawn_ready_settle_frames += 1
		return

	_reset_town_measurement_window("auto_teleport_entry")
	player.global_position = teleport_pos
	player.velocity = Vector3.ZERO
	_set_player_movement_enabled(true)
	hold_started_logged = false
	pending_town_spawn_requested = false
	town_spawn_ready_settle_frames = 0

	_emit_scope_state("town_stall_test", {
		"phase": "town_teleported",
		"world_path": generated_world_path,
		"town_x": town_x,
		"town_z": town_z,
		"town_y": town_y,
		"building_count": int(selected_town.get("building_count", 0))
	})
	_emit_scope_event("town_stall_test", "teleport", {
		"town_x": town_x,
		"town_z": town_z,
		"town_y": town_y,
		"spawn_radius": 2
	})

	print("[TOWN_STALL_TEST] Teleported to town at (%.1f, %.1f, %.1f)" % [teleport_pos.x, teleport_pos.y, teleport_pos.z])
	print("[TOWN_STALL_TEST] Waiting %.1f seconds for the stall window..." % configured_hold_seconds)

	current_hold_seconds = configured_hold_seconds
	_apply_baked_building_smoke_hold_extension()
	phase = Phase.HOLD_FIRST
	phase_time = 0.0
	hold_started_logged = false
	_reset_hold_settle()


func _is_town_spawn_ready(position: Vector3) -> bool:
	return _get_town_spawn_ready_blockers(position).is_empty()


func _get_town_spawn_ready_blockers(position: Vector3) -> Array[String]:
	var blockers: Array[String] = []
	if pending_town_spawn_requested and chunk_manager.has_method("is_spawn_zone_ready"):
		if not bool(chunk_manager.is_spawn_zone_ready(position, 2)):
			blockers.append("spawn_zone_not_ready")
	elif chunk_manager.has_method("ensure_collision_ready_at") and not bool(chunk_manager.ensure_collision_ready_at(position, 1)):
		blockers.append("spawn_collision_not_ready")
	blockers.append_array(_get_town_terrain_stream_blockers())
	blockers.append_array(_get_town_building_stream_blockers())
	blockers.append_array(_get_town_vegetation_stream_blockers())
	blockers.append_array(_get_town_entity_stream_blockers())
	return blockers


func _is_town_terrain_stream_ready() -> bool:
	return _get_town_terrain_stream_blockers().is_empty()


func _get_town_terrain_stream_blockers() -> Array[String]:
	var blockers: Array[String] = []
	if not chunk_manager.has_method("get_telemetry_snapshot"):
		return blockers
	var telemetry: Dictionary = chunk_manager.get_telemetry_snapshot()
	var render_distance := int(telemetry.get("render_distance", 0))
	var min_loaded_chunks := int(ceil(PI * float(render_distance * render_distance)))
	var loaded_chunk_count := int(telemetry.get("loaded_chunk_count", 0))
	if render_distance > 0 and loaded_chunk_count < min_loaded_chunks:
		blockers.append("terrain_loaded_chunks=%d/%d" % [loaded_chunk_count, min_loaded_chunks])
	if bool(telemetry.get("distant_world_map_lod_enabled", false)) and bool(telemetry.get("world_map_active", false)):
		var lod_distance := int(telemetry.get("distant_world_map_lod_distance", 0))
		var lod_overlap := int(telemetry.get("distant_world_map_lod_overlap", 0))
		var lod_inner_distance := maxi(render_distance - lod_overlap, 0)
		if lod_distance > lod_inner_distance:
			if bool(telemetry.get("distant_world_map_lod_deferred", false)):
				blockers.append("terrain_world_lod_deferred")
			if int(telemetry.get("world_map_lod_chunk_count", 0)) <= 0:
				blockers.append("terrain_world_lod_empty")
			var world_lod_pending := int(telemetry.get("world_map_lod_pending_candidate_count", 0))
			if world_lod_pending > 0:
				blockers.append("terrain_world_lod_pending=%d" % world_lod_pending)
			var world_lod_loads := int(telemetry.get("last_world_map_lod_loads", 0))
			if world_lod_loads > 0:
				blockers.append("terrain_world_lod_loads=%d" % world_lod_loads)
			var world_lod_unloads := int(telemetry.get("last_world_map_lod_unloads", 0))
			if world_lod_unloads > 0:
				blockers.append("terrain_world_lod_unloads=%d" % world_lod_unloads)
	var pending_chunks := int(telemetry.get("pending_chunk_count", 0))
	if pending_chunks > 0:
		blockers.append("terrain_pending_chunks=%d" % pending_chunks)
	var pending_nodes := int(telemetry.get("pending_node_count", 0))
	if pending_nodes > 0:
		blockers.append("terrain_pending_nodes=%d" % pending_nodes)
	var task_queue := int(telemetry.get("task_queue_count", 0))
	if task_queue > 0:
		blockers.append("terrain_gpu_tasks=%d" % task_queue)
	var cpu_task_queue := int(telemetry.get("cpu_task_queue_count", 0))
	if cpu_task_queue > 0:
		blockers.append("terrain_cpu_tasks=%d" % cpu_task_queue)
	var completed_queue := int(telemetry.get("completed_generation_queue_count", 0))
	if completed_queue > 0:
		blockers.append("terrain_completed_queue=%d" % completed_queue)
	var pending_collision := int(telemetry.get("pending_terrain_collision_create_count", 0))
	if pending_collision > 0:
		blockers.append("terrain_pending_collision=%d" % pending_collision)
	var last_update_loads := int(telemetry.get("last_update_loads", 0))
	if last_update_loads > 0:
		blockers.append("terrain_last_loads=%d" % last_update_loads)
	var last_update_unloads := int(telemetry.get("last_update_unloads", 0))
	if last_update_unloads > 0:
		blockers.append("terrain_last_unloads=%d" % last_update_unloads)
	if bool(telemetry.get("render_resource_prewarm_active", false)):
		blockers.append("terrain_render_prewarm=%d" % int(telemetry.get("render_resource_prewarm_frames_remaining", 0)))
	if not blockers.is_empty():
		_reset_town_terrain_stability()
		return blockers

	var signature := "%d:%d:%d:%d:%d:%d:%d" % [
		int(telemetry.get("active_chunk_count", 0)),
		loaded_chunk_count,
		int(telemetry.get("rendered_terrain_chunk_count", 0)),
		int(telemetry.get("rendered_water_chunk_count", 0)),
		int(telemetry.get("collision_ready_chunk_count", 0)),
		int(telemetry.get("world_map_lod_chunk_count", 0)),
		int(telemetry.get("world_map_lod_pending_candidate_count", 0))
	]
	if signature != town_terrain_stability_signature:
		town_terrain_stability_signature = signature
		town_terrain_stable_frames = 0
		blockers.append("terrain_stabilizing=0/12")
		return blockers
	town_terrain_stable_frames += 1
	if town_terrain_stable_frames < 12:
		blockers.append("terrain_stabilizing=%d/12" % town_terrain_stable_frames)
	return blockers


func _is_town_building_stream_ready() -> bool:
	return _get_town_building_stream_blockers().is_empty()


func _get_town_building_stream_blockers() -> Array[String]:
	var blockers: Array[String] = []
	var prefab_spawner := _find_manager_node("prefab_spawner", "PrefabSpawner")
	if is_instance_valid(prefab_spawner):
		if prefab_spawner.has_method("has_pending_spawn_jobs") and prefab_spawner.has_pending_spawn_jobs():
			blockers.append("prefab_spawn_jobs")
		if prefab_spawner.has_method("has_pending_world_map_baked_payload_jobs") and prefab_spawner.has_pending_world_map_baked_payload_jobs():
			blockers.append("prefab_baked_payload_jobs")
	if not is_instance_valid(building_manager):
		building_manager = _find_manager_node("building_manager", "BuildingManager")
	if is_instance_valid(building_manager):
		if building_manager.has_method("is_object_render_prewarm_active") and building_manager.is_object_render_prewarm_active():
			blockers.append("building_object_prewarm")
		if building_manager.has_method("has_pending_world_map_baked_building_apply_phases") and building_manager.has_pending_world_map_baked_building_apply_phases():
			blockers.append("building_baked_apply")
		if building_manager.has_method("has_pending_world_map_baked_object_spawns") and building_manager.has_pending_world_map_baked_object_spawns():
			blockers.append("building_object_spawns")
		if building_manager.has_method("has_dirty_global_visual_batches") and building_manager.has_dirty_global_visual_batches():
			blockers.append("building_global_visual_batches")
		if building_manager.has_method("has_dirty_visible_chunks") and building_manager.has_dirty_visible_chunks():
			blockers.append("building_dirty_visible_chunks")
		if building_manager.has_method("get_telemetry_snapshot"):
			var telemetry: Dictionary = building_manager.get_telemetry_snapshot()
			if bool(telemetry.get("object_render_prewarm_active", false)):
				blockers.append("building_object_prewarm=%d" % int(telemetry.get("object_render_prewarm_frames_remaining", 0)))
			var visual_rebuilds := int(telemetry.get("pending_visual_batch_rebuilds", 0))
			if visual_rebuilds > 0:
				blockers.append("building_visual_rebuilds=%d" % visual_rebuilds)
			var baked_visual_dirty := int(telemetry.get("world_map_baked_building_visual_batch_dirty_count", 0))
			if baked_visual_dirty > 0:
				blockers.append("building_baked_visual_dirty=%d" % baked_visual_dirty)
	return blockers


func _is_town_vegetation_stream_ready() -> bool:
	return _get_town_vegetation_stream_blockers().is_empty()


func _get_town_vegetation_stream_blockers() -> Array[String]:
	var blockers: Array[String] = []
	if not is_instance_valid(vegetation_manager):
		vegetation_manager = _find_manager_node("vegetation_manager", "VegetationManager")
	if is_instance_valid(vegetation_manager):
		if vegetation_manager.has_method("get_telemetry_snapshot"):
			var telemetry: Dictionary = vegetation_manager.get_telemetry_snapshot()
			var pending_chunks := int(telemetry.get("pending_chunks_count", telemetry.get("pending_chunks", 0)))
			if pending_chunks > 0:
				blockers.append("vegetation_pending_chunks=%d" % pending_chunks)
			var dirty_kinds: Array = telemetry.get("global_render_dirty_kinds", [])
			if not dirty_kinds.is_empty():
				blockers.append("vegetation_dirty=%s" % str(dirty_kinds))
			if bool(telemetry.get("vegetation_render_prewarm_active", false)):
				blockers.append("vegetation_prewarm=%d" % int(telemetry.get("vegetation_render_prewarm_frames_remaining", 0)))
		elif vegetation_manager.has_method("is_vegetation_ready") and not bool(vegetation_manager.is_vegetation_ready()):
			blockers.append("vegetation_not_ready")
	return blockers


func _is_town_entity_stream_ready() -> bool:
	return _get_town_entity_stream_blockers().is_empty()


func _get_town_entity_stream_blockers() -> Array[String]:
	var blockers: Array[String] = []
	if not is_instance_valid(entity_manager):
		entity_manager = _find_manager_node("entity_manager", "EntityManager")
	if not is_instance_valid(entity_manager) or not entity_manager.has_method("get_telemetry_snapshot"):
		return blockers
	var telemetry: Dictionary = entity_manager.get_telemetry_snapshot()
	if bool(telemetry.get("entity_render_prewarm_active", false)):
		blockers.append("entity_prewarm=%d" % int(telemetry.get("entity_render_prewarm_frames_remaining", 0)))
	var spawned := int(telemetry.get("last_spawn_queue_spawned", 0))
	if spawned > 0:
		blockers.append("entity_spawned=%d" % spawned)
	var dormant_spawned := int(telemetry.get("last_dormant_respawn_spawned", 0))
	if dormant_spawned > 0:
		blockers.append("entity_dormant_spawned=%d" % dormant_spawned)
	if not blockers.is_empty():
		_reset_town_entity_stability()
		return blockers

	var signature := "%d:%d:%d:%d:%d:%d:%d" % [
		int(telemetry.get("active_entities", 0)),
		int(telemetry.get("frozen_entities", 0)),
		int(telemetry.get("dormant_entities", 0)),
		int(telemetry.get("pending_spawns", 0)),
		int(telemetry.get("deferred_spawn_chunks", 0)),
		int(telemetry.get("deferred_spawn_plans", 0)),
		int(telemetry.get("spawned_chunks", 0))
	]
	if signature != town_entity_stability_signature:
		town_entity_stability_signature = signature
		town_entity_stable_frames = 0
		blockers.append("entity_stabilizing=0/20")
		return blockers
	town_entity_stable_frames += 1
	if town_entity_stable_frames < 20:
		blockers.append("entity_stabilizing=%d/20" % town_entity_stable_frames)
	return blockers


func _reset_town_stream_stability() -> void:
	_reset_town_terrain_stability()
	_reset_town_entity_stability()


func _reset_town_terrain_stability() -> void:
	town_terrain_stable_frames = 0
	town_terrain_stability_signature = ""


func _reset_town_entity_stability() -> void:
	town_entity_stable_frames = 0
	town_entity_stability_signature = ""


func _set_player_movement_enabled(enabled: bool) -> void:
	if not is_instance_valid(player):
		return
	if movement_component == null or not is_instance_valid(movement_component):
		movement_component = player.get_node_or_null("Components/Movement")
	if movement_component:
		if movement_component.has_method("set_physics_process"):
			movement_component.set_physics_process(enabled)
		if movement_component.has_method("set_process"):
			movement_component.set_process(enabled)
	player.velocity = Vector3.ZERO


func _reset_hold_settle() -> void:
	_reset_hold_settle_progress()
	hold_stream_ready_wait_logged = false
	hold_stream_ready_last_log_seconds = -1000000.0
	hold_stream_ready_last_blockers = ""


func _reset_hold_settle_progress() -> void:
	hold_settle_elapsed_seconds = 0.0
	hold_settle_stable_frames = 0
	hold_settle_timed_out = false
	hold_settle_wait_logged = false
	hold_settle_last_player_position = Vector3(1.0e20, 1.0e20, 1.0e20)


func _get_player_velocity_length() -> float:
	if not is_instance_valid(player):
		return 0.0
	if "velocity" in player:
		return player.velocity.length()
	return 0.0


func _is_hold_settled(delta: float) -> bool:
	if not is_instance_valid(player):
		return true

	hold_settle_elapsed_seconds += delta
	var player_position := player.global_position
	var moved := false
	if hold_settle_last_player_position.x <= 9.0e19:
		moved = player_position.distance_to(hold_settle_last_player_position) > HOLD_SETTLE_POSITION_EPSILON
	hold_settle_last_player_position = player_position

	var velocity_len := _get_player_velocity_length()
	if not moved and velocity_len <= HOLD_SETTLE_VELOCITY_EPSILON:
		hold_settle_stable_frames += 1
	else:
		hold_settle_stable_frames = 0

	if hold_settle_stable_frames >= HOLD_SETTLE_STABLE_FRAMES:
		return true

	if hold_settle_elapsed_seconds >= HOLD_SETTLE_MAX_SECONDS:
		hold_settle_timed_out = true
		_emit_scope_event("town_stall_test", "hold_settle_timeout", {
			"elapsed_seconds": hold_settle_elapsed_seconds,
			"stable_frames": hold_settle_stable_frames,
			"velocity": velocity_len,
			"player_x": player_position.x,
			"player_y": player_position.y,
			"player_z": player_position.z
		})
		return true

	if not hold_settle_wait_logged:
		hold_settle_wait_logged = true
		print("[TOWN_STALL_TEST] Waiting for player settle before hold")
	return false


func _enter_fly_to_town() -> void:
	if not is_instance_valid(game_root) or not is_instance_valid(player):
		_fail("Game scene references vanished before fly-to-town setup")
		return

	_apply_terrain_chunk_updates_toggle()

	mode_manager = player.get_node_or_null("Systems/ModeManager")
	mode_editor = player.get_node_or_null("Modes/ModeEditor")
	movement_component = player.get_node_or_null("Components/Movement")

	if mode_manager == null or mode_editor == null:
		_fail("Failed to locate editor mode components on player")
		return

	if movement_component and movement_component.has_method("set_physics_process"):
		movement_component.set_physics_process(false)
	if movement_component and movement_component.has_method("set_process"):
		movement_component.set_process(false)
	if mode_editor.has_method("set_physics_process"):
		mode_editor.set_physics_process(false)
	if mode_editor.has_method("set_process"):
		mode_editor.set_process(false)

	if mode_manager.has_method("is_editor_mode") and not bool(mode_manager.is_editor_mode()):
		mode_manager.toggle_editor_mode()
	if mode_manager.has_method("is_fly_active") and not bool(mode_manager.is_fly_active()):
		mode_manager.toggle_fly_mode()

	return_origin = player.global_position
	var town_x: float = float(selected_town.get("x", 0.0))
	var town_z: float = float(selected_town.get("z", 0.0))
	var town_y: float = float(selected_town.get("terrain_y", 12.0))
	town_entry_capture_started = false
	_begin_flight_to_target(
		Vector3(town_x, town_y + TELEPORT_HEIGHT_OFFSET, town_z),
		Phase.FLY_TO_TOWN,
		"town center",
		"fly_to_town",
		{
			"building_count": int(selected_town.get("building_count", 0)),
			"town_radius": float(selected_town.get("radius", 0.0)),
			"auto_teleport": false,
			"auto_fly": true
		}
	)
	print("[TOWN_STALL_TEST] Auto fly mode active - editor/fly enabled.")
	print("[TOWN_STALL_TEST] Flying to town center: (%.1f, %.1f, %.1f) buildings=%d radius=%.1f" % [
		town_x,
		town_y,
		town_z,
		int(selected_town.get("building_count", 0)),
		float(selected_town.get("radius", 0.0))
	])


func _apply_terrain_chunk_updates_toggle() -> void:
	if not disable_terrain_chunk_updates_enabled:
		return

	if not is_instance_valid(chunk_manager):
		chunk_manager = get_tree().get_first_node_in_group("terrain_manager")
	if chunk_manager and "skip_terrain_chunk_updates_for_test" in chunk_manager:
		chunk_manager.skip_terrain_chunk_updates_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "terrain_chunk_updates_disabled",
		"disable_terrain_chunk_updates": true
	})
	print("[TOWN_STALL_TEST] Terrain chunk updates disabled for test isolation.")


func _begin_flight_to_target(target: Vector3, next_phase: Phase, target_label: String, scope_phase: String, extra_state: Dictionary = {}) -> void:
	fly_target = target
	fly_target_altitude = maxf(player.global_position.y + AUTO_FLY_ASCEND_MARGIN, fly_target.y + AUTO_FLY_ASCEND_MARGIN)
	fly_stage = 0

	var state: Dictionary = {
		"phase": scope_phase,
		"world_path": generated_world_path,
		"target_x": target.x,
		"target_y": target.y,
		"target_z": target.z,
	}
	for key in extra_state.keys():
		state[key] = extra_state[key]
	_emit_scope_state("town_stall_test", state)
	if measure_full_flight_enabled and next_phase == Phase.FLY_TO_TOWN:
		town_entry_capture_started = true
		_reset_town_measurement_window("full_flight")
		_emit_scope_event("town_stall_test", "full_flight_capture_started", {
			"phase": scope_phase,
			"target_x": target.x,
			"target_y": target.y,
			"target_z": target.z
		})

	if next_phase == Phase.FLY_TO_TOWN:
		phase = Phase.FLY_TO_TOWN
	elif next_phase == Phase.FLY_BACK_TO_ORIGIN:
		phase = Phase.FLY_BACK_TO_ORIGIN
	elif next_phase == Phase.FLY_TO_TOWN_SECOND:
		phase = Phase.FLY_TO_TOWN_SECOND
	else:
		phase = next_phase
	phase_time = 0.0

	print("[TOWN_STALL_TEST] Flying to %s: (%.1f, %.1f, %.1f)" % [target_label, target.x, target.y, target.z])


func _restore_player_control() -> void:
	if is_instance_valid(player):
		player.velocity = Vector3.ZERO

	if is_instance_valid(mode_manager) and mode_manager.has_method("is_editor_mode") and bool(mode_manager.is_editor_mode()):
		if mode_manager.has_method("toggle_editor_mode"):
			mode_manager.toggle_editor_mode()

	if movement_component:
		if movement_component.has_method("set_physics_process"):
			movement_component.set_physics_process(true)
		if movement_component.has_method("set_process"):
			movement_component.set_process(true)

	if mode_editor:
		if mode_editor.has_method("set_physics_process"):
			mode_editor.set_physics_process(true)
		if mode_editor.has_method("set_process"):
			mode_editor.set_process(true)

	_emit_scope_event("town_stall_test", "manual_control_restored", {
		"world_path": generated_world_path,
		"phase": str(phase)
	})


func _fly_to_town(_delta: float) -> void:
	if phase_time >= AUTO_FLY_TIMEOUT_SECONDS:
		_emit_scope_event("town_stall_test", "fly_timeout", {
			"timeout_seconds": AUTO_FLY_TIMEOUT_SECONDS
		})
		_fail("Timed out flying to town center")
		return

	if not is_instance_valid(player) or not is_instance_valid(mode_manager):
		_fail("Player or mode manager vanished during fly-to-town")
		return

	var current_pos: Vector3 = player.global_position
	if fly_stage == 0:
		var vertical_delta := fly_target_altitude - current_pos.y
		if absf(vertical_delta) <= 1.5:
			player.velocity = Vector3.ZERO
			fly_stage = 1
			return

		player.velocity = Vector3(0.0, signf(vertical_delta) * AUTO_FLY_SPEED, 0.0)
		player.move_and_slide()
		return

	if fly_stage == 1:
		var horizontal_target := Vector3(fly_target.x, current_pos.y, fly_target.z)
		var to_target := horizontal_target - current_pos
		to_target.y = 0.0
		if not town_entry_capture_started and not measure_full_flight_enabled:
			var capture_radius := float(selected_town.get("radius", 0.0)) + AUTO_FLY_ENTRY_CAPTURE_BUFFER
			if capture_radius > 0.0 and to_target.length() <= capture_radius:
				town_entry_capture_started = true
				_reset_town_measurement_window("auto_fly_entry")
				_emit_scope_event("town_stall_test", "town_entry_capture_started", {
					"phase": str(phase),
					"capture_radius": capture_radius,
					"target_x": fly_target.x,
					"target_y": fly_target.y,
					"target_z": fly_target.z
				})
		if to_target.length() <= AUTO_FLY_ARRIVAL_RADIUS:
			fly_stage = 2
			return

		player.velocity = to_target.normalized() * AUTO_FLY_SPEED
		player.velocity.y = 0.0
		player.move_and_slide()
		return

	var descent_delta := fly_target.y - current_pos.y
	if absf(descent_delta) <= 1.5:
		player.velocity = Vector3.ZERO
		print("[TOWN_STALL_TEST] Auto fly reached target, starting hold")
		_restore_player_control()
		match phase:
			Phase.FLY_TO_TOWN:
				current_hold_seconds = REPEAT_ENTRY_FIRST_HOLD_SECONDS if repeat_entry_enabled else configured_hold_seconds
				phase = Phase.HOLD_FIRST
			Phase.FLY_BACK_TO_ORIGIN:
				current_hold_seconds = REPEAT_ENTRY_RETURN_HOLD_SECONDS
				phase = Phase.HOLD_RETURN
			Phase.FLY_TO_TOWN_SECOND:
				current_hold_seconds = REPEAT_ENTRY_SECOND_HOLD_SECONDS
				phase = Phase.HOLD_SECOND
			_:
				current_hold_seconds = configured_hold_seconds
				phase = Phase.HOLD_FIRST
		_apply_baked_building_smoke_hold_extension()
		phase_time = 0.0
		hold_started_logged = false
		_reset_hold_settle()
		return

	player.velocity = Vector3(0.0, signf(descent_delta) * AUTO_FLY_SPEED, 0.0)
	player.move_and_slide()


func _should_wait_for_hold_stream_ready() -> bool:
	return hold_wait_stream_ready_enabled and (phase == Phase.HOLD_FIRST or phase == Phase.HOLD_SECOND)


func _is_hold_stream_ready() -> bool:
	if not _should_wait_for_hold_stream_ready():
		return true
	if not is_instance_valid(player):
		return true
	var blockers := _get_town_spawn_ready_blockers(player.global_position)
	if blockers.is_empty():
		hold_stream_ready_last_blockers = ""
		return true
	_maybe_log_hold_stream_blockers(blockers)
	return false


func _maybe_log_hold_stream_blockers(blockers: Array[String]) -> void:
	var blocker_text := ""
	for blocker in blockers:
		if not blocker_text.is_empty():
			blocker_text += ", "
		blocker_text += blocker
	var should_log := not hold_stream_ready_wait_logged \
		or blocker_text != hold_stream_ready_last_blockers \
		or phase_time - hold_stream_ready_last_log_seconds >= HOLD_STREAM_READY_LOG_INTERVAL_SECONDS
	if not should_log:
		return
	hold_stream_ready_wait_logged = true
	hold_stream_ready_last_log_seconds = phase_time
	hold_stream_ready_last_blockers = blocker_text
	print("[TOWN_STALL_TEST] Waiting for stream/prewarm stability before hold: %s" % blocker_text)
	_emit_scope_event("town_stall_test", "hold_stream_wait", {
		"blockers": blockers,
		"phase_time": phase_time
	})


func _hold_in_town(_delta: float) -> void:
	if not hold_started_logged:
		if not _is_hold_stream_ready():
			_reset_hold_settle_progress()
			return
		if not _is_hold_settled(_delta):
			return
		phase_time = 0.0
		print("[TOWN_STALL_TEST] Hold started")
		_hold_started_sample_index = _town_entry_samples.size()
		_emit_scope_event("town_stall_test", "hold_started", {
			"phase": str(phase),
			"hold_seconds": current_hold_seconds
		})
		hold_started_logged = true
		_begin_directional_render_sampling()
		_update_directional_render_sampling()
		next_hold_snapshot_phase_time = HOLD_SNAPSHOT_INTERVAL_SECONDS if hold_periodic_snapshots_enabled else -1.0

	if next_hold_snapshot_phase_time >= 0.0 and phase_time >= next_hold_snapshot_phase_time:
		_write_native_town_entry_snapshot()
		next_hold_snapshot_phase_time += HOLD_SNAPSHOT_INTERVAL_SECONDS

	if baked_building_persistence_smoke_enabled:
		if not baked_building_persistence_smoke_started:
			baked_building_persistence_smoke_started = true
			baked_building_persistence_smoke_running = true
			_emit_scope_event("town_stall_test", "baked_building_persistence_smoke_start", {
				"hold_seconds": current_hold_seconds
			})
			print("[TOWN_STALL_TEST] Starting baked-building persistence smoke test")
			call_deferred("_run_baked_building_persistence_smoke_test")
		return

	if phase_time >= current_hold_seconds:
		_hold_completed_sample_index = _town_entry_samples.size()
		_emit_scope_event("town_stall_test", "hold_complete", {
			"hold_seconds": current_hold_seconds,
			"phase": str(phase)
		})

		if phase == Phase.HOLD_FIRST and repeat_entry_enabled:
			print("[TOWN_STALL_TEST] First hold complete, flying back out before re-entering town")
			_begin_flight_to_target(
				return_origin,
				Phase.FLY_BACK_TO_ORIGIN,
				"fly_back_to_origin",
				"return origin",
				{}
			)
			return

		if phase == Phase.HOLD_RETURN and repeat_entry_enabled:
			var town_x: float = float(selected_town.get("x", 0.0))
			var town_z: float = float(selected_town.get("z", 0.0))
			var town_y: float = float(selected_town.get("terrain_y", 12.0))
			print("[TOWN_STALL_TEST] Return hold complete, flying back into town")
			_reset_town_measurement_window("repeat_entry_second")
			_begin_flight_to_target(
				Vector3(town_x, town_y + TELEPORT_HEIGHT_OFFSET, town_z),
				Phase.FLY_TO_TOWN_SECOND,
				"fly_to_town_second",
				"town center",
				{
					"building_count": int(selected_town.get("building_count", 0)),
					"town_radius": float(selected_town.get("radius", 0.0))
				}
			)
			return

		print("[TOWN_STALL_TEST] Hold complete, quitting")
		_begin_shutdown()


func _begin_shutdown() -> void:
	if pending_quit:
		return
	pending_quit = true
	phase = Phase.DONE
	_emit_scope_event("town_stall_test", "shutdown_requested", {
		"world_path": generated_world_path,
		"phase": str(phase)
	})
	_write_native_town_entry_snapshot()
	town_entry_capture_started = false
	if is_instance_valid(game_root):
		game_root.process_mode = Node.PROCESS_MODE_DISABLED
	_cleanup_managers_before_quit()
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(game_root):
		game_root.queue_free()
	call_deferred("_finalize_shutdown")


func _cleanup_managers_before_quit() -> void:
	var terrain_manager := _find_manager_node("terrain_manager", "TerrainManager")
	if terrain_manager:
		_disable_node_for_shutdown(terrain_manager)
		if terrain_manager.has_method("clear_all_chunks"):
			terrain_manager.clear_all_chunks()

	var building_manager := _find_manager_node("building_manager", "BuildingManager")
	if building_manager:
		_disable_node_for_shutdown(building_manager)
		if building_manager.has_method("clear_immediate_for_shutdown"):
			building_manager.clear_immediate_for_shutdown()
		elif building_manager.has_method("clear_for_shutdown"):
			building_manager.clear_for_shutdown()
		else:
			if building_manager.has_method("clear_pending_object_collision_tasks"):
				building_manager.clear_pending_object_collision_tasks()
			if building_manager.has_method("clear_global_visual_batches"):
				building_manager.clear_global_visual_batches()

	var vegetation_manager := _find_manager_node("vegetation_manager", "VegetationManager")
	if vegetation_manager and vegetation_manager.has_method("clear_all_data"):
		_disable_node_for_shutdown(vegetation_manager)
		if vegetation_manager.has_method("clear_for_shutdown"):
			vegetation_manager.clear_for_shutdown()
		else:
			vegetation_manager.clear_all_data(true)

	var entity_manager := _find_manager_node("entity_manager", "EntityManager")
	if entity_manager:
		_disable_node_for_shutdown(entity_manager)
		if entity_manager.has_method("clear_for_shutdown"):
			entity_manager.clear_for_shutdown()
		elif entity_manager.has_method("clear_all_entities"):
			entity_manager.clear_all_entities()
		if entity_manager.has_method("clear_spawned_chunks"):
			entity_manager.clear_spawned_chunks()

	var vehicle_manager := _find_manager_node("vehicle_manager", "VehicleManager")
	if vehicle_manager:
		_disable_node_for_shutdown(vehicle_manager)
		if vehicle_manager.has_method("clear_immediate_for_shutdown"):
			vehicle_manager.clear_immediate_for_shutdown()
		elif vehicle_manager.has_method("clear_for_shutdown"):
			vehicle_manager.clear_for_shutdown()
		elif vehicle_manager.has_method("load_save_data"):
			vehicle_manager.load_save_data({})

	var prefab_spawner := _find_manager_node("prefab_spawner", "PrefabSpawner")
	if prefab_spawner:
		_disable_node_for_shutdown(prefab_spawner)
		if prefab_spawner.has_method("clear_pending_spawn_jobs"):
			prefab_spawner.clear_pending_spawn_jobs()

	if ClassDB.class_exists("PrefabGeometry"):
		PrefabGeometry.clear_cache()


func _disable_node_for_shutdown(node: Node) -> void:
	if not is_instance_valid(node):
		return
	node.process_mode = Node.PROCESS_MODE_DISABLED
	if node.has_method("set_process"):
		node.set_process(false)
	if node.has_method("set_physics_process"):
		node.set_physics_process(false)


func _finalize_shutdown() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0)


func _apply_baked_building_smoke_hold_extension() -> void:
	if not baked_building_persistence_smoke_enabled:
		return
	current_hold_seconds = maxf(current_hold_seconds, baked_building_persistence_smoke_timeout_seconds * 3.0)


func _on_baked_building_persistence_load_completed(success: bool, path: String) -> void:
	if not baked_building_persistence_smoke_running:
		return
	if path != baked_building_persistence_smoke_load_path:
		return
	baked_building_persistence_smoke_load_completed = true
	baked_building_persistence_smoke_load_success = success


func _run_baked_building_persistence_smoke_test() -> void:
	if pending_quit or phase == Phase.DONE or phase == Phase.FAILED:
		return
	if not baked_building_persistence_smoke_enabled:
		return

	var save_manager := get_node_or_null("/root/SaveManager")
	if not save_manager:
		_fail("SaveManager autoload missing for baked-building smoke test")
		return

	var smoke_timeout_ms := int(baked_building_persistence_smoke_timeout_seconds * 1000.0)
	var smoke_start_ms := Time.get_ticks_msec()
	var smoke_target := _find_baked_building_smoke_target()
	while smoke_target.is_empty():
		if Time.get_ticks_msec() - smoke_start_ms > smoke_timeout_ms:
			_fail("Timed out waiting for a loaded baked building target")
			return
		await get_tree().process_frame
		if pending_quit or phase == Phase.DONE or phase == Phase.FAILED:
			return
		smoke_target = _find_baked_building_smoke_target()

	baked_building_persistence_smoke_running = true
	var building_key := str(smoke_target.get("building_key", ""))
	var voxel_pos_variant: Variant = smoke_target.get("voxel_pos", Vector3.ZERO)
	var voxel_pos: Vector3 = voxel_pos_variant if typeof(voxel_pos_variant) == TYPE_VECTOR3 else Vector3.ZERO
	var static_body_variant: Variant = smoke_target.get("static_body", null)
	var static_body := static_body_variant if static_body_variant is StaticBody3D else null
	if building_key.is_empty() or static_body == null:
		_fail("Failed to resolve a baked building target for persistence smoke test")
		return

	print("[TOWN_STALL_TEST] Smoke target building=%s voxel=%s" % [building_key, voxel_pos])
	_emit_scope_event("town_stall_test", "baked_building_persistence_smoke_target", {
		"building_key": building_key,
		"voxel_x": voxel_pos.x,
		"voxel_y": voxel_pos.y,
		"voxel_z": voxel_pos.z
	})

	var building_api = BuildingAPIScript.new()
	building_api.building_manager = building_manager
	building_api.terrain_manager = terrain_manager
	building_api.player = player

	var hit := {
		"position": voxel_pos + Vector3(0.5, 0.5, 0.5),
		"normal": Vector3.UP,
		"collider": static_body
	}
	var removed := false
	if building_api.has_method("remove_block"):
		removed = bool(building_api.remove_block(hit))
	if not removed:
		_fail("Baked-building smoke test could not remove the target block")
		return

	await get_tree().process_frame
	var removed_voxel := 0
	if is_instance_valid(building_manager) and building_manager.has_method("get_voxel"):
		removed_voxel = int(building_manager.get_voxel(voxel_pos))
	if removed_voxel != 0:
		_fail("Baked-building smoke test removed the block visually but the voxel still reads as solid")
		return

	if save_manager.has_method("_find_managers"):
		save_manager._find_managers()

	var save_data_variant: Variant = {}
	if save_manager.has_method("_gather_save_data"):
		save_data_variant = save_manager._gather_save_data()
	if typeof(save_data_variant) != TYPE_DICTIONARY:
		_fail("SaveManager did not return a dictionary while gathering save data")
		return

	var save_data: Dictionary = save_data_variant
	var baked_edits_variant: Variant = save_data.get("world_map_baked_building_edits", {})
	if typeof(baked_edits_variant) != TYPE_DICTIONARY:
		_fail("SaveManager did not include baked building edit data in the save payload")
		return
	var baked_edits: Dictionary = baked_edits_variant
	var baked_buildings_variant: Variant = baked_edits.get("buildings", {})
	if typeof(baked_buildings_variant) != TYPE_DICTIONARY:
		_fail("SaveManager included baked edit data, but it was missing the buildings map")
		return
	var baked_buildings: Dictionary = baked_buildings_variant
	var building_edits_variant: Variant = baked_buildings.get(building_key, {})
	if typeof(building_edits_variant) != TYPE_DICTIONARY or (building_edits_variant as Dictionary).is_empty():
		_fail("SaveManager gathered save data, but the mined baked building edit was missing")
		return

	var smoke_dir := "user://debug/tests"
	var smoke_dir_abs := ProjectSettings.globalize_path(smoke_dir)
	if not DirAccess.dir_exists_absolute(smoke_dir_abs):
		DirAccess.make_dir_recursive_absolute(smoke_dir_abs)
	var save_path := "%s/baked_building_persistence_smoke_%d.json" % [smoke_dir, Time.get_ticks_msec()]

	print("[TOWN_STALL_TEST] Saving smoke test state to %s" % save_path)
	_emit_scope_event("town_stall_test", "baked_building_persistence_smoke_save", {
		"save_path": save_path,
		"building_key": building_key
	})

	if not save_manager.has_method("_save_game_internal"):
		_fail("SaveManager missing synchronous save helper for smoke test")
		return
	if not bool(save_manager._save_game_internal(save_path)):
		_fail("Smoke test save failed")
		return

	baked_building_persistence_smoke_load_completed = false
	baked_building_persistence_smoke_load_success = false
	baked_building_persistence_smoke_load_path = save_path
	if not save_manager.load_completed.is_connected(_on_baked_building_persistence_load_completed):
		save_manager.load_completed.connect(_on_baked_building_persistence_load_completed)

	print("[TOWN_STALL_TEST] Reloading smoke save from %s" % save_path)
	_emit_scope_event("town_stall_test", "baked_building_persistence_smoke_load", {
		"save_path": save_path,
		"building_key": building_key
	})
	if not save_manager.load_game(save_path):
		_fail("Smoke test load did not start")
		return

	smoke_start_ms = Time.get_ticks_msec()
	while not baked_building_persistence_smoke_load_completed:
		if Time.get_ticks_msec() - smoke_start_ms > smoke_timeout_ms:
			_fail("Timed out waiting for baked-building smoke load to complete")
			return
		await get_tree().process_frame
		if pending_quit or phase == Phase.DONE or phase == Phase.FAILED:
			return

	if not baked_building_persistence_smoke_load_success:
		_fail("Smoke test load completed but reported failure")
		return

	await get_tree().process_frame
	await get_tree().process_frame

	building_manager = _find_manager_node("building_manager", "BuildingManager")
	if not is_instance_valid(building_manager):
		_fail("BuildingManager vanished before verifying smoke load result")
		return

	var loaded_voxel := 0
	if building_manager.has_method("get_voxel"):
		loaded_voxel = int(building_manager.get_voxel(voxel_pos))
	if loaded_voxel != 0:
		_fail("Baked-building smoke test failed: the mined block came back after reload")
		return

	var cleanup_path := ProjectSettings.globalize_path(save_path)
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(cleanup_path)

	print("[TOWN_STALL_TEST] Baked building persistence smoke test PASSED")
	_emit_scope_event("town_stall_test", "baked_building_persistence_smoke_passed", {
		"save_path": save_path,
		"building_key": building_key,
		"voxel_x": voxel_pos.x,
		"voxel_y": voxel_pos.y,
		"voxel_z": voxel_pos.z
	})
	print("[TOWN_STALL_TEST] Hold complete, quitting")
	_emit_scope_event("town_stall_test", "hold_complete", {
		"hold_seconds": phase_time,
		"phase": str(phase),
		"smoke_test": true
	})
	_begin_shutdown()


func _find_baked_building_smoke_target() -> Dictionary:
	if not is_instance_valid(building_manager):
		building_manager = _find_manager_node("building_manager", "BuildingManager")
	if not is_instance_valid(building_manager):
		return {}

	var payloads_variant: Variant = building_manager.get("_world_map_baked_building_visual_payloads_by_key")
	if typeof(payloads_variant) != TYPE_DICTIONARY:
		return {}
	var payloads: Dictionary = payloads_variant
	if payloads.is_empty():
		return {}

	var visual_nodes_variant: Variant = building_manager.get("_world_map_baked_building_visual_nodes")
	var visual_nodes: Dictionary = visual_nodes_variant if typeof(visual_nodes_variant) == TYPE_DICTIONARY else {}

	for building_key_variant in payloads.keys():
		var building_key := str(building_key_variant)
		if building_key.is_empty():
			continue

		var payload_variant: Variant = payloads.get(building_key, {})
		if typeof(payload_variant) != TYPE_DICTIONARY:
			continue
		var payload: Dictionary = payload_variant
		var voxel_bytes: PackedByteArray = payload.get("voxel_bytes", PackedByteArray())
		var voxel_size := int(payload.get("voxel_size", 0))
		var voxel_origin_variant: Variant = payload.get("voxel_origin", Vector3.ZERO)
		var voxel_origin: Vector3 = voxel_origin_variant if typeof(voxel_origin_variant) == TYPE_VECTOR3 else Vector3.ZERO
		if voxel_bytes.is_empty() or voxel_size <= 0:
			continue

		var root_variant: Variant = visual_nodes.get(building_key, null)
		var root := root_variant if root_variant is Node3D else null
		if root == null or not is_instance_valid(root):
			continue
		var static_body := root.get_node_or_null("StaticBody") as StaticBody3D
		if static_body == null or not is_instance_valid(static_body):
			continue

		for voxel_index in range(voxel_bytes.size()):
			if int(voxel_bytes[voxel_index]) <= 0:
				continue
			var local_x := voxel_index % voxel_size
			var local_y := int(voxel_index / voxel_size) % voxel_size
			var local_z := int(voxel_index / (voxel_size * voxel_size))
			var voxel_pos := Vector3(
				floor(voxel_origin.x) + float(local_x),
				floor(voxel_origin.y) + float(local_y),
				floor(voxel_origin.z) + float(local_z)
			)
			if not building_manager.has_method("get_voxel"):
				continue
			if int(building_manager.get_voxel(voxel_pos)) <= 0:
				continue

			return {
				"building_key": building_key,
				"voxel_pos": voxel_pos,
				"static_body": static_body
			}

	return {}


func _select_town(towns: Array) -> Dictionary:
	var best_town: Dictionary = {}
	var best_building_count: int = -1
	var best_dist: float = INF
	var fallback_town: Dictionary = {}
	var fallback_building_count: int = -1
	var fallback_dist: float = -1.0

	for town_variant in towns:
		if not town_variant is Dictionary:
			continue

		var town: Dictionary = town_variant
		var town_x: float = float(town.get("x", 0.0))
		var town_z: float = float(town.get("z", 0.0))
		var dist: float = Vector2(town_x, town_z).length()
		var building_count: int = int(town.get("building_count", 0))

		if building_count > fallback_building_count or (building_count == fallback_building_count and dist > fallback_dist):
			fallback_town = town
			fallback_building_count = building_count
			fallback_dist = dist

		if dist < TELEPORT_MIN_DISTANCE:
			continue

		if building_count > best_building_count or (building_count == best_building_count and dist < best_dist):
			best_town = town
			best_building_count = building_count
			best_dist = dist

	if not best_town.is_empty():
		return best_town
	return fallback_town


func _fail(message: String) -> void:
	if phase == Phase.FAILED or phase == Phase.DONE:
		return

	phase = Phase.FAILED
	print("[TOWN_STALL_TEST] ERROR: %s" % message)
	_emit_scope_event("town_stall_test", "failed", {
		"message": message
	})
	_write_native_town_entry_snapshot()
	get_tree().quit(1)
