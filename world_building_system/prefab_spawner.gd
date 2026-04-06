extends Node3D
class_name PrefabSpawner

const PrefabGeometry = preload("res://world_building_system/prefab_geometry.gd")
const TERRAIN_DIG_AIR_DENSITY: float = 10.0
const BUILDING_CHUNK_SIZE: int = 16

## Spawns prefab buildings near procedural roads
## Uses the existing building system so buildings are destructible/mutable

@export var terrain_manager: Node3D # ChunkManager reference
@export var building_manager: Node3D # BuildingManager reference
@export var viewer: Node3D # Player reference for distance checks

## Procedural road settings (must match ChunkManager)
@export var road_spacing: float = 100.0
@export var road_width: float = 8.0
@export var enabled: bool = true
var skip_block_placement_for_test: bool = false

## Spawning settings
@export var spawn_distance_from_road: float = 15.0 # How far from road center
@export var spawn_interval: float = 50.0 # Distance between buildings along road
@export var seed_offset: int = 42 # Added to world seed for variety
@export var door_despawn_distance: float = 150.0 # Distance at which doors unload
@export_range(0.5, 20.0, 0.5) var spawn_processing_budget_ms: float = 4.0
@export_range(1.0, 500.0, 1.0) var chunk_flush_interval_ms: float = 250.0
var skip_object_spawns_for_test: bool = false
var skip_chunk_flush_for_test: bool = false
var skip_carving_for_test: bool = false

# Track which road intersections have been processed
# This is persisted via SaveManager to prevent respawning
var spawned_positions: Dictionary = {}
var pending_spawn_jobs: Array[Dictionary] = []
var pending_spawn_keys: Dictionary = {}
var rotated_block_batches_cache: Dictionary = {}
var _last_spawn_job_msec: int = 0

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
		# Pass building_map from terrain_manager to building_manager (world map mode)
		if building_manager and "_world_map_building_map" in terrain_manager and terrain_manager._world_map_building_map:
			building_manager.set_building_map(terrain_manager._world_map_building_map)
			DebugManager.log_building("PrefabSpawner: Passed building_map to BuildingManager")
	
	load_user_prefabs()

func _process(_delta):
	_process_pending_spawn_jobs()
	_cleanup_distant_doors()

func clear_pending_spawn_jobs() -> void:
	pending_spawn_jobs.clear()
	pending_spawn_keys.clear()
	_last_spawn_job_msec = 0


func has_pending_spawn_jobs() -> bool:
	return not pending_spawn_jobs.is_empty()

func get_telemetry_snapshot() -> Dictionary:
	return {
		"enabled": enabled,
		"world_map_mode": bool(building_manager and building_manager.world_map_mode),
		"road_spacing": road_spacing,
		"road_width": road_width,
		"spawn_distance_from_road": spawn_distance_from_road,
		"spawn_interval": spawn_interval,
		"spawn_processing_budget_ms": spawn_processing_budget_ms,
		"spawned_positions": spawned_positions.size(),
		"pending_spawn_jobs": pending_spawn_jobs.size(),
		"pending_spawn_keys": pending_spawn_keys.size(),
		"skip_object_spawns_for_test": skip_object_spawns_for_test,
		"skip_block_placement_for_test": skip_block_placement_for_test,
		"skip_chunk_flush_for_test": skip_chunk_flush_for_test,
		"skip_carving_for_test": skip_carving_for_test,
		"spawned_doors": spawned_doors.size(),
		"prefab_catalog_size": prefabs.size(),
		"rotated_block_batches_cache_size": rotated_block_batches_cache.size()
	}

func _queue_spawn_job(spawn_key: String, job: Dictionary) -> void:
	if spawned_positions.has(spawn_key) or pending_spawn_keys.has(spawn_key):
		return
	job["spawn_key"] = spawn_key
	spawned_positions[spawn_key] = true
	if building_manager and building_manager.world_map_mode and not pending_spawn_jobs.is_empty():
		_insert_world_map_spawn_job_sorted(job)
	else:
		pending_spawn_jobs.append(job)
	pending_spawn_keys[spawn_key] = true

func _insert_world_map_spawn_job_sorted(job: Dictionary) -> void:
	var insert_index := pending_spawn_jobs.size()
	while insert_index > 0 and _sort_world_map_spawn_job_by_distance(job, pending_spawn_jobs[insert_index - 1]):
		insert_index -= 1
	pending_spawn_jobs.insert(insert_index, job)

func _process_pending_spawn_jobs() -> void:
	if not building_manager:
		return

	var start_time := Time.get_ticks_usec()
	var processed := 0
	var started_measure := false
	var now_msec := Time.get_ticks_msec()
	var effective_budget_ms := spawn_processing_budget_ms
	if building_manager and building_manager.world_map_mode:
		effective_budget_ms = min(effective_budget_ms, 3.0)

	while not pending_spawn_jobs.is_empty():
		if processed > 0:
			var elapsed_ms := float(Time.get_ticks_usec() - start_time) / 1000.0
			if elapsed_ms >= effective_budget_ms:
				break

		var job: Dictionary = pending_spawn_jobs.pop_back()
		var spawn_key := str(job.get("spawn_key", ""))
		if spawn_key != "":
			pending_spawn_keys.erase(spawn_key)

		if not started_measure:
			PerformanceMonitor.start_measure("Baked Building Spawn")
			started_measure = true

		var prefab_name := str(job.get("prefab_name", ""))
		var world_pos: Vector3 = job.get("world_pos", Vector3.ZERO)
		var submerge_offset := int(job.get("submerge_offset", 1))
		var rotation := int(job.get("rotation", 0))
		var carve_terrain := bool(job.get("carve_terrain", false))
		var skip_blocks := bool(job.get("skip_blocks", false))
		var interior_carve := bool(job.get("interior_carve", false))
		var clear_vegetation := bool(job.get("clear_vegetation", true))

		spawn_user_prefab(
			prefab_name,
			world_pos,
			submerge_offset,
			rotation,
			carve_terrain,
			skip_blocks,
			interior_carve,
			clear_vegetation,
			false,
			false,
			int(job.get("object_start_index", 0)),
			bool(job.get("resume_objects_only", false))
		)
		processed += 1
		_last_spawn_job_msec = Time.get_ticks_msec()

	if started_measure:
		PerformanceMonitor.end_measure("Baked Building Spawn", 5.0)

	if building_manager and building_manager.has_method("has_dirty_global_visual_batches") and building_manager.has_dirty_global_visual_batches():
		# Defer the world-map visual batch rebuild until the prefab burst has
		# drained so we do not rebuild the same repeated prop meshes once per
		# spawn tick during town entry.
		if pending_spawn_jobs.is_empty():
			PerformanceMonitor.start_measure("Baked Building Visual Batch Flush")
			building_manager.flush_global_visual_batches()
			PerformanceMonitor.end_measure("Baked Building Visual Batch Flush", 5.0)
		else:
			PerformanceMonitor.capture_scope_state("buildings", {
				"phase": "visual_batch_flush_deferred",
				"pending_spawn_jobs": pending_spawn_jobs.size(),
				"pending_visual_batch_rebuilds": building_manager.has_method("has_pending_visual_batch_work") and building_manager.has_pending_visual_batch_work()
			})

	if skip_chunk_flush_for_test:
		PerformanceMonitor.capture_scope_event("buildings", "spawn_chunk_flush_skipped", {
			"reason": "test_toggle",
			"pending_spawn_jobs": pending_spawn_jobs.size()
		})
		return

	if building_manager.has_method("has_dirty_chunks") and building_manager.has_dirty_chunks():
		now_msec = Time.get_ticks_msec()
		var idle_since_last_spawn := now_msec - _last_spawn_job_msec
		var has_visible_dirty_chunks: bool = building_manager.has_method("has_dirty_visible_chunks") and building_manager.has_dirty_visible_chunks()
		if has_visible_dirty_chunks and pending_spawn_jobs.is_empty() and (processed > 0 or _last_spawn_job_msec > 0) and idle_since_last_spawn >= int(chunk_flush_interval_ms):
			PerformanceMonitor.start_measure("Baked Building Flush")
			building_manager.flush_dirty_chunks()
			PerformanceMonitor.end_measure("Baked Building Flush", 5.0)

func _get_rotated_block_batches(prefab_name: String, rotation: int) -> Array:
	var cache_key := "%s:%d" % [prefab_name, rotation]
	if rotated_block_batches_cache.has(cache_key):
		return rotated_block_batches_cache[cache_key]

	var rotated_blocks: Array = []
	var blocks: Array = prefabs.get(prefab_name, [])
	for block in blocks:
		var offset: Vector3i = block.offset
		var rotated_offset: Vector3i = _rotate_offset(offset, rotation)
		var block_type: int = int(block.type)
		var block_meta: int = int(block.get("meta", 0))

		if block_type == 4 or (block_type == 2 and block_meta >= 1 and block_meta <= 3):
			block_meta = (block_meta + rotation) % 4

		rotated_blocks.append({
			"offset": rotated_offset,
			"type": block_type,
			"meta": block_meta
		})

	rotated_block_batches_cache[cache_key] = rotated_blocks
	return rotated_blocks

func _pack_world_map_block_batches_from_rotated_blocks(rotated_blocks: Array, spawn_pos: Vector3, chunk_size: int) -> Array:
	var chunk_batches: Dictionary = {}
	if rotated_blocks.is_empty() or chunk_size <= 0:
		return []

	for block_data in rotated_blocks:
		var rotated_offset: Vector3i = block_data.get("offset", Vector3i.ZERO)
		var block_global_pos: Vector3 = spawn_pos + Vector3(rotated_offset)
		var chunk_coord: Vector3i = Vector3i(
			int(floor(block_global_pos.x / float(chunk_size))),
			int(floor(block_global_pos.y / float(chunk_size))),
			int(floor(block_global_pos.z / float(chunk_size)))
		)
		var local_pos: Vector3i = Vector3i(
			int(floor(block_global_pos.x)) % chunk_size,
			int(floor(block_global_pos.y)) % chunk_size,
			int(floor(block_global_pos.z)) % chunk_size
		)
		if local_pos.x < 0: local_pos.x += chunk_size
		if local_pos.y < 0: local_pos.y += chunk_size
		if local_pos.z < 0: local_pos.z += chunk_size
		var local_index := local_pos.x + local_pos.y * chunk_size + local_pos.z * chunk_size * chunk_size

		var batch: Dictionary = chunk_batches.get(chunk_coord, {})
		if batch.is_empty():
			batch = {
				"coord": chunk_coord,
				"indices": PackedInt32Array(),
				"types": PackedByteArray(),
				"metas": PackedByteArray()
			}
		var indices: PackedInt32Array = batch.get("indices", PackedInt32Array())
		var types: PackedByteArray = batch.get("types", PackedByteArray())
		var metas: PackedByteArray = batch.get("metas", PackedByteArray())
		indices.append(local_index)
		types.append(int(block_data.get("type", 0)))
		metas.append(int(block_data.get("meta", 0)))
		batch["indices"] = indices
		batch["types"] = types
		batch["metas"] = metas
		chunk_batches[chunk_coord] = batch

	var batches: Array = []
	for chunk_coord_variant in chunk_batches.keys():
		batches.append(chunk_batches[chunk_coord_variant])
	return batches

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
	
	# World map mode: spawn baked buildings from world_meta.json
	if terrain_manager and "world_map_active" in terrain_manager and terrain_manager.world_map_active:
		_spawn_baked_buildings(coord)
		return
	
	# Procedural mode: check for road intersections in this chunk
	var chunk_world_x = coord.x * 31 # CHUNK_STRIDE
	var chunk_world_z = coord.z * 31 # Use .z for Z coordinate (Vector3i)
	
	_check_and_spawn_buildings(chunk_world_x, chunk_world_z)

## Spawn pre-baked buildings from the world map generator.
## Buildings whose XZ falls within this chunk's bounds are spawned unconditionally.
## Uses the baked Y estimate from the world map generator.
## World map mode is already flattened at generation time, so we avoid any
## runtime carving here to keep the map sealed and the spawn position exact.
func _spawn_baked_buildings(coord: Vector3i):
	if not terrain_manager or not "_world_map_buildings" in terrain_manager:
		return

	var chunk_stride = 31
	var chunk_x = coord.x * chunk_stride
	var chunk_z = coord.z * chunk_stride
	var queued_count := 0

	if building_manager and not building_manager.world_map_mode:
		building_manager.world_map_mode = true
		# Town entry is the critical path: keep the spawn/rebuild batches smaller
		# so the loading work stays spread out instead of clustering into spikes.
		if building_manager.has_variable("dirty_chunk_flush_budget") and building_manager.dirty_chunk_flush_budget < 1:
			building_manager.dirty_chunk_flush_budget = 1
		if spawn_processing_budget_ms < 1.0:
			spawn_processing_budget_ms = 1.0

	for bldg in terrain_manager._world_map_buildings:
		var bx = float(bldg.get("x", 0))
		var bz = float(bldg.get("z", 0))
		var by = float(bldg.get("y", 12))
		var btype = str(bldg.get("type", "small_house"))

		# Check if this building falls within this chunk
		if bx >= chunk_x and bx < chunk_x + chunk_stride \
			and bz >= chunk_z and bz < chunk_z + chunk_stride:
			var key = "baked_%d_%d" % [int(bx), int(bz)]
			if spawned_positions.has(key):
				continue

			# Use the baked Y exactly. The generator has already flattened the lot
			# and baked the final height, so runtime height probing can only drift.
			by = floor(by)
			var rot = int(bldg.get("rotation", 0))
			var spawn_pos = Vector3(
				float(bldg.get("spawn_origin_x", bx)),
				float(bldg.get("spawn_origin_y", by)),
				float(bldg.get("spawn_origin_z", bz))
			)
			if not bldg.has("spawn_origin_x"):
				spawn_pos = PrefabGeometry.get_spawn_origin_for_occupied_min(btype, Vector3(bx, by, bz), rot)
			var spawn_key = "baked_%d_%d" % [int(bx), int(bz)]
			_queue_spawn_job(spawn_key, {
				"prefab_name": btype,
				"world_pos": spawn_pos,
				"submerge_offset": 0,
				"rotation": rot,
				"carve_terrain": false,
				"skip_blocks": false,
				"interior_carve": false,
				"clear_vegetation": false
			})
			queued_count += 1

	PerformanceMonitor.capture_scope_state("buildings", {
		"phase": "baked_queue",
		"pending_spawn_jobs": pending_spawn_jobs.size(),
		"queued_in_chunk": queued_count
	})

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
			
			# Use procedural road height for exact road alignment
			var terrain_y = floor(get_procedural_road_height(spawn_x, spawn_z))
			if terrain_y <= 0:
				terrain_y = 12.0 # Fallback
			
			# Place floor at terrain level
			var spawn_pos = Vector3(spawn_x, terrain_y, spawn_z)

			_queue_spawn_job(key, {
				"prefab_name": "small_house",
				"world_pos": spawn_pos,
				"submerge_offset": 1,
				"rotation": 0,
				"carve_terrain": false,
				"skip_blocks": false,
				"interior_carve": false,
				"clear_vegetation": true
			})

func _get_terrain_height(x: float, z: float) -> float:
	if terrain_manager and terrain_manager.has_method("get_terrain_height"):
		return terrain_manager.get_terrain_height(x, z)
	return -1.0

# === PROCEDURAL ROAD SYNC (Matching gen_density.glsl) ===

func _fract(x: float) -> float:
	return x - floor(x)

func _procedural_hash(p: Vector3) -> float:
	var h = Vector3(
		_fract(p.x * 0.3183099 + 0.1),
		_fract(p.y * 0.3183099 + 0.1),
		_fract(p.z * 0.3183099 + 0.1)
	)
	h *= 17.0
	return _fract(h.x * h.y * h.z * (h.x + h.y + h.z))

func _procedural_noise(p: Vector3) -> float:
	var i = Vector3(floor(p.x), floor(p.y), floor(p.z))
	var f = Vector3(_fract(p.x), _fract(p.y), _fract(p.z))
	
	# Hermite interpolation f = f*f*(3-2*f)
	var f_interp = Vector3(
		f.x * f.x * (3.0 - 2.0 * f.x),
		f.y * f.y * (3.0 - 2.0 * f.y),
		f.z * f.z * (3.0 - 2.0 * f.z)
	)
	
	var h000 = _procedural_hash(i + Vector3(0,0,0))
	var h100 = _procedural_hash(i + Vector3(1,0,0))
	var h010 = _procedural_hash(i + Vector3(0,1,0))
	var h110 = _procedural_hash(i + Vector3(1,1,0))
	var h001 = _procedural_hash(i + Vector3(0,0,1))
	var h101 = _procedural_hash(i + Vector3(1,0,1))
	var h011 = _procedural_hash(i + Vector3(0,1,1))
	var h111 = _procedural_hash(i + Vector3(1,1,1))
	
	return lerp(
		lerp(lerp(h000, h100, f_interp.x), lerp(h010, h110, f_interp.x), f_interp.y),
		lerp(lerp(h001, h101, f_interp.x), lerp(h011, h111, f_interp.x), f_interp.y),
		f_interp.z
	)

## Returns the exact procedural road height at a given world X,Z
func get_procedural_road_height(x: float, z: float) -> float:
	if road_spacing <= 0:
		return 0.0
	
	var cell_x = floor(x / road_spacing)
	var cell_z = floor(z / road_spacing)
	
	var local_x = fmod(x, road_spacing)
	if local_x < 0: local_x += road_spacing
	var local_z = fmod(z, road_spacing)
	if local_z < 0: local_z += road_spacing
	
	# Match shader noise scale 0.008 and amplitude 3.0 + 12.0 base
	var h1 = _procedural_noise(Vector3(cell_x * road_spacing, 0.0, cell_z * road_spacing) * 0.008) * 3.0 + 12.0
	var h2 = _procedural_noise(Vector3((cell_x + 1.0) * road_spacing, 0.0, cell_z * road_spacing) * 0.008) * 3.0 + 12.0
	var h3 = _procedural_noise(Vector3(cell_x * road_spacing, 0.0, (cell_z + 1.0) * road_spacing) * 0.008) * 3.0 + 12.0
	var h4 = _procedural_noise(Vector3((cell_x + 1.0) * road_spacing, 0.0, (cell_z + 1.0) * road_spacing) * 0.008) * 3.0 + 12.0
	
	var tx = local_x / road_spacing
	var tz = local_z / road_spacing
	var interp_h = lerp(lerp(h1, h2, tx), lerp(h3, h4, tx), tz)
	
	# Stepped road logic (matching shader)
	var base_level = floor(interp_h)
	var frac = interp_h - base_level
	var flat_size = 0.45
	
	if frac < flat_size:
		return base_level
	elif frac > 1.0 - flat_size:
		return base_level + 1.0
	else:
		var ramp_t = (frac - flat_size) / (1.0 - 2.0 * flat_size)
		# smoothstep ramp_t = t * t * (3.0 - 2.0 * t)
		ramp_t = ramp_t * ramp_t * (3.0 - 2.0 * ramp_t)
		return base_level + ramp_t


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
	if not building_manager.has_method("has_dirty_visible_chunks") or building_manager.has_dirty_visible_chunks():
		building_manager.flush_dirty_chunks()
	else:
		PerformanceMonitor.capture_scope_event("buildings", "chunk_flush_skipped", {
			"prefab": prefab_name,
			"reason": "hidden_only"
		})
	
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
	clear_pending_spawn_jobs()

# ============ USER PREFAB SUPPORT ============

const USER_PREFAB_DIR = "user://world_prefabs/"
const RES_PREFAB_DIR = "res://world_prefabs/"

## Load all user prefabs from res://world_prefabs/ and user://world_prefabs/
func load_user_prefabs():
	var count = 0
	
	for dir_path in [RES_PREFAB_DIR, USER_PREFAB_DIR]:
		if DirAccess.dir_exists_absolute(dir_path):
			var dir = DirAccess.open(dir_path)
			if dir:
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
		DebugManager.log_building("Loaded %d custom JSON prefabs" % count)

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
		var parsed_objects := _parse_compact_objects(data.objects)
		get_meta("prefab_objects")[prefab_name] = parsed_objects
		if not has_meta("prefab_objects_sorted"):
			set_meta("prefab_objects_sorted", {})
		var sorted_objects := parsed_objects.duplicate()
		sorted_objects.sort_custom(Callable(self, "_sort_world_map_prefab_object_spawn"))
		get_meta("prefab_objects_sorted")[prefab_name] = sorted_objects

	var validation := PrefabGeometry.get_prefab_validation(prefab_name)
	if not bool(validation.get("valid_for_spawn", true)):
		DebugManager.log_building("[PrefabValidation] '%s' has errors: %s" % [
			prefab_name,
			"; ".join(validation.get("errors", []))
		])
	else:
		var warnings: Array = validation.get("warnings", [])
		if warnings.is_empty():
			DebugManager.log_building("Loaded prefab '%s' with %d blocks" % [prefab_name, blocks.size()])
			return true
		DebugManager.log_building("[PrefabValidation] '%s' warnings: %s" % [
			prefab_name,
			"; ".join(warnings)
		])

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
			var object_id := int(obj[0])
			var object_name := str(object_id)
			var object_scene_path := ""
			var object_size := Vector3i.ONE
			var has_authored_collision := false
			var has_authored_collision_valid := false
			var object_def := ObjectRegistry.get_object(object_id) if object_id >= 0 else {}
			if not object_def.is_empty():
				object_name = str(object_def.get("name", object_name))
				object_scene_path = str(object_def.get("scene", ""))
				object_size = object_def.get("size", Vector3i.ONE)
				has_authored_collision = bool(object_def.get("has_authored_collision", ObjectRegistry.get_object_has_authored_collision(object_id)))
				has_authored_collision_valid = true
			result.append({
				"offset": [obj[1], obj[2], obj[3]],
				"object_id": object_id,
				"rotation": obj[4],
				"fractional_y": obj[5] if obj.size() > 5 else 0.0,
				"object_name": object_name,
				"scene_path": object_scene_path,
				"object_size": object_size,
				"has_authored_collision": has_authored_collision,
				"has_authored_collision_valid": has_authored_collision_valid
			})
	return result

## Spawn a user prefab at the given world position
## submerge_offset: how many blocks to bury into terrain (negative Y adjustment)
## rotation: 0-3 for 0°, 90°, 180°, 270° rotation
## carve_terrain: if true, carve out terrain where submerged blocks go
## foundation_fill: [REMOVED]
## skip_blocks: if true, only perform terrain operations (carve/fill) without placing blocks
## interior_carve: if true, carve terrain at block positions that intersect with terrain
func spawn_user_prefab(prefab_name: String, world_pos: Vector3, submerge_offset: int = 1, rotation: int = 0, carve_terrain: bool = false, skip_blocks: bool = false, interior_carve: bool = false, clear_vegetation: bool = true, flush_chunks: bool = true, flush_visual_batches: bool = true, object_start_index: int = 0, resume_objects_only: bool = false) -> bool:
	if skip_carving_for_test:
		carve_terrain = false
		interior_carve = false
	var is_object_resume := resume_objects_only or object_start_index > 0
	if is_object_resume:
		carve_terrain = false
		skip_blocks = true
		interior_carve = false
		clear_vegetation = false
	var world_map_mode := bool(building_manager and building_manager.world_map_mode)
	PerformanceMonitor.start_measure("Prefab: " + prefab_name)
	if not world_map_mode:
		PerformanceMonitor.capture_scope_event("buildings", "spawn_requested", {
			"prefab": prefab_name,
			"world_pos": str(world_pos),
			"rotation": rotation,
			"carve_terrain": carve_terrain,
			"skip_carving_for_test": skip_carving_for_test,
			"skip_blocks": skip_blocks,
			"interior_carve": interior_carve
		})
	# Try to load if not already loaded
	if not prefabs.has(prefab_name):
		PerformanceMonitor.start_measure("Prefab Load: " + prefab_name)
		if not load_prefab_from_file(prefab_name):
			PerformanceMonitor.capture_scope_event("buildings", "load_failed", {
				"prefab": prefab_name
			})
			PerformanceMonitor.end_measure("Prefab Load: " + prefab_name, 1.0)
			PerformanceMonitor.end_measure("Prefab: " + prefab_name, 10.0)
			return false
		PerformanceMonitor.end_measure("Prefab Load: " + prefab_name, 1.0)
	
	# Use default submerge of 1 for carve mode (prefabs no longer store this value)
	if carve_terrain:
		submerge_offset = 1

	var placement_profile := PrefabGeometry.get_placement_profile(prefab_name)
	if world_map_mode:
		# Baked towns already had their lots prepared by the world generator.
		# Skipping runtime carve avoids paying the same excavation cost again
		# during the town-entry burst.
		carve_terrain = false
		interior_carve = false
	elif bool(placement_profile.get("auto_carve_volume", false)):
		interior_carve = true
	var rotated_bounds := PrefabGeometry.get_rotated_bounds(prefab_name, rotation)
	var precise_carve_segments := PrefabGeometry.get_rotated_excavation_segments(prefab_name, rotation)
	var min_offset: Vector3i = rotated_bounds.get("min", Vector3i.ZERO)
	var max_offset: Vector3i = rotated_bounds.get("max", Vector3i.ZERO)

	# Adjust Y to submerge into terrain
	var spawn_pos = world_pos - Vector3(0, submerge_offset, 0)
	
	# Clear vegetation
	if clear_vegetation:
		var veg_mgr = _get_vegetation_manager()
		if veg_mgr and veg_mgr.has_method("clear_vegetation_in_area"):
			veg_mgr.clear_vegetation_in_area(spawn_pos, 10.0)

	var blocks = prefabs[prefab_name]
	PerformanceMonitor.capture_scope_state("buildings", {
		"prefab": prefab_name,
		"world_pos": str(world_pos),
		"spawn_pos": str(spawn_pos),
		"rotation": rotation,
		"submerge_offset": submerge_offset,
		"carve_terrain": carve_terrain,
		"skip_blocks": skip_blocks,
		"interior_carve": interior_carve,
		"block_count": blocks.size(),
		"chunk_batch_mode": bool(building_manager and building_manager.world_map_mode)
	})
	var carved_terrain := false
	var carve_elapsed_ms := 0.0
	
	# Carve terrain for submerged blocks (only in carve mode)
	if carve_terrain:
		var carve_start_us := Time.get_ticks_usec()
		PerformanceMonitor.start_measure("Prefab Carve")
		carved_terrain = true
		if _can_use_column_terrain_ops():
			_carve_submerged_block_columns(blocks, spawn_pos, rotation, world_pos.y)
		else:
			for block in blocks:
				var offset = block.offset
				var rotated_offset = _rotate_offset(offset, rotation)
				var pos = spawn_pos + Vector3(rotated_offset)
				
				# If this block is at or below terrain surface, carve it out
				if pos.y <= world_pos.y:
						if terrain_manager and terrain_manager.has_method("modify_terrain"):
							# Dig a small box at this position (shape 1 = box, value > 0 = dig)
							terrain_manager.modify_terrain(pos + Vector3(0.5, 0.5, 0.5), 0.6, 1.0, 1, 0)
		carve_elapsed_ms = float(Time.get_ticks_usec() - carve_start_us) / 1000.0
	# Full-volume carve: clear ALL terrain within the building's bounding box
	# This prevents terrain from poking through walls, floors, or windows.
	if interior_carve:
		var interior_carve_start_us := Time.get_ticks_usec()
		if not carved_terrain:
			PerformanceMonitor.start_measure("Prefab Carve")
			carved_terrain = true
		var carve_count := 0
		var used_precise_carve := false
		if not precise_carve_segments.is_empty():
			used_precise_carve = true
			if _can_use_column_terrain_ops():
				carve_count = _carve_precise_segments_columns(spawn_pos, precise_carve_segments)
			elif terrain_manager and terrain_manager.has_method("modify_terrain"):
				for segment in precise_carve_segments:
					var world_x: float = spawn_pos.x + float(segment.get("x", 0)) + 0.5
					var world_z: float = spawn_pos.z + float(segment.get("z", 0)) + 0.5
					var min_y: int = int(segment.get("min_y", 0))
					var max_y: int = int(segment.get("max_y", -1))
					for cy in range(min_y, max_y + 1):
						var carve_pos := Vector3(world_x, spawn_pos.y + float(cy) + 0.5, world_z)
						terrain_manager.modify_terrain(carve_pos, 0.6, 1.0, 1, 0)
						carve_count += 1
		elif _can_use_column_terrain_ops():
			carve_count = _carve_prefab_volume_columns(spawn_pos, min_offset, max_offset, submerge_offset)
		elif terrain_manager and terrain_manager.has_method("modify_terrain"):
			# Carve every position inside the bounding box where terrain exists
			for cx in range(min_offset.x, max_offset.x + 1):
				for cz in range(min_offset.z, max_offset.z + 1):
					var pos = spawn_pos + Vector3(cx, 0, cz)
					var terrain_y = _get_terrain_height(pos.x + 0.5, pos.z + 0.5)
					if terrain_y <= 0:
						continue
					# Carve from ground floor to terrain surface (or ceiling, whichever is lower)
					# Start carving from submerge_offset so we don't hollow out the dirt holding up the foundation!
					var y_start = max(min_offset.y, submerge_offset)
					var y_end = min(max_offset.y, int(terrain_y - spawn_pos.y) + 1)
					for cy in range(y_start, y_end + 1):
						var carve_pos = spawn_pos + Vector3(float(cx) + 0.5, float(cy) + 0.5, float(cz) + 0.5)
						terrain_manager.modify_terrain(carve_pos, 0.6, 1.0, 1, 0)
						carve_count += 1
		if used_precise_carve:
			DebugManager.log_building("[PreciseCarve] Carved %d columns for '%s'" % [carve_count, prefab_name])
		else:
			DebugManager.log_building("[FullCarve] Carved %d columns for '%s' (box: %v to %v)" % [carve_count, prefab_name, min_offset, max_offset])
		carve_elapsed_ms += float(Time.get_ticks_usec() - interior_carve_start_us) / 1000.0
	if carved_terrain:
		PerformanceMonitor.end_measure("Prefab Carve", 5.0)
	
	# Skip block/object spawning if requested (used for carve-only step in Carve+Fill mode)
	if skip_blocks:
		var mode_str = "carve-only" if carve_terrain else "fill-only"
		DebugManager.log_building("Terrain-only operation '%s' at %v (submerge: %d, mode: %s)" % [prefab_name, spawn_pos, submerge_offset, mode_str])
		PerformanceMonitor.end_measure("Prefab: " + prefab_name, 10.0)
		PerformanceMonitor.capture_scope_event("buildings", "spawn_complete", {
			"prefab": prefab_name,
			"mode": mode_str,
			"carved_terrain": carved_terrain,
			"carve_elapsed_ms": carve_elapsed_ms,
			"block_count": blocks.size()
		})
		return true
	
	# Spawn blocks with rotation.
	# World map mode uses chunk-grouped batches so town spawning does less
	# per-block dictionary churn and chunk bookkeeping on the main thread.
	var block_placement_elapsed_ms := 0.0
	var block_pack_elapsed_ms := 0.0
	var block_apply_elapsed_ms := 0.0
	if not skip_block_placement_for_test:
		var block_start_us := Time.get_ticks_usec()
		PerformanceMonitor.start_measure("Prefab Block Placement")
		if building_manager and building_manager.world_map_mode:
			var chunk_batches: Array = []
			var mesher = building_manager.mesher if building_manager else null
			PerformanceMonitor.start_measure("Prefab Block Pack")
			if mesher and mesher.has_method("pack_rotated_world_map_block_batches"):
				chunk_batches = mesher.pack_rotated_world_map_block_batches(blocks, rotation, spawn_pos, BUILDING_CHUNK_SIZE)
			elif mesher and mesher.has_method("pack_world_map_block_batches"):
				var rotated_blocks: Array = _get_rotated_block_batches(prefab_name, rotation)
				chunk_batches = mesher.pack_world_map_block_batches(rotated_blocks, spawn_pos, BUILDING_CHUNK_SIZE)
			else:
				var rotated_blocks_fallback: Array = _get_rotated_block_batches(prefab_name, rotation)
				chunk_batches = _pack_world_map_block_batches_from_rotated_blocks(rotated_blocks_fallback, spawn_pos, BUILDING_CHUNK_SIZE)
			PerformanceMonitor.end_measure("Prefab Block Pack", 5.0)
			block_pack_elapsed_ms = float(Time.get_ticks_usec() - block_start_us) / 1000.0

			var block_apply_start_us := Time.get_ticks_usec()
			PerformanceMonitor.start_measure("Prefab Block Apply")
			for batch_variant in chunk_batches:
				var batch: Dictionary = batch_variant
				var chunk_coord_variant: Variant = batch.get("coord", Vector3i.ZERO)
				var chunk_coord: Vector3i = chunk_coord_variant
				var chunk: BuildingChunk = building_manager.get_chunk(chunk_coord)
				chunk.apply_voxel_batch_indices(
					batch.get("indices", PackedInt32Array()),
					batch.get("types", PackedByteArray()),
					batch.get("metas", PackedByteArray())
				)
				building_manager.mark_chunk_dirty(chunk_coord, chunk)
			PerformanceMonitor.end_measure("Prefab Block Apply", 5.0)
			block_apply_elapsed_ms = float(Time.get_ticks_usec() - block_apply_start_us) / 1000.0
		else:
			for block in blocks:
				var offset: Vector3i = block.offset
				var rotated_offset: Vector3i = _rotate_offset(offset, rotation)
				var block_type: int = int(block.type)
				var block_meta: int = int(block.get("meta", 0))

				# Rotate meta for directional blocks (stairs type=4, ramps type=2 with metas 1-3)
				# Meta values 0-3 represent directions that need to rotate with the prefab
				if block_type == 4 or (block_type == 2 and block_meta >= 1 and block_meta <= 3):
					block_meta = (block_meta + rotation) % 4

				var pos: Vector3 = spawn_pos + Vector3(rotated_offset)
				building_manager.set_voxel_batched(pos, block_type, block_meta)
			PerformanceMonitor.end_measure("Prefab Block Placement", 5.0)
			block_placement_elapsed_ms = float(Time.get_ticks_usec() - block_start_us) / 1000.0
	else:
		PerformanceMonitor.capture_scope_event("buildings", "spawn_block_placement_skipped", {
			"prefab": prefab_name,
			"reason": "test_toggle"
		})
	
	# Spawn objects if any
	var prefab_object_count: int = 0
	var direct_scene_count: int = 0
	var object_spawn_elapsed_ms := 0.0
	var seal_elapsed_ms := 0.0
	var chunk_flush_elapsed_ms := 0.0
	var slow_object_spawns: Array = []
	var collect_object_telemetry := false
	var object_mix_counts: Dictionary = {}
	var defer_global_visual_batch_rebuild := bool(building_manager and building_manager.world_map_mode)
	if not skip_object_spawns_for_test and has_meta("prefab_objects"):
		var objects_data = get_meta("prefab_objects")
		if objects_data.has(prefab_name):
			var object_start_us := Time.get_ticks_usec()
			PerformanceMonitor.start_measure("Prefab Objects")
			var use_world_map_mode := bool(building_manager and building_manager.world_map_mode)
			collect_object_telemetry = not use_world_map_mode
			var prefab_objects: Array = objects_data[prefab_name]
			if use_world_map_mode and has_meta("prefab_objects_sorted"):
				var sorted_objects_data = get_meta("prefab_objects_sorted")
				if sorted_objects_data.has(prefab_name):
					prefab_objects = sorted_objects_data[prefab_name]
			for obj_index in range(object_start_index, prefab_objects.size()):
				var obj: Dictionary = prefab_objects[obj_index]
				var obj_start_us := Time.get_ticks_usec()
				prefab_object_count += 1
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

				var obj_rotation = combined_rot
				var object_id := -1
				var object_name := ""
				var object_scene_path := ""
				# Use object_id if available, otherwise try to load scene directly
				if obj.has("object_id"):
					object_id = int(obj.object_id)
					object_name = str(obj.get("object_name", "Object %d" % object_id))
					object_scene_path = str(obj.get("scene_path", ""))
				elif obj.has("scene") and obj.scene != "":
					object_scene_path = obj.scene
					object_name = object_scene_path
					obj_rotation = int(obj.get("rotation_y", 0)) + (rotation * 90)

				# Use object_id if available, otherwise try to load scene directly
				var obj_elapsed_ms := 0.0
				if object_id >= 0:
					if collect_object_telemetry:
						var object_mix_key := "object:%d" % object_id
						var object_mix_entry: Dictionary = object_mix_counts.get(object_mix_key, {
							"kind": "object_id",
							"object_id": object_id,
							"object_name": object_name,
							"scene_path": object_scene_path,
							"count": 0
						})
						object_mix_entry["count"] = int(object_mix_entry.get("count", 0)) + 1
						object_mix_counts[object_mix_key] = object_mix_entry
					var object_size: Vector3i = obj.get("object_size", Vector3i.ONE)
					var has_authored_collision := bool(obj.get("has_authored_collision", false))
					var has_authored_collision_valid := bool(obj.get("has_authored_collision_valid", false))
					var precomputed_cells: Array = []
					if object_id >= 0:
						precomputed_cells = ObjectRegistry.get_occupied_cells(object_id, Vector3i.ZERO, obj_rotation)
					if not building_manager.place_object(obj_pos, object_id, obj_rotation, true, true, defer_global_visual_batch_rebuild, precomputed_cells, object_size, object_scene_path, has_authored_collision, has_authored_collision_valid):
						# print("DEBUG_MISSING_OBJ: Failed to place object_id %d at %v (Rotation %d)" % [obj.object_id, obj_pos, combined_rot])
						pass
				elif object_scene_path != "":
					direct_scene_count += 1
					if collect_object_telemetry:
						var scene_mix_key := "scene:%s" % object_scene_path
						var scene_mix_entry: Dictionary = object_mix_counts.get(scene_mix_key, {
							"kind": "scene",
							"scene_path": object_scene_path,
							"count": 0
						})
						scene_mix_entry["count"] = int(scene_mix_entry.get("count", 0)) + 1
						object_mix_counts[scene_mix_key] = scene_mix_entry
					_spawn_scene_at(object_scene_path, obj_pos, obj_rotation)
				if collect_object_telemetry:
					obj_elapsed_ms = float(Time.get_ticks_usec() - obj_start_us) / 1000.0
					if obj_elapsed_ms >= 0.1:
						slow_object_spawns.append({
							"elapsed_ms": obj_elapsed_ms,
							"object_name": object_name if object_id != -1 else object_scene_path,
							"object_id": object_id,
							"scene_path": object_scene_path,
							"rotation": obj_rotation,
							"world_pos": str(obj_pos)
						})
			PerformanceMonitor.end_measure("Prefab Objects", 5.0)
			if flush_visual_batches and defer_global_visual_batch_rebuild and building_manager and building_manager.has_method("flush_global_visual_batches"):
				building_manager.flush_global_visual_batches()
			object_spawn_elapsed_ms = float(Time.get_ticks_usec() - object_start_us) / 1000.0

	if not skip_blocks and not skip_block_placement_for_test and _should_seal_prefab_foundation(placement_profile):
		var seal_start_us := Time.get_ticks_usec()
		PerformanceMonitor.start_measure("Prefab Seal")
		var sealed_columns := _seal_prefab_foundation(prefab_name, spawn_pos, placement_profile, min_offset, max_offset)
		PerformanceMonitor.end_measure("Prefab Seal", 1.0)
		seal_elapsed_ms = float(Time.get_ticks_usec() - seal_start_us) / 1000.0
		if sealed_columns > 0:
			DebugManager.log_building("[FoundationSeal] Sealed %d columns for '%s'" % [sealed_columns, prefab_name])

	if flush_chunks and building_manager:
		if skip_chunk_flush_for_test:
			PerformanceMonitor.capture_scope_event("buildings", "chunk_flush_skipped", {
				"prefab": prefab_name,
				"reason": "test_toggle"
			})
		elif building_manager.has_method("has_dirty_visible_chunks") and not building_manager.has_dirty_visible_chunks():
			PerformanceMonitor.capture_scope_event("buildings", "chunk_flush_skipped", {
				"prefab": prefab_name,
				"reason": "hidden_only"
			})
		else:
			var flush_start_us := Time.get_ticks_usec()
			PerformanceMonitor.start_measure("Prefab Chunk Flush")
			building_manager.flush_dirty_chunks()
			PerformanceMonitor.end_measure("Prefab Chunk Flush", 5.0)
			chunk_flush_elapsed_ms = float(Time.get_ticks_usec() - flush_start_us) / 1000.0
	
	var mode_str = "carve" if carve_terrain else "surface"
	DebugManager.log_building("Spawned user prefab '%s' at %v (submerge: %d, mode: %s)" % [prefab_name, spawn_pos, submerge_offset, mode_str])
	PerformanceMonitor.end_measure("Prefab: " + prefab_name, 10.0)
	var spawn_complete_event := {
		"prefab": prefab_name,
		"carved_terrain": carved_terrain,
		"carve_elapsed_ms": carve_elapsed_ms,
		"block_count": blocks.size(),
		"object_count": prefab_object_count,
		"unique_object_kinds": object_mix_counts.size() if collect_object_telemetry else 0,
		"direct_scene_count": direct_scene_count,
		"block_placement_elapsed_ms": block_placement_elapsed_ms,
		"block_pack_elapsed_ms": block_pack_elapsed_ms,
		"block_apply_elapsed_ms": block_apply_elapsed_ms,
		"object_spawn_elapsed_ms": object_spawn_elapsed_ms,
		"seal_elapsed_ms": seal_elapsed_ms,
		"chunk_flush_elapsed_ms": chunk_flush_elapsed_ms,
		"slowest_object_spawns": _build_top_slow_object_spawns(slow_object_spawns, 5) if collect_object_telemetry else [],
		"top_object_mix": _build_top_object_mix_summary(object_mix_counts, 5) if collect_object_telemetry else []
	}
	if not world_map_mode:
		PerformanceMonitor.capture_scope_event("buildings", "spawn_complete", spawn_complete_event)
	return true

func _can_use_column_terrain_ops() -> bool:
	return terrain_manager and terrain_manager.has_method("fill_column")

func _is_world_map_mode() -> bool:
	return terrain_manager and "world_map_active" in terrain_manager and terrain_manager.world_map_active

func _carve_submerged_block_columns(blocks: Array, spawn_pos: Vector3, rotation: int, surface_y: float) -> int:
	var columns: Dictionary = {}
	for block in blocks:
		var rotated_offset = _rotate_offset(block.offset, rotation)
		var world_x: int = int(floor(spawn_pos.x)) + rotated_offset.x
		var world_y: int = int(floor(spawn_pos.y)) + rotated_offset.y
		var world_z: int = int(floor(spawn_pos.z)) + rotated_offset.z
		if float(world_y) > surface_y:
			continue
		var key := Vector2i(world_x, world_z)
		if not columns.has(key):
			columns[key] = {
				"min_y": world_y,
				"max_y": world_y
			}
			continue
		var entry: Dictionary = columns[key]
		entry["min_y"] = mini(int(entry.get("min_y", world_y)), world_y)
		entry["max_y"] = maxi(int(entry.get("max_y", world_y)), world_y)
		columns[key] = entry

	for key in columns:
		var info: Dictionary = columns[key]
		terrain_manager.fill_column(
			float(key.x) + 0.5,
			float(key.y) + 0.5,
			float(info.get("min_y", 0)),
			float(info.get("max_y", 0)) + 1.0,
			TERRAIN_DIG_AIR_DENSITY,
			0
		)
	return columns.size()

func _carve_prefab_volume_columns(spawn_pos: Vector3, min_offset: Vector3i, max_offset: Vector3i, submerge_offset: int) -> int:
	var carve_count := 0
	for cx in range(min_offset.x, max_offset.x + 1):
		for cz in range(min_offset.z, max_offset.z + 1):
			var world_x = int(floor(spawn_pos.x)) + cx
			var world_z = int(floor(spawn_pos.z)) + cz
			var terrain_y = _get_terrain_height(float(world_x) + 0.5, float(world_z) + 0.5)
			if terrain_y <= 0:
				continue
			var y_start = max(min_offset.y, submerge_offset)
			var y_end = min(max_offset.y, int(floor(terrain_y - spawn_pos.y)) + 1)
			if y_end < y_start:
				continue
			terrain_manager.fill_column(
				float(world_x) + 0.5,
				float(world_z) + 0.5,
				spawn_pos.y + float(y_start),
				spawn_pos.y + float(y_end) + 1.0,
				TERRAIN_DIG_AIR_DENSITY,
				0
			)
			carve_count += 1
	return carve_count

func _carve_precise_segments_columns(spawn_pos: Vector3, carve_segments: Array) -> int:
	var carve_count := 0
	for segment in carve_segments:
		var world_x: int = int(floor(spawn_pos.x)) + int(segment.get("x", 0))
		var world_z: int = int(floor(spawn_pos.z)) + int(segment.get("z", 0))
		var min_y := int(segment.get("min_y", 0))
		var max_y := int(segment.get("max_y", -1))
		if max_y < min_y:
			continue
		terrain_manager.fill_column(
			float(world_x) + 0.5,
			float(world_z) + 0.5,
			spawn_pos.y + float(min_y),
			spawn_pos.y + float(max_y) + 1.0,
			TERRAIN_DIG_AIR_DENSITY,
			0
		)
		carve_count += 1
	return carve_count

func _should_seal_prefab_foundation(placement_profile: Dictionary) -> bool:
	if not _can_use_column_terrain_ops():
		return false
	if _is_world_map_mode():
		return false
	return bool(placement_profile.get("seal_foundation", true))

func _seal_prefab_foundation(prefab_name: String, spawn_pos: Vector3, placement_profile: Dictionary,
		min_offset: Vector3i, max_offset: Vector3i) -> int:
	var max_gap := float(placement_profile.get("max_foundation_gap", 3.0))
	if max_gap <= 0.0:
		return 0

	var grade_world_y = spawn_pos.y + float(placement_profile.get("grade_y", 0))
	var outer_min_x = min_offset.x - 1
	var outer_max_x = max_offset.x + 1
	var outer_min_z = min_offset.z - 1
	var outer_max_z = max_offset.z + 1
	var filled_columns := 0

	for local_z in range(outer_min_z, outer_max_z + 1):
		for local_x in range(outer_min_x, outer_max_x + 1):
			var on_ring = (
				local_x == outer_min_x or local_x == outer_max_x or
				local_z == outer_min_z or local_z == outer_max_z
			)
			if not on_ring:
				continue
			var world_x = int(floor(spawn_pos.x)) + local_x
			var world_z = int(floor(spawn_pos.z)) + local_z
			var terrain_y = _get_terrain_height(float(world_x) + 0.5, float(world_z) + 0.5)
			if terrain_y <= 0.0:
				continue
			var gap = grade_world_y - terrain_y
			if gap <= 0.05 or gap > max_gap:
				continue
			terrain_manager.fill_column(
				float(world_x) + 0.5,
				float(world_z) + 0.5,
				terrain_y,
				grade_world_y,
				-0.8,
				0
			)
			filled_columns += 1
	return filled_columns


func _spawn_scene_at(scene_path: String, pos: Vector3, rotation_y: float):
	var packed = ObjectRegistry.get_preloaded_scene(scene_path)
	if not packed:
		return
	
	PerformanceMonitor.start_measure("Prefab Scene Spawn")
	var instance = packed.instantiate()
	add_child(instance)
	instance.global_position = pos
	instance.rotation_degrees.y = rotation_y
	PerformanceMonitor.end_measure("Prefab Scene Spawn", 0.5)

func _build_top_object_mix_summary(object_mix_counts: Dictionary, limit: int = 5) -> Array:
	var entries: Array = []
	for key in object_mix_counts:
		var entry: Dictionary = object_mix_counts[key]
		entries.append({
			"kind": entry.get("kind", "object_id"),
			"object_id": entry.get("object_id", -1),
			"object_name": entry.get("object_name", ""),
			"scene_path": entry.get("scene_path", ""),
			"count": int(entry.get("count", 0))
		})
	entries.sort_custom(Callable(self, "_sort_object_mix_desc"))
	if entries.size() > limit:
		entries.resize(limit)
	return entries

func _build_top_slow_object_spawns(entries: Array, limit: int = 5) -> Array:
	if entries.is_empty():
		return []
	entries.sort_custom(Callable(self, "_sort_slow_object_spawn_desc"))
	if entries.size() > limit:
		entries.resize(limit)
	return entries

func _sort_slow_object_spawn_desc(a: Dictionary, b: Dictionary) -> bool:
	var a_ms := float(a.get("elapsed_ms", 0.0))
	var b_ms := float(b.get("elapsed_ms", 0.0))
	if a_ms == b_ms:
		return str(a.get("object_name", "")) < str(b.get("object_name", ""))
	return a_ms > b_ms

func _sort_object_mix_desc(a: Dictionary, b: Dictionary) -> bool:
	var a_count := int(a.get("count", 0))
	var b_count := int(b.get("count", 0))
	if a_count == b_count:
		return str(a.get("object_name", a.get("scene_path", ""))) < str(b.get("object_name", b.get("scene_path", "")))
	return a_count > b_count

func _sort_world_map_prefab_object_spawn(a: Dictionary, b: Dictionary) -> bool:
	var a_priority := _get_world_map_prefab_object_priority(a)
	var b_priority := _get_world_map_prefab_object_priority(b)
	if a_priority == b_priority:
		var a_name := str(a.get("object_name", a.get("scene", "")))
		var b_name := str(b.get("object_name", b.get("scene", "")))
		if a_name == b_name:
			var a_id := int(a.get("object_id", -1))
			var b_id := int(b.get("object_id", -1))
			return a_id < b_id
		return a_name < b_name
	return a_priority > b_priority

func _get_world_map_prefab_object_priority(obj: Dictionary) -> int:
	var object_id := int(obj.get("object_id", -1))
	match object_id:
		4:
			return 0 # Door
		5:
			return 1 # Window
		2:
			return 2 # Long Crate
		1:
			return 3 # Cardboard Box
		3:
			return 4 # Wooden Table
		6:
			return 5 # Heavy Pistol
		_:
			if object_id >= 0:
				return 10 + object_id
	var scene_path := str(obj.get("scene", ""))
	if scene_path != "":
		return 50
	return 100

func _sort_world_map_spawn_job_by_distance(a: Dictionary, b: Dictionary) -> bool:
	var a_dist := _get_world_map_spawn_job_distance_sq(a)
	var b_dist := _get_world_map_spawn_job_distance_sq(b)
	if a_dist == b_dist:
		var a_name := str(a.get("prefab_name", ""))
		var b_name := str(b.get("prefab_name", ""))
		if a_name == b_name:
			return str(a.get("spawn_key", "")) < str(b.get("spawn_key", ""))
		return a_name < b_name
	return a_dist > b_dist

func _get_world_map_spawn_job_distance_sq(job: Dictionary) -> float:
	var world_pos: Variant = job.get("world_pos", Vector3.ZERO)
	if typeof(world_pos) != TYPE_VECTOR3:
		return 0.0

	var origin := Vector3.ZERO
	if is_instance_valid(viewer):
		origin = viewer.global_position
	elif building_manager and building_manager.has_method("get_viewer_position"):
		origin = building_manager.get_viewer_position()
	return origin.distance_squared_to(world_pos)

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
