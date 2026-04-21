extends Node3D
class_name BuildingChunk

# Constants
const SIZE = 16

# Data
var chunk_coord: Vector3i
var voxel_bytes: PackedByteArray # Block IDs (0 = air, 1-127 = blocks, 128+ reserved for object markers)
var voxel_meta: PackedByteArray # Rotation/Meta
var is_empty: bool = true

# Object storage (separate from voxels for multi-cell objects)
var objects: Dictionary = {} # Vector3i (local anchor) -> { object_id: int, rotation: int }
var occupied_by_object: Dictionary = {} # Vector3i (any local cell) -> Vector3i (anchor pos)
var object_nodes: Dictionary = {} # Vector3i (local anchor) -> Node3D (visual instance)
var object_collision_nodes: Dictionary = {} # Vector3i (local anchor) -> Node3D (simple collision holder)
var simple_visual_instances: Dictionary = {} # Vector3i (local anchor) -> { object_id, rotation, fractional_pos }
var simple_visual_batch_entries: Dictionary = {} # int object_id -> Array[{ anchor, transform }]
var simple_visual_batch_nodes: Dictionary = {} # int object_id -> MultiMeshInstance3D
var _has_deferred_runtime_visuals: bool = false
var _runtime_nodes_ready: bool = false
var _runtime_visuals_activated: bool = false
var _last_snapshot_mesh_surface_count: int = -1
var _last_snapshot_collision_box_count: int = -1
var _last_runtime_mesh_surface_count: int = -1
var _last_runtime_mesh_visible: bool = false
var mesh_dirty: bool = true

# Visuals
var mesh_instance: MeshInstance3D
var static_body: StaticBody3D
var prop_collision_body: StaticBody3D
var collision_shape: CollisionShape3D
var _pending_mesh_apply: Dictionary = {}
var _applied_collision_boxes: Array = []
var baked_snapshot_loaded: bool = false
var baked_snapshot_chunk_coord: Vector3i = Vector3i(-2147483648, -2147483648, -2147483648)

# Mesher Reference (injected by Manager)
var mesher: Node # BuildingMesher
var manager: Node # BuildingManager

static var _object_collision_shape_cache: Dictionary = {}
static var _box_collision_shape_cache: Dictionary = {}
const BuildingVisuals = preload("res://world_building_system/building_visuals.gd")
const BuildingBakeSnapshot = preload("res://world_building_system/building_bake_snapshot.gd")
const SIMPLE_OBJECT_COLLISION_IDS := {}

func _get_cached_object_collision_shape(mesh: Mesh) -> Shape3D:
	if not mesh:
		return null

	var cache_key := mesh.get_instance_id()
	if _object_collision_shape_cache.has(cache_key):
		return _object_collision_shape_cache[cache_key]

	var shape := _build_native_trimesh_collision_shape(mesh)
	if shape:
		_object_collision_shape_cache[cache_key] = shape
	return shape

func _build_native_trimesh_collision_shape(mesh: Mesh) -> Shape3D:
	if not mesh:
		return null
	if not is_instance_valid(mesher) or not mesher.has_method("build_trimesh_collision_shape_from_faces"):
		push_error("BuildingChunk: MeshBuilder.build_trimesh_collision_shape_from_faces() is required.")
		return null
	var faces := mesh.get_faces()
	if faces.is_empty():
		return null
	return mesher.build_trimesh_collision_shape_from_faces(faces)

static func _get_cached_box_shape(size: Vector3i) -> BoxShape3D:
	var cache_key := "%d_%d_%d" % [size.x, size.y, size.z]
	if _box_collision_shape_cache.has(cache_key):
		return _box_collision_shape_cache[cache_key]

	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(float(size.x), float(size.y), float(size.z))
	_box_collision_shape_cache[cache_key] = box_shape
	return box_shape

func _get_world_visual_batch_anchor(local_anchor: Vector3i, source_chunk_coord: Vector3i) -> Vector3i:
	return Vector3i(
		source_chunk_coord.x * SIZE + local_anchor.x,
		source_chunk_coord.y * SIZE + local_anchor.y,
		source_chunk_coord.z * SIZE + local_anchor.z
	)

func _init(coord: Vector3i):
	chunk_coord = coord
	# Resize and init with 0 (Air)
	voxel_bytes.resize(SIZE * SIZE * SIZE)
	voxel_bytes.fill(0)
	voxel_meta.resize(SIZE * SIZE * SIZE)
	voxel_meta.fill(0)

## Reset chunk for pool reuse - clears data without reallocating arrays
func reset(new_coord: Vector3i):
	var previous_chunk_coord := chunk_coord
	chunk_coord = new_coord
	voxel_bytes.fill(0) # Clear all voxels to air
	voxel_meta.fill(0) # Clear all metadata
	is_empty = true
	mesh_dirty = true
	baked_snapshot_loaded = false
	baked_snapshot_chunk_coord = Vector3i(-2147483648, -2147483648, -2147483648)
	_pending_mesh_apply.clear()
	_runtime_visuals_activated = false
	_last_snapshot_mesh_surface_count = -1
	_last_snapshot_collision_box_count = -1
	_last_runtime_mesh_surface_count = -1
	_last_runtime_mesh_visible = false
	_clear_object_runtime_state(previous_chunk_coord)

func _ensure_runtime_nodes() -> void:
	if static_body and is_instance_valid(static_body) and prop_collision_body and is_instance_valid(prop_collision_body) and mesh_instance and is_instance_valid(mesh_instance) and collision_shape and is_instance_valid(collision_shape):
		_runtime_nodes_ready = true
		if not _pending_mesh_apply.is_empty():
			var pending := _pending_mesh_apply
			_pending_mesh_apply = {}
			apply_mesh(
				pending.get("arrays", []),
				pending.get("shape", null),
				pending.get("source_mesh", null),
				pending.get("collision_boxes", [])
			)
		return

	static_body = StaticBody3D.new()
	static_body.collision_layer = 1 + 512
	add_child(static_body)

	mesh_instance = MeshInstance3D.new()
	static_body.add_child(mesh_instance)

	collision_shape = CollisionShape3D.new()
	static_body.add_child(collision_shape)

	prop_collision_body = StaticBody3D.new()
	prop_collision_body.name = "PropCollisionBody"
	prop_collision_body.collision_layer = static_body.collision_layer
	prop_collision_body.collision_mask = static_body.collision_mask
	add_child(prop_collision_body)
	_runtime_nodes_ready = true

	if not _pending_mesh_apply.is_empty():
		var pending := _pending_mesh_apply
		_pending_mesh_apply = {}
		apply_mesh(
			pending.get("arrays", []),
			pending.get("shape", null),
			pending.get("source_mesh", null),
			pending.get("collision_boxes", [])
		)

func activate_runtime_visuals(defer_collision: bool = true) -> void:
	if _runtime_visuals_activated:
		return
	_runtime_visuals_activated = true
	_ensure_runtime_nodes()
	if baked_snapshot_loaded or not objects.is_empty() or not simple_visual_instances.is_empty() or not _pending_mesh_apply.is_empty():
		restore_object_visuals(defer_collision)

func _ready():
	add_to_group("building_chunks")
	if not _runtime_visuals_activated and (baked_snapshot_loaded or not objects.is_empty() or not _pending_mesh_apply.is_empty()):
		activate_runtime_visuals(false)

func get_voxel(local_pos: Vector3i) -> int:
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return 0
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return 0
	
	var idx = _get_index(local_pos)
	return voxel_bytes.decode_u8(idx)

func get_voxel_meta(local_pos: Vector3i) -> int:
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return 0
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return 0
	
	var idx = _get_index(local_pos)
	return voxel_meta.decode_u8(idx)

func set_voxel(local_pos: Vector3i, value: int, meta: int = 0):
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return
	
	var idx = _get_index(local_pos)
	voxel_bytes.encode_u8(idx, value)
	voxel_meta.encode_u8(idx, meta)
	
	if value > 0:
		is_empty = false

## Apply a pre-grouped batch of voxel writes for a single chunk.
## The caller is expected to provide chunk-local positions that are already in bounds.
func apply_voxel_batch(local_blocks: Array) -> void:
	if local_blocks.is_empty():
		return

	for block_data in local_blocks:
		var local_pos: Vector3i = block_data.get("local_pos", Vector3i.ZERO)
		var idx := _get_index(local_pos)
		voxel_bytes.encode_u8(idx, int(block_data.get("type", 0)))
		voxel_meta.encode_u8(idx, int(block_data.get("meta", 0)))

	is_empty = false

## Apply a packed voxel batch using chunk-local voxel indices.
## This is the faster town/world-map path because it avoids per-block dictionaries.
func apply_voxel_batch_indices(local_indices: PackedInt32Array, block_types: PackedByteArray, block_metas: PackedByteArray) -> void:
	var count: int = min(local_indices.size(), min(block_types.size(), block_metas.size()))
	if count <= 0:
		return

	for i in range(count):
		var idx: int = local_indices[i]
		voxel_bytes.encode_u8(idx, int(block_types[i]))
		voxel_meta.encode_u8(idx, int(block_metas[i]))

	is_empty = false

func _should_batch_simple_visual(object_id: int) -> bool:
	return manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled() and not ("skip_building_visual_batches_for_test" in manager and manager.skip_building_visual_batches_for_test) and ObjectRegistry.is_simple_visual_batch_object(object_id)

func _should_batch_proxy_visual(object_id: int) -> bool:
	return manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled() and not ("skip_building_visual_batches_for_test" in manager and manager.skip_building_visual_batches_for_test) and ObjectRegistry.is_proxy_visual_batch_object(object_id)

func _build_simple_visual_transform(local_anchor: Vector3i, object_id: int, rotation: int, fractional_pos: Vector3, mesh_transform: Transform3D) -> Transform3D:
	var original_size = ObjectRegistry.get_object(object_id).get("size", Vector3i(1, 1, 1))
	var offset_x = float(original_size.x) / 2.0
	var offset_z = float(original_size.z) / 2.0
	if rotation == 1 or rotation == 3:
		var temp = offset_x
		offset_x = offset_z
		offset_z = temp
	var base_pos = Vector3(local_anchor.x + offset_x, local_anchor.y, local_anchor.z + offset_z) + fractional_pos
	var root_transform := Transform3D(Basis.from_euler(Vector3(0.0, deg_to_rad(rotation * 90), 0.0)), base_pos)
	return root_transform * mesh_transform

func _get_simple_visual_batch_node(object_id: int, mesh: Mesh) -> MultiMeshInstance3D:
	if simple_visual_batch_nodes.has(object_id):
		var existing: MultiMeshInstance3D = simple_visual_batch_nodes[object_id]
		if existing and is_instance_valid(existing):
			existing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			return existing

	var batch_node := MultiMeshInstance3D.new()
	batch_node.name = "SimpleVisualBatch_%d" % object_id
	batch_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(batch_node)
	simple_visual_batch_nodes[object_id] = batch_node

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = 0
	batch_node.multimesh = multimesh
	return batch_node

func _append_simple_visual_batch_instance(object_id: int, local_anchor: Vector3i, transform: Transform3D, mesh: Mesh) -> void:
	var entries: Array = simple_visual_batch_entries.get(object_id, [])
	entries.append({
		"anchor": local_anchor,
		"transform": transform
	})
	simple_visual_batch_entries[object_id] = entries

	var batch_node := _get_simple_visual_batch_node(object_id, mesh)
	var multimesh: MultiMesh = batch_node.multimesh
	if not multimesh:
		multimesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		batch_node.multimesh = multimesh
	elif multimesh.mesh != mesh:
		multimesh.mesh = mesh

	if multimesh.instance_count < entries.size():
		multimesh.instance_count = entries.size()
	multimesh.set_instance_transform(entries.size() - 1, transform)

func _hide_mesh_descendants(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			child.visible = false
		if child is Node:
			_hide_mesh_descendants(child)

func _set_shadow_casting_recursive(node: Node, enabled: bool) -> void:
	for child in node.get_children():
		if child is GeometryInstance3D:
			(child as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if child is Node:
			_set_shadow_casting_recursive(child, enabled)

func _rebuild_simple_visual_batch(object_id: int) -> void:
	if not simple_visual_batch_entries.has(object_id):
		if simple_visual_batch_nodes.has(object_id):
			var node = simple_visual_batch_nodes[object_id]
			if node and is_instance_valid(node):
				node.queue_free()
			simple_visual_batch_nodes.erase(object_id)
		return

	var entries: Array = simple_visual_batch_entries[object_id]
	if entries.is_empty():
		simple_visual_batch_entries.erase(object_id)
		if simple_visual_batch_nodes.has(object_id):
			var empty_node = simple_visual_batch_nodes[object_id]
			if empty_node and is_instance_valid(empty_node):
				empty_node.queue_free()
			simple_visual_batch_nodes.erase(object_id)
		return

	var visual_data := ObjectRegistry.get_object_visual_data(object_id)
	if visual_data.is_empty():
		return
	var mesh: Mesh = visual_data.get("mesh")
	if not mesh:
		return

	var batch_node := _get_simple_visual_batch_node(object_id, mesh)
	var multimesh: MultiMesh = batch_node.multimesh
	if not multimesh:
		multimesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		batch_node.multimesh = multimesh
	else:
		multimesh.mesh = mesh

	multimesh.instance_count = entries.size()
	var geometry_helper: Variant = null
	if manager and manager.has_method("get_prefab_geometry_native_helper"):
		geometry_helper = manager.get_prefab_geometry_native_helper()
	if geometry_helper and geometry_helper.has_method("pack_multimesh_buffer_from_instances"):
		var buffer: PackedFloat32Array = geometry_helper.pack_multimesh_buffer_from_instances(entries)
		if not buffer.is_empty():
			multimesh.set_buffer(buffer)
			return

	for i in range(entries.size()):
		var entry: Dictionary = entries[i]
		var transform: Transform3D = entry.get("transform", Transform3D.IDENTITY)
		multimesh.set_instance_transform(i, transform)

func _remove_simple_visual_batch_instance(local_anchor: Vector3i) -> bool:
	if not simple_visual_instances.has(local_anchor):
		return false

	var instance_data: Dictionary = simple_visual_instances[local_anchor]
	var object_id := int(instance_data.get("object_id", -1))
	if object_nodes.has(local_anchor):
		var live_node = object_nodes[local_anchor]
		if live_node and is_instance_valid(live_node):
			live_node.queue_free()
		object_nodes.erase(local_anchor)
	if object_collision_nodes.has(local_anchor):
		var collision_node = object_collision_nodes[local_anchor]
		if collision_node and is_instance_valid(collision_node):
			collision_node.queue_free()
		object_collision_nodes.erase(local_anchor)
	simple_visual_instances.erase(local_anchor)
	if manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled() and manager.has_method("remove_global_visual_batch"):
		manager.remove_global_visual_batch(_get_world_visual_batch_anchor(local_anchor, chunk_coord))
		return true

	if not simple_visual_batch_entries.has(object_id):
		return true

	var entries: Array = simple_visual_batch_entries[object_id]
	var filtered: Array = []
	for entry_variant in entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		if Vector3i(entry.get("anchor", Vector3i.ZERO)) != local_anchor:
			filtered.append(entry)

	if filtered.is_empty():
		simple_visual_batch_entries.erase(object_id)
		if simple_visual_batch_nodes.has(object_id):
			var node = simple_visual_batch_nodes[object_id]
			if node and is_instance_valid(node):
				node.queue_free()
			simple_visual_batch_nodes.erase(object_id)
		return true

	simple_visual_batch_entries[object_id] = filtered
	_rebuild_simple_visual_batch(object_id)
	return true

func place_simple_visual_object(local_anchor: Vector3i, object_id: int, rotation: int, cells: Array[Vector3i], fractional_pos: Vector3 = Vector3.ZERO, visual_data: Dictionary = {}, defer_global_visual_batch_rebuild: bool = false) -> bool:
	if not _should_batch_simple_visual(object_id):
		return false

	if visual_data.is_empty():
		visual_data = ObjectRegistry.get_object_visual_data(object_id)
	if visual_data.is_empty():
		return false

	var mesh: Mesh = visual_data.get("mesh")
	if not mesh:
		return false
	var mesh_transform: Transform3D = visual_data.get("mesh_transform", Transform3D.IDENTITY)

	var object_state := {
		"object_id": object_id,
		"rotation": rotation,
		"fractional_pos": fractional_pos
	}
	if objects.has(local_anchor) and typeof(objects[local_anchor]) == TYPE_DICTIONARY and objects[local_anchor].has("should_populate_loot"):
		object_state["should_populate_loot"] = bool(objects[local_anchor].get("should_populate_loot", false))
	objects[local_anchor] = object_state
	_has_deferred_runtime_visuals = true
	for cell in cells:
		occupied_by_object[cell] = local_anchor

	simple_visual_instances[local_anchor] = {
		"object_id": object_id,
		"rotation": rotation,
		"fractional_pos": fractional_pos
	}
	var final_transform := _build_simple_visual_transform(local_anchor, object_id, rotation, fractional_pos, mesh_transform)
	if _should_use_simple_object_collision(object_id):
		_generate_simple_visual_collision(local_anchor, object_id, final_transform, mesh)
	if manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled() and manager.has_method("register_global_visual_batch"):
		var chunk_origin := Transform3D(Basis.IDENTITY, Vector3(chunk_coord) * float(SIZE))
		var world_transform := chunk_origin * final_transform
		var world_anchor := _get_world_visual_batch_anchor(local_anchor, chunk_coord)
		if manager.register_global_visual_batch(world_anchor, object_id, world_transform, mesh, defer_global_visual_batch_rebuild):
			is_empty = false
			return true
	# Keep the fallback batch entry attached to the chunk even before it enters
	# the scene tree so the visual can appear as soon as the chunk becomes active.
	_append_simple_visual_batch_instance(object_id, local_anchor, final_transform, mesh)
	is_empty = false
	return true

func place_proxy_visual_object(local_anchor: Vector3i, object_id: int, rotation: int, cells: Array[Vector3i], scene_instance: Node3D, fractional_pos: Vector3 = Vector3.ZERO, visual_data: Dictionary = {}, defer_global_visual_batch_rebuild: bool = false) -> bool:
	if not _should_batch_proxy_visual(object_id):
		return false

	if visual_data.is_empty():
		visual_data = ObjectRegistry.get_object_visual_data(object_id)
	if visual_data.is_empty():
		return false

	var mesh: Mesh = visual_data.get("mesh")
	if not mesh:
		return false
	var mesh_transform: Transform3D = visual_data.get("mesh_transform", Transform3D.IDENTITY)

	var object_state := {
		"object_id": object_id,
		"rotation": rotation,
		"fractional_pos": fractional_pos
	}
	if objects.has(local_anchor) and typeof(objects[local_anchor]) == TYPE_DICTIONARY and objects[local_anchor].has("should_populate_loot"):
		object_state["should_populate_loot"] = bool(objects[local_anchor].get("should_populate_loot", false))
	objects[local_anchor] = object_state
	_has_deferred_runtime_visuals = true
	for cell in cells:
		occupied_by_object[cell] = local_anchor

	simple_visual_instances[local_anchor] = {
		"object_id": object_id,
		"rotation": rotation,
		"fractional_pos": fractional_pos
	}

	if scene_instance:
		if manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled():
			_set_shadow_casting_recursive(scene_instance, true)
		_hide_mesh_descendants(scene_instance)
		if ObjectRegistry.get_object_has_authored_collision(object_id):
			_prune_proxy_visual_children(scene_instance)

	var final_transform := _build_simple_visual_transform(local_anchor, object_id, rotation, fractional_pos, mesh_transform)
	if manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled() and manager.has_method("register_global_visual_batch"):
		var chunk_origin := Transform3D(Basis.IDENTITY, Vector3(chunk_coord) * float(SIZE))
		var world_transform := chunk_origin * final_transform
		var world_anchor := _get_world_visual_batch_anchor(local_anchor, chunk_coord)
		if manager.register_global_visual_batch(world_anchor, object_id, world_transform, mesh, defer_global_visual_batch_rebuild):
			is_empty = false
			return true
	# Preserve the local fallback batch so proxy objects do not disappear if
	# the global batch path is unavailable during restore.
	_append_simple_visual_batch_instance(object_id, local_anchor, final_transform, mesh)
	is_empty = false
	return true

func _spawn_proxy_gameplay_shell(local_anchor: Vector3i, object_id: int, rotation: int, fractional_pos: Vector3) -> Node3D:
	var scene_instance: Node3D = ObjectRegistry.create_proxy_gameplay_shell(object_id, bool(manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled()))
	if not scene_instance:
		return null

	var obj_data: Dictionary = objects.get(local_anchor, {})
	if scene_instance.has_method("populate_loot") and bool(obj_data.get("should_populate_loot", false)):
		scene_instance.set_meta("should_populate_loot", true)

	add_child(scene_instance)
	if manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled():
		_set_shadow_casting_recursive(scene_instance, true)

	var original_size = ObjectRegistry.get_object(object_id).get("size", Vector3i(1, 1, 1))
	var offset_x = float(original_size.x) / 2.0
	var offset_z = float(original_size.z) / 2.0
	if rotation == 1 or rotation == 3:
		var temp = offset_x
		offset_x = offset_z
		offset_z = temp

	scene_instance.position = Vector3(local_anchor.x + offset_x, local_anchor.y, local_anchor.z + offset_z) + fractional_pos
	scene_instance.rotation_degrees.y = rotation * 90
	scene_instance.add_to_group("placed_objects")
	scene_instance.set_meta("anchor", local_anchor)
	scene_instance.set_meta("chunk", self)
	scene_instance.set_meta("object_id", object_id)
	object_nodes[local_anchor] = scene_instance
	return scene_instance

func promote_simple_visual_batches_to_global() -> void:
	if not manager or not manager.has_method("is_baked_world_map_visual_mode_enabled") or not manager.is_baked_world_map_visual_mode_enabled():
		return
	if not manager.has_method("register_global_visual_batch"):
		return
	if not is_inside_tree():
		return

	var promoted_any := false
	var chunk_origin := Transform3D(Basis.IDENTITY, Vector3(chunk_coord) * float(SIZE))
	var object_id_variants: Array = simple_visual_batch_entries.keys()
	for object_id_variant in object_id_variants:
		var object_id := int(object_id_variant)
		var entries: Array = simple_visual_batch_entries.get(object_id, [])
		if entries.is_empty():
			continue

		var visual_data := ObjectRegistry.get_object_visual_data(object_id)
		if visual_data.is_empty():
			continue
		var mesh: Mesh = visual_data.get("mesh")
		if not mesh:
			continue

		var remaining: Array = []
		for entry_variant in entries:
			if typeof(entry_variant) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = entry_variant
			var local_anchor: Vector3i = entry.get("anchor", Vector3i.ZERO)
			var transform: Transform3D = entry.get("transform", Transform3D.IDENTITY)
			var world_anchor := _get_world_visual_batch_anchor(local_anchor, chunk_coord)
			var world_transform := chunk_origin * transform
			if manager.register_global_visual_batch(world_anchor, object_id, world_transform, mesh, true):
				promoted_any = true
			else:
				remaining.append(entry)

		if remaining.is_empty():
			simple_visual_batch_entries.erase(object_id)
			if simple_visual_batch_nodes.has(object_id):
				var node = simple_visual_batch_nodes[object_id]
				if node and is_instance_valid(node):
					node.queue_free()
				simple_visual_batch_nodes.erase(object_id)
		elif remaining.size() != entries.size() or not simple_visual_batch_nodes.has(object_id):
			simple_visual_batch_entries[object_id] = remaining
			_rebuild_simple_visual_batch(object_id)

	if promoted_any and manager.has_method("flush_global_visual_batches"):
		manager.flush_global_visual_batches()

func refresh_proxy_visual_shells(viewer_position: Vector3, activation_distance: float, generous_activation_distance: float = 0.0) -> void:
	if activation_distance <= 0.0:
		return
	if not manager or not manager.world_map_mode:
		return
	if not manager.has_method("is_eager_baked_building_residency_enabled") or not manager.is_eager_baked_building_residency_enabled():
		return

	var activation_sq := activation_distance * activation_distance
	var generous_activation_sq := generous_activation_distance * generous_activation_distance
	var chunk_origin := Vector3(chunk_coord) * float(SIZE)

	for local_anchor_variant in simple_visual_instances.keys():
		var local_anchor: Vector3i = local_anchor_variant
		var instance_data: Dictionary = simple_visual_instances[local_anchor]
		var object_id := int(instance_data.get("object_id", -1))
		if not ObjectRegistry.is_proxy_visual_batch_object(object_id):
			continue

		var rotation := int(instance_data.get("rotation", 0))
		var fractional_pos: Vector3 = instance_data.get("fractional_pos", Vector3.ZERO)
		var visual_data := ObjectRegistry.get_object_visual_data(object_id)
		var mesh_transform := Transform3D.IDENTITY
		if not visual_data.is_empty():
			mesh_transform = visual_data.get("mesh_transform", Transform3D.IDENTITY)

		var final_transform := _build_simple_visual_transform(local_anchor, object_id, rotation, fractional_pos, mesh_transform)
		var world_pos := chunk_origin + final_transform.origin
		var shell_activation_sq := activation_sq
		if generous_activation_sq > activation_sq and ObjectRegistry.is_high_priority_proxy_visual_batch_object(object_id):
			shell_activation_sq = generous_activation_sq
		var shell_active := object_nodes.has(local_anchor)
		if shell_active:
			var existing = object_nodes[local_anchor]
			if not existing or not is_instance_valid(existing):
				object_nodes.erase(local_anchor)
				shell_active = false

		if world_pos.distance_squared_to(viewer_position) <= shell_activation_sq:
			if not shell_active:
				_spawn_proxy_gameplay_shell(local_anchor, object_id, rotation, fractional_pos)
		elif shell_active:
			var node = object_nodes[local_anchor]
			if node and is_instance_valid(node):
				node.queue_free()
			object_nodes.erase(local_anchor)

func refresh_lazy_object_visuals(viewer_position: Vector3, activation_distance: float) -> void:
	if activation_distance <= 0.0:
		return
	if not manager or not manager.world_map_mode:
		return
	if not manager.has_method("is_eager_baked_building_residency_enabled") or not manager.is_eager_baked_building_residency_enabled():
		return

	var activation_sq := activation_distance * activation_distance
	var chunk_origin := Vector3(chunk_coord) * float(SIZE)

	for local_anchor_variant in objects.keys():
		var local_anchor: Vector3i = local_anchor_variant
		var obj_data: Dictionary = objects[local_anchor]
		var object_id := int(obj_data.get("object_id", -1))
		if object_id < 0:
			continue
		if ObjectRegistry.is_simple_visual_batch_object(object_id) or ObjectRegistry.is_proxy_visual_batch_object(object_id):
			continue
		var effective_activation_sq := activation_sq
		if ObjectRegistry.is_high_priority_lazy_scene_object(object_id):
			effective_activation_sq = activation_sq * 16.0

		var rotation := int(obj_data.get("rotation", 0))
		var fractional_pos: Vector3 = obj_data.get("fractional_pos", Vector3.ZERO)
		var object_def := ObjectRegistry.get_object(object_id)
		if object_def.is_empty():
			continue
		var scene_path := str(object_def.get("scene", ""))
		if scene_path.is_empty():
			continue
		var object_size: Vector3i = object_def.get("size", Vector3i(1, 1, 1))

		var object_anchor := chunk_origin + Vector3(local_anchor)
		var object_center := object_anchor + Vector3(float(object_size.x) * 0.5, 0.0, float(object_size.z) * 0.5)
		if rotation == 1 or rotation == 3:
			object_center = object_anchor + Vector3(float(object_size.z) * 0.5, 0.0, float(object_size.x) * 0.5)
		object_center += fractional_pos

		var active_node_exists := object_nodes.has(local_anchor)
		if active_node_exists:
			var active_node = object_nodes[local_anchor]
			if not active_node or not is_instance_valid(active_node):
				object_nodes.erase(local_anchor)
				active_node_exists = false

		if object_center.distance_squared_to(viewer_position) <= effective_activation_sq:
			if active_node_exists:
				continue
			var packed = ObjectRegistry.get_preloaded_scene(scene_path)
			if not packed:
				continue
			var scene_instance: Node3D = packed.instantiate()
			if scene_instance:
				var cells := ObjectRegistry.get_occupied_cells(object_id, local_anchor, rotation)
				var has_authored_collision := ObjectRegistry.get_object_has_authored_collision(object_id)
				var should_populate_loot := bool(obj_data.get("should_populate_loot", false))
				if should_populate_loot and scene_instance.has_method("populate_loot"):
					scene_instance.set_meta("should_populate_loot", true)
				place_object(local_anchor, object_id, rotation, cells, scene_instance, fractional_pos, false, true, object_size, has_authored_collision, true)

func rebuild_mesh():
	if mesher:
		mesher.request_mesh_generation(self)

func apply_mesh(arrays: Array, shape: Shape3D = null, source_mesh: ArrayMesh = null, collision_boxes: Array = []):
	if not mesh_instance:
		_pending_mesh_apply = {
			"arrays": arrays,
			"shape": shape,
			"source_mesh": source_mesh,
			"collision_boxes": collision_boxes
		}
		return

	var use_source_mesh := source_mesh != null
	var skip_mesh_render := bool(manager and "skip_building_chunk_mesh_render_for_test" in manager and manager.skip_building_chunk_mesh_render_for_test)
	var is_world_map_mode := bool(manager and manager.world_map_mode)
	var use_legacy_material_override := BuildingVisuals.use_legacy_building_shader_override_for_test()
	var mesh: ArrayMesh = mesh_instance.mesh as ArrayMesh
	_applied_collision_boxes = collision_boxes.duplicate(true)
	if use_source_mesh:
		mesh = source_mesh

	if mesh == null:
		mesh = ArrayMesh.new()
	elif not use_source_mesh:
		mesh.clear_surfaces()

	if arrays.size() > 0 or use_source_mesh:
		if skip_mesh_render:
			mesh_instance.visible = false
			mesh_instance.mesh = null
		else:
			mesh_instance.visible = true
			if use_source_mesh:
				mesh_instance.mesh = mesh
				if use_legacy_material_override:
					BuildingVisuals.apply_runtime_surface_materials(mesh_instance, voxel_bytes)
				else:
					mesh_instance.material_override = null
					var surface_count := mesh.get_surface_count() if mesh else 0
					for surface_index in range(surface_count):
						mesh_instance.set_surface_override_material(surface_index, null)
			else:
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				if mesh_instance.mesh != mesh:
					mesh_instance.mesh = mesh
				BuildingVisuals.apply_runtime_surface_materials(mesh_instance, voxel_bytes)
				if mesh_instance.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
					mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	else:
		if mesh_instance.mesh != mesh:
			mesh_instance.mesh = mesh
	_last_runtime_mesh_surface_count = mesh.get_surface_count() if mesh else -1
	_last_runtime_mesh_visible = mesh_instance.visible if mesh_instance else false

	if _should_skip_chunk_collisions():
		_clear_static_body_shapes()
		_applied_collision_boxes.clear()
		mesh_dirty = false
		return

	# Prefer the exact collision shape whenever the mesher produced one.
	# Box collision is only a fallback for chunks that do not have a usable
	# exact shape payload.
	_clear_static_body_shapes()
	if _shape_is_usable(shape):
		_apply_primary_collision_shape(shape)
	elif is_world_map_mode and collision_boxes.size() > 0:
		var handled_native_boxes := false
		if mesher and mesher.has_method("apply_world_map_collision_boxes") and static_body:
			handled_native_boxes = mesher.apply_world_map_collision_boxes(static_body.get_rid(), collision_boxes)
		if not handled_native_boxes:
			_apply_collision_boxes(collision_boxes)
	elif mesh_instance.mesh and mesh_instance.mesh.get_surface_count() > 0:
		var native_trimesh_shape := _build_native_trimesh_collision_shape(mesh_instance.mesh)
		if _shape_is_usable(native_trimesh_shape):
			_apply_primary_collision_shape(native_trimesh_shape)

	mesh_dirty = false
	return

func capture_bake_snapshot() -> BuildingBakeSnapshot:
	var snapshot := BuildingBakeSnapshot.new()
	snapshot.chunk_coord = chunk_coord
	snapshot.is_empty = is_empty
	snapshot.voxel_bytes = voxel_bytes.duplicate()
	snapshot.voxel_meta = voxel_meta.duplicate()
	snapshot.objects_data = _serialize_objects_for_bake()
	var snapshot_mesh: ArrayMesh = null
	if mesh_instance and is_instance_valid(mesh_instance) and mesh_instance.mesh:
		snapshot_mesh = mesh_instance.mesh as ArrayMesh
	elif _pending_mesh_apply.has("source_mesh"):
		snapshot_mesh = _pending_mesh_apply.get("source_mesh", null) as ArrayMesh
	snapshot.mesh = snapshot_mesh

	var snapshot_collision_shape: Shape3D = null
	if collision_shape and is_instance_valid(collision_shape) and collision_shape.shape:
		snapshot_collision_shape = collision_shape.shape
	elif _pending_mesh_apply.has("shape"):
		snapshot_collision_shape = _pending_mesh_apply.get("shape", null)
	snapshot.collision_shape = snapshot_collision_shape

	var snapshot_collision_boxes: Array = _applied_collision_boxes.duplicate(true)
	if snapshot_collision_boxes.is_empty() and _pending_mesh_apply.has("collision_boxes"):
		snapshot_collision_boxes = _pending_mesh_apply.get("collision_boxes", []).duplicate(true)
	snapshot.collision_boxes = snapshot_collision_boxes
	_last_snapshot_mesh_surface_count = snapshot.mesh.get_surface_count() if snapshot.mesh else -1
	_last_snapshot_collision_box_count = snapshot.collision_boxes.size()
	return snapshot

func _resolve_baked_snapshot_resource_path(file_name: String) -> String:
	if file_name.is_empty():
		return ""
	if not manager or not ("baked_buildings_world_path" in manager):
		return ""
	var world_path := str(manager.baked_buildings_world_path)
	if world_path.is_empty():
		return ""
	return world_path.path_join("baked_buildings").path_join(file_name)

func _load_baked_snapshot_resource(file_name: String) -> Resource:
	var resource_path := _resolve_baked_snapshot_resource_path(file_name)
	if resource_path.is_empty() or not FileAccess.file_exists(resource_path):
		return null
	return ResourceLoader.load(resource_path, "", ResourceLoader.CACHE_MODE_REPLACE)

func apply_bake_snapshot(snapshot: Resource) -> void:
	if snapshot == null or not snapshot is BuildingBakeSnapshot:
		return

	var bake_snapshot := snapshot as BuildingBakeSnapshot
	voxel_bytes = bake_snapshot.voxel_bytes.duplicate()
	voxel_meta = bake_snapshot.voxel_meta.duplicate()
	is_empty = bool(bake_snapshot.is_empty)
	mesh_dirty = false
	baked_snapshot_loaded = true
	baked_snapshot_chunk_coord = bake_snapshot.chunk_coord
	_runtime_visuals_activated = false
	_clear_object_runtime_state(chunk_coord)
	_load_objects_from_bake(bake_snapshot.objects_data)

	var resolved_mesh: ArrayMesh = bake_snapshot.mesh
	if not resolved_mesh and not str(bake_snapshot.mesh_file).is_empty():
		var loaded_mesh := _load_baked_snapshot_resource(str(bake_snapshot.mesh_file))
		if loaded_mesh is ArrayMesh:
			resolved_mesh = loaded_mesh as ArrayMesh

	var resolved_collision_shape: Shape3D = bake_snapshot.collision_shape
	if not resolved_collision_shape and not str(bake_snapshot.collision_shape_file).is_empty():
		var loaded_shape := _load_baked_snapshot_resource(str(bake_snapshot.collision_shape_file))
		if loaded_shape is Shape3D:
			resolved_collision_shape = loaded_shape as Shape3D

	var resolved_collision_boxes: Array = bake_snapshot.collision_boxes.duplicate(true)
	_last_snapshot_mesh_surface_count = resolved_mesh.get_surface_count() if resolved_mesh else -1
	_last_snapshot_collision_box_count = resolved_collision_boxes.size()

	if resolved_mesh:
		_pending_mesh_apply = {
			"arrays": [],
			"shape": resolved_collision_shape,
			"source_mesh": resolved_mesh,
			"collision_boxes": resolved_collision_boxes
		}
	else:
		_pending_mesh_apply.clear()
		if voxel_bytes.size() > 0:
			mesh_dirty = true
			# Defer the fallback rebuild until the chunk is actually visible.
			# Off-tree baked chunks should stay dormant so eager manifest loads do
			# not recreate the full runtime chunk graph up front.
			if is_inside_tree():
				rebuild_mesh()

	if is_inside_tree():
		activate_runtime_visuals(false)

func _serialize_objects_for_bake() -> Array:
	var serialized: Array = []
	for local_anchor in objects:
		var obj_data: Dictionary = objects[local_anchor]
		var fractional_pos: Vector3 = obj_data.get("fractional_pos", Vector3.ZERO)
		if obj_data.has("fractional_y") and not obj_data.has("fractional_pos"):
			fractional_pos = Vector3(0.0, float(obj_data.get("fractional_y", 0.0)), 0.0)
		serialized.append({
			"anchor": [local_anchor.x, local_anchor.y, local_anchor.z],
			"object_id": int(obj_data.get("object_id", -1)),
			"rotation": int(obj_data.get("rotation", 0)),
			"fractional_pos": [fractional_pos.x, fractional_pos.y, fractional_pos.z],
			"should_populate_loot": bool(obj_data.get("should_populate_loot", false))
		})
	return serialized

func _load_objects_from_bake(objects_data: Array) -> void:
	objects.clear()
	occupied_by_object.clear()
	object_nodes.clear()
	object_collision_nodes.clear()
	simple_visual_instances.clear()
	simple_visual_batch_entries.clear()
	simple_visual_batch_nodes.clear()
	_has_deferred_runtime_visuals = false
	for entry_variant in objects_data:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		var anchor_arr: Array = entry.get("anchor", [])
		if anchor_arr.size() < 3:
			continue
		var local_anchor := Vector3i(int(anchor_arr[0]), int(anchor_arr[1]), int(anchor_arr[2]))
		var object_id := int(entry.get("object_id", -1))
		if object_id < 0:
			continue
		if not ObjectRegistry.is_simple_visual_batch_object(object_id):
			_has_deferred_runtime_visuals = true
		var rotation := int(entry.get("rotation", 0))
		var fractional_arr: Array = entry.get("fractional_pos", [0.0, 0.0, 0.0])
		var fractional_pos := Vector3(
			float(fractional_arr[0]) if fractional_arr.size() > 0 else 0.0,
			float(fractional_arr[1]) if fractional_arr.size() > 1 else 0.0,
			float(fractional_arr[2]) if fractional_arr.size() > 2 else 0.0
		)
		objects[local_anchor] = {
			"object_id": object_id,
			"rotation": rotation,
			"fractional_pos": fractional_pos,
			"should_populate_loot": bool(entry.get("should_populate_loot", false))
		}
		var cells := ObjectRegistry.get_occupied_cells(object_id, local_anchor, rotation)
		for cell in cells:
			occupied_by_object[cell] = local_anchor

func _clear_object_runtime_state(previous_chunk_coord: Vector3i) -> void:
	for anchor in object_nodes:
		var node = object_nodes[anchor]
		if node and is_instance_valid(node):
			node.queue_free()
	for anchor in object_collision_nodes:
		var collision_node = object_collision_nodes[anchor]
		if collision_node and is_instance_valid(collision_node):
			collision_node.queue_free()
	if prop_collision_body and is_instance_valid(prop_collision_body):
		prop_collision_body.queue_free()
	prop_collision_body = null
	if manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled() and manager.has_method("remove_global_visual_batch"):
		for anchor in simple_visual_instances:
			manager.remove_global_visual_batch(_get_world_visual_batch_anchor(anchor, previous_chunk_coord))
	for batch_node in simple_visual_batch_nodes.values():
		if batch_node and is_instance_valid(batch_node):
			batch_node.queue_free()
	objects.clear()
	occupied_by_object.clear()
	object_nodes.clear()
	object_collision_nodes.clear()
	_clear_static_body_shapes()
	simple_visual_instances.clear()
	simple_visual_batch_entries.clear()
	simple_visual_batch_nodes.clear()
	_has_deferred_runtime_visuals = false
	_applied_collision_boxes.clear()

func requires_runtime_visual_refresh() -> bool:
	return _has_deferred_runtime_visuals

func is_runtime_visuals_activated() -> bool:
	return _runtime_visuals_activated

func get_runtime_mesh_surface_count() -> int:
	if not mesh_instance or not is_instance_valid(mesh_instance):
		return 0
	if not mesh_instance.mesh:
		return 0
	return mesh_instance.mesh.get_surface_count()

func is_runtime_mesh_visible() -> bool:
	if not mesh_instance or not is_instance_valid(mesh_instance):
		return false
	return mesh_instance.visible

func get_last_snapshot_mesh_surface_count() -> int:
	return _last_snapshot_mesh_surface_count

func get_last_snapshot_collision_box_count() -> int:
	return _last_snapshot_collision_box_count

func get_last_runtime_mesh_surface_count() -> int:
	return _last_runtime_mesh_surface_count

func get_last_runtime_mesh_visible() -> bool:
	return _last_runtime_mesh_visible

func _apply_collision_boxes(collision_boxes: Array) -> void:
	if not static_body:
		return

	var body_rid := static_body.get_rid()
	if not body_rid.is_valid():
		return

	for box_data_variant in collision_boxes:
		if typeof(box_data_variant) != TYPE_DICTIONARY:
			continue
		var box_data: Dictionary = box_data_variant
		var origin: Vector3i = box_data.get("origin", Vector3i.ZERO)
		var size: Vector3i = box_data.get("size", Vector3i.ONE)
		if size.x <= 0 or size.y <= 0 or size.z <= 0:
			continue

		var box_shape := _get_cached_box_shape(size)
		var box_transform := Transform3D(Basis.IDENTITY, Vector3(origin) + Vector3(size) * 0.5)
		PhysicsServer3D.body_add_shape(body_rid, box_shape.get_rid(), box_transform)

func _apply_primary_collision_shape(shape: Shape3D) -> void:
	if not static_body:
		return

	if not _shape_is_usable(shape):
		return

	if collision_shape and is_instance_valid(collision_shape):
		collision_shape.shape = shape

func _clear_static_body_shapes() -> void:
	if collision_shape and is_instance_valid(collision_shape):
		collision_shape.shape = null
	if static_body and is_instance_valid(static_body):
		var body_rid := static_body.get_rid()
		if body_rid.is_valid():
			var shape_count := PhysicsServer3D.body_get_shape_count(body_rid)
			for shape_idx in range(shape_count - 1, -1, -1):
				PhysicsServer3D.body_remove_shape(body_rid, shape_idx)
	_applied_collision_boxes.clear()
func _shape_is_usable(candidate: Shape3D) -> bool:
	if candidate == null:
		return false
	if candidate is ConcavePolygonShape3D:
		return candidate.get_faces().size() > 0
	return true

func get_runtime_collision_shape_count() -> int:
	var total_shapes := 0
	if static_body and is_instance_valid(static_body):
		var body_rid := static_body.get_rid()
		if body_rid.is_valid():
			total_shapes += PhysicsServer3D.body_get_shape_count(body_rid)
	if prop_collision_body and is_instance_valid(prop_collision_body):
		var prop_body_rid := prop_collision_body.get_rid()
		if prop_body_rid.is_valid():
			total_shapes += PhysicsServer3D.body_get_shape_count(prop_body_rid)
	return total_shapes

func mark_mesh_dirty() -> void:
	mesh_dirty = true

func is_mesh_dirty() -> bool:
	return mesh_dirty

func _get_index(pos: Vector3i) -> int:
	return pos.x + pos.y * SIZE + pos.z * SIZE * SIZE

## Check if a cell is available (no block, no object)
func is_cell_available(local_pos: Vector3i) -> bool:
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return false
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return false
	
	# Check block
	if get_voxel(local_pos) > 0:
		return false
	
	# Check object occupation
	if occupied_by_object.has(local_pos):
		return false
	
	return true

## Place an object at the anchor position (assumes cells already validated)
## fractional_pos is the 3D offset from the anchor block's origin (0,0,0)
func place_object(local_anchor: Vector3i, object_id: int, rotation: int, cells: Array[Vector3i], scene_instance: Node3D, fractional_pos: Vector3 = Vector3.ZERO, defer_collision: bool = false, defer_global_visual_batch_rebuild: bool = false, object_size: Vector3i = Vector3i.ZERO, has_authored_collision: bool = false, has_authored_collision_valid: bool = false) -> bool:
	# Store object data (include fractional_pos for persistence)
	var object_state := {
		"object_id": object_id,
		"rotation": rotation,
		"fractional_pos": fractional_pos
	}
	if objects.has(local_anchor) and typeof(objects[local_anchor]) == TYPE_DICTIONARY and objects[local_anchor].has("should_populate_loot"):
		object_state["should_populate_loot"] = bool(objects[local_anchor].get("should_populate_loot", false))
	objects[local_anchor] = object_state
	
	# Mark all occupied cells
	for cell in cells:
		occupied_by_object[cell] = local_anchor

	# Add visual instance with collision
	if scene_instance:
		add_child(scene_instance)
		if not ObjectRegistry.is_simple_visual_batch_object(object_id):
			_has_deferred_runtime_visuals = true
		if manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled():
			_set_shadow_casting_recursive(scene_instance, true)
		
		# Position logic:
		# Center the object over its ORIGINAL footprint (unrotated size)
		# The visual rotation is applied to the model, so we use original size for offset
		# For rotations 1 and 3 (90°/270°), swap the offset components to match rotated footprint
		var original_size := object_size
		if original_size == Vector3i.ZERO:
			original_size = ObjectRegistry.get_object(object_id).get("size", Vector3i(1, 1, 1))
		var offset_x = float(original_size.x) / 2.0
		var offset_z = float(original_size.z) / 2.0
		
		# For 90° and 270° rotations, swap offsets since footprint is rotated
		if rotation == 1 or rotation == 3:
			var temp = offset_x
			offset_x = offset_z
			offset_z = temp
		
		# Base position is anchor + centered offset
		var base_pos = Vector3(local_anchor.x + offset_x, local_anchor.y, local_anchor.z + offset_z)
		
		# Add fractional_pos (treated as extra offset, usually 0 for manual placement)
		scene_instance.position = base_pos + fractional_pos
		
		# Apply rotation (90 degree increments)
		scene_instance.rotation_degrees.y = rotation * 90
		
		# Add to group for identification during removal
		scene_instance.add_to_group("placed_objects")
		# Store anchor reference in metadata for removal lookup
		scene_instance.set_meta("anchor", local_anchor)
		scene_instance.set_meta("chunk", self)
		scene_instance.set_meta("object_id", object_id)
		var resolved_has_authored_collision := has_authored_collision if has_authored_collision_valid else ObjectRegistry.get_object_has_authored_collision(object_id)
		if _should_batch_proxy_visual(object_id):
			# Proxy shells already provide their own lightweight collision.
			# Skipping the generic collision cooking path keeps the eager path
			# from doing redundant physics work per object.
			resolved_has_authored_collision = true

		if _should_batch_proxy_visual(object_id):
			var proxy_cells := ObjectRegistry.get_occupied_cells(object_id, local_anchor, rotation)
			var visual_data := ObjectRegistry.get_object_visual_data(object_id)
			if not visual_data.is_empty():
				place_proxy_visual_object(local_anchor, object_id, rotation, proxy_cells, scene_instance, fractional_pos, visual_data, defer_global_visual_batch_rebuild)
		
		# Objects that already ship with authored collision do not need the extra
		# generic collision cooking pass.
		if not resolved_has_authored_collision:
			# Generate collision now for manual placements; procedural spawns can defer to the manager budget.
			if defer_collision and manager and manager.has_method("queue_object_collision"):
				manager.queue_object_collision(self, scene_instance, local_anchor)
			else:
				_generate_object_collision_measured(scene_instance, local_anchor)

		object_nodes[local_anchor] = scene_instance

	is_empty = false
	return true

func _generate_object_collision_measured(obj: Node3D, anchor: Vector3i) -> void:
	if _should_skip_object_collisions():
		return
	var object_id := int(obj.get_meta("object_id", -1))
	if _should_use_simple_object_collision(object_id):
		_generate_simple_object_collision(obj, anchor, object_id)
	else:
		_generate_object_collision(obj, anchor)

func _should_use_simple_object_collision(object_id: int) -> bool:
	return SIMPLE_OBJECT_COLLISION_IDS.has(object_id)

func _should_skip_object_collisions() -> bool:
	return manager and "skip_object_collisions_for_test" in manager and bool(manager.skip_object_collisions_for_test)

func _should_skip_chunk_collisions() -> bool:
	return manager and "skip_building_chunk_collisions_for_test" in manager and bool(manager.skip_building_chunk_collisions_for_test)

func _generate_simple_object_collision(obj: Node3D, anchor: Vector3i, object_id: int) -> void:
	var visual_data := ObjectRegistry.get_object_visual_data(object_id)
	if visual_data.is_empty():
		_generate_object_collision(obj, anchor)
		return

	var mesh: Mesh = visual_data.get("mesh")
	var mesh_transform: Transform3D = visual_data.get("mesh_transform", Transform3D.IDENTITY)
	if not mesh:
		_generate_object_collision(obj, anchor)
		return

	var mesh_local_transform := obj.transform * mesh_transform
	var aabb := mesh.get_aabb()
	var box_size := Vector3(
		maxf(aabb.size.x, 0.05),
		maxf(aabb.size.y, 0.05),
		maxf(aabb.size.z, 0.05)
	)
	_create_simple_object_collision_node(anchor, object_id, mesh_local_transform * Transform3D(Basis.IDENTITY, aabb.position + (aabb.size * 0.5)), box_size, obj)

func _generate_simple_visual_collision(local_anchor: Vector3i, object_id: int, final_transform: Transform3D, mesh: Mesh) -> void:
	if _should_skip_object_collisions():
		return
	if not mesh:
		return

	var aabb := mesh.get_aabb()
	var box_size := Vector3(
		maxf(aabb.size.x, 0.05),
		maxf(aabb.size.y, 0.05),
		maxf(aabb.size.z, 0.05)
	)
	_create_simple_object_collision_node(local_anchor, object_id, final_transform * Transform3D(Basis.IDENTITY, aabb.position + (aabb.size * 0.5)), box_size, null)

func _create_simple_object_collision_node(anchor: Vector3i, object_id: int, collision_transform: Transform3D, box_size: Vector3, object_node: Node3D = null) -> void:
	if _should_skip_object_collisions():
		return
	if object_collision_nodes.has(anchor):
		var existing_collision = object_collision_nodes[anchor]
		if existing_collision and is_instance_valid(existing_collision):
			return
		object_collision_nodes.erase(anchor)

	_ensure_runtime_nodes()
	if not prop_collision_body or not is_instance_valid(prop_collision_body):
		return
	prop_collision_body.collision_layer = static_body.collision_layer if static_body and is_instance_valid(static_body) else 1 + 512
	prop_collision_body.collision_mask = static_body.collision_mask if static_body and is_instance_valid(static_body) else 1

	var collision := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box_size
	collision.shape = box_shape
	collision.add_to_group("placed_objects")
	collision.transform = collision_transform
	collision.set_meta("anchor", anchor)
	collision.set_meta("chunk", self)
	collision.set_meta("object_id", object_id)
	if object_node and is_instance_valid(object_node):
		collision.set_meta("object_node", object_node)
	prop_collision_body.add_child(collision)
	object_collision_nodes[anchor] = collision

func resolve_collision_hit_target(collider: Object, shape_index: int = -1) -> Node:
	if collider is Node and collider.is_in_group("placed_objects"):
		return collider

	if collider is CollisionObject3D and shape_index >= 0:
		var owner_id: int = collider.shape_find_owner(shape_index)
		if owner_id != -1:
			var owner: Object = collider.shape_owner_get_owner(owner_id)
			if owner is Node:
				var owner_node: Node = owner
				if owner_node.has_meta("object_node"):
					var object_node = owner_node.get_meta("object_node")
					if object_node and is_instance_valid(object_node):
						return object_node
				return owner_node

	if collider is Node:
		return collider
	return null

func _scene_has_authored_collision(node: Node) -> bool:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		return true
	for child in node.get_children():
		if _scene_has_authored_collision(child):
			return true
	return false

func _subtree_has_mesh_instance(node: Node) -> bool:
	if node is MeshInstance3D:
		return true
	for child in node.get_children():
		if _subtree_has_mesh_instance(child):
			return true
	return false

func _prune_proxy_visual_children(node: Node) -> void:
	for child in node.get_children():
		if child is CollisionShape3D or child is CollisionPolygon3D:
			continue
		if child is AudioStreamPlayer3D or child is AnimationPlayer or child is Skeleton3D or child is BoneAttachment3D:
			continue
		if child.get_script():
			continue
		if _subtree_has_mesh_instance(child) and not _scene_has_authored_collision(child):
			child.queue_free()

func _find_first_mesh_instance(node: Node) -> MeshInstance3D:
	for child in node.get_children():
		if child is MeshInstance3D:
			return child
		if child is Node:
			var nested := _find_first_mesh_instance(child)
			if nested:
				return nested
	return null

## Generate collision for an object by finding its meshes
## anchor is passed in since child nodes may not have the meta set
## Skips objects in "interactable" group - they handle their own collision
func _generate_object_collision(obj: Node3D, anchor: Vector3i):
	if _should_skip_object_collisions():
		return
	# Skip collision generation for interactable objects (they manage their own)
	if obj.is_in_group("interactable"):
		return
	var object_id := int(obj.get_meta("object_id", -1))
	if _should_use_simple_object_collision(object_id):
		_generate_simple_object_collision(obj, anchor, object_id)
		return
	# Find all MeshInstance3D children and create collision shapes
	for child in obj.get_children():
		if child is MeshInstance3D:
			var mesh_inst = child as MeshInstance3D
			if mesh_inst.mesh:
				# Create StaticBody3D with trimesh collision
				var collision_shape := _get_cached_object_collision_shape(mesh_inst.mesh)
				if not _shape_is_usable(collision_shape):
					continue

				var static_body = StaticBody3D.new()
				static_body.add_to_group("placed_objects")
				static_body.set_meta("anchor", anchor)
				static_body.set_meta("chunk", self)
				
				var collision = CollisionShape3D.new()
				collision.shape = collision_shape
				static_body.add_child(collision)
				
				# Match the mesh position
				static_body.position = mesh_inst.position
				static_body.rotation = mesh_inst.rotation
				static_body.scale = mesh_inst.scale
				
				mesh_inst.add_child(static_body)
		# Recurse into children
		if child is Node3D:
			_generate_object_collision(child, anchor)

## Remove an object and free its cells
func remove_object(local_anchor: Vector3i) -> bool:
	if not objects.has(local_anchor):
		return false
	
	var obj_data = objects[local_anchor]
	var object_id = obj_data.object_id
	var rotation = obj_data.rotation
	
	# Get all cells to free
	var cells = ObjectRegistry.get_occupied_cells(object_id, local_anchor, rotation)
	for cell in cells:
		occupied_by_object.erase(cell)
	
	# Remove visual
	if _remove_simple_visual_batch_instance(local_anchor):
		objects.erase(local_anchor)
		return true
	if object_nodes.has(local_anchor):
		var node = object_nodes[local_anchor]
		if node and is_instance_valid(node):
			node.queue_free()
		object_nodes.erase(local_anchor)
	if object_collision_nodes.has(local_anchor):
		var collision_node = object_collision_nodes[local_anchor]
		if collision_node and is_instance_valid(collision_node):
			collision_node.queue_free()
		object_collision_nodes.erase(local_anchor)
	
	objects.erase(local_anchor)
	return true

## Get object at a cell (returns anchor position, or null if no object)
func get_object_at(local_pos: Vector3i):
	if occupied_by_object.has(local_pos):
		return occupied_by_object[local_pos]
	return null

## Restore visual instances for all stored objects (called after load)
## This spawns the scene instances for objects that were saved to the objects dictionary
func _restore_object_visuals_legacy(defer_collision: bool = true):
	for local_anchor in objects:
		# Skip if visual already exists
		if (object_nodes.has(local_anchor) and is_instance_valid(object_nodes[local_anchor])) or simple_visual_instances.has(local_anchor):
			continue
		var obj_data = objects[local_anchor]
		var object_id = obj_data.object_id
		var rotation = obj_data.rotation
		var fractional_pos: Vector3 = obj_data.get("fractional_pos", Vector3(0.0, float(obj_data.get("fractional_y", 0.0)), 0.0))
		if _should_batch_simple_visual(object_id):
			var cells := ObjectRegistry.get_occupied_cells(object_id, local_anchor, rotation)
			if place_simple_visual_object(local_anchor, object_id, rotation, cells, fractional_pos):
				continue
		# Load and instantiate the scene
		var obj_def = ObjectRegistry.get_object(object_id)
		if obj_def.is_empty():
			continue
		
		var scene_path = obj_def.get("scene", "")
		if scene_path == "":
			continue
		
		var scene_instance: Node3D = null
		if manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled() and ObjectRegistry.is_proxy_visual_batch_object(object_id):
			scene_instance = ObjectRegistry.create_proxy_gameplay_shell(object_id, true)
		if scene_instance == null:
			var packed = ObjectRegistry.get_preloaded_scene(scene_path)
			if not packed:
				continue
			scene_instance = packed.instantiate()
		if scene_instance.has_method("populate_loot") and bool(obj_data.get("should_populate_loot", false)):
			scene_instance.set_meta("should_populate_loot", true)
		
		# Add and position the visual
		add_child(scene_instance)
		if manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled():
			_set_shadow_casting_recursive(scene_instance, true)
		var original_size = ObjectRegistry.get_object(object_id).get("size", Vector3i(1, 1, 1))
		var offset_x = float(original_size.x) / 2.0
		var offset_z = float(original_size.z) / 2.0
		
		# For 90° and 270° rotations, swap offsets since footprint is rotated
		if rotation == 1 or rotation == 3:
			var temp = offset_x
			offset_x = offset_z
			offset_z = temp
		
		scene_instance.position = Vector3(local_anchor.x + offset_x, local_anchor.y, local_anchor.z + offset_z) + fractional_pos
		scene_instance.rotation_degrees.y = rotation * 90
		
		# Add to group for identification
		scene_instance.add_to_group("placed_objects")
		scene_instance.set_meta("anchor", local_anchor)
		scene_instance.set_meta("chunk", self)
		scene_instance.set_meta("object_id", object_id)
		var has_authored_collision := ObjectRegistry.get_object_has_authored_collision(object_id)
		if _should_batch_proxy_visual(object_id):
			has_authored_collision = true

		if _should_batch_proxy_visual(object_id):
			var cells := ObjectRegistry.get_occupied_cells(object_id, local_anchor, rotation)
			var visual_data := ObjectRegistry.get_object_visual_data(object_id)
			if not visual_data.is_empty():
				place_proxy_visual_object(local_anchor, object_id, rotation, cells, scene_instance, fractional_pos, visual_data)
		
		# Objects that already ship with authored collision do not need the extra
		# generic collision cooking pass.
		if not has_authored_collision:
			# Generate collision now for manual loads; deferred mode keeps load spikes down.
			if defer_collision and manager and manager.has_method("queue_object_collision"):
				manager.queue_object_collision(self, scene_instance, local_anchor)
			else:
				_generate_object_collision_measured(scene_instance, local_anchor)

		object_nodes[local_anchor] = scene_instance

	for object_id_variant in simple_visual_batch_entries.keys():
		_rebuild_simple_visual_batch(int(object_id_variant))

	promote_simple_visual_batches_to_global()

func restore_object_visuals(defer_collision: bool = true):
	var baked_world_visual_mode := bool(manager and manager.has_method("is_baked_world_map_visual_mode_enabled") and manager.is_baked_world_map_visual_mode_enabled())
	var proxy_shell_activation_distance := 0.0
	var proxy_shell_activation_sq := 0.0
	var proxy_shell_culling_enabled := false
	var viewer_position := Vector3.ZERO
	var lazy_shell_activation_sq := 0.0
	if baked_world_visual_mode and manager.has_method("get_proxy_shell_activation_distance") and "viewer" in manager and manager.viewer and manager.has_method("get_viewer_position"):
		proxy_shell_activation_distance = float(manager.get_proxy_shell_activation_distance())
		if proxy_shell_activation_distance > 0.0:
			proxy_shell_activation_sq = proxy_shell_activation_distance * proxy_shell_activation_distance
			viewer_position = manager.get_viewer_position()
			proxy_shell_culling_enabled = true
			if manager.has_method("get_lazy_object_activation_distance"):
				var lazy_shell_activation_distance := float(manager.get_lazy_object_activation_distance())
				if lazy_shell_activation_distance > proxy_shell_activation_distance:
					lazy_shell_activation_sq = lazy_shell_activation_distance * lazy_shell_activation_distance

	for local_anchor in objects:
		# Skip if visual already exists
		if (object_nodes.has(local_anchor) and is_instance_valid(object_nodes[local_anchor])) or simple_visual_instances.has(local_anchor):
			continue
		var obj_data = objects[local_anchor]
		var object_id = obj_data.object_id
		var rotation = obj_data.rotation
		var fractional_pos: Vector3 = obj_data.get("fractional_pos", Vector3(0.0, float(obj_data.get("fractional_y", 0.0)), 0.0))
		if _should_batch_simple_visual(object_id):
			var cells := ObjectRegistry.get_occupied_cells(object_id, local_anchor, rotation)
			if place_simple_visual_object(local_anchor, object_id, rotation, cells, fractional_pos):
				continue

		var obj_def = ObjectRegistry.get_object(object_id)
		if obj_def.is_empty():
			continue

		var scene_path = obj_def.get("scene", "")
		if scene_path == "":
			continue

		var scene_instance: Node3D = null
		var should_spawn_runtime_shell := true
		var visual_data: Dictionary = {}
		if baked_world_visual_mode and _should_batch_proxy_visual(object_id):
			visual_data = ObjectRegistry.get_object_visual_data(object_id)
			if visual_data.is_empty():
				continue
			if proxy_shell_culling_enabled:
				var mesh_transform: Transform3D = visual_data.get("mesh_transform", Transform3D.IDENTITY)
				var final_transform := _build_simple_visual_transform(local_anchor, object_id, rotation, fractional_pos, mesh_transform)
				var chunk_origin := Transform3D(Basis.IDENTITY, Vector3(chunk_coord) * float(SIZE))
				var world_transform := chunk_origin * final_transform
				var shell_activation_sq := proxy_shell_activation_sq
				if lazy_shell_activation_sq > proxy_shell_activation_sq and ObjectRegistry.is_high_priority_proxy_visual_batch_object(object_id):
					shell_activation_sq = lazy_shell_activation_sq
				if world_transform.origin.distance_squared_to(viewer_position) > shell_activation_sq:
					should_spawn_runtime_shell = false

		if should_spawn_runtime_shell:
			if baked_world_visual_mode and ObjectRegistry.is_proxy_visual_batch_object(object_id):
				scene_instance = ObjectRegistry.create_proxy_gameplay_shell(object_id, true)
			if scene_instance == null:
				var packed = ObjectRegistry.get_preloaded_scene(scene_path)
				if not packed:
					continue
				scene_instance = packed.instantiate()
			if scene_instance and scene_instance.has_method("populate_loot") and bool(obj_data.get("should_populate_loot", false)):
				scene_instance.set_meta("should_populate_loot", true)

			add_child(scene_instance)
			if baked_world_visual_mode:
				_set_shadow_casting_recursive(scene_instance, true)
			var original_size = ObjectRegistry.get_object(object_id).get("size", Vector3i(1, 1, 1))
			var offset_x = float(original_size.x) / 2.0
			var offset_z = float(original_size.z) / 2.0

			if rotation == 1 or rotation == 3:
				var temp = offset_x
				offset_x = offset_z
				offset_z = temp

			scene_instance.position = Vector3(local_anchor.x + offset_x, local_anchor.y, local_anchor.z + offset_z) + fractional_pos
			scene_instance.rotation_degrees.y = rotation * 90
			scene_instance.add_to_group("placed_objects")
			scene_instance.set_meta("anchor", local_anchor)
			scene_instance.set_meta("chunk", self)
			scene_instance.set_meta("object_id", object_id)

		var has_authored_collision := ObjectRegistry.get_object_has_authored_collision(object_id)
		if _should_batch_proxy_visual(object_id):
			has_authored_collision = true

		if _should_batch_proxy_visual(object_id):
			var cells := ObjectRegistry.get_occupied_cells(object_id, local_anchor, rotation)
			if not visual_data.is_empty():
				place_proxy_visual_object(local_anchor, object_id, rotation, cells, scene_instance, fractional_pos, visual_data)

		if not has_authored_collision:
			if defer_collision and manager and manager.has_method("queue_object_collision"):
				manager.queue_object_collision(self, scene_instance, local_anchor)
			else:
				_generate_object_collision_measured(scene_instance, local_anchor)

		if scene_instance:
			object_nodes[local_anchor] = scene_instance
