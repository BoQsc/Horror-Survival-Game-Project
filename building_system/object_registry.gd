extends Node
class_name ObjectRegistry
## Registry of all placeable objects with their properties

# Object definitions: ID -> { name, scene, size, etc }
# Size is in voxel units (1 unit = 1 block)
const OBJECTS = {
	1: {
		"name": "Cardboard Box",
		"scene": "res://models/objects/cardboard/1/cc0_free_cardboard_box.tscn",
		"size": Vector3i(1, 1, 1),
	},
	2: {
		"name": "Long Crate",
		"scene": "res://models/objects/crate/1/simple_long_crate.tscn", 
		"size": Vector3i(2, 1, 1),
	},
	3: {
		"name": "Wooden Table",
		"scene": "res://models/objects/table/1/psx_wooden_table.tscn",
		"size": Vector3i(2, 1, 1),
	},
	4: {
		"name": "Door",
		"scene": "res://models/objects/interactive_door/interactive_door.tscn",
		"size": Vector3i(1, 2, 1),
	},
	5: {
		"name": "Window",
		"scene": "res://models/objects/window/1/window.tscn",
		"size": Vector3i(1, 1, 1),
	},
	6: {
		"name": "Heavy Pistol",
		"scene": "res://models/pistol/heavy_pistol_physics.tscn",
		"size": Vector3i(1, 1, 1), # Small prop, 1x1 footprint
	},
}

# === PRELOADED SCENE CACHE ===
# Scenes are preloaded at startup so instantiation doesn't require disk reads
static var _preloaded_scenes: Dictionary = {}  # scene_path -> PackedScene
static var _preload_done: bool = false

## Preload all object scenes (call at game startup for faster spawning)
static func preload_all_scenes() -> void:
	if _preload_done:
		return
	
	print("[ObjectRegistry] Preloading %d object scenes..." % OBJECTS.size())
	var start_time = Time.get_ticks_msec()
	
	for id in OBJECTS:
		var obj = OBJECTS[id]
		var scene_path = obj.get("scene", "")
		if scene_path != "" and not _preloaded_scenes.has(scene_path):
			if ResourceLoader.exists(scene_path):
				_preloaded_scenes[scene_path] = load(scene_path)
	
	var elapsed = Time.get_ticks_msec() - start_time
	print("[ObjectRegistry] Preloaded %d scenes in %dms" % [_preloaded_scenes.size(), elapsed])
	_preload_done = true

## Get a preloaded scene (returns null if not preloaded)
static func get_preloaded_scene(scene_path: String) -> PackedScene:
	if _preloaded_scenes.has(scene_path):
		return _preloaded_scenes[scene_path]
	
	# Fallback: load on demand (slower, but works)
	if ResourceLoader.exists(scene_path):
		var packed = load(scene_path) as PackedScene
		_preloaded_scenes[scene_path] = packed  # Cache for next time
		return packed
	
	return null

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
