extends SceneTree

const WorldMapGeneratorScript := preload("res://world_map_generator/world_map_generator.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	if not _expect(ClassDB.class_exists("PrefabGeometryNative"), "PrefabGeometryNative should be available"):
		return 1
	if not _expect(Thread.is_main_thread(), "test should start on the main thread"):
		return 1

	var main_generator: WorldMapGenerator = WorldMapGeneratorScript.new()
	main_generator.world_seed = 12345
	main_generator.noise_freq = 0.1
	main_generator.terrain_height = 10.0
	main_generator._init_noise()
	var main_result: Dictionary = main_generator._generate_height_biome_bytes(128, 25.0)
	if not _expect(str(main_result.get("backend", "")) == "native", "main-thread generation should use native backend"):
		return 1
	if not _expect(bool(main_generator.get_telemetry_snapshot().get("native_height_biome_can_run_now", false)), "main-thread telemetry should report native backend runnable"):
		return 1

	var thread := Thread.new()
	var err := thread.start(Callable(self, "_threaded_height_biome_probe"))
	if not _expect(err == OK, "height/biome thread should start"):
		return 1
	var threaded_result_variant: Variant = thread.wait_to_finish()
	if not _expect(threaded_result_variant is Dictionary, "threaded probe should return a dictionary"):
		return 1
	var threaded_result: Dictionary = threaded_result_variant
	if not _expect(not bool(threaded_result.get("is_main_thread", true)), "threaded probe should run off the main thread"):
		return 1
	if not _expect(str(threaded_result.get("backend", "")) == "native", "worker-thread generation should use worker-safe native backend"):
		return 1
	if not _expect(int(threaded_result.get("height_byte_count", 0)) == 128 * 128, "threaded height bytes should be complete"):
		return 1
	if not _expect(int(threaded_result.get("biome_byte_count", 0)) == 128 * 128, "threaded biome bytes should be complete"):
		return 1
	if not _expect(int(threaded_result.get("height_reference_mismatch_count", 999999)) <= 16, "threaded native height bytes should stay within byte-threshold tolerance"):
		return 1
	if not _expect(int(threaded_result.get("height_reference_max_delta", 999999)) <= 1, "threaded native height byte drift should be at most one byte"):
		return 1
	if not _expect(bool(threaded_result.get("biome_matches_reference", false)), "threaded native biome bytes should match GDScript reference"):
		return 1
	if not _expect(bool(threaded_result.get("can_run_native", false)), "threaded telemetry should report native backend runnable in worker"):
		return 1

	print("[WORLD_MAP_HEIGHT_BIOME_THREAD_POLICY_TEST] PASS")
	return 0


func _threaded_height_biome_probe() -> Dictionary:
	var generator: WorldMapGenerator = WorldMapGeneratorScript.new()
	generator.world_seed = 12345
	generator.noise_freq = 0.1
	generator.terrain_height = 10.0
	generator._init_noise()
	var result: Dictionary = generator._generate_height_biome_bytes(128, 25.0)
	var reference: Dictionary = generator._generate_height_biome_bytes_gdscript(128, 25.0)
	var telemetry := generator.get_telemetry_snapshot()
	var height_bytes: PackedByteArray = result.get("height_bytes", PackedByteArray())
	var biome_bytes: PackedByteArray = result.get("biome_bytes", PackedByteArray())
	return {
		"is_main_thread": Thread.is_main_thread(),
		"backend": str(result.get("backend", "")),
		"height_byte_count": height_bytes.size(),
		"biome_byte_count": biome_bytes.size(),
		"height_reference_mismatch_count": _count_byte_mismatches(height_bytes, reference.get("height_bytes", PackedByteArray())),
		"height_reference_max_delta": _max_byte_delta(height_bytes, reference.get("height_bytes", PackedByteArray())),
		"biome_matches_reference": biome_bytes == reference.get("biome_bytes", PackedByteArray()),
		"can_run_native": bool(telemetry.get("native_height_biome_can_run_now", true))
	}


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_HEIGHT_BIOME_THREAD_POLICY_TEST] FAIL: %s" % message)
	return false


func _count_byte_mismatches(a: PackedByteArray, b: PackedByteArray) -> int:
	if a.size() != b.size():
		return 999999
	var mismatch_count := 0
	for i in a.size():
		if a[i] != b[i]:
			mismatch_count += 1
	return mismatch_count


func _max_byte_delta(a: PackedByteArray, b: PackedByteArray) -> int:
	if a.size() != b.size():
		return 999999
	var max_delta := 0
	for i in a.size():
		max_delta = maxi(max_delta, absi(int(a[i]) - int(b[i])))
	return max_delta
