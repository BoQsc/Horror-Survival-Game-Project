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
var buildings_per_town_max: int = 20
var wilderness_building_chance: float = 0.03  # ~3% of grid cells get a wilderness building
var access_path_width: float = 3.0  # Narrow road from wilderness buildings to nearest main road

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
		"rejected_slope": 0, "rejected_forest": 0, "rejected_height": 0
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
		road_segments = _build_mst_roads(towns)
		_rasterize_roads(road_segments, height_bytes, biome_bytes, road_bytes, max_h, half, road_width)
		# Internal town roads
		for town in towns:
			var internal_segs = _generate_town_internal_roads(town)
			_rasterize_roads(internal_segs, height_bytes, biome_bytes, road_bytes, max_h, half, 6.0)
		
		if progress_callback.is_valid():
			progress_callback.call(55.0, "Placing buildings in towns")
		_generate_town_buildings(towns, height_bytes, water_bytes, road_bytes, max_h, half, buildings, bldg_stats)
		
		if progress_callback.is_valid():
			progress_callback.call(70.0, "Placing wilderness buildings")
		_generate_wilderness_buildings(towns, road_segments, height_bytes, water_bytes, biome_bytes, road_bytes, max_h, half, buildings, bldg_stats)
	
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
		var stamp_size = 10
		var stamp_half = stamp_size / 2
		for fx in range(stamp_size):
			for fz in range(stamp_size):
				var fpx = px - stamp_half + fx
				var fpz = pz - stamp_half + fz
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
	var max_attempts = target_count * 50
	
	for _attempt in range(max_attempts):
		if towns.size() >= target_count:
			break
		
		# Random position within map (leave margin)
		var margin = 150.0
		var tx = rng.randf_range(-half + margin, half - margin)
		var tz = rng.randf_range(-half + margin, half - margin)
		
		# Check spacing from other towns
		var too_close = false
		for existing in towns:
			var dist = Vector2(tx, tz).distance_to(Vector2(existing.x, existing.z))
			if dist < town_min_spacing:
				too_close = true
				break
		if too_close:
			continue
		
		# Check terrain at town center
		var px = int(tx + half)
		var pz = int(tz + half)
		if px < 0 or px >= MAP_SIZE or pz < 0 or pz >= MAP_SIZE:
			continue
		var bidx = pz * MAP_SIZE + px
		
		# Reject water
		if water_bytes[bidx] > 128:
			continue
		
		# Reject extreme heights
		var terrain_y = clampf(float(height_bytes[bidx]) / 255.0 * max_h, 1.0, 28.0)
		if terrain_y < 3.0 or terrain_y > 26.0:
			continue
		
		var radius = rng.randf_range(town_radius_min, town_radius_max)
		var bldg_count = mini(buildings_per_town_max, int(radius * 0.25))
		bldg_count = maxi(bldg_count, 8)
		
		towns.append({
			"x": tx, "z": tz,
			"radius": radius,
			"building_count": bldg_count,
			"terrain_y": terrain_y
		})
	
	print("[WorldMapGen] Placed %d towns (target: %d)" % [towns.size(), target_count])
	return towns

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

func _uf_find(parent: Array, x: int) -> int:
	while parent[x] != x:
		parent[x] = parent[parent[x]]  # Path compression
		x = parent[x]
	return x

# ============================================================================
# INTERNAL TOWN ROADS
# ============================================================================

func _generate_town_internal_roads(town: Dictionary) -> Array:
	var cx = town.x
	var cz = town.z
	var r = town.radius * 0.8  # Roads extend to 80% of town radius
	# Cross pattern: N/S + E/W through center
	return [
		{"from": Vector2(cx, cz - r), "to": Vector2(cx, cz + r)},
		{"from": Vector2(cx - r, cz), "to": Vector2(cx + r, cz)},
	]

# ============================================================================
# ROAD RASTERIZATION
# ============================================================================

func _rasterize_roads(segments: Array, height_bytes: PackedByteArray, biome_bytes: PackedByteArray,
		road_bytes: PackedByteArray, max_h: float, half: int, r_width: float) -> void:
	var half_w = r_width * 0.5
	var flatten_w = r_width + 15.0  # Smooth blend shoulder
	
	for seg in segments:
		var from_v: Vector2 = seg["from"]
		var to_v: Vector2 = seg["to"]
		var seg_len = from_v.distance_to(to_v)
		if seg_len < 1.0:
			continue
		var dir = (to_v - from_v) / seg_len  # Normalized direction
		
		# Bounding box of segment, expanded by flatten_w
		var min_x = int(min(from_v.x, to_v.x) - flatten_w) + half
		var max_x = int(max(from_v.x, to_v.x) + flatten_w) + half
		var min_z = int(min(from_v.y, to_v.y) - flatten_w) + half
		var max_z = int(max(from_v.y, to_v.y) + flatten_w) + half
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
				
				if dist > flatten_w:
					continue
				
				# Road height at the closest point on the segment
				var r_height = _get_road_height_at(closest.x, closest.y)
				var idx = pz * MAP_SIZE + px
				var ridx = idx * 2
				
				if dist < half_w:
					# Road surface — overwrite height, biome, and road mask
					var r_height_byte = int(clampf(r_height / 64.0, 0.0, 1.0) * 255.0)
					var h_byte = int(clampf(r_height / max_h, 0.0, 1.0) * 255.0)
					road_bytes[ridx] = 255
					road_bytes[ridx + 1] = r_height_byte
					biome_bytes[idx] = MaterialID.ROAD
					height_bytes[idx] = h_byte
				else:
					# Blend zone — smooth lerp from road height to terrain height
					var blend_t = clampf((dist - half_w) / (flatten_w - half_w), 0.0, 1.0)
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
# TOWN BUILDING LOTS
# ============================================================================

func _generate_town_buildings(towns: Array, height_bytes: PackedByteArray,
		water_bytes: PackedByteArray, road_bytes: PackedByteArray,
		max_h: float, half: int, buildings: Array, bldg_stats: Dictionary) -> void:
	
	var forest_noise = FastNoiseLite.new()
	forest_noise.noise_type = FastNoiseLite.TYPE_VALUE
	forest_noise.seed = world_seed + 100
	forest_noise.frequency = 0.02
	var available_prefabs = _get_available_prefabs()
	
	for town in towns:
		var rng = RandomNumberGenerator.new()
		rng.seed = hash("%d_%d" % [int(town.x), int(town.z)]) + 42
		
		var placed_in_town = 0
		var target = town.building_count
		var attempts = target * 8
		
		for _attempt in range(attempts):
			if placed_in_town >= target:
				break
			
			bldg_stats.attempted += 1
			
			# Pick a random position within town radius, offset from roads
			var angle = rng.randf() * TAU
			var dist = rng.randf_range(spawn_distance_from_road, town.radius)
			var spawn_x = town.x + cos(angle) * dist
			var spawn_z = town.z + sin(angle) * dist
			
			if not _validate_building_spot(spawn_x, spawn_z, height_bytes, water_bytes, forest_noise, max_h, half, bldg_stats):
				continue
			
			var px = int(spawn_x + half)
			var pz = int(spawn_z + half)
			var bidx = pz * MAP_SIZE + px
			var terrain_y = clampf(float(height_bytes[bidx]) / 255.0 * max_h, 1.0, 28.0)
			
			# Get road height for alignment
			var road_y = _get_road_height_at(town.x, town.z)
			
			bldg_stats.placed += 1
			placed_in_town += 1
			buildings.append({
				"x": spawn_x, "y": floor(terrain_y), "z": spawn_z,
				"road_y": floor(road_y),
				"type": available_prefabs[rng.randi() % available_prefabs.size()]
			})
		
		print("[WorldMapGen] Town at (%.0f,%.0f): %d/%d buildings placed" % [town.x, town.z, placed_in_town, target])

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
			
			if not _validate_building_spot(sx, sz, height_bytes, water_bytes, forest_noise, max_h, half, bldg_stats):
				wz += spacing
				continue
			
			var px = int(sx + half)
			var pz = int(sz + half)
			var bidx = pz * MAP_SIZE + px
			var terrain_y = clampf(float(height_bytes[bidx]) / 255.0 * max_h, 1.0, 28.0)
			
			# Find nearest road point and carve access path
			var nearest_road_pt = _find_nearest_road_point(sx, sz, road_bytes, half)
			if nearest_road_pt != Vector2.ZERO:
				# Rasterize narrow access path
				var path_seg = [{"from": Vector2(sx, sz), "to": nearest_road_pt}]
				_rasterize_roads(path_seg, height_bytes, biome_bytes, road_bytes, max_h, half, access_path_width)
			
			var road_y = _get_road_height_at(sx, sz)
			bldg_stats.placed += 1
			wilderness_count += 1
			buildings.append({
				"x": sx, "y": floor(terrain_y), "z": sz,
				"road_y": floor(road_y),
				"type": available_prefabs[cell_rng.randi() % available_prefabs.size()],
				"wilderness": true
			})
			
			wz += spacing
		wx += spacing
	
	print("[WorldMapGen] Wilderness buildings: %d placed" % wilderness_count)

func _find_nearest_road_point(wx: float, wz: float, road_bytes: PackedByteArray, half: int) -> Vector2:
	# Scan outward in a spiral to find the nearest road pixel
	var max_search = 300  # Max 300m search radius
	var bx = int(wx + half)
	var bz = int(wz + half)
	
	for radius in range(1, max_search, 2):
		# Check 8 directions at this radius
		for angle_idx in range(16):
			var angle = float(angle_idx) / 16.0 * TAU
			var sx = bx + int(cos(angle) * float(radius))
			var sz = bz + int(sin(angle) * float(radius))
			if sx < 0 or sx >= MAP_SIZE or sz < 0 or sz >= MAP_SIZE:
				continue
			var ridx = (sz * MAP_SIZE + sx) * 2
			if road_bytes[ridx] > 128:
				return Vector2(float(sx - half), float(sz - half))
	
	return Vector2.ZERO  # No road found

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
		"version": 3, "map_size": MAP_SIZE,
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
	for dir_path in ["res://world_prefabs/", "user://world_prefabs/"]:
		if DirAccess.dir_exists_absolute(dir_path):
			var dir = DirAccess.open(dir_path)
			if dir:
				dir.list_dir_begin()
				var file_name = dir.get_next()
				while file_name != "":
					if file_name.ends_with(".json"):
						prefabs.append(file_name.replace(".json", ""))
					file_name = dir.get_next()
				dir.list_dir_end()
	
	if not "small_house" in prefabs:
		prefabs.append("small_house")
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
