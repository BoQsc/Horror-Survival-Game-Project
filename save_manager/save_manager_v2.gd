extends Node
## SaveManager - Handles saving and loading game state
## Autoload singleton for centralized save/load operations

signal save_completed(success: bool, path: String)
signal load_completed(success: bool, path: String)
signal load_step(step_name: String, step_index: int, total_steps: int)

# V2: Added inventory, hotbar, stats, containers, player state
const SAVE_VERSION = 2
const SAVE_DIR = "user://saves/"
const QUICKSAVE_FILE = "quicksave.json"

# References to game managers (set in _ready or via exports)
var chunk_manager: Node = null
var building_manager: Node = null
var vegetation_manager: Node = null
var road_manager: Node = null
var prefab_spawner: Node = null
var entity_manager: Node = null
var vehicle_manager: Node = null
var building_generator: Node = null
var player: Node = null

# World Editor integration: set before scene change, consumed by chunk_manager on _ready
var pending_world_definition_path: String = ""

# V2: New player system references
var player_inventory: Node = null
var player_hotbar: Node = null
var player_stats: Node = null
var mode_manager: Node = null
var crouch_component: Node = null
var player_movement: Node = null
var player_camera: Node = null
var player_combat: Node = null
var player_terrain: Node = null
var container_registry: Node = null

# Deferred spawn data - waiting for terrain to load
var pending_player_data: Dictionary = {}
var pending_entity_data: Dictionary = {}
var pending_vehicle_data: Dictionary = {}
var pending_door_data: Dictionary = {} # Deferred until world ready
var pending_container_data: Dictionary = {} # Deferred until world ready
var pending_player_position_restore: bool = false  # Fix: defer position until terrain collision ready
var is_loading_game: bool = false
var current_save_path: String = "" # Tracks current active save path

# CRITICAL: Static flag that persists through scene reload
# EntityManager checks this in _ready() to skip procedural spawning during QuickLoad
static var is_quickloading: bool = false

var awaiting_terrain_ready: bool = false
var awaiting_vegetation_ready: bool = false
var load_safety_timer: SceneTreeTimer = null # Safety timeout to prevent infinite hang

# Autosave settings
var autosave_enabled: bool = true
var autosave_interval_seconds: float = 300.0 # 5 minutes
var _autosave_timer: Timer = null

# Thread Management
var _save_threads: Array[Thread] = []
var _is_saving: bool = false # Prevent concurrent saves to avoid file corruption

func _ready():
	# Add to group for dynamic lookup by HUD
	add_to_group("save_manager")
	
	# Create saves directory if it doesn't exist
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	
	# Setup Autosave
	_setup_autosave()
	
	# Find managers (deferred to ensure scene is ready)
	call_deferred("_find_managers")

func _setup_autosave():
	if _autosave_timer:
		_autosave_timer.queue_free()
	
	_autosave_timer = Timer.new()
	_autosave_timer.name = "AutosaveTimer"
	_autosave_timer.one_shot = false
	_autosave_timer.wait_time = autosave_interval_seconds
	_autosave_timer.autostart = autosave_enabled
	_autosave_timer.timeout.connect(_on_autosave_timeout)
	add_child(_autosave_timer)
	
	if autosave_enabled:
		_autosave_timer.start()
		DebugManager.log_save("Autosave enabled: %d seconds" % autosave_interval_seconds)

func _on_autosave_timeout():
	if is_loading_game or _is_saving:
		DebugManager.log_save("Autosave skipped (loading=%s, saving=%s)" % [is_loading_game, _is_saving])
		return
	DebugManager.log_save("Autosave triggered...")
	save_game(SAVE_DIR + "autosave.json")

func _find_managers():
	# Terrain
	chunk_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	# Building
	building_manager = get_tree().get_first_node_in_group("building_manager")
	if not building_manager:
		building_manager = get_node_or_null("/root/MainGame/BuildingManager")
	
	# Vegetation
	vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	if not vegetation_manager:
		vegetation_manager = get_node_or_null("/root/MainGame/VegetationManager")
	
	# Roads
	road_manager = get_tree().get_first_node_in_group("road_manager")
	if not road_manager:
		road_manager = get_node_or_null("/root/MainGame/RoadManager")
	
	# Prefabs
	prefab_spawner = get_tree().get_first_node_in_group("prefab_spawner")
	if not prefab_spawner:
		prefab_spawner = get_node_or_null("/root/MainGame/PrefabSpawner")
	
	# Entities
	entity_manager = get_tree().get_first_node_in_group("entity_manager")
	if not entity_manager:
		entity_manager = get_node_or_null("/root/MainGame/EntityManager")
	
	# Vehicles
	vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	
	# Building Generator
	building_generator = get_tree().get_first_node_in_group("building_generator")
	if not building_generator:
		building_generator = get_node_or_null("/root/MainGame/BuildingGenerator")
	
	# Player
	player = get_tree().get_first_node_in_group("player")
	
	DebugManager.log_save("Managers: CM=%s BM=%s VM=%s RM=%s PF=%s EM=%s VEH=%s P=%s" % [
		chunk_manager != null, building_manager != null, vegetation_manager != null,
		road_manager != null, prefab_spawner != null, entity_manager != null,
		vehicle_manager != null, player != null
	])
	
	# Connect to chunk_manager's spawn_zones_ready signal
	if chunk_manager and chunk_manager.has_signal("spawn_zones_ready"):
		if not chunk_manager.is_connected("spawn_zones_ready", _on_spawn_zones_ready):
			chunk_manager.connect("spawn_zones_ready", _on_spawn_zones_ready)
	
	# Connect to vegetation_manager's all_vegetation_ready signal
	if vegetation_manager and vegetation_manager.has_signal("all_vegetation_ready"):
		if not vegetation_manager.is_connected("all_vegetation_ready", _on_all_vegetation_ready):
			vegetation_manager.connect("all_vegetation_ready", _on_all_vegetation_ready)
	
	# V2: Find player components
	if player:
		var systems_node = player.get_node_or_null("Systems")
		if systems_node:
			player_inventory = systems_node.get_node_or_null("Inventory")
			player_hotbar = systems_node.get_node_or_null("Hotbar")
			mode_manager = systems_node.get_node_or_null("ModeManager")
		
		var components_node = player.get_node_or_null("Components")
		if components_node:
			player_movement = components_node.get_node_or_null("Movement")
			player_camera = components_node.get_node_or_null("Camera")
			var movement_node = components_node.get_node_or_null("Movement")
			if movement_node:
				crouch_component = movement_node.get_node_or_null("Crouch")
		
		var modes_node = player.get_node_or_null("Modes")
		if modes_node:
			player_combat = modes_node.get_node_or_null("CombatSystem")
			player_terrain = modes_node.get_node_or_null("TerrainInteraction")
	
	# Find player stats (autoload)
	player_stats = get_node_or_null("/root/PlayerStats")
	
	# Get container registry
	container_registry = get_node_or_null("/root/ContainerRegistry")
	
	DebugManager.log_save("V2 Systems: INV=%s HB=%s STATS=%s MODE=%s CROUCH=%s CONT=%s" % [
		player_inventory != null, player_hotbar != null, player_stats != null,
		mode_manager != null, crouch_component != null, container_registry != null
	])

func _input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F5:
			if is_loading_game:
				DebugManager.log_save("F5 ignored - load in progress")
				return
			quick_save()
		elif event.keycode == KEY_F8:
			if is_loading_game:
				DebugManager.log_save("F8 ignored - load already in progress")
				return
			quick_load()

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Auto-save on exit
		DebugManager.log_save("Auto-saving on exit (FORCED SYNCHRONOUS)...")
		# Wait for any active threaded save to finish first to avoid file corruption
		for thread in _save_threads:
			if thread.is_alive():
				thread.wait_to_finish()
		_save_threads.clear()
		_is_saving = false
		_save_game_internal(SAVE_DIR + "autosave.json") # Call synchronous version for exit
		get_tree().quit()

func _process(_delta):
	# Cleanup finished threads
	var i = _save_threads.size() - 1
	while i >= 0:
		if not _save_threads[i].is_alive():
			_save_threads[i].wait_to_finish()
			_save_threads.remove_at(i)
		i -= 1
	# Only clear _is_saving when ALL threads are done
	if _save_threads.is_empty():
		_is_saving = false

## Quick save to default slot
func quick_save():
	var path = SAVE_DIR + QUICKSAVE_FILE
	save_game(path)

## Quick load from default slot
func quick_load():
	_find_managers() # Ensure we have latest references
	var path = SAVE_DIR + QUICKSAVE_FILE
	load_game(path)

## Save game to specified path
func save_game(path: String) -> bool:
	_find_managers() # Ensure we have latest references
	if is_loading_game:
		push_warning("SaveManager: Cannot save while loading")
		return false
	
	if _is_saving:
		push_warning("SaveManager: Save already in progress, skipping...")
		return false
	
	DebugManager.log_save("Saving to: %s (Threaded)" % path)
	_is_saving = true
	
	var save_data = _gather_save_data()
	
	# Start thread for JSON processing and file writing
	var thread = Thread.new()
	var error = thread.start(_threaded_save.bind(path, save_data))
	
	if error != OK:
		push_error("SaveManager: Failed to start save thread")
		_is_saving = false
		return false
	
	_save_threads.append(thread)
	return true

## Internal synchronous save for critical moments (e.g. exit)
func _save_game_internal(path: String) -> bool:
	var data = _gather_save_data()
	var json_string = JSON.stringify(data, "\t")
	# Atomic write: write to .tmp then rename to prevent corruption on crash
	var tmp_path = path + ".tmp"
	var file = FileAccess.open(tmp_path, FileAccess.WRITE)
	if file:
		file.store_string(json_string)
		file.close()
		# Atomic rename over the real file
		var dir = DirAccess.open(SAVE_DIR)
		if dir:
			dir.rename(tmp_path, path)
		DebugManager.log_save("Synchronous save complete: %s" % path)
		return true
	return false

func _gather_save_data() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"timestamp": Time.get_datetime_string_from_system(),
		"game_seed": _get_world_seed(),
		"world_definition_path": _get_world_definition_path(),
		"player": _get_player_data(),
		"terrain_modifications": _get_terrain_data(),
		"buildings": _get_building_data(),
		"vegetation": _get_vegetation_data(),
		"roads": _get_road_data(),
		"prefabs": _get_prefab_data(),
		"entities": _get_entity_data(),
		"doors": _get_door_data(),
		"vehicles": _get_vehicle_data(),
		"building_spawns": _get_building_spawn_data(),
		# V2 additions
		"player_inventory": _get_inventory_data(),
		"player_hotbar": _get_hotbar_data(),
		"player_stats": _get_player_stats_data(),
		"player_state": _get_player_state_data(),
		"containers": _get_container_data(),
		"game_settings": _get_game_settings_data()
	}

func _threaded_save(path: String, data: Dictionary):
	# Convert to JSON (heavy operation)
	var json_string = JSON.stringify(data, "\t")
	
	# Atomic write: write to .tmp then rename to prevent corruption on crash
	var tmp_path = path + ".tmp"
	var file = FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("[SaveManager] Failed to open file for writing: " + tmp_path)
		call_deferred("emit_signal", "save_completed", false, path)
		return
	
	file.store_string(json_string)
	file.close()
	
	# Atomic rename over the real file (prevents 0-byte on crash)
	var dir = DirAccess.open(path.get_base_dir())
	if dir:
		dir.rename(tmp_path, path)
	
	DebugManager.log_save("Threaded save complete!")
	call_deferred("_finalize_save", path)

func _finalize_save(path: String):
	print("[SAVE_NOTIFICATION] Game saved to: %s" % path)
	save_completed.emit(true, path)

## Load game from specified path
func load_game(path: String) -> bool:
	# Guard against double-load (F8 pressed twice)
	if is_loading_game:
		DebugManager.log_save("Load rejected - already loading")
		return false
	
	_find_managers() # Ensure we have latest references
	# CRITICAL: Set flag BEFORE anything else to prevent procedural spawning during reload
	is_quickloading = true
	DebugManager.log_save("Loading from: %s" % path)
	current_save_path = path
	
	# Stop autosave timer during load to prevent saving partial state
	if _autosave_timer:
		_autosave_timer.stop()

	# CRITICAL: Strict input freeze during load
	if player_camera and "mouse_look_enabled" in player_camera:
		player_camera.mouse_look_enabled = false
		DebugManager.log_save("Player camera mouse look LOCKED for load sequence")
	
	# CRITICAL: Immediate Cleanup of entities to prevent ghosts during load
	if entity_manager:
		entity_manager.is_loading_save = true
		if entity_manager.has_method("clear_all_entities"):
			entity_manager.clear_all_entities()
		DebugManager.log_save("Immediate entity cleanup triggered")
	
	# Open file
	if not FileAccess.file_exists(path):
		push_error("[SaveManager] Save file not found: " + path)
		_reset_load_flags()
		load_completed.emit(false, path)
		return false
	
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[SaveManager] Failed to open file for reading: " + path)
		_reset_load_flags()
		load_completed.emit(false, path)
		return false
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_string)
	if parse_result != OK:
		push_error("[SaveManager] Failed to parse JSON: " + json.get_error_message())
		_reset_load_flags()
		load_completed.emit(false, path)
		return false
	
	var save_data = json.get_data()
	
	# Structural validation: ensure save_data is a Dictionary with minimum required keys
	if not save_data is Dictionary:
		push_error("[SaveManager] Save data is not a Dictionary")
		_reset_load_flags()
		load_completed.emit(false, path)
		return false
	
	# Validate version
	var version = save_data.get("version", 0)
	if version > SAVE_VERSION:
		push_error("[SaveManager] Save version %d newer than supported %d" % [version, SAVE_VERSION])
		_reset_load_flags()
		load_completed.emit(false, path)
		return false
	
	# Validate critical keys exist (prevents silent state reset from truncated files)
	if not save_data.has("player") and not save_data.has("game_seed"):
		push_error("[SaveManager] Save file appears truncated/corrupted - missing player and seed data")
		_reset_load_flags()
		load_completed.emit(false, path)
		return false
	
	# V1 saves now use the same V2 pipeline (missing V2 keys default to empty)
	if version == 1:
		DebugManager.log_save("Detected v1 save - upgrading to V2 pipeline")
	
	# Load each component
	# IMPORTANT: Load prefabs FIRST to prevent respawning during chunk generation
	_load_prefab_data(save_data.get("prefabs", {}))
	# Load building spawn state BEFORE chunks generate
	_load_building_spawn_data(save_data.get("building_spawns", {}))
	
	# CRITICAL: Disable player physics and interaction EARLY to allow immediate position restoration
	if player:
		player.set_physics_process(false)
		if player_movement:
			player_movement.set_physics_process(false)
			player_movement.set_process(false)
		if player_camera:
			player_camera.set_process(false)
		if player_combat:
			player_combat.set_physics_process(false)
			player_combat.set_process(false)
		if player_terrain:
			player_terrain.set_physics_process(false)
			player_terrain.set_process(false)
		DebugManager.log_save("Player and sub-components frozen EARLY for position restoration")
	
	# Set loading flag - entities will be deferred until terrain is ready
	load_step.emit("Loading prefabs", 1, 10)
	is_loading_game = true
	pending_entity_data = save_data.get("entities", {})
	
	# CRITICAL FIX: Disable procedural entity spawning IMMEDIATELY before terrain regenerates
	# Otherwise chunk_generated signals queue procedural zombies that duplicate saved ones
	if entity_manager:
		entity_manager.is_loading_save = true
		if "pending_spawns" in entity_manager:
			entity_manager.pending_spawns.clear()
		DebugManager.log_save("Blocked procedural spawning before terrain reload")
	
	# V2: Initialize all data-driven managers FIRST
	# This ensures they have their "chopped trees", "inventory", etc. before chunks generate
	load_step.emit("Restoring world seed", 2, 10)
	_load_world_seed(int(save_data.get("game_seed", 12345)))
	_load_world_definition_path(save_data.get("world_definition_path", ""))
	
	# CRITICAL: Clear all existing vegetation data before loading new state
	if vegetation_manager and vegetation_manager.has_method("clear_all_data"):
		vegetation_manager.clear_all_data()
	
	load_step.emit("Loading vegetation", 3, 10)
	_load_vegetation_data(save_data.get("vegetation", {}))
	_load_road_data(save_data.get("roads", {}))
	load_step.emit("Loading player data", 4, 10)
	_load_inventory_data(save_data.get("player_inventory", {}))
	_load_hotbar_data(save_data.get("player_hotbar", {}))
	_load_player_stats_data(save_data.get("player_stats", {}))
	_load_player_state_data(save_data.get("player_state", {}))
	_load_game_settings_data(save_data.get("game_settings", {}))
	load_step.emit("Loading containers & vehicles", 5, 10)
	
	# Store door/container/vehicle data as pending - loaded in _check_world_readiness
	# when buildings have actually spawned (doors & containers live inside buildings)
	pending_door_data = save_data.get("doors", {})
	pending_container_data = save_data.get("containers", {})
	pending_vehicle_data = save_data.get("vehicles", {})
	
	# Load terrain modifications (clears world) - MUST happen before building data
	# since clear_all_chunks destroys any meshes rebuilt prematurely
	load_step.emit("Loading terrain", 6, 10)
	_load_terrain_data(save_data.get("terrain_modifications", {}))
	
	# Load building data AFTER terrain is cleared so meshes aren't wasted
	load_step.emit("Loading buildings", 7, 10)
	_load_building_data(save_data.get("buildings", {}))
	
	# Readiness flags - set before triggering world gen
	awaiting_terrain_ready = true
	# Only wait for vegetation if there is data to process
	awaiting_vegetation_ready = not save_data.get("vegetation", {}).is_empty() and vegetation_manager != null
	
	DebugManager.log_save("Awaiting: Terrain=%s Vegetation=%s" % [awaiting_terrain_ready, awaiting_vegetation_ready])
	
	# Show loading screen BEFORE triggering world gen (so it catches early signals)
	_show_loading_screen()
	
	# Finally, trigger the world generation by requesting the player's zone
	# This MUST be last because it triggers signals that managers above react to
	load_step.emit("Generating terrain", 8, 10)
	_load_player_data(save_data.get("player", {}))
	
	# V2 FIX: DON'T emit load_completed or print "Game loaded" here!
	# We are still waiting for terrain and vegetation.
	DebugManager.log_save("Load initiated - awaiting world generation...")
	
	# Start safety timeout (15s to accommodate large worlds)
	_start_load_safety_timeout(15.0)
	
	return true

## Instantiate and show the loading screen overlay
func _show_loading_screen():
	# Don't spawn if already exists
	if get_tree().root.find_child("LoadingScreen", true, false):
		return
		
	var screen_path = "res://modules/world_player_v2/features/ui_loading_screen/loading_screen.tscn"
	if ResourceLoader.exists(screen_path):
		var screen_scene = load(screen_path)
		var screen_instance = screen_scene.instantiate()
		get_tree().root.add_child(screen_instance)
		DebugManager.log_save("Loading screen spawned")

## Safety timeout to prevent being stuck forever if signals are dropped
func _start_load_safety_timeout(seconds: float):
	load_safety_timer = get_tree().create_timer(seconds)
	load_safety_timer.timeout.connect(_on_load_timeout)

func _on_load_timeout():
	if is_loading_game:
		push_warning("SaveManager: LOAD TIMEOUT REACHED! Forcing unfreeze.")
		awaiting_terrain_ready = false
		awaiting_vegetation_ready = false
		_check_world_readiness()

## Emit player_loaded signal (deferred to ensure all systems are ready)
func _emit_player_loaded():
	if has_node("/root/PlayerSignals"):
		PlayerSignals.player_loaded.emit()
		DebugManager.log_save("Player loaded signal emitted - systems should reconnect")

## Called when terrain chunks around spawn positions are ready
func _on_spawn_zones_ready(_positions: Array):
	if not is_loading_game or not awaiting_terrain_ready:
		return
	
	awaiting_terrain_ready = false
	DebugManager.log_save("Terrain ready - checking if vegetation is also ready")
	_check_world_readiness()

## Called when vegetation manager finishes its initial load batch
func _on_all_vegetation_ready():
	if not is_loading_game or not awaiting_vegetation_ready:
		return
		
	awaiting_vegetation_ready = false
	DebugManager.log_save("Vegetation ready - checking if terrain is also ready")
	_check_world_readiness()

## Finalize loading when all systems are ready
func _check_world_readiness():
	if awaiting_terrain_ready or awaiting_vegetation_ready:
		DebugManager.log_save("Still waiting for: %s%s" % [
			"Terrain " if awaiting_terrain_ready else "",
			"Vegetation" if awaiting_vegetation_ready else ""
		])
		return
	
	DebugManager.log_save("All world components ready - final unfreeze")
	
	# Re-enable player physics now that ground is solid
	if player:
		player.set_physics_process(true)
		if player_movement:
			player_movement.set_physics_process(true)
			player_movement.set_process(true)
		if player_camera:
			player_camera.set_process(true)
			if "mouse_look_enabled" in player_camera:
				player_camera.mouse_look_enabled = true
		
		# FORCE mouse capture to ensure the player has control immediately
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		DebugManager.log_save("Forced mouse capture on unfreeze")
		
		if player_combat:
			player_combat.set_physics_process(true)
			player_combat.set_process(true)
		if player_terrain:
			player_terrain.set_physics_process(true)
			player_terrain.set_process(true)
		DebugManager.log_save("Player and sub-components re-enabled")
	
	# CRITICAL FIX: Always call load_save_data to clear existing zombies
	# Even if no entities are saved, we need to clean up procedural spawns
	load_step.emit("Loading entities", 9, 10)
	if entity_manager and entity_manager.has_method("load_save_data"):
		entity_manager.load_save_data(pending_entity_data)
	
	# Spawn queued vehicles now that terrain is ready
	if not pending_vehicle_data.is_empty():
		_load_vehicle_data(pending_vehicle_data)
	
	# Load doors and containers NOW that buildings have had time to spawn
	# (They were deferred from load_game because buildings need terrain first)
	if not pending_door_data.is_empty():
		_load_door_data(pending_door_data)
	if not pending_container_data.is_empty():
		_load_container_data(pending_container_data)
	
	# Clear pending data
	pending_player_data = {}
	pending_entity_data = {}
	pending_vehicle_data = {}
	pending_door_data = {}
	pending_container_data = {}
	is_loading_game = false
	
	# Restart autosave timer now that load is complete
	if _autosave_timer and autosave_enabled:
		_autosave_timer.start()
	
	# CRITICAL: Emit player_loaded signal so hotbar/combat/HUD reconnect
	# Hotbar's load_save_data connects to this (one-shot) to re-emit select_slot & item_changed
	# Without this, the combat system never knows what item is selected → no hand visual
	call_deferred("_emit_player_loaded")
	
	# FINAL NOTIFICATION: Now that everything is unfrozen and ready
	load_step.emit("Complete", 10, 10)
	DebugManager.log_save("Load process fully complete!")
	print("[LOAD_NOTIFICATION] Game loaded and world ready!")
	load_completed.emit(true, current_save_path)
	is_quickloading = false  # Clear the flag now that load is complete

## Get list of available save files
func get_save_files() -> Array[String]:
	var saves: Array[String] = []
	var dir = DirAccess.open(SAVE_DIR)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(".json"):
				saves.append(file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
	return saves

# ============ DATA GETTERS ============

func _get_world_seed() -> int:
	if chunk_manager and "world_seed" in chunk_manager:
		return chunk_manager.world_seed
	return 12345

func _get_player_data() -> Dictionary:
	if not player:
		return {}
	
	# Find player's camera to save look direction (pitch)
	var camera_pitch: float = 0.0
	var camera = player.get_node_or_null("Camera3D")
	if camera:
		camera_pitch = camera.rotation.x
	
	return {
		"position": _vec3_to_array(player.global_position),
		"rotation": _vec3_to_array(player.rotation),
		"camera_pitch": camera_pitch,
		"is_flying": player.get("is_flying") if "is_flying" in player else false
	}

func _get_terrain_data() -> Dictionary:
	if not chunk_manager:
		push_warning("SaveManager: chunk_manager is null")
		return {}
	
	# Access stored_modifications directly
	if not "stored_modifications" in chunk_manager:
		push_warning("SaveManager: no stored_modifications")
		return {}
	
	var result = {}
	for coord in chunk_manager.stored_modifications:
		var key = "%d,%d,%d" % [coord.x, coord.y, coord.z]
		var mods = []
		for mod in chunk_manager.stored_modifications[coord]:
			mods.append({
				"brush_pos": _vec3_to_array(mod.brush_pos),
				"radius": mod.radius,
				"value": mod.value,
				"shape": mod.shape,
				"layer": mod.layer,
				"material_id": mod.get("material_id", -1)
			})
		result[key] = mods
	
	DebugManager.log_save("Saved %d terrain chunks" % result.size())
	return result

func _get_building_data() -> Dictionary:
	if not building_manager:
		return {}
	
	if not "chunks" in building_manager:
		return {}
	
	var result = {}
	for coord in building_manager.chunks:
		var chunk = building_manager.chunks[coord]
		if chunk == null or chunk.is_empty:
			continue
		
		var key = "%d,%d,%d" % [coord.x, coord.y, coord.z]
		
		# Encode voxel data as base64
		var voxels_b64 = Marshalls.raw_to_base64(chunk.voxel_bytes)
		var meta_b64 = Marshalls.raw_to_base64(chunk.voxel_meta)
		
		# Serialize objects
		var objects_data = []
		for anchor in chunk.objects:
			var obj = chunk.objects[anchor]
			objects_data.append({
				"anchor": _vec3i_to_array(anchor),
				"object_id": obj.object_id,
				"rotation": obj.rotation,
				"fractional_y": obj.get("fractional_y", 0.0)
			})
		
		result[key] = {
			"voxels": voxels_b64,
			"meta": meta_b64,
			"objects": objects_data
		}
	
	return result

func _get_vegetation_data() -> Dictionary:
	if not vegetation_manager:
		return {}
	
	# Use vegetation manager's built-in save method (includes chopped trees)
	if vegetation_manager.has_method("get_save_data"):
		return vegetation_manager.get_save_data()
	
	return {}

func _get_road_data() -> Dictionary:
	if road_manager and road_manager.has_method("get_save_data"):
		return road_manager.get_save_data()
	return {}

func _get_prefab_data() -> Dictionary:
	if not prefab_spawner:
		return {}
	
	if prefab_spawner.has_method("get_save_data"):
		return prefab_spawner.get_save_data()
	
	return {}

func _get_building_spawn_data() -> Dictionary:
	if not building_generator:
		return {}
	if building_generator.has_method("get_save_data"):
		return building_generator.get_save_data()
	return {}

# ============ DATA LOADERS ============

func _load_prefab_data(data: Dictionary):
	if data.is_empty() or not prefab_spawner:
		return
	
	if prefab_spawner.has_method("load_save_data"):
		prefab_spawner.load_save_data(data)

func _load_building_spawn_data(data: Dictionary):
	if data.is_empty() or not building_generator:
		return
	if building_generator.has_method("load_save_data"):
		building_generator.load_save_data(data)

func _load_player_data(data: Dictionary):
	if data.is_empty() or not player:
		return
	
	# Store data for logic that might check it later
	pending_player_data = data
	
	var player_pos = Vector3.ZERO
	
	# IMMEDIATE RESTORATION: Set position/rotation right away
	# Safe because physics_process is already disabled in load_game()
	if data.has("position"):
		player_pos = _array_to_vec3(data.position)
		player.global_position = player_pos
		DebugManager.log_save("Player position restored IMMEDIATELY: %s" % player_pos)
		
	if data.has("rotation"):
		player.rotation = _array_to_vec3(data.rotation)
	
	# Camera pitch and flying state
	if data.has("camera_pitch"):
		var camera = player.get_node_or_null("Camera3D")
		if camera:
			camera.rotation.x = data.camera_pitch
	if data.has("is_flying") and "is_flying" in player:
		player.is_flying = data.is_flying
	
	# Reset velocity
	player.velocity = Vector3.ZERO
	
	# Request terrain around player position (for spawn zone readiness)
	if chunk_manager and chunk_manager.has_method("request_spawn_zone"):
		chunk_manager.request_spawn_zone(player_pos, 2)
	
	DebugManager.log_save("Player data loaded - position restored, physics pending world load")

func _load_terrain_data(data: Dictionary):
	if not chunk_manager:
		push_error("SaveManager: Cannot load terrain - chunk_manager is null!")
		return
	
	# CRITICAL: Atomic reset of all background tasks and existing chunks
	# This prevents "double rendering" and redundant generation during load
	if chunk_manager.has_method("clear_all_chunks"):
		chunk_manager.clear_all_chunks()
	else:
		# Fallback to manual clear if API changed (should not happen with v2)
		chunk_manager.stored_modifications.clear()
	
	if data.is_empty():
		return
	
	# Load new modifications
	for key in data:
		var parts = key.split(",")
		if parts.size() != 3:
			continue
		var coord = Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
		
		var mods = []
		for mod in data[key]:
			mods.append({
				"brush_pos": _array_to_vec3(mod.brush_pos),
				"radius": mod.radius,
				"value": mod.value,
				"shape": mod.shape,
				"layer": mod.layer,
				"material_id": mod.get("material_id", -1)
			})
		chunk_manager.stored_modifications[coord] = mods
	
	DebugManager.log_save("Terrain modifications loaded: %d chunks" % data.size())

func _load_building_data(data: Dictionary):
	if data.is_empty() or not building_manager:
		return
	
	if not "chunks" in building_manager:
		return
	
	for key in data:
		var parts = key.split(",")
		if parts.size() != 3:
			continue
		var coord = Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
		var chunk_data = data[key]
		
		# Get or create building chunk
		var chunk = building_manager.get_chunk(coord)
		
		# Decode voxel data
		if chunk_data.has("voxels"):
			chunk.voxel_bytes = Marshalls.base64_to_raw(chunk_data.voxels)
		if chunk_data.has("meta"):
			chunk.voxel_meta = Marshalls.base64_to_raw(chunk_data.meta)
		
		# Check if voxels are all empty (building was destroyed)
		var has_voxels = false
		for byte_idx in chunk.voxel_bytes.size():
			if chunk.voxel_bytes.decode_u8(byte_idx) > 0:
				has_voxels = true
				break
		
		# Load objects ONLY if the chunk has actual voxel data
		# Prevents orphaned floating objects when building was destroyed
		if chunk_data.has("objects") and has_voxels:
			for obj_data in chunk_data.objects:
				var anchor = _array_to_vec3i(obj_data.anchor)
				# FIX: JSON floats → int for ObjectRegistry lookups and rotation checks
				var object_id = int(obj_data.object_id)
				var rotation = int(obj_data.rotation)
				var fractional_y = obj_data.get("fractional_y", 0.0)
				
				# Store object data (visual will be created on rebuild)
				chunk.objects[anchor] = {
					"object_id": object_id,
					"rotation": rotation,
					"fractional_y": fractional_y
				}
				
				# Mark cells as occupied
				var cells = ObjectRegistry.get_occupied_cells(object_id, anchor, rotation)
				for cell in cells:
					chunk.occupied_by_object[cell] = anchor
		elif chunk_data.has("objects") and not has_voxels:
			DebugManager.log_save("Skipped %d orphan objects in empty building chunk %s" % [chunk_data.objects.size(), key])
		
		if has_voxels:
			chunk.is_empty = false
			chunk.rebuild_mesh()
			# Restore visual instances for placed objects (tables, doors, etc.)
			chunk.call_deferred("restore_object_visuals")
		else:
			chunk.is_empty = true
	
	DebugManager.log_save("Buildings loaded: %d chunks" % data.size())

func _load_world_seed(seed_val: int):
	if chunk_manager and "world_seed" in chunk_manager:
		chunk_manager.world_seed = seed_val
		DebugManager.log_save("World seed restored to ChunkManager: %d" % seed_val)
	
	if vegetation_manager and vegetation_manager.has_method("initialize_noise"):
		vegetation_manager.initialize_noise()
		DebugManager.log_save("VegetationManager noise re-initialized with new seed")

func _get_world_definition_path() -> String:
	if chunk_manager and "world_definition_path" in chunk_manager:
		return chunk_manager.world_definition_path
	return ""

func _load_world_definition_path(path: String):
	if chunk_manager and "world_definition_path" in chunk_manager:
		chunk_manager.world_definition_path = path
		if path != "":
			chunk_manager.world_map_active = true
			if "terrain_height" in chunk_manager:
				chunk_manager.world_map_max_height = chunk_manager.terrain_height * 2.5
			DebugManager.log_save("World map path restored: %s" % path)
		else:
			chunk_manager.world_map_active = false
			DebugManager.log_save("No world map path — using procedural terrain")

func _load_vegetation_data(data: Dictionary):
	if data.is_empty() or not vegetation_manager:
		return
	
	# Use vegetation manager's built-in load method (handles chopped trees, etc.)
	if vegetation_manager.has_method("load_save_data"):
		vegetation_manager.load_save_data(data)
	else:
		push_warning("SaveManager: vegetation_manager has no load_save_data method")

func _load_road_data(data: Dictionary):
	if data.is_empty() or not road_manager:
		return
	
	if road_manager.has_method("load_save_data"):
		road_manager.load_save_data(data)

# ============ ENTITY DATA ============

func _get_entity_data() -> Dictionary:
	if not entity_manager:
		return {}
	
	if entity_manager.has_method("get_save_data"):
		return entity_manager.get_save_data()
	
	return {}

func _load_entity_data(data: Dictionary):
	if data.is_empty() or not entity_manager:
		return
	
	if entity_manager.has_method("load_save_data"):
		entity_manager.load_save_data(data)

# ============ VEHICLE DATA ============

func _get_vehicle_data() -> Dictionary:
	if not vehicle_manager:
		return {}
	
	if vehicle_manager.has_method("get_save_data"):
		return vehicle_manager.get_save_data()
	
	return {}

func _load_vehicle_data(data: Dictionary):
	if data.is_empty() or not vehicle_manager:
		return
	
	if vehicle_manager.has_method("load_save_data"):
		vehicle_manager.load_save_data(data)

# ============ DOOR DATA ============

func _get_door_data() -> Dictionary:
	# Find all interactive doors in the scene
	var doors = get_tree().get_nodes_in_group("interactable")
	var door_states: Array = []
	
	for node in doors:
		if node is InteractiveDoor:
			door_states.append({
				"position": _vec3_to_array(node.global_position),
				"is_open": node.is_open
			})
	
	return { "doors": door_states }

func _load_door_data(data: Dictionary):
	if data.is_empty() or not data.has("doors"):
		return
	
	# Find all doors and match by position
	var doors = get_tree().get_nodes_in_group("interactable")
	
	for saved_door in data.doors:
		var saved_pos = _array_to_vec3(saved_door.position)
		var saved_is_open = saved_door.is_open
		
		# Find matching door by position
		for node in doors:
			if node is InteractiveDoor:
				var dist = node.global_position.distance_to(saved_pos)
				if dist < 0.5:  # Within 0.5 units = same door
					if saved_is_open and not node.is_open:
						node.open_door()
					elif not saved_is_open and node.is_open:
						node.close_door()
					break
	
	DebugManager.log_save("Doors loaded: %d" % data.doors.size())

# ============ V2: NEW PLAYER SYSTEM DATA ============

func _get_inventory_data() -> Dictionary:
	if not player_inventory or not player_inventory.has_method("get_save_data"):
		return {}
	return player_inventory.get_save_data()

func _load_inventory_data(data: Dictionary):
	if data.is_empty() or not player_inventory or not player_inventory.has_method("load_save_data"):
		return
	player_inventory.load_save_data(data)

func _get_hotbar_data() -> Dictionary:
	if not player_hotbar or not player_hotbar.has_method("get_save_data"):
		return {}
	return player_hotbar.get_save_data()

func _load_hotbar_data(data: Dictionary):
	if data.is_empty() or not player_hotbar or not player_hotbar.has_method("load_save_data"):
		return
	player_hotbar.load_save_data(data)

func _get_player_stats_data() -> Dictionary:
	if not player_stats or not player_stats.has_method("get_save_data"):
		return {}
	return player_stats.get_save_data()

func _load_player_stats_data(data: Dictionary):
	if data.is_empty() or not player_stats or not player_stats.has_method("load_save_data"):
		return
	player_stats.load_save_data(data)

func _get_player_state_data() -> Dictionary:
	var data = {}
	if crouch_component:
		data["is_crouching"] = crouch_component.is_crouching
	
	if mode_manager:
		if mode_manager.has_method("get_save_data"):
			var mode_data = mode_manager.get_save_data()
			for key in mode_data:
				data[key] = mode_data[key]
		else:
			data["current_mode"] = mode_manager.current_mode
			data["editor_submode"] = mode_manager.editor_submode
			data["is_flying"] = mode_manager.is_flying
			
	return data

func _load_player_state_data(data: Dictionary):
	if data.is_empty():
		return
	
	# Restore crouch state
	if data.has("is_crouching") and crouch_component:
		if crouch_component.has_method("set_crouch_state"):
			crouch_component.set_crouch_state(data.is_crouching)
		else:
			# Fallback if method missing
			crouch_component.is_crouching = data.is_crouching
	
	# Restore mode state
	if mode_manager:
		if mode_manager.has_method("load_save_data"):
			mode_manager.load_save_data(data)
		else:
			# Fallback for old versions
			if data.has("current_mode") and mode_manager.has_method("set_mode"):
				mode_manager.set_mode(data.current_mode)
			if data.has("editor_submode") and "editor_submode" in mode_manager:
				mode_manager.editor_submode = data.editor_submode
			if data.has("is_flying") and "is_flying" in mode_manager:
				mode_manager.is_flying = data.is_flying

func _get_container_data() -> Dictionary:
	if not container_registry or not container_registry.has_method("get_save_data"):
		return {}
	return container_registry.get_save_data()

func _load_container_data(data: Dictionary):
	if data.is_empty() or not container_registry:
		return
	
	if container_registry.has_method("load_save_data"):
		container_registry.load_save_data(data)

func _get_game_settings_data() -> Dictionary:
	var settings = {
		"autosave_enabled": autosave_enabled,
		"autosave_interval": autosave_interval_seconds,
		"time_of_day": 0.5, # Placeholder for TimeManager
		"weather": "clear", # Placeholder for WeatherManager
		"difficulty": "normal"
	}
	return settings

func _load_game_settings_data(data: Dictionary):
	if data.is_empty():
		return
	
	if data.has("autosave_enabled"):
		autosave_enabled = data.autosave_enabled
	if data.has("autosave_interval"):
		autosave_interval_seconds = data.autosave_interval
		_setup_autosave() # Re-apply interval
	
	# Restore time/weather once those systems exist
	DebugManager.log_save("Game settings loaded (Time: %s, Weather: %s)" % [
		data.get("time_of_day", "?"), data.get("weather", "?")
	])

## Reset all load-related flags on failure (prevents permanent state corruption)
func _reset_load_flags():
	is_quickloading = false
	is_loading_game = false
	awaiting_terrain_ready = false
	awaiting_vegetation_ready = false
	pending_entity_data = {}
	pending_vehicle_data = {}
	pending_door_data = {}
	pending_container_data = {}
	if entity_manager:
		entity_manager.is_loading_save = false
	# Unfreeze player (they may have been frozen before the failure)
	if player:
		player.set_physics_process(true)
		if player_movement:
			player_movement.set_physics_process(true)
			player_movement.set_process(true)
		if player_camera:
			player_camera.set_process(true)
			if "mouse_look_enabled" in player_camera:
				player_camera.mouse_look_enabled = true
		if player_combat:
			player_combat.set_physics_process(true)
			player_combat.set_process(true)
		if player_terrain:
			player_terrain.set_physics_process(true)
			player_terrain.set_process(true)
	# Restart autosave
	if _autosave_timer and autosave_enabled:
		_autosave_timer.start()
	DebugManager.log_save("Load flags reset after failure - player unfrozen")

# ============ UTILITY FUNCTIONS ============

func _vec3_to_array(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

func _array_to_vec3(a: Array) -> Vector3:
	if a.size() < 3:
		return Vector3.ZERO
	return Vector3(a[0], a[1], a[2])

func _vec3i_to_array(v: Vector3i) -> Array:
	return [v.x, v.y, v.z]

func _array_to_vec3i(a: Array) -> Vector3i:
	if a.size() < 3:
		return Vector3i.ZERO
	return Vector3i(int(a[0]), int(a[1]), int(a[2]))
