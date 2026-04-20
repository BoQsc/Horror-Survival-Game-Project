extends Resource
class_name BuildingBakeSnapshot

@export var schema_version: int = 1
@export var chunk_coord: Vector3i = Vector3i.ZERO
@export var source_prefab: String = ""
@export var source_rotation: int = 0
@export var source_spawn_origin: Vector3 = Vector3.ZERO
@export var is_empty: bool = true
@export var voxel_bytes: PackedByteArray = PackedByteArray()
@export var voxel_meta: PackedByteArray = PackedByteArray()
@export var objects_data: Array = []
@export var mesh: ArrayMesh
@export var collision_shape: Shape3D
@export var collision_boxes: Array = []
