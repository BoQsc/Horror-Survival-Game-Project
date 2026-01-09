extends Node3D
class_name PrefabSpawner

## Spawns prefab buildings near procedural roads
## Uses the existing building system so buildings are destructible/mutable

@export var terrain_manager: Node3D # ChunkManager reference
@export var building_manager: Node3D # BuildingManager reference
@export var viewer: Node3D # Player reference for distance checks

## Procedural road settings (must match ChunkManager)
@export var road_spacing: float = 100.0
@export var road_width: float = 8.0
@export var enabled: bool = true

## Spawning settings
@export var spawn_distance_from_road: float = 15.0 # How far from road center
@export var spawn_interval: float = 50.0 # Distance between buildings along road
@export var seed_offset: int = 42 # Added to world seed for variety
@export var door_despawn_distance: float = 150.0 # Distance at which doors unload

# Track which road intersections have been processed
# This is persisted via SaveManager to prevent respawning
var spawned_positions: Dictionary = {}

# Track spawned doors for distance-based cleanup
var spawned_doors: Dictionary = {} # "x_z" -> door instance

# Preload the interactive door scene
const DOOR_SCENE = preload("res://models/objects/interactive_door/interactive_door.tscn")

# Simple prefab definitions (relative block positions)
# Block types: 1=Wood, 2=Stone, 3=Ramp, 4=Stairs
var prefabs = {
	"small_house": [
		# Entrance stairs (in front, type=4 is stairs)
		{"offset": Vector3i(1, 0, -1), "type": 4, "meta": 0}, # Stairs facing +Z (into building)
		
		# Floor
		{"offset": Vector3i(0, 0, 0), "type": 1, "meta": 0},
		{"offset": Vector3i(1, 0, 0), "type": 1, "meta": 0},
		{"offset": Vector3i(2, 0, 0), "type": 1, "meta": 0},
		{"offset": Vector3i(0, 0, 1), "type": 1, "meta": 0},
		{"offset": Vector3i(1, 0, 1), "type": 1, "meta": 0},
		{"offset": Vector3i(2, 0, 1), "type": 1, "meta": 0},
		{"offset": Vector3i(0, 0, 2), "type": 1, "meta": 0},
		{"offset": Vector3i(1, 0, 2), "type": 1, "meta": 0},
		{"offset": Vector3i(2, 0, 2), "type": 1, "meta": 0},
		
		# Walls - layer 1 (door opening at 1, 1, 0)
		{"offset": Vector3i(0, 1, 0), "type": 1, "meta": 0},
		{"offset": Vector3i(2, 1, 0), "type": 1, "meta": 0},
		{"offset": Vector3i(0, 1, 2), "type": 1, "meta": 0},
		{"offset": Vector3i(1, 1, 2), "type": 1, "meta": 0}, # Back wall
		{"offset": Vector3i(2, 1, 2), "type": 1, "meta": 0},
		{"offset": Vector3i(0, 1, 1), "type": 1, "meta": 0},
		{"offset": Vector3i(2, 1, 1), "type": 1, "meta": 0},
		
		# Walls - layer 2 (door opening continues here - no block at 1,2,0)
		{"offset": Vector3i(0, 2, 0), "type": 1, "meta": 0},
		# {"offset": Vector3i(1, 2, 0) removed for 2-block doorway}
		{"offset": Vector3i(2, 2, 0), "type": 1, "meta": 0},
		{"offset": Vector3i(0, 2, 2), "type": 1, "meta": 0},
		{"offset": Vector3i(1, 2, 2), "type": 1, "meta": 0},
		{"offset": Vector3i(2, 2, 2), "type": 1, "meta": 0},
		{"offset": Vector3i(0, 2, 1), "type": 1, "meta": 0},
		{"offset": Vector3i(2, 2, 1), "type": 1, "meta": 0},
		
		# Roof
		{"offset": Vector3i(0, 3, 0), "type": 1, "meta": 0},
		{"offset": Vector3i(1, 3, 0), "type": 1, "meta": 0},
		{"offset": Vector3i(2, 3, 0), "type": 1, "meta": 0},
		{"offset": Vector3i(0, 3, 1), "type": 1, "meta": 0},
		{"offset": Vector3i(1, 3, 1), "type": 1, "meta": 0},
		{"offset": Vector3i(2, 3, 1), "type": 1, "meta": 0},
		{"offset": Vector3i(0, 3, 2), "type": 1, "meta": 0},
		{"offset": Vector3i(1, 3, 2), "type": 1, "meta": 0},
		{"offset": Vector3i(2, 3, 2), "type": 1, "meta": 0},
	]
}

# Noise to check if trees would spawn (same as vegetation_manager)
var forest_noise: FastNoiseLite

func _ready():
	# Find managers if not assigned
	if not terrain_manager:
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if not building_manager:
		building_manager = get_tree().get_first_node_in_group("building_manager")
	if not viewer:
		viewer = get_tree().get_first_node_in_group("player")
	
	# Connect to chunk generation signal
	if terrain_manager and terrain_manager.has_signal("chunk_generated"):
		terrain_manager.chunk_generated.connect(_on_chunk_generated)
		DebugManager.log_building("PrefabSpawner connected to terrain_manager")
	
	# Setup forest noise (same params as vegetation_manager)
	forest_noise = FastNoiseLite.new()
	forest_noise.frequency = 0.05
	var base_seed = terrain_manager.world_seed if terrain_manager else 12345
	forest_noise.seed = base_seed
	
	# Sync road settings from terrain_manager
	if terrain_manager:
		if "procedural_road_spacing" in terrain_manager:
			road_spacing = terrain_manager.procedural_road_spacing
		if "procedural_road_width" in terrain_manager:
			road_width = terrain_manager.procedural_road_width

func _process(_delta):
	_cleanup_distant_doors()

## Remove doors that are too far from the player
func _cleanup_distant_doors():
	if not viewer:
		viewer = get_tree().get_first_node_in_group("player")
		if not viewer:
			return
	
	var player_pos = viewer.global_position
	var max_dist_sq = door_despawn_distance * door_despawn_distance
	var to_remove: Array = []
	
	for key in spawned_doors:
		var door = spawned_doors[key]
		if not is_instance_valid(door):
			to_remove.append(key)
			continue
		
		var dist_sq = door.global_position.distance_squared_to(player_pos)
		if dist_sq > max_dist_sq:
			door.queue_free()
			to_remove.append(key)
	
	for key in to_remove:
		spawned_doors.erase(key)

## Check if location would have trees (returns true if forested area)
func _is_forested_area(x: float, z: float) -> bool:
	if not forest_noise:
		return false
	# Check a small area around the point
	for dx in range(-2, 5, 2): # -2 to 4 step 2 = covers 3x3 building
		for dz in range(-2, 5, 2):
			var noise_val = forest_noise.get_noise_2d(x + dx, z + dz)
			if noise_val >= 0.4: # Trees spawn when >= 0.4
				return true
	return false

func _on_chunk_generated(coord: Vector3i, _chunk_node: Node3D):
	if not enabled or not building_manager:
		return
	
	# Only spawn buildings on surface chunks (Y=0)
	if coord.y != 0:
		return
	
	# Check for road intersections in this chunk
	var chunk_world_x = coord.x * 31 # CHUNK_STRIDE
	var chunk_world_z = coord.z * 31 # Use .z for Z coordinate (Vector3i)
	
	_check_and_spawn_buildings(chunk_world_x, chunk_world_z)

func _check_and_spawn_buildings(chunk_x: float, chunk_z: float):
	if road_spacing <= 0:
		return
	
	# Find road grid cells that overlap this chunk
	var cell_x = floor(chunk_x / road_spacing)
	var cell_z = floor(chunk_z / road_spacing)
	
	# Check this cell and neighbors for road intersections
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var cx = int(cell_x + dx)
			var cz = int(cell_z + dz)
			
			# Road intersection point
			var intersection = Vector2(cx * road_spacing, cz * road_spacing)
			var key = "%d_%d" % [cx, cz]
			
			if spawned_positions.has(key):
				continue
			
			# Mark as processed
			spawned_positions[key] = true
			
			# Deterministic random for this intersection
			var rng = RandomNumberGenerator.new()
			rng.seed = hash(key) + seed_offset
			
			# Chance to spawn a building (not every intersection)
			if rng.randf() > 0.3:
				continue
			
			# Pick a side of the road (offset from intersection)
			var side = 1.0 if rng.randf() > 0.5 else -1.0
			var spawn_x = intersection.x + spawn_distance_from_road * side
			var spawn_z = intersection.y + spawn_distance_from_road
			
			# Skip if this is a forested area (trees would spawn here)
			if _is_forested_area(spawn_x, spawn_z):
				continue
			
			# Sample terrain height at multiple points (building is 3x3)
			# Use the MAXIMUM height to prevent the building from being buried
			var h1 = _get_terrain_height(spawn_x, spawn_z)
			var h2 = _get_terrain_height(spawn_x + 3, spawn_z)
			var h3 = _get_terrain_height(spawn_x, spawn_z + 3)
			var h4 = _get_terrain_height(spawn_x + 3, spawn_z + 3)
			
			# Use max height to ensure building sits on highest point
			var terrain_y = max(max(h1, h2), max(h3, h4))
			if terrain_y < 0:
				terrain_y = 15.0 # Fallback
			
			# Place floor at terrain level (prefab floor is at Y=0)
			var spawn_pos = Vector3(spawn_x, terrain_y, spawn_z)
			
			# Spawn a prefab
			_spawn_prefab("small_house", spawn_pos)

func _get_terrain_height(x: float, z: float) -> float:
	if terrain_manager and terrain_manager.has_method("get_terrain_height"):
		return terrain_manager.get_terrain_height(x, z)
	return -1.0

var vegetation_manager: Node3D # Cached reference

func _get_vegetation_manager() -> Node3D:
	if not vegetation_manager:
		vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
		# Fallback: search by name
		if not vegetation_manager:
			vegetation_manager = get_tree().root.find_child("VegetationManager", true, false)
	return vegetation_manager

func _spawn_prefab(prefab_name: String, world_pos: Vector3):
	if not prefabs.has(prefab_name):
		return
	
	# Clear vegetation in the building area first
	var veg_mgr = _get_vegetation_manager()
	if veg_mgr and veg_mgr.has_method("clear_vegetation_in_area"):
		veg_mgr.clear_vegetation_in_area(world_pos, 5.0) # 5 meter radius
	
	var blocks = prefabs[prefab_name]
	
	for block in blocks:
		var offset = block.offset
		var block_type = block.type
		var block_meta = block.get("meta", 0) # Default to 0 if not specified
		
		var pos = world_pos + Vector3(offset)
		building_manager.set_voxel_batched(pos, block_type, block_meta)
	
	# Flush all batched voxel changes at once (triggers single mesh rebuild per chunk)
	building_manager.flush_dirty_chunks()
	
	# Spawn interactive door for small_house prefab
	if prefab_name == "small_house":
		_spawn_door_at_prefab(world_pos)
	
	DebugManager.log_building("Spawned %s at %v" % [prefab_name, world_pos])

## Spawn an interactive door at the prefab doorway
func _spawn_door_at_prefab(prefab_world_pos: Vector3):
	# Create key based on prefab position
	var key = "%d_%d" % [int(prefab_world_pos.x), int(prefab_world_pos.z)]
	
	# Skip if door already exists at this position
	if spawned_doors.has(key) and is_instance_valid(spawned_doors[key]):
		return
	
	# The doorway is at block offset (1, 1, 0) in the small_house prefab
	# Door should be placed at the front of the building, facing outward
	var door_offset = Vector3(1.5, 1.0, 0.0) # Center in x, floor level + 1, front edge
	var door_pos = prefab_world_pos + door_offset
	
	# Instance the door scene
	var door_instance = DOOR_SCENE.instantiate()
	
	# Rotate door to face outward (-Z direction, which is 180 degrees)
	door_instance.rotation_degrees.y = 180.0
	
	# Add to scene tree FIRST (required before setting global_transform)
	add_child(door_instance)
	
	# Now set global position (must be after add_child)
	door_instance.global_transform.origin = door_pos
	
	# Track door for cleanup
	spawned_doors[key] = door_instance
	
	DebugManager.log_building("Spawned door at %v" % door_pos)

## Save/Load persistence - prevents prefabs from respawning after load
func get_save_data() -> Dictionary:
	return {
		"spawned_positions": spawned_positions.keys()
	}

func load_save_data(data: Dictionary):
	if data.has("spawned_positions"):
		spawned_positions.clear()
		for key in data.spawned_positions:
			spawned_positions[key] = true
		DebugManager.log_building("Loaded %d spawned positions" % spawned_positions.size())

# ============ USER PREFAB SUPPORT ============

const USER_PREFAB_DIR = "user://world_prefabs/"
const RES_PREFAB_DIR = "res://world_prefabs/"

## Load all user prefabs from user://world_prefabs/ directory
func load_user_prefabs():
	if not DirAccess.dir_exists_absolute(USER_PREFAB_DIR):
		return
	
	var dir = DirAccess.open(USER_PREFAB_DIR)
	if not dir:
		return
	
	var count = 0
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.ends_with(".json"):
			var prefab_name = file_name.replace(".json", "")
			if load_prefab_from_file(prefab_name):
				count += 1
		file_name = dir.get_next()
	dir.list_dir_end()
	
	if count > 0:
		DebugManager.log_building("Loaded %d user prefabs" % count)

## Load a single prefab from JSON file (v2 bracket notation format only)
## Checks res://world_prefabs/ first, then user://world_prefabs/
func load_prefab_from_file(prefab_name: String) -> bool:
	# Try res://world_prefabs/ first (built-in prefabs)
	var path = RES_PREFAB_DIR + prefab_name + ".json"
	if not FileAccess.file_exists(path):
		# Fall back to user://world_prefabs/ (user-created prefabs)
		path = USER_PREFAB_DIR + prefab_name + ".json"
		if not FileAccess.file_exists(path):
			DebugManager.log_building("Prefab not found in res:// or user:// : %s" % prefab_name)
			return false
	
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return false
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	if json.parse(json_string) != OK:
		DebugManager.log_building("Failed to parse prefab: %s" % prefab_name)
		return false
	
	var data = json.get_data()
	var version = data.get("version", 1)
	
	# v2 format required
	if version < 2 or not data.has("layers"):
		DebugManager.log_building("Prefab '%s' uses old format (v%d). Run convert_prefab.py to upgrade." % [prefab_name, version])
		return false
	
	# Parse bracket notation layers
	var blocks = _parse_layers(data.layers, data.get("size", [1, 1, 1]))
	
	# Store in prefabs dictionary
	prefabs[prefab_name] = blocks
	
	# Store object data if present (for spawning .tscn objects)
	if data.has("objects") and data.objects.size() > 0:
		if not has_meta("prefab_objects"):
			set_meta("prefab_objects", {})
		get_meta("prefab_objects")[prefab_name] = _parse_compact_objects(data.objects)
	

	DebugManager.log_building("Loaded prefab '%s' with %d blocks" % [prefab_name, blocks.size()])
	return true

## Parse bracket notation token to type and meta
## Returns {type, meta} or null for empty
func _parse_token(token: String) -> Variant:
	if token == "." or token == "":
		return null
	
	# Remove brackets [type] or [type:meta]
	if token.begins_with("[") and token.ends_with("]"):
		var content = token.substr(1, token.length() - 2)
		if ":" in content:
			var parts = content.split(":")
			return {"type": int(parts[0]), "meta": int(parts[1])}
		else:
			return {"type": int(content), "meta": 0}
	
	return null

## Parse layer strings to blocks array
func _parse_layers(layers: Array, size_arr: Array) -> Array:
	var blocks: Array = []
	var size = Vector3i(int(size_arr[0]), int(size_arr[1]), int(size_arr[2]))
	
	var y = 0
	var z = 0
	
	for layer_str in layers:
		var line = str(layer_str).strip_edges()
		
		# Y-level separator
		if line == "---":
			y += 1
			z = 0
			continue
		
		# Parse tokens in this row
		var tokens = line.split(" ", false) # false = skip empty
		var x = 0
		for token in tokens:
			var parsed = _parse_token(token.strip_edges())
			if parsed != null:
				blocks.append({
					"offset": Vector3i(x, y, z),
					"type": parsed.type,
					"meta": parsed.meta
				})
			x += 1
		
		z += 1
	
	return blocks

## Parse compact object format [id, x, y, z, rot, frac_y] to full format
func _parse_compact_objects(compact: Array) -> Array:
	var result: Array = []
	for obj in compact:
		if obj is Array and obj.size() >= 5:
			result.append({
				"offset": [obj[1], obj[2], obj[3]],
				"object_id": obj[0],
				"rotation": obj[4],
				"fractional_y": obj[5] if obj.size() > 5 else 0.0
			})
	return result

## Spawn a user prefab at the given world position
## submerge_offset: how many blocks to bury into terrain (negative Y adjustment)
## rotation: 0-3 for 0°, 90°, 180°, 270° rotation
## carve_terrain: if true, carve out terrain where submerged blocks go
## foundation_fill: if true, grow terrain under foundation blocks to fill gaps
## skip_blocks: if true, only perform terrain operations (carve/fill) without placing blocks
## interior_carve: if true, carve terrain at block positions that intersect with terrain
func spawn_user_prefab(prefab_name: String, world_pos: Vector3, submerge_offset: int = 1, rotation: int = 0, carve_terrain: bool = false, foundation_fill: bool = false, skip_blocks: bool = false, interior_carve: bool = false) -> bool:
	PerformanceMonitor.start_measure("Prefab: " + prefab_name)
	# Try to load if not already loaded
	if not prefabs.has(prefab_name):
		if not load_prefab_from_file(prefab_name):
			PerformanceMonitor.end_measure("Prefab: " + prefab_name, 10.0)
			return false
	
	# Use default submerge of 1 for carve mode (prefabs no longer store this value)
	if carve_terrain:
		submerge_offset = 1
	
	# Adjust Y to submerge into terrain
	var spawn_pos = world_pos - Vector3(0, submerge_offset, 0)
	
	# Clear vegetation
	var veg_mgr = _get_vegetation_manager()
	if veg_mgr and veg_mgr.has_method("clear_vegetation_in_area"):
		veg_mgr.clear_vegetation_in_area(spawn_pos, 10.0)
	
	var blocks = prefabs[prefab_name]
	
	# Foundation fill mode: grow terrain under foundation blocks
	if foundation_fill:
		_fill_foundation_terrain(blocks, spawn_pos, rotation)
	
	# Carve terrain for submerged blocks (only in carve mode)
	if carve_terrain:
		for block in blocks:
			var offset = block.offset
			var rotated_offset = _rotate_offset(offset, rotation)
			var pos = spawn_pos + Vector3(rotated_offset)
			
			# If this block is at or below terrain surface, carve it out
			if pos.y <= world_pos.y:
				if terrain_manager and terrain_manager.has_method("modify_terrain"):
					# Dig a small box at this position (shape 1 = box, value > 0 = dig)
					terrain_manager.modify_terrain(pos + Vector3(0.5, 0.5, 0.5), 0.6, 1.0, 1, 0)
	
	# Interior carve: carve only at interior positions (where there are gaps in Y levels)
	# Walls have blocks at many consecutive Y levels, interior floors have gaps
	if interior_carve and terrain_manager and terrain_manager.has_method("modify_terrain"):
		# Build occupancy map: track which X,Z columns have blocks and at what Y levels
		var column_blocks = {} # Key: Vector2i(x,z), Value: Array of Y values
		var min_y = 999
		var max_y = -999
		
		for block in blocks:
			var offset = block.offset
			var rotated_offset = _rotate_offset(offset, rotation)
			var key = Vector2i(rotated_offset.x, rotated_offset.z)
			if not column_blocks.has(key):
				column_blocks[key] = []
			column_blocks[key].append(rotated_offset.y)
			min_y = min(min_y, rotated_offset.y)
			max_y = max(max_y, rotated_offset.y)
		
		DebugManager.log_building("[InteriorCarve] Prefab Y range: %d to %d, columns: %d" % [min_y, max_y, column_blocks.size()])
		
		# Interior column detection: a column is interior if it has fewer blocks
		# than the total height span (i.e., there are empty/gap Y levels)
		var prefab_height = max_y - min_y + 1
		var carve_count = 0
		var interior_count = 0
		
		for xz_key in column_blocks:
			var y_levels = column_blocks[xz_key]
			var block_count = y_levels.size()
			
			# Interior = has gaps in Y levels (fewer blocks than height span)
			# Wall = fully filled column (block at every Y level)
			var is_interior = block_count < prefab_height
			
			if not is_interior:
				continue # Skip fully-filled wall columns
			
			interior_count += 1
			
			# Get world position for this column at floor level
			var pos = spawn_pos + Vector3(xz_key.x, min_y, xz_key.y)
			
			# Check terrain height at this X,Z position
			var terrain_y = _get_terrain_height(pos.x + 0.5, pos.z + 0.5)
			
			# If terrain surface is above this floor, carve upward
			if terrain_y > 0 and pos.y <= terrain_y:
				var y = int(pos.y)
				while y <= int(terrain_y):
					var carve_pos = Vector3(pos.x + 0.5, float(y) + 0.5, pos.z + 0.5)
					terrain_manager.modify_terrain(carve_pos, 0.6, 1.0, 1, 0) # Box shape, dig
					carve_count += 1
					y += 1
		
		DebugManager.log_building("[InteriorCarve] Found %d interior columns, carved %d positions" % [interior_count, carve_count])
	
	# Skip block/object spawning if requested (used for carve-only step in Carve+Fill mode)
	if skip_blocks:
		var mode_str = "carve-only" if carve_terrain else "fill-only"
		DebugManager.log_building("Terrain-only operation '%s' at %v (submerge: %d, mode: %s)" % [prefab_name, spawn_pos, submerge_offset, mode_str])
		PerformanceMonitor.end_measure("Prefab: " + prefab_name, 10.0)
		return true
	
	# Spawn blocks with rotation (BATCHED - no mesh rebuild per block)
	for block in blocks:
		var offset = block.offset
		var rotated_offset = _rotate_offset(offset, rotation)
		var block_type = block.type
		var block_meta = block.get("meta", 0)
		
		# Rotate meta for directional blocks (stairs type=4, ramps type=2 with metas 1-3)
		# Meta values 0-3 represent directions that need to rotate with the prefab
		if block_type == 4 or (block_type == 2 and block_meta >= 1 and block_meta <= 3):
			block_meta = (block_meta + rotation) % 4
		
		var pos = spawn_pos + Vector3(rotated_offset)
		building_manager.set_voxel_batched(pos, block_type, block_meta)
	
	# Flush all batched voxel changes at once (triggers single mesh rebuild per chunk)
	building_manager.flush_dirty_chunks()
	
	# Spawn objects if any
	if has_meta("prefab_objects"):
		var objects_data = get_meta("prefab_objects")
		if objects_data.has(prefab_name):
			for obj in objects_data[prefab_name]:
				var offset = obj.offset
				# --- COMMON POSITIONING LOGIC ---
				# 1. Calculate the Target Corner (Rotated + Grid Corrected)
				var vec_offset = Vector3(float(offset[0]), float(offset[1]), float(offset[2]))
				var rotated_corner = _rotate_vector3_offset(vec_offset, rotation)
				var grid_correction = _get_grid_correction(rotation)
				var target_corner = spawn_pos + rotated_corner + grid_correction
				
				# Get object size (default 1x1x1)
				var obj_size = Vector3(1, 1, 1)
				var obj_local_rot = int(obj.get("rotation", 0))
				
				# If it's a known object_id, use its registry size
				if obj.has("object_id"):
					var def = ObjectRegistry.get_object(obj.object_id)
					if not def.is_empty():
						var s = def.size
						obj_size = Vector3(s.x, s.y, s.z)
				
				# 2. Calculate Local Size (Dimensions in Unrotated Prefab space)
				# If object is locally rotated 90/270, swap X/Z
				var local_size = obj_size
				if obj_local_rot == 1 or obj_local_rot == 3:
					local_size = Vector3(obj_size.z, obj_size.y, obj_size.x)
				
				# 3. Calculate Half-Size Offset (from Corner to Center) in Unrotated Prefab Space
				var half_size = local_size * 0.5
				
				# 4. Rotate this Half-Size vector by the PREFAB Rotation
				var rotated_half_size = _rotate_vector3_offset(half_size, rotation)
				
				# Remove Y offset if pivot is bottom-centered
				var center_offset = rotated_half_size
				center_offset.y = 0
				
				# 5. Calculate Final Target Center
				var target_center = target_corner + center_offset
				
				# 6. Compensation for BuildingChunk's Auto-Centering
				# BuildingChunk uses 'combined rotation' to swap offsets and ORIGINAL Unrotated Registry Size.
				# Combined Rotation = (obj_local_rot + rotation) % 4
				var combined_rot = (obj_local_rot + rotation) % 4
				
				var chunk_offset_x = obj_size.x * 0.5
				var chunk_offset_z = obj_size.z * 0.5
				
				# Swap if Combined Rotation is 90/270
				if combined_rot == 1 or combined_rot == 3:
					var temp = chunk_offset_x
					chunk_offset_x = chunk_offset_z
					chunk_offset_z = temp
				
				var chunk_center_offset = Vector3(chunk_offset_x, 0, chunk_offset_z)
				
				# 7. Final Position passed to helper
				var obj_pos = target_center - chunk_center_offset
				# --------------------------------
				
				# Use object_id if available, otherwise try to load scene directly
				if obj.has("object_id"):
					if not building_manager.place_object(obj_pos, obj.object_id, combined_rot, true, true):
						# print("DEBUG_MISSING_OBJ: Failed to place object_id %d at %v (Rotation %d)" % [obj.object_id, obj_pos, combined_rot])
						pass
				elif obj.has("scene") and obj.scene != "":
					var scene_rot_y = obj.get("rotation_y", 0) + (rotation * 90)
					_spawn_scene_at(obj.scene, obj_pos, scene_rot_y)
	
	var mode_str = "carve" if carve_terrain else ("fill" if foundation_fill else "surface")
	DebugManager.log_building("Spawned user prefab '%s' at %v (submerge: %d, mode: %s)" % [prefab_name, spawn_pos, submerge_offset, mode_str])
	PerformanceMonitor.end_measure("Prefab: " + prefab_name, 10.0)
	return true

## Fill terrain gaps under the prefab's foundation layer (Y=0 blocks)
func _fill_foundation_terrain(blocks: Array, spawn_pos: Vector3, rotation: int):
	if not terrain_manager or not terrain_manager.has_method("modify_terrain"):
		return
	
	DebugManager.log_building("[Foundation Fill] Starting fill for prefab at %v" % spawn_pos)
	
	# Find the minimum Y in the prefab (usually 0, but could be offset)
	var min_y = 999
	for block in blocks:
		if block.offset.y < min_y:
			min_y = block.offset.y
	
	# Process only foundation layer blocks (blocks at min_y)
	var fill_count = 0
	for block in blocks:
		if block.offset.y != min_y:
			continue
		
		var rotated_offset = _rotate_offset(block.offset, rotation)
		var block_world_pos = spawn_pos + Vector3(rotated_offset)
		
		# Sample terrain height at this X,Z position
		var terrain_y = _get_terrain_height(block_world_pos.x + 0.5, block_world_pos.z + 0.5)
		
		# Target Y is just below the foundation block (fill up to the block's bottom)
		var target_y = block_world_pos.y
		var gap = target_y - terrain_y
		
		DebugManager.log_building("  Block at (%d, %d): terrain_y=%.1f, target_y=%.1f, gap=%.1f" % [
			int(block_world_pos.x), int(block_world_pos.z), terrain_y, target_y, gap])
		
		# Only fill if there's a gap (terrain is below foundation)
		if gap > 0.2:
			# Fill in 1-block increments from terrain up to foundation
			# Each fill creates solid terrain at that level
			var current_y = terrain_y + 0.5 # Start half a block above terrain
			while current_y < target_y:
				var fill_pos = Vector3(block_world_pos.x + 0.5, current_y, block_world_pos.z + 0.5)
				# Strong fill: shape 1 = box, value -2.0 = aggressive terrain add
				terrain_manager.modify_terrain(fill_pos, 0.6, -2.0, 1, 0) # Box shape, STRONG fill
				current_y += 0.8 # Move up slightly less than 1 for overlap
				fill_count += 1
	
	DebugManager.log_building("[Foundation Fill] Completed: %d fill operations" % fill_count)


func _spawn_scene_at(scene_path: String, pos: Vector3, rotation_y: float):
	var packed = ObjectRegistry.get_preloaded_scene(scene_path)
	if not packed:
		return
	
	var instance = packed.instantiate()
	add_child(instance)
	instance.global_position = pos
	instance.rotation_degrees.y = rotation_y

## Get list of available prefabs from both res://world_prefabs/ and user://world_prefabs/
func get_available_prefabs() -> Array[String]:
	var result: Array[String] = []
	var seen: Dictionary = {} # Track names to avoid duplicates
	
	# Check res://world_prefabs/ first (built-in prefabs)
	var res_dir = DirAccess.open(RES_PREFAB_DIR)
	if res_dir:
		res_dir.list_dir_begin()
		var file_name = res_dir.get_next()
		while file_name != "":
			if file_name.ends_with(".json"):
				var prefab_name = file_name.replace(".json", "")
				if not seen.has(prefab_name):
					result.append(prefab_name)
					seen[prefab_name] = true
			file_name = res_dir.get_next()
		res_dir.list_dir_end()
	
	# Check user://world_prefabs/ (user-created prefabs)
	if DirAccess.dir_exists_absolute(USER_PREFAB_DIR):
		var user_dir = DirAccess.open(USER_PREFAB_DIR)
		if user_dir:
			user_dir.list_dir_begin()
			var file_name = user_dir.get_next()
			while file_name != "":
				if file_name.ends_with(".json"):
					var prefab_name = file_name.replace(".json", "")
					if not seen.has(prefab_name):
						result.append(prefab_name)
						seen[prefab_name] = true
				file_name = user_dir.get_next()
			user_dir.list_dir_end()
	
	return result

## Rotate a Vector3i offset by 90 degree increments
func _rotate_offset(offset: Vector3i, rotation: int) -> Vector3i:
	match rotation:
		0: return offset # No rotation
		1: return Vector3i(-offset.z, offset.y, offset.x) # 90°
		2: return Vector3i(-offset.x, offset.y, -offset.z) # 180°
		3: return Vector3i(offset.z, offset.y, -offset.x) # 270°
	return offset

## Rotate a Vector3 offset by 90 degree increments (preserves float precision)
func _rotate_vector3_offset(offset: Vector3, rotation: int) -> Vector3:
	match rotation:
		0: return offset # No rotation
		1: return Vector3(-offset.z, offset.y, offset.x) # 90°
		2: return Vector3(-offset.x, offset.y, -offset.z) # 180°
		3: return Vector3(offset.z, offset.y, -offset.x) # 270°
	return offset
## Get correction offset to realign geometry with the voxel grid after rotation
## This is needed because rotating 0..1 into the negative axis (e.g. -1..0) 
## shifts the floor() index by -1 compared to simple integer negation.
func _get_grid_correction(rotation: int) -> Vector3:
	match rotation:
		1: return Vector3(1, 0, 0) # X axis becomes negative Z
		2: return Vector3(1, 0, 1) # X->-X, Z->-Z
		3: return Vector3(0, 0, 1) # Z axis becomes negative X
	return Vector3.ZERO
