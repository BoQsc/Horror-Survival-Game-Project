extends Node
class_name ObjectRegistry
## Registry of all placeable objects with their properties

# Object definitions: ID -> { name, scene, size, etc }
# Size is in voxel units (1 unit = 1 block)
const OBJECTS = {
	1: {
		"name": "Cardboard Box",
		"scene": "res://models/objects/cardboard/1/cc0_free_cardboard_box.tscn",
		"visual_mesh_root": "BoxModel",
		"visual_batch_mode": "proxy",
		"size": Vector3i(1, 1, 1),
		"material": "paper",
		"movable": true,
	},
	2: {
		"name": "Long Crate",
		"scene": "res://models/objects/crate/1/simple_long_crate.tscn", 
		"visual_mesh_root": "CrateModel",
		"visual_batch_mode": "proxy",
		"size": Vector3i(2, 1, 1),
		"material": "wood",
		"movable": true,
	},
	3: {
		"name": "Wooden Table",
		"scene": "res://models/objects/table/1/psx_wooden_table.tscn",
		"visual_mesh_root": "TableModel",
		"visual_batch_mode": "proxy",
		"size": Vector3i(2, 1, 1),
		"material": "wood",
		"movable": true,
	},
	4: {
		"name": "Door",
		"scene": "res://models/objects/interactive_door/interactive_door.tscn",
		"visual_mesh_root": "DoorModel",
		"visual_batch_mode": "proxy",
		"size": Vector3i(1, 2, 1),
		"material": "wood",
		"movable": false,
	},
	5: {
		"name": "Window",
		"scene": "res://models/objects/window/1/window.tscn",
		"visual_mesh_root": "WindowModel",
		# Windows stay visually correct by using the merged proxy mesh path.
		"visual_batch_mode": "proxy",
		"size": Vector3i(1, 1, 1),
		"material": "wood",
		"movable": false,
	},
	6: {
		"name": "Heavy Pistol",
		"scene": "res://models/pistol/heavy_pistol_physics.tscn",
		"visual_mesh_root": "Visuals",
		"visual_batch_mode": "proxy",
		"size": Vector3i(1, 1, 1), # Small prop, 1x1 footprint
		"material": "metal",
		"movable": true,
	},
	7: {
		"name": "Chair",
		"scene": "res://models/objects/chair/1/cc0_chair_8.tscn",
		"visual_mesh_root": "ChairModel",
		"visual_batch_mode": "proxy",
		"size": Vector3i(1, 1, 1),
		"material": "wood",
		"movable": false,
	},
}

# Batching is opt-in via `visual_batch_mode` on each object definition.
# Modes are intentionally conservative: only objects with batch-safe visuals
# should opt into `simple` or `proxy`.

const CONTAINER_INTERACTABLE_SCRIPT := preload("res://modules/world_player_v2/features/data_containers/container_interactable.gd")
const DOOR_PROXY_SHELL_SCRIPT := preload("res://world_building_system/door_proxy_shell.gd")
const PROP_PHYSICS_SETTLER_SCRIPT := preload("res://world_building_system/prop_physics_settler.gd")

# === PRELOADED SCENE CACHE ===
# Scenes are preloaded at startup so instantiation doesn't require disk reads
static var _preloaded_scenes: Dictionary = {}  # scene_path -> PackedScene
static var _preload_done: bool = false
static var _visual_data_cache: Dictionary = {} # scene_path -> { mesh, mesh_transform }
static var _authored_collision_cache: Dictionary = {} # scene_path -> bool
static var _occupied_cells_cache: Dictionary = {} # id:rotation -> Array[Vector3i]
static var _generic_collision_mesh_cache: Dictionary = {} # scene_path -> Array[{ path, mesh }]
static var _proxy_shell_box_shape_cache: Dictionary = {} # cache_key -> BoxShape3D
static var _proxy_shell_box_data_cache: Dictionary = {} # object_id -> { size, transform }
static var _simple_object_collision_data_cache: Dictionary = {} # object_id -> { shape, transform }

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
				var warmed_scene: Node = _preloaded_scenes[scene_path].instantiate()
				if warmed_scene:
					if warmed_scene.has_method("_ensure_cached_door_scene_paths"):
						var door_model := warmed_scene.get_node_or_null("DoorModel")
						if door_model:
							warmed_scene.call("_ensure_cached_door_scene_paths", door_model)
							warmed_scene.call("_resolve_animation_player", door_model)
					warmed_scene.free()
		if is_simple_visual_batch_object(int(id)) or is_proxy_visual_batch_object(int(id)):
			get_object_visual_data(int(id))
		if is_proxy_visual_batch_object(int(id)):
			_get_proxy_shell_box_data(int(id))
		if int(id) == 3 or int(id) == 5 or int(id) == 7:
			get_simple_object_collision_data(int(id))
		var has_authored_collision := get_object_has_authored_collision(int(id))
		if not has_authored_collision:
			get_object_collision_mesh_descriptors(int(id))
	
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
	var preferred_root_name := str(obj.get("visual_mesh_root", ""))
	var mesh_inst = _find_render_mesh_instance(instance, preferred_root_name)
	if preferred_root_name != "" and not mesh_inst:
		push_warning("[ObjectRegistry] No visible render mesh found for object %d (%s) under '%s'" % [
			object_id,
			str(obj.get("name", "Unknown")),
			preferred_root_name
		])
		if instance:
			instance.free()
		return {}
	if not mesh_inst or not mesh_inst.mesh:
		if instance:
			instance.free()
		return {}
	var mesh_instance_count := _count_visible_mesh_instances(instance)
	var data := {
		"mesh": mesh_inst.mesh,
		"mesh_transform": _get_scene_relative_transform(mesh_inst),
		"mesh_instance_count": mesh_instance_count,
		"is_single_mesh": mesh_instance_count == 1
	}
	var batch_mode := get_visual_batch_mode(object_id)
	var instance_root := instance as Node3D
	if batch_mode == "proxy" and mesh_instance_count > 1 and instance_root:
		var merged_visual_data := _build_merged_visual_mesh(instance_root)
		if not merged_visual_data.is_empty():
			data["mesh"] = merged_visual_data.get("mesh", null)
			data["mesh_transform"] = Transform3D.IDENTITY
			data["proxy_mesh_merged"] = true
			data["proxy_mesh_surface_count"] = int(merged_visual_data.get("surface_count", 0))
			data["proxy_mesh_source_surface_count"] = int(merged_visual_data.get("source_surface_count", 0))
		else:
			push_warning("[ObjectRegistry] Object %d (%s) is marked '%s' but its merged proxy mesh could not be built; batching is disabled for safety." % [
				object_id,
				str(obj.get("name", "Unknown")),
				batch_mode
			])
	elif batch_mode == "simple" and mesh_instance_count != 1:
		push_warning("[ObjectRegistry] Object %d (%s) is marked '%s' but has %d visible mesh instances; batching is disabled for safety." % [
			object_id,
			str(obj.get("name", "Unknown")),
			batch_mode,
			mesh_instance_count
		])
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

static func get_object_collision_mesh_descriptors(object_id: int) -> Array:
	var obj = get_object(object_id)
	if obj.is_empty():
		return []
	var scene_path = str(obj.get("scene", ""))
	if scene_path == "":
		return []
	if _generic_collision_mesh_cache.has(scene_path):
		return _generic_collision_mesh_cache[scene_path]
	var packed = get_preloaded_scene(scene_path)
	if not packed:
		_generic_collision_mesh_cache[scene_path] = []
		return []
	var instance = packed.instantiate()
	if not instance:
		_generic_collision_mesh_cache[scene_path] = []
		return []
	var descriptors: Array = []
	_collect_generic_collision_mesh_descriptors(instance, instance, descriptors)
	_generic_collision_mesh_cache[scene_path] = descriptors
	instance.free()
	return descriptors

static func get_visual_batch_mode(object_id: int) -> String:
	var obj = get_object(object_id)
	if obj.is_empty():
		return "none"

	var mode := str(obj.get("visual_batch_mode", "none")).to_lower()
	match mode:
		"simple", "proxy":
			return mode
		_:
			return "none"

static func _count_visible_mesh_instances(node: Node, ancestors_visible: bool = true) -> int:
	if not node:
		return 0

	var node_visible := ancestors_visible
	if node is Node3D:
		node_visible = ancestors_visible and (node as Node3D).visible

	var total := 1 if node is MeshInstance3D and node_visible else 0
	for child in node.get_children():
		total += _count_visible_mesh_instances(child, node_visible)
	return total

static func _collect_visible_mesh_instances(node: Node, ancestors_visible: bool, result: Array) -> void:
	if not node:
		return

	var node_visible := ancestors_visible
	if node is Node3D:
		node_visible = ancestors_visible and bool((node as Node3D).visible)

	if node is MeshInstance3D and node_visible:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh:
			result.append(mesh_inst)

	for child in node.get_children():
		_collect_visible_mesh_instances(child, node_visible, result)

static func _transform_visual_surface_arrays(arrays: Array, transform: Transform3D) -> Array:
	if arrays.is_empty():
		return []

	var transformed_arrays: Array = arrays.duplicate(true)
	var vertices: PackedVector3Array = transformed_arrays[Mesh.ARRAY_VERTEX]
	if vertices.is_empty():
		return []

	var transformed_vertices := PackedVector3Array()
	transformed_vertices.resize(vertices.size())
	for i in range(vertices.size()):
		transformed_vertices[i] = transform * vertices[i]
	transformed_arrays[Mesh.ARRAY_VERTEX] = transformed_vertices

	var normals: PackedVector3Array = transformed_arrays[Mesh.ARRAY_NORMAL]
	if not normals.is_empty():
		var normal_basis := transform.basis
		if absf(transform.basis.determinant()) > 0.000001:
			normal_basis = transform.basis.inverse().transposed()
		var transformed_normals := PackedVector3Array()
		transformed_normals.resize(normals.size())
		for i in range(normals.size()):
			transformed_normals[i] = (normal_basis * normals[i]).normalized()
		transformed_arrays[Mesh.ARRAY_NORMAL] = transformed_normals

	var tangents: PackedFloat32Array = transformed_arrays[Mesh.ARRAY_TANGENT]
	if not tangents.is_empty():
		var tangent_basis := transform.basis
		var transformed_tangents := PackedFloat32Array()
		transformed_tangents.resize(tangents.size())
		for i in range(0, tangents.size(), 4):
			var tangent := Vector3(tangents[i], tangents[i + 1], tangents[i + 2])
			tangent = tangent_basis * tangent
			tangent = tangent.normalized()
			transformed_tangents[i] = tangent.x
			transformed_tangents[i + 1] = tangent.y
			transformed_tangents[i + 2] = tangent.z
			transformed_tangents[i + 3] = tangents[i + 3]
		transformed_arrays[Mesh.ARRAY_TANGENT] = transformed_tangents

	return transformed_arrays

static func _mesh_array_slot_has_data(value: Variant) -> bool:
	match typeof(value):
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			return value.size() > 0
		_:
			return false

static func _surface_array_mask(arrays: Array) -> int:
	var mask := 0
	var slot_count := mini(arrays.size(), Mesh.ARRAY_MAX)
	for i in range(slot_count):
		if _mesh_array_slot_has_data(arrays[i]):
			mask |= 1 << i
	return mask

static func _surface_material_key(material: Material) -> String:
	if material == null:
		return "<null>"
	if not material.resource_path.is_empty():
		return material.resource_path
	return str(material.get_instance_id())

static func _empty_packed_array_like(value: Variant) -> Variant:
	match typeof(value):
		TYPE_PACKED_BYTE_ARRAY:
			return PackedByteArray()
		TYPE_PACKED_INT32_ARRAY:
			return PackedInt32Array()
		TYPE_PACKED_FLOAT32_ARRAY:
			return PackedFloat32Array()
		TYPE_PACKED_VECTOR2_ARRAY:
			return PackedVector2Array()
		TYPE_PACKED_VECTOR3_ARRAY:
			return PackedVector3Array()
		TYPE_PACKED_COLOR_ARRAY:
			return PackedColorArray()
		TYPE_PACKED_VECTOR4_ARRAY:
			return PackedVector4Array()
		_:
			return null

static func _empty_surface_arrays_like(source: Array) -> Array:
	var result: Array = []
	result.resize(Mesh.ARRAY_MAX)
	var slot_count := mini(source.size(), Mesh.ARRAY_MAX)
	for i in range(slot_count):
		if _mesh_array_slot_has_data(source[i]):
			result[i] = _empty_packed_array_like(source[i])
	return result

static func _append_mesh_array(dst: Variant, src: Variant) -> Variant:
	match typeof(src):
		TYPE_PACKED_BYTE_ARRAY:
			var out_bytes: PackedByteArray = dst
			out_bytes.append_array(src)
			return out_bytes
		TYPE_PACKED_INT32_ARRAY:
			var out_i32: PackedInt32Array = dst
			out_i32.append_array(src)
			return out_i32
		TYPE_PACKED_FLOAT32_ARRAY:
			var out_f32: PackedFloat32Array = dst
			out_f32.append_array(src)
			return out_f32
		TYPE_PACKED_VECTOR2_ARRAY:
			var out_v2: PackedVector2Array = dst
			out_v2.append_array(src)
			return out_v2
		TYPE_PACKED_VECTOR3_ARRAY:
			var out_v3: PackedVector3Array = dst
			out_v3.append_array(src)
			return out_v3
		TYPE_PACKED_COLOR_ARRAY:
			var out_color: PackedColorArray = dst
			out_color.append_array(src)
			return out_color
		TYPE_PACKED_VECTOR4_ARRAY:
			var out_v4: PackedVector4Array = dst
			out_v4.append_array(src)
			return out_v4
		_:
			return dst

static func _adjust_surface_indices(arrays: Array, vertex_offset: int) -> Array:
	if arrays.size() <= Mesh.ARRAY_INDEX:
		return arrays
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if indices.is_empty() or vertex_offset == 0:
		return arrays
	var adjusted := PackedInt32Array()
	adjusted.resize(indices.size())
	for i in range(indices.size()):
		adjusted[i] = indices[i] + vertex_offset
	arrays[Mesh.ARRAY_INDEX] = adjusted
	return arrays

static func _append_surface_to_group(group: Dictionary, surface_arrays: Array) -> void:
	var group_arrays: Array = group.get("arrays", [])
	var vertices: PackedVector3Array = group_arrays[Mesh.ARRAY_VERTEX]
	var vertex_offset := vertices.size()
	var adjusted_arrays := _adjust_surface_indices(surface_arrays.duplicate(true), vertex_offset)
	var slot_count := mini(adjusted_arrays.size(), Mesh.ARRAY_MAX)

	for i in range(slot_count):
		var src: Variant = adjusted_arrays[i]
		if not _mesh_array_slot_has_data(src):
			continue
		var dst: Variant = group_arrays[i]
		group_arrays[i] = _append_mesh_array(dst, src)

	group["arrays"] = group_arrays
	group["source_surface_count"] = int(group.get("source_surface_count", 0)) + 1

static func _build_merged_visual_mesh(root: Node3D) -> Dictionary:
	if not root:
		return {}

	var mesh_instances: Array = []
	_collect_visible_mesh_instances(root, true, mesh_instances)
	if mesh_instances.is_empty():
		return {}

	var merged_mesh := ArrayMesh.new()
	var surface_groups: Dictionary = {}
	var surface_group_order: Array[String] = []
	var source_surface_count := 0
	for mesh_inst_variant in mesh_instances:
		if typeof(mesh_inst_variant) != TYPE_OBJECT:
			continue
		var mesh_inst := mesh_inst_variant as MeshInstance3D
		if not mesh_inst or not mesh_inst.mesh:
			continue

		var mesh_transform := _get_scene_relative_transform(mesh_inst)
		for surface_idx in range(mesh_inst.mesh.get_surface_count()):
			var arrays: Array = mesh_inst.mesh.surface_get_arrays(surface_idx)
			var transformed_arrays := _transform_visual_surface_arrays(arrays, mesh_transform)
			if transformed_arrays.is_empty():
				continue

			var primitive_type: int = mesh_inst.mesh.surface_get_primitive_type(surface_idx)
			var material := mesh_inst.mesh.surface_get_material(surface_idx)
			var array_mask := _surface_array_mask(transformed_arrays)
			var group_key := "%d|%d|%s" % [primitive_type, array_mask, _surface_material_key(material)]
			if not surface_groups.has(group_key):
				surface_groups[group_key] = {
					"arrays": _empty_surface_arrays_like(transformed_arrays),
					"material": material,
					"primitive_type": primitive_type,
					"source_surface_count": 0
				}
				surface_group_order.append(group_key)
			_append_surface_to_group(surface_groups[group_key], transformed_arrays)
			source_surface_count += 1

	for group_key in surface_group_order:
		var group: Dictionary = surface_groups[group_key]
		var group_arrays: Array = group.get("arrays", [])
		if group_arrays.is_empty():
			continue
		merged_mesh.add_surface_from_arrays(int(group.get("primitive_type", Mesh.PRIMITIVE_TRIANGLES)), group_arrays)
		var material: Material = group.get("material", null)
		if material:
			merged_mesh.surface_set_material(merged_mesh.get_surface_count() - 1, material)

	var surface_count := merged_mesh.get_surface_count()
	if surface_count == 0:
		return {}

	return {
		"mesh": merged_mesh,
		"mesh_instance_count": mesh_instances.size(),
		"surface_count": surface_count,
		"source_surface_count": source_surface_count,
		"proxy_mesh_merged": true
	}

static func is_visual_batch_safe(object_id: int) -> bool:
	var mode := get_visual_batch_mode(object_id)
	if mode == "none":
		return false

	var visual_data := get_object_visual_data(object_id)
	if visual_data.is_empty():
		return false

	if mode == "simple":
		return int(visual_data.get("mesh_instance_count", 0)) == 1
	return bool(visual_data.get("proxy_mesh_merged", false)) or int(visual_data.get("mesh_instance_count", 0)) == 1

static func is_simple_visual_batch_object(object_id: int) -> bool:
	return get_visual_batch_mode(object_id) == "simple" and is_visual_batch_safe(object_id)

static func is_proxy_visual_batch_object(object_id: int) -> bool:
	return get_visual_batch_mode(object_id) == "proxy" and is_visual_batch_safe(object_id)

static func _find_render_mesh_instance(root: Node, preferred_root_name: String = "") -> MeshInstance3D:
	if not root:
		return null

	if preferred_root_name != "":
		var preferred_root := root.find_child(preferred_root_name, true, false)
		if not preferred_root:
			return null
		return _find_first_visible_mesh_instance(preferred_root)

	return _find_first_visible_mesh_instance(root)

static func create_proxy_gameplay_shell(object_id: int, world_map_mode: bool = false) -> Node3D:
	if not is_proxy_visual_batch_object(object_id):
		return null
	match object_id:
		1:
			return _create_container_shell(
				"CardboardBoxShell",
				6,
				"Cardboard Box",
				Vector3(0.7589844, 0.48020607, 0.6033878),
				Transform3D(Basis.IDENTITY, Vector3(-0.016992182, 0.23745339, -0.0048420727))
			)
		2:
			return _create_container_shell(
				"LongCrateShell",
				12,
				"Long Crate",
				Vector3(1.8, 0.7, 0.8),
				Transform3D(Basis.IDENTITY, Vector3(0.0, 0.35, 0.0))
			)
		3:
			return _create_visual_box_proxy_shell("WoodenTableShell", object_id)
		4:
			return _create_door_proxy_shell()
		5:
			return _create_visual_box_proxy_shell("WindowShell", object_id)
		6:
			return _create_pistol_shell(world_map_mode)
		7:
			return _create_visual_box_proxy_shell("ChairShell", object_id)
	return null

static func _get_proxy_shell_box_data(object_id: int) -> Dictionary:
	if _proxy_shell_box_data_cache.has(object_id):
		return _proxy_shell_box_data_cache[object_id]

	var visual_data := get_object_visual_data(object_id)
	if visual_data.is_empty():
		return {}

	var mesh: Mesh = visual_data.get("mesh")
	if not mesh:
		return {}

	var mesh_transform: Transform3D = visual_data.get("mesh_transform", Transform3D.IDENTITY)
	var aabb := mesh.get_aabb()
	var box_size := Vector3(
		maxf(aabb.size.x, 0.05),
		maxf(aabb.size.y, 0.05),
		maxf(aabb.size.z, 0.05)
	)
	var box_transform := mesh_transform * Transform3D(Basis.IDENTITY, aabb.position + (aabb.size * 0.5))
	var data := {
		"size": box_size,
		"transform": box_transform
	}
	_proxy_shell_box_data_cache[object_id] = data
	return data

static func get_simple_object_collision_data(object_id: int) -> Dictionary:
	if _simple_object_collision_data_cache.has(object_id):
		return _simple_object_collision_data_cache[object_id]

	var visual_data := get_object_visual_data(object_id)
	if visual_data.is_empty():
		return {}

	var mesh: Mesh = visual_data.get("mesh")
	if not mesh:
		return {}

	var mesh_transform: Transform3D = visual_data.get("mesh_transform", Transform3D.IDENTITY)
	var aabb := mesh.get_aabb()
	var box_size := Vector3(
		maxf(aabb.size.x, 0.05),
		maxf(aabb.size.y, 0.05),
		maxf(aabb.size.z, 0.05)
	)
	var data := {
		"shape": _get_cached_box_shape("simple_visual:%d" % object_id, box_size),
		"transform": mesh_transform * Transform3D(Basis.IDENTITY, aabb.position + (aabb.size * 0.5))
	}
	_simple_object_collision_data_cache[object_id] = data
	return data

static func _get_cached_box_shape(cache_key: String, box_size: Vector3) -> BoxShape3D:
	if _proxy_shell_box_shape_cache.has(cache_key):
		return _proxy_shell_box_shape_cache[cache_key]

	var box_shape := BoxShape3D.new()
	box_shape.size = box_size
	_proxy_shell_box_shape_cache[cache_key] = box_shape
	return box_shape

static func _create_container_shell(
	node_name: String,
	slot_count: int,
	container_name: String,
	box_size: Vector3,
	collision_transform: Transform3D = Transform3D.IDENTITY
) -> StaticBody3D:
	var shell := CONTAINER_INTERACTABLE_SCRIPT.new() as StaticBody3D
	if not shell:
		return null
	shell.name = node_name
	if shell.has_method("set"):
		shell.set("slot_count", slot_count)
		shell.set("container_name", container_name)
	shell.add_to_group("objects")
	var collision := CollisionShape3D.new()
	collision.shape = _get_cached_box_shape("container:%s:%s" % [container_name, str(box_size)], box_size)
	collision.transform = collision_transform
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
	if world_map_mode:
		shell.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		shell.freeze = true
		shell.sleeping = true
		shell.can_sleep = false
		shell.continuous_cd = false
		shell.set_physics_process(false)
	var collision := CollisionShape3D.new()
	collision.shape = _get_cached_box_shape("pistol", Vector3(0.2, 0.15, 0.05))
	shell.add_child(collision)
	return shell

static func _create_door_proxy_shell() -> StaticBody3D:
	var shell := DOOR_PROXY_SHELL_SCRIPT.new() as StaticBody3D
	if not shell:
		return null
	shell.name = "DoorProxyShell"
	shell.collision_layer = 4
	shell.collision_mask = 0
	shell.add_to_group("objects")
	shell.add_to_group("interactable")
	shell.add_to_group("breakable")

	var box_size := Vector3(0.9, 2.0, 0.2)
	var box_transform := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	var box_data := _get_proxy_shell_box_data(4)
	if not box_data.is_empty():
		box_size = box_data.get("size", box_size)
		box_transform = box_data.get("transform", box_transform)

	var collision := CollisionShape3D.new()
	collision.shape = _get_cached_box_shape("door_proxy", box_size)
	collision.transform = box_transform
	shell.add_child(collision)
	return shell

static func _create_visual_box_proxy_shell(node_name: String, object_id: int) -> StaticBody3D:
	var shell := StaticBody3D.new()
	if not shell:
		return null
	shell.name = node_name
	shell.collision_layer = 4
	shell.collision_mask = 0
	shell.add_to_group("objects")

	var box_size := Vector3.ONE
	var box_transform := Transform3D.IDENTITY
	var box_data := _get_proxy_shell_box_data(object_id)
	if not box_data.is_empty():
		box_size = box_data.get("size", box_size)
		box_transform = box_data.get("transform", box_transform)

	var collision := CollisionShape3D.new()
	collision.shape = _get_cached_box_shape("visual_box:%d" % object_id, box_size)
	collision.transform = box_transform
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

static func _find_first_visible_mesh_instance(node: Node, ancestors_visible: bool = true) -> MeshInstance3D:
	if not node or not ancestors_visible:
		return null

	var node_visible := ancestors_visible
	if node is Node3D:
		node_visible = node_visible and bool((node as Node3D).visible)

	if node is MeshInstance3D and node_visible:
		return node

	for child in node.get_children():
		var nested := _find_first_visible_mesh_instance(child, node_visible)
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

static func _collect_generic_collision_mesh_descriptors(node: Node, root: Node, descriptors: Array) -> void:
	if not node or node.is_in_group("interactable"):
		return
	for child in node.get_children():
		if child is MeshInstance3D:
			var mesh_inst := child as MeshInstance3D
			if mesh_inst.mesh:
				descriptors.append({
					"path": root.get_path_to(mesh_inst),
					"mesh": mesh_inst.mesh
				})
		if child is Node3D:
			_collect_generic_collision_mesh_descriptors(child, root, descriptors)
