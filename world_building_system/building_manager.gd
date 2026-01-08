extends Node3D

# Maps Vector3i (Chunk Coord) -> BuildingChunk (data always persisted)
var chunks: Dictionary = {}
var mesher: BuildingMesher

# Render distance management
@export var viewer: Node3D
@export var render_distance: int = 8 # Increased for better visibility

# Track which chunks are currently visible (have nodes in scene tree)
var visible_chunks: Dictionary = {} # Vector3i -> true

# Chunk pool for recycling (multiplayer optimization)
var chunk_pool: Array[BuildingChunk] = []
const MAX_POOL_SIZE = 32 # Keep up to 32 chunks in pool

# Batched operations - accumulate changes, rebuild once
var _dirty_chunks: Dictionary = {} # Vector3i -> BuildingChunk (chunks needing rebuild)

const CHUNK_SIZE = 16 # Must match BuildingChunk.SIZE

func _ready():
	# Preload all object scenes for faster building spawning
	ObjectRegistry.preload_all_scenes()
	
	mesher = BuildingMesher.new()
	add_child(mesher)
	
	# Find player if not assigned
	if not viewer:
		viewer = get_tree().get_first_node_in_group("player")

func _process(_delta):
	if viewer:
		update_building_chunks()

## Gets effective viewer position - returns vehicle position if player is driving
func get_viewer_position() -> Vector3:
	if not viewer:
		return Vector3.ZERO
	
	# Check if player is in a vehicle
	var vm = get_tree().get_first_node_in_group("vehicle_manager")
	if vm and "current_player_vehicle" in vm and vm.current_player_vehicle:
		return vm.current_player_vehicle.global_position
	
	return viewer.global_position

func update_building_chunks():
	var p_pos = get_viewer_position()
	var p_chunk_x = floor(p_pos.x / CHUNK_SIZE)
	var p_chunk_y = floor(p_pos.y / CHUNK_SIZE)
	var p_chunk_z = floor(p_pos.z / CHUNK_SIZE)
	var center_chunk = Vector3i(p_chunk_x, p_chunk_y, p_chunk_z)
	
	# 1. Unload chunks that are too far (remove from scene tree, keep data)
	var chunks_to_unload = []
	for coord in visible_chunks:
		var dist = Vector3(coord).distance_to(Vector3(center_chunk))
		if dist > render_distance + 2:
			chunks_to_unload.append(coord)
	
	for coord in chunks_to_unload:
		_unload_chunk_visual(coord)
	
	# 2. Load chunks that are in range and have data
	for coord in chunks:
		if visible_chunks.has(coord):
			continue # Already visible
		
		var dist = Vector3(coord).distance_to(Vector3(center_chunk))
		if dist <= render_distance:
			_load_chunk_visual(coord)

func _unload_chunk_visual(coord: Vector3i):
	if not chunks.has(coord):
		return
	
	var chunk = chunks[coord]
	if chunk.is_inside_tree():
		remove_child(chunk)
	
	visible_chunks.erase(coord)

func _load_chunk_visual(coord: Vector3i):
	if not chunks.has(coord):
		return
	
	var chunk = chunks[coord]
	if not chunk.is_inside_tree():
		add_child(chunk)
		chunk.position = Vector3(coord) * CHUNK_SIZE
		# Rebuild mesh if chunk has data
		if not chunk.is_empty:
			chunk.rebuild_mesh()
	
	visible_chunks[coord] = true

## Get or create a chunk at the given coordinate. Uses pool for recycling.
func get_chunk(chunk_coord: Vector3i) -> BuildingChunk:
	if chunks.has(chunk_coord):
		return chunks[chunk_coord]
	
	# Get chunk from pool or create new one
	var chunk: BuildingChunk
	if chunk_pool.size() > 0:
		chunk = chunk_pool.pop_back()
		chunk.reset(chunk_coord) # Recycle: clear and assign new coord
	else:
		chunk = BuildingChunk.new(chunk_coord) # Pool empty: create new
	
	chunk.mesher = mesher # Inject dependency
	chunks[chunk_coord] = chunk
	
	# Only add to tree if within render distance
	if viewer:
		var p_pos = viewer.global_position
		var p_chunk = Vector3i(floor(p_pos.x / CHUNK_SIZE), floor(p_pos.y / CHUNK_SIZE), floor(p_pos.z / CHUNK_SIZE))
		var dist = Vector3(chunk_coord).distance_to(Vector3(p_chunk))
		
		if dist <= render_distance:
			add_child(chunk)
			chunk.position = Vector3(chunk_coord) * CHUNK_SIZE
			visible_chunks[chunk_coord] = true
		# else: chunk exists but is not in tree yet
	else:
		# No viewer yet, add normally
		add_child(chunk)
		chunk.position = Vector3(chunk_coord) * CHUNK_SIZE
		visible_chunks[chunk_coord] = true
	
	return chunk

## Return a chunk to the pool for recycling (call when permanently removing a chunk)
func release_chunk(chunk_coord: Vector3i):
	if not chunks.has(chunk_coord):
		return
	
	var chunk = chunks[chunk_coord]
	chunks.erase(chunk_coord)
	visible_chunks.erase(chunk_coord)
	
	if chunk.is_inside_tree():
		remove_child(chunk)
	
	# Add to pool if not full, otherwise free
	if chunk_pool.size() < MAX_POOL_SIZE:
		chunk_pool.append(chunk)
	else:
		chunk.queue_free()

func set_voxel(global_pos: Vector3, value: int, meta: int = 0):
	var chunk_x = floor(global_pos.x / CHUNK_SIZE)
	var chunk_y = floor(global_pos.y / CHUNK_SIZE)
	var chunk_z = floor(global_pos.z / CHUNK_SIZE)
	var chunk_coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	var local_x = int(floor(global_pos.x)) % CHUNK_SIZE
	var local_y = int(floor(global_pos.y)) % CHUNK_SIZE
	var local_z = int(floor(global_pos.z)) % CHUNK_SIZE
	
	# Handle negative modulo correctly
	if local_x < 0: local_x += CHUNK_SIZE
	if local_y < 0: local_y += CHUNK_SIZE
	if local_z < 0: local_z += CHUNK_SIZE
	
	var chunk = get_chunk(chunk_coord)
	chunk.set_voxel(Vector3i(local_x, local_y, local_z), value, meta)
	
	# Trigger rebuild for this chunk if it's visible
	if visible_chunks.has(chunk_coord):
		chunk.rebuild_mesh()

## Set voxel WITHOUT triggering immediate mesh rebuild (for batch operations)
## Call flush_dirty_chunks() after all batch operations are complete
func set_voxel_batched(global_pos: Vector3, value: int, meta: int = 0):
	var chunk_x = floor(global_pos.x / CHUNK_SIZE)
	var chunk_y = floor(global_pos.y / CHUNK_SIZE)
	var chunk_z = floor(global_pos.z / CHUNK_SIZE)
	var chunk_coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	var local_x = int(floor(global_pos.x)) % CHUNK_SIZE
	var local_y = int(floor(global_pos.y)) % CHUNK_SIZE
	var local_z = int(floor(global_pos.z)) % CHUNK_SIZE
	
	# Handle negative modulo correctly
	if local_x < 0: local_x += CHUNK_SIZE
	if local_y < 0: local_y += CHUNK_SIZE
	if local_z < 0: local_z += CHUNK_SIZE
	
	var chunk = get_chunk(chunk_coord)
	chunk.set_voxel(Vector3i(local_x, local_y, local_z), value, meta)
	
	# Always mark chunk as dirty - rebuild will check visibility
	_dirty_chunks[chunk_coord] = chunk

## Rebuild all chunks that were modified by batched operations
## Call this once after completing a batch of set_voxel_batched calls
func flush_dirty_chunks():
	if _dirty_chunks.is_empty():
		return
	
	# Only rebuild chunks that are currently visible
	var rebuilt = 0
	for coord in _dirty_chunks:
		if visible_chunks.has(coord):
			_dirty_chunks[coord].rebuild_mesh()
			rebuilt += 1
	
	print("[BatchFlush] Flushed %d dirty chunks (%d rebuilt)" % [_dirty_chunks.size(), rebuilt])
	_dirty_chunks.clear()

func get_voxel(global_pos: Vector3) -> int:
	var chunk_x = floor(global_pos.x / CHUNK_SIZE)
	var chunk_y = floor(global_pos.y / CHUNK_SIZE)
	var chunk_z = floor(global_pos.z / CHUNK_SIZE)
	var chunk_coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not chunks.has(chunk_coord):
		return 0
		
	var local_x = int(floor(global_pos.x)) % CHUNK_SIZE
	var local_y = int(floor(global_pos.y)) % CHUNK_SIZE
	var local_z = int(floor(global_pos.z)) % CHUNK_SIZE
	
	if local_x < 0: local_x += CHUNK_SIZE
	if local_y < 0: local_y += CHUNK_SIZE
	if local_z < 0: local_z += CHUNK_SIZE
	
	return chunks[chunk_coord].get_voxel(Vector3i(local_x, local_y, local_z))

## Check if an object can be placed at the given global position
func can_place_object(global_pos: Vector3, object_id: int, rotation: int) -> bool:
	var anchor = Vector3i(floor(global_pos.x), floor(global_pos.y), floor(global_pos.z))
	var cells = ObjectRegistry.get_occupied_cells(object_id, anchor, rotation)
	
	for cell in cells:
		# Calculate which chunk this specific cell belongs to
		var chunk_coord = Vector3i(
			int(floor(float(cell.x) / CHUNK_SIZE)),
			int(floor(float(cell.y) / CHUNK_SIZE)),
			int(floor(float(cell.z) / CHUNK_SIZE))
		)
		
		var local = Vector3i(cell.x % CHUNK_SIZE, cell.y % CHUNK_SIZE, cell.z % CHUNK_SIZE)
		if local.x < 0: local.x += CHUNK_SIZE
		if local.y < 0: local.y += CHUNK_SIZE
		if local.z < 0: local.z += CHUNK_SIZE
		
		# Check if cell is available in its chunk
		if chunks.has(chunk_coord):
			var chunk = chunks[chunk_coord]
			if not chunk.is_cell_available(local):
				DebugManager.log_building("DEBUG_MISSING_OBJ: Cell collision at global %v (Chunk %v Local %v) for Object %d" % [cell, chunk_coord, local, object_id])
				return false
		# If chunk doesn't exist, cell is available (empty terrain)
	
	return true

## Place an object at the given global position (supports fractional Y for terrain surface)
## Set is_procedural=true when spawning from prefab system to trigger loot population
func place_object(global_pos: Vector3, object_id: int, rotation: int, ignore_collision: bool = false, is_procedural: bool = false) -> bool:
	if not ignore_collision and not can_place_object(global_pos, object_id, rotation):
		return false
	
	var obj_def = ObjectRegistry.get_object(object_id)
	if obj_def.is_empty():
		return false
	
	# Calculate anchor (integer grid position) and fractional position offset
	var anchor = Vector3i(int(floor(global_pos.x)), int(floor(global_pos.y)), int(floor(global_pos.z)))
	var fractional_pos = global_pos - Vector3(anchor) # Full 3D offset from anchor
	var cells = ObjectRegistry.get_occupied_cells(object_id, anchor, rotation)
	
	# Load and instantiate the scene (uses preloaded cache)
	var scene_path = obj_def.scene
	var scene_instance: Node3D = null
	var packed = ObjectRegistry.get_preloaded_scene(scene_path)
	if packed:
		scene_instance = packed.instantiate()
	
	# Place in the chunk containing the anchor
	var chunk_coord = Vector3i(
		int(floor(float(anchor.x) / CHUNK_SIZE)),
		int(floor(float(anchor.y) / CHUNK_SIZE)),
		int(floor(float(anchor.z) / CHUNK_SIZE))
	)
	
	var local_anchor = Vector3i(anchor.x % CHUNK_SIZE, anchor.y % CHUNK_SIZE, anchor.z % CHUNK_SIZE)
	if local_anchor.x < 0: local_anchor.x += CHUNK_SIZE
	if local_anchor.y < 0: local_anchor.y += CHUNK_SIZE
	if local_anchor.z < 0: local_anchor.z += CHUNK_SIZE
	
	# Convert cells to local coordinates for the anchor chunk
	var local_cells: Array[Vector3i] = []
	for cell in cells:
		var local_cell = Vector3i(cell.x % CHUNK_SIZE, cell.y % CHUNK_SIZE, cell.z % CHUNK_SIZE)
		if local_cell.x < 0: local_cell.x += CHUNK_SIZE
		if local_cell.y < 0: local_cell.y += CHUNK_SIZE
		if local_cell.z < 0: local_cell.z += CHUNK_SIZE
		local_cells.append(local_cell)
	
	var chunk = get_chunk(chunk_coord)
	
	# Mark container for loot population BEFORE adding to tree
	# This allows _ready() to populate after creating the inventory
	if is_procedural and scene_instance and scene_instance.has_method("populate_loot"):
		scene_instance.set_meta("should_populate_loot", true)
	
	var success = chunk.place_object(local_anchor, object_id, rotation, local_cells, scene_instance, fractional_pos)
	
	return success

## Remove an object at the given global position
func remove_object_at(global_pos: Vector3) -> bool:
	var cell = Vector3i(floor(global_pos.x), floor(global_pos.y), floor(global_pos.z))
	
	var chunk_coord = Vector3i(
		int(floor(float(cell.x) / CHUNK_SIZE)),
		int(floor(float(cell.y) / CHUNK_SIZE)),
		int(floor(float(cell.z) / CHUNK_SIZE))
	)
	
	if not chunks.has(chunk_coord):
		return false
	
	var local = Vector3i(cell.x % CHUNK_SIZE, cell.y % CHUNK_SIZE, cell.z % CHUNK_SIZE)
	if local.x < 0: local.x += CHUNK_SIZE
	if local.y < 0: local.y += CHUNK_SIZE
	if local.z < 0: local.z += CHUNK_SIZE
	
	var chunk = chunks[chunk_coord]
	var anchor = chunk.get_object_at(local)
	if anchor == null:
		return false
	
	return chunk.remove_object(anchor)
