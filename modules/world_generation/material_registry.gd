extends Node
class_name MaterialRegistry

## Central registry of all material IDs
## Used by gen_density.glsl and terrain.gdshader

# Surface Biomes
const GRASS = 0
const STONE = 1
const ORE_GENERIC = 2 # Legacy, will be replaced with specific ores
const SAND = 3
const GRAVEL = 4
const SNOW = 5
const ROAD = 6

# Shallow Underground
const DIRT = 7
const CLAY = 8

# Deep Underground - Stone Variants
const GRANITE = 9
const SLATE = 10

# Ore Types
const COAL = 11
const IRON = 12
const GOLD = 13
const CRYSTAL = 14

# Player-Placed (100+)
const PLAYER_PLACED_START = 100
const PLACED_STONE = 101
const PLACED_BRICK = 102
const PLACED_WOOD = 103

const DEFAULT_SURFACE_MATERIAL = GRASS

# Get display name for a material ID
static func get_material_name(id: int) -> String:
	match id:
		GRASS: return "Grass"
		STONE: return "Stone"
		ORE_GENERIC: return "Ore"
		SAND: return "Sand"
		GRAVEL: return "Gravel"
		SNOW: return "Snow"
		ROAD: return "Road"
		DIRT: return "Dirt"
		CLAY: return "Clay"
		GRANITE: return "Granite"
		SLATE: return "Slate"
		COAL: return "Coal"
		IRON: return "Iron"
		GOLD: return "Gold"
		CRYSTAL: return "Crystal"
		_:
			if id >= PLAYER_PLACED_START:
				return "Placed Material"
			return "Unknown"

static func get_base_material_id(id: int) -> int:
	if id >= PLAYER_PLACED_START:
		return id - PLAYER_PLACED_START
	return id

static func is_world_map_surface_material_id(id: int) -> bool:
	match id:
		GRASS, SAND, GRAVEL, SNOW, ROAD:
			return true
		_:
			return false

static func normalize_world_map_biome_id(id: int) -> int:
	# World-map biome layers should never use ore IDs. If a biome layer
	# contains category byte 2, preserve snow instead of rendering ore/stone.
	if id == ORE_GENERIC:
		return SNOW
	if is_world_map_surface_material_id(id):
		return id
	return DEFAULT_SURFACE_MATERIAL

static func get_minimap_rgb(id: int) -> Vector3i:
	match get_base_material_id(id):
		SAND:
			return Vector3i(194, 178, 128)
		GRAVEL:
			return Vector3i(140, 130, 115)
		SNOW:
			return Vector3i(230, 230, 240)
		ROAD:
			return Vector3i(64, 64, 77)
		STONE, ORE_GENERIC, GRANITE, SLATE, COAL, IRON, GOLD, CRYSTAL:
			return Vector3i(120, 118, 112)
		_:
			return Vector3i(80, 160, 60)
