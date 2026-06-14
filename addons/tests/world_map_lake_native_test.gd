extends SceneTree

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
	_native = PrefabGeometryNative.new()
	var native := _native
	if not _expect(native != null and native.has_method("apply_world_map_lakes"), "native lake backend should be bound"):
		return 1

	var map_size := 128
	var total := map_size * map_size
	var max_h := 25.0
	var terrain_height := 10.0
	var water_level := 13.0
	var lake_threshold := 0.35
	var road_width := 8.0
	var road_blend_margin := 4.0
	var road_block_threshold := 240
	var world_seed := 12345
	var water_bytes := PackedByteArray()
	water_bytes.resize(total)
	var road_bytes := PackedByteArray()
	road_bytes.resize(total * 2)
	var height_bytes := PackedByteArray()
	height_bytes.resize(total)
	for i in total:
		height_bytes[i] = _encode_height_byte(20.0, max_h)
	for z in range(16, 112):
		var idx := (z * map_size + 64) * 2
		road_bytes[idx] = 255

	var native_start_us := Time.get_ticks_usec()
	var native_result: Dictionary = native.apply_world_map_lakes(
		water_bytes,
		road_bytes,
		height_bytes,
		map_size,
		map_size,
		world_seed,
		lake_threshold,
		road_width,
		road_blend_margin,
		road_block_threshold,
		terrain_height,
		water_level,
		max_h,
		true
	)
	var native_ms := float(Time.get_ticks_usec() - native_start_us) / 1000.0
	if not _expect(native_result.get("water_bytes", null) is PackedByteArray, "native result should include water bytes"):
		return 1
	if not _expect(native_result.get("height_bytes", null) is PackedByteArray, "native result should include height bytes"):
		return 1

	var reference_start_us := Time.get_ticks_usec()
	var reference_result := _reference_apply_lakes(
		water_bytes,
		road_bytes,
		height_bytes,
		map_size,
		map_size,
		world_seed,
		lake_threshold,
		road_width,
		road_blend_margin,
		road_block_threshold,
		terrain_height,
		water_level,
		max_h,
		true
	)
	var reference_ms := float(Time.get_ticks_usec() - reference_start_us) / 1000.0

	if not _expect_byte_arrays_close(
		native_result.get("water_bytes", PackedByteArray()),
		reference_result.get("water_bytes", PackedByteArray()),
		8,
		"native water mask should match reference lake pass"
	):
		return 1
	if not _expect_byte_arrays_close(
		native_result.get("height_bytes", PackedByteArray()),
		reference_result.get("height_bytes", PackedByteArray()),
		8,
		"native carved heightmap should match reference lake pass"
	):
		return 1
	if not _expect(int(native_result.get("water_pixel_count", -1)) == int(reference_result.get("water_pixel_count", -2)), "water pixel count should match reference"):
		return 1
	if not _expect(int(native_result.get("height_carve_count", -1)) == int(reference_result.get("height_carve_count", -2)), "height carve count should match reference"):
		return 1

	print("[WORLD_MAP_LAKE_NATIVE_TEST] PASS native_ms=%.3f reference_ms=%.3f water=%d carved=%d" % [
		native_ms,
		reference_ms,
		int(native_result.get("water_pixel_count", 0)),
		int(native_result.get("height_carve_count", 0))
	])
	native = null
	return 0


func _reference_apply_lakes(
	water_data: PackedByteArray,
	road_data: PackedByteArray,
	height_data: PackedByteArray,
	map_size: int,
	world_size: int,
	world_seed: int,
	lake_threshold: float,
	road_width: float,
	road_blend_margin: float,
	road_block_threshold: int,
	terrain_height: float,
	water_level: float,
	max_h: float,
	deep_lakes_enabled: bool
) -> Dictionary:
	var water_bytes := water_data.duplicate()
	var height_bytes := height_data.duplicate()
	var lake_noise = FastNoiseLite.new()
	lake_noise.seed = world_seed + 300
	lake_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	lake_noise.frequency = 0.0008
	lake_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	var water_road_buffer := road_width * 0.5 + road_blend_margin
	var lake_cutoff := lake_threshold - 0.05
	var shore_submerge := 1.25
	var basin_depth_max := clampf(terrain_height * 0.65, 2.5, 8.0)
	var half_world := float(world_size) * 0.5
	var sample_scale := float(world_size) / float(map_size)
	var water_pixel_count := 0
	var height_carve_count := 0
	var road_blocked_pixel_count := 0
	var near_road_blocked_pixel_count := 0
	for z in map_size:
		var wz := float(z) * sample_scale - half_world
		var row_offset := z * map_size
		for x in map_size:
			var wx := float(x) * sample_scale - half_world
			var idx := row_offset + x
			var ridx := idx * 2
			if road_data[ridx] >= road_block_threshold:
				road_blocked_pixel_count += 1
				continue
			var near_road := false
			for dr in range(-int(water_road_buffer), int(water_road_buffer) + 1, 4):
				var check_x := x + dr
				if check_x >= 0 and check_x < map_size:
					var check_ridx := (z * map_size + check_x) * 2
					if road_data[check_ridx] >= road_block_threshold:
						near_road = true
						break
				var check_z := z + dr
				if check_z >= 0 and check_z < map_size:
					var check_ridx := (check_z * map_size + x) * 2
					if road_data[check_ridx] >= road_block_threshold:
						near_road = true
						break
			if near_road:
				near_road_blocked_pixel_count += 1
				continue
			var lake_val := lake_noise.get_noise_2d(wx, wz)
			if lake_val <= lake_cutoff:
				continue
			water_bytes[idx] = 255
			water_pixel_count += 1
			if not deep_lakes_enabled:
				continue
			var depth_t := clampf((lake_val - lake_cutoff) / maxf(0.001, 1.0 - lake_cutoff), 0.0, 1.0)
			depth_t = depth_t * depth_t * (3.0 - 2.0 * depth_t)
			var current_h := float(height_bytes[idx]) / 255.0 * max_h
			var target_h := water_level - shore_submerge - basin_depth_max * depth_t
			if current_h > target_h:
				height_bytes[idx] = _encode_height_byte(target_h, max_h)
				height_carve_count += 1
	return {
		"water_bytes": water_bytes,
		"height_bytes": height_bytes,
		"water_pixel_count": water_pixel_count,
		"height_carve_count": height_carve_count,
		"road_blocked_pixel_count": road_blocked_pixel_count,
		"near_road_blocked_pixel_count": near_road_blocked_pixel_count
	}


func _encode_height_byte(height: float, max_h: float) -> int:
	return int(round(clampf(height / max_h, 0.0, 1.0) * 255.0))


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_LAKE_NATIVE_TEST] FAIL: %s" % message)
	return false


func _expect_byte_arrays_close(native_bytes: PackedByteArray, reference_bytes: PackedByteArray, max_mismatches: int, message: String) -> bool:
	if native_bytes.size() != reference_bytes.size():
		printerr("[WORLD_MAP_LAKE_NATIVE_TEST] FAIL: %s: size native=%d reference=%d" % [
			message,
			native_bytes.size(),
			reference_bytes.size()
		])
		return false
	var mismatch_count := 0
	var first_mismatch := ""
	for i in native_bytes.size():
		if native_bytes[i] == reference_bytes[i]:
			continue
		mismatch_count += 1
		if first_mismatch.is_empty():
			first_mismatch = "index=%d native=%d reference=%d" % [i, native_bytes[i], reference_bytes[i]]
	if mismatch_count <= max_mismatches:
		return true
	printerr("[WORLD_MAP_LAKE_NATIVE_TEST] FAIL: %s: mismatches=%d %s" % [
		message,
		mismatch_count,
		first_mismatch
	])
	return false
