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
		"material": "paper",
		"movable": true,
	},
	2: {
		"name": "Long Crate",
		"scene": "res://models/objects/crate/1/simple_long_crate.tscn", 
		"size": Vector3i(2, 1, 1),
		"material": "wood",
		"movable": true,
	},
	3: {
		"name": "Wooden Table",
		"scene": "res://models/objects/table/1/psx_wooden_table.tscn",
		"size": Vector3i(2, 1, 1),
		"material": "wood",
		"movable": true,
	},
	4: {
		"name": "Door",
		"scene": "res://models/objects/interactive_door/interactive_door.tscn",
		"size": Vector3i(1, 2, 1),
		"material": "wood",
		"movable": false,
	},
	5: {
		"name": "Window",
		"scene": "res://models/objects/window/1/window.tscn",
		"size": Vector3i(1, 1, 1),
		"material": "wood",
		"movable": false,
	},
	6: {
		"name": "Heavy Pistol",
		"scene": "res://models/pistol/heavy_pistol_physics.tscn",
		"size": Vector3i(1, 1, 1), # Small prop, 1x1 footprint
		"material": "metal",
		"movable": true,
	},
	7: {
		"name": "Chair",
		"scene": "res://models/objects/chair/1/cc0_chair_8.tscn",
		"size": Vector3i(1, 1, 1),
		"material": "wood",
		"movable": false,
	},
}

const SIMPLE_VISUAL_BATCH_OBJECT_IDS := {
}

const PROXY_VISUAL_BATCH_OBJECT_IDS := {
}

const CONTAINER_INTERACTABLE_SCRIPT := preload("res://modules/world_player_v2/features/data_containers/container_interactable.gd")
const PROP_PHYSICS_SETTLER_SCRIPT := preload("res://world_building_system/prop_physics_settler.gd")

# === PRELOADED SCENE CACHE ===
# Scenes are preloaded at startup so instantiation doesn't require disk reads
static var _preloaded_scenes: Dictionary = {}  # scene_path -> PackedScene
static var _preload_done: bool = false
static var _visual_data_cache: Dictionary = {} # scene_path -> { mesh, mesh_transform }
static var _authored_collision_cache: Dictionary = {} # scene_path -> bool
static var _occupied_cells_cache: Dictionary = {} # id:rotation -> Array[Vector3i]

## Preload all object scenes (call at game startup for faster spawning)
static func preload_all_scenes() -> void:
	if _preload_done:
		return
	
	var start_time = Time.get_ticks_msec()
	
	for id in OBJECTS:
		var obj = OBJECTS[id]
		var scene_path = obj.get("scene", "")
		if scene_path != "" and not _preloaded_scenes.has(scene_path):
			if ResourceLoader.exists(scene_path):
				_preloaded_scenes[scene_path] = load(scene_path)
		if is_simple_visual_batch_object(int(id)):
			get_object_visual_data(int(id))
		get_object_has_authored_collision(int(id))
	
	var elapsed = Time.get_ticks_msec() - start_time
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

static func get_object_visual_data(object_id: int) -> Dictionary:
	var obj = get_object(object_id)
	if obj.is_empty():
		return {}
	var scene_path = str(obj.get("scene", ""))
	if scene_path == "":
		return {}
	if _visual_data_cache.has(scene_path):
		return _visual_data_cache[scene_path]
	var packed = get_preloaded_scene(scene_path)
	if not packed:
		return {}
	var instance = packed.instantiate()
	var mesh_inst = _find_first_mesh_instance(instance)
	if not mesh_inst or not mesh_inst.mesh:
		if instance:
			instance.free()
		return {}
	var data := {
		"mesh": mesh_inst.mesh,
		"mesh_transform": _get_scene_relative_transform(mesh_inst)
	}
	_visual_data_cache[scene_path] = data
	if instance:
		instance.free()
	return data

static func get_object_has_authored_collision(object_id: int) -> bool:
	var obj = get_object(object_id)
	if obj.is_empty():
		return false
	var scene_path = str(obj.get("scene", ""))
	if scene_path == "":
		return false
	if _authored_collision_cache.has(scene_path):
		return bool(_authored_collision_cache[scene_path])
	var packed = get_preloaded_scene(scene_path)
	if not packed:
		return false
	var instance = packed.instantiate()
	if not instance:
		_authored_collision_cache[scene_path] = false
		return false
	var has_collision := _scene_has_authored_collision(instance)
	_authored_collision_cache[scene_path] = has_collision
	if instance:
		instance.free()
	return has_collision

static func is_simple_visual_batch_object(object_id: int) -> bool:
	return SIMPLE_VISUAL_BATCH_OBJECT_IDS.has(object_id)

static func is_proxy_visual_batch_object(object_id: int) -> bool:
	return PROXY_VISUAL_BATCH_OBJECT_IDS.has(object_id)

static func create_proxy_gameplay_shell(object_id: int, world_map_mode: bool = false) -> Node3D:
	match object_id:
		1:
			return _create_container_shell("CardboardBoxShell", 6, "Cardboard Box", Vector3(0.8, 0.7, 0.8))
		2:
			return _create_container_shell("LongCrateShell", 12, "Long Crate", Vector3(1.8, 0.7, 0.8))
		6:
			return _create_pistol_shell(world_map_mode)
	return null

static func _create_container_shell(node_name: String, slot_count: int, container_name: String, box_size: Vector3) -> StaticBody3D:
	var shell := CONTAINER_INTERACTABLE_SCRIPT.new() as StaticBody3D
	if not shell:
		return null
	shell.name = node_name
	if shell.has_method("set"):
		shell.set("slot_count", slot_count)
		shell.set("container_name", container_name)
	shell.add_to_group("objects")
	var collision := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box_size
	collision.shape = box_shape
	shell.add_child(collision)
	return shell

static func _create_pistol_shell(world_map_mode: bool = false) -> RigidBody3D:
	var shell := PROP_PHYSICS_SETTLER_SCRIPT.new() as RigidBody3D
	if not shell:
		return null
	shell.name = "HeavyPistolPhysicsShell"
	shell.add_to_group("interactable")
	if shell.has_method("set"):
		shell.set("world_map_mode", world_map_mode)
	var collision := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(0.2, 0.15, 0.05)
	collision.shape = box_shape
	shell.add_child(collision)
	return shell

## Get object definition by ID
static func get_object(id: int) -> Dictionary:
	return OBJECTS.get(id, {})

static func is_movable_object(id: int) -> bool:
	var obj = get_object(id)
	if obj.is_empty():
		return false
	return bool(obj.get("movable", false))

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
	var cache_key := "%d:%d" % [id, rotation]
	var local_cells: Array[Vector3i]
	if _occupied_cells_cache.has(cache_key):
		local_cells = _occupied_cells_cache[cache_key]
	else:
		local_cells = []
		var size = get_rotated_size(id, rotation)
		for x in range(size.x):
			for y in range(size.y):
				for z in range(size.z):
					local_cells.append(Vector3i(x, y, z))
		_occupied_cells_cache[cache_key] = local_cells

	if anchor == Vector3i.ZERO:
		return local_cells

	var cells: Array[Vector3i] = []
	cells.resize(local_cells.size())
	for i in range(local_cells.size()):
		cells[i] = local_cells[i] + anchor
	return cells

static func _find_first_mesh_instance(node: Node) -> MeshInstance3D:
	for child in node.get_children():
		if child is MeshInstance3D:
			return child
		if child is Node:
			var nested := _find_first_mesh_instance(child)
			if nested:
				return nested
	return null

static func _get_scene_relative_transform(node: Node3D) -> Transform3D:
	var transform := Transform3D.IDENTITY
	var current: Node = node
	while current and current is Node3D:
		transform = (current as Node3D).transform * transform
		current = current.get_parent()
	return transform

static func _scene_has_authored_collision(node: Node) -> bool:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		return true
	for child in node.get_children():
		if _scene_has_authored_collision(child):
			return true
	return false
