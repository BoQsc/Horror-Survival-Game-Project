extends Node3D
const BuildingVisuals = preload("res://world_building_system/building_visuals.gd")
const RenderResourcePrewarm = preload("res://world_render_prewarm/render_resource_prewarm.gd")
const WORLD_MAP_VISIBILITY_EXTRA_DISTANCE := 0
const WORLD_MAP_TERRAIN_CHUNK_STRIDE := 31
const MULTIMESH_FLOATS_PER_INSTANCE_3D := 12

# Maps Vector3i (Chunk Coord) -> BuildingChunk (data always persisted)
var chunks: Dictionary = {}
var mesher: BuildingMesher

# Render distance management
@export var viewer: Node3D
@export var render_distance: int = 8 # Increased for better visibility
var _last_building_viewer_chunk: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _cached_vehicle_manager: Node = null
var _cached_terrain_manager: Node = null

# Track which chunks are currently visible (have nodes in scene tree)
var visible_chunks: Dictionary = {} # Vector3i -> true

# Chunk pool for recycling (multiplayer optimization)
var chunk_pool: Array[BuildingChunk] = []
const MAX_POOL_SIZE = 32 # Keep up to 32 chunks in pool

@export_range(0.5, 20.0, 0.5) var object_collision_budget_ms: float = 2.0
@export_range(0.25, 10.0, 0.25) var world_map_baked_object_spawn_budget_ms: float = 1.0
@export_range(1, 32, 1) var world_map_baked_object_spawn_max_per_frame: int = 2
@export_range(0.25, 10.0, 0.25) var world_map_baked_object_spawn_headroom_budget_ms: float = 1.5
@export_range(1, 64, 1) var world_map_baked_object_spawn_headroom_max_per_frame: int = 4
@export_range(0.1, 5.0, 0.1) var world_map_baked_object_spawn_hot_budget_ms: float = 0.35
@export var world_map_baked_building_visual_batching_enabled: bool = true
@export_range(1, 16, 1) var world_map_baked_building_visual_batch_size: int = 8
@export_range(1, 8, 1) var world_map_baked_building_visual_batch_rebuilds_per_frame: int = 2
@export_range(1, 32, 1) var dirty_chunk_flush_budget: int = 4
@export_range(0, 60, 1) var object_render_prewarm_frames: int = 12
@export_range(0.025, 1.0, 0.025) var viewer_chunk_update_interval: float = 0.10
var skip_object_collisions_for_test: bool = false
var skip_building_chunk_collisions_for_test: bool = false
var skip_building_chunk_mesh_render_for_test: bool = false
var skip_building_visual_batches_for_test: bool = false
var _pending_object_collision_tasks: Array[Dictionary] = []
var _pending_world_map_baked_object_spawns: Array[Dictionary] = []
var _object_spawn_profile_cache: Dictionary = {}

# Global world-map visual batching for repeated props
var _global_visual_batch_instances: Dictionary = {} # Vector3i anchor -> { object_id, transform, mesh }
var _global_visual_batch_entries: Dictionary = {} # int object_id -> Array[{ anchor, transform }]
var _global_visual_batch_nodes: Dictionary = {} # int object_id -> MultiMeshInstance3D
var _dirty_global_visual_batch_object_ids: Dictionary = {} # int object_id -> true
var _world_map_baked_building_visual_nodes: Dictionary = {} # String building_key -> Node3D
var _world_map_baked_building_visual_payloads_by_key: Dictionary = {} # String building_key -> Dictionary visual payload
var _world_map_baked_building_keys_by_chunk: Dictionary = {} # Vector3i chunk_coord -> Array[String]
var _world_map_baked_building_chunk_coords_by_key: Dictionary = {} # String building_key -> Array[Vector3i]
var _world_map_baked_building_edits_by_key: Dictionary = {} # String building_key -> Dictionary[voxel_key] = { value, meta }
var _world_map_baked_building_visual_batch_root: Node3D = null
var _world_map_baked_building_visual_batches: Dictionary = {} # Vector2i -> MeshInstance3D
var _world_map_baked_building_visual_batch_dirty: Dictionary = {} # Vector2i -> true
var _last_world_map_baked_building_visual_batch_rebuild_ms: float = 0.0
var _last_world_map_baked_building_visual_batch_rebuild_count: int = 0
var _last_world_map_baked_building_visual_batch_source_nodes: int = 0
var _last_world_map_baked_building_visual_batch_source_surfaces: int = 0
var _last_world_map_baked_building_visual_batch_output_surfaces: int = 0
var _last_world_map_baked_building_visual_batch_hidden_nodes: int = 0
var _last_global_visual_batch_center_chunk: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _native_helper: Object = null
var _object_render_resource_prewarm_node: Node = null
var _object_render_resource_prewarm_mesh_count: int = 0

# Batched operations - accumulate changes, rebuild once
var _dirty_chunks: Dictionary = {} # Vector3i -> BuildingChunk (chunks needing rebuild)
var _dirty_visible_chunk_count: int = 0
var _last_flush_dirty_chunks_ms: float = 0.0
var _last_flush_dirty_chunks_count: int = 0
var _last_flush_global_visual_batches_ms: float = 0.0
var _last_flush_global_visual_batches_count: int = 0
var _last_apply_world_map_baked_building_payload_ms: float = 0.0
var _last_apply_world_map_baked_building_payload_chunk_ms: float = 0.0
var _last_apply_world_map_baked_building_payload_object_ms: float = 0.0
var _last_apply_world_map_baked_building_payload_flush_ms: float = 0.0
var _last_apply_world_map_baked_building_payload_slowest_object_ms: float = 0.0
var _last_apply_world_map_baked_building_payload_slowest_object_id: int = -1
var _last_apply_world_map_baked_building_payload_slowest_object_scene_path: String = ""
var _last_apply_world_map_baked_building_payload_slowest_object_world_pos: Vector3 = Vector3.ZERO
var _last_apply_world_map_baked_building_payload_slow_object_spawns: Array = []
var _last_apply_world_map_baked_building_visual_ms: float = 0.0
var _last_apply_world_map_baked_building_visual_root_ms: float = 0.0
var _last_apply_world_map_baked_building_visual_mesh_attach_ms: float = 0.0
var _last_apply_world_map_baked_building_visual_body_attach_ms: float = 0.0
var _last_apply_world_map_baked_building_visual_mesh_ms: float = 0.0
var _last_apply_world_map_baked_building_visual_collision_ms: float = 0.0
var _last_apply_world_map_baked_building_visual_sync_ms: float = 0.0
var _last_apply_world_map_baked_building_visual_count: int = 0
var _last_apply_world_map_baked_building_chunk_count: int = 0
var _last_apply_world_map_baked_building_object_count: int = 0
var _last_apply_world_map_baked_building_prebuilt_chunk_count: int = 0
var _last_world_map_baked_object_spawn_queue_ms: float = 0.0
var _last_world_map_baked_object_spawn_queue_count: int = 0
var _last_world_map_baked_object_spawn_queue_budget_ms: float = 0.0
var _last_world_map_baked_object_spawn_queue_max_per_frame: int = 0
var _last_world_map_baked_object_spawn_queue_hot_frame: bool = false
var _last_frame_ms: float = 0.0
var _last_world_map_baked_visibility_update_ms: float = 0.0
var _last_world_map_baked_visibility_added: int = 0
var _last_world_map_baked_visibility_removed: int = 0
var _last_world_map_baked_visibility_kept_visible: int = 0
var _last_world_map_baked_visibility_target_visible: int = 0
var _last_world_map_baked_visibility_total_roots: int = 0
var _last_world_map_baked_visibility_stale_roots: int = 0
var _viewer_chunk_update_timer: Timer = null

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
	set_process(false)
	# Preload all object scenes for faster building spawning
	ObjectRegistry.preload_all_scenes()
	_start_object_render_resource_prewarm()
	
	mesher = BuildingMesher.new()
	add_child(mesher)
	
	# Find player if not assigned
	if not viewer:
		viewer = get_tree().get_first_node_in_group("player")
	_start_viewer_chunk_update_timer()
	_sync_viewer_chunk(true)
	_sync_process_loop()

func _process(delta):
	_last_frame_ms = delta * 1000.0
	if not _has_process_work_pending():
		set_process(false)
		return
	_process_pending_world_map_baked_object_spawns()
	_process_pending_object_collisions()
	_process_world_map_baked_building_visual_batches()
	if has_dirty_visible_chunks():
		flush_dirty_chunks()
	_sync_process_loop()

func _start_viewer_chunk_update_timer() -> void:
	if _viewer_chunk_update_timer and is_instance_valid(_viewer_chunk_update_timer):
		return
	var timer := Timer.new()
	timer.name = "ViewerChunkUpdateTimer"
	timer.wait_time = maxf(viewer_chunk_update_interval, 0.025)
	timer.one_shot = false
	timer.autostart = false
	timer.process_callback = Timer.TIMER_PROCESS_IDLE
	add_child(timer)
	_viewer_chunk_update_timer = timer
	timer.timeout.connect(_on_viewer_chunk_update_timer_timeout)
	timer.start()

func _on_viewer_chunk_update_timer_timeout() -> void:
	_sync_viewer_chunk()

func _sync_viewer_chunk(force_update: bool = false) -> void:
	if not viewer or not is_instance_valid(viewer):
		viewer = get_tree().get_first_node_in_group("player")
	if not viewer:
		return

	var center_chunk := _get_current_building_center_chunk()
	if force_update or center_chunk != _last_building_viewer_chunk:
		_last_building_viewer_chunk = center_chunk
		update_building_chunks(center_chunk)

func _has_process_work_pending() -> bool:
	return (
		not _pending_world_map_baked_object_spawns.is_empty()
		or not _pending_object_collision_tasks.is_empty()
		or has_dirty_visible_chunks()
		or has_dirty_global_visual_batches()
		or not _world_map_baked_building_visual_batch_dirty.is_empty()
	)

func _wake_process_loop() -> void:
	if not is_processing():
		set_process(true)

func _sync_process_loop() -> void:
	if _has_process_work_pending():
		_wake_process_loop()
	else:
		set_process(false)

## Gets effective viewer position - returns vehicle position if player is driving
func get_viewer_position() -> Vector3:
	if not viewer:
		return Vector3.ZERO
	
	# Check if player is in a vehicle
	var vm = _get_vehicle_manager()
	if vm and "current_player_vehicle" in vm and vm.current_player_vehicle:
		return vm.current_player_vehicle.global_position
	
	return viewer.global_position

func _get_current_building_center_chunk() -> Vector3i:
	var p_pos = get_viewer_position()
	return Vector3i(
		floor(p_pos.x / CHUNK_SIZE),
		floor(p_pos.y / CHUNK_SIZE),
		floor(p_pos.z / CHUNK_SIZE)
	)

func _get_vehicle_manager() -> Node:
	if _cached_vehicle_manager and is_instance_valid(_cached_vehicle_manager):
		return _cached_vehicle_manager

	_cached_vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	return _cached_vehicle_manager

func _get_terrain_manager() -> Node:
	if _cached_terrain_manager and is_instance_valid(_cached_terrain_manager):
		return _cached_terrain_manager

	_cached_terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	return _cached_terrain_manager

func _start_object_render_resource_prewarm() -> void:
	if object_render_prewarm_frames <= 0 or _is_object_render_resource_prewarm_active():
		return

	var mesh_entries := _collect_object_render_resource_prewarm_entries()
	_object_render_resource_prewarm_mesh_count = mesh_entries.size()
	if mesh_entries.is_empty():
		return

	var prewarmer: Node = RenderResourcePrewarm.new()
	prewarmer.name = "ObjectRenderResourcePrewarm"
	add_child(prewarmer)
	_object_render_resource_prewarm_node = prewarmer
	prewarmer.configure([], object_render_prewarm_frames, mesh_entries)

func _collect_object_render_resource_prewarm_entries() -> Array:
	var entries: Array = []
	var unique_meshes: Array = []
	for object_id_variant in ObjectRegistry.get_all_ids():
		var object_id := int(object_id_variant)
		var visual_data := ObjectRegistry.get_object_visual_data(object_id)
		if visual_data.is_empty():
			continue

		var mesh: Mesh = visual_data.get("mesh", null)
		if not mesh or unique_meshes.has(mesh):
			continue

		unique_meshes.append(mesh)
		entries.append({
			"mesh": mesh,
			"transform": visual_data.get("mesh_transform", Transform3D.IDENTITY)
		})
	return entries

func _is_object_render_resource_prewarm_active() -> bool:
	return _object_render_resource_prewarm_node != null and is_instance_valid(_object_render_resource_prewarm_node)

func _get_object_render_resource_prewarm_frames_remaining() -> int:
	if not _is_object_render_resource_prewarm_active():
		return 0
	if not _object_render_resource_prewarm_node.has_method("get_frames_remaining"):
		return 0
	return int(_object_render_resource_prewarm_node.get_frames_remaining())

func update_building_chunks(center_chunk: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)):
	if center_chunk.x == 2147483647:
		center_chunk = _get_current_building_center_chunk()
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

	_update_world_map_baked_building_visual_visibility(center_chunk)
	_update_global_visual_batch_visibility(center_chunk)

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
			_clear_chunk_dirty(coord)
	
	visible_chunks[coord] = true
	if not was_visible and _dirty_chunks.has(coord):
		_dirty_visible_chunk_count += 1
	_sync_process_loop()

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
	_wake_process_loop()

func mark_chunk_dirty(chunk_coord: Vector3i, chunk: BuildingChunk) -> void:
	if not chunk or not is_instance_valid(chunk):
		return
	var was_dirty := _dirty_chunks.has(chunk_coord)
	chunk.mark_mesh_dirty()
	_dirty_chunks[chunk_coord] = chunk
	if not was_dirty and visible_chunks.has(chunk_coord):
		_dirty_visible_chunk_count += 1
		_wake_process_loop()

func _clear_chunk_dirty(chunk_coord: Vector3i) -> void:
	if not _dirty_chunks.has(chunk_coord):
		return
	_dirty_chunks.erase(chunk_coord)
	if visible_chunks.has(chunk_coord):
		_dirty_visible_chunk_count = maxi(0, _dirty_visible_chunk_count - 1)

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

		chunk.generate_deferred_object_collision(obj, anchor)
		processed += 1

func clear_pending_object_collision_tasks() -> void:
	_pending_object_collision_tasks.clear()
	_sync_process_loop()

func clear_pending_world_map_baked_object_spawns() -> void:
	_pending_world_map_baked_object_spawns.clear()
	_last_world_map_baked_object_spawn_queue_ms = 0.0
	_last_world_map_baked_object_spawn_queue_count = 0
	_last_world_map_baked_object_spawn_queue_budget_ms = 0.0
	_last_world_map_baked_object_spawn_queue_max_per_frame = 0
	_last_world_map_baked_object_spawn_queue_hot_frame = false
	_sync_process_loop()

func has_pending_world_map_baked_object_spawns() -> bool:
	return not _pending_world_map_baked_object_spawns.is_empty()

func _get_world_map_baked_object_spawn_schedule() -> Dictionary:
	var frame_budget_ms := 1000.0 / 60.0
	if _last_frame_ms > frame_budget_ms:
		return {
			"budget_ms": world_map_baked_object_spawn_hot_budget_ms,
			"max_per_frame": 1,
			"hot_frame": true
		}

	if _last_frame_ms > 0.0 and _last_frame_ms <= 14.5 and _dirty_chunks.is_empty() and _dirty_global_visual_batch_object_ids.is_empty():
		return {
			"budget_ms": world_map_baked_object_spawn_headroom_budget_ms,
			"max_per_frame": world_map_baked_object_spawn_headroom_max_per_frame,
			"hot_frame": false
		}

	return {
		"budget_ms": world_map_baked_object_spawn_budget_ms,
		"max_per_frame": world_map_baked_object_spawn_max_per_frame,
		"hot_frame": false
	}

func _queue_world_map_baked_object_spawns(object_spawns: Array) -> int:
	if object_spawns.is_empty():
		return 0

	var queued := 0
	for i in range(object_spawns.size() - 1, -1, -1):
		var spawn_variant: Variant = object_spawns[i]
		if typeof(spawn_variant) != TYPE_DICTIONARY:
			continue
		var spawn: Dictionary = spawn_variant
		_pending_world_map_baked_object_spawns.append(spawn)
		queued += 1
	if queued > 0:
		_wake_process_loop()
	return queued

func _process_pending_world_map_baked_object_spawns() -> void:
	if _pending_world_map_baked_object_spawns.is_empty():
		_last_world_map_baked_object_spawn_queue_ms = 0.0
		_last_world_map_baked_object_spawn_queue_count = 0
		_flush_world_map_baked_object_spawn_visuals_if_ready()
		return

	var start_time := Time.get_ticks_usec()
	var processed := 0
	var applied := 0
	var slow_object_spawns: Array = []
	var schedule := _get_world_map_baked_object_spawn_schedule()
	var budget_ms := maxf(float(schedule.get("budget_ms", world_map_baked_object_spawn_budget_ms)), 0.1)
	var max_per_frame := maxi(1, int(schedule.get("max_per_frame", world_map_baked_object_spawn_max_per_frame)))
	_last_world_map_baked_object_spawn_queue_budget_ms = budget_ms
	_last_world_map_baked_object_spawn_queue_max_per_frame = max_per_frame
	_last_world_map_baked_object_spawn_queue_hot_frame = bool(schedule.get("hot_frame", false))

	while not _pending_world_map_baked_object_spawns.is_empty() and processed < max_per_frame:
		if processed > 0:
			var elapsed_ms := float(Time.get_ticks_usec() - start_time) / 1000.0
			if elapsed_ms >= budget_ms:
				break

		var spawn: Dictionary = _pending_world_map_baked_object_spawns.pop_back()
		processed += 1
		var world_pos_variant: Variant = spawn.get("world_pos", Vector3.ZERO)
		if typeof(world_pos_variant) != TYPE_VECTOR3:
			continue
		var world_pos: Vector3 = world_pos_variant
		var object_id := int(spawn.get("object_id", -1))
		var object_scene_path := str(spawn.get("object_scene_path", ""))
		if object_id < 0 and object_scene_path.is_empty():
			continue

		var spawn_start_us := Time.get_ticks_usec()
		var success := _apply_world_map_baked_object_spawn(spawn, true)
		var object_elapsed_ms := float(Time.get_ticks_usec() - spawn_start_us) / 1000.0
		_record_world_map_baked_object_spawn_timing(
			spawn,
			object_elapsed_ms,
			object_id,
			object_scene_path,
			world_pos,
			slow_object_spawns
		)
		if success:
			applied += 1

	_last_world_map_baked_object_spawn_queue_ms = float(Time.get_ticks_usec() - start_time) / 1000.0
	_last_world_map_baked_object_spawn_queue_count = applied
	_last_apply_world_map_baked_building_payload_object_ms = _last_world_map_baked_object_spawn_queue_ms
	_last_apply_world_map_baked_building_object_count = applied
	_last_apply_world_map_baked_building_payload_slow_object_spawns = _build_top_world_map_baked_building_slow_object_spawns(slow_object_spawns)
	_flush_world_map_baked_object_spawn_visuals_if_ready()

func _flush_world_map_baked_object_spawn_visuals_if_ready() -> void:
	if not _pending_world_map_baked_object_spawns.is_empty():
		return
	if has_dirty_global_visual_batches():
		flush_global_visual_batches()

func register_global_visual_batch(anchor: Vector3i, object_id: int, transform: Transform3D, mesh: Mesh, defer_rebuild: bool = false) -> bool:
	if skip_building_visual_batches_for_test or object_id < 0 or not mesh:
		return false
	_ensure_global_visual_batch_center_chunk()

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
	if can_append and _is_global_visual_batch_anchor_in_range(anchor, _last_global_visual_batch_center_chunk, 2):
		_append_global_visual_batch_instance(object_id, transform, mesh)
	elif defer_rebuild:
		_dirty_global_visual_batch_object_ids[object_id] = true
		_wake_process_loop()
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
	_last_global_visual_batch_center_chunk = Vector3i(2147483647, 2147483647, 2147483647)
	_sync_process_loop()


func _get_native_helper() -> Object:
	if _native_helper and is_instance_valid(_native_helper):
		return _native_helper
	if not ClassDB.class_exists("PrefabGeometryNative"):
		return null
	_native_helper = ClassDB.instantiate("PrefabGeometryNative")
	return _native_helper

func _is_global_visual_batch_center_valid() -> bool:
	return _last_global_visual_batch_center_chunk.x != 2147483647


func _ensure_global_visual_batch_center_chunk() -> void:
	if _is_global_visual_batch_center_valid() or not viewer:
		return
	_last_global_visual_batch_center_chunk = _get_current_building_center_chunk()


func _get_global_visual_batch_anchor_chunk(anchor: Vector3i) -> Vector3i:
	return Vector3i(
		floor(float(anchor.x) / float(CHUNK_SIZE)),
		floor(float(anchor.y) / float(CHUNK_SIZE)),
		floor(float(anchor.z) / float(CHUNK_SIZE))
	)


func _is_global_visual_batch_anchor_in_range(anchor: Vector3i, center_chunk: Vector3i, extra_distance: int = 0) -> bool:
	if center_chunk.x == 2147483647:
		return true

	var anchor_chunk := _get_global_visual_batch_anchor_chunk(anchor)
	# Keep repeated-prop batches on the native building-chunk radius. Only the
	# baked building shells need the terrain-matched reveal distance.
	var max_dist := render_distance + extra_distance
	var max_dist_sq := max_dist * max_dist
	var dx := anchor_chunk.x - center_chunk.x
	var dy := anchor_chunk.y - center_chunk.y
	var dz := anchor_chunk.z - center_chunk.z
	return dx * dx + dy * dy + dz * dz <= max_dist_sq


func _get_visible_global_visual_batch_entries(entries: Array) -> Array:
	if not _is_global_visual_batch_center_valid():
		return entries.duplicate()

	var visible_entries: Array = []
	for entry_variant in entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		var anchor: Vector3i = entry.get("anchor", Vector3i.ZERO)
		if _is_global_visual_batch_anchor_in_range(anchor, _last_global_visual_batch_center_chunk, WORLD_MAP_VISIBILITY_EXTRA_DISTANCE):
			visible_entries.append(entry)
	return visible_entries


func _update_global_visual_batch_visibility(center_chunk: Vector3i) -> void:
	if center_chunk == _last_global_visual_batch_center_chunk:
		return

	_last_global_visual_batch_center_chunk = center_chunk
	if _global_visual_batch_entries.is_empty():
		return

	for object_id_variant in _global_visual_batch_entries.keys():
		_dirty_global_visual_batch_object_ids[int(object_id_variant)] = true
	flush_global_visual_batches()


func _count_visible_global_visual_batch_instances() -> int:
	var total := 0
	for node in _global_visual_batch_nodes.values():
		if node == null or not is_instance_valid(node):
			continue
		var batch_node := node as MultiMeshInstance3D
		if batch_node == null or batch_node.multimesh == null:
			continue
		total += batch_node.multimesh.instance_count
	return total

func _count_visible_global_visual_batch_surfaces() -> int:
	var total := 0
	for node in _global_visual_batch_nodes.values():
		if node == null or not is_instance_valid(node):
			continue
		var batch_node := node as MultiMeshInstance3D
		if batch_node == null or batch_node.multimesh == null:
			continue
		if batch_node.multimesh.instance_count <= 0 or batch_node.multimesh.mesh == null:
			continue
		total += batch_node.multimesh.mesh.get_surface_count()
	return total


func _count_visible_world_map_baked_building_visual_nodes() -> int:
	var total := 0
	for node in _world_map_baked_building_visual_nodes.values():
		if node and is_instance_valid(node) and node.is_inside_tree():
			total += 1
	return total

func _count_visible_world_map_baked_building_visual_surfaces() -> int:
	var total := 0
	for node in _world_map_baked_building_visual_nodes.values():
		if not (node and is_instance_valid(node) and node.is_inside_tree()):
			continue
		var root := node as Node3D
		if root == null:
			continue
		var mesh_instance := root.get_node_or_null("Mesh") as MeshInstance3D
		if mesh_instance == null or not mesh_instance.visible or mesh_instance.mesh == null:
			continue
		total += mesh_instance.mesh.get_surface_count()
	for node in _world_map_baked_building_visual_batches.values():
		if not (node and is_instance_valid(node)):
			continue
		var batch_node := node as MeshInstance3D
		if batch_node == null or not batch_node.visible or batch_node.mesh == null:
			continue
		total += batch_node.mesh.get_surface_count()
	return total

func _count_visible_world_map_baked_building_visual_batch_surfaces() -> int:
	var total := 0
	for node in _world_map_baked_building_visual_batches.values():
		if not (node and is_instance_valid(node)):
			continue
		var batch_node := node as MeshInstance3D
		if batch_node == null or not batch_node.visible or batch_node.mesh == null:
			continue
		total += batch_node.mesh.get_surface_count()
	return total

func _get_world_map_baked_building_visual_batch_root() -> Node3D:
	if _world_map_baked_building_visual_batch_root and is_instance_valid(_world_map_baked_building_visual_batch_root):
		return _world_map_baked_building_visual_batch_root
	_world_map_baked_building_visual_batch_root = Node3D.new()
	_world_map_baked_building_visual_batch_root.name = "BakedBuildingVisualBatches"
	add_child(_world_map_baked_building_visual_batch_root)
	return _world_map_baked_building_visual_batch_root

func _get_world_map_baked_building_visual_mesh(root: Node3D) -> MeshInstance3D:
	if root == null or not is_instance_valid(root):
		return null
	return root.get_node_or_null("Mesh") as MeshInstance3D

func _world_map_baked_building_visual_batch_key_from_position(position: Vector3) -> Vector2i:
	var batch_world_size := float(maxi(world_map_baked_building_visual_batch_size, 1) * CHUNK_SIZE)
	return Vector2i(
		int(floor(position.x / batch_world_size)),
		int(floor(position.z / batch_world_size))
	)

func _world_map_baked_building_visual_batch_key_for_root(root: Node3D) -> Vector2i:
	if root == null:
		return Vector2i.ZERO
	return _world_map_baked_building_visual_batch_key_from_position(root.position)

func _world_map_baked_building_visual_batch_origin(key: Vector2i) -> Vector3:
	var batch_world_size := float(maxi(world_map_baked_building_visual_batch_size, 1) * CHUNK_SIZE)
	return Vector3(
		(float(key.x) + 0.5) * batch_world_size,
		0.0,
		(float(key.y) + 0.5) * batch_world_size
	)

func _set_world_map_baked_building_visual_mesh_visible(root: Node3D, visible: bool) -> void:
	var mesh_instance := _get_world_map_baked_building_visual_mesh(root)
	if mesh_instance:
		mesh_instance.visible = visible

func _show_individual_world_map_baked_building_visuals_for_batch(key: Vector2i) -> void:
	for root_variant in _world_map_baked_building_visual_nodes.values():
		var root := root_variant as Node3D
		if root == null or not is_instance_valid(root) or not root.is_inside_tree():
			continue
		if _world_map_baked_building_visual_batch_key_for_root(root) != key:
			continue
		_set_world_map_baked_building_visual_mesh_visible(root, true)

func _mark_world_map_baked_building_visual_batch_dirty_for_root(root: Node3D, invalidate_visible_batch: bool = false) -> void:
	if not world_map_baked_building_visual_batching_enabled or not world_map_mode:
		return
	if root == null or not is_instance_valid(root):
		return
	var key := _world_map_baked_building_visual_batch_key_for_root(root)
	_world_map_baked_building_visual_batch_dirty[key] = true
	if invalidate_visible_batch and _world_map_baked_building_visual_batches.has(key):
		var batch_node := _world_map_baked_building_visual_batches[key] as MeshInstance3D
		if batch_node and is_instance_valid(batch_node):
			batch_node.visible = false
		_show_individual_world_map_baked_building_visuals_for_batch(key)
	_wake_process_loop()

func _mark_all_world_map_baked_building_visual_batches_dirty(invalidate_visible_batches: bool = false) -> void:
	if not world_map_baked_building_visual_batching_enabled or not world_map_mode:
		return
	for root_variant in _world_map_baked_building_visual_nodes.values():
		var root := root_variant as Node3D
		if root == null or not is_instance_valid(root) or not root.is_inside_tree():
			continue
		_mark_world_map_baked_building_visual_batch_dirty_for_root(root, invalidate_visible_batches)
	for key_variant in _world_map_baked_building_visual_batches.keys():
		var key: Vector2i = key_variant
		_world_map_baked_building_visual_batch_dirty[key] = true
		if invalidate_visible_batches:
			var batch_node := _world_map_baked_building_visual_batches[key] as MeshInstance3D
			if batch_node and is_instance_valid(batch_node):
				batch_node.visible = false
	if not _world_map_baked_building_visual_batch_dirty.is_empty():
		_wake_process_loop()

func _clear_world_map_baked_building_visual_batches(immediate: bool = false) -> void:
	for key_variant in _world_map_baked_building_visual_batches.keys():
		var key: Vector2i = key_variant
		_show_individual_world_map_baked_building_visuals_for_batch(key)
	for node in _world_map_baked_building_visual_batches.values():
		if node and is_instance_valid(node):
			if immediate or not node.is_inside_tree():
				node.free()
			else:
				node.queue_free()
	_world_map_baked_building_visual_batches.clear()
	_world_map_baked_building_visual_batch_dirty.clear()
	_last_world_map_baked_building_visual_batch_rebuild_ms = 0.0
	_last_world_map_baked_building_visual_batch_rebuild_count = 0
	_last_world_map_baked_building_visual_batch_source_nodes = 0
	_last_world_map_baked_building_visual_batch_source_surfaces = 0
	_last_world_map_baked_building_visual_batch_output_surfaces = 0
	_last_world_map_baked_building_visual_batch_hidden_nodes = 0

func _build_world_map_baked_building_visual_batch_mesh(entries: Array, batch_origin: Vector3) -> Dictionary:
	var groups: Dictionary = {}
	var group_order: Array[String] = []
	var source_surfaces := 0

	for entry_variant in entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		var root := entry.get("root", null) as Node3D
		var mesh_instance := entry.get("mesh_instance", null) as MeshInstance3D
		if root == null or mesh_instance == null or mesh_instance.mesh == null:
			continue
		var mesh := mesh_instance.mesh
		var offset := root.position - batch_origin
		for surface_index in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(surface_index)
			if arrays.size() <= Mesh.ARRAY_VERTEX:
				continue
			var source_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if source_vertices.is_empty():
				continue
			var material := mesh.surface_get_material(surface_index)
			var material_key := "material_%d" % (material.get_instance_id() if material else surface_index)
			if not groups.has(material_key):
				groups[material_key] = {
					"material": material,
					"vertices": PackedVector3Array(),
					"normals": PackedVector3Array(),
					"colors": PackedColorArray(),
					"uvs": PackedVector2Array(),
					"indices": PackedInt32Array()
				}
				group_order.append(material_key)
			var group: Dictionary = groups[material_key]
			var vertices: PackedVector3Array = group["vertices"]
			var normals: PackedVector3Array = group["normals"]
			var colors: PackedColorArray = group["colors"]
			var uvs: PackedVector2Array = group["uvs"]
			var indices: PackedInt32Array = group["indices"]
			var vertex_offset := vertices.size()
			var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays.size() > Mesh.ARRAY_NORMAL else PackedVector3Array()
			var source_colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays.size() > Mesh.ARRAY_COLOR else PackedColorArray()
			var source_uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays.size() > Mesh.ARRAY_TEX_UV else PackedVector2Array()
			var source_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else PackedInt32Array()

			for i in range(source_vertices.size()):
				vertices.append(source_vertices[i] + offset)
				normals.append(source_normals[i] if i < source_normals.size() else Vector3.UP)
				colors.append(source_colors[i] if i < source_colors.size() else Color(1.0, 1.0, 1.0, 1.0))
				uvs.append(source_uvs[i] if i < source_uvs.size() else Vector2.ZERO)

			if source_indices.is_empty():
				for i in range(source_vertices.size()):
					indices.append(vertex_offset + i)
			else:
				for source_index in source_indices:
					indices.append(vertex_offset + int(source_index))

			group["vertices"] = vertices
			group["normals"] = normals
			group["colors"] = colors
			group["uvs"] = uvs
			group["indices"] = indices
			groups[material_key] = group
			source_surfaces += 1

	if groups.is_empty():
		return {}

	var merged_mesh := ArrayMesh.new()
	for material_key in group_order:
		var group: Dictionary = groups[material_key]
		var vertices: PackedVector3Array = group["vertices"]
		if vertices.is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = group["normals"]
		arrays[Mesh.ARRAY_COLOR] = group["colors"]
		arrays[Mesh.ARRAY_TEX_UV] = group["uvs"]
		arrays[Mesh.ARRAY_INDEX] = group["indices"]
		merged_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := group.get("material", null) as Material
		if material:
			merged_mesh.surface_set_material(merged_mesh.get_surface_count() - 1, material)

	return {
		"mesh": merged_mesh,
		"source_surfaces": source_surfaces,
		"output_surfaces": merged_mesh.get_surface_count()
	}

func _collect_world_map_baked_building_visual_batch_entries(key: Vector2i) -> Array:
	var entries: Array = []
	for root_variant in _world_map_baked_building_visual_nodes.values():
		var root := root_variant as Node3D
		if root == null or not is_instance_valid(root) or not root.is_inside_tree():
			continue
		if _world_map_baked_building_visual_batch_key_for_root(root) != key:
			continue
		var mesh_instance := _get_world_map_baked_building_visual_mesh(root)
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		entries.append({
			"root": root,
			"mesh_instance": mesh_instance
		})
	return entries

func _apply_world_map_baked_building_visual_batch_mesh(key: Vector2i, entries: Array, merged_mesh: ArrayMesh) -> void:
	var batch_node: MeshInstance3D = null
	if _world_map_baked_building_visual_batches.has(key):
		batch_node = _world_map_baked_building_visual_batches[key] as MeshInstance3D
		if not is_instance_valid(batch_node):
			batch_node = null
	if batch_node == null:
		batch_node = MeshInstance3D.new()
		batch_node.name = "BakedBuildingVisualBatch_%d_%d" % [key.x, key.y]
		batch_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		batch_node.add_to_group("building_chunks")
		_get_world_map_baked_building_visual_batch_root().add_child(batch_node)
		_world_map_baked_building_visual_batches[key] = batch_node

	batch_node.position = _world_map_baked_building_visual_batch_origin(key)
	batch_node.mesh = merged_mesh
	batch_node.visible = true
	for entry_variant in entries:
		var entry: Dictionary = entry_variant
		var root := entry.get("root", null) as Node3D
		_set_world_map_baked_building_visual_mesh_visible(root, false)
	_last_world_map_baked_building_visual_batch_hidden_nodes = _count_hidden_world_map_baked_building_visual_nodes()

func _rebuild_world_map_baked_building_visual_batch(key: Vector2i) -> bool:
	var entries := _collect_world_map_baked_building_visual_batch_entries(key)
	_last_world_map_baked_building_visual_batch_source_nodes = entries.size()
	if entries.is_empty():
		if _world_map_baked_building_visual_batches.has(key):
			var old_node := _world_map_baked_building_visual_batches[key] as Node
			_world_map_baked_building_visual_batches.erase(key)
			if old_node:
				old_node.queue_free()
		return true

	var batch_origin := _world_map_baked_building_visual_batch_origin(key)
	var build_result := _build_world_map_baked_building_visual_batch_mesh(entries, batch_origin)
	var merged_mesh := build_result.get("mesh", null) as ArrayMesh
	_last_world_map_baked_building_visual_batch_source_surfaces = int(build_result.get("source_surfaces", 0))
	_last_world_map_baked_building_visual_batch_output_surfaces = int(build_result.get("output_surfaces", 0))
	if merged_mesh == null:
		_show_individual_world_map_baked_building_visuals_for_batch(key)
		return true

	_apply_world_map_baked_building_visual_batch_mesh(key, entries, merged_mesh)
	return true

func _process_world_map_baked_building_visual_batches() -> void:
	_last_world_map_baked_building_visual_batch_rebuild_count = 0
	_last_world_map_baked_building_visual_batch_rebuild_ms = 0.0
	if not world_map_baked_building_visual_batching_enabled or not world_map_mode:
		if not _world_map_baked_building_visual_batches.is_empty():
			_clear_world_map_baked_building_visual_batches()
		return
	if _world_map_baked_building_visual_batch_dirty.is_empty():
		return

	var start_us := Time.get_ticks_usec()
	var rebuilt := 0
	var keys := _world_map_baked_building_visual_batch_dirty.keys()
	for key_variant in keys:
		if rebuilt >= world_map_baked_building_visual_batch_rebuilds_per_frame:
			break
		var key: Vector2i = key_variant
		if _rebuild_world_map_baked_building_visual_batch(key):
			_world_map_baked_building_visual_batch_dirty.erase(key)
			rebuilt += 1

	_last_world_map_baked_building_visual_batch_rebuild_count = rebuilt
	_last_world_map_baked_building_visual_batch_rebuild_ms = float(Time.get_ticks_usec() - start_us) / 1000.0

func _count_hidden_world_map_baked_building_visual_nodes() -> int:
	var total := 0
	for root_variant in _world_map_baked_building_visual_nodes.values():
		var root := root_variant as Node3D
		if root == null or not is_instance_valid(root) or not root.is_inside_tree():
			continue
		var mesh_instance := _get_world_map_baked_building_visual_mesh(root)
		if mesh_instance and mesh_instance.mesh and not mesh_instance.visible:
			total += 1
	return total

func clear_world_map_baked_building_visuals(immediate: bool = false) -> void:
	clear_pending_world_map_baked_object_spawns()
	_clear_world_map_baked_building_visual_batches(immediate)
	for node in _world_map_baked_building_visual_nodes.values():
		if node and is_instance_valid(node):
			if immediate or not node.is_inside_tree():
				node.free()
			else:
				node.queue_free()
	_world_map_baked_building_visual_nodes.clear()
	_world_map_baked_building_visual_payloads_by_key.clear()
	_world_map_baked_building_keys_by_chunk.clear()
	_world_map_baked_building_chunk_coords_by_key.clear()
	clear_world_map_baked_building_edits()
	_last_apply_world_map_baked_building_payload_ms = 0.0
	_last_apply_world_map_baked_building_payload_chunk_ms = 0.0
	_last_apply_world_map_baked_building_payload_object_ms = 0.0
	_last_apply_world_map_baked_building_payload_flush_ms = 0.0
	_last_apply_world_map_baked_building_payload_slowest_object_ms = 0.0
	_last_apply_world_map_baked_building_payload_slowest_object_id = -1
	_last_apply_world_map_baked_building_payload_slowest_object_scene_path = ""
	_last_apply_world_map_baked_building_payload_slowest_object_world_pos = Vector3.ZERO
	_last_apply_world_map_baked_building_payload_slow_object_spawns = []
	_last_apply_world_map_baked_building_visual_ms = 0.0
	_last_apply_world_map_baked_building_visual_root_ms = 0.0
	_last_apply_world_map_baked_building_visual_mesh_attach_ms = 0.0
	_last_apply_world_map_baked_building_visual_body_attach_ms = 0.0
	_last_apply_world_map_baked_building_visual_mesh_ms = 0.0
	_last_apply_world_map_baked_building_visual_collision_ms = 0.0
	_last_apply_world_map_baked_building_visual_sync_ms = 0.0
	_last_apply_world_map_baked_building_visual_count = 0
	_last_world_map_baked_object_spawn_queue_ms = 0.0
	_last_world_map_baked_object_spawn_queue_count = 0
	_last_world_map_baked_visibility_update_ms = 0.0
	_last_world_map_baked_visibility_added = 0
	_last_world_map_baked_visibility_removed = 0
	_last_world_map_baked_visibility_kept_visible = 0
	_last_world_map_baked_visibility_target_visible = 0
	_last_world_map_baked_visibility_total_roots = 0
	_last_world_map_baked_visibility_stale_roots = 0


func clear_world_map_baked_building_edits() -> void:
	_world_map_baked_building_edits_by_key.clear()


func _register_world_map_baked_building_chunk_coords(building_key: String, chunk_coords: Array) -> void:
	if building_key.is_empty() or chunk_coords.is_empty():
		return

	var stored_coords: Array = []
	for coord_variant in chunk_coords:
		if typeof(coord_variant) != TYPE_VECTOR3I:
			continue
		var coord: Vector3i = coord_variant
		if not stored_coords.has(coord):
			stored_coords.append(coord)
		var building_keys: Array = _world_map_baked_building_keys_by_chunk.get(coord, [])
		if not building_keys.has(building_key):
			building_keys.append(building_key)
		_world_map_baked_building_keys_by_chunk[coord] = building_keys

	if not stored_coords.is_empty():
		_world_map_baked_building_chunk_coords_by_key[building_key] = stored_coords


func _get_world_map_baked_building_keys_for_chunk(chunk_coord: Vector3i, preferred_building_key: String = "") -> Array:
	var building_keys: Array = []
	if not preferred_building_key.is_empty():
		var preferred_payload_variant: Variant = _world_map_baked_building_visual_payloads_by_key.get(preferred_building_key, {})
		if typeof(preferred_payload_variant) == TYPE_DICTIONARY:
			var preferred_payload: Dictionary = preferred_payload_variant
			if not preferred_payload.is_empty():
				building_keys.append(preferred_building_key)
				return building_keys

	var keys_variant: Variant = _world_map_baked_building_keys_by_chunk.get(chunk_coord, [])
	if typeof(keys_variant) != TYPE_ARRAY:
		return building_keys

	for key_variant in keys_variant:
		var building_key := str(key_variant)
		if building_key.is_empty() or building_keys.has(building_key):
			continue
		building_keys.append(building_key)

	return building_keys


func _remove_world_map_baked_building_visual(building_key: String) -> void:
	if building_key.is_empty():
		return
	var root: Node3D = _world_map_baked_building_visual_nodes.get(building_key, null)
	if root and is_instance_valid(root):
		_mark_world_map_baked_building_visual_batch_dirty_for_root(root, true)
		if root.is_inside_tree():
			root.queue_free()
		else:
			root.free()
	_world_map_baked_building_visual_nodes.erase(building_key)


func _is_world_map_baked_building_in_range(building_key: String, center_chunk: Vector3i, extra_distance: int = 0) -> bool:
	var coords_variant: Variant = _world_map_baked_building_chunk_coords_by_key.get(building_key, [])
	if typeof(coords_variant) != TYPE_ARRAY:
		return true
	var coords: Array = coords_variant
	if coords.is_empty():
		return true

	var max_dist := _get_world_map_visibility_distance(extra_distance)
	var max_dist_sq := max_dist * max_dist
	for coord_variant in coords:
		if typeof(coord_variant) != TYPE_VECTOR3I:
			continue
		var coord: Vector3i = coord_variant
		var dx := coord.x - center_chunk.x
		var dy := coord.y - center_chunk.y
		var dz := coord.z - center_chunk.z
		if dx * dx + dy * dy + dz * dz <= max_dist_sq:
			return true
	return false


func _set_world_map_baked_building_visual_in_tree(building_key: String, should_be_in_tree: bool) -> void:
	var root: Node3D = _world_map_baked_building_visual_nodes.get(building_key, null)
	if root == null or not is_instance_valid(root):
		return

	var was_in_tree := root.is_inside_tree()
	if should_be_in_tree:
		var parent := root.get_parent()
		if parent == self:
			return
		if parent:
			parent.remove_child(root)
		add_child(root)
		_set_world_map_baked_building_visual_mesh_visible(root, true)
		_mark_world_map_baked_building_visual_batch_dirty_for_root(root, true)
		return

	var existing_parent := root.get_parent()
	if existing_parent:
		if was_in_tree:
			_mark_world_map_baked_building_visual_batch_dirty_for_root(root, true)
		existing_parent.remove_child(root)
		_set_world_map_baked_building_visual_mesh_visible(root, true)


func _sync_world_map_baked_building_visual_visibility_for_key(building_key: String) -> void:
	if building_key.is_empty():
		return
	if not viewer:
		_set_world_map_baked_building_visual_in_tree(building_key, true)
		return
	var center_chunk := _get_current_building_center_chunk()
	_set_world_map_baked_building_visual_in_tree(
		building_key,
		_is_world_map_baked_building_in_range(building_key, center_chunk)
	)


func _update_world_map_baked_building_visual_visibility(center_chunk: Vector3i) -> void:
	if _world_map_baked_building_visual_nodes.is_empty():
		_last_world_map_baked_visibility_update_ms = 0.0
		_last_world_map_baked_visibility_added = 0
		_last_world_map_baked_visibility_removed = 0
		_last_world_map_baked_visibility_kept_visible = 0
		_last_world_map_baked_visibility_target_visible = 0
		_last_world_map_baked_visibility_total_roots = 0
		_last_world_map_baked_visibility_stale_roots = 0
		return

	var start_us := Time.get_ticks_usec()
	var added := 0
	var removed := 0
	var kept_visible := 0
	var target_visible := 0
	var total_roots := 0
	var stale_keys: Array[String] = []
	for key_variant in _world_map_baked_building_visual_nodes.keys():
		var building_key := str(key_variant)
		var root: Node3D = _world_map_baked_building_visual_nodes.get(building_key, null)
		if root == null or not is_instance_valid(root):
			stale_keys.append(building_key)
			continue

		total_roots += 1
		var was_visible := root.is_inside_tree()
		var should_be_visible := _is_world_map_baked_building_in_range(building_key, center_chunk, WORLD_MAP_VISIBILITY_EXTRA_DISTANCE)
		if should_be_visible:
			target_visible += 1
		_set_world_map_baked_building_visual_in_tree(building_key, should_be_visible)
		var is_visible := root.is_inside_tree()
		if not was_visible and is_visible:
			added += 1
		elif was_visible and not is_visible:
			removed += 1
		elif is_visible:
			kept_visible += 1

	for building_key in stale_keys:
		_world_map_baked_building_visual_nodes.erase(building_key)

	_last_world_map_baked_visibility_update_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
	_last_world_map_baked_visibility_added = added
	_last_world_map_baked_visibility_removed = removed
	_last_world_map_baked_visibility_kept_visible = kept_visible
	_last_world_map_baked_visibility_target_visible = target_visible
	_last_world_map_baked_visibility_total_roots = total_roots
	_last_world_map_baked_visibility_stale_roots = stale_keys.size()


func _get_world_map_visibility_distance(extra_distance: int = 0) -> int:
	var base_distance := maxi(render_distance + extra_distance, 0)
	if not world_map_mode:
		return base_distance

	# Terrain chunks span a larger world-space footprint than building chunks.
	# Match against the actual TerrainManager radius so baked building shells do
	# not stay visible far beyond the loaded terrain boundary.
	var terrain_render_distance := base_distance
	var terrain_manager := _get_terrain_manager()
	if terrain_manager and "render_distance" in terrain_manager:
		terrain_render_distance = maxi(int(terrain_manager.render_distance) + extra_distance, 0)
	var terrain_world_radius := terrain_render_distance * WORLD_MAP_TERRAIN_CHUNK_STRIDE
	return maxi(base_distance, int(ceil(float(terrain_world_radius) / float(CHUNK_SIZE))))


func _update_world_map_baked_building_visual_for_voxel(building_key: String, voxel_pos: Vector3, value: int, meta: int) -> bool:
	if building_key.is_empty():
		return false

	var payload_variant: Variant = _world_map_baked_building_visual_payloads_by_key.get(building_key, {})
	if typeof(payload_variant) != TYPE_DICTIONARY:
		return false
	var visual_payload: Dictionary = payload_variant
	if visual_payload.is_empty():
		return false

	var voxel_bytes: PackedByteArray = visual_payload.get("voxel_bytes", PackedByteArray())
	var voxel_meta: PackedByteArray = visual_payload.get("voxel_meta", PackedByteArray())
	var voxel_size := int(visual_payload.get("voxel_size", 0))
	var voxel_origin_variant: Variant = visual_payload.get("voxel_origin", Vector3.ZERO)
	var voxel_origin: Vector3 = voxel_origin_variant if typeof(voxel_origin_variant) == TYPE_VECTOR3 else Vector3.ZERO
	if voxel_bytes.is_empty() or voxel_meta.is_empty() or voxel_size <= 0:
		return false

	var local_x := int(floor(voxel_pos.x)) - int(floor(voxel_origin.x))
	var local_y := int(floor(voxel_pos.y)) - int(floor(voxel_origin.y))
	var local_z := int(floor(voxel_pos.z)) - int(floor(voxel_origin.z))
	if local_x < 0 or local_y < 0 or local_z < 0 or local_x >= voxel_size or local_y >= voxel_size or local_z >= voxel_size:
		return false

	var local_index := local_x + local_y * voxel_size + local_z * voxel_size * voxel_size
	if local_index < 0 or local_index >= voxel_bytes.size():
		return false

	voxel_bytes.encode_u8(local_index, mini(maxi(int(value), 0), 255))
	voxel_meta.encode_u8(local_index, mini(maxi(int(meta), 0), 255))
	visual_payload["voxel_bytes"] = voxel_bytes
	visual_payload["voxel_meta"] = voxel_meta
	_world_map_baked_building_visual_payloads_by_key[building_key] = visual_payload

	var root: Node3D = _world_map_baked_building_visual_nodes.get(building_key, null)
	if root == null or not is_instance_valid(root):
		return false

	if not mesher or not mesher.has_method("build_building_mesh_from_voxels"):
		return false

	var use_box_collision := true
	if mesher.has_method("voxels_need_detailed_collision"):
		use_box_collision = not bool(mesher.voxels_need_detailed_collision(voxel_bytes))

	var mesh_result: Dictionary = mesher.build_building_mesh_from_voxels(voxel_bytes, voxel_meta, use_box_collision, voxel_size)
	if mesh_result.is_empty():
		_remove_world_map_baked_building_visual(building_key)
		return true

	visual_payload["mesh"] = mesh_result.get("mesh", null)
	visual_payload["shape"] = mesh_result.get("shape", null)
	visual_payload["collision_boxes"] = mesh_result.get("collision_boxes", [])
	_world_map_baked_building_visual_payloads_by_key[building_key] = visual_payload
	return _apply_world_map_baked_building_visual(building_key, visual_payload)


func _get_world_map_baked_building_edit_key(voxel_pos: Vector3) -> String:
	return "%d,%d,%d" % [int(floor(voxel_pos.x)), int(floor(voxel_pos.y)), int(floor(voxel_pos.z))]


func _record_world_map_baked_building_edit(building_key: String, voxel_pos: Vector3, value: int, meta: int) -> void:
	if building_key.is_empty():
		return

	var edit_key := _get_world_map_baked_building_edit_key(voxel_pos)
	if edit_key.is_empty():
		return

	var building_edits_variant: Variant = _world_map_baked_building_edits_by_key.get(building_key, {})
	var building_edits: Dictionary = building_edits_variant if typeof(building_edits_variant) == TYPE_DICTIONARY else {}
	building_edits[edit_key] = {
		"value": mini(maxi(int(value), 0), 255),
		"meta": mini(maxi(int(meta), 0), 255)
	}
	_world_map_baked_building_edits_by_key[building_key] = building_edits


func _apply_world_map_baked_building_saved_edits(building_key: String) -> int:
	if building_key.is_empty():
		return 0

	var edits_variant: Variant = _world_map_baked_building_edits_by_key.get(building_key, {})
	if typeof(edits_variant) != TYPE_DICTIONARY:
		return 0

	var edits: Dictionary = edits_variant
	if edits.is_empty():
		return 0

	var applied := 0
	var edit_keys: Array = edits.keys()
	for edit_key_variant in edit_keys:
		var edit_key := str(edit_key_variant)
		if edit_key.is_empty():
			continue

		var parts := edit_key.split(",")
		if parts.size() != 3:
			continue

		var edit_variant: Variant = edits.get(edit_key, {})
		if typeof(edit_variant) != TYPE_DICTIONARY:
			continue
		var edit: Dictionary = edit_variant
		var voxel_pos := Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
		set_voxel(voxel_pos, int(edit.get("value", 0)), int(edit.get("meta", 0)), building_key)
		applied += 1

	return applied


func get_world_map_baked_building_edits_save_data() -> Dictionary:
	if not world_map_mode or _world_map_baked_building_edits_by_key.is_empty():
		return {}

	var buildings: Dictionary = {}
	for building_key_variant in _world_map_baked_building_edits_by_key.keys():
		var building_key := str(building_key_variant)
		if building_key.is_empty():
			continue

		var edits_variant: Variant = _world_map_baked_building_edits_by_key.get(building_key, {})
		if typeof(edits_variant) != TYPE_DICTIONARY:
			continue
		var edits: Dictionary = edits_variant
		if edits.is_empty():
			continue
		buildings[building_key] = edits.duplicate(true)

	if buildings.is_empty():
		return {}

	return {
		"version": 1,
		"buildings": buildings
	}


func load_world_map_baked_building_edits_save_data(data: Dictionary) -> void:
	clear_world_map_baked_building_edits()
	if data.is_empty():
		return

	var buildings_variant: Variant = data.get("buildings", data)
	if typeof(buildings_variant) != TYPE_DICTIONARY:
		return

	var buildings: Dictionary = buildings_variant
	for building_key_variant in buildings.keys():
		var building_key := str(building_key_variant)
		if building_key.is_empty():
			continue

		var building_entry_variant: Variant = buildings.get(building_key, {})
		var building_edits_variant: Variant = building_entry_variant
		if typeof(building_entry_variant) == TYPE_DICTIONARY:
			var building_entry: Dictionary = building_entry_variant
			if building_entry.has("edits"):
				building_edits_variant = building_entry.get("edits", {})

		if typeof(building_edits_variant) != TYPE_DICTIONARY:
			continue

		var building_edits: Dictionary = building_edits_variant
		if building_edits.is_empty():
			continue

		var normalized_edits: Dictionary = {}
		for edit_key_variant in building_edits.keys():
			var edit_key := str(edit_key_variant)
			if edit_key.is_empty():
				continue

			var parts := edit_key.split(",")
			if parts.size() != 3:
				continue

			var edit_variant: Variant = building_edits.get(edit_key, {})
			if typeof(edit_variant) != TYPE_DICTIONARY:
				continue
			var edit: Dictionary = edit_variant
			normalized_edits[edit_key] = {
				"value": mini(maxi(int(edit.get("value", 0)), 0), 255),
				"meta": mini(maxi(int(edit.get("meta", 0)), 0), 255)
			}

		if not normalized_edits.is_empty():
			_world_map_baked_building_edits_by_key[building_key] = normalized_edits


func _get_world_map_baked_building_edit_count() -> int:
	var total := 0
	for edits_variant in _world_map_baked_building_edits_by_key.values():
		if typeof(edits_variant) != TYPE_DICTIONARY:
			continue
		total += (edits_variant as Dictionary).size()
	return total


func clear_for_shutdown() -> void:
	clear_pending_object_collision_tasks()
	clear_pending_world_map_baked_object_spawns()
	clear_global_visual_batches()
	clear_world_map_baked_building_visuals()
	for chunk in chunks.values():
		if chunk and is_instance_valid(chunk):
			chunk.queue_free()
	for chunk in chunk_pool:
		if chunk and is_instance_valid(chunk):
			chunk.queue_free()
	chunk_pool.clear()
	chunks.clear()
	visible_chunks.clear()
	_dirty_chunks.clear()
	_object_spawn_profile_cache.clear()
	_cached_vehicle_manager = null
	_native_helper = null


func clear_immediate_for_shutdown() -> void:
	clear_pending_object_collision_tasks()
	clear_pending_world_map_baked_object_spawns()
	for node in _global_visual_batch_nodes.values():
		if node and is_instance_valid(node):
			node.free()
	clear_world_map_baked_building_visuals(true)
	for chunk in chunks.values():
		if chunk and is_instance_valid(chunk):
			chunk.free()
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
	_last_global_visual_batch_center_chunk = Vector3i(2147483647, 2147483647, 2147483647)
	_object_spawn_profile_cache.clear()
	_cached_vehicle_manager = null
	_native_helper = null


func _exit_tree() -> void:
	clear_immediate_for_shutdown()

func flush_global_visual_batches() -> void:
	if _dirty_global_visual_batch_object_ids.is_empty():
		return
	_ensure_global_visual_batch_center_chunk()

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
	_sync_process_loop()

func apply_world_map_baked_building_payload(chunk_payload: Dictionary, object_spawns: Array = [], flush_now: bool = true, force_flush: bool = false, building_visual_payload: Dictionary = {}, building_key: String = "") -> void:
	if chunk_payload.is_empty() and object_spawns.is_empty():
		return

	var start_time := Time.get_ticks_usec()
	var applied_chunks := 0
	var applied_objects := 0
	var applied_prebuilt_chunks := 0
	var applied_building_visual := false
	var visual_start_us := 0
	var defer_global_visual_batch_rebuild := world_map_mode

	if not building_key.is_empty():
		_register_world_map_baked_building_chunk_coords(building_key, chunk_payload.keys())
		if not building_visual_payload.is_empty():
			_world_map_baked_building_visual_payloads_by_key[building_key] = building_visual_payload

	if world_map_mode and not building_visual_payload.is_empty():
		visual_start_us = Time.get_ticks_usec()
		applied_building_visual = _apply_world_map_baked_building_visual(building_key, building_visual_payload)
		if applied_building_visual:
			applied_prebuilt_chunks = 1

	var chunk_apply_start_us := Time.get_ticks_usec()
	for chunk_coord_variant in chunk_payload.keys():
		var chunk_coord: Vector3i = chunk_coord_variant
		var batch_variant: Variant = chunk_payload.get(chunk_coord, {})
		if typeof(batch_variant) != TYPE_DICTIONARY:
			continue
		var batch: Dictionary = batch_variant
		if batch.is_empty():
			continue

		var indices_variant: Variant = batch.get("indices", PackedInt32Array())
		var types_variant: Variant = batch.get("types", PackedByteArray())
		var metas_variant: Variant = batch.get("metas", PackedByteArray())
		var arrays_variant: Variant = batch.get("arrays", [])
		var mesh_variant: Variant = batch.get("mesh", null)
		var shape_variant: Variant = batch.get("shape", null)
		var collision_boxes_variant: Variant = batch.get("collision_boxes", [])
		var indices: PackedInt32Array = indices_variant
		var types: PackedByteArray = types_variant
		var metas: PackedByteArray = metas_variant
		if indices.is_empty() or types.is_empty() or metas.is_empty():
			continue

		var chunk := get_chunk(chunk_coord)
		chunk.apply_voxel_batch_indices(indices, types, metas)
		if applied_building_visual:
			chunk.clear_baked_render_state()
			_clear_chunk_dirty(chunk_coord)
		else:
			var arrays: Array = arrays_variant
			var mesh: ArrayMesh = mesh_variant
			var shape: Shape3D = shape_variant
			var collision_boxes: Array = collision_boxes_variant
			var applied_direct_mesh := false
			if mesh != null:
				chunk.apply_mesh([], shape, mesh, collision_boxes)
				applied_direct_mesh = true
			elif not arrays.is_empty():
				chunk.apply_mesh(arrays, shape, null, collision_boxes)
				applied_direct_mesh = true

			if applied_direct_mesh:
				_clear_chunk_dirty(chunk_coord)
				applied_prebuilt_chunks += 1
			else:
				mark_chunk_dirty(chunk_coord, chunk)
		applied_chunks += 1
	_last_apply_world_map_baked_building_payload_chunk_ms = float(Time.get_ticks_usec() - chunk_apply_start_us) / 1000.0

	if not building_key.is_empty():
		_apply_world_map_baked_building_saved_edits(building_key)

	var object_apply_start_us := Time.get_ticks_usec()
	if flush_now and has_dirty_chunks():
		flush_dirty_chunks(force_flush)

	var slow_object_spawns: Array = []
	if world_map_mode and not flush_now:
		applied_objects = _queue_world_map_baked_object_spawns(object_spawns)
	else:
		for spawn_variant in object_spawns:
			if typeof(spawn_variant) != TYPE_DICTIONARY:
				continue

			var spawn: Dictionary = spawn_variant
			var world_pos_variant: Variant = spawn.get("world_pos", Vector3.ZERO)
			if typeof(world_pos_variant) != TYPE_VECTOR3:
				continue
			var world_pos: Vector3 = world_pos_variant
			var object_id := int(spawn.get("object_id", -1))
			var object_scene_path := str(spawn.get("object_scene_path", ""))
			if object_id < 0 and object_scene_path.is_empty():
				continue

			var spawn_start_us := Time.get_ticks_usec()
			var success := _apply_world_map_baked_object_spawn(spawn, defer_global_visual_batch_rebuild)
			var object_elapsed_ms := float(Time.get_ticks_usec() - spawn_start_us) / 1000.0
			_record_world_map_baked_object_spawn_timing(
				spawn,
				object_elapsed_ms,
				object_id,
				object_scene_path,
				world_pos,
				slow_object_spawns
			)
			if success:
				applied_objects += 1
	_last_apply_world_map_baked_building_payload_object_ms = float(Time.get_ticks_usec() - object_apply_start_us) / 1000.0
	_last_apply_world_map_baked_building_payload_slow_object_spawns = _build_top_world_map_baked_building_slow_object_spawns(slow_object_spawns)

	var flush_start_us := Time.get_ticks_usec()
	if flush_now and defer_global_visual_batch_rebuild and has_dirty_global_visual_batches():
		flush_global_visual_batches()
	_last_apply_world_map_baked_building_payload_flush_ms = float(Time.get_ticks_usec() - flush_start_us) / 1000.0

	if applied_building_visual:
		_last_apply_world_map_baked_building_visual_ms = float(Time.get_ticks_usec() - visual_start_us) / 1000.0
		_last_apply_world_map_baked_building_visual_count = 1
	else:
		_last_apply_world_map_baked_building_visual_ms = 0.0
		_last_apply_world_map_baked_building_visual_count = 0

	_last_apply_world_map_baked_building_payload_ms = float(Time.get_ticks_usec() - start_time) / 1000.0
	_last_apply_world_map_baked_building_chunk_count = applied_chunks
	_last_apply_world_map_baked_building_object_count = applied_objects
	_last_apply_world_map_baked_building_prebuilt_chunk_count = applied_prebuilt_chunks

func _apply_world_map_baked_object_spawn(spawn: Dictionary, defer_global_visual_batch_rebuild: bool) -> bool:
	var world_pos_variant: Variant = spawn.get("world_pos", Vector3.ZERO)
	if typeof(world_pos_variant) != TYPE_VECTOR3:
		return false
	var world_pos: Vector3 = world_pos_variant
	var object_id := int(spawn.get("object_id", -1))
	var object_scene_path := str(spawn.get("object_scene_path", ""))
	if object_id < 0 and object_scene_path.is_empty():
		return false
	if world_map_mode and object_id >= 0:
		return _place_world_map_baked_object_spawn(spawn, world_pos, object_id, object_scene_path, defer_global_visual_batch_rebuild)

	return place_object(
		world_pos,
		object_id,
		int(spawn.get("rotation", 0)),
		true,
		true,
		defer_global_visual_batch_rebuild,
		spawn.get("precomputed_cells", []),
		Vector3i(spawn.get("object_size", Vector3i.ZERO)),
		object_scene_path,
		bool(spawn.get("has_authored_collision", false)),
		bool(spawn.get("has_authored_collision_valid", false))
	)

func _get_object_spawn_profile(object_id: int, object_scene_path: String = "", object_size: Vector3i = Vector3i.ZERO, has_authored_collision: bool = false, has_authored_collision_valid: bool = false) -> Dictionary:
	if object_id < 0:
		return {}
	var profile_key := "%d|%s|%s|%s|%s" % [object_id, object_scene_path, str(object_size), str(has_authored_collision), str(has_authored_collision_valid)]
	if _object_spawn_profile_cache.has(profile_key):
		return _object_spawn_profile_cache[profile_key]

	var obj_def := ObjectRegistry.get_object(object_id)
	if obj_def.is_empty():
		return {}

	var resolved_scene_path := object_scene_path if not object_scene_path.is_empty() else str(obj_def.get("scene", ""))
	var resolved_size := object_size
	if resolved_size == Vector3i.ZERO:
		resolved_size = Vector3i(obj_def.get("size", Vector3i(1, 1, 1)))
	var visual_data := ObjectRegistry.get_object_visual_data(object_id)
	var batch_mode := ObjectRegistry.get_visual_batch_mode(object_id)
	var visual_safe := false
	if not visual_data.is_empty():
		if batch_mode == "simple":
			visual_safe = int(visual_data.get("mesh_instance_count", 0)) == 1
		elif batch_mode == "proxy":
			visual_safe = bool(visual_data.get("proxy_mesh_merged", false)) or int(visual_data.get("mesh_instance_count", 0)) == 1
	var proxy_visual := batch_mode == "proxy" and visual_safe
	var chunk_static_proxy := false
	if proxy_visual:
		match object_id:
			1, 2, 3, 5, 7:
				chunk_static_proxy = true

	var profile := {
		"scene_path": resolved_scene_path,
		"size": resolved_size,
		"has_authored_collision": has_authored_collision if has_authored_collision_valid else ObjectRegistry.get_object_has_authored_collision(object_id),
		"visual_data": visual_data,
		"simple_visual": batch_mode == "simple" and visual_safe,
		"proxy_visual": proxy_visual,
		"chunk_static_proxy": chunk_static_proxy
	}
	_object_spawn_profile_cache[profile_key] = profile
	return profile

func _build_object_local_cells(anchor: Vector3i, object_id: int, rotation: int, precomputed_cells: Array) -> Dictionary:
	var cells: Array[Vector3i] = []
	var local_cells: Array[Vector3i] = []
	if precomputed_cells.is_empty():
		cells = _build_object_cells(anchor, object_id, rotation, precomputed_cells)
		local_cells.resize(cells.size())
		for i in range(cells.size()):
			var cell: Vector3i = cells[i]
			var local_cell := Vector3i(cell.x % CHUNK_SIZE, cell.y % CHUNK_SIZE, cell.z % CHUNK_SIZE)
			if local_cell.x < 0: local_cell.x += CHUNK_SIZE
			if local_cell.y < 0: local_cell.y += CHUNK_SIZE
			if local_cell.z < 0: local_cell.z += CHUNK_SIZE
			local_cells[i] = local_cell
	else:
		cells.resize(precomputed_cells.size())
		local_cells.resize(precomputed_cells.size())
		for i in range(precomputed_cells.size()):
			var precomputed_cell: Vector3i = precomputed_cells[i]
			var cell: Vector3i = precomputed_cell + anchor
			cells[i] = cell
			var local_cell := Vector3i(cell.x % CHUNK_SIZE, cell.y % CHUNK_SIZE, cell.z % CHUNK_SIZE)
			if local_cell.x < 0: local_cell.x += CHUNK_SIZE
			if local_cell.y < 0: local_cell.y += CHUNK_SIZE
			if local_cell.z < 0: local_cell.z += CHUNK_SIZE
			local_cells[i] = local_cell
	return {
		"cells": cells,
		"local_cells": local_cells
	}

func _place_world_map_baked_object_spawn(spawn: Dictionary, world_pos: Vector3, object_id: int, object_scene_path: String, defer_global_visual_batch_rebuild: bool) -> bool:
	var profile := _get_object_spawn_profile(
		object_id,
		object_scene_path,
		Vector3i(spawn.get("object_size", Vector3i.ZERO)),
		bool(spawn.get("has_authored_collision", false)),
		bool(spawn.get("has_authored_collision_valid", false))
	)
	if profile.is_empty():
		return false

	var anchor := Vector3i(int(floor(world_pos.x)), int(floor(world_pos.y)), int(floor(world_pos.z)))
	var fractional_pos := world_pos - Vector3(anchor)
	var cell_data := _build_object_local_cells(anchor, object_id, int(spawn.get("rotation", 0)), spawn.get("precomputed_cells", []))
	var local_cells: Array[Vector3i] = cell_data.get("local_cells", [])

	var chunk_coord := Vector3i(
		int(floor(float(anchor.x) / CHUNK_SIZE)),
		int(floor(float(anchor.y) / CHUNK_SIZE)),
		int(floor(float(anchor.z) / CHUNK_SIZE))
	)
	var local_anchor := Vector3i(anchor.x % CHUNK_SIZE, anchor.y % CHUNK_SIZE, anchor.z % CHUNK_SIZE)
	if local_anchor.x < 0: local_anchor.x += CHUNK_SIZE
	if local_anchor.y < 0: local_anchor.y += CHUNK_SIZE
	if local_anchor.z < 0: local_anchor.z += CHUNK_SIZE

	var chunk := get_chunk(chunk_coord)
	var visual_data: Dictionary = profile.get("visual_data", {})
	var rotation := int(spawn.get("rotation", 0))
	if bool(profile.get("simple_visual", false)) and not visual_data.is_empty():
		return chunk.place_simple_visual_object(local_anchor, object_id, rotation, local_cells, fractional_pos, visual_data, defer_global_visual_batch_rebuild)
	if bool(profile.get("chunk_static_proxy", false)) and not visual_data.is_empty():
		return chunk.place_chunk_static_proxy_object(local_anchor, object_id, rotation, local_cells, fractional_pos, visual_data, defer_global_visual_batch_rebuild, true)

	var scene_instance: Node3D = null
	if bool(profile.get("proxy_visual", false)):
		scene_instance = ObjectRegistry.create_proxy_gameplay_shell(object_id, world_map_mode)
	if scene_instance == null:
		var scene_path := str(profile.get("scene_path", ""))
		var packed := ObjectRegistry.get_preloaded_scene(scene_path)
		if packed:
			scene_instance = packed.instantiate()
	if scene_instance and scene_instance.has_method("populate_loot"):
		scene_instance.set_meta("should_populate_loot", true)

	return chunk.place_object(
		local_anchor,
		object_id,
		rotation,
		local_cells,
		scene_instance,
		fractional_pos,
		true,
		defer_global_visual_batch_rebuild,
		profile.get("size", Vector3i(1, 1, 1)),
		bool(profile.get("has_authored_collision", false)),
		true
	)

func _record_world_map_baked_object_spawn_timing(spawn: Dictionary, object_elapsed_ms: float, object_id: int, object_scene_path: String, world_pos: Vector3, slow_object_spawns: Array) -> void:
	if object_elapsed_ms > _last_apply_world_map_baked_building_payload_slowest_object_ms:
		_last_apply_world_map_baked_building_payload_slowest_object_ms = object_elapsed_ms
		_last_apply_world_map_baked_building_payload_slowest_object_id = object_id
		_last_apply_world_map_baked_building_payload_slowest_object_scene_path = object_scene_path
		_last_apply_world_map_baked_building_payload_slowest_object_world_pos = world_pos
	slow_object_spawns.append({
		"elapsed_ms": object_elapsed_ms,
		"object_id": object_id,
		"scene_path": object_scene_path,
		"world_pos": world_pos,
		"rotation": int(spawn.get("rotation", 0))
	})

func _apply_world_map_baked_building_visual(building_key: String, visual_payload: Dictionary) -> bool:
	if building_key.is_empty() or visual_payload.is_empty():
		return false

	var mesh_variant: Variant = visual_payload.get("mesh", null)
	if mesh_variant == null or not (mesh_variant is ArrayMesh):
		return false
	var mesh: ArrayMesh = mesh_variant

	var voxel_bytes: PackedByteArray = visual_payload.get("voxel_bytes", PackedByteArray())
	if voxel_bytes.is_empty():
		return false

	var voxel_origin_variant: Variant = visual_payload.get("voxel_origin", Vector3.ZERO)
	var voxel_origin: Vector3 = voxel_origin_variant if typeof(voxel_origin_variant) == TYPE_VECTOR3 else Vector3.ZERO
	var building_index := int(visual_payload.get("building_index", -1))

	var visual_root_start_us := Time.get_ticks_usec()
	var root: Node3D = _world_map_baked_building_visual_nodes.get(building_key, null)
	if root == null or not is_instance_valid(root):
		root = Node3D.new()
		root.name = "BakedBuilding_%d" % maxi(building_index, 0)
		root.add_to_group("building_chunks")
		root.set_meta("building_key", building_key)
		_world_map_baked_building_visual_nodes[building_key] = root

	var target_position := to_local(voxel_origin) if is_inside_tree() else voxel_origin
	if root.position != target_position:
		root.position = target_position
	_last_apply_world_map_baked_building_visual_root_ms = float(Time.get_ticks_usec() - visual_root_start_us) / 1000.0

	var visual_mesh_attach_start_us := Time.get_ticks_usec()
	var mesh_instance := root.get_node_or_null("Mesh") as MeshInstance3D
	var mesh_instance_was_created := false
	if not mesh_instance:
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "Mesh"
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(mesh_instance)
		mesh_instance_was_created = true
	_last_apply_world_map_baked_building_visual_mesh_attach_ms = float(Time.get_ticks_usec() - visual_mesh_attach_start_us) / 1000.0

	var has_church_floor := bool(visual_payload.get("has_church_floor", false))
	var visual_mesh_start_us := Time.get_ticks_usec()
	BuildingVisuals.apply_shared_surface_materials(mesh, voxel_bytes, has_church_floor, true)
	var mesh_changed := mesh_instance.mesh != mesh
	if mesh_changed:
		mesh_instance.mesh = mesh
	if not mesh_instance.visible:
		mesh_instance.visible = true
	if BuildingVisuals.use_legacy_building_shader_override_for_test():
		BuildingVisuals.apply_runtime_surface_materials(mesh_instance, voxel_bytes, has_church_floor, true)
	else:
		if not mesh_instance_was_created and mesh_changed:
			var surface_count := mesh.get_surface_count()
			for surface_index in range(surface_count):
				mesh_instance.set_surface_override_material(surface_index, null)
		if not mesh_instance_was_created and mesh_instance.material_override != null:
			mesh_instance.material_override = null
	_last_apply_world_map_baked_building_visual_mesh_ms = float(Time.get_ticks_usec() - visual_mesh_start_us) / 1000.0

	var visual_body_attach_start_us := Time.get_ticks_usec()
	var static_body := root.get_node_or_null("StaticBody") as StaticBody3D
	var static_body_was_created := false
	if not static_body:
		static_body = StaticBody3D.new()
		static_body.name = "StaticBody"
		static_body.add_to_group("building_chunks")
		static_body.collision_layer = 1 + 512
		root.add_child(static_body)
		static_body_was_created = true
	_last_apply_world_map_baked_building_visual_body_attach_ms = float(Time.get_ticks_usec() - visual_body_attach_start_us) / 1000.0

	var visual_collision_start_us := Time.get_ticks_usec()
	if not static_body_was_created:
		for child in static_body.get_children():
			if child:
				child.free()

	var collision_boxes: Array = visual_payload.get("collision_boxes", [])
	var shape_variant: Variant = visual_payload.get("shape", null)
	var shape: Shape3D = shape_variant if shape_variant is Shape3D else null
	if collision_boxes.size() > 0 and mesher and mesher.has_method("apply_world_map_collision_boxes"):
		if not mesher.apply_world_map_collision_boxes(static_body.get_rid(), collision_boxes) and shape != null:
			var collision := CollisionShape3D.new()
			collision.shape = shape
			static_body.add_child(collision)
	elif shape != null:
		var collision := CollisionShape3D.new()
		collision.shape = shape
		static_body.add_child(collision)
	_last_apply_world_map_baked_building_visual_collision_ms = float(Time.get_ticks_usec() - visual_collision_start_us) / 1000.0

	var visual_sync_start_us := Time.get_ticks_usec()
	_sync_world_map_baked_building_visual_visibility_for_key(building_key)
	_mark_world_map_baked_building_visual_batch_dirty_for_root(root, true)
	_last_apply_world_map_baked_building_visual_sync_ms = float(Time.get_ticks_usec() - visual_sync_start_us) / 1000.0
	return true

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

	var visible_entries := _get_visible_global_visual_batch_entries(entries)
	multimesh.instance_count = visible_entries.size()
	multimesh.buffer = _pack_global_visual_batch_transform_buffer(visible_entries)

func _pack_global_visual_batch_transform_buffer(entries: Array) -> PackedFloat32Array:
	var native := _get_native_helper()
	if native and native.has_method("pack_multimesh_buffer_from_instances"):
		return native.pack_multimesh_buffer_from_instances(entries)

	var buffer := PackedFloat32Array()
	buffer.resize(entries.size() * MULTIMESH_FLOATS_PER_INSTANCE_3D)

	var write_index := 0
	for entry_variant in entries:
		var entry: Dictionary = entry_variant
		var transform: Transform3D = entry.get("transform", Transform3D.IDENTITY)
		buffer[write_index + 0] = transform.basis.x.x
		buffer[write_index + 1] = transform.basis.y.x
		buffer[write_index + 2] = transform.basis.z.x
		buffer[write_index + 3] = transform.origin.x
		buffer[write_index + 4] = transform.basis.x.y
		buffer[write_index + 5] = transform.basis.y.y
		buffer[write_index + 6] = transform.basis.z.y
		buffer[write_index + 7] = transform.origin.y
		buffer[write_index + 8] = transform.basis.x.z
		buffer[write_index + 9] = transform.basis.y.z
		buffer[write_index + 10] = transform.basis.z.z
		buffer[write_index + 11] = transform.origin.z
		write_index += MULTIMESH_FLOATS_PER_INSTANCE_3D
	return buffer

func get_telemetry_snapshot() -> Dictionary:
	var total_objects := 0
	var total_object_nodes := 0
	var total_object_collision_nodes := 0
	var total_collision_box_shapes := 0
	var total_simple_visual_instances := 0
	var total_visual_batches := 0
	var total_occupied_cells := 0
	var total_chunk_static_proxy_instances := 0
	var total_chunk_static_proxy_shapes := 0
	var total_virtual_container_nodes := 0
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
		total_chunk_static_proxy_instances += chunk.chunk_static_proxy_instances.size()
		total_chunk_static_proxy_shapes += chunk.chunk_static_proxy_shape_indices.size()
		total_virtual_container_nodes += chunk.virtual_container_nodes.size()
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
		"process_loop_awake": is_processing(),
		"viewer_chunk_update_interval": viewer_chunk_update_interval,
		"viewer_chunk_update_timer_active": _viewer_chunk_update_timer != null and is_instance_valid(_viewer_chunk_update_timer) and not _viewer_chunk_update_timer.is_stopped(),
		"last_building_viewer_chunk": _last_building_viewer_chunk,
		"chunk_count": chunks.size(),
		"visible_chunk_count": visible_chunks.size(),
		"dirty_chunk_count": _dirty_chunks.size(),
		"pending_object_collision_jobs": _pending_object_collision_tasks.size(),
		"pending_world_map_baked_object_spawns": _pending_world_map_baked_object_spawns.size(),
		"world_map_baked_object_spawn_budget_ms": world_map_baked_object_spawn_budget_ms,
		"world_map_baked_object_spawn_max_per_frame": world_map_baked_object_spawn_max_per_frame,
		"world_map_baked_object_spawn_headroom_budget_ms": world_map_baked_object_spawn_headroom_budget_ms,
		"world_map_baked_object_spawn_headroom_max_per_frame": world_map_baked_object_spawn_headroom_max_per_frame,
		"world_map_baked_object_spawn_hot_budget_ms": world_map_baked_object_spawn_hot_budget_ms,
		"last_world_map_baked_object_spawn_queue_ms": _last_world_map_baked_object_spawn_queue_ms,
		"last_world_map_baked_object_spawn_queue_count": _last_world_map_baked_object_spawn_queue_count,
		"last_world_map_baked_object_spawn_queue_budget_ms": _last_world_map_baked_object_spawn_queue_budget_ms,
		"last_world_map_baked_object_spawn_queue_max_per_frame": _last_world_map_baked_object_spawn_queue_max_per_frame,
		"last_world_map_baked_object_spawn_queue_hot_frame": _last_world_map_baked_object_spawn_queue_hot_frame,
		"object_spawn_profile_cache_count": _object_spawn_profile_cache.size(),
		"object_render_prewarm_frames": object_render_prewarm_frames,
		"object_render_prewarm_mesh_count": _object_render_resource_prewarm_mesh_count,
		"object_render_prewarm_active": _is_object_render_resource_prewarm_active(),
		"object_render_prewarm_frames_remaining": _get_object_render_resource_prewarm_frames_remaining(),
		"last_world_map_baked_visibility_update_ms": _last_world_map_baked_visibility_update_ms,
		"last_world_map_baked_visibility_added": _last_world_map_baked_visibility_added,
		"last_world_map_baked_visibility_removed": _last_world_map_baked_visibility_removed,
		"last_world_map_baked_visibility_kept_visible": _last_world_map_baked_visibility_kept_visible,
		"last_world_map_baked_visibility_target_visible": _last_world_map_baked_visibility_target_visible,
		"last_world_map_baked_visibility_total_roots": _last_world_map_baked_visibility_total_roots,
		"last_world_map_baked_visibility_stale_roots": _last_world_map_baked_visibility_stale_roots,
		"world_map_baked_building_visual_batching_enabled": world_map_baked_building_visual_batching_enabled,
		"world_map_baked_building_visual_batch_size": world_map_baked_building_visual_batch_size,
		"world_map_baked_building_visual_batch_rebuilds_per_frame": world_map_baked_building_visual_batch_rebuilds_per_frame,
		"world_map_baked_building_visual_batch_node_count": _world_map_baked_building_visual_batches.size(),
		"world_map_baked_building_visual_batch_dirty_count": _world_map_baked_building_visual_batch_dirty.size(),
		"visible_world_map_baked_building_visual_batch_surfaces": _count_visible_world_map_baked_building_visual_batch_surfaces(),
		"hidden_world_map_baked_building_visual_nodes": _count_hidden_world_map_baked_building_visual_nodes(),
		"last_world_map_baked_building_visual_batch_rebuild_ms": _last_world_map_baked_building_visual_batch_rebuild_ms,
		"last_world_map_baked_building_visual_batch_rebuild_count": _last_world_map_baked_building_visual_batch_rebuild_count,
		"last_world_map_baked_building_visual_batch_source_nodes": _last_world_map_baked_building_visual_batch_source_nodes,
		"last_world_map_baked_building_visual_batch_source_surfaces": _last_world_map_baked_building_visual_batch_source_surfaces,
		"last_world_map_baked_building_visual_batch_output_surfaces": _last_world_map_baked_building_visual_batch_output_surfaces,
		"last_world_map_baked_building_visual_batch_hidden_nodes": _last_world_map_baked_building_visual_batch_hidden_nodes,
		"chunk_pool_size": chunk_pool.size(),
		"total_objects": total_objects,
		"total_object_nodes": total_object_nodes,
		"total_object_collision_nodes": total_object_collision_nodes,
		"total_collision_box_nodes": total_collision_box_shapes,
		"total_simple_visual_instances": total_simple_visual_instances,
		"total_chunk_static_proxy_instances": total_chunk_static_proxy_instances,
		"total_chunk_static_proxy_shapes": total_chunk_static_proxy_shapes,
		"total_virtual_container_nodes": total_virtual_container_nodes,
		"total_visual_batches": total_visual_batches,
		"total_global_visual_batches": _global_visual_batch_nodes.size(),
		"total_global_visual_instances": _global_visual_batch_instances.size(),
		"visible_global_visual_instances": _count_visible_global_visual_batch_instances(),
		"visible_global_visual_batch_surfaces": _count_visible_global_visual_batch_surfaces(),
		"pending_visual_batch_rebuilds": _dirty_global_visual_batch_object_ids.size(),
		"total_occupied_cells": total_occupied_cells,
		"mesh_dirty_chunks": total_mesh_dirty_chunks,
		"dirty_visible_chunk_count": total_dirty_visible_chunks,
		"dirty_hidden_chunk_count": total_dirty_hidden_chunks,
		"last_flush_dirty_chunks_ms": _last_flush_dirty_chunks_ms,
		"last_flush_dirty_chunks_count": _last_flush_dirty_chunks_count,
		"last_flush_global_visual_batches_ms": _last_flush_global_visual_batches_ms,
		"last_flush_global_visual_batches_count": _last_flush_global_visual_batches_count,
		"last_apply_world_map_baked_building_payload_ms": _last_apply_world_map_baked_building_payload_ms,
		"last_apply_world_map_baked_building_payload_chunk_ms": _last_apply_world_map_baked_building_payload_chunk_ms,
		"last_apply_world_map_baked_building_payload_object_ms": _last_apply_world_map_baked_building_payload_object_ms,
		"last_apply_world_map_baked_building_payload_flush_ms": _last_apply_world_map_baked_building_payload_flush_ms,
		"last_apply_world_map_baked_building_payload_slowest_object_ms": _last_apply_world_map_baked_building_payload_slowest_object_ms,
		"last_apply_world_map_baked_building_payload_slowest_object_id": _last_apply_world_map_baked_building_payload_slowest_object_id,
		"last_apply_world_map_baked_building_payload_slowest_object_scene_path": _last_apply_world_map_baked_building_payload_slowest_object_scene_path,
		"last_apply_world_map_baked_building_payload_slowest_object_world_pos": _last_apply_world_map_baked_building_payload_slowest_object_world_pos,
		"last_apply_world_map_baked_building_payload_slow_object_spawns": _last_apply_world_map_baked_building_payload_slow_object_spawns,
		"last_apply_world_map_baked_building_visual_ms": _last_apply_world_map_baked_building_visual_ms,
		"last_apply_world_map_baked_building_visual_root_ms": _last_apply_world_map_baked_building_visual_root_ms,
		"last_apply_world_map_baked_building_visual_mesh_attach_ms": _last_apply_world_map_baked_building_visual_mesh_attach_ms,
		"last_apply_world_map_baked_building_visual_body_attach_ms": _last_apply_world_map_baked_building_visual_body_attach_ms,
		"last_apply_world_map_baked_building_visual_mesh_ms": _last_apply_world_map_baked_building_visual_mesh_ms,
		"last_apply_world_map_baked_building_visual_collision_ms": _last_apply_world_map_baked_building_visual_collision_ms,
		"last_apply_world_map_baked_building_visual_sync_ms": _last_apply_world_map_baked_building_visual_sync_ms,
		"last_apply_world_map_baked_building_visual_count": _last_apply_world_map_baked_building_visual_count,
		"last_apply_world_map_baked_building_chunk_count": _last_apply_world_map_baked_building_chunk_count,
		"last_apply_world_map_baked_building_object_count": _last_apply_world_map_baked_building_object_count,
		"last_apply_world_map_baked_building_prebuilt_chunk_count": _last_apply_world_map_baked_building_prebuilt_chunk_count,
		"world_map_baked_building_edit_keys": _world_map_baked_building_edits_by_key.size(),
		"world_map_baked_building_edit_count": _get_world_map_baked_building_edit_count(),
		"world_map_visibility_distance_chunks": _get_world_map_visibility_distance(WORLD_MAP_VISIBILITY_EXTRA_DISTANCE),
		"total_world_map_baked_building_visual_nodes": _world_map_baked_building_visual_nodes.size(),
		"visible_world_map_baked_building_visual_nodes": _count_visible_world_map_baked_building_visual_nodes(),
		"visible_world_map_baked_building_visual_surfaces": _count_visible_world_map_baked_building_visual_surfaces()
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

func set_voxel(global_pos: Vector3, value: int, meta: int = 0, baked_building_key: String = ""):
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

	var handled_world_map_baked_building := false
	if world_map_mode:
		var baked_building_keys := _get_world_map_baked_building_keys_for_chunk(chunk_coord, baked_building_key)
		for building_key_variant in baked_building_keys:
			var building_key := str(building_key_variant)
			if building_key.is_empty():
				continue
			var updated_world_map_baked_building := _update_world_map_baked_building_visual_for_voxel(building_key, global_pos, value, meta)
			_record_world_map_baked_building_edit(building_key, global_pos, value, meta)
			if updated_world_map_baked_building:
				handled_world_map_baked_building = true

	# Trigger rebuild for this chunk if it's visible and we did not update a baked whole-building visual instead.
	if visible_chunks.has(chunk_coord) and not handled_world_map_baked_building:
		chunk.rebuild_mesh()

## Set voxel WITHOUT triggering immediate mesh rebuild (for batch operations)
## Call flush_dirty_chunks() after all batch operations are complete
func set_voxel_batched(global_pos: Vector3, value: int, meta: int = 0, baked_building_key: String = ""):
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

	var handled_world_map_baked_building := false
	if world_map_mode:
		var baked_building_keys := _get_world_map_baked_building_keys_for_chunk(chunk_coord, baked_building_key)
		for building_key_variant in baked_building_keys:
			var building_key := str(building_key_variant)
			if building_key.is_empty():
				continue
			var updated_world_map_baked_building := _update_world_map_baked_building_visual_for_voxel(building_key, global_pos, value, meta)
			_record_world_map_baked_building_edit(building_key, global_pos, value, meta)
			if updated_world_map_baked_building:
				handled_world_map_baked_building = true

	# Always mark chunk as dirty unless the baked whole-building visual was updated in place.
	if not handled_world_map_baked_building:
		mark_chunk_dirty(chunk_coord, chunk)

## Rebuild all chunks that were modified by batched operations.
## Call this once after completing a batch of set_voxel_batched calls.
## Set force_all=true when a burst must fully settle visible chunks right away.
func flush_dirty_chunks(force_all: bool = false):
	if _dirty_chunks.is_empty():
		return

	var start_time := Time.get_ticks_usec()
	# Only rebuild a limited number of visible chunks per flush so we do not
	# turn one town burst into a single giant rebuild spike.
	var effective_budget := dirty_chunk_flush_budget
	if force_all:
		effective_budget = maxi(_dirty_chunks.size(), 1)
	elif world_map_mode:
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
	if force_all or not world_map_mode:
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
	# Only visible building mesh work should block terrain finalization.
	# Collision cooking can continue in the background without stalling terrain loads.
	return _dirty_visible_chunk_count > 0

func has_pending_visual_batch_work() -> bool:
	return not _dirty_global_visual_batch_object_ids.is_empty()

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
func place_object(global_pos: Vector3, object_id: int, rotation: int, ignore_collision: bool = false, is_procedural: bool = false, defer_global_visual_batch_rebuild: bool = false, precomputed_cells: Array = [], object_size: Vector3i = Vector3i.ZERO, object_scene_path: String = "", has_authored_collision: bool = false, has_authored_collision_valid: bool = false, force_immediate_collision: bool = false) -> bool:
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
	var cells: Array[Vector3i] = []
	var local_cells: Array[Vector3i] = []
	if precomputed_cells.is_empty():
		cells = _build_object_cells(anchor, object_id, rotation, precomputed_cells)
		local_cells.resize(cells.size())
		for i in range(cells.size()):
			var cell: Vector3i = cells[i]
			var local_cell = Vector3i(cell.x % CHUNK_SIZE, cell.y % CHUNK_SIZE, cell.z % CHUNK_SIZE)
			if local_cell.x < 0: local_cell.x += CHUNK_SIZE
			if local_cell.y < 0: local_cell.y += CHUNK_SIZE
			if local_cell.z < 0: local_cell.z += CHUNK_SIZE
			local_cells[i] = local_cell
	else:
		cells.resize(precomputed_cells.size())
		local_cells.resize(precomputed_cells.size())
		for i in range(precomputed_cells.size()):
			var precomputed_cell: Vector3i = precomputed_cells[i]
			var cell: Vector3i = precomputed_cell + anchor
			cells[i] = cell
			var local_cell = Vector3i(cell.x % CHUNK_SIZE, cell.y % CHUNK_SIZE, cell.z % CHUNK_SIZE)
			if local_cell.x < 0: local_cell.x += CHUNK_SIZE
			if local_cell.y < 0: local_cell.y += CHUNK_SIZE
			if local_cell.z < 0: local_cell.z += CHUNK_SIZE
			local_cells[i] = local_cell
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
	
	var chunk = get_chunk(chunk_coord)

	if world_map_mode and ObjectRegistry.is_simple_visual_batch_object(object_id):
		var visual_data = ObjectRegistry.get_object_visual_data(object_id)
		if not visual_data.is_empty():
			var simple_success = chunk.place_simple_visual_object(local_anchor, object_id, rotation, local_cells, fractional_pos, visual_data, defer_global_visual_batch_rebuild)
			if simple_success:
				return true

	if world_map_mode and ObjectRegistry.is_chunk_static_proxy_object(object_id):
		var static_proxy_visual_data = ObjectRegistry.get_object_visual_data(object_id)
		if not static_proxy_visual_data.is_empty():
			var static_proxy_success = chunk.place_chunk_static_proxy_object(local_anchor, object_id, rotation, local_cells, fractional_pos, static_proxy_visual_data, defer_global_visual_batch_rebuild, is_procedural)
			if static_proxy_success:
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
	
	var defer_collision := is_procedural and not force_immediate_collision
	if force_immediate_collision and (not chunk.is_inside_tree() or not chunk.static_body):
		defer_collision = true
	var success = chunk.place_object(local_anchor, object_id, rotation, local_cells, scene_instance, fractional_pos, defer_collision, defer_global_visual_batch_rebuild, object_size, has_authored_collision, has_authored_collision_valid)
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

func _build_top_world_map_baked_building_slow_object_spawns(entries: Array, limit: int = 5) -> Array:
	if entries.is_empty():
		return []
	entries.sort_custom(Callable(self, "_sort_world_map_baked_building_slow_object_spawn_desc"))
	if entries.size() > limit:
		entries.resize(limit)
	return entries

func _sort_world_map_baked_building_slow_object_spawn_desc(a: Dictionary, b: Dictionary) -> bool:
	var a_ms := float(a.get("elapsed_ms", 0.0))
	var b_ms := float(b.get("elapsed_ms", 0.0))
	if a_ms == b_ms:
		return int(a.get("object_id", -1)) < int(b.get("object_id", -1))
	return a_ms > b_ms
