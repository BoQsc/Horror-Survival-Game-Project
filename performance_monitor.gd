extends Node
## PerformanceMonitor - Tracks performance spikes and sends grouped frame summaries

# Signal for local connections
signal frame_spike(frame_number: int, total_ms: float, measures: Array)
signal thresholds_changed()

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
	"frame_time": 20.0,
	"chunk_gen": 3.0,
	"vegetation": 2.0
}

# Current thresholds (configurable at runtime)
var thresholds: Dictionary = DEFAULT_THRESHOLDS.duplicate()

# Whether to send to debugger panel (auto-enabled when debugger active)
var use_debugger_panel: bool = false

# Whether to also print to console when using debugger panel
var also_print_to_console: bool = false


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	if EngineDebugger.is_active():
		EngineDebugger.register_message_capture("perf_monitor", _on_debugger_message)
		call_deferred("_enable_panel_mode")
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


func _process(delta):
	_frame_number += 1
	var frame_ms = delta * 1000.0
	
	# Only send summary if frame exceeded threshold
	if frame_ms > thresholds.get("frame_time", 20.0):
		_send_frame_summary(frame_ms)
	
	# Clear frame measures for next frame
	_frame_measures.clear()


func _send_frame_summary(total_frame_ms: float) -> void:
	# Sort measures by duration (descending - biggest impact first)
	var sorted_measures = _frame_measures.duplicate()
	sorted_measures.sort_custom(func(a, b): return a.duration_ms > b.duration_ms)
	
	# Calculate sum of measured time
	var measured_total = 0.0
	for m in sorted_measures:
		measured_total += m.duration_ms
	
	# Calculate "Other" (unmeasured time)
	var other_ms = max(0.0, total_frame_ms - measured_total)
	
	# Build summary data
	var summary = {
		"frame": _frame_number,
		"total_ms": total_frame_ms,
		"threshold_ms": thresholds.get("frame_time", 20.0),
		"measures": [],
		"other_ms": other_ms
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
	
	# Add "Other" if significant
	if other_ms >= 0.1:
		var other_pct = (other_ms / total_frame_ms) * 100.0 if total_frame_ms > 0 else 0.0
		summary.measures.append({
			"name": "Other",
			"ms": other_ms,
			"pct": other_pct
		})
	
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
	elif also_print_to_console or not use_debugger_panel:
		# Console fallback - compact format
		var parts = ["[FRAME #%d] %.1fms" % [_frame_number, total_frame_ms]]
		for m in summary.measures:
			if m.name != "Other":
				parts.append("  %s: %.1fms (%.0f%%)" % [m.name, m.ms, m.pct])
		print("\n".join(parts))
	
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
	elif also_print_to_console or not use_debugger_panel:
		print("[%s] %s" % [category, message])
