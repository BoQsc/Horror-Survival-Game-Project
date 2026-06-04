extends SceneTree

const PlayerScript := preload("res://modules/world_player_v2/player.gd")


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := await _run()
	quit(exit_code)


func _run() -> int:
	var player = PlayerScript.new()
	root.add_child(player)
	await process_frame

	var signal_events: Array[Dictionary] = []
	player.viewer_position_changed.connect(func(previous_position: Vector3, current_position: Vector3) -> void:
		signal_events.append({
			"previous": previous_position,
			"current": current_position
		})
	)

	player.viewer_position_signal_min_distance = 0.5
	player.global_position = Vector3(0.25, 0.0, 0.0)
	player._emit_viewer_position_signal_if_needed()
	if not _expect(signal_events.size() == 0, "sub-threshold movement should not emit viewer position signal"):
		return 1

	player.global_position = Vector3(0.75, 0.0, 0.0)
	player._emit_viewer_position_signal_if_needed()
	if not _expect(signal_events.size() == 1, "threshold-crossing movement should emit viewer position signal"):
		return 1
	var first_event: Dictionary = signal_events[0]
	if not _expect(
		first_event.get("previous", Vector3.INF) == Vector3.ZERO
		and first_event.get("current", Vector3.INF) == Vector3(0.75, 0.0, 0.0),
		"signal should report the last emitted position"
	):
		return 1

	player.viewer_position_signal_min_distance = 0.0
	player.global_position = Vector3(0.80, 0.0, 0.0)
	player._emit_viewer_position_signal_if_needed()
	if not _expect(signal_events.size() == 2, "zero threshold should preserve exact movement signaling"):
		return 1

	player.queue_free()
	print("[PLAYER_VIEWER_SIGNAL_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[PLAYER_VIEWER_SIGNAL_TEST] FAIL: %s" % message)
	return false
