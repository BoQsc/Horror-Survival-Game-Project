@tool
extends EditorDebuggerPlugin
## Receives messages from the running game and forwards to the panel

var panel: Control = null
var _sessions: Array[int] = []


func _has_capture(prefix: String) -> bool:
	return prefix == "perf_monitor"


func _capture(message: String, data: Array, _session_id: int) -> bool:
	if message == "perf_monitor:log":
		if panel and panel.has_method("add_log"):
			panel.add_log(data[0], data[1])
		return true
	
	if message == "perf_monitor:spike":
		if panel and panel.has_method("add_log"):
			panel.add_log("SPIKE", data[1])
		return true
	
	return false


func _setup_session(session_id: int) -> void:
	_sessions.append(session_id)
	# Tell the game to enable debugger panel mode
	var sessions = get_sessions()
	for s in sessions:
		if s.is_active():
			# Send message to enable panel mode in PerformanceMonitor
			s.send_message("perf_monitor:enable_panel", [true])
