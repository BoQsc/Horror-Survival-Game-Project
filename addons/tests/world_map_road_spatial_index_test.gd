extends SceneTree

const WorldMapGeneratorScript := preload("res://world_map_generator/world_map_generator.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var generator: WorldMapGenerator = WorldMapGeneratorScript.new()
	generator.native_road_footprint_enabled = false
	var road_segments := [
		{"from": Vector2(-140.0, -60.0), "to": Vector2(140.0, -20.0), "width": 8.0},
		{"from": Vector2(-35.0, -120.0), "to": Vector2(-35.0, 120.0), "width": 5.5},
		{"from": Vector2(80.0, 70.0), "to": Vector2(170.0, 130.0), "width": 6.0}
	]
	var mismatches := 0
	var first_mismatch := ""
	for z in range(-150, 151, 11):
		for x in range(-160, 181, 13):
			var footprint := Vector2i(18 + abs(x) % 9, 14 + abs(z) % 7)
			generator._road_segment_spatial_index = {}
			var reference := generator._footprint_hits_road_segments(float(x), float(z), footprint, road_segments)
			generator._road_segment_spatial_index = generator._build_road_segment_spatial_index(road_segments)
			var indexed := generator._footprint_hits_road_segments(float(x), float(z), footprint, road_segments)
			if reference != indexed:
				mismatches += 1
				if first_mismatch.is_empty():
					first_mismatch = "x=%d z=%d footprint=%s reference=%s indexed=%s" % [x, z, footprint, reference, indexed]
	for z in range(-150, 151, 17):
		for x in range(-160, 181, 19):
			var probe := Vector2(float(x), float(z))
			generator._road_segment_spatial_index = {}
			var reference_connection := generator._find_best_road_connection(probe, road_segments)
			generator._road_segment_spatial_index = generator._build_road_segment_spatial_index(road_segments)
			var indexed_connection := generator._find_best_road_connection(probe, road_segments)
			if not _connections_match(reference_connection, indexed_connection):
				mismatches += 1
				if first_mismatch.is_empty():
					first_mismatch = "probe=%s reference=%s indexed=%s" % [probe, reference_connection, indexed_connection]
	if mismatches > 0:
		printerr("[WORLD_MAP_ROAD_SPATIAL_INDEX_TEST] FAIL mismatches=%d %s" % [mismatches, first_mismatch])
		return 1
	print("[WORLD_MAP_ROAD_SPATIAL_INDEX_TEST] PASS cells=%d refs=%d" % [
		int(generator._road_segment_spatial_index.get("cell_count", 0)),
		int(generator._road_segment_spatial_index.get("segment_ref_count", 0))
	])
	return 0


func _connections_match(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return a.is_empty() and b.is_empty()
	var point_a: Vector2 = a.get("point", Vector2.INF)
	var point_b: Vector2 = b.get("point", Vector2.INF)
	if point_a.distance_to(point_b) > 0.001:
		return false
	if str(a.get("kind", "")) != str(b.get("kind", "")):
		return false
	if absf(float(a.get("distance", 0.0)) - float(b.get("distance", 0.0))) > 0.001:
		return false
	return true
