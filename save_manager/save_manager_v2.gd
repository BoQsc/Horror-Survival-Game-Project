extends Node
## SaveManager - Handles saving and loading game state
## Autoload singleton for centralized save/load operations

signal save_completed(success: bool, path: String)
signal load_completed(success: bool, path: String)

const SAVE_VERSION = 2  # V2: Added inventory, hotbar, stats, containers, player state
const SAVE_DIR = "user://saves/"
const QUICKSAVE_FILE = "quicksave.json"

# Preload V1 loader for backward compatibility
const SaveManagerV1 = preload("res://save_manager/save_manager_v1.gd")

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

# V2: New player system references
var player_inventory: Node = null
var player_hotbar: Node = null
var player_stats: Node = null
var mode_manager: Node = null
var crouch_component: Node = null
var container_registry: Node = null

# Deferred spawn data - waiting for terrain to load
var pending_player_data: Dictionary = {}
var pending_entity_data: Dictionary = {}
var pending_vehicle_data: Dictionary = {}
var pending_player_position_restore: bool = false  # Fix: defer position until terrain collision ready
var is_loading_game: bool = false

# CRITICAL: Static flag that persists through scene reload
# EntityManager checks this in _ready() to skip procedural spawning during QuickLoad
static var is_quickloading: bool = false

func _ready():
	# Add to group for dynamic lookup by HUD
	add_to_group("save_manager")
	
	# Create saves directory if it doesn't exist
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	
	# Find managers (deferred to ensure scene is ready)
	call_deferred("_find_managers")

func _find_managers():
	chunk_manager = get_tree().get_first_node_in_group("terrain_manager")
	if not chunk_manager:
		chunk_manager = get_node_or_null("/root/MainGame/TerrainManager")
	
	building_manager = get_node_or_null("/root/MainGame/BuildingManager")
	vegetation_manager = get_node_or_null("/root/MainGame/VegetationManager")
	road_manager = get_node_or_null("/root/MainGame/RoadManager")
	prefab_spawner = get_node_or_null("/root/MainGame/PrefabSpawner")
	entity_manager = get_node_or_null("/root/MainGame/EntityManager")
	vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	building_generator = get_node_or_null("/root/MainGame/BuildingGenerator")
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
	
	# V2: Find player components
	if player:
		var systems_node = player.get_node_or_null("Systems")
		if systems_node:
			player_inventory = systems_node.get_node_or_null("Inventory")
			player_hotbar = systems_node.get_node_or_null("Hotbar")
			mode_manager = systems_node.get_node_or_null("ModeManager")
		
		var components_node = player.get_node_or_null("Components")
		if components_node:
			var movement_node = components_node.get_node_or_null("Movement")
			if movement_node:
				crouch_component = movement_node.get_node_or_null("Crouch")
	
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
			quick_save()
		elif event.keycode == KEY_F8:
			quick_load()

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Auto-save on exit
		DebugManager.log_save("Auto-saving on exit...")
		save_game(SAVE_DIR + "autosave.json")
		get_tree().quit()

## Quick save to default slot
func quick_save():
	var path = SAVE_DIR + QUICKSAVE_FILE
	save_game(path)

## Quick load from default slot
func quick_load():
	var path = SAVE_DIR + QUICKSAVE_FILE
	load_game(path)

## Save game to specified path
func save_game(path: String) -> bool:
	DebugManager.log_save("Saving to: %s" % path)
	
	var save_data = {
		"version": SAVE_VERSION,
		"timestamp": Time.get_datetime_string_from_system(),
		"game_seed": _get_world_seed(),
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
	
	# Convert to JSON
	var json_string = JSON.stringify(save_data, "\t")
	
	# Write to file
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[SaveManager] Failed to open file for writing: " + path)
		save_completed.emit(false, path)
		return false
	
	file.store_string(json_string)
	file.close()
	
	DebugManager.log_save("Save complete!")
	print("[SAVE_NOTIFICATION] Game saved to: %s" % path)
	save_completed.emit(true, path)
	return true

## Load game from specified path
func load_game(path: String) -> bool:
	# CRITICAL: Set flag BEFORE anything else to prevent procedural spawning during reload
	is_quickloading = true
	DebugManager.log_save("Loading from: %s" % path)
	
	if not FileAccess.file_exists(path):
		push_error("[SaveManager] Save file not found: " + path)
		load_completed.emit(false, path)
		return false
	
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[SaveManager] Failed to open file for reading: " + path)
		load_completed.emit(false, path)
		return false
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_string)
	if parse_result != OK:
		push_error("[SaveManager] Failed to parse JSON: " + json.get_error_message())
		load_completed.emit(false, path)
		return false
	
	var save_data = json.get_data()
	
	# Validate version
	var version = save_data.get("version", 0)
	if version > SAVE_VERSION:
		push_error("[SaveManager] Save version %d newer than supported %d" % [version, SAVE_VERSION])
		load_completed.emit(false, path)
		return false
	
	# V2: Delegate to v1 loader if v1 save detected
	if version == 1:
		DebugManager.log_save("Detected v1 save - delegating to v1 loader")
		var success = SaveManagerV1.load_v1_save(save_data, self)
		load_completed.emit(success, path)
		return success
	
	# Load each component
	# IMPORTANT: Load prefabs FIRST to prevent respawning during chunk generation
	_load_prefab_data(save_data.get("prefabs", {}))
	# Load building spawn state BEFORE chunks generate
	_load_building_spawn_data(save_data.get("building_spawns", {}))
	
	# Set loading flag - entities will be deferred until terrain is ready
	is_loading_game = true
	pending_entity_data = save_data.get("entities", {})
	
	# CRITICAL FIX: Disable procedural entity spawning IMMEDIATELY before terrain regenerates
	# Otherwise chunk_generated signals queue procedural zombies that duplicate saved ones
	if entity_manager:
		entity_manager.is_loading_save = true
		if "pending_spawns" in entity_manager:
			entity_manager.pending_spawns.clear()
		DebugManager.log_save("Blocked procedural spawning before terrain reload")
	
	_load_player_data(save_data.get("player", {}))
	_load_terrain_data(save_data.get("terrain_modifications", {}))
	_load_building_data(save_data.get("buildings", {}))
	_load_vegetation_data(save_data.get("vegetation", {}))
	_load_road_data(save_data.get("roads", {}))
	# Entities are deferred - they will spawn in _on_spawn_zones_ready()
	# _load_entity_data is NOT called here anymore
	# Doors are loaded after buildings (since doors are placed in building chunks)
	call_deferred("_load_door_data", save_data.get("doors", {}))
	# Vehicles are ALSO deferred until terrain is ready (prevents falling through)
	pending_vehicle_data = save_data.get("vehicles", {})
	
	# V2: Load player systems
	_load_inventory_data(save_data.get("player_inventory", {}))
	_load_hotbar_data(save_data.get("player_hotbar", {}))
	_load_player_stats_data(save_data.get("player_stats", {}))
	_load_player_state_data(save_data.get("player_state", {}))
	
	# V2: Containers (deferred)
	call_deferred("_load_container_data", save_data.get("containers", {}))
	
	# Emit player_loaded signal to reconnect all player systems
	call_deferred("_emit_player_loaded")
	
	DebugManager.log_save("Load complete!")
	print("[LOAD_NOTIFICATION] Game loaded from: %s" % path)
	load_completed.emit(true, path)
	return true

## Emit player_loaded signal (deferred to ensure all systems are ready)
func _emit_player_loaded():
	if has_node("/root/PlayerSignals"):
		PlayerSignals.player_loaded.emit()
		DebugManager.log_save("Player loaded signal emitted - systems should reconnect")

## Called when terrain chunks around spawn positions are ready
func _on_spawn_zones_ready(positions: Array):
	if not is_loading_game:
		return
	
	DebugManager.log_save("Spawn zones ready - gameplay enabled")
	
	# FIX: Restore player position/rotation NOW that terrain collision is ready
	if pending_player_position_restore and player and not pending_player_data.is_empty():
		if pending_player_data.has("position"):
			player.global_position = _array_to_vec3(pending_player_data.position)
			DebugManager.log_save("Player position restored: %s" % player.global_position)
		if pending_player_data.has("rotation"):
			player.rotation = _array_to_vec3(pending_player_data.rotation)
		pending_player_position_restore = false
	
	# CRITICAL FIX: Always call load_save_data to clear existing zombies
	# Even if no entities are saved, we need to clean up procedural spawns
	if entity_manager and entity_manager.has_method("load_save_data"):
		entity_manager.load_save_data(pending_entity_data)
	
	# Spawn queued vehicles now that terrain is ready
	if not pending_vehicle_data.is_empty():
		_load_vehicle_data(pending_vehicle_data)
	
	# Clear pending data
	pending_player_data = {}
	pending_entity_data = {}
	pending_vehicle_data = {}
	is_loading_game = false
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
	if not road_manager:
		return {}
	
	if not "road_segments" in road_manager:
		return {}
	
	var segments = []
	for segment_id in road_manager.road_segments:
		var seg = road_manager.road_segments[segment_id]
		var points = []
		for p in seg.points:
			points.append(_vec3_to_array(p))
		segments.append({
			"id": segment_id,
			"points": points,
			"width": seg.width,
			"is_trail": seg.is_trail
		})
	
	return { "segments": segments }

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
	
	# Store position for deferred restoration (FIX: wait for terrain collision)
	pending_player_data = data
	pending_player_position_restore = (data.has("position") or data.has("rotation"))
	
	var player_pos = Vector3.ZERO
	
	# FIX: Don't set position/rotation here - defer until terrain collision ready!
	# This prevents fall-through when QuickLoading early in game start
	if data.has("position"):
		player_pos = _array_to_vec3(data.position)
		# player.global_position = player_pos  # REMOVED - set in _on_spawn_zones_ready()
	# if data.has("rotation"):
	#	player.rotation = _array_to_vec3(data.rotation)  # REMOVED - set in _on_spawn_zones_ready()
	
	# Camera pitch and flying state are safe to restore immediately (don't affect physics)
	if data.has("camera_pitch"):
		var camera = player.get_node_or_null("Camera3D")
		if camera:
			camera.rotation.x = data.camera_pitch
	if data.has("is_flying") and "is_flying" in player:
		player.is_flying = data.is_flying
	
	# NOTE: Player freeze removed for QuickLoad (v2)
	# QuickLoad doesn't reload the scene, so player can stay active
	# V1 full scene loads handle freezing separately if needed
	player.velocity = Vector3.ZERO
	
	# Request terrain around player position (for spawn zone readiness)
	if chunk_manager and chunk_manager.has_method("request_spawn_zone"):
		chunk_manager.request_spawn_zone(player_pos, 2)
	
	DebugManager.log_save("Player data loaded - position deferred until terrain ready")

func _load_terrain_data(data: Dictionary):
	if data.is_empty():
		return
	if not chunk_manager:
		push_error("SaveManager: Cannot load terrain - chunk_manager is null!")
		return
	
	if not "stored_modifications" in chunk_manager:
		push_error("SaveManager: chunk_manager has no stored_modifications property!")
		return
	
	# Clear existing modifications
	chunk_manager.stored_modifications.clear()
	
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
	
	# Force regeneration of affected chunks by marking them for reload
	# This ensures the loaded modifications are actually applied
	var affected_chunks = chunk_manager.stored_modifications.keys()
	for coord in affected_chunks:
		if chunk_manager.active_chunks.has(coord):
			# Clear from active chunks to force regeneration
			var chunk_data = chunk_manager.active_chunks[coord]
			if chunk_data and chunk_data.node_terrain:
				chunk_data.node_terrain.queue_free()
			if chunk_data and chunk_data.node_water:
				chunk_data.node_water.queue_free()
			chunk_manager.active_chunks.erase(coord)
	
	DebugManager.log_save("Terrain loaded: %d chunks, regenerating %d" % [data.size(), affected_chunks.size()])

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
		
		# Load objects
		if chunk_data.has("objects"):
			for obj_data in chunk_data.objects:
				var anchor = _array_to_vec3i(obj_data.anchor)
				var object_id = obj_data.object_id
				var rotation = obj_data.rotation
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
		
		chunk.is_empty = false
		chunk.rebuild_mesh()
		# Restore visual instances for placed objects (tables, doors, etc.)
		chunk.call_deferred("restore_object_visuals")
	
	DebugManager.log_save("Buildings loaded: %d chunks" % data.size())

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
	
	if not "road_segments" in road_manager:
		return
	
	# Clear existing roads
	if road_manager.has_method("clear_all_roads"):
		road_manager.clear_all_roads()
	
	# Load road segments
	if data.has("segments"):
		for seg_data in data.segments:
			var points: Array[Vector3] = []
			for p in seg_data.points:
				points.append(_array_to_vec3(p))
			
			var segment_id = seg_data.id
			var width = seg_data.width
			var is_trail = seg_data.is_trail
			
			road_manager.road_segments[segment_id] = {
				"points": points,
				"width": width,
				"is_trail": is_trail
			}
			
			# Repaint road on mask
			for i in range(points.size() - 1):
				road_manager._paint_road_on_mask(points[i], points[i + 1], width)
		
		# Update next_segment_id
		if data.segments.size() > 0:
			var max_id = 0
			for seg in data.segments:
				if seg.id > max_id:
					max_id = seg.id
			road_manager.next_segment_id = max_id + 1
	
	DebugManager.log_save("Roads loaded: %d segments" % (data.segments.size() if data.has("segments") else 0))

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
	var state = {}
	
	# Crouch state
	if crouch_component and "is_crouching" in crouch_component:
		state["is_crouching"] = crouch_component.is_crouching
	
	# Mode state
	if mode_manager:
		if "current_mode" in mode_manager:
			state["current_mode"] = mode_manager.current_mode
		if "editor_submode" in mode_manager:
			state["editor_submode"] = mode_manager.editor_submode
		if "is_flying" in mode_manager:
			state["is_flying"] = mode_manager.is_flying
	
	return state

func _load_player_state_data(data: Dictionary):
	if data.is_empty():
		return
	
	# Restore crouch state (will be implemented when crouch refactor is done)
	if data.has("is_crouching") and crouch_component:
		if crouch_component.has_method("set_crouch_state"):
			crouch_component.set_crouch_state(data.is_crouching)
		else:
			DebugManager.log_save("Note: Crouch state was %s (refactor pending)" % data.is_crouching)
	
	# Restore mode state
	if mode_manager:
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
	# TODO: Time of day, weather when implemented
	return {}

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

