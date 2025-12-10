extends Node3D
class_name BuildingChunk

# Constants
const SIZE = 16

# Data
var chunk_coord: Vector3i
var voxel_bytes: PackedByteArray # IDs
var voxel_meta: PackedByteArray # Rotation/Meta
var is_empty: bool = true

# Visuals
var mesh_instance: MeshInstance3D
var static_body: StaticBody3D
var collision_shape: CollisionShape3D

# Mesher Reference (injected by Manager)
var mesher: Node # BuildingMesher

func _init(coord: Vector3i):
	chunk_coord = coord
	# Resize and init with 0 (Air)
	voxel_bytes.resize(SIZE * SIZE * SIZE)
	voxel_bytes.fill(0)
	voxel_meta.resize(SIZE * SIZE * SIZE)
	voxel_meta.fill(0)

## Reset chunk for pool reuse - clears data without reallocating arrays
func reset(new_coord: Vector3i):
	chunk_coord = new_coord
	voxel_bytes.fill(0)  # Clear all voxels to air
	voxel_meta.fill(0)   # Clear all metadata
	is_empty = true
	# Clear visuals
	if mesh_instance:
		mesh_instance.mesh = null
	if collision_shape:
		collision_shape.shape = null

func _ready():
	# Setup Node Structure
	static_body = StaticBody3D.new()
	add_child(static_body)
	
	mesh_instance = MeshInstance3D.new()
	static_body.add_child(mesh_instance)
	
	collision_shape = CollisionShape3D.new()
	static_body.add_child(collision_shape)

func get_voxel(local_pos: Vector3i) -> int:
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return 0
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return 0
	
	var idx = _get_index(local_pos)
	return voxel_bytes.decode_u8(idx)

func get_voxel_meta(local_pos: Vector3i) -> int:
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return 0
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return 0
	
	var idx = _get_index(local_pos)
	return voxel_meta.decode_u8(idx)

func set_voxel(local_pos: Vector3i, value: int, meta: int = 0):
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return
	
	var idx = _get_index(local_pos)
	voxel_bytes.encode_u8(idx, value)
	voxel_meta.encode_u8(idx, meta)
	
	if value > 0:
		is_empty = false

func rebuild_mesh():
	if mesher:
		mesher.request_mesh_generation(self)

func apply_mesh(arrays: Array, shape: Shape3D = null):
	if arrays.size() > 0:
		var mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		
		var material = StandardMaterial3D.new()
		material.albedo_color = Color(1.0, 1.0, 1.0) # White so texture shows
		material.albedo_texture = load("res://greedy_meshing/wood-block-texture.png")
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		
		mesh_instance.material_override = material
		mesh_instance.mesh = mesh
		
		# Generate Physics Shape (Main Thread, since we disabled threading it)
		if collision_shape.shape:
			collision_shape.shape = null
		collision_shape.shape = mesh.create_trimesh_shape()
	else:
		mesh_instance.mesh = null
		collision_shape.shape = null

func _get_index(pos: Vector3i) -> int:
	return pos.x + pos.y * SIZE + pos.z * SIZE * SIZE
