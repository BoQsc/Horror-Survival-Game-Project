extends Node3D

# Maps Vector3i (Chunk Coord) -> BuildingChunk
var chunks: Dictionary = {}
var mesher: BuildingMesher

func _ready():
	mesher = BuildingMesher.new()
	add_child(mesher)

# TODO: Pooling chunks could optimize this further
func get_chunk(chunk_coord: Vector3i) -> BuildingChunk:
	if chunks.has(chunk_coord):
		return chunks[chunk_coord]
	
	# Create new chunk if not exists
	var chunk = BuildingChunk.new(chunk_coord)
	chunk.mesher = mesher # Inject dependency
	
	chunks[chunk_coord] = chunk
	add_child(chunk)
	
	# Position it in world
	chunk.position = Vector3(chunk_coord) * BuildingChunk.SIZE
	
	return chunk

func set_voxel(global_pos: Vector3, value: int):
	var chunk_size = BuildingChunk.SIZE
	
	var chunk_x = floor(global_pos.x / chunk_size)
	var chunk_y = floor(global_pos.y / chunk_size)
	var chunk_z = floor(global_pos.z / chunk_size)
	var chunk_coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	var local_x = int(global_pos.x) % chunk_size
	var local_y = int(global_pos.y) % chunk_size
	var local_z = int(global_pos.z) % chunk_size
	
	# Handle negative modulo correctly
	if local_x < 0: local_x += chunk_size
	if local_y < 0: local_y += chunk_size
	if local_z < 0: local_z += chunk_size
	
	var chunk = get_chunk(chunk_coord)
	chunk.set_voxel(Vector3i(local_x, local_y, local_z), value)
	
	# Trigger rebuild for this chunk
	chunk.rebuild_mesh()

func get_voxel(global_pos: Vector3) -> int:
	var chunk_size = BuildingChunk.SIZE
	var chunk_x = floor(global_pos.x / chunk_size)
	var chunk_y = floor(global_pos.y / chunk_size)
	var chunk_z = floor(global_pos.z / chunk_size)
	var chunk_coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not chunks.has(chunk_coord):
		return 0
		
	var local_x = int(global_pos.x) % chunk_size
	var local_y = int(global_pos.y) % chunk_size
	var local_z = int(global_pos.z) % chunk_size
	
	if local_x < 0: local_x += chunk_size
	if local_y < 0: local_y += chunk_size
	if local_z < 0: local_z += chunk_size
	
	return chunks[chunk_coord].get_voxel(Vector3i(local_x, local_y, local_z))
