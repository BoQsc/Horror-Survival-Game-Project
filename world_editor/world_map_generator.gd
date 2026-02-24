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

# Progress callback
var progress_callback: Callable = Callable()

# Noise instances
var _height_noise: FastNoiseLite
var _biome_noise: FastNoiseLite
var _road_height_noise: FastNoiseLite

enum MaterialID {
	GRASS = 0, STONE = 1, ORE = 2, SAND = 3,
	GRAVEL = 4, SNOW = 5, ROAD = 6, GRANITE = 9
}

func _init_noise() -> void:
	_height_noise = FastNoiseLite.new()
	_height_noise.seed = world_seed
	_height_noise.noise_type = FastNoiseLite.TYPE_VALUE_CUBIC
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
	var struct_bytes = PackedByteArray()
	struct_bytes.resize(total)
	
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
			
			# Biome
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
	
	# PASS 3: Convert byte arrays to Images
	if progress_callback.is_valid():
		progress_callback.call(90.0, "Building images")
	
	var heightmap = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8, height_bytes)
	var biome_map = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8, biome_bytes)
	var road_map = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_RG8, road_bytes)
	var structure_map = Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8, struct_bytes)
	
	if progress_callback.is_valid():
		progress_callback.call(100.0, "Complete")
	
	return {
		"heightmap": heightmap,
		"biomes": biome_map,
		"roads": road_map,
		"structures": structure_map
	}

# ============================================================================
# SAVE / LOAD
# ============================================================================

func save_world(path: String, images: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(path)
	for key in images:
		var err = (images[key] as Image).save_png(path.path_join(key + ".png"))
		if err != OK:
			push_error("[WorldMapGen] Failed to save %s" % key)
			return false
	
	var meta = {
		"version": 1, "map_size": MAP_SIZE,
		"noise_freq": noise_freq, "terrain_height": terrain_height,
		"road_spacing": road_spacing, "road_width": road_width,
		"world_seed": world_seed,
		"created": Time.get_datetime_string_from_system()
	}
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
		"structures": Image.FORMAT_R8
	}
	for img_name in ["heightmap", "biomes", "roads", "structures"]:
		var fp = path.path_join(img_name + ".png")
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
			result["metadata"] = j.get_data(); f.close()
	return result
