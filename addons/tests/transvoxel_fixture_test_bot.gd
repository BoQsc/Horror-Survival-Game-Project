extends Node

const MeshBuilderClass := "MeshBuilder"

var _passed: bool = false

func _ready() -> void:
	print("[TRANSVOXEL_FIXTURE] Starting extractor fixture validation")
	call_deferred("_run_tests")


func _run_tests() -> void:
	if not ClassDB.class_exists(MeshBuilderClass):
		print("[TRANSVOXEL_FIXTURE] ERROR: MeshBuilder GDExtension class not available")
		get_tree().quit(1)
		return

	var builder: Object = ClassDB.instantiate(MeshBuilderClass)
	if builder == null:
		print("[TRANSVOXEL_FIXTURE] ERROR: Could not instantiate MeshBuilder")
		get_tree().quit(1)
		return

	var cases := [
		{
			"name": "flat_plane",
			"heightmap": _build_heightmap_flat(64, 64, 18),
			"mask": 0,
			"block_base": Vector3(-32, 0, -32),
			"block_size": Vector3(64, 32, 64),
			"subdivisions": 4
		},
		{
			"name": "slope",
			"heightmap": _build_heightmap_slope(64, 64, 8, 26),
			"mask": 0,
			"block_base": Vector3(-32, 0, -32),
			"block_size": Vector3(64, 32, 64),
			"subdivisions": 4
		},
		{
			"name": "cliff_step",
			"heightmap": _build_heightmap_cliff(64, 64, 10, 24),
			"mask": (1 << 0) | (1 << 1) | (1 << 4) | (1 << 5),
			"block_base": Vector3(-32, 0, -32),
			"block_size": Vector3(64, 32, 64),
			"subdivisions": 4
		},
		{
			"name": "corner_seam",
			"heightmap": _build_heightmap_corner(64, 64, 12, 28),
			"mask": (1 << 0) | (1 << 1) | (1 << 4) | (1 << 5),
			"block_base": Vector3(-32, 0, -32),
			"block_size": Vector3(64, 32, 64),
			"subdivisions": 4
		}
	]

	for test_case in cases:
		var mesh: ArrayMesh = builder.build_transvoxel_heightfield_mesh(
			test_case["heightmap"],
			64,
			64,
			64.0,
			32.0,
			test_case["block_base"],
			test_case["block_size"],
			test_case["subdivisions"],
			test_case["mask"]
		)
		if mesh == null or mesh.get_surface_count() == 0:
			print("[TRANSVOXEL_FIXTURE] ERROR: %s produced no mesh" % test_case["name"])
			get_tree().quit(1)
			return

		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if vertices.is_empty() or indices.is_empty():
			print("[TRANSVOXEL_FIXTURE] ERROR: %s produced empty arrays" % test_case["name"])
			get_tree().quit(1)
			return

		var bounds_ok := _validate_bounds(vertices, test_case["block_base"], test_case["block_size"], test_case["name"])
		if not bounds_ok:
			get_tree().quit(1)
			return

	print("[TRANSVOXEL_FIXTURE] All fixture cases passed")
	_passed = true
	get_tree().quit(0)


func _build_heightmap_flat(width: int, height: int, value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(width * height)
	bytes.fill(value)
	return bytes


func _build_heightmap_slope(width: int, height: int, low_value: int, high_value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(width * height)
	for z in range(height):
		for x in range(width):
			var t := float(x) / float(max(1, width - 1))
			bytes[z * width + x] = int(round(lerp(float(low_value), float(high_value), t)))
	return bytes


func _build_heightmap_cliff(width: int, height: int, low_value: int, high_value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(width * height)
	for z in range(height):
		for x in range(width):
			bytes[z * width + x] = low_value if x < width / 2 else high_value
	return bytes


func _build_heightmap_corner(width: int, height: int, low_value: int, high_value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(width * height)
	for z in range(height):
		for x in range(width):
			var corner_high := (x >= width / 2 and z >= height / 2)
			bytes[z * width + x] = high_value if corner_high else low_value
	return bytes


func _validate_bounds(vertices: PackedVector3Array, block_base: Vector3, block_size: Vector3, case_name: String) -> bool:
	var min_v := Vector3(1.0e20, 1.0e20, 1.0e20)
	var max_v := Vector3(-1.0e20, -1.0e20, -1.0e20)
	for v in vertices:
		min_v.x = min(min_v.x, v.x)
		min_v.y = min(min_v.y, v.y)
		min_v.z = min(min_v.z, v.z)
		max_v.x = max(max_v.x, v.x)
		max_v.y = max(max_v.y, v.y)
		max_v.z = max(max_v.z, v.z)

	var within_x := min_v.x >= block_base.x - 1.0 and max_v.x <= block_base.x + block_size.x + 1.0
	var within_z := min_v.z >= block_base.z - 1.0 and max_v.z <= block_base.z + block_size.z + 1.0
	var within_y := min_v.y >= block_base.y - 1.0 and max_v.y <= block_base.y + block_size.y + 1.0
	if not within_x or not within_y or not within_z:
		print("[TRANSVOXEL_FIXTURE] ERROR: %s bounds out of range min=%s max=%s base=%s size=%s" % [
			case_name, min_v, max_v, block_base, block_size
		])
		return false

	print("[TRANSVOXEL_FIXTURE] %s passed with %d vertices and bounds min=%s max=%s" % [
		case_name, vertices.size(), min_v, max_v
	])
	return true
