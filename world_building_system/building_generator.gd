extends Node3D
## Procedural Building Generator
## Spawns prefab buildings along roads with throttled queue

signal building_spawned(position: Vector3, prefab_name: String)

# --- Configuration ---
@export var enabled: bool = true  # Now uses batched voxel operations
@export_range(0.0, 1.0) var building_density: float = 0.3 # Chance per valid spot
@export var spawn_interval: float = 0.5 # Seconds between spawns
@export var min_road_distance: int = 2 # Min blocks from road center
@export var max_road_distance: int = 10 # Max blocks from road center
@export var road_spacing: float = 100.0 # Match chunk_manager.procedural_road_spacing
@export var road_width: float = 8.0 # Match chunk_manager.procedural_road_width
@export var prefab_list: Array[String] = ["new_wooden_house_2floor"]
@export var min_building_spacing: float = 20.0 # Min distance between buildings
@export var intersection_avoid_radius: float = 15.0 # Avoid spawning near road intersections
@export var regenerate_buildings_on_load: bool = false # Debug: regenerate instead of loading saved state

# --- References ---
@export var prefab_spawner: Node = null
@export var terrain_manager: Node = null

# --- State ---
var spawn_queue: Array = [] # Queue of {position, rotation, prefab_name}
var spawned_buildings: Dictionary = {} # Key: chunk_coord, Value: Array of positions
var global_building_positions: Array[Vector3] = [] # All building positions for overlap check
var spawn_timer: float = 0.0

# --- Save/Load Support ---
func get_save_data() -> Dictionary:
	var result = {}
	for coord in spawned_buildings:
		var key = "%d,%d,%d" % [coord.x, coord.y, coord.z]
		var positions = []
		for pos in spawned_buildings[coord]:
			positions.append([pos.x, pos.y, pos.z])
		result[key] = positions
	return {"spawned_chunks": result}

func load_save_data(data: Dictionary) -> void:
	if regenerate_buildings_on_load:
		DebugManager.log_building("Regenerate mode enabled - skipping saved state")
		return # Debug: regenerate fresh instead of loading
	
	spawned_buildings.clear()
	global_building_positions.clear()
	spawn_queue.clear()
	
	if data.has("spawned_chunks"):
		for key in data.spawned_chunks:
			var parts = key.split(",")
			if parts.size() != 3:
				continue
			var coord = Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
			spawned_buildings[coord] = []
			for pos_arr in data.spawned_chunks[key]:
				var pos = Vector3(pos_arr[0], pos_arr[1], pos_arr[2])
				spawned_buildings[coord].append(pos)
				global_building_positions.append(pos)
		DebugManager.log_building("Loaded %d chunks with building spawn data" % spawned_buildings.size())

func _ready():
	# Connect to terrain manager signals
	if terrain_manager and terrain_manager.has_signal("chunk_generated"):
		terrain_manager.chunk_generated.connect(_on_chunk_generated)
		DebugManager.log_building("BuildingGenerator connected to chunk_generated signal")
		
		# Get road spacing from terrain manager
		if "procedural_road_spacing" in terrain_manager:
			road_spacing = terrain_manager.procedural_road_spacing
		if "procedural_road_width" in terrain_manager:
			road_width = terrain_manager.procedural_road_width
	else:
		push_warning("[BuildingGenerator] Could not connect to terrain_manager!")
	
	if prefab_spawner:
		DebugManager.log_building("BuildingGenerator found PrefabSpawner")
	else:
		push_warning("[BuildingGenerator] PrefabSpawner not found!")
	
	DebugManager.log_building("BuildingGenerator ready, enabled=%s, density=%.2f, interval=%.1fs" % [enabled, building_density, spawn_interval])

func _process(delta):
	if not enabled or spawn_queue.is_empty():
		return
	
	spawn_timer += delta
	if spawn_timer >= spawn_interval:
		spawn_timer = 0.0
		_process_spawn_queue()

## Process one building from the queue
func _process_spawn_queue() -> void:
	if spawn_queue.is_empty():
		return
	
	PerformanceMonitor.start_measure("Building Spawn")
	var item = spawn_queue.pop_front()
	_spawn_building(item.position, item.rotation, item.prefab_name)
	PerformanceMonitor.end_measure("Building Spawn", 5.0)

## Called when a chunk finishes generating
func _on_chunk_generated(coord: Vector3i, chunk_node: Node3D) -> void:
	if not enabled:
		return
	
	var chunk_world_pos = Vector3(coord.x * 32, coord.y * 32, coord.z * 32)
	_queue_buildings_for_chunk(coord, chunk_world_pos)

## Queue buildings for a chunk (non-blocking)
func _queue_buildings_for_chunk(chunk_coord: Vector3i, chunk_world_pos: Vector3) -> void:
	# Only generate for Y=0 layer (ground level)
	if chunk_coord.y != 0:
		return
	
	# Skip if already processed
	if spawned_buildings.has(chunk_coord):
		return
	
	spawned_buildings[chunk_coord] = []
	
	var chunk_size = 32
	var spots = _find_road_adjacent_spots(chunk_world_pos, chunk_size)
	
	for spot in spots:
		# Random chance based on density
		if randf() > building_density:
			continue
		
		# Check spacing from other buildings (including queued ones)
		if not _is_valid_spacing(spot.position):
			continue
		
		# Skip if near a road intersection
		if _is_near_intersection(spot.position):
			continue
		
		# Skip if over water
		if _is_over_water(spot.position):
			continue
		
		# Add to queue instead of spawning immediately
		var prefab_name = prefab_list[randi() % prefab_list.size()]
		spawn_queue.append({
			"position": spot.position,
			"rotation": spot.rotation,
			"prefab_name": prefab_name,
			"chunk_coord": chunk_coord
		})
		
		# Track position immediately to prevent overlaps
		global_building_positions.append(spot.position)
	
	if spawn_queue.size() > 0:
		DebugManager.log_building("Queued %d spots for chunk %v (total queue: %d)" % [spots.size(), chunk_coord, spawn_queue.size()])

## Find spots adjacent to roads within this chunk
func _find_road_adjacent_spots(chunk_pos: Vector3, chunk_size: int) -> Array:
	var spots = []
	
	if road_spacing <= 0:
		return spots
	
	# Check along X-aligned roads (roads at Z = n * road_spacing)
	var road_z_start = floor(chunk_pos.z / road_spacing) * road_spacing
	var road_z = road_z_start
	while road_z <= chunk_pos.z + chunk_size + road_spacing:
		if road_z >= chunk_pos.z - max_road_distance and road_z <= chunk_pos.z + chunk_size + max_road_distance:
			_add_spots_along_road(spots, chunk_pos, chunk_size, road_z, true)
		road_z += road_spacing
	
	# Check along Z-aligned roads (roads at X = n * road_spacing)
	var road_x_start = floor(chunk_pos.x / road_spacing) * road_spacing
	var road_x = road_x_start
	while road_x <= chunk_pos.x + chunk_size + road_spacing:
		if road_x >= chunk_pos.x - max_road_distance and road_x <= chunk_pos.x + chunk_size + max_road_distance:
			_add_spots_along_road(spots, chunk_pos, chunk_size, road_x, false)
		road_x += road_spacing
	
	return spots

## Add building spots along one road
func _add_spots_along_road(spots: Array, chunk_pos: Vector3, chunk_size: int, road_coord: float, is_x_road: bool) -> void:
	var step = min_building_spacing
	
	if is_x_road:
		var x = chunk_pos.x
		while x < chunk_pos.x + chunk_size:
			var north_z = road_coord - min_road_distance - road_width / 2
			var south_z = road_coord + min_road_distance + road_width / 2
			
			if north_z >= chunk_pos.z and north_z < chunk_pos.z + chunk_size:
				spots.append({"position": Vector3(x, 0, north_z), "rotation": 2})
			
			if south_z >= chunk_pos.z and south_z < chunk_pos.z + chunk_size:
				spots.append({"position": Vector3(x, 0, south_z), "rotation": 0})
			
			x += step
	else:
		var z = chunk_pos.z
		while z < chunk_pos.z + chunk_size:
			var west_x = road_coord - min_road_distance - road_width / 2
			var east_x = road_coord + min_road_distance + road_width / 2
			
			if west_x >= chunk_pos.x and west_x < chunk_pos.x + chunk_size:
				spots.append({"position": Vector3(west_x, 0, z), "rotation": 1})
			
			if east_x >= chunk_pos.x and east_x < chunk_pos.x + chunk_size:
				spots.append({"position": Vector3(east_x, 0, z), "rotation": 3})
			
			z += step

## Check if position is far enough from existing buildings
func _is_valid_spacing(pos: Vector3) -> bool:
	for existing in global_building_positions:
		var dist = Vector2(pos.x, pos.z).distance_to(Vector2(existing.x, existing.z))
		if dist < min_building_spacing:
			return false
	return true

## Check if position is near a road intersection (where X and Z roads cross)
func _is_near_intersection(pos: Vector3) -> bool:
	if road_spacing <= 0:
		return false
	
	# Find nearest intersection (occurs at multiples of road_spacing on both axes)
	var nearest_x = round(pos.x / road_spacing) * road_spacing
	var nearest_z = round(pos.z / road_spacing) * road_spacing
	
	var dist_to_intersection = Vector2(pos.x, pos.z).distance_to(Vector2(nearest_x, nearest_z))
	return dist_to_intersection < intersection_avoid_radius

## Check if position is over water
## Balanced check - catches water without being too aggressive
func _is_over_water(pos: Vector3) -> bool:
	if not terrain_manager:
		return false
	
	var water_level = 13.0 # Default
	if "water_level" in terrain_manager:
		water_level = terrain_manager.water_level
	
	# Buffer: reject terrain within 1 block above water level
	var water_buffer = 1.0
	
	# Check terrain height at points across building footprint
	var check_radius = 8.0 # Building footprint
	var check_offsets = [
		Vector2(0, 0),
		Vector2(-check_radius, 0), Vector2(check_radius, 0),
		Vector2(0, -check_radius), Vector2(0, check_radius),
		Vector2(-check_radius, -check_radius), Vector2(check_radius, -check_radius),
		Vector2(-check_radius, check_radius), Vector2(check_radius, check_radius),
	]
	
	for offset in check_offsets:
		var cx = pos.x + offset.x
		var cz = pos.z + offset.y
		
		# Check terrain height - reject if below or near water level
		if terrain_manager.has_method("get_terrain_height"):
			var terrain_h = terrain_manager.get_terrain_height(cx, cz)
			if terrain_h > 0 and terrain_h < water_level + water_buffer:
				return true
		
		# Also check water density if chunks are loaded
		if terrain_manager.has_method("get_water_density"):
			var density = terrain_manager.get_water_density(Vector3(cx, water_level, cz))
			if density < 0.0: # Negative = inside water
				return true
	
	# Check if in wet region AND terrain is low
	if _is_in_wet_region(pos.x, pos.z):
		if terrain_manager.has_method("get_terrain_height"):
			var h = terrain_manager.get_terrain_height(pos.x, pos.z)
			if h > 0 and h < water_level: # Only reject if actually below water
				return true
	
	return false

## Check if position is in a "wet region" using noise (matches gen_water_density.glsl)
func _is_in_wet_region(x: float, z: float) -> bool:
	var noise_freq = 0.02 # Default
	if terrain_manager and "noise_frequency" in terrain_manager:
		noise_freq = terrain_manager.noise_frequency
	
	# Sample low-frequency noise - matches shader: noise_freq * 0.1
	var sample_freq = noise_freq * 0.1
	var noise_val = _simple_noise_2d(x * sample_freq, z * sample_freq)
	
	# Map 0..1 to -1..1, then smoothstep(-0.3, 0.3)
	var mask_val = (noise_val * 2.0) - 1.0
	# smoothstep: wet when mask_val > 0
	return mask_val > 0.0

## Simple 2D noise for wet region detection
func _simple_noise_2d(x: float, z: float) -> float:
	var ix = floor(x)
	var iz = floor(z)
	var fx = x - ix
	var fz = z - iz
	fx = fx * fx * (3.0 - 2.0 * fx)
	fz = fz * fz * (3.0 - 2.0 * fz)
	
	var h00 = _hash_2d(ix, iz)
	var h10 = _hash_2d(ix + 1, iz)
	var h01 = _hash_2d(ix, iz + 1)
	var h11 = _hash_2d(ix + 1, iz + 1)
	
	return lerp(lerp(h00, h10, fx), lerp(h01, h11, fx), fz)

func _hash_2d(x: float, z: float) -> float:
	var px = fmod(abs(x * 0.3183099 + 0.1), 1.0)
	var pz = fmod(abs(z * 0.3183099 + 0.1), 1.0)
	px *= 17.0
	pz *= 17.0
	return fmod(abs(px * pz * (px + pz)), 1.0)

## Spawn a building at the given position
func _spawn_building(pos: Vector3, rotation: int, prefab_name: String) -> bool:
	if not prefab_spawner or not prefab_spawner.has_method("spawn_user_prefab"):
		return false
	
	# Get road height at this position
	var road_y = _get_road_height(pos.x, pos.z)
	var spawn_pos = Vector3(floor(pos.x), road_y, floor(pos.z))
	
	# Double-check water at spawn time (chunk may have loaded since queueing)
	if _is_over_water(spawn_pos):
		DebugManager.log_building("Skipped %s at %v - over water" % [prefab_name, spawn_pos])
		return false
	
	# Spawn WITHOUT interior carve (false at the end) for performance
	var success = prefab_spawner.spawn_user_prefab(prefab_name, spawn_pos, 0, rotation, false, false, false, false)
	
	if success:
		building_spawned.emit(spawn_pos, prefab_name)
		DebugManager.log_building("Spawned %s at %v" % [prefab_name, spawn_pos])
	
	return success

## Get road height at position
func _get_road_height(x: float, z: float) -> float:
	if road_spacing <= 0:
		return 12.0
	
	var nearest_x_road = round(x / road_spacing) * road_spacing
	var nearest_z_road = round(z / road_spacing) * road_spacing
	
	var dist_to_x = abs(x - nearest_x_road)
	var dist_to_z = abs(z - nearest_z_road)
	
	var road_x_sample: float
	var road_z_sample: float
	
	if dist_to_x < dist_to_z:
		road_x_sample = nearest_x_road
		road_z_sample = z
	else:
		road_x_sample = x
		road_z_sample = nearest_z_road
	
	if terrain_manager and terrain_manager.has_method("get_terrain_height"):
		var h = terrain_manager.get_terrain_height(road_x_sample, road_z_sample)
		if h > 0:
			return floor(h)
	
	return 12.0

## Clear buildings when chunk unloads
func clear_buildings_for_chunk(chunk_coord: Vector3i) -> void:
	if spawned_buildings.has(chunk_coord):
		var positions = spawned_buildings[chunk_coord]
		for pos in positions:
			global_building_positions.erase(pos)
		spawned_buildings.erase(chunk_coord)
