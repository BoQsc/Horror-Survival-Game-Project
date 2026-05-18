extends Node3D
class_name VegetationManager

const MULTIMESH_FLOATS_PER_INSTANCE_3D := 12
const GLOBAL_VEGETATION_RENDER_AABB := AABB(Vector3(-4096.0, -128.0, -4096.0), Vector3(8192.0, 512.0, 8192.0))
const RenderResourcePrewarm = preload("res://world_render_prewarm/render_resource_prewarm.gd")


signal tree_chopped(world_position: Vector3)
signal grass_harvested(world_position: Vector3)
signal rock_harvested(world_position: Vector3)
signal all_vegetation_ready # Emitted when initial load batch finishes

@export var terrain_manager: Node3D
@export var tree_model_path: String = "res://models/tree/1/pine_tree_-_ps1_low_poly.glb"
@export var tree_scale: float = 1.0
@export var tree_y_offset: float = 0.0 # GLB model has Y=11.76 origin built-in
@export var tree_rotation_fix: Vector3 = Vector3.ZERO
@export var collision_radius: float = 0.5
@export var collision_height: float = 8.0
@export var collider_distance: float = 30.0 # Only trees within this distance get colliders
@export var road_clearance: float = 2.0 # Extra gap beyond road surface before vegetation can spawn
@export var global_render_batches_enabled: bool = true
@export_range(1, 32, 1) var vegetation_render_cluster_size: int = 8
@export_range(1, 32, 1) var vegetation_grass_render_cluster_size: int = 6
@export_range(0, 60, 1) var vegetation_render_prewarm_frames: int = 12
@export_range(0.0, 32.0, 0.1) var vegetation_stream_budget_ms: float = 1.5
@export_range(0.0, 64.0, 0.1) var vegetation_initial_load_budget_ms: float = 3.0
@export_range(0, 8, 1) var vegetation_chunk_start_delay_frames: int = 0
@export_range(1, 128, 1) var vegetation_max_stages_per_frame: int = 8
@export_range(0, 120, 1) var vegetation_global_render_stream_flush_interval_frames: int = 12
@export_range(0.05, 1.0, 0.05) var vegetation_collider_update_interval: float = 0.20
@export var prioritize_nearby_vegetation_chunks: bool = true

# Grass settings
@export var grass_model_path: String = "res://models/grass/2/grass_lowpoly.glb"
@export var grass_scale: float = 0.5
@export var grass_y_offset: float = 0.0
@export var grass_collision_radius: float = 0.3
@export var grass_collision_height: float = 0.5
## Dense grass mode: even distribution everywhere (GPU intensive)
## Default (false): patchy distribution using noise (better performance)
@export var dense_grass_mode: bool = false

# Rock settings
@export var rock_model_path: String = "res://models/small_rock/simple_rock_-_ps1_low_poly.glb"
@export var rock_scale: float = 0.5
@export var rock_y_offset: float = 0.0
@export var rock_collision_radius: float = 0.4
@export var rock_collision_height: float = 0.4

var tree_mesh: Mesh
var tree_base_transform: Transform3D = Transform3D() # Orientation fix from GLB
var grass_mesh: Mesh
var grass_base_transform: Transform3D = Transform3D()
var rock_mesh: Mesh
var rock_base_transform: Transform3D = Transform3D()
static var _loaded_model_cache: Dictionary = {}
var _native_helper: Object = null
var forest_noise: FastNoiseLite
var grass_noise: FastNoiseLite
var rock_noise: FastNoiseLite
var player: Node3D
var _cached_vehicle_manager: Node = null

# Queue for deferred vegetation placement
var pending_chunks: Array[Dictionary] = []

# Tree data per chunk coord -> { multimesh, trees[], collision_container }
var chunk_tree_data: Dictionary = {}

# Pool of active colliders (reusable)
var active_colliders: Dictionary = {} # tree_key -> StaticBody3D
var collider_pool: Array[StaticBody3D] = []
const MAX_ACTIVE_COLLIDERS = 50 # Limit active colliders for performance

# Grass data per chunk coord -> { multimesh, grass_list[] }
var chunk_grass_data: Dictionary = {}
var active_grass_colliders: Dictionary = {} # grass_key -> Area3D
var grass_collider_pool: Array[Area3D] = []
const MAX_ACTIVE_GRASS_COLLIDERS = 30

# Rock data per chunk coord -> { multimesh, rock_list[] }
var chunk_rock_data: Dictionary = {}
var active_rock_colliders: Dictionary = {} # rock_key -> Area3D
var rock_collider_pool: Array[Area3D] = []
const MAX_ACTIVE_ROCK_COLLIDERS = 30

# Persistence - survives chunk unloading
var removed_grass: Dictionary = {} # "x_z" position hash -> true
var removed_rocks: Dictionary = {} # "x_z" position hash -> true
var chopped_trees: Dictionary = {} # "x_z" position hash -> true (for save/load persistence)
var placed_grass: Array = []
var placed_rocks: Array = []

# Pending placements - retry when chunk becomes valid
var pending_rock_placements: Array = []
var pending_grass_placements: Array = []

# Incremental Collider Updates
var pending_collider_adds: Array[Dictionary] = [] # {type, key, item}
var pending_collider_removes: Array[Dictionary] = [] # {type, key}
var keys_pending_add: Dictionary = {} # Duplicate check
var keys_pending_remove: Dictionary = {} # Duplicate check
const MAX_COLLIDER_UPDATES_PER_FRAME = 5
var _collider_refresh_dirty: bool = true
var _last_collider_update_chunk: Vector2i = Vector2i(2147483647, 2147483647)
var _last_collider_update_pos: Vector3 = Vector3(1.0e20, 1.0e20, 1.0e20)
var _last_pending_chunk_process_ms: float = 0.0
var _last_pending_chunk_budget_ms: float = 0.0
var _last_pending_chunk_stages_processed: int = 0
var _last_collider_refresh_ms: float = 0.0
var _last_queued_collider_update_ms: float = 0.0
var _last_pending_placements_ms: float = 0.0
var _terrain_supports_road_query: bool = false
var _collider_update_timer: Timer = null
var _collider_update_deferred_pending: bool = false
var _collider_update_timer_tick_count: int = 0
var _collider_update_deferred_tick_count: int = 0
var _collider_refresh_tick_count: int = 0
var _global_tree_render_mmi: MultiMeshInstance3D = null
var _global_grass_render_mmi: MultiMeshInstance3D = null
var _global_rock_render_mmi: MultiMeshInstance3D = null
var _global_tree_render_clusters: Dictionary = {}
var _global_grass_render_clusters: Dictionary = {}
var _global_rock_render_clusters: Dictionary = {}
var _global_tree_render_chunk_payloads: Dictionary = {}
var _global_grass_render_chunk_payloads: Dictionary = {}
var _global_rock_render_chunk_payloads: Dictionary = {}
var _global_tree_render_cluster_chunks: Dictionary = {}
var _global_grass_render_cluster_chunks: Dictionary = {}
var _global_rock_render_cluster_chunks: Dictionary = {}
var _global_tree_render_chunk_clusters: Dictionary = {}
var _global_grass_render_chunk_clusters: Dictionary = {}
var _global_rock_render_chunk_clusters: Dictionary = {}
var _global_tree_render_cluster_instance_counts: Dictionary = {}
var _global_grass_render_cluster_instance_counts: Dictionary = {}
var _global_rock_render_cluster_instance_counts: Dictionary = {}
var _global_tree_dirty_clusters: Dictionary = {}
var _global_grass_dirty_clusters: Dictionary = {}
var _global_rock_dirty_clusters: Dictionary = {}
var _global_tree_render_dirty: bool = false
var _global_grass_render_dirty: bool = false
var _global_rock_render_dirty: bool = false
var _last_global_render_sync_ms: float = 0.0
var _last_global_render_sync_kind: String = ""
var _last_global_render_sync_cluster: Vector2i = Vector2i.ZERO
var _last_global_render_sync_chunk_count: int = 0
var _global_tree_render_instance_count: int = 0
var _global_grass_render_instance_count: int = 0
var _global_rock_render_instance_count: int = 0
var _global_render_stream_flush_counter: int = 0
var _last_global_render_collect_ms: float = 0.0
var _last_global_render_pack_ms: float = 0.0
var _last_global_render_candidate_chunk_count: int = 0
var _vegetation_render_resource_prewarm_node: Node = null
var _vegetation_render_resource_prewarm_mesh_count: int = 0

# QuickLoad vegetation regeneration - deferred until terrain is ready
var pending_vegetation_regen: bool = false
var is_initial_load_batch: bool = false # Mark as initial load to signal completion
var initial_load_count: int = 0 # Specifically track chunks from the load regeneration

## Returns true when all queued vegetation has been placed (for loading screen)
func is_vegetation_ready() -> bool:
	return pending_chunks.is_empty() and not _has_dirty_global_vegetation_render_batch()

## Get count of pending vegetation chunks (for loading screen progress)
func get_pending_chunks_count() -> int:
	return pending_chunks.size()


func _has_process_work_pending() -> bool:
	return (
		not pending_chunks.is_empty()
		or _has_retryable_pending_placements()
		or _has_dirty_global_vegetation_render_batch()
	)


func _has_retryable_pending_placements() -> bool:
	if not terrain_manager:
		return false

	var chunk_stride = terrain_manager.CHUNK_STRIDE
	for placement in pending_rock_placements:
		var rock_coord = Vector2i(int(floor(placement.world_pos.x / chunk_stride)), int(floor(placement.world_pos.z / chunk_stride)))
		if chunk_rock_data.has(rock_coord):
			return true

	for placement in pending_grass_placements:
		var grass_coord = Vector2i(int(floor(placement.world_pos.x / chunk_stride)), int(floor(placement.world_pos.z / chunk_stride)))
		if chunk_grass_data.has(grass_coord):
			return true

	return false


func _wake_process_loop() -> void:
	if not is_processing():
		set_process(true)


func _sync_process_loop() -> void:
	if _has_process_work_pending():
		_wake_process_loop()
	else:
		set_process(false)


func get_telemetry_snapshot() -> Dictionary:
	return {
		"pending_chunks": pending_chunks.size(),
		"tree_chunk_count": chunk_tree_data.size(),
		"grass_chunk_count": chunk_grass_data.size(),
		"rock_chunk_count": chunk_rock_data.size(),
		"active_tree_colliders": active_colliders.size(),
		"active_grass_colliders": active_grass_colliders.size(),
		"active_rock_colliders": active_rock_colliders.size(),
		"tree_collider_pool_size": collider_pool.size(),
		"grass_collider_pool_size": grass_collider_pool.size(),
		"rock_collider_pool_size": rock_collider_pool.size(),
		"pending_collider_adds": pending_collider_adds.size(),
		"pending_collider_removes": pending_collider_removes.size(),
		"removed_grass_count": removed_grass.size(),
		"removed_rocks_count": removed_rocks.size(),
		"chopped_trees_count": chopped_trees.size(),
		"placed_grass_count": placed_grass.size(),
		"placed_rocks_count": placed_rocks.size(),
		"collider_refresh_dirty": _collider_refresh_dirty,
		"dense_grass_mode": dense_grass_mode,
		"initial_load_count": initial_load_count,
		"is_initial_load_batch": is_initial_load_batch,
		"process_loop_awake": is_processing(),
		"last_pending_chunk_process_ms": _last_pending_chunk_process_ms,
		"last_pending_chunk_budget_ms": _last_pending_chunk_budget_ms,
		"last_pending_chunk_stages_processed": _last_pending_chunk_stages_processed,
		"vegetation_stream_budget_ms": vegetation_stream_budget_ms,
		"vegetation_initial_load_budget_ms": vegetation_initial_load_budget_ms,
		"vegetation_chunk_start_delay_frames": vegetation_chunk_start_delay_frames,
		"vegetation_max_stages_per_frame": vegetation_max_stages_per_frame,
		"vegetation_global_render_stream_flush_interval_frames": vegetation_global_render_stream_flush_interval_frames,
		"prioritize_nearby_vegetation_chunks": prioritize_nearby_vegetation_chunks,
		"last_collider_refresh_ms": _last_collider_refresh_ms,
		"last_queued_collider_update_ms": _last_queued_collider_update_ms,
		"last_pending_placements_ms": _last_pending_placements_ms,
		"vegetation_collider_update_interval": vegetation_collider_update_interval,
		"collider_update_timer_active": _collider_update_timer != null and is_instance_valid(_collider_update_timer) and not _collider_update_timer.is_stopped(),
		"collider_update_timer_tick_count": _collider_update_timer_tick_count,
		"collider_update_deferred_tick_count": _collider_update_deferred_tick_count,
		"collider_refresh_tick_count": _collider_refresh_tick_count,
		"collider_update_deferred_pending": _collider_update_deferred_pending,
		"physics_process_enabled": is_physics_processing(),
		"terrain_supports_road_query": _terrain_supports_road_query,
		"global_render_batches_enabled": global_render_batches_enabled,
		"vegetation_render_cluster_size": vegetation_render_cluster_size,
		"vegetation_grass_render_cluster_size": vegetation_grass_render_cluster_size,
		"global_render_batch_count": _get_global_render_batch_count(),
		"global_tree_render_chunk_payloads": _global_tree_render_chunk_payloads.size(),
		"global_grass_render_chunk_payloads": _global_grass_render_chunk_payloads.size(),
		"global_rock_render_chunk_payloads": _global_rock_render_chunk_payloads.size(),
		"global_tree_render_instances": _global_tree_render_instance_count,
		"global_grass_render_instances": _global_grass_render_instance_count,
		"global_rock_render_instances": _global_rock_render_instance_count,
		"global_render_dirty_kinds": _get_global_render_dirty_kinds(),
		"last_global_render_sync_ms": _last_global_render_sync_ms,
		"last_global_render_collect_ms": _last_global_render_collect_ms,
		"last_global_render_pack_ms": _last_global_render_pack_ms,
		"last_global_render_sync_kind": _last_global_render_sync_kind,
		"last_global_render_sync_cluster": str(_last_global_render_sync_cluster),
		"last_global_render_sync_chunk_count": _last_global_render_sync_chunk_count,
		"last_global_render_candidate_chunk_count": _last_global_render_candidate_chunk_count,
		"vegetation_render_prewarm_frames": vegetation_render_prewarm_frames,
		"vegetation_render_prewarm_mesh_count": _vegetation_render_resource_prewarm_mesh_count,
		"vegetation_render_prewarm_active": _is_vegetation_render_resource_prewarm_active(),
		"vegetation_render_prewarm_frames_remaining": _get_vegetation_render_resource_prewarm_frames_remaining()
	}


func _get_native_helper() -> Object:
	if _native_helper and is_instance_valid(_native_helper):
		return _native_helper
	if not ClassDB.class_exists("PrefabGeometryNative"):
		return null
	_native_helper = ClassDB.instantiate("PrefabGeometryNative")
	return _native_helper

func _start_vegetation_render_resource_prewarm() -> void:
	if vegetation_render_prewarm_frames <= 0 or _is_vegetation_render_resource_prewarm_active():
		return

	var mesh_entries := _collect_vegetation_render_resource_prewarm_entries()
	_vegetation_render_resource_prewarm_mesh_count = mesh_entries.size()
	if mesh_entries.is_empty():
		return

	var prewarmer: Node = RenderResourcePrewarm.new()
	prewarmer.name = "VegetationRenderResourcePrewarm"
	add_child(prewarmer)
	_vegetation_render_resource_prewarm_node = prewarmer
	prewarmer.configure([], vegetation_render_prewarm_frames, mesh_entries)

func _collect_vegetation_render_resource_prewarm_entries() -> Array:
	var entries: Array = []
	var unique_meshes: Array = []
	_append_vegetation_render_resource_prewarm_entry(entries, unique_meshes, tree_mesh, tree_base_transform)
	_append_vegetation_render_resource_prewarm_entry(entries, unique_meshes, grass_mesh, grass_base_transform)
	_append_vegetation_render_resource_prewarm_entry(entries, unique_meshes, rock_mesh, rock_base_transform)
	return entries

func _append_vegetation_render_resource_prewarm_entry(entries: Array, unique_meshes: Array, mesh: Mesh, transform: Transform3D) -> void:
	if not mesh or unique_meshes.has(mesh):
		return
	unique_meshes.append(mesh)
	entries.append({
		"mesh": mesh,
		"transform": transform
	})

func _is_vegetation_render_resource_prewarm_active() -> bool:
	return _vegetation_render_resource_prewarm_node != null and is_instance_valid(_vegetation_render_resource_prewarm_node)

func _get_vegetation_render_resource_prewarm_frames_remaining() -> int:
	if not _is_vegetation_render_resource_prewarm_active():
		return 0
	if not _vegetation_render_resource_prewarm_node.has_method("get_frames_remaining"):
		return 0
	return int(_vegetation_render_resource_prewarm_node.get_frames_remaining())

func _start_collider_update_timer() -> void:
	if _collider_update_timer and is_instance_valid(_collider_update_timer):
		_collider_update_timer.wait_time = maxf(vegetation_collider_update_interval, 0.05)
		if _collider_update_timer.is_stopped():
			_collider_update_timer.start()
		return
	var timer := Timer.new()
	timer.name = "VegetationColliderUpdateTimer"
	timer.wait_time = maxf(vegetation_collider_update_interval, 0.05)
	timer.one_shot = false
	timer.autostart = false
	timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
	add_child(timer)
	_collider_update_timer = timer
	timer.timeout.connect(_on_collider_update_timer_timeout)
	timer.start()

func _on_collider_update_timer_timeout() -> void:
	_collider_update_timer_tick_count += 1
	_run_collider_refresh_tick()

func _request_collider_update_soon() -> void:
	if _collider_update_deferred_pending or not is_inside_tree():
		return
	_collider_update_deferred_pending = true
	call_deferred("_run_deferred_collider_refresh_tick")

func _run_deferred_collider_refresh_tick() -> void:
	_collider_update_deferred_pending = false
	if not is_inside_tree():
		return
	_collider_update_deferred_tick_count += 1
	_run_collider_refresh_tick()


func _exit_tree() -> void:
	clear_all_data(true)
	_vegetation_render_resource_prewarm_node = null
	if _collider_update_timer and is_instance_valid(_collider_update_timer):
		_collider_update_timer.stop()
	_native_helper = null


func _make_hidden_transform(local_pos: Vector3) -> Transform3D:
	var t := Transform3D.IDENTITY
	t = t.scaled(Vector3.ZERO)
	t.origin = local_pos
	return t


func _build_vegetation_transform(
		base_transform: Transform3D,
		rotation_fix: Vector3,
		rotation_angle: float,
		scale: float,
		local_pos: Vector3
) -> Transform3D:
	var t := base_transform
	t.basis = t.basis * Basis.from_euler(rotation_fix)
	t = t.rotated(Vector3.UP, rotation_angle)
	t = t.scaled(Vector3(scale, scale, scale))
	t.origin = local_pos
	return t


func _vegetation_custom_aabb(chunk_stride: int) -> AABB:
	return AABB(
		Vector3(-16.0, -32.0, -16.0),
		Vector3(chunk_stride + 32.0, 128.0, chunk_stride + 32.0)
	)

func _global_vegetation_custom_aabb(transforms: Array) -> AABB:
	if transforms.is_empty():
		return GLOBAL_VEGETATION_RENDER_AABB

	var first_transform := _get_vegetation_instance_transform(transforms[0])
	var bounds := AABB(first_transform.origin, Vector3.ZERO)
	for transform_variant in transforms:
		var transform := _get_vegetation_instance_transform(transform_variant)
		bounds = bounds.expand(transform.origin)
	return bounds.grow(96.0)

func _get_global_render_batch_count() -> int:
	var count := 0
	for batch in _global_tree_render_clusters.values():
		if batch and is_instance_valid(batch):
			count += 1
	for batch in _global_grass_render_clusters.values():
		if batch and is_instance_valid(batch):
			count += 1
	for batch in _global_rock_render_clusters.values():
		if batch and is_instance_valid(batch):
			count += 1
	return count

func _get_global_render_dirty_kinds() -> Array[String]:
	var kinds: Array[String] = []
	if _global_tree_render_dirty:
		kinds.append("tree")
	if _global_grass_render_dirty:
		kinds.append("grass")
	if _global_rock_render_dirty:
		kinds.append("rock")
	return kinds

func _create_chunk_multimesh_handle(kind: String, coord: Vector2i, mesh: Mesh):
	if global_render_batches_enabled:
		return {
			"vegetation_kind": kind,
			"vegetation_coord": coord
		}

	if not mesh:
		return null

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.mesh = mesh
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh.use_colors = false
	mmi.multimesh.use_custom_data = false
	_prepare_chunk_multimesh(mmi, kind, coord)
	return mmi

func _prepare_chunk_multimesh(mmi: MultiMeshInstance3D, kind: String, coord: Vector2i) -> void:
	if not mmi:
		return
	mmi.set_meta("vegetation_kind", kind)
	mmi.set_meta("vegetation_coord", coord)
	if global_render_batches_enabled:
		# Data remains per chunk for gameplay/colliders; rendering is handled by
		# clustered render batches for this vegetation type.
		mmi.visible = false

func _chunk_multimesh_handle_kind(handle) -> String:
	if typeof(handle) == TYPE_DICTIONARY:
		return str(handle.get("vegetation_kind", ""))
	if handle is Object and is_instance_valid(handle) and handle.has_meta("vegetation_kind"):
		return str(handle.get_meta("vegetation_kind"))
	return ""

func _chunk_multimesh_handle_coord(handle):
	if typeof(handle) == TYPE_DICTIONARY:
		return handle.get("vegetation_coord", null)
	if handle is Object and is_instance_valid(handle) and handle.has_meta("vegetation_coord"):
		return handle.get_meta("vegetation_coord")
	return null

func _is_chunk_multimesh_handle_valid(handle) -> bool:
	if typeof(handle) == TYPE_DICTIONARY:
		return not _chunk_multimesh_handle_kind(handle).is_empty()
	if not (handle is Object) or not is_instance_valid(handle):
		return false
	var mmi := handle as MultiMeshInstance3D
	if global_render_batches_enabled and handle.has_meta("vegetation_kind"):
		return true
	return mmi != null and mmi.multimesh != null

func _free_chunk_multimesh_handle(handle, immediate_free: bool = false) -> void:
	if not (handle is Object) or not is_instance_valid(handle):
		return
	if handle is Node:
		if immediate_free:
			handle.free()
		else:
			handle.queue_free()

func _attach_chunk_multimesh(mmi, chunk_node: Node3D) -> void:
	if not mmi:
		return
	if global_render_batches_enabled:
		if mmi is Node:
			var global_parent: Node = mmi.get_parent()
			if global_parent:
				global_parent.remove_child(mmi)
		return
	if not is_instance_valid(chunk_node):
		return
	var mmi_node := mmi as MultiMeshInstance3D
	if not mmi_node:
		return
	var current_parent := mmi_node.get_parent()
	if current_parent == chunk_node:
		return
	if current_parent:
		current_parent.remove_child(mmi_node)
	chunk_node.add_child(mmi_node)

func _get_global_render_cluster_dictionary(kind: String) -> Dictionary:
	match kind:
		"tree":
			return _global_tree_render_clusters
		"grass":
			return _global_grass_render_clusters
		"rock":
			return _global_rock_render_clusters
	return {}

func _get_global_render_dirty_cluster_dictionary(kind: String) -> Dictionary:
	match kind:
		"tree":
			return _global_tree_dirty_clusters
		"grass":
			return _global_grass_dirty_clusters
		"rock":
			return _global_rock_dirty_clusters
	return {}

func _get_global_render_chunk_payload_dictionary(kind: String) -> Dictionary:
	match kind:
		"tree":
			return _global_tree_render_chunk_payloads
		"grass":
			return _global_grass_render_chunk_payloads
		"rock":
			return _global_rock_render_chunk_payloads
	return {}

func _get_global_render_cluster_chunk_dictionary(kind: String) -> Dictionary:
	match kind:
		"tree":
			return _global_tree_render_cluster_chunks
		"grass":
			return _global_grass_render_cluster_chunks
		"rock":
			return _global_rock_render_cluster_chunks
	return {}

func _get_global_render_chunk_cluster_dictionary(kind: String) -> Dictionary:
	match kind:
		"tree":
			return _global_tree_render_chunk_clusters
		"grass":
			return _global_grass_render_chunk_clusters
		"rock":
			return _global_rock_render_chunk_clusters
	return {}

func _get_global_render_cluster_instance_count_dictionary(kind: String) -> Dictionary:
	match kind:
		"tree":
			return _global_tree_render_cluster_instance_counts
		"grass":
			return _global_grass_render_cluster_instance_counts
		"rock":
			return _global_rock_render_cluster_instance_counts
	return {}

func _set_global_render_dirty_flag(kind: String, dirty: bool) -> void:
	match kind:
		"tree":
			_global_tree_render_dirty = dirty
		"grass":
			_global_grass_render_dirty = dirty
		"rock":
			_global_rock_render_dirty = dirty
	if dirty:
		_wake_process_loop()

func _vegetation_cluster_key(kind: String, coord: Vector2i) -> Vector2i:
	var cluster_size := vegetation_grass_render_cluster_size if kind == "grass" else vegetation_render_cluster_size
	cluster_size = maxi(cluster_size, 1)
	return Vector2i(
		int(floor(float(coord.x) / float(cluster_size))),
		int(floor(float(coord.y) / float(cluster_size)))
	)

func _mark_all_global_vegetation_clusters_dirty(kind: String) -> void:
	var dirty_clusters := _get_global_render_dirty_cluster_dictionary(kind)
	match kind:
		"tree":
			for coord in chunk_tree_data.keys():
				dirty_clusters[_vegetation_cluster_key(kind, coord)] = true
		"grass":
			for coord in chunk_grass_data.keys():
				dirty_clusters[_vegetation_cluster_key(kind, coord)] = true
		"rock":
			for coord in chunk_rock_data.keys():
				dirty_clusters[_vegetation_cluster_key(kind, coord)] = true
	_set_global_render_dirty_flag(kind, not dirty_clusters.is_empty())

func _mark_global_vegetation_render_dirty(kind: String, coord = null) -> void:
	if not global_render_batches_enabled:
		return
	if typeof(coord) == TYPE_VECTOR2I:
		var dirty_clusters := _get_global_render_dirty_cluster_dictionary(kind)
		dirty_clusters[_vegetation_cluster_key(kind, coord)] = true
		_set_global_render_dirty_flag(kind, true)
	else:
		_mark_all_global_vegetation_clusters_dirty(kind)
	_sync_process_loop()

func _remove_global_render_chunk_membership(kind: String, coord: Vector2i) -> void:
	var chunk_clusters := _get_global_render_chunk_cluster_dictionary(kind)
	var old_cluster_variant: Variant = chunk_clusters.get(coord, null)
	if typeof(old_cluster_variant) != TYPE_VECTOR2I:
		return

	var old_cluster: Vector2i = old_cluster_variant
	var cluster_chunks := _get_global_render_cluster_chunk_dictionary(kind)
	var chunk_set: Dictionary = cluster_chunks.get(old_cluster, {})
	if not chunk_set.is_empty():
		chunk_set.erase(coord)
		if chunk_set.is_empty():
			cluster_chunks.erase(old_cluster)
		else:
			cluster_chunks[old_cluster] = chunk_set
	chunk_clusters.erase(coord)

func _set_global_render_chunk_membership(kind: String, coord: Vector2i) -> Vector2i:
	var cluster_key := _vegetation_cluster_key(kind, coord)
	var chunk_clusters := _get_global_render_chunk_cluster_dictionary(kind)
	var old_cluster_variant: Variant = chunk_clusters.get(coord, null)
	if typeof(old_cluster_variant) == TYPE_VECTOR2I and old_cluster_variant != cluster_key:
		_remove_global_render_chunk_membership(kind, coord)

	chunk_clusters[coord] = cluster_key
	var cluster_chunks := _get_global_render_cluster_chunk_dictionary(kind)
	var chunk_set: Dictionary = cluster_chunks.get(cluster_key, {})
	chunk_set[coord] = true
	cluster_chunks[cluster_key] = chunk_set
	return cluster_key

func _set_global_render_cluster_instance_count(kind: String, cluster_key: Vector2i, instance_count: int) -> void:
	var counts := _get_global_render_cluster_instance_count_dictionary(kind)
	var previous_count := int(counts.get(cluster_key, 0))
	if instance_count > 0:
		counts[cluster_key] = instance_count
	else:
		counts.erase(cluster_key)

	var delta := instance_count - previous_count
	if delta == 0:
		return

	match kind:
		"tree":
			_global_tree_render_instance_count += delta
		"grass":
			_global_grass_render_instance_count += delta
		"rock":
			_global_rock_render_instance_count += delta

func _clear_global_vegetation_render_batches(immediate_free: bool = false) -> void:
	var nodes := [_global_tree_render_mmi, _global_grass_render_mmi, _global_rock_render_mmi]
	nodes.append_array(_global_tree_render_clusters.values())
	nodes.append_array(_global_grass_render_clusters.values())
	nodes.append_array(_global_rock_render_clusters.values())
	for node in nodes:
		if node and is_instance_valid(node):
			if immediate_free:
				node.free()
			else:
				node.queue_free()
	_global_tree_render_mmi = null
	_global_grass_render_mmi = null
	_global_rock_render_mmi = null
	_global_tree_render_clusters.clear()
	_global_grass_render_clusters.clear()
	_global_rock_render_clusters.clear()
	_global_tree_render_chunk_payloads.clear()
	_global_grass_render_chunk_payloads.clear()
	_global_rock_render_chunk_payloads.clear()
	_global_tree_render_cluster_chunks.clear()
	_global_grass_render_cluster_chunks.clear()
	_global_rock_render_cluster_chunks.clear()
	_global_tree_render_chunk_clusters.clear()
	_global_grass_render_chunk_clusters.clear()
	_global_rock_render_chunk_clusters.clear()
	_global_tree_render_cluster_instance_counts.clear()
	_global_grass_render_cluster_instance_counts.clear()
	_global_rock_render_cluster_instance_counts.clear()
	_global_tree_dirty_clusters.clear()
	_global_grass_dirty_clusters.clear()
	_global_rock_dirty_clusters.clear()
	_global_tree_render_dirty = false
	_global_grass_render_dirty = false
	_global_rock_render_dirty = false
	_global_tree_render_instance_count = 0
	_global_grass_render_instance_count = 0
	_global_rock_render_instance_count = 0

func _get_global_render_multimesh(kind: String, cluster_key: Vector2i) -> MultiMeshInstance3D:
	var clusters := _get_global_render_cluster_dictionary(kind)
	var existing: MultiMeshInstance3D = clusters.get(cluster_key, null)
	var mesh: Mesh = null
	match kind:
		"tree":
			mesh = tree_mesh
		"grass":
			mesh = grass_mesh
		"rock":
			mesh = rock_mesh
		_:
			return null
	if not mesh:
		return null
	if existing and is_instance_valid(existing):
		return existing

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Global%sRenderBatch_%d_%d" % [kind.capitalize(), cluster_key.x, cluster_key.y]
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.mesh = mesh
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh.use_colors = false
	mmi.multimesh.use_custom_data = false
	mmi.multimesh.custom_aabb = GLOBAL_VEGETATION_RENDER_AABB
	mmi.extra_cull_margin = 1000.0
	mmi.ignore_occlusion_culling = true
	mmi.lod_bias = 100.0
	mmi.visibility_range_end = 0.0
	add_child(mmi)
	clusters[cluster_key] = mmi
	return mmi

func _get_global_vegetation_instance_transform(item) -> Transform3D:
	var transform := _get_vegetation_instance_transform(item)
	if item is Dictionary:
		var world_pos: Vector3 = item.get("world_pos", transform.origin)
		transform.origin = to_local(world_pos) if is_inside_tree() else world_pos
	return transform

func _append_alive_global_vegetation_transforms(target: Array, entries: Array) -> void:
	for item in entries:
		if item is Dictionary and not bool(item.get("alive", true)):
			continue
		target.append(_get_global_vegetation_instance_transform(item))

func _build_global_vegetation_chunk_render_payload(instances: Array) -> Dictionary:
	var transforms: Array = []
	var bounds := GLOBAL_VEGETATION_RENDER_AABB
	var has_bounds := false
	for item in instances:
		if item is Dictionary and not bool(item.get("alive", true)):
			continue
		var transform := _get_global_vegetation_instance_transform(item)
		transforms.append(transform)
		if has_bounds:
			bounds = bounds.expand(transform.origin)
		else:
			bounds = AABB(transform.origin, Vector3.ZERO)
			has_bounds = true

	return {
		"buffer": _pack_multimesh_buffer_from_instances(transforms, true),
		"instance_count": transforms.size(),
		"bounds": bounds,
		"has_bounds": has_bounds
	}

func _update_global_vegetation_chunk_render_payload(kind: String, coord, instances: Array) -> void:
	if not global_render_batches_enabled or typeof(coord) != TYPE_VECTOR2I:
		return
	var payloads := _get_global_render_chunk_payload_dictionary(kind)
	var payload := _build_global_vegetation_chunk_render_payload(instances)
	if int(payload.get("instance_count", 0)) <= 0:
		_clear_global_vegetation_chunk_render_payload(kind, coord)
		return
	payloads[coord] = payload
	_set_global_render_chunk_membership(kind, coord)

func _clear_global_vegetation_chunk_render_payload(kind: String, coord: Vector2i) -> void:
	var payloads := _get_global_render_chunk_payload_dictionary(kind)
	payloads.erase(coord)
	_remove_global_render_chunk_membership(kind, coord)

func _collect_global_vegetation_transforms(kind: String, cluster_key = null) -> Array:
	var transforms: Array = []
	match kind:
		"tree":
			for coord in chunk_tree_data.keys():
				if typeof(cluster_key) == TYPE_VECTOR2I and _vegetation_cluster_key(kind, coord) != cluster_key:
					continue
				var data = chunk_tree_data[coord]
				_append_alive_global_vegetation_transforms(transforms, data.get("trees", []))
		"grass":
			for coord in chunk_grass_data.keys():
				if typeof(cluster_key) == TYPE_VECTOR2I and _vegetation_cluster_key(kind, coord) != cluster_key:
					continue
				var data = chunk_grass_data[coord]
				_append_alive_global_vegetation_transforms(transforms, data.get("grass_list", []))
		"rock":
			for coord in chunk_rock_data.keys():
				if typeof(cluster_key) == TYPE_VECTOR2I and _vegetation_cluster_key(kind, coord) != cluster_key:
					continue
				var data = chunk_rock_data[coord]
				_append_alive_global_vegetation_transforms(transforms, data.get("rock_list", []))
	return transforms

func _collect_global_vegetation_render_payload(kind: String, cluster_key = null) -> Dictionary:
	var payload := {
		"buffer": PackedFloat32Array(),
		"bounds": GLOBAL_VEGETATION_RENDER_AABB,
		"has_bounds": false,
		"chunk_count": 0,
		"instance_count": 0
	}
	var cluster_buffer: PackedFloat32Array = payload.buffer
	var payloads := _get_global_render_chunk_payload_dictionary(kind)
	var coord_keys: Array = []
	if typeof(cluster_key) == TYPE_VECTOR2I:
		var cluster_chunks := _get_global_render_cluster_chunk_dictionary(kind)
		var chunk_set: Dictionary = cluster_chunks.get(cluster_key, {})
		coord_keys = chunk_set.keys()
	else:
		coord_keys = payloads.keys()
	_last_global_render_candidate_chunk_count = coord_keys.size()
	for coord_variant in coord_keys:
		var coord: Vector2i = coord_variant
		var chunk_payload: Dictionary = payloads.get(coord, {})
		var instance_count := int(chunk_payload.get("instance_count", 0))
		if instance_count <= 0:
			continue
		var chunk_buffer: PackedFloat32Array = chunk_payload.get("buffer", PackedFloat32Array())
		if chunk_buffer.is_empty():
			continue
		cluster_buffer.append_array(chunk_buffer)
		payload.chunk_count = int(payload.chunk_count) + 1
		payload.instance_count = int(payload.instance_count) + instance_count
		if bool(chunk_payload.get("has_bounds", false)):
			var chunk_bounds: AABB = chunk_payload.get("bounds", GLOBAL_VEGETATION_RENDER_AABB)
			if bool(payload.has_bounds):
				var merged_bounds: AABB = payload.bounds
				payload.bounds = merged_bounds.merge(chunk_bounds)
			else:
				payload.bounds = chunk_bounds
				payload.has_bounds = true
	payload.buffer = cluster_buffer
	if bool(payload.has_bounds):
		var payload_bounds: AABB = payload.bounds
		payload.bounds = payload_bounds.grow(96.0)
	return payload

func _recount_global_render_instances(kind: String) -> int:
	var total := 0
	var clusters := _get_global_render_cluster_dictionary(kind)
	for batch_variant in clusters.values():
		var batch := batch_variant as MultiMeshInstance3D
		if batch and is_instance_valid(batch) and batch.multimesh:
			total += batch.multimesh.instance_count
	match kind:
		"tree":
			_global_tree_render_instance_count = total
		"grass":
			_global_grass_render_instance_count = total
		"rock":
			_global_rock_render_instance_count = total
	return total

func _sync_global_vegetation_render_batch(kind: String) -> void:
	if not global_render_batches_enabled:
		return
	var dirty_clusters := _get_global_render_dirty_cluster_dictionary(kind)
	if dirty_clusters.is_empty():
		_set_global_render_dirty_flag(kind, false)
		return
	var cluster_key: Vector2i = dirty_clusters.keys()[0]
	var start_us := Time.get_ticks_usec()

	var collect_start_us := Time.get_ticks_usec()
	var payload := _collect_global_vegetation_render_payload(kind, cluster_key)
	var instance_count := int(payload.get("instance_count", 0))
	var buffer: PackedFloat32Array = payload.get("buffer", PackedFloat32Array())
	_last_global_render_collect_ms = float(Time.get_ticks_usec() - collect_start_us) / 1000.0
	var clusters := _get_global_render_cluster_dictionary(kind)
	if instance_count <= 0 or buffer.is_empty():
		var old_batch := clusters.get(cluster_key, null) as Node
		if old_batch and is_instance_valid(old_batch):
			old_batch.queue_free()
		clusters.erase(cluster_key)
		dirty_clusters.erase(cluster_key)
		_set_global_render_dirty_flag(kind, not dirty_clusters.is_empty())
		_set_global_render_cluster_instance_count(kind, cluster_key, 0)
		_last_global_render_pack_ms = 0.0
		_last_global_render_sync_kind = kind
		_last_global_render_sync_cluster = cluster_key
		_last_global_render_sync_chunk_count = int(payload.get("chunk_count", 0))
		_last_global_render_sync_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
		return

	var mmi := _get_global_render_multimesh(kind, cluster_key)
	if not mmi or not mmi.multimesh:
		return
	var pack_start_us := Time.get_ticks_usec()
	mmi.multimesh.instance_count = instance_count
	mmi.multimesh.buffer = buffer
	mmi.multimesh.custom_aabb = payload.get("bounds", GLOBAL_VEGETATION_RENDER_AABB)
	_last_global_render_pack_ms = float(Time.get_ticks_usec() - pack_start_us) / 1000.0
	dirty_clusters.erase(cluster_key)
	_set_global_render_dirty_flag(kind, not dirty_clusters.is_empty())
	_set_global_render_cluster_instance_count(kind, cluster_key, instance_count)
	_last_global_render_sync_kind = kind
	_last_global_render_sync_cluster = cluster_key
	_last_global_render_sync_chunk_count = int(payload.get("chunk_count", 0))
	_last_global_render_sync_ms = float(Time.get_ticks_usec() - start_us) / 1000.0

func _flush_one_global_vegetation_render_batch() -> void:
	if not global_render_batches_enabled:
		return
	if _global_tree_render_dirty:
		_sync_global_vegetation_render_batch("tree")
	elif _global_grass_render_dirty:
		_sync_global_vegetation_render_batch("grass")
	elif _global_rock_render_dirty:
		_sync_global_vegetation_render_batch("rock")


func _has_dirty_global_vegetation_render_batch() -> bool:
	return _global_tree_render_dirty or _global_grass_render_dirty or _global_rock_render_dirty


func _should_flush_global_vegetation_render_batch() -> bool:
	if not global_render_batches_enabled or not _has_dirty_global_vegetation_render_batch():
		_global_render_stream_flush_counter = 0
		return false
	if pending_chunks.is_empty():
		_global_render_stream_flush_counter = 0
		return true
	if vegetation_global_render_stream_flush_interval_frames <= 0:
		return false
	_global_render_stream_flush_counter += 1
	if _global_render_stream_flush_counter >= vegetation_global_render_stream_flush_interval_frames:
		_global_render_stream_flush_counter = 0
		return true
	return false


func _pack_multimesh_buffer_from_instances(instances: Array, instances_are_transforms: bool = false) -> PackedFloat32Array:
	var native := _get_native_helper()
	if native and native.has_method("pack_multimesh_buffer_from_instances"):
		if instances_are_transforms:
			var native_transform_buffer: PackedFloat32Array = native.pack_multimesh_buffer_from_instances(instances)
			return native_transform_buffer

		var transforms: Array = []
		transforms.resize(instances.size())
		var write_index := 0
		for item in instances:
			transforms[write_index] = _get_vegetation_instance_transform(item)
			write_index += 1

		var native_buffer: PackedFloat32Array = native.pack_multimesh_buffer_from_instances(transforms)
		return native_buffer

	var buffer := PackedFloat32Array()
	buffer.resize(instances.size() * MULTIMESH_FLOATS_PER_INSTANCE_3D)
	var write_index := 0
	for item in instances:
		var transform := _get_vegetation_instance_transform(item)

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


func _get_vegetation_instance_transform(item) -> Transform3D:
	if typeof(item) == TYPE_TRANSFORM3D:
		return item
	if item is Dictionary:
		var transform_variant = item.get("transform", Transform3D.IDENTITY)
		if typeof(transform_variant) == TYPE_TRANSFORM3D:
			return transform_variant
	return Transform3D.IDENTITY


func _sync_multimesh_from_instances(mmi, instances: Array, chunk_stride: int) -> void:
	if not _is_chunk_multimesh_handle_valid(mmi):
		return

	var kind := _chunk_multimesh_handle_kind(mmi)
	if global_render_batches_enabled and not kind.is_empty():
		if mmi is MultiMeshInstance3D:
			mmi.visible = false
		var coord = _chunk_multimesh_handle_coord(mmi)
		_update_global_vegetation_chunk_render_payload(kind, coord, instances)
		_mark_global_vegetation_render_dirty(kind, coord)
		return
	elif mmi is MultiMeshInstance3D and mmi.has_meta("vegetation_kind"):
		mmi.visible = true

	var mmi_node := mmi as MultiMeshInstance3D
	if not mmi_node or not mmi_node.multimesh:
		return

	mmi_node.multimesh.instance_count = instances.size()
	mmi_node.multimesh.buffer = _pack_multimesh_buffer_from_instances(instances)
	mmi_node.multimesh.custom_aabb = _vegetation_custom_aabb(chunk_stride)


func _append_native_generated_instances(target: Array, records: Array) -> void:
	for record_variant in records:
		var record: Dictionary = record_variant
		var item = _make_vegetation_generated(
			record.get("world_pos", Vector3.ZERO),
			record.get("local_pos", Vector3.ZERO),
			record.get("hit_pos", Vector3.ZERO),
			float(record.get("rotation_angle", 0.0)),
			float(record.get("random_scale_factor", 1.0)),
			int(record.get("index", target.size())),
			float(record.get("scale", 1.0)),
			bool(record.get("placed_by_player", false)),
			record.get("transform", Transform3D.IDENTITY)
		)
		item.alive = bool(record.get("alive", true))
		target.append(item)


func _build_vegetation_native_config(
		chunk_stride: int,
		step: int,
		chunk_origin_x: int,
		chunk_origin_z: int,
		chunk_world_pos: Vector3,
		base_transform: Transform3D,
		rotation_fix: Vector3,
		road_clearance: float,
		procedural_roads_enabled: bool,
		procedural_road_spacing: float,
		procedural_road_width: float,
		world_map_active: bool,
		water_level: float,
		noise_values: PackedFloat32Array,
		noise_seed: int,
		noise_frequency: float,
		noise_threshold: float,
		scale_min: float,
		scale_max: float,
		scale_multiplier: float,
		y_offset: float,
		use_noise: bool,
		use_water_density: bool,
		record_random_scale_factor: bool
) -> Dictionary:
	return {
		"chunk_stride": chunk_stride,
		"step": step,
		"chunk_origin_x": chunk_origin_x,
		"chunk_origin_z": chunk_origin_z,
		"chunk_world_pos": chunk_world_pos,
		"base_transform": base_transform,
		"rotation_fix": rotation_fix,
		"road_clearance": road_clearance,
		"procedural_roads_enabled": procedural_roads_enabled,
		"procedural_road_spacing": procedural_road_spacing,
		"procedural_road_width": procedural_road_width,
		"world_map_active": world_map_active,
		"water_level": water_level,
		"noise_values": noise_values,
		"noise_seed": noise_seed,
		"noise_frequency": noise_frequency,
		"noise_threshold": noise_threshold,
		"scale_min": scale_min,
		"scale_max": scale_max,
		"scale_multiplier": scale_multiplier,
		"y_offset": y_offset,
		"use_noise": use_noise,
		"use_water_density": use_water_density,
		"record_random_scale_factor": record_random_scale_factor
	}


func _build_vegetation_noise_samples(noise_source: FastNoiseLite, chunk_origin_x: int, chunk_origin_z: int, chunk_stride: int, step: int, use_noise: bool) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	if not use_noise or noise_source == null:
		return samples

	for x in range(0, chunk_stride, step):
		for z in range(0, chunk_stride, step):
			samples.append(noise_source.get_noise_2d(chunk_origin_x + x, chunk_origin_z + z))

	return samples


func _build_native_vegetation_instances(
		batch_heights: PackedFloat32Array,
		config: Dictionary
) -> Array:
	var native := _get_native_helper()
	if not native or not native.has_method("build_vegetation_instances"):
		return []
	if batch_heights.is_empty():
		return []

	var native_records: Array = native.build_vegetation_instances(config, batch_heights)
	return native_records


func _ready():
	set_process(false)
	set_physics_process(false)
	# Load tree mesh from GLB model with its orientation transform
	var glb_result = load_tree_mesh_from_glb(tree_model_path)
	if glb_result.mesh:
		tree_mesh = glb_result.mesh
		tree_base_transform = glb_result.transform
		tree_base_transform.origin = Vector3.ZERO # Remove position, keep rotation/scale
	else:
		push_warning("Failed to load tree model, falling back to basic mesh")
		tree_mesh = create_basic_tree_mesh()

	# Load grass mesh
	var grass_result = load_tree_mesh_from_glb(grass_model_path)
	if grass_result.mesh:
		grass_mesh = grass_result.mesh
		grass_base_transform = grass_result.transform
		grass_base_transform.origin = Vector3.ZERO
	else:
		push_warning("Failed to load grass model, using basic mesh")
		grass_mesh = create_basic_grass_mesh()

	# Load rock mesh
	var rock_result = load_tree_mesh_from_glb(rock_model_path)
	if rock_result.mesh:
		rock_mesh = rock_result.mesh
		rock_base_transform = rock_result.transform
		rock_base_transform.origin = Vector3.ZERO
	else:
		push_warning("Failed to load rock model, using basic mesh")
		rock_mesh = create_basic_rock_mesh()

	_start_vegetation_render_resource_prewarm()

	# Initialize noise generators with current seed
	initialize_noise()

	if terrain_manager:
		terrain_manager.chunk_generated.connect(_on_chunk_generated)
		terrain_manager.chunk_modified.connect(_on_chunk_modified)
		if terrain_manager.has_signal("chunk_unloaded"):
			terrain_manager.chunk_unloaded.connect(_on_chunk_unloaded)
		if terrain_manager.has_signal("spawn_zones_ready"):
			terrain_manager.spawn_zones_ready.connect(_on_spawn_zones_ready)
		_terrain_supports_road_query = terrain_manager.has_method("is_road_at_position")

	# Find player
	player = get_tree().get_first_node_in_group("player")
	_start_collider_update_timer()


func get_viewer_position() -> Vector3:
	var vehicle_manager := _get_vehicle_manager()
	if vehicle_manager and "current_player_vehicle" in vehicle_manager:
		var vehicle: Node3D = vehicle_manager.current_player_vehicle
		if is_instance_valid(vehicle):
			return vehicle.global_position

	if not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player")
	if is_instance_valid(player):
		return player.global_position
	return global_position


func _get_vehicle_manager() -> Node:
	if _cached_vehicle_manager and is_instance_valid(_cached_vehicle_manager):
		return _cached_vehicle_manager

	_cached_vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	return _cached_vehicle_manager


## Initialize or re-initialize noise generators based on current terrain seed
func initialize_noise():
	# Derive seed from world seed for reproducibility
	var base_seed = terrain_manager.world_seed if terrain_manager else 12345

	forest_noise = FastNoiseLite.new()
	forest_noise.frequency = 0.05
	forest_noise.seed = base_seed

	grass_noise = FastNoiseLite.new()
	grass_noise.frequency = 0.08
	grass_noise.seed = base_seed + 1

	rock_noise = FastNoiseLite.new()
	rock_noise.frequency = 0.06
	rock_noise.seed = base_seed + 2


# Called when terrain is modified (player edits) - reparent vegetation, don't regenerate
func _on_chunk_modified(coord: Vector3i, chunk_node: Node3D):
	if chunk_node == null:
		return

	# Only handle surface chunks (Y=0) - vegetation doesn't exist on underground/sky chunks
	if coord.y != 0:
		return

	# Extract surface key (X,Z) - vegetation only exists on surface
	var surface_key = Vector2i(coord.x, coord.z)

	# Reparent vegetation MultiMeshInstances to the NEW chunk_node
	# This prevents them from being deleted when old chunk_node is freed
	if chunk_tree_data.has(surface_key):
		var data = chunk_tree_data[surface_key]
		if data.has("multimesh") and _is_chunk_multimesh_handle_valid(data.multimesh):
			_attach_chunk_multimesh(data.multimesh, chunk_node)
		data.chunk_node = chunk_node

	if chunk_grass_data.has(surface_key):
		var data = chunk_grass_data[surface_key]
		if data.has("multimesh") and _is_chunk_multimesh_handle_valid(data.multimesh):
			_attach_chunk_multimesh(data.multimesh, chunk_node)
		data.chunk_node = chunk_node

	if chunk_rock_data.has(surface_key):
		var data = chunk_rock_data[surface_key]
		if data.has("multimesh") and _is_chunk_multimesh_handle_valid(data.multimesh):
			_attach_chunk_multimesh(data.multimesh, chunk_node)
		data.chunk_node = chunk_node

## Called when a chunk is unloaded - clean up vegetation data and colliders
func _on_chunk_unloaded(coord: Vector3i):
	# Only handle surface chunks (Y=0)
	if coord.y != 0:
		return

	var surface_key = Vector2i(coord.x, coord.z)

	# Clean up trees (including MultiMesh and colliders)
	if chunk_tree_data.has(surface_key):
		var data = chunk_tree_data[surface_key]
		var tree_count = data.trees.size() if data.has("trees") else 0
		var colliders_removed = 0
		# Free MultiMesh
		if data.has("multimesh"):
			_free_chunk_multimesh_handle(data.multimesh)
		# Return colliders to pool
		for tree in data.trees:
			var key = _tree_key(surface_key, tree.index)
			if active_colliders.has(key):
				_return_collider_to_pool(active_colliders[key])
				active_colliders.erase(key)
				colliders_removed += 1
		chunk_tree_data.erase(surface_key)
		_clear_global_vegetation_chunk_render_payload("tree", surface_key)
		_mark_global_vegetation_render_dirty("tree", surface_key)

	# Clean up grass
	if chunk_grass_data.has(surface_key):
		var data = chunk_grass_data[surface_key]
		if data.has("multimesh"):
			_free_chunk_multimesh_handle(data.multimesh)
		for grass in data.grass_list:
			var key = _grass_key(surface_key, grass.index)
			if active_grass_colliders.has(key):
				_return_grass_collider_to_pool(active_grass_colliders[key])
				active_grass_colliders.erase(key)
		chunk_grass_data.erase(surface_key)
		_clear_global_vegetation_chunk_render_payload("grass", surface_key)
		_mark_global_vegetation_render_dirty("grass", surface_key)

	# Clean up rocks
	if chunk_rock_data.has(surface_key):
		var data = chunk_rock_data[surface_key]
		if data.has("multimesh"):
			_free_chunk_multimesh_handle(data.multimesh)
		for rock in data.rock_list:
			var key = _rock_key(surface_key, rock.index)
			if active_rock_colliders.has(key):
				_return_rock_collider_to_pool(active_rock_colliders[key])
				active_rock_colliders.erase(key)
		chunk_rock_data.erase(surface_key)
		_clear_global_vegetation_chunk_render_payload("rock", surface_key)
		_mark_global_vegetation_render_dirty("rock", surface_key)

	_mark_collider_refresh_dirty()

func _on_chunk_generated(coord: Vector3i, chunk_node: Node3D):
	if chunk_node == null:
		return

	# Only spawn vegetation on surface chunks (Y=0)
	# Underground chunks (Y=-1, -2, etc.) and sky chunks (Y=1+) don't need vegetation
	if coord.y != 0:
		return

	# Skip vegetation for modified chunks (player-built structures)
	# Check all Y layers at this X,Z for modifications
	if terrain_manager and terrain_manager.has_method("has_modifications_at_xz"):
		if terrain_manager.has_modifications_at_xz(coord.x, coord.z):
			return # Don't spawn vegetation on player-modified terrain

	# Extract surface key (X,Z) - vegetation only exists on surface
	var surface_key = Vector2i(coord.x, coord.z)

	if chunk_tree_data.has(surface_key):
		_cleanup_chunk_trees(surface_key)
	if chunk_grass_data.has(surface_key):
		_cleanup_chunk_grass(surface_key)
	if chunk_rock_data.has(surface_key):
		_cleanup_chunk_rocks(surface_key)

	pending_chunks.append({
		"coord": surface_key, # Use surface_key for vegetation
		"chunk_node": chunk_node,
		"frames_waited": 0,
		"stage": 0 # 0=Trees, 1=Grass, 2=Rocks
	})
	_wake_process_loop()
	_mark_collider_refresh_dirty()

func _cleanup_chunk_trees(coord: Vector2i, immediate_free: bool = false):
	if chunk_tree_data.has(coord):
		var data = chunk_tree_data[coord]
		# FIX: Properly free the MultiMeshInstance3D to prevent "ghost" trees
		if data.has("multimesh"):
			_free_chunk_multimesh_handle(data.multimesh, immediate_free)

		# Return colliders to pool
		for tree in data.trees:
			var key = _tree_key(coord, tree.index)
			if active_colliders.has(key):
				if immediate_free:
					active_colliders[key].free()
				else:
					_return_collider_to_pool(active_colliders[key])
				active_colliders.erase(key)
		if immediate_free:
			_free_vegetation_instance_entries(data.trees)
		chunk_tree_data.erase(coord)
		_clear_global_vegetation_chunk_render_payload("tree", coord)
		_mark_collider_refresh_dirty()
		_mark_global_vegetation_render_dirty("tree", coord)

func _cleanup_chunk_grass(coord: Vector2i, immediate_free: bool = false):
	if chunk_grass_data.has(coord):
		var data = chunk_grass_data[coord]
		# FIX: Properly free the MultiMeshInstance3D
		if data.has("multimesh"):
			_free_chunk_multimesh_handle(data.multimesh, immediate_free)

		for grass in data.grass_list:
			var key = _grass_key(coord, grass.index)
			if active_grass_colliders.has(key):
				if immediate_free:
					active_grass_colliders[key].free()
				else:
					_return_grass_collider_to_pool(active_grass_colliders[key])
				active_grass_colliders.erase(key)
		if immediate_free:
			_free_vegetation_instance_entries(data.grass_list)
		chunk_grass_data.erase(coord)
		_clear_global_vegetation_chunk_render_payload("grass", coord)
		_mark_collider_refresh_dirty()
		_mark_global_vegetation_render_dirty("grass", coord)

func _cleanup_chunk_rocks(coord: Vector2i, immediate_free: bool = false):
	if chunk_rock_data.has(coord):
		var data = chunk_rock_data[coord]
		# FIX: Properly free the MultiMeshInstance3D
		if data.has("multimesh"):
			_free_chunk_multimesh_handle(data.multimesh, immediate_free)

		for rock in data.rock_list:
			var key = _rock_key(coord, rock.index)
			if active_rock_colliders.has(key):
				if immediate_free:
					active_rock_colliders[key].free()
				else:
					_return_rock_collider_to_pool(active_rock_colliders[key])
				active_rock_colliders.erase(key)
		if immediate_free:
			_free_vegetation_instance_entries(data.rock_list)
		chunk_rock_data.erase(coord)
		_clear_global_vegetation_chunk_render_payload("rock", coord)
		_mark_collider_refresh_dirty()
		_mark_global_vegetation_render_dirty("rock", coord)


func _free_vegetation_instance_entries(entries: Array) -> void:
	for entry in entries:
		if entry is Object and is_instance_valid(entry):
			entry.free()

func _get_pending_vegetation_budget_ms() -> float:
	var budget := vegetation_initial_load_budget_ms if is_initial_load_batch else vegetation_stream_budget_ms
	return maxf(0.1, budget)

func _get_next_pending_chunk_index() -> int:
	if pending_chunks.is_empty():
		return -1
	if not prioritize_nearby_vegetation_chunks or not terrain_manager:
		return 0

	var viewer_pos := get_viewer_position()
	var chunk_stride := int(terrain_manager.CHUNK_STRIDE)
	var best_index := 0
	var best_distance_sq := 1.0e30
	for i in range(pending_chunks.size()):
		var item := pending_chunks[i]
		var coord: Vector2i = item.get("coord", Vector2i.ZERO)
		var center_x := (float(coord.x) + 0.5) * float(chunk_stride)
		var center_z := (float(coord.y) + 0.5) * float(chunk_stride)
		var dx := viewer_pos.x - center_x
		var dz := viewer_pos.z - center_z
		var distance_sq := dx * dx + dz * dz
		if distance_sq < best_distance_sq:
			best_distance_sq = distance_sq
			best_index = i
	return best_index

func _complete_initial_load_pending_chunk() -> void:
	if not is_initial_load_batch:
		return
	initial_load_count -= 1
	if initial_load_count <= 0:
		is_initial_load_batch = false
		initial_load_count = 0
		all_vegetation_ready.emit()

func _process_pending_vegetation_chunks() -> void:
	var pending_chunk_start_us := Time.get_ticks_usec()
	_last_pending_chunk_stages_processed = 0
	_last_pending_chunk_budget_ms = _get_pending_vegetation_budget_ms()

	while not pending_chunks.is_empty():
		if _last_pending_chunk_stages_processed >= vegetation_max_stages_per_frame:
			break

		var elapsed_ms := float(Time.get_ticks_usec() - pending_chunk_start_us) / 1000.0
		if _last_pending_chunk_stages_processed > 0 and elapsed_ms >= _last_pending_chunk_budget_ms:
			break

		var item_index := _get_next_pending_chunk_index()
		if item_index < 0:
			break

		var item := pending_chunks[item_index]
		var frames_waited := int(item.get("frames_waited", 0))
		if frames_waited < vegetation_chunk_start_delay_frames:
			item["frames_waited"] = frames_waited + 1
			pending_chunks[item_index] = item
			break

		var chunk_node_variant: Variant = item.get("chunk_node", null)
		if not is_instance_valid(chunk_node_variant):
			pending_chunks.remove_at(item_index)
			_complete_initial_load_pending_chunk()
			continue
		var chunk_node: Node3D = chunk_node_variant as Node3D
		if chunk_node == null:
			pending_chunks.remove_at(item_index)
			_complete_initial_load_pending_chunk()
			continue

		var stage := int(item.get("stage", 0))
		var coord: Vector2i = item.get("coord", Vector2i.ZERO)
		match stage:
			0:
				_place_vegetation_for_chunk(coord, chunk_node)
				item["stage"] = 1
				pending_chunks[item_index] = item
			1:
				_place_grass_for_chunk(coord, chunk_node)
				item["stage"] = 2
				pending_chunks[item_index] = item
			2:
				_place_rocks_for_chunk(coord, chunk_node)
				pending_chunks.remove_at(item_index)
				_complete_initial_load_pending_chunk()
			_:
				pending_chunks.remove_at(item_index)
				_complete_initial_load_pending_chunk()
		_last_pending_chunk_stages_processed += 1

	_last_pending_chunk_process_ms = float(Time.get_ticks_usec() - pending_chunk_start_us) / 1000.0

func _process(_delta):
	if not _has_process_work_pending():
		set_process(false)
		return
	var pending_placements_start_us := Time.get_ticks_usec()
	_process_pending_vegetation_chunks()
	_process_pending_placements()
	if _should_flush_global_vegetation_render_batch():
		_flush_one_global_vegetation_render_batch()
	_last_pending_placements_ms = float(Time.get_ticks_usec() - pending_placements_start_us) / 1000.0
	_sync_process_loop()


func _physics_process(_delta):
	_run_collider_refresh_tick()

func _run_collider_refresh_tick() -> void:
	_collider_refresh_tick_count += 1
	# Refresh colliders when the active viewer actually moves far enough or the
	# loaded vegetation set changes, instead of doing a blind timer sweep.
	var collider_refresh_start_us := Time.get_ticks_usec()
	var should_refresh_colliders := _collider_refresh_dirty or not pending_collider_adds.is_empty() or not pending_collider_removes.is_empty()
	var current_viewer_pos := get_viewer_position()
	var current_viewer_chunk := _last_collider_update_chunk
	if terrain_manager:
		var chunk_stride = terrain_manager.CHUNK_STRIDE
		current_viewer_chunk = Vector2i(int(floor(current_viewer_pos.x / chunk_stride)), int(floor(current_viewer_pos.z / chunk_stride)))
		var collider_refresh_distance: float = max(4.0, collider_distance * 0.25)
		var collider_refresh_distance_sq: float = collider_refresh_distance * collider_refresh_distance
		if current_viewer_chunk != _last_collider_update_chunk:
			should_refresh_colliders = true
		elif current_viewer_pos.distance_squared_to(_last_collider_update_pos) >= collider_refresh_distance_sq:
			should_refresh_colliders = true

	if should_refresh_colliders and terrain_manager:
		_last_collider_update_chunk = current_viewer_chunk
		_last_collider_update_pos = current_viewer_pos
		_collider_refresh_dirty = false
		_update_proximity_colliders()
		_update_grass_proximity_colliders()
		_update_rock_proximity_colliders()
		_cleanup_orphan_colliders()
	_last_collider_refresh_ms = float(Time.get_ticks_usec() - collider_refresh_start_us) / 1000.0

	# Always process incremental updates (Add/Remove actual nodes)
	var queued_collider_updates_start_us := Time.get_ticks_usec()
	_process_queued_collider_updates()
	_last_queued_collider_update_ms = float(Time.get_ticks_usec() - queued_collider_updates_start_us) / 1000.0

func _process_queued_collider_updates():
	var updates_done = 0

	# Prioritize removes (to free pool)
	while updates_done < MAX_COLLIDER_UPDATES_PER_FRAME and not pending_collider_removes.is_empty():
		var task = pending_collider_removes.pop_front()
		keys_pending_remove.erase(task.key)
		updates_done += 1

		if task.type == "tree":
			if active_colliders.has(task.key):
				_return_collider_to_pool(active_colliders[task.key])
				active_colliders.erase(task.key)
		elif task.type == "grass":
			if active_grass_colliders.has(task.key):
				_return_grass_collider_to_pool(active_grass_colliders[task.key])
				active_grass_colliders.erase(task.key)
		elif task.type == "rock":
			if active_rock_colliders.has(task.key):
				_return_rock_collider_to_pool(active_rock_colliders[task.key])
				active_rock_colliders.erase(task.key)

	# Then do adds
	while updates_done < MAX_COLLIDER_UPDATES_PER_FRAME and not pending_collider_adds.is_empty():
		var task = pending_collider_adds.pop_front()
		keys_pending_add.erase(task.key)
		updates_done += 1

		# Check if remove is pending (race condition)
		if keys_pending_remove.has(task.key):
			continue

		if task.type == "tree":
			# Copied logic from old loop
			if not active_colliders.has(task.key):
				_spawn_tree_collider(task.key, task.item)
		elif task.type == "grass":
			if not active_grass_colliders.has(task.key):
				_spawn_grass_collider(task.key, task.item)
		elif task.type == "rock":
			if not active_rock_colliders.has(task.key):
				_spawn_rock_collider(task.key, task.item)

	if updates_done > 0:
		_mark_collider_refresh_dirty()
	if not pending_collider_adds.is_empty() or not pending_collider_removes.is_empty():
		_request_collider_update_soon()


func _mark_collider_refresh_dirty() -> void:
	_collider_refresh_dirty = true
	_request_collider_update_soon()

func _is_spawn_blocked_by_road(global_x: float, global_z: float) -> bool:
	if not terrain_manager:
		return false

	if _terrain_supports_road_query:
		return terrain_manager.is_road_at_position(global_x, global_z, road_clearance)

	if "procedural_road_spacing" in terrain_manager and "procedural_road_width" in terrain_manager:
		var road_spacing := float(terrain_manager.procedural_road_spacing)
		if road_spacing <= 0.0:
			return false

		var road_width := float(terrain_manager.procedural_road_width)
		var local_x := fposmod(global_x, road_spacing)
		var local_z := fposmod(global_z, road_spacing)
		var dist_x := minf(local_x, road_spacing - local_x)
		var dist_z := minf(local_z, road_spacing - local_z)
		return minf(dist_x, dist_z) <= road_width * 0.5 + road_clearance

	return false

func _spawn_tree_collider(key, item):
	var collider = _get_collider_from_pool()
	collider.global_position = item.tree.hit_pos
	collider.global_position.y += (collision_height * item.tree.scale) / 2.0
	var shape = collider.get_child(0).shape as CylinderShape3D
	shape.radius = collision_radius * item.tree.scale
	shape.height = collision_height * item.tree.scale
	collider.set_meta("tree_coord", item.coord)
	collider.set_meta("tree_index", item.tree.index)
	active_colliders[key] = collider

func _spawn_grass_collider(key, item):
	var collider = _get_grass_collider_from_pool()
	collider.global_position = item.grass.hit_pos
	collider.global_position.y += grass_collision_height / 2.0
	var shape = collider.get_child(0).shape as CylinderShape3D
	shape.radius = grass_collision_radius
	shape.height = grass_collision_height
	collider.set_meta("grass_coord", item.coord)
	collider.set_meta("grass_index", item.grass.index)
	active_grass_colliders[key] = collider

func _spawn_rock_collider(key, item):
	var collider = _get_rock_collider_from_pool()
	collider.global_position = item.rock.hit_pos
	collider.global_position.y += rock_collision_height / 2.0
	var shape = collider.get_child(0).shape as CylinderShape3D
	shape.radius = rock_collision_radius
	shape.height = rock_collision_height
	collider.set_meta("rock_coord", item.coord)
	collider.set_meta("rock_index", item.rock.index)
	active_rock_colliders[key] = collider

func _process_pending_placements():
	var chunk_stride = terrain_manager.CHUNK_STRIDE

	# Process pending rock placements
	var completed_rocks = []
	for i in range(pending_rock_placements.size()):
		var placement = pending_rock_placements[i]
		var coord = Vector2i(int(floor(placement.world_pos.x / chunk_stride)), int(floor(placement.world_pos.z / chunk_stride)))

		if chunk_rock_data.has(coord):
			var data = chunk_rock_data[coord]
			if data.has("chunk_node") and is_instance_valid(data.chunk_node) and data.has("multimesh") and _is_chunk_multimesh_handle_valid(data.multimesh):
				# Chunk is now valid, add the rock
				if _add_rock_to_chunk(placement.world_pos, placement.scale, placement.rotation, coord):
					completed_rocks.append(i)

	# Remove completed placements (reverse order to preserve indices)
	for i in range(completed_rocks.size() - 1, -1, -1):
		pending_rock_placements.remove_at(completed_rocks[i])

	# Process pending grass placements
	var completed_grass = []
	for i in range(pending_grass_placements.size()):
		var placement = pending_grass_placements[i]
		var coord = Vector2i(int(floor(placement.world_pos.x / chunk_stride)), int(floor(placement.world_pos.z / chunk_stride)))

		if chunk_grass_data.has(coord):
			var data = chunk_grass_data[coord]
			if data.has("chunk_node") and is_instance_valid(data.chunk_node) and data.has("multimesh") and _is_chunk_multimesh_handle_valid(data.multimesh):
				if _add_grass_to_chunk(placement.world_pos, placement.scale, placement.rotation, coord):
					completed_grass.append(i)

	for i in range(completed_grass.size() - 1, -1, -1):
		pending_grass_placements.remove_at(completed_grass[i])

## Clean up any orphan colliders that aren't in loaded chunks
## This catches colliders that weren't properly tracked in active_colliders
func _cleanup_orphan_colliders():
	if not terrain_manager:
		return

	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var cleaned = 0
	var visible_colliders = 0
	var total_colliders = 0

	# Check all children that are colliders (StaticBody3D or Area3D)
	for child in get_children():
		if child is StaticBody3D or child is Area3D:
			total_colliders += 1

			# Skip if already in pool (visible = false means in pool)
			if not child.visible:
				continue

			visible_colliders += 1

			# Calculate which chunk this collider is in
			var pos = child.global_position
			var chunk_x = int(floor(pos.x / chunk_stride))
			var chunk_z = int(floor(pos.z / chunk_stride))
			var chunk_key = Vector2i(chunk_x, chunk_z)

			# If chunk isn't loaded (not in tree/grass/rock data), this is orphaned
			var is_loaded = chunk_tree_data.has(chunk_key) or chunk_grass_data.has(chunk_key) or chunk_rock_data.has(chunk_key)

			if not is_loaded:
				# This collider is orphaned - hide it and disable collision
				child.visible = false
				child.collision_layer = 0
				if child is Area3D:
					child.monitorable = false
				# Also disable CollisionShape3D so it doesn't show in debug
				for grandchild in child.get_children():
					if grandchild is CollisionShape3D:
						grandchild.disabled = true
				cleaned += 1

func _update_proximity_colliders():
	if not terrain_manager:
		return

	var player_pos = get_viewer_position()
	var dist_sq = collider_distance * collider_distance
	var chunk_stride = terrain_manager.CHUNK_STRIDE

	# Collect trees that need colliders (only from nearby chunks)
	var trees_needing_colliders: Array[Dictionary] = []

	# Optimized: Check only 3x3 chunks around the active viewer instead of iterating all loaded chunks
	var player_chunk_x = int(floor(player_pos.x / chunk_stride))
	var player_chunk_z = int(floor(player_pos.z / chunk_stride))

	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var coord = Vector2i(player_chunk_x + dx, player_chunk_z + dz)

			if not chunk_tree_data.has(coord):
				continue

			if not _chunk_overlaps_radius(coord, player_pos, collider_distance, chunk_stride):
				continue

			var data = chunk_tree_data[coord]
			for tree in data.trees:
				if not tree.alive:
					continue

				var tree_dist_sq = player_pos.distance_squared_to(tree.world_pos)
				if tree_dist_sq < dist_sq:
					trees_needing_colliders.append({
						"coord": coord,
						"tree": tree,
						"dist_sq": tree_dist_sq
					})

	# Limit to MAX_ACTIVE_COLLIDERS
	var wanted_keys: Dictionary = {}
	for item in _pick_nearest_candidates(trees_needing_colliders, MAX_ACTIVE_COLLIDERS):
		var key = _tree_key(item.coord, item.tree.index)
		wanted_keys[key] = item

	# Remove colliders that are no longer needed
	var keys_to_remove = []
	for key in active_colliders:
		if not wanted_keys.has(key):
			keys_to_remove.append(key)

	for key in keys_to_remove:
		if not keys_pending_remove.has(key):
			pending_collider_removes.append({"type": "tree", "key": key})
			keys_pending_remove[key] = true

	# Add colliders for trees that need them
	for key in wanted_keys:
		if not active_colliders.has(key) and not keys_pending_add.has(key):
			var item = wanted_keys[key]
			pending_collider_adds.append({"type": "tree", "key": key, "item": item})
			keys_pending_add[key] = true

func _tree_key(coord: Vector2i, index: int) -> String:
	return "%d_%d_%d" % [coord.x, coord.y, index]

@export var debug_collision: bool = false

# ... (existing variables)

func _get_collider_from_pool() -> StaticBody3D:
	if collider_pool.size() > 0:
		var collider = collider_pool.pop_back()
		collider.visible = debug_collision # Use the flag
		collider.collision_layer = 8 # Layer 8 = vegetation (separate from terrain layer 1)
		# Re-enable the CollisionShape3D
		for child in collider.get_children():
			if child is CollisionShape3D:
				child.disabled = false
		return collider

	# Create new collider
	var body = StaticBody3D.new()
	body.add_to_group("trees")
	body.collision_layer = 8 # Layer 8 = vegetation (separate from terrain layer 1)

	var shape_node = CollisionShape3D.new()
	var shape = CylinderShape3D.new()
	shape.radius = collision_radius
	shape.height = collision_height
	shape_node.shape = shape
	body.add_child(shape_node)

	# DEBUG: Add visible mesh to see collider position
	var mesh_instance = MeshInstance3D.new()
	var cylinder_mesh = CylinderMesh.new()
	cylinder_mesh.top_radius = collision_radius
	cylinder_mesh.bottom_radius = collision_radius
	cylinder_mesh.height = collision_height
	mesh_instance.mesh = cylinder_mesh
	var debug_mat = StandardMaterial3D.new()
	debug_mat.albedo_color = Color(1, 0, 0, 0.5)
	debug_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = debug_mat
	body.add_child(mesh_instance)

	body.visible = debug_collision # Set initial visibility

	add_child(body)
	return body

func _return_collider_to_pool(collider: StaticBody3D):
	collider.collision_layer = 0 # Disable collision
	collider.visible = false
	# Also disable the CollisionShape3D so it doesn't show in Godot's debug view
	for child in collider.get_children():
		if child is CollisionShape3D:
			child.disabled = true
	collider_pool.append(collider)

# ========== GRASS HELPER FUNCTIONS ==========

func _grass_key(coord: Vector2i, index: int) -> String:
	return "g_%d_%d_%d" % [coord.x, coord.y, index]

func _get_grass_collider_from_pool() -> Area3D:
	if grass_collider_pool.size() > 0:
		var collider = grass_collider_pool.pop_back()
		collider.visible = debug_collision
		collider.collision_layer = 8 # Layer 8 = vegetation (separate from terrain layer 1)
		collider.monitorable = true
		# Re-enable CollisionShape3D
		for child in collider.get_children():
			if child is CollisionShape3D:
				child.disabled = false
		return collider

	# Create new collider - Area3D so player can walk through
	var body = Area3D.new()
	body.add_to_group("grass")
	body.collision_layer = 8 # Layer 8 = vegetation (separate from terrain)
	body.monitorable = true # Can be detected by raycasts
	body.monitoring = false # Doesn't need to detect others

	var shape_node = CollisionShape3D.new()
	var shape = CylinderShape3D.new()
	shape.radius = grass_collision_radius
	shape.height = grass_collision_height
	shape_node.shape = shape
	body.add_child(shape_node)

	# DEBUG: Add visible mesh to see collider position
	var mesh_instance = MeshInstance3D.new()
	var cylinder_mesh = CylinderMesh.new()
	cylinder_mesh.top_radius = grass_collision_radius
	cylinder_mesh.bottom_radius = grass_collision_radius
	cylinder_mesh.height = grass_collision_height
	mesh_instance.mesh = cylinder_mesh
	var debug_mat = StandardMaterial3D.new()
	debug_mat.albedo_color = Color(0, 1, 0, 0.5) # Green for grass
	debug_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = debug_mat
	body.add_child(mesh_instance)

	body.visible = debug_collision

	add_child(body)
	return body

func _return_grass_collider_to_pool(collider: Area3D):
	collider.collision_layer = 0
	collider.monitorable = false
	collider.visible = false
	# Disable CollisionShape3D so it doesn't show in Godot's debug view
	for child in collider.get_children():
		if child is CollisionShape3D:
			child.disabled = true
	grass_collider_pool.append(collider)

func _update_grass_proximity_colliders():
	if not terrain_manager:
		return

	var player_pos = get_viewer_position()
	var dist_sq = collider_distance * collider_distance
	var chunk_stride = terrain_manager.CHUNK_STRIDE

	# Collect grass that needs colliders
	var grass_needing_colliders: Array[Dictionary] = []

	# Optimized: Check only 3x3 chunks around the active viewer
	var player_chunk_x = int(floor(player_pos.x / chunk_stride))
	var player_chunk_z = int(floor(player_pos.z / chunk_stride))

	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var coord = Vector2i(player_chunk_x + dx, player_chunk_z + dz)

			if not chunk_grass_data.has(coord):
				continue

			if not _chunk_overlaps_radius(coord, player_pos, collider_distance, chunk_stride):
				continue

			var data = chunk_grass_data[coord]
			for grass in data.grass_list:
				if not grass.alive:
					continue

				var grass_dist_sq = player_pos.distance_squared_to(grass.world_pos)
				if grass_dist_sq < dist_sq:
					grass_needing_colliders.append({
						"coord": coord,
						"grass": grass,
						"dist_sq": grass_dist_sq
					})

	# Limit to MAX_ACTIVE_GRASS_COLLIDERS
	var wanted_keys: Dictionary = {}
	for item in _pick_nearest_candidates(grass_needing_colliders, MAX_ACTIVE_GRASS_COLLIDERS):
		var key = _grass_key(item.coord, item.grass.index)
		wanted_keys[key] = item

	# Remove colliders that are no longer needed
	var keys_to_remove = []
	for key in active_grass_colliders:
		if not wanted_keys.has(key):
			keys_to_remove.append(key)

	for key in keys_to_remove:
		if not keys_pending_remove.has(key):
			pending_collider_removes.append({"type": "grass", "key": key})
			keys_pending_remove[key] = true

	# Add colliders for grass that needs them
	for key in wanted_keys:
		if not active_grass_colliders.has(key) and not keys_pending_add.has(key):
			var item = wanted_keys[key]
			pending_collider_adds.append({"type": "grass", "key": key, "item": item})
			keys_pending_add[key] = true

# ========== ROCK HELPER FUNCTIONS ==========

func _rock_key(coord: Vector2i, index: int) -> String:
	return "r_%d_%d_%d" % [coord.x, coord.y, index]

func _get_rock_collider_from_pool() -> Area3D:
	if rock_collider_pool.size() > 0:
		var collider = rock_collider_pool.pop_back()
		collider.visible = debug_collision
		collider.collision_layer = 8 # Layer 8 = vegetation (separate from terrain)
		collider.monitorable = true
		# Re-enable CollisionShape3D
		for child in collider.get_children():
			if child is CollisionShape3D:
				child.disabled = false
		return collider

	# Create new collider - Area3D so player can walk through
	var body = Area3D.new()
	body.add_to_group("rocks")
	body.collision_layer = 8 # Layer 8 = vegetation (separate from terrain)
	body.monitorable = true
	body.monitoring = false

	var shape_node = CollisionShape3D.new()
	var shape = CylinderShape3D.new()
	shape.radius = rock_collision_radius
	shape.height = rock_collision_height
	shape_node.shape = shape
	body.add_child(shape_node)

	# DEBUG: Add visible mesh
	var mesh_instance = MeshInstance3D.new()
	var cylinder_mesh = CylinderMesh.new()
	cylinder_mesh.top_radius = rock_collision_radius
	cylinder_mesh.bottom_radius = rock_collision_radius
	cylinder_mesh.height = rock_collision_height
	mesh_instance.mesh = cylinder_mesh
	var debug_mat = StandardMaterial3D.new()
	debug_mat.albedo_color = Color(0.5, 0.5, 0.5, 0.5) # Gray for rocks
	debug_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = debug_mat
	body.add_child(mesh_instance)

	body.visible = debug_collision

	add_child(body)
	return body

func _return_rock_collider_to_pool(collider: Area3D):
	collider.collision_layer = 0
	collider.monitorable = false
	collider.visible = false
	# Disable CollisionShape3D so it doesn't show in Godot's debug view
	for child in collider.get_children():
		if child is CollisionShape3D:
			child.disabled = true
	rock_collider_pool.append(collider)

func _update_rock_proximity_colliders():
	if not terrain_manager:
		return

	var player_pos = get_viewer_position()
	var dist_sq = collider_distance * collider_distance
	var chunk_stride = terrain_manager.CHUNK_STRIDE

	var rocks_needing_colliders: Array[Dictionary] = []

	# Optimized: Check only 3x3 chunks around the active viewer
	var player_chunk_x = int(floor(player_pos.x / chunk_stride))
	var player_chunk_z = int(floor(player_pos.z / chunk_stride))

	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var coord = Vector2i(player_chunk_x + dx, player_chunk_z + dz)

			if not chunk_rock_data.has(coord):
				continue

			if not _chunk_overlaps_radius(coord, player_pos, collider_distance, chunk_stride):
				continue

			var data = chunk_rock_data[coord]
			for rock in data.rock_list:
				if not rock.alive:
					continue

				var rock_dist_sq = player_pos.distance_squared_to(rock.world_pos)
				if rock_dist_sq < dist_sq:
					rocks_needing_colliders.append({
						"coord": coord,
						"rock": rock,
						"dist_sq": rock_dist_sq
					})

	var wanted_keys: Dictionary = {}
	for item in _pick_nearest_candidates(rocks_needing_colliders, MAX_ACTIVE_ROCK_COLLIDERS):
		var key = _rock_key(item.coord, item.rock.index)
		wanted_keys[key] = item

	var keys_to_remove = []
	for key in active_rock_colliders:
		if not wanted_keys.has(key):
			keys_to_remove.append(key)

	for key in keys_to_remove:
		if not keys_pending_remove.has(key):
			pending_collider_removes.append({"type": "rock", "key": key})
			keys_pending_remove[key] = true

	for key in wanted_keys:
		if not active_rock_colliders.has(key) and not keys_pending_add.has(key):
			var item = wanted_keys[key]
			pending_collider_adds.append({"type": "rock", "key": key, "item": item})
			keys_pending_add[key] = true

func _place_vegetation_for_chunk(coord: Vector2i, chunk_node: Node3D):
	var mmi = _create_chunk_multimesh_handle("tree", coord, tree_mesh)

	var tree_list: Array = []
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var chunk_origin_x = coord.x * chunk_stride
	var chunk_origin_z = coord.y * chunk_stride
	var chunk_world_pos = chunk_node.global_position

	# Use density lookup instead of physics raycasting (much faster)
	# Use density lookup instead of physics raycasting (much faster)
	var step = 4

	var batch_heights = _get_chunk_height_map(coord, chunk_stride, step)
	var native := _get_native_helper()
	if native and native.has_method("build_vegetation_instances") and not batch_heights.is_empty() and not terrain_manager.world_map_active:
		var native_config := _build_vegetation_native_config(
			chunk_stride,
			step,
			chunk_origin_x,
			chunk_origin_z,
			chunk_world_pos,
			tree_base_transform,
			tree_rotation_fix,
			road_clearance,
			terrain_manager.procedural_roads_enabled,
			terrain_manager.procedural_road_spacing,
			terrain_manager.procedural_road_width,
			terrain_manager.world_map_active,
			terrain_manager.water_level,
			_build_vegetation_noise_samples(forest_noise, chunk_origin_x, chunk_origin_z, chunk_stride, step, true),
			int(forest_noise.seed),
			float(forest_noise.frequency),
			0.4,
			0.8,
			1.2,
			tree_scale,
			tree_y_offset,
			true,
			false,
			true
		)
		var native_records: Array = _build_native_vegetation_instances(batch_heights, native_config)
		_append_native_generated_instances(tree_list, native_records)

		if tree_list.size() > 0:
			_attach_chunk_multimesh(mmi, chunk_node)

		chunk_tree_data[coord] = {
			"multimesh": mmi,
			"trees": tree_list,
			"chunk_node": chunk_node
		}

		for tree in tree_list:
			var persist_key = _position_hash(tree.world_pos)
			if chopped_trees.has(persist_key):
				tree.alive = false
				tree.transform = _make_hidden_transform(tree.local_pos)

		if tree_list.size() > 0:
			_sync_multimesh_from_instances(mmi, tree_list, chunk_stride)
		return

	var batch_idx = 0

	for x in range(0, chunk_stride, step):
		for z in range(0, chunk_stride, step):
			var gx = chunk_origin_x + x
			var gz = chunk_origin_z + z

			if _is_spawn_blocked_by_road(gx, gz):
				if not batch_heights.is_empty():
					batch_idx += 1
				continue

			var noise_val = forest_noise.get_noise_2d(gx, gz)
			if noise_val < 0.4:
				# Sync index even if skipping
				if not batch_heights.is_empty(): batch_idx += 1
				continue

			# Use optimized chunk density lookup
			var terrain_y = -1000.0
			if not batch_heights.is_empty():
				# Use batch result
				if batch_idx < batch_heights.size():
					terrain_y = batch_heights[batch_idx]
				batch_idx += 1
			else:
				# Slow fallback
				terrain_y = terrain_manager.get_chunk_surface_height(Vector3i(coord.x, 0, coord.y), x, z)

			if terrain_y < -100.0: # No terrain found
				continue

			var hit_pos = Vector3(gx, terrain_y, gz)

			# Skip if underwater (Optimized: Simple check against water level for Infinite Plane)
			if terrain_y + 1.0 < terrain_manager.water_level:
				continue

			var local_pos = hit_pos - chunk_world_pos
			local_pos.y += tree_y_offset

			var world_pos = hit_pos
			world_pos.y += tree_y_offset

			var random_scale = randf_range(0.8, 1.2)
			var final_scale = tree_scale * random_scale
			var rotation_angle = randf() * TAU

			var t = _build_vegetation_transform(tree_base_transform, tree_rotation_fix, rotation_angle, final_scale, local_pos)
			tree_list.append(_make_vegetation_generated(
				world_pos,
				local_pos,
				hit_pos,
				rotation_angle,
				random_scale,
				tree_list.size(),
				final_scale,
				false,
				t
			))

	if tree_list.size() > 0:
		_attach_chunk_multimesh(mmi, chunk_node)

	chunk_tree_data[coord] = {
		"multimesh": mmi,
		"trees": tree_list,
		"chunk_node": chunk_node
	}

	# Apply chopped_trees filter - hide trees that were previously chopped
	for tree in tree_list:
		var persist_key = _position_hash(tree.world_pos)
		if chopped_trees.has(persist_key):
			tree.alive = false
			tree.transform = _make_hidden_transform(tree.local_pos)

	if tree_list.size() > 0:
		_sync_multimesh_from_instances(mmi, tree_list, chunk_stride)

func chop_tree_by_collider(collider: Node) -> bool:
	# Check if collider is still valid (not freed)
	if not is_instance_valid(collider):
		return false

	if not collider.has_meta("tree_coord"):
		return false

	var coord = collider.get_meta("tree_coord")
	var tree_index = collider.get_meta("tree_index")

	if not chunk_tree_data.has(coord):
		return false

	var data = chunk_tree_data[coord]
	for tree in data.trees:
		if tree.index == tree_index and tree.alive:
			tree.alive = false

			# Add to chopped_trees for persistence across chunk unloads
			var persist_key = _position_hash(tree.world_pos)
			chopped_trees[persist_key] = true

			tree.transform = _make_hidden_transform(tree.local_pos)
			if data.has("multimesh"):
				_sync_multimesh_from_instances(data.multimesh, data.trees, terrain_manager.CHUNK_STRIDE)

			# Remove collider
			var key = _tree_key(coord, tree_index)
			if active_colliders.has(key):
				_return_collider_to_pool(active_colliders[key])
				active_colliders.erase(key)

			tree_chopped.emit(tree.world_pos)
			return true

	return false

## Clear all vegetation (trees, grass, rocks) within a radius of a world position
## Used by prefab spawner to ensure buildings don't overlap vegetation
func clear_vegetation_in_area(center: Vector3, radius: float):
	if not terrain_manager:
		return


	var radius_sq = radius * radius
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var min_chunk_x = int(floor((center.x - radius) / chunk_stride))
	var max_chunk_x = int(floor((center.x + radius) / chunk_stride))
	var min_chunk_z = int(floor((center.z - radius) / chunk_stride))
	var max_chunk_z = int(floor((center.z + radius) / chunk_stride))

	for chunk_x in range(min_chunk_x, max_chunk_x + 1):
		for chunk_z in range(min_chunk_z, max_chunk_z + 1):
			var coord := Vector2i(chunk_x, chunk_z)
			if not _chunk_overlaps_radius(coord, center, radius, chunk_stride):
				continue
			if chunk_tree_data.has(coord):
				var tree_data = chunk_tree_data[coord]
				var tree_dirty := false
				for tree in tree_data.trees:
					if not tree.alive:
						continue
					var dx = tree.world_pos.x - center.x
					var dz = tree.world_pos.z - center.z
					if dx * dx + dz * dz < radius_sq:
						tree.alive = false
						tree.transform = _make_hidden_transform(tree.local_pos)
						tree_dirty = true
						var key = _tree_key(coord, tree.index)
						if active_colliders.has(key):
							_return_collider_to_pool(active_colliders[key])
							active_colliders.erase(key)
				if tree_dirty and tree_data.has("multimesh"):
					_sync_multimesh_from_instances(tree_data.multimesh, tree_data.trees, chunk_stride)

			if chunk_grass_data.has(coord):
				var grass_data = chunk_grass_data[coord]
				var grass_dirty := false
				for grass in grass_data.grass_list:
					if not grass.alive:
						continue
					var dx = grass.world_pos.x - center.x
					var dz = grass.world_pos.z - center.z
					if dx * dx + dz * dz < radius_sq:
						grass.alive = false
						grass.transform = _make_hidden_transform(grass.local_pos)
						grass_dirty = true
						var key = _grass_key(coord, grass.index)
						if active_grass_colliders.has(key):
							_return_grass_collider_to_pool(active_grass_colliders[key])
							active_grass_colliders.erase(key)
				if grass_dirty and grass_data.has("multimesh"):
					_sync_multimesh_from_instances(grass_data.multimesh, grass_data.grass_list, chunk_stride)

			if chunk_rock_data.has(coord):
				var rock_data = chunk_rock_data[coord]
				var rock_dirty := false
				for rock in rock_data.rock_list:
					if not rock.alive:
						continue
					var dx = rock.world_pos.x - center.x
					var dz = rock.world_pos.z - center.z
					if dx * dx + dz * dz < radius_sq:
						rock.alive = false
						rock.transform = _make_hidden_transform(rock.local_pos)
						rock_dirty = true
						var key = _rock_key(coord, rock.index)
						if active_rock_colliders.has(key):
							_return_rock_collider_to_pool(active_rock_colliders[key])
							active_rock_colliders.erase(key)
				if rock_dirty and rock_data.has("multimesh"):
					_sync_multimesh_from_instances(rock_data.multimesh, rock_data.rock_list, chunk_stride)


# ========== GRASS SPAWNING AND HARVESTING ==========

func _place_grass_for_chunk(coord: Vector2i, chunk_node: Node3D):
	if not grass_mesh:
		return

	var mmi = _create_chunk_multimesh_handle("grass", coord, grass_mesh)

	# Fix distance visibility issues
	if mmi is MultiMeshInstance3D:
		mmi.extra_cull_margin = 1000.0 # Very large margin
		mmi.ignore_occlusion_culling = true # Ignore occlusion
		mmi.lod_bias = 100.0 # Prevent LOD from hiding mesh
		mmi.visibility_range_end = 0.0 # 0 = infinite visibility

	var grass_list: Array = []
	var valid_transforms = []
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var chunk_origin_x = coord.x * chunk_stride
	var chunk_origin_z = coord.y * chunk_stride
	var chunk_world_pos = chunk_node.global_position

	# Grass placement - mode determines density and distribution
	# Optimized: step 2 reduces checks by 4x (256 vs 1024) - acceptable for grass
	var step = 2
	if dense_grass_mode: step = 1 # Use stride 1 for dense mode if requested

	var batch_heights = _get_chunk_height_map(coord, chunk_stride, step)
	var native := _get_native_helper()
	if native and native.has_method("build_vegetation_instances") and not batch_heights.is_empty() and not terrain_manager.world_map_active:
		var native_config := _build_vegetation_native_config(
			chunk_stride,
			step,
			chunk_origin_x,
			chunk_origin_z,
			chunk_world_pos,
			grass_base_transform,
			Vector3.ZERO,
			road_clearance,
			terrain_manager.procedural_roads_enabled,
			terrain_manager.procedural_road_spacing,
			terrain_manager.procedural_road_width,
			terrain_manager.world_map_active,
			terrain_manager.water_level,
			_build_vegetation_noise_samples(grass_noise, chunk_origin_x, chunk_origin_z, chunk_stride, step, not dense_grass_mode),
			int(grass_noise.seed),
			float(grass_noise.frequency),
			0.3,
			0.8,
			1.2,
			grass_scale,
			grass_y_offset,
			not dense_grass_mode,
			true,
			false
		)
		var native_records: Array = _build_native_vegetation_instances(batch_heights, native_config)
		_append_native_generated_instances(grass_list, native_records)

		# Add player-placed grass for this chunk
		for placed in placed_grass:
			var placed_coord = Vector2i(int(floor(placed.world_pos.x / chunk_stride)), int(floor(placed.world_pos.z / chunk_stride)))
			if placed_coord == coord:
				var local_pos = placed.world_pos - chunk_world_pos
				local_pos.y += grass_y_offset

				var t = grass_base_transform
				t = t.rotated(Vector3.UP, placed.rotation)
				t = t.scaled(Vector3(placed.scale, placed.scale, placed.scale))
				t.origin = local_pos

				var grass_index = grass_list.size()
				grass_list.append(_make_vegetation_generated(
					placed.world_pos,
					local_pos,
					placed.world_pos,
					placed.rotation,
					0.0,
					grass_index,
					placed.scale,
					true,
					t
				))

		_sync_multimesh_from_instances(mmi, grass_list, chunk_stride)

		# Store data even when the render node is data-only under global batching.
		_attach_chunk_multimesh(mmi, chunk_node)

		chunk_grass_data[coord] = {
			"multimesh": mmi,
			"grass_list": grass_list,
			"chunk_node": chunk_node
		}
		return

	var batch_idx = 0

	for x in range(0, chunk_stride, step):
		for z in range(0, chunk_stride, step):
			var gx = chunk_origin_x + x
			var gz = chunk_origin_z + z

			if _is_spawn_blocked_by_road(gx, gz):
				if not batch_heights.is_empty():
					batch_idx += 1
				continue

			# Default mode: use noise for patchy distribution
			# Dense mode: skip noise check for even distribution everywhere
			if not dense_grass_mode:
				var noise_val = grass_noise.get_noise_2d(gx, gz)
				if noise_val < 0.3:
					# Skip index if using batch (sync index)
					if not batch_heights.is_empty(): batch_idx += 1
					continue

			# Use optimized chunk density lookup
			var terrain_y = -1000.0
			if not batch_heights.is_empty():
				if batch_idx < batch_heights.size():
					terrain_y = batch_heights[batch_idx]
				batch_idx += 1
			else:
				# Slow fallback
				terrain_y = terrain_manager.get_chunk_surface_height(Vector3i(coord.x, 0, coord.y), x, z)

			if terrain_y < -100.0: # No terrain found
				continue

			var hit_pos = Vector3(gx, terrain_y, gz)

			# Skip if this grass was previously removed
			var pos_hash = _position_hash(hit_pos)
			if removed_grass.has(pos_hash):
				continue

			# Skip if underwater
			var water_dens = terrain_manager.get_water_density(Vector3(gx, terrain_y + 0.5, gz))
			if water_dens < 0.0:
				continue

			var local_pos = hit_pos - chunk_world_pos
			local_pos.y += grass_y_offset

			var world_pos = hit_pos
			world_pos.y += grass_y_offset

			var random_scale = randf_range(0.8, 1.2)
			var final_scale = grass_scale * random_scale
			var rotation_angle = randf() * TAU

			var t = grass_base_transform
			t = t.rotated(Vector3.UP, rotation_angle)
			t = t.scaled(Vector3(final_scale, final_scale, final_scale))
			t.origin = local_pos

			valid_transforms.append(t)

			var grass_index = valid_transforms.size() - 1
			grass_list.append(_make_vegetation_generated(
				world_pos,
				local_pos,
				hit_pos,
				rotation_angle,
				0.0,
				grass_index,
				final_scale,
				false,
				t
			))

	# Add player-placed grass for this chunk
	for placed in placed_grass:
		var placed_coord = Vector2i(int(floor(placed.world_pos.x / chunk_stride)), int(floor(placed.world_pos.z / chunk_stride)))
		if placed_coord == coord:
			var local_pos = placed.world_pos - chunk_world_pos
			local_pos.y += grass_y_offset

			var t = grass_base_transform
			t = t.rotated(Vector3.UP, placed.rotation)
			t = t.scaled(Vector3(placed.scale, placed.scale, placed.scale))
			t.origin = local_pos

			valid_transforms.append(t)

			var grass_index = valid_transforms.size() - 1
			grass_list.append(_make_vegetation_generated(
				placed.world_pos,
				local_pos,
				placed.world_pos,
				placed.rotation,
				0.0,
				grass_index,
				placed.scale,
				true,
				t
			))

	_sync_multimesh_from_instances(mmi, grass_list, chunk_stride)

	# Store data even when the render node is data-only under global batching.
	_attach_chunk_multimesh(mmi, chunk_node)

	chunk_grass_data[coord] = {
		"multimesh": mmi,
		"grass_list": grass_list,
		"chunk_node": chunk_node
	}

func harvest_grass_by_collider(collider: Node) -> bool:
	# Check if collider is still valid (not freed)
	if not is_instance_valid(collider):
		return false

	if not collider.has_meta("grass_coord"):
		return false

	var coord = collider.get_meta("grass_coord")
	var grass_index = collider.get_meta("grass_index")

	if not chunk_grass_data.has(coord):
		return false

	var data = chunk_grass_data[coord]

	# Validate that data is still valid
	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		# Chunk was freed, but we can still store removal for persistence
		for grass in data.grass_list:
			if grass.index == grass_index and grass.alive:
				grass.alive = false
				var pos_hash = _position_hash(grass.world_pos)
				removed_grass[pos_hash] = true
				grass_harvested.emit(grass.world_pos)
				return true
		return false

	for grass in data.grass_list:
		if grass.index == grass_index and grass.alive:
			grass.alive = false

			# Store removal for persistence (using position hash)
			var pos_hash = _position_hash(grass.world_pos)
			removed_grass[pos_hash] = true

			grass.transform = _make_hidden_transform(grass.local_pos)
			if data.has("multimesh"):
				_sync_multimesh_from_instances(data.multimesh, data.grass_list, terrain_manager.CHUNK_STRIDE)

			# Remove collider
			var key = _grass_key(coord, grass_index)
			if active_grass_colliders.has(key):
				_return_grass_collider_to_pool(active_grass_colliders[key])
				active_grass_colliders.erase(key)

			grass_harvested.emit(grass.world_pos)
			return true

	return false

# Helper to create position hash for persistence
# NOTE: int() truncates toward zero, which could cause issues near coordinate 0
# e.g. int(-0.5) = 0, int(0.5) = 0 - these would collide!
func _position_hash(pos: Vector3) -> String:
	var hash_x = int(floor(pos.x))  # Use floor for consistent rounding
	var hash_z = int(floor(pos.z))
	return "%d_%d" % [hash_x, hash_z]

func _get_chunk_height_map(coord: Vector2i, chunk_stride: int, step: int) -> PackedFloat32Array:
	if not terrain_manager:
		return PackedFloat32Array()

	if terrain_manager.has_method("get_cached_chunk_height_map"):
		return terrain_manager.get_cached_chunk_height_map(coord, chunk_stride, step)

	var chunk_key = Vector3i(coord.x, 0, coord.y)
	if not terrain_manager.active_chunks.has(chunk_key):
		return PackedFloat32Array()

	var c_data = terrain_manager.active_chunks[chunk_key]
	if not c_data or c_data.cpu_density_terrain.is_empty():
		return PackedFloat32Array()

	if not terrain_manager.get("terrain_grid"):
		return PackedFloat32Array()

	return terrain_manager.terrain_grid.get_chunk_height_map(c_data.cpu_density_terrain, chunk_stride, step)

func _chunk_overlaps_radius(coord: Vector2i, center: Vector3, radius: float, chunk_stride: int) -> bool:
	var chunk_center_x = (coord.x + 0.5) * chunk_stride
	var chunk_center_z = (coord.y + 0.5) * chunk_stride
	var dx = center.x - chunk_center_x
	var dz = center.z - chunk_center_z
	var max_dist = radius + (chunk_stride * 0.70710678) # half diagonal of a square chunk
	return dx * dx + dz * dz <= max_dist * max_dist

func _make_vegetation_generated(
		world_pos: Vector3,
		local_pos: Vector3,
		hit_pos: Vector3,
		rotation_angle: float,
		random_scale_factor: float,
		index: int,
		scale: float,
		placed_by_player: bool = false,
		transform: Transform3D = Transform3D.IDENTITY
	):
	return {
		"world_pos": world_pos,
		"local_pos": local_pos,
		"hit_pos": hit_pos,
		"rotation_angle": rotation_angle,
		"rotation": rotation_angle,
		"random_scale_factor": random_scale_factor,
		"index": index,
		"alive": true,
		"scale": scale,
		"placed_by_player": placed_by_player,
		"transform": transform
	}

func _make_vegetation_placement(world_pos: Vector3, scale: float, rotation_angle: float):
	return {
		"world_pos": world_pos,
		"local_pos": Vector3.ZERO,
		"hit_pos": Vector3.ZERO,
		"rotation_angle": rotation_angle,
		"rotation": rotation_angle,
		"random_scale_factor": 1.0,
		"index": -1,
		"alive": true,
		"scale": scale,
		"placed_by_player": true,
		"transform": Transform3D.IDENTITY
	}

func _pick_nearest_candidates(candidates: Array[Dictionary], max_count: int) -> Array[Dictionary]:
	if candidates.is_empty() or max_count <= 0:
		return []

	var native := _get_native_helper()
	if native and native.has_method("pick_nearest_candidates"):
		var native_selected: Array = native.pick_nearest_candidates(candidates, max_count)
		if not native_selected.is_empty():
			var typed_selected: Array[Dictionary] = []
			typed_selected.assign(native_selected)
			return typed_selected
		if candidates.is_empty():
			return []

	var selected: Array[Dictionary] = []
	for item in candidates:
		if selected.size() < max_count:
			var inserted := false
			for i in range(selected.size()):
				if item.dist_sq < selected[i].dist_sq:
					selected.insert(i, item)
					inserted = true
					break
			if not inserted:
				selected.append(item)
			continue

		if item.dist_sq >= selected[selected.size() - 1].dist_sq:
			continue

		var inserted = false
		for i in range(selected.size()):
			if item.dist_sq < selected[i].dist_sq:
				selected.insert(i, item)
				inserted = true
				break
		if not inserted:
			selected.append(item)
		if selected.size() > max_count:
			selected.resize(max_count)

	return selected

func place_grass(world_pos: Vector3) -> bool:
	# Find which chunk this position belongs to
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var coord = Vector2i(floor(world_pos.x / chunk_stride), floor(world_pos.z / chunk_stride))

	var random_scale = randf_range(0.8, 1.2)
	var final_scale = grass_scale * random_scale
	var rotation_angle = randf() * TAU

	# Always store for persistence first
	placed_grass.append(_make_vegetation_placement(world_pos, final_scale, rotation_angle))
	# Store for persistence

	# Check if we can place immediately
	if not chunk_grass_data.has(coord):
		# Chunk grass data not ready - queue for retry
		pending_grass_placements.append(_make_vegetation_placement(world_pos, final_scale, rotation_angle))
		_wake_process_loop()
		return true # Stored for later

	var data = chunk_grass_data[coord]

	# Validate chunk_node
	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		# Chunk node not valid - queue for retry
		pending_grass_placements.append(_make_vegetation_placement(world_pos, final_scale, rotation_angle))
		_wake_process_loop()
		return true # Stored for later

	var chunk_node = data.chunk_node
	var chunk_world_pos = chunk_node.global_position
	var local_pos = world_pos - chunk_world_pos
	local_pos.y += grass_y_offset

	var t = grass_base_transform
	t = t.rotated(Vector3.UP, rotation_angle)
	t = t.scaled(Vector3(final_scale, final_scale, final_scale))
	t.origin = local_pos

	# Add to the chunk render data and mark the real render batch dirty.
	if not data.has("multimesh") or not _is_chunk_multimesh_handle_valid(data.multimesh):
		# MultiMesh not valid - queue for retry
		pending_grass_placements.append(_make_vegetation_placement(world_pos, final_scale, rotation_angle))
		_wake_process_loop()
		return true # Stored for later

	var grass_entry = _make_vegetation_generated(
		world_pos + Vector3(0, grass_y_offset, 0),
		local_pos,
		world_pos,
		rotation_angle,
		0.0,
		data.grass_list.size(),
		final_scale,
		true,
		t
	)
	data.grass_list.append(grass_entry)
	_sync_multimesh_from_instances(data.multimesh, data.grass_list, chunk_stride)
	return true

func _add_grass_to_chunk(world_pos: Vector3, final_scale: float, rotation_angle: float, coord: Vector2i) -> bool:
	"""Helper to add a grass instance to an existing chunk."""
	if not chunk_grass_data.has(coord):
		return false

	var data = chunk_grass_data[coord]

	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		return false

	if not data.has("multimesh") or not _is_chunk_multimesh_handle_valid(data.multimesh):
		return false

	var chunk_node = data.chunk_node
	var chunk_world_pos = chunk_node.global_position
	var local_pos = world_pos - chunk_world_pos
	local_pos.y += grass_y_offset

	var t = grass_base_transform
	t = t.rotated(Vector3.UP, rotation_angle)
	t = t.scaled(Vector3(final_scale, final_scale, final_scale))
	t.origin = local_pos

	var grass_entry = _make_vegetation_generated(
		world_pos + Vector3(0, grass_y_offset, 0),
		local_pos,
		world_pos,
		rotation_angle,
		0.0,
		data.grass_list.size(),
		final_scale,
		true,
		t
	)
	data.grass_list.append(grass_entry)
	_sync_multimesh_from_instances(data.multimesh, data.grass_list, terrain_manager.CHUNK_STRIDE)
	return true

# ========== ROCK SPAWNING AND HARVESTING ==========

func _place_rocks_for_chunk(coord: Vector2i, chunk_node: Node3D):
	if not rock_mesh:
		return

	var mmi = _create_chunk_multimesh_handle("rock", coord, rock_mesh)

	var rock_list: Array = []
	var valid_transforms = []
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var chunk_origin_x = coord.x * chunk_stride
	var chunk_origin_z = coord.y * chunk_stride
	var chunk_world_pos = chunk_node.global_position

	# Use density lookup instead of physics raycasting (much faster)
	# Sparse rocks - every 7 meters (less frequent than grass)
	var step = 7
	var batch_heights = _get_chunk_height_map(coord, chunk_stride, step)
	var native := _get_native_helper()
	if native and native.has_method("build_vegetation_instances") and not batch_heights.is_empty() and not terrain_manager.world_map_active:
		var native_config := _build_vegetation_native_config(
			chunk_stride,
			step,
			chunk_origin_x,
			chunk_origin_z,
			chunk_world_pos,
			rock_base_transform,
			Vector3.ZERO,
			road_clearance,
			terrain_manager.procedural_roads_enabled,
			terrain_manager.procedural_road_spacing,
			terrain_manager.procedural_road_width,
			terrain_manager.world_map_active,
			terrain_manager.water_level,
			_build_vegetation_noise_samples(rock_noise, chunk_origin_x, chunk_origin_z, chunk_stride, step, true),
			int(rock_noise.seed),
			float(rock_noise.frequency),
			0.35,
			0.6,
			1.4,
			rock_scale,
			rock_y_offset,
			true,
			true,
			false
		)
		var native_records: Array = _build_native_vegetation_instances(batch_heights, native_config)
		_append_native_generated_instances(rock_list, native_records)

		# Add player-placed rocks for this chunk
		for placed in placed_rocks:
			var placed_coord = Vector2i(int(floor(placed.world_pos.x / chunk_stride)), int(floor(placed.world_pos.z / chunk_stride)))
			if placed_coord == coord:
				var local_pos = placed.world_pos - chunk_world_pos
				local_pos.y += rock_y_offset

				var t = rock_base_transform
				t = t.rotated(Vector3.UP, placed.rotation)
				t = t.scaled(Vector3(placed.scale, placed.scale, placed.scale))
				t.origin = local_pos

				var rock_index = rock_list.size()
				rock_list.append(_make_vegetation_generated(
					placed.world_pos,
					local_pos,
					placed.world_pos,
					placed.rotation,
					0.0,
					rock_index,
					placed.scale,
					true,
					t
				))

		_sync_multimesh_from_instances(mmi, rock_list, chunk_stride)

		# Store data even when the render node is data-only under global batching.
		_attach_chunk_multimesh(mmi, chunk_node)

		chunk_rock_data[coord] = {
			"multimesh": mmi,
			"rock_list": rock_list,
			"chunk_node": chunk_node
		}
		return

	var batch_idx = 0

	for x in range(0, chunk_stride, step):
		for z in range(0, chunk_stride, step):
			var gx = chunk_origin_x + x
			var gz = chunk_origin_z + z

			if _is_spawn_blocked_by_road(gx, gz):
				if not batch_heights.is_empty():
					batch_idx += 1
				continue

			var noise_val = rock_noise.get_noise_2d(gx, gz)
			if noise_val < 0.35: # Slightly higher threshold than grass
				if not batch_heights.is_empty():
					batch_idx += 1
				continue

			# Use optimized chunk density lookup
			var terrain_y = -1000.0
			if not batch_heights.is_empty():
				if batch_idx < batch_heights.size():
					terrain_y = batch_heights[batch_idx]
				batch_idx += 1
			else:
				terrain_y = terrain_manager.get_chunk_surface_height(Vector3i(coord.x, 0, coord.y), x, z)
			if terrain_y < -100.0: # No terrain found
				continue

			var hit_pos = Vector3(gx, terrain_y, gz)

			# Skip if this rock was previously removed
			var pos_hash = _position_hash(hit_pos)
			if removed_rocks.has(pos_hash):
				continue

			# Skip if underwater
			var water_dens = terrain_manager.get_water_density(Vector3(gx, terrain_y + 0.5, gz))
			if water_dens < 0.0:
				continue

			# Note: Slope check removed since we no longer have normal data
			# Rocks can appear on any terrain now

			var local_pos = hit_pos - chunk_world_pos
			local_pos.y += rock_y_offset

			var world_pos = hit_pos
			world_pos.y += rock_y_offset

			var random_scale = randf_range(0.6, 1.4)
			var final_scale = rock_scale * random_scale
			var rotation_angle = randf() * TAU

			var t = rock_base_transform
			t = t.rotated(Vector3.UP, rotation_angle)
			t = t.scaled(Vector3(final_scale, final_scale, final_scale))
			t.origin = local_pos

			valid_transforms.append(t)

			var rock_index = valid_transforms.size() - 1
			rock_list.append(_make_vegetation_generated(
				world_pos,
				local_pos,
				hit_pos,
				rotation_angle,
				0.0,
				rock_index,
				final_scale,
				false,
				t
			))

	# Add player-placed rocks for this chunk
	for placed in placed_rocks:
		var placed_coord = Vector2i(int(floor(placed.world_pos.x / chunk_stride)), int(floor(placed.world_pos.z / chunk_stride)))
		if placed_coord == coord:
			var local_pos = placed.world_pos - chunk_world_pos
			local_pos.y += rock_y_offset

			var t = rock_base_transform
			t = t.rotated(Vector3.UP, placed.rotation)
			t = t.scaled(Vector3(placed.scale, placed.scale, placed.scale))
			t.origin = local_pos

			valid_transforms.append(t)

			var rock_index = valid_transforms.size() - 1
			rock_list.append(_make_vegetation_generated(
				placed.world_pos,
				local_pos,
				placed.world_pos,
				placed.rotation,
				0.0,
				rock_index,
				placed.scale,
				true,
				t
			))

	_sync_multimesh_from_instances(mmi, rock_list, chunk_stride)


	# Store data even when the render node is data-only under global batching.
	_attach_chunk_multimesh(mmi, chunk_node)

	chunk_rock_data[coord] = {
		"multimesh": mmi,
		"rock_list": rock_list,
		"chunk_node": chunk_node
	}

func harvest_rock_by_collider(collider: Node) -> bool:
	if not is_instance_valid(collider):
		return false

	if not collider.has_meta("rock_coord"):
		return false

	var coord = collider.get_meta("rock_coord")
	var rock_index = collider.get_meta("rock_index")

	if not chunk_rock_data.has(coord):
		return false

	var data = chunk_rock_data[coord]

	# Validate that data is still valid
	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		# Chunk was freed, but we can still store removal for persistence
		for rock in data.rock_list:
			if rock.index == rock_index and rock.alive:
				rock.alive = false
				var pos_hash = _position_hash(rock.world_pos)
				removed_rocks[pos_hash] = true
				rock_harvested.emit(rock.world_pos)
				return true
		return false

	for rock in data.rock_list:
		if rock.index == rock_index and rock.alive:
			rock.alive = false

			# Store removal for persistence
			var pos_hash = _position_hash(rock.world_pos)
			removed_rocks[pos_hash] = true

			rock.transform = _make_hidden_transform(rock.local_pos)
			if data.has("multimesh"):
				_sync_multimesh_from_instances(data.multimesh, data.rock_list, terrain_manager.CHUNK_STRIDE)

			var key = _rock_key(coord, rock_index)
			if active_rock_colliders.has(key):
				_return_rock_collider_to_pool(active_rock_colliders[key])
				active_rock_colliders.erase(key)

			rock_harvested.emit(rock.world_pos)
			return true

	return false

func place_rock(world_pos: Vector3) -> bool:
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var coord = Vector2i(int(floor(world_pos.x / chunk_stride)), int(floor(world_pos.z / chunk_stride)))

	var random_scale = randf_range(0.6, 1.4)
	var final_scale = rock_scale * random_scale
	var rotation_angle = randf() * TAU

	# Always store for persistence first
	placed_rocks.append(_make_vegetation_placement(world_pos, final_scale, rotation_angle))
	# Store for persistence

	# Check if we can place immediately
	if not chunk_rock_data.has(coord):
		# Chunk rock data not ready - queue for retry
		pending_rock_placements.append(_make_vegetation_placement(world_pos, final_scale, rotation_angle))
		_wake_process_loop()
		return true

	var data = chunk_rock_data[coord]

	# Validate chunk_node
	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		# Chunk node not valid - queue for retry
		pending_rock_placements.append(_make_vegetation_placement(world_pos, final_scale, rotation_angle))
		_wake_process_loop()
		return true

	# Validate render data
	if not data.has("multimesh") or not _is_chunk_multimesh_handle_valid(data.multimesh):
		# MultiMesh not valid - queue for retry
		pending_rock_placements.append(_make_vegetation_placement(world_pos, final_scale, rotation_angle))
		_wake_process_loop()
		return true

	# Can place immediately
	if _add_rock_to_chunk(world_pos, final_scale, rotation_angle, coord):
		return true

	return true

func _add_rock_to_chunk(world_pos: Vector3, final_scale: float, rotation_angle: float, coord: Vector2i) -> bool:
	"""Helper to add a rock instance to an existing chunk."""
	if not chunk_rock_data.has(coord):
		return false

	var data = chunk_rock_data[coord]

	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		return false

	if not data.has("multimesh") or not _is_chunk_multimesh_handle_valid(data.multimesh):
		return false

	var chunk_node = data.chunk_node
	var chunk_world_pos = chunk_node.global_position
	var local_pos = world_pos - chunk_world_pos
	local_pos.y += rock_y_offset

	var t = rock_base_transform
	t = t.rotated(Vector3.UP, rotation_angle)
	t = t.scaled(Vector3(final_scale, final_scale, final_scale))
	t.origin = local_pos

	var rock_entry = _make_vegetation_generated(
		world_pos + Vector3(0, rock_y_offset, 0),
		local_pos,
		world_pos,
		rotation_angle,
		0.0,
		data.rock_list.size(),
		final_scale,
		true,
		t
	)
	data.rock_list.append(rock_entry)
	_sync_multimesh_from_instances(data.multimesh, data.rock_list, terrain_manager.CHUNK_STRIDE)
	return true

func load_tree_mesh_from_glb(path: String) -> Dictionary:
	if _loaded_model_cache.has(path):
		return _loaded_model_cache[path]

	var scene = load(path)
	if scene == null:
		push_error("Could not load GLB: " + path)
		return {"mesh": null, "transform": Transform3D()}

	var instance = scene.instantiate()
	var result = find_mesh_and_transform_in_node(instance, Transform3D.IDENTITY)
	if instance:
		instance.free()

	if result.mesh:
		_loaded_model_cache[path] = result

	return result

func find_mesh_and_transform_in_node(node: Node, parent_transform: Transform3D = Transform3D.IDENTITY) -> Dictionary:
	var current_transform := parent_transform
	if node is Node3D:
		current_transform = parent_transform * (node as Node3D).transform

	if node is MeshInstance3D:
		return {"mesh": node.mesh, "transform": current_transform}

	for child in node.get_children():
		var result = find_mesh_and_transform_in_node(child, current_transform)
		if result.mesh:
			return result

	return {"mesh": null, "transform": Transform3D()}

func create_basic_tree_mesh() -> Mesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var trunk_mat = StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.5, 0.2, 0.0)
	st.set_material(trunk_mat)

	var trunk_height = 5.0
	var trunk_radius = 0.5

	for i in range(8):
		var angle1 = float(i) / 8.0 * PI * 2.0
		var angle2 = float(i + 1) / 8.0 * PI * 2.0
		var p1 = Vector3(cos(angle1) * trunk_radius, 0, sin(angle1) * trunk_radius)
		var p2 = Vector3(cos(angle2) * trunk_radius, 0, sin(angle2) * trunk_radius)
		var p3 = Vector3(cos(angle2) * trunk_radius, trunk_height, sin(angle2) * trunk_radius)
		var p4 = Vector3(cos(angle1) * trunk_radius, trunk_height, sin(angle1) * trunk_radius)
		st.add_vertex(p1)
		st.add_vertex(p2)
		st.add_vertex(p3)
		st.add_vertex(p1)
		st.add_vertex(p3)
		st.add_vertex(p4)

	var leaves_mat = StandardMaterial3D.new()
	leaves_mat.albedo_color = Color(0.0, 0.5, 0.1)
	st.set_material(leaves_mat)

	var leaves_height = 7.0
	var leaves_radius = 3.0
	var leaves_base_y = trunk_height * 0.8

	for i in range(8):
		var angle1 = float(i) / 8.0 * PI * 2.0
		var angle2 = float(i + 1) / 8.0 * PI * 2.0
		var p1 = Vector3(cos(angle1) * leaves_radius, leaves_base_y, sin(angle1) * leaves_radius)
		var p2 = Vector3(cos(angle2) * leaves_radius, leaves_base_y, sin(angle2) * leaves_radius)
		var p_top = Vector3(0, leaves_base_y + leaves_height, 0)
		st.add_vertex(p1)
		st.add_vertex(p2)
		st.add_vertex(p_top)

	st.index()
	return st.commit()

func create_basic_grass_mesh() -> Mesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var grass_mat = StandardMaterial3D.new()
	grass_mat.albedo_color = Color(0.2, 0.6, 0.1)
	grass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(grass_mat)

	var height = 0.5
	var width = 0.2

	# Simple quad for grass blade
	st.add_vertex(Vector3(-width / 2, 0, 0))
	st.add_vertex(Vector3(width / 2, 0, 0))
	st.add_vertex(Vector3(0, height, 0))

	st.index()
	return st.commit()

func create_basic_rock_mesh() -> Mesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var rock_mat = StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.4, 0.4, 0.4)
	st.set_material(rock_mat)

	# Simple octahedron for rock shape
	var size = 0.3
	var top = Vector3(0, size, 0)
	var bottom = Vector3(0, -size * 0.5, 0)
	var front = Vector3(0, 0, size)
	var back = Vector3(0, 0, -size)
	var left = Vector3(-size, 0, 0)
	var right = Vector3(size, 0, 0)

	# Top half
	st.add_vertex(top); st.add_vertex(front); st.add_vertex(right)
	st.add_vertex(top); st.add_vertex(right); st.add_vertex(back)
	st.add_vertex(top); st.add_vertex(back); st.add_vertex(left)
	st.add_vertex(top); st.add_vertex(left); st.add_vertex(front)

	# Bottom half
	st.add_vertex(bottom); st.add_vertex(right); st.add_vertex(front)
	st.add_vertex(bottom); st.add_vertex(back); st.add_vertex(right)
	st.add_vertex(bottom); st.add_vertex(left); st.add_vertex(back)
	st.add_vertex(bottom); st.add_vertex(front); st.add_vertex(left)

	st.index()
	return st.commit()
## Save/Load persistence for vegetation state
func get_save_data() -> Dictionary:
	# Collect all chopped trees from active chunks
	var all_chopped: Array = []
	for coord in chunk_tree_data:
		var data = chunk_tree_data[coord]
		for tree in data.trees:
			if not tree.alive:
				# Store as position hash
				var key = _position_hash(tree.world_pos)
				all_chopped.append(key)
	# Also include previously stored chopped trees (from unloaded chunks)
	for key in chopped_trees:
		if key not in all_chopped:
			all_chopped.append(key)

	return {
		"removed_grass": removed_grass.keys(),
		"removed_rocks": removed_rocks.keys(),
		"chopped_trees": all_chopped,
		"placed_grass": _serialize_placed_list(placed_grass),
		"placed_rocks": _serialize_placed_list(placed_rocks)
	}

func load_save_data(data: Dictionary):
	if data.has("removed_grass"):
		removed_grass.clear()
		for key in data.removed_grass:
			removed_grass[key] = true

	if data.has("removed_rocks"):
		removed_rocks.clear()
		for key in data.removed_rocks:
			removed_rocks[key] = true

	if data.has("chopped_trees"):
		chopped_trees.clear()
		for key in data.chopped_trees:
			chopped_trees[key] = true
		# Apply to currently loaded trees
		_apply_chopped_trees()

	if data.has("placed_grass"):
		placed_grass.clear()
		for g in data.placed_grass:
			placed_grass.append(_make_vegetation_placement(
				Vector3(g.world_pos[0], g.world_pos[1], g.world_pos[2]),
				g.get("scale", 1.0),
				g.get("rotation", 0.0)
			))

	if data.has("placed_rocks"):
		placed_rocks.clear()
		for r in data.placed_rocks:
			placed_rocks.append(_make_vegetation_placement(
				Vector3(r.world_pos[0], r.world_pos[1], r.world_pos[2]),
				r.get("scale", 1.0),
				r.get("rotation", 0.0)
			))


	# DEFERRED: Set flag to regenerate vegetation when terrain is fully ready
	# This is triggered by spawn_zones_ready signal (after terrain modifications applied)
	pending_vegetation_regen = true

## Called when terrain confirms spawn zones are ready (after modifications applied)
func _on_spawn_zones_ready(_positions: Array) -> void:
	if pending_vegetation_regen:
		pending_vegetation_regen = false
		is_initial_load_batch = true
		initial_load_count = pending_chunks.size()

		# If queue is empty, signal ready now
		if initial_load_count <= 0:
			all_vegetation_ready.emit()
			is_initial_load_batch = false
		else:
			_wake_process_loop()

func _apply_chopped_trees():
	# Mark trees as dead based on chopped_trees dictionary
	for coord in chunk_tree_data:
		var data = chunk_tree_data[coord]
		var chunk_dirty := false
		for tree in data.trees:
			var key = _position_hash(tree.world_pos)
			if chopped_trees.has(key) and tree.alive:
				tree.alive = false
				tree.transform = _make_hidden_transform(tree.local_pos)
				chunk_dirty = true

		if chunk_dirty and data.has("multimesh"):
			_sync_multimesh_from_instances(data.multimesh, data.trees, terrain_manager.CHUNK_STRIDE)

func _serialize_placed_list(list: Array) -> Array:
	var result = []
	for item in list:
		result.append({
			"world_pos": [item.world_pos.x, item.world_pos.y, item.world_pos.z],
			"scale": item.scale,
			"rotation": item.rotation
		})
	return result

## Clear loaded vegetation chunk visuals/colliders without touching persistent
## chopped/removed/placed state. Used when terrain chunks are reset or relocated.
func clear_loaded_chunk_data(immediate_free: bool = false):
	# Stop all pending work
	pending_chunks.clear()
	pending_grass_placements.clear()
	pending_rock_placements.clear()
	pending_collider_adds.clear()
	pending_collider_removes.clear()
	keys_pending_add.clear()
	keys_pending_remove.clear()

	# Clear active visual data
	var grass_coords = chunk_grass_data.keys().duplicate()
	for coord in grass_coords:
		_cleanup_chunk_grass(coord, immediate_free)

	var rock_coords = chunk_rock_data.keys().duplicate()
	for coord in rock_coords:
		_cleanup_chunk_rocks(coord, immediate_free)

	var tree_coords = chunk_tree_data.keys().duplicate()
	for coord in tree_coords:
		_cleanup_chunk_trees(coord, immediate_free)

	_clear_global_vegetation_render_batches(immediate_free)

	if immediate_free:
		for collider in collider_pool:
			if is_instance_valid(collider):
				collider.free()
		collider_pool.clear()
		for collider in grass_collider_pool:
			if is_instance_valid(collider):
				collider.free()
		grass_collider_pool.clear()
		for collider in rock_collider_pool:
			if is_instance_valid(collider):
				collider.free()
		rock_collider_pool.clear()

		active_colliders.clear()
		active_grass_colliders.clear()
		active_rock_colliders.clear()

	# Reset states
	pending_vegetation_regen = false
	is_initial_load_batch = false
	initial_load_count = 0
	_sync_process_loop()


## Clear all internal vegetation data for a fresh start (e.g. before loading a save)
func clear_all_data(immediate_free: bool = false):
	clear_loaded_chunk_data(immediate_free)

	# Clear persistent tracking
	removed_grass.clear()
	removed_rocks.clear()
	chopped_trees.clear()
	placed_grass.clear()
	placed_rocks.clear()
