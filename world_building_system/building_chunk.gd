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
var mesh_dirty: bool = true

# Visuals
var mesh_instance: MeshInstance3D
var static_body: StaticBody3D
var collision_shape: CollisionShape3D
var _pending_mesh_apply: Dictionary = {}

# Mesher Reference (injected by Manager)
var mesher: Node # BuildingMesher
var manager: Node # BuildingManager

static var _object_collision_shape_cache: Dictionary = {}
static var _box_collision_shape_cache: Dictionary = {}
const SIMPLE_OBJECT_COLLISION_IDS := {
	3: true, # Wooden Table
	5: true, # Window
	7: true, # Chair
}

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

func _init(coord: Vector3i):
	chunk_coord = coord
	# Resize and init with 0 (Air)
	voxel_bytes.resize(SIZE * SIZE * SIZE)
	voxel_bytes.fill(0)
	voxel_meta.resize(SIZE * SIZE * SIZE)
	voxel_meta.fill(0)

## Reset chunk for pool reuse - clears data without reallocating arrays
func reset(new_coord: Vector3i):
	chunk_coord = new_coord
	voxel_bytes.fill(0) # Clear all voxels to air
	voxel_meta.fill(0) # Clear all metadata
	is_empty = true
	mesh_dirty = true
	# Clear object data
	for anchor in object_nodes:
		var node = object_nodes[anchor]
		if node and is_instance_valid(node):
			node.queue_free()
	for anchor in object_collision_nodes:
		var collision_node = object_collision_nodes[anchor]
		if collision_node and is_instance_valid(collision_node):
			collision_node.queue_free()
	if manager and manager.world_map_mode and manager.has_method("remove_global_visual_batch"):
		for anchor in simple_visual_instances:
			manager.remove_global_visual_batch(anchor)
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
## Shared building material reused by all building chunks.
static func _get_shared_building_material() -> Material:
	return BuildingVisuals.get_shared_building_material()

func _ready():
	# Add to group for detection by player punch system
	add_to_group("building_chunks")

	# Setup Node Structure
	static_body = StaticBody3D.new()
	# The StaticBody3D needs the group so physics raycasts can identify what they hit
	static_body.add_to_group("building_chunks")
	
	# Layer 1 = Default (Player/Physics)
	# Layer 10 (512) = Terrain Special (for PickupItem detection)
	static_body.collision_layer = 1 + 512 
	add_child(static_body)
	
	mesh_instance = MeshInstance3D.new()
	static_body.add_child(mesh_instance)
	
	collision_shape = CollisionShape3D.new()
	static_body.add_child(collision_shape)

	if not _pending_mesh_apply.is_empty():
		var pending := _pending_mesh_apply
		_pending_mesh_apply = {}
		apply_mesh(
			pending.get("arrays", []),
			pending.get("shape", null),
			pending.get("source_mesh", null),
			pending.get("collision_boxes", [])
		)

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
	return manager and manager.world_map_mode and not ("skip_building_visual_batches_for_test" in manager and manager.skip_building_visual_batches_for_test) and ObjectRegistry.is_simple_visual_batch_object(object_id)

func _should_batch_proxy_visual(object_id: int) -> bool:
	return manager and manager.world_map_mode and not ("skip_building_visual_batches_for_test" in manager and manager.skip_building_visual_batches_for_test) and ObjectRegistry.is_proxy_visual_batch_object(object_id)

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
	for i in range(entries.size()):
		var entry: Dictionary = entries[i]
		var transform: Transform3D = entry.get("transform", Transform3D.IDENTITY)
		multimesh.set_instance_transform(i, transform)

func _remove_simple_visual_batch_instance(local_anchor: Vector3i) -> bool:
	if not simple_visual_instances.has(local_anchor):
		return false

	var instance_data: Dictionary = simple_visual_instances[local_anchor]
	var object_id := int(instance_data.get("object_id", -1))
	simple_visual_instances.erase(local_anchor)
	if manager and manager.world_map_mode and manager.has_method("remove_global_visual_batch"):
		manager.remove_global_visual_batch(local_anchor)
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

	objects[local_anchor] = {"object_id": object_id, "rotation": rotation, "fractional_pos": fractional_pos}
	for cell in cells:
		occupied_by_object[cell] = local_anchor

	simple_visual_instances[local_anchor] = {
		"object_id": object_id,
		"rotation": rotation,
		"fractional_pos": fractional_pos
	}
	var final_transform := _build_simple_visual_transform(local_anchor, object_id, rotation, fractional_pos, mesh_transform)
	if manager and manager.world_map_mode and manager.has_method("register_global_visual_batch"):
		var chunk_origin := Transform3D(Basis.IDENTITY, Vector3(chunk_coord) * float(SIZE))
		var world_transform := chunk_origin * final_transform
		if manager.register_global_visual_batch(local_anchor, object_id, world_transform, mesh, defer_global_visual_batch_rebuild):
			is_empty = false
			return true
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

	objects[local_anchor] = {"object_id": object_id, "rotation": rotation, "fractional_pos": fractional_pos}
	for cell in cells:
		occupied_by_object[cell] = local_anchor

	simple_visual_instances[local_anchor] = {
		"object_id": object_id,
		"rotation": rotation,
		"fractional_pos": fractional_pos
	}

	if scene_instance:
		if manager and manager.world_map_mode:
			_set_shadow_casting_recursive(scene_instance, true)
		_hide_mesh_descendants(scene_instance)
		if ObjectRegistry.get_object_has_authored_collision(object_id):
			_prune_proxy_visual_children(scene_instance)

	var final_transform := _build_simple_visual_transform(local_anchor, object_id, rotation, fractional_pos, mesh_transform)
	if manager and manager.world_map_mode and manager.has_method("register_global_visual_batch"):
		var chunk_origin := Transform3D(Basis.IDENTITY, Vector3(chunk_coord) * float(SIZE))
		var world_transform := chunk_origin * final_transform
		if manager.register_global_visual_batch(local_anchor, object_id, world_transform, mesh, defer_global_visual_batch_rebuild):
			is_empty = false
			return true
	_append_simple_visual_batch_instance(object_id, local_anchor, final_transform, mesh)
	is_empty = false
	return true

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
	
	var apply_start_us := Time.get_ticks_usec()
	var use_source_mesh := source_mesh != null
	var skip_mesh_render := bool(manager and "skip_building_chunk_mesh_render_for_test" in manager and manager.skip_building_chunk_mesh_render_for_test)
	var is_world_map_mode := bool(manager and manager.world_map_mode)
	var measure_building_apply := not is_world_map_mode
	if measure_building_apply:
		PerformanceMonitor.start_measure("Building Apply Mesh")
	var mesh: ArrayMesh = mesh_instance.mesh as ArrayMesh
	if use_source_mesh:
		mesh = source_mesh
	if mesh == null:
		mesh = ArrayMesh.new()
	elif not use_source_mesh:
		mesh.clear_surfaces()

	var mesh_upload_elapsed_ms := 0.0
	var collision_clear_elapsed_ms := 0.0
	var collision_boxes_elapsed_ms := 0.0
	var collision_primary_elapsed_ms := 0.0
	var collision_trimesh_elapsed_ms := 0.0
	var collision_mode := "none"

	if arrays.size() > 0 or use_source_mesh:
		var mesh_upload_start_us := Time.get_ticks_usec()
		if measure_building_apply:
			PerformanceMonitor.start_measure("Building Mesh Upload")
		if skip_mesh_render:
			mesh_instance.visible = false
			mesh_instance.mesh = null
		else:
			mesh_instance.visible = true
			if use_source_mesh:
				mesh_instance.mesh = mesh
			else:
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			if mesh_instance.mesh != mesh:
				mesh_instance.mesh = mesh
			var shared_material := _get_shared_building_material()
			if mesh_instance.material_override != shared_material:
				mesh_instance.material_override = shared_material
			if mesh_instance.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
				mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if measure_building_apply:
			PerformanceMonitor.end_measure("Building Mesh Upload", 0.5)
		mesh_upload_elapsed_ms = float(Time.get_ticks_usec() - mesh_upload_start_us) / 1000.0
	else:
		if mesh_instance.mesh != mesh:
			mesh_instance.mesh = mesh
		_clear_static_body_shapes()
		mesh_dirty = false
		PerformanceMonitor.capture_scope_event("buildings", "mesh_apply_complete", {
			"chunk_coord": str(chunk_coord),
			"arrays_count": arrays.size(),
			"use_source_mesh": use_source_mesh,
			"skip_mesh_render": skip_mesh_render,
			"world_map_mode": bool(manager and manager.world_map_mode),
			"collision_boxes_count": collision_boxes.size(),
			"mesh_surface_count": mesh.get_surface_count() if mesh else 0,
			"mesh_upload_elapsed_ms": 0.0,
			"collision_clear_elapsed_ms": 0.0,
			"collision_boxes_elapsed_ms": 0.0,
			"collision_primary_elapsed_ms": 0.0,
			"collision_trimesh_elapsed_ms": 0.0,
			"collision_mode": "none",
			"total_elapsed_ms": float(Time.get_ticks_usec() - apply_start_us) / 1000.0
		})
		if measure_building_apply:
			PerformanceMonitor.end_measure("Building Apply Mesh", 1.0)
		return

	if _should_skip_chunk_collisions():
		var clear_start_us := Time.get_ticks_usec()
		_clear_static_body_shapes()
		collision_clear_elapsed_ms = float(Time.get_ticks_usec() - clear_start_us) / 1000.0
		mesh_dirty = false
		PerformanceMonitor.capture_scope_event("buildings", "chunk_collision_skipped", {
			"chunk_coord": str(chunk_coord),
			"world_map_mode": bool(manager and manager.world_map_mode)
		})
		PerformanceMonitor.capture_scope_event("buildings", "mesh_apply_complete", {
			"chunk_coord": str(chunk_coord),
			"arrays_count": arrays.size(),
			"use_source_mesh": use_source_mesh,
			"skip_mesh_render": skip_mesh_render,
			"world_map_mode": bool(manager and manager.world_map_mode),
			"collision_boxes_count": collision_boxes.size(),
			"mesh_surface_count": mesh_instance.mesh.get_surface_count() if mesh_instance.mesh else 0,
			"mesh_upload_elapsed_ms": mesh_upload_elapsed_ms,
			"collision_clear_elapsed_ms": collision_clear_elapsed_ms,
			"collision_boxes_elapsed_ms": 0.0,
			"collision_primary_elapsed_ms": 0.0,
			"collision_trimesh_elapsed_ms": 0.0,
			"collision_mode": "skipped",
			"total_elapsed_ms": float(Time.get_ticks_usec() - apply_start_us) / 1000.0
		})
		if measure_building_apply:
			PerformanceMonitor.end_measure("Building Apply Mesh", 1.0)
		return

	# World-map buildings use merged box colliders so the physics server handles fewer shapes.
	# This keeps the block occupancy collision exact at voxel resolution while avoiding trimesh cooking.
	if manager and manager.world_map_mode and collision_boxes.size() > 0:
		collision_mode = "boxes"
		var collision_start_us := Time.get_ticks_usec()
		if measure_building_apply:
			PerformanceMonitor.start_measure("Building Collision Shape")
		var handled_native_boxes := false
		if mesher and mesher.has_method("apply_world_map_collision_boxes") and static_body:
			handled_native_boxes = mesher.apply_world_map_collision_boxes(static_body.get_rid(), collision_boxes)
		if not handled_native_boxes:
			_clear_static_body_shapes()
			_apply_collision_boxes(collision_boxes)
		if measure_building_apply:
			PerformanceMonitor.end_measure("Building Collision Shape", 0.5)
		collision_boxes_elapsed_ms = float(Time.get_ticks_usec() - collision_start_us) / 1000.0
	else:
		# Use native shape when available; otherwise build a native trimesh shape from the mesh resource.
		var clear_start_us := Time.get_ticks_usec()
		_clear_static_body_shapes()
		collision_clear_elapsed_ms = float(Time.get_ticks_usec() - clear_start_us) / 1000.0
		if _shape_is_usable(shape):
			collision_mode = "native_shape"
			var collision_start_us := Time.get_ticks_usec()
			_apply_primary_collision_shape(shape)
			collision_primary_elapsed_ms = float(Time.get_ticks_usec() - collision_start_us) / 1000.0
		elif mesh_instance.mesh and mesh_instance.mesh.get_surface_count() > 0:
			collision_mode = "trimesh"
			var collision_start_us := Time.get_ticks_usec()
			PerformanceMonitor.start_measure("Building Collision Shape")
			var native_trimesh_shape := _build_native_trimesh_collision_shape(mesh_instance.mesh)
			if _shape_is_usable(native_trimesh_shape):
				_apply_primary_collision_shape(native_trimesh_shape)
			PerformanceMonitor.end_measure("Building Collision Shape", 0.5)
			collision_trimesh_elapsed_ms = float(Time.get_ticks_usec() - collision_start_us) / 1000.0
	
	mesh_dirty = false
	if not is_world_map_mode:
		var mesh_apply_event := {
			"chunk_coord": str(chunk_coord),
			"arrays_count": arrays.size(),
			"use_source_mesh": use_source_mesh,
			"skip_mesh_render": skip_mesh_render,
			"world_map_mode": is_world_map_mode,
			"collision_boxes_count": collision_boxes.size(),
			"mesh_surface_count": mesh_instance.mesh.get_surface_count() if mesh_instance.mesh else 0,
			"mesh_upload_elapsed_ms": mesh_upload_elapsed_ms,
			"collision_mode": collision_mode,
			"total_elapsed_ms": float(Time.get_ticks_usec() - apply_start_us) / 1000.0
		}
		mesh_apply_event["collision_clear_elapsed_ms"] = collision_clear_elapsed_ms
		mesh_apply_event["collision_boxes_elapsed_ms"] = collision_boxes_elapsed_ms
		mesh_apply_event["collision_primary_elapsed_ms"] = collision_primary_elapsed_ms
		mesh_apply_event["collision_trimesh_elapsed_ms"] = collision_trimesh_elapsed_ms
		PerformanceMonitor.capture_scope_event("buildings", "mesh_apply_complete", mesh_apply_event)
	if measure_building_apply:
		PerformanceMonitor.end_measure("Building Apply Mesh", 1.0)


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

	var body_rid := static_body.get_rid()
	if not body_rid.is_valid():
		return

	if not _shape_is_usable(shape):
		return

	PhysicsServer3D.body_add_shape(body_rid, shape.get_rid(), Transform3D.IDENTITY)

func _clear_static_body_shapes() -> void:
	if static_body and is_instance_valid(static_body):
		var body_rid := static_body.get_rid()
		if body_rid.is_valid():
			var shape_count := PhysicsServer3D.body_get_shape_count(body_rid)
			for shape_idx in range(shape_count - 1, -1, -1):
				PhysicsServer3D.body_remove_shape(body_rid, shape_idx)
func _shape_is_usable(candidate: Shape3D) -> bool:
	if candidate == null:
		return false
	if candidate is ConcavePolygonShape3D:
		return candidate.get_faces().size() > 0
	return true

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
	objects[local_anchor] = {"object_id": object_id, "rotation": rotation, "fractional_pos": fractional_pos}
	
	# Mark all occupied cells
	for cell in cells:
		occupied_by_object[cell] = local_anchor

	# Add visual instance with collision
	if scene_instance:
		add_child(scene_instance)
		if manager and manager.world_map_mode:
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
	PerformanceMonitor.start_measure("Building Object Collision")
	var object_id := int(obj.get_meta("object_id", -1))
	if _should_use_simple_object_collision(object_id):
		_generate_simple_object_collision(obj, anchor, object_id)
	else:
		_generate_object_collision(obj, anchor)
	PerformanceMonitor.end_measure("Building Object Collision", 0.5)

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

	var mesh_global_transform := obj.global_transform * mesh_transform
	var aabb := mesh.get_aabb()
	var box_size := Vector3(
		maxf(aabb.size.x, 0.05),
		maxf(aabb.size.y, 0.05),
		maxf(aabb.size.z, 0.05)
	)

	var collision := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box_size
	collision.shape = box_shape
	collision.set_meta("anchor", anchor)
	collision.set_meta("chunk", self)
	collision.set_meta("object_id", object_id)
	collision.global_transform = mesh_global_transform * Transform3D(Basis.IDENTITY, aabb.position + (aabb.size * 0.5))
	static_body.add_child(collision)
	object_collision_nodes[anchor] = collision

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
		DebugManager.log_building("BuildingChunk: Skipping collision for interactable object")
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
func restore_object_visuals(defer_collision: bool = true):
	PerformanceMonitor.start_measure("Building Restore Visuals")
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
			print("BuildingChunk: restore_object_visuals - Unknown object_id: ", object_id)
			continue
		
		var scene_path = obj_def.get("scene", "")
		if scene_path == "":
			continue
		
		var scene_instance: Node3D = null
		if manager and manager.world_map_mode and ObjectRegistry.is_proxy_visual_batch_object(object_id):
			scene_instance = ObjectRegistry.create_proxy_gameplay_shell(object_id, manager.world_map_mode)
		if scene_instance == null:
			var packed = ObjectRegistry.get_preloaded_scene(scene_path)
			if not packed:
				print("BuildingChunk: restore_object_visuals - Failed to load scene: ", scene_path)
				continue
			scene_instance = packed.instantiate()
		
		# Add and position the visual
		add_child(scene_instance)
		if manager and manager.world_map_mode:
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

	print("BuildingChunk: Restored %d object visuals" % (object_nodes.size() + simple_visual_instances.size()))
	PerformanceMonitor.end_measure("Building Restore Visuals", 2.0)
