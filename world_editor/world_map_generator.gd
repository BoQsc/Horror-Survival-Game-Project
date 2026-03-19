extends RefCounted
class_name WorldMapGenerator
## WorldMapGenerator - World definition PNG generation
## Supports two modes:
##  - TOWN mode (default): Towns connected by MST roads, wilderness buildings with access paths
##  - GRID mode (legacy toggle): Roads at fixed intervals with buildings at intersections

const MAP_SIZE: int = 2048  # 1 pixel = 1 meter

# CONSTRAINT: max decoded height = 2 * terrain_height must be < CHUNK_SIZE (32)
var noise_freq: float = 0.1
var terrain_height: float = 10.0
var road_spacing: float = 100.0  # Used for GRID mode fallback
var road_width: float = 8.0
var wide_shoulders: bool = false
var world_seed: int = 12345
var lake_threshold: float = 0.35
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
const ROAD_BLEND_MARGIN: float = 4.0

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
			height_bytes[idx] = int(clampf(h / max_h, 0.0, 1.0) * 255.0)
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
	var bldg_stats = {
		"attempted": 0, "placed": 0,
		"rejected_chance": 0, "rejected_bounds": 0, "rejected_water": 0,
		"rejected_slope": 0, "rejected_forest": 0, "rejected_height": 0,
		"rejected_road": 0
	}
	
	if use_grid_roads:
		# LEGACY GRID MODE
		_generate_grid_roads(height_bytes, biome_bytes, road_bytes, max_h, half)
		_generate_grid_buildings(height_bytes, water_bytes, biome_bytes, road_bytes, max_h, half, buildings, bldg_stats)
	else:
		# TOWN MODE
		if progress_callback.is_valid():
			progress_callback.call(30.0, "Placing towns")
		towns = _place_towns(height_bytes, water_bytes, max_h, half)
		
		if progress_callback.is_valid():
			progress_callback.call(40.0, "Building road network")
		road_segments = _build_settlement_roads(towns)
		_rasterize_roads(road_segments, height_bytes, biome_bytes, road_bytes, max_h, half, road_width)
		
		if progress_callback.is_valid():
			progress_callback.call(55.0, "Placing buildings in towns")
		_generate_town_buildings(towns, road_segments, height_bytes, water_bytes, road_bytes, max_h, half, buildings, bldg_stats)
	
	# PASS: Lakes
	if progress_callback.is_valid():
		progress_callback.call(80.0, "Generating lakes")
	_generate_lakes(water_bytes, road_bytes, height_bytes, half)
	
	# PASS: Building footprint map
	if progress_callback.is_valid():
		progress_callback.call(95.0, "Finalizing")
	var building_bytes = PackedByteArray()
	building_bytes.resize(total)
	building_bytes.fill(0)
	for bldg in buildings:
		var px = int(float(bldg.x) + half)
		var pz = int(float(bldg.z) + half)
		var footprint = _get_prefab_footprint(str(bldg.get("type", "small_house")))
		var rot = int(bldg.get("rotation", 0))
		if rot == 1 or rot == 3:
			footprint = Vector2i(footprint.y, footprint.x)
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
		"buildings": buildings, "building_stats": bldg_stats, "towns": towns
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
	
	var biome_bias = 0.0
	var biome_val = _biome_noise.get_noise_2d(wx, wz)
	if biome_val > 0.1 and biome_val < 0.5:
		biome_bias = 0.12
	elif biome_val < -0.2:
		biome_bias = -0.08
	elif biome_val > 0.6:
		biome_bias = -0.1
	
	var score = elevation_score * 0.46 + (1.0 - slope_penalty) * 0.42 + biome_bias
	score -= water_penalty * 0.7
	score += rng_from_site(wx, wz) * 0.06
	return clampf(score, 0.0, 1.0)

func rng_from_site(wx: float, wz: float) -> float:
	var seed_value = int(abs(wx) * 37.0 + abs(wz) * 91.0) ^ world_seed
	seed_value = (seed_value * 1103515245 + 12345) & 0x7fffffff
	return float(seed_value % 1000) / 1000.0

# ============================================================================
# MST ROAD NETWORK
# ============================================================================

func _build_mst_roads(towns: Array) -> Array:
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
			result.append({
				"from": Vector2(towns[edge.i].x, towns[edge.i].z),
				"to": Vector2(towns[edge.j].x, towns[edge.j].z)
			})
			if result.size() >= towns.size() - 1:
				break
	
	# Add 1-2 extra edges for variety (loops)
	var rng = RandomNumberGenerator.new()
	rng.seed = world_seed + 600
	var extra_count = mini(2, edges.size() - result.size())
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

func _build_settlement_roads(towns: Array) -> Array:
	var roads: Array = []
	roads.append_array(_build_mst_roads(towns))
	for town in towns:
		roads.append_array(_generate_town_internal_roads(town))
	return roads

func _uf_find(parent: Array, x: int) -> int:
	while parent[x] != x:
		parent[x] = parent[parent[x]]  # Path compression
		x = parent[x]
	return x

func _get_town_layout(town: Dictionary) -> Dictionary:
	var rng = RandomNumberGenerator.new()
	rng.seed = hash("%d_%d_layout" % [int(town.x), int(town.z)]) + world_seed + 900
	var spacing = clampf(town.radius / 2.8, 30.0, 44.0)
	var jitter = spacing * 0.08
	var origin_x = town.x - town.radius + spacing * 0.5 + rng.randf_range(-jitter, jitter)
	var origin_z = town.z - town.radius + spacing * 0.5 + rng.randf_range(-jitter, jitter)
	var plaza_half = max(14.0, town.radius * 0.20)
	var ring_radius = max(plaza_half + spacing * 0.95, town.radius * 0.58)
	return {
		"spacing": spacing,
		"origin_x": origin_x,
		"origin_z": origin_z,
		"plaza_half": plaza_half,
		"ring_radius": ring_radius,
		"road_bands": [0.0]
	}

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

func _generate_town_internal_roads(town: Dictionary) -> Array:
	var layout = _get_town_layout(town)
	var cx = town.x
	var cz = town.z
	var r = town.radius
	var roads: Array = []
	var plaza_half = layout.plaza_half
	var ring_radius = layout.ring_radius
	
	for offset in layout.road_bands:
		var band_offset = float(offset)
		var x = cx + band_offset
		if abs(band_offset) <= r:
			var x_span = sqrt(max(0.0, r * r - band_offset * band_offset))
			if x_span > plaza_half:
				roads.append({"from": Vector2(x, cz - x_span), "to": Vector2(x, cz + x_span), "width": settlement_road_width})
		var z = cz + band_offset
		if abs(band_offset) <= r:
			var z_span = sqrt(max(0.0, r * r - band_offset * band_offset))
			if z_span > plaza_half:
				roads.append({"from": Vector2(cx - z_span, z), "to": Vector2(cx + z_span, z), "width": settlement_road_width})
	
	roads.append_array(_make_square_ring(Vector2(cx, cz), ring_radius))
	return roads

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
					var h_byte = int(clampf(r_height / max_h, 0.0, 1.0) * 255.0)
					road_bytes[ridx] = 255
					road_bytes[ridx + 1] = r_height_byte
					biome_bytes[idx] = MaterialID.ROAD
					height_bytes[idx] = h_byte
				else:
					# Blend zone — smooth lerp from road height to terrain height
					var blend_t = clampf((dist - half_w_local) / (flatten_local - half_w_local), 0.0, 1.0)
					var orig_h = float(height_bytes[idx]) / 255.0 * max_h
					var blended = lerp(r_height, orig_h, blend_t)
					height_bytes[idx] = int(clampf(blended / max_h, 0.0, 1.0) * 255.0)

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
	# Try to read from JSON prefab files
	for dir_path in ["res://world_prefabs/", "user://world_prefabs/"]:
		var fp = dir_path + prefab_name + ".json"
		if FileAccess.file_exists(fp):
			var file = FileAccess.open(fp, FileAccess.READ)
			if file:
				var json = JSON.new()
				if json.parse(file.get_as_text()) == OK:
					var data = json.get_data()
					if data.has("size"):
						var s = data["size"]
						return Vector2i(int(s[0]), int(s[2]))  # Width (X), Depth (Z)
				file.close()
	# Fallback: small_house = ~3x3, generic = 10x12
	if prefab_name == "small_house":
		return Vector2i(3, 3)
	return Vector2i(10, 12)

## Check if two axis-aligned rectangles overlap (with margin)
func _rects_overlap(ax: float, az: float, aw: float, ad: float,
		bx: float, bz: float, bw: float, bd: float, margin: float) -> bool:
	return not (ax + aw + margin <= bx or bx + bw + margin <= ax or
				az + ad + margin <= bz or bz + bd + margin <= az)

func _generate_town_building_slots(town: Dictionary, layout: Dictionary, road_segments: Array, rng: RandomNumberGenerator) -> Array:
	var slots: Array = []
	var town_center = Vector2(town.x, town.z)
	var outer_ring = layout.ring_radius
	var bounds = [
		-town.radius,
		-outer_ring,
		0.0,
		outer_ring,
		town.radius,
	]

	var line_values: Array = []
	for rel in bounds:
		var world_val = town_center.x + rel
		if world_val < town_center.x - town.radius or world_val > town_center.x + town.radius:
			continue
		line_values.append(world_val)
	line_values.sort()
	line_values = _dedupe_sorted_floats(line_values, 0.5)

	var z_values: Array = []
	for rel in bounds:
		var world_val = town_center.y + rel
		if world_val < town_center.y - town.radius or world_val > town_center.y + town.radius:
			continue
		z_values.append(world_val)
	z_values.sort()
	z_values = _dedupe_sorted_floats(z_values, 0.5)

	for xi in range(line_values.size() - 1):
		var x0 = float(line_values[xi])
		var x1 = float(line_values[xi + 1])
		var parcel_w = x1 - x0
		if parcel_w < layout.spacing * 0.35:
			continue
		for zi in range(z_values.size() - 1):
			var z0 = float(z_values[zi])
			var z1 = float(z_values[zi + 1])
			var parcel_d = z1 - z0
			if parcel_d < layout.spacing * 0.35:
				continue

			var center = Vector2((x0 + x1) * 0.5, (z0 + z1) * 0.5)
			var dist_to_center = center.distance_to(town_center)
			if dist_to_center <= layout.plaza_half * 1.05:
				continue
			if dist_to_center > town.radius + 1.0:
				continue

			var district = "residential"
			if dist_to_center <= town.radius * 0.42:
				district = "core"
			elif dist_to_center >= town.radius * 0.76:
				district = "edge"

			var area = parcel_w * parcel_d
			var score = area / max(1.0, town.radius * town.radius)
			if district == "core":
				score += 0.26
			elif district == "edge":
				score += 0.08
			score += rng.randf_range(-0.03, 0.03)
			slots.append({
				"center": center,
				"size": Vector2(parcel_w, parcel_d),
				"district": district,
				"score": score
			})
			for offset in _make_parcel_offsets(parcel_w, parcel_d):
				if offset == Vector2.ZERO:
					continue
				slots.append({
					"center": center + offset,
					"size": Vector2(parcel_w, parcel_d),
					"district": district,
					"score": score - 0.04
				})

	slots.sort_custom(func(a, b): return a.score > b.score)
	return slots

func _generate_town_buildings(towns: Array, road_segments: Array, height_bytes: PackedByteArray,
		water_bytes: PackedByteArray, road_bytes: PackedByteArray,
		max_h: float, half: int, buildings: Array, bldg_stats: Dictionary) -> void:
	var forest_noise = FastNoiseLite.new()
	forest_noise.noise_type = FastNoiseLite.TYPE_VALUE
	forest_noise.seed = world_seed + 100
	forest_noise.frequency = 0.02
	var catalog = _build_prefab_catalog(_get_available_prefabs())
	
	for town in towns:
		var layout = _get_town_layout(town)
		var rng = RandomNumberGenerator.new()
		rng.seed = hash("%d_%d" % [int(town.x), int(town.z)]) + 42
		var target = town.building_count
		var placed_in_town = 0
		var occupied: Array = []
		var candidates: Array = []
		var landmark_done = false
		var inner_limit = town.radius - layout.spacing * 0.2
		var plaza_limit = layout.plaza_half * 1.15
		landmark_done = _try_place_town_landmark(town, layout, catalog, road_segments, height_bytes, water_bytes, max_h, half, buildings, bldg_stats, occupied, rng)
		if landmark_done:
			placed_in_town += 1
			if placed_in_town >= target:
				print("[WorldMapGen] Town at (%.0f,%.0f): %d/%d buildings placed" % [town.x, town.z, placed_in_town, target])
				continue

		var parcel_slots = _generate_town_building_slots(town, layout, road_segments, rng)
		if not parcel_slots.is_empty():
			for candidate in parcel_slots:
				if placed_in_town >= target:
					break

				var center: Vector2 = candidate.center
				var parcel_size: Vector2 = candidate.size
				var district: String = candidate.district
				var prefab_name = _choose_prefab_for_parcel(catalog, district, parcel_size, rng)
				if prefab_name.is_empty():
					continue

				var fp = catalog[prefab_name]["footprint"]
				var nearest_road_pt = _find_nearest_road_point(center.x, center.y, road_segments)
				var rot = _choose_rotation_toward_point(center, nearest_road_pt, town)
				var footprint = _footprint_for_rotation(fp, rot)
				var bldg_x = floor(center.x - float(footprint.x) * 0.5)
				var bldg_z = floor(center.y - float(footprint.y) * 0.5)
				if not _validate_town_building_spot(bldg_x, bldg_z, footprint, road_segments, height_bytes, water_bytes, forest_noise, max_h, half, bldg_stats):
					continue

				var overlaps = false
				var clearance_margin = max(3.0, max(float(footprint.x), float(footprint.y)) * 0.35)
				for occ in occupied:
					if _rects_overlap(bldg_x, bldg_z, float(footprint.x), float(footprint.y), occ.x, occ.z, occ.w, occ.d, clearance_margin):
						overlaps = true
						break
				if overlaps:
					continue

				var px_b = clampi(int(bldg_x + float(footprint.x) * 0.5 + half), 0, MAP_SIZE - 1)
				var pz_b = clampi(int(bldg_z + float(footprint.y) * 0.5 + half), 0, MAP_SIZE - 1)
				var bidx = pz_b * MAP_SIZE + px_b
				var terrain_y = clampf(float(height_bytes[bidx]) / 255.0 * max_h, 1.0, 28.0)
				var road_y = _get_road_height_at(center.x, center.y)
				var bldg_y = floor(terrain_y)

				_flatten_building_pad(height_bytes, bldg_x, bldg_z, footprint, bldg_y, max_h, half)

				occupied.append({"x": bldg_x, "z": bldg_z, "w": float(footprint.x), "d": float(footprint.y)})
				bldg_stats.placed += 1
				placed_in_town += 1

				buildings.append({
					"x": bldg_x, "y": bldg_y, "z": bldg_z,
					"road_y": floor(road_y),
					"rotation": rot,
					"type": prefab_name,
					"district": district
				})

			if placed_in_town >= target:
				print("[WorldMapGen] Town at (%.0f,%.0f): %d/%d buildings placed" % [town.x, town.z, placed_in_town, target])
				continue

		print("[WorldMapGen] Town at (%.0f,%.0f): %d/%d buildings placed" % [town.x, town.z, placed_in_town, target])

func _try_place_town_landmark(town: Dictionary, layout: Dictionary, catalog: Dictionary, road_segments: Array, height_bytes: PackedByteArray, water_bytes: PackedByteArray, max_h: float, half: int, buildings: Array, bldg_stats: Dictionary, occupied: Array, rng: RandomNumberGenerator) -> bool:
	if catalog.is_empty():
		return false
	
	var prefab_name = ""
	for candidate in ["new_wooden_hall", "new_wooden_house_wide", "new_wooden_house_2floor", "wooden_house_2floor"]:
		if catalog.has(candidate):
			prefab_name = candidate
			break
	if prefab_name.is_empty():
		prefab_name = _choose_prefab_for_district(catalog, "core", rng)
	if prefab_name.is_empty():
		return false
	
	var fp = catalog[prefab_name]["footprint"]
	var clear_radius = max(float(fp.x), float(fp.y)) * 0.95 + 6.0
	var offsets = [
		Vector2(0.0, -clear_radius),
		Vector2(clear_radius, 0.0),
		Vector2(0.0, clear_radius),
		Vector2(-clear_radius, 0.0),
		Vector2(clear_radius * 0.75, -clear_radius * 0.75),
		Vector2(-clear_radius * 0.75, -clear_radius * 0.75),
		Vector2(clear_radius * 0.75, clear_radius * 0.75),
		Vector2(-clear_radius * 0.75, clear_radius * 0.75),
	]
	
	for offset in offsets:
		var center = Vector2(town.x + offset.x, town.z + offset.y)
		var nearest_road_pt = _find_nearest_road_point(center.x, center.y, road_segments)
		var rot = _choose_rotation_toward_point(center, nearest_road_pt, town)
		var footprint = _footprint_for_rotation(fp, rot)
		var bldg_x = floor(center.x - float(footprint.x) * 0.5)
		var bldg_z = floor(center.y - float(footprint.y) * 0.5)
		if not _validate_town_building_spot(bldg_x, bldg_z, footprint, road_segments, height_bytes, water_bytes, null, max_h, half, bldg_stats):
			continue
		var px_b = clampi(int(bldg_x + float(footprint.x) * 0.5 + half), 0, MAP_SIZE - 1)
		var pz_b = clampi(int(bldg_z + float(footprint.y) * 0.5 + half), 0, MAP_SIZE - 1)
		var bidx = pz_b * MAP_SIZE + px_b
		var terrain_y = clampf(float(height_bytes[bidx]) / 255.0 * max_h, 1.0, 28.0)
		var road_y = _get_road_height_at(center.x, center.y)
		var bldg_y = floor(terrain_y)
		_flatten_building_pad(height_bytes, bldg_x, bldg_z, footprint, bldg_y, max_h, half)
		occupied.append({"x": bldg_x, "z": bldg_z, "w": float(footprint.x), "d": float(footprint.y)})
		bldg_stats.placed += 1
		buildings.append({
			"x": bldg_x, "y": bldg_y, "z": bldg_z,
			"road_y": floor(road_y),
			"rotation": rot,
			"type": prefab_name,
			"district": "core_landmark"
		})
		return true
	
	return false

func _build_prefab_catalog(available_prefabs: Array[String]) -> Dictionary:
	var catalog: Dictionary = {}
	for pname in available_prefabs:
		var fp = _get_prefab_footprint(pname)
		catalog[pname] = {
			"name": pname,
			"footprint": fp,
			"area": fp.x * fp.y
		}
	return catalog

func _pick_random_catalog_entry(pool: Array, rng: RandomNumberGenerator) -> String:
	if pool.is_empty():
		return ""
	var idx = rng.randi_range(0, pool.size() - 1)
	return str(pool[idx]["name"])

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
	if district == "core":
		if roll < 0.9:
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

	var usable_w = max(0.0, parcel_size.x - settlement_lot_setback * 2.0)
	var usable_d = max(0.0, parcel_size.y - settlement_lot_setback * 2.0)

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

	var district_bonus = 1.0
	if district == "core":
		district_bonus = 1.15
	elif district == "edge":
		district_bonus = 0.95

	var roll = rng.randf()
	if roll < 0.75 * district_bonus:
		var pick = _pick_random_catalog_entry(fit_large, rng)
		if not pick.is_empty():
			return pick
	if roll < 0.95 * district_bonus:
		var pick = _pick_random_catalog_entry(fit_medium, rng)
		if not pick.is_empty():
			return pick
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
	var px = int(bldg_x + half)
	var pz = int(bldg_z + half)
	if px < 2 or px >= MAP_SIZE - 2 or pz < 2 or pz >= MAP_SIZE - 2:
		bldg_stats.rejected_bounds += 1
		return false
	
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
				return false
			var sh = clampf(float(height_bytes[idx]) / 255.0 * max_h, 1.0, 28.0)
			min_h_local = min(min_h_local, sh)
			max_h_local = max(max_h_local, sh)
	
	if _footprint_hits_road_segments(bldg_x, bldg_z, footprint, road_segments):
		bldg_stats.rejected_road += 1
		return false
	
	if max_h_local - min_h_local > 4.0:
		bldg_stats.rejected_slope += 1
		return false
	
	return true

func _flatten_building_pad(height_bytes: PackedByteArray, bldg_x: float, bldg_z: float, footprint: Vector2i, bldg_y: float, max_h: float, half: int) -> void:
	var flat_h_byte = int(clampf(bldg_y / max_h, 0.0, 1.0) * 255.0)
	var longest_side = max(float(footprint.x), float(footprint.y))
	var pad = max(6, int(ceil(longest_side * 0.5)))
	var width = footprint.x + pad * 2
	var depth = footprint.y + pad * 2
	for fz in range(-pad, depth - pad + 1):
		for fx in range(-pad, width - pad + 1):
			var fpx = clampi(int(bldg_x + half) + fx, 0, MAP_SIZE - 1)
			var fpz = clampi(int(bldg_z + half) + fz, 0, MAP_SIZE - 1)
			var h_idx = fpz * MAP_SIZE + fpx
			var orig_h_byte = height_bytes[h_idx]
			var dx = max(0.0, max(0.0 - fx, fx - float(footprint.x)))
			var dz = max(0.0, max(0.0 - fz, fz - float(footprint.y)))
			var dist = sqrt(dx * dx + dz * dz)
			if dist <= 1.25:
				height_bytes[h_idx] = flat_h_byte
			elif dist < float(pad):
				var blend_t = (dist - 1.25) / max(0.001, float(pad) - 1.25)
				var smooth_t = blend_t * blend_t * (3.0 - 2.0 * blend_t)
				height_bytes[h_idx] = int(lerp(float(flat_h_byte), float(orig_h_byte), smooth_t))

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
		var clearance_radius = seg_width + ROAD_BLEND_MARGIN
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
		max_h: float, half: int, buildings: Array, bldg_stats: Dictionary) -> void:
	
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
			var footprint = _get_prefab_footprint(prefab_name)
			if not _validate_town_building_spot(sx, sz, footprint, road_segments, height_bytes, water_bytes, forest_noise, max_h, half, bldg_stats):
				wz += spacing
				continue

			var px = int(sx + half)
			var pz = int(sz + half)
			var bidx = pz * MAP_SIZE + px
			var terrain_y = clampf(float(height_bytes[bidx]) / 255.0 * max_h, 1.0, 28.0)
			var nearest_road_pt = _find_nearest_road_point(sx, sz, road_segments)
			if nearest_road_pt != Vector2.ZERO:
				var path_seg = [{"from": Vector2(sx, sz), "to": nearest_road_pt}]
				_rasterize_roads(path_seg, height_bytes, biome_bytes, road_bytes, max_h, half, access_path_width)
			
			var road_y = _get_road_height_at(sx, sz)
			bldg_stats.placed += 1
			wilderness_count += 1
			buildings.append({
				"x": sx, "y": floor(terrain_y), "z": sz,
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
		height_bytes: PackedByteArray, half: int) -> void:
	var water_road_buffer = road_width * 0.5 + 20.0
	for z in MAP_SIZE:
		var wz = float(z - half)
		var row_offset = z * MAP_SIZE
		for x in MAP_SIZE:
			var wx = float(x - half)
			var idx = row_offset + x
			
			# Skip near roads (check road_bytes directly)
			var ridx = idx * 2
			if road_bytes[ridx] > 128:
				continue
			# Also skip if there are road pixels nearby (simple check)
			var near_road = false
			for dr in range(-int(water_road_buffer), int(water_road_buffer) + 1, 4):
				var check_x = x + dr
				var check_z = z
				if check_x >= 0 and check_x < MAP_SIZE:
					var check_ridx = (check_z * MAP_SIZE + check_x) * 2
					if road_bytes[check_ridx] > 128:
						near_road = true
						break
				check_x = x
				check_z = z + dr
				if check_z >= 0 and check_z < MAP_SIZE:
					var check_ridx = (check_z * MAP_SIZE + check_x) * 2
					if road_bytes[check_ridx] > 128:
						near_road = true
						break
			if near_road:
				continue
			
			var lake_val = _lake_noise.get_noise_2d(wx, wz)
			if lake_val > 0.3:
				water_bytes[idx] = 255

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
						height_bytes[idx] = int(clampf(r_height / max_h, 0.0, 1.0) * 255.0)
					else:
						var t = clampf((min_dist - flat_zone_end) / (flatten_width - flat_zone_end), 0.0, 1.0)
						var blend = 1.0 - t
						var orig_h = float(height_bytes[idx]) / 255.0 * max_h
						var blended = lerp(orig_h, r_height, blend)
						height_bytes[idx] = int(clampf(blended / max_h, 0.0, 1.0) * 255.0)
			
			road_bytes[ridx] = is_road_byte
			road_bytes[ridx + 1] = road_h_byte

func _generate_grid_buildings(height_bytes: PackedByteArray, water_bytes: PackedByteArray,
		biome_bytes: PackedByteArray, road_bytes: PackedByteArray,
		max_h: float, half: int, buildings: Array, bldg_stats: Dictionary) -> void:
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
				
				bldg_stats.placed += 1
				buildings.append({
					"x": spawn_x, "y": floor(terrain_y), "z": spawn_z,
					"road_y": floor(road_y),
					"type": available_prefabs[rng.randi() % available_prefabs.size()]
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
		"version": 4, "map_size": MAP_SIZE,
		"noise_freq": noise_freq, "terrain_height": terrain_height,
		"road_spacing": road_spacing, "road_width": road_width,
		"world_seed": world_seed, "use_grid_roads": use_grid_roads,
		"created": Time.get_datetime_string_from_system()
	}
	if images.has("buildings"):
		meta["buildings"] = images.buildings
	if images.has("towns"):
		meta["towns"] = images.towns
	
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
			f.close()
	return result
