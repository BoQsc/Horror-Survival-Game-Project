extends RefCounted
class_name ItemDefinitions
## ItemDefinitions - Item category definitions and test item data
## Provides item category enum and helper functions.

enum ItemCategory {
	NONE, # Empty hand / fists
	TOOL, # Pickaxe, Axe, Sword - combat/mining
	BUCKET, # Water bucket - place/remove water
	RESOURCE, # Dirt, Stone, Sand - place terrain
	BLOCK, # Cube, Ramp, Stairs - building blocks
	OBJECT, # Door, Window, Table - functional grid items
	PROP # Food cans, decorations - free-placed items
}

# Item structure:
# {
#     "id": String,           # Unique identifier
#     "name": String,         # Display name
#     "category": ItemCategory,
#     "damage": int,          # For TOOL: melee damage
#     "mining_strength": float, # For TOOL: terrain dig amount
#     "icon": String,         # Path to icon texture (optional)
#     "scene": String,        # Path to 3D model scene (optional)
#     "stack_size": int,      # Max stack size (default 1 for tools, 64 for resources)
# }

## Test items for initial hotbar population
static func get_test_items() -> Array[Dictionary]:
	return [
		# Slot 0 (key 1): Stone Pickaxe
		{
			"id": "pickaxe_stone",
			"name": "Stone Pickaxe",
			"category": ItemCategory.TOOL,
			"damage": 2,
			"mining_strength": 1.5,
			"stack_size": 1
		},
		# Slot 1 (key 2): Stone Axe
		{
			"id": "axe_stone",
			"name": "Stone Axe",
			"category": ItemCategory.TOOL,
			"damage": 3,
			"mining_strength": 0.5,
			"stack_size": 1
		},
		# Slot 2 (key 3): Water Bucket
		{
			"id": "bucket_water",
			"name": "Water Bucket",
			"category": ItemCategory.BUCKET,
			"damage": 1,
			"mining_strength": 0.0,
			"stack_size": 1
		},
		# Slot 4 (key 5): Dirt
		{
			"id": "dirt",
			"name": "Dirt",
			"category": ItemCategory.RESOURCE,
			"damage": 0,
			"mining_strength": 0.0,
			"stack_size": 64,
			"mat_id": 0 # 0=Grass/Dirt surface material
		},
		# Slot 5 (key 6): Stone Block
		{
			"id": "block_cube",
			"name": "Wood Cube",
			"category": ItemCategory.BLOCK,
			"block_id": 1,
			"damage": 0,
			"mining_strength": 0.0,
			"stack_size": 64
		},
		# Slot 6 (key 7): Ramp Block
		{
			"id": "block_ramp",
			"name": "Ramp",
			"category": ItemCategory.BLOCK,
			"block_id": 2,
			"damage": 0,
			"mining_strength": 0.0,
			"stack_size": 64
		},
		# Slot 7 (key 8): Door
		{
			"id": "object_door",
			"name": "Wooden Door",
			"category": ItemCategory.OBJECT,
			"object_id": 4,
			"damage": 0,
			"mining_strength": 0.0,
			"stack_size": 16
		},
		# Slot 8 (key 9): Cardboard
		{
			"id": "object_cardboard",
			"name": "Cardboard Box",
			"category": ItemCategory.OBJECT,
			"object_id": 1,
			"damage": 0,
			"mining_strength": 0.0,
			"stack_size": 16
		},
		# Slot 9 (key 0): Empty slot (acts like fists for combat)
		{
			"id": "empty",
			"name": "Empty",
			"category": ItemCategory.NONE,
			"damage": 1,
			"mining_strength": 1.0,
			"stack_size": 1
		}
	]

## Get category name for display
static func get_category_name(category: ItemCategory) -> String:
	match category:
		ItemCategory.NONE: return "None"
		ItemCategory.TOOL: return "Tool"
		ItemCategory.BUCKET: return "Bucket"
		ItemCategory.RESOURCE: return "Resource"
		ItemCategory.BLOCK: return "Block"
		ItemCategory.OBJECT: return "Object"
		ItemCategory.PROP: return "Prop"
	return "Unknown"

## Check if category triggers BUILD mode (category-only check)
static func is_build_category(category: ItemCategory) -> bool:
	return category in [ItemCategory.BLOCK, ItemCategory.OBJECT, ItemCategory.PROP]

## Check if an item should trigger BUILD mode (considers firearm flag)
static func is_build_item(item: Dictionary) -> bool:
	var category = item.get("category", ItemCategory.NONE)
	
	# Firearms stay in PLAY mode even though they're PROP category
	if item.get("is_firearm", false):
		return false
	
	return is_build_category(category)

## Check if category is a PLAY mode tool
static func is_play_category(category: ItemCategory) -> bool:
	return category in [ItemCategory.NONE, ItemCategory.TOOL, ItemCategory.BUCKET, ItemCategory.RESOURCE]

## Get the legacy Fists item (hidden, not in default hotbar)
## Can be spawned via console or given to player programmatically
static func get_fists_item() -> Dictionary:
	return {
		"id": "fists",
		"name": "Fists",
		"category": ItemCategory.NONE,
		"damage": 1,
		"mining_strength": 1.0,
		"stack_size": 1
	}

## Terrain resource items - map material ID to item
static func get_terrain_resources() -> Dictionary:
	return {
		0: {"id": "res_grass", "name": "Grass", "category": ItemCategory.RESOURCE, "stack_size": 64, "mat_id": 0},
		1: {"id": "res_stone", "name": "Stone", "category": ItemCategory.RESOURCE, "stack_size": 64, "mat_id": 1},
		2: {"id": "res_ore", "name": "Ore", "category": ItemCategory.RESOURCE, "stack_size": 64, "mat_id": 2},
		3: {"id": "res_sand", "name": "Sand", "category": ItemCategory.RESOURCE, "stack_size": 64, "mat_id": 3},
		4: {"id": "res_gravel", "name": "Gravel", "category": ItemCategory.RESOURCE, "stack_size": 64, "mat_id": 4},
		5: {"id": "res_snow", "name": "Snow", "category": ItemCategory.RESOURCE, "stack_size": 64, "mat_id": 5},
		9: {"id": "res_granite", "name": "Granite", "category": ItemCategory.RESOURCE, "stack_size": 64, "mat_id": 9},
	}

## Vegetation resource items - dropped when harvesting vegetation
static func get_vegetation_resources() -> Dictionary:
	return {
		"wood": {"id": "veg_wood", "name": "Wood", "category": ItemCategory.RESOURCE, "stack_size": 64},
		"fiber": {"id": "veg_fiber", "name": "Plant Fiber", "category": ItemCategory.RESOURCE, "stack_size": 64},
		"rock": {"id": "veg_rock", "name": "Rock", "category": ItemCategory.RESOURCE, "stack_size": 64},
	}

## Get vegetation resource item by type (wood, fiber, rock)
static func get_vegetation_resource(veg_type: String) -> Dictionary:
	var resources = get_vegetation_resources()
	if resources.has(veg_type):
		return resources[veg_type].duplicate()
	return {}

## Get resource item by material ID
static func get_resource_for_material(mat_id: int) -> Dictionary:
	var resources = get_terrain_resources()
	if resources.has(mat_id):
		return resources[mat_id].duplicate()
	# Fallback to stone
	return resources[1].duplicate()

## Get item definition for a specific block ID
static func get_item_for_block(block_id: int) -> Dictionary:
	var items = get_test_items()
	for item in items:
		if item.get("category") == ItemCategory.BLOCK and item.get("block_id") == block_id:
			return item.duplicate()
	return {}

## Get Heavy Pistol definition (Single Source of Truth)
static func get_heavy_pistol_definition() -> Dictionary:
	return {
		"id": "heavy_pistol",
		"name": "Heavy Pistol",
		"category": ItemCategory.PROP,
		"is_firearm": true,  # Firearms stay in PLAY mode, not BUILD mode
		"damage": 5,
		"range": 50.0,
		"stack_size": 1,
		"scene": "res://models/pistol/heavy_pistol_physics.tscn"
	}
