extends SceneTree

const FoundationSupportScript := preload("res://world_building_system/foundation_support.gd")

var _native: Object = null


func _init() -> void:
	var exit_code := _run()
	_release_native()
	quit(exit_code)


func _release_native() -> void:
	if _native == null or not is_instance_valid(_native):
		_native = null
		return
	if _native is RefCounted:
		_native.unreference()
		if is_instance_valid(_native):
			_native.free()
	else:
		_native.free()
	_native = null


func _run() -> int:
	if not _expect(ClassDB.class_exists("PrefabGeometryNative"), "PrefabGeometryNative should be available"):
		return 1
	_native = ClassDB.instantiate("PrefabGeometryNative")
	var native := _native
	if not _expect(native != null and native.has_method("resolve_world_map_building_support"), "native building support resolver should be bound"):
		return 1

	var map_size := 128
	var half := map_size / 2
	var max_h := 25.0
	var height_bytes := _make_height_bytes(map_size, max_h)
	var footprint := Vector2i(18, 14)
	var bldg_x := -21.0
	var bldg_z := 13.0
	var config := {
		"sample_stride": 2.0,
		"edge_inset": 0.18,
		"max_samples_per_axis": 5,
		"search_radius": 3,
		"max_float_gap": 0.75,
		"max_embed_depth": 1.5,
		"max_height_range": 5.0,
		"float_weight": 8.0,
		"embed_weight": 3.0,
		"float_peak_weight": 6.0,
		"embed_peak_weight": 4.0,
		"preferred_weight": 0.3,
		"balance_weight": 0.85
	}

	var native_start_us := Time.get_ticks_usec()
	var native_result: Dictionary
	for i in 200:
		native_result = native.resolve_world_map_building_support(
			height_bytes,
			map_size,
			bldg_x,
			bldg_z,
			footprint,
			max_h,
			half,
			config
		)
	var native_ms := float(Time.get_ticks_usec() - native_start_us) / 1000.0
	if not _expect(not native_result.is_empty(), "native support result should not be empty"):
		return 1

	var reference_start_us := Time.get_ticks_usec()
	var reference_result: Dictionary
	for i in 200:
		reference_result = _reference_resolve_support(height_bytes, map_size, bldg_x, bldg_z, footprint, max_h, half, config)
	var reference_ms := float(Time.get_ticks_usec() - reference_start_us) / 1000.0

	var numeric_keys := [
		"resolved_y",
		"avg_float_gap",
		"avg_embed_depth",
		"max_float_gap",
		"max_embed_depth",
		"score",
		"preferred_y",
		"mean_height",
		"median_height",
		"min_height",
		"max_height",
		"height_range"
	]
	for key in numeric_keys:
		if not _expect(abs(float(native_result.get(key, 0.0)) - float(reference_result.get(key, 0.0))) <= 0.001, "%s should match reference" % key):
			return 1
	if not _expect(bool(native_result.get("valid", false)) == bool(reference_result.get("valid", false)), "valid flag should match reference"):
		return 1
	if not _expect(int(native_result.get("sample_count", -1)) == int(reference_result.get("sample_count", -2)), "sample count should match reference"):
		return 1

	print("[WORLD_MAP_BUILDING_SUPPORT_NATIVE_TEST] PASS native_ms=%.3f reference_ms=%.3f resolved_y=%.3f valid=%s samples=%d" % [
		native_ms,
		reference_ms,
		float(native_result.get("resolved_y", 0.0)),
		str(bool(native_result.get("valid", false))),
		int(native_result.get("sample_count", 0))
	])
	return 0


func _make_height_bytes(map_size: int, max_h: float) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(map_size * map_size)
	var half := map_size / 2
	for z in map_size:
		for x in map_size:
			var wx := float(x - half)
			var wz := float(z - half)
			var h := 13.0 + sin(wx * 0.11) * 1.2 + cos(wz * 0.09) * 0.9 + float((x + z) % 7) * 0.08
			bytes[z * map_size + x] = _encode_height_byte(h, max_h)
	return bytes


func _reference_resolve_support(height_bytes: PackedByteArray, map_size: int, bldg_x: float, bldg_z: float, footprint: Vector2i, max_h: float, half: int, config: Dictionary) -> Dictionary:
	var preferred_y := _sample_building_pad_height(height_bytes, map_size, bldg_x, bldg_z, footprint, max_h, half)
	var result: Dictionary = FoundationSupportScript.resolve_footprint_support(
		func(wx: float, wz: float) -> float:
			return _sample_support_height(height_bytes, map_size, wx, wz, max_h, half),
		Vector2(bldg_x, bldg_z),
		footprint,
		preferred_y,
		config
	)
	return result


func _sample_building_pad_height(height_bytes: PackedByteArray, map_size: int, bldg_x: float, bldg_z: float, footprint: Vector2i, max_h: float, half: int) -> float:
	var min_x = clampi(int(floor(bldg_x)) + half, 0, map_size - 1)
	var min_z = clampi(int(floor(bldg_z)) + half, 0, map_size - 1)
	var max_x = clampi(int(ceil(bldg_x + footprint.x - 1.0)) + half, 0, map_size - 1)
	var max_z = clampi(int(ceil(bldg_z + footprint.y - 1.0)) + half, 0, map_size - 1)
	var height_sum = 0.0
	var sample_count = 0
	for cz in range(min_z, max_z + 1, 2):
		for cx in range(min_x, max_x + 1, 2):
			height_sum += clampf(float(height_bytes[cz * map_size + cx]) / 255.0 * max_h, 1.0, 28.0)
			sample_count += 1
	if sample_count <= 0:
		return 12.0
	return height_sum / float(sample_count)


func _sample_support_height(height_bytes: PackedByteArray, map_size: int, wx: float, wz: float, max_h: float, half: int) -> float:
	var px = clampi(int(floor(wx)) + half, 0, map_size - 1)
	var pz = clampi(int(floor(wz)) + half, 0, map_size - 1)
	return clampf(float(height_bytes[pz * map_size + px]) / 255.0 * max_h, 1.0, 28.0)


func _encode_height_byte(height: float, max_h: float) -> int:
	return int(round(clampf(height / max_h, 0.0, 1.0) * 255.0))


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_BUILDING_SUPPORT_NATIVE_TEST] FAIL: %s" % message)
	return false
