extends Node

const GAME_SCENE_PATH := "res://modules/world_module/world_test_world_player_v2.tscn"
const SNAPSHOT_DIR := "user://debug/performance/"

var warmup_timeout_s: float = 75.0
var move_seconds: float = 16.0
var hold_seconds: float = 8.0
var sample_interval_s: float = 1.0
var require_stream_settled: bool = true
var stream_settle_seconds: float = 1.5
var snapshot_dir: String = SNAPSHOT_DIR
var disable_glow_enabled: bool = false
var scaling_3d_scale_override: float = -1.0
var screenshot_dir: String = ""
var disable_entities_enabled: bool = false
var disable_vegetation_enabled: bool = false

var game_root: Node = null
var terrain_manager: Node = null
var player: Node3D = null
var phase: String = "load"
var phase_time: float = 0.0
var elapsed_time: float = 0.0
var stream_settled_time: float = 0.0
var next_sample_time: float = 0.0
var samples: Array[Dictionary] = []
var phase_events: Array[Dictionary] = []
var active_action: String = ""
var snapshot_path: String = ""
var render_feature_state: Dictionary = {}
var visual_capture_state: Dictionary = {}
var manager_isolation_state: Dictionary = {}
var snapshot_write_started: bool = false

func _ready() -> void:
	warmup_timeout_s = _env_float("PROCEDURAL_POWER_WARMUP_TIMEOUT_S", warmup_timeout_s)
	move_seconds = _env_float("PROCEDURAL_POWER_MOVE_SECONDS", move_seconds)
	hold_seconds = _env_float("PROCEDURAL_POWER_HOLD_SECONDS", hold_seconds)
	sample_interval_s = _env_float("PROCEDURAL_POWER_SAMPLE_INTERVAL_S", sample_interval_s)
	require_stream_settled = _env_bool("PROCEDURAL_POWER_REQUIRE_STREAM_SETTLED", require_stream_settled)
	stream_settle_seconds = _env_float("PROCEDURAL_POWER_STREAM_SETTLE_SECONDS", stream_settle_seconds)
	snapshot_dir = _env_string("PROCEDURAL_POWER_SNAPSHOT_DIR", snapshot_dir)
	disable_glow_enabled = _env_bool("PROCEDURAL_POWER_DISABLE_GLOW", _env_bool("TOWN_STALL_DISABLE_GLOW", false))
	scaling_3d_scale_override = _env_float("PROCEDURAL_POWER_SCALING_3D_SCALE", scaling_3d_scale_override)
	screenshot_dir = _env_string("PROCEDURAL_POWER_SCREENSHOT_DIR", screenshot_dir)
	disable_entities_enabled = _env_bool("PROCEDURAL_POWER_DISABLE_ENTITIES", false)
	disable_vegetation_enabled = _env_bool("PROCEDURAL_POWER_DISABLE_VEGETATION", false)
	_record_phase_event("start", phase)
	print("[PROCEDURAL_POWER] Loading procedural scene: %s" % GAME_SCENE_PATH)
	var packed := load(GAME_SCENE_PATH)
	if packed == null:
		_fail("failed_to_load_game_scene")
		return
	game_root = packed.instantiate()
	add_child(game_root)
	_apply_manager_isolation_toggles()
	_apply_render_feature_toggles()

func _process(delta: float) -> void:
	elapsed_time += delta
	phase_time += delta
	_refresh_nodes()
	if elapsed_time >= next_sample_time:
		_capture_sample()
		next_sample_time = elapsed_time + sample_interval_s

	match phase:
		"load":
			if _is_ready_for_measurement(delta):
				_change_phase("move")
			elif phase_time >= warmup_timeout_s:
				_fail("initial_load_timeout")
		"move":
			_apply_movement_pattern()
			if phase_time >= move_seconds:
				_release_active_action()
				_change_phase("hold")
		"hold":
			if phase_time >= hold_seconds:
				_write_snapshot_and_quit()
		"done":
			pass

func _env_float(name: String, default_value: float) -> float:
	var raw := OS.get_environment(name).strip_edges()
	if raw.is_empty() or not raw.is_valid_float():
		return default_value
	var value := float(raw)
	return value if value > 0.0 else default_value

func _env_bool(name: String, default_value: bool) -> bool:
	var raw := OS.get_environment(name).strip_edges().to_lower()
	if raw.is_empty():
		return default_value
	if raw == "1" or raw == "true" or raw == "yes" or raw == "on":
		return true
	if raw == "0" or raw == "false" or raw == "no" or raw == "off":
		return false
	return default_value

func _env_string(name: String, default_value: String) -> String:
	var raw := OS.get_environment(name).strip_edges()
	return default_value if raw.is_empty() else raw

func _refresh_nodes() -> void:
	if terrain_manager == null or not is_instance_valid(terrain_manager):
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if player == null or not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player") as Node3D

func _is_world_ready() -> bool:
	if terrain_manager == null:
		return false
	if terrain_manager.has_method("is_initial_load_complete") and not terrain_manager.is_initial_load_complete():
		return false
	return true

func _is_ready_for_measurement(delta: float) -> bool:
	if not _is_world_ready():
		stream_settled_time = 0.0
		return false
	if not require_stream_settled:
		return true
	if _is_stream_settled_for_measurement():
		stream_settled_time += delta
	else:
		stream_settled_time = 0.0
	return stream_settled_time >= stream_settle_seconds

func _is_stream_settled_for_measurement() -> bool:
	var terrain := _manager_snapshot("terrain_manager")
	if terrain.is_empty():
		return false
	if bool(terrain.get("initial_load_phase", false)):
		return false
	if bool(terrain.get("terrain_stream_under_target", false)):
		return false
	var min_target := int(terrain.get("terrain_stream_min_chunk_target", 0))
	if min_target > 0:
		if int(terrain.get("active_chunk_count", 0)) < min_target:
			return false
		if int(terrain.get("rendered_terrain_chunk_count", 0)) < min_target:
			return false
	for key in [
		"pending_node_count",
		"task_queue_count",
		"cpu_task_queue_count",
		"completed_generation_queue_count",
		"terrain_visual_batch_dirty_count",
		"terrain_visual_batch_async_in_flight_count",
		"terrain_visual_batch_async_completed_count",
		"water_visual_batch_dirty_count"
	]:
		if int(terrain.get(key, 0)) > 0:
			return false
	return true

func _change_phase(next_phase: String) -> void:
	print("[PROCEDURAL_POWER] Phase: %s -> %s at %.2fs" % [phase, next_phase, elapsed_time])
	phase = next_phase
	phase_time = 0.0
	_record_phase_event("change", phase)

func _record_phase_event(label: String, event_phase: String) -> void:
	phase_events.append({
		"label": label,
		"phase": event_phase,
		"elapsed_time": elapsed_time,
		"epoch": Time.get_unix_time_from_system()
	})

func _apply_movement_pattern() -> void:
	var actions := ["move_forward", "move_left", "move_backward", "move_right"]
	var segment := maxf(move_seconds / float(actions.size()), 0.1)
	var index := clampi(int(floor(phase_time / segment)), 0, actions.size() - 1)
	_press_action(actions[index])

func _press_action(action: String) -> void:
	if action == active_action:
		return
	_release_active_action()
	if InputMap.has_action(action):
		Input.action_press(action)
		active_action = action

func _release_active_action() -> void:
	if not active_action.is_empty() and InputMap.has_action(active_action):
		Input.action_release(active_action)
	active_action = ""

func _capture_sample() -> void:
	var terrain := _manager_snapshot("terrain_manager")
	var pipeline_compilations := _collect_pipeline_compilation_monitor_snapshot()
	var sample := {
		"elapsed_time": elapsed_time,
		"epoch": Time.get_unix_time_from_system(),
		"phase": phase,
		"phase_time": phase_time,
		"fps": Engine.get_frames_per_second(),
		"process_ms": float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0,
		"physics_ms": float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0,
		"engine_max_fps": Engine.max_fps,
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"render_objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"vram_mb": float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / (1024.0 * 1024.0),
		"texture_mem_mb": float(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)) / (1024.0 * 1024.0),
		"buffer_mem_mb": float(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)) / (1024.0 * 1024.0),
		"pipeline_compilations_canvas": int(pipeline_compilations.get("canvas", 0)),
		"pipeline_compilations_mesh": int(pipeline_compilations.get("mesh", 0)),
		"pipeline_compilations_surface": int(pipeline_compilations.get("surface", 0)),
		"pipeline_compilations_draw": int(pipeline_compilations.get("draw", 0)),
		"pipeline_compilations_specialization": int(pipeline_compilations.get("specialization", 0)),
		"pipeline_compilations_total": int(pipeline_compilations.get("total", 0)),
		"render_features": _render_feature_snapshot(),
		"terrain": terrain,
		"building": _manager_snapshot("building_manager"),
		"vegetation": _manager_snapshot("vegetation_manager"),
		"entities": _manager_snapshot("entity_manager")
	}
	samples.append(sample)

func _manager_snapshot(group_name: String) -> Dictionary:
	var node := get_tree().get_first_node_in_group(group_name)
	if node and node.has_method("get_telemetry_snapshot"):
		return node.get_telemetry_snapshot()
	return {}

func _collect_pipeline_compilation_monitor_snapshot() -> Dictionary:
	var canvas := int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS))
	var mesh := int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH))
	var surface := int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE))
	var draw := int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW))
	var specialization := int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SPECIALIZATION))
	return {
		"canvas": canvas,
		"mesh": mesh,
		"surface": surface,
		"draw": draw,
		"specialization": specialization,
		"total": canvas + mesh + surface + draw + specialization
	}

func _ensure_snapshot_dir() -> bool:
	if not snapshot_dir.begins_with("user://"):
		var absolute_err := DirAccess.make_dir_recursive_absolute(snapshot_dir)
		return absolute_err == OK or absolute_err == ERR_ALREADY_EXISTS

	var dir := DirAccess.open("user://")
	if dir == null:
		return false
	if not DirAccess.dir_exists_absolute("user://debug"):
		var err := dir.make_dir("debug")
		if err != OK and err != ERR_ALREADY_EXISTS:
			return false
	if not DirAccess.dir_exists_absolute("user://debug/performance"):
		dir = DirAccess.open("user://debug")
		if dir == null:
			return false
		var err := dir.make_dir("performance")
		if err != OK and err != ERR_ALREADY_EXISTS:
			return false
	return true

func _write_snapshot_and_quit() -> void:
	if snapshot_write_started:
		return
	snapshot_write_started = true
	_release_active_action()
	phase = "done"
	_record_phase_event("done", phase)
	_capture_sample()
	if not _ensure_snapshot_dir():
		_fail("failed_to_create_snapshot_dir")
		return
	visual_capture_state = _capture_visual_snapshot()
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	snapshot_path = snapshot_dir.path_join("procedural_power_snapshot_%s.json" % stamp)
	var payload := {
		"benchmark": "procedural_power",
		"completed": true,
		"elapsed_time": elapsed_time,
		"move_seconds": move_seconds,
		"hold_seconds": hold_seconds,
		"require_stream_settled": require_stream_settled,
		"stream_settle_seconds": stream_settle_seconds,
		"render_features": _render_feature_snapshot(),
		"visual_capture": visual_capture_state.duplicate(true),
		"manager_isolation": manager_isolation_state.duplicate(true),
		"phase_events": phase_events,
		"samples": samples,
		"final_sample": samples[-1] if not samples.is_empty() else {}
	}
	var file := FileAccess.open(snapshot_path, FileAccess.WRITE)
	if file == null:
		_fail("failed_to_open_snapshot")
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	print("[PROCEDURAL_POWER] Snapshot: %s" % snapshot_path)
	call_deferred("_shutdown_after_snapshot")

func _fail(reason: String) -> void:
	_release_active_action()
	print("[PROCEDURAL_POWER] ERROR: %s" % reason)
	get_tree().quit(1)

func _apply_render_feature_toggles() -> void:
	var glow_count := 0
	if disable_glow_enabled and is_instance_valid(game_root):
		glow_count = _set_glow_enabled_recursive(game_root, false)

	var viewport := get_viewport()
	var scaling_supported := viewport != null and "scaling_3d_scale" in viewport
	var previous_scale := 0.0
	var actual_scale := 0.0
	var scale_applied := false
	if scaling_supported:
		previous_scale = float(viewport.scaling_3d_scale)
		actual_scale = previous_scale
		if scaling_3d_scale_override > 0.0:
			viewport.scaling_3d_scale = clampf(scaling_3d_scale_override, 0.5, 1.0)
			actual_scale = float(viewport.scaling_3d_scale)
			scale_applied = true

	render_feature_state = {
		"disable_glow": disable_glow_enabled,
		"glow_environment_count": glow_count,
		"scaling_3d_scale_supported": scaling_supported,
		"scaling_3d_scale_requested": scaling_3d_scale_override,
		"scaling_3d_scale_previous": previous_scale,
		"scaling_3d_scale_actual": actual_scale,
		"scaling_3d_scale_applied": scale_applied
	}
	print(
		"[PROCEDURAL_POWER] Render feature toggles: disable_glow=%s glow_envs=%d scale_requested=%.2f scale_actual=%.2f scale_applied=%s" % [
			"true" if disable_glow_enabled else "false",
			glow_count,
			scaling_3d_scale_override,
			actual_scale,
			"true" if scale_applied else "false"
		]
	)

func _apply_manager_isolation_toggles() -> void:
	var disabled_entities := _disable_manager_for_isolation("entity_manager", "EntityManager") if disable_entities_enabled else false
	var disabled_vegetation := _disable_manager_for_isolation("vegetation_manager", "VegetationManager") if disable_vegetation_enabled else false
	manager_isolation_state = {
		"disable_entities": disable_entities_enabled,
		"entities_disabled": disabled_entities,
		"disable_vegetation": disable_vegetation_enabled,
		"vegetation_disabled": disabled_vegetation
	}
	if disable_entities_enabled or disable_vegetation_enabled:
		print(
			"[PROCEDURAL_POWER] Manager isolation: entities=%s vegetation=%s" % [
				"disabled" if disabled_entities else "not_found",
				"disabled" if disabled_vegetation else "not_found"
			]
		)

func _disable_manager_for_isolation(group_name: String, fallback_name: String) -> bool:
	var node := _find_manager_node(group_name, fallback_name)
	if not node:
		return false
	_disable_node_for_shutdown(node)
	node.queue_free()
	return true

func _set_glow_enabled_recursive(node: Node, enabled: bool) -> int:
	var changed := 0
	var world_environment := node as WorldEnvironment
	if world_environment:
		var environment := world_environment.environment
		if environment:
			var environment_copy := environment.duplicate() as Environment
			environment_copy.glow_enabled = enabled
			world_environment.environment = environment_copy
			changed += 1

	for child in node.get_children():
		changed += _set_glow_enabled_recursive(child, enabled)
	return changed

func _render_feature_snapshot() -> Dictionary:
	var snapshot := render_feature_state.duplicate(true)
	var viewport := get_viewport()
	if viewport != null and "scaling_3d_scale" in viewport:
		var current_scale := float(viewport.scaling_3d_scale)
		snapshot["scaling_3d_scale_current"] = current_scale
		snapshot["scaling_3d_scale_actual"] = current_scale
	return snapshot

func _capture_visual_snapshot() -> Dictionary:
	if screenshot_dir.strip_edges().is_empty():
		return {}

	var absolute_dir := ProjectSettings.globalize_path(screenshot_dir)
	var make_dir_error := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if make_dir_error != OK:
		return {
			"requested": true,
			"saved": false,
			"error": "make_dir_failed_%d" % make_dir_error,
			"path": ""
		}

	var viewport := get_viewport()
	if viewport == null:
		return {
			"requested": true,
			"saved": false,
			"error": "missing_viewport",
			"path": ""
		}

	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return {
			"requested": true,
			"saved": false,
			"error": "empty_image",
			"path": ""
		}

	var timestamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var glow_label := "glow_off" if disable_glow_enabled else "glow_on"
	var scale_value := float(_render_feature_snapshot().get("scaling_3d_scale_actual", 1.0))
	var scale_label := ("scale_%.2f" % scale_value).replace(".", "p")
	var path := absolute_dir.path_join("procedural_%s_%s_%s.png" % [timestamp, glow_label, scale_label])
	var save_error := image.save_png(path)
	return {
		"requested": true,
		"saved": save_error == OK,
		"error": "" if save_error == OK else "save_png_failed_%d" % save_error,
		"path": path,
		"width": image.get_width(),
		"height": image.get_height(),
		"disable_glow": disable_glow_enabled,
		"scaling_3d_scale_actual": scale_value
	}

func _shutdown_after_snapshot() -> void:
	if is_instance_valid(game_root):
		game_root.process_mode = Node.PROCESS_MODE_DISABLED
	_cleanup_managers_before_quit()
	await _wait_process_frames(8)
	if is_instance_valid(game_root):
		game_root.queue_free()
	call_deferred("_finalize_shutdown")

func _finalize_shutdown() -> void:
	await _wait_process_frames(12)
	get_tree().quit()

func _wait_process_frames(frame_count: int) -> void:
	for _i in range(frame_count):
		await get_tree().process_frame

func _cleanup_managers_before_quit() -> void:
	var terrain := _find_manager_node("terrain_manager", "TerrainManager")
	if terrain:
		_disable_node_for_shutdown(terrain)
		if terrain.has_method("clear_all_chunks"):
			terrain.clear_all_chunks()

	var building := _find_manager_node("building_manager", "BuildingManager")
	if building:
		_disable_node_for_shutdown(building)
		if building.has_method("clear_immediate_for_shutdown"):
			building.clear_immediate_for_shutdown()
		elif building.has_method("clear_for_shutdown"):
			building.clear_for_shutdown()

	var vegetation := _find_manager_node("vegetation_manager", "VegetationManager")
	if vegetation:
		_disable_node_for_shutdown(vegetation)
		if vegetation.has_method("clear_for_shutdown"):
			vegetation.clear_for_shutdown()
		elif vegetation.has_method("clear_all_data"):
			vegetation.clear_all_data(true)

	var entities := _find_manager_node("entity_manager", "EntityManager")
	if entities:
		_disable_node_for_shutdown(entities)
		if entities.has_method("clear_for_shutdown"):
			entities.clear_for_shutdown()
		elif entities.has_method("clear_all_entities"):
			entities.clear_all_entities()
		if entities.has_method("clear_spawned_chunks"):
			entities.clear_spawned_chunks()

	var vehicles := _find_manager_node("vehicle_manager", "VehicleManager")
	if vehicles:
		_disable_node_for_shutdown(vehicles)
		if vehicles.has_method("clear_immediate_for_shutdown"):
			vehicles.clear_immediate_for_shutdown()
		elif vehicles.has_method("clear_for_shutdown"):
			vehicles.clear_for_shutdown()
		elif vehicles.has_method("load_save_data"):
			vehicles.load_save_data({})

	var prefab_spawner := _find_manager_node("prefab_spawner", "PrefabSpawner")
	if prefab_spawner:
		_disable_node_for_shutdown(prefab_spawner)
		if prefab_spawner.has_method("clear_pending_spawn_jobs"):
			prefab_spawner.clear_pending_spawn_jobs()

	if ClassDB.class_exists("PrefabGeometry"):
		PrefabGeometry.clear_cache()

func _disable_node_for_shutdown(node: Node) -> void:
	if not is_instance_valid(node):
		return
	node.process_mode = Node.PROCESS_MODE_DISABLED
	node.set_process(false)
	node.set_physics_process(false)

func _find_manager_node(group_name: String, fallback_name: String) -> Node:
	var node := get_tree().get_first_node_in_group(group_name)
	if node:
		return node
	if is_instance_valid(game_root):
		node = game_root.find_child(fallback_name, true, false)
		if node:
			return node
	return get_tree().root.find_child(fallback_name, true, false)
