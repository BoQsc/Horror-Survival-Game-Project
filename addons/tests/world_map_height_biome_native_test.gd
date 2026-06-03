extends SceneTree

const WorldMapGeneratorScript := preload("res://world_map_generator/world_map_generator.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	if not _expect(ClassDB.class_exists("PrefabGeometryNative"), "PrefabGeometryNative should be available"):
		return 1
	var native = ClassDB.instantiate("PrefabGeometryNative")
	if not _expect(native != null and native.has_method("build_world_map_height_biome_bytes"), "native height/biome backend should be bound"):
		return 1

	var native_total_us := 0
	var reference_total_us := 0
	for seed in [12345, 77, -901]:
		var generator: WorldMapGenerator = WorldMapGeneratorScript.new()
		generator.world_seed = seed
		generator.noise_freq = 0.1
		generator.terrain_height = 10.0
		generator._init_noise()
		var max_height := generator.terrain_height * 2.5
		var native_start_us := Time.get_ticks_usec()
		var native_result: Dictionary = generator._generate_height_biome_bytes(256, max_height)
		native_total_us += Time.get_ticks_usec() - native_start_us
		var reference_start_us := Time.get_ticks_usec()
		var reference_result: Dictionary = generator._generate_height_biome_bytes_gdscript(256, max_height)
		reference_total_us += Time.get_ticks_usec() - reference_start_us
		if not _expect(str(native_result.get("backend", "")) == "native", "native backend should be selected"):
			return 1
		if not _expect(native_result.get("height_bytes", PackedByteArray()) == reference_result.get("height_bytes", PackedByteArray()), "native height bytes should match GDScript reference for seed %d" % seed):
			return 1
		if not _expect(native_result.get("biome_bytes", PackedByteArray()) == reference_result.get("biome_bytes", PackedByteArray()), "native biome bytes should match GDScript reference for seed %d" % seed):
			return 1

	var preview_generator: WorldMapGenerator = WorldMapGeneratorScript.new()
	preview_generator.world_seed = 12345
	preview_generator.noise_freq = 0.1
	preview_generator.terrain_height = 10.0
	preview_generator._init_noise()
	var preview_native: Dictionary = preview_generator._generate_height_biome_bytes(128, 25.0, false, WorldMapGeneratorScript.MAP_SIZE)
	var preview_reference: Dictionary = preview_generator._generate_height_biome_bytes_gdscript(128, 25.0, false, WorldMapGeneratorScript.MAP_SIZE)
	if not _expect(preview_native.get("height_bytes", PackedByteArray()) == preview_reference.get("height_bytes", PackedByteArray()), "full-world preview height samples should match reference"):
		return 1
	if not _expect(preview_native.get("biome_bytes", PackedByteArray()) == preview_reference.get("biome_bytes", PackedByteArray()), "full-world preview biome samples should match reference"):
		return 1
	var preview_images: Dictionary = preview_generator.generate_preview(128)
	var preview_heightmap: Image = preview_images.get("heightmap")
	if not _expect(preview_heightmap != null and preview_heightmap.get_size() == Vector2i(128, 128), "preview generator should return requested heightmap dimensions"):
		return 1
	var preview_profile: Dictionary = preview_images.get("preview_generation_profile", {})
	if not _expect(str(preview_profile.get("backend", "")) == "native", "preview generator should report native backend"):
		return 1

	print("[WORLD_MAP_HEIGHT_BIOME_NATIVE_TEST] PASS native_ms=%.3f reference_ms=%.3f" % [
		float(native_total_us) / 1000.0,
		float(reference_total_us) / 1000.0
	])
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_HEIGHT_BIOME_NATIVE_TEST] FAIL: %s" % message)
	return false
