extends SceneTree

const EntityManagerScript := preload("res://game/entities/entity_manager.gd")


class FakeTerrainManager:
	extends Node3D

	var sample_count: int = 0

	func get_terrain_height(_x: float, _z: float) -> float:
		sample_count += 1
		return 12.25

	func is_collision_ready_at(_position: Vector3) -> bool:
		return false


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	await process_frame
	quit(exit_code)


func _run() -> int:
	var viewer := Node3D.new()
	viewer.add_to_group("player")
	root.add_child(viewer)

	var terrain := FakeTerrainManager.new()
	root.add_child(terrain)

	var manager = EntityManagerScript.new()
	manager.procedural_spawning_enabled = false
	manager.entity_render_prewarm_frames = 0
	manager.viewer = viewer
	manager.player = viewer
	manager.terrain_manager = terrain
	manager.pending_spawn_checks_per_frame = 4
	manager.spawn_queue_budget_ms = 10.0
	root.add_child(manager)

	var entity_scene := _make_entity_scene()
	manager.pending_spawns.append({
		"position": Vector3(10.0, 0.0, 0.0),
		"scene": entity_scene,
		"procedural": true
	})
	manager._process_spawn_queue()

	if not _expect(manager.pending_spawns.is_empty(), "height path should drain pending spawn"):
		return _cleanup(manager, terrain, viewer, 1)
	if not _expect(manager.active_entities.size() == 1, "height path should spawn one entity"):
		return _cleanup(manager, terrain, viewer, 1)
	if not _expect(manager.frozen_entities.size() == 1, "height-spawned entity should remain frozen"):
		return _cleanup(manager, terrain, viewer, 1)
	if not _expect(int(manager.get_telemetry_snapshot().get("last_spawn_queue_height_spawns", 0)) == 1, "telemetry should count height spawn"):
		return _cleanup(manager, terrain, viewer, 1)
	if not _expect(int(manager.get_telemetry_snapshot().get("last_spawn_queue_raycasts", -1)) == 0, "height path should avoid raycasts"):
		return _cleanup(manager, terrain, viewer, 1)

	print("[ENTITY_SPAWN_QUEUE_HEIGHT_PATH_TEST] PASS")
	return _cleanup(manager, terrain, viewer, 0)


func _make_entity_scene() -> PackedScene:
	var scene_root := Node3D.new()
	var packed := PackedScene.new()
	var err := packed.pack(scene_root)
	scene_root.free()
	if err != OK:
		return null
	return packed


func _cleanup(manager: Node, terrain: Node, viewer: Node, exit_code: int) -> int:
	if manager and is_instance_valid(manager):
		manager.free()
	if terrain and is_instance_valid(terrain):
		terrain.free()
	if viewer and is_instance_valid(viewer):
		viewer.free()
	return exit_code


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[ENTITY_SPAWN_QUEUE_HEIGHT_PATH_TEST] FAIL: %s" % message)
	return false
