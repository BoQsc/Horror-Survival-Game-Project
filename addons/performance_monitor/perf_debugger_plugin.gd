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
	
	if message == "perf_monitor:frame_summary":
		if panel and panel.has_method("add_frame_summary"):
			panel.add_frame_summary(data[0])
		return true
	
	return false


func _setup_session(session_id: int) -> void:
	_sessions.append(session_id)
	_send_to_active_sessions("perf_monitor:enable_panel", [true])


func _send_to_active_sessions(message: String, data: Array) -> void:
	var sessions = get_sessions()
	for s in sessions:
		if s.is_active():
			s.send_message(message, data)


func send_threshold(threshold_name: String, value: float) -> void:
	_send_to_active_sessions("perf_monitor:set_threshold", [threshold_name, value])


func send_reset_thresholds() -> void:
	_send_to_active_sessions("perf_monitor:reset_thresholds", [])
