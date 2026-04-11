extends Node

const MeshBuilderClass := "MeshBuilder"

func _ready() -> void:
	print("[TRANSVOXEL_NORMAL] Starting normal parity validation")
	call_deferred("_run_tests")


func _run_tests() -> void:
	if not ClassDB.class_exists(MeshBuilderClass):
		print("[TRANSVOXEL_NORMAL] ERROR: MeshBuilder GDExtension class not available")
		get_tree().quit(1)
		return

	var builder: Object = ClassDB.instantiate(MeshBuilderClass)
	if builder == null:
		print("[TRANSVOXEL_NORMAL] ERROR: Could not instantiate MeshBuilder")
		get_tree().quit(1)
		return

	var mesh: ArrayMesh = builder.build_transvoxel_heightfield_mesh(
		_build_heightmap_cliff(64, 64, 0, 255),
		64,
		64,
		64.0,
		64.0,
		Vector3(-32, 0, -32),
		Vector3(64, 64, 64),
		8,
		0,
		{},
		32
	)
	if mesh == null or mesh.get_surface_count() == 0:
		print("[TRANSVOXEL_NORMAL] ERROR: Mesh failed to build")
		get_tree().quit(1)
		return

	var arrays := mesh.surface_get_arrays(0)
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	if normals.is_empty():
		print("[TRANSVOXEL_NORMAL] ERROR: Mesh produced no normals")
		get_tree().quit(1)
		return

	var steep_count := 0
	var min_y := 1.0
	var max_y := -1.0
	for normal in normals:
		min_y = min(min_y, normal.y)
		max_y = max(max_y, normal.y)
		if abs(normal.x) > 0.45 or abs(normal.z) > 0.45:
			steep_count += 1

	if steep_count == 0:
		print("[TRANSVOXEL_NORMAL] ERROR: Normals are still heightfield-flat")
		get_tree().quit(1)
		return
	if min_y > 0.7 or max_y < 0.9:
		print("[TRANSVOXEL_NORMAL] ERROR: Normal range suspicious min_y=%.3f max_y=%.3f" % [min_y, max_y])
		get_tree().quit(1)
		return

	print("[TRANSVOXEL_NORMAL] Normal parity passed steep=%d min_y=%.3f max_y=%.3f" % [steep_count, min_y, max_y])
	get_tree().quit(0)


func _build_heightmap_cliff(width: int, height: int, low_value: int, high_value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(width * height)
	for z in range(height):
		for x in range(width):
			bytes[z * width + x] = low_value if x < width / 2 else high_value
	return bytes
