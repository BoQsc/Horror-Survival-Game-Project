extends SceneTree

const MaterialRegistry := preload("res://modules/world_generation/material_registry.gd")

var _native: Object = null


func _init() -> void:
	var exit_code := _run()
	_release_native()
	quit(exit_code)


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
	if not _expect(native != null and native.has_method("build_world_map_minimap_rgb_bytes"), "native minimap backend should be bound"):
		return 1

	var width := 8
	var height := 4
	var total := width * height
	var height_data := PackedByteArray()
	var biome_data := PackedByteArray()
	var road_data := PackedByteArray()
	var water_data := PackedByteArray()
	var building_data := PackedByteArray()
	height_data.resize(total)
	biome_data.resize(total)
	road_data.resize(total * 2)
	water_data.resize(total)
	building_data.resize(total)

	var biome_cycle := [
		MaterialRegistry.GRASS,
		MaterialRegistry.SAND,
		MaterialRegistry.GRAVEL,
		MaterialRegistry.SNOW,
		MaterialRegistry.STONE,
		MaterialRegistry.COAL,
		MaterialRegistry.PLACED_STONE
	]
	for i in range(total):
		height_data[i] = int((i * 37) % 256)
		biome_data[i] = int(biome_cycle[i % biome_cycle.size()])

	road_data[3 * 2] = 255
	road_data[10 * 2] = 255
	water_data[5] = 255
	building_data[6] = 255

	var native_start_us := Time.get_ticks_usec()
	var native_result: Dictionary = native.build_world_map_minimap_rgb_bytes(
		height_data,
		biome_data,
		road_data,
		water_data,
		building_data,
		width,
		height,
		_build_material_lut(),
		MaterialRegistry.ROAD,
		40,
		80,
		160,
		220,
		80,
		40
	)
	var native_ms := float(Time.get_ticks_usec() - native_start_us) / 1000.0
	var native_bytes: PackedByteArray = native_result.get("rgb_bytes", PackedByteArray())
	if not _expect(native_bytes.size() == total * 3, "native minimap should return RGB bytes"):
		return 1
	if not _expect(int(native_result.get("pixel_count", 0)) == total, "native pixel count should match input"):
		return 1
	if not _expect(int(native_result.get("road_pixel_count", -1)) == 2, "native road overlay count should match input"):
		return 1
	if not _expect(int(native_result.get("water_pixel_count", -1)) == 1, "native water overlay count should match input"):
		return 1
	if not _expect(int(native_result.get("building_pixel_count", -1)) == 1, "native building overlay count should match input"):
		return 1

	var reference_start_us := Time.get_ticks_usec()
	var reference_bytes := _build_reference_minimap_bytes(height_data, biome_data, road_data, water_data, building_data, width, height)
	var reference_ms := float(Time.get_ticks_usec() - reference_start_us) / 1000.0
	if not _expect(native_bytes == reference_bytes, "native minimap RGB bytes should match GDScript reference"):
		_print_first_mismatch(native_bytes, reference_bytes)
		return 1

	print("[WORLD_MAP_MINIMAP_NATIVE_TEST] PASS native_ms=%.3f reference_ms=%.3f workers=%d" % [
		native_ms,
		reference_ms,
		int(native_result.get("worker_count", 0))
	])
	return 0


func _build_material_lut() -> PackedInt32Array:
	var lut := PackedInt32Array()
	lut.resize(256 * 3)
	for material_id in range(256):
		var rgb := MaterialRegistry.get_minimap_rgb(material_id)
		var offset := material_id * 3
		lut[offset] = rgb.x
		lut[offset + 1] = rgb.y
		lut[offset + 2] = rgb.z
	return lut


func _build_reference_minimap_bytes(
	height_data: PackedByteArray,
	biome_data: PackedByteArray,
	road_data: PackedByteArray,
	water_data: PackedByteArray,
	building_data: PackedByteArray,
	width: int,
	height: int
) -> PackedByteArray:
	var total := width * height
	var map_pixels := PackedByteArray()
	map_pixels.resize(total * 3)
	for i in range(total):
		var height_val := float(height_data[i]) / 255.0
		var shade := 0.5 + height_val * 0.5
		var biome := biome_data[i] if i < biome_data.size() else 0
		var rgb := MaterialRegistry.get_minimap_rgb(biome)
		var r: int = rgb.x
		var g: int = rgb.y
		var b: int = rgb.z
		if road_data.size() > 0:
			var ri := i * 2
			if ri < road_data.size() and road_data[ri] > 128:
				rgb = MaterialRegistry.get_minimap_rgb(MaterialRegistry.ROAD)
				r = rgb.x
				g = rgb.y
				b = rgb.z
		if water_data.size() > 0 and i < water_data.size() and water_data[i] > 128:
			r = 40
			g = 80
			b = 160
		if building_data.size() > 0 and i < building_data.size() and building_data[i] > 128:
			r = 220
			g = 80
			b = 40
		var pi := i * 3
		map_pixels[pi] = int(clampf(r * shade, 0, 255))
		map_pixels[pi + 1] = int(clampf(g * shade, 0, 255))
		map_pixels[pi + 2] = int(clampf(b * shade, 0, 255))
	return map_pixels


func _print_first_mismatch(native_bytes: PackedByteArray, reference_bytes: PackedByteArray) -> void:
	var limit := mini(native_bytes.size(), reference_bytes.size())
	for i in range(limit):
		if native_bytes[i] == reference_bytes[i]:
			continue
		printerr("[WORLD_MAP_MINIMAP_NATIVE_TEST] first mismatch index=%d native=%d reference=%d" % [
			i,
			native_bytes[i],
			reference_bytes[i]
		])
		return
	printerr("[WORLD_MAP_MINIMAP_NATIVE_TEST] size mismatch native=%d reference=%d" % [
		native_bytes.size(),
		reference_bytes.size()
	])


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_MINIMAP_NATIVE_TEST] FAIL: %s" % message)
	return false
