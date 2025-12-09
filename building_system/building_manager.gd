extends Node3D

# Maps Vector3i (Chunk Coord) -> BuildingChunk (data always persisted)
var chunks: Dictionary = {}
var mesher: BuildingMesher

# Render distance management
@export var viewer: Node3D
@export var render_distance: int = 8  # Increased for better visibility

# Track which chunks are currently visible (have nodes in scene tree)
var visible_chunks: Dictionary = {}  # Vector3i -> true

const CHUNK_SIZE = 16  # Must match BuildingChunk.SIZE

func _ready():
	mesher = BuildingMesher.new()
	add_child(mesher)
	
	# Find player if not assigned
	if not viewer:
		viewer = get_tree().get_first_node_in_group("player")

func _process(_delta):
	if viewer:
		update_building_chunks()

func update_building_chunks():
	var p_pos = viewer.global_position
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
			continue  # Already visible
		
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

# TODO: Pooling chunks could optimize this further
func get_chunk(chunk_coord: Vector3i) -> BuildingChunk:
	if chunks.has(chunk_coord):
		return chunks[chunk_coord]
	
	# Create new chunk if not exists
	var chunk = BuildingChunk.new(chunk_coord)
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

func set_voxel(global_pos: Vector3, value: int, meta: int = 0):
	var chunk_x = floor(global_pos.x / CHUNK_SIZE)
	var chunk_y = floor(global_pos.y / CHUNK_SIZE)
	var chunk_z = floor(global_pos.z / CHUNK_SIZE)
	var chunk_coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	var local_x = int(global_pos.x) % CHUNK_SIZE
	var local_y = int(global_pos.y) % CHUNK_SIZE
	var local_z = int(global_pos.z) % CHUNK_SIZE
	
	# Handle negative modulo correctly
	if local_x < 0: local_x += CHUNK_SIZE
	if local_y < 0: local_y += CHUNK_SIZE
	if local_z < 0: local_z += CHUNK_SIZE
	
	var chunk = get_chunk(chunk_coord)
	chunk.set_voxel(Vector3i(local_x, local_y, local_z), value, meta)
	
	# Trigger rebuild for this chunk if it's visible
	if visible_chunks.has(chunk_coord):
		chunk.rebuild_mesh()

func get_voxel(global_pos: Vector3) -> int:
	var chunk_x = floor(global_pos.x / CHUNK_SIZE)
	var chunk_y = floor(global_pos.y / CHUNK_SIZE)
	var chunk_z = floor(global_pos.z / CHUNK_SIZE)
	var chunk_coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not chunks.has(chunk_coord):
		return 0
		
	var local_x = int(global_pos.x) % CHUNK_SIZE
	var local_y = int(global_pos.y) % CHUNK_SIZE
	var local_z = int(global_pos.z) % CHUNK_SIZE
	
	if local_x < 0: local_x += CHUNK_SIZE
	if local_y < 0: local_y += CHUNK_SIZE
	if local_z < 0: local_z += CHUNK_SIZE
	
	return chunks[chunk_coord].get_voxel(Vector3i(local_x, local_y, local_z))

