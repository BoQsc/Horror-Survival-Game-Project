extends SceneTree

const EntityManagerScript = preload("res://game/entities/entity_manager.gd")
const EntityScene = preload("res://game/entities/entity_base.tscn")


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := await _run()
	quit(exit_code)


func _run() -> int:
	var manager = EntityManagerScript.new()
	manager.procedural_spawning_enabled = false
	manager.entity_render_prewarm_frames = 0
	manager.default_entity_scene = EntityScene
	manager.entity_pool_enabled = true
	manager.entity_pool_max_size = 1
	get_root().add_child(manager)

	var first: Node3D = manager.spawn_entity(Vector3(1.0, 2.0, 3.0))
	if not _expect(first != null, "default entity should spawn"):
		return 1
	var first_id := first.get_instance_id()
	manager.despawn_entity(first)
	if not _expect(manager.entity_pool.size() == 1, "non-permanent despawn should enter the pool"):
		return 1
	if not _expect(first.get_parent() == null, "pooled entity should leave the scene tree"):
		return 1
	if not _expect(not first.visible, "pooled entity should be hidden"):
		return 1

	var reused: Node3D = manager.spawn_entity(Vector3(4.0, 5.0, 6.0))
	if not _expect(reused != null and reused.get_instance_id() == first_id, "matching packed scene should reuse the pooled instance"):
		return 1
	if not _expect(reused.get_parent() == manager and reused.visible, "reused entity should re-enter the scene tree"):
		return 1
	if not _expect(manager.entity_pool.is_empty(), "pool should be empty after reuse"):
		return 1

	manager.despawn_entity(reused, true)
	if not _expect(manager.entity_pool.is_empty(), "permanent despawn should not enter the pool"):
		return 1
	await process_frame

	var capacity_a: Node3D = manager.spawn_entity(Vector3.ZERO)
	var capacity_b: Node3D = manager.spawn_entity(Vector3.ONE)
	manager.despawn_entity(capacity_a)
	manager.despawn_entity(capacity_b)
	if not _expect(manager.entity_pool.size() == 1, "pool should respect its capacity"):
		return 1

	var telemetry: Dictionary = manager.get_telemetry_snapshot()
	if not _expect(int(telemetry.get("entity_pool_hit_count", 0)) == 1, "telemetry should count pool hits"):
		return 1
	if not _expect(int(telemetry.get("entity_pool_store_count", 0)) == 2, "telemetry should count successful pool stores"):
		return 1
	if not _expect(int(telemetry.get("entity_pool_full_discard_count", 0)) == 1, "telemetry should count capacity discards"):
		return 1

	manager.clear_all_entities()
	if not _expect(manager.entity_pool.is_empty(), "entity reset should clear retained pool instances"):
		return 1
	manager.queue_free()
	await process_frame
	print("[ENTITY_POOL_REUSE_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[ENTITY_POOL_REUSE_TEST] FAIL: %s" % message)
	return false
