extends Node
## SaveManager - Handles saving and loading game state
## Autoload singleton for centralized save/load operations

signal save_completed(success: bool, path: String)
signal load_completed(success: bool, path: String)

const SAVE_VERSION = 1
const SAVE_DIR = "user://saves/"
const QUICKSAVE_FILE = "quicksave.json"

# References to game managers (set in _ready or via exports)
var chunk_manager: Node = null
var building_manager: Node = null
var vegetation_manager: Node = null
var road_manager: Node = null
var prefab_spawner: Node = null
var entity_manager: Node = null
var player: Node = null

func _ready():
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
	player = get_tree().get_first_node_in_group("player")
	
	print("[SaveManager] Managers found:")
	print("  - ChunkManager: ", chunk_manager != null)
	print("  - BuildingManager: ", building_manager != null)
	print("  - VegetationManager: ", vegetation_manager != null)
	print("  - RoadManager: ", road_manager != null)
	print("  - PrefabSpawner: ", prefab_spawner != null)
	print("  - EntityManager: ", entity_manager != null)
	print("  - Player: ", player != null)

func _input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F5:
			quick_save()
		elif event.keycode == KEY_F8:
			quick_load()

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Auto-save on exit
		print("[SaveManager] Auto-saving on exit...")
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
	print("[SaveManager] Saving game to: ", path)
	
	var save_data = {
		"version": SAVE_VERSION,
		"timestamp": Time.get_datetime_string_from_system(),
		"game_seed": _get_world_seed(),
		"player": _get_player_data(),
		"terrain_modifications": _get_terrain_data(),
		"buildings": _get_building_data(),
		"vegetation": _get_vegetation_data(),
		"roads": _get_road_data(),
		"prefabs": _get_prefab_data()
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
	
	print("[SaveManager] Save completed successfully!")
	save_completed.emit(true, path)
	return true

## Load game from specified path
func load_game(path: String) -> bool:
	print("[SaveManager] Loading game from: ", path)
	
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
		push_error("[SaveManager] Save file version %d is newer than supported %d" % [version, SAVE_VERSION])
		load_completed.emit(false, path)
		return false
	
	# Load each component
	# IMPORTANT: Load prefabs FIRST to prevent respawning during chunk generation
	_load_prefab_data(save_data.get("prefabs", {}))
	_load_player_data(save_data.get("player", {}))
	_load_terrain_data(save_data.get("terrain_modifications", {}))
	_load_building_data(save_data.get("buildings", {}))
	_load_vegetation_data(save_data.get("vegetation", {}))
	_load_road_data(save_data.get("roads", {}))
	
	print("[SaveManager] Load completed successfully!")
	load_completed.emit(true, path)
	return true

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
	
	return {
		"position": _vec3_to_array(player.global_position),
		"rotation": _vec3_to_array(player.rotation),
		"is_flying": player.get("is_flying") if "is_flying" in player else false
	}

func _get_terrain_data() -> Dictionary:
	if not chunk_manager:
		print("[SaveManager] WARNING: chunk_manager is null!")
		return {}
	
	# Access stored_modifications directly
	if not "stored_modifications" in chunk_manager:
		print("[SaveManager] WARNING: chunk_manager has no stored_modifications!")
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
	
	print("[SaveManager] Saved %d terrain modification chunks (%d total edits)" % [result.size(), chunk_manager.stored_modifications.size()])
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

# ============ DATA LOADERS ============

func _load_prefab_data(data: Dictionary):
	if data.is_empty() or not prefab_spawner:
		return
	
	if prefab_spawner.has_method("load_save_data"):
		prefab_spawner.load_save_data(data)

func _load_player_data(data: Dictionary):
	if data.is_empty() or not player:
		return
	
	if data.has("position"):
		player.global_position = _array_to_vec3(data.position)
	if data.has("rotation"):
		player.rotation = _array_to_vec3(data.rotation)
	if data.has("is_flying") and "is_flying" in player:
		player.is_flying = data.is_flying
	
	print("[SaveManager] Player data loaded")

func _load_terrain_data(data: Dictionary):
	if data.is_empty():
		print("[SaveManager] No terrain data to load")
		return
	if not chunk_manager:
		print("[SaveManager] ERROR: Cannot load terrain - chunk_manager is null!")
		return
	
	if not "stored_modifications" in chunk_manager:
		print("[SaveManager] ERROR: chunk_manager has no stored_modifications property!")
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
	
	print("[SaveManager] Terrain modifications loaded: %d chunks" % data.size())
	
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
	
	print("[SaveManager] Forced regeneration of %d chunks" % affected_chunks.size())

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
	
	print("[SaveManager] Building data loaded: %d chunks" % data.size())

func _load_vegetation_data(data: Dictionary):
	if data.is_empty() or not vegetation_manager:
		return
	
	# Use vegetation manager's built-in load method (handles chopped trees, etc.)
	if vegetation_manager.has_method("load_save_data"):
		vegetation_manager.load_save_data(data)
	else:
		print("[SaveManager] WARNING: vegetation_manager has no load_save_data method!")

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
	
	print("[SaveManager] Road data loaded: %d segments" % data.segments.size() if data.has("segments") else 0)

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
