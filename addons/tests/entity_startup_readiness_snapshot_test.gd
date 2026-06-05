extends SceneTree

const EntityManagerScript := preload("res://game/entities/entity_manager.gd")


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	await process_frame
	quit(exit_code)


func _run() -> int:
	var manager = EntityManagerScript.new()
	var viewer := Node3D.new()
	viewer.position = Vector3.ZERO
	viewer.add_to_group("player")
	manager.viewer = viewer
	manager.player = viewer
	manager.spawn_radius = 50.0
	manager.entity_render_prewarm_frames = 0
	manager.block_startup_on_deferred_spawn_backlog = false
	root.add_child(viewer)

	manager.pending_spawns.append({
		"position": Vector3(24.0, 0.0, 0.0),
		"procedural": true
	})
	manager.pending_spawns.append({
		"position": Vector3(180.0, 0.0, 0.0),
		"procedural": true
	})
	manager.deferred_spawn_chunks[Vector2i(0, 0)] = {
		"coord": Vector3i(0, 0, 0),
		"spawns": [{"position": Vector3(8.0, 0.0, 8.0)}]
	}
	manager.deferred_spawn_chunks[Vector2i(10, 0)] = {
		"coord": Vector3i(10, 0, 0),
		"spawns": [
			{"position": Vector3(320.0, 0.0, 8.0)},
			{"position": Vector3(328.0, 0.0, 8.0)}
		]
	}

	var mixed_snapshot: Dictionary = manager.get_startup_readiness_snapshot()
	var mixed_details: Dictionary = mixed_snapshot.get("details", {})
	if not _expect(not bool(mixed_snapshot.get("ready", true)), "near entity work should block startup readiness"):
		return _cleanup(manager, viewer, 1)
	if not _expect(int(mixed_snapshot.get("pending", 0)) == 2, "startup pending should count only near spawn work by default"):
		return _cleanup(manager, viewer, 1)
	if not _expect(int(mixed_details.get("startup_pending_spawns", 0)) == 1, "near pending spawn should be startup-blocking"):
		return _cleanup(manager, viewer, 1)
	if not _expect(int(mixed_details.get("startup_deferred_spawn_chunks", 0)) == 1, "near deferred chunk should be startup-blocking"):
		return _cleanup(manager, viewer, 1)
	if not _expect(int(mixed_details.get("background_spawn_backlog", 0)) == 5, "far entity backlog should remain visible as background work"):
		return _cleanup(manager, viewer, 1)

	manager.pending_spawns.remove_at(0)
	manager.deferred_spawn_chunks.erase(Vector2i(0, 0))
	var background_only_snapshot: Dictionary = manager.get_startup_readiness_snapshot()
	if not _expect(bool(background_only_snapshot.get("ready", false)), "far-only entity backlog should not block startup by default"):
		return _cleanup(manager, viewer, 1)
	if not _expect(int(background_only_snapshot.get("pending", -1)) == 0, "far-only startup pending should be zero"):
		return _cleanup(manager, viewer, 1)

	manager.block_startup_on_deferred_spawn_backlog = true
	var strict_snapshot: Dictionary = manager.get_startup_readiness_snapshot()
	if not _expect(not bool(strict_snapshot.get("ready", true)), "strict mode should block on deferred spawn backlog"):
		return _cleanup(manager, viewer, 1)
	if not _expect(int(strict_snapshot.get("pending", 0)) == 3, "strict mode should count deferred chunks and plans"):
		return _cleanup(manager, viewer, 1)

	var telemetry: Dictionary = manager.get_telemetry_snapshot()
	if not _expect(int(telemetry.get("startup_pending_total", 0)) == 3, "telemetry should expose startup pending total"):
		return _cleanup(manager, viewer, 1)
	if not _expect(int(telemetry.get("background_spawn_backlog", -1)) == 1, "telemetry should expose remaining far pending spawn backlog"):
		return _cleanup(manager, viewer, 1)

	print("[ENTITY_STARTUP_READINESS_SNAPSHOT_TEST] PASS")
	return _cleanup(manager, viewer, 0)


func _cleanup(manager: Node, viewer: Node, exit_code: int) -> int:
	manager.free()
	viewer.free()
	return exit_code


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[ENTITY_STARTUP_READINESS_SNAPSHOT_TEST] FAIL: %s" % message)
	return false
