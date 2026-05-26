extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	root.add_child(manager)
	if not _expect(ClassDB.class_exists("PrefabGeometryNative"), "PrefabGeometryNative should be available"):
		return 1

	var noise := FastNoiseLite.new()
	noise.seed = 12345
	noise.frequency = 0.073
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM

	var origin_x := -32
	var origin_z := 48
	var chunk_stride := 16
	var step := 4
	var samples: PackedFloat32Array = manager._build_vegetation_noise_samples(noise, origin_x, origin_z, chunk_stride, step, true)
	if not _expect(samples.size() == 16, "native noise samples should match chunk sample count"):
		return 1

	var index := 0
	for x in range(0, chunk_stride, step):
		for z in range(0, chunk_stride, step):
			var expected := noise.get_noise_2d(origin_x + x, origin_z + z)
			if not _expect(is_equal_approx(samples[index], expected), "native noise sample should match FastNoiseLite.get_noise_2d"):
				return 1
			index += 1

	var disabled: PackedFloat32Array = manager._build_vegetation_noise_samples(noise, origin_x, origin_z, chunk_stride, step, false)
	if not _expect(disabled.is_empty(), "disabled noise sampling should stay empty"):
		return 1

	var telemetry := manager.get_telemetry_snapshot()
	var counts: Dictionary = telemetry.get("vegetation_noise_sample_backend_counts", {})
	if not _expect(int(counts.get("native_calls", 0)) == 1, "noise sample telemetry should count native calls"):
		return 1
	if not _expect(int(counts.get("native_samples", 0)) == samples.size(), "noise sample telemetry should count native samples"):
		return 1
	if not _expect(int(counts.get("disabled_calls", 0)) == 1, "noise sample telemetry should count disabled calls"):
		return 1

	manager.free()
	print("[VEGETATION_NOISE_SAMPLES_NATIVE_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_NOISE_SAMPLES_NATIVE_TEST] FAIL: %s" % message)
	return false
