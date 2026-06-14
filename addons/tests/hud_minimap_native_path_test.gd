extends SceneTree

const HUDMinimapScript := preload("res://modules/world_player_v2/features/ui_hud/hud_minimap.gd")
const MaterialRegistry := preload("res://modules/world_generation/material_registry.gd")

var _minimap: HUDMinimap = null


func _init() -> void:
	var exit_code := _run()
	if is_instance_valid(_minimap):
		_minimap.free()
	_minimap = null
	quit(exit_code)


func _run() -> int:
	if not _expect(ClassDB.class_exists("PrefabGeometryNative"), "PrefabGeometryNative should be available"):
		return 1
	_minimap = HUDMinimapScript.new()
	root.add_child(_minimap)
	if not _expect(_minimap._native_minimap_available(), "HUD minimap should see native minimap backend"):
		return 1

	var width := 16
	var height := 16
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
	for i in range(total):
		height_data[i] = int((i * 19) % 256)
		biome_data[i] = MaterialRegistry.SAND if i % 3 == 0 else MaterialRegistry.GRASS
	road_data[7 * 2] = 255
	water_data[30] = 255
	building_data[45] = 255

	var native_bytes: PackedByteArray = _minimap._build_minimap_pixels_native(
		height_data,
		biome_data,
		road_data,
		water_data,
		building_data,
		width,
		height
	)
	var fallback_bytes: PackedByteArray = _minimap._build_minimap_pixels_gdscript(
		height_data,
		biome_data,
		road_data,
		water_data,
		building_data,
		width,
		height
	)
	if not _expect(native_bytes.size() == total * 3, "HUD native path should return RGB bytes"):
		return 1
	if not _expect(native_bytes == fallback_bytes, "HUD native bytes should match fallback bytes"):
		return 1
	var telemetry := _minimap.get_telemetry_snapshot()
	if not _expect(str(telemetry.get("last_minimap_backend", "")) == "native", "HUD telemetry should report native minimap backend"):
		return 1
	if not _expect(int(telemetry.get("last_minimap_pixel_count", 0)) == total, "HUD telemetry should report pixel count"):
		return 1

	print("[HUD_MINIMAP_NATIVE_PATH_TEST] PASS native_ms=%.3f workers=%d" % [
		float(telemetry.get("last_minimap_native_ms", 0.0)),
		int(telemetry.get("last_minimap_native_worker_count", 0))
	])
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[HUD_MINIMAP_NATIVE_PATH_TEST] FAIL: %s" % message)
	return false
