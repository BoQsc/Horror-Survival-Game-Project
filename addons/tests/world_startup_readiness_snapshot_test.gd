extends SceneTree

const CoordinatorScript = preload("res://world_performance/world_startup_coordinator.gd")


class FakeReadinessNode:
	extends Node

	var component_id: String = ""
	var pending_sequence: Array = []
	var calls: int = 0

	func _init(id: String, sequence: Array) -> void:
		component_id = id
		pending_sequence = sequence.duplicate()

	func get_startup_readiness_snapshot() -> Dictionary:
		var index := mini(calls, maxi(pending_sequence.size() - 1, 0))
		var pending := int(pending_sequence[index]) if not pending_sequence.is_empty() else 0
		calls += 1
		var ready := pending <= 0
		var progress := 1.0 if ready else 0.25
		var details := {
			"component": component_id,
			"call_count": calls
		}
		details["%s_pending" % component_id] = pending
		return {
			"ready": ready,
			"pending": pending,
			"completed": int(round(progress * 1000.0)),
			"total": 1000,
			"progress": progress,
			"message": "%s ready" % component_id if ready else "%s pending: %d" % [component_id, pending],
			"details": details
		}


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := await _run()
	quit(exit_code)


func _run() -> int:
	var coordinator := CoordinatorScript.new()
	coordinator.terrain_poll_interval_s = 0.05
	coordinator.world_content_poll_interval_s = 0.05
	coordinator.vegetation_poll_interval_s = 0.05
	coordinator.stage_timeout_s = 5.0
	get_root().add_child(coordinator)

	var terrain := _add_fake_manager("TerrainManager", "terrain_manager", "terrain", [4, 0])
	var prefab := _add_fake_manager("PrefabSpawner", "prefab_spawner", "prefab", [3, 0])
	var building := _add_fake_manager("BuildingManager", "building_manager", "building", [2, 0])
	var entity := _add_fake_manager("EntityManager", "entity_manager", "entity", [1, 0])
	var vegetation := _add_fake_manager("VegetationManager", "vegetation_manager", "vegetation", [5, 0])

	var terrain_details: Array = []
	var world_content_details: Array = []
	var vegetation_details: Array = []
	coordinator.stage_progress.connect(func(_load_id: String, stage_id: StringName, _completed: int, _total: int, details: Dictionary) -> void:
		match stage_id:
			&"terrain":
				terrain_details.append(details.duplicate(true))
			&"world_content":
				world_content_details.append(details.duplicate(true))
			&"vegetation":
				vegetation_details.append(details.duplicate(true))
	)

	coordinator.begin_load("readiness-snapshot-test", {"source": "test"})
	coordinator.start_world_startup_monitoring()
	if not await _wait_for_inactive(coordinator, 3000):
		return _fail("startup coordinator did not complete from readiness snapshots")

	var snapshot: Dictionary = coordinator.get_snapshot()
	if not _expect(not bool(snapshot.get("active", true)), "load should no longer be active"):
		return 1
	if not _expect(bool(snapshot.get("playable_ready", false)), "terrain snapshot readiness should mark playable ready"):
		return 1
	if not _expect(float(snapshot.get("overall_progress_percent", 0.0)) == 100.0, "completed snapshot load should report 100 percent"):
		return 1
	if not _expect(terrain.calls >= 2, "terrain snapshot should be polled until ready"):
		return 1
	if not _expect(prefab.calls > 0 and building.calls > 0 and entity.calls > 0, "world-content managers should be polled via snapshots"):
		return 1
	if not _expect(vegetation.calls >= 2, "vegetation snapshot should be polled until ready"):
		return 1
	if not _expect(_has_snapshot_source(terrain_details), "terrain stage details should identify snapshot source"):
		return 1
	if not _expect(_has_component(world_content_details, "entity_manager"), "world-content details should include entity manager readiness"):
		return 1
	if not _expect(_has_snapshot_source(vegetation_details), "vegetation stage details should identify snapshot source"):
		return 1

	coordinator.queue_free()
	terrain.queue_free()
	prefab.queue_free()
	building.queue_free()
	entity.queue_free()
	vegetation.queue_free()
	print("[WORLD_STARTUP_READINESS_SNAPSHOT_TEST] PASS")
	return 0


func _add_fake_manager(node_name: String, group_name: String, component_id: String, pending_sequence: Array) -> FakeReadinessNode:
	var manager := FakeReadinessNode.new(component_id, pending_sequence)
	manager.name = node_name
	get_root().add_child(manager)
	manager.add_to_group(group_name)
	return manager


func _wait_for_inactive(coordinator: Node, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while bool(coordinator.get_snapshot().get("active", false)) and Time.get_ticks_msec() < deadline:
		await process_frame
	return not bool(coordinator.get_snapshot().get("active", false))


func _has_snapshot_source(details_list: Array) -> bool:
	for details_variant in details_list:
		if details_variant is Dictionary and str(details_variant.get("source", "")) == "startup_readiness_snapshot":
			return true
	return false


func _has_component(details_list: Array, component_name: String) -> bool:
	for details_variant in details_list:
		if not (details_variant is Dictionary):
			continue
		var details := details_variant as Dictionary
		var components_variant: Variant = details.get("components", {})
		if not (components_variant is Dictionary):
			continue
		var components := components_variant as Dictionary
		if components.has(component_name):
			return true
	return false


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	return _fail(message) == 0


func _fail(message: String) -> int:
	printerr("[WORLD_STARTUP_READINESS_SNAPSHOT_TEST] FAIL: %s" % message)
	return 1
