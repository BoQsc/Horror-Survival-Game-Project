extends Node

const MeshBuilderClass := "MeshBuilder"

func _ready() -> void:
	print("[TRANSVOXEL_EXCAVATION] Starting excavation parity validation")
	call_deferred("_run_tests")


func _run_tests() -> void:
	if not ClassDB.class_exists(MeshBuilderClass):
		print("[TRANSVOXEL_EXCAVATION] ERROR: MeshBuilder GDExtension class not available")
		get_tree().quit(1)
		return

	var builder: Object = ClassDB.instantiate(MeshBuilderClass)
	if builder == null:
		print("[TRANSVOXEL_EXCAVATION] ERROR: Could not instantiate MeshBuilder")
		get_tree().quit(1)
		return

	var excavation_masks := _build_excavation_masks(32, 12, 20)
	var mesh: ArrayMesh = builder.build_transvoxel_heightfield_mesh(
		_build_heightmap_flat(64, 64, 18),
		64,
		64,
		64.0,
		32.0,
		Vector3(0, 0, 0),
		Vector3(32, 32, 32),
		8,
		0,
		excavation_masks,
		32
	)
	if mesh == null or mesh.get_surface_count() == 0:
		print("[TRANSVOXEL_EXCAVATION] ERROR: Excavated mesh failed to build")
		get_tree().quit(1)
		return

	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if vertices.is_empty():
		print("[TRANSVOXEL_EXCAVATION] ERROR: Excavated mesh has no vertices")
		get_tree().quit(1)
		return

	var root := Node3D.new()
	add_child(root)
	var body := StaticBody3D.new()
	root.add_child(body)
	var shape := mesh.create_trimesh_shape()
	if shape == null:
		print("[TRANSVOXEL_EXCAVATION] ERROR: Could not create collision shape")
		get_tree().quit(1)
		return
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)

	await get_tree().physics_frame

	var viewport := get_viewport()
	if viewport == null or viewport.world_3d == null:
		print("[TRANSVOXEL_EXCAVATION] ERROR: Missing 3D world")
		get_tree().quit(1)
		return
	var space_state: PhysicsDirectSpaceState3D = viewport.world_3d.direct_space_state
	if space_state == null:
		print("[TRANSVOXEL_EXCAVATION] ERROR: Missing physics space")
		get_tree().quit(1)
		return

	if _ray_hits(space_state, Vector3(16.0, 64.0, 16.0), Vector3(16.0, -16.0, 16.0)):
		print("[TRANSVOXEL_EXCAVATION] ERROR: Center ray still hit terrain, excavation not applied")
		get_tree().quit(1)
		return

	if not _ray_hits(space_state, Vector3(6.0, 64.0, 6.0), Vector3(6.0, -16.0, 6.0)):
		print("[TRANSVOXEL_EXCAVATION] ERROR: Edge ray missed terrain, mesh hole too large")
		get_tree().quit(1)
		return

	print("[TRANSVOXEL_EXCAVATION] Excavation parity passed")
	get_tree().quit(0)


func _build_heightmap_flat(width: int, height: int, value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(width * height)
	bytes.fill(value)
	return bytes


func _build_excavation_masks(chunk_stride: int, hole_min: int, hole_max: int) -> Dictionary:
	var mask_bytes := PackedByteArray()
	mask_bytes.resize(_excavation_mask_byte_count(chunk_stride))
	mask_bytes.fill(0)
	for z in range(hole_min, hole_max + 1):
		for y in range(0, chunk_stride + 1):
			for x in range(hole_min, hole_max + 1):
				var bit_index := x + (y * (chunk_stride + 1)) + (z * (chunk_stride + 1) * (chunk_stride + 1))
				var byte_index := bit_index / 8
				mask_bytes[byte_index] = mask_bytes[byte_index] | (1 << (bit_index % 8))
	var masks := {}
	masks[Vector3i(0, 0, 0)] = mask_bytes
	return masks


func _excavation_mask_byte_count(chunk_stride: int) -> int:
	var point_count := (chunk_stride + 1) * (chunk_stride + 1) * (chunk_stride + 1)
	return int(ceil(float(point_count) / 8.0))


func _ray_hits(space_state: PhysicsDirectSpaceState3D, origin: Vector3, target: Vector3) -> bool:
	var params := PhysicsRayQueryParameters3D.create(origin, target)
	params.collide_with_areas = false
	params.collide_with_bodies = true
	params.hit_from_inside = false
	var result: Dictionary = space_state.intersect_ray(params)
	return not result.is_empty()
