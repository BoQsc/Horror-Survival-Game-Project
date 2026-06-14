extends SceneTree

const WorldMapGeneratorScript := preload("res://world_map_generator/world_map_generator.gd")

var _native: Object = null
var _generator: WorldMapGenerator = null


func _init() -> void:
	var exit_code := _run()
	_release_generator()
	_release_native()
	quit(exit_code)


func _release_generator() -> void:
	if _generator != null:
		_generator.release_runtime_resources()
		_generator = null


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
	if not _expect(native != null and native.has_method("build_world_map_excavation_modifications"), "native excavation builder should be bound"):
		return 1

	var segments := _make_segments()
	var spawn_origin := Vector3(-17.25, 9.0, 23.75)
	var native_start_us := Time.get_ticks_usec()
	var native_mods: Array
	for i in 200:
		native_mods = native.build_world_map_excavation_modifications(segments, spawn_origin)
	var native_ms := float(Time.get_ticks_usec() - native_start_us) / 1000.0

	var reference_start_us := Time.get_ticks_usec()
	var reference_mods: Array
	for i in 200:
		reference_mods = _reference_modifications(segments, spawn_origin)
	var reference_ms := float(Time.get_ticks_usec() - reference_start_us) / 1000.0

	if not _expect(native_mods.size() == reference_mods.size(), "native excavation count should match reference"):
		return 1
	for i in native_mods.size():
		if not _expect(_modification_matches(native_mods[i], reference_mods[i]), "native excavation modification %d should match reference" % i):
			return 1

	_generator = WorldMapGeneratorScript.new()
	var generator := _generator
	var key := generator._prefab_rotation_key("synthetic_excavation_prefab", 0)
	generator._prefab_rotation_cache[key] = {"excavation_segments": segments}
	var appended: Array = []
	var wrapper_result: Dictionary = generator._append_baked_excavation_modifications(appended, "synthetic_excavation_prefab", spawn_origin, 0)
	if not _expect(str(wrapper_result.get("backend", "")) == "native", "generator wrapper should use native excavation backend"):
		return 1
	if not _expect(appended.size() == reference_mods.size(), "generator wrapper should append native modifications"):
		return 1
	for i in appended.size():
		if not _expect(_modification_matches(appended[i], reference_mods[i]), "generator wrapper modification %d should match reference" % i):
			return 1

	print("[WORLD_MAP_EXCAVATION_NATIVE_TEST] PASS native_ms=%.3f reference_ms=%.3f mods=%d" % [
		native_ms,
		reference_ms,
		native_mods.size()
	])
	return 0


func _make_segments() -> Array:
	return [
		{"x": 0, "z": 0, "min_y": -3, "max_y": 2},
		{"x": 4, "z": -2, "min_y": -1, "max_y": 0},
		{"x": -3, "z": 5, "min_y": 2, "max_y": 1},
		{"x": 8, "z": 7, "min_y": -4, "max_y": -1}
	]


func _reference_modifications(segments: Array, spawn_origin: Vector3) -> Array:
	var result: Array = []
	for segment in segments:
		var world_y_min := spawn_origin.y + float(segment.get("min_y", 0))
		var world_y_max := spawn_origin.y + float(segment.get("max_y", -1)) + 1.0
		if world_y_max <= world_y_min:
			continue
		var world_x := int(floor(spawn_origin.x)) + int(segment.get("x", 0))
		var world_z := int(floor(spawn_origin.z)) + int(segment.get("z", 0))
		result.append({
			"brush_pos": [
				float(world_x) + 0.5,
				(world_y_min + world_y_max) * 0.5,
				float(world_z) + 0.5
			],
			"radius": 0.6,
			"value": 10.0,
			"shape": 2,
			"layer": 0,
			"y_min": world_y_min,
			"y_max": world_y_max,
			"material_id": -1
		})
	return result


func _modification_matches(a: Dictionary, b: Dictionary) -> bool:
	var brush_a: Array = a.get("brush_pos", [])
	var brush_b: Array = b.get("brush_pos", [])
	if brush_a.size() != brush_b.size():
		return false
	for i in brush_a.size():
		if absf(float(brush_a[i]) - float(brush_b[i])) > 0.001:
			return false
	for key in ["radius", "value", "y_min", "y_max"]:
		if absf(float(a.get(key, 0.0)) - float(b.get(key, 0.0))) > 0.001:
			return false
	for key in ["shape", "layer", "material_id"]:
		if int(a.get(key, 0)) != int(b.get(key, 0)):
			return false
	return true


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_EXCAVATION_NATIVE_TEST] FAIL: %s" % message)
	return false
