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
	_send_to_active_sessions("perf_monitor:enable_panel", [true])


## Send a message to all active debugging sessions (editor → game)
func _send_to_active_sessions(message: String, data: Array) -> void:
	var sessions = get_sessions()
	for s in sessions:
		if s.is_active():
			s.send_message(message, data)


## Called by the panel to send threshold changes to the game
func send_threshold(threshold_name: String, value: float) -> void:
	_send_to_active_sessions("perf_monitor:set_threshold", [threshold_name, value])


## Called by the panel to reset all thresholds in the game
func send_reset_thresholds() -> void:
	_send_to_active_sessions("perf_monitor:reset_thresholds", [])
