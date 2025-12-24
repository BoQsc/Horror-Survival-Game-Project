extends Node
## Frame Profiler - Auto-detects which scripts cause spikes
## F12 = Stats | F11 = List nodes | F10 = Start auto-test (15 seconds)

var _frame_times: Array[float] = []
var _last_print_time: float = 0.0
var _processing_nodes: Array[Node] = []

# Auto-test state
var _testing: bool = false
var _test_queue: Array = []
var _test_results: Dictionary = {}
var _current_test_script: String = ""
var _test_phase: int = 0
var _test_samples: Array[float] = []
var _test_start_time: float = 0.0
const TEST_DURATION_SEC: float = 15.0 # 15 seconds total test

func _ready():
	print("[FrameProfiler] F12=Stats | F11=List | F10=Auto-test (15 sec)")

func _process(delta):
	var process_ms = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_frame_times.append(process_ms)
	while _frame_times.size() > 300:
		_frame_times.pop_front()
	
	if _testing:
		_run_auto_test(process_ms, delta)
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
	
	# Calculate time per script (15 sec total / num scripts / 2 phases)
	var time_per_phase = TEST_DURATION_SEC / _test_queue.size() / 2.0
	
	print("\n=== AUTO-TEST STARTED (15 sec) ===")
	print("Testing %d scripts, %.1fs each..." % [_test_queue.size(), time_per_phase * 2])
	print("==================================\n")
	
	_testing = true
	_test_phase = 0
	_test_samples.clear()
	_test_start_time = 0.0
	_current_test_script = _test_queue.pop_front()

func _run_auto_test(process_ms: float, delta: float):
	_test_samples.append(process_ms)
	_test_start_time += delta
	
	# Time per phase = 15 sec / (num scripts * 2 phases)
	var total_scripts = _test_results.size() + _test_queue.size() + 1
	var time_per_phase = TEST_DURATION_SEC / total_scripts / 2.0
	
	if _test_start_time < time_per_phase:
		return # Still collecting
	
	var avg = _average(_test_samples)
	
	if _test_phase == 0:
		_test_results[_current_test_script] = {"enabled": avg, "disabled": 0.0}
		for node in _processing_nodes:
			if node.get_script() and node.get_script().resource_path == _current_test_script:
				if is_instance_valid(node):
					node.set_process(false)
		_test_phase = 1
		_test_samples.clear()
		_test_start_time = 0.0
		print("  Testing: %s (disabled)" % _current_test_script.get_file())
	
	elif _test_phase == 1:
		_test_results[_current_test_script].disabled = avg
		for node in _processing_nodes:
			if node.get_script() and node.get_script().resource_path == _current_test_script:
				if is_instance_valid(node):
					node.set_process(true)
		
		if _test_queue.is_empty():
			_finish_auto_test()
		else:
			_test_phase = 0
			_test_samples.clear()
			_test_start_time = 0.0
			_current_test_script = _test_queue.pop_front()
			print("  Testing: %s (enabled)" % _current_test_script.get_file())

func _finish_auto_test():
	_testing = false
	
	print("\n========== RESULTS ==========")
	
	var sorted_scripts = _test_results.keys()
	sorted_scripts.sort_custom(func(a, b):
		var ia = _test_results[a].enabled - _test_results[a].disabled
		var ib = _test_results[b].enabled - _test_results[b].disabled
		return ia > ib
	)
	
	for script_path in sorted_scripts:
		var r = _test_results[script_path]
		var impact = r.enabled - r.disabled
		if impact > 1.0:
			print("  %-30s %+.1fms" % [script_path.get_file(), impact])
	
	print("==============================")
	print("Higher = bigger bottleneck\n")

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
