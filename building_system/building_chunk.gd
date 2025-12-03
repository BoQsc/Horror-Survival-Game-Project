extends Node3D
class_name BuildingChunk

# Constants
const SIZE = 16

# Data
var chunk_coord: Vector3i
var voxel_bytes: PackedByteArray # 16x16x16 * 4 bytes
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
	voxel_bytes.resize(SIZE * SIZE * SIZE * 4)
	voxel_bytes.fill(0)

func _ready():
	# Setup Node Structure
	static_body = StaticBody3D.new()
	add_child(static_body)
	
	mesh_instance = MeshInstance3D.new()
	static_body.add_child(mesh_instance)
	
	collision_shape = CollisionShape3D.new()
	static_body.add_child(collision_shape)

func get_voxel(local_pos: Vector3i) -> float:
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return 0.0
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return 0.0
	
	var idx = _get_index(local_pos)
	return voxel_bytes.decode_float(idx * 4)

func set_voxel(local_pos: Vector3i, value: float):
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return
	
	var idx = _get_index(local_pos)
	voxel_bytes.encode_float(idx * 4, value)
	
	if value > 0.0:
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
		
		if collision_shape.shape:
			collision_shape.shape = null
		collision_shape.shape = mesh.create_trimesh_shape()
	else:
		mesh_instance.mesh = null
		collision_shape.shape = null

func _get_index(pos: Vector3i) -> int:
	return pos.x + pos.y * SIZE + pos.z * SIZE * SIZE
