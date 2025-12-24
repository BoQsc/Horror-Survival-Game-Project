extends Node
## Frame Profiler - Auto-detects which scripts cause spikes
## F12 = Stats | F11 = List nodes | F10 = Start auto-test

var _frame_times: Array[float] = []
var _last_print_time: float = 0.0
var _processing_nodes: Array[Node] = []

# Auto-test state
var _testing: bool = false
var _test_queue: Array = [] # Script paths to test
var _test_results: Dictionary = {} # script_path -> { disabled_avg, enabled_avg }
var _current_test_script: String = ""
var _test_phase: int = 0 # 0=measure enabled, 1=disable and measure, 2=re-enable
var _test_samples: Array[float] = []
var _test_frame_count: int = 0
const TEST_FRAMES: int = 30 # Frames per test phase

func _ready():
	print("[FrameProfiler] F12=Stats | F11=List | F10=Auto-test scripts")

func _process(delta):
	var process_ms = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_frame_times.append(process_ms)
	while _frame_times.size() > 300:
		_frame_times.pop_front()
	
	# Run auto-test if active
	if _testing:
		_run_auto_test(process_ms)
		return
	
	_last_print_time += delta
	if _last_print_time >= 5.0:
		_last_print_time = 0.0
		_print_stats()

func _unhandled_input(event):
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F12: _print_stats()
			KEY_F11: _list_process_nodes()
			KEY_F10: _start_auto_test()

func _print_stats():
	var fps = Performance.get_monitor(Performance.TIME_FPS)
	var nodes = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var process_avg = _average(_frame_times)
	var process_max = _max_val(_frame_times)
	print("FPS:%.0f Nodes:%.0f | Process: avg=%.0fms max=%.0fms" % [fps, nodes, process_avg, process_max])

func _list_process_nodes():
	print("\n=== _process NODES ===")
	_find_processing_nodes()
	var by_script: Dictionary = {}
	for node in _processing_nodes:
		var s = node.get_script().resource_path if node.get_script() else "no_script"
		by_script[s] = by_script.get(s, 0) + 1
	for s in by_script:
		print("  %s (%d)" % [s.get_file(), by_script[s]])
	print("======================\n")

func _find_processing_nodes():
	_processing_nodes.clear()
	_find_nodes_recursive(get_tree().root)

func _find_nodes_recursive(node: Node):
	if node.is_processing() and node != self:
		_processing_nodes.append(node)
	for child in node.get_children():
		_find_nodes_recursive(child)

func _start_auto_test():
	if _testing:
		print("[TEST] Already running")
		return
	
	_find_processing_nodes()
	
	# Get unique script paths (skip this profiler)
	var scripts: Dictionary = {}
	for node in _processing_nodes:
		if node.get_script():
			var path = node.get_script().resource_path
			if "frame_profiler" not in path:
				scripts[path] = true
	
	_test_queue = scripts.keys()
	_test_results.clear()
	
	if _test_queue.is_empty():
		print("[TEST] No scripts to test")
		return
	
	print("\n=== AUTO-TEST STARTED ===")
	print("Testing %d scripts..." % _test_queue.size())
	print("This will briefly disable each script to measure impact.")
	print("=========================\n")
	
	_testing = true
	_test_phase = 0
	_test_samples.clear()
	_test_frame_count = 0
	_current_test_script = _test_queue.pop_front()

func _run_auto_test(process_ms: float):
	_test_samples.append(process_ms)
	_test_frame_count += 1
	
	if _test_frame_count < TEST_FRAMES:
		return # Still collecting samples
	
	var avg = _average(_test_samples)
	
	if _test_phase == 0:
		# Phase 0: Measured with script enabled
		_test_results[_current_test_script] = {"enabled": avg, "disabled": 0.0}
		# Disable all nodes with this script
		for node in _processing_nodes:
			if node.get_script() and node.get_script().resource_path == _current_test_script:
				if is_instance_valid(node):
					node.set_process(false)
		_test_phase = 1
		_test_samples.clear()
		_test_frame_count = 0
	
	elif _test_phase == 1:
		# Phase 1: Measured with script disabled
		_test_results[_current_test_script].disabled = avg
		var impact = _test_results[_current_test_script].enabled - avg
		# Re-enable
		for node in _processing_nodes:
			if node.get_script() and node.get_script().resource_path == _current_test_script:
				if is_instance_valid(node):
					node.set_process(true)
		
		# Move to next script or finish
		if _test_queue.is_empty():
			_finish_auto_test()
		else:
			_test_phase = 0
			_test_samples.clear()
			_test_frame_count = 0
			_current_test_script = _test_queue.pop_front()

func _finish_auto_test():
	_testing = false
	
	print("\n========== AUTO-TEST RESULTS ==========")
	print("Script                          Impact (ms)")
	print("-".repeat(50))
	
	# Sort by impact (biggest first)
	var sorted_scripts = _test_results.keys()
	sorted_scripts.sort_custom(func(a, b):
		var ia = _test_results[a].enabled - _test_results[a].disabled
		var ib = _test_results[b].enabled - _test_results[b].disabled
		return ia > ib
	)
	
	for script_path in sorted_scripts:
		var r = _test_results[script_path]
		var impact = r.enabled - r.disabled
		var name = script_path.get_file()
		if impact > 1.0: # Only show if >1ms impact
			print("  %-35s %+.1fms" % [name, impact])
	
	print("========================================\n")
	print("Higher impact = disabling that script reduced frame time more.")
	print("Those are your bottlenecks.\n")

func _average(arr) -> float:
	if arr.is_empty(): return 0.0
	var sum = 0.0
	for v in arr: sum += v
	return sum / arr.size()

func _max_val(arr) -> float:
	if arr.is_empty(): return 0.0
	var m = arr[0]
	for v in arr:
		if v > m: m = v
	return m
