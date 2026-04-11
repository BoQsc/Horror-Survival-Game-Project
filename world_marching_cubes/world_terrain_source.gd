extends RefCounted
class_name WorldTerrainSource

var world_map_active: bool = false
var world_map_size: float = 0.0
var world_map_half: float = 0.0
var world_map_max_height: float = 0.0
var terrain_height: float = 0.0
var water_level: float = 0.0

var heightmap_bytes: PackedByteArray = PackedByteArray()
var heightmap_width: int = 0
var heightmap_height: int = 0

var biome_bytes: PackedByteArray = PackedByteArray()
var biome_width: int = 0
var biome_height: int = 0

var road_bytes: PackedByteArray = PackedByteArray()
var road_width: int = 0
var road_height: int = 0

var water_bytes: PackedByteArray = PackedByteArray()
var water_width: int = 0
var water_height: int = 0

var buildings: Array = []
var terrain_modifications: Array = []
var excavation_masks = {}
var building_map: Image = null

func reset() -> void:
	world_map_active = false
	world_map_size = 0.0
	world_map_half = 0.0
	world_map_max_height = 0.0
	terrain_height = 0.0
	water_level = 0.0
	heightmap_bytes = PackedByteArray()
	heightmap_width = 0
	heightmap_height = 0
	biome_bytes = PackedByteArray()
	biome_width = 0
	biome_height = 0
	road_bytes = PackedByteArray()
	road_width = 0
	road_height = 0
	water_bytes = PackedByteArray()
	water_width = 0
	water_height = 0
	buildings = []
	terrain_modifications = []
	excavation_masks = {}
	building_map = null

func apply_loaded_world_map(loaded: Dictionary, fallback_terrain_height: float, fallback_map_size: float, fallback_water_level: float) -> bool:
	reset()
	if not loaded.has("heightmap") or not loaded.has("biomes") or not loaded.has("roads"):
		return false

	var hmap: Image = loaded.heightmap
	var bmap: Image = loaded.biomes
	var rmap: Image = loaded.roads
	if hmap == null or bmap == null or rmap == null:
		return false

	heightmap_bytes = hmap.get_data()
	heightmap_width = hmap.get_width()
	heightmap_height = hmap.get_height()
	biome_bytes = bmap.get_data()
	biome_width = bmap.get_width()
	biome_height = bmap.get_height()
	road_bytes = rmap.get_data()
	road_width = rmap.get_width()
	road_height = rmap.get_height()
	if loaded.has("water") and loaded.water is Image:
		var wmap: Image = loaded.water
		water_bytes = wmap.get_data()
		water_width = wmap.get_width()
		water_height = wmap.get_height()
	if loaded.has("buildings"):
		var loaded_buildings = loaded.get("buildings", [])
		if loaded_buildings is Array:
			buildings = loaded_buildings
	if loaded.has("terrain_modifications"):
		var loaded_mods = loaded.get("terrain_modifications", [])
		if loaded_mods is Array:
			terrain_modifications = loaded_mods
	if loaded.has("excavation_masks"):
		excavation_masks = loaded.get("excavation_masks", {})
	if loaded.has("building_map") and loaded.building_map is Image:
		building_map = loaded.building_map

	world_map_active = true
	terrain_height = fallback_terrain_height
	world_map_size = fallback_map_size
	water_level = fallback_water_level

	if loaded.has("metadata"):
		var meta: Dictionary = loaded.metadata
		terrain_height = float(meta.get("terrain_height", fallback_terrain_height))
		world_map_size = float(meta.get("map_size", fallback_map_size))
		water_level = float(meta.get("water_level", terrain_height + 3.0))

	world_map_half = world_map_size * 0.5
	world_map_max_height = terrain_height * 2.5
	return true

func has_world_data() -> bool:
	return world_map_active and not heightmap_bytes.is_empty() and heightmap_width > 1 and heightmap_height > 1

func sample_height(world_x: float, world_z: float) -> float:
	if not has_world_data() or world_map_size <= 0.0 or world_map_max_height <= 0.0:
		return 0.0

	var fx: float = clamp((world_x + world_map_half) / world_map_size, 0.0, 1.0) * float(heightmap_width - 1)
	var fz: float = clamp((world_z + world_map_half) / world_map_size, 0.0, 1.0) * float(heightmap_height - 1)
	var x0: int = int(floor(fx))
	var z0: int = int(floor(fz))
	var x1: int = min(x0 + 1, heightmap_width - 1)
	var z1: int = min(z0 + 1, heightmap_height - 1)
	var tx: float = fx - float(x0)
	var tz: float = fz - float(z0)

	var idx00: int = z0 * heightmap_width + x0
	var idx10: int = z0 * heightmap_width + x1
	var idx01: int = z1 * heightmap_width + x0
	var idx11: int = z1 * heightmap_width + x1
	if idx00 < 0 or idx11 >= heightmap_bytes.size():
		return 0.0

	var h00 := float(heightmap_bytes[idx00]) / 255.0 * world_map_max_height
	var h10 := float(heightmap_bytes[idx10]) / 255.0 * world_map_max_height
	var h01 := float(heightmap_bytes[idx01]) / 255.0 * world_map_max_height
	var h11 := float(heightmap_bytes[idx11]) / 255.0 * world_map_max_height
	var h0: float = lerp(h00, h10, tx)
	var h1: float = lerp(h01, h11, tx)
	return lerp(h0, h1, tz)

func sample_biome(world_x: float, world_z: float) -> float:
	if biome_bytes.is_empty() or biome_width < 1 or biome_height < 1 or world_map_size <= 0.0:
		return 0.0
	var fx: float = clamp((world_x + world_map_half) / world_map_size, 0.0, 1.0) * float(biome_width - 1)
	var fz: float = clamp((world_z + world_map_half) / world_map_size, 0.0, 1.0) * float(biome_height - 1)
	var x: int = int(clamp(round(fx), 0.0, float(biome_width - 1)))
	var z: int = int(clamp(round(fz), 0.0, float(biome_height - 1)))
	var idx: int = z * biome_width + x
	if idx < 0 or idx >= biome_bytes.size():
		return 0.0
	return float(biome_bytes[idx]) / 255.0

func sample_road(world_x: float, world_z: float) -> float:
	if road_bytes.is_empty() or road_width < 1 or road_height < 1 or world_map_size <= 0.0:
		return 0.0
	var fx: float = clamp((world_x + world_map_half) / world_map_size, 0.0, 1.0) * float(road_width - 1)
	var fz: float = clamp((world_z + world_map_half) / world_map_size, 0.0, 1.0) * float(road_height - 1)
	var x: int = int(clamp(round(fx), 0.0, float(road_width - 1)))
	var z: int = int(clamp(round(fz), 0.0, float(road_height - 1)))
	var idx: int = z * road_width + x
	if idx < 0 or idx >= road_bytes.size():
		return 0.0
	return float(road_bytes[idx]) / 255.0

func sample_is_below_water(world_x: float, world_z: float, world_y: float) -> bool:
	return world_y < water_level
