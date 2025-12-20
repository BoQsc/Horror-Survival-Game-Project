extends Node

# Dictionary to store start times of currently running measures
var _start_times: Dictionary = {}

# Default thresholds (in milliseconds)
const THRESHOLD_FRAME_TIME = 20.0
const THRESHOLD_CHUNK_GEN = 3.0
const THRESHOLD_VEGETATION = 2.0

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("[PerformanceMonitor] Initialized (Autoload)")

func start_measure(name: String) -> void:
	_start_times[name] = Time.get_ticks_usec()

func end_measure(name: String, threshold_ms: float = -1.0) -> void:
	if not _start_times.has(name):
		return
		
	var start_time = _start_times[name]
	var end_time = Time.get_ticks_usec()
	var duration_ms = (end_time - start_time) / 1000.0
	
	_start_times.erase(name)
	
	if threshold_ms > 0 and duration_ms > threshold_ms:
		log_spike(name, duration_ms, threshold_ms)

func log_spike(name: String, duration_ms: float, threshold_ms: float) -> void:
	var message = "[SPIKE] %s took %.2fms (Threshold: %.2fms)" % [name, duration_ms, threshold_ms]
	print(message)

func _process(delta):
	# Frame time monitoring
	var frame_ms = delta * 1000.0
	if frame_ms > THRESHOLD_FRAME_TIME:
		log_spike("Frame Time", frame_ms, THRESHOLD_FRAME_TIME)
