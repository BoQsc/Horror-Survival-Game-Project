extends Node
## Frame Profiler - Non-invasive performance tracking
## F12 = Print stats | F11 = List all _process nodes | F10 = Toggle disable test

var _frame_times: Array[float] = []
var _physics_times: Array[float] = []
var _last_print_time: float = 0.0
var _processing_nodes: Array[Node] = [] # Cache of nodes with _process
var _disabled_nodes: Array[Node] = [] # Nodes we've disabled for testing

func _ready():
	print("[FrameProfiler] Ready")
	print("  F12 = Stats | F11 = List _process nodes | F10 = Toggle disable half")

func _process(delta):
	var process_time = Performance.get_monitor(Performance.TIME_PROCESS)
	var physics_time = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	
	_frame_times.append(process_time * 1000.0)
	_physics_times.append(physics_time * 1000.0)
	
	while _frame_times.size() > 300:
		_frame_times.pop_front()
	while _physics_times.size() > 300:
		_physics_times.pop_front()
	
	_last_print_time += delta
	if _last_print_time >= 5.0:
		_last_print_time = 0.0
		_print_stats()

func _unhandled_input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F12:
			_print_stats()
		elif event.keycode == KEY_F11:
			_list_process_nodes()
		elif event.keycode == KEY_F10:
			_toggle_disable_test()

func _print_stats():
	var fps = Performance.get_monitor(Performance.TIME_FPS)
	var objects = Performance.get_monitor(Performance.OBJECT_COUNT)
	var nodes = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	
	var process_avg = _average(_frame_times)
	var process_max = _max_val(_frame_times)
	var physics_avg = _average(_physics_times)
	var physics_max = _max_val(_physics_times)
	
	print("\n=== PROFILER (F12) ===")
	print("FPS: %.0f | Nodes: %.0f | Objects: %.0f" % [fps, nodes, objects])
	print("_process:         avg %.1fms, max %.1fms" % [process_avg, process_max])
	print("_physics_process: avg %.1fms, max %.1fms" % [physics_avg, physics_max])
	if _disabled_nodes.size() > 0:
		print("[TEST] %d nodes disabled" % _disabled_nodes.size())
	print("======================\n")

func _list_process_nodes():
	print("\n=== ALL NODES WITH _process (F11) ===")
	_processing_nodes.clear()
	_find_processing_nodes(get_tree().root)
	
	# Sort by script path for readability
	var by_script: Dictionary = {}
	for node in _processing_nodes:
		var script_path = node.get_script().resource_path if node.get_script() else "no_script"
		if not by_script.has(script_path):
			by_script[script_path] = []
		by_script[script_path].append(node)
	
	for script_path in by_script:
		var nodes = by_script[script_path]
		print("  %s (%d nodes)" % [script_path.get_file(), nodes.size()])
	
	print("TOTAL: %d nodes with _process enabled" % _processing_nodes.size())
	print("Press F10 to disable half and measure impact")
	print("=====================================\n")

func _find_processing_nodes(node: Node):
	# Check if node has processing enabled (has _process being called)
	if node.is_processing() and node != self:
		_processing_nodes.append(node)
	for child in node.get_children():
		_find_processing_nodes(child)

func _toggle_disable_test():
	if _disabled_nodes.size() > 0:
		# Re-enable all
		for node in _disabled_nodes:
			if is_instance_valid(node):
				node.set_process(true)
		print("[TEST] Re-enabled %d nodes" % _disabled_nodes.size())
		_disabled_nodes.clear()
		_frame_times.clear()
	else:
		# Disable half of processing nodes
		_processing_nodes.clear()
		_find_processing_nodes(get_tree().root)
		
		var half = _processing_nodes.size() / 2
		for i in range(half):
			var node = _processing_nodes[i]
			if is_instance_valid(node):
				node.set_process(false)
				_disabled_nodes.append(node)
		
		print("[TEST] Disabled %d of %d nodes - wait 5sec then compare stats" % [half, _processing_nodes.size()])
		print("Disabled scripts:")
		var shown: Dictionary = {}
		for node in _disabled_nodes:
			var script_path = node.get_script().resource_path if node.get_script() else "no_script"
			if not shown.has(script_path):
				print("  - %s" % script_path.get_file())
				shown[script_path] = true
		_frame_times.clear()

func _average(arr: Array[float]) -> float:
	if arr.is_empty(): return 0.0
	var sum = 0.0
	for v in arr: sum += v
	return sum / arr.size()

func _max_val(arr: Array[float]) -> float:
	if arr.is_empty(): return 0.0
	var m = arr[0]
	for v in arr:
		if v > m: m = v
	return m
