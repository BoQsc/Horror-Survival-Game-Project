extends RefCounted
class_name WorldMapGenerator
## WorldMapGenerator - World definition PNG generation
## Supports two modes:
##  - TOWN mode (default): Towns connected by MST roads, wilderness buildings with access paths
##  - GRID mode (legacy toggle): Roads at fixed intervals with buildings at intersections

const PrefabGeometry = preload("res://world_building_system/prefab_geometry.gd")
const FoundationSupport = preload("res://world_building_system/foundation_support.gd")

const MAP_SIZE: int = 2048  # 1 pixel = 1 meter

# CONSTRAINT: max decoded height = 2 * terrain_height must be < CHUNK_SIZE (32)
var noise_freq: float = 0.1
var terrain_height: float = 10.0
var water_level: float = 13.0
var road_spacing: float = 100.0  # Used for GRID mode fallback
var road_width: float = 8.0
var wide_shoulders: bool = false
var world_seed: int = 12345
var lake_threshold: float = 0.35
var deep_lakes_enabled: bool = true
var spawn_distance_from_road: float = 15.0
var building_spawn_chance: float = 0.6

## Toggle: false = TOWN mode (MST roads + towns), true = GRID mode (legacy)
var use_grid_roads: bool = false

# Town generation parameters
var town_count_min: int = 8
var town_count_max: int = 12
var town_radius_min: float = 40.0
var town_radius_max: float = 80.0
var town_min_spacing: float = 300.0  # Min distance between town centers
var buildings_per_town_max: int = 48
var wilderness_building_chance: float = 0.03  # ~3% of grid cells get a wilderness building
var access_path_width: float = 3.0  # Narrow road from wilderness buildings to nearest main road
var settlement_sample_spacing: float = 96.0
var settlement_road_width: float = 5.5
var settlement_plaza_ratio: float = 0.22
var settlement_grid_spacing_min: float = 24.0
var settlement_grid_spacing_max: float = 34.0
var settlement_lot_setback: float = 3.0
var building_path_width: float = 2.5
const ROAD_BLEND_MARGIN: float = 4.0
var building_support_max_float: float = 1.85
var building_support_max_embed: float = 3.5
var building_support_search_radius: int = 4
var building_support_sample_stride: float = 1.0
var underground_cover_min: float = 2.0
var underground_flatten_protection_margin: int = 1
const PATH_SHOULDER_BASE: float = 0.65
const PATH_SHOULDER_SLOPE_FACTOR: float = 0.35
const PATH_SHOULDER_SLOPE_CAP: float = 0.6
const PATH_SHOULDER_STEEP_LIMIT: float = 0.35
const PATH_TERRAIN_BLEND_SLOPE_START: float = 0.06
const PATH_TERRAIN_BLEND_SLOPE_FULL: float = 0.16
const PATH_TERRAIN_BLEND_LENGTH_START: float = 10.0
const PATH_TERRAIN_BLEND_LENGTH_FULL: float = 30.0
const PATH_ROAD_LINK_MAX_LENGTH: float = 8.0
const PATH_ROAD_LINK_MAX_RISE: float = 1.75
const PATH_ROAD_LINK_MAX_SLOPE: float = 0.16
const PATH_FRONTAGE_MAX_RISE: float = 1.5
const PATH_FRONTAGE_MAX_SLOPE: float = 0.12
const LAKE_ROAD_BLOCK_THRESHOLD: int = 240

# Progress callback
var progress_callback: Callable = Callable()

# Noise instances
var _height_noise: FastNoiseLite
var _biome_noise: FastNoiseLite
var _road_height_noise: FastNoiseLite
var _lake_noise: FastNoiseLite

enum MaterialID {
	GRASS = 0, STONE = 1, ORE = 2, SAND = 3,
	GRAVEL = 4, SNOW = 5, ROAD = 6, GRANITE = 9
}

func _init_noise() -> void:
	_height_noise = FastNoiseLite.new()
	_height_noise.seed = world_seed
	_height_noise.noise_type = FastNoiseLite.TYPE_VALUE
	_height_noise.frequency = noise_freq
	
	_biome_noise = FastNoiseLite.new()
	_biome_noise.seed = world_seed + 100
	_biome_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_biome_noise.frequency = 0.002
	_biome_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_biome_noise.fractal_octaves = 3
	_biome_noise.fractal_gain = 0.5
	
	_road_height_noise = FastNoiseLite.new()
	_road_height_noise.seed = world_seed + 200
	_road_height_noise.noise_type = FastNoiseLite.TYPE_VALUE_CUBIC
	_road_height_noise.frequency = 0.008
	
	_lake_noise = FastNoiseLite.new()
	_lake_noise.seed = world_seed + 300
	_lake_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_lake_noise.frequency = 0.0008
	_lake_noise.fractal_type = FastNoiseLite.FRACTAL_NONE

# ============================================================================
# MAIN GENERATION
# ============================================================================

func generate_world() -> Dictionary:
	if terrain_height > 15.0:
		print("[WorldMapGen] WARNING: terrain_height %.1f exceeds safe max 15.0, clamping" % terrain_height)
		terrain_height = 15.0
	_init_noise()
	var half = MAP_SIZE / 2
	var total = MAP_SIZE * MAP_SIZE
	
	var height_bytes = PackedByteArray()
	height_bytes.resize(total)
	var biome_bytes = PackedByteArray()
	biome_bytes.resize(total)
	var road_bytes = PackedByteArray()
	road_bytes.resize(total * 2)
	var water_bytes = PackedByteArray()
	water_bytes.resize(total)
	
	var max_h = terrain_height * 2.5
	
	# PASS 1: Height + Biome
	if progress_callback.is_valid():
		progress_callback.call(0.0, "Generating height + biomes")
	
	for z in MAP_SIZE:
		if z % 256 == 0 and progress_callback.is_valid():
			progress_callback.call(float(z) / MAP_SIZE * 30.0, "Height + biomes")
		var wz = float(z - half)
		var row_offset = z * MAP_SIZE
		for x in MAP_SIZE:
			var wx = float(x - half)
			var idx = row_offset + x
			var h_raw = _height_noise.get_noise_2d(wx, wz)
			var h = terrain_height + (h_raw * 0.5 + 0.5) * terrain_height
			height_bytes[idx] = _encode_height_byte(h, max_h)
			var bv = _biome_noise.get_noise_2d(wx, wz)
			var biome: int = MaterialID.GRASS
			if bv < -0.2: biome = MaterialID.SAND
			elif bv > 0.6: biome = MaterialID.SNOW
			elif bv > 0.2: biome = MaterialID.GRAVEL
			biome_bytes[idx] = biome
	
	# Branch: TOWN mode or GRID mode
	var buildings: Array = []
	var towns: Array = []
	var road_segments: Array = []  # [{from: Vector2, to: Vector2}]
	var path_segments: Array = []
	var terrain_modifications: Array = []
	var bldg_stats = {
		"attempted": 0, "placed": 0,
		"rejected_chance": 0, "rejected_bounds": 0, "rejected_water": 0,
		"rejected_slope": 0, "rejected_forest": 0, "rejected_height": 0,
		"rejected_road": 0, "rejected_float": 0, "rejected_embed": 0,
		"rejected_cover": 0
	}
	
	if use_grid_roads:
		# LEGACY GRID MODE
		_generate_grid_roads(height_bytes, biome_bytes, road_bytes, max_h, half)
		_generate_grid_buildings(height_bytes, water_bytes, biome_bytes, road_bytes, max_h, half, buildings, terrain_modifications, bldg_stats)
	else:
		# TOWN MODE
		if progress_callback.is_valid():
			progress_callback.call(30.0, "Placing towns")
		towns = _place_towns(height_bytes, water_bytes, max_h, half)
		var catalog = _build_prefab_catalog(_get_available_prefabs())
		
		if progress_callback.is_valid():
			progress_callback.call(40.0, "Building road network")
		road_segments = _build_settlement_roads(towns, catalog)
		_rasterize_roads(road_segments, height_bytes, biome_bytes, road_bytes, max_h, half, road_width)
		
		if progress_callback.is_valid():
			progress_callback.call(55.0, "Placing buildings in towns")
		_generate_town_buildings(towns, road_segments, path_segments, height_bytes, water_bytes, road_bytes, catalog, max_h, half, buildings, terrain_modifications, bldg_stats)
		if not path_segments.is_empty():
			_rasterize_paths(path_segments, height_bytes, biome_bytes, road_bytes, max_h, half)
	
	# PASS: Lakes
	if progress_callback.is_valid():
		progress_callback.call(80.0, "Generating lakes")
	_generate_lakes(water_bytes, road_bytes, height_bytes, half, max_h)
	
	# PASS: Building footprint map
	if progress_callback.is_valid():
		progress_callback.call(95.0, "Finalizing")
	var building_bytes = PackedByteArray()
	building_bytes.resize(total)
	building_bytes.fill(0)
	for bldg in buildings:
		var px = int(float(bldg.x) + half)
		var pz = int(float(bldg.z) + half)
		var footprint = Vector2i(
			int(bldg.get("footprint_w", 0)),
			int(bldg.get("footprint_d", 0))
		)
		if footprint.x <= 0 or footprint.y <= 0:
			var rot = int(bldg.get("rotation", 0))
			footprint = PrefabGeometry.get_rotated_surface_footprint(str(bldg.get("type", "small_house")), rot)
		for fx in range(footprint.x):
			for fz in range(footprint.y):
				var fpx = px + fx
				var fpz = pz + fz
				if fpx >= 0 and fpx < MAP_SIZE and fpz >= 0 and fpz < MAP_SIZE:
					building_bytes[fpz * MAP_SIZE + fpx] = 255
	
	print("[WorldMapGen] Mode: %s | Buildings: %d placed / %d attempted | Towns: %d" % [
		"GRID" if use_grid_roads else "TOWN", bldg_stats.placed, bldg_stats.attempted, towns.size()
	])
	
	var heightmap = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8, height_bytes)
	var biome_map = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8, biome_bytes)
	var road_map = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_RG8, road_bytes)
	var water_map = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8, water_bytes)
	var building_map = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8, building_bytes)
	
	if progress_callback.is_valid():
		progress_callback.call(100.0, "Complete")
	
	return {
		"heightmap": heightmap, "biomes": biome_map, "roads": road_map,
		"water": water_map, "building_map": building_map,
		"buildings": buildings, "building_stats": bldg_stats, "towns": towns,
		"terrain_modifications": terrain_modifications
	}

# ============================================================================
# TOWN PLACEMENT (Poisson disk)
# ============================================================================

func _place_towns(height_bytes: PackedByteArray, water_bytes: PackedByteArray, max_h: float, half: int) -> Array:
	var rng = RandomNumberGenerator.new()
	rng.seed = world_seed + 500
	var towns: Array = []
	var target_count = rng.randi_range(town_count_min, town_count_max)
	var candidates: Array = []
	var margin = max(150.0, town_radius_max + 24.0)
	var sample_step = settlement_sample_spacing
	var start_x = -half + margin
	var start_z = -half + margin
	var end_x = half - margin
	var end_z = half - margin
	
	var wz = start_z
	while wz <= end_z:
		var wx = start_x
		while wx <= end_x:
			var score = _score_settlement_site(wx, wz, height_bytes, water_bytes, max_h, half)
			if score > 0.0:
				candidates.append({
					"x": wx,
					"z": wz,
					"score": score
				})
			wx += sample_step
		wz += sample_step
	
	candidates.sort_custom(func(a, b): return a.score > b.score)
	
	for candidate in candidates:
		if towns.size() >= target_count:
			break
		
		var tx = float(candidate.x)
		var tz = float(candidate.z)
		
		var too_close = false
		for existing in towns:
			var dist = Vector2(tx, tz).distance_to(Vector2(existing.x, existing.z))
			if dist < town_min_spacing:
				too_close = true
				break
		if too_close:
			continue
		
		var score = float(candidate.score)
		var radius = lerpf(town_radius_min, town_radius_max, score)
		radius = clampf(radius, town_radius_min, town_radius_max)
		
		var bldg_count = int(radius * 0.9 + score * 18.0)
		bldg_count = clampi(bldg_count, 24, buildings_per_town_max + 24)
		
		var px = int(tx + half)
		var pz = int(tz + half)
		var bidx = pz * MAP_SIZE + px
		var terrain_y = clampf(float(height_bytes[bidx]) / 255.0 * max_h, 1.0, 28.0)
		
		towns.append({
			"x": tx, "z": tz,
			"radius": radius,
			"building_count": bldg_count,
			"terrain_y": terrain_y,
			"score": score
		})
	
	print("[WorldMapGen] Placed %d towns (target: %d)" % [towns.size(), target_count])
	return towns

func _score_settlement_site(wx: float, wz: float, height_bytes: PackedByteArray, water_bytes: PackedByteArray, max_h: float, half: int) -> float:
	var px = int(wx + half)
	var pz = int(wz + half)
	if px < 8 or px >= MAP_SIZE - 8 or pz < 8 or pz >= MAP_SIZE - 8:
		return 0.0
	
	var center_idx = pz * MAP_SIZE + px
	if water_bytes[center_idx] > 128:
		return 0.0
	
	var center_h = clampf(float(height_bytes[center_idx]) / 255.0 * max_h, 1.0, 28.0)
	if center_h < 3.0 or center_h > 26.0:
		return 0.0
	
	var offsets = [-18, -12, -6, 0, 6, 12, 18]
	var min_h = center_h
	var max_h_local = center_h
	var water_hits = 0
	var sample_count = 0
	var sum_h = 0.0
	
	for dz in offsets:
		for dx in offsets:
			var sx = clampi(px + dx, 0, MAP_SIZE - 1)
			var sz = clampi(pz + dz, 0, MAP_SIZE - 1)
			var sidx = sz * MAP_SIZE + sx
			var sh = clampf(float(height_bytes[sidx]) / 255.0 * max_h, 1.0, 28.0)
			sum_h += sh
			sample_count += 1
			min_h = min(min_h, sh)
			max_h_local = max(max_h_local, sh)
			if water_bytes[sidx] > 128:
				water_hits += 1
	
	var avg_h = sum_h / float(sample_count)
	var slope_penalty = clampf((max_h_local - min_h) / 5.0, 0.0, 1.0)
	var elevation_score = 1.0 - clampf(abs(avg_h - 14.0) / 12.0, 0.0, 1.0)
	var water_penalty = float(water_hits) / float(sample_count)
	var civic_support = _score_civic_core_support(px, pz, height_bytes, water_bytes, max_h)
	if civic_support <= 0.0:
		return 0.0
	
	var biome_bias = 0.0
	var biome_val = _biome_noise.get_noise_2d(wx, wz)
	if biome_val > 0.1 and biome_val < 0.5:
		biome_bias = 0.12
	elif biome_val < -0.2:
		biome_bias = -0.08
	elif biome_val > 0.6:
		biome_bias = -0.1
	
	var score = elevation_score * 0.36 + (1.0 - slope_penalty) * 0.34 + civic_support * 0.24 + biome_bias
	score -= water_penalty * 0.7
	score += rng_from_site(wx, wz) * 0.06
	return clampf(score, 0.0, 1.0)

func _score_civic_core_support(px: int, pz: int, height_bytes: PackedByteArray, water_bytes: PackedByteArray, max_h: float) -> float:
	var center_idx = pz * MAP_SIZE + px
	var center_h = clampf(float(height_bytes[center_idx]) / 255.0 * max_h, 1.0, 28.0)
	var half = MAP_SIZE / 2
	var center_wx = float(px - half)
	var center_wz = float(pz - half)
	if _lake_noise.get_noise_2d(center_wx, center_wz) > lake_threshold - 0.05:
		return 0.0
	var directions = [
		Vector2i(1, 0),
		Vector2i(-1, 0),
		Vector2i(0, 1),
		Vector2i(0, -1)
	]
	var support = 0.0
	var viable_sides = 0
	for dir in directions:
		var side_viable = true
		var side_score = 0.0
		for step in [18, 26, 34]:
			var sx = clampi(px + dir.x * step, 0, MAP_SIZE - 1)
			var sz = clampi(pz + dir.y * step, 0, MAP_SIZE - 1)
			var sidx = sz * MAP_SIZE + sx
			if water_bytes[sidx] > 128:
				side_viable = false
				break
			var swx = float(sx - half)
			var swz = float(sz - half)
			if _lake_noise.get_noise_2d(swx, swz) > lake_threshold - 0.05:
				side_viable = false
				break
			var sh = clampf(float(height_bytes[sidx]) / 255.0 * max_h, 1.0, 28.0)
			if abs(sh - center_h) > 4.0:
				side_viable = false
				break
			side_score += 1.0
		if side_viable:
			viable_sides += 1
			support += side_score / 3.0
	if viable_sides < 2:
		return 0.0
	return clampf(support / 4.0, 0.0, 1.0)

func rng_from_site(wx: float, wz: float) -> float:
	var seed_value = int(abs(wx) * 37.0 + abs(wz) * 91.0) ^ world_seed
	seed_value = (seed_value * 1103515245 + 12345) & 0x7fffffff
	return float(seed_value % 1000) / 1000.0

# ============================================================================
# MST ROAD NETWORK
# ============================================================================

func _build_mst_roads(towns: Array, catalog: Dictionary) -> Array:
	if towns.size() < 2:
		return []
	
	# Kruskal's MST
	var edges: Array = []
	for i in range(towns.size()):
		for j in range(i + 1, towns.size()):
			var dist = Vector2(towns[i].x, towns[i].z).distance_to(Vector2(towns[j].x, towns[j].z))
			edges.append({"i": i, "j": j, "dist": dist})
	
	# Sort by distance
	edges.sort_custom(func(a, b): return a.dist < b.dist)
	
	# Union-Find
	var parent: Array = []
	for i in range(towns.size()):
		parent.append(i)
	
	var result: Array = []
	for edge in edges:
		var ri = _uf_find(parent, edge.i)
		var rj = _uf_find(parent, edge.j)
		if ri != rj:
			parent[ri] = rj
			var from_town: Dictionary = towns[edge.i]
			var to_town: Dictionary = towns[edge.j]
			var from_gate := _choose_gateway_for_target(from_town, Vector2(to_town.x, to_town.z), catalog)
			var to_gate := _choose_gateway_for_target(to_town, Vector2(from_town.x, from_town.z), catalog)
			result.append({
				"from": from_gate.get("entry", Vector2(from_town.x, from_town.z)),
				"to": to_gate.get("entry", Vector2(to_town.x, to_town.z)),
				"width": road_width + 1.0,
				"kind": "arterial"
			})
			if result.size() >= towns.size() - 1:
				break
	
	# Add 1-2 extra edges for variety (loops)
	var extra_count = 0
	var added_extra = 0
	for edge in edges:
		if added_extra >= extra_count:
			break
		var ri = _uf_find(parent, edge.i)
		var rj = _uf_find(parent, edge.j)
		if ri == rj:
			# This would create a cycle — good, we want 1-2 loops
			result.append({
				"from": Vector2(towns[edge.i].x, towns[edge.i].z),
				"to": Vector2(towns[edge.j].x, towns[edge.j].z)
			})
			added_extra += 1
	
	print("[WorldMapGen] MST roads: %d segments (%d towns, %d extra loops)" % [result.size(), towns.size(), added_extra])
	return result

func _build_settlement_roads(towns: Array, catalog: Dictionary) -> Array:
	var roads: Array = []
	roads.append_array(_build_mst_roads(towns, catalog))
	for town in towns:
		roads.append_array(_generate_town_internal_roads(town, catalog))
	return roads

func _uf_find(parent: Array, x: int) -> int:
	while parent[x] != x:
		parent[x] = parent[parent[x]]  # Path compression
		x = parent[x]
	return x

func _get_civic_parcel_requirements(catalog: Dictionary) -> Vector2:
	var max_surface_footprint = Vector2i.ZERO
	for prefab_name in catalog:
		var surface_fp := PrefabGeometry.get_rotated_surface_footprint(prefab_name, 1)
		var reservation_fp := PrefabGeometry.get_rotated_reservation_footprint(prefab_name, 1)
		max_surface_footprint.x = maxi(max_surface_footprint.x, maxi(surface_fp.x, reservation_fp.x))
		max_surface_footprint.y = maxi(max_surface_footprint.y, maxi(surface_fp.y, reservation_fp.y))
	if max_surface_footprint == Vector2i.ZERO:
		return Vector2.ZERO

	var front_inset = _parcel_front_setback({"road_kind": "main"})
	var side_inset = 1.0
	return Vector2(
		float(max_surface_footprint.x) + front_inset + side_inset,
		float(max_surface_footprint.y) + side_inset + side_inset
	)

func _get_town_layout(town: Dictionary, catalog: Dictionary = {}) -> Dictionary:
	if town.has("_layout"):
		return town["_layout"]

	var rng = RandomNumberGenerator.new()
	rng.seed = hash("%d_%d_layout" % [int(town.x), int(town.z)]) + world_seed + 900
	var cx = float(town.x)
	var cz = float(town.z)
	var radius = float(town.radius)
	var plaza_half = max(14.0, radius * 0.18)
	var main_width = settlement_road_width + 2.0
	var secondary_width = settlement_road_width
	var ring_radius = clampf(radius * 0.58, plaza_half + 14.0, radius - _road_layout_half(secondary_width) - 8.0)
	var spacing = clampf(radius / 2.5, 24.0, 38.0)
	var main_clear = _road_layout_half(main_width)
	var secondary_clear = _road_layout_half(secondary_width)
	var min_block_gap = 12.0
	var civic_requirements = _get_civic_parcel_requirements(catalog)
	var civic_width = max(18.0, max(radius * 0.30, civic_requirements.x))
	var civic_depth = max(16.0, max(radius * 0.28, civic_requirements.y))

	var x_corridors: Array = []
	var z_corridors: Array = []
	x_corridors.append({"center": cx - ring_radius, "width": secondary_width, "kind": "ring"})
	x_corridors.append({"center": cx, "width": main_width, "kind": "main"})
	x_corridors.append({"center": cx + ring_radius, "width": secondary_width, "kind": "ring"})
	z_corridors.append({"center": cz - ring_radius, "width": secondary_width, "kind": "ring"})
	z_corridors.append({"center": cz, "width": main_width, "kind": "main"})
	z_corridors.append({"center": cz + ring_radius, "width": secondary_width, "kind": "ring"})

	var side_min = max(plaza_half + 6.0, main_clear + secondary_clear + min_block_gap)
	var side_max = ring_radius - secondary_clear - 8.0
	if side_max - side_min >= 4.0:
		var side_mid = (side_min + side_max) * 0.5
		var jitter = min(4.0, (side_max - side_min) * 0.25)
		var side_offset_x = clampf(side_mid + rng.randf_range(-jitter, jitter), side_min, side_max)
		var side_offset_z = clampf(side_mid + rng.randf_range(-jitter, jitter), side_min, side_max)
		x_corridors.append({"center": cx - side_offset_x, "width": secondary_width, "kind": "secondary"})
		x_corridors.append({"center": cx + side_offset_x, "width": secondary_width, "kind": "secondary"})
		z_corridors.append({"center": cz - side_offset_z, "width": secondary_width, "kind": "secondary"})
		z_corridors.append({"center": cz + side_offset_z, "width": secondary_width, "kind": "secondary"})

	x_corridors.sort_custom(func(a, b): return float(a.center) < float(b.center))
	z_corridors.sort_custom(func(a, b): return float(a.center) < float(b.center))

	var roads: Array = []
	var road_extent = radius - (_road_layout_half(settlement_road_width) + 2.0)
	for corridor in x_corridors:
		roads.append({
			"from": Vector2(float(corridor.center), cz - road_extent),
			"to": Vector2(float(corridor.center), cz + road_extent),
			"width": float(corridor.width),
			"kind": str(corridor.kind)
		})
	for corridor in z_corridors:
		roads.append({
			"from": Vector2(cx - road_extent, float(corridor.center)),
			"to": Vector2(cx + road_extent, float(corridor.center)),
			"width": float(corridor.width),
			"kind": str(corridor.kind)
		})

	var gateway_data := _build_town_gateways(town, x_corridors, z_corridors, ring_radius, rng)
	roads.append_array(gateway_data.get("roads", []))
	var blocks: Array = _build_town_blocks(town, x_corridors, z_corridors, plaza_half, ring_radius)
	var layout = {
		"spacing": spacing,
		"plaza_half": plaza_half,
		"ring_radius": ring_radius,
		"main_width": main_width,
		"secondary_width": secondary_width,
		"civic_width": civic_width,
		"civic_depth": civic_depth,
		"x_corridors": x_corridors,
		"z_corridors": z_corridors,
		"gateways": gateway_data.get("gateways", []),
		"roads": roads,
		"blocks": blocks
	}
	town["_layout"] = layout
	return layout

func _road_kind_priority(kind: String) -> int:
	match kind:
		"main":
			return 4
		"secondary":
			return 3
		"ring":
			return 2
		"boundary":
			return 0
		_:
			return 0

func _road_clear_half(width: float) -> float:
	return width * 0.5 + ROAD_BLEND_MARGIN + settlement_lot_setback + 2.0

func _road_layout_half(width: float) -> float:
	return width * 0.5 + ROAD_BLEND_MARGIN + 1.0

func _preferred_gateway_side(town_pos: Vector2, target_pos: Vector2) -> String:
	var delta = target_pos - town_pos
	if abs(delta.x) > abs(delta.y):
		return "east" if delta.x > 0.0 else "west"
	return "south" if delta.y > 0.0 else "north"

func _choose_gateway_lane(corridors: Array, center_value: float, rng: RandomNumberGenerator) -> Dictionary:
	var candidates: Array = []
	var offset_candidates: Array = []
	for corridor in corridors:
		var kind = str(corridor.kind)
		if kind == "boundary":
			continue
		var candidate = {
			"center": float(corridor.center),
			"width": float(corridor.width),
			"kind": kind,
			"priority": _road_kind_priority(kind),
			"offset": abs(float(corridor.center) - center_value)
		}
		candidates.append(candidate)
		if float(candidate.offset) >= 8.0 and kind != "ring":
			offset_candidates.append(candidate)

	var pool = offset_candidates if not offset_candidates.is_empty() else candidates
	pool.sort_custom(func(a, b):
		if int(a.priority) == int(b.priority):
			if abs(float(a.offset) - float(b.offset)) <= 0.5:
				return float(a.center) < float(b.center)
			return float(a.offset) < float(b.offset)
		return int(a.priority) > int(b.priority)
	)
	return pool[0] if not pool.is_empty() else {}

func _build_town_gateways(town: Dictionary, x_corridors: Array, z_corridors: Array, ring_radius: float, rng: RandomNumberGenerator) -> Dictionary:
	var cx = float(town.x)
	var cz = float(town.z)
	var radius = float(town.radius)
	var boundary_margin = _road_layout_half(settlement_road_width) + 2.0
	var gateways: Array = []
	var lane_map := {
		"north": _choose_gateway_lane(x_corridors, cx, rng),
		"south": _choose_gateway_lane(x_corridors, cx, rng),
		"west": _choose_gateway_lane(z_corridors, cz, rng),
		"east": _choose_gateway_lane(z_corridors, cz, rng)
	}
	for side in lane_map:
		var lane: Dictionary = lane_map[side]
		if lane.is_empty():
			continue
		var width = float(lane.get("width", settlement_road_width))
		var kind = str(lane.get("kind", "secondary"))
		var entry := Vector2.ZERO
		match side:
			"north":
				entry = Vector2(float(lane.center), cz - radius + boundary_margin)
			"south":
				entry = Vector2(float(lane.center), cz + radius - boundary_margin)
			"west":
				entry = Vector2(cx - radius + boundary_margin, float(lane.center))
			"east":
				entry = Vector2(cx + radius - boundary_margin, float(lane.center))
		gateways.append({
			"side": side,
			"entry": entry,
			"width": width,
			"kind": kind
		})
	return {
		"gateways": gateways,
		"roads": []
	}

func _choose_gateway_for_target(town: Dictionary, target_pos: Vector2, catalog: Dictionary = {}) -> Dictionary:
	var layout = _get_town_layout(town, catalog)
	var gateways: Array = layout.get("gateways", [])
	if gateways.is_empty():
		return {"entry": Vector2(town.x, town.z), "side": "center", "kind": "main"}
	var preferred_side = _preferred_gateway_side(Vector2(town.x, town.z), target_pos)
	var preferred: Array = []
	for gateway in gateways:
		if str(gateway.get("side", "")) == preferred_side:
			preferred.append(gateway)
	var pool = preferred if not preferred.is_empty() else gateways
	pool.sort_custom(func(a, b):
		var a_priority = _road_kind_priority(str(a.get("kind", "secondary")))
		var b_priority = _road_kind_priority(str(b.get("kind", "secondary")))
		if a_priority == b_priority:
			return Vector2(a.get("entry", Vector2.ZERO)).distance_to(target_pos) < Vector2(b.get("entry", Vector2.ZERO)).distance_to(target_pos)
		return a_priority > b_priority
	)
	return pool[0]

func _build_corridor_spans(corridors: Array) -> Array:
	var spans: Array = []
	for corridor in corridors:
		var center = float(corridor.center)
		var width = float(corridor.width)
		var clear_half = _road_layout_half(width)
		spans.append({
			"center": center,
			"width": width,
			"kind": str(corridor.kind),
			"min": center - clear_half,
			"max": center + clear_half
		})
	return spans

func _build_town_blocks(town: Dictionary, x_corridors: Array, z_corridors: Array, plaza_half: float, ring_radius: float) -> Array:
	var blocks: Array = []
	var town_center = Vector2(town.x, town.z)
	var x_spans = _build_corridor_spans(x_corridors)
	var z_spans = _build_corridor_spans(z_corridors)

	var x_gaps: Array = []
	var x_cursor = float(town.x) - float(town.radius)
	var x_left_kind = "boundary"
	for span in x_spans:
		var gap_min_x = x_cursor
		var gap_max_x = float(span.min)
		if gap_max_x - gap_min_x >= 12.0:
			x_gaps.append({
				"min": gap_min_x,
				"max": gap_max_x,
				"min_kind": x_left_kind,
				"max_kind": str(span.kind)
			})
		x_cursor = float(span.max)
		x_left_kind = str(span.kind)
	var x_outer_max = float(town.x) + float(town.radius)
	if x_outer_max - x_cursor >= 12.0:
		x_gaps.append({
			"min": x_cursor,
			"max": x_outer_max,
			"min_kind": x_left_kind,
			"max_kind": "boundary"
		})

	var z_gaps: Array = []
	var z_cursor = float(town.z) - float(town.radius)
	var z_top_kind = "boundary"
	for span in z_spans:
		var gap_min_z = z_cursor
		var gap_max_z = float(span.min)
		if gap_max_z - gap_min_z >= 12.0:
			z_gaps.append({
				"min": gap_min_z,
				"max": gap_max_z,
				"min_kind": z_top_kind,
				"max_kind": str(span.kind)
			})
		z_cursor = float(span.max)
		z_top_kind = str(span.kind)
	var z_outer_max = float(town.z) + float(town.radius)
	if z_outer_max - z_cursor >= 12.0:
		z_gaps.append({
			"min": z_cursor,
			"max": z_outer_max,
			"min_kind": z_top_kind,
			"max_kind": "boundary"
		})

	for x_gap in x_gaps:
		var x0 = float(x_gap.min)
		var x1 = float(x_gap.max)
		var block_w = x1 - x0
		for z_gap in z_gaps:
			var z0 = float(z_gap.min)
			var z1 = float(z_gap.max)
			var block_d = z1 - z0

			var center = Vector2((x0 + x1) * 0.5, (z0 + z1) * 0.5)
			var dist_to_center = center.distance_to(town_center)
			if dist_to_center > float(town.radius) * 1.05:
				continue

			var roads = {
				"west": str(x_gap.min_kind),
				"east": str(x_gap.max_kind),
				"north": str(z_gap.min_kind),
				"south": str(z_gap.max_kind)
			}
			var main_edges = 0
			var secondary_edges = 0
			var road_edges = 0
			for side_name in roads:
				var kind = str(roads[side_name])
				if kind == "main":
					main_edges += 1
				elif kind == "secondary":
					secondary_edges += 1
				elif kind != "boundary":
					road_edges += 1
			if road_edges <= 0:
				continue

			var dist_norm = dist_to_center / max(1.0, ring_radius)
			var district = "residential"
			if dist_to_center <= plaza_half + 28.0 and road_edges >= 2:
				district = "civic"
			elif dist_norm <= 0.72 and (main_edges >= 1 or secondary_edges >= 1 or road_edges >= 2):
				district = "mainstreet"
			elif dist_norm >= 0.90:
				district = "edge"

			var score = block_w * block_d * 0.01
			score += float(main_edges) * 2.2
			score += float(secondary_edges) * 0.9
			score += float(road_edges) * 0.35
			score -= dist_norm * 0.45
			if district == "civic":
				score += 3.0
			elif district == "mainstreet":
				score += 1.7
			elif district == "edge":
				score += 0.2

			blocks.append({
				"min": Vector2(x0, z0),
				"max": Vector2(x1, z1),
				"size": Vector2(block_w, block_d),
				"center": center,
				"district": district,
				"roads": roads,
				"score": score
			})

	blocks.sort_custom(func(a, b): return a.score > b.score)
	return blocks

func _frontage_axis(side: String) -> String:
	if side == "north" or side == "south":
		return "z"
	return "x"

func _select_block_frontages(block: Dictionary) -> Array:
	var size: Vector2 = block.size
	var candidates: Array = []
	for side in ["north", "south", "west", "east"]:
		var kind = str(block.roads[side])
		if kind == "boundary":
			continue
		var length = size.x if side == "north" or side == "south" else size.y
		candidates.append({
			"side": side,
			"kind": kind,
			"priority": _road_kind_priority(kind),
			"length": length
		})

	candidates.sort_custom(func(a, b):
		if int(a.priority) == int(b.priority):
			return float(a.length) > float(b.length)
		return int(a.priority) > int(b.priority)
	)

	var max_sides = 1
	var min_dim = min(size.x, size.y)
	if block.district == "civic":
		max_sides = 4 if min_dim >= 28.0 else 3
	elif block.district == "mainstreet":
		max_sides = 4 if min_dim >= 22.0 else 3
	elif min_dim >= 26.0:
		max_sides = 3
	elif min_dim >= 20.0:
		max_sides = 2

	var selected: Array = []
	for frontage in candidates:
		if selected.size() >= max_sides:
			break
		var side = str(frontage.side)
		var axis = _frontage_axis(side)
		var axis_taken = false
		for existing in selected:
			if _frontage_axis(str(existing.side)) == axis:
				axis_taken = true
				break
		if axis_taken:
			var axis_size = size.y if axis == "z" else size.x
			if axis_size < 18.0:
				continue
		selected.append(frontage)
	return selected

func _create_block_frontage_parcels(block: Dictionary) -> Array:
	var parcels: Array = []
	var block_min: Vector2 = block.min
	var block_max: Vector2 = block.max
	var size: Vector2 = block.size
	var edge_buffer = 1.5

	for frontage in _select_block_frontages(block):
		var side = str(frontage.side)
		var kind = str(frontage.kind)
		var frontage_len = size.x if side == "north" or side == "south" else size.y
		var cross_depth = size.y if side == "north" or side == "south" else size.x
		var parcel_depth = cross_depth * (0.60 if kind == "main" or block.district == "civic" else 0.48)
		parcel_depth = clampf(parcel_depth, 14.0, cross_depth - 3.0)
		if frontage_len < 12.0 or parcel_depth < 10.0:
			continue

		var usable_frontage = frontage_len - edge_buffer * 2.0
		var target_width = 14.0 if block.district == "civic" or block.district == "mainstreet" or kind == "main" else 12.0
		var gap = 1.5
		var count = maxi(1, int(floor((usable_frontage + gap) / (target_width + gap))))
		count = mini(count, 9)
		while count > 1 and usable_frontage / float(count) < 9.0:
			count -= 1
		var cell_span = usable_frontage / float(count)

		for i in range(count):
			var parcel_min = Vector2.ZERO
			var parcel_max = Vector2.ZERO
			if side == "north" or side == "south":
				parcel_min.x = block_min.x + edge_buffer + cell_span * i
				parcel_max.x = block_min.x + edge_buffer + cell_span * (i + 1)
				if side == "north":
					parcel_min.y = block_min.y + edge_buffer
					parcel_max.y = parcel_min.y + parcel_depth
				else:
					parcel_max.y = block_max.y - edge_buffer
					parcel_min.y = parcel_max.y - parcel_depth
			else:
				parcel_min.y = block_min.y + edge_buffer + cell_span * i
				parcel_max.y = block_min.y + edge_buffer + cell_span * (i + 1)
				if side == "west":
					parcel_min.x = block_min.x + edge_buffer
					parcel_max.x = parcel_min.x + parcel_depth
				else:
					parcel_max.x = block_max.x - edge_buffer
					parcel_min.x = parcel_max.x - parcel_depth

			var parcel_size = parcel_max - parcel_min
			if parcel_size.x < 10.0 or parcel_size.y < 10.0:
				continue

			var parcel_center = (parcel_min + parcel_max) * 0.5
			var center_bias = 1.0 - abs((float(i) + 0.5) / float(count) - 0.5) * 2.0
			var frontage_target = parcel_center
			match side:
				"north":
					frontage_target = Vector2(parcel_center.x, block_min.y)
				"south":
					frontage_target = Vector2(parcel_center.x, block_max.y)
				"west":
					frontage_target = Vector2(block_min.x, parcel_center.y)
				"east":
					frontage_target = Vector2(block_max.x, parcel_center.y)

			parcels.append({
				"min": parcel_min,
				"max": parcel_max,
				"center": parcel_center,
				"size": parcel_size,
				"district": str(block.district),
				"road_kind": kind,
				"frontage_side": side,
				"frontage_target": frontage_target,
				"score": float(block.score) + float(frontage.priority) * 0.6 + center_bias * 0.5
			})
	return parcels

func _rotation_for_frontage_side(side: String) -> int:
	match side:
		"north":
			return 0
		"south":
			return 2
		"west":
			return 3
		"east":
			return 1
		_:
			return 0

func _parcel_front_setback(parcel: Dictionary) -> float:
	var road_kind = str(parcel.get("road_kind", "secondary"))
	var base = settlement_lot_setback + 1.5
	if road_kind == "main":
		return base + 0.5
	if road_kind == "ring":
		return base
	return base

func _fit_footprint_in_parcel(parcel: Dictionary, footprint: Vector2i) -> Vector2:
	var min_v: Vector2 = parcel.min
	var max_v: Vector2 = parcel.max
	var side = str(parcel.frontage_side)
	var front_inset = _parcel_front_setback(parcel)
	var side_inset = 1.0
	var usable_min = min_v + Vector2(side_inset, side_inset)
	var usable_max = max_v - Vector2(side_inset, side_inset)
	var usable_size = usable_max - usable_min
	if footprint.x > usable_size.x or footprint.y > usable_size.y:
		return Vector2(INF, INF)

	var x = usable_min.x + floor((usable_size.x - float(footprint.x)) * 0.5)
	var z = usable_min.y + floor((usable_size.y - float(footprint.y)) * 0.5)
	match side:
		"north":
			z = usable_min.y + front_inset
		"south":
			z = usable_max.y - front_inset - footprint.y
		"west":
			x = usable_min.x + front_inset
		"east":
			x = usable_max.x - front_inset - footprint.x
	return Vector2(floor(x), floor(z))

func _make_square_ring(center: Vector2, half_size: float) -> Array:
	var roads: Array = []
	if half_size <= 0.0:
		return roads
	var min_x = center.x - half_size
	var max_x = center.x + half_size
	var min_z = center.y - half_size
	var max_z = center.y + half_size
	roads.append({"from": Vector2(min_x, min_z), "to": Vector2(max_x, min_z), "width": settlement_road_width})
	roads.append({"from": Vector2(max_x, min_z), "to": Vector2(max_x, max_z), "width": settlement_road_width})
	roads.append({"from": Vector2(max_x, max_z), "to": Vector2(min_x, max_z), "width": settlement_road_width})
	roads.append({"from": Vector2(min_x, max_z), "to": Vector2(min_x, min_z), "width": settlement_road_width})
	return roads

# ============================================================================
# INTERNAL TOWN ROADS
# ============================================================================

func _generate_town_internal_roads(town: Dictionary, catalog: Dictionary) -> Array:
	return _get_town_layout(town, catalog).get("roads", [])

# ============================================================================
# ROAD RASTERIZATION
# ============================================================================

func _rasterize_roads(segments: Array, height_bytes: PackedByteArray, biome_bytes: PackedByteArray,
		road_bytes: PackedByteArray, max_h: float, half: int, r_width: float) -> void:
	var half_w = r_width * 0.5
	var flatten_w = r_width + ROAD_BLEND_MARGIN  # Match the same shoulder width used for building clearance
	
	for seg in segments:
		var from_v: Vector2 = seg["from"]
		var to_v: Vector2 = seg["to"]
		var seg_width = float(seg.get("width", r_width))
		var seg_len = from_v.distance_to(to_v)
		if seg_len < 1.0:
			continue
		var dir = (to_v - from_v) / seg_len  # Normalized direction
		
		# Bounding box of segment, expanded by flatten_w
		var half_w_local = seg_width * 0.5
		var flatten_local = seg_width + ROAD_BLEND_MARGIN
		var min_x = int(min(from_v.x, to_v.x) - flatten_local) + half
		var max_x = int(max(from_v.x, to_v.x) + flatten_local) + half
		var min_z = int(min(from_v.y, to_v.y) - flatten_local) + half
		var max_z = int(max(from_v.y, to_v.y) + flatten_local) + half
		min_x = clampi(min_x, 0, MAP_SIZE - 1)
		max_x = clampi(max_x, 0, MAP_SIZE - 1)
		min_z = clampi(min_z, 0, MAP_SIZE - 1)
		max_z = clampi(max_z, 0, MAP_SIZE - 1)
		
		# Scan every pixel in the bounding box
		for pz in range(min_z, max_z + 1):
			var wz = float(pz - half)
			for px in range(min_x, max_x + 1):
				var wx = float(px - half)
				var point = Vector2(wx, wz)
				
				# Compute perpendicular distance from point to line segment
				var ap = point - from_v
				var t = clampf(ap.dot(dir), 0.0, seg_len)  # Project onto segment
				var closest = from_v + dir * t
				var dist = point.distance_to(closest)
				
				if dist > flatten_local:
					continue
				
				# Road height at the closest point on the segment
				var r_height = _get_road_height_at(closest.x, closest.y)
				var idx = pz * MAP_SIZE + px
				var ridx = idx * 2
				
				if dist < half_w_local:
					# Road surface — overwrite height, biome, and road mask
					var r_height_byte = int(clampf(r_height / 64.0, 0.0, 1.0) * 255.0)
					var h_byte = _encode_height_byte(r_height, max_h)
					road_bytes[ridx] = 255
					road_bytes[ridx + 1] = r_height_byte
					biome_bytes[idx] = MaterialID.ROAD
					height_bytes[idx] = h_byte
				else:
					# Blend zone — smooth lerp from road height to terrain height
					var blend_t = clampf((dist - half_w_local) / (flatten_local - half_w_local), 0.0, 1.0)
					var orig_h = float(height_bytes[idx]) / 255.0 * max_h
					var blended = lerp(r_height, orig_h, blend_t)
					height_bytes[idx] = _encode_height_byte(blended, max_h)

func _rasterize_paths(segments: Array, height_bytes: PackedByteArray, biome_bytes: PackedByteArray,
		road_bytes: PackedByteArray, max_h: float, half: int) -> void:
	for seg in segments:
		var from_v: Vector2 = seg["from"]
		var to_v: Vector2 = seg["to"]
		var seg_width = float(seg.get("width", building_path_width))
		var from_y = float(seg.get("from_y", 12.0))
		var to_y = float(seg.get("to_y", from_y))
		var seg_len = from_v.distance_to(to_v)
		if seg_len < 0.5:
			continue
		var dir = (to_v - from_v) / seg_len
		var half_w_local = seg_width * 0.5
		var rise = abs(to_y - from_y)
		var slope = rise / max(seg_len, 1.0)
		var slope_blend = clampf((slope - PATH_TERRAIN_BLEND_SLOPE_START) / max(0.001, PATH_TERRAIN_BLEND_SLOPE_FULL - PATH_TERRAIN_BLEND_SLOPE_START), 0.0, 1.0)
		var length_blend = clampf((seg_len - PATH_TERRAIN_BLEND_LENGTH_START) / max(0.001, PATH_TERRAIN_BLEND_LENGTH_FULL - PATH_TERRAIN_BLEND_LENGTH_START), 0.0, 1.0)
		var terrain_blend = max(slope_blend, length_blend)
		var shoulder_width = PATH_SHOULDER_BASE + clampf(slope * PATH_SHOULDER_SLOPE_FACTOR, 0.0, PATH_SHOULDER_SLOPE_CAP)
		# Steep links get a narrow core only so they do not carve broad terraces into the shoreline.
		if slope > PATH_SHOULDER_STEEP_LIMIT or rise > 3.0:
			shoulder_width = 0.0
		var flatten_local = half_w_local + shoulder_width
		var min_x = clampi(int(min(from_v.x, to_v.x) - flatten_local) + half, 0, MAP_SIZE - 1)
		var max_x = clampi(int(max(from_v.x, to_v.x) + flatten_local) + half, 0, MAP_SIZE - 1)
		var min_z = clampi(int(min(from_v.y, to_v.y) - flatten_local) + half, 0, MAP_SIZE - 1)
		var max_z = clampi(int(max(from_v.y, to_v.y) + flatten_local) + half, 0, MAP_SIZE - 1)
		for pz in range(min_z, max_z + 1):
			var wz = float(pz - half)
			for px in range(min_x, max_x + 1):
				var wx = float(px - half)
				var point = Vector2(wx, wz)
				var ap = point - from_v
				var t = clampf(ap.dot(dir), 0.0, seg_len)
				var closest = from_v + dir * t
				var dist = point.distance_to(closest)
				if dist > flatten_local:
					continue
				var path_u = t / seg_len
				var eased_u = path_u * path_u * (3.0 - 2.0 * path_u)
				var idx = pz * MAP_SIZE + px
				var ridx = idx * 2
				var terrain_h = float(height_bytes[idx]) / 255.0 * max_h
				var path_y = lerp(lerp(from_y, to_y, eased_u), terrain_h, terrain_blend)
				if dist < half_w_local:
					var h_byte = _encode_height_byte(path_y, max_h)
					var r_height_byte = int(clampf(path_y / 64.0, 0.0, 1.0) * 255.0)
					road_bytes[ridx] = max(road_bytes[ridx], 196)
					road_bytes[ridx + 1] = max(road_bytes[ridx + 1], r_height_byte)
					biome_bytes[idx] = MaterialID.ROAD
					height_bytes[idx] = h_byte
				elif shoulder_width > 0.0:
					var blend_t = clampf((dist - half_w_local) / max(0.001, flatten_local - half_w_local), 0.0, 1.0)
					var smooth_t = blend_t * blend_t * (3.0 - 2.0 * blend_t)
					smooth_t = smooth_t * smooth_t * (3.0 - 2.0 * smooth_t)
					var blended = lerp(path_y, terrain_h, smooth_t)
					height_bytes[idx] = _encode_height_byte(blended, max_h)

func _get_road_height_at(wx: float, wz: float) -> float:
	# Same formula as chunk_manager gen_density shader
	var h = _road_height_noise.get_noise_2d(wx, wz) * 3.0 + 12.0
	# Step it
	var base_level = floor(h)
	var frac_val = h - base_level
	if frac_val < 0.45:
		return base_level
	elif frac_val > 0.55:
		return base_level + 1.0
	else:
		var ramp_t = (frac_val - 0.45) / 0.1
		ramp_t = ramp_t * ramp_t * (3.0 - 2.0 * ramp_t)
		return base_level + ramp_t

# ============================================================================
# TOWN BUILDING LOTS — organized along roads, facing road, collision-checked
# ============================================================================

## Get the footprint (width, depth) of a prefab by name. Reads JSON if available.
func _get_prefab_footprint(prefab_name: String) -> Vector2i:
	return PrefabGeometry.get_rotated_surface_footprint(prefab_name, 0)

func _get_prefab_reservation_footprint(prefab_name: String) -> Vector2i:
	return PrefabGeometry.get_rotated_reservation_footprint(prefab_name, 0)

func _get_prefab_reservation_rect(prefab_name: String, rotation: int, surface_x: float, surface_z: float) -> Dictionary:
	var surface_bounds := PrefabGeometry.get_rotated_surface_bounds(prefab_name, rotation)
	var reservation_bounds := PrefabGeometry.get_rotated_reservation_bounds(prefab_name, rotation)
	var surface_min: Vector2i = surface_bounds.get("min", Vector2i.ZERO)
	var reservation_min: Vector2i = reservation_bounds.get("min", Vector2i.ZERO)
	var reservation_fp: Vector2i = reservation_bounds.get("footprint", Vector2i.ONE)
	return {
		"x": surface_x + float(reservation_min.x - surface_min.x),
		"z": surface_z + float(reservation_min.y - surface_min.y),
		"w": float(reservation_fp.x),
		"d": float(reservation_fp.y)
	}

## Check if two axis-aligned rectangles overlap (with margin)
func _rects_overlap(ax: float, az: float, aw: float, ad: float,
		bx: float, bz: float, bw: float, bd: float, margin: float) -> bool:
	return not (ax + aw + margin <= bx or bx + bw + margin <= ax or
				az + ad + margin <= bz or bz + bd + margin <= az)

func _generate_town_building_slots(town: Dictionary, layout: Dictionary, road_segments: Array, rng: RandomNumberGenerator) -> Array:
	var slots: Array = _get_civic_core_parcels(town, layout)
	for block in layout.get("blocks", []):
		slots.append_array(_create_block_frontage_parcels(block))

	slots.sort_custom(func(a, b): return a.score > b.score)
	return slots

func _get_civic_core_parcels(town: Dictionary, layout: Dictionary) -> Array:
	var parcels: Array = []
	var cx = float(town.x)
	var cz = float(town.z)
	var radius = float(town.radius)
	var plaza_half = float(layout.get("plaza_half", 14.0))
	var main_width = float(layout.get("main_width", settlement_road_width + 2.0))
	var road_clear = _road_layout_half(main_width)
	# Civic parcels need enough room for the largest landmark prefab in the catalog.
	var civic_width = float(layout.get("civic_width", clampf(radius * 0.50, 18.0, 32.0)))
	var civic_depth = float(layout.get("civic_depth", clampf(radius * 0.32, 16.0, 24.0)))
	var civic_buffer = max(civic_width, civic_depth) + ROAD_BLEND_MARGIN + settlement_lot_setback
	var offset = max(plaza_half, road_clear) + max(3.5, civic_buffer)
	var north_mid = cz - offset - civic_depth * 0.5
	var south_mid = cz + offset + civic_depth * 0.5
	var definitions = [
		{
			"frontage_side": "east",
			"frontage_target": Vector2(cx - offset, north_mid),
			"min": Vector2(cx - offset - 1.5 - civic_width, cz - offset - civic_depth),
			"max": Vector2(cx - offset - 1.5, cz - offset)
		},
		{
			"frontage_side": "west",
			"frontage_target": Vector2(cx + offset, north_mid),
			"min": Vector2(cx + offset + 1.5, cz - offset - civic_depth),
			"max": Vector2(cx + offset + 1.5 + civic_width, cz - offset)
		},
		{
			"frontage_side": "east",
			"frontage_target": Vector2(cx - offset, south_mid),
			"min": Vector2(cx - offset - 1.5 - civic_width, cz + offset),
			"max": Vector2(cx - offset - 1.5, cz + offset + civic_depth)
		},
		{
			"frontage_side": "west",
			"frontage_target": Vector2(cx + offset, south_mid),
			"min": Vector2(cx + offset + 1.5, cz + offset),
			"max": Vector2(cx + offset + 1.5 + civic_width, cz + offset + civic_depth)
		}
	]
	for definition in definitions:
		var parcel_min: Vector2 = definition.min
		var parcel_max: Vector2 = definition.max
		if parcel_max.x - parcel_min.x < 12.0 or parcel_max.y - parcel_min.y < 12.0:
			continue
		parcels.append({
			"min": parcel_min,
			"max": parcel_max,
			"center": (parcel_min + parcel_max) * 0.5,
			"size": parcel_max - parcel_min,
			"district": "civic",
			"road_kind": "main",
			"frontage_side": str(definition.frontage_side),
			"frontage_target": Vector2(definition.frontage_target),
			"score": 100.0
		})
	return parcels

func _fit_footprint_variants_in_parcel(parcel: Dictionary, footprint: Vector2i) -> Array:
	var base = _fit_footprint_in_parcel(parcel, footprint)
	if base.x == INF:
		return []
	var min_v: Vector2 = parcel.min
	var max_v: Vector2 = parcel.max
	var side = str(parcel.frontage_side)
	var front_inset = _parcel_front_setback(parcel)
	var side_inset = 1.0
	var usable_min = min_v + Vector2(side_inset, side_inset)
	var usable_max = max_v - Vector2(side_inset, side_inset)
	var usable_size = usable_max - usable_min
	var positions: Array = []
	var candidates: Array = []
	if side == "north" or side == "south":
		var min_x = usable_min.x
		var max_x = usable_max.x - float(footprint.x)
		var front_min = usable_min.y + front_inset
		var front_max = usable_max.y - front_inset - float(footprint.y)
		var front_candidates: Array = [front_min]
		if front_max - front_min >= 2.0:
			front_candidates.append(floor(lerp(front_min, front_max, 0.5)))
			front_candidates.append(front_max)
		candidates = [0.0, 0.5, 1.0]
		if max_x - min_x >= 10.0:
			candidates = [0.0, 0.25, 0.5, 0.75, 1.0]
		for z in front_candidates:
			for t in candidates:
				var x = floor(lerp(min_x, max_x, float(t)))
				var pos = Vector2(x, floor(z))
				if not positions.has(pos):
					positions.append(pos)
	else:
		var min_z = usable_min.y
		var max_z = usable_max.y - float(footprint.y)
		var front_min = usable_min.x + front_inset
		var front_max = usable_max.x - front_inset - float(footprint.x)
		var front_candidates: Array = [front_min]
		if front_max - front_min >= 2.0:
			front_candidates.append(floor(lerp(front_min, front_max, 0.5)))
			front_candidates.append(front_max)
		candidates = [0.0, 0.5, 1.0]
		if max_z - min_z >= 10.0:
			candidates = [0.0, 0.25, 0.5, 0.75, 1.0]
		for x in front_candidates:
			for t in candidates:
				var z = floor(lerp(min_z, max_z, float(t)))
				var pos = Vector2(floor(x), z)
				if not positions.has(pos):
					positions.append(pos)
	if not positions.has(base):
		positions.push_front(base)
	return positions

func _clip_segment_to_footprint_edge(start: Vector2, target: Vector2, bldg_x: float, bldg_z: float, footprint: Vector2i) -> Vector2:
	var rect_min = Vector2(bldg_x, bldg_z)
	var rect_max = Vector2(bldg_x + float(footprint.x), bldg_z + float(footprint.y))
	if not _point_in_rect(target, rect_min, rect_max):
		return target
	var dir = target - start
	if dir.length_squared() <= 0.0001:
		return target
	var intersections: Array = []
	var corners = [
		Vector2(rect_min.x, rect_min.y),
		Vector2(rect_max.x, rect_min.y),
		Vector2(rect_max.x, rect_max.y),
		Vector2(rect_min.x, rect_max.y)
	]
	for i in range(4):
		var a = corners[i]
		var b = corners[(i + 1) % 4]
		var hit = Geometry2D.segment_intersects_segment(start, target, a, b)
		if hit != null:
			intersections.append(hit)
	if intersections.is_empty():
		return target
	intersections.sort_custom(func(a, b): return start.distance_to(a) < start.distance_to(b))
	return intersections[0]

func _sample_world_height(wx: float, wz: float, height_bytes: PackedByteArray, max_h: float, half: int) -> float:
	var px = clampi(int(round(wx)) + half, 0, MAP_SIZE - 1)
	var pz = clampi(int(round(wz)) + half, 0, MAP_SIZE - 1)
	return clampf(float(height_bytes[pz * MAP_SIZE + px]) / 255.0 * max_h, 1.0, 28.0)

func _encode_height_byte(height: float, max_h: float) -> int:
	return int(round(clampf(height / max_h, 0.0, 1.0) * 255.0))

func _append_path_segment(path_segments: Array, from_v: Vector2, to_v: Vector2, width: float, from_y: float, to_y: float) -> void:
	if from_v.distance_to(to_v) < 0.35:
		return
	path_segments.append({
		"from": from_v,
		"to": to_v,
		"width": width,
		"from_y": from_y,
		"to_y": to_y
	})

func _append_door_path_segment(path_segments: Array, frontage_target: Vector2, road_target: Vector2, prefab_name: String,
		spawn_origin: Vector3, rotation: int, bldg_x: float, bldg_z: float, footprint: Vector2i, road_y: float,
		bldg_y: float, height_bytes: PackedByteArray, max_h: float, half: int) -> void:
	var door_center_var = PrefabGeometry.get_primary_door_world_center(prefab_name, spawn_origin, rotation)
	if door_center_var == null:
		return
	var door_center: Vector3 = door_center_var
	var door_target = _clip_segment_to_footprint_edge(frontage_target, Vector2(door_center.x, door_center.z), bldg_x, bldg_z, footprint)
	var door_to_frontage = frontage_target - door_target
	if door_to_frontage.length() < 0.5 and road_target.distance_to(frontage_target) < 0.75:
		return
	var landing_point = door_target
	if door_to_frontage.length() > 0.5:
		var landing_dist = min(3.5, max(1.5, door_to_frontage.length() * 0.35))
		landing_dist = min(landing_dist, max(0.75, door_to_frontage.length() - 0.35))
		landing_point = door_target + door_to_frontage.normalized() * landing_dist
	var frontage_y = _sample_world_height(frontage_target.x, frontage_target.y, height_bytes, max_h, half)
	_append_path_segment(path_segments, door_target, landing_point, building_path_width + 0.35, bldg_y, bldg_y)
	var frontage_link_length = landing_point.distance_to(frontage_target)
	var frontage_link_rise = abs(frontage_y - bldg_y)
	var frontage_link_slope = frontage_link_rise / max(frontage_link_length, 1.0)
	# If the frontage climb is steep, skip the ramp rather than carving a long shelf.
	if frontage_link_rise <= PATH_FRONTAGE_MAX_RISE and frontage_link_slope <= PATH_FRONTAGE_MAX_SLOPE:
		_append_path_segment(path_segments, landing_point, frontage_target, building_path_width, bldg_y, frontage_y)
	var road_link_length = frontage_target.distance_to(road_target)
	var road_link_rise = abs(road_y - frontage_y)
	var road_link_slope = road_link_rise / max(road_link_length, 1.0)
	# Only draw the final road connector when it is short and gentle enough to avoid terrain shelves.
	if road_link_length <= PATH_ROAD_LINK_MAX_LENGTH and road_link_rise <= PATH_ROAD_LINK_MAX_RISE and road_link_slope <= PATH_ROAD_LINK_MAX_SLOPE:
		_append_path_segment(path_segments, frontage_target, road_target, building_path_width, frontage_y, road_y)

func _append_baked_excavation_modifications(terrain_modifications: Array, prefab_name: String, spawn_origin: Vector3, rotation: int) -> void:
	var segments := PrefabGeometry.get_rotated_excavation_segments(prefab_name, rotation)
	for segment in segments:
		var world_y_min := spawn_origin.y + float(segment.get("min_y", 0))
		var world_y_max := spawn_origin.y + float(segment.get("max_y", -1)) + 1.0
		if world_y_max <= world_y_min:
			continue
		var world_x := int(floor(spawn_origin.x)) + int(segment.get("x", 0))
		var world_z := int(floor(spawn_origin.z)) + int(segment.get("z", 0))
		terrain_modifications.append({
			"brush_pos": [
				float(world_x) + 0.5,
				(world_y_min + world_y_max) * 0.5,
				float(world_z) + 0.5
			],
			"radius": 0.6,
			"value": 10.0,
			"shape": 2,
			"layer": 0,
			"y_min": world_y_min,
			"y_max": world_y_max,
			"material_id": -1
		})

func _append_baked_building(buildings: Array, terrain_modifications: Array, path_segments: Array, height_bytes: PackedByteArray, max_h: float, half: int,
		road_segments: Array, prefab_name: String, bldg_x: float, bldg_y: float, bldg_z: float, footprint: Vector2i,
		rot: int, road_target: Vector2, district: String, road_kind: String, support_info: Dictionary = {}) -> void:
	var spawn_origin = PrefabGeometry.get_spawn_origin_for_surface_min(
		prefab_name,
		Vector3(bldg_x, bldg_y, bldg_z),
		rot
	)
	var protected_excavation_columns := _get_off_footprint_excavation_columns(prefab_name, spawn_origin, rot, bldg_x, bldg_z, footprint)
	var connection = _find_best_road_connection(road_target, road_segments, road_kind)
	var road_point: Vector2 = connection.get("point", road_target)
	var road_y = floor(_get_road_height_at(road_point.x, road_point.y))
	_flatten_building_pad(height_bytes, bldg_x, bldg_z, footprint, bldg_y, max_h, half, support_info, protected_excavation_columns)
	_append_door_path_segment(path_segments, road_target, road_point, prefab_name, spawn_origin, rot, bldg_x, bldg_z, footprint, road_y, bldg_y, height_bytes, max_h, half)
	_append_baked_excavation_modifications(terrain_modifications, prefab_name, spawn_origin, rot)
	buildings.append({
		"x": bldg_x, "y": bldg_y, "z": bldg_z,
		"anchor_mode": "occupied_min",
		"spawn_origin_x": spawn_origin.x,
		"spawn_origin_y": spawn_origin.y,
		"spawn_origin_z": spawn_origin.z,
		"footprint_w": footprint.x,
		"footprint_d": footprint.y,
		"road_y": road_y,
		"rotation": rot,
		"type": prefab_name,
		"district": district,
		"road_kind": road_kind
	})

func _place_forced_core_landmarks(town: Dictionary, layout: Dictionary, preferred_prefabs: Array, road_segments: Array, path_segments: Array, height_bytes: PackedByteArray, water_bytes: PackedByteArray, max_h: float, half: int, buildings: Array, terrain_modifications: Array, bldg_stats: Dictionary, occupied: Array, desired_count: int) -> int:
	var center = Vector2(float(town.x), float(town.z))
	var plaza_half = float(layout.get("plaza_half", 14.0))
	var main_width = float(layout.get("main_width", settlement_road_width + 2.0))
	var offset = max(plaza_half, _road_clear_half(main_width)) + 4.0
	var slot_defs = [
		{"side": "west", "road_target": Vector2(center.x + offset - 2.0, center.y)},
		{"side": "east", "road_target": Vector2(center.x - offset + 2.0, center.y)},
		{"side": "south", "road_target": Vector2(center.x, center.y + offset - 2.0)},
		{"side": "north", "road_target": Vector2(center.x, center.y - offset + 2.0)}
	]
	var placed = 0
	for slot in slot_defs:
		if placed >= desired_count:
			break
		var side = str(slot.side)
		var rot = _rotation_for_frontage_side(side)
		for prefab_name in preferred_prefabs:
			bldg_stats.attempted += 1
			var footprint = PrefabGeometry.get_rotated_surface_footprint(prefab_name, rot)
			var bldg_x = center.x - float(footprint.x) * 0.5
			var bldg_z = center.y - float(footprint.y) * 0.5
			match side:
				"west":
					bldg_x = center.x + offset
				"east":
					bldg_x = center.x - offset - float(footprint.x)
				"south":
					bldg_z = center.y + offset
				"north":
					bldg_z = center.y - offset - float(footprint.y)
			bldg_x = floor(bldg_x)
			bldg_z = floor(bldg_z)
			var reservation_rect := _get_prefab_reservation_rect(prefab_name, rot, bldg_x, bldg_z)
			var overlaps = false
			for occ in occupied:
				if _rects_overlap(reservation_rect.x, reservation_rect.z, reservation_rect.w, reservation_rect.d, occ.x, occ.z, occ.w, occ.d, 6.0):
					overlaps = true
					break
			if overlaps:
				continue
			var support = _resolve_town_building_support(bldg_x, bldg_z, footprint, road_segments, height_bytes, water_bytes, null, max_h, half, bldg_stats)
			if support.is_empty():
				continue
			var bldg_y = float(support.resolved_y)
			if not _has_sufficient_excavation_cover(prefab_name, bldg_x, bldg_y, bldg_z, footprint, rot, height_bytes, max_h, half):
				bldg_stats.rejected_cover += 1
				continue
			occupied.append(reservation_rect)
			bldg_stats.placed += 1
			placed += 1
			_append_baked_building(buildings, terrain_modifications, path_segments, height_bytes, max_h, half, road_segments,
				prefab_name, bldg_x, bldg_y, bldg_z, footprint, rot, Vector2(slot.road_target),
				"core_landmark", "main", support)
			break
	return placed

func _place_landmarks_from_parcel_candidates(parcel_candidates: Array, preferred_prefabs: Array, road_segments: Array,
		path_segments: Array, height_bytes: PackedByteArray, water_bytes: PackedByteArray, max_h: float, half: int,
		buildings: Array, terrain_modifications: Array, bldg_stats: Dictionary, occupied: Array, used_prefabs: Dictionary, desired_count: int) -> int:
	var used_parcels: Dictionary = {}
	var placed = 0
	for parcel_info in parcel_candidates:
		if placed >= desired_count:
			break
		var parcel_idx = int(parcel_info.idx)
		if used_parcels.has(parcel_idx):
			continue
		var parcel: Dictionary = parcel_info.parcel
		var rot = _rotation_for_frontage_side(str(parcel.frontage_side))
		for prefab_name in preferred_prefabs:
			if placed > 0 and used_prefabs.has(prefab_name) and preferred_prefabs.size() > 1:
				continue
			bldg_stats.attempted += 1
			var footprint = PrefabGeometry.get_rotated_surface_footprint(prefab_name, rot)
			var fitted_positions = _fit_footprint_variants_in_parcel(parcel, footprint)
			if fitted_positions.is_empty():
				continue
			for fitted in fitted_positions:
				var bldg_x = fitted.x
				var bldg_z = fitted.y
				var reservation_rect := _get_prefab_reservation_rect(prefab_name, rot, bldg_x, bldg_z)
				var overlaps = false
				for occ in occupied:
					if _rects_overlap(reservation_rect.x, reservation_rect.z, reservation_rect.w, reservation_rect.d, occ.x, occ.z, occ.w, occ.d, 6.0):
						overlaps = true
						break
				if overlaps:
					continue
				var support = _resolve_town_building_support(bldg_x, bldg_z, footprint, road_segments, height_bytes, water_bytes, null, max_h, half, bldg_stats)
				if support.is_empty():
					continue
				var bldg_y = float(support.resolved_y)
				if not _has_sufficient_excavation_cover(prefab_name, bldg_x, bldg_y, bldg_z, footprint, rot, height_bytes, max_h, half):
					bldg_stats.rejected_cover += 1
					continue
				occupied.append(reservation_rect)
				bldg_stats.placed += 1
				placed += 1
				used_parcels[parcel_idx] = true
				used_prefabs[prefab_name] = true
				_append_baked_building(buildings, terrain_modifications, path_segments, height_bytes, max_h, half, road_segments,
					prefab_name, bldg_x, bldg_y, bldg_z, footprint, rot, Vector2(parcel.frontage_target),
					"core_landmark", str(parcel.get("road_kind", "main")), support)
				break
			if used_parcels.has(parcel_idx):
				break
	return placed

func _get_town_required_prefabs(catalog: Dictionary) -> Array[String]:
	var entries: Array = []
	for prefab_name in catalog:
		entries.append(catalog[prefab_name])
	entries.sort_custom(func(a, b):
		var area_a := int(a.get("area", 0))
		var area_b := int(b.get("area", 0))
		if area_a == area_b:
			return str(a.get("name", "")) < str(b.get("name", ""))
		return area_a > area_b
	)
	var required: Array[String] = []
	for entry in entries:
		required.append(str(entry.get("name", "")))
	return required

func _get_town_building_clearance_margin(footprint: Vector2i) -> float:
	return max(3.0, max(float(footprint.x), float(footprint.y)) * 0.35)

func _try_place_required_prefab_in_parcels(prefab_name: String, parcel_candidates: Array, used_parcels: Dictionary,
		road_segments: Array, path_segments: Array, height_bytes: PackedByteArray, water_bytes: PackedByteArray,
		forest_noise: FastNoiseLite, max_h: float, half: int, buildings: Array, terrain_modifications: Array, bldg_stats: Dictionary,
		occupied: Array) -> bool:
	for parcel_info in parcel_candidates:
		var parcel_idx := int(parcel_info.get("idx", -1))
		if used_parcels.has(parcel_idx):
			continue
		var parcel: Dictionary = parcel_info.get("parcel", {})
		if parcel.is_empty():
			continue
		var rot = _rotation_for_frontage_side(str(parcel.get("frontage_side", "north")))
		bldg_stats.attempted += 1
		var footprint = PrefabGeometry.get_rotated_surface_footprint(prefab_name, rot)
		var fitted_positions = _fit_footprint_variants_in_parcel(parcel, footprint)
		if fitted_positions.is_empty():
			continue
		var clearance_margin := _get_town_building_clearance_margin(footprint)
		for fitted in fitted_positions:
			var bldg_x = fitted.x
			var bldg_z = fitted.y
			var reservation_rect := _get_prefab_reservation_rect(prefab_name, rot, bldg_x, bldg_z)
			var overlaps = false
			for occ in occupied:
				if _rects_overlap(reservation_rect.x, reservation_rect.z, reservation_rect.w, reservation_rect.d, occ.x, occ.z, occ.w, occ.d, clearance_margin):
					overlaps = true
					break
			if overlaps:
				continue
			var support = _resolve_town_building_support(bldg_x, bldg_z, footprint, road_segments, height_bytes, water_bytes, forest_noise, max_h, half, bldg_stats)
			if support.is_empty():
				continue
			var bldg_y = float(support.resolved_y)
			if not _has_sufficient_excavation_cover(prefab_name, bldg_x, bldg_y, bldg_z, footprint, rot, height_bytes, max_h, half):
				bldg_stats.rejected_cover += 1
				continue
			occupied.append(reservation_rect)
			used_parcels[parcel_idx] = true
			bldg_stats.placed += 1
			_append_baked_building(buildings, terrain_modifications, path_segments, height_bytes, max_h, half, road_segments,
				prefab_name, bldg_x, bldg_y, bldg_z, footprint, rot, Vector2(parcel.frontage_target),
				str(parcel.get("district", "residential")), str(parcel.get("road_kind", "secondary")), support)
			return true
	return false

func _try_place_required_prefab_in_forced_core_slots(town: Dictionary, layout: Dictionary, prefab_name: String,
		road_segments: Array, path_segments: Array, height_bytes: PackedByteArray, water_bytes: PackedByteArray,
		max_h: float, half: int, buildings: Array, terrain_modifications: Array, bldg_stats: Dictionary, occupied: Array) -> bool:
	var center = Vector2(float(town.x), float(town.z))
	var plaza_half = float(layout.get("plaza_half", 14.0))
	var main_width = float(layout.get("main_width", settlement_road_width + 2.0))
	var offset = max(plaza_half, _road_clear_half(main_width)) + 4.0
	var slot_defs = [
		{"side": "west", "road_target": Vector2(center.x + offset - 2.0, center.y)},
		{"side": "east", "road_target": Vector2(center.x - offset + 2.0, center.y)},
		{"side": "south", "road_target": Vector2(center.x, center.y + offset - 2.0)},
		{"side": "north", "road_target": Vector2(center.x, center.y - offset + 2.0)}
	]
	for slot in slot_defs:
		var side = str(slot.side)
		var rot = _rotation_for_frontage_side(side)
		bldg_stats.attempted += 1
		var footprint = PrefabGeometry.get_rotated_surface_footprint(prefab_name, rot)
		var bldg_x = center.x - float(footprint.x) * 0.5
		var bldg_z = center.y - float(footprint.y) * 0.5
		match side:
			"west":
				bldg_x = center.x + offset
			"east":
				bldg_x = center.x - offset - float(footprint.x)
			"south":
				bldg_z = center.y + offset
			"north":
				bldg_z = center.y - offset - float(footprint.y)
		bldg_x = floor(bldg_x)
		bldg_z = floor(bldg_z)
		var clearance_margin := _get_town_building_clearance_margin(footprint)
		var reservation_rect := _get_prefab_reservation_rect(prefab_name, rot, bldg_x, bldg_z)
		var overlaps = false
		for occ in occupied:
			if _rects_overlap(reservation_rect.x, reservation_rect.z, reservation_rect.w, reservation_rect.d, occ.x, occ.z, occ.w, occ.d, clearance_margin):
				overlaps = true
				break
		if overlaps:
			continue
		var support = _resolve_town_building_support(bldg_x, bldg_z, footprint, road_segments, height_bytes, water_bytes, null, max_h, half, bldg_stats)
		if support.is_empty():
			continue
		var bldg_y = float(support.resolved_y)
		if not _has_sufficient_excavation_cover(prefab_name, bldg_x, bldg_y, bldg_z, footprint, rot, height_bytes, max_h, half):
			bldg_stats.rejected_cover += 1
			continue
		occupied.append(reservation_rect)
		bldg_stats.placed += 1
		_append_baked_building(buildings, terrain_modifications, path_segments, height_bytes, max_h, half, road_segments,
			prefab_name, bldg_x, bldg_y, bldg_z, footprint, rot, Vector2(slot.road_target),
			"core_landmark", "main", support)
		return true
	return false

func _place_required_prefabs_for_town(town: Dictionary, layout: Dictionary, required_prefabs: Array[String], parcel_slots: Array,
		road_segments: Array, path_segments: Array, height_bytes: PackedByteArray, water_bytes: PackedByteArray,
		forest_noise: FastNoiseLite, max_h: float, half: int, buildings: Array, terrain_modifications: Array, bldg_stats: Dictionary,
		occupied: Array) -> Dictionary:
	var parcel_candidates: Array = []
	for i in range(parcel_slots.size()):
		var parcel: Dictionary = parcel_slots[i]
		var parcel_size: Vector2 = parcel.get("size", Vector2.ZERO)
		parcel_candidates.append({
			"idx": i,
			"parcel": parcel,
			"area": float(parcel_size.x * parcel_size.y),
			"score": float(parcel.get("score", 0.0))
		})
	parcel_candidates.sort_custom(func(a, b):
		var area_a := float(a.get("area", 0.0))
		var area_b := float(b.get("area", 0.0))
		if abs(area_a - area_b) > 0.01:
			return area_a > area_b
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)

	var used_parcels: Dictionary = {}
	var missing: Array[String] = []
	var placed := 0
	for prefab_name in required_prefabs:
		if _try_place_required_prefab_in_parcels(prefab_name, parcel_candidates, used_parcels, road_segments, path_segments,
			height_bytes, water_bytes, forest_noise, max_h, half, buildings, terrain_modifications, bldg_stats, occupied):
			placed += 1
			continue
		if _try_place_required_prefab_in_forced_core_slots(town, layout, prefab_name, road_segments, path_segments,
			height_bytes, water_bytes, max_h, half, buildings, terrain_modifications, bldg_stats, occupied):
			placed += 1
			continue
		missing.append(prefab_name)
	return {
		"placed": placed,
		"missing": missing
	}

func _generate_town_buildings(towns: Array, road_segments: Array, path_segments: Array, height_bytes: PackedByteArray,
		water_bytes: PackedByteArray, road_bytes: PackedByteArray, catalog: Dictionary,
		max_h: float, half: int, buildings: Array, terrain_modifications: Array, bldg_stats: Dictionary) -> void:
	var forest_noise = FastNoiseLite.new()
	forest_noise.noise_type = FastNoiseLite.TYPE_VALUE
	forest_noise.seed = world_seed + 100
	forest_noise.frequency = 0.02
	
	for town in towns:
		var layout = _get_town_layout(town, catalog)
		var rng = RandomNumberGenerator.new()
		rng.seed = hash("%d_%d" % [int(town.x), int(town.z)]) + 42
		var required_prefabs := _get_town_required_prefabs(catalog)
		var target = maxi(int(town.building_count), required_prefabs.size())
		var placed_in_town = 0
		var occupied: Array = []
		var parcel_slots = _generate_town_building_slots(town, layout, road_segments, rng)
		var guarantee_result := _place_required_prefabs_for_town(town, layout, required_prefabs, parcel_slots,
			road_segments, path_segments, height_bytes, water_bytes, forest_noise, max_h, half, buildings, terrain_modifications, bldg_stats, occupied)
		placed_in_town += int(guarantee_result.get("placed", 0))
		var missing_required: Array = guarantee_result.get("missing", [])
		if not missing_required.is_empty():
			print("[WorldMapGen] Town at (%.0f,%.0f): missing guaranteed prefabs [%s]" % [
				town.x,
				town.z,
				", ".join(missing_required)
			])
		if placed_in_town >= target:
			print("[WorldMapGen] Town at (%.0f,%.0f): %d/%d buildings placed" % [town.x, town.z, placed_in_town, target])
			continue

		var landmark_count = _place_town_landmarks(town, layout, catalog, road_segments, path_segments, height_bytes, water_bytes, max_h, half, buildings, terrain_modifications, bldg_stats, occupied, rng, 2)
		if landmark_count > 0:
			placed_in_town += landmark_count
			if placed_in_town >= target:
				print("[WorldMapGen] Town at (%.0f,%.0f): %d/%d buildings placed" % [town.x, town.z, placed_in_town, target])
				continue

		target = mini(target, maxi(placed_in_town + 6, placed_in_town + parcel_slots.size()))
		if not parcel_slots.is_empty():
			for candidate in parcel_slots:
				if placed_in_town >= target:
					break

				bldg_stats.attempted += 1
				var district: String = candidate.district
				var rot = _rotation_for_frontage_side(str(candidate.frontage_side))
				var prefab_name = ""
				var footprint = Vector2i.ZERO
				var fitted = Vector2(INF, INF)
				for prefab_candidate in _get_prefab_candidates_for_parcel(catalog, district, rng):
					var trial_footprint = PrefabGeometry.get_rotated_surface_footprint(prefab_candidate, rot)
					var trial_fit = _fit_footprint_in_parcel(candidate, trial_footprint)
					if trial_fit.x == INF:
						continue
					prefab_name = prefab_candidate
					footprint = trial_footprint
					fitted = trial_fit
					break
				if prefab_name.is_empty():
					continue
				var bldg_x = fitted.x
				var bldg_z = fitted.y
				var support = _resolve_town_building_support(bldg_x, bldg_z, footprint, road_segments, height_bytes, water_bytes, forest_noise, max_h, half, bldg_stats)
				if support.is_empty():
					continue
				var bldg_y = float(support.resolved_y)
				if not _has_sufficient_excavation_cover(prefab_name, bldg_x, bldg_y, bldg_z, footprint, rot, height_bytes, max_h, half):
					bldg_stats.rejected_cover += 1
					continue

				var reservation_rect := _get_prefab_reservation_rect(prefab_name, rot, bldg_x, bldg_z)
				var overlaps = false
				var clearance_margin = max(3.0, max(float(footprint.x), float(footprint.y)) * 0.35)
				for occ in occupied:
					if _rects_overlap(reservation_rect.x, reservation_rect.z, reservation_rect.w, reservation_rect.d, occ.x, occ.z, occ.w, occ.d, clearance_margin):
						overlaps = true
						break
				if overlaps:
					continue

				var road_target: Vector2 = candidate.frontage_target

				occupied.append(reservation_rect)
				bldg_stats.placed += 1
				placed_in_town += 1
				_append_baked_building(buildings, terrain_modifications, path_segments, height_bytes, max_h, half, road_segments,
					prefab_name, bldg_x, bldg_y, bldg_z, footprint, rot, road_target,
					district, str(candidate.get("road_kind", "secondary")), support)

			if placed_in_town >= target:
				print("[WorldMapGen] Town at (%.0f,%.0f): %d/%d buildings placed" % [town.x, town.z, placed_in_town, target])
				continue

		print("[WorldMapGen] Town at (%.0f,%.0f): %d/%d buildings placed" % [town.x, town.z, placed_in_town, target])

func _place_town_landmarks(town: Dictionary, layout: Dictionary, catalog: Dictionary, road_segments: Array, path_segments: Array, height_bytes: PackedByteArray, water_bytes: PackedByteArray, max_h: float, half: int, buildings: Array, terrain_modifications: Array, bldg_stats: Dictionary, occupied: Array, rng: RandomNumberGenerator, desired_count: int = 2) -> int:
	if catalog.is_empty() or desired_count <= 0:
		return 0

	var center = Vector2(float(town.x), float(town.z))
	var central_limit = float(layout.get("ring_radius", town.radius)) * 0.72
	var core_slots = _get_civic_core_parcels(town, layout)
	var core_candidates: Array = []
	for i in range(core_slots.size()):
		var parcel: Dictionary = core_slots[i]
		var dist_to_center = Vector2(parcel.center).distance_to(center)
		var score = 24.0 - dist_to_center * 0.12
		score += 6.0 if str(parcel.get("road_kind", "")) == "main" else 0.0
		core_candidates.append({
			"idx": i,
			"parcel": parcel,
			"score": score
		})
	core_candidates.sort_custom(func(a, b): return a.score > b.score)

	var parcel_slots = _generate_town_building_slots(town, layout, road_segments, rng)
	var parcel_candidates: Array = []
	for i in range(parcel_slots.size()):
		var parcel: Dictionary = parcel_slots[i]
		var district = str(parcel.get("district", "residential"))
		if district != "civic" and district != "mainstreet":
			continue
		var dist_to_center = Vector2(parcel.center).distance_to(center)
		if dist_to_center > central_limit:
			continue
		var score = 10.0 - dist_to_center * 0.08
		if district == "civic":
			score += 4.0
		if str(parcel.get("road_kind", "")) == "main":
			score += 2.0
		parcel_candidates.append({
			"idx": i,
			"parcel": parcel,
			"score": score
		})
	parcel_candidates.sort_custom(func(a, b): return a.score > b.score)
	if parcel_candidates.is_empty():
		return 0

	var preferred_prefabs: Array = []
	for candidate in ["new_wooden_hall", "new_wooden_house_wide", "new_wooden_house_2floor", "wooden_house_2floor"]:
		if catalog.has(candidate) and not preferred_prefabs.has(candidate):
			preferred_prefabs.append(candidate)
	var remaining_prefabs: Array = []
	for pname in catalog:
		if preferred_prefabs.has(pname):
			continue
		remaining_prefabs.append(catalog[pname])
	remaining_prefabs.sort_custom(func(a, b): return int(a.area) > int(b.area))
	for entry in remaining_prefabs:
		if int(entry.area) >= 24:
			preferred_prefabs.append(str(entry.name))

	var used_prefabs: Dictionary = {}
	var placed = _place_landmarks_from_parcel_candidates(core_candidates, preferred_prefabs, road_segments, path_segments,
		height_bytes, water_bytes, max_h, half, buildings, terrain_modifications, bldg_stats, occupied, used_prefabs, desired_count)
	if placed < desired_count:
		placed += _place_landmarks_from_parcel_candidates(parcel_candidates, preferred_prefabs, road_segments, path_segments,
			height_bytes, water_bytes, max_h, half, buildings, terrain_modifications, bldg_stats, occupied, used_prefabs, desired_count - placed)
	if placed < desired_count:
		placed += _place_forced_core_landmarks(town, layout, preferred_prefabs, road_segments, path_segments, height_bytes, water_bytes, max_h, half, buildings, terrain_modifications, bldg_stats, occupied, desired_count - placed)

	return placed

func _build_prefab_catalog(available_prefabs: Array[String]) -> Dictionary:
	var catalog: Dictionary = {}
	for pname in available_prefabs:
		var validation := PrefabGeometry.get_prefab_validation(pname)
		if not bool(validation.get("valid_for_spawn", true)):
			print("[WorldMapGen] Skipping prefab '%s': %s" % [pname, "; ".join(validation.get("errors", []))])
			continue
		var fp = _get_prefab_footprint(pname)
		var reservation_fp = _get_prefab_reservation_footprint(pname)
		catalog[pname] = {
			"name": pname,
			"footprint": fp,
			"reservation_footprint": reservation_fp,
			"area": reservation_fp.x * reservation_fp.y,
			"surface_area": fp.x * fp.y
		}
	return catalog

func _pick_random_catalog_entry(pool: Array, rng: RandomNumberGenerator) -> String:
	if pool.is_empty():
		return ""
	var idx = rng.randi_range(0, pool.size() - 1)
	return str(pool[idx]["name"])

func _shuffled_catalog_names(pool: Array, rng: RandomNumberGenerator) -> Array:
	var copy: Array = pool.duplicate()
	for i in range(copy.size() - 1, 0, -1):
		var j = rng.randi_range(0, i)
		var tmp = copy[i]
		copy[i] = copy[j]
		copy[j] = tmp
	var names: Array = []
	for entry in copy:
		names.append(str(entry["name"]))
	return names

func _get_prefab_candidates_for_parcel(catalog: Dictionary, district: String, rng: RandomNumberGenerator) -> Array:
	if catalog.is_empty():
		return []

	var entries: Array = []
	for pname in catalog:
		entries.append(catalog[pname])
	entries.sort_custom(func(a, b): return a.area > b.area)

	var small_entries: Array = []
	var medium_entries: Array = []
	var large_entries: Array = []
	for entry in entries:
		var area = int(entry["area"])
		if area >= 80:
			large_entries.append(entry)
		elif area >= 24:
			medium_entries.append(entry)
		else:
			small_entries.append(entry)

	var ordered: Array = []
	match district:
		"civic", "core_landmark":
			ordered.append_array(_shuffled_catalog_names(large_entries, rng))
			ordered.append_array(_shuffled_catalog_names(medium_entries, rng))
		"mainstreet":
			ordered.append_array(_shuffled_catalog_names(large_entries, rng))
			ordered.append_array(_shuffled_catalog_names(medium_entries, rng))
		"edge":
			ordered.append_array(_shuffled_catalog_names(large_entries, rng))
			ordered.append_array(_shuffled_catalog_names(medium_entries, rng))
			ordered.append_array(_shuffled_catalog_names(small_entries, rng))
		_:
			ordered.append_array(_shuffled_catalog_names(large_entries, rng))
			ordered.append_array(_shuffled_catalog_names(medium_entries, rng))
			ordered.append_array(_shuffled_catalog_names(small_entries, rng))
	return ordered

func _choose_prefab_for_district(catalog: Dictionary, district: String, rng: RandomNumberGenerator) -> String:
	if catalog.is_empty():
		return ""

	var entries: Array = []
	for pname in catalog:
		entries.append(catalog[pname])
	entries.sort_custom(func(a, b): return a.area < b.area)

	var small_entries: Array = []
	var medium_entries: Array = []
	var large_entries: Array = []
	for entry in entries:
		var area = int(entry["area"])
		if area >= 80:
			large_entries.append(entry)
		elif area >= 24:
			medium_entries.append(entry)
		else:
			small_entries.append(entry)

	var roll = rng.randf()
	if district == "core" or district == "civic" or district == "core_landmark":
		if roll < 0.9:
			var pick = _pick_random_catalog_entry(large_entries, rng)
			if not pick.is_empty():
				return pick
		elif roll < 0.98:
			var pick = _pick_random_catalog_entry(medium_entries, rng)
			if not pick.is_empty():
				return pick
	elif district == "mainstreet":
		if roll < 0.88:
			var pick = _pick_random_catalog_entry(large_entries, rng)
			if not pick.is_empty():
				return pick
		elif roll < 0.98:
			var pick = _pick_random_catalog_entry(medium_entries, rng)
			if not pick.is_empty():
				return pick
	elif district == "edge":
		if roll < 0.75:
			var pick = _pick_random_catalog_entry(large_entries, rng)
			if not pick.is_empty():
				return pick
		elif roll < 0.95:
			var pick = _pick_random_catalog_entry(medium_entries, rng)
			if not pick.is_empty():
				return pick
	else:
		if roll < 0.82:
			var pick = _pick_random_catalog_entry(large_entries, rng)
			if not pick.is_empty():
				return pick
		elif roll < 0.96:
			var pick = _pick_random_catalog_entry(medium_entries, rng)
			if not pick.is_empty():
				return pick

	if not large_entries.is_empty():
		return _pick_random_catalog_entry(large_entries, rng)
	if not medium_entries.is_empty():
		return _pick_random_catalog_entry(medium_entries, rng)
	return _pick_random_catalog_entry(small_entries, rng)

func _choose_prefab_for_parcel(catalog: Dictionary, district: String, parcel_size: Vector2, rng: RandomNumberGenerator) -> String:
	if catalog.is_empty():
		return ""

	var parcel_padding = 2.0
	var usable_w = max(0.0, parcel_size.x - parcel_padding)
	var usable_d = max(0.0, parcel_size.y - parcel_padding)

	var fit_large: Array = []
	var fit_medium: Array = []
	var fit_small: Array = []
	for pname in catalog:
		var entry = catalog[pname]
		var fp: Vector2i = entry["footprint"]
		var fits = (
			(fp.x <= usable_w and fp.y <= usable_d) or
			(fp.y <= usable_w and fp.x <= usable_d)
		)
		if not fits:
			continue
		var area = int(entry["area"])
		if area >= 80:
			fit_large.append(entry)
		elif area >= 24:
			fit_medium.append(entry)
		else:
			fit_small.append(entry)

	if district == "civic" or district == "core_landmark":
		var civic_pick = _pick_random_catalog_entry(fit_large, rng)
		if not civic_pick.is_empty():
			return civic_pick
		return _pick_random_catalog_entry(fit_medium, rng)
	if district == "mainstreet":
		var main_pick = _pick_random_catalog_entry(fit_large, rng)
		if not main_pick.is_empty():
			return main_pick
		var main_medium = _pick_random_catalog_entry(fit_medium, rng)
		if not main_medium.is_empty():
			return main_medium
		return ""
	if district == "edge":
		var edge_roll = rng.randf()
		if edge_roll < 0.6:
			var edge_medium = _pick_random_catalog_entry(fit_medium, rng)
			if not edge_medium.is_empty():
				return edge_medium
		var edge_large = _pick_random_catalog_entry(fit_large, rng)
		if not edge_large.is_empty():
			return edge_large
		return _pick_random_catalog_entry(fit_small, rng)

	var roll = rng.randf()
	if roll < 0.82:
		var pick = _pick_random_catalog_entry(fit_large, rng)
		if not pick.is_empty():
			return pick
	if roll < 0.97:
		var medium_pick = _pick_random_catalog_entry(fit_medium, rng)
		if not medium_pick.is_empty():
			return medium_pick
	return _pick_random_catalog_entry(fit_small, rng)

func _dedupe_sorted_floats(values: Array, epsilon: float) -> Array:
	var result: Array = []
	var last_val = null
	for value in values:
		var f = float(value)
		if last_val == null or abs(f - float(last_val)) > epsilon:
			result.append(f)
			last_val = f
	return result

func _make_parcel_offsets(parcel_w: float, parcel_d: float) -> Array:
	var offsets: Array = [Vector2.ZERO]
	var min_span = min(parcel_w, parcel_d)
	if min_span >= 24.0:
		var x_step = max(4.0, parcel_w * 0.18)
		var z_step = max(4.0, parcel_d * 0.18)
		offsets.append(Vector2(-x_step, 0.0))
		offsets.append(Vector2(x_step, 0.0))
		offsets.append(Vector2(0.0, -z_step))
		offsets.append(Vector2(0.0, z_step))
	if min_span >= 36.0:
		var x_step_corner = max(4.0, parcel_w * 0.22)
		var z_step_corner = max(4.0, parcel_d * 0.22)
		offsets.append(Vector2(-x_step_corner, -z_step_corner))
		offsets.append(Vector2(-x_step_corner, z_step_corner))
		offsets.append(Vector2(x_step_corner, -z_step_corner))
		offsets.append(Vector2(x_step_corner, z_step_corner))
	return offsets

func _footprint_for_rotation(footprint: Vector2i, rotation: int) -> Vector2i:
	if rotation == 1 or rotation == 3:
		return Vector2i(footprint.y, footprint.x)
	return footprint

func _choose_rotation_toward_point(center: Vector2, target: Vector2, town: Dictionary) -> int:
	if target != Vector2.ZERO:
		var dx = target.x - center.x
		var dz = target.y - center.y
		if abs(dx) > abs(dz):
			return 3 if dx > 0.0 else 1
		return 2 if dz > 0.0 else 0
	var dx_fallback = center.x - town.x
	var dz_fallback = center.y - town.z
	if abs(dx_fallback) > abs(dz_fallback):
		return 3 if dx_fallback > 0.0 else 1
	return 0 if dz_fallback > 0.0 else 2

func _validate_town_building_spot(bldg_x: float, bldg_z: float, footprint: Vector2i, road_segments: Array, height_bytes: PackedByteArray, water_bytes: PackedByteArray, forest_noise: FastNoiseLite, max_h: float, half: int, bldg_stats: Dictionary) -> bool:
	return not _resolve_town_building_support(bldg_x, bldg_z, footprint, road_segments, height_bytes, water_bytes, forest_noise, max_h, half, bldg_stats).is_empty()

func _resolve_town_building_support(bldg_x: float, bldg_z: float, footprint: Vector2i, road_segments: Array,
		height_bytes: PackedByteArray, water_bytes: PackedByteArray, forest_noise: FastNoiseLite,
		max_h: float, half: int, bldg_stats: Dictionary) -> Dictionary:
	var px = int(bldg_x + half)
	var pz = int(bldg_z + half)
	if px < 2 or px >= MAP_SIZE - 2 or pz < 2 or pz >= MAP_SIZE - 2:
		bldg_stats.rejected_bounds += 1
		return {}
	
	var margin = 1
	var sample_min_x = clampi(int(bldg_x) - margin, 0, MAP_SIZE - 1)
	var sample_max_x = clampi(int(bldg_x + footprint.x) + margin, 0, MAP_SIZE - 1)
	var sample_min_z = clampi(int(bldg_z) - margin, 0, MAP_SIZE - 1)
	var sample_max_z = clampi(int(bldg_z + footprint.y) + margin, 0, MAP_SIZE - 1)
	
	var min_h_local = 999.0
	var max_h_local = -999.0
	for cz in range(sample_min_z, sample_max_z + 1, 2):
		for cx in range(sample_min_x, sample_max_x + 1, 2):
			var idx = cz * MAP_SIZE + cx
			if water_bytes[idx] > 128:
				bldg_stats.rejected_water += 1
				return {}
			var sh = clampf(float(height_bytes[idx]) / 255.0 * max_h, 1.0, 28.0)
			min_h_local = min(min_h_local, sh)
			max_h_local = max(max_h_local, sh)
	
	if _footprint_hits_road_segments(bldg_x, bldg_z, footprint, road_segments):
		bldg_stats.rejected_road += 1
		return {}
	
	if max_h_local - min_h_local > 5.0:
		bldg_stats.rejected_slope += 1
		return {}

	if forest_noise != null:
		for dx in range(0, footprint.x + 1, max(1, int(ceil(float(footprint.x) / 2.0)))):
			for dz in range(0, footprint.y + 1, max(1, int(ceil(float(footprint.y) / 2.0)))):
				if forest_noise.get_noise_2d(bldg_x + float(dx), bldg_z + float(dz)) >= 0.45:
					bldg_stats.rejected_forest += 1
					return {}

	var support = _resolve_building_support(bldg_x, bldg_z, footprint, height_bytes, max_h, half)
	if not bool(support.get("valid", false)):
		if float(support.get("max_float_gap", 0.0)) > building_support_max_float:
			bldg_stats.rejected_float += 1
		elif float(support.get("max_embed_depth", 0.0)) > building_support_max_embed:
			bldg_stats.rejected_embed += 1
		else:
			bldg_stats.rejected_slope += 1
		return {}

	return support

func _has_sufficient_excavation_cover(prefab_name: String, bldg_x: float, bldg_y: float, bldg_z: float, footprint: Vector2i,
		rotation: int, height_bytes: PackedByteArray, max_h: float, half: int) -> bool:
	var segments := PrefabGeometry.get_rotated_excavation_segments(prefab_name, rotation)
	if segments.is_empty():
		return true
	var spawn_origin := PrefabGeometry.get_spawn_origin_for_surface_min(
		prefab_name,
		Vector3(bldg_x, bldg_y, bldg_z),
		rotation
	)
	var min_x := int(floor(bldg_x))
	var min_z := int(floor(bldg_z))
	var max_x := min_x + footprint.x - 1
	var max_z := min_z + footprint.y - 1
	for segment in segments:
		var world_x := int(floor(spawn_origin.x)) + int(segment.get("x", 0))
		var world_z := int(floor(spawn_origin.z)) + int(segment.get("z", 0))
		if world_x >= min_x and world_x <= max_x and world_z >= min_z and world_z <= max_z:
			continue
		var excavation_top := spawn_origin.y + float(segment.get("max_y", -1)) + 1.0
		var terrain_top := _sample_world_height(float(world_x), float(world_z), height_bytes, max_h, half)
		if terrain_top < excavation_top + underground_cover_min:
			return false
	return true

func _sample_building_pad_height(bldg_x: float, bldg_z: float, footprint: Vector2i, height_bytes: PackedByteArray, max_h: float, half: int) -> float:
	var min_x = clampi(int(floor(bldg_x)) + half, 0, MAP_SIZE - 1)
	var min_z = clampi(int(floor(bldg_z)) + half, 0, MAP_SIZE - 1)
	var max_x = clampi(int(ceil(bldg_x + footprint.x - 1.0)) + half, 0, MAP_SIZE - 1)
	var max_z = clampi(int(ceil(bldg_z + footprint.y - 1.0)) + half, 0, MAP_SIZE - 1)
	var height_sum = 0.0
	var sample_count = 0
	for cz in range(min_z, max_z + 1, 2):
		for cx in range(min_x, max_x + 1, 2):
			var idx = cz * MAP_SIZE + cx
			height_sum += clampf(float(height_bytes[idx]) / 255.0 * max_h, 1.0, 28.0)
			sample_count += 1
	if sample_count <= 0:
		return 12.0
	return height_sum / float(sample_count)

func _resolve_building_support(bldg_x: float, bldg_z: float, footprint: Vector2i, height_bytes: PackedByteArray, max_h: float, half: int) -> Dictionary:
	var preferred_y = _sample_building_pad_height(bldg_x, bldg_z, footprint, height_bytes, max_h, half)
	return FoundationSupport.resolve_footprint_support(
		func(wx: float, wz: float) -> float:
			return _sample_support_height(wx, wz, height_bytes, max_h, half),
		Vector2(bldg_x, bldg_z),
		footprint,
		preferred_y,
		{
			"sample_stride": building_support_sample_stride,
			"edge_inset": 0.18,
			"max_samples_per_axis": 5,
			"search_radius": building_support_search_radius,
			"max_float_gap": building_support_max_float,
			"max_embed_depth": building_support_max_embed,
			"max_height_range": 5.0,
			"float_weight": 8.0,
			"embed_weight": 3.0,
			"float_peak_weight": 6.0,
			"embed_peak_weight": 4.0,
			"preferred_weight": 0.3,
			"balance_weight": 0.85
		}
	)

func _sample_support_height(wx: float, wz: float, height_bytes: PackedByteArray, max_h: float, half: int) -> float:
	var px = clampi(int(floor(wx)) + half, 0, MAP_SIZE - 1)
	var pz = clampi(int(floor(wz)) + half, 0, MAP_SIZE - 1)
	return clampf(float(height_bytes[pz * MAP_SIZE + px]) / 255.0 * max_h, 1.0, 28.0)

func _flatten_building_pad(height_bytes: PackedByteArray, bldg_x: float, bldg_z: float, footprint: Vector2i, bldg_y: float, max_h: float, half: int, support_info: Dictionary = {}, protected_columns: Dictionary = {}) -> void:
	var flat_h_byte = _encode_height_byte(bldg_y, max_h)
	var longest_side = max(float(footprint.x), float(footprint.y))
	var support_range = float(support_info.get("height_range", 0.0))
	var pad = max(6, int(ceil(longest_side * 0.5 + support_range * 1.25)))
	var base_world_x := int(floor(bldg_x))
	var base_world_z := int(floor(bldg_z))
	var width = footprint.x + pad * 2
	var depth = footprint.y + pad * 2
	for fz in range(-pad, depth - pad + 1):
		for fx in range(-pad, width - pad + 1):
			var fpx = clampi(int(bldg_x + half) + fx, 0, MAP_SIZE - 1)
			var fpz = clampi(int(bldg_z + half) + fz, 0, MAP_SIZE - 1)
			var world_col := Vector2i(base_world_x + fx, base_world_z + fz)
			var inside_surface := fx >= 0 and fx < footprint.x and fz >= 0 and fz < footprint.y
			if not inside_surface and protected_columns.has(world_col):
				continue
			var h_idx = fpz * MAP_SIZE + fpx
			var orig_h_byte = height_bytes[h_idx]
			var dx = max(0.0, max(0.0 - fx, fx - float(footprint.x)))
			var dz = max(0.0, max(0.0 - fz, fz - float(footprint.y)))
			var dist = sqrt(dx * dx + dz * dz)
			var inner_flat = 1.25 + min(1.5, support_range * 0.3)
			if dist <= inner_flat:
				height_bytes[h_idx] = flat_h_byte
			elif dist < float(pad):
				var blend_t = (dist - inner_flat) / max(0.001, float(pad) - inner_flat)
				var smooth_t = blend_t * blend_t * (3.0 - 2.0 * blend_t)
				height_bytes[h_idx] = int(lerp(float(flat_h_byte), float(orig_h_byte), smooth_t))

func _get_off_footprint_excavation_columns(prefab_name: String, spawn_origin: Vector3, rotation: int, bldg_x: float, bldg_z: float, footprint: Vector2i) -> Dictionary:
	var direct_columns: Dictionary = {}
	var min_x := int(floor(bldg_x))
	var min_z := int(floor(bldg_z))
	var max_x := min_x + footprint.x - 1
	var max_z := min_z + footprint.y - 1
	for segment in PrefabGeometry.get_rotated_excavation_segments(prefab_name, rotation):
		var world_x := int(floor(spawn_origin.x)) + int(segment.get("x", 0))
		var world_z := int(floor(spawn_origin.z)) + int(segment.get("z", 0))
		if world_x >= min_x and world_x <= max_x and world_z >= min_z and world_z <= max_z:
			continue
		direct_columns[Vector2i(world_x, world_z)] = true
	if direct_columns.is_empty():
		return {}
	var protected_columns: Dictionary = {}
	for col_var in direct_columns.keys():
		var col: Vector2i = col_var
		for dz in range(-underground_flatten_protection_margin, underground_flatten_protection_margin + 1):
			for dx in range(-underground_flatten_protection_margin, underground_flatten_protection_margin + 1):
				protected_columns[col + Vector2i(dx, dz)] = true
	return protected_columns

func _front_center_for_rotation(bldg_x: float, bldg_z: float, footprint: Vector2i, rotation: int) -> Vector2:
	match rotation:
		0:
			return Vector2(bldg_x + float(footprint.x) * 0.5, bldg_z)
		1:
			return Vector2(bldg_x + float(footprint.x), bldg_z + float(footprint.y) * 0.5)
		2:
			return Vector2(bldg_x + float(footprint.x) * 0.5, bldg_z + float(footprint.y))
		3:
			return Vector2(bldg_x, bldg_z + float(footprint.y) * 0.5)
	return Vector2(bldg_x + float(footprint.x) * 0.5, bldg_z + float(footprint.y) * 0.5)

func _footprint_hits_road_segments(bldg_x: float, bldg_z: float, footprint: Vector2i, road_segments: Array) -> bool:
	var rect_min = Vector2(bldg_x, bldg_z)
	var rect_max = Vector2(bldg_x + float(footprint.x), bldg_z + float(footprint.y))
	for seg in road_segments:
		var from_v: Vector2 = seg["from"]
		var to_v: Vector2 = seg["to"]
		var seg_width = float(seg.get("width", settlement_road_width))
		var clearance_radius = seg_width * 0.5 + ROAD_BLEND_MARGIN + 0.75
		if _distance_segment_to_rect(from_v, to_v, rect_min, rect_max) <= clearance_radius:
			return true
	return false

func _distance_point_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab = b - a
	var ab_len_sq = ab.length_squared()
	if ab_len_sq <= 0.000001:
		return point.distance_to(a)
	var t = clampf((point - a).dot(ab) / ab_len_sq, 0.0, 1.0)
	var closest = a + ab * t
	return point.distance_to(closest)

func _point_in_rect(point: Vector2, rect_min: Vector2, rect_max: Vector2) -> bool:
	return point.x >= rect_min.x and point.x <= rect_max.x and point.y >= rect_min.y and point.y <= rect_max.y

func _segments_intersect(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> bool:
	var d1 = (a2 - a1).cross(b1 - a1)
	var d2 = (a2 - a1).cross(b2 - a1)
	var d3 = (b2 - b1).cross(a1 - b1)
	var d4 = (b2 - b1).cross(a2 - b1)
	var eps = 0.0001
	if abs(d1) < eps and abs(d2) < eps and abs(d3) < eps and abs(d4) < eps:
		# Collinear overlap
		var a_min_x = min(a1.x, a2.x)
		var a_max_x = max(a1.x, a2.x)
		var a_min_y = min(a1.y, a2.y)
		var a_max_y = max(a1.y, a2.y)
		var b_min_x = min(b1.x, b2.x)
		var b_max_x = max(b1.x, b2.x)
		var b_min_y = min(b1.y, b2.y)
		var b_max_y = max(b1.y, b2.y)
		return not (a_max_x < b_min_x or b_max_x < a_min_x or a_max_y < b_min_y or b_max_y < a_min_y)
	return (d1 * d2 <= 0.0) and (d3 * d4 <= 0.0)

func _distance_segment_to_segment(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> float:
	if _segments_intersect(a1, a2, b1, b2):
		return 0.0
	return min(
		min(_distance_point_to_segment(a1, b1, b2), _distance_point_to_segment(a2, b1, b2)),
		min(_distance_point_to_segment(b1, a1, a2), _distance_point_to_segment(b2, a1, a2))
	)

func _distance_segment_to_rect(a: Vector2, b: Vector2, rect_min: Vector2, rect_max: Vector2) -> float:
	if _point_in_rect(a, rect_min, rect_max) or _point_in_rect(b, rect_min, rect_max):
		return 0.0
	var c1 = Vector2(rect_min.x, rect_min.y)
	var c2 = Vector2(rect_max.x, rect_min.y)
	var c3 = Vector2(rect_max.x, rect_max.y)
	var c4 = Vector2(rect_min.x, rect_max.y)
	var dist = INF
	dist = min(dist, _distance_segment_to_segment(a, b, c1, c2))
	dist = min(dist, _distance_segment_to_segment(a, b, c2, c3))
	dist = min(dist, _distance_segment_to_segment(a, b, c3, c4))
	dist = min(dist, _distance_segment_to_segment(a, b, c4, c1))
	return dist

func _find_best_road_connection(probe: Vector2, road_segments: Array, preferred_kind: String = "") -> Dictionary:
	var best: Dictionary = {}
	var best_score = INF
	for seg in road_segments:
		var from_v: Vector2 = seg["from"]
		var to_v: Vector2 = seg["to"]
		var point = _closest_point_on_segment(probe, from_v, to_v)
		var dist = point.distance_to(probe)
		var width = float(seg.get("width", settlement_road_width))
		var kind = str(seg.get("kind", "secondary"))
		var score = dist
		if not preferred_kind.is_empty() and kind != preferred_kind:
			score += 3.0
		if kind == "gateway" or kind == "arterial":
			score += 1.0
		if score < best_score:
			best_score = score
			best = {
				"point": point,
				"width": width,
				"kind": kind,
				"distance": dist
			}
	return best

func _closest_point_on_segment(point: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab = b - a
	var ab_len_sq = ab.length_squared()
	if ab_len_sq <= 0.000001:
		return a
	var t = clampf((point - a).dot(ab) / ab_len_sq, 0.0, 1.0)
	return a + ab * t

# ============================================================================
# WILDERNESS BUILDINGS + ACCESS PATHS
# ============================================================================

func _generate_wilderness_buildings(towns: Array, road_segments: Array,
		height_bytes: PackedByteArray, water_bytes: PackedByteArray,
		biome_bytes: PackedByteArray, road_bytes: PackedByteArray,
		max_h: float, half: int, buildings: Array, terrain_modifications: Array, bldg_stats: Dictionary) -> void:
	
	var rng = RandomNumberGenerator.new()
	rng.seed = world_seed + 700
	var forest_noise = FastNoiseLite.new()
	forest_noise.noise_type = FastNoiseLite.TYPE_VALUE
	forest_noise.seed = world_seed + 100
	forest_noise.frequency = 0.02
	var available_prefabs = _get_available_prefabs()
	
	# Scan grid at spacing intervals for candidate wilderness building spots
	var spacing = 200.0  # Check every 200m
	var wilderness_count = 0
	
	var wx = float(-half)
	while wx < float(half):
		var wz = float(-half)
		while wz < float(half):
			bldg_stats.attempted += 1
			
			# Deterministic chance
			var key = "%d_%d" % [int(wx / spacing), int(wz / spacing)]
			var cell_rng = RandomNumberGenerator.new()
			cell_rng.seed = hash(key) + world_seed + 800
			
			if cell_rng.randf() > wilderness_building_chance:
				bldg_stats.rejected_chance += 1
				wz += spacing
				continue
			
			# Slight random offset within the cell
			var sx = wx + cell_rng.randf_range(-spacing * 0.3, spacing * 0.3)
			var sz = wz + cell_rng.randf_range(-spacing * 0.3, spacing * 0.3)
			
			# Skip if inside a town
			var in_town = false
			for town in towns:
				if Vector2(sx, sz).distance_to(Vector2(town.x, town.z)) < town.radius + 50.0:
					in_town = true
					break
			if in_town:
				wz += spacing
				continue

			var prefab_name = available_prefabs[cell_rng.randi() % available_prefabs.size()]
			var footprint = PrefabGeometry.get_rotated_surface_footprint(prefab_name, 0)
			var support = _resolve_town_building_support(sx, sz, footprint, road_segments, height_bytes, water_bytes, forest_noise, max_h, half, bldg_stats)
			if support.is_empty():
				wz += spacing
				continue

			var px = int(sx + half)
			var pz = int(sz + half)
			var bidx = pz * MAP_SIZE + px
			var terrain_y = float(support.get("resolved_y", clampf(float(height_bytes[bidx]) / 255.0 * max_h, 1.0, 28.0)))
			if not _has_sufficient_excavation_cover(prefab_name, sx, terrain_y, sz, footprint, 0, height_bytes, max_h, half):
				bldg_stats.rejected_cover += 1
				wz += spacing
				continue
			var nearest_road_pt = _find_nearest_road_point(sx, sz, road_segments)
			if nearest_road_pt != Vector2.ZERO:
				var path_seg = [{"from": Vector2(sx, sz), "to": nearest_road_pt}]
				_rasterize_roads(path_seg, height_bytes, biome_bytes, road_bytes, max_h, half, access_path_width)
			
			var road_y = _get_road_height_at(sx, sz)
			var spawn_origin = PrefabGeometry.get_spawn_origin_for_surface_min(
				prefab_name,
				Vector3(sx, floor(terrain_y), sz),
				0
			)
			_append_baked_excavation_modifications(terrain_modifications, prefab_name, spawn_origin, 0)
			bldg_stats.placed += 1
			wilderness_count += 1
			buildings.append({
				"x": sx, "y": floor(terrain_y), "z": sz,
				"anchor_mode": "occupied_min",
				"spawn_origin_x": spawn_origin.x,
				"spawn_origin_y": spawn_origin.y,
				"spawn_origin_z": spawn_origin.z,
				"footprint_w": footprint.x,
				"footprint_d": footprint.y,
				"road_y": floor(road_y),
				"type": prefab_name,
				"wilderness": true
			})
			
			wz += spacing
		wx += spacing
	
	print("[WorldMapGen] Wilderness buildings: %d placed" % wilderness_count)

func _find_nearest_road_point(wx: float, wz: float, road_segments: Array) -> Vector2:
	var point = Vector2(wx, wz)
	var best_point = Vector2.ZERO
	var best_dist = INF
	for seg in road_segments:
		var from_v: Vector2 = seg["from"]
		var to_v: Vector2 = seg["to"]
		var closest = _closest_point_on_segment(point, from_v, to_v)
		var dist = point.distance_to(closest)
		if dist < best_dist:
			best_dist = dist
			best_point = closest
	return best_point

# ============================================================================
# VALIDATION HELPERS
# ============================================================================

func _validate_building_spot(sx: float, sz: float, height_bytes: PackedByteArray,
		water_bytes: PackedByteArray, forest_noise: FastNoiseLite,
		max_h: float, half: int, bldg_stats: Dictionary) -> bool:
	var px = int(sx + half)
	var pz = int(sz + half)
	if px < 2 or px >= MAP_SIZE - 2 or pz < 2 or pz >= MAP_SIZE - 2:
		bldg_stats.rejected_bounds += 1
		return false
	var bidx = pz * MAP_SIZE + px
	
	if water_bytes[bidx] > 128:
		bldg_stats.rejected_water += 1
		return false
	
	var terrain_y = clampf(float(height_bytes[bidx]) / 255.0 * max_h, 1.0, 28.0)
	if terrain_y < 3.0 or terrain_y > 26.0:
		bldg_stats.rejected_height += 1
		return false
	
	# Slope check (7x7 footprint)
	var min_h_local = terrain_y
	var max_h_local = terrain_y
	var total = MAP_SIZE * MAP_SIZE
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			var si = (pz + dz) * MAP_SIZE + (px + dx)
			if si >= 0 and si < total:
				var sh = clampf(float(height_bytes[si]) / 255.0 * max_h, 1.0, 28.0)
				min_h_local = min(min_h_local, sh)
				max_h_local = max(max_h_local, sh)
	if max_h_local - min_h_local > 2.5:
		bldg_stats.rejected_slope += 1
		return false
	
	# Forest check
	var is_forested = false
	for dx in range(-2, 5, 2):
		for dz in range(-2, 5, 2):
			if forest_noise.get_noise_2d(sx + dx, sz + dz) >= 0.4:
				is_forested = true
				break
		if is_forested:
			break
	if is_forested:
		bldg_stats.rejected_forest += 1
		return false
	
	return true

# ============================================================================
# LAKES
# ============================================================================

func _generate_lakes(water_bytes: PackedByteArray, road_bytes: PackedByteArray,
		height_bytes: PackedByteArray, half: int, max_h: float) -> void:
	# Keep the shore off the road shoulder, but do not leave a huge dry corridor.
	var water_road_buffer = road_width * 0.5 + ROAD_BLEND_MARGIN
	var lake_cutoff = lake_threshold - 0.05
	var shore_submerge = 1.25
	var basin_depth_max = clampf(terrain_height * 0.65, 2.5, 8.0)
	for z in MAP_SIZE:
		var wz = float(z - half)
		var row_offset = z * MAP_SIZE
		for x in MAP_SIZE:
			var wx = float(x - half)
			var idx = row_offset + x
			
			# Skip only true road cores. Access paths use a lower mask value and should not
			# push the shoreline back by themselves.
			var ridx = idx * 2
			if road_bytes[ridx] >= LAKE_ROAD_BLOCK_THRESHOLD:
				continue
			# Also skip if there are road pixels nearby (simple check)
			var near_road = false
			for dr in range(-int(water_road_buffer), int(water_road_buffer) + 1, 4):
				var check_x = x + dr
				var check_z = z
				if check_x >= 0 and check_x < MAP_SIZE:
					var check_ridx = (check_z * MAP_SIZE + check_x) * 2
					if road_bytes[check_ridx] >= LAKE_ROAD_BLOCK_THRESHOLD:
						near_road = true
						break
				check_x = x
				check_z = z + dr
				if check_z >= 0 and check_z < MAP_SIZE:
					var check_ridx = (check_z * MAP_SIZE + check_x) * 2
					if road_bytes[check_ridx] >= LAKE_ROAD_BLOCK_THRESHOLD:
						near_road = true
						break
			if near_road:
				continue
			
			var lake_val = _lake_noise.get_noise_2d(wx, wz)
			if lake_val <= lake_cutoff:
				continue

			water_bytes[idx] = 255
			if not deep_lakes_enabled:
				continue

			var depth_t = clampf((lake_val - lake_cutoff) / maxf(0.001, 1.0 - lake_cutoff), 0.0, 1.0)
			depth_t = depth_t * depth_t * (3.0 - 2.0 * depth_t)
			var current_h = float(height_bytes[idx]) / 255.0 * max_h
			var target_h = water_level - shore_submerge - basin_depth_max * depth_t
			if current_h > target_h:
				height_bytes[idx] = _encode_height_byte(target_h, max_h)

# ============================================================================
# LEGACY GRID ROADS (fallback)
# ============================================================================

func _generate_grid_roads(height_bytes: PackedByteArray, biome_bytes: PackedByteArray,
		road_bytes: PackedByteArray, max_h: float, half: int) -> void:
	if progress_callback.is_valid():
		progress_callback.call(30.0, "Generating grid roads")
	
	var half_road_w = road_width * 0.5
	var flatten_width = (road_width + 25.0) if wide_shoulders else road_width
	var flat_zone_end = (road_width * 0.5 + 15.0) if wide_shoulders else half_road_w
	
	for z in MAP_SIZE:
		if z % 256 == 0 and progress_callback.is_valid():
			progress_callback.call(30.0 + float(z) / MAP_SIZE * 40.0, "Grid roads")
		var wz = float(z - half)
		var row_offset = z * MAP_SIZE
		for x in MAP_SIZE:
			var wx = float(x - half)
			var idx = row_offset + x
			var ridx = idx * 2
			var is_road_byte: int = 0
			var road_h_byte: int = 0
			
			if road_spacing > 0.0:
				var local_x = fmod(wx, road_spacing)
				var local_z = fmod(wz, road_spacing)
				if local_x < 0: local_x += road_spacing
				if local_z < 0: local_z += road_spacing
				var dist_x = minf(local_x, road_spacing - local_x)
				var dist_z = minf(local_z, road_spacing - local_z)
				var min_dist = minf(dist_x, dist_z)
				
				if min_dist < flatten_width:
					var cell_x = floor(wx / road_spacing)
					var cell_z = floor(wz / road_spacing)
					var h1 = _road_height_noise.get_noise_2d(cell_x * road_spacing, cell_z * road_spacing) * 3.0 + 12.0
					var h2 = _road_height_noise.get_noise_2d((cell_x + 1) * road_spacing, cell_z * road_spacing) * 3.0 + 12.0
					var h3 = _road_height_noise.get_noise_2d(cell_x * road_spacing, (cell_z + 1) * road_spacing) * 3.0 + 12.0
					var h4 = _road_height_noise.get_noise_2d((cell_x + 1) * road_spacing, (cell_z + 1) * road_spacing) * 3.0 + 12.0
					var tx = local_x / road_spacing
					var tz = local_z / road_spacing
					var interp_h = lerp(lerp(h1, h2, tx), lerp(h3, h4, tx), tz)
					var base_level = floor(interp_h)
					var frac_val = interp_h - base_level
					var r_height: float
					if frac_val < 0.45:
						r_height = base_level
					elif frac_val > 0.55:
						r_height = base_level + 1.0
					else:
						var ramp_t = (frac_val - 0.45) / 0.1
						ramp_t = ramp_t * ramp_t * (3.0 - 2.0 * ramp_t)
						r_height = base_level + ramp_t
					
					road_h_byte = int(clampf(r_height / 64.0, 0.0, 1.0) * 255.0)
					
					if min_dist < half_road_w:
						is_road_byte = 255
						biome_bytes[idx] = MaterialID.ROAD
						height_bytes[idx] = _encode_height_byte(r_height, max_h)
					else:
						var t = clampf((min_dist - flat_zone_end) / (flatten_width - flat_zone_end), 0.0, 1.0)
						var blend = 1.0 - t
						var orig_h = float(height_bytes[idx]) / 255.0 * max_h
						var blended = lerp(orig_h, r_height, blend)
						height_bytes[idx] = _encode_height_byte(blended, max_h)
			
			road_bytes[ridx] = is_road_byte
			road_bytes[ridx + 1] = road_h_byte

func _generate_grid_buildings(height_bytes: PackedByteArray, water_bytes: PackedByteArray,
		biome_bytes: PackedByteArray, road_bytes: PackedByteArray,
		max_h: float, half: int, buildings: Array, terrain_modifications: Array, bldg_stats: Dictionary) -> void:
	if progress_callback.is_valid():
		progress_callback.call(70.0, "Placing buildings (grid)")
	
	var forest_noise = FastNoiseLite.new()
	forest_noise.noise_type = FastNoiseLite.TYPE_VALUE
	forest_noise.seed = world_seed + 100
	forest_noise.frequency = 0.02
	var available_prefabs = _get_available_prefabs()
	
	if road_spacing > 0.0:
		var grid_min = int(-half / road_spacing) - 1
		var grid_max = int(half / road_spacing) + 1
		
		for cx in range(grid_min, grid_max + 1):
			for cz in range(grid_min, grid_max + 1):
				var key = "%d_%d" % [cx, cz]
				var rng = RandomNumberGenerator.new()
				rng.seed = hash(key) + 42
				
				bldg_stats.attempted += 1
				
				if rng.randf() > building_spawn_chance:
					bldg_stats.rejected_chance += 1
					continue
				
				var side = 1.0 if rng.randf() > 0.5 else -1.0
				var spawn_x = cx * road_spacing + spawn_distance_from_road * side
				var spawn_z = cz * road_spacing + spawn_distance_from_road
				
				if not _validate_building_spot(spawn_x, spawn_z, height_bytes, water_bytes, forest_noise, max_h, half, bldg_stats):
					continue
				
				var px = int(spawn_x + half)
				var pz = int(spawn_z + half)
				var bidx = pz * MAP_SIZE + px
				var terrain_y = clampf(float(height_bytes[bidx]) / 255.0 * max_h, 1.0, 28.0)
				
				# Road height at intersection
				var road_cell_x = cx * road_spacing
				var road_cell_z = cz * road_spacing
				var road_y = _get_road_height_at(road_cell_x, road_cell_z)
				
				var prefab_name = available_prefabs[rng.randi() % available_prefabs.size()]
				var footprint = PrefabGeometry.get_rotated_surface_footprint(prefab_name, 0)
				var spawn_origin = PrefabGeometry.get_spawn_origin_for_surface_min(
					prefab_name,
					Vector3(spawn_x, floor(terrain_y), spawn_z),
					0
				)
				_append_baked_excavation_modifications(terrain_modifications, prefab_name, spawn_origin, 0)
				bldg_stats.placed += 1
				buildings.append({
					"x": spawn_x, "y": floor(terrain_y), "z": spawn_z,
					"anchor_mode": "occupied_min",
					"spawn_origin_x": spawn_origin.x,
					"spawn_origin_y": spawn_origin.y,
					"spawn_origin_z": spawn_origin.z,
					"footprint_w": footprint.x,
					"footprint_d": footprint.y,
					"road_y": floor(road_y),
					"type": prefab_name
				})

# ============================================================================
# SAVE / LOAD
# ============================================================================

func save_world(path: String, images: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(path)
	for key in images:
		if images[key] is Image:
			var err = (images[key] as Image).save_png(path.path_join(key + ".png"))
			if err != OK:
				push_error("[WorldMapGen] Failed to save %s" % key)
				return false
	
	var meta = {
		"version": 7, "map_size": MAP_SIZE,
		"noise_freq": noise_freq, "terrain_height": terrain_height,
		"water_level": water_level,
		"road_spacing": road_spacing, "road_width": road_width,
		"world_seed": world_seed, "use_grid_roads": use_grid_roads,
		"deep_lakes_enabled": deep_lakes_enabled,
		"building_placement_schema": "occupied_min_v1",
		"created": Time.get_datetime_string_from_system()
	}
	if images.has("buildings"):
		meta["buildings"] = images.buildings
	if images.has("towns"):
		meta["towns"] = images.towns
	if images.has("terrain_modifications"):
		meta["terrain_modifications"] = images.terrain_modifications
	
	var file = FileAccess.open(path.path_join("world_meta.json"), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(meta, "\t"))
		file.close()
	print("[WorldMapGen] Saved to: %s" % path)
	return true

func _get_available_prefabs() -> Array[String]:
	var prefabs: Array[String] = []
	var seen: Dictionary = {}
	for dir_path in ["res://world_prefabs/", "user://world_prefabs/"]:
		if DirAccess.dir_exists_absolute(dir_path):
			var dir = DirAccess.open(dir_path)
			if dir:
				dir.list_dir_begin()
				var file_name = dir.get_next()
				while file_name != "":
					if file_name.ends_with(".json"):
						var prefab_name = file_name.replace(".json", "")
						if not seen.has(prefab_name):
							seen[prefab_name] = true
							prefabs.append(prefab_name)
					file_name = dir.get_next()
				dir.list_dir_end()
	
	if not "small_house" in prefabs:
		prefabs.append("small_house")
	if not "new_wooden_house_2floor" in prefabs:
		prefabs.append("new_wooden_house_2floor")
	prefabs.sort()
	return prefabs

static func load_world(path: String) -> Dictionary:
	var result = {}
	var expected_formats = {
		"heightmap": Image.FORMAT_R8,
		"biomes": Image.FORMAT_R8,
		"roads": Image.FORMAT_RG8,
		"water": Image.FORMAT_R8,
		"building_map": Image.FORMAT_R8
	}
	for img_name in ["heightmap", "biomes", "roads", "water", "building_map"]:
		var fp = path.path_join(img_name + ".png")
		if not FileAccess.file_exists(fp) and img_name == "water":
			fp = path.path_join("structures.png")
		if FileAccess.file_exists(fp):
			var img = Image.load_from_file(fp)
			if img:
				if img.get_format() != expected_formats[img_name]:
					img.convert(expected_formats[img_name])
				result[img_name] = img
	var mp = path.path_join("world_meta.json")
	if FileAccess.file_exists(mp):
		var f = FileAccess.open(mp, FileAccess.READ)
		if f:
			var j = JSON.new(); j.parse(f.get_as_text())
			var meta = j.get_data()
			result["metadata"] = meta
			if meta.has("buildings"):
				result["buildings"] = meta.buildings
			if meta.has("towns"):
				result["towns"] = meta.towns
			if meta.has("terrain_modifications"):
				result["terrain_modifications"] = meta.terrain_modifications
			f.close()
	return result
