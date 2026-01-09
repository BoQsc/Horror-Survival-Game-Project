extends Node
## PerformanceMonitor - Tracks performance spikes and sends to editor plugin panel

# Signal for local connections (optional)
signal spike_logged(category: String, message: String, duration_ms: float, threshold_ms: float)
signal thresholds_changed()

# Log buffer for history
var log_buffer: Array = []
const MAX_BUFFER_SIZE = 200

# Dictionary to store start times of currently running measures
var _start_times: Dictionary = {}

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
	
	# When debugger is active, enable panel mode (assumes plugin is loaded)
	if EngineDebugger.is_active():
		EngineDebugger.register_message_capture("perf_monitor", _on_debugger_message)
		# Delay enabling to give plugin time to initialize
		call_deferred("_enable_panel_mode")
	else:
		print("[PerformanceMonitor] Running without debugger")


func _enable_panel_mode() -> void:
	use_debugger_panel = true
	# Also sync to DebugManager for thread-safe logging
	if has_node("/root/DebugManager"):
		get_node("/root/DebugManager").set_debugger_panel_enabled(true)
	print("[PerformanceMonitor] Panel mode auto-enabled")


func _on_debugger_message(message: String, data: Array) -> bool:
	# Handle messages FROM the editor plugin
	# Note: Godot may send with or without the prefix, so check both
	
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
				# Echo back to panel so user sees confirmation
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
	
	if threshold_ms > 0 and duration_ms > threshold_ms:
		log_spike(measure_name, duration_ms, threshold_ms)


func log_spike(spike_name: String, duration_ms: float, threshold_ms: float) -> void:
	var message = "[SPIKE] %s took %.2fms (Threshold: %.2fms)" % [spike_name, duration_ms, threshold_ms]
	
	# Add to buffer
	var entry = {
		"category": "SPIKE",
		"message": message,
		"time": Time.get_ticks_msec()
	}
	log_buffer.append(entry)
	if log_buffer.size() > MAX_BUFFER_SIZE:
		log_buffer.pop_front()
	
	# Send to editor debugger panel if enabled
	if use_debugger_panel and EngineDebugger.is_active():
		EngineDebugger.send_message("perf_monitor:spike", [spike_name, message, duration_ms, threshold_ms])
	elif also_print_to_console or not use_debugger_panel:
		# Fallback to console
		print(message)
	
	# Emit signal
	spike_logged.emit(spike_name, message, duration_ms, threshold_ms)


## Add a generic log entry
func log_entry(category: String, message: String) -> void:
	var entry = {
		"category": category,
		"message": message,
		"time": Time.get_ticks_msec()
	}
	log_buffer.append(entry)
	if log_buffer.size() > MAX_BUFFER_SIZE:
		log_buffer.pop_front()
	
	# Send to editor debugger panel if enabled
	if use_debugger_panel and EngineDebugger.is_active():
		EngineDebugger.send_message("perf_monitor:log", [category, message])
	elif also_print_to_console or not use_debugger_panel:
		# Fallback to console
		print("[%s] %s" % [category, message])


func _process(delta):
	# Frame time monitoring
	var frame_ms = delta * 1000.0
	if frame_ms > thresholds.get("frame_time", 20.0):
		log_spike("Frame Time", frame_ms, thresholds["frame_time"])
