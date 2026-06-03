extends SceneTree

const WorldEventTrace = preload("res://world_performance/world_event_trace.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var trace = WorldEventTrace.new(3)
	var trace_id: String = trace.begin("test", {"phase": "start"})
	if not _expect(not trace_id.is_empty(), "trace ID should be created"):
		return 1

	trace.capture("one")
	trace.capture("two", {"value": 2})
	trace.capture("three")

	var snapshot: Dictionary = trace.get_snapshot()
	if not _expect(int(snapshot.get("event_count", 0)) == 4, "all events should be counted"):
		return 1
	if not _expect((snapshot.get("recent_events", []) as Array).size() == 3, "recent events should respect the limit"):
		return 1
	if not _expect(int((snapshot.get("event_counts", {}) as Dictionary).get("two", 0)) == 1, "event counts should be tracked"):
		return 1
	if not _expect(str(snapshot.get("last_event", "")) == "three", "last event should be reported"):
		return 1

	print("[WORLD_EVENT_TRACE_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_EVENT_TRACE_TEST] FAIL: %s" % message)
	return false
