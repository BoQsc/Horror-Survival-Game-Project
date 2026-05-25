extends SceneTree

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	if not ClassDB.class_exists("PrefabGeometryNative"):
		return _fail("PrefabGeometryNative is not registered")

	var native := PrefabGeometryNative.new()
	if native == null or not native.has_method("build_global_vegetation_cluster_render_payload"):
		return _fail("native cluster payload merge method is missing")

	var payloads := {}
	payloads[Vector2i(0, 0)] = {
		"buffer": _make_buffer(12, 1.0),
		"instance_count": 1,
		"bounds": AABB(Vector3(1.0, 2.0, 3.0), Vector3.ZERO),
		"has_bounds": true
	}
	payloads[Vector2i(1, 0)] = {
		"buffer": _make_buffer(24, 10.0),
		"instance_count": 2,
		"bounds": AABB(Vector3(4.0, 5.0, 6.0), Vector3.ONE),
		"has_bounds": true
	}
	payloads[Vector2i(9, 9)] = {
		"buffer": PackedFloat32Array(),
		"instance_count": 0,
		"bounds": AABB(),
		"has_bounds": false
	}

	var result: Dictionary = native.build_global_vegetation_cluster_render_payload(
		payloads,
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
		0.5
	)
	if not _expect(int(result.get("chunk_count", 0)) == 2, "expected two non-empty chunks"):
		return 1
	if not _expect(int(result.get("instance_count", 0)) == 3, "expected three instances"):
		return 1

	var buffer: PackedFloat32Array = result.get("buffer", PackedFloat32Array())
	if not _expect(buffer.size() == 36, "expected one packed 3D transform buffer"):
		return 1
	if not _expect(is_equal_approx(buffer[0], 1.0) and is_equal_approx(buffer[11], 12.0), "first chunk buffer order changed"):
		return 1
	if not _expect(is_equal_approx(buffer[12], 10.0) and is_equal_approx(buffer[35], 33.0), "second chunk buffer order changed"):
		return 1

	var bounds: AABB = result.get("bounds", AABB())
	if not _expect(_vec_equal(bounds.position, Vector3(0.5, 1.5, 2.5)), "merged bounds position mismatch"):
		return 1
	if not _expect(_vec_equal(bounds.size, Vector3(5.0, 5.0, 5.0)), "merged bounds size mismatch"):
		return 1

	result.clear()
	payloads.clear()
	native = null
	print("[VEGETATION_CLUSTER_PAYLOAD_NATIVE_TEST] PASS")
	return 0

func _make_buffer(count: int, start_value: float) -> PackedFloat32Array:
	var buffer := PackedFloat32Array()
	buffer.resize(count)
	for index in range(count):
		buffer[index] = start_value + float(index)
	return buffer

func _vec_equal(actual: Vector3, expected: Vector3) -> bool:
	return is_equal_approx(actual.x, expected.x) \
		and is_equal_approx(actual.y, expected.y) \
		and is_equal_approx(actual.z, expected.z)

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_CLUSTER_PAYLOAD_NATIVE_TEST] FAIL: %s" % message)
	return false

func _fail(message: String) -> int:
	printerr("[VEGETATION_CLUSTER_PAYLOAD_NATIVE_TEST] FAIL: %s" % message)
	return 1
