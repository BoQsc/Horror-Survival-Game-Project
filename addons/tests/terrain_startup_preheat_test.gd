extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var manager = ChunkManagerScript.new()
	manager.mutex = Mutex.new()
	manager.semaphore = Semaphore.new()
	manager.pending_nodes_mutex = Mutex.new()
	manager.cpu_mutex = Mutex.new()
	manager.completed_generation_mutex = Mutex.new()
	manager.stored_modifications_mutex = Mutex.new()
	manager.startup_preheat_radius_chunks = 1
	manager.startup_require_preheat_before_play = true
	manager.initial_load_phase = false
	manager.initial_load_target_chunks = 0

	var pending_count: int = manager.request_startup_preheat(Vector3.ZERO)
	if not _expect(pending_count == 27, "radius-one preheat should request three 3x3 chunk layers"):
		return 1
	if not _expect(manager.pending_spawn_zones.size() == 1, "preheat should create one tracked spawn zone"):
		return 1
	var zone: Dictionary = manager.pending_spawn_zones[0]
	if not _expect(StringName(str(zone.get("purpose", ""))) == &"startup_preheat", "preheat zone should be purpose-tagged"):
		return 1
	if not _expect(not manager.is_startup_preheat_ready(), "pending preheat should not report ready"):
		return 1
	if not _expect(not manager.is_initial_load_complete(), "required preheat should gate playable terrain readiness"):
		return 1

	manager.initial_load_phase = false
	manager.startup_require_preheat_before_play = false
	if not _expect(manager.is_initial_load_complete(), "optional preheat should not gate playable terrain readiness"):
		return 1

	var telemetry: Dictionary = manager.get_telemetry_snapshot()
	if not _expect(int(telemetry.get("startup_preheat_request_count", 0)) == 1, "telemetry should count preheat requests"):
		return 1
	if not _expect(int(telemetry.get("last_startup_preheat_pending_chunks", 0)) == 27, "telemetry should report pending preheat chunks"):
		return 1
	if not _expect(int(telemetry.get("startup_preheat_radius_chunks", -1)) == 1, "telemetry should report configured preheat radius"):
		return 1

	manager.pending_spawn_zones.clear()
	if not _expect(manager.is_startup_preheat_ready(), "cleared preheat should report ready"):
		return 1

	manager.active_chunks.clear()
	manager.startup_require_preheat_before_play = false
	manager.initial_load_phase = false
	manager.request_startup_preheat(Vector3.ZERO)
	if not _expect(manager.pending_spawn_zones.size() == 2, "optional wider preheat should create safety and background zones"):
		return 1
	if not _expect(int(manager.initial_load_target_chunks) == 3, "optional wider preheat should gate only the center safety column"):
		return 1
	var safety_zone: Dictionary = manager.pending_spawn_zones[0]
	var background_zone: Dictionary = manager.pending_spawn_zones[1]
	if not _expect(StringName(str(safety_zone.get("purpose", ""))) == &"startup_safety", "optional preheat should tag its safety zone"):
		return 1
	if not _expect(StringName(str(background_zone.get("purpose", ""))) == &"startup_preheat", "optional preheat should retain a background preheat zone"):
		return 1

	manager.pending_spawn_zones.remove_at(0)
	manager.initial_load_phase = false
	if not _expect(not manager.is_startup_preheat_ready(), "background preheat should remain visible in telemetry"):
		return 1
	if not _expect(manager.is_initial_load_complete(), "optional background preheat should not gate playable readiness after safety is ready"):
		return 1

	manager.pending_spawn_zones.clear()
	manager.priority_task_queue.clear()
	manager.task_queue.clear()
	manager.cpu_task_queue.clear()
	manager.completed_generation_queue.clear()
	manager.pending_nodes.clear()
	manager.initial_load_target_chunks = 0
	manager.startup_require_preheat_before_play = false
	manager.initial_load_phase = false
	manager._startup_visual_batch_gate_satisfied = false
	manager._terrain_visual_batch_dirty[Vector2i.ZERO] = true
	var optional_visual_snapshot: Dictionary = manager.get_startup_readiness_snapshot()
	var optional_visual_details: Dictionary = optional_visual_snapshot.get("details", {})
	if not _expect(bool(optional_visual_snapshot.get("ready", false)), "optional startup should not wait for visual batch polish"):
		return 1
	if not _expect(int(optional_visual_details.get("terrain_visual_batch_dirty_count", 0)) == 1, "optional readiness details should still expose dirty visual batches"):
		return 1

	manager._terrain_visual_batch_dirty.clear()
	manager.startup_require_preheat_before_play = true
	manager._startup_visual_batch_gate_satisfied = false
	manager._terrain_visual_batch_dirty[Vector2i.ZERO] = true
	var strict_visual_snapshot: Dictionary = manager.get_startup_readiness_snapshot()
	var strict_visual_details: Dictionary = strict_visual_snapshot.get("details", {})
	if not _expect(not bool(strict_visual_snapshot.get("ready", true)), "strict startup should wait for visual batch preparation"):
		return 1
	if not _expect(str(strict_visual_snapshot.get("message", "")).begins_with("Preparing terrain visual batches"), "strict startup message should name visual batch preparation"):
		return 1
	if not _expect(int(strict_visual_snapshot.get("pending", 0)) == 1, "strict startup should count one pending visual batch"):
		return 1
	if not _expect(int(strict_visual_details.get("startup_visual_batch_pending_count", 0)) == 1, "strict startup details should count pending visual batches"):
		return 1
	if not _expect(bool(strict_visual_details.get("startup_visual_batch_gate_pending", false)), "strict startup details should expose visual batch gate"):
		return 1
	if not _expect(manager._has_terrain_process_work_pending(), "strict startup visual batch gate should keep terrain process work active"):
		return 1

	manager._terrain_visual_batch_dirty.clear()
	var strict_visual_ready_snapshot: Dictionary = manager.get_startup_readiness_snapshot()
	var strict_visual_ready_details: Dictionary = strict_visual_ready_snapshot.get("details", {})
	if not _expect(bool(strict_visual_ready_snapshot.get("ready", false)), "strict startup should become ready after visual batch preparation finishes"):
		return 1
	if not _expect(bool(strict_visual_ready_details.get("startup_visual_batch_gate_satisfied", false)), "strict startup should mark visual batch gate satisfied"):
		return 1

	manager._terrain_visual_batch_dirty[Vector2i(1, 0)] = true
	var runtime_visual_snapshot: Dictionary = manager.get_startup_readiness_snapshot()
	if not _expect(bool(runtime_visual_snapshot.get("ready", false)), "post-handoff dirty visual batches should not regress startup readiness"):
		return 1
	manager.runtime_power_mode_enabled = true
	manager._runtime_power_viewer_moved_last = true
	manager.world_map_active = false
	if not _expect(manager._terrain_visual_batch_paused_for_active_gameplay(), "procedural terrain visual polish should pause during active player movement"):
		return 1
	manager.world_map_active = true
	if not _expect(not manager._terrain_visual_batch_paused_for_active_gameplay(), "world-map visual batches should keep catching up during active player movement"):
		return 1
	manager._terrain_visual_batch_dirty.clear()
	if not _expect(manager._terrain_visual_batch_paused_for_active_gameplay(), "world-map visual batching should pause once no catch-up work remains"):
		return 1

	manager.pending_spawn_zones.clear()
	manager.priority_task_queue.clear()
	manager.task_queue.clear()
	manager.cpu_task_queue.clear()
	manager.completed_generation_queue.clear()
	manager.pending_nodes.clear()
	manager.active_chunks.clear()
	manager.world_map_active = true
	manager.startup_require_preheat_before_play = true
	manager.startup_preheat_radius_chunks = 1
	manager.initial_load_phase = false
	var world_map_pending_count: int = manager.request_startup_preheat(Vector3(0.0, 8.0, 0.0))
	if not _expect(world_map_pending_count == 9, "world-map above-ground preheat should request only the baked Y=0 layer"):
		return 1
	if not _expect(int(manager.initial_load_target_chunks) == 9, "world-map initial load target should match the requested Y=0 layer"):
		return 1
	var world_map_zone: Dictionary = manager.pending_spawn_zones[0]
	var world_map_coords: Array = world_map_zone.get("pending_coords", [])
	for coord_variant in world_map_coords:
		if not (coord_variant is Vector3i):
			return 1
		var coord: Vector3i = coord_variant
		if not _expect(coord.y == 0, "world-map preheat should not queue unbaked vertical terrain layers"):
			return 1

	manager.free()
	print("[TERRAIN_STARTUP_PREHEAT_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_STARTUP_PREHEAT_TEST] FAIL: %s" % message)
	return false
