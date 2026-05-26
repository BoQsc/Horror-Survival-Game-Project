extends SceneTree

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	if not ClassDB.class_exists("TerrainGrid"):
		return _fail("TerrainGrid is not available")
	var grid = ClassDB.instantiate("TerrainGrid")
	if grid == null:
		return _fail("TerrainGrid could not be instantiated")
	if not grid.has_method("get_world_map_road_block_samples"):
		return _fail("native road mask sampling is unavailable")
	if not grid.has_method("get_world_map_water_block_samples"):
		return _fail("native water mask sampling is unavailable")

	var road_data := PackedByteArray()
	road_data.resize(64)
	road_data[0] = 255
	road_data[2 * 8 + 2] = 255
	var road_samples: PackedFloat32Array = grid.get_world_map_road_block_samples(
		road_data,
		8,
		8,
		-4,
		-4,
		4,
		2,
		4.0,
		8.0
	)
	if not _expect(_same_float_array(road_samples, PackedFloat32Array([1.0, 0.0, 0.0, 1.0])), "road mask samples should match GDScript ordering and scaling"):
		return 1

	var water_data := PackedByteArray()
	water_data.resize(64)
	for i in range(water_data.size()):
		water_data[i] = 255
	var water_samples: PackedFloat32Array = grid.get_world_map_water_block_samples(
		water_data,
		8,
		8,
		-4,
		-4,
		4,
		2,
		PackedFloat32Array([0.0, 0.0, 10.0, -200.0]),
		4.0,
		1.0
	)
	if not _expect(_same_float_array(water_samples, PackedFloat32Array([1.0, 1.0, 0.0, 0.0])), "water mask samples should preserve terrain-height and no-terrain rules"):
		return 1

	print("[WORLD_MAP_MASK_SAMPLES_NATIVE_TEST] PASS")
	return 0

func _same_float_array(actual: PackedFloat32Array, expected: PackedFloat32Array) -> bool:
	if actual.size() != expected.size():
		return false
	for i in range(actual.size()):
		if not is_equal_approx(actual[i], expected[i]):
			return false
	return true

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_MASK_SAMPLES_NATIVE_TEST] FAIL: %s" % message)
	return false

func _fail(message: String) -> int:
	printerr("[WORLD_MAP_MASK_SAMPLES_NATIVE_TEST] FAIL: %s" % message)
	return 1
