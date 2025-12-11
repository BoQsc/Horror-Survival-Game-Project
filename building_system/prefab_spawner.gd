extends Node3D
class_name PrefabSpawner

## Spawns prefab buildings near procedural roads
## Uses the existing building system so buildings are destructible/mutable

@export var terrain_manager: Node3D  # ChunkManager reference
@export var building_manager: Node3D  # BuildingManager reference

## Procedural road settings (must match ChunkManager)
@export var road_spacing: float = 100.0
@export var road_width: float = 8.0
@export var enabled: bool = true

## Spawning settings
@export var spawn_distance_from_road: float = 15.0  # How far from road center
@export var spawn_interval: float = 50.0  # Distance between buildings along road
@export var seed_offset: int = 42  # Added to world seed for variety

# Track which road intersections have been processed
var spawned_positions: Dictionary = {}

# Simple prefab definitions (relative block positions)
# Block types: 1=Wood, 2=Stone, 3=Ramp, 4=Stairs
var prefabs = {
	"small_house": [
		# Entrance stairs (in front, type=4 is stairs)
		{"offset": Vector3i(1, 0, -1), "type": 4, "meta": 0},  # Stairs facing +Z (into building)
		
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
		{"offset": Vector3i(1, 1, 2), "type": 1, "meta": 0},  # Back wall
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
	
	# Connect to chunk generation signal
	if terrain_manager and terrain_manager.has_signal("chunk_generated"):
		terrain_manager.chunk_generated.connect(_on_chunk_generated)
		print("PrefabSpawner: Connected to terrain_manager")
	
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

## Check if location would have trees (returns true if forested area)
func _is_forested_area(x: float, z: float) -> bool:
	if not forest_noise:
		return false
	# Check a small area around the point
	for dx in range(-2, 5, 2):  # -2 to 4 step 2 = covers 3x3 building
		for dz in range(-2, 5, 2):
			var noise_val = forest_noise.get_noise_2d(x + dx, z + dz)
			if noise_val >= 0.4:  # Trees spawn when >= 0.4
				return true
	return false

func _on_chunk_generated(coord: Vector3i, _chunk_node: Node3D):
	if not enabled or not building_manager:
		return
	
	# Check for road intersections in this chunk
	var chunk_world_x = coord.x * 31  # CHUNK_STRIDE
	var chunk_world_z = coord.z * 31  # Use .z for Z coordinate (Vector3i)
	
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
				terrain_y = 15.0  # Fallback
			
			# Place floor at terrain level (prefab floor is at Y=0)
			var spawn_pos = Vector3(spawn_x, terrain_y, spawn_z)
			
			# Spawn a prefab
			_spawn_prefab("small_house", spawn_pos)

func _get_terrain_height(x: float, z: float) -> float:
	if terrain_manager and terrain_manager.has_method("get_terrain_height"):
		return terrain_manager.get_terrain_height(x, z)
	return -1.0

var vegetation_manager: Node3D  # Cached reference

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
		veg_mgr.clear_vegetation_in_area(world_pos, 5.0)  # 5 meter radius
	
	var blocks = prefabs[prefab_name]
	
	for block in blocks:
		var offset = block.offset
		var block_type = block.type
		var block_meta = block.get("meta", 0)  # Default to 0 if not specified
		
		var pos = world_pos + Vector3(offset)
		building_manager.set_voxel(pos, block_type, block_meta)
	
	print("PrefabSpawner: Spawned %s at %v" % [prefab_name, world_pos])

