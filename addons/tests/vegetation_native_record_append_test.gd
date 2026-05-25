extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	if not ClassDB.class_exists("PrefabGeometryNative"):
		return _fail("PrefabGeometryNative is not registered")

	var native := ClassDB.instantiate("PrefabGeometryNative")
	if native == null or not native.has_method("build_vegetation_instances"):
		return _fail("native vegetation builder is unavailable")

	var config := {
		"chunk_stride": 4,
		"step": 4,
		"chunk_origin_x": 0,
		"chunk_origin_z": 0,
		"chunk_world_pos": Vector3.ZERO,
		"base_transform": Transform3D.IDENTITY,
		"rotation_fix": Vector3.ZERO,
		"road_clearance": 0.0,
		"procedural_roads_enabled": false,
		"procedural_road_spacing": 100.0,
		"procedural_road_width": 8.0,
		"world_map_active": false,
		"road_block_values": PackedFloat32Array(),
		"use_road_block_values": false,
		"water_block_values": PackedFloat32Array(),
		"use_water_block_values": false,
		"water_level": -100.0,
		"noise_values": PackedFloat32Array(),
		"use_noise": false,
		"use_water_density": false,
		"noise_threshold": 0.0,
		"scale_min": 1.0,
		"scale_max": 1.0,
		"scale_multiplier": 1.0,
		"y_offset": 0.0,
		"record_random_scale_factor": true
	}
	var height_map := PackedFloat32Array([2.0])
	var records: Array = native.build_vegetation_instances(config, height_map)
	if not _expect(records.size() == 1, "native builder should create one record"):
		return 1

	var record: Dictionary = records[0]
	for key in ["world_pos", "local_pos", "hit_pos", "rotation_angle", "rotation", "random_scale_factor", "index", "alive", "scale", "placed_by_player", "transform"]:
		if not _expect(record.has(key), "native record missing key %s" % key):
			return 1
	if not _expect(is_equal_approx(float(record.get("rotation", 0.0)), float(record.get("rotation_angle", 1.0))), "rotation aliases should match"):
		return 1

	var manager: VegetationManager = VegetationManagerScript.new()
	var target: Array = []
	manager._append_native_generated_instances(target, records)
	if not _expect(target.size() == 1, "bulk append should add native record"):
		manager.free()
		return 1
	if not _expect(target[0].has("rotation"), "bulk-appended record should preserve rotation key"):
		manager.free()
		return 1
	var telemetry := manager.get_telemetry_snapshot()
	var append_counts: Dictionary = telemetry.get("vegetation_native_record_append_counts", {})
	if not _expect(int(append_counts.get("bulk_records", 0)) == 1, "bulk append telemetry should count record"):
		manager.free()
		return 1

	manager.free()
	print("[VEGETATION_NATIVE_RECORD_APPEND_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_NATIVE_RECORD_APPEND_TEST] FAIL: %s" % message)
	return false

func _fail(message: String) -> int:
	printerr("[VEGETATION_NATIVE_RECORD_APPEND_TEST] FAIL: %s" % message)
	return 1
