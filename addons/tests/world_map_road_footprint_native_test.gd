extends SceneTree

const WorldMapGeneratorScript := preload("res://world_map_generator/world_map_generator.gd")

var _native: Object = null
var _reference_generator: WorldMapGenerator = null
var _native_generator: WorldMapGenerator = null


func _init() -> void:
	var exit_code := _run()
	_release_generators()
	_release_native()
	quit(exit_code)


func _release_generators() -> void:
	if _reference_generator != null:
		_reference_generator.release_runtime_resources()
		_reference_generator = null
	if _native_generator != null:
		_native_generator.release_runtime_resources()
		_native_generator = null


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
	if not _expect(native != null and native.has_method("footprint_hits_world_map_road_segments"), "native dictionary road footprint predicate should be bound"):
		return 1
	if not _expect(native != null and native.has_method("footprint_hits_packed_world_map_road_segments"), "native packed road footprint predicate should be bound"):
		return 1

	var road_segments := [
		{"from": Vector2(-140.0, -60.0), "to": Vector2(140.0, -20.0), "width": 8.0},
		{"from": Vector2(-35.0, -120.0), "to": Vector2(-35.0, 120.0), "width": 5.5},
		{"from": Vector2(80.0, 70.0), "to": Vector2(170.0, 130.0), "width": 6.0},
		{"from": Vector2(-175.0, 145.0), "to": Vector2(-65.0, 105.0)}
	]
	_reference_generator = WorldMapGeneratorScript.new()
	_reference_generator.native_road_footprint_enabled = false
	_native_generator = WorldMapGeneratorScript.new()
	_native_generator.native_road_footprint_enabled = true
	var packed_index: Dictionary = _reference_generator._build_road_segment_spatial_index(road_segments)
	var packed_segments: PackedFloat32Array = packed_index.get("packed_segments", PackedFloat32Array())
	if not _expect(packed_segments.size() == road_segments.size() * 5, "packed road segments should contain five floats per segment"):
		return 1

	var mismatches := 0
	var first_mismatch := ""
	var reference_start_us := Time.get_ticks_usec()
	var reference_hits := 0
	var cases: Array = []
	for z in range(-170, 171, 9):
		for x in range(-180, 191, 10):
			cases.append({
				"x": float(x),
				"z": float(z),
				"footprint": Vector2i(8 + abs(x) % 29, 7 + abs(z) % 23)
			})
	for case in cases:
		_reference_generator._road_segment_spatial_index = {}
		var reference := _reference_generator._footprint_hits_road_segments(
			float(case.x),
			float(case.z),
			case.footprint,
			road_segments
		)
		if reference:
			reference_hits += 1
	var reference_ms := float(Time.get_ticks_usec() - reference_start_us) / 1000.0

	var native_start_us := Time.get_ticks_usec()
	var native_hits := 0
	var checked_segments := 0
	for case in cases:
		var native_result: Dictionary = native.footprint_hits_packed_world_map_road_segments(
			packed_segments,
			float(case.x),
			float(case.z),
			case.footprint
		)
		if not _expect(native_result.has("hit"), "native result should include hit flag"):
			return 1
		var native_hit := bool(native_result.get("hit", false))
		checked_segments += int(native_result.get("checked_segment_count", 0))
		if native_hit:
			native_hits += 1

		_reference_generator._road_segment_spatial_index = {}
		var reference := _reference_generator._footprint_hits_road_segments(
			float(case.x),
			float(case.z),
			case.footprint,
			road_segments
		)
		if native_hit != reference:
			mismatches += 1
			if first_mismatch.is_empty():
				first_mismatch = "x=%.1f z=%.1f footprint=%s native=%s reference=%s" % [
					float(case.x),
					float(case.z),
					str(case.footprint),
					str(native_hit),
					str(reference)
				]
	var native_ms := float(Time.get_ticks_usec() - native_start_us) / 1000.0

	var stats := {
		"support_road_native_calls": 0,
		"support_road_gdscript_calls": 0,
		"support_road_checked_segments": 0
	}
	_native_generator._road_segment_spatial_index = _native_generator._build_road_segment_spatial_index(road_segments)
	var routed_hit := _native_generator._footprint_hits_road_segments(25.0, -44.0, Vector2i(18, 14), road_segments, stats)
	var direct_routed_result: Dictionary = native.footprint_hits_packed_world_map_road_segments(
		_native_generator._road_segment_spatial_index.get("packed_segments", PackedFloat32Array()),
		25.0,
		-44.0,
		Vector2i(18, 14)
	)
	if not _expect(routed_hit == bool(direct_routed_result.get("hit", false)), "generator route should match direct native result"):
		return 1
	if not _expect(int(stats.get("support_road_native_calls", 0)) == 1, "generator route should count one native road predicate call"):
		return 1
	if not _expect(int(stats.get("support_road_gdscript_calls", 0)) == 0, "generator route should avoid GDScript road predicate fallback"):
		return 1

	if mismatches > 0:
		printerr("[WORLD_MAP_ROAD_FOOTPRINT_NATIVE_TEST] FAIL mismatches=%d %s" % [mismatches, first_mismatch])
		return 1
	if not _expect(native_hits == reference_hits, "native and reference hit counts should match"):
		return 1

	print("[WORLD_MAP_ROAD_FOOTPRINT_NATIVE_TEST] PASS cases=%d hits=%d native_ms=%.3f reference_ms=%.3f checked_segments=%d" % [
		cases.size(),
		native_hits,
		native_ms,
		reference_ms,
		checked_segments
	])
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_ROAD_FOOTPRINT_NATIVE_TEST] FAIL: %s" % message)
	return false
