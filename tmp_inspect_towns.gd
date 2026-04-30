extends Object

func _init() -> void:
	var gen = load("res://world_map_generator/world_map_generator.gd").new()
	gen.world_seed = 12345
	gen.use_grid_roads = false
	gen.town_count_min = 10
	gen.town_count_max = 10
	gen.buildings_per_town_max = 72

	var result = gen.generate_world()
	var towns = result.get("towns", [])
	var buildings = result.get("buildings", [])
	var heightmap = result["heightmap"]
	var water_map = result["water"]

	var height_bytes = heightmap.get_data()
	var water_bytes = water_map.get_data()
	var road_segments = gen._build_settlement_roads(towns)
	var catalog = gen._build_prefab_catalog(gen._get_available_prefabs())
	var rng = RandomNumberGenerator.new()
	rng.seed = 12345 + 777

	var report_lines: Array[String] = []
	report_lines.append("TOWNS=%d BUILDINGS=%d" % [towns.size(), buildings.size()])

	for town in towns:
		var layout = gen._get_town_layout(town)
		var slots = gen._generate_town_building_slots(town, layout, road_segments, rng)
		var local_stats := {
			"attempted": 0,
			"placed": 0,
			"rejected_chance": 0,
			"rejected_bounds": 0,
			"rejected_water": 0,
			"rejected_slope": 0,
			"rejected_forest": 0,
			"rejected_height": 0,
			"rejected_road": 0
		}
		var valid_slots := 0
		var large_fit := 0
		var medium_fit := 0
		var small_fit := 0
		for candidate in slots:
			var center = candidate.center
			var parcel_size = candidate.size
			var district = candidate.district
			var prefab_name = gen._choose_prefab_for_parcel(catalog, district, parcel_size, rng)
			if prefab_name.is_empty():
				continue
			var fp = catalog[prefab_name]["footprint"]
			var nearest_road_pt = gen._find_nearest_road_point(center.x, center.y, road_segments)
			var rot = gen._choose_rotation_toward_point(center, nearest_road_pt, town)
			var footprint = gen._footprint_for_rotation(fp, rot)
			if footprint.x * footprint.y >= 80:
				large_fit += 1
			elif footprint.x * footprint.y >= 24:
				medium_fit += 1
			else:
				small_fit += 1
			var bldg_x: float = floor(center.x - float(footprint.x) * 0.5)
			var bldg_z: float = floor(center.y - float(footprint.y) * 0.5)
			if gen._validate_town_building_spot(bldg_x, bldg_z, footprint, road_segments, height_bytes, water_bytes, null, 25.0, 1024, local_stats):
				valid_slots += 1
		report_lines.append("Town (%.0f,%.0f) target=%d slots=%d valid=%d fit(L/M/S)=%d/%d/%d dist=%s radius=%.1f spacing=%.1f plaza=%.1f ring=%.1f" % [
			town.x, town.z, town.building_count, slots.size(), valid_slots, large_fit, medium_fit, small_fit,
			str(layout.get("road_bands", [])), town.radius, layout.spacing, layout.plaza_half, layout.ring_radius
		])
		report_lines.append("  district counts: core=%d edge=%d res=%d" % [
			_count_district(slots, "core"),
			_count_district(slots, "edge"),
			_count_district(slots, "residential")
		])
		report_lines.append("  reject road=%d water=%d slope=%d bounds=%d" % [
			local_stats.rejected_road, local_stats.rejected_water, local_stats.rejected_slope, local_stats.rejected_bounds
		])

	var report_path = "user://tmp_inspect_report.txt"
	var f = FileAccess.open(report_path, FileAccess.WRITE)
	if f:
		for line in report_lines:
			f.store_line(line)
		f.close()

func _count_district(slots: Array, name: String) -> int:
	var c := 0
	for s in slots:
		if String(s.district) == name:
			c += 1
	return c
