extends SceneTree


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	if not _expect(ClassDB.class_exists("TerrainGrid"), "TerrainGrid GDExtension class should be available"):
		return 1
	var terrain_grid := ClassDB.instantiate("TerrainGrid")
	if not _expect(terrain_grid != null, "TerrainGrid should instantiate"):
		return 1

	var heightmap := _filled_bytes(16, 64)
	var dry_water := _filled_bytes(16, 0)
	var wet_water := _filled_bytes(16, 255)
	var expected_density_bytes := 33 * 33 * 33 * 4

	var dry_payload: Dictionary = terrain_grid.build_world_map_density_payload(
		heightmap,
		4,
		4,
		PackedByteArray(),
		0,
		0,
		PackedByteArray(),
		0,
		0,
		dry_water,
		4,
		4,
		PackedByteArray(),
		Vector3i(0, 0, 0),
		33,
		31,
		32,
		64.0,
		32.0,
		13.0
	)
	if not _expect(not dry_payload.is_empty(), "dry native payload should be generated"):
		return 1
	if not _expect(not bool(dry_payload.get("water_surface_possible", true)), "dry native payload should report no water surface"):
		return 1
	if not _expect((dry_payload.get("density_bytes_water", PackedByteArray()) as PackedByteArray).is_empty(), "dry native payload should skip water density bytes"):
		return 1
	if not _expect((dry_payload.get("density_bytes_terrain", PackedByteArray()) as PackedByteArray).size() == expected_density_bytes, "dry native payload should keep terrain density bytes"):
		return 1

	var wet_payload: Dictionary = terrain_grid.build_world_map_density_payload(
		heightmap,
		4,
		4,
		PackedByteArray(),
		0,
		0,
		PackedByteArray(),
		0,
		0,
		wet_water,
		4,
		4,
		PackedByteArray(),
		Vector3i(0, 0, 0),
		33,
		31,
		32,
		64.0,
		32.0,
		13.0
	)
	if not _expect(bool(wet_payload.get("water_surface_possible", false)), "wet native payload should report water surface"):
		return 1
	if not _expect((wet_payload.get("density_bytes_water", PackedByteArray()) as PackedByteArray).size() == expected_density_bytes, "wet native payload should keep water density bytes"):
		return 1
	return 0


func _filled_bytes(size: int, value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(size)
	for i in range(size):
		bytes[i] = value
	return bytes


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error("[TERRAIN_NATIVE_DENSITY_PAYLOAD_TEST] " + message)
	return false
