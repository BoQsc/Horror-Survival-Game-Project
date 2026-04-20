extends Node3D

const BuildingBakeSnapshot = preload("res://world_building_system/building_bake_snapshot.gd")

# Maps Vector3i (Chunk Coord) -> BuildingChunk (data always persisted)
var chunks: Dictionary = {}
var mesher: BuildingMesher

# Render distance management
@export var viewer: Node3D
@export var render_distance: int = 8 # Increased for better visibility
var _last_building_viewer_chunk: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _cached_vehicle_manager: Node = null

# Track which chunks are currently visible (have nodes in scene tree)
var visible_chunks: Dictionary = {} # Vector3i -> true

# Chunk pool for recycling (multiplayer optimization)
var chunk_pool: Array[BuildingChunk] = []
const MAX_POOL_SIZE = 32 # Keep up to 32 chunks in pool

@export_range(0.5, 20.0, 0.5) var object_collision_budget_ms: float = 2.0
@export_range(1, 32, 1) var dirty_chunk_flush_budget: int = 4
var skip_object_collisions_for_test: bool = false
var skip_building_chunk_collisions_for_test: bool = false
var skip_building_chunk_mesh_render_for_test: bool = false
var skip_building_visual_batches_for_test: bool = false
var _pending_object_collision_tasks: Array[Dictionary] = []

# Global world-map visual batching for repeated props
var _global_visual_batch_instances: Dictionary = {} # Vector3i anchor -> { object_id, transform, mesh }
var _global_visual_batch_entries: Dictionary = {} # int object_id -> Array[{ anchor, transform }]
var _global_visual_batch_nodes: Dictionary = {} # int object_id -> MultiMeshInstance3D
var _dirty_global_visual_batch_object_ids: Dictionary = {} # int object_id -> true

# Batched operations - accumulate changes, rebuild once
var _dirty_chunks: Dictionary = {} # Vector3i -> BuildingChunk (chunks needing rebuild)
var _dirty_visible_chunk_count: int = 0
var _last_flush_dirty_chunks_ms: float = 0.0
var _last_flush_dirty_chunks_count: int = 0
var _last_flush_global_visual_batches_ms: float = 0.0
var _last_flush_global_visual_batches_count: int = 0
var baked_buildings_loaded: bool = false
var baked_buildings_world_path: String = ""
var baked_building_manifest: Dictionary = {}
var baked_building_manifest_index: Dictionary = {}
var baked_building_snapshot_cache: Dictionary = {}
var baked_building_loaded_chunk_keys: Dictionary = {}
var _last_baked_building_load_ms: float = 0.0
var _last_baked_building_load_chunks: int = 0
var _last_baked_building_manifest_chunks: int = 0
var _last_baked_building_load_mode: String = "none"

const CHUNK_SIZE = 16 # Must match BuildingChunk.SIZE

# Building map layer — tracks building block footprints on a 2D map
const MAP_SIZE: int = 2048  # Must match WorldMapGenerator.MAP_SIZE
var building_map: Image = null  # R8 image, 255 = building, 0 = empty
var minimap_image: Image = null  # Reference to HUDMinimap's RGB8 image (set by minimap)
var world_map_mode: bool = false  # Set at startup — disables minimap writes (PNG is pre-baked)

## Initialize building_map if not already loaded from disk
func _ensure_building_map() -> void:
	if building_map == null:
		building_map = Image.create(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8)
		building_map.fill(Color(0, 0, 0, 1))

## Set building_map from loaded data (called by chunk_manager on world load)
func set_building_map(img: Image) -> void:
	building_map = img

## Get the current building_map for saving / preview
func get_building_map() -> Image:
	_ensure_building_map()
	return building_map

## Update a pixel on the building_map when a block is placed or removed
## In world map mode: minimap writes disabled (pre-baked from PNG, corrections via clear_building_area)
## In procedural mode: minimap writes enabled for real-time building feedback
func _update_building_map_pixel(global_pos: Vector3, is_set: bool) -> void:
	if world_map_mode:
		return
	_ensure_building_map()
	var half = MAP_SIZE / 2
	var px = int(floor(global_pos.x)) + half
	var pz = int(floor(global_pos.z)) + half
	if px < 0 or px >= MAP_SIZE or pz < 0 or pz >= MAP_SIZE:
		return
	var val = 1.0 if is_set else 0.0
	building_map.set_pixel(px, pz, Color(val, 0, 0, 1))
	
	# Update minimap pixels for real-time feedback (both procedural and world map modes)
	if minimap_image:
		if is_set:
			minimap_image.set_pixel(px, pz, Color(0.86, 0.31, 0.16, 1.0))
		else:
			minimap_image.set_pixel(px, pz, Color(0.31, 0.63, 0.24, 1.0))
		# Signal minimap to re-upload texture to GPU
		var hud_minimap = get_tree().get_first_node_in_group("hud_minimap")
		if hud_minimap and hud_minimap.has_method("mark_dirty"):
			hud_minimap.mark_dirty()

func _ready():
	# Preload all object scenes for faster building spawning
	ObjectRegistry.preload_all_scenes()
	
	mesher = BuildingMesher.new()
	add_child(mesher)
	
	# Find player if not assigned
	if not viewer:
		viewer = get_tree().get_first_node_in_group("player")

func _process(_delta):
	if viewer:
		var p_pos = get_viewer_position()
		var center_chunk = Vector3i(
			floor(p_pos.x / CHUNK_SIZE),
			floor(p_pos.y / CHUNK_SIZE),
			floor(p_pos.z / CHUNK_SIZE)
		)
		if center_chunk != _last_building_viewer_chunk:
			_last_building_viewer_chunk = center_chunk
			update_building_chunks(center_chunk)
	_process_pending_object_collisions()

## Gets effective viewer position - returns vehicle position if player is driving
func get_viewer_position() -> Vector3:
	if not viewer:
		return Vector3.ZERO
	
	# Check if player is in a vehicle
	var vm = _get_vehicle_manager()
	if vm and "current_player_vehicle" in vm and vm.current_player_vehicle:
		return vm.current_player_vehicle.global_position
	
	return viewer.global_position

func _get_vehicle_manager() -> Node:
	if _cached_vehicle_manager and is_instance_valid(_cached_vehicle_manager):
		return _cached_vehicle_manager

	_cached_vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	return _cached_vehicle_manager

func update_building_chunks(center_chunk: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)):
	if center_chunk.x == 2147483647:
		var p_pos = get_viewer_position()
		center_chunk = Vector3i(
			floor(p_pos.x / CHUNK_SIZE),
			floor(p_pos.y / CHUNK_SIZE),
			floor(p_pos.z / CHUNK_SIZE)
		)
	var render_distance_sq := render_distance * render_distance
	
	# 1. Unload chunks that are too far (remove from scene tree, keep data)
	var chunks_to_unload = []
	for coord in visible_chunks:
		var dx = coord.x - center_chunk.x
		var dy = coord.y - center_chunk.y
		var dz = coord.z - center_chunk.z
		var dist_sq = dx * dx + dy * dy + dz * dz
		if dist_sq > (render_distance + 2) * (render_distance + 2):
			chunks_to_unload.append(coord)
	
	for coord in chunks_to_unload:
		_unload_chunk_visual(coord)
	
	# 2. Load chunks that are in range and have data
	for coord in chunks:
		if visible_chunks.has(coord):
			continue # Already visible
		
		var dx = coord.x - center_chunk.x
		var dy = coord.y - center_chunk.y
		var dz = coord.z - center_chunk.z
		var dist_sq = dx * dx + dy * dy + dz * dz
		if dist_sq <= render_distance_sq:
			_load_chunk_visual(coord)

func _unload_chunk_visual(coord: Vector3i):
	if not chunks.has(coord):
		return
	
	var chunk = chunks[coord]
	var was_visible := visible_chunks.has(coord)
	if was_visible and _dirty_chunks.has(coord):
		_dirty_visible_chunk_count = maxi(0, _dirty_visible_chunk_count - 1)
	if chunk.is_inside_tree():
		remove_child(chunk)
	
	visible_chunks.erase(coord)

func _load_chunk_visual(coord: Vector3i):
	if not chunks.has(coord):
		return
	
	var chunk = chunks[coord]
	var was_visible := visible_chunks.has(coord)
	if not chunk.is_inside_tree():
		add_child(chunk)
		chunk.position = Vector3(coord) * CHUNK_SIZE
		# Rebuild mesh if chunk has data
		if not chunk.is_empty and chunk.is_mesh_dirty():
			chunk.rebuild_mesh()
	
	visible_chunks[coord] = true
	if not was_visible and _dirty_chunks.has(coord):
		_dirty_visible_chunk_count += 1

func queue_object_collision(chunk: BuildingChunk, obj: Node3D, anchor: Vector3i) -> void:
	if not chunk or not obj:
		return
	if not is_instance_valid(chunk) or not is_instance_valid(obj):
		return
	if skip_object_collisions_for_test:
		return

	_pending_object_collision_tasks.append({
		"chunk": chunk,
		"obj": obj,
		"anchor": anchor
	})

func mark_chunk_dirty(chunk_coord: Vector3i, chunk: BuildingChunk) -> void:
	if not chunk or not is_instance_valid(chunk):
		return
	var was_dirty := _dirty_chunks.has(chunk_coord)
	chunk.mark_mesh_dirty()
	_dirty_chunks[chunk_coord] = chunk
	if not was_dirty and visible_chunks.has(chunk_coord):
		_dirty_visible_chunk_count += 1

func _process_pending_object_collisions() -> void:
	if _pending_object_collision_tasks.is_empty():
		return
	if skip_object_collisions_for_test:
		_pending_object_collision_tasks.clear()
		return

	var processed := 0
	var start_time := Time.get_ticks_usec()

	while not _pending_object_collision_tasks.is_empty():
		if processed > 0:
			var elapsed_ms := float(Time.get_ticks_usec() - start_time) / 1000.0
			if elapsed_ms >= object_collision_budget_ms:
				break

		var task: Dictionary = _pending_object_collision_tasks.pop_back()
		var chunk: BuildingChunk = task.get("chunk")
		var obj: Node3D = task.get("obj")
		var anchor: Vector3i = task.get("anchor", Vector3i.ZERO)

		if not is_instance_valid(chunk) or not is_instance_valid(obj):
			continue

		chunk._generate_object_collision(obj, anchor)
		processed += 1

func clear_pending_object_collision_tasks() -> void:
	_pending_object_collision_tasks.clear()

func register_global_visual_batch(anchor: Vector3i, object_id: int, transform: Transform3D, mesh: Mesh, defer_rebuild: bool = false) -> bool:
	if skip_building_visual_batches_for_test or object_id < 0 or not mesh:
		return false

	_global_visual_batch_instances[anchor] = {
		"object_id": object_id,
		"transform": transform,
		"mesh": mesh
	}

	var entries: Array = _global_visual_batch_entries.get(object_id, [])
	entries.append({
		"anchor": anchor,
		"transform": transform
	})
	_global_visual_batch_entries[object_id] = entries
	var batch_node: MultiMeshInstance3D = _global_visual_batch_nodes.get(object_id, null)
	var can_append := batch_node and is_instance_valid(batch_node) and not _dirty_global_visual_batch_object_ids.has(object_id)
	if can_append:
		_append_global_visual_batch_instance(object_id, transform, mesh)
	elif defer_rebuild:
		_dirty_global_visual_batch_object_ids[object_id] = true
	else:
		_rebuild_global_visual_batch(object_id, mesh)
	return true

func remove_global_visual_batch(anchor: Vector3i) -> bool:
	if not _global_visual_batch_instances.has(anchor):
		return false

	var instance_data: Dictionary = _global_visual_batch_instances[anchor]
	var object_id := int(instance_data.get("object_id", -1))
	_global_visual_batch_instances.erase(anchor)

	if not _global_visual_batch_entries.has(object_id):
		return true

	var entries: Array = _global_visual_batch_entries[object_id]
	var filtered: Array = []
	for entry_variant in entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		if Vector3i(entry.get("anchor", Vector3i.ZERO)) != anchor:
			filtered.append(entry)

	if filtered.is_empty():
		_global_visual_batch_entries.erase(object_id)
		if _global_visual_batch_nodes.has(object_id):
			var node = _global_visual_batch_nodes[object_id]
			if node and is_instance_valid(node):
				node.queue_free()
			_global_visual_batch_nodes.erase(object_id)
		return true

	_global_visual_batch_entries[object_id] = filtered
	_rebuild_global_visual_batch(object_id, instance_data.get("mesh", null))
	return true

func clear_global_visual_batches() -> void:
	for node in _global_visual_batch_nodes.values():
		if node and is_instance_valid(node):
			node.queue_free()
	_global_visual_batch_instances.clear()
	_global_visual_batch_entries.clear()
	_global_visual_batch_nodes.clear()
	_dirty_global_visual_batch_object_ids.clear()


func clear_for_shutdown() -> void:
	clear_pending_object_collision_tasks()
	clear_global_visual_batches()
	for chunk in chunk_pool:
		if chunk and is_instance_valid(chunk):
			chunk.queue_free()
	chunk_pool.clear()
	chunks.clear()
	visible_chunks.clear()
	_dirty_chunks.clear()
	_cached_vehicle_manager = null


func clear_immediate_for_shutdown() -> void:
	clear_pending_object_collision_tasks()
	for node in _global_visual_batch_nodes.values():
		if node and is_instance_valid(node):
			node.free()
	for chunk in chunk_pool:
		if chunk and is_instance_valid(chunk):
			chunk.free()
	chunk_pool.clear()
	chunks.clear()
	visible_chunks.clear()
	_dirty_chunks.clear()
	_global_visual_batch_instances.clear()
	_global_visual_batch_entries.clear()
	_global_visual_batch_nodes.clear()
	_dirty_global_visual_batch_object_ids.clear()
	_cached_vehicle_manager = null


func clear_all_building_chunks() -> void:
	if mesher and mesher.has_method("clear_pending_work"):
		mesher.clear_pending_work()
	clear_immediate_for_shutdown()
	baked_buildings_loaded = false
	baked_buildings_world_path = ""
	baked_building_manifest.clear()
	baked_building_manifest_index.clear()
	baked_building_snapshot_cache.clear()
	baked_building_loaded_chunk_keys.clear()
	_last_baked_building_load_ms = 0.0
	_last_baked_building_load_chunks = 0
	_last_baked_building_manifest_chunks = 0
	_last_baked_building_load_mode = "none"
	_dirty_visible_chunk_count = 0
	_last_building_viewer_chunk = Vector3i(2147483647, 2147483647, 2147483647)


func _exit_tree() -> void:
	clear_immediate_for_shutdown()

func flush_global_visual_batches() -> void:
	if _dirty_global_visual_batch_object_ids.is_empty():
		return

	var start_time := Time.get_ticks_usec()
	var dirty_ids: Array = _dirty_global_visual_batch_object_ids.keys()
	_dirty_global_visual_batch_object_ids.clear()
	var rebuilt := 0
	for object_id_variant in dirty_ids:
		var object_id: int = int(object_id_variant)
		var entries: Array = _global_visual_batch_entries.get(object_id, [])
		if entries.is_empty():
			continue
		var mesh: Mesh = null
		var first_entry: Dictionary = entries[0]
		var first_anchor: Vector3i = first_entry.get("anchor", Vector3i.ZERO)
		if _global_visual_batch_instances.has(first_anchor):
			mesh = _global_visual_batch_instances[first_anchor].get("mesh", null)
		if mesh == null:
			var visual_data := ObjectRegistry.get_object_visual_data(object_id)
			mesh = visual_data.get("mesh")
		_rebuild_global_visual_batch(object_id, mesh)
		rebuilt += 1
	_last_flush_global_visual_batches_ms = float(Time.get_ticks_usec() - start_time) / 1000.0
	_last_flush_global_visual_batches_count = rebuilt
func has_dirty_global_visual_batches() -> bool:
	return not _dirty_global_visual_batch_object_ids.is_empty()

func _get_global_visual_batch_node(object_id: int, mesh: Mesh) -> MultiMeshInstance3D:
	if _global_visual_batch_nodes.has(object_id):
		var existing: MultiMeshInstance3D = _global_visual_batch_nodes[object_id]
		if existing and is_instance_valid(existing):
			existing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			return existing

	var batch_node := MultiMeshInstance3D.new()
	batch_node.name = "GlobalVisualBatch_%d" % object_id
	batch_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(batch_node)
	_global_visual_batch_nodes[object_id] = batch_node

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = 0
	batch_node.multimesh = multimesh
	return batch_node

func _append_global_visual_batch_instance(object_id: int, transform: Transform3D, mesh: Mesh) -> void:
	var batch_node := _get_global_visual_batch_node(object_id, mesh)
	if not batch_node:
		return

	var multimesh: MultiMesh = batch_node.multimesh
	if not multimesh:
		multimesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		batch_node.multimesh = multimesh
	elif multimesh.mesh != mesh:
		multimesh.mesh = mesh

	var next_index := multimesh.instance_count
	multimesh.instance_count = next_index + 1
	multimesh.set_instance_transform(next_index, transform)

func _rebuild_global_visual_batch(object_id: int, mesh: Mesh = null) -> void:
	if not _global_visual_batch_entries.has(object_id):
		if _global_visual_batch_nodes.has(object_id):
			var node = _global_visual_batch_nodes[object_id]
			if node and is_instance_valid(node):
				node.queue_free()
			_global_visual_batch_nodes.erase(object_id)
		return

	var entries: Array = _global_visual_batch_entries[object_id]
	if entries.is_empty():
		_global_visual_batch_entries.erase(object_id)
		if _global_visual_batch_nodes.has(object_id):
			var empty_node = _global_visual_batch_nodes[object_id]
			if empty_node and is_instance_valid(empty_node):
				empty_node.queue_free()
			_global_visual_batch_nodes.erase(object_id)
		return

	if mesh == null:
		var visual_data := ObjectRegistry.get_object_visual_data(object_id)
		if visual_data.is_empty():
			return
		mesh = visual_data.get("mesh")
	if not mesh:
		return

	var batch_node := _get_global_visual_batch_node(object_id, mesh)
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

func get_telemetry_snapshot() -> Dictionary:
	var total_objects := 0
	var total_object_nodes := 0
	var total_object_collision_nodes := 0
	var total_collision_box_shapes := 0
	var total_simple_visual_instances := 0
	var total_visual_batches := 0
	var total_occupied_cells := 0
	var total_mesh_dirty_chunks := _dirty_chunks.size()
	var total_dirty_visible_chunks := _dirty_visible_chunk_count
	var total_dirty_hidden_chunks := maxi(0, total_mesh_dirty_chunks - total_dirty_visible_chunks)

	for chunk_coord_variant in chunks:
		var chunk: BuildingChunk = chunks[chunk_coord_variant]
		if not chunk or not is_instance_valid(chunk):
			continue

		total_objects += chunk.objects.size()
		total_object_nodes += chunk.object_nodes.size()
		total_object_collision_nodes += chunk.object_collision_nodes.size()
		total_collision_box_shapes += 1 if chunk.collision_shape else 0
		total_simple_visual_instances += chunk.simple_visual_instances.size()
		total_visual_batches += chunk.simple_visual_batch_nodes.size()
		total_occupied_cells += chunk.occupied_by_object.size()

	return {
		"phase": "object_collision_queue" if not _pending_object_collision_tasks.is_empty() else "idle",
		"world_map_mode": world_map_mode,
		"render_distance": render_distance,
		"object_collision_budget_ms": object_collision_budget_ms,
		"skip_object_collisions_for_test": skip_object_collisions_for_test,
		"skip_building_chunk_collisions_for_test": skip_building_chunk_collisions_for_test,
		"skip_building_chunk_mesh_render_for_test": skip_building_chunk_mesh_render_for_test,
		"skip_building_visual_batches_for_test": skip_building_visual_batches_for_test,
		"chunk_count": chunks.size(),
		"visible_chunk_count": visible_chunks.size(),
		"dirty_chunk_count": _dirty_chunks.size(),
		"pending_object_collision_jobs": _pending_object_collision_tasks.size(),
		"chunk_pool_size": chunk_pool.size(),
		"total_objects": total_objects,
		"total_object_nodes": total_object_nodes,
		"total_object_collision_nodes": total_object_collision_nodes,
		"total_collision_box_nodes": total_collision_box_shapes,
		"total_simple_visual_instances": total_simple_visual_instances,
		"total_visual_batches": total_visual_batches,
		"total_global_visual_batches": _global_visual_batch_nodes.size(),
		"total_global_visual_instances": _global_visual_batch_instances.size(),
		"pending_visual_batch_rebuilds": _dirty_global_visual_batch_object_ids.size(),
		"total_occupied_cells": total_occupied_cells,
		"mesh_dirty_chunks": total_mesh_dirty_chunks,
		"dirty_visible_chunk_count": total_dirty_visible_chunks,
		"dirty_hidden_chunk_count": total_dirty_hidden_chunks,
		"last_flush_dirty_chunks_ms": _last_flush_dirty_chunks_ms,
		"last_flush_dirty_chunks_count": _last_flush_dirty_chunks_count,
		"last_flush_global_visual_batches_ms": _last_flush_global_visual_batches_ms,
		"last_flush_global_visual_batches_count": _last_flush_global_visual_batches_count,
		"baked_buildings_loaded": baked_buildings_loaded,
		"baked_buildings_world_path": baked_buildings_world_path,
		"cached_baked_snapshot_count": baked_building_snapshot_cache.size(),
		"loaded_baked_chunk_count": baked_building_loaded_chunk_keys.size(),
		"baked_buildings_fully_loaded": is_baked_buildings_fully_loaded(),
		"baked_building_load_profile": {
			"mode": _last_baked_building_load_mode,
			"load_ms": _last_baked_building_load_ms,
			"loaded_chunks": _last_baked_building_load_chunks,
			"manifest_chunks": _last_baked_building_manifest_chunks
		}
	}

## Get or create a chunk at the given coordinate. Uses pool for recycling.
func get_chunk(chunk_coord: Vector3i) -> BuildingChunk:
	if chunks.has(chunk_coord):
		return chunks[chunk_coord]
	
	# Get chunk from pool or create new one
	var chunk: BuildingChunk
	if chunk_pool.size() > 0:
		chunk = chunk_pool.pop_back()
		chunk.reset(chunk_coord) # Recycle: clear and assign new coord
	else:
		chunk = BuildingChunk.new(chunk_coord) # Pool empty: create new
	
	chunk.mesher = mesher # Inject dependency
	chunk.manager = self
	chunks[chunk_coord] = chunk
	
	# Only add to tree if within render distance
	if viewer:
		var p_pos = viewer.global_position
		var p_chunk = Vector3i(floor(p_pos.x / CHUNK_SIZE), floor(p_pos.y / CHUNK_SIZE), floor(p_pos.z / CHUNK_SIZE))
		var dx = chunk_coord.x - p_chunk.x
		var dy = chunk_coord.y - p_chunk.y
		var dz = chunk_coord.z - p_chunk.z
		var dist_sq = dx * dx + dy * dy + dz * dz
		
		if dist_sq <= render_distance * render_distance:
			add_child(chunk)
			chunk.position = Vector3(chunk_coord) * CHUNK_SIZE
			visible_chunks[chunk_coord] = true
		# else: chunk exists but is not in tree yet
	else:
		# No viewer yet, add normally
		add_child(chunk)
		chunk.position = Vector3(chunk_coord) * CHUNK_SIZE
		visible_chunks[chunk_coord] = true
	
	return chunk

## Return a chunk to the pool for recycling (call when permanently removing a chunk)
func release_chunk(chunk_coord: Vector3i):
	if not chunks.has(chunk_coord):
		return
	
	var chunk = chunks[chunk_coord]
	if _dirty_chunks.has(chunk_coord) and visible_chunks.has(chunk_coord):
		_dirty_visible_chunk_count = maxi(0, _dirty_visible_chunk_count - 1)
		_dirty_chunks.erase(chunk_coord)
	chunks.erase(chunk_coord)
	visible_chunks.erase(chunk_coord)
	
	if chunk.is_inside_tree():
		remove_child(chunk)
	
	# Add to pool if not full, otherwise free
	if chunk_pool.size() < MAX_POOL_SIZE:
		chunk_pool.append(chunk)
	else:
		chunk.queue_free()

func set_voxel(global_pos: Vector3, value: int, meta: int = 0):
	var chunk_x = floor(global_pos.x / CHUNK_SIZE)
	var chunk_y = floor(global_pos.y / CHUNK_SIZE)
	var chunk_z = floor(global_pos.z / CHUNK_SIZE)
	var chunk_coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	var local_x = int(floor(global_pos.x)) % CHUNK_SIZE
	var local_y = int(floor(global_pos.y)) % CHUNK_SIZE
	var local_z = int(floor(global_pos.z)) % CHUNK_SIZE
	
	# Handle negative modulo correctly
	if local_x < 0: local_x += CHUNK_SIZE
	if local_y < 0: local_y += CHUNK_SIZE
	if local_z < 0: local_z += CHUNK_SIZE
	
	var chunk = get_chunk(chunk_coord)
	chunk.set_voxel(Vector3i(local_x, local_y, local_z), value, meta)
	
	# Update building map
	_update_building_map_pixel(global_pos, value > 0)
	
	# Trigger rebuild for this chunk if it's visible
	if visible_chunks.has(chunk_coord):
		chunk.rebuild_mesh()

## Set voxel WITHOUT triggering immediate mesh rebuild (for batch operations)
## Call flush_dirty_chunks() after all batch operations are complete
func set_voxel_batched(global_pos: Vector3, value: int, meta: int = 0):
	var chunk_x = floor(global_pos.x / CHUNK_SIZE)
	var chunk_y = floor(global_pos.y / CHUNK_SIZE)
	var chunk_z = floor(global_pos.z / CHUNK_SIZE)
	var chunk_coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	var local_x = int(floor(global_pos.x)) % CHUNK_SIZE
	var local_y = int(floor(global_pos.y)) % CHUNK_SIZE
	var local_z = int(floor(global_pos.z)) % CHUNK_SIZE
	
	# Handle negative modulo correctly
	if local_x < 0: local_x += CHUNK_SIZE
	if local_y < 0: local_y += CHUNK_SIZE
	if local_z < 0: local_z += CHUNK_SIZE
	
	var chunk = get_chunk(chunk_coord)
	chunk.set_voxel(Vector3i(local_x, local_y, local_z), value, meta)
	
	# Update building map
	_update_building_map_pixel(global_pos, value > 0)
	
	# Always mark chunk as dirty - rebuild will check visibility
	mark_chunk_dirty(chunk_coord, chunk)

## Rebuild all chunks that were modified by batched operations
## Call this once after completing a batch of set_voxel_batched calls
func flush_dirty_chunks():
	if _dirty_chunks.is_empty():
		return

	var start_time := Time.get_ticks_usec()
	# Only rebuild a limited number of visible chunks per flush so we do not
	# turn one town burst into a single giant rebuild spike.
	var effective_budget := dirty_chunk_flush_budget
	if world_map_mode:
		effective_budget = mini(dirty_chunk_flush_budget, 2)
	var rebuilt = 0
	var processed = 0
	var flush_coords: Array = _dirty_chunks.keys()
	var visible_coords: Array = []
	var hidden_coords: Array = []
	for coord_variant in flush_coords:
		var coord: Vector3i = coord_variant
		if visible_chunks.has(coord):
			visible_coords.append(coord)
		else:
			hidden_coords.append(coord)

	var coord_lists: Array = [visible_coords]
	if not world_map_mode:
		coord_lists.append(hidden_coords)

	for coord_list in coord_lists:
		for coord in coord_list:
			if processed >= effective_budget:
				break
			if not _dirty_chunks.has(coord):
				continue
			var chunk: BuildingChunk = _dirty_chunks[coord]
			if not chunk or not is_instance_valid(chunk):
				if visible_chunks.has(coord):
					_dirty_visible_chunk_count = maxi(0, _dirty_visible_chunk_count - 1)
				_dirty_chunks.erase(coord)
				continue
			chunk.rebuild_mesh()
			rebuilt += 1
			processed += 1
			if visible_chunks.has(coord):
				_dirty_visible_chunk_count = maxi(0, _dirty_visible_chunk_count - 1)
			_dirty_chunks.erase(coord)
		if processed >= effective_budget:
			break
	_last_flush_dirty_chunks_ms = float(Time.get_ticks_usec() - start_time) / 1000.0
	_last_flush_dirty_chunks_count = rebuilt


func has_dirty_chunks() -> bool:
	return not _dirty_chunks.is_empty()

func has_dirty_visible_chunks() -> bool:
	return _dirty_visible_chunk_count > 0

func has_pending_building_work() -> bool:
	# Only gameplay-critical building work should block terrain finalization.
	# Render-only visual batch rebuilds can lag behind without affecting play.
	return _dirty_visible_chunk_count > 0 \
		or not _pending_object_collision_tasks.is_empty() \
		or (mesher and mesher.has_method("has_pending_work") and mesher.has_pending_work())

func has_pending_visual_batch_work() -> bool:
	return not _dirty_global_visual_batch_object_ids.is_empty()

func has_baked_buildings_loaded() -> bool:
	return baked_buildings_loaded

func is_baked_buildings_fully_loaded() -> bool:
	if not baked_buildings_loaded:
		return false
	if baked_building_manifest_index.is_empty():
		return false
	return baked_building_loaded_chunk_keys.size() >= baked_building_manifest_index.size()

func load_baked_buildings_from_manifest(world_path: String, clear_existing: bool = true, eager_load_chunks: bool = false) -> bool:
	var manifest_path := world_path.path_join("baked_buildings/manifest.json")
	if not FileAccess.file_exists(manifest_path):
		_last_baked_building_load_mode = "missing_manifest"
		_last_baked_building_load_ms = 0.0
		_last_baked_building_load_chunks = 0
		_last_baked_building_manifest_chunks = 0
		return false

	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if not file:
		_last_baked_building_load_mode = "manifest_open_failed"
		_last_baked_building_load_ms = 0.0
		_last_baked_building_load_chunks = 0
		_last_baked_building_manifest_chunks = 0
		return false

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		_last_baked_building_load_mode = "manifest_parse_failed"
		_last_baked_building_load_ms = 0.0
		_last_baked_building_load_chunks = 0
		_last_baked_building_manifest_chunks = 0
		return false
	file.close()

	var manifest_variant = json.get_data()
	if not manifest_variant is Dictionary:
		_last_baked_building_load_mode = "manifest_invalid"
		_last_baked_building_load_ms = 0.0
		_last_baked_building_load_chunks = 0
		_last_baked_building_manifest_chunks = 0
		return false

	var manifest: Dictionary = manifest_variant
	var start_us := Time.get_ticks_usec()
	if clear_existing:
		clear_all_building_chunks()
	else:
		clear_pending_object_collision_tasks()
		clear_global_visual_batches()
		_dirty_chunks.clear()
		_dirty_visible_chunk_count = 0

	baked_building_manifest = manifest.duplicate(true)
	baked_buildings_world_path = world_path
	baked_building_manifest_index.clear()
	baked_building_snapshot_cache.clear()
	baked_building_loaded_chunk_keys.clear()

	var chunk_entries: Array = manifest.get("chunks", [])
	_last_baked_building_manifest_chunks = chunk_entries.size()
	for entry_variant in chunk_entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		var coord_arr: Array = entry.get("coord", [])
		if coord_arr.size() < 3:
			continue
		var chunk_coord := Vector3i(int(coord_arr[0]), int(coord_arr[1]), int(coord_arr[2]))
		baked_building_manifest_index[_coord_key(chunk_coord)] = entry
	baked_buildings_loaded = not baked_building_manifest_index.is_empty()

	var loaded_chunk_count := 0
	if eager_load_chunks:
		for entry_variant in chunk_entries:
			if typeof(entry_variant) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = entry_variant
			var coord_arr: Array = entry.get("coord", [])
			if coord_arr.size() < 3:
				continue
			var chunk_coord := Vector3i(int(coord_arr[0]), int(coord_arr[1]), int(coord_arr[2]))
			if ensure_baked_building_chunk_loaded(chunk_coord):
				loaded_chunk_count += 1

	_last_baked_building_load_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
	_last_baked_building_load_chunks = baked_building_loaded_chunk_keys.size() if eager_load_chunks else loaded_chunk_count
	_last_baked_building_load_mode = "manifest_loaded_eager" if eager_load_chunks and baked_buildings_loaded else ("manifest_loaded" if baked_buildings_loaded else "manifest_empty")
	if eager_load_chunks and baked_buildings_loaded and has_pending_visual_batch_work():
		flush_global_visual_batches()
	return baked_buildings_loaded

func ensure_baked_building_chunk_loaded(chunk_coord: Vector3i) -> bool:
	if not baked_buildings_loaded:
		return false

	var coord_key := _coord_key(chunk_coord)
	var entry: Dictionary = baked_building_manifest_index.get(coord_key, {})
	if entry.is_empty():
		return false

	var chunk: BuildingChunk = chunks.get(chunk_coord, null)
	if chunk and chunk.baked_snapshot_loaded and chunk.baked_snapshot_chunk_coord == chunk_coord:
		baked_building_loaded_chunk_keys[coord_key] = true
		_last_baked_building_load_chunks = max(_last_baked_building_load_chunks, baked_building_loaded_chunk_keys.size())
		return true

	var file_name := str(entry.get("file", ""))
	if file_name.is_empty():
		return false

	var snapshot: Resource = baked_building_snapshot_cache.get(coord_key, null)
	if snapshot == null:
		var snapshot_path := baked_buildings_world_path.path_join("baked_buildings").path_join(file_name)
		if not FileAccess.file_exists(snapshot_path):
			return false
		snapshot = ResourceLoader.load(snapshot_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if snapshot == null or not snapshot is BuildingBakeSnapshot:
			return false
		baked_building_snapshot_cache[coord_key] = snapshot

	if not chunk:
		chunk = get_chunk(chunk_coord)
	if not chunk:
		return false
	chunk.apply_bake_snapshot(snapshot)
	baked_building_loaded_chunk_keys[coord_key] = true
	_last_baked_building_load_chunks = max(_last_baked_building_load_chunks, baked_building_loaded_chunk_keys.size())
	_last_baked_building_load_mode = "chunk_load"
	return true

func save_baked_buildings_to_dir(world_path: String) -> Dictionary:
	return _export_baked_buildings(world_path, false)

func export_dirty_baked_buildings(world_path: String) -> Dictionary:
	if _dirty_chunks.is_empty():
		return {}
	return _export_baked_buildings(world_path, true)

func get_dirty_building_data() -> Dictionary:
	if _dirty_chunks.is_empty():
		return {}
	var result: Dictionary = {}
	for coord_variant in _dirty_chunks:
		var coord: Vector3i = coord_variant
		if not chunks.has(coord):
			continue
		var chunk: BuildingChunk = chunks[coord]
		if chunk == null or chunk.is_empty:
			continue
		result[_coord_key(coord)] = _serialize_chunk_save_data(chunk)
	return result

func _coord_key(coord: Vector3i) -> String:
	return "%d,%d,%d" % [coord.x, coord.y, coord.z]

func _serialize_chunk_save_data(chunk: BuildingChunk) -> Dictionary:
	var voxels_b64 := Marshalls.raw_to_base64(chunk.voxel_bytes)
	var meta_b64 := Marshalls.raw_to_base64(chunk.voxel_meta)
	var objects_data: Array = []
	for anchor in chunk.objects:
		var obj = chunk.objects[anchor]
		var fractional_pos: Vector3 = obj.get("fractional_pos", Vector3.ZERO)
		objects_data.append({
			"anchor": [anchor.x, anchor.y, anchor.z],
			"object_id": int(obj.object_id),
			"rotation": int(obj.rotation),
			"fractional_y": float(obj.get("fractional_y", fractional_pos.y)),
			"fractional_pos": [fractional_pos.x, fractional_pos.y, fractional_pos.z]
		})

	return {
		"voxels": voxels_b64,
		"meta": meta_b64,
		"objects": objects_data
	}

func _load_baked_building_manifest(world_path: String) -> Dictionary:
	var manifest_path := world_path.path_join("baked_buildings/manifest.json")
	if not FileAccess.file_exists(manifest_path):
		return {}
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if not file:
		return {}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		return {}
	file.close()
	var data = json.get_data()
	if data is Dictionary:
		return data
	return {}

func _export_baked_buildings(world_path: String, only_dirty: bool) -> Dictionary:
	var bake_dir := world_path.path_join("baked_buildings")
	var bake_dir_abs := ProjectSettings.globalize_path(bake_dir)
	var mkdir_err := DirAccess.make_dir_recursive_absolute(bake_dir_abs)
	if mkdir_err != OK:
		push_error("[BuildingManager] Failed to create baked building directory %s (err %d)" % [bake_dir_abs, mkdir_err])
		return {}

	var existing_manifest := _load_baked_building_manifest(world_path)
	var entries_by_key: Dictionary = {}
	if existing_manifest.has("chunks"):
		for entry_variant in existing_manifest.get("chunks", []):
			if typeof(entry_variant) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = entry_variant
			var coord_arr: Array = entry.get("coord", [])
			if coord_arr.size() < 3:
				continue
			var key := _coord_key(Vector3i(int(coord_arr[0]), int(coord_arr[1]), int(coord_arr[2])))
			entries_by_key[key] = entry

	var coord_source: Array = _dirty_chunks.keys() if only_dirty else chunks.keys()
	var exported_chunk_count := 0
	for coord_variant in coord_source:
		var coord: Vector3i = coord_variant
		if not chunks.has(coord):
			continue
		var chunk: BuildingChunk = chunks[coord]
		var coord_key := _coord_key(coord)
		if chunk == null or chunk.is_empty:
			entries_by_key.erase(coord_key)
			continue
		var snapshot := chunk.capture_bake_snapshot()
		if snapshot == null:
			continue
		var file_name := "chunk_%d_%d_%d.tres" % [coord.x, coord.y, coord.z]
		var file_path := bake_dir.path_join(file_name)
		var save_err := ResourceSaver.save(snapshot, file_path)
		if save_err != OK:
			push_error("[BuildingManager] Failed to save baked chunk %s (err %d)" % [file_path, save_err])
			continue
		entries_by_key[coord_key] = {
			"coord": [coord.x, coord.y, coord.z],
			"file": file_name
		}
		exported_chunk_count += 1

	var manifest := {
		"schema_version": 1,
		"world_definition_path": world_path,
		"chunk_count": entries_by_key.size(),
		"exported_chunk_count": exported_chunk_count,
		"updated": Time.get_datetime_string_from_system(),
		"chunks": []
	}
	for key in entries_by_key:
		manifest["chunks"].append(entries_by_key[key])
	manifest["chunks"].sort_custom(func(a, b):
		var ac: Array = a.get("coord", [0, 0, 0])
		var bc: Array = b.get("coord", [0, 0, 0])
		if ac[0] == bc[0]:
			if ac[1] == bc[1]:
				return ac[2] < bc[2]
			return ac[1] < bc[1]
		return ac[0] < bc[0]
	)

	var manifest_path := bake_dir.path_join("manifest.json")
	var file := FileAccess.open(manifest_path, FileAccess.WRITE)
	if not file:
		push_error("[BuildingManager] Failed to open baked manifest for writing: %s" % manifest_path)
		return manifest
	file.store_string(JSON.stringify(manifest, "\t"))
	file.close()

	baked_buildings_world_path = world_path
	baked_building_manifest = manifest.duplicate(true)
	baked_buildings_loaded = true
	return manifest

func get_voxel(global_pos: Vector3) -> int:
	var chunk_x = floor(global_pos.x / CHUNK_SIZE)
	var chunk_y = floor(global_pos.y / CHUNK_SIZE)
	var chunk_z = floor(global_pos.z / CHUNK_SIZE)
	var chunk_coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not chunks.has(chunk_coord):
		return 0
		
	var local_x = int(floor(global_pos.x)) % CHUNK_SIZE
	var local_y = int(floor(global_pos.y)) % CHUNK_SIZE
	var local_z = int(floor(global_pos.z)) % CHUNK_SIZE
	
	if local_x < 0: local_x += CHUNK_SIZE
	if local_y < 0: local_y += CHUNK_SIZE
	if local_z < 0: local_z += CHUNK_SIZE
	
	return chunks[chunk_coord].get_voxel(Vector3i(local_x, local_y, local_z))

## Check if an object can be placed at the given global position
func can_place_object(global_pos: Vector3, object_id: int, rotation: int, precomputed_cells: Array = []) -> bool:
	var anchor = Vector3i(floor(global_pos.x), floor(global_pos.y), floor(global_pos.z))
	var cells := _build_object_cells(anchor, object_id, rotation, precomputed_cells)
	return _can_place_cells(cells, object_id)

func _can_place_cells(cells: Array[Vector3i], object_id: int) -> bool:
	for cell in cells:
		# Calculate which chunk this specific cell belongs to
		var chunk_coord = Vector3i(
			int(floor(float(cell.x) / CHUNK_SIZE)),
			int(floor(float(cell.y) / CHUNK_SIZE)),
			int(floor(float(cell.z) / CHUNK_SIZE))
		)
		
		var local = Vector3i(cell.x % CHUNK_SIZE, cell.y % CHUNK_SIZE, cell.z % CHUNK_SIZE)
		if local.x < 0: local.x += CHUNK_SIZE
		if local.y < 0: local.y += CHUNK_SIZE
		if local.z < 0: local.z += CHUNK_SIZE
		
		# Check if cell is available in its chunk
		if chunks.has(chunk_coord):
			var chunk = chunks[chunk_coord]
			if not chunk.is_cell_available(local):
				return false
		# If chunk doesn't exist, cell is available (empty terrain)
	
	return true

func _build_object_cells(anchor: Vector3i, object_id: int, rotation: int, precomputed_cells: Array = []) -> Array[Vector3i]:
	if precomputed_cells.is_empty():
		return ObjectRegistry.get_occupied_cells(object_id, anchor, rotation)

	var cells: Array[Vector3i] = []
	cells.resize(precomputed_cells.size())
	for i in range(precomputed_cells.size()):
		var precomputed_cell: Vector3i = precomputed_cells[i]
		cells[i] = precomputed_cell + anchor
	return cells

## Place an object at the given global position (supports fractional Y for terrain surface)
## Set is_procedural=true when spawning from prefab system to trigger loot population
func place_object(global_pos: Vector3, object_id: int, rotation: int, ignore_collision: bool = false, is_procedural: bool = false, defer_global_visual_batch_rebuild: bool = false, precomputed_cells: Array = [], object_size: Vector3i = Vector3i.ZERO, object_scene_path: String = "", has_authored_collision: bool = false, has_authored_collision_valid: bool = false) -> bool:
	var obj_def: Dictionary = {}
	var needs_registry_lookup := object_scene_path.is_empty() or object_size == Vector3i.ZERO or not has_authored_collision_valid
	if needs_registry_lookup:
		obj_def = ObjectRegistry.get_object(object_id)
		if obj_def.is_empty():
			return false
		if object_scene_path.is_empty():
			object_scene_path = str(obj_def.get("scene", ""))
		if object_size == Vector3i.ZERO:
			object_size = obj_def.get("size", Vector3i(1, 1, 1))
		if not has_authored_collision_valid:
			has_authored_collision = ObjectRegistry.get_object_has_authored_collision(object_id)
			has_authored_collision_valid = true

	# Calculate anchor (integer grid position) and fractional position offset
	var anchor = Vector3i(int(floor(global_pos.x)), int(floor(global_pos.y)), int(floor(global_pos.z)))
	var fractional_pos = global_pos - Vector3(anchor) # Full 3D offset from anchor
	var cells: Array[Vector3i] = _build_object_cells(anchor, object_id, rotation, precomputed_cells)
	if not ignore_collision and not _can_place_cells(cells, object_id):
		return false
	
	# Place in the chunk containing the anchor
	var chunk_coord = Vector3i(
		int(floor(float(anchor.x) / CHUNK_SIZE)),
		int(floor(float(anchor.y) / CHUNK_SIZE)),
		int(floor(float(anchor.z) / CHUNK_SIZE))
	)
	
	var local_anchor = Vector3i(anchor.x % CHUNK_SIZE, anchor.y % CHUNK_SIZE, anchor.z % CHUNK_SIZE)
	if local_anchor.x < 0: local_anchor.x += CHUNK_SIZE
	if local_anchor.y < 0: local_anchor.y += CHUNK_SIZE
	if local_anchor.z < 0: local_anchor.z += CHUNK_SIZE
	
	# Convert cells to local coordinates for the anchor chunk
	var local_cells: Array[Vector3i] = []
	for cell in cells:
		var local_cell = Vector3i(cell.x % CHUNK_SIZE, cell.y % CHUNK_SIZE, cell.z % CHUNK_SIZE)
		if local_cell.x < 0: local_cell.x += CHUNK_SIZE
		if local_cell.y < 0: local_cell.y += CHUNK_SIZE
		if local_cell.z < 0: local_cell.z += CHUNK_SIZE
		local_cells.append(local_cell)
	
	var chunk = get_chunk(chunk_coord)

	if world_map_mode and ObjectRegistry.is_simple_visual_batch_object(object_id):
		var visual_data = ObjectRegistry.get_object_visual_data(object_id)
		if not visual_data.is_empty():
			var simple_success = chunk.place_simple_visual_object(local_anchor, object_id, rotation, local_cells, fractional_pos, visual_data, defer_global_visual_batch_rebuild)
			if simple_success:
				return true

	var scene_instance: Node3D = null
	if world_map_mode and ObjectRegistry.is_proxy_visual_batch_object(object_id):
		scene_instance = ObjectRegistry.create_proxy_gameplay_shell(object_id, world_map_mode)

	# Load and instantiate the scene (uses preloaded cache) if we did not build a shell
	if scene_instance == null:
		var scene_path = object_scene_path if not object_scene_path.is_empty() else str(obj_def.get("scene", ""))
		var packed = ObjectRegistry.get_preloaded_scene(scene_path)
		if packed:
			scene_instance = packed.instantiate()
	
	# Mark container for loot population BEFORE adding to tree
	# This allows _ready() to populate after creating the inventory
	if is_procedural and scene_instance and scene_instance.has_method("populate_loot"):
		scene_instance.set_meta("should_populate_loot", true)
	
	var success = chunk.place_object(local_anchor, object_id, rotation, local_cells, scene_instance, fractional_pos, is_procedural, defer_global_visual_batch_rebuild, object_size, has_authored_collision, has_authored_collision_valid)
	return success

## Remove an object at the given global position
func remove_object_at(global_pos: Vector3) -> bool:
	var cell = Vector3i(floor(global_pos.x), floor(global_pos.y), floor(global_pos.z))
	
	var chunk_coord = Vector3i(
		int(floor(float(cell.x) / CHUNK_SIZE)),
		int(floor(float(cell.y) / CHUNK_SIZE)),
		int(floor(float(cell.z) / CHUNK_SIZE))
	)
	
	if not chunks.has(chunk_coord):
		return false
	
	var local = Vector3i(cell.x % CHUNK_SIZE, cell.y % CHUNK_SIZE, cell.z % CHUNK_SIZE)
	if local.x < 0: local.x += CHUNK_SIZE
	if local.y < 0: local.y += CHUNK_SIZE
	if local.z < 0: local.z += CHUNK_SIZE
	
	var chunk = chunks[chunk_coord]
	var anchor = chunk.get_object_at(local)
	if anchor == null:
		return false
	
	var result = chunk.remove_object(anchor)
	if result:
		# Clear this cell on the building map
		_update_building_map_pixel(global_pos, false)
	return result
