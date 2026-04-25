extends Node3D

signal chunk_generated(coord: Vector3i, chunk_node: Node3D)
signal chunk_modified(coord: Vector3i, chunk_node: Node3D) # For terrain edits - vegetation stays
signal chunk_unloaded(coord: Vector3i) # Emitted when chunk is removed from world
signal spawn_zones_ready(positions: Array) # Emitted when all requested spawn zones have loaded

# 32 Voxels wide
const CHUNK_SIZE = 32
# Overlap chunks by 1 unit to prevent gaps (seams)
const CHUNK_STRIDE = CHUNK_SIZE - 1
const DENSITY_GRID_SIZE = 33 # 0..32
const EXCAVATION_MASK_POINT_COUNT = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE
const EXCAVATION_MASK_UINT_COUNT = int(ceil(float(EXCAVATION_MASK_POINT_COUNT) / 32.0))
const EXCAVATION_MASK_BYTE_COUNT = EXCAVATION_MASK_UINT_COUNT * 4
const WorldMapData = preload("res://world_map_data/world_map_data.gd")

# Y-layer limits for vertical chunk stacking
const MIN_Y_LAYER = -20 # How deep you can dig (in chunk layers)
const MAX_Y_LAYER = 40 # How high you can build (in chunk layers)

# Max triangles estimation
const MAX_TRIANGLES = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 5
const PACKED_VERTEX_UINTS = 6 # pos.xyz float32 + normal.xyz float16 + packed material payload
const LEGACY_VERTEX_FLOATS = 9
const PACKED_OUTPUT_MAGIC = 0x5041434B # "PACK"

@export var viewer: Node3D
@export var render_distance: int = 5 # Visual range
@export var terrain_height: float = 10.0
@export var water_level: float = 13.0 # Lowered to keep roads dry
@export var noise_frequency: float = 0.1
## World generation seed - same seed = same world
## Change this for different world generation
@export var world_seed: int = 12345

## Procedural Road Network (generated with terrain)
@export var procedural_roads_enabled: bool = true # Toggle to disable procedural roads
@export var procedural_road_wide_shoulders: bool = false # Toggle to enable wide terrain flattening alongside roads (for buildings)
@export var procedural_road_spacing: float = 100.0 # Distance between roads
@export var procedural_road_width: float = 8.0 # Width of roads
@export var debug_show_road_zones: bool = false # Debug: show road alignment (Yellow=correct, Red=spillover, Green=crack)

## World Map Editor Integration
## When set, the terrain reads height/biome/road data from PNGs instead of procedural noise
@export var world_definition_path: String = ""
@export var world_map_data_cache_enabled: bool = true # Toggle cached world-map loads
var world_map_active: bool = false
var world_map_size: float = 2048.0
var world_map_half: float = 1024.0
var world_map_max_height: float = 50.0  # terrain_height * 2.5
var _world_map_heightmap_buf: RID = RID()
var _world_map_biome_buf: RID = RID()
var _world_map_road_buf: RID = RID()
var _world_map_water_buf: RID = RID()
var _world_map_empty_excavation_buf: RID = RID()
var _world_map_road_image: Image = null
var _world_map_set1: RID = RID()  # Uniform set 1 for terrain shader world map bindings
var _world_map_water_set1: RID = RID()  # Uniform set 1 for water shader
var _world_map_buildings: Array = []  # Baked building positions from world_meta.json
var _world_map_building_map: Image = null  # R8 building footprint map from buildings.png
var _world_map_excavation_masks: Dictionary = {}
var _world_map_excavation_buffers: Dictionary = {}
var gpu_biome_map: PackedByteArray = PackedByteArray()  # GPU-generated biome map for minimap (uses same fbm() as shader)

# GPU Threading (single thread for compute shaders)
var compute_thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var exit_thread: bool = false

# CPU Worker Pool (for mesh building and collision)
# Dynamically scale workers based on available CPU cores (leave 2 for OS/Main Thread)
var _cpu_worker_count: int = max(2, OS.get_processor_count() - 2)
var cpu_threads: Array[Thread] = []
var cpu_task_queue: Array[Dictionary] = []
var cpu_mutex: Mutex
var cpu_semaphore: Semaphore

# Task queues (GPU tasks)
# Priority work stays separate so modifications and spawn requests do not
# shift large arrays behind background chunk generation.
var priority_task_queue: Array[Dictionary] = []
var task_queue: Array[Dictionary] = []

# Batching for synchronized updates
var modification_batch_id: int = 0
var pending_batches: Dictionary = {}

# Shaders (SPIR-V Data)
var shader_gen_spirv: RDShaderSPIRV
var shader_gen_water_spirv: RDShaderSPIRV # New
var shader_mod_spirv: RDShaderSPIRV
var shader_mesh_spirv: RDShaderSPIRV

var material_terrain: Material
var material_water: Material
var _material_texture_builder: Object = null
var _cached_vehicle_manager: Node = null
var _cached_building_manager: Node = null
var _cached_prefab_spawner: Node = null

class ChunkData:
	var node_terrain: Node3D
	var node_water: Node3D
	var density_buffer_terrain: RID
	var density_buffer_water: RID
	var material_buffer_terrain: RID # Material IDs per voxel (GPU)

	# Terrain collision can be represented either by a live PhysicsServer RID
	# or by a StaticBody3D + CollisionShape3D when the chunk has been modified.
	var body_rid_terrain: RID

	var collision_shape_terrain: CollisionShape3D # For dynamic enable/disable
	var terrain_shape: Shape3D # Store the shape for lazy creation
	# CPU mirrors for physics detection
	var cpu_density_water: PackedFloat32Array = PackedFloat32Array()
	var cpu_density_terrain: PackedFloat32Array = PackedFloat32Array()
	# CPU mirror for materials (for 3D texture creation)
	var cpu_material_terrain: PackedByteArray = PackedByteArray()
	# 3D texture for fragment shader sampling
	var material_texture: ImageTexture3D = null
	var chunk_material: ShaderMaterial = null # Per-chunk material instance
	# Modification version - incremented on each modify, used to skip stale updates
	var mod_version: int = 0

var active_chunks: Dictionary = {}

# Collision distance - only enable collision within this range (cheaper than render_distance)
@export var collision_distance: int = 3 # Chunks within this get collision

# Time-budgeted node creation - prevents stutters from multiple chunks completing at once
var pending_nodes: Array[Dictionary] = [] # Queue of completed chunks waiting for node creation
var pending_nodes_mutex: Mutex
var pending_nodes_needs_sort: bool = false

# Time-distributed finalization - spreads chunk appearances evenly over time
var last_finalization_time_ms: int = 0
## Minimum time between chunk finalizations (ms). Lower = faster loading, Higher = smoother appearance.
## 100ms = max 10 chunks/second for very smooth visual spread.
@export_range(0, 5000, 10) var min_finalization_interval_ms: int = 100

# Two-phase loading system
# Phase 1 (Initial Load): Fast/aggressive at game start for loading screen
# Phase 2 (Exploration): Slower/throttled when player explores
var initial_load_phase: bool = true
var initial_load_target_chunks: int = 0 # Calculated at startup based on render_distance
var chunks_loaded_initial: int = 0
var underground_load_triggered: bool = false # Track if Y=-1 burst load has been done

## Delay between chunk generation during initial game load (ms).
## Initial load ends after ~π×render_distance² chunks (e.g., ~78 chunks for render_distance=5).
## Set to 0 for fastest loading. Higher values = slower but smoother loading.
@export_range(0, 100, 1) var initial_load_delay_ms: int = 0

## Delay between chunk generation when player is exploring (ms).
## Higher values reduce FPS drops but make terrain load slower as you move.
## Recommended: 100-200ms for smooth exploration.
@export_range(0, 6000, 10) var exploration_delay_ms: int = 300

# Adaptive loading - throttles based on current FPS
var target_fps: float = 75.0
var min_acceptable_fps: float = 45.0
var current_fps: float = 60.0
var fps_samples: Array[float] = []
var fps_sample_sum: float = 0.0
var adaptive_frame_budget_ms: float = 1.0 # Dynamically adjusted (reduced for smoother FPS)
var chunks_per_frame_limit: int = 2 # Dynamically adjusted
var loading_paused: bool = false
@export_range(1, 64, 1) var terrain_unload_budget_per_frame: int = 8
@export_range(0, 5, 1) var terrain_hot_frame_backoff_frames: int = 2
var _last_frame_ms: float = 0.0
var _hot_frame_backoff_remaining_frames: int = 0
var skip_terrain_chunk_updates_for_test: bool = false
var terrain_grid = null
var _native_backends_ready: bool = false
var _last_update_loads: int = 0
var _last_update_unloads: int = 0
var _last_update_backend: String = ""
var _last_terrain_finalization_defer_reason: String = ""
var _last_update_duration_ms: float = 0.0
var _last_pending_node_process_ms: float = 0.0
var _last_finalize_terrain_ms: float = 0.0
var _last_finalize_water_ms: float = 0.0
var _last_chunk_update_ms: float = 0.0
var _last_modify_terrain_ms: float = 0.0
var _last_world_map_entry_ms: float = 0.0
var _last_world_map_load_profile: Dictionary = {}
var _startup_world_map_data: Dictionary = {}
var _startup_world_map_load_profile: Dictionary = {}


# Persistent modification storage - survives chunk unloading
# Format: coord (Vector2i) -> Array of { brush_pos: Vector3, radius: float, value: float, shape: int, layer: int }
var stored_modifications: Dictionary = {}
var _world_map_terrain_modifications: Dictionary = {}

# Spawn zone tracking - positions waiting for terrain to load
# Format: Array of { "position": Vector3, "radius": int, "pending_coords": Array[Vector3i] }
var pending_spawn_zones: Array = []

func _ready():
	mutex = Mutex.new()
	semaphore = Semaphore.new()
	pending_nodes_mutex = Mutex.new()
	cpu_mutex = Mutex.new()
	cpu_semaphore = Semaphore.new()

	if not viewer:
		viewer = get_tree().get_first_node_in_group("player")
		if not viewer:
			viewer = get_node_or_null("../CharacterBody3D")

	if not viewer:
		push_warning("Viewer NOT found! Terrain generation will not start.")

	# Native backends are required.
	if not ClassDB.class_exists("MeshBuilder"):
		push_error("[ChunkManager] MeshBuilder GDExtension is required.")
		return

	if not ClassDB.class_exists("TerrainGrid"):
		push_error("[ChunkManager] TerrainGrid GDExtension is required.")
		return
	terrain_grid = ClassDB.instantiate("TerrainGrid")
	if not terrain_grid:
		push_error("[ChunkManager] Failed to instantiate TerrainGrid GDExtension.")
		return
	_native_backends_ready = true


	# Load shaders (Data only, safe on Main Thread)
	shader_gen_spirv = load("res://world_marching_cubes/gen_density.glsl").get_spirv()
	shader_gen_water_spirv = load("res://world_marching_cubes/gen_water_density.glsl").get_spirv() # New
	shader_mod_spirv = load("res://world_marching_cubes/modify_density.glsl").get_spirv()
	shader_mesh_spirv = load("res://world_marching_cubes/marching_cubes.glsl").get_spirv()

	# Setup Terrain Shader Material
	var shader = load("res://world_marching_cubes/terrain.gdshader")
	material_terrain = ShaderMaterial.new()
	material_terrain.shader = shader

	material_terrain.set_shader_parameter("texture_grass", load("res://world_marching_cubes/green-grass-texture.jpg"))
	material_terrain.set_shader_parameter("texture_rock", load("res://world_marching_cubes/rocky-texture.jpg"))
	material_terrain.set_shader_parameter("texture_stone", load("res://world_marching_cubes/stone_material.png")) # Underground/gravel
	material_terrain.set_shader_parameter("texture_sand", load("res://world_marching_cubes/sand-texture.jpg"))
	material_terrain.set_shader_parameter("texture_snow", load("res://world_marching_cubes/snow-texture.jpg") if FileAccess.file_exists("res://world_marching_cubes/snow-texture.jpg") else load("res://world_marching_cubes/rocky-texture.jpg"))
	material_terrain.set_shader_parameter("texture_road", load("res://world_marching_cubes/asphalt-texture.png"))
	material_terrain.set_shader_parameter("uv_scale", 0.5)
	material_terrain.set_shader_parameter("global_snow_amount", 0.0)
	# Procedural road texture settings (sync with density shader)
	material_terrain.set_shader_parameter("procedural_road_enabled", procedural_roads_enabled)
	material_terrain.set_shader_parameter("procedural_road_spacing", procedural_road_spacing if procedural_roads_enabled else 0.0)
	material_terrain.set_shader_parameter("procedural_road_width", procedural_road_width)
	# Terrain parameters for per-pixel material calculation (sync with gen_density.glsl)
	material_terrain.set_shader_parameter("terrain_height", terrain_height)
	material_terrain.set_shader_parameter("noise_frequency", noise_frequency)
	# Debug visualization
	material_terrain.set_shader_parameter("debug_show_road_zones", debug_show_road_zones)
	# Road mask will be set by road_manager

	# Setup Water Material
	material_water = ShaderMaterial.new()
	material_water.shader = load("res://world_marching_cubes/water.gdshader")
	# Dark green water colors
	material_water.set_shader_parameter("albedo", Color(0.05, 0.18, 0.12))
	material_water.set_shader_parameter("albedo_deep", Color(0.01, 0.06, 0.04))
	material_water.set_shader_parameter("albedo_shallow", Color(0.1, 0.3, 0.2))
	material_water.set_shader_parameter("beer_factor", 0.25)
	# Water normal texture for detailed ripples
	var water_normal = load("res://world_marching_cubes/water_texture.png")
	if water_normal:
		material_water.set_shader_parameter("water_normal_texture", water_normal)

	# Activate world map if a definition path is set (directly or via SaveManager autoload)
	if world_definition_path == "":
		# Check if SaveManager has a pending path from the World Map Generator
		var sm = Engine.get_singleton("SaveManager") if Engine.has_singleton("SaveManager") else null
		if not sm:
			sm = get_node_or_null("/root/SaveManager")
		if sm and "pending_world_definition_path" in sm and sm.pending_world_definition_path != "":
			world_definition_path = sm.pending_world_definition_path
			sm.pending_world_definition_path = ""  # Consume it
		if sm and "pending_world_map_data_cache_enabled" in sm:
			world_map_data_cache_enabled = sm.pending_world_map_data_cache_enabled

	WorldMapData.set_cache_enabled(world_map_data_cache_enabled)
	if world_definition_path != "":
		world_map_active = true
		world_map_max_height = terrain_height * 2.5
		# Disable procedural road overlay in fragment shader — world map roads
		# are controlled by the material buffer (depth-limited to 2 blocks)
		material_terrain.set_shader_parameter("procedural_road_enabled", false)
		material_terrain.set_shader_parameter("use_world_map", true)
		PrefabGeometry.clear_cache()
		# Read metadata for map params (biome blending now uses GPU fbm() directly, no texture needed)
		var startup_world_map_load_profile: Dictionary = {}
		var loaded = WorldMapData.load_world(world_definition_path, world_map_data_cache_enabled, false, startup_world_map_load_profile)
		_startup_world_map_data = loaded
		_startup_world_map_load_profile = startup_world_map_load_profile.duplicate(true)
		if loaded.has("metadata"):
			var meta = loaded.metadata
			var meta_terrain_height = float(meta.get("terrain_height", terrain_height))
			world_map_size = float(meta.get("map_size", 2048))
			world_map_half = world_map_size / 2.0
			world_map_max_height = meta_terrain_height * 2.5
			water_level = float(meta.get("water_level", meta_terrain_height + 3.0))
		# Pass world map road image as road_mask for per-pixel road edge blending
		# UV mapping: road_uv = world_pos.xz * scale + 0.5 = (world_pos.xz + half) / size
		if loaded.has("roads"):
			var rmap: Image = loaded.roads
			_world_map_road_image = rmap
			var road_tex = ImageTexture.create_from_image(rmap)
			material_terrain.set_shader_parameter("road_mask", road_tex)
			material_terrain.set_shader_parameter("road_mask_offset", Vector2(0.0, 0.0))
			material_terrain.set_shader_parameter("road_mask_scale", 1.0 / world_map_size)

	# Start GPU thread
	compute_thread = Thread.new()
	compute_thread.start(_thread_function)

	# Start CPU worker pool
	for i in range(_cpu_worker_count):
		var thread = Thread.new()
		thread.start(_cpu_thread_function)
		cpu_threads.append(thread)

	# Calculate initial load target (all chunks within render distance)
	# For ground-level players, we only load Y=0, same chunk count as before
	initial_load_target_chunks = int(PI * render_distance * render_distance)


func get_telemetry_snapshot() -> Dictionary:
	var loaded_chunk_count := 0
	var pending_chunk_count := 0
	var rendered_terrain_chunk_count := 0
	var rendered_water_chunk_count := 0
	var collision_chunk_count := 0
	var collision_ready_chunk_count := 0
	var dirty_loaded_chunk_count := 0
	var active_render_chunk_count := 0

	for coord_variant in active_chunks:
		var data_variant: Variant = active_chunks[coord_variant]
		if data_variant == null:
			pending_chunk_count += 1
			continue

		loaded_chunk_count += 1
		var data: ChunkData = data_variant
		if data.node_terrain:
			rendered_terrain_chunk_count += 1
		if data.node_water:
			rendered_water_chunk_count += 1
		if data.body_rid_terrain.is_valid():
			collision_chunk_count += 1
		if data.node_terrain or data.node_water:
			active_render_chunk_count += 1

	if terrain_grid and terrain_grid.has_method("get_collision_ready_chunk_count"):
		collision_ready_chunk_count = terrain_grid.get_collision_ready_chunk_count()

	return {
		"active_chunk_count": active_chunks.size(),
		"loaded_chunk_count": loaded_chunk_count,
		"pending_chunk_count": pending_chunk_count,
		"rendered_terrain_chunk_count": rendered_terrain_chunk_count,
		"rendered_water_chunk_count": rendered_water_chunk_count,
		"collision_chunk_count": collision_chunk_count,
		"collision_ready_chunk_count": collision_ready_chunk_count,
		"pending_terrain_collision_create_count": pending_terrain_collision_creates.size(),
		"last_terrain_collision_create_count": _last_terrain_collision_create_count,
		"last_terrain_collision_create_ms": _last_terrain_collision_create_ms,
		"loaded_dirty_chunk_count": dirty_loaded_chunk_count,
		"active_render_chunk_count": active_render_chunk_count,
		"pending_node_count": pending_nodes.size(),
		"pending_node_sort_needed": pending_nodes_needs_sort,
		"pending_batch_count": pending_batches.size(),
		"task_queue_count": _get_task_queue_count(),
		"cpu_task_queue_count": cpu_task_queue.size(),
		"pending_spawn_zone_count": pending_spawn_zones.size(),
		"stored_modification_count": stored_modifications.size(),
		"world_map_active": world_map_active,
		"render_distance": render_distance,
		"collision_distance": collision_distance,
		"initial_load_phase": initial_load_phase,
		"initial_load_target_chunks": initial_load_target_chunks,
		"chunks_loaded_initial": chunks_loaded_initial,
		"loading_paused": loading_paused,
		"current_fps": current_fps,
		"adaptive_frame_budget_ms": adaptive_frame_budget_ms,
		"chunks_per_frame_limit": chunks_per_frame_limit,
		"last_update_loads": _last_update_loads,
		"last_update_unloads": _last_update_unloads,
		"last_update_backend": _last_update_backend,
		"last_terrain_finalization_defer_reason": _last_terrain_finalization_defer_reason,
		"last_update_duration_ms": _last_update_duration_ms,
		"last_pending_node_process_ms": _last_pending_node_process_ms,
		"last_finalize_terrain_ms": _last_finalize_terrain_ms,
		"last_finalize_water_ms": _last_finalize_water_ms,
		"last_chunk_update_ms": _last_chunk_update_ms,
		"last_modify_terrain_ms": _last_modify_terrain_ms,
		"last_world_map_entry_ms": _last_world_map_entry_ms,
		"world_map_load_profile": _last_world_map_load_profile.duplicate(true),
		"hot_frame_backoff_remaining_frames": _hot_frame_backoff_remaining_frames,
		"world_map_building_count": _world_map_buildings.size(),
		"world_map_excavation_mask_count": _world_map_excavation_masks.size(),
		"world_map_excavation_buffer_count": _world_map_excavation_buffers.size(),
		"native_backends_ready": _native_backends_ready
	}


## Gets the effective viewer position for chunk loading.
## Returns vehicle position when player is driving a vehicle,
## otherwise returns the player's position.
func get_viewer_position() -> Vector3:
	if not viewer:
		return Vector3.ZERO

	# Check if player is in a vehicle
	var vm = _get_vehicle_manager()
	if vm and "current_player_vehicle" in vm and vm.current_player_vehicle:
		return vm.current_player_vehicle.global_position

	# Default: player's position
	return viewer.global_position

func _get_vehicle_manager() -> Node:
	if _cached_vehicle_manager and is_instance_valid(_cached_vehicle_manager):
		return _cached_vehicle_manager

	_cached_vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	return _cached_vehicle_manager

func _get_building_manager() -> Node:
	if _cached_building_manager and is_instance_valid(_cached_building_manager):
		return _cached_building_manager

	_cached_building_manager = get_tree().get_first_node_in_group("building_manager")
	if not _cached_building_manager:
		_cached_building_manager = get_tree().root.find_child("BuildingManager", true, false)
	return _cached_building_manager

func _get_prefab_spawner() -> Node:
	if _cached_prefab_spawner and is_instance_valid(_cached_prefab_spawner):
		return _cached_prefab_spawner

	_cached_prefab_spawner = get_tree().get_first_node_in_group("prefab_spawner")
	if not _cached_prefab_spawner:
		_cached_prefab_spawner = get_tree().root.find_child("PrefabSpawner", true, false)
	return _cached_prefab_spawner


func _get_task_queue_count() -> int:
	mutex.lock()
	var count := task_queue.size() + priority_task_queue.size()
	mutex.unlock()
	return count


func _get_cpu_task_queue_count() -> int:
	cpu_mutex.lock()
	var count := cpu_task_queue.size()
	cpu_mutex.unlock()
	return count


func _has_pending_gpu_tasks() -> bool:
	mutex.lock()
	var has_tasks := not priority_task_queue.is_empty() or not task_queue.is_empty()
	mutex.unlock()
	return has_tasks


func _pop_next_gpu_task() -> Dictionary:
	mutex.lock()
	var task: Dictionary = {}
	if not priority_task_queue.is_empty():
		task = priority_task_queue.pop_back()
	elif not task_queue.is_empty():
		task = task_queue.pop_back()
	mutex.unlock()
	return task


func _clear_gpu_task_queues() -> void:
	mutex.lock()
	priority_task_queue.clear()
	task_queue.clear()
	mutex.unlock()


func _queue_gpu_free_tasks(tasks: Array[Dictionary]) -> void:
	if tasks.is_empty() or not mutex or not semaphore:
		return

	mutex.lock()
	for t in tasks:
		task_queue.append(t)
	mutex.unlock()

	for _task in tasks:
		semaphore.post()


func _append_pending_finalization_free_tasks(item: Dictionary, cleanup_tasks: Array[Dictionary]) -> void:
	var item_type := String(item.get("type", ""))
	if item_type == "final_terrain":
		var dens_rid = item.get("dens", RID())
		if dens_rid.is_valid():
			cleanup_tasks.append({"type": "free", "rid": dens_rid})
		var mat_rid = item.get("mat_buf", RID())
		if mat_rid.is_valid():
			cleanup_tasks.append({"type": "free", "rid": mat_rid})
	elif item_type == "final_water":
		var water_rid = item.get("dens", RID())
		if water_rid.is_valid():
			cleanup_tasks.append({"type": "free", "rid": water_rid})


func _queue_pending_finalization_item_free(item: Dictionary) -> void:
	var cleanup_tasks: Array[Dictionary] = []
	_append_pending_finalization_free_tasks(item, cleanup_tasks)
	_queue_gpu_free_tasks(cleanup_tasks)


func _drain_pending_finalization_free_tasks() -> Array[Dictionary]:
	var cleanup_tasks: Array[Dictionary] = []
	if not pending_nodes_mutex:
		return cleanup_tasks

	pending_nodes_mutex.lock()
	for item in pending_nodes:
		if item is Dictionary:
			_append_pending_finalization_free_tasks(item, cleanup_tasks)
	pending_nodes.clear()
	pending_nodes_needs_sort = false
	pending_nodes_mutex.unlock()

	return cleanup_tasks


func _remove_pending_generate_tasks_for_coord(coord: Vector3i) -> void:
	mutex.lock()
	_remove_pending_generate_tasks_from_queue(priority_task_queue, coord)
	_remove_pending_generate_tasks_from_queue(task_queue, coord)
	mutex.unlock()


func _remove_pending_generate_tasks_from_queue(queue: Array[Dictionary], coord: Vector3i) -> void:
	var i := queue.size() - 1
	while i >= 0:
		var t: Dictionary = queue[i]
		if t.type == "generate" and t.coord == coord:
			queue.remove_at(i)
		i -= 1


func _capture_terrain_telemetry(event_label: String = "", details: Dictionary = {}) -> void:
	return


func _process(delta):
	if not viewer:
		return

	# Track FPS
	_update_fps_tracking(delta)
	_last_frame_ms = delta * 1000.0

	# Adjust loading based on FPS
	_adjust_adaptive_loading()

	if skip_terrain_chunk_updates_for_test:
		return

	var defer_terrain_finalization := false
	var terrain_defer_reason := ""
	if not initial_load_phase:
		var frame_budget_ms := 1000.0 / 60.0
		if _last_frame_ms > frame_budget_ms:
			_hot_frame_backoff_remaining_frames = maxi(_hot_frame_backoff_remaining_frames, terrain_hot_frame_backoff_frames)
		if _hot_frame_backoff_remaining_frames > 0:
			defer_terrain_finalization = true
			if terrain_defer_reason.is_empty():
				terrain_defer_reason = "hot_frame_backoff"
			_hot_frame_backoff_remaining_frames -= 1
	_last_terrain_finalization_defer_reason = terrain_defer_reason
	if not defer_terrain_finalization:
		update_chunks()

		process_pending_nodes()
	else:
		update_chunk_unloads_only()

	update_collision_proximity() # Enable/disable collision based on player distance
	process_pending_terrain_collision_creates()

	# HOTFIX: Ensure all existing chunks have layer 512 (Layer 10) for pickups
	if active_chunks.size() > 0 and not get_meta("collision_fixed", false):
		for coord in active_chunks:
			var data = active_chunks[coord]
			if data:
				if data.body_rid_terrain.is_valid():
					PhysicsServer3D.body_set_collision_layer(data.body_rid_terrain, 1 | 512)
				if data.node_terrain is StaticBody3D:
					data.node_terrain.collision_layer = 1 | 512
		set_meta("collision_fixed", true)

var debug_chunk_bounds: bool = false

func _unhandled_input(_event):
	pass

func set_debug_chunk_bounds(enabled: bool) -> void:
	debug_chunk_bounds = enabled
	# Update all chunk materials
	for coord in active_chunks:
		var data = active_chunks[coord]
		if data and data.chunk_material:
			data.chunk_material.set_shader_parameter("debug_show_chunk_bounds", debug_chunk_bounds)
	material_terrain.set_shader_parameter("debug_show_chunk_bounds", debug_chunk_bounds)

func set_debug_show_road_zones(enabled: bool) -> void:
	debug_show_road_zones = enabled
	# Update all chunk materials
	for coord in active_chunks:
		var data = active_chunks[coord]
		if data and data.chunk_material:
			data.chunk_material.set_shader_parameter("debug_show_road_zones", debug_show_road_zones)
	material_terrain.set_shader_parameter("debug_show_road_zones", debug_show_road_zones)


func _update_fps_tracking(delta: float):
	var instant_fps = 1.0 / delta if delta > 0 else 60.0
	if fps_samples.size() >= 30:
		fps_sample_sum -= fps_samples.pop_front()
	fps_samples.append(instant_fps)
	fps_sample_sum += instant_fps
	current_fps = fps_sample_sum / fps_samples.size()

func _adjust_adaptive_loading():
	# BOOSTED LOADING: During initial load (like save load), bypass FPS throttling
	# to ensure world generates as fast as possible regardless of temporary FPS dips
	if initial_load_phase:
		loading_paused = false
		adaptive_frame_budget_ms = 4.0 # High budget for speed
		chunks_per_frame_limit = 4    # Force multiple chunks per frame
		return

	if current_fps < min_acceptable_fps:
		# FPS is too low - pause loading completely
		loading_paused = true
		adaptive_frame_budget_ms = 0.0 # Zero work when FPS critical
		chunks_per_frame_limit = 0
	elif current_fps < target_fps:
		# FPS is below target - reduce loading with tighter budget
		loading_paused = false
		var fps_ratio = current_fps / target_fps
		adaptive_frame_budget_ms = lerp(0.25, 1.0, fps_ratio) # Tighter range
		chunks_per_frame_limit = 1
	else:
		# FPS is good - still limit to prevent stutters
		loading_paused = false
		adaptive_frame_budget_ms = 1.5 # Max 1.5ms (reduced from 3ms)
		chunks_per_frame_limit = 1

var _last_collision_center_chunk: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _last_collision_active_count: int = -1
var pending_terrain_collision_creates: Dictionary = {}
var _last_terrain_collision_create_ms: float = 0.0
var _last_terrain_collision_create_count: int = 0
@export_range(1, 16, 1) var terrain_collision_create_budget_per_frame: int = 2
func update_collision_proximity():
	var p_pos = get_viewer_position()
	var p_chunk_x = int(floor(p_pos.x / CHUNK_STRIDE))
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE))
	var p_chunk_z = int(floor(p_pos.z / CHUNK_STRIDE))
	var center_chunk = Vector3i(p_chunk_x, p_chunk_y, p_chunk_z)
	var active_count := active_chunks.size()
	if center_chunk == _last_collision_center_chunk and active_count == _last_collision_active_count:
		return
	_last_collision_center_chunk = center_chunk
	_last_collision_active_count = active_count
	var collision_distance_sq := collision_distance * collision_distance

	for coord in active_chunks:
		var data = active_chunks[coord]
		if data == null:
			continue

		var should_have_collision = _should_have_terrain_collision(coord, center_chunk, collision_distance_sq)
		_sync_terrain_collision_state(coord, data, should_have_collision)

func _should_have_terrain_collision(coord: Vector3i, center_chunk: Vector3i, collision_distance_sq: int) -> bool:
	var dx = coord.x - center_chunk.x
	var dy = coord.y - center_chunk.y
	var dz = coord.z - center_chunk.z
	var dist_xz_sq = dx * dx + dz * dz
	return dist_xz_sq <= collision_distance_sq and abs(dy) <= 2

func _queue_terrain_collision_create(coord: Vector3i) -> void:
	pending_terrain_collision_creates[coord] = true

func _sync_terrain_collision_state(coord: Vector3i, data, should_have_collision: bool) -> void:
	if data == null:
		return

	# Modified terrain chunks use a real node-based StaticBody3D, so we can
	# just toggle the shape there.
	if data.node_terrain is StaticBody3D:
		if data.collision_shape_terrain:
			var desired_disabled: bool = not should_have_collision
			if data.collision_shape_terrain.disabled != desired_disabled:
				data.collision_shape_terrain.disabled = desired_disabled
		if terrain_grid and terrain_grid.has_method("set_chunk_collision_ready"):
			terrain_grid.set_chunk_collision_ready(coord, should_have_collision and data.collision_shape_terrain != null)
		pending_terrain_collision_creates.erase(coord)
		return

	# Initial-load terrain chunks use a PhysicsServer RID so we can keep the
	# visual mesh alive while only paying collision cost when the player is near.
	# Body creation is budgeted separately so entering town does not wake the
	# entire collision neighborhood in one frame.
	if should_have_collision:
		if data.body_rid_terrain.is_valid():
			var world = get_world_3d()
			if world:
				PhysicsServer3D.body_set_space(data.body_rid_terrain, world.space)
				PhysicsServer3D.body_set_collision_layer(data.body_rid_terrain, 1 | 512)
				PhysicsServer3D.body_set_collision_mask(data.body_rid_terrain, 1)
			if terrain_grid and terrain_grid.has_method("set_chunk_collision_ready"):
				terrain_grid.set_chunk_collision_ready(coord, true)
			pending_terrain_collision_creates.erase(coord)
			return
		if not data.node_terrain or not data.terrain_shape:
			if terrain_grid and terrain_grid.has_method("set_chunk_collision_ready"):
				terrain_grid.set_chunk_collision_ready(coord, false)
			return

		_queue_terrain_collision_create(coord)
		if terrain_grid and terrain_grid.has_method("set_chunk_collision_ready"):
			terrain_grid.set_chunk_collision_ready(coord, false)
	else:
		if terrain_grid and terrain_grid.has_method("set_chunk_collision_ready"):
			terrain_grid.set_chunk_collision_ready(coord, false)
		if data.body_rid_terrain.is_valid():
			var world = get_world_3d()
			if world:
				PhysicsServer3D.body_set_space(data.body_rid_terrain, RID())
			PhysicsServer3D.body_set_collision_layer(data.body_rid_terrain, 0)
			PhysicsServer3D.body_set_collision_mask(data.body_rid_terrain, 0)
			pending_terrain_collision_creates.erase(coord)

func _terrain_collision_sort_score(coord: Vector3i, center_chunk: Vector3i) -> int:
	var dx = coord.x - center_chunk.x
	var dy = coord.y - center_chunk.y
	var dz = coord.z - center_chunk.z
	return dx * dx + dz * dz + abs(dy) * 10

func process_pending_terrain_collision_creates():
	if pending_terrain_collision_creates.is_empty():
		_last_terrain_collision_create_count = 0
		_last_terrain_collision_create_ms = 0.0
		return

	var start_us := Time.get_ticks_usec()
	var p_pos = get_viewer_position()
	var center_chunk = Vector3i(
		int(floor(p_pos.x / CHUNK_STRIDE)),
		int(floor(p_pos.y / CHUNK_STRIDE)),
		int(floor(p_pos.z / CHUNK_STRIDE))
	)
	var collision_distance_sq := collision_distance * collision_distance
	var queued_coords: Array[Vector3i] = []
	for coord_variant in pending_terrain_collision_creates.keys():
		queued_coords.append(coord_variant)
	queued_coords.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return _terrain_collision_sort_score(a, center_chunk) < _terrain_collision_sort_score(b, center_chunk)
	)

	var created := 0
	for coord in queued_coords:
		if created >= terrain_collision_create_budget_per_frame:
			break

		if not pending_terrain_collision_creates.has(coord):
			continue
		if not active_chunks.has(coord):
			pending_terrain_collision_creates.erase(coord)
			continue

		var data = active_chunks[coord]
		if data == null:
			pending_terrain_collision_creates.erase(coord)
			continue
		if data.body_rid_terrain.is_valid():
			pending_terrain_collision_creates.erase(coord)
			continue
		if not _should_have_terrain_collision(coord, center_chunk, collision_distance_sq):
			pending_terrain_collision_creates.erase(coord)
			continue
		if not data.node_terrain or not data.terrain_shape:
			continue

		var world = get_world_3d()
		if not world:
			continue

		var body_rid = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_add_shape(body_rid, data.terrain_shape.get_rid())
		PhysicsServer3D.body_set_collision_layer(body_rid, 1 | 512)
		PhysicsServer3D.body_set_collision_mask(body_rid, 1)
		PhysicsServer3D.body_set_space(body_rid, world.space)
		var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
		PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), chunk_pos))
		PhysicsServer3D.body_attach_object_instance_id(body_rid, data.node_terrain.get_instance_id())
		data.body_rid_terrain = body_rid
		if terrain_grid and terrain_grid.has_method("set_chunk_collision_ready"):
			terrain_grid.set_chunk_collision_ready(coord, true)
		pending_terrain_collision_creates.erase(coord)
		created += 1

	_last_terrain_collision_create_count = created
	_last_terrain_collision_create_ms = float(Time.get_ticks_usec() - start_us) / 1000.0

# Process pending node creations - TIME-DISTRIBUTED to eliminate burst loading
func process_pending_nodes():
	if pending_nodes.is_empty():
		return

	# Skip entirely if loading is paused due to low FPS
	if loading_paused:
		return
	var process_start_us := Time.get_ticks_usec()

	# Time-distributed: Only finalize if enough time has passed since last chunk
	# This spreads chunk appearances evenly over time instead of bursts
	var current_time = Time.get_ticks_msec()
	var time_since_last = current_time - last_finalization_time_ms

	# During initial load phase, process faster (50ms interval)
	var effective_interval = 50 if initial_load_phase else min_finalization_interval_ms

	if time_since_last < effective_interval:
		return

	pending_nodes_mutex.lock()
	if pending_nodes.is_empty():
		pending_nodes_mutex.unlock()
		return

	# Sort by distance to player (closest first) only when new items arrived.
	if pending_nodes_needs_sort:
		_sort_pending_by_distance()
		pending_nodes_needs_sort = false

	var item = pending_nodes.pop_back()
	pending_nodes_mutex.unlock()

	_finalize_chunk_creation(item)
	last_finalization_time_ms = current_time
	_last_pending_node_process_ms = float(Time.get_ticks_usec() - process_start_us) / 1000.0

# Sort pending nodes by distance to player (closest first)
func _sort_pending_by_distance():
	if pending_nodes.size() <= 1 or not viewer:
		return
	var p_pos = get_viewer_position()
	var viewer_chunk = Vector3i(
		int(floor(p_pos.x / CHUNK_STRIDE)),
		int(floor(p_pos.y / CHUNK_STRIDE)),
		int(floor(p_pos.z / CHUNK_STRIDE))
	)
	pending_nodes.sort_custom(func(a, b):
		var dist_a = (a.coord - viewer_chunk).length_squared()
		var dist_b = (b.coord - viewer_chunk).length_squared()
		return dist_a > dist_b
	)


## Get terrain density at world position (reads from CPU-cached chunk data)
## Returns positive for air, negative for solid. Returns 1.0 if chunk not loaded.
func get_terrain_density(global_pos: Vector3) -> float:
	# Find Chunk (3D coordinates)
	var chunk_x = int(floor(global_pos.x / CHUNK_STRIDE))
	var chunk_y = int(floor(global_pos.y / CHUNK_STRIDE))
	var chunk_z = int(floor(global_pos.z / CHUNK_STRIDE))
	var coord = Vector3i(chunk_x, chunk_y, chunk_z)

	if not active_chunks.has(coord):
		return 1.0 # Air (chunk not loaded)

	var data = active_chunks[coord]
	if data == null or data.cpu_density_terrain.is_empty():
		return 1.0

	# Find local position within chunk
	var chunk_origin = Vector3(chunk_x * CHUNK_STRIDE, chunk_y * CHUNK_STRIDE, chunk_z * CHUNK_STRIDE)
	var local_pos = global_pos - chunk_origin

	# Round to nearest grid point
	var ix = int(round(local_pos.x))
	var iy = int(round(local_pos.y))
	var iz = int(round(local_pos.z))

	if ix < 0 or ix >= DENSITY_GRID_SIZE or iy < 0 or iy >= DENSITY_GRID_SIZE or iz < 0 or iz >= DENSITY_GRID_SIZE:
		return 1.0 # Out of bounds

	var index = ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)

	if index >= 0 and index < data.cpu_density_terrain.size():
		var density = data.cpu_density_terrain[index]
		return density

	return 1.0

func get_water_density(global_pos: Vector3) -> float:
	# Find Chunk (3D coordinates)
	var chunk_x = int(floor(global_pos.x / CHUNK_STRIDE))
	var chunk_y = int(floor(global_pos.y / CHUNK_STRIDE))
	var chunk_z = int(floor(global_pos.z / CHUNK_STRIDE))
	var coord = Vector3i(chunk_x, chunk_y, chunk_z)

	if not active_chunks.has(coord):
		return 1.0 # Air (Positive is air, Negative is water)

	var data = active_chunks[coord]
	if data == null or data.cpu_density_water.is_empty():
		return 1.0

	# Find local position within chunk
	var chunk_origin = Vector3(chunk_x * CHUNK_STRIDE, chunk_y * CHUNK_STRIDE, chunk_z * CHUNK_STRIDE)
	var local_pos = global_pos - chunk_origin

	# Clamp to grid
	var ix = int(round(local_pos.x))
	var iy = int(round(local_pos.y))
	var iz = int(round(local_pos.z))

	if ix < 0 or ix >= DENSITY_GRID_SIZE or iy < 0 or iy >= DENSITY_GRID_SIZE or iz < 0 or iz >= DENSITY_GRID_SIZE:
		return 1.0 # Out of bounds

	var index = ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)

	if index >= 0 and index < data.cpu_density_water.size():
		return data.cpu_density_water[index]

	return 1.0

## Returns true when initial terrain chunks are visually ready (meshes created)
func is_initial_load_complete() -> bool:
	pending_nodes_mutex.lock()
	var nodes_empty = pending_nodes.is_empty()
	pending_nodes_mutex.unlock()
	return not initial_load_phase and nodes_empty

## Progress: 0.0-1.0 based on chunks loaded during initial phase
func get_loading_progress() -> float:
	if initial_load_target_chunks <= 0:
		return 1.0
	return clamp(float(chunks_loaded_initial) / initial_load_target_chunks, 0.0, 1.0)

## Get count of pending nodes waiting to be finalized (for loading screen)
func get_pending_nodes_count() -> int:
	pending_nodes_mutex.lock()
	var count = pending_nodes.size()
	pending_nodes_mutex.unlock()
	return count

## Get material ID at world position (reads from CPU-cached chunk data)
## Returns -1 if position is outside loaded chunks or no material data
func get_material_at(global_pos: Vector3) -> int:
	# Find Chunk (3D coordinates)
	var chunk_x = int(floor(global_pos.x / CHUNK_STRIDE))
	var chunk_y = int(floor(global_pos.y / CHUNK_STRIDE))
	var chunk_z = int(floor(global_pos.z / CHUNK_STRIDE))
	var coord = Vector3i(chunk_x, chunk_y, chunk_z)

	if not active_chunks.has(coord):
		return -1 # Chunk not loaded

	var data = active_chunks[coord]
	if data == null or data.cpu_material_terrain.is_empty():
		return -1 # No material data

	# Find local position within chunk
	var chunk_origin = Vector3(chunk_x * CHUNK_STRIDE, chunk_y * CHUNK_STRIDE, chunk_z * CHUNK_STRIDE)
	var local_pos = global_pos - chunk_origin

	# CRITICAL: Match GPU behavior!
	# GPU marching_cubes.glsl samples material at: pos + vec3(0.5) then uses round()
	# We use floor to find the voxel cube, which is equivalent to GPU's round(pos+0.5) = floor(pos)+1 when pos > 0.5
	# Actually, to EXACTLY match: round(local_pos) gives the nearest voxel
	var ix = int(round(local_pos.x))
	var iy = int(round(local_pos.y))
	var iz = int(round(local_pos.z))

	# Clamp to valid range (0-32)
	ix = clampi(ix, 0, DENSITY_GRID_SIZE - 1)
	iy = clampi(iy, 0, DENSITY_GRID_SIZE - 1)
	iz = clampi(iz, 0, DENSITY_GRID_SIZE - 1)

	var voxel_index = ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)

	# CRITICAL: Material buffer stores uint32 per voxel (4 bytes each)
	# We need to read the first byte of each uint32 (material ID is 0-255)
	var byte_offset = voxel_index * 4 # 4 bytes per uint

	if byte_offset >= 0 and byte_offset < data.cpu_material_terrain.size():
		return data.cpu_material_terrain[byte_offset] # First byte is the mat_id

	return -1


# Check if any Y layer at this X,Z has terrain modifications.
func has_modifications_at_xz(x: int, z: int) -> bool:
	for coord in _get_all_modification_coords():
		if coord.x == x and coord.z == z:
			return true
	return false

func is_road_at_position(global_x: float, global_z: float, road_clearance: float = 0.0) -> bool:
	if world_map_active:
		return _is_world_map_road_at_position(global_x, global_z)
	if are_procedural_roads_enabled():
		return _is_procedural_road_at_position(global_x, global_z, road_clearance)
	return false

func are_procedural_roads_enabled() -> bool:
	return procedural_roads_enabled and procedural_road_spacing > 0.0 and not world_map_active

func _is_procedural_road_at_position(global_x: float, global_z: float, road_clearance: float) -> bool:
	if procedural_road_spacing <= 0.0:
		return false

	var local_x := fposmod(global_x, procedural_road_spacing)
	var local_z := fposmod(global_z, procedural_road_spacing)
	var dist_x := minf(local_x, procedural_road_spacing - local_x)
	var dist_z := minf(local_z, procedural_road_spacing - local_z)
	var road_half_width := procedural_road_width * 0.5 + road_clearance
	return minf(dist_x, dist_z) <= road_half_width

func _procedural_road_hash(p: Vector3) -> float:
	var h = Vector3(
		p.x - floor(p.x),
		p.y - floor(p.y),
		p.z - floor(p.z)
	)
	h *= 17.0
	var value = h.x * h.y * h.z * (h.x + h.y + h.z)
	return value - floor(value)

func _procedural_road_noise(p: Vector3) -> float:
	var i = Vector3(floor(p.x), floor(p.y), floor(p.z))
	var f = Vector3(p.x - i.x, p.y - i.y, p.z - i.z)

	var f_interp = Vector3(
		f.x * f.x * (3.0 - 2.0 * f.x),
		f.y * f.y * (3.0 - 2.0 * f.y),
		f.z * f.z * (3.0 - 2.0 * f.z)
	)

	var h000 = _procedural_road_hash(i + Vector3(0, 0, 0))
	var h100 = _procedural_road_hash(i + Vector3(1, 0, 0))
	var h010 = _procedural_road_hash(i + Vector3(0, 1, 0))
	var h110 = _procedural_road_hash(i + Vector3(1, 1, 0))
	var h001 = _procedural_road_hash(i + Vector3(0, 0, 1))
	var h101 = _procedural_road_hash(i + Vector3(1, 0, 1))
	var h011 = _procedural_road_hash(i + Vector3(0, 1, 1))
	var h111 = _procedural_road_hash(i + Vector3(1, 1, 1))

	return lerp(
		lerp(lerp(h000, h100, f_interp.x), lerp(h010, h110, f_interp.x), f_interp.y),
		lerp(lerp(h001, h101, f_interp.x), lerp(h011, h111, f_interp.x), f_interp.y),
		f_interp.z
	)

func get_procedural_road_height(global_x: float, global_z: float) -> float:
	if not are_procedural_roads_enabled():
		return 0.0

	var cell_x = floor(global_x / procedural_road_spacing)
	var cell_z = floor(global_z / procedural_road_spacing)

	var local_x = fposmod(global_x, procedural_road_spacing)
	var local_z = fposmod(global_z, procedural_road_spacing)

	var h1 = _procedural_road_noise(Vector3(cell_x * procedural_road_spacing, 0.0, cell_z * procedural_road_spacing) * 0.008) * 3.0 + 12.0
	var h2 = _procedural_road_noise(Vector3((cell_x + 1.0) * procedural_road_spacing, 0.0, cell_z * procedural_road_spacing) * 0.008) * 3.0 + 12.0
	var h3 = _procedural_road_noise(Vector3(cell_x * procedural_road_spacing, 0.0, (cell_z + 1.0) * procedural_road_spacing) * 0.008) * 3.0 + 12.0
	var h4 = _procedural_road_noise(Vector3((cell_x + 1.0) * procedural_road_spacing, 0.0, (cell_z + 1.0) * procedural_road_spacing) * 0.008) * 3.0 + 12.0

	var tx = local_x / procedural_road_spacing
	var tz = local_z / procedural_road_spacing
	var interp_h = lerp(lerp(h1, h2, tx), lerp(h3, h4, tx), tz)

	var base_level = floor(interp_h)
	var frac = interp_h - base_level
	var flat_size = 0.45

	if frac < flat_size:
		return base_level
	elif frac > 1.0 - flat_size:
		return base_level + 1.0

	var ramp_t = (frac - flat_size) / (1.0 - 2.0 * flat_size)
	# smoothstep ramp_t = t * t * (3.0 - 2.0 * t)
	ramp_t = ramp_t * ramp_t * (3.0 - 2.0 * ramp_t)
	return base_level + ramp_t

func _is_world_map_road_at_position(global_x: float, global_z: float) -> bool:
	if _world_map_road_image == null:
		return false

	var road_width := _world_map_road_image.get_width()
	var road_height := _world_map_road_image.get_height()
	if road_width <= 0 or road_height <= 0 or world_map_size <= 0.0:
		return false

	var u := (global_x + world_map_half) / world_map_size
	var v := (global_z + world_map_half) / world_map_size
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return false

	var px := clampi(int(floor(u * float(road_width))), 0, road_width - 1)
	var py := clampi(int(floor(v * float(road_height))), 0, road_height - 1)
	var road_pixel := _world_map_road_image.get_pixel(px, py)
	return road_pixel.r > 0.5

func _get_all_modification_coords() -> Array:
	var coords: Array = []
	var seen: Dictionary = {}
	for coord in _world_map_terrain_modifications:
		seen[coord] = true
		coords.append(coord)
	for coord in stored_modifications:
		if seen.has(coord):
			continue
		coords.append(coord)
	return coords

func _get_modifications_for_chunk(coord: Vector3i) -> Array:
	var mods_for_chunk: Array = []
	mutex.lock()
	var runtime_mods = stored_modifications.get(coord, []).duplicate()
	mutex.unlock()
	if not runtime_mods.is_empty():
		mods_for_chunk.append_array(runtime_mods)
	return mods_for_chunk

func _cache_world_map_terrain_modifications(raw_mods: Array) -> void:
	_world_map_terrain_modifications.clear()
	_world_map_excavation_masks.clear()
	for raw_mod in raw_mods:
		var mod := _normalize_world_map_modification(raw_mod)
		if mod.is_empty():
			continue
		for coord in _get_modification_covered_chunk_coords(mod):
			if not _world_map_terrain_modifications.has(coord):
				_world_map_terrain_modifications[coord] = []
			_world_map_terrain_modifications[coord].append(mod)
		_cache_world_map_excavation_mask_from_mod(mod)

func _normalize_world_map_modification(raw_mod: Variant) -> Dictionary:
	if not (raw_mod is Dictionary):
		return {}
	var mod_in: Dictionary = raw_mod
	if not mod_in.has("brush_pos"):
		return {}
	var brush_pos := _read_mod_vector3(mod_in.get("brush_pos"))
	var shape := int(mod_in.get("shape", 0))
	var normalized := {
		"brush_pos": brush_pos,
		"radius": float(mod_in.get("radius", 0.6)),
		"value": float(mod_in.get("value", 0.0)),
		"shape": shape,
		"layer": int(mod_in.get("layer", 0)),
		"material_id": int(mod_in.get("material_id", -1))
	}
	if shape == 2:
		var y_min := float(mod_in.get("y_min", brush_pos.y))
		var y_max := float(mod_in.get("y_max", brush_pos.y))
		if y_max <= y_min:
			return {}
		normalized["y_min"] = y_min
		normalized["y_max"] = y_max
	return normalized

func _read_mod_vector3(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO

func _get_modification_covered_chunk_coords(mod: Dictionary) -> Array:
	var coords: Array = []
	var seen: Dictionary = {}
	var brush_pos: Vector3 = mod.get("brush_pos", Vector3.ZERO)
	var shape := int(mod.get("shape", 0))
	var radius := float(mod.get("radius", 0.0))
	var min_x := brush_pos.x - radius
	var max_x := brush_pos.x + radius
	var min_y := brush_pos.y - radius
	var max_y := brush_pos.y + radius
	var min_z := brush_pos.z - radius
	var max_z := brush_pos.z + radius
	if shape == 2:
		var margin := 1.0
		min_x = brush_pos.x - margin
		max_x = brush_pos.x + margin
		min_y = float(mod.get("y_min", brush_pos.y))
		max_y = float(mod.get("y_max", brush_pos.y))
		min_z = brush_pos.z - margin
		max_z = brush_pos.z + margin

	for chunk_x in range(int(floor(min_x / CHUNK_STRIDE)), int(floor(max_x / CHUNK_STRIDE)) + 1):
		for chunk_y in range(int(floor(min_y / CHUNK_STRIDE)), int(floor(max_y / CHUNK_STRIDE)) + 1):
			for chunk_z in range(int(floor(min_z / CHUNK_STRIDE)), int(floor(max_z / CHUNK_STRIDE)) + 1):
				var coord := Vector3i(chunk_x, chunk_y, chunk_z)
				if seen.has(coord):
					continue
				seen[coord] = true
				coords.append(coord)
	return coords

func _cache_world_map_excavation_mask_from_mod(mod: Dictionary) -> void:
	if int(mod.get("shape", -1)) != 2:
		return
	if float(mod.get("value", 0.0)) <= 0.0:
		return

	var brush_pos: Vector3 = mod.get("brush_pos", Vector3.ZERO)
	var sample_x_min := int(ceil(brush_pos.x - 0.5))
	var sample_x_max := int(floor(brush_pos.x + 0.5))
	var sample_z_min := int(ceil(brush_pos.z - 0.5))
	var sample_z_max := int(floor(brush_pos.z + 0.5))
	var sample_y_min := int(ceil(float(mod.get("y_min", brush_pos.y))))
	var sample_y_max := int(floor(float(mod.get("y_max", brush_pos.y))))

	if sample_x_max < sample_x_min or sample_y_max < sample_y_min or sample_z_max < sample_z_min:
		return

	var chunk_xs := _get_density_sample_axis_chunks(sample_x_min, sample_x_max)
	var chunk_ys := _get_density_sample_axis_chunks(sample_y_min, sample_y_max)
	var chunk_zs := _get_density_sample_axis_chunks(sample_z_min, sample_z_max)
	for chunk_x in chunk_xs:
		var local_x_min := maxi(0, sample_x_min - chunk_x * CHUNK_STRIDE)
		var local_x_max := mini(DENSITY_GRID_SIZE - 1, sample_x_max - chunk_x * CHUNK_STRIDE)
		if local_x_max < local_x_min:
			continue
		for chunk_y in chunk_ys:
			var local_y_min := maxi(0, sample_y_min - chunk_y * CHUNK_STRIDE)
			var local_y_max := mini(DENSITY_GRID_SIZE - 1, sample_y_max - chunk_y * CHUNK_STRIDE)
			if local_y_max < local_y_min:
				continue
			for chunk_z in chunk_zs:
				var local_z_min := maxi(0, sample_z_min - chunk_z * CHUNK_STRIDE)
				var local_z_max := mini(DENSITY_GRID_SIZE - 1, sample_z_max - chunk_z * CHUNK_STRIDE)
				if local_z_max < local_z_min:
					continue
				var coord := Vector3i(chunk_x, chunk_y, chunk_z)
				var mask: PackedByteArray = _world_map_excavation_masks.get(coord, PackedByteArray())
				if mask.size() != EXCAVATION_MASK_BYTE_COUNT:
					mask = _create_empty_excavation_mask_bytes()
				_mark_excavation_mask_box(mask, local_x_min, local_x_max, local_y_min, local_y_max, local_z_min, local_z_max)
				_world_map_excavation_masks[coord] = mask

func _get_density_sample_axis_chunks(sample_min: int, sample_max: int) -> Array[int]:
	var coords: Array[int] = []
	var first_chunk := int(ceil(float(sample_min - (DENSITY_GRID_SIZE - 1)) / float(CHUNK_STRIDE)))
	var last_chunk := int(floor(float(sample_max) / float(CHUNK_STRIDE)))
	for chunk_idx in range(first_chunk, last_chunk + 1):
		var local_min := sample_min - chunk_idx * CHUNK_STRIDE
		var local_max := sample_max - chunk_idx * CHUNK_STRIDE
		if local_max < 0 or local_min >= DENSITY_GRID_SIZE:
			continue
		coords.append(chunk_idx)
	return coords

func _create_empty_excavation_mask_bytes() -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(EXCAVATION_MASK_BYTE_COUNT)
	mask.fill(0)
	return mask

func _mark_excavation_mask_box(mask: PackedByteArray, min_x: int, max_x: int, min_y: int, max_y: int, min_z: int, max_z: int) -> void:
	for local_z in range(min_z, max_z + 1):
		for local_y in range(min_y, max_y + 1):
			for local_x in range(min_x, max_x + 1):
				var bit_index := local_x + (local_y * DENSITY_GRID_SIZE) + (local_z * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
				var byte_index := bit_index / 8
				mask[byte_index] = mask[byte_index] | (1 << (bit_index % 8))

func _rebuild_world_map_excavation_buffers(rd: RenderingDevice) -> void:
	_free_world_map_excavation_buffers(rd)
	var empty_mask := _create_empty_excavation_mask_bytes()
	_world_map_empty_excavation_buf = rd.storage_buffer_create(empty_mask.size(), empty_mask)
	for coord in _world_map_excavation_masks:
		var mask: PackedByteArray = _world_map_excavation_masks.get(coord, PackedByteArray())
		if mask.size() != EXCAVATION_MASK_BYTE_COUNT:
			continue
		_world_map_excavation_buffers[coord] = rd.storage_buffer_create(mask.size(), mask)

func _free_world_map_excavation_buffers(rd: RenderingDevice) -> void:
	for buffer_rid in _world_map_excavation_buffers.values():
		if buffer_rid.is_valid():
			rd.free_rid(buffer_rid)
	_world_map_excavation_buffers.clear()
	if _world_map_empty_excavation_buf.is_valid():
		rd.free_rid(_world_map_empty_excavation_buf)
		_world_map_empty_excavation_buf = RID()

func get_terrain_height(global_x: float, global_z: float) -> float:
	# Find X,Z chunk coordinates
	var chunk_x = int(floor(global_x / CHUNK_STRIDE))
	var chunk_z = int(floor(global_z / CHUNK_STRIDE))

	# Calculate local X,Z within chunk
	var chunk_origin_x = chunk_x * CHUNK_STRIDE
	var chunk_origin_z = chunk_z * CHUNK_STRIDE
	var local_x = int(round(global_x - chunk_origin_x))
	var local_z = int(round(global_z - chunk_origin_z))

	if local_x < 0 or local_x >= DENSITY_GRID_SIZE or local_z < 0 or local_z >= DENSITY_GRID_SIZE:
		return -1000.0

	# Scan from highest to lowest Y-layer to find terrain surface
	var best_height = -1000.0

	for chunk_y in range(MAX_Y_LAYER, MIN_Y_LAYER - 1, -1):
		var coord = Vector3i(chunk_x, chunk_y, chunk_z)

		if not active_chunks.has(coord):
			continue

		var data = active_chunks[coord]
		if data == null or data.cpu_density_terrain.is_empty():
			continue

		var chunk_base_y = chunk_y * CHUNK_STRIDE

		# Scan Y column from top to bottom within this chunk
		var prev_density = 1.0 # Assume air above
		for iy in range(DENSITY_GRID_SIZE - 1, -1, -1):
			var index = local_x + (iy * DENSITY_GRID_SIZE) + (local_z * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
			var density = data.cpu_density_terrain[index]

			if density < 0.0:
				# Found ground! Interpolate for accurate isosurface height
				var local_height: float
				if iy < DENSITY_GRID_SIZE - 1:
					var t = prev_density / (prev_density - density)
					local_height = float(iy + 1) - t
				else:
					local_height = float(iy)

				var world_height = chunk_base_y + local_height
				if world_height > best_height:
					best_height = world_height
				# Found surface in this chunk, stop searching
				return best_height
			prev_density = density

	return best_height # Return -1000.0 if no terrain found

# Optimized height lookup that only checks a specific chunk (much faster for vegetation placement)
func get_chunk_surface_height(coord: Vector3i, local_x: int, local_z: int) -> float:
	if not active_chunks.has(coord):
		return -1000.0

	var data = active_chunks[coord]
	if data == null or data.cpu_density_terrain.is_empty():
		return -1000.0

	# Scan Y column from top to bottom within this chunk
	var chunk_base_y = coord.y * CHUNK_STRIDE
	var prev_density = 1.0 # Assume air above

	# Safety check for bounds
	if local_x < 0 or local_x >= DENSITY_GRID_SIZE or local_z < 0 or local_z >= DENSITY_GRID_SIZE:
		return -1000.0

	# Pre-calculate index offsets to avoid multiplication in loop
	var col_offset = local_x + (local_z * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
	var stride_y = DENSITY_GRID_SIZE

	for iy in range(DENSITY_GRID_SIZE - 1, -1, -1):
		var index = col_offset + (iy * stride_y)
		var density = data.cpu_density_terrain[index]

		if density < 0.0:
			# Found ground! Interpolate
			var local_height: float
			if iy < DENSITY_GRID_SIZE - 1:
				var t = prev_density / (prev_density - density)
				local_height = float(iy + 1) - t
			else:
				local_height = float(iy)

			return chunk_base_y + local_height

		prev_density = density

	return -1000.0

# Updated to accept layer (0=Terrain, 1=Water) and optional material_id
# Rate limiting to prevent GPU overload from rapid-fire calls
var _last_modify_time_ms: int = 0
const MODIFY_COOLDOWN_MS: int = 100  # Max 10 modifications per second

func modify_terrain(pos: Vector3, radius: float, value: float, shape: int = 0, layer: int = 0, material_id: int = -1):
	# RATE LIMITING: Skip if called too quickly (prevents 60 GPU ops/sec when holding mouse)
	var now_ms = Time.get_ticks_msec()
	if now_ms - _last_modify_time_ms < MODIFY_COOLDOWN_MS:
		_last_modify_terrain_ms = 0.0
		return  # Skip this call, too soon after last one
	_last_modify_time_ms = now_ms
	var modify_start_us := Time.get_ticks_usec()
	# Calculate bounds of the modification sphere/box
	# Add extra margin (1.0) to account for material radius extension and shader sampling
	var extra_margin = 1.0 if material_id >= 0 else 0.0
	var min_pos = pos - Vector3(radius + extra_margin, radius + extra_margin, radius + extra_margin)
	var max_pos = pos + Vector3(radius + extra_margin, radius + extra_margin, radius + extra_margin)

	var min_chunk_x = int(floor(min_pos.x / CHUNK_STRIDE))
	var max_chunk_x = int(floor(max_pos.x / CHUNK_STRIDE))
	var min_chunk_y = int(floor(min_pos.y / CHUNK_STRIDE))
	var max_chunk_y = int(floor(max_pos.y / CHUNK_STRIDE))
	var min_chunk_z = int(floor(min_pos.z / CHUNK_STRIDE))
	var max_chunk_z = int(floor(max_pos.z / CHUNK_STRIDE))

	var tasks_to_add = []
	var chunks_to_generate = [] # Track unloaded chunks that need immediate loading

	# Store modification for persistence (all affected chunks)
	for x in range(min_chunk_x, max_chunk_x + 1):
		for y in range(min_chunk_y, max_chunk_y + 1):
			for z in range(min_chunk_z, max_chunk_z + 1):
				var coord = Vector3i(x, y, z)

				# Store the modification for this chunk (persists across unloads)
				if not stored_modifications.has(coord):
					stored_modifications[coord] = []
				stored_modifications[coord].append({
					"brush_pos": pos,
					"radius": radius,
					"value": value,
					"shape": shape,
					"layer": layer,
					"material_id": material_id
				})


				# Only dispatch GPU task if chunk is currently loaded
				if active_chunks.has(coord):
					var data = active_chunks[coord]
					if data != null:
						var target_buffer = data.density_buffer_terrain if layer == 0 else data.density_buffer_water

						if target_buffer.is_valid():
							var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)

							# Increment chunk's modification version and capture for stale detection
							data.mod_version += 1
							var start_mod_version = data.mod_version

							var task = {
								"type": "modify",
								"coord": coord,
								"rid": target_buffer,
								"material_rid": data.material_buffer_terrain, # Pass material buffer
								"pos": chunk_pos,
								"brush_pos": pos,
								"radius": radius,
								"value": value,
								"shape": shape,
								"layer": layer,
								"material_id": material_id,
								"start_mod_version": start_mod_version  # For stale detection
							}
							tasks_to_add.append(task)
				else:
					# Chunk not loaded - trigger immediate generation
					# This handles digging into underground layers (Y=-1, etc.)
					if not active_chunks.has(coord): # Not already queued
						active_chunks[coord] = null # Mark as pending
						var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
						chunks_to_generate.append({
							"type": "generate",
							"coord": coord,
							"pos": chunk_pos
						})

	# Queue chunk generations with high priority (before other generates but after modifies)
	if chunks_to_generate.size() > 0:
		mutex.lock()
		for gen_task in chunks_to_generate:
			priority_task_queue.append(gen_task)
		mutex.unlock()
		for i in range(chunks_to_generate.size()):
			semaphore.post()

	if tasks_to_add.size() > 0:
		modification_batch_id += 1
		var batch_count = tasks_to_add.size()

		mutex.lock()
		# Priority work stays on a separate queue so we can use simple append/pop
		# stacks without shifting large arrays.
		for i in range(tasks_to_add.size() - 1, -1, -1): # Reverse order to maintain sequence
			var t = tasks_to_add[i]
			t["batch_id"] = modification_batch_id
			t["batch_count"] = batch_count
			priority_task_queue.append(t)
		mutex.unlock()

		for i in range(batch_count):
			semaphore.post()
	
	_last_modify_terrain_ms = float(Time.get_ticks_usec() - modify_start_us) / 1000.0

## Fill a 1x1 vertical column of terrain from y_from to y_to
## Uses Column shape (type=2) for precise vertical fills
func fill_column(x: float, z: float, y_from: float, y_to: float, value: float, layer: int = 0):
	# Calculate center position (mid-point of column)
	var pos = Vector3(x, (y_from + y_to) / 2.0, z)

	# Add margin for Marching Cubes boundary overlap (1.0 is sufficient)
	# This ensures adjacent chunks are also updated when column is near boundary
	var margin = 1.0
	var min_chunk_x = int(floor((x - margin) / CHUNK_STRIDE))
	var max_chunk_x = int(floor((x + margin) / CHUNK_STRIDE))
	var min_chunk_y = int(floor(y_from / CHUNK_STRIDE))
	var max_chunk_y = int(floor(y_to / CHUNK_STRIDE))
	var min_chunk_z = int(floor((z - margin) / CHUNK_STRIDE))
	var max_chunk_z = int(floor((z + margin) / CHUNK_STRIDE))

	var tasks_to_add = []
	var chunks_to_generate = []

	for chunk_x in range(min_chunk_x, max_chunk_x + 1):
		for chunk_y in range(min_chunk_y, max_chunk_y + 1):
			for chunk_z in range(min_chunk_z, max_chunk_z + 1):
				var coord = Vector3i(chunk_x, chunk_y, chunk_z)

				# Store modification for persistence
				if not stored_modifications.has(coord):
					stored_modifications[coord] = []
				stored_modifications[coord].append({
					"brush_pos": pos,
					"radius": 0.6, # Minimal radius, column shape uses XZ distance
					"value": value,
					"shape": 2, # Column shape
					"layer": layer,
					"y_min": y_from,
					"y_max": y_to,
					"material_id": - 1
				})

				if active_chunks.has(coord):
					var data = active_chunks[coord]
					if data != null:
						var target_buffer = data.density_buffer_terrain if layer == 0 else data.density_buffer_water
						if target_buffer.is_valid():
							var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
							tasks_to_add.append({
								"type": "modify",
								"coord": coord,
								"rid": target_buffer,
								"material_rid": data.material_buffer_terrain,
								"pos": chunk_pos,
								"brush_pos": pos,
								"radius": 0.6,
								"value": value,
								"shape": 2, # Column shape
								"layer": layer,
								"y_min": y_from,
								"y_max": y_to,
								"material_id": - 1
							})
				else:
					active_chunks[coord] = null
					var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
					chunks_to_generate.append({
						"type": "generate",
						"coord": coord,
						"pos": chunk_pos
					})

	if chunks_to_generate.size() > 0:
		mutex.lock()
		for gen_task in chunks_to_generate:
			priority_task_queue.append(gen_task)
		mutex.unlock()
		for i in range(chunks_to_generate.size()):
			semaphore.post()

	if tasks_to_add.size() > 0:
		modification_batch_id += 1
		var batch_count = tasks_to_add.size()

		mutex.lock()
		for i in range(tasks_to_add.size() - 1, -1, -1):
			var t = tasks_to_add[i]
			t["batch_id"] = modification_batch_id
			t["batch_count"] = batch_count
			priority_task_queue.append(t)
		mutex.unlock()

		for i in range(batch_count):
			semaphore.post()

func _exit_tree():
	# CRITICAL: Clean up all GPU resources BEFORE terminating threads
	# This fixes 682 resource leaks (StorageBuffers, Meshes, Collision, Materials)

	# 1. Unload all active chunks (frees meshes, collision, GPU buffers)
	var coords_to_unload = active_chunks.keys()
	for coord in coords_to_unload:
		_unload_chunk(coord)

	# 2. Clear pending nodes queue (prevents creating nodes after cleanup)
	_queue_gpu_free_tasks(_drain_pending_finalization_free_tasks())

	# 3. Signal threads to exit
	mutex.lock()
	exit_thread = true
	mutex.unlock()

	# Signal GPU thread to exit
	semaphore.post()

	# Signal all CPU workers to exit
	for i in range(_cpu_worker_count):
		cpu_semaphore.post()

	# 5. Wait for GPU thread to finish (processes remaining "free" tasks)
	if compute_thread:
		compute_thread.wait_to_finish()
		compute_thread = null

	# 6. Wait for CPU workers to finish
	for i in range(cpu_threads.size()):
		var thread = cpu_threads[i]
		if thread:
			thread.wait_to_finish()
	cpu_threads.clear()

	# Drop helper references and any leftover queued payloads now that workers are done.
	if terrain_grid and terrain_grid.has_method("clear"):
		terrain_grid.clear()
	terrain_grid = null
	_native_backends_ready = false
	_clear_gpu_task_queues()
	cpu_task_queue.clear()
	pending_spawn_zones.clear()
	pending_batches.clear()
	active_chunks.clear()
	PrefabGeometry.clear_cache()



func update_chunks():
	if not _native_backends_ready or not terrain_grid or not is_instance_valid(terrain_grid):
		return
	_update_chunks_native()

func update_chunk_unloads_only():
	if not _native_backends_ready or not terrain_grid or not is_instance_valid(terrain_grid):
		return

	var update_start_us := Time.get_ticks_usec()
	_last_update_backend = "native_unload_only"

	var p_pos = get_viewer_position()
	var p_chunk_x = int(floor(p_pos.x / CHUNK_STRIDE))
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE))
	var p_chunk_z = int(floor(p_pos.z / CHUNK_STRIDE))
	var unload_count := _unload_out_of_range_chunks(
		p_chunk_x,
		p_chunk_y,
		p_chunk_z,
		terrain_unload_budget_per_frame
	)
	_last_update_loads = 0
	_last_update_unloads = unload_count
	_last_update_duration_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0

func _update_chunks_native():
	var update_start_us := Time.get_ticks_usec()
	_last_update_backend = "native"

	var p_pos = get_viewer_position()
	var p_chunk_x = int(floor(p_pos.x / CHUNK_STRIDE))
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE))
	var p_chunk_z = int(floor(p_pos.z / CHUNK_STRIDE))
	if loading_paused:
		var paused_unloads := _unload_out_of_range_chunks(
			p_chunk_x,
			p_chunk_y,
			p_chunk_z,
			terrain_unload_budget_per_frame
		)
		_last_update_loads = 0
		_last_update_unloads = paused_unloads
		_last_update_duration_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0
		return

	var is_above_ground = p_chunk_y >= 0
	var render_distance_sq = render_distance * render_distance

	# 1. Update Grid (C++)
	# Returns { "load": [Vector3i], "unload": [Vector3i] }
	var result = terrain_grid.update(p_pos, render_distance, is_above_ground, CHUNK_STRIDE, chunks_per_frame_limit, terrain_unload_budget_per_frame)

	# 2. Process Unloads
	var unload_count := 0
	for coord in result["unload"]:
		unload_count += 1
		_unload_chunk(coord)
		terrain_grid.remove_chunk(coord)

	if unload_count < terrain_unload_budget_per_frame:
		unload_count += _unload_out_of_range_chunks(
			p_chunk_x,
			p_chunk_y,
			p_chunk_z,
			terrain_unload_budget_per_frame - unload_count
		)

	# 3. Process Loads
	var chunks_queued = 0
	for coord in result["load"]:
		if chunks_queued >= chunks_per_frame_limit:
			break

		# Safe check, though Grid should handle it
		if active_chunks.has(coord):
			continue

		_load_chunk(coord)
		terrain_grid.add_chunk(coord)
		chunks_queued += 1

	# 4. Special Case: Stored Modifications (Force load if nearby)
	if chunks_queued < chunks_per_frame_limit and not initial_load_phase:
		for coord in _get_all_modification_coords():
			if chunks_queued >= chunks_per_frame_limit: break
			if active_chunks.has(coord): continue

			var dx = coord.x - p_chunk_x
			var dz = coord.z - p_chunk_z
			if dx * dx + dz * dz <= render_distance_sq:
				_load_chunk(coord)
				terrain_grid.add_chunk(coord)
				chunks_queued += 1

	_last_update_loads = chunks_queued
	_last_update_unloads = unload_count
	_last_update_duration_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0

func _unload_out_of_range_chunks(center_x: int, center_y: int, center_z: int, budget: int) -> int:
	if budget <= 0:
		return 0

	var unload_distance := render_distance + 2
	var unload_distance_sq := unload_distance * unload_distance
	var coords_to_unload: Array[Vector3i] = []

	for coord_variant in active_chunks.keys():
		var coord: Vector3i = coord_variant
		var dx := coord.x - center_x
		var dz := coord.z - center_z
		var dist_xz_sq := dx * dx + dz * dz
		var is_terrain_layer := coord.y >= -20 and coord.y <= 1
		if dist_xz_sq > unload_distance_sq or (not is_terrain_layer and abs(coord.y - center_y) > 3):
			coords_to_unload.append(coord)

	var unloaded := 0
	for coord in coords_to_unload:
		if unloaded >= budget:
			break
		if not active_chunks.has(coord):
			continue
		_unload_chunk(coord)
		if terrain_grid and terrain_grid.has_method("remove_chunk"):
			terrain_grid.remove_chunk(coord)
		unloaded += 1

	return unloaded

func _load_chunk(coord: Vector3i):
	active_chunks[coord] = null

	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
	var task = {
		"type": "generate",
		"coord": coord,
		"pos": chunk_pos
	}

	mutex.lock()
	task_queue.append(task)
	mutex.unlock()
	semaphore.post()

func _unload_chunk(coord: Vector3i):
	if not active_chunks.has(coord):
		return

	_remove_pending_generate_tasks_for_coord(coord)

	var data = active_chunks[coord]
	if data:
		if terrain_grid and terrain_grid.has_method("set_chunk_collision_ready"):
			terrain_grid.set_chunk_collision_ready(coord, false)
		pending_terrain_collision_creates.erase(coord)
		if data.node_terrain: data.node_terrain.queue_free()
		if data.node_water: data.node_water.queue_free()

		# Free Physics Body RID (Immediate, Main Thread/Thread Safe)
		if data.body_rid_terrain.is_valid():
			var world = get_world_3d()
			if world:
				PhysicsServer3D.body_set_space(data.body_rid_terrain, RID())
			PhysicsServer3D.body_set_collision_layer(data.body_rid_terrain, 0)
			PhysicsServer3D.body_set_collision_mask(data.body_rid_terrain, 0)
			PhysicsServer3D.free_rid(data.body_rid_terrain)

		var tasks = []
		if data.density_buffer_terrain.is_valid():
			tasks.append({"type": "free", "rid": data.density_buffer_terrain})
		if data.density_buffer_water.is_valid():
			tasks.append({"type": "free", "rid": data.density_buffer_water})
		if data.material_buffer_terrain.is_valid():
			tasks.append({"type": "free", "rid": data.material_buffer_terrain})
			data.material_buffer_terrain = RID()

		mutex.lock()
		for t in tasks: task_queue.append(t)
		mutex.unlock()

		for t in tasks: semaphore.post()

	active_chunks.erase(coord)
	chunk_unloaded.emit(coord)

## Atomic world reset: cancels all background work and clears active chunks
## Used during Save/Load to prevent "double rendering" and redundant processing
func clear_all_chunks():

	# 1. Clear background task queues immediately
	_clear_gpu_task_queues()

	cpu_mutex.lock()
	cpu_task_queue.clear()
	cpu_mutex.unlock()

	# 2. Clear finalization queue
	_queue_gpu_free_tasks(_drain_pending_finalization_free_tasks())
	pending_terrain_collision_creates.clear()
	_last_terrain_collision_create_count = 0
	_last_terrain_collision_create_ms = 0.0

	# 3. Wipe all active chunks (frees Meshes, RIDs, and Collision)
	# Working on a copy of keys because _unload_chunk modifies the dictionary
	var coords = active_chunks.keys()
	for coord in coords:
		_unload_chunk(coord)

	# 4. Reset internal state
	active_chunks.clear()
	if terrain_grid and terrain_grid.has_method("clear"):
		terrain_grid.clear()

	var prefab_spawner = _get_prefab_spawner()
	if prefab_spawner and prefab_spawner.has_method("clear_pending_spawn_jobs"):
		prefab_spawner.clear_pending_spawn_jobs()

	var building_manager = _get_building_manager()
	if building_manager and building_manager.has_method("clear_pending_object_collision_tasks"):
		building_manager.clear_pending_object_collision_tasks()

	pending_spawn_zones.clear()
	modification_batch_id = 0
	pending_batches.clear()
	_last_update_backend = "clear"
	_last_update_loads = 0
	_last_update_unloads = 0
	_capture_terrain_telemetry("world_reset", {"cleared_chunks": coords.size()})


func _update_chunks_legacy():
	var update_start_us := Time.get_ticks_usec()
	_last_update_backend = "legacy"
	var p_pos = get_viewer_position()
	var p_chunk_x = int(floor(p_pos.x / CHUNK_STRIDE))
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE)) # Y uses CHUNK_STRIDE for 1-voxel overlap
	var p_chunk_z = int(floor(p_pos.z / CHUNK_STRIDE))
	var center_chunk = Vector3i(p_chunk_x, p_chunk_y, p_chunk_z)
	var render_distance_sq = render_distance * render_distance

	# 1. Unload far chunks (3D distance check)
	var chunks_to_remove = []
	for coord in active_chunks:
		# NEVER unload terrain layers from MIN_Y_LAYER to 1 within horizontal range
		# This includes all underground layers we might dig into
		var is_terrain_layer = coord.y >= MIN_Y_LAYER and coord.y <= 1

		# XZ distance for horizontal, separate check for Y
		var dx = coord.x - center_chunk.x
		var dy = coord.y - center_chunk.y
		var dz = coord.z - center_chunk.z
		var dist_xz_sq = dx * dx + dz * dz

		# Unload if too far horizontally
		if dist_xz_sq > (render_distance + 2) * (render_distance + 2):
			chunks_to_remove.append(coord)
		# For non-terrain layers, also unload if too far vertically
		elif not is_terrain_layer and abs(dy) > 3:
			chunks_to_remove.append(coord)

	for coord in chunks_to_remove:
		_remove_pending_generate_tasks_for_coord(coord)

		var data = active_chunks[coord]
		if data:
			if data.node_terrain: data.node_terrain.queue_free()
			if data.node_water: data.node_water.queue_free()

			# Free Physics Body RID
			if data.body_rid_terrain.is_valid():
				PhysicsServer3D.free_rid(data.body_rid_terrain)

			var tasks = []
			if data.density_buffer_terrain.is_valid():
				tasks.append({"type": "free", "rid": data.density_buffer_terrain})
			if data.density_buffer_water.is_valid():
				tasks.append({"type": "free", "rid": data.density_buffer_water})
			if data.material_buffer_terrain.is_valid():
				tasks.append({"type": "free", "rid": data.material_buffer_terrain})
				data.material_buffer_terrain = RID()

			mutex.lock()
			for t in tasks: task_queue.append(t)
			mutex.unlock()

			for t in tasks: semaphore.post()

		active_chunks.erase(coord)

		# Notify systems that chunk has unloaded (for vegetation cleanup, etc.)
		chunk_unloaded.emit(coord)

	_last_update_unloads = chunks_to_remove.size()

	# 2. Load new chunks (adaptive rate limiting based on FPS)
	if loading_paused:
		_last_update_loads = 0
		_last_update_duration_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0
		return # Skip loading when FPS is too low

	var chunks_queued_this_frame = 0

	# Fast path for players above ground (the common case)
	# This matches the original 2D loading loop exactly, just with Vector3i(x, 0, z)
	# Only use multi-layer path for underground players (Y < 0)
	var is_above_ground = center_chunk.y >= 0

	# Debug loading state (gated)

	if is_above_ground:
		# Only load Y=0 layer for performance
		# Underground chunks load on-demand when player digs (via modify_terrain)
		# They're protected from unloading by is_terrain_layer check
		var y_to_load: Array[int] = [0]
		for x in range(center_chunk.x - render_distance, center_chunk.x + render_distance + 1):
			for z in range(center_chunk.z - render_distance, center_chunk.z + render_distance + 1):
				var dx = x - center_chunk.x
				var dz = z - center_chunk.z
				if dx * dx + dz * dz > render_distance_sq:
					continue

				for y in y_to_load:
					if chunks_queued_this_frame >= chunks_per_frame_limit:
						_last_update_loads = chunks_queued_this_frame
						_last_update_duration_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0
						return

					var coord = Vector3i(x, y, z)

					if active_chunks.has(coord):
						continue

					active_chunks[coord] = null

					# Debug: track when underground chunks are queued

					var chunk_pos = Vector3(x * CHUNK_STRIDE, y * CHUNK_STRIDE, z * CHUNK_STRIDE)

					var task = {
						"type": "generate",
						"coord": coord,
						"pos": chunk_pos
					}

					mutex.lock()
					task_queue.append(task)
					mutex.unlock()
					semaphore.post()

					chunks_queued_this_frame += 1

		# Also load chunks with stored modifications (player builds) within range
		if not initial_load_phase:
			for coord in _get_all_modification_coords():
				if chunks_queued_this_frame >= chunks_per_frame_limit:
					_last_update_loads = chunks_queued_this_frame
					_last_update_duration_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0
					return
				if active_chunks.has(coord):
					continue

				# Check if chunk is within horizontal render distance
				var dx = coord.x - center_chunk.x
				var dz = coord.z - center_chunk.z
				if dx * dx + dz * dz > render_distance_sq:
					continue

				active_chunks[coord] = null
				var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
				var task = {"type": "generate", "coord": coord, "pos": chunk_pos}

				mutex.lock()
				task_queue.append(task)
				mutex.unlock()
				semaphore.post()
				chunks_queued_this_frame += 1
	else:
		# Player is underground or flying - load multiple Y layers
		var y_layers = [center_chunk.y - 1, center_chunk.y, center_chunk.y + 1, 0] # Include terrain layer 0

		for x in range(center_chunk.x - render_distance, center_chunk.x + render_distance + 1):
			for z in range(center_chunk.z - render_distance, center_chunk.z + render_distance + 1):
				var dx = x - center_chunk.x
				var dz = z - center_chunk.z
				if dx * dx + dz * dz > render_distance_sq:
					continue

				for y in y_layers:
					if y < MIN_Y_LAYER or y > MAX_Y_LAYER:
						continue
					if chunks_queued_this_frame >= chunks_per_frame_limit:
						_last_update_loads = chunks_queued_this_frame
						_last_update_duration_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0
						return

					var coord = Vector3i(x, y, z)

					if active_chunks.has(coord):
						continue

					active_chunks[coord] = null

					var chunk_pos = Vector3(x * CHUNK_STRIDE, y * CHUNK_STRIDE, z * CHUNK_STRIDE)

					var task = {
						"type": "generate",
						"coord": coord,
						"pos": chunk_pos
					}

					mutex.lock()
					task_queue.append(task)
					mutex.unlock()
					semaphore.post()

					chunks_queued_this_frame += 1

	_last_update_loads = chunks_queued_this_frame
	_last_update_duration_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0

## Interruptible delay - checks for high-priority tasks every 10ms
## Allows player interactions to interrupt chunk loading delays
func _interruptible_delay(total_ms: int):
	var elapsed = 0
	while elapsed < total_ms:
		# Check if any GPU terrain work is waiting; priority tasks should interrupt.
		var has_pending_gpu_task = _has_pending_gpu_tasks()

		if has_pending_gpu_task:
			return # Stop delaying, process immediately

		# Sleep in small chunks
		var sleep_time = min(10, total_ms - elapsed)
		OS.delay_msec(sleep_time)
		elapsed += sleep_time

func _thread_function():
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		return

	var sid_gen = rd.shader_create_from_spirv(shader_gen_spirv)
	var sid_gen_water = rd.shader_create_from_spirv(shader_gen_water_spirv)
	var sid_mod = rd.shader_create_from_spirv(shader_mod_spirv)
	var sid_mesh = rd.shader_create_from_spirv(shader_mesh_spirv)

	var pipe_gen = rd.compute_pipeline_create(sid_gen)
	var pipe_gen_water = rd.compute_pipeline_create(sid_gen_water)
	var pipe_mod = rd.compute_pipeline_create(sid_mod)
	var pipe_mesh = rd.compute_pipeline_create(sid_mesh)

	# === GPU Biome Map Generation (for minimap — uses same fbm() as terrain shader) ===
	if world_map_active:
		var biome_spirv = load("res://world_marching_cubes/gen_biome_map.glsl").get_spirv()
		var sid_biome = rd.shader_create_from_spirv(biome_spirv)
		var pipe_biome = rd.compute_pipeline_create(sid_biome)

		var map_size_i = int(world_map_size)
		var buf_size = map_size_i * map_size_i
		# Pad to 4-byte alignment
		while buf_size % 4 != 0: buf_size += 1
		var biome_init = PackedByteArray()
		biome_init.resize(buf_size)
		biome_init.fill(0)
		var biome_buf_rid = rd.storage_buffer_create(buf_size, biome_init)

		var u_biome = RDUniform.new()
		u_biome.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u_biome.binding = 0
		u_biome.add_id(biome_buf_rid)
		var biome_set = rd.uniform_set_create([u_biome], sid_biome, 0)

		# Push constants: map_size, map_half, pad, pad
		var pc = PackedFloat32Array([world_map_size, world_map_half, 0.0, 0.0])
		var pc_bytes = pc.to_byte_array()

		var cl = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipe_biome)
		rd.compute_list_bind_uniform_set(cl, biome_set, 0)
		rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
		var groups = int(ceil(world_map_size / 16.0))
		rd.compute_list_dispatch(cl, groups, groups, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()

		# Read back GPU-generated biome data
		gpu_biome_map = rd.buffer_get_data(biome_buf_rid)
		gpu_biome_map.resize(map_size_i * map_size_i)  # Trim to exact size

		rd.free_rid(biome_buf_rid)
		rd.free_rid(sid_biome)

	# === World Map Buffers (uploaded from editor PNGs) ===

	_world_map_buildings = []
	_world_map_terrain_modifications.clear()
	_world_map_excavation_masks.clear()
	var world_map_setup_start_us := 0
	if world_map_active and world_definition_path != "":
		world_map_setup_start_us = Time.get_ticks_usec()
		PrefabGeometry.clear_cache()
		var loaded: Dictionary = {}
		if not _startup_world_map_data.is_empty():
			loaded = _startup_world_map_data
			_startup_world_map_data = {}
			_last_world_map_load_profile = _startup_world_map_load_profile.duplicate(true)
		else:
			var world_map_load_profile: Dictionary = {}
			loaded = WorldMapData.load_world(world_definition_path, world_map_data_cache_enabled, false, world_map_load_profile)
			_last_world_map_load_profile = world_map_load_profile.duplicate(true)

		if loaded.has("heightmap") and loaded.has("biomes") and loaded.has("roads"):
			var hmap: Image = loaded.heightmap
			var bmap: Image = loaded.biomes
			var rmap: Image = loaded.roads

			# Upload raw bytes as storage buffers
			var h_bytes = hmap.get_data()
			var b_bytes = bmap.get_data()
			var r_bytes = rmap.get_data()

			# Pad to 4-byte alignment for uint packing
			while h_bytes.size() % 4 != 0: h_bytes.append(0)
			while b_bytes.size() % 4 != 0: b_bytes.append(0)
			while r_bytes.size() % 4 != 0: r_bytes.append(0)

			_world_map_heightmap_buf = rd.storage_buffer_create(h_bytes.size(), h_bytes)
			_world_map_biome_buf = rd.storage_buffer_create(b_bytes.size(), b_bytes)
			_world_map_road_buf = rd.storage_buffer_create(r_bytes.size(), r_bytes)

			# Upload water map if available
			if loaded.has("water"):
				var wmap: Image = loaded.water
				var w_bytes = wmap.get_data()
				while w_bytes.size() % 4 != 0: w_bytes.append(0)
				_world_map_water_buf = rd.storage_buffer_create(w_bytes.size(), w_bytes)

			# Load baked buildings and terrain edits
			_world_map_buildings = []
			_world_map_terrain_modifications.clear()
			if loaded.has("buildings"):
				_world_map_buildings = loaded.buildings
			if loaded.has("terrain_modifications"):
				_cache_world_map_terrain_modifications(loaded.terrain_modifications)

			# Load building footprint map
			if loaded.has("building_map"):
				_world_map_building_map = loaded.building_map

			# Read metadata for map params
			if loaded.has("metadata"):
				var meta = loaded.metadata
				var meta_terrain_height = float(meta.get("terrain_height", terrain_height))
				world_map_size = float(meta.get("map_size", 2048))
				world_map_half = world_map_size / 2.0
				world_map_max_height = meta_terrain_height * 2.5
				water_level = float(meta.get("water_level", meta_terrain_height + 3.0))

		else:
			push_error("[ChunkManager] World map at %s missing required PNGs" % world_definition_path)
			world_map_active = false
	else:
		_last_world_map_load_profile = {}

	if world_map_setup_start_us != 0:
		_last_world_map_entry_ms = float(Time.get_ticks_usec() - world_map_setup_start_us) / 1000.0
	else:
		_last_world_map_entry_ms = 0.0

	_rebuild_world_map_excavation_buffers(rd)

	# Always create dummy buffers if not loaded (shader declares set 1 even when unused)
	if not _world_map_heightmap_buf.is_valid():
		var dummy = PackedByteArray()
		dummy.resize(4)
		_world_map_heightmap_buf = rd.storage_buffer_create(4, dummy)
		_world_map_biome_buf = rd.storage_buffer_create(4, dummy)
		_world_map_road_buf = rd.storage_buffer_create(4, dummy)
	if not _world_map_water_buf.is_valid():
		var dummy = PackedByteArray()
		dummy.resize(4)
		_world_map_water_buf = rd.storage_buffer_create(4, dummy)

	# Create uniform set 1 (always bound — real data or dummy)
	var u_hmap = RDUniform.new()
	u_hmap.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_hmap.binding = 0
	u_hmap.add_id(_world_map_heightmap_buf)

	var u_bmap = RDUniform.new()
	u_bmap.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_bmap.binding = 1
	u_bmap.add_id(_world_map_biome_buf)

	var u_rmap = RDUniform.new()
	u_rmap.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_rmap.binding = 2
	u_rmap.add_id(_world_map_road_buf)

	_world_map_set1 = rd.uniform_set_create([u_hmap, u_bmap, u_rmap], sid_gen, 1)

	# Create uniform set 1 for water shader (water map buffer)
	var u_wmap = RDUniform.new()
	u_wmap.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_wmap.binding = 0
	u_wmap.add_id(_world_map_water_buf)
	_world_map_water_set1 = rd.uniform_set_create([u_wmap], sid_gen_water, 1)

	# Keep legacy-sized GPU buffers so stale imported shaders cannot write past
	# the end before Godot reimports the packed-output shader.
	# This lets a couple of chunks overlap without reusing the same GPU storage buffers
	# before readback has completed.
	const MAX_IN_FLIGHT = 4 # Batch more terrain work before sync; output stays identical.
	var output_bytes_size = MAX_TRIANGLES * 3 * LEGACY_VERTEX_FLOATS * 4
	var buffer_slots: Array[Dictionary] = []
	for _slot in range(MAX_IN_FLIGHT):
		var counter_data_t = PackedByteArray()
		counter_data_t.resize(8)
		counter_data_t.encode_u32(0, 0)
		counter_data_t.encode_u32(4, 0)
		var counter_data_w = PackedByteArray()
		counter_data_w.resize(8)
		counter_data_w.encode_u32(0, 0)
		counter_data_w.encode_u32(4, 0)
		buffer_slots.append({
			"vertex_buffer_terrain": rd.storage_buffer_create(output_bytes_size),
			"counter_buffer_terrain": rd.storage_buffer_create(8, counter_data_t),
			"vertex_buffer_water": rd.storage_buffer_create(output_bytes_size),
			"counter_buffer_water": rd.storage_buffer_create(8, counter_data_w)
		})

	var modify_mesh_builder = ClassDB.instantiate("MeshBuilder")
	if not modify_mesh_builder:
		push_error("[ChunkManager] MeshBuilder GDExtension is required for modification meshing.")
		return

	# In-flight chunks: dispatched but not yet read back
	var in_flight: Array[Dictionary] = []

	while true:
		# 1. Check for new tasks FIRST (prioritize modifications before completing in-flight work)
		semaphore.wait()

		var task = _pop_next_gpu_task()
		if task.is_empty():
			var should_exit = exit_thread
			# Only complete in-flight when no tasks pending
			_flush_generation_batch(rd, in_flight, sid_mesh, pipe_mesh, buffer_slots)
			if should_exit:
				break
			continue

		# 2. Handle task types
		if task.type == "modify":
			# HIGHEST PRIORITY: Process modifications immediately, sync all pending work first
			_flush_generation_batch(rd, in_flight, sid_mesh, pipe_mesh, buffer_slots)
			process_modify(rd, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, buffer_slots[0]["vertex_buffer_terrain"], buffer_slots[0]["counter_buffer_terrain"], modify_mesh_builder)
		elif task.type == "generate":
			var task_has_stored_mods := _get_modifications_for_chunk(task.coord).size() > 0
			if task_has_stored_mods and not in_flight.is_empty():
				_flush_generation_batch(rd, in_flight, sid_mesh, pipe_mesh, buffer_slots)
				_delay_after_generation_batch()

			if in_flight.size() >= MAX_IN_FLIGHT:
				_flush_generation_batch(rd, in_flight, sid_mesh, pipe_mesh, buffer_slots)
				_delay_after_generation_batch()

			# Queue generation work without syncing. If more generate tasks are already
			# queued, the next loop can fill another buffer slot before one batch submit.
			var flight_data = _dispatch_chunk_generation(rd, task, sid_gen, sid_gen_water, sid_mod, pipe_gen, pipe_gen_water, pipe_mod)
			if flight_data:
				flight_data["buffer_slot"] = in_flight.size()
				in_flight.append(flight_data)

				# Flush when the slot ring is full, or immediately when the queue drained.
				# The queue-drained case prevents a lone chunk from sitting in-flight until
				# some unrelated future semaphore post wakes the thread.
				if in_flight.size() >= MAX_IN_FLIGHT or not _has_pending_gpu_tasks():
					_flush_generation_batch(rd, in_flight, sid_mesh, pipe_mesh, buffer_slots)
					_delay_after_generation_batch()
		elif task.type == "free":
			# Keep resource frees ordered after any pending GPU work.
			_flush_generation_batch(rd, in_flight, sid_mesh, pipe_mesh, buffer_slots)
			if task.rid.is_valid():
				rd.free_rid(task.rid)

	# Cleanup
	for slot in buffer_slots:
		rd.free_rid(slot["vertex_buffer_terrain"])
		rd.free_rid(slot["counter_buffer_terrain"])
		rd.free_rid(slot["vertex_buffer_water"])
		rd.free_rid(slot["counter_buffer_water"])
	rd.free_rid(pipe_gen)
	rd.free_rid(pipe_gen_water)
	rd.free_rid(pipe_mod)
	rd.free_rid(pipe_mesh)
	rd.free_rid(sid_gen)
	rd.free_rid(sid_gen_water)
	rd.free_rid(sid_mod)
	rd.free_rid(sid_mesh)

	# Free world map buffers
	if _world_map_heightmap_buf.is_valid(): rd.free_rid(_world_map_heightmap_buf)
	if _world_map_biome_buf.is_valid(): rd.free_rid(_world_map_biome_buf)
	if _world_map_road_buf.is_valid(): rd.free_rid(_world_map_road_buf)
	if _world_map_water_buf.is_valid(): rd.free_rid(_world_map_water_buf)
	_free_world_map_excavation_buffers(rd)

	rd.free()


func _flush_generation_batch(rd: RenderingDevice, in_flight: Array, sid_mesh, pipe_mesh, buffer_slots: Array) -> void:
	if in_flight.is_empty():
		return

	var needs_submit := false
	for flight_data in in_flight:
		if bool(flight_data.get("needs_submit", true)):
			needs_submit = true
			break

	if needs_submit:
		rd.submit()
	rd.sync()

	var mesh_readbacks: Array[Dictionary] = []
	for flight_data in in_flight:
		var slot_index := int(flight_data.get("buffer_slot", 0))
		if slot_index < 0 or slot_index >= buffer_slots.size():
			slot_index = 0
		var slot: Dictionary = buffer_slots[slot_index]
		mesh_readbacks.append(_dispatch_chunk_meshing(rd, flight_data, sid_mesh, pipe_mesh, slot["vertex_buffer_terrain"], slot["counter_buffer_terrain"], slot["vertex_buffer_water"], slot["counter_buffer_water"]))

	if not mesh_readbacks.is_empty():
		rd.submit()
		rd.sync()
		for readback in mesh_readbacks:
			_complete_chunk_readback(rd, readback)

	in_flight.clear()


func _delay_after_generation_batch() -> void:
	# Two-phase loading: fast initial load, then throttled exploration.
	# Initial progress is counted in complete_generation(), after CPU mesh work
	# has produced the pending visual nodes.
	if initial_load_phase:
		if initial_load_delay_ms > 0:
			_interruptible_delay(initial_load_delay_ms)
	else:
		_interruptible_delay(exploration_delay_ms)

# Dispatch generation work WITHOUT syncing - returns in-flight data for later readback
func _dispatch_chunk_generation(rd: RenderingDevice, task, sid_gen, sid_gen_water, sid_mod, pipe_gen, pipe_gen_water, pipe_mod) -> Dictionary:
	var chunk_pos = task.pos
	var coord = task.coord
	var density_bytes = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4
	var material_bytes = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4 # uint per voxel

	# Create density and material buffers (will persist until readback)
	var dens_buf_terrain = rd.storage_buffer_create(density_bytes)
	var dens_buf_water = rd.storage_buffer_create(density_bytes)
	var mat_buf_terrain = rd.storage_buffer_create(material_bytes) # Material IDs

	# --- Dispatch Terrain Density (no sync) ---
	var u_density_t = RDUniform.new()
	u_density_t.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density_t.binding = 0
	u_density_t.add_id(dens_buf_terrain)

	var u_material_t = RDUniform.new()
	u_material_t.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_material_t.binding = 1
	u_material_t.add_id(mat_buf_terrain)

	var u_excavation_t = RDUniform.new()
	u_excavation_t.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_excavation_t.binding = 2
	u_excavation_t.add_id(_world_map_excavation_buffers.get(coord, _world_map_empty_excavation_buf))

	var set_gen_t = rd.uniform_set_create([u_density_t, u_material_t, u_excavation_t], sid_gen, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_gen)
	rd.compute_list_bind_uniform_set(list, set_gen_t, 0)

	# Always bind world map buffers on set 1 (real data or dummy)
	rd.compute_list_bind_uniform_set(list, _world_map_set1, 1)

	# Pass 0.0 for road spacing if disabled
	var actual_road_spacing = procedural_road_spacing if procedural_roads_enabled else 0.0
	var wide_shoulders_val = 1.0 if procedural_road_wide_shoulders else 0.0
	var use_world_map_val = 1.0 if world_map_active else 0.0
	var push_data_t = PackedFloat32Array([
		chunk_pos.x, chunk_pos.y, chunk_pos.z, wide_shoulders_val,
		noise_frequency, terrain_height, actual_road_spacing, procedural_road_width,
		use_world_map_val, world_map_size, world_map_half, world_map_max_height
	])
	rd.compute_list_set_push_constant(list, push_data_t.to_byte_array(), push_data_t.size() * 4)
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	# NO sync here!

	# --- Dispatch Water Density (no sync) ---
	var u_density_w = RDUniform.new()
	u_density_w.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density_w.binding = 0
	u_density_w.add_id(dens_buf_water)

	var set_gen_w = rd.uniform_set_create([u_density_w], sid_gen_water, 0)
	list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_gen_water)
	rd.compute_list_bind_uniform_set(list, set_gen_w, 0)
	rd.compute_list_bind_uniform_set(list, _world_map_water_set1, 1)
	var use_wm_w = 1.0 if world_map_active else 0.0
	var push_data_w = PackedFloat32Array([chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0, noise_frequency, water_level, use_wm_w, world_map_size, world_map_half, 0.0, 0.0, 0.0])
	rd.compute_list_set_push_constant(list, push_data_w.to_byte_array(), push_data_w.size() * 4)
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	# NO sync here!

	# Apply runtime terrain edits only.
	# Baked world-map excavation is injected directly into gen_density.glsl via _world_map_excavation_buffers.
	var mods_for_chunk = _get_modifications_for_chunk(coord)
	var needs_material_readback := false

	if mods_for_chunk.size() > 0:
		# Debug: show when mods are applied to underground chunks
		# Need to sync before modifications since they read/write density
		rd.submit()
		rd.sync()
		for mod in mods_for_chunk:
			if int(mod.get("material_id", -1)) >= 0:
				needs_material_readback = true
			var target_buffer = dens_buf_terrain if mod.layer == 0 else dens_buf_water
			_apply_modification_to_buffer(rd, sid_mod, pipe_mod, target_buffer, mat_buf_terrain, chunk_pos, mod)

	# Free uniform sets
	if set_gen_t.is_valid(): rd.free_rid(set_gen_t)
	if set_gen_w.is_valid(): rd.free_rid(set_gen_w)

	# Return in-flight data for later readback
	return {
		"coord": coord,
		"chunk_pos": chunk_pos,
		"dens_buf_terrain": dens_buf_terrain,
		"dens_buf_water": dens_buf_water,
		"mat_buf_terrain": mat_buf_terrain,
		"needs_material_readback": needs_material_readback,
		"needs_submit": mods_for_chunk.is_empty()
	}

# Dispatch terrain and water meshing without syncing so the whole chunk batch can complete together.
func _dispatch_chunk_meshing(rd: RenderingDevice, flight_data: Dictionary, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, vertex_buffer_water, counter_buffer_water) -> Dictionary:
	var chunk_pos = flight_data.chunk_pos
	var dens_buf_terrain = flight_data.dens_buf_terrain
	var dens_buf_water = flight_data.dens_buf_water
	var mat_buf_terrain = flight_data.mat_buf_terrain

	var set_mesh_t = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, dens_buf_terrain, mat_buf_terrain, chunk_pos, vertex_buffer_terrain, counter_buffer_terrain)
	var set_mesh_w = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, dens_buf_water, mat_buf_terrain, chunk_pos, vertex_buffer_water, counter_buffer_water)

	return {
		"flight_data": flight_data,
		"set_mesh_t": set_mesh_t,
		"set_mesh_w": set_mesh_w,
		"vertex_buffer_terrain": vertex_buffer_terrain,
		"counter_buffer_terrain": counter_buffer_terrain,
		"vertex_buffer_water": vertex_buffer_water,
		"counter_buffer_water": counter_buffer_water
	}

# Complete readback and queue to CPU workers (called after density and mesh syncs)
func _complete_chunk_readback(rd: RenderingDevice, readback: Dictionary):
	var flight_data: Dictionary = readback.flight_data
	var coord = flight_data.coord
	var chunk_pos = flight_data.chunk_pos
	var dens_buf_terrain = flight_data.dens_buf_terrain
	var dens_buf_water = flight_data.dens_buf_water
	var mat_buf_terrain = flight_data.mat_buf_terrain

	var mesh_data_terrain = run_gpu_meshing_readback(rd, readback.vertex_buffer_terrain, readback.counter_buffer_terrain, readback.set_mesh_t)
	var mesh_data_water = run_gpu_meshing_readback(rd, readback.vertex_buffer_water, readback.counter_buffer_water, readback.set_mesh_w)

	# Readback density for physics
	var cpu_density_bytes_w = rd.buffer_get_data(dens_buf_water)
	var cpu_density_floats_w = cpu_density_bytes_w.to_float32_array()
	var cpu_density_bytes_t = rd.buffer_get_data(dens_buf_terrain)
	var cpu_density_floats_t = cpu_density_bytes_t.to_float32_array()

	# Only material edits need a CPU material copy for per-chunk override textures.
	var cpu_material_bytes = PackedByteArray()
	if bool(flight_data.get("needs_material_readback", false)):
		cpu_material_bytes = rd.buffer_get_data(mat_buf_terrain)

	# Queue to CPU workers for mesh building

	cpu_mutex.lock()
	cpu_task_queue.append({
		"coord": coord,
		"chunk_pos": chunk_pos,
		"mesh_data_terrain": mesh_data_terrain,
		"mesh_data_water": mesh_data_water,
		"cpu_dens_w": cpu_density_floats_w,
		"cpu_dens_t": cpu_density_floats_t,
		"cpu_mat_t": cpu_material_bytes, # Material data for 3D texture
		"dens_buf_terrain": dens_buf_terrain,
		"dens_buf_water": dens_buf_water,
		"mat_buf_terrain": mat_buf_terrain # Material buffer for modify path
	})
	cpu_mutex.unlock()
	cpu_semaphore.post()

# GPU meshing dispatch only - NO sync, returns uniform set for later cleanup
func run_gpu_meshing_dispatch(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer) -> RID:
	# Reset Counter to 0
	var zero_data = PackedByteArray()
	zero_data.resize(8)
	zero_data.encode_u32(0, 0)
	zero_data.encode_u32(4, 0)
	rd.buffer_update(counter_buffer, 0, 8, zero_data)

	var u_vert = RDUniform.new()
	u_vert.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_vert.binding = 0
	u_vert.add_id(vertex_buffer)

	var u_count = RDUniform.new()
	u_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_count.binding = 1
	u_count.add_id(counter_buffer)

	var u_dens = RDUniform.new()
	u_dens.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_dens.binding = 2
	u_dens.add_id(density_buffer)

	var u_mat = RDUniform.new()
	u_mat.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_mat.binding = 3
	u_mat.add_id(material_buffer)

	var set_mesh = rd.uniform_set_create([u_vert, u_count, u_dens, u_mat], sid_mesh, 0)

	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mesh)
	rd.compute_list_bind_uniform_set(list, set_mesh, 0)

	var push_data = PackedFloat32Array([
		chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0,
		noise_frequency, terrain_height, 0.0, 0.0
	])
	rd.compute_list_set_push_constant(list, push_data.to_byte_array(), push_data.size() * 4)

	var groups = CHUNK_SIZE / 8
	rd.compute_list_dispatch(list, groups, groups, groups)
	rd.compute_list_end()
	# NO submit/sync here - caller handles it

	return set_mesh

# Readback packed mesh data AFTER sync has been called.
func run_gpu_meshing_readback(rd: RenderingDevice, vertex_buffer, counter_buffer, set_mesh: RID) -> Dictionary:
	# Read back vertex data
	var count_bytes = rd.buffer_get_data(counter_buffer)
	var tri_count = count_bytes.decode_u32(0)
	var vertex_count = tri_count * 3

	var output_format_magic := 0
	if count_bytes.size() >= 8:
		output_format_magic = count_bytes.decode_u32(4)

	var vertex_bytes = PackedByteArray()
	var vert_floats = PackedFloat32Array()
	if tri_count > 0:
		if output_format_magic == PACKED_OUTPUT_MAGIC:
			var total_bytes = vertex_count * PACKED_VERTEX_UINTS * 4
			vertex_bytes = rd.buffer_get_data(vertex_buffer, 0, total_bytes)
		else:
			var total_float_bytes = vertex_count * LEGACY_VERTEX_FLOATS * 4
			vert_floats = rd.buffer_get_data(vertex_buffer, 0, total_float_bytes).to_float32_array()

	if set_mesh.is_valid(): rd.free_rid(set_mesh)

	return {
		"bytes": vertex_bytes,
		"floats": vert_floats,
		"vertex_count": vertex_count,
		"packed": output_format_magic == PACKED_OUTPUT_MAGIC
	}

# Legacy function for modify path (still needs sync inline)
func run_gpu_meshing(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer) -> Dictionary:
	var set_mesh = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer)
	rd.submit()
	rd.sync()
	return run_gpu_meshing_readback(rd, vertex_buffer, counter_buffer, set_mesh)

# CPU Worker Thread - builds meshes and collision shapes (CPU intensive, parallelized)
func _cpu_thread_function():
	var builder = ClassDB.instantiate("MeshBuilder")
	if not builder:
		push_error("[ChunkManager] MeshBuilder GDExtension is required for CPU meshing.")
		return

	while true:
		cpu_semaphore.wait()

		mutex.lock()
		var should_exit = exit_thread
		mutex.unlock()

		cpu_mutex.lock()
		if cpu_task_queue.is_empty():
			cpu_mutex.unlock()
			if should_exit:
				break
			continue

		var task = cpu_task_queue.pop_back()
		cpu_mutex.unlock()

		# Build terrain mesh and collision (CPU intensive)
		var mesh_terrain = null
		var shape_terrain = null
		var mesh_data_terrain: Dictionary = task.get("mesh_data_terrain", {})
		if int(mesh_data_terrain.get("vertex_count", 0)) > 0:
			var built_terrain := build_packed_mesh_and_collision(mesh_data_terrain, material_terrain, builder)
			mesh_terrain = built_terrain.get("mesh", null)
			shape_terrain = built_terrain.get("shape", null)

		# Build water mesh and collision (CPU intensive)
		var mesh_water = null
		var shape_water = null
		var mesh_data_water: Dictionary = task.get("mesh_data_water", {})
		if int(mesh_data_water.get("vertex_count", 0)) > 0:
			var built_water := build_packed_mesh_and_collision(mesh_data_water, material_water, builder)
			mesh_water = built_water.get("mesh", null)
			shape_water = built_water.get("shape", null)

		# Package results
		var result_t = {"mesh": mesh_terrain, "shape": shape_terrain}
		var result_w = {"mesh": mesh_water, "shape": shape_water}

		# Send to main thread
		call_deferred("complete_generation", task.coord, result_t, task.dens_buf_terrain, result_w, task.dens_buf_water, task.cpu_dens_w, task.cpu_dens_t, task.mat_buf_terrain, task.cpu_mat_t)

# Helper to apply a single modification to a density buffer (used during generation replay)
func _apply_modification_to_buffer(rd: RenderingDevice, sid_mod, pipe_mod, density_buffer: RID, material_buffer: RID, chunk_pos: Vector3, mod: Dictionary):
	var u_density = RDUniform.new()
	u_density.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density.binding = 0
	u_density.add_id(density_buffer)

	# Add material buffer binding
	var u_material = RDUniform.new()
	u_material.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_material.binding = 1
	if material_buffer.is_valid():
		u_material.add_id(material_buffer)
	else:
		u_material.add_id(density_buffer) # Placeholder when material data is unavailable.

	var set_mod = rd.uniform_set_create([u_density, u_material], sid_mod, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mod)
	rd.compute_list_bind_uniform_set(list, set_mod, 0)

	var push_data = PackedByteArray()
	push_data.resize(48)
	var buffer = StreamPeerBuffer.new()
	buffer.data_array = push_data

	buffer.put_float(chunk_pos.x)
	buffer.put_float(chunk_pos.y)
	buffer.put_float(chunk_pos.z)
	buffer.put_float(0.0)

	buffer.put_float(mod.brush_pos.x)
	buffer.put_float(mod.brush_pos.y)
	buffer.put_float(mod.brush_pos.z)
	buffer.put_float(mod.radius)

	buffer.put_float(mod.value)
	buffer.put_32(mod.get("shape", 0))
	buffer.put_32(mod.get("material_id", -1)) # Material ID
	buffer.put_float(0.0) # Padding

	rd.compute_list_set_push_constant(list, buffer.data_array, buffer.data_array.size())
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	rd.submit()
	rd.sync()

	if set_mod.is_valid(): rd.free_rid(set_mod)

func process_modify(rd: RenderingDevice, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, vertex_buffer, counter_buffer, builder_override: Object = null):
	var density_buffer = task.rid
	var material_buffer = task.get("material_rid", RID()) # Material buffer from chunk
	var chunk_pos = task.pos
	var layer = task.get("layer", 0)
	var material_id = task.get("material_id", -1)


	var u_density = RDUniform.new()
	u_density.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density.binding = 0
	u_density.add_id(density_buffer)

	# Add material buffer binding
	var u_material = RDUniform.new()
	u_material.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_material.binding = 1
	if material_buffer.is_valid():
		u_material.add_id(material_buffer)
	else:
		u_material.add_id(density_buffer) # Placeholder when material data is unavailable.

	var set_mod = rd.uniform_set_create([u_density, u_material], sid_mod, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mod)
	rd.compute_list_bind_uniform_set(list, set_mod, 0)

	var push_data = PackedByteArray()
	push_data.resize(48)
	var buffer = StreamPeerBuffer.new()
	buffer.data_array = push_data

	# For Column shape (type=2), y_min is passed in chunk_offset.w
	var y_min_val = task.get("y_min", 0.0) if task.get("shape", 0) == 2 else 0.0

	buffer.put_float(chunk_pos.x)
	buffer.put_float(chunk_pos.y)
	buffer.put_float(chunk_pos.z)
	buffer.put_float(y_min_val) # chunk_offset.w = y_min for Column shape

	buffer.put_float(task.brush_pos.x)
	buffer.put_float(task.brush_pos.y)
	buffer.put_float(task.brush_pos.z)
	buffer.put_float(task.radius)

	# For Column shape (type=2), y_max is passed in last float
	var y_max_val = task.get("y_max", 0.0) if task.get("shape", 0) == 2 else 0.0

	buffer.put_float(task.value)
	buffer.put_32(task.get("shape", 0))
	buffer.put_32(material_id) # Material ID (int32)
	buffer.put_float(y_max_val) # y_max for Column shape

	rd.compute_list_set_push_constant(list, buffer.data_array, buffer.data_array.size())
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	rd.submit()
	rd.sync()

	if set_mod.is_valid(): rd.free_rid(set_mod)

	var material = material_terrain if layer == 0 else material_water
	var result = run_meshing(rd, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, material, vertex_buffer, counter_buffer, builder_override)

	var cpu_density_floats = PackedFloat32Array()
	# Read back density for this layer
	var cpu_density_bytes = rd.buffer_get_data(density_buffer)
	cpu_density_floats = cpu_density_bytes.to_float32_array()

	# Read back material buffer for 3D texture recreation
	var cpu_material_bytes = PackedByteArray()
	if material_buffer.is_valid():
		cpu_material_bytes = rd.buffer_get_data(material_buffer)

	var b_id = task.get("batch_id", -1)
	var b_count = task.get("batch_count", 1)
	var start_mod_version = task.get("start_mod_version", 0)

	call_deferred("complete_modification", task.coord, result, layer, b_id, b_count, cpu_density_floats, cpu_material_bytes, start_mod_version)

var _meshbuilder_logged: bool = false

func build_mesh(data: PackedFloat32Array, material_instance: Material, builder_override: Object = null) -> ArrayMesh:
	if data.size() == 0:
		return null

	var vertex_count = data.size() / 9 # 9 floats per vertex: pos(3) + normal(3) + color(3)

	var native_builder = builder_override
	if not native_builder:
		native_builder = ClassDB.instantiate("MeshBuilder")
		if not native_builder:
			push_error("[ChunkManager] MeshBuilder GDExtension is required for mesh building.")
			return null

	var native_mesh = native_builder.build_mesh_native(data, 9)
	if native_mesh:
		native_mesh.surface_set_material(0, material_instance)
		return native_mesh

	push_error("[ChunkManager] MeshBuilder.build_mesh_native() failed.")
	return null

	# Legacy native-path block kept unreachable for reference.
	if false:
		if not _meshbuilder_logged:
			_meshbuilder_logged = true
		var builder = ClassDB.instantiate("MeshBuilder")
		# 9 stride = pos(3) + norm(3) + col(3)
		var mesh = builder.build_mesh_native(data, 9)
		if mesh:
			mesh.surface_set_material(0, material_instance)
			return mesh

	# Legacy ArrayMesh assembly block.
	# Pre-allocate arrays
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var colors = PackedColorArray()
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)

	# Fill arrays directly (much faster than SurfaceTool)
	for i in range(vertex_count):
		var idx = i * 9
		vertices[i] = Vector3(data[idx], data[idx + 1], data[idx + 2])
		normals[i] = Vector3(data[idx + 3], data[idx + 4], data[idx + 5])
		colors[i] = Color(data[idx + 6], data[idx + 7], data[idx + 8])

	# Build ArrayMesh directly
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors

	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material_instance)

	return mesh

func build_mesh_and_collision(data: PackedFloat32Array, material_instance: Material, builder_override: Object = null) -> Dictionary:
	if data.size() == 0:
		return {"mesh": null, "shape": null}

	var native_builder = builder_override
	if not native_builder:
		native_builder = ClassDB.instantiate("MeshBuilder")
		if not native_builder:
			push_error("[ChunkManager] MeshBuilder GDExtension is required for mesh/collision building.")
			return {"mesh": null, "shape": null}

	if native_builder.has_method("build_mesh_and_collision"):
		var result: Dictionary = native_builder.build_mesh_and_collision(data, 9)
		var native_mesh = result.get("mesh", null)
		if native_mesh:
			native_mesh.surface_set_material(0, material_instance)
			result["mesh"] = native_mesh
		return result

	var mesh = build_mesh(data, material_instance, native_builder)
	var shape = null
	if mesh:
		shape = native_builder.build_collision_shape(data, 9)
	return {"mesh": mesh, "shape": shape}

func build_packed_mesh_and_collision(mesh_data: Dictionary, material_instance: Material, builder_override: Object = null) -> Dictionary:
	var vertex_count := int(mesh_data.get("vertex_count", 0))
	if not bool(mesh_data.get("packed", true)):
		var legacy_floats: PackedFloat32Array = mesh_data.get("floats", PackedFloat32Array())
		return build_mesh_and_collision(legacy_floats, material_instance, builder_override)

	var vertex_bytes: PackedByteArray = mesh_data.get("bytes", PackedByteArray())
	if vertex_count <= 0 or vertex_bytes.is_empty():
		return {"mesh": null, "shape": null}

	var native_builder = builder_override
	if not native_builder:
		native_builder = ClassDB.instantiate("MeshBuilder")
		if not native_builder:
			push_error("[ChunkManager] MeshBuilder GDExtension is required for packed mesh/collision building.")
			return {"mesh": null, "shape": null}

	if not native_builder.has_method("build_packed_mesh_and_collision"):
		push_error("[ChunkManager] MeshBuilder.build_packed_mesh_and_collision() is required for packed terrain meshes.")
		return {"mesh": null, "shape": null}

	var result: Dictionary = native_builder.build_packed_mesh_and_collision(vertex_bytes, vertex_count)
	var native_mesh = result.get("mesh", null)
	if native_mesh:
		native_mesh.surface_set_material(0, material_instance)
		result["mesh"] = native_mesh
	return result

func run_meshing(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, material_instance: Material, vertex_buffer, counter_buffer, builder_override: Object = null):
	# Reset Counter to 0
	var zero_data = PackedByteArray()
	zero_data.resize(8)
	zero_data.encode_u32(0, 0)
	zero_data.encode_u32(4, 0)
	rd.buffer_update(counter_buffer, 0, 8, zero_data)

	var u_vert = RDUniform.new()
	u_vert.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_vert.binding = 0
	u_vert.add_id(vertex_buffer)

	var u_count = RDUniform.new()
	u_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_count.binding = 1
	u_count.add_id(counter_buffer)

	var u_dens = RDUniform.new()
	u_dens.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_dens.binding = 2
	u_dens.add_id(density_buffer)

	var u_mat = RDUniform.new()
	u_mat.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_mat.binding = 3
	if material_buffer.is_valid():
		u_mat.add_id(material_buffer)
	else:
		# Placeholder when material data is unavailable.
		u_mat.add_id(density_buffer)

	var set_mesh = rd.uniform_set_create([u_vert, u_count, u_dens, u_mat], sid_mesh, 0)

	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mesh)
	rd.compute_list_bind_uniform_set(list, set_mesh, 0)

	var push_data = PackedFloat32Array([
		chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0,
		noise_frequency, terrain_height, 0.0, 0.0
	])
	rd.compute_list_set_push_constant(list, push_data.to_byte_array(), push_data.size() * 4)

	var groups = CHUNK_SIZE / 8
	rd.compute_list_dispatch(list, groups, groups, groups)
	rd.compute_list_end()

	rd.submit()
	rd.sync()

	# Read back
	var count_bytes = rd.buffer_get_data(counter_buffer)
	var tri_count = count_bytes.decode_u32(0)
	var output_format_magic := 0
	if count_bytes.size() >= 8:
		output_format_magic = count_bytes.decode_u32(4)

	var mesh = null
	var shape = null
	var builder = builder_override
	if not builder:
		builder = ClassDB.instantiate("MeshBuilder")
	if not builder:
		push_error("[ChunkManager] MeshBuilder GDExtension is required for mesh generation.")
		return {"mesh": null, "shape": null}

	if tri_count > 0:
		var vertex_count = tri_count * 3
		var built: Dictionary
		if output_format_magic == PACKED_OUTPUT_MAGIC:
			var total_bytes = vertex_count * PACKED_VERTEX_UINTS * 4
			var vertex_bytes = rd.buffer_get_data(vertex_buffer, 0, total_bytes)
			built = build_packed_mesh_and_collision({"bytes": vertex_bytes, "vertex_count": vertex_count, "packed": true}, material_instance, builder)
		else:
			var total_float_bytes = vertex_count * LEGACY_VERTEX_FLOATS * 4
			var vert_floats = rd.buffer_get_data(vertex_buffer, 0, total_float_bytes).to_float32_array()
			built = build_mesh_and_collision(vert_floats, material_instance, builder)
		mesh = built.get("mesh", null)
		shape = built.get("shape", null)

	if set_mesh.is_valid(): rd.free_rid(set_mesh)

	return {"mesh": mesh, "shape": shape}

func complete_generation(coord: Vector3i, result_t: Dictionary, dens_t: RID, result_w: Dictionary, dens_w: RID, cpu_dens_w: PackedFloat32Array, cpu_dens_t: PackedFloat32Array, mat_t: RID = RID(), cpu_mat_t: PackedByteArray = PackedByteArray()):
	if not active_chunks.has(coord):
		var tasks = []
		tasks.append({"type": "free", "rid": dens_t})
		tasks.append({"type": "free", "rid": dens_w})
		if mat_t.is_valid():
			tasks.append({"type": "free", "rid": mat_t})
		mutex.lock()
		for t in tasks: task_queue.append(t)
		mutex.unlock()
		for t in tasks: semaphore.post()
		return

	if initial_load_phase:
		chunks_loaded_initial += 1
		if chunks_loaded_initial >= initial_load_target_chunks:
			initial_load_phase = false

	pending_nodes_mutex.lock()

	pending_nodes.append({
		"type": "final_terrain",
		"coord": coord,
		"result": result_t,
		"dens": dens_t,
		"mat_buf": mat_t,
		"cpu_dens": cpu_dens_t,
		"cpu_mat": cpu_mat_t
	})

	# Task 2: Water (Lighter - ~2ms)
	pending_nodes.append({
		"type": "final_water",
		"coord": coord,
		"result": result_w,
		"dens": dens_w,
		"cpu_dens": cpu_dens_w
	})
	pending_nodes_needs_sort = true

	pending_nodes_mutex.unlock()

func _finalize_chunk_creation(item: Dictionary):
	if item.type == "final_terrain":
		var start = Time.get_ticks_usec()
		var coord = item.coord

		if not active_chunks.has(coord):
			_queue_pending_finalization_item_free(item)
			return

		var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)

		# Create Material
		var chunk_material = _create_chunk_material(chunk_pos, item.get("cpu_mat", PackedByteArray()))

		# Create Node (VISUALS ONLY)
		# Pass defer_collision=true to prevent create_chunk_node from creating a StaticBody3D/CollisionShape3D
		var result = create_chunk_node(item.result.mesh, null, chunk_pos, false, chunk_material, true)

		# Update Data
		var data = active_chunks[coord]
		if data == null:
			data = ChunkData.new()
			active_chunks[coord] = data

		data.node_terrain = result.node if not result.is_empty() else null

		# CRITICAL: Keep Shape3D resource alive!
		# If we don't store this, the RefCount goes to 0 -> RID freed -> No Collision
		data.terrain_shape = item.result.shape

		# Terrain collision is created lazily so we only keep live physics bodies
		# close to the player.
		var p_pos = get_viewer_position()
		var center_chunk = Vector3i(
			int(floor(p_pos.x / CHUNK_STRIDE)),
			int(floor(p_pos.y / CHUNK_STRIDE)),
			int(floor(p_pos.z / CHUNK_STRIDE))
		)
		var collision_distance_sq := collision_distance * collision_distance
		_sync_terrain_collision_state(coord, data, _should_have_terrain_collision(coord, center_chunk, collision_distance_sq))

		data.density_buffer_terrain = item.dens
		data.material_buffer_terrain = item.get("mat_buf", RID())
		data.cpu_density_terrain = item.cpu_dens
		data.chunk_material = chunk_material
		data.cpu_material_terrain = item.get("cpu_mat", PackedByteArray())

		# Spawn Zones
		call_deferred("emit_signal", "chunk_generated", coord, data.node_terrain)
		_check_spawn_zone_readiness(coord)

		_last_finalize_terrain_ms = float(Time.get_ticks_usec() - start) / 1000.0

	# REMOVED: final_collision block - handled in worker thread now!

	elif item.type == "final_water":
		var start = Time.get_ticks_usec()
		var coord = item.coord

		if not active_chunks.has(coord):
			_queue_pending_finalization_item_free(item)
			return
		var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)

		# Create Node
		var result = create_chunk_node(item.result.mesh, item.result.shape, chunk_pos, true)

		# Update Data
		var data = active_chunks[coord]
		if data == null:
			data = ChunkData.new()
			active_chunks[coord] = data

		data.node_water = result.node if not result.is_empty() else null
		data.density_buffer_water = item.dens
		data.cpu_density_water = item.cpu_dens

		_last_finalize_water_ms = float(Time.get_ticks_usec() - start) / 1000.0

## Create per-chunk ShaderMaterial with 3D material texture
func _create_chunk_material(_chunk_pos: Vector3, cpu_mat: PackedByteArray) -> ShaderMaterial:
	# The terrain shader currently derives world-space data from the node
	# transform, so chunks that do not have per-voxel material overrides can
	# safely share the base material. This avoids duplicating a unique
	# ShaderMaterial for every loaded chunk and keeps batching/state churn lower.
	if cpu_mat.is_empty() or not _chunk_has_player_material_overrides(cpu_mat):
		return material_terrain as ShaderMaterial

	var mat = material_terrain.duplicate() as ShaderMaterial

	# Create 3D texture from material data only when the chunk actually has
	# player-placed material overrides.
	var tex3d = _create_material_texture_3d(cpu_mat)
	if tex3d:
		mat.set_shader_parameter("material_map", tex3d)
		mat.set_shader_parameter("has_material_map", true)

	return mat

## Create ImageTexture3D from material buffer (uint8 per voxel)
func _create_material_texture_3d(cpu_mat: PackedByteArray) -> ImageTexture3D:
	# Material buffer is 33x33x33 uints (4 bytes each)
	# We only need the first byte (material ID 0-255)
	if cpu_mat.size() < DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4:
		return null

	var builder = _get_material_texture_builder()
	if not builder:
		push_error("[ChunkManager] MeshBuilder GDExtension is required for material texture creation.")
		return null

	return builder.create_material_texture(cpu_mat, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE)

func _get_material_texture_builder() -> Object:
	if _material_texture_builder:
		return _material_texture_builder

	_material_texture_builder = ClassDB.instantiate("MeshBuilder")
	return _material_texture_builder

func _chunk_has_player_material_overrides(cpu_mat: PackedByteArray) -> bool:
	if cpu_mat.is_empty():
		return false

	var builder = _get_material_texture_builder()
	if not builder:
		return false

	return builder.has_player_material_overrides(cpu_mat, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE)

func complete_modification(coord: Vector3i, result: Dictionary, layer: int, batch_id: int = -1, batch_count: int = 1, cpu_dens: PackedFloat32Array = PackedFloat32Array(), cpu_mat: PackedByteArray = PackedByteArray(), start_mod_version: int = 0):
	# For non-batched updates, do stale check here
	if batch_id == -1:
		# STALE CHECK for non-batched updates
		if active_chunks.has(coord):
			var chunk_data = active_chunks[coord]
			if chunk_data != null and start_mod_version > 0 and start_mod_version < chunk_data.mod_version:
				return
		_apply_chunk_update(coord, result, layer, cpu_dens, cpu_mat, start_mod_version)
		return

	# BATCHED UPDATES: Must track batch counter even for stale updates
	if not pending_batches.has(batch_id):
		pending_batches[batch_id] = {"received": 0, "expected": batch_count, "updates": []}

	var batch = pending_batches[batch_id]
	batch.received += 1  # Always increment, even if stale (to complete the batch)

	# Only add to updates list if not stale
	var is_stale = false
	if active_chunks.has(coord):
		var chunk_data = active_chunks[coord]
		if chunk_data != null and start_mod_version > 0 and start_mod_version < chunk_data.mod_version:
			is_stale = true

	if not is_stale and active_chunks.has(coord):
		batch.updates.append({"coord": coord, "result": result, "layer": layer, "cpu_dens": cpu_dens, "cpu_mat": cpu_mat, "start_mod_version": start_mod_version})

	if batch.received >= batch.expected:
		for update in batch.updates:
			_apply_chunk_update(update.coord, update.result, update.layer, update.cpu_dens, update.get("cpu_mat", PackedByteArray()), update.get("start_mod_version", 0))
		pending_batches.erase(batch_id)

func _apply_chunk_update(coord: Vector3i, result: Dictionary, layer: int, cpu_dens: PackedFloat32Array, cpu_mat: PackedByteArray = PackedByteArray(), start_mod_version: int = 0):
	if not active_chunks.has(coord):
		return
	var data = active_chunks[coord]

	# STALE CHECK: Secondary check at application time (for batched updates)
	if data != null and start_mod_version > 0 and start_mod_version < data.mod_version:
		return

	var update_start_us := Time.get_ticks_usec()
	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)

	if layer == 0: # Terrain
		# CRITICAL: Free the PhysicsServer body RID first (contains stale collision)
		if terrain_grid and terrain_grid.has_method("set_chunk_collision_ready"):
			terrain_grid.set_chunk_collision_ready(coord, false)
		pending_terrain_collision_creates.erase(coord)
		if data.body_rid_terrain.is_valid():
			PhysicsServer3D.free_rid(data.body_rid_terrain)
			data.body_rid_terrain = RID() # Clear to prevent double-free
		if data.node_terrain: data.node_terrain.queue_free()

		# Recreate chunk material with updated 3D texture
		var chunk_material = _create_chunk_material(chunk_pos, cpu_mat)

		var result_node = create_chunk_node(result.mesh, result.shape, chunk_pos, false, chunk_material)
		data.node_terrain = result_node.node if not result_node.is_empty() else null
		data.collision_shape_terrain = result_node.collision_shape if not result_node.is_empty() else null
		data.chunk_material = chunk_material
		if not cpu_dens.is_empty():
			data.cpu_density_terrain = cpu_dens
		if not cpu_mat.is_empty():
			data.cpu_material_terrain = cpu_mat
		var p_pos = get_viewer_position()
		var center_chunk = Vector3i(
			int(floor(p_pos.x / CHUNK_STRIDE)),
			int(floor(p_pos.y / CHUNK_STRIDE)),
			int(floor(p_pos.z / CHUNK_STRIDE))
		)
		var collision_distance_sq := collision_distance * collision_distance
		_sync_terrain_collision_state(coord, data, _should_have_terrain_collision(coord, center_chunk, collision_distance_sq))
		# Signal vegetation manager that chunk node changed (update references, don't regenerate)
		chunk_modified.emit(coord, data.node_terrain)
	else: # Water
		if data.node_water: data.node_water.queue_free()
		var result_node = create_chunk_node(result.mesh, result.shape, chunk_pos, true)
		data.node_water = result_node.node if not result_node.is_empty() else null
		if not cpu_dens.is_empty():
			data.cpu_density_water = cpu_dens
	_last_chunk_update_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0

func create_chunk_node(mesh: ArrayMesh, shape: Shape3D, position: Vector3, is_water: bool = false, custom_material: Material = null, defer_collision: bool = false) -> Dictionary:
	if mesh == null:
		return {}

	var node: Node3D

	if is_water:
		node = Area3D.new()
		node.add_to_group("water")
		# Ensure it's monitorable so the player can detect it
		node.monitorable = true
		node.monitoring = false # Terrain chunks don't need to monitor others
	elif defer_collision:
		node = Node3D.new()
		node.add_to_group("terrain")
	else:
		node = StaticBody3D.new()
		node.collision_layer = 1 | 512 # Terrain layer + Special layer for pickups
		node.add_to_group("terrain")

	node.position = position

	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = mesh

	# Apply per-chunk material if provided, otherwise mesh uses its surface material
	if custom_material:
		mesh_instance.material_override = custom_material

	# If water, we might want to ensure it's not casting shadows or has specific render flags if needed,
	# but the material handles most transparency.
	if is_water:
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	node.add_child(mesh_instance)

	var collision_shape: CollisionShape3D = null
	if not defer_collision:
		collision_shape = CollisionShape3D.new()
		if shape:
			collision_shape.shape = shape
		node.add_child(collision_shape)

	# Optimization: Add to tree LAST to perform single update
	add_child(node)

	# Return both node and collision_shape for tracking
	return {"node": node, "collision_shape": collision_shape}

# ============ SPAWN ZONE API ============
# These methods enable save/load to wait for terrain before spawning players/entities

## Request priority loading of chunks around a spawn position
## The spawn_zones_ready signal will be emitted when all chunks are loaded
func request_spawn_zone(position: Vector3, radius: int = 2):
	var chunk_x = int(floor(position.x / CHUNK_STRIDE))
	var chunk_y = int(floor(position.y / CHUNK_STRIDE))
	var chunk_z = int(floor(position.z / CHUNK_STRIDE))

	# RESET LOADING PHASE for Save/Load tracking
	initial_load_phase = true
	# Target chunks in a square/circle around spawn (radius 2 = 5x5 chunks = 25 chunks)
	# But request_spawn_zone also checks Y-1, 0, +1 layers (3 layers).
	initial_load_target_chunks = (radius * 2 + 1) * (radius * 2 + 1) * 3
	chunks_loaded_initial = 0

	var pending_coords: Array[Vector3i] = []

	# Collect chunks in radius and request generation for any not loaded
	for dx in range(-radius, radius + 1):
		for dy in range(-1, 2): # Only check Y layers -1, 0, +1 around spawn
			for dz in range(-radius, radius + 1):
				var coord = Vector3i(chunk_x + dx, chunk_y + dy, chunk_z + dz)

				# Skip if already loaded with data
				if active_chunks.has(coord) and active_chunks[coord] != null:
					continue

				# Mark as pending
				if not active_chunks.has(coord):
					active_chunks[coord] = null
					var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
					var task = {
						"type": "generate",
						"coord": coord,
						"pos": chunk_pos
					}
					mutex.lock()
					priority_task_queue.append(task)
					mutex.unlock()
					semaphore.post()
				pending_coords.append(coord)

	if pending_coords.is_empty():
		# All chunks already loaded - emit immediately
		_capture_terrain_telemetry("spawn_zone_ready_immediate", {
			"position": str(position),
			"radius": radius
		})
		call_deferred("emit_signal", "spawn_zones_ready", [position])
	else:
		# Track this spawn zone
		pending_spawn_zones.append({
			"position": position,
			"radius": radius,
			"pending_coords": pending_coords
		})
		_capture_terrain_telemetry("spawn_zone_requested", {
			"position": str(position),
			"radius": radius,
			"pending_coords": pending_coords.size()
		})

## Check if chunks around a position are ready (loaded with data)
func are_chunks_ready_around(position: Vector3, radius: int = 2) -> bool:
	var chunk_x = int(floor(position.x / CHUNK_STRIDE))
	var chunk_y = int(floor(position.y / CHUNK_STRIDE))
	var chunk_z = int(floor(position.z / CHUNK_STRIDE))

	for dx in range(-radius, radius + 1):
		for dy in range(-1, 2):
			for dz in range(-radius, radius + 1):
				var coord = Vector3i(chunk_x + dx, chunk_y + dy, chunk_z + dz)
				# Not loaded or still pending (null)
				if not active_chunks.has(coord) or active_chunks[coord] == null:
					return false
	return true


func is_collision_ready_at(position: Vector3) -> bool:
	if terrain_grid and terrain_grid.has_method("is_collision_ready_at"):
		return terrain_grid.is_collision_ready_at(position, CHUNK_STRIDE)

	var chunk_x = int(floor(position.x / CHUNK_STRIDE))
	var chunk_y = int(floor(position.y / CHUNK_STRIDE))
	var chunk_z = int(floor(position.z / CHUNK_STRIDE))

	for dy in range(-1, 2):
		var coord = Vector3i(chunk_x, chunk_y + dy, chunk_z)
		if not active_chunks.has(coord):
			continue

		var data = active_chunks[coord]
		if data != null and data.body_rid_terrain.is_valid():
			return true

	return false

## Called when a chunk completes generation - checks if any spawn zones are now ready
func _check_spawn_zone_readiness(completed_coord: Vector3i):
	if pending_spawn_zones.is_empty():
		return

	var zones_to_remove: Array[int] = []
	var ready_positions: Array[Vector3] = []

	for i in range(pending_spawn_zones.size()):
		var zone = pending_spawn_zones[i]
		zone.pending_coords.erase(completed_coord)

		if zone.pending_coords.is_empty():
			zones_to_remove.append(i)
			ready_positions.append(zone.position)

	# Remove completed zones (reverse order to preserve indices)
	for i in range(zones_to_remove.size() - 1, -1, -1):
		pending_spawn_zones.remove_at(zones_to_remove[i])

	# Emit signal if any zones completed
	if not ready_positions.is_empty():
		# TERMINATE INITIAL LOAD PHASE: Switch to slower/throttled exploration mode
		if initial_load_phase:
			initial_load_phase = false
			_capture_terrain_telemetry("initial_load_complete", {
				"ready_positions": ready_positions.size()
			})

		spawn_zones_ready.emit(ready_positions)

## Request multiple spawn zones at once (for batch loading player + entities)
func request_spawn_zones(positions: Array[Vector3], radius: int = 2):
	for pos in positions:
		request_spawn_zone(pos, radius)
