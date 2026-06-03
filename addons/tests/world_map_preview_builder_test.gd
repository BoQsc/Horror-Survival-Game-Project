extends SceneTree

const WorldMapPreviewBuilder = preload("res://world_performance/world_map_preview_builder.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var width := 8
	var height := 4
	var height_bytes := PackedByteArray()
	height_bytes.resize(width * height)
	height_bytes.fill(128)
	var biome_bytes := PackedByteArray()
	biome_bytes.resize(width * height)
	biome_bytes.fill(0)
	var road_bytes := PackedByteArray()
	road_bytes.resize(width * height * 2)
	road_bytes[0] = 255
	var water_bytes := PackedByteArray()
	water_bytes.resize(width * height)
	water_bytes[2] = 255
	var building_bytes := PackedByteArray()
	building_bytes.resize(width * height)
	building_bytes[4] = 255

	var images := {
		"heightmap": Image.create_from_data(width, height, false, Image.FORMAT_R8, height_bytes),
		"biomes": Image.create_from_data(width, height, false, Image.FORMAT_R8, biome_bytes),
		"roads": Image.create_from_data(width, height, false, Image.FORMAT_RG8, road_bytes),
		"water": Image.create_from_data(width, height, false, Image.FORMAT_R8, water_bytes),
		"building_map": Image.create_from_data(width, height, false, Image.FORMAT_R8, building_bytes)
	}
	var result := WorldMapPreviewBuilder.build_preview(images, 4)
	if not _expect(not result.is_empty(), "bounded preview should build"):
		return 1
	if not _expect(result.get("source_size", Vector2i.ZERO) == Vector2i(8, 4), "source size should be retained"):
		return 1
	if not _expect(result.get("output_size", Vector2i.ZERO) == Vector2i(4, 2), "preview should preserve aspect ratio within the bound"):
		return 1
	if not _expect(int(result.get("sample_count", 0)) == 8, "sample count should match bounded output pixels"):
		return 1

	var preview: Image = result.get("image")
	var road_color := preview.get_pixel(0, 0)
	var water_color := preview.get_pixel(1, 0)
	var building_color := preview.get_pixel(2, 0)
	var grass_color := preview.get_pixel(3, 0)
	if not _expect(road_color.b > road_color.r, "road overlay should be visible"):
		return 1
	if not _expect(water_color.b > water_color.r and water_color.b > water_color.g, "water overlay should be visible"):
		return 1
	if not _expect(building_color.r > building_color.g and building_color.r > building_color.b, "building overlay should be visible"):
		return 1
	if not _expect(grass_color.g > grass_color.r and grass_color.g > grass_color.b, "biome color should remain visible"):
		return 1

	var full_result := WorldMapPreviewBuilder.build_preview(images, 64)
	if not _expect(full_result.get("output_size", Vector2i.ZERO) == Vector2i(8, 4), "small sources should not be upscaled"):
		return 1

	print("[WORLD_MAP_PREVIEW_BUILDER_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_PREVIEW_BUILDER_TEST] FAIL: %s" % message)
	return false
