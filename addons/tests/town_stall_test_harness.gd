extends Node

const WorldMapGenScript := preload("res://world_editor/world_map_generator.gd")
const GameScene: PackedScene = preload("res://modules/world_module/world_test_world_player_v2.tscn")
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
var _scope_states: Dictionary = {}
var _recent_scope_events: Array[Dictionary] = []
var _town_entry_latest_town_state: Dictionary = {}
var _town_entry_latest_entities_state: Dictionary = {}
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
var disable_entities_enabled: bool = false
var repeat_entry_enabled: bool = false
var configured_hold_seconds: float = HOLD_SECONDS
var fly_stage: int = 0
var fly_target: Vector3 = Vector3.ZERO
var fly_target_altitude: float = 0.0
var return_origin: Vector3 = Vector3.ZERO
var current_hold_seconds: float = HOLD_SECONDS

var game_root: Node3D = null
var terrain_manager: Node = null
var chunk_manager: Node = null
var player: WorldPlayerV2 = null
var mode_manager: Node = null
var mode_editor: Node = null
var movement_component: Node = null
var loading_screen: Node = null
var pending_quit: bool = false

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


func _emit_scope_state(scope: String, payload: Dictionary) -> void:
	if scope.is_empty():
		return

	var state := payload.duplicate(true)
	var frame_number := _get_current_frame_number()
	state["frame"] = frame_number
	state["timestamp"] = Time.get_ticks_msec()
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
		"timestamp": Time.get_ticks_msec()
	}
	if not payload.is_empty():
		event["details"] = payload.duplicate(true)

	_recent_scope_events.append(event)
	if _recent_scope_events.size() > 64:
		_recent_scope_events.pop_front()


func _reset_town_measurement_window(reason: String) -> void:
	_town_entry_samples.clear()
	_scope_states.clear()
	_recent_scope_events.clear()
	_town_entry_snapshot_stamp = ""
	_town_entry_capture_reason = reason
	town_entry_capture_started = true
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


func _capture_native_town_entry_sample() -> void:
	if not town_entry_capture_started or pending_quit:
		return

	var sample := _build_native_town_entry_sample()
	if sample.is_empty():
		return

	_town_entry_samples.append(sample)


func _build_native_town_entry_sample() -> Dictionary:
	var frame_number := _get_current_frame_number()
	var fps := float(Performance.get_monitor(Performance.TIME_FPS))
	var total_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var navigation_ms := Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var vram_mb := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0)
	var other_ms := maxf(0.0, total_ms - physics_ms - navigation_ms)
	var top_measure := _resolve_native_top_measure(total_ms, physics_ms, navigation_ms, other_ms, draw_calls)

	return {
		"frame": frame_number,
		"fps": fps,
		"total_ms": total_ms,
		"draw_calls": draw_calls,
		"objects": objects,
		"physics_ms": physics_ms,
		"navigation_ms": navigation_ms,
		"vram_mb": vram_mb,
		"other_ms": other_ms,
		"top_measure_name": str(top_measure.get("name", "Unknown")),
		"top_measure_bucket": str(top_measure.get("bucket", "Unknown")),
		"top_measure_ms": float(top_measure.get("ms", 0.0)),
		"top_measure_pct": float(top_measure.get("pct", 0.0))
	}


func _resolve_native_top_measure(total_ms: float, physics_ms: float, navigation_ms: float, other_ms: float, draw_calls: int) -> Dictionary:
	var top_name := "Unmeasured"
	var top_bucket := "Unmeasured"
	var top_ms := other_ms

	if physics_ms >= navigation_ms and physics_ms >= other_ms:
		top_name = "Engine: Physics"
		top_bucket = top_name
		top_ms = physics_ms
	elif navigation_ms >= physics_ms and navigation_ms >= other_ms:
		top_name = "Engine: Navigation"
		top_bucket = top_name
		top_ms = navigation_ms
	elif draw_calls > 0:
		top_name = "GPU/Render (%d draws)" % draw_calls
		top_bucket = "GPU/Render"

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
		"stable_top_bucket": "Unknown",
		"stable_top_bucket_count": 0,
		"top_bucket_counts": {},
		"baseline_comparison": {},
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

	for index in range(start_index, samples.size()):
		var entry: Dictionary = samples[index]
		if index == start_index:
			first_entry = entry
		last_entry = entry
		total_fps += float(entry.get("fps", 0.0))
		total_draw_calls += float(entry.get("draw_calls", 0))
		total_objects += float(entry.get("objects", 0))
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

	longest_over_budget_streak = maxi(longest_over_budget_streak, current_over_budget_streak)
	longest_over_40ms_streak = maxi(longest_over_40ms_streak, current_over_40ms_streak)
	longest_over_50ms_streak = maxi(longest_over_50ms_streak, current_over_50ms_streak)

	var dominant_bucket := _get_dominant_bucket(bucket_counts)
	var avg_total_ms := total_ms / sample_count
	var avg_draw_calls := total_draw_calls / sample_count
	var avg_objects := total_objects / sample_count
	var avg_physics_ms := total_physics_ms / sample_count
	var avg_navigation_ms := total_navigation_ms / sample_count
	var avg_vram_mb := total_vram_mb / sample_count
	var avg_other_ms := total_other_ms / sample_count
	var latest_vs_window: Dictionary = {}
	if not last_entry.is_empty():
		latest_vs_window = {
			"total_ms": float(last_entry.get("total_ms", 0.0)) - avg_total_ms,
			"draw_calls": float(last_entry.get("draw_calls", 0)) - avg_draw_calls,
			"objects": float(last_entry.get("objects", 0)) - avg_objects,
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
		"stable_top_bucket": str(dominant_bucket.get("bucket", "Unknown")),
		"stable_top_bucket_count": int(dominant_bucket.get("count", 0)),
		"top_bucket_counts": bucket_counts,
		"baseline_comparison": latest_vs_window,
		"latest_town_state": _town_entry_latest_town_state.duplicate(true),
		"latest_entities_state": _town_entry_latest_entities_state.duplicate(true)
	}


func _write_native_town_entry_snapshot() -> void:
	if _town_entry_snapshot_stamp.is_empty():
		_town_entry_snapshot_stamp = _make_timestamp_slug()

	if not DirAccess.dir_exists_absolute(PERFORMANCE_SNAPSHOT_DIR):
		var dir_error := DirAccess.make_dir_recursive_absolute(PERFORMANCE_SNAPSHOT_DIR)
		if dir_error != OK:
			push_warning("[TownStallTest] Failed to create snapshot directory: %s (err %d)" % [PERFORMANCE_SNAPSHOT_DIR, dir_error])
			return

	var town_window := _build_native_town_entry_window(_town_entry_samples, _town_entry_samples.size())
	var recent_window := _build_native_town_entry_window(_town_entry_samples, TOWN_ENTRY_WINDOW_RECENT_LIMIT)
	var stable_bucket := str(town_window.get("stable_top_bucket", "Unknown"))
	var stable_bucket_count := int(town_window.get("stable_top_bucket_count", 0))
	if stable_bucket.is_empty() or stable_bucket == "Unknown":
		stable_bucket = str(recent_window.get("stable_top_bucket", "Unknown"))
		stable_bucket_count = int(recent_window.get("stable_top_bucket_count", 0))

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
		"recent_spike_window": recent_window,
		"town_entry_window": town_window,
		"latest_town_state": town_window.get("latest_town_state", {}),
		"baseline_comparison": town_window.get("baseline_comparison", recent_window.get("baseline_comparison", {}))
	}

	if not _scope_states.is_empty():
		snapshot["scope_states"] = _scope_states.duplicate(true)
	if not _recent_scope_events.is_empty():
		snapshot["recent_scope_events"] = _recent_scope_events.duplicate(true)

	_atomic_write_text_file("%s/snapshot_menu_%s.json" % [PERFORMANCE_SNAPSHOT_DIR, _town_entry_snapshot_stamp], JSON.stringify(snapshot, "\t"))


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
	disable_entities_enabled = OS.get_environment("TOWN_STALL_DISABLE_ENTITIES") == "1"
	repeat_entry_enabled = OS.get_environment("TOWN_STALL_REPEAT_ENTRY") == "1"
	configured_hold_seconds = _get_positive_env_float("TOWN_STALL_HOLD_SECONDS", HOLD_SECONDS)
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
	print("[TOWN_STALL_TEST] Disable entities: %s" % ("ON" if disable_entities_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Repeat entry: %s" % ("ON" if repeat_entry_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Hold seconds: %.1f" % configured_hold_seconds)
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
		"disable_entities": disable_entities_enabled,
		"repeat_entry": repeat_entry_enabled,
		"hold_seconds": configured_hold_seconds
	})
	_begin_generation()


func _process(delta: float) -> void:
	phase_time += delta
	if town_entry_capture_started and phase != Phase.DONE and phase != Phase.FAILED and not pending_quit:
		_capture_native_town_entry_sample()

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


func _poll_world_ready() -> void:
	if phase_time > WORLD_READY_TIMEOUT_SECONDS:
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
		return

	var terrain_ready := false
	if terrain_manager.has_method("is_initial_load_complete"):
		terrain_ready = terrain_manager.is_initial_load_complete()

	var loading_screen_done := true
	if loading_screen and ("is_loading" in loading_screen):
		loading_screen_done = not bool(loading_screen.get("is_loading"))

	if not terrain_ready or not loading_screen_done:
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

	_reset_town_measurement_window("auto_teleport_entry")
	_apply_terrain_chunk_updates_toggle()

	var town_x: float = float(selected_town.get("x", 0.0))
	var town_z: float = float(selected_town.get("z", 0.0))
	var town_y: float = float(selected_town.get("terrain_y", 12.0))
	var teleport_pos := Vector3(town_x, town_y + TELEPORT_HEIGHT_OFFSET, town_z)

	player.global_position = teleport_pos
	player.velocity = Vector3.ZERO
	hold_started_logged = false

	if chunk_manager.has_method("request_spawn_zone"):
		chunk_manager.request_spawn_zone(teleport_pos, 2)

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
	phase = Phase.HOLD_FIRST
	phase_time = 0.0
	hold_started_logged = false


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
	town_entry_capture_started = false
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
		if not town_entry_capture_started:
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
		phase_time = 0.0
		hold_started_logged = false
		return

	player.velocity = Vector3(0.0, signf(descent_delta) * AUTO_FLY_SPEED, 0.0)
	player.move_and_slide()


func _hold_in_town(_delta: float) -> void:
	if not hold_started_logged:
		print("[TOWN_STALL_TEST] Hold started")
		_emit_scope_event("town_stall_test", "hold_started", {
			"phase": str(phase),
			"hold_seconds": current_hold_seconds
		})
		hold_started_logged = true

	if phase_time >= current_hold_seconds:
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
		game_root.queue_free()
	call_deferred("_finalize_shutdown")


func _finalize_shutdown() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0)


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
