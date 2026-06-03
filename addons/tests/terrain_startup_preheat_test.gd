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

	manager.free()
	print("[TERRAIN_STARTUP_PREHEAT_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_STARTUP_PREHEAT_TEST] FAIL: %s" % message)
	return false
