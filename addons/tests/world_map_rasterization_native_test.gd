extends SceneTree

const WorldMapGeneratorScript := preload("res://world_map_generator/world_map_generator.gd")
const MaterialRegistry := preload("res://modules/world_generation/material_registry.gd")

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
	if not _expect(native != null and native.has_method("rasterize_world_map_segments"), "native rasterizer should be bound"):
		return 1

	var generator: WorldMapGenerator = WorldMapGeneratorScript.new()
	generator.world_seed = 12345
	generator.road_width = 8.0
	generator.building_path_width = 2.5
	generator._init_noise()

	var max_h := 25.0
	var road_segments := [
		{"from": Vector2(-40.0, -12.0), "to": Vector2(48.0, 31.0), "width": 8.0, "kind": "arterial"},
		{"from": Vector2(-25.0, 42.0), "to": Vector2(55.0, 42.0), "width": 5.5, "kind": "main"}
	]
	var path_segments := [
		{"from": Vector2(-12.0, -5.0), "to": Vector2(18.0, 9.0), "width": 2.5, "from_y": 11.0, "to_y": 13.5},
		{"from": Vector2(20.0, 11.0), "to": Vector2(20.0, 36.0), "width": 2.85, "from_y": 13.5, "to_y": 12.5}
	]

	var road_check := _compare_segment_pass(generator, native, road_segments, max_h, 8.0, false)
	if not bool(road_check.get("ok", false)):
		return 1
	var path_check := _compare_segment_pass(generator, native, path_segments, max_h, generator.building_path_width, true)
	if not bool(path_check.get("ok", false)):
		return 1

	print("[WORLD_MAP_RASTERIZATION_NATIVE_TEST] PASS road_native_ms=%.3f road_reference_ms=%.3f road_touched=%d path_native_ms=%.3f path_reference_ms=%.3f path_touched=%d" % [
		float(road_check.get("native_ms", 0.0)),
		float(road_check.get("reference_ms", 0.0)),
		int(road_check.get("touched_pixel_count", 0)),
		float(path_check.get("native_ms", 0.0)),
		float(path_check.get("reference_ms", 0.0)),
		int(path_check.get("touched_pixel_count", 0))
	])
	return 0


func _compare_segment_pass(generator: WorldMapGenerator, native: Object, segments: Array, max_h: float, default_width: float, path_mode: bool) -> Dictionary:
	var map_size := WorldMapGenerator.MAP_SIZE
	var total := map_size * map_size
	var base_height := PackedByteArray()
	base_height.resize(total)
	base_height.fill(_encode_height_byte(18.0, max_h))
	var base_biome := PackedByteArray()
	base_biome.resize(total)
	base_biome.fill(MaterialRegistry.GRASS)
	var base_road := PackedByteArray()
	base_road.resize(total * 2)

	var native_height := base_height.duplicate()
	var native_biome := base_biome.duplicate()
	var native_road := base_road.duplicate()
	var native_start_us := Time.get_ticks_usec()
	var native_result: Dictionary = native.rasterize_world_map_segments(
		segments,
		native_height,
		native_biome,
		native_road,
		map_size,
		generator.world_seed,
		WorldMapGenerator.ROAD_BLEND_MARGIN,
		default_width,
		max_h,
		MaterialRegistry.ROAD,
		path_mode
	)
	var native_ms := float(Time.get_ticks_usec() - native_start_us) / 1000.0
	if not _expect(native_result.get("height_bytes", null) is PackedByteArray, "native result should include height bytes"):
		return {"ok": false}
	if not _expect(native_result.get("biome_bytes", null) is PackedByteArray, "native result should include biome bytes"):
		return {"ok": false}
	if not _expect(native_result.get("road_bytes", null) is PackedByteArray, "native result should include road bytes"):
		return {"ok": false}

	var reference_height := base_height.duplicate()
	var reference_biome := base_biome.duplicate()
	var reference_road := base_road.duplicate()
	var reference_start_us := Time.get_ticks_usec()
	var reference_result: Dictionary
	if path_mode:
		reference_result = generator._rasterize_paths(segments, reference_height, reference_biome, reference_road, max_h, map_size / 2)
	else:
		reference_result = generator._rasterize_roads(segments, reference_height, reference_biome, reference_road, max_h, map_size / 2, default_width)
	var reference_ms := float(Time.get_ticks_usec() - reference_start_us) / 1000.0

	if not _expect_byte_arrays_close(native_result.get("height_bytes", PackedByteArray()), reference_height, 32, 1, "height bytes should match native rasterizer reference"):
		return {"ok": false}
	if not _expect_byte_arrays_close(native_result.get("biome_bytes", PackedByteArray()), reference_biome, 0, 0, "biome bytes should match native rasterizer reference"):
		return {"ok": false}
	if not _expect_byte_arrays_close(native_result.get("road_bytes", PackedByteArray()), reference_road, 32, 1, "road bytes should match native rasterizer reference"):
		return {"ok": false}
	if not _expect(int(native_result.get("segment_count", -1)) == int(reference_result.get("segment_count", -2)), "native segment count should match reference"):
		return {"ok": false}
	if not _expect(int(native_result.get("touched_pixel_count", -1)) == int(reference_result.get("touched_pixel_count", -2)), "native touched pixel count should match reference"):
		return {"ok": false}

	return {
		"ok": true,
		"native_ms": native_ms,
		"reference_ms": reference_ms,
		"touched_pixel_count": int(native_result.get("touched_pixel_count", 0))
	}


func _encode_height_byte(height: float, max_h: float) -> int:
	return int(round(clampf(height / max_h, 0.0, 1.0) * 255.0))


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_RASTERIZATION_NATIVE_TEST] FAIL: %s" % message)
	return false


func _expect_byte_arrays_close(native_bytes: PackedByteArray, reference_bytes: PackedByteArray, max_mismatches: int, max_delta: int, message: String) -> bool:
	if native_bytes.size() != reference_bytes.size():
		printerr("[WORLD_MAP_RASTERIZATION_NATIVE_TEST] FAIL: %s: size native=%d reference=%d" % [
			message,
			native_bytes.size(),
			reference_bytes.size()
		])
		return false
	var mismatch_count := 0
	var first_mismatch := ""
	for i in native_bytes.size():
		if abs(int(native_bytes[i]) - int(reference_bytes[i])) <= max_delta:
			continue
		mismatch_count += 1
		if first_mismatch.is_empty():
			first_mismatch = "index=%d native=%d reference=%d" % [i, native_bytes[i], reference_bytes[i]]
		if mismatch_count > max_mismatches:
			break
	if mismatch_count <= max_mismatches:
		return true
	printerr("[WORLD_MAP_RASTERIZATION_NATIVE_TEST] FAIL: %s: mismatches>%d %s" % [
		message,
		max_mismatches,
		first_mismatch
	])
	return false
