extends RefCounted
## Thread-safe bounded event trace for startup and world performance telemetry.

const DEFAULT_EVENT_LIMIT: int = 64

var _event_limit: int = DEFAULT_EVENT_LIMIT
var _mutex: Mutex = Mutex.new()
var _trace_id: String = ""
var _label: String = ""
var _started_at_usec: int = 0
var _last_event_usec: int = 0
var _last_event_name: String = ""
var _event_count: int = 0
var _event_counts: Dictionary = {}
var _recent_events: Array[Dictionary] = []


func _init(event_limit: int = DEFAULT_EVENT_LIMIT) -> void:
	_event_limit = maxi(event_limit, 1)


func begin(label: String, details: Dictionary = {}) -> String:
	var now_usec := Time.get_ticks_usec()
	_mutex.lock()
	_label = label if not label.is_empty() else "trace"
	_trace_id = "%s-%d" % [_label, now_usec]
	_started_at_usec = now_usec
	_last_event_usec = 0
	_last_event_name = ""
	_event_count = 0
	_event_counts.clear()
	_recent_events.clear()
	_append_event_locked("trace_started", details, now_usec)
	var result := _trace_id
	_mutex.unlock()
	return result


func capture(event_name: String, details: Dictionary = {}) -> Dictionary:
	if event_name.is_empty():
		return {}

	var now_usec := Time.get_ticks_usec()
	_mutex.lock()
	if _started_at_usec <= 0:
		_label = "trace"
		_trace_id = "%s-%d" % [_label, now_usec]
		_started_at_usec = now_usec
		_append_event_locked("trace_started", {}, now_usec)
	var event := _append_event_locked(event_name, details, now_usec)
	_mutex.unlock()
	return event


func get_snapshot() -> Dictionary:
	var now_usec := Time.get_ticks_usec()
	_mutex.lock()
	var elapsed_ms := 0.0
	if _started_at_usec > 0:
		elapsed_ms = float(now_usec - _started_at_usec) / 1000.0
	var snapshot := {
		"trace_id": _trace_id,
		"label": _label,
		"started_at_usec": _started_at_usec,
		"elapsed_ms": elapsed_ms,
		"event_count": _event_count,
		"event_limit": _event_limit,
		"last_event": _last_event_name,
		"event_counts": _event_counts.duplicate(true),
		"recent_events": _recent_events.duplicate(true)
	}
	_mutex.unlock()
	return snapshot


func clear() -> void:
	_mutex.lock()
	_trace_id = ""
	_label = ""
	_started_at_usec = 0
	_last_event_usec = 0
	_last_event_name = ""
	_event_count = 0
	_event_counts.clear()
	_recent_events.clear()
	_mutex.unlock()


func _append_event_locked(event_name: String, details: Dictionary, now_usec: int) -> Dictionary:
	var elapsed_ms := float(now_usec - _started_at_usec) / 1000.0 if _started_at_usec > 0 else 0.0
	var since_previous_ms := 0.0
	if _last_event_usec > 0:
		since_previous_ms = float(now_usec - _last_event_usec) / 1000.0

	var event := {
		"trace_id": _trace_id,
		"event": event_name,
		"timestamp_usec": now_usec,
		"elapsed_ms": elapsed_ms,
		"since_previous_ms": since_previous_ms
	}
	if not details.is_empty():
		event["details"] = details.duplicate(true)

	_event_count += 1
	_event_counts[event_name] = int(_event_counts.get(event_name, 0)) + 1
	_last_event_usec = now_usec
	_last_event_name = event_name
	_recent_events.append(event)
	while _recent_events.size() > _event_limit:
		_recent_events.pop_front()
	return event
