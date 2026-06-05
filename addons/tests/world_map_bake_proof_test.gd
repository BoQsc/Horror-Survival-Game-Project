extends SceneTree

const WorldMapGeneratorScript := preload("res://world_map_generator/world_map_generator.gd")
const WorldMapData := preload("res://world_map_data/world_map_data.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var generator: WorldMapGenerator = WorldMapGeneratorScript.new()
	generator.world_seed = 4242
	generator.noise_freq = 0.1
	generator.terrain_height = 10.0
	generator.water_level = 13.0
	generator.road_spacing = 100.0
	generator.road_width = 8.0
	generator.use_grid_roads = false
	generator.deep_lakes_enabled = true
	generator.last_generation_profile = {
		"world_seed": generator.world_seed,
		"map_size": WorldMapGeneratorScript.MAP_SIZE,
		"layout_mode": "town",
		"height_biome_backend": "native",
		"height_biome_ms": 1.25,
		"layout_ms": 2.5,
		"lakes_ms": 0.5,
		"finalize_ms": 0.75,
		"total_ms": 5.5,
		"town_count": 1,
		"road_segment_count": 1,
		"building_count": 1,
		"path_segment_count": 1,
		"terrain_modification_count": 1
	}

	var images := _build_test_images(false)
	var proof_a: Dictionary = generator.build_world_bake_proof(images)
	if not _expect(bool(proof_a.get("success", false)), "bake proof should succeed for complete baked layers"):
		return 1
	if not _expect(int(proof_a.get("baked_layer_count", 0)) == WorldMapData.get_baked_image_names().size(), "proof should count all baked layers"):
		return 1
	if not _expect(str(proof_a.get("content_signature", "")).length() > 0, "proof should expose a content signature"):
		return 1
	if not _expect(float(proof_a.get("generation_unaccounted_ms", 0.0)) > 0.0, "proof should expose unaccounted generation time"):
		return 1

	var proof_b: Dictionary = generator.build_world_bake_proof(_build_test_images(false))
	if not _expect(str(proof_a.get("content_signature", "")) == str(proof_b.get("content_signature", "")), "identical baked content should keep the same signature"):
		return 1

	var proof_mutated: Dictionary = generator.build_world_bake_proof(_build_test_images(true))
	if not _expect(str(proof_a.get("content_signature", "")) != str(proof_mutated.get("content_signature", "")), "mutated baked content should change the signature"):
		return 1

	var save_path := "user://world_map_bake_proof_test_%d" % Time.get_ticks_usec()
	if not _expect(generator.save_world(save_path, images), "save_world should export synthetic baked layers"):
		return 1
	var save_profile: Dictionary = generator.last_save_profile
	if not _expect(bool(save_profile.get("success", false)), "save profile should report success"):
		return 1
	if not _expect(str(save_profile.get("cache_signature", "")).length() > 0, "save profile should expose export cache signature"):
		return 1
	if not _expect(bool(save_profile.get("world_cache_signature_file_written", false)), "save profile should report signature-file write"):
		return 1

	var telemetry: Dictionary = generator.get_telemetry_snapshot()
	var exported_proof: Dictionary = telemetry.get("last_bake_proof", {})
	if not _expect(bool(exported_proof.get("success", false)), "telemetry should expose exported bake proof"):
		return 1
	if not _expect(str(exported_proof.get("content_signature", "")) == str(proof_a.get("content_signature", "")), "exported proof should preserve generated content signature"):
		return 1
	var exported_save_profile: Dictionary = exported_proof.get("save_profile", {})
	if not _expect(bool(exported_save_profile.get("success", false)), "exported proof should include save profile"):
		return 1

	print("[WORLD_MAP_BAKE_PROOF_TEST] PASS signature=%s export_signature=%s" % [
		str(proof_a.get("content_signature", "")).substr(0, 12),
		str(save_profile.get("cache_signature", "")).substr(0, 12)
	])
	return 0


func _build_test_images(mutated: bool) -> Dictionary:
	var size := 4
	var total := size * size
	var height_bytes := PackedByteArray()
	height_bytes.resize(total)
	var biome_bytes := PackedByteArray()
	biome_bytes.resize(total)
	var road_bytes := PackedByteArray()
	road_bytes.resize(total * 2)
	var water_bytes := PackedByteArray()
	water_bytes.resize(total)
	var building_bytes := PackedByteArray()
	building_bytes.resize(total)

	for index in range(total):
		height_bytes[index] = 80 + index
		biome_bytes[index] = index % 4
		water_bytes[index] = 255 if index == 3 else 0
		building_bytes[index] = 255 if index == 5 else 0
		road_bytes[index * 2] = 255 if index == 1 else 0
		road_bytes[index * 2 + 1] = 128 if index == 1 else 0
	if mutated:
		height_bytes[0] = 7

	return {
		"heightmap": Image.create_from_data(size, size, false, Image.FORMAT_R8, height_bytes),
		"biomes": Image.create_from_data(size, size, false, Image.FORMAT_R8, biome_bytes),
		"roads": Image.create_from_data(size, size, false, Image.FORMAT_RG8, road_bytes),
		"water": Image.create_from_data(size, size, false, Image.FORMAT_R8, water_bytes),
		"building_map": Image.create_from_data(size, size, false, Image.FORMAT_R8, building_bytes),
		"buildings": [{
			"x": 1.0,
			"y": 2.0,
			"z": 3.0,
			"type": "small_house",
			"rotation": 0,
			"footprint_w": 2,
			"footprint_d": 2
		}],
		"towns": [{
			"x": 1.0,
			"z": 3.0,
			"radius": 12.0,
			"building_count": 1,
			"terrain_y": 2.0
		}],
		"terrain_modifications": [{
			"type": "excavate",
			"x": 1,
			"y": 2,
			"z": 3
		}]
	}


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_BAKE_PROOF_TEST] FAIL: %s" % message)
	return false
