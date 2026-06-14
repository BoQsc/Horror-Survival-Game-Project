extends SceneTree

const WorldMapGeneratorScript := preload("res://world_map_generator/world_map_generator.gd")
const OUTPUT_PATH := "res://.agent/world-map-generation-native-lakes-profile.json"

var _generator: WorldMapGenerator = null


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	_release_generator()
	for _i in 4:
		await process_frame
	quit(exit_code)


func _release_generator() -> void:
	if _generator != null:
		_generator.release_runtime_resources()
		_generator = null


func _release_generated_world(images: Dictionary) -> void:
	for key in images.keys():
		var value: Variant = images.get(key)
		if value is Dictionary:
			(value as Dictionary).clear()
		elif value is Array:
			(value as Array).clear()
		images[key] = null
	images.clear()


func _run() -> int:
	_generator = WorldMapGeneratorScript.new()
	var generator := _generator
	generator.world_seed = 12345
	generator.noise_freq = 0.1
	generator.terrain_height = 10.0
	generator.water_level = 13.0
	generator.road_spacing = 100.0
	generator.road_width = 8.0
	generator.use_grid_roads = false
	generator.deep_lakes_enabled = true
	if not _expect(generator._native_lake_generation_available(), "native lake generation should be available"):
		return 1

	var started_us := Time.get_ticks_usec()
	var images := generator.generate_world()
	var elapsed_ms := float(Time.get_ticks_usec() - started_us) / 1000.0
	var profile := generator.last_generation_profile
	if not _expect(images.get("heightmap", null) is Image, "full generation should produce a heightmap"):
		return 1
	if not _expect(images.get("water", null) is Image, "full generation should produce a water map"):
		return 1
	if not _expect(str(profile.get("height_biome_backend", "")) == "native", "full generation should use native height/biome"):
		return 1
	if not _expect(str(profile.get("road_rasterize_backend", "")) == "native", "full generation should use native road rasterization"):
		return 1
	if not _expect(str(profile.get("path_rasterize_backend", "")) == "native", "full generation should use native path rasterization"):
		return 1
	if not _expect(str(profile.get("lakes_backend", "")) == "native", "full generation should use native lakes"):
		return 1
	if not _expect(float(profile.get("road_rasterize_ms", 999999.0)) < 1500.0, "native road rasterization should avoid multi-second GDScript rasterization"):
		return 1
	if not _expect(float(profile.get("path_rasterize_ms", 999999.0)) < 1500.0, "native path rasterization should avoid multi-second GDScript rasterization"):
		return 1
	if not _expect(int(profile.get("lake_water_pixel_count", 0)) > 0, "native lakes should mark water pixels"):
		return 1
	if not _expect(float(profile.get("lakes_ms", 999999.0)) < 5000.0, "native lakes should avoid multi-second GDScript lake pass"):
		return 1
	if not _expect(str(profile.get("terrain_modification_format", "")) == "excavation_columns_v1", "terrain modifications should use compact excavation column format"):
		return 1
	if not _expect(int(profile.get("terrain_modification_count", 0)) > 1000, "compact terrain modifications should preserve excavation column count"):
		return 1
	if not _expect(int(profile.get("terrain_modification_storage_entry_count", 999999)) == 1, "compact terrain modifications should store one payload entry"):
		return 1
	if not _expect(int(profile.get("building_support_road_native_calls", 0)) > 0, "building road-footprint rejection should use native predicate"):
		return 1
	if not _expect(int(profile.get("building_support_road_gdscript_calls", 999999)) == 0, "building road-footprint rejection should avoid GDScript fallback"):
		return 1

	var evidence := {
		"elapsed_ms": elapsed_ms,
		"profile": profile.duplicate(true),
		"heightmap_size": (images.get("heightmap") as Image).get_size(),
		"water_size": (images.get("water") as Image).get_size()
	}
	var output_path := ProjectSettings.globalize_path(OUTPUT_PATH)
	var dir := DirAccess.open(output_path.get_base_dir())
	if dir == null:
		DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(evidence, "\t"))
		file.close()

	print("[WORLD_MAP_GENERATION_NATIVE_LAKES_PROFILE_TEST] PASS total_ms=%.3f profile_total_ms=%.3f height_biome_ms=%.3f layout_ms=%.3f road_rasterize_ms=%.3f town_buildings_ms=%.3f path_rasterize_ms=%.3f lakes_ms=%.3f water=%d carved=%d" % [
		elapsed_ms,
		float(profile.get("total_ms", 0.0)),
		float(profile.get("height_biome_ms", 0.0)),
		float(profile.get("layout_ms", 0.0)),
		float(profile.get("road_rasterize_ms", 0.0)),
		float(profile.get("town_buildings_ms", 0.0)),
		float(profile.get("path_rasterize_ms", 0.0)),
		float(profile.get("lakes_ms", 0.0)),
		int(profile.get("lake_water_pixel_count", 0)),
		int(profile.get("lake_height_carve_count", 0))
	])
	_release_generated_world(images)
	generator = null
	_release_generator()
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_GENERATION_NATIVE_LAKES_PROFILE_TEST] FAIL: %s" % message)
	return false
