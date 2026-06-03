extends RefCounted
## Builds a resolution-bounded color preview from authoritative world-map images.


static func build_preview(images: Dictionary, max_size: int) -> Dictionary:
	if not images.has("heightmap") or not images.has("biomes"):
		return {}
	var heightmap: Image = images.get("heightmap")
	var biome_map: Image = images.get("biomes")
	if heightmap == null or biome_map == null or heightmap.is_empty() or biome_map.is_empty():
		return {}

	var source_width := heightmap.get_width()
	var source_height := heightmap.get_height()
	var source_pixel_count := source_width * source_height
	if source_width <= 0 or source_height <= 0:
		return {}

	var height_data := heightmap.get_data()
	var biome_data := biome_map.get_data()
	if height_data.size() < source_pixel_count or biome_data.size() < source_pixel_count:
		return {}

	var bounded_max_size := maxi(max_size, 1)
	var scale := minf(
		1.0,
		minf(float(bounded_max_size) / float(source_width), float(bounded_max_size) / float(source_height))
	)
	var preview_width := maxi(int(round(float(source_width) * scale)), 1)
	var preview_height := maxi(int(round(float(source_height) * scale)), 1)

	var road_map: Image = images.get("roads", null)
	var water_map: Image = images.get("water", null)
	var building_map: Image = images.get("building_map", null)
	var road_data := road_map.get_data() if road_map else PackedByteArray()
	var water_data := water_map.get_data() if water_map else PackedByteArray()
	var building_data := building_map.get_data() if building_map else PackedByteArray()

	var preview_bytes := PackedByteArray()
	preview_bytes.resize(preview_width * preview_height * 3)
	var biome_lut := {
		0: [77, 153, 51],
		1: [128, 128, 128],
		3: [217, 199, 140],
		4: [140, 128, 115],
		5: [230, 235, 242],
		6: [64, 64, 77],
		9: [153, 140, 128],
	}
	var default_color := [77, 153, 51]
	var source_x_scale := float(source_width) / float(preview_width)
	var source_y_scale := float(source_height) / float(preview_height)

	for preview_y in range(preview_height):
		var source_y := mini(int(float(preview_y) * source_y_scale), source_height - 1)
		var source_row_offset := source_y * source_width
		var preview_row_offset := preview_y * preview_width
		for preview_x in range(preview_width):
			var source_x := mini(int(float(preview_x) * source_x_scale), source_width - 1)
			var source_index := source_row_offset + source_x
			var height_value := float(height_data[source_index]) / 255.0
			var shade := 0.6 + height_value * 0.8
			var base: Array = biome_lut.get(biome_data[source_index], default_color)

			var road_index := source_index * 2
			if road_index < road_data.size() and road_data[road_index] > 128:
				base = [64, 64, 77]
			if source_index < water_data.size() and water_data[source_index] > 128:
				base = [40, 80, 160]
			if source_index < building_data.size() and building_data[source_index] > 128:
				base = [220, 80, 40]

			var preview_index := (preview_row_offset + preview_x) * 3
			preview_bytes[preview_index] = int(clampf(base[0] * shade, 0, 255))
			preview_bytes[preview_index + 1] = int(clampf(base[1] * shade, 0, 255))
			preview_bytes[preview_index + 2] = int(clampf(base[2] * shade, 0, 255))

	return {
		"image": Image.create_from_data(preview_width, preview_height, false, Image.FORMAT_RGB8, preview_bytes),
		"source_size": Vector2i(source_width, source_height),
		"output_size": Vector2i(preview_width, preview_height),
		"sample_count": preview_width * preview_height
	}
