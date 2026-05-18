extends Node

const GAME_SCENE_PATH := "res://modules/world_module/world_test_world_player_v2.tscn"
const SNAPSHOT_DIR := "user://debug/performance/"

var warmup_timeout_s: float = 45.0
var move_seconds: float = 16.0
var hold_seconds: float = 8.0
var sample_interval_s: float = 1.0
var snapshot_dir: String = SNAPSHOT_DIR

var game_root: Node = null
var terrain_manager: Node = null
var player: Node3D = null
var phase: String = "load"
var phase_time: float = 0.0
var elapsed_time: float = 0.0
var next_sample_time: float = 0.0
var samples: Array[Dictionary] = []
var active_action: String = ""
var snapshot_path: String = ""

func _ready() -> void:
	warmup_timeout_s = _env_float("PROCEDURAL_POWER_WARMUP_TIMEOUT_S", warmup_timeout_s)
	move_seconds = _env_float("PROCEDURAL_POWER_MOVE_SECONDS", move_seconds)
	hold_seconds = _env_float("PROCEDURAL_POWER_HOLD_SECONDS", hold_seconds)
	sample_interval_s = _env_float("PROCEDURAL_POWER_SAMPLE_INTERVAL_S", sample_interval_s)
	snapshot_dir = _env_string("PROCEDURAL_POWER_SNAPSHOT_DIR", snapshot_dir)
	print("[PROCEDURAL_POWER] Loading procedural scene: %s" % GAME_SCENE_PATH)
	var packed := load(GAME_SCENE_PATH)
	if packed == null:
		_fail("failed_to_load_game_scene")
		return
	game_root = packed.instantiate()
	add_child(game_root)

func _process(delta: float) -> void:
	elapsed_time += delta
	phase_time += delta
	_refresh_nodes()
	if elapsed_time >= next_sample_time:
		_capture_sample()
		next_sample_time = elapsed_time + sample_interval_s

	match phase:
		"load":
			if _is_world_ready():
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

func _change_phase(next_phase: String) -> void:
	print("[PROCEDURAL_POWER] Phase: %s -> %s at %.2fs" % [phase, next_phase, elapsed_time])
	phase = next_phase
	phase_time = 0.0

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
	var sample := {
		"elapsed_time": elapsed_time,
		"phase": phase,
		"phase_time": phase_time,
		"fps": Engine.get_frames_per_second(),
		"engine_max_fps": Engine.max_fps,
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"render_objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
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
	_release_active_action()
	phase = "done"
	_capture_sample()
	if not _ensure_snapshot_dir():
		_fail("failed_to_create_snapshot_dir")
		return
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	snapshot_path = snapshot_dir.path_join("procedural_power_snapshot_%s.json" % stamp)
	var payload := {
		"benchmark": "procedural_power",
		"completed": true,
		"elapsed_time": elapsed_time,
		"move_seconds": move_seconds,
		"hold_seconds": hold_seconds,
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
	get_tree().quit()

func _fail(reason: String) -> void:
	_release_active_action()
	print("[PROCEDURAL_POWER] ERROR: %s" % reason)
	get_tree().quit(1)
