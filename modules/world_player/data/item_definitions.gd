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
		# Slot 0 (key 1): Fists
		{
			"id": "fists",
			"name": "Fists",
			"category": ItemCategory.NONE,
			"damage": 1,
			"mining_strength": 1.0,
			"stack_size": 1
		},
		# Slot 1 (key 2): Stone Pickaxe
		{
			"id": "pickaxe_stone",
			"name": "Stone Pickaxe",
			"category": ItemCategory.TOOL,
			"damage": 2,
			"mining_strength": 1.5,
			"stack_size": 1
		},
		# Slot 2 (key 3): Axe
		{
			"id": "axe_stone",
			"name": "Stone Axe",
			"category": ItemCategory.TOOL,
			"damage": 3,
			"mining_strength": 0.5,
			"stack_size": 1
		},
		# Slot 3 (key 4): Water Bucket
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
			"stack_size": 64
		},
		# Slot 5 (key 6): Stone Block
		{
			"id": "block_cube",
			"name": "Stone Cube",
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
		# Slot 9 (key 0): Empty
		{
			"id": "empty",
			"name": "Empty",
			"category": ItemCategory.NONE,
			"damage": 0,
			"mining_strength": 0.0,
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

## Check if category triggers BUILD mode
static func is_build_category(category: ItemCategory) -> bool:
	return category in [ItemCategory.BLOCK, ItemCategory.OBJECT, ItemCategory.PROP]

## Check if category is a PLAY mode tool
static func is_play_category(category: ItemCategory) -> bool:
	return category in [ItemCategory.NONE, ItemCategory.TOOL, ItemCategory.BUCKET, ItemCategory.RESOURCE]
