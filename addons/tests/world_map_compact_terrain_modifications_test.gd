extends SceneTree

const ChunkManagerScript := preload("res://world_marching_cubes/chunk_manager.gd")
const WorldMapGeneratorScript := preload("res://world_map_generator/world_map_generator.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var columns := [
		-18, 24, 6.0, 12.0,
		0, 0, -2.0, 4.0,
		31, -31, 10.0, 35.0,
		32, -32, 30.0, 31.0
	]
	var compact := [{
		"format": "excavation_columns_v1",
		"shape": 2,
		"radius": 0.6,
		"value": 10.0,
		"layer": 0,
		"material_id": -1,
		"columns": columns
	}]
	var legacy := _legacy_modifications_from_columns(columns)

	var compact_manager = ChunkManagerScript.new()
	compact_manager._cache_world_map_terrain_modifications(compact)
	var legacy_manager = ChunkManagerScript.new()
	legacy_manager._cache_world_map_terrain_modifications(legacy)

	if not _expect(_same_vector3i_key_set(compact_manager._world_map_terrain_modifications, legacy_manager._world_map_terrain_modifications), "compact chunk modification keys should match legacy keys"):
		return 1
	if not _expect(_same_mask_dictionary(compact_manager._world_map_excavation_masks, legacy_manager._world_map_excavation_masks), "compact excavation masks should match legacy masks"):
		return 1

	var generator: WorldMapGenerator = WorldMapGeneratorScript.new()
	var generated := generator._make_compact_terrain_modifications()
	if not _expect(generator._append_compact_excavation_column(generated, -18, 24, 6.0, 12.0), "generator should append compact column"):
		return 1
	if not _expect(generator._terrain_modification_count(generated) == 1, "generator compact count should report columns, not wrapper entries"):
		return 1
	var payload: Dictionary = generated[0]
	if not _expect(str(payload.get("format", "")) == "excavation_columns_v1", "generator compact format should be stable"):
		return 1
	if not _expect((payload.get("columns", []) as Array).size() == 4, "generator should store one flat column record"):
		return 1

	print("[WORLD_MAP_COMPACT_TERRAIN_MODIFICATIONS_TEST] PASS columns=%d chunks=%d masks=%d" % [
		int(columns.size() / 4),
		compact_manager._world_map_terrain_modifications.size(),
		compact_manager._world_map_excavation_masks.size()
	])
	return 0


func _legacy_modifications_from_columns(columns: Array) -> Array:
	var result: Array = []
	var count := int(columns.size() / 4)
	for i in range(count):
		var base := i * 4
		var world_x := int(columns[base])
		var world_z := int(columns[base + 1])
		var y_min := float(columns[base + 2])
		var y_max := float(columns[base + 3])
		result.append({
			"brush_pos": [float(world_x) + 0.5, (y_min + y_max) * 0.5, float(world_z) + 0.5],
			"radius": 0.6,
			"value": 10.0,
			"shape": 2,
			"layer": 0,
			"y_min": y_min,
			"y_max": y_max,
			"material_id": -1
		})
	return result


func _same_vector3i_key_set(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for key in a.keys():
		if not b.has(key):
			return false
	return true


func _same_mask_dictionary(a: Dictionary, b: Dictionary) -> bool:
	if not _same_vector3i_key_set(a, b):
		return false
	for key in a.keys():
		var mask_a: PackedByteArray = a.get(key, PackedByteArray())
		var mask_b: PackedByteArray = b.get(key, PackedByteArray())
		if mask_a.size() != mask_b.size():
			return false
		for i in mask_a.size():
			if mask_a[i] != mask_b[i]:
				return false
	return true


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_COMPACT_TERRAIN_MODIFICATIONS_TEST] FAIL: %s" % message)
	return false
