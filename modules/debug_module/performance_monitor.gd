extends Node
## PerformanceMonitor - Tracks performance spikes and sends grouped frame summaries

# Signal for local connections
signal frame_spike(frame_number: int, total_ms: float, measures: Array)
signal thresholds_changed()

const PERFORMANCE_LOG_DIR := "user://debug/performance"
const PERFORMANCE_HISTORY_LIMIT := 60
const DISK_FLUSH_INTERVAL_MS := 2000
const CONTEXT_EVENT_LIMIT := 40
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

# Whether to send to debugger panel (auto-enabled when debugger active)
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
var _disk_csv_dirty: bool = false
var _disk_snapshot_dirty: bool = false
var _disk_last_flush_msec: int = 0

# Rolling context snapshots from terrain, vegetation, save/load, etc.
var _scope_states: Dictionary = {}
var _recent_scope_events: Array[Dictionary] = []


func _ready():
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


func _process(delta):
	_frame_number += 1
	var frame_ms = delta * 1000.0

	# Only send summary if frame exceeded threshold
	if frame_ms > thresholds.get("frame_time", FRAME_BUDGET_MS):
		_send_frame_summary(frame_ms)

	# Clear frame measures for next frame
	_frame_measures.clear()

	# Flush performance logs at a low cadence so disk I/O doesn't pile onto spikes.
	_flush_disk_logs_if_due()


func _send_frame_summary(total_frame_ms: float) -> void:
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
	else:
		summary.top_measure = {}

	summary.scope_states = _scope_states.duplicate(true)
	summary.recent_scope_events = _recent_scope_events.duplicate(true)

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
		"other_ms": float(summary.get("other_ms", 0.0))
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
		"scope_states": _scope_states.duplicate(true),
		"recent_scope_events": _recent_scope_events.duplicate(true)
	}
	_atomic_write_text_file(_disk_snapshot_menu_path, JSON.stringify(snapshot, "\t"))


func _make_timestamp_slug() -> String:
	return Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "T")


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
