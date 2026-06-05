extends SceneTree

const HarnessScript = preload("res://addons/tests/town_stall_test_harness.gd")


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var harness := HarnessScript.new()
	var samples: Array[Dictionary] = [
		_make_sample(1, 1.0, 0.0, 0.0, 0.1, 0.2),
		_make_sample(2, 0.0, 3.0, 2.0, 1.5, 0.7)
	]
	samples[1]["world_runtime_building_process_awake"] = 1.0
	samples[1]["world_runtime_entity_maintenance_awake"] = 1.0
	samples[1]["terrain_finalization_pending"] = 4.0
	samples[0]["terrain_artifact_cache_entries"] = 3.0
	samples[0]["terrain_artifact_cache_bytes"] = 1024.0
	samples[0]["terrain_artifact_cache_byte_budget_ratio"] = 0.25
	samples[0]["terrain_artifact_cache_hit_ratio"] = 0.25
	samples[0]["terrain_artifact_cache_evictions"] = 2.0
	samples[0]["terrain_artifact_disk_cache_bytes"] = 4096.0
	samples[0]["terrain_artifact_disk_cache_byte_budget_ratio"] = 0.1
	samples[0]["terrain_artifact_cache_disk_hits"] = 1.0
	samples[0]["terrain_artifact_disk_cache_evictions"] = 1.0
	samples[1]["terrain_artifact_cache_entries"] = 5.0
	samples[1]["terrain_artifact_cache_bytes"] = 2048.0
	samples[1]["terrain_artifact_cache_byte_budget_ratio"] = 0.5
	samples[1]["terrain_artifact_cache_hit_ratio"] = 0.75
	samples[1]["terrain_artifact_cache_evictions"] = 3.0
	samples[1]["terrain_artifact_disk_cache_bytes"] = 8192.0
	samples[1]["terrain_artifact_disk_cache_byte_budget_ratio"] = 0.2
	samples[1]["terrain_artifact_cache_disk_hits"] = 4.0
	samples[1]["terrain_artifact_disk_cache_evictions"] = 4.0

	var window: Dictionary = harness._build_native_town_entry_window(samples, samples.size())
	if not _expect(int(window.get("world_runtime_monitor_available_samples", 0)) == 2, "window should count monitor-available samples"):
		return _fail(harness)
	if not _expect(int(window.get("world_runtime_idle_samples", 0)) == 1, "window should count idle samples"):
		return _fail(harness)
	if not _expect(int(window.get("world_runtime_busy_samples", 0)) == 1, "window should count busy samples"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("world_runtime_idle_sample_ratio", 0.0)), 0.5), "window should expose idle sample ratio"):
		return _fail(harness)
	if not _expect(not bool(window.get("world_runtime_all_idle", true)), "mixed window should not be all idle"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("avg_world_runtime_pending_work", 0.0)), 1.5), "window should average pending work"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("max_world_runtime_pending_work", 0.0)), 3.0), "window should expose max pending work"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("max_world_runtime_awake_process_count", 0.0)), 2.0), "window should expose max awake process count"):
		return _fail(harness)
	if not _expect(int(window.get("world_runtime_building_process_awake_samples", 0)) == 1, "window should count building awake samples"):
		return _fail(harness)
	if not _expect(int(window.get("world_runtime_entity_maintenance_awake_samples", 0)) == 1, "window should count entity awake samples"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("avg_terrain_artifact_cache_hit_ratio", 0.0)), 0.5), "window should average terrain artifact hit ratio"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("end_terrain_artifact_cache_hit_ratio", 0.0)), 0.75), "window should expose ending terrain artifact hit ratio"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("max_terrain_artifact_cache_entries", 0.0)), 5.0), "window should expose max terrain artifact entries"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("max_terrain_artifact_cache_bytes", 0.0)), 2048.0), "window should expose max terrain artifact cache bytes"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("end_terrain_artifact_cache_bytes", 0.0)), 2048.0), "window should expose ending terrain artifact cache bytes"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("max_terrain_artifact_cache_byte_budget_ratio", 0.0)), 0.5), "window should expose max memory cache budget ratio"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("terrain_artifact_cache_eviction_delta", 0.0)), 1.0), "window should expose memory cache eviction delta"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("max_terrain_artifact_disk_cache_bytes", 0.0)), 8192.0), "window should expose max disk artifact cache bytes"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("end_terrain_artifact_disk_cache_byte_budget_ratio", 0.0)), 0.2), "window should expose ending disk cache budget ratio"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("terrain_artifact_cache_disk_hit_delta", 0.0)), 3.0), "window should expose disk hit delta"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("terrain_artifact_disk_cache_eviction_delta", 0.0)), 3.0), "window should expose disk cache eviction delta"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("max_terrain_generation_gpu_sync_ms", 0.0)), 1.5), "window should expose max GPU sync monitor value"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("max_terrain_generation_readback_ms", 0.0)), 0.7), "window should expose max readback monitor value"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(window.get("max_terrain_finalization_pending", 0.0)), 4.0), "window should expose max terrain pending monitor value"):
		return _fail(harness)

	var startup_verdict: Dictionary = harness._build_startup_readiness_verdict(_make_startup_system_telemetry())
	if not _expect(bool(startup_verdict.get("completed", false)), "startup verdict fixture should complete"):
		return _fail(harness)
	if not _expect(str(startup_verdict.get("current_stage_label", "")) == "Preparing world content", "startup verdict should expose current stage label"):
		return _fail(harness)
	if not _expect(is_equal_approx(float(startup_verdict.get("current_stage_progress_percent", 0.0)), 60.0), "startup verdict should expose current stage progress"):
		return _fail(harness)
	if not _expect(int(startup_verdict.get("current_stage_completed", 0)) == 6, "startup verdict should expose current stage completed count"):
		return _fail(harness)
	var startup_stage_details: Dictionary = startup_verdict.get("current_stage_details", {})
	if not _expect(str(startup_stage_details.get("blocking_component", "")) == "entity_manager", "startup verdict should preserve current stage details"):
		return _fail(harness)

	var direct_startup_verdict: Dictionary = harness._build_startup_readiness_verdict(_make_direct_startup_system_telemetry())
	if not _expect(bool(direct_startup_verdict.get("completed", false)), "startup verdict should complete from direct coordinator telemetry"):
		return _fail(harness)
	if not _expect(not bool(direct_startup_verdict.get("loading_screen_available", true)), "direct startup verdict should not require loading screen telemetry"):
		return _fail(harness)
	if not _expect(bool(direct_startup_verdict.get("startup_coordinator_available", false)), "direct startup verdict should preserve coordinator availability"):
		return _fail(harness)

	var empty_window: Dictionary = harness._build_empty_native_town_entry_window()
	if not _expect(empty_window.has("world_runtime_monitor_available_samples"), "empty window should preserve monitor schema"):
		return _fail(harness)
	if not _expect(empty_window.has("world_runtime_all_idle"), "empty window should preserve idle verdict schema"):
		return _fail(harness)

	harness.free()
	print("[TOWN_STALL_MONITOR_SNAPSHOT_TEST] PASS")
	return 0


func _make_startup_system_telemetry() -> Dictionary:
	var stage_states := {}
	var started := 1000000
	for index in range(HarnessScript.STARTUP_PROOF_STAGE_IDS.size()):
		var stage_id: String = HarnessScript.STARTUP_PROOF_STAGE_IDS[index]
		var stage_started := started + index * 100000
		stage_states[stage_id] = {
			"started": true,
			"completed": true,
			"progress": 1.0,
			"started_usec": stage_started,
			"completed_usec": stage_started + 90000
		}
	var current_stage_details := {
		"message": "Preparing entities: 4 startup pending",
		"blocking_component": "entity_manager",
		"blocking_component_pending": 4
	}
	return {
		"loading_screen": {
			"is_loading": false,
			"stage": "world_content",
			"stage_label": "Preparing world content",
			"stage_progress_percent": 60.0,
			"stage_completed": 6,
			"stage_total": 10,
			"stage_details": current_stage_details,
			"stage_detail_text": "Preparing world content 60% (6/10) | blocked by entity_manager (4)",
			"progress_percent": 84.0,
			"failure_message": "",
			"cancellation_message": "",
			"elapsed_seconds": 1.0,
			"terrain_ready_emitted": true,
			"startup_coordinator": {
				"active": false,
				"failed": false,
				"cancelled": false,
				"playable_ready": true,
				"world_monitor_running": false,
				"world_monitor_completed": true,
				"overall_progress_percent": 84.0,
				"elapsed_ms": 1000.0,
				"current_stage_id": "world_content",
				"current_stage_label": "Preparing world content",
				"current_stage_progress_percent": 60.0,
				"current_stage_completed": 6,
				"current_stage_total": 10,
				"current_stage_details": current_stage_details,
				"stage_states": stage_states,
				"trace": {"event_count": 12}
			}
		}
	}


func _make_direct_startup_system_telemetry() -> Dictionary:
	var telemetry := _make_startup_system_telemetry()
	var loading_screen: Dictionary = telemetry.get("loading_screen", {})
	return {
		"startup_coordinator": loading_screen.get("startup_coordinator", {})
	}


func _make_sample(frame: int, idle: float, pending_work: float, awake_process_count: float, gpu_sync_ms: float, readback_ms: float) -> Dictionary:
	return {
		"frame": frame,
		"engine_max_fps": 60,
		"fps": 60.0,
		"draw_calls": 1,
		"objects": 1,
		"primitives": 1,
		"total_ms": 16.0,
		"process_monitor_ms": 1.0,
		"physics_ms": 1.0,
		"navigation_ms": 0.0,
		"vram_mb": 100.0,
		"other_ms": 14.0,
		"top_measure_bucket": "Synthetic",
		"top_measure_name": "Synthetic",
		"top_measure_ms": 14.0,
		"top_measure_pct": 87.5,
		"world_performance_monitors_available": true,
		"world_runtime_idle": idle,
		"world_runtime_pending_work": pending_work,
		"world_runtime_awake_process_count": awake_process_count,
		"world_runtime_terrain_process_awake": 0.0,
		"world_runtime_building_process_awake": 0.0,
		"world_runtime_prefab_process_awake": 0.0,
		"world_runtime_vegetation_process_awake": 0.0,
		"world_runtime_entity_maintenance_awake": 0.0,
		"terrain_artifact_cache_entries": 0.0,
		"terrain_artifact_cache_bytes": 0.0,
		"terrain_artifact_cache_byte_budget_ratio": 0.0,
		"terrain_artifact_cache_hit_ratio": 0.0,
		"terrain_artifact_cache_evictions": 0.0,
		"terrain_artifact_disk_cache_bytes": 0.0,
		"terrain_artifact_disk_cache_byte_budget_ratio": 0.0,
		"terrain_artifact_cache_disk_hits": 0.0,
		"terrain_artifact_disk_cache_evictions": 0.0,
		"terrain_generation_gpu_sync_ms": gpu_sync_ms,
		"terrain_generation_readback_ms": readback_ms,
		"terrain_finalization_pending": 0.0
	}


func _fail(harness: Node) -> int:
	if harness and is_instance_valid(harness):
		harness.free()
	return 1


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TOWN_STALL_MONITOR_SNAPSHOT_TEST] FAIL: %s" % message)
	return false
