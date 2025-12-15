extends Node
class_name ObjectRegistry
## Registry of all placeable objects with their properties

# Object definitions: ID -> { name, scene, size, etc }
# Size is in voxel units (1 unit = 1 block)
const OBJECTS = {
	1: {
		"name": "Cardboard Box",
		"scene": "res://models/objects/cardboard/1/cc0_free_cardboard_box.glb",
		"size": Vector3i(1, 1, 1),
	},
	2: {
		"name": "Long Crate",
		"scene": "res://objects/long_crate.tscn", 
		"size": Vector3i(2, 1, 1),
	},
	3: {
		"name": "Wooden Table",
		"scene": "res://models/objects/table/1/psx_wooden_table.tscn",
		"size": Vector3i(2, 1, 2),
	},
}

## Get object definition by ID
static func get_object(id: int) -> Dictionary:
	return OBJECTS.get(id, {})

## Get all object IDs
static func get_all_ids() -> Array:
	return OBJECTS.keys()

## Get rotated size based on 90-degree rotation (0, 1, 2, 3)
static func get_rotated_size(id: int, rotation: int) -> Vector3i:
	var obj = get_object(id)
	if obj.is_empty():
		return Vector3i(1, 1, 1)
	
	var size = obj.size
	# Rotation 0 and 2: no swap
	# Rotation 1 and 3: swap X and Z
	if rotation == 1 or rotation == 3:
		return Vector3i(size.z, size.y, size.x)
	return size

## Get all cells that would be occupied by this object at anchor position
static func get_occupied_cells(id: int, anchor: Vector3i, rotation: int) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var size = get_rotated_size(id, rotation)
	
	for x in range(size.x):
		for y in range(size.y):
			for z in range(size.z):
				cells.append(anchor + Vector3i(x, y, z))
	
	return cells
