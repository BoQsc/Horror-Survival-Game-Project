extends SceneTree

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	if not _expect(ClassDB.class_exists("TerrainGrid"), "TerrainGrid should be available"):
		return 1
	var grid = ClassDB.instantiate("TerrainGrid")
	if not _expect(grid != null, "TerrainGrid should instantiate"):
		return 1
	if not _expect(grid.has_method("sample_cached_height_map"), "TerrainGrid should expose native cached height-map sampling"):
		return 1

	var height_map := PackedFloat32Array()
	height_map.resize(16)
	for x in range(4):
		for z in range(4):
			height_map[x * 4 + z] = float(x * 10 + z)
	height_map[2 * 4 + 2] = -1000.0

	var samples: PackedFloat32Array = grid.sample_cached_height_map(height_map, 4, 4, 2, 32.0)
	var expected := PackedFloat32Array([32.0, 34.0, 52.0, -1000.0])
	if not _expect(samples.size() == expected.size(), "sample count should match range(0, chunk_stride, step)^2"):
		return 1
	for i in range(expected.size()):
		if not _expect(is_equal_approx(samples[i], expected[i]), "sampled height should match GDScript cached height-map semantics"):
			return 1

	var clamped: PackedFloat32Array = grid.sample_cached_height_map(height_map, 4, 6, 4, 0.0)
	var expected_clamped := PackedFloat32Array([0.0, 3.0, 30.0, 33.0])
	if not _expect(clamped.size() == expected_clamped.size(), "out-of-map samples should clamp like _sample_height_map_local"):
		return 1
	for i in range(expected_clamped.size()):
		if not _expect(is_equal_approx(clamped[i], expected_clamped[i]), "clamped sample should match edge height"):
			return 1

	var disabled: PackedFloat32Array = grid.sample_cached_height_map(PackedFloat32Array(), 4, 4, 2, 0.0)
	if not _expect(disabled.is_empty(), "empty source height map should return empty samples"):
		return 1

	print("[TERRAIN_HEIGHT_MAP_SAMPLES_NATIVE_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_HEIGHT_MAP_SAMPLES_NATIVE_TEST] FAIL: %s" % message)
	return false
