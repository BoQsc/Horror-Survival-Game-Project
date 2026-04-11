extends Node

const WorldMapGenScript := preload("res://world_editor/world_map_generator.gd")
const GameScene: PackedScene = preload("res://modules/world_module/world_test_world_player_v2.tscn")
const SAVE_BASE := "user://worlds/"
const TELEPORT_MIN_DISTANCE := 200.0
const TELEPORT_HEIGHT_OFFSET := 8.0
const HOLD_SECONDS := 40.0
const REPEAT_ENTRY_FIRST_HOLD_SECONDS := 20.0
const REPEAT_ENTRY_RETURN_HOLD_SECONDS := 5.0
const REPEAT_ENTRY_SECOND_HOLD_SECONDS := 20.0
const WORLD_READY_TIMEOUT_SECONDS := 300.0
const AUTO_FLY_TIMEOUT_SECONDS := 840.0
const AUTO_FLY_SPEED := 24.0
const AUTO_FLY_ASCEND_MARGIN := 40.0
const AUTO_FLY_ARRIVAL_RADIUS := 12.0
const AUTO_FLY_ENTRY_CAPTURE_BUFFER := 64.0

enum Phase {
	GENERATING,
	WAIT_WORLD_READY,
	TELEPORT,
	FLY_TO_TOWN,
	HOLD_FIRST,
	FLY_BACK_TO_ORIGIN,
	HOLD_RETURN,
	FLY_TO_TOWN_SECOND,
	HOLD_SECOND,
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
var town_entry_capture_started: bool = false
var auto_teleport_enabled: bool = true
var disable_buildings_enabled: bool = false
var disable_building_objects_enabled: bool = false
var disable_building_blocks_enabled: bool = false
var disable_building_chunk_mesh_render_enabled: bool = false
var disable_building_visual_batches_enabled: bool = false
var disable_building_carve_enabled: bool = false
var disable_building_object_collisions_enabled: bool = false
var disable_building_chunk_flush_enabled: bool = false
var disable_building_chunk_collisions_enabled: bool = false
var disable_terrain_chunk_updates_enabled: bool = false
var transvoxel_preview_enabled: bool = false
var transvoxel_preview_applied: bool = false
var transvoxel_preview_collision_expected: bool = false
var transvoxel_preview_collision_verified: bool = false
var transvoxel_preview_collision_wait_seconds: float = 0.0
var hold_seconds_override: float = -1.0
var repeat_entry_enabled: bool = false
var fly_stage: int = 0
var fly_target: Vector3 = Vector3.ZERO
var fly_target_altitude: float = 0.0
var return_origin: Vector3 = Vector3.ZERO
var current_hold_seconds: float = HOLD_SECONDS

var game_root: Node3D = null
var terrain_manager: Node = null
var chunk_manager: Node = null
var player: WorldPlayerV2 = null
var mode_manager: Node = null
var mode_editor: Node = null
var movement_component: Node = null
var loading_screen: Node = null
var pending_quit: bool = false

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


func _reset_town_measurement_window(reason: String) -> void:
	if PerformanceMonitor and PerformanceMonitor.has_method("reset_measurement_window"):
		PerformanceMonitor.reset_measurement_window(reason)
	_emit_scope_state("town_stall_test", {
		"phase": "measurement_reset",
		"reason": reason,
		"world_path": generated_world_path
	})
	_emit_scope_event("town_stall_test", "measurement_reset", {
		"reason": reason,
		"world_path": generated_world_path
	})


func _resolve_hold_seconds(base_seconds: float) -> float:
	if hold_seconds_override > 0.0:
		return hold_seconds_override
	return base_seconds

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	auto_teleport_enabled = OS.get_environment("TOWN_STALL_AUTO_TELEPORT") != "0"
	disable_buildings_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDINGS") == "1"
	disable_building_objects_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_OBJECTS") == "1"
	disable_building_blocks_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_BLOCKS") == "1"
	disable_building_chunk_mesh_render_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_CHUNK_MESH_RENDER") == "1"
	disable_building_visual_batches_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_VISUAL_BATCHES") == "1"
	disable_building_carve_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_CARVE") == "1"
	disable_building_object_collisions_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_OBJECT_COLLISIONS") == "1"
	disable_building_chunk_flush_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_CHUNK_FLUSH") == "1"
	disable_building_chunk_collisions_enabled = OS.get_environment("TOWN_STALL_DISABLE_BUILDING_CHUNK_COLLISIONS") == "1"
	disable_terrain_chunk_updates_enabled = OS.get_environment("TOWN_STALL_DISABLE_TERRAIN_CHUNK_UPDATES") == "1"
	transvoxel_preview_enabled = OS.get_environment("TOWN_STALL_ENABLE_TRANSVOXEL_PREVIEW") == "1"
	repeat_entry_enabled = OS.get_environment("TOWN_STALL_REPEAT_ENTRY") == "1"
	var hold_seconds_text := OS.get_environment("TOWN_STALL_HOLD_SECONDS")
	if hold_seconds_text.is_valid_float():
		hold_seconds_override = max(0.0, float(hold_seconds_text))
	print("[TOWN_STALL_TEST] Harness starting")
	print("[TOWN_STALL_TEST] Auto teleport: %s" % ("ON" if auto_teleport_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable buildings: %s" % ("ON" if disable_buildings_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building objects: %s" % ("ON" if disable_building_objects_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building blocks: %s" % ("ON" if disable_building_blocks_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building chunk mesh render: %s" % ("ON" if disable_building_chunk_mesh_render_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building visual batches: %s" % ("ON" if disable_building_visual_batches_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building carve: %s" % ("ON" if disable_building_carve_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building object collisions: %s" % ("ON" if disable_building_object_collisions_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building chunk flush: %s" % ("ON" if disable_building_chunk_flush_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable building chunk collisions: %s" % ("ON" if disable_building_chunk_collisions_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Disable terrain chunk updates: %s" % ("ON" if disable_terrain_chunk_updates_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Transvoxel preview: %s" % ("ON" if transvoxel_preview_enabled else "OFF"))
	print("[TOWN_STALL_TEST] Hold seconds override: %s" % (("%.1f" % hold_seconds_override) if hold_seconds_override > 0.0 else "OFF"))
	print("[TOWN_STALL_TEST] Repeat entry: %s" % ("ON" if repeat_entry_enabled else "OFF"))
	_emit_scope_state("town_stall_test", {
		"phase": "start",
		"auto_teleport": auto_teleport_enabled,
		"disable_buildings": disable_buildings_enabled,
		"disable_building_objects": disable_building_objects_enabled,
		"disable_building_blocks": disable_building_blocks_enabled,
		"disable_building_chunk_mesh_render": disable_building_chunk_mesh_render_enabled,
		"disable_building_visual_batches": disable_building_visual_batches_enabled,
		"disable_building_carve": disable_building_carve_enabled,
		"disable_building_object_collisions": disable_building_object_collisions_enabled,
		"disable_building_chunk_flush": disable_building_chunk_flush_enabled,
		"disable_building_chunk_collisions": disable_building_chunk_collisions_enabled,
		"disable_terrain_chunk_updates": disable_terrain_chunk_updates_enabled,
		"transvoxel_preview": transvoxel_preview_enabled,
		"hold_seconds_override": hold_seconds_override,
		"repeat_entry": repeat_entry_enabled
	})
	_begin_generation()


func _process(delta: float) -> void:
	phase_time += delta
	_verify_transvoxel_preview_collision(delta)

	match phase:
		Phase.WAIT_WORLD_READY:
			_poll_world_ready()
		Phase.TELEPORT:
			_teleport_into_town()
		Phase.FLY_TO_TOWN, Phase.FLY_BACK_TO_ORIGIN, Phase.FLY_TO_TOWN_SECOND:
			_fly_to_town(delta)
		Phase.HOLD_FIRST, Phase.HOLD_RETURN, Phase.HOLD_SECOND:
			_hold_in_town(delta)
		Phase.DONE, Phase.FAILED:
			pass
		_:
			pass


func _verify_transvoxel_preview_collision(delta: float) -> void:
	if not transvoxel_preview_collision_expected or transvoxel_preview_collision_verified:
		return
	if not is_instance_valid(chunk_manager):
		return
	var preview_root := chunk_manager.get_node_or_null("WorldMapTransvoxelLOD")
	if preview_root == null:
		transvoxel_preview_collision_wait_seconds += delta
		if transvoxel_preview_collision_wait_seconds > 15.0:
			_fail("Timed out waiting for the Transvoxel preview root")
		return
	var collision_shapes := preview_root.find_children("", "CollisionShape3D", true, false)
	var static_bodies := preview_root.find_children("", "StaticBody3D", true, false)
	if collision_shapes.is_empty() or static_bodies.is_empty():
		transvoxel_preview_collision_wait_seconds += delta
		if transvoxel_preview_collision_wait_seconds > 15.0:
			_fail("Transvoxel preview collision shapes were not built")
		return

	transvoxel_preview_collision_verified = true
	print("[TOWN_STALL_TEST] Transvoxel preview collision verified: bodies=%d shapes=%d" % [static_bodies.size(), collision_shapes.size()])


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
	if generation_thread:
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

	generated_world_path = SAVE_BASE + "town_stall_%d_%d" % [generated_seed, Time.get_ticks_msec()]
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
	if disable_buildings_enabled and ("disable_buildings_for_test" in save_manager):
		save_manager.disable_buildings_for_test = true
		_apply_buildings_toggle()
	elif disable_building_objects_enabled:
		_apply_building_objects_toggle()
	elif disable_building_blocks_enabled:
		_apply_building_blocks_toggle()
	elif disable_building_chunk_mesh_render_enabled:
		_apply_building_chunk_mesh_render_toggle()
	elif disable_building_visual_batches_enabled:
		_apply_building_visual_batches_toggle()
	elif disable_building_carve_enabled:
		_apply_building_carve_toggle()
	elif disable_building_object_collisions_enabled:
		_apply_building_object_collisions_toggle()
	elif disable_building_chunk_flush_enabled:
		_apply_building_chunk_flush_toggle()
	elif disable_building_chunk_collisions_enabled:
		_apply_building_chunk_collisions_toggle()
	add_child(game_root)
	phase = Phase.WAIT_WORLD_READY
	phase_time = 0.0

	_emit_scope_state("town_stall_test", {
		"phase": "game_loaded",
		"world_path": generated_world_path
	})
	print("[TOWN_STALL_TEST] Game scene loaded, waiting for world to finish initial load...")


func _apply_buildings_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var building_manager := game_root.find_child("BuildingManager", true, false)
	if building_manager:
		building_manager.process_mode = Node.PROCESS_MODE_DISABLED
		if building_manager.has_method("set_process"):
			building_manager.set_process(false)
		if building_manager.has_method("set_physics_process"):
			building_manager.set_physics_process(false)

	var prefab_spawner := game_root.find_child("PrefabSpawner", true, false)
	if prefab_spawner:
		if "enabled" in prefab_spawner:
			prefab_spawner.enabled = false
		prefab_spawner.process_mode = Node.PROCESS_MODE_DISABLED
		if prefab_spawner.has_method("set_process"):
			prefab_spawner.set_process(false)
		if prefab_spawner.has_method("set_physics_process"):
			prefab_spawner.set_physics_process(false)

	var building_generator := game_root.find_child("BuildingGenerator", true, false)
	if building_generator:
		if "enabled" in building_generator:
			building_generator.enabled = false
		building_generator.process_mode = Node.PROCESS_MODE_DISABLED
		if building_generator.has_method("set_process"):
			building_generator.set_process(false)
		if building_generator.has_method("set_physics_process"):
			building_generator.set_physics_process(false)

	_emit_scope_state("town_stall_test", {
		"phase": "buildings_disabled",
		"disable_buildings": true
	})
	print("[TOWN_STALL_TEST] Buildings subsystem disabled for test isolation.")


func _apply_building_objects_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var prefab_spawner := game_root.find_child("PrefabSpawner", true, false)
	if prefab_spawner and "skip_object_spawns_for_test" in prefab_spawner:
		prefab_spawner.skip_object_spawns_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_objects_disabled",
		"disable_building_objects": true
	})
	print("[TOWN_STALL_TEST] Building objects disabled for test isolation.")


func _apply_building_blocks_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var prefab_spawner := game_root.find_child("PrefabSpawner", true, false)
	if prefab_spawner and "skip_block_placement_for_test" in prefab_spawner:
		prefab_spawner.skip_block_placement_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_blocks_disabled",
		"disable_building_blocks": true
	})
	print("[TOWN_STALL_TEST] Building blocks disabled for test isolation.")


func _apply_building_chunk_mesh_render_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var building_manager := game_root.find_child("BuildingManager", true, false)
	if building_manager and "skip_building_chunk_mesh_render_for_test" in building_manager:
		building_manager.skip_building_chunk_mesh_render_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_chunk_mesh_render_disabled",
		"disable_building_chunk_mesh_render": true
	})
	print("[TOWN_STALL_TEST] Building chunk mesh render disabled for test isolation.")


func _apply_building_visual_batches_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var building_manager := game_root.find_child("BuildingManager", true, false)
	if building_manager and "skip_building_visual_batches_for_test" in building_manager:
		building_manager.skip_building_visual_batches_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_visual_batches_disabled",
		"disable_building_visual_batches": true
	})
	print("[TOWN_STALL_TEST] Building visual batches disabled for test isolation.")


func _apply_building_carve_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var prefab_spawner := game_root.find_child("PrefabSpawner", true, false)
	if prefab_spawner and "skip_carving_for_test" in prefab_spawner:
		prefab_spawner.skip_carving_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_carve_disabled",
		"disable_building_carve": true
	})
	print("[TOWN_STALL_TEST] Building carve disabled for test isolation.")


func _apply_building_object_collisions_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var building_manager := game_root.find_child("BuildingManager", true, false)
	if building_manager and "skip_object_collisions_for_test" in building_manager:
		building_manager.skip_object_collisions_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_object_collisions_disabled",
		"disable_building_object_collisions": true
	})
	print("[TOWN_STALL_TEST] Building object collisions disabled for test isolation.")


func _apply_building_chunk_flush_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var prefab_spawner := game_root.find_child("PrefabSpawner", true, false)
	if prefab_spawner and "skip_chunk_flush_for_test" in prefab_spawner:
		prefab_spawner.skip_chunk_flush_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_chunk_flush_disabled",
		"disable_building_chunk_flush": true
	})
	print("[TOWN_STALL_TEST] Building chunk flush disabled for test isolation.")


func _apply_building_chunk_collisions_toggle() -> void:
	if not is_instance_valid(game_root):
		return

	var building_manager := game_root.find_child("BuildingManager", true, false)
	if building_manager and "skip_building_chunk_collisions_for_test" in building_manager:
		building_manager.skip_building_chunk_collisions_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "building_chunk_collisions_disabled",
		"disable_building_chunk_collisions": true
	})
	print("[TOWN_STALL_TEST] Building chunk collisions disabled for test isolation.")


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

	if transvoxel_preview_enabled and not transvoxel_preview_applied and terrain_manager.has_method("set_transvoxel_preview_enabled"):
		terrain_manager.set_transvoxel_preview_enabled(true)
		transvoxel_preview_applied = true
		transvoxel_preview_collision_expected = true
		print("[TOWN_STALL_TEST] Transvoxel preview enabled on terrain manager")

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

	_reset_town_measurement_window("auto_teleport_entry")
	_apply_terrain_chunk_updates_toggle()

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
	var hold_target_seconds := _resolve_hold_seconds(HOLD_SECONDS)
	print("[TOWN_STALL_TEST] Waiting %.1f seconds for the stall window..." % hold_target_seconds)

	current_hold_seconds = hold_target_seconds
	phase = Phase.HOLD_FIRST
	phase_time = 0.0
	hold_started_logged = false


func _enter_fly_to_town() -> void:
	if not is_instance_valid(game_root) or not is_instance_valid(player):
		_fail("Game scene references vanished before fly-to-town setup")
		return

	_apply_terrain_chunk_updates_toggle()

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

	return_origin = player.global_position
	var town_x: float = float(selected_town.get("x", 0.0))
	var town_z: float = float(selected_town.get("z", 0.0))
	var town_y: float = float(selected_town.get("terrain_y", 12.0))
	_begin_flight_to_target(
		Vector3(town_x, town_y + TELEPORT_HEIGHT_OFFSET, town_z),
		Phase.FLY_TO_TOWN,
		"town center",
		"fly_to_town",
		{
			"building_count": int(selected_town.get("building_count", 0)),
			"town_radius": float(selected_town.get("radius", 0.0)),
			"auto_teleport": false,
			"auto_fly": true
		}
	)
	town_entry_capture_started = false
	print("[TOWN_STALL_TEST] Auto fly mode active - editor/fly enabled.")
	print("[TOWN_STALL_TEST] Flying to town center: (%.1f, %.1f, %.1f) buildings=%d radius=%.1f" % [
		town_x,
		town_y,
		town_z,
		int(selected_town.get("building_count", 0)),
		float(selected_town.get("radius", 0.0))
	])


func _apply_terrain_chunk_updates_toggle() -> void:
	if not disable_terrain_chunk_updates_enabled:
		return

	if not is_instance_valid(chunk_manager):
		chunk_manager = get_tree().get_first_node_in_group("terrain_manager")
	if chunk_manager and "skip_terrain_chunk_updates_for_test" in chunk_manager:
		chunk_manager.skip_terrain_chunk_updates_for_test = true

	_emit_scope_state("town_stall_test", {
		"phase": "terrain_chunk_updates_disabled",
		"disable_terrain_chunk_updates": true
	})
	print("[TOWN_STALL_TEST] Terrain chunk updates disabled for test isolation.")


func _begin_flight_to_target(target: Vector3, next_phase: Phase, target_label: String, scope_phase: String, extra_state: Dictionary = {}) -> void:
	fly_target = target
	fly_target_altitude = maxf(player.global_position.y + AUTO_FLY_ASCEND_MARGIN, fly_target.y + AUTO_FLY_ASCEND_MARGIN)
	fly_stage = 0

	var state: Dictionary = {
		"phase": scope_phase,
		"world_path": generated_world_path,
		"target_x": target.x,
		"target_y": target.y,
		"target_z": target.z,
	}
	for key in extra_state.keys():
		state[key] = extra_state[key]
	_emit_scope_state("town_stall_test", state)

	if next_phase == Phase.FLY_TO_TOWN:
		phase = Phase.FLY_TO_TOWN
	elif next_phase == Phase.FLY_BACK_TO_ORIGIN:
		phase = Phase.FLY_BACK_TO_ORIGIN
	elif next_phase == Phase.FLY_TO_TOWN_SECOND:
		phase = Phase.FLY_TO_TOWN_SECOND
	else:
		phase = next_phase
	phase_time = 0.0

	print("[TOWN_STALL_TEST] Flying to %s: (%.1f, %.1f, %.1f)" % [target_label, target.x, target.y, target.z])


func _restore_player_control() -> void:
	if is_instance_valid(player):
		player.velocity = Vector3.ZERO

	if is_instance_valid(mode_manager) and mode_manager.has_method("is_editor_mode") and bool(mode_manager.is_editor_mode()):
		if mode_manager.has_method("toggle_editor_mode"):
			mode_manager.toggle_editor_mode()

	if movement_component:
		if movement_component.has_method("set_physics_process"):
			movement_component.set_physics_process(true)
		if movement_component.has_method("set_process"):
			movement_component.set_process(true)

	if mode_editor:
		if mode_editor.has_method("set_physics_process"):
			mode_editor.set_physics_process(true)
		if mode_editor.has_method("set_process"):
			mode_editor.set_process(true)

	_emit_scope_event("town_stall_test", "manual_control_restored", {
		"world_path": generated_world_path,
		"phase": str(phase)
	})


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
		if not town_entry_capture_started:
			var capture_radius := float(selected_town.get("radius", 0.0)) + AUTO_FLY_ENTRY_CAPTURE_BUFFER
			if capture_radius > 0.0 and to_target.length() <= capture_radius:
				town_entry_capture_started = true
				_reset_town_measurement_window("auto_fly_entry")
				_emit_scope_event("town_stall_test", "town_entry_capture_started", {
					"phase": str(phase),
					"capture_radius": capture_radius,
					"target_x": fly_target.x,
					"target_y": fly_target.y,
					"target_z": fly_target.z
				})
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
		print("[TOWN_STALL_TEST] Auto fly reached target, starting hold")
		_restore_player_control()
		match phase:
			Phase.FLY_TO_TOWN:
				current_hold_seconds = _resolve_hold_seconds(REPEAT_ENTRY_FIRST_HOLD_SECONDS if repeat_entry_enabled else HOLD_SECONDS)
				phase = Phase.HOLD_FIRST
			Phase.FLY_BACK_TO_ORIGIN:
				current_hold_seconds = _resolve_hold_seconds(REPEAT_ENTRY_RETURN_HOLD_SECONDS)
				phase = Phase.HOLD_RETURN
			Phase.FLY_TO_TOWN_SECOND:
				current_hold_seconds = _resolve_hold_seconds(REPEAT_ENTRY_SECOND_HOLD_SECONDS)
				phase = Phase.HOLD_SECOND
			_:
				current_hold_seconds = _resolve_hold_seconds(HOLD_SECONDS)
				phase = Phase.HOLD_FIRST
		phase_time = 0.0
		hold_started_logged = false
		return

	player.velocity = Vector3(0.0, signf(descent_delta) * AUTO_FLY_SPEED, 0.0)
	player.move_and_slide()


func _hold_in_town(_delta: float) -> void:
	if not hold_started_logged:
		print("[TOWN_STALL_TEST] Hold started")
		if PerformanceMonitor and PerformanceMonitor.has_method("end_town_entry_capture"):
			PerformanceMonitor.end_town_entry_capture("hold_started")
		_emit_scope_event("town_stall_test", "hold_started", {
			"phase": str(phase),
			"hold_seconds": current_hold_seconds
		})
		hold_started_logged = true

	if phase_time >= current_hold_seconds:
		_emit_scope_event("town_stall_test", "hold_complete", {
			"hold_seconds": current_hold_seconds,
			"phase": str(phase)
		})

		if phase == Phase.HOLD_FIRST and repeat_entry_enabled:
			print("[TOWN_STALL_TEST] First hold complete, flying back out before re-entering town")
			_begin_flight_to_target(
				return_origin,
				Phase.FLY_BACK_TO_ORIGIN,
				"fly_back_to_origin",
				"return origin",
				{}
			)
			return

		if phase == Phase.HOLD_RETURN and repeat_entry_enabled:
			var town_x: float = float(selected_town.get("x", 0.0))
			var town_z: float = float(selected_town.get("z", 0.0))
			var town_y: float = float(selected_town.get("terrain_y", 12.0))
			print("[TOWN_STALL_TEST] Return hold complete, flying back into town")
			_reset_town_measurement_window("repeat_entry_second")
			_begin_flight_to_target(
				Vector3(town_x, town_y + TELEPORT_HEIGHT_OFFSET, town_z),
				Phase.FLY_TO_TOWN_SECOND,
				"fly_to_town_second",
				"town center",
				{
					"building_count": int(selected_town.get("building_count", 0)),
					"town_radius": float(selected_town.get("radius", 0.0))
				}
			)
			return

		print("[TOWN_STALL_TEST] Hold complete, quitting")
		_begin_shutdown()


func _begin_shutdown() -> void:
	if pending_quit:
		return
	pending_quit = true
	phase = Phase.DONE
	_emit_scope_event("town_stall_test", "shutdown_requested", {
		"world_path": generated_world_path,
		"phase": str(phase)
	})
	if is_instance_valid(game_root):
		game_root.queue_free()
	call_deferred("_finalize_shutdown")


func _finalize_shutdown() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
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
