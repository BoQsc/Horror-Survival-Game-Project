extends SceneTree

const EntityManagerScript := preload("res://game/entities/entity_manager.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var manager = EntityManagerScript.new()
	manager.proximity_update_interval = 0.1
	manager.spawn_queue_update_interval = 0.2
	manager.dormant_respawn_update_interval = 0.3
	manager.balanced_ring_fill_enabled = false

	if not _expect(is_equal_approx(manager._get_entity_maintenance_timer_interval(), 0.05), "idle manager should use the harmless fallback interval"):
		return 1

	manager.dormant_entities.append({"position": Vector3.ZERO})
	if not _expect(is_equal_approx(manager._get_entity_maintenance_timer_interval(), 0.3), "dormant-only work should use the dormant interval"):
		return 1
	manager.proximity_update_interval = 0.0
	if not _expect(not manager._entity_maintenance_requires_physics_process(), "unused zero proximity interval should not force physics processing"):
		return 1

	manager.pending_spawns.append({"position": Vector3.ZERO})
	if not _expect(is_equal_approx(manager._get_entity_maintenance_timer_interval(), 0.2), "spawn work should select the faster relevant interval"):
		return 1
	manager.spawn_queue_update_interval = 0.0
	if not _expect(manager._entity_maintenance_requires_physics_process(), "active zero spawn interval should force physics processing"):
		return 1

	manager.pending_spawns.clear()
	manager.spawn_queue_update_interval = 0.2
	var entity := Node3D.new()
	manager.active_entities.append(entity)
	if not _expect(manager._entity_maintenance_requires_physics_process(), "active zero proximity interval should force physics processing"):
		return 1

	manager.active_entities.clear()
	entity.free()
	manager.free()
	print("[ENTITY_MAINTENANCE_DRIVER_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[ENTITY_MAINTENANCE_DRIVER_TEST] FAIL: %s" % message)
	return false
