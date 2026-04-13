@tool
extends Node
## PerformanceMonitor - Tracks performance spikes and sends grouped frame summaries

# Signal for local connections
signal frame_spike(frame_number: int, total_ms: float, measures: Array)
signal thresholds_changed()

const PERFORMANCE_LOG_DIR := "user://debug/performance"
const PERFORMANCE_HISTORY_LIMIT := 60
const RECENT_SPIKE_WINDOW_LIMIT := 10
const DISK_FLUSH_INTERVAL_MS := 2000
const CONTEXT_EVENT_LIMIT := 300
const TOWN_ENTRY_FRAME_HISTORY_LIMIT := 4096
const TARGET_FPS := 60.0
const FRAME_BUDGET_MS := 1000.0 / TARGET_FPS

# Log buffer for history
var log_buffer: Array = []
const MAX_BUFFER_SIZE = 200

# Dictionary to store start times of currently running measures
var _start_times: Dictionary = {}

# Per-frame measure collection
var _frame_measures: Array = []  # Array of {name: String, duration_ms: float}
var _frame_number: int = 0

# Default thresholds (in milliseconds)
const DEFAULT_THRESHOLDS = {
	"frame_time": FRAME_BUDGET_MS,
	"chunk_gen": 3.0,
	"vegetation": 2.0
}

# Current thresholds (configurable at runtime)
var thresholds: Dictionary = DEFAULT_THRESHOLDS.duplicate()

# Whether to send to debugger panel. The editor plugin toggles this on/off.
var use_debugger_panel: bool = false

# Whether to also print to console when using debugger panel
var also_print_to_console: bool = false

# Disk spike logging state. We keep a compact session CSV plus one rolling summary.
var _disk_logging_ready: bool = false
var _disk_session_stamp: String = ""
var _disk_csv_path: String = ""
var _disk_snapshot_menu_path: String = ""
var _disk_csv_rows: Array[String] = []
var _disk_recent_history: Array[Dictionary] = []
var _disk_latest_spike_snapshot: Dictionary = {}
var _disk_spike_count: int = 0
var _disk_sum_fps: float = 0.0
var _disk_sum_draw_calls: float = 0.0
var _disk_sum_vram_mb: float = 0.0
var _disk_sum_physics_ms: float = 0.0
var _disk_sum_navigation_ms: float = 0.0
var _disk_max_frame_ms: float = 0.0
var _disk_top_bucket_counts: Dictionary = {}
var _disk_csv_dirty: bool = false
var _disk_snapshot_dirty: bool = false
var _disk_last_flush_msec: int = 0

# Rolling context snapshots from terrain, vegetation, save/load, etc.
var _scope_states: Dictionary = {}
var _recent_scope_events: Array[Dictionary] = []
var _town_entry_capture_active: bool = false
var _town_entry_capture_reason: String = ""
var _town_entry_frame_history: Array[Dictionary] = []


func _ready():
	if Engine.is_editor_hint():
		return

	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_disk_logging_ready()

	if EngineDebugger.is_active():
		EngineDebugger.register_message_capture("perf_monitor", _on_debugger_message)
	else:
		print("[PerformanceMonitor] Running without debugger")


func _enable_panel_mode() -> void:
	use_debugger_panel = true
	if has_node("/root/DebugManager"):
		get_node("/root/DebugManager").set_debugger_panel_enabled(true)


func _on_debugger_message(message: String, data: Array) -> bool:
	# Handle messages FROM the editor plugin (with or without prefix)
	if message == "perf_monitor:enable_panel" or message == "enable_panel":
		use_debugger_panel = data[0] if data.size() > 0 else true
		if has_node("/root/DebugManager"):
			get_node("/root/DebugManager").set_debugger_panel_enabled(use_debugger_panel)
		return true

	if message == "perf_monitor:set_threshold" or message == "set_threshold":
		if data.size() >= 2:
			var threshold_name = data[0]
			var new_value = data[1]
			if thresholds.has(threshold_name):
				thresholds[threshold_name] = new_value
				thresholds_changed.emit()
				if use_debugger_panel and EngineDebugger.is_active():
					EngineDebugger.send_message("perf_monitor:log", ["Config", "[CONFIG] Threshold '%s' set to %.2fms" % [threshold_name, new_value]])
		return true

	if message == "perf_monitor:reset_thresholds" or message == "reset_thresholds":
		thresholds = DEFAULT_THRESHOLDS.duplicate()
		thresholds_changed.emit()
		if use_debugger_panel and EngineDebugger.is_active():
			EngineDebugger.send_message("perf_monitor:log", ["Config", "[CONFIG] Thresholds reset to defaults"])
		return true

	return false


func start_measure(measure_name: String) -> void:
	_start_times[measure_name] = Time.get_ticks_usec()


func end_measure(measure_name: String, threshold_ms: float = -1.0) -> void:
	if not _start_times.has(measure_name):
		return

	var start_time = _start_times[measure_name]
	var end_time = Time.get_ticks_usec()
	var duration_ms = (end_time - start_time) / 1000.0

	_start_times.erase(measure_name)

	# Always record to frame measures (we'll filter when sending summary)
	_frame_measures.append({
		"name": measure_name,
		"duration_ms": duration_ms,
		"threshold_ms": threshold_ms
	})


func capture_scope_state(scope: String, state: Dictionary) -> void:
	if scope.is_empty():
		return

	var payload := state.duplicate(true)
	payload["frame"] = _frame_number
	payload["timestamp"] = Time.get_ticks_msec()
	_scope_states[scope] = payload
	_disk_snapshot_dirty = true


func capture_scope_event(scope: String, label: String, details: Dictionary = {}) -> void:
	if scope.is_empty() or label.is_empty():
		return

	var event := {
		"scope": scope,
		"label": label,
		"frame": _frame_number,
		"timestamp": Time.get_ticks_msec(),
		"details": details.duplicate(true)
	}
	_recent_scope_events.append(event)
	if _recent_scope_events.size() > CONTEXT_EVENT_LIMIT:
		_recent_scope_events.pop_front()
	_disk_snapshot_dirty = true


func reset_measurement_window(reason: String = "") -> void:
	log_buffer.clear()
	_start_times.clear()
	_frame_measures.clear()

	_disk_recent_history.clear()
	_disk_latest_spike_snapshot.clear()
	_disk_spike_count = 0
	_disk_sum_fps = 0.0
	_disk_sum_draw_calls = 0.0
	_disk_sum_vram_mb = 0.0
	_disk_sum_physics_ms = 0.0
	_disk_sum_navigation_ms = 0.0
	_disk_max_frame_ms = 0.0
	_disk_top_bucket_counts.clear()
	_disk_csv_rows.clear()
	_disk_csv_dirty = true
	_disk_snapshot_dirty = true
	_disk_last_flush_msec = 0
	_scope_states.clear()
	_recent_scope_events.clear()
	_town_entry_frame_history.clear()
	_town_entry_capture_active = true
	_town_entry_capture_reason = reason
	_frame_number = 0

	if not reason.is_empty():
		capture_scope_state("town_stall_test", {
			"phase": "measurement_reset",
			"reason": reason
		})


func end_town_entry_capture(reason: String = "") -> void:
	if not _town_entry_capture_active:
		return
	_town_entry_capture_active = false
	_town_entry_capture_reason = reason
	_disk_snapshot_dirty = true
	if not reason.is_empty():
		capture_scope_event("town_stall_test", "town_entry_capture_complete", {
			"reason": reason
		})


func _append_town_entry_frame_sample(summary: Dictionary) -> void:
	if not _town_entry_capture_active:
		return
	var scope_states: Dictionary = summary.get("scope_states", {})
	var frame_sample := {
		"frame": int(summary.get("frame", 0)),
		"fps": float(summary.get("fps", 0.0)),
		"total_ms": float(summary.get("total_ms", 0.0)),
		"draw_calls": int(summary.get("draw_calls", 0)),
		"objects": int(summary.get("objects", 0)),
		"physics_ms": float(summary.get("physics_ms", 0.0)),
		"navigation_ms": float(summary.get("navigation_ms", 0.0)),
		"vram_mb": float(summary.get("vram_mb", 0.0)),
		"other_ms": float(summary.get("other_ms", 0.0)),
		"top_measure_name": str(summary.get("top_measure", {}).get("name", "Unknown")),
		"top_measure_bucket": str(summary.get("top_bucket", "Unknown")),
		"top_measure_ms": float(summary.get("top_measure", {}).get("ms", 0.0)),
		"top_measure_pct": float(summary.get("top_measure", {}).get("pct", 0.0)),
		"buildings_state": scope_states.get("buildings", {}).duplicate(true),
		"terrain_state": scope_states.get("terrain", {}).duplicate(true),
		"prefab_state": scope_states.get("town", {}).get("prefab_spawner", {}).duplicate(true),
		"vegetation_state": scope_states.get("vegetation", {}).duplicate(true),
		"town_state": summary.get("town_state", {}).duplicate(true),
		"town_test_state": summary.get("town_test_state", {}).duplicate(true)
	}
	_town_entry_frame_history.append(frame_sample)
	if _town_entry_frame_history.size() > TOWN_ENTRY_FRAME_HISTORY_LIMIT:
		_town_entry_frame_history.pop_front()


func _process(delta):
	_frame_number += 1
	var frame_ms = delta * 1000.0

	var frame_summary := _build_frame_summary(frame_ms)
	_append_town_entry_frame_sample(frame_summary)

	# Only send summary if frame exceeded threshold
	if frame_ms > thresholds.get("frame_time", FRAME_BUDGET_MS):
		_send_frame_summary(frame_summary)

	# Clear frame measures for next frame
	_frame_measures.clear()

	# Flush performance logs at a low cadence so disk I/O doesn't pile onto spikes.
	_flush_disk_logs_if_due()


func _build_frame_summary(total_frame_ms: float) -> Dictionary:
	# Sort measures by duration (descending - biggest impact first)
	var sorted_measures = _frame_measures.duplicate()
	sorted_measures.sort_custom(func(a, b): return a.duration_ms > b.duration_ms)

	# Calculate sum of measured time
	var measured_total = 0.0
	for m in sorted_measures:
		measured_total += m.duration_ms

	# Get Godot's built-in performance data (in seconds, convert to ms)
	var physics_time_ms = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var _render_time_ms = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0  # Includes rendering prep
	var navigation_time_ms = Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0
	var vram_mb = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0)

	# Get render info for context
	var draw_calls = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var objects_drawn = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	var fps = float(Engine.get_frames_per_second())

	# Build summary data
	var summary = {
		"frame": _frame_number,
		"total_ms": total_frame_ms,
		"threshold_ms": thresholds.get("frame_time", FRAME_BUDGET_MS),
		"fps": fps,
		"physics_ms": physics_time_ms,
		"navigation_ms": navigation_time_ms,
		"vram_mb": vram_mb,
		"timestamp": Time.get_ticks_msec(),
		"measures": [],
		"other_ms": 0.0,
		"draw_calls": int(draw_calls),
		"objects": int(objects_drawn)
	}

	# Add measures with percentages (only include significant ones > 0.1ms)
	for m in sorted_measures:
		if m.duration_ms >= 0.1:
			var pct = (m.duration_ms / total_frame_ms) * 100.0 if total_frame_ms > 0 else 0.0
			summary.measures.append({
				"name": m.name,
				"ms": m.duration_ms,
				"pct": pct
			})

	# Add Godot engine times (these are automatically tracked by the engine)
	if physics_time_ms >= 0.1:
		var pct = (physics_time_ms / total_frame_ms) * 100.0 if total_frame_ms > 0 else 0.0
		summary.measures.append({"name": "Engine: Physics", "ms": physics_time_ms, "pct": pct})
		measured_total += physics_time_ms

	if navigation_time_ms >= 0.1:
		var pct = (navigation_time_ms / total_frame_ms) * 100.0 if total_frame_ms > 0 else 0.0
		summary.measures.append({"name": "Engine: Navigation", "ms": navigation_time_ms, "pct": pct})
		measured_total += navigation_time_ms

	# Calculate "Other" (unmeasured time - likely GPU/Render)
	var other_ms = max(0.0, total_frame_ms - measured_total)
	summary.other_ms = other_ms

	# Add render context as "GPU/Render" estimate
	if other_ms >= 0.1:
		var other_pct = (other_ms / total_frame_ms) * 100.0 if total_frame_ms > 0 else 0.0
		# Label it as GPU if draw calls are high
		var label = "GPU/Render" if draw_calls > 100 else "Unmeasured"
		summary.measures.append({
			"name": label + " (%d draws)" % int(draw_calls),
			"ms": other_ms,
			"pct": other_pct
		})

	# Re-sort by duration after adding engine times
	summary.measures.sort_custom(func(a, b): return a.ms > b.ms)

	if not summary.measures.is_empty():
		var top_measure = summary.measures[0]
		summary.top_measure = {
			"name": top_measure.get("name", "Unknown"),
			"ms": float(top_measure.get("ms", 0.0)),
			"pct": float(top_measure.get("pct", 0.0))
		}
		summary.top_bucket = _normalize_measure_bucket(str(summary.top_measure.get("name", "Unknown")))
	else:
		summary.top_measure = {}
		summary.top_bucket = "Unknown"

	summary.scope_states = _scope_states.duplicate(true)
	summary.recent_scope_events = _recent_scope_events.duplicate(true)

	return summary


func _send_frame_summary(summary: Dictionary) -> void:
	var total_frame_ms: float = float(summary.get("total_ms", 0.0))

	# Add to log buffer
	var frame_entry = {
		"category": "FRAME",
		"message": "Frame #%d: %.1fms" % [_frame_number, total_frame_ms],
		"time": Time.get_ticks_msec(),
		"summary": summary
	}
	log_buffer.append(frame_entry)
	if log_buffer.size() > MAX_BUFFER_SIZE:
		log_buffer.pop_front()

	# Send to panel
	if use_debugger_panel and EngineDebugger.is_active():
		EngineDebugger.send_message("perf_monitor:frame_summary", [summary])
	elif also_print_to_console:
		# Console fallback - compact format
		var parts = ["[FRAME #%d] %.1fms" % [_frame_number, total_frame_ms]]
		for m in summary.measures:
			if m.name != "Other":
				parts.append("  %s: %.1fms (%.0f%%)" % [m.name, m.ms, m.pct])
		print("\n".join(parts))

	# Persist the spike to disk so we can inspect hitches after the session.
	_append_disk_spike(summary)

	# Emit signal
	frame_spike.emit(_frame_number, total_frame_ms, summary.measures)


## Add a generic log entry (for non-frame-based logging)
func log_entry(category: String, message: String) -> void:
	var entry = {
		"category": category,
		"message": message,
		"time": Time.get_ticks_msec()
	}
	log_buffer.append(entry)
	if log_buffer.size() > MAX_BUFFER_SIZE:
		log_buffer.pop_front()

	if use_debugger_panel and EngineDebugger.is_active():
		EngineDebugger.send_message("perf_monitor:log", [category, message])
	elif also_print_to_console:
		print("[%s] %s" % [category, message])


func _ensure_disk_logging_ready() -> void:
	if _disk_logging_ready:
		return

	if not DirAccess.dir_exists_absolute(PERFORMANCE_LOG_DIR):
		var dir_error = DirAccess.make_dir_recursive_absolute(PERFORMANCE_LOG_DIR)
		if dir_error != OK:
			push_warning("[PerformanceMonitor] Failed to create disk log directory: %s (err %d)" % [PERFORMANCE_LOG_DIR, dir_error])
			return

	_disk_session_stamp = _make_timestamp_slug()
	_disk_csv_path = "%s/perf_menu_%s.csv" % [PERFORMANCE_LOG_DIR, _disk_session_stamp]
	_disk_snapshot_menu_path = "%s/snapshot_menu_%s.json" % [PERFORMANCE_LOG_DIR, _disk_session_stamp]
	_disk_logging_ready = true
	print("[PerformanceMonitor] Writing performance logs to %s" % PERFORMANCE_LOG_DIR)


func _append_disk_spike(summary: Dictionary) -> void:
	_ensure_disk_logging_ready()
	if not _disk_logging_ready:
		return

	var top_measure: Dictionary = summary.get("top_measure", {})
	var top_measure_name: String = str(top_measure.get("name", "Unknown"))
	var top_measure_bucket: String = str(summary.get("top_bucket", _normalize_measure_bucket(top_measure_name)))
	if top_measure_bucket.is_empty():
		top_measure_bucket = "Unknown"

	_disk_top_bucket_counts[top_measure_bucket] = int(_disk_top_bucket_counts.get(top_measure_bucket, 0)) + 1

	var scope_states: Dictionary = summary.get("scope_states", {})
	var buildings_state: Dictionary = scope_states.get("buildings", {})
	var terrain_state: Dictionary = scope_states.get("terrain", {})
	var town_state: Dictionary = scope_states.get("town", {})
	var town_test_state: Dictionary = scope_states.get("town_stall_test", {})
	var prefab_state: Dictionary = town_state.get("prefab_spawner", {})
	var vegetation_state: Dictionary = scope_states.get("vegetation", {})

	var history_entry: Dictionary = {
		"timestamp": summary.get("timestamp", Time.get_ticks_msec()),
		"frame": int(summary.get("frame", 0)),
		"fps": float(summary.get("fps", 0.0)),
		"total_ms": float(summary.get("total_ms", 0.0)),
		"draw_calls": int(summary.get("draw_calls", 0)),
		"objects": int(summary.get("objects", 0)),
		"physics_ms": float(summary.get("physics_ms", 0.0)),
		"navigation_ms": float(summary.get("navigation_ms", 0.0)),
		"vram_mb": float(summary.get("vram_mb", 0.0)),
		"other_ms": float(summary.get("other_ms", 0.0)),
		"top_measure_name": top_measure_name,
		"top_measure_bucket": top_measure_bucket,
		"top_measure_ms": float(top_measure.get("ms", 0.0)),
		"top_measure_pct": float(top_measure.get("pct", 0.0)),
		"buildings_phase": str(buildings_state.get("phase", "")),
		"buildings_pending_spawn_jobs": int(buildings_state.get("pending_spawn_jobs", 0)),
		"buildings_queued_in_chunk": int(buildings_state.get("queued_in_chunk", 0)),
		"terrain_phase": str(terrain_state.get("phase", "")),
		"terrain_pending_nodes": int(terrain_state.get("pending_nodes", 0)),
		"terrain_task_queue": int(terrain_state.get("task_queue", 0)),
		"terrain_cpu_task_queue": int(terrain_state.get("cpu_task_queue", 0)),
		"vegetation_pending_chunks": int(vegetation_state.get("pending_chunks", 0)),
		"vegetation_pending_collider_adds": int(vegetation_state.get("pending_collider_adds", 0)),
		"vegetation_pending_collider_removes": int(vegetation_state.get("pending_collider_removes", 0)),
		"vegetation_pending_regen": bool(vegetation_state.get("pending_vegetation_regen", false)),
		"town_phase": str(town_state.get("phase", "")),
		"town_world_map_active": bool(town_state.get("world_map_active", false)),
		"town_world_definition_path": str(town_state.get("world_definition_path", "")),
		"town_viewer_chunk": str(town_state.get("viewer_chunk", "")),
		"town_viewer_pos": str(town_state.get("viewer_pos", "")),
		"town_test_state": town_test_state.duplicate(true),
		"town_test_phase": str(town_test_state.get("phase", "")),
		"town_test_auto_fly": bool(town_test_state.get("auto_fly", false)),
		"town_test_auto_teleport": bool(town_test_state.get("auto_teleport", false)),
		"town_test_disable_buildings": bool(town_test_state.get("disable_buildings", false)),
		"town_test_repeat_entry": bool(town_test_state.get("repeat_entry", false)),
		"town_buildings_phase": str(town_state.get("buildings", {}).get("phase", "")),
		"town_buildings_chunk_count": int(town_state.get("buildings", {}).get("chunk_count", 0)),
		"town_buildings_visible_chunk_count": int(town_state.get("buildings", {}).get("visible_chunk_count", 0)),
		"town_buildings_dirty_chunk_count": int(town_state.get("buildings", {}).get("dirty_chunk_count", 0)),
		"town_buildings_pending_object_collision_jobs": int(town_state.get("buildings", {}).get("pending_object_collision_jobs", 0)),
		"town_buildings_total_objects": int(town_state.get("buildings", {}).get("total_objects", 0)),
		"town_buildings_total_object_nodes": int(town_state.get("buildings", {}).get("total_object_nodes", 0)),
		"town_buildings_total_object_collision_nodes": int(town_state.get("buildings", {}).get("total_object_collision_nodes", 0)),
		"town_buildings_total_collision_box_nodes": int(town_state.get("buildings", {}).get("total_collision_box_nodes", 0)),
		"town_buildings_total_simple_visual_instances": int(town_state.get("buildings", {}).get("total_simple_visual_instances", 0)),
		"town_buildings_total_visual_batches": int(town_state.get("buildings", {}).get("total_visual_batches", 0)),
		"town_prefab_enabled": bool(prefab_state.get("enabled", false)),
		"town_prefab_pending_spawn_jobs": int(prefab_state.get("pending_spawn_jobs", 0)),
		"town_prefab_pending_spawn_keys": int(prefab_state.get("pending_spawn_keys", 0)),
		"town_prefab_spawned_positions": int(prefab_state.get("spawned_positions", 0)),
		"town_prefab_spawned_doors": int(prefab_state.get("spawned_doors", 0)),
		"town_prefab_prefab_catalog_size": int(prefab_state.get("prefab_catalog_size", 0)),
		"town_prefab_rotated_block_batches_cache_size": int(prefab_state.get("rotated_block_batches_cache_size", 0)),
		"town_state": town_state.duplicate(true)
	}

	_disk_recent_history.append(history_entry)
	if _disk_recent_history.size() > PERFORMANCE_HISTORY_LIMIT:
		_disk_recent_history.pop_front()

	_disk_spike_count += 1
	_disk_sum_fps += history_entry.fps
	_disk_sum_draw_calls += float(history_entry.draw_calls)
	_disk_sum_vram_mb += history_entry.vram_mb
	_disk_sum_physics_ms += history_entry.physics_ms
	_disk_sum_navigation_ms += history_entry.navigation_ms
	_disk_max_frame_ms = max(_disk_max_frame_ms, history_entry.total_ms)
	_disk_latest_spike_snapshot = {
		"frame": history_entry.frame,
		"timestamp": history_entry.timestamp,
		"summary": summary.duplicate(true),
		"history": _disk_recent_history.duplicate(true),
		"town_state": town_state.duplicate(true),
		"town_test_state": town_test_state.duplicate(true),
		"average_fps": _disk_sum_fps / _disk_spike_count,
		"avg_draw_calls": _disk_sum_draw_calls / _disk_spike_count,
		"avg_vram_mb": _disk_sum_vram_mb / _disk_spike_count,
		"avg_physics_ms": _disk_sum_physics_ms / _disk_spike_count,
		"avg_navigation_ms": _disk_sum_navigation_ms / _disk_spike_count,
		"max_frame_ms": _disk_max_frame_ms,
		"spike_count": _disk_spike_count,
		"session_started_at": _disk_session_stamp
	}

	_disk_csv_rows.append("%d,%d,%.2f,%.3f,%d,%d,%.3f,%.3f,%.3f,%.3f" % [
		history_entry.timestamp,
		history_entry.frame,
		history_entry.fps,
		history_entry.total_ms,
		history_entry.draw_calls,
		history_entry.objects,
		history_entry.physics_ms,
		history_entry.navigation_ms,
		history_entry.other_ms,
		history_entry.vram_mb
	])
	_disk_csv_dirty = true
	_disk_snapshot_dirty = true


func _write_disk_csv() -> void:
	var lines: Array[String] = ["timestamp,frame,fps,total_ms,draw_calls,objects,physics_ms,navigation_ms,other_ms,vram_mb"]
	lines.append_array(_disk_csv_rows)
	_atomic_write_text_file(_disk_csv_path, "\n".join(lines) + "\n")


func _write_disk_snapshot_menu() -> void:
	var recent_window: Dictionary = _build_recent_spike_window()
	var town_window: Dictionary = _build_town_entry_window()
	var dominant_bucket: Dictionary = _get_dominant_bucket(_disk_top_bucket_counts)
	var stable_bucket: String = str(town_window.get("stable_top_bucket", ""))
	var stable_bucket_count: int = int(town_window.get("stable_top_bucket_count", 0))
	if stable_bucket.is_empty():
		stable_bucket = str(recent_window.get("stable_top_bucket", dominant_bucket.get("bucket", "")))
		stable_bucket_count = int(recent_window.get("stable_top_bucket_count", dominant_bucket.get("count", 0)))
	var snapshot = {
		"average_fps": _disk_sum_fps / _disk_spike_count if _disk_spike_count > 0 else 0.0,
		"avg_draw_calls": _disk_sum_draw_calls / _disk_spike_count if _disk_spike_count > 0 else 0.0,
		"avg_vram_mb": _disk_sum_vram_mb / _disk_spike_count if _disk_spike_count > 0 else 0.0,
		"avg_physics_ms": _disk_sum_physics_ms / _disk_spike_count if _disk_spike_count > 0 else 0.0,
		"avg_navigation_ms": _disk_sum_navigation_ms / _disk_spike_count if _disk_spike_count > 0 else 0.0,
		"max_frame_ms": _disk_max_frame_ms,
		"spike_count": _disk_spike_count,
		"session_started_at": _disk_session_stamp,
		"history": _disk_recent_history.duplicate(true),
		"latest_spike": _disk_latest_spike_snapshot.duplicate(true),
		"stable_top_bucket": stable_bucket,
		"stable_top_bucket_count": stable_bucket_count,
		"top_bucket_counts": _disk_top_bucket_counts.duplicate(true),
		"recent_spike_window": recent_window,
		"town_entry_window": town_window,
		"latest_town_state": _disk_latest_spike_snapshot.get("town_state", _disk_latest_spike_snapshot.get("town_test_state", {})),
		"baseline_comparison": town_window.get("baseline_comparison", recent_window.get("baseline_comparison", {})),
		"scope_states": _scope_states.duplicate(true),
		"recent_scope_events": _recent_scope_events.duplicate(true)
	}
	_atomic_write_text_file(_disk_snapshot_menu_path, JSON.stringify(snapshot, "\t"))


func _make_timestamp_slug() -> String:
	return Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "T")


func _normalize_measure_bucket(measure_name: String) -> String:
	var bucket := measure_name.strip_edges()
	if bucket.is_empty():
		return "Unknown"
	if bucket.begins_with("GPU/Render"):
		return "GPU/Render"
	if bucket.begins_with("Prefab Load: "):
		return "Prefab Load"
	if bucket.begins_with("Prefab: "):
		return "Prefab"
	if bucket.begins_with("Engine: "):
		return bucket
	if bucket.begins_with("Building "):
		return bucket
	return bucket


func _get_dominant_bucket(counts: Dictionary) -> Dictionary:
	var dominant_bucket: String = ""
	var dominant_count: int = 0
	for bucket_variant in counts.keys():
		var bucket: String = str(bucket_variant)
		var count: int = int(counts.get(bucket_variant, 0))
		if count > dominant_count:
			dominant_bucket = bucket
			dominant_count = count
	return {
		"bucket": dominant_bucket,
		"count": dominant_count
	}


func _build_recent_spike_window(window_size: int = RECENT_SPIKE_WINDOW_LIMIT) -> Dictionary:
	return _build_spike_window(_disk_recent_history, window_size)


func _build_town_entry_window(window_size: int = RECENT_SPIKE_WINDOW_LIMIT) -> Dictionary:
	if not _town_entry_frame_history.is_empty():
		return _build_spike_window(_town_entry_frame_history, max(window_size, _town_entry_frame_history.size()))

	var start_frame := -1
	var end_frame := -1

	for event_variant in _recent_scope_events:
		if typeof(event_variant) != TYPE_DICTIONARY:
			continue
		var event: Dictionary = event_variant
		if str(event.get("scope", "")) != "town_stall_test":
			continue
		var label := str(event.get("label", ""))
		var frame := int(event.get("frame", -1))
		if label == "measurement_reset":
			start_frame = frame
			end_frame = -1
		elif label == "hold_started" and start_frame >= 0:
			end_frame = frame
			break

	var town_entries: Array = []
	for index in range(_disk_recent_history.size()):
		var entry: Dictionary = _disk_recent_history[index]
		if not _is_town_entry_spike(entry):
			continue
		var entry_frame := int(entry.get("frame", 0))
		if start_frame >= 0 and entry_frame < start_frame:
			continue
		if end_frame >= 0 and entry_frame > end_frame:
			continue
		town_entries.append(entry)

	if town_entries.is_empty():
		for index in range(_disk_recent_history.size()):
			var fallback_entry: Dictionary = _disk_recent_history[index]
			if _is_town_entry_spike(fallback_entry):
				town_entries.append(fallback_entry)

	return _build_spike_window(town_entries, max(window_size, town_entries.size()))


func _build_spike_window(entries: Array, window_size: int) -> Dictionary:
	if entries.is_empty():
		return {}

	var sample_count: int = mini(window_size, entries.size())
	if sample_count <= 0:
		return {}

	var start_index: int = entries.size() - sample_count
	var total_fps: float = 0.0
	var total_draw_calls: float = 0.0
	var total_objects: float = 0.0
	var total_ms: float = 0.0
	var total_physics_ms: float = 0.0
	var total_navigation_ms: float = 0.0
	var total_vram_mb: float = 0.0
	var total_other_ms: float = 0.0
	var bucket_counts: Dictionary = {}
	var first_entry: Dictionary = {}
	var last_entry: Dictionary = {}
	var peak_entry: Dictionary = {}
	var latest_town_state: Dictionary = {}
	var peak_total_ms: float = -1.0
	var peak_frame: int = -1
	var peak_top_bucket: String = "Unknown"
	var peak_top_measure_name: String = "Unknown"
	var peak_top_measure_ms: float = 0.0
	var peak_top_measure_pct: float = 0.0
	var frames_over_budget: int = 0
	var frames_over_40ms: int = 0
	var frames_over_50ms: int = 0
	var total_over_budget_ms: float = 0.0
	var total_over_40ms_ms: float = 0.0
	var total_over_50ms_ms: float = 0.0
	var current_over_budget_streak: int = 0
	var current_over_40ms_streak: int = 0
	var current_over_50ms_streak: int = 0
	var longest_over_budget_streak: int = 0
	var longest_over_40ms_streak: int = 0
	var longest_over_50ms_streak: int = 0

	for index in range(start_index, entries.size()):
		var entry: Dictionary = entries[index]
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

		var bucket: String = str(entry.get("top_measure_bucket", "Unknown"))
		bucket_counts[bucket] = int(bucket_counts.get(bucket, 0)) + 1

	longest_over_budget_streak = maxi(longest_over_budget_streak, current_over_budget_streak)
	longest_over_40ms_streak = maxi(longest_over_40ms_streak, current_over_40ms_streak)
	longest_over_50ms_streak = maxi(longest_over_50ms_streak, current_over_50ms_streak)

	var dominant_bucket: Dictionary = _get_dominant_bucket(bucket_counts)
	var avg_total_ms: float = total_ms / sample_count
	var avg_draw_calls: float = total_draw_calls / sample_count
	var avg_objects: float = total_objects / sample_count
	var avg_physics_ms: float = total_physics_ms / sample_count
	var avg_navigation_ms: float = total_navigation_ms / sample_count
	var avg_vram_mb: float = total_vram_mb / sample_count
	var avg_other_ms: float = total_other_ms / sample_count

	var latest_vs_window: Dictionary = {}
	if not last_entry.is_empty():
		latest_town_state = last_entry.get("town_state", {})
		if latest_town_state.is_empty():
			latest_town_state = last_entry.get("town_test_state", {})
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
		"start_frame": int(first_entry.get("frame", 0)),
		"end_frame": int(last_entry.get("frame", 0)),
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
		"latest_town_state": latest_town_state
	}


func _is_town_entry_spike(entry: Dictionary) -> bool:
	if int(entry.get("draw_calls", 0)) <= 0 or int(entry.get("objects", 0)) <= 0:
		return false

	var buildings_phase: String = str(entry.get("buildings_phase", ""))
	var town_test_phase: String = str(entry.get("town_test_phase", ""))
	var town_buildings_chunk_count := int(entry.get("town_buildings_chunk_count", 0))
	if buildings_phase == "baked_queue" and town_buildings_chunk_count <= 0:
		return false
	if buildings_phase == "baked_queue" and town_test_phase == "measurement_reset":
		return false
	if buildings_phase.begins_with("town_entry"):
		return true
	if buildings_phase == "baked_queue" or buildings_phase == "place_object" or buildings_phase == "chunk_flush":
		return true
	if buildings_phase == "object_collision_queue":
		return true
	if int(entry.get("buildings_pending_spawn_jobs", 0)) > 0:
		return true
	if int(entry.get("buildings_queued_in_chunk", 0)) > 0:
		return true
	if town_test_phase in ["fly_to_town", "town_teleported", "hold_first", "fly_back_to_origin", "hold_return", "fly_to_town_second", "hold_second"]:
		return true
	return false


func _flush_disk_logs_if_due() -> void:
	if not _disk_logging_ready:
		return

	if not _disk_csv_dirty and not _disk_snapshot_dirty:
		return

	var now = Time.get_ticks_msec()
	if _disk_last_flush_msec == 0 or now - _disk_last_flush_msec >= DISK_FLUSH_INTERVAL_MS:
		_flush_disk_logs()


func _flush_disk_logs() -> void:
	if not _disk_logging_ready:
		return

	if _disk_csv_dirty:
		_write_disk_csv()
		_disk_csv_dirty = false

	if _disk_snapshot_dirty:
		_write_disk_snapshot_menu()
		_disk_snapshot_dirty = false

	_disk_last_flush_msec = Time.get_ticks_msec()


func _exit_tree() -> void:
	_flush_disk_logs()


func _atomic_write_text_file(path: String, content: String) -> bool:
	var tmp_path = path + ".tmp"
	var file = FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_warning("[PerformanceMonitor] Failed to open temp file for writing: %s" % tmp_path)
		return false

	file.store_string(content)
	file.close()

	var dir = DirAccess.open(path.get_base_dir())
	if dir == null:
		push_warning("[PerformanceMonitor] Failed to open directory for rename: %s" % path.get_base_dir())
		return false

	var rename_error = dir.rename(tmp_path, path)
	if rename_error != OK:
		push_warning("[PerformanceMonitor] Failed to finalize log file %s (err %d)" % [path, rename_error])
		return false

	return true
