extends Node

const WorldMapGenScript := preload("res://world_editor/world_map_generator.gd")
const GameScene: PackedScene = preload("res://modules/world_module/world_test_world_player_v2.tscn")
const SAVE_BASE := "user://worlds/"
const TELEPORT_MIN_DISTANCE := 200.0
const TELEPORT_HEIGHT_OFFSET := 8.0
const HOLD_SECONDS := 40.0
const WORLD_READY_TIMEOUT_SECONDS := 300.0
const AUTO_FLY_TIMEOUT_SECONDS := 840.0
const AUTO_FLY_SPEED := 24.0
const AUTO_FLY_ASCEND_MARGIN := 40.0
const AUTO_FLY_ARRIVAL_RADIUS := 12.0

enum Phase {
	GENERATING,
	WAIT_WORLD_READY,
	TELEPORT,
	FLY_TO_TOWN,
	HOLD,
	DONE,
	FAILED
}

var phase: Phase = Phase.GENERATING
var phase_time: float = 0.0

var world_generator: WorldMapGenerator = null
var generation_thread: Thread = null
var generated_images: Dictionary = {}
var generated_towns: Array = []
var generated_world_path: String = ""
var generated_seed: int = 0
var selected_town: Dictionary = {}
var hold_started_logged: bool = false
var auto_teleport_enabled: bool = true
var fly_stage: int = 0
var fly_target: Vector3 = Vector3.ZERO
var fly_target_altitude: float = 0.0

var game_root: Node3D = null
var terrain_manager: Node = null
var chunk_manager: Node = null
var player: WorldPlayerV2 = null
var mode_manager: Node = null
var mode_editor: Node = null
var movement_component: Node = null
var loading_screen: Node = null

func _get_town_stall_seed() -> int:
	var seed_text := OS.get_environment("TOWN_STALL_SEED")
	if seed_text.is_valid_int():
		return int(seed_text)
	return 12345


func _emit_scope_state(scope: String, payload: Dictionary) -> void:
	if PerformanceMonitor and PerformanceMonitor.has_method("capture_scope_state"):
		PerformanceMonitor.capture_scope_state(scope, payload)


func _emit_scope_event(scope: String, event_name: String, payload: Dictionary) -> void:
	if PerformanceMonitor and PerformanceMonitor.has_method("capture_scope_event"):
		PerformanceMonitor.capture_scope_event(scope, event_name, payload)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	auto_teleport_enabled = OS.get_environment("TOWN_STALL_AUTO_TELEPORT") != "0"
	print("[TOWN_STALL_TEST] Harness starting")
	print("[TOWN_STALL_TEST] Auto teleport: %s" % ("ON" if auto_teleport_enabled else "OFF"))
	_emit_scope_state("town_stall_test", {
		"phase": "start",
		"auto_teleport": auto_teleport_enabled
	})
	_begin_generation()


func _process(delta: float) -> void:
	phase_time += delta

	match phase:
		Phase.WAIT_WORLD_READY:
			_poll_world_ready()
		Phase.TELEPORT:
			_teleport_into_town()
		Phase.FLY_TO_TOWN:
			_fly_to_town(delta)
		Phase.HOLD:
			_hold_in_town(delta)
		Phase.DONE, Phase.FAILED:
			pass
		_:
			pass


func _begin_generation() -> void:
	world_generator = WorldMapGenScript.new()
	generated_seed = _get_town_stall_seed()
	world_generator.world_seed = generated_seed
	world_generator.terrain_height = 10.0
	world_generator.water_level = 13.0
	world_generator.noise_freq = 0.1
	world_generator.road_spacing = 100.0
	world_generator.use_grid_roads = false
	world_generator.deep_lakes_enabled = true

	print("[TOWN_STALL_TEST] Generating world seed %d..." % generated_seed)
	_emit_scope_event("town_stall_test", "generation_start", {
		"seed": generated_seed
	})

	generation_thread = Thread.new()
	var err: int = generation_thread.start(Callable(self, "_threaded_generate_world"))
	if err != OK:
		_fail("Failed to start generation thread: %d" % err)


func _threaded_generate_world() -> void:
	var images: Dictionary = world_generator.generate_world()
	call_deferred("_on_world_generated", images)


func _on_world_generated(images: Dictionary) -> void:
	if generation_thread and generation_thread.is_alive():
		generation_thread.wait_to_finish()
	generation_thread = null

	generated_images = images
	var towns_value: Variant = images.get("towns", [])
	if towns_value is Array:
		generated_towns = towns_value
	else:
		generated_towns = []

	if generated_towns.is_empty():
		_fail("World generation completed without towns")
		return

	generated_world_path = SAVE_BASE + "town_stall_%d" % generated_seed
	if not world_generator.save_world(generated_world_path, generated_images):
		_fail("Failed to save generated world to %s" % generated_world_path)
		return

	selected_town = _select_town(generated_towns)
	if selected_town.is_empty():
		_fail("No suitable town found in generated world")
		return

	_emit_scope_event("town_stall_test", "generation_complete", {
		"world_path": generated_world_path,
		"town_count": generated_towns.size(),
		"selected_town_x": float(selected_town.get("x", 0.0)),
		"selected_town_z": float(selected_town.get("z", 0.0)),
		"selected_town_buildings": int(selected_town.get("building_count", 0))
	})

	print("[TOWN_STALL_TEST] World saved to %s" % generated_world_path)
	print("[TOWN_STALL_TEST] Selected town: x=%.1f z=%.1f buildings=%d radius=%.1f" % [
		float(selected_town.get("x", 0.0)),
		float(selected_town.get("z", 0.0)),
		int(selected_town.get("building_count", 0)),
		float(selected_town.get("radius", 0.0))
	])

	_start_game_scene()


func _start_game_scene() -> void:
	var packed_scene := GameScene
	var instanced := packed_scene.instantiate()
	game_root = instanced as Node3D
	if game_root == null:
		_fail("Failed to instance game scene")
		return

	# Strip out the old test-only helpers so the harness owns the flow.
	for node_name in ["DebugTeleporter", "MovementBot"]:
		var helper := game_root.find_child(node_name, true, false)
		if helper:
			helper.free()
			print("[TOWN_STALL_TEST] Removed helper node: %s" % node_name)

	var save_manager: Node = get_node_or_null("/root/SaveManager")
	if not save_manager or not ("pending_world_definition_path" in save_manager):
		_fail("SaveManager autoload missing pending_world_definition_path")
		return

	save_manager.pending_world_definition_path = generated_world_path
	add_child(game_root)
	phase = Phase.WAIT_WORLD_READY
	phase_time = 0.0

	_emit_scope_state("town_stall_test", {
		"phase": "game_loaded",
		"world_path": generated_world_path
	})
	print("[TOWN_STALL_TEST] Game scene loaded, waiting for world to finish initial load...")


func _poll_world_ready() -> void:
	if phase_time > WORLD_READY_TIMEOUT_SECONDS:
		_fail("Timed out waiting for world to become ready")
		return

	if not is_instance_valid(game_root):
		return

	if terrain_manager == null:
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if chunk_manager == null:
		chunk_manager = terrain_manager
	if player == null:
		player = get_tree().get_first_node_in_group("player") as WorldPlayerV2
	if loading_screen == null or not is_instance_valid(loading_screen):
		loading_screen = game_root.find_child("LoadingScreen", true, false)

	if terrain_manager == null or chunk_manager == null or player == null:
		return

	var terrain_ready := false
	if terrain_manager.has_method("is_initial_load_complete"):
		terrain_ready = terrain_manager.is_initial_load_complete()

	var loading_screen_done := true
	if loading_screen and ("is_loading" in loading_screen):
		loading_screen_done = not bool(loading_screen.get("is_loading"))

	if not terrain_ready or not loading_screen_done:
		return

	_emit_scope_event("town_stall_test", "world_ready", {
		"phase_time": phase_time,
		"world_path": generated_world_path
	})
	if auto_teleport_enabled:
		phase = Phase.TELEPORT
	else:
		_enter_fly_to_town()
	phase_time = 0.0


func _teleport_into_town() -> void:
	if not is_instance_valid(game_root) or not is_instance_valid(player) or not is_instance_valid(chunk_manager):
		_fail("Game scene references vanished before teleport")
		return

	var town_x: float = float(selected_town.get("x", 0.0))
	var town_z: float = float(selected_town.get("z", 0.0))
	var town_y: float = float(selected_town.get("terrain_y", 12.0))
	var teleport_pos := Vector3(town_x, town_y + TELEPORT_HEIGHT_OFFSET, town_z)

	player.global_position = teleport_pos
	player.velocity = Vector3.ZERO
	hold_started_logged = false

	if chunk_manager.has_method("request_spawn_zone"):
		chunk_manager.request_spawn_zone(teleport_pos, 2)

	_emit_scope_state("town_stall_test", {
		"phase": "town_teleported",
		"world_path": generated_world_path,
		"town_x": town_x,
		"town_z": town_z,
		"town_y": town_y,
		"building_count": int(selected_town.get("building_count", 0))
	})
	_emit_scope_event("town_stall_test", "teleport", {
		"town_x": town_x,
		"town_z": town_z,
		"town_y": town_y,
		"spawn_radius": 2
	})

	print("[TOWN_STALL_TEST] Teleported to town at (%.1f, %.1f, %.1f)" % [teleport_pos.x, teleport_pos.y, teleport_pos.z])
	print("[TOWN_STALL_TEST] Waiting %.1f seconds for the stall window..." % HOLD_SECONDS)

	phase = Phase.HOLD
	phase_time = 0.0


func _enter_fly_to_town() -> void:
	if not is_instance_valid(game_root) or not is_instance_valid(player):
		_fail("Game scene references vanished before fly-to-town setup")
		return

	mode_manager = player.get_node_or_null("Systems/ModeManager")
	mode_editor = player.get_node_or_null("Modes/ModeEditor")
	movement_component = player.get_node_or_null("Components/Movement")

	if mode_manager == null or mode_editor == null:
		_fail("Failed to locate editor mode components on player")
		return

	if movement_component and movement_component.has_method("set_physics_process"):
		movement_component.set_physics_process(false)
	if movement_component and movement_component.has_method("set_process"):
		movement_component.set_process(false)
	if mode_editor.has_method("set_physics_process"):
		mode_editor.set_physics_process(false)
	if mode_editor.has_method("set_process"):
		mode_editor.set_process(false)

	if mode_manager.has_method("is_editor_mode") and not bool(mode_manager.is_editor_mode()):
		mode_manager.toggle_editor_mode()
	if mode_manager.has_method("is_fly_active") and not bool(mode_manager.is_fly_active()):
		mode_manager.toggle_fly_mode()

	var town_x: float = float(selected_town.get("x", 0.0))
	var town_z: float = float(selected_town.get("z", 0.0))
	var town_y: float = float(selected_town.get("terrain_y", 12.0))
	fly_target = Vector3(town_x, town_y + TELEPORT_HEIGHT_OFFSET, town_z)
	fly_target_altitude = maxf(player.global_position.y + AUTO_FLY_ASCEND_MARGIN, fly_target.y + AUTO_FLY_ASCEND_MARGIN)
	fly_stage = 0

	print("[TOWN_STALL_TEST] Auto fly mode active - editor/fly enabled.")
	print("[TOWN_STALL_TEST] Flying to town center: (%.1f, %.1f, %.1f) buildings=%d radius=%.1f" % [
		town_x,
		town_y,
		town_z,
		int(selected_town.get("building_count", 0)),
		float(selected_town.get("radius", 0.0))
	])
	_emit_scope_state("town_stall_test", {
		"phase": "fly_to_town",
		"world_path": generated_world_path,
		"town_x": town_x,
		"town_z": town_z,
		"town_y": town_y,
		"building_count": int(selected_town.get("building_count", 0)),
		"auto_teleport": false,
		"auto_fly": true
	})
	phase = Phase.FLY_TO_TOWN
	phase_time = 0.0


func _fly_to_town(_delta: float) -> void:
	if phase_time >= AUTO_FLY_TIMEOUT_SECONDS:
		_emit_scope_event("town_stall_test", "fly_timeout", {
			"timeout_seconds": AUTO_FLY_TIMEOUT_SECONDS
		})
		_fail("Timed out flying to town center")
		return

	if not is_instance_valid(player) or not is_instance_valid(mode_manager):
		_fail("Player or mode manager vanished during fly-to-town")
		return

	var current_pos: Vector3 = player.global_position
	if fly_stage == 0:
		var vertical_delta := fly_target_altitude - current_pos.y
		if absf(vertical_delta) <= 1.5:
			player.velocity = Vector3.ZERO
			fly_stage = 1
			return

		player.velocity = Vector3(0.0, signf(vertical_delta) * AUTO_FLY_SPEED, 0.0)
		player.move_and_slide()
		return

	if fly_stage == 1:
		var horizontal_target := Vector3(fly_target.x, current_pos.y, fly_target.z)
		var to_target := horizontal_target - current_pos
		to_target.y = 0.0
		if to_target.length() <= AUTO_FLY_ARRIVAL_RADIUS:
			fly_stage = 2
			return

		player.velocity = to_target.normalized() * AUTO_FLY_SPEED
		player.velocity.y = 0.0
		player.move_and_slide()
		return

	var descent_delta := fly_target.y - current_pos.y
	if absf(descent_delta) <= 1.5:
		player.velocity = Vector3.ZERO
		print("[TOWN_STALL_TEST] Auto fly reached town center, starting hold")
		phase = Phase.HOLD
		phase_time = 0.0
		hold_started_logged = false
		return

	player.velocity = Vector3(0.0, signf(descent_delta) * AUTO_FLY_SPEED, 0.0)
	player.move_and_slide()


func _hold_in_town(_delta: float) -> void:
	if not hold_started_logged:
		print("[TOWN_STALL_TEST] Hold started")
		hold_started_logged = true

	if phase_time >= HOLD_SECONDS:
		_emit_scope_event("town_stall_test", "hold_complete", {
			"hold_seconds": HOLD_SECONDS
		})
		print("[TOWN_STALL_TEST] Hold complete, quitting")
		phase = Phase.DONE
		get_tree().quit(0)


func _select_town(towns: Array) -> Dictionary:
	var best_town: Dictionary = {}
	var best_building_count: int = -1
	var best_dist: float = INF
	var fallback_town: Dictionary = {}
	var fallback_building_count: int = -1
	var fallback_dist: float = -1.0

	for town_variant in towns:
		if not town_variant is Dictionary:
			continue

		var town: Dictionary = town_variant
		var town_x: float = float(town.get("x", 0.0))
		var town_z: float = float(town.get("z", 0.0))
		var dist: float = Vector2(town_x, town_z).length()
		var building_count: int = int(town.get("building_count", 0))

		if building_count > fallback_building_count or (building_count == fallback_building_count and dist > fallback_dist):
			fallback_town = town
			fallback_building_count = building_count
			fallback_dist = dist

		if dist < TELEPORT_MIN_DISTANCE:
			continue

		if building_count > best_building_count or (building_count == best_building_count and dist < best_dist):
			best_town = town
			best_building_count = building_count
			best_dist = dist

	if not best_town.is_empty():
		return best_town
	return fallback_town


func _fail(message: String) -> void:
	if phase == Phase.FAILED or phase == Phase.DONE:
		return

	phase = Phase.FAILED
	print("[TOWN_STALL_TEST] ERROR: %s" % message)
	_emit_scope_event("town_stall_test", "failed", {
		"message": message
	})
	get_tree().quit(1)
