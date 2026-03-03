extends RefCounted
class_name WorldMapGenerator
## WorldMapGenerator - FAST world definition PNG generation
## Uses FastNoiseLite (C++) + raw byte arrays (no set_pixel overhead)

const MAP_SIZE: int = 2048  # 1 pixel = 1 meter

# CONSTRAINT: max decoded height = 2 * terrain_height must be < CHUNK_SIZE (32)
# Max safe value is 15.0 (2*15=30 < 32). Default matches chunk_manager.gd procedural terrain.
var noise_freq: float = 0.1  # Must match chunk_manager.gd noise_frequency for similar terrain
var terrain_height: float = 10.0
var road_spacing: float = 100.0
var road_width: float = 8.0
var wide_shoulders: bool = false
var world_seed: int = 12345
var lake_threshold: float = 0.35  # Fraction of max height below which lakes form
var spawn_distance_from_road: float = 15.0
var building_spawn_chance: float = 0.3

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
	_height_noise.noise_type = FastNoiseLite.TYPE_VALUE  # Matches shader hash noise range [0,1]
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
	_lake_noise.frequency = 0.0008  # Very low frequency = few large lake regions
	_lake_noise.fractal_type = FastNoiseLite.FRACTAL_NONE  # No fractal = smooth blobs, not scattered dots

# ============================================================================
# OPTIMIZED GENERATION — raw byte arrays, no set_pixel
# ============================================================================

func generate_world() -> Dictionary:
	# Enforce height constraint: 2 * terrain_height must fit within CHUNK_SIZE (32)
	# Heights range from terrain_height to 2*terrain_height, so max terrain_height = 15
	if terrain_height > 15.0:
		print("[WorldMapGen] WARNING: terrain_height %.1f exceeds safe max 15.0, clamping" % terrain_height)
		terrain_height = 15.0
	_init_noise()
	var half = MAP_SIZE / 2
	var total = MAP_SIZE * MAP_SIZE
	
	# Allocate raw byte buffers (MUCH faster than per-pixel Image.set_pixel)
	var height_bytes = PackedByteArray()
	height_bytes.resize(total)
	var biome_bytes = PackedByteArray()
	biome_bytes.resize(total)
	# Roads: 2 bytes per pixel (RG8)
	var road_bytes = PackedByteArray()
	road_bytes.resize(total * 2)
	# Water map: R8, 255 = water, 0 = dry
	var water_bytes = PackedByteArray()
	water_bytes.resize(total)
	
	var max_h = terrain_height * 2.5
	var half_road_w = road_width * 0.5
	var flatten_width = (road_width + 25.0) if wide_shoulders else road_width
	var flat_zone_end = (road_width * 0.5 + 15.0) if wide_shoulders else half_road_w
	
	# PASS 1: Height + Biome (fast — just FastNoiseLite calls + byte writes)
	if progress_callback.is_valid():
		progress_callback.call(0.0, "Generating height + biomes")
	
	for z in MAP_SIZE:
		if z % 256 == 0 and progress_callback.is_valid():
			progress_callback.call(float(z) / MAP_SIZE * 50.0, "Height + biomes")
		
		var wz = float(z - half)
		var row_offset = z * MAP_SIZE
		
		for x in MAP_SIZE:
			var wx = float(x - half)
			var idx = row_offset + x
			
			# Height from noise ([-1,1] → [0,1] → scaled)
			var h_raw = _height_noise.get_noise_2d(wx, wz)
			var h = terrain_height + (h_raw * 0.5 + 0.5) * terrain_height
			height_bytes[idx] = int(clampf(h / max_h, 0.0, 1.0) * 255.0)
			
			# Biome — discrete IDs for world editor preview
			# In-game terrain uses GPU fbm() directly (same as procedural mode)
			var bv = _biome_noise.get_noise_2d(wx, wz)
			var biome: int = MaterialID.GRASS
			if bv < -0.2: biome = MaterialID.SAND
			elif bv > 0.6: biome = MaterialID.SNOW
			elif bv > 0.2: biome = MaterialID.GRAVEL
			biome_bytes[idx] = biome
	
	# PASS 2: Roads (grid math + road height noise)
	if progress_callback.is_valid():
		progress_callback.call(50.0, "Generating roads")
	
	for z in MAP_SIZE:
		if z % 256 == 0 and progress_callback.is_valid():
			progress_callback.call(50.0 + float(z) / MAP_SIZE * 40.0, "Roads")
		
		var wz = float(z - half)
		var row_offset = z * MAP_SIZE
		
		for x in MAP_SIZE:
			var wx = float(x - half)
			var idx = row_offset + x
			var ridx = idx * 2  # 2 bytes per pixel
			
			# Road distance (inline for speed)
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
					# Need road height
					var cell_x = floor(wx / road_spacing)
					var cell_z = floor(wz / road_spacing)
					var h1 = _road_height_noise.get_noise_2d(cell_x * road_spacing, cell_z * road_spacing) * 3.0 + 12.0
					var h2 = _road_height_noise.get_noise_2d((cell_x + 1) * road_spacing, cell_z * road_spacing) * 3.0 + 12.0
					var h3 = _road_height_noise.get_noise_2d(cell_x * road_spacing, (cell_z + 1) * road_spacing) * 3.0 + 12.0
					var h4 = _road_height_noise.get_noise_2d((cell_x + 1) * road_spacing, (cell_z + 1) * road_spacing) * 3.0 + 12.0
					
					var tx = local_x / road_spacing
					var tz = local_z / road_spacing
					var interp_h = lerp(lerp(h1, h2, tx), lerp(h3, h4, tx), tz)
					
					# Stepped height
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
						# Overwrite height with road height
						height_bytes[idx] = int(clampf(r_height / max_h, 0.0, 1.0) * 255.0)
					else:
						# Blend zone — lerp terrain height toward road height
						var t = clampf((min_dist - flat_zone_end) / (flatten_width - flat_zone_end), 0.0, 1.0)
						var blend = 1.0 - t
						var orig_h = float(height_bytes[idx]) / 255.0 * max_h
						var blended = lerp(orig_h, r_height, blend)
						height_bytes[idx] = int(clampf(blended / max_h, 0.0, 1.0) * 255.0)
			
			road_bytes[ridx] = is_road_byte
			road_bytes[ridx + 1] = road_h_byte
	
	# PASS 3: Lakes — large coherent water bodies, exclude roads
	if progress_callback.is_valid():
		progress_callback.call(90.0, "Generating lakes")
	
	# Lakes are defined purely by low-frequency noise — no height dependency
	# This creates a few large, smooth lake shapes instead of scattered dots
	var water_road_buffer = half_road_w + 20.0  # Keep water this far from road centers
	for z in MAP_SIZE:
		var wz = float(z - half)
		var row_offset = z * MAP_SIZE
		for x in MAP_SIZE:
			var wx = float(x - half)
			var idx = row_offset + x
			
			# Skip near roads — compute distance to nearest road line
			if road_spacing > 0.0:
				var local_x = fmod(wx, road_spacing)
				var local_z = fmod(wz, road_spacing)
				if local_x < 0: local_x += road_spacing
				if local_z < 0: local_z += road_spacing
				var dist_x = minf(local_x, road_spacing - local_x)
				var dist_z = minf(local_z, road_spacing - local_z)
				var min_dist = minf(dist_x, dist_z)
				if min_dist < water_road_buffer:
					continue
			
			# Lake noise: only strong positive values become lakes (large smooth blobs)
			var lake_val = _lake_noise.get_noise_2d(wx, wz)
			if lake_val > 0.3:
				water_bytes[idx] = 255
	
	# PASS 4: Bake building positions at road intersections (VALIDATED)
	if progress_callback.is_valid():
		progress_callback.call(95.0, "Placing buildings")
	
	# Building map — R8 image tracking building footprints
	var building_bytes = PackedByteArray()
	building_bytes.resize(total)
	building_bytes.fill(0)
	
	# Rejection stats
	var bldg_stats = {
		"attempted": 0,
		"placed": 0,
		"rejected_chance": 0,
		"rejected_bounds": 0,
		"rejected_water": 0,
		"rejected_slope": 0,
		"rejected_forest": 0,
		"rejected_height": 0
	}
	
	# Forest noise for checking forested areas (matches prefab_spawner)
	var forest_noise = FastNoiseLite.new()
	forest_noise.noise_type = FastNoiseLite.TYPE_VALUE
	forest_noise.seed = world_seed + 100
	forest_noise.frequency = 0.02
	
	var buildings: Array = []
	if road_spacing > 0.0:
		var grid_min = int(-half / road_spacing) - 1
		var grid_max = int(half / road_spacing) + 1
		
		for cx in range(grid_min, grid_max + 1):
			for cz in range(grid_min, grid_max + 1):
				var key = "%d_%d" % [cx, cz]
				var rng = RandomNumberGenerator.new()
				rng.seed = hash(key) + 42
				
				bldg_stats.attempted += 1
				
				# Chance to spawn
				if rng.randf() > building_spawn_chance:
					bldg_stats.rejected_chance += 1
					continue
				
				# Pick side of road
				var side = 1.0 if rng.randf() > 0.5 else -1.0
				var spawn_x = cx * road_spacing + spawn_distance_from_road * side
				var spawn_z = cz * road_spacing + spawn_distance_from_road
				
				# Check within map bounds
				var px = int(spawn_x + half)
				var pz = int(spawn_z + half)
				if px < 2 or px >= MAP_SIZE - 2 or pz < 2 or pz >= MAP_SIZE - 2:
					bldg_stats.rejected_bounds += 1
					continue
				
				var bidx = pz * MAP_SIZE + px
				
				# Check: water
				if water_bytes[bidx] > 128:
					bldg_stats.rejected_water += 1
					continue
				
				# Check: terrain height sanity
				var terrain_y = float(height_bytes[bidx]) / 255.0 * max_h
				if terrain_y < 2.0 or terrain_y > 28.0:
					bldg_stats.rejected_height += 1
					continue
				
				# Check: terrain slope (max height diff across 5x5 footprint)
				var min_h_local = terrain_y
				var max_h_local = terrain_y
				for sx in range(-2, 3):
					for sz in range(-2, 3):
						var si = (pz + sz) * MAP_SIZE + (px + sx)
						if si >= 0 and si < total:
							var sh = float(height_bytes[si]) / 255.0 * max_h
							min_h_local = min(min_h_local, sh)
							max_h_local = max(max_h_local, sh)
				if max_h_local - min_h_local > 3.0:
					bldg_stats.rejected_slope += 1
					continue
				
				# Check: forest (matches prefab_spawner._is_forested_area)
				var is_forested = false
				for dx in range(-2, 5, 2):
					for dz in range(-2, 5, 2):
						if forest_noise.get_noise_2d(spawn_x + dx, spawn_z + dz) >= 0.4:
							is_forested = true
							break
					if is_forested:
						break
				if is_forested:
					bldg_stats.rejected_forest += 1
					continue
				
				# ALL CHECKS PASSED — place building
				bldg_stats.placed += 1
				buildings.append({
					"x": spawn_x,
					"y": floor(terrain_y),
					"z": spawn_z,
					"type": "small_house"
				})
				
				# Stamp building footprint onto building_bytes (10x10 visible on map)
				var stamp_size = 10
				var stamp_half = stamp_size / 2
				for fx in range(stamp_size):
					for fz in range(stamp_size):
						var fpx = px - stamp_half + fx
						var fpz = pz - stamp_half + fz
						if fpx >= 0 and fpx < MAP_SIZE and fpz >= 0 and fpz < MAP_SIZE:
							building_bytes[fpz * MAP_SIZE + fpx] = 255
	
	print("[WorldMapGen] Buildings: %d placed / %d attempted (water:%d slope:%d forest:%d height:%d bounds:%d chance:%d)" % [
		bldg_stats.placed, bldg_stats.attempted,
		bldg_stats.rejected_water, bldg_stats.rejected_slope,
		bldg_stats.rejected_forest, bldg_stats.rejected_height,
		bldg_stats.rejected_bounds, bldg_stats.rejected_chance
	])
	
	# Convert byte arrays to Images
	var heightmap = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8, height_bytes)
	var biome_map = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8, biome_bytes)
	var road_map = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_RG8, road_bytes)
	var water_map = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8, water_bytes)
	var building_map = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8, building_bytes)
	
	if progress_callback.is_valid():
		progress_callback.call(100.0, "Complete")
	
	return {
		"heightmap": heightmap,
		"biomes": biome_map,
		"roads": road_map,
		"water": water_map,
		"building_map": building_map,
		"buildings": buildings,
		"building_stats": bldg_stats
	}

# ============================================================================
# SAVE / LOAD
# ============================================================================

func save_world(path: String, images: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(path)
	# Save image files (skip non-Image entries like "buildings")
	for key in images:
		if images[key] is Image:
			var err = (images[key] as Image).save_png(path.path_join(key + ".png"))
			if err != OK:
				push_error("[WorldMapGen] Failed to save %s" % key)
				return false
	
	var meta = {
		"version": 2, "map_size": MAP_SIZE,
		"noise_freq": noise_freq, "terrain_height": terrain_height,
		"road_spacing": road_spacing, "road_width": road_width,
		"world_seed": world_seed,
		"created": Time.get_datetime_string_from_system()
	}
	# Store baked building positions in metadata
	if images.has("buildings"):
		meta["buildings"] = images.buildings
	
	var file = FileAccess.open(path.path_join("world_meta.json"), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(meta, "\t"))
		file.close()
	print("[WorldMapGen] Saved to: %s" % path)
	return true

static func load_world(path: String) -> Dictionary:
	var result = {}
	# Expected formats (PNG always loads as RGBA8, must convert back)
	var expected_formats = {
		"heightmap": Image.FORMAT_R8,
		"biomes": Image.FORMAT_R8,
		"roads": Image.FORMAT_RG8,
		"water": Image.FORMAT_R8,
		"building_map": Image.FORMAT_R8
	}
	for img_name in ["heightmap", "biomes", "roads", "water", "building_map"]:
		var fp = path.path_join(img_name + ".png")
		# Backward compat: old worlds saved "structures.png" instead of "water.png"
		if not FileAccess.file_exists(fp) and img_name == "water":
			fp = path.path_join("structures.png")
		if FileAccess.file_exists(fp):
			var img = Image.load_from_file(fp)
			if img:
				# PNG loads as RGBA8 — convert to our expected format
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
			# Load baked buildings from metadata
			if meta.has("buildings"):
				result["buildings"] = meta.buildings
			f.close()
	return result

