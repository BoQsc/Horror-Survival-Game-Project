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
