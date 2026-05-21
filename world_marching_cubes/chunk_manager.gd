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
const MaterialRegistry = preload("res://modules/world_generation/material_registry.gd")
const BuildingVisuals = preload("res://world_building_system/building_visuals.gd")
const RenderResourcePrewarm = preload("res://world_render_prewarm/render_resource_prewarm.gd")

# Y-layer limits for vertical chunk stacking
const MIN_Y_LAYER = -20 # How deep you can dig (in chunk layers)
const MAX_Y_LAYER = 40 # How high you can build (in chunk layers)

# Max triangles estimation
const MAX_TRIANGLES = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 5
const PACKED_VERTEX_UINTS = 6 # pos.xyz float32 + normal.xyz float16 + packed material payload
const LEGACY_VERTEX_FLOATS = 9
const PACKED_OUTPUT_MAGIC = 0x5041434B # "PACK"
const PACKED_INDEXED_OUTPUT_MAGIC = 0x58444950 # "PIDX"

@export var viewer: Node3D
@export var render_distance: int = 5 # Visual range
@export var terrain_height: float = 10.0
@export var water_level: float = 13.0 # Lowered to keep roads dry
@export var water_render_enabled: bool = true
@export var terrain_skip_dry_water_density_dispatch: bool = true
@export var water_screen_refraction_enabled: bool = false
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
@export var distant_world_map_lod_enabled: bool = false
@export_range(1, 64, 1) var distant_world_map_lod_distance: int = 10
@export_range(0, 8, 1) var distant_world_map_lod_overlap: int = 2
@export_range(1, 16, 1) var distant_world_map_lod_sample_step: int = 4
@export_range(1, 16, 1) var distant_world_map_lod_budget_per_frame: int = 2
@export var distant_world_map_lod_defer_until_initial_viewer_move: bool = true
@export var terrain_visual_batching_enabled: bool = true
@export var procedural_terrain_visual_batching_enabled: bool = true
@export_range(1, 16, 1) var terrain_visual_batch_size: int = 2
@export var world_map_visual_batch_profile_enabled: bool = true
@export_range(1, 16, 1) var world_map_terrain_visual_batch_size: int = 3
@export_range(1, 8, 1) var terrain_visual_batch_rebuilds_per_frame: int = 1
@export_range(0, 16, 1) var terrain_visual_batch_cached_rebuilds_per_frame: int = 4
@export_range(0.1, 5.0, 0.1) var terrain_visual_batch_cached_rebuild_budget_ms: float = 0.75
@export var terrain_visual_batch_async_build_enabled: bool = true
@export var terrain_visual_batch_async_during_streaming: bool = true
@export_range(1, 16, 1) var terrain_visual_batch_async_builds_per_frame: int = 1
@export_range(0, 8, 1) var terrain_visual_batch_streaming_async_queue_per_frame: int = 1
@export_range(1, 64, 1) var terrain_visual_batch_async_build_queue_limit: int = 8
@export_range(1, 16, 1) var terrain_visual_batch_async_apply_per_frame: int = 4
@export_range(0.1, 5.0, 0.1) var terrain_visual_batch_async_apply_budget_ms: float = 1.0
@export_range(1, 60, 1) var terrain_visual_batch_hot_rebuild_interval_frames: int = 2
@export_range(1, 512, 1) var terrain_visual_batch_hot_rebuild_dirty_threshold: int = 8
@export_range(0, 200000, 1000) var terrain_visual_batch_max_vertices: int = 48000
@export_range(0, 200000, 1000) var world_map_terrain_visual_batch_max_vertices: int = 200000
@export_range(0, 8, 1) var procedural_terrain_visual_batch_near_cull_radius_chunks: int = 0
@export var terrain_shadow_lod_enabled: bool = true
@export_range(0, 32, 1) var terrain_shadow_lod_radius_chunks: int = 2
@export_range(0, 2048, 16) var terrain_visual_batch_mesh_cache_limit: int = 512
@export var terrain_visual_batch_idle_polish_enabled: bool = true
@export var water_visual_batching_enabled: bool = true
@export var procedural_water_visual_batching_enabled: bool = true
@export_range(1, 16, 1) var water_visual_batch_size: int = 2
@export_range(1, 16, 1) var world_map_water_visual_batch_size: int = 3
@export_range(1, 8, 1) var water_visual_batch_rebuilds_per_frame: int = 1
@export_range(0, 200000, 1000) var water_visual_batch_max_vertices: int = 48000
@export_range(0, 200000, 1000) var world_map_water_visual_batch_max_vertices: int = 200000
@export_range(0, 8, 1) var procedural_water_visual_batch_near_cull_radius_chunks: int = 0
var world_map_active: bool = false
var world_map_size: float = 2048.0
var world_map_half: float = 1024.0
var world_map_max_height: float = 50.0  # terrain_height * 2.5
var _world_map_heightmap_buf: RID = RID()
var _world_map_biome_buf: RID = RID()
var _world_map_road_buf: RID = RID()
var _world_map_water_buf: RID = RID()
var _world_map_empty_excavation_buf: RID = RID()
var _world_map_heightmap_data: PackedByteArray = PackedByteArray()
var _world_map_heightmap_width: int = 0
var _world_map_heightmap_height: int = 0
var _world_map_biome_image: Image = null
var _world_map_biome_texture: ImageTexture = null
var _world_map_road_image: Image = null
var _world_map_road_texture: ImageTexture = null
var _world_map_water_image: Image = null
var _world_map_set1: RID = RID()  # Uniform set 1 for terrain shader world map bindings
var _world_map_water_set1: RID = RID()  # Uniform set 1 for water shader
var _world_map_buildings: Array = []  # Baked building positions from world_meta.json
var _world_map_building_map: Image = null  # R8 building footprint map from buildings.png
var _world_map_excavation_masks: Dictionary = {}
var _world_map_excavation_buffers: Dictionary = {}
var gpu_biome_map: PackedByteArray = PackedByteArray()  # Baked biome/material bytes for minimap compatibility

# GPU Threading (single thread for compute shaders)
var compute_thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var exit_thread: bool = false
var _shutdown_cleanup_started: bool = false
var _shutdown_cpu_workers_finished: bool = true

# CPU Worker Pool (for mesh building and collision)
# Dynamically scale workers based on available CPU cores (leave 2 for OS/Main Thread)
var _cpu_worker_count: int = max(2, OS.get_processor_count() - 2)
var cpu_threads: Array[Thread] = []
var cpu_task_queue: Array[Dictionary] = []
var cpu_mutex: Mutex
var cpu_semaphore: Semaphore
var completed_generation_queue: Array[Dictionary] = []
var completed_generation_mutex: Mutex
var stored_modifications_mutex: Mutex

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
var _chunk_node_root: Node3D = null
var _material_texture_builder: Object = null
var _cached_vehicle_manager: Node = null
var _cached_building_manager: Node = null
var _cached_prefab_spawner: Node = null
var _cached_vegetation_manager: Node = null

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
	var terrain_collision_enabled: bool = false
	var terrain_collision_body_in_space: bool = false
	var terrain_collision_ready: bool = false
	var terrain_collision_ready_reported: bool = false
	var terrain_collision_shared_shape_index: int = -1
	var terrain_visual_mesh: ArrayMesh = null
	var terrain_visual_batched: bool = false
	var water_visual_mesh: ArrayMesh = null
	var water_visual_batched: bool = false
	# CPU mirrors for physics detection
	var cpu_density_water: PackedFloat32Array = PackedFloat32Array()
	var generated_water_density_available: bool = false
	var cpu_density_terrain: PackedFloat32Array = PackedFloat32Array()
	# Compact top-down terrain surface cache. This replaces full density reads
	# for normal generated chunks while keeping vegetation/height queries fast.
	var cpu_height_map_terrain: PackedFloat32Array = PackedFloat32Array()
	var cpu_height_map_size: int = 0
	# CPU mirror for materials (for 3D texture creation)
	var cpu_material_terrain: PackedByteArray = PackedByteArray()
	# 3D texture for fragment shader sampling
	var material_texture: ImageTexture3D = null
	var chunk_material: ShaderMaterial = null # Per-chunk material instance
	# Modification version - incremented on each modify, used to skip stale updates
	var mod_version: int = 0
	var water_mod_version: int = 0

var active_chunks: Dictionary = {}

# Collision distance - only enable collision within this range (cheaper than render_distance)
@export var collision_distance: int = 3 # Chunks within this get collision
@export var collision_prewarm_distance: int = 5 # Disabled bodies prepared ahead of fast vehicle/player motion
@export_range(0, 512, 1) var terrain_collision_body_cache_limit: int = 256
@export var keep_disabled_terrain_collision_bodies_in_space: bool = true
@export var shared_terrain_collision_body_enabled: bool = true
@export_range(1, 8, 1) var shared_terrain_collision_cluster_size: int = 2
@export_range(1, 64, 1) var shared_terrain_collision_create_budget_per_frame: int = 1

# Time-budgeted node creation - prevents stutters from multiple chunks completing at once
var pending_nodes: Array[Dictionary] = [] # Queue of completed chunks waiting for node creation
var pending_nodes_mutex: Mutex
var pending_nodes_needs_sort: bool = false
var _pending_nodes_sort_center: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _pending_nodes_sort_size_at_last_sort: int = 0
var _last_pending_node_sort_ms: float = 0.0
var _last_pending_node_sort_count: int = 0
var _last_pending_node_sort_skipped: bool = false
var _last_pending_node_finalize_count: int = 0
@export_range(1, 256, 1) var pending_node_resort_growth_threshold: int = 64
@export_range(1, 64, 1) var pending_node_finalize_max_per_frame: int = 8
@export_range(1, 128, 1) var pending_node_initial_finalize_max_per_frame: int = 32
@export_range(1, 8, 1) var pending_node_runtime_render_commits_per_frame: int = 1
@export_range(1, 16, 1) var spawn_zone_pending_node_finalize_max_per_frame: int = 2
@export_range(0.1, 5.0, 0.1) var spawn_zone_pending_node_finalize_budget_ms: float = 0.75

# Budgeted finalization - spreads chunk appearances without letting ready chunks starve.
var last_finalization_time_ms: int = 0
## Legacy editor knob retained for saved scenes; finalization now uses frame budgets.
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
@export var terrain_gpu_separate_water_meshing: bool = false
@export_range(1, 8, 1) var terrain_gpu_mesh_slices_per_chunk: int = 1
@export_range(0, 20, 1) var terrain_gpu_mesh_slice_delay_ms: int = 2
@export var terrain_native_cpu_meshing_enabled: bool = true

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
@export_range(0, 60, 1) var render_resource_prewarm_frames: int = 12
@export_range(0, 256, 1) var spawn_zone_far_reset_distance_chunks: int = 16
@export_range(1, 128, 1) var retired_chunk_node_cleanup_budget_per_frame: int = 24
@export var runtime_power_mode_enabled: bool = true
@export_range(30, 240, 1) var runtime_power_active_max_fps: int = 60
@export_range(30, 120, 1) var runtime_power_idle_max_fps: int = 30
@export_range(30, 120, 1) var runtime_power_deep_idle_max_fps: int = 30
@export_range(0.1, 10.0, 0.1) var runtime_power_idle_enter_delay_s: float = 1.25
@export_range(1.0, 60.0, 0.5) var runtime_power_deep_idle_enter_delay_s: float = 10.0
@export_range(0.0, 5.0, 0.1) var runtime_power_active_grace_s: float = 0.75
@export_range(0.001, 1.0, 0.001) var runtime_power_position_epsilon: float = 0.10
@export_range(0.001, 0.1, 0.001) var runtime_power_orientation_epsilon: float = 0.01
@export var runtime_power_suspend_render_loop_in_deep_idle: bool = true
@export var runtime_power_suspend_background_world_work: bool = true
@export var runtime_power_viewport_scaling_enabled: bool = false
@export_range(0.5, 1.0, 0.01) var runtime_power_active_3d_scale: float = 1.0
@export_range(0.5, 1.0, 0.01) var runtime_power_idle_3d_scale: float = 1.0
@export_range(0.5, 1.0, 0.01) var runtime_power_deep_idle_3d_scale: float = 1.0
var _last_frame_ms: float = 0.0
var _hot_frame_backoff_remaining_frames: int = 0
var skip_terrain_chunk_updates_for_test: bool = false
var terrain_grid = null
var _native_backends_ready: bool = false
var _runtime_power_mode: String = "active"
var _runtime_power_target_fps: int = 0
var _runtime_power_idle_seconds: float = 0.0
var _runtime_power_active_grace_remaining_s: float = 0.0
var _runtime_power_last_viewer_pos: Vector3 = Vector3(1.0e20, 1.0e20, 1.0e20)
var _runtime_power_last_view_forward: Vector3 = Vector3(1.0e20, 1.0e20, 1.0e20)
var _runtime_power_active_frame_count: int = 0
var _runtime_power_idle_frame_count: int = 0
var _runtime_power_deep_idle_frame_count: int = 0
var _runtime_power_active_reason: String = "startup"
var _runtime_power_terrain_busy_last: bool = false
var _runtime_power_foreground_terrain_busy_last: bool = false
var _runtime_power_external_world_busy_last: bool = false
var _runtime_power_viewer_moved_last: bool = false
var _runtime_power_disabled_reason: String = ""
var _runtime_power_render_loop_suspended: bool = false
var _runtime_power_render_loop_restore_enabled: bool = true
var _runtime_power_render_loop_restore_captured: bool = false
var _runtime_power_world_work_suspended: bool = false
var _runtime_power_world_work_suspended_frame_count: int = 0
var _runtime_power_world_work_suspend_count: int = 0
var _runtime_power_world_work_resume_count: int = 0
var _runtime_power_world_work_suspend_reason: String = ""
var _runtime_power_world_work_resume_reason: String = "startup"
var _runtime_power_recent_events: Array[Dictionary] = []
var _runtime_power_viewport_scale_supported: bool = false
var _runtime_power_viewport_scale_original: float = 1.0
var _runtime_power_viewport_scale_current: float = 1.0
var _runtime_power_viewport_scale_captured: bool = false
var _last_update_loads: int = 0
var _last_update_unloads: int = 0
var _last_fallback_unloads: int = 0
var _last_fallback_unload_ms: float = 0.0
var _last_native_grid_active_chunk_count: int = 0
var _last_update_backend: String = ""
var _last_terrain_stream_update_center_chunk: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _last_terrain_stream_update_render_distance: int = -1
var _last_terrain_stream_update_loading_paused: bool = false
var _last_terrain_stream_update_gate_reason: String = ""
var _terrain_stream_update_idle_skip_count: int = 0
var _last_terrain_finalization_defer_reason: String = ""
var _last_update_duration_ms: float = 0.0
var _last_pending_node_process_ms: float = 0.0
var _last_completed_generation_drain_ms: float = 0.0
var _last_completed_generation_drain_count: int = 0
var _last_gpu_generation_dispatch_ms: float = 0.0
var _last_gpu_generation_dispatch_coord: Vector3i = Vector3i.ZERO
var _last_gpu_generation_mod_sync_ms: float = 0.0
var _last_gpu_generation_batch_ms: float = 0.0
var _last_gpu_generation_batch_chunk_count: int = 0
var _last_gpu_generation_sync_ms: float = 0.0
var _last_gpu_meshing_dispatch_ms: float = 0.0
var _last_gpu_meshing_sync_ms: float = 0.0
var _last_gpu_mesh_readback_ms: float = 0.0
var _last_gpu_mesh_readback_chunk_count: int = 0
var _last_gpu_mesh_readback_terrain_vertices: int = 0
var _last_gpu_mesh_readback_water_vertices: int = 0
var _last_gpu_mesh_slice_count: int = 0
var _last_gpu_mesh_slice_max_sync_ms: float = 0.0
var _last_gpu_water_density_dispatched: bool = false
var _gpu_water_density_skipped_count: int = 0
var _last_gpu_water_density_skipped_coord: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _last_gpu_generation_batch_event_id: int = 0
var _last_cpu_mesh_build_ms: float = 0.0
var _last_cpu_mesh_build_terrain_ms: float = 0.0
var _last_cpu_mesh_build_water_ms: float = 0.0
var _last_cpu_mesh_build_queue_wait_ms: float = 0.0
var _last_cpu_mesh_build_terrain_vertices: int = 0
var _last_cpu_mesh_build_water_vertices: int = 0
var _last_cpu_mesh_build_coord: Vector3i = Vector3i.ZERO
var _last_cpu_mesh_build_event_id: int = 0
var _last_finalize_terrain_ms: float = 0.0
var _last_finalize_water_ms: float = 0.0
var _last_chunk_update_ms: float = 0.0
var _last_modify_terrain_ms: float = 0.0
var _last_world_map_entry_ms: float = 0.0
var _last_spawn_zone_far_reset_ms: float = 0.0
var _last_spawn_zone_far_reset_cleared_chunks: int = 0
var _spawn_zone_far_reset_count: int = 0
var _generated_water_surface_skip_count: int = 0
var _last_generated_water_surface_skip_coord: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _last_retired_chunk_node_cleanup_ms: float = 0.0
var _last_retired_chunk_node_cleanup_count: int = 0
var _retired_chunk_node_roots: Array[Node3D] = []
var _last_world_map_load_profile: Dictionary = {}
var _startup_world_map_data: Dictionary = {}
var _startup_world_map_load_profile: Dictionary = {}
var _world_map_lod_chunks: Dictionary = {}
var _world_map_lod_merged_node: MeshInstance3D = null
var _world_map_lod_builder: Object = null
var _world_map_lod_material: ShaderMaterial = null
var _world_map_lod_load_candidates: Array[Vector2i] = []
var _world_map_lod_unload_candidates: Array[Vector2i] = []
var _world_map_lod_load_cursor: int = 0
var _world_map_lod_unload_cursor: int = 0
var _world_map_lod_sort_center: Vector2i = Vector2i.ZERO
var _last_world_map_lod_center: Vector2i = Vector2i(2147483647, 2147483647)
var _last_world_map_lod_inner_distance: int = -1
var _last_world_map_lod_outer_distance: int = -1
var _last_world_map_lod_update_ms: float = 0.0
var _last_world_map_lod_merge_ms: float = 0.0
var _last_world_map_lod_loads: int = 0
var _last_world_map_lod_unloads: int = 0
var _last_world_map_lod_deferred: bool = false
var _last_world_map_lod_throttled_update: bool = false
var _world_map_lod_initial_viewer_chunk: Vector2i = Vector2i(2147483647, 2147483647)
var _world_map_lod_initial_defer_released: bool = false
var _dry_water_density_bytes: PackedByteArray = PackedByteArray()
var _terrain_visual_batch_root: Node3D = null
var _terrain_visual_batches: Dictionary = {}
var _terrain_visual_batch_members: Dictionary = {}
var _terrain_visual_batch_dirty: Dictionary = {}
var _terrain_visual_batch_mesh_cache: Dictionary = {}
var _terrain_visual_batch_mesh_cache_order: Array[String] = []
var _terrain_visual_batch_builds_in_flight: Dictionary = {}
var _completed_terrain_visual_batch_builds: Array[Dictionary] = []
var _completed_terrain_visual_batch_mutex: Mutex
var _terrain_visual_batch_builder: Object = null
var _last_terrain_visual_batch_rebuild_ms: float = 0.0
var _last_terrain_visual_batch_rebuild_count: int = 0
var _last_terrain_visual_batch_hidden_chunk_count: int = 0
var _last_terrain_visual_batch_vertex_count: int = 0
var _last_terrain_visual_batch_index_count: int = 0
var _last_terrain_visual_batch_skipped_heavy_count: int = 0
var _last_terrain_visual_batch_cache_hit: bool = false
var _last_terrain_visual_batch_cached_rebuild_count: int = 0
var _last_terrain_visual_batch_cached_rebuild_ms: float = 0.0
var _last_terrain_visual_batch_cached_rebuild_attempts: int = 0
var _last_terrain_visual_batch_async_queued_count: int = 0
var _last_terrain_visual_batch_streaming_async_queued_count: int = 0
var _last_terrain_visual_batch_async_apply_count: int = 0
var _last_terrain_visual_batch_async_apply_ms: float = 0.0
var _last_terrain_visual_batch_async_stale_count: int = 0
var _last_terrain_visual_batch_idle_polish: bool = false
var _terrain_visual_batch_idle_polish_frame_count: int = 0
var _terrain_visual_batch_mesh_cache_hits: int = 0
var _terrain_visual_batch_mesh_cache_misses: int = 0
var _terrain_visual_batch_total_heavy_skips: int = 0
var _terrain_visual_batch_stream_idle_frames: int = 0
var _terrain_visual_batch_hot_rebuild_frame_counter: int = 0
var _last_terrain_visual_batch_hot_rebuild: bool = false
var _last_effective_terrain_visual_batch_size: int = -1
var _last_effective_terrain_visual_batch_max_vertices: int = -1
var _last_effective_terrain_visual_batch_near_cull_radius: int = -1
var _terrain_visual_mesh_retire_queue: Array[Vector3i] = []
var _terrain_visual_mesh_retire_queued: Dictionary = {}
@export_range(1, 64, 1) var terrain_visual_mesh_retire_budget_per_frame: int = 16
var _water_visual_batch_root: Node3D = null
var _water_visual_batches: Dictionary = {}
var _water_visual_batch_members: Dictionary = {}
var _water_visual_batch_dirty: Dictionary = {}
var _last_water_visual_batch_rebuild_ms: float = 0.0
var _last_water_visual_batch_rebuild_count: int = 0
var _last_water_visual_batch_hidden_chunk_count: int = 0
var _last_water_visual_batch_vertex_count: int = 0
var _last_water_visual_batch_index_count: int = 0
var _last_water_visual_batch_skipped_heavy_count: int = 0
var _water_visual_batch_total_heavy_skips: int = 0
var _last_effective_water_visual_batch_size: int = -1
var _last_effective_water_visual_batch_max_vertices: int = -1
var _last_effective_water_visual_batch_near_cull_radius: int = -1
var _last_visual_batch_near_cull_viewer_chunk: Vector2i = Vector2i(2147483647, 2147483647)
var _last_terrain_shadow_lod_enabled_count: int = 0
var _last_terrain_shadow_lod_disabled_count: int = 0
var _last_terrain_shadow_lod_update_count: int = 0
var _last_terrain_shadow_lod_ms: float = 0.0
var _last_terrain_shadow_lod_viewer_chunk: Vector2i = Vector2i(2147483647, 2147483647)
var _last_terrain_shadow_lod_active_chunk_count: int = -1
var _last_terrain_shadow_lod_batch_count: int = -1
var _last_terrain_shadow_lod_enabled_setting: bool = true
var _last_terrain_shadow_lod_radius_setting: int = -1
var _render_resource_prewarm_started: bool = false
var _render_resource_prewarm_node: Node = null
@export_range(1, 256, 1) var completed_generation_drain_limit_per_frame: int = 32
@export_range(0.1, 10.0, 0.1) var completed_generation_drain_budget_ms: float = 2.0


# Persistent modification storage - survives chunk unloading
# Format: coord (Vector2i) -> Array of { brush_pos: Vector3, radius: float, value: float, shape: int, layer: int }
var stored_modifications: Dictionary = {}
var _world_map_terrain_modifications: Dictionary = {}
var _modification_coord_cache: Array[Vector3i] = []
var _modification_coord_cache_dirty: bool = true

# Spawn zone tracking - positions waiting for terrain to load
# Format: Array of { "position": Vector3, "radius": int, "pending_coords": Array[Vector3i] }
var pending_spawn_zones: Array = []

func _ready():
	mutex = Mutex.new()
	semaphore = Semaphore.new()
	pending_nodes_mutex = Mutex.new()
	cpu_mutex = Mutex.new()
	cpu_semaphore = Semaphore.new()
	completed_generation_mutex = Mutex.new()
	_completed_terrain_visual_batch_mutex = Mutex.new()
	stored_modifications_mutex = Mutex.new()
	_ensure_chunk_node_root()
	add_to_group("terrain")
	_configure_runtime_power_mode_from_env()
	_configure_terrain_gpu_mode_from_env()

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
	if terrain_native_cpu_meshing_enabled:
		var mesh_builder_probe = ClassDB.instantiate("MeshBuilder")
		if mesh_builder_probe and mesh_builder_probe.has_method("has_marching_cubes_tables") and not mesh_builder_probe.has_marching_cubes_tables():
			push_error("[ChunkManager] MeshBuilder cannot load marching_cubes_lookup_table.glslinc; falling back to GPU mesh readback. Export builds must include world_marching_cubes/*.glslinc to keep native CPU terrain meshing enabled.")
			terrain_native_cpu_meshing_enabled = false
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
	var water_shader_path := "res://world_marching_cubes/water.gdshader" if water_screen_refraction_enabled else "res://world_marching_cubes/water_no_refraction.gdshader"
	material_water.shader = load(water_shader_path)
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
		# Read metadata for map params (biome blending now uses GPU fbm() directly, no texture needed)
		var startup_world_map_load_profile: Dictionary = {}
		var loaded = WorldMapData.load_world(world_definition_path, world_map_data_cache_enabled, false, startup_world_map_load_profile, ["heightmap", "biomes", "roads", "water"])
		_startup_world_map_data = loaded
		_startup_world_map_load_profile = startup_world_map_load_profile
		if loaded.has("metadata"):
			var meta = loaded.metadata
			var meta_terrain_height = float(meta.get("terrain_height", terrain_height))
			world_map_size = float(meta.get("map_size", 2048))
			world_map_half = world_map_size / 2.0
			world_map_max_height = meta_terrain_height * 2.5
			water_level = float(meta.get("water_level", meta_terrain_height + 3.0))
		if loaded.has("heightmap"):
			var startup_hmap: Image = loaded.heightmap
			_world_map_heightmap_data = startup_hmap.get_data()
			_world_map_heightmap_width = startup_hmap.get_width()
			_world_map_heightmap_height = startup_hmap.get_height()
		if loaded.has("biomes"):
			_world_map_biome_image = loaded.biomes
			gpu_biome_map = _world_map_biome_image.get_data()
			_world_map_biome_texture = ImageTexture.create_from_image(_world_map_biome_image)
			material_terrain.set_shader_parameter("world_map_biome_map", _world_map_biome_texture)
			material_terrain.set_shader_parameter("world_map_texture_scale", 1.0 / world_map_size)
		# LOD uses baked map textures directly; near terrain uses baked material IDs.
		if loaded.has("roads"):
			var rmap: Image = loaded.roads
			_world_map_road_image = rmap
			_world_map_road_texture = ImageTexture.create_from_image(rmap)
			material_terrain.set_shader_parameter("world_map_road_map", _world_map_road_texture)
		if loaded.has("water"):
			_world_map_water_image = loaded.water

	_start_render_resource_prewarm()

	# Start GPU thread
	compute_thread = Thread.new()
	compute_thread.start(_thread_function)

	# Start CPU worker pool
	for i in range(_cpu_worker_count):
		var thread = Thread.new()
		thread.start(_cpu_thread_function)
		cpu_threads.append(thread)

	# Calculate initial load target (all chunks within render distance)
	# Match TerrainGrid's integer disk exactly; PI*r^2 overestimates some radii.
	initial_load_target_chunks = _chunk_disk_count(render_distance)


func get_telemetry_snapshot() -> Dictionary:
	var loaded_chunk_count := 0
	var pending_chunk_count := 0
	var rendered_terrain_chunk_count := 0
	var rendered_water_chunk_count := 0
	var rendered_water_y0_chunk_count := 0
	var rendered_water_non_y0_chunk_count := 0
	var water_physics_area_count := 0
	var collision_chunk_count := 0
	var collision_enabled_chunk_count := 0
	var collision_ready_chunk_count := 0
	var native_grid_active_chunk_count := 0
	var dirty_loaded_chunk_count := 0
	var active_render_chunk_count := 0

	for coord_variant in active_chunks:
		var coord: Vector3i = coord_variant
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
			if coord.y == 0:
				rendered_water_y0_chunk_count += 1
			else:
				rendered_water_non_y0_chunk_count += 1
			if data.node_water is Area3D:
				water_physics_area_count += 1
		if data.body_rid_terrain.is_valid() or int(data.terrain_collision_shared_shape_index) >= 0:
			collision_chunk_count += 1
		if bool(data.terrain_collision_enabled):
			collision_enabled_chunk_count += 1
		if data.node_terrain or data.node_water:
			active_render_chunk_count += 1

	if terrain_grid and terrain_grid.has_method("get_collision_ready_chunk_count"):
		collision_ready_chunk_count = terrain_grid.get_collision_ready_chunk_count()
	if terrain_grid and terrain_grid.has_method("get_active_chunk_count"):
		native_grid_active_chunk_count = terrain_grid.get_active_chunk_count()
		_last_native_grid_active_chunk_count = native_grid_active_chunk_count

	return {
		"active_chunk_count": active_chunks.size(),
		"native_grid_active_chunk_count": native_grid_active_chunk_count,
		"loaded_chunk_count": loaded_chunk_count,
		"pending_chunk_count": pending_chunk_count,
		"rendered_terrain_chunk_count": rendered_terrain_chunk_count,
		"rendered_water_chunk_count": rendered_water_chunk_count,
		"rendered_water_y0_chunk_count": rendered_water_y0_chunk_count,
		"rendered_water_non_y0_chunk_count": rendered_water_non_y0_chunk_count,
		"water_physics_area_count": water_physics_area_count,
		"collision_chunk_count": collision_chunk_count,
		"collision_enabled_chunk_count": collision_enabled_chunk_count,
		"collision_space_attached_chunk_count": _terrain_collision_space_attached_coords.size(),
		"shared_collision_body_enabled": shared_terrain_collision_body_enabled,
		"shared_collision_shape_count": _shared_terrain_collision_shape_coords.size(),
		"shared_collision_cluster_body_count": _shared_terrain_collision_cluster_bodies.size(),
		"shared_terrain_collision_create_budget_per_frame": shared_terrain_collision_create_budget_per_frame,
		"collision_ready_chunk_count": collision_ready_chunk_count,
		"collision_prewarm_distance": collision_prewarm_distance,
		"pending_terrain_collision_create_count": pending_terrain_collision_creates.size(),
		"last_terrain_collision_create_count": _last_terrain_collision_create_count,
		"last_terrain_collision_create_ms": _last_terrain_collision_create_ms,
		"last_terrain_collision_create_skipped_far": _last_terrain_collision_create_skipped_far,
		"last_terrain_collision_create_stale": _last_terrain_collision_create_stale,
		"last_terrain_collision_create_deferred_prewarm": _last_terrain_collision_create_deferred_prewarm,
		"last_terrain_collision_candidate_checks": _last_terrain_collision_candidate_checks,
		"last_collision_proximity_update_ms": _last_collision_proximity_update_ms,
		"last_collision_proximity_enable_count": _last_collision_proximity_enable_count,
		"last_collision_proximity_disable_count": _last_collision_proximity_disable_count,
		"last_collision_proximity_prewarm_queued": _last_collision_proximity_prewarm_queued,
		"terrain_collision_create_budget_per_frame": terrain_collision_create_budget_per_frame,
		"terrain_collision_candidate_checks_per_frame": terrain_collision_candidate_checks_per_frame,
		"terrain_collision_body_cache_limit": terrain_collision_body_cache_limit,
		"terrain_collision_body_cache_count": _terrain_collision_body_cache.size(),
		"terrain_collision_body_cache_hits": _terrain_collision_body_cache_hits,
		"terrain_collision_body_cache_misses": _terrain_collision_body_cache_misses,
		"terrain_collision_body_cache_stores": _terrain_collision_body_cache_stores,
		"terrain_collision_body_cache_evictions": _terrain_collision_body_cache_evictions,
		"loaded_dirty_chunk_count": dirty_loaded_chunk_count,
		"active_render_chunk_count": active_render_chunk_count,
		"terrain_visual_batching_enabled": terrain_visual_batching_enabled,
		"procedural_terrain_visual_batching_enabled": procedural_terrain_visual_batching_enabled,
		"terrain_visual_batch_active": _is_terrain_visual_batch_active(),
		"terrain_visual_batch_size": terrain_visual_batch_size,
		"world_map_visual_batch_profile_enabled": world_map_visual_batch_profile_enabled,
		"world_map_terrain_visual_batch_size": world_map_terrain_visual_batch_size,
		"world_map_terrain_visual_batch_max_vertices": world_map_terrain_visual_batch_max_vertices,
		"effective_terrain_visual_batch_size": _effective_terrain_visual_batch_size(),
		"effective_terrain_visual_batch_max_vertices": _effective_terrain_visual_batch_max_vertices(),
		"terrain_visual_batch_cached_rebuilds_per_frame": terrain_visual_batch_cached_rebuilds_per_frame,
		"terrain_visual_batch_cached_rebuild_budget_ms": terrain_visual_batch_cached_rebuild_budget_ms,
		"terrain_visual_batch_async_build_enabled": terrain_visual_batch_async_build_enabled,
		"terrain_visual_batch_async_during_streaming": terrain_visual_batch_async_during_streaming,
		"terrain_visual_batch_async_builds_per_frame": terrain_visual_batch_async_builds_per_frame,
		"terrain_visual_batch_streaming_async_queue_per_frame": terrain_visual_batch_streaming_async_queue_per_frame,
		"terrain_visual_batch_async_build_queue_limit": terrain_visual_batch_async_build_queue_limit,
		"terrain_visual_batch_async_apply_per_frame": terrain_visual_batch_async_apply_per_frame,
		"terrain_visual_batch_async_apply_budget_ms": terrain_visual_batch_async_apply_budget_ms,
		"terrain_visual_batch_hot_rebuild_interval_frames": terrain_visual_batch_hot_rebuild_interval_frames,
		"terrain_visual_batch_hot_rebuild_dirty_threshold": terrain_visual_batch_hot_rebuild_dirty_threshold,
		"terrain_visual_batch_max_vertices": terrain_visual_batch_max_vertices,
		"procedural_terrain_visual_batch_near_cull_radius_chunks": procedural_terrain_visual_batch_near_cull_radius_chunks,
		"effective_terrain_visual_batch_near_cull_radius_chunks": _effective_terrain_visual_batch_near_cull_radius(),
		"terrain_visual_batch_near_cull_chunk_count": _count_near_cull_visual_batch_chunks(_effective_terrain_visual_batch_near_cull_radius()),
		"terrain_shadow_lod_enabled": terrain_shadow_lod_enabled,
		"terrain_shadow_lod_radius_chunks": terrain_shadow_lod_radius_chunks,
		"last_terrain_shadow_lod_enabled_count": _last_terrain_shadow_lod_enabled_count,
		"last_terrain_shadow_lod_disabled_count": _last_terrain_shadow_lod_disabled_count,
		"last_terrain_shadow_lod_update_count": _last_terrain_shadow_lod_update_count,
		"last_terrain_shadow_lod_ms": _last_terrain_shadow_lod_ms,
		"terrain_visual_batch_idle_polish_enabled": terrain_visual_batch_idle_polish_enabled,
		"terrain_visual_batch_idle_polish_active": _last_terrain_visual_batch_idle_polish,
		"terrain_visual_batch_idle_polish_frame_count": _terrain_visual_batch_idle_polish_frame_count,
		"terrain_visual_batch_mesh_cache_limit": terrain_visual_batch_mesh_cache_limit,
		"terrain_visual_batch_mesh_cache_count": _terrain_visual_batch_mesh_cache.size(),
		"terrain_visual_batch_mesh_cache_hits": _terrain_visual_batch_mesh_cache_hits,
		"terrain_visual_batch_mesh_cache_misses": _terrain_visual_batch_mesh_cache_misses,
		"terrain_visual_batch_node_count": _terrain_visual_batches.size(),
		"terrain_visual_batch_hidden_chunk_count": _count_hidden_terrain_visual_batch_chunks(),
		"terrain_visual_batch_dirty_count": _terrain_visual_batch_dirty.size(),
		"last_terrain_visual_batch_rebuild_ms": _last_terrain_visual_batch_rebuild_ms,
		"last_terrain_visual_batch_rebuild_count": _last_terrain_visual_batch_rebuild_count,
		"last_terrain_visual_batch_hot_rebuild": _last_terrain_visual_batch_hot_rebuild,
		"last_terrain_visual_batch_hidden_chunk_count": _last_terrain_visual_batch_hidden_chunk_count,
		"last_terrain_visual_batch_vertex_count": _last_terrain_visual_batch_vertex_count,
		"last_terrain_visual_batch_index_count": _last_terrain_visual_batch_index_count,
		"last_terrain_visual_batch_skipped_heavy_count": _last_terrain_visual_batch_skipped_heavy_count,
		"last_terrain_visual_batch_cache_hit": _last_terrain_visual_batch_cache_hit,
		"last_terrain_visual_batch_cached_rebuild_count": _last_terrain_visual_batch_cached_rebuild_count,
		"last_terrain_visual_batch_cached_rebuild_ms": _last_terrain_visual_batch_cached_rebuild_ms,
		"last_terrain_visual_batch_cached_rebuild_attempts": _last_terrain_visual_batch_cached_rebuild_attempts,
		"terrain_visual_batch_async_in_flight_count": _terrain_visual_batch_builds_in_flight.size(),
		"terrain_visual_batch_async_completed_count": _completed_terrain_visual_batch_builds.size(),
		"last_terrain_visual_batch_async_queued_count": _last_terrain_visual_batch_async_queued_count,
		"last_terrain_visual_batch_streaming_async_queued_count": _last_terrain_visual_batch_streaming_async_queued_count,
		"last_terrain_visual_batch_async_apply_count": _last_terrain_visual_batch_async_apply_count,
		"last_terrain_visual_batch_async_apply_ms": _last_terrain_visual_batch_async_apply_ms,
		"last_terrain_visual_batch_async_stale_count": _last_terrain_visual_batch_async_stale_count,
		"terrain_visual_batch_total_heavy_skips": _terrain_visual_batch_total_heavy_skips,
		"terrain_visual_batch_stream_idle_frames": _terrain_visual_batch_stream_idle_frames,
		"terrain_visual_mesh_retire_queue_count": _terrain_visual_mesh_retire_queue.size(),
		"water_visual_batching_enabled": water_visual_batching_enabled,
		"procedural_water_visual_batching_enabled": procedural_water_visual_batching_enabled,
		"water_visual_batch_active": _is_water_visual_batch_active(),
		"water_visual_batch_size": water_visual_batch_size,
		"world_map_water_visual_batch_size": world_map_water_visual_batch_size,
		"world_map_water_visual_batch_max_vertices": world_map_water_visual_batch_max_vertices,
		"effective_water_visual_batch_size": _effective_water_visual_batch_size(),
		"effective_water_visual_batch_max_vertices": _effective_water_visual_batch_max_vertices(),
		"water_visual_batch_rebuilds_per_frame": water_visual_batch_rebuilds_per_frame,
		"water_visual_batch_max_vertices": water_visual_batch_max_vertices,
		"procedural_water_visual_batch_near_cull_radius_chunks": procedural_water_visual_batch_near_cull_radius_chunks,
		"effective_water_visual_batch_near_cull_radius_chunks": _effective_water_visual_batch_near_cull_radius(),
		"water_visual_batch_near_cull_chunk_count": _count_near_cull_visual_batch_chunks(_effective_water_visual_batch_near_cull_radius()),
		"water_visual_batch_node_count": _water_visual_batches.size(),
		"water_visual_batch_hidden_chunk_count": _count_hidden_water_visual_batch_chunks(),
		"water_visual_batch_dirty_count": _water_visual_batch_dirty.size(),
		"last_water_visual_batch_rebuild_ms": _last_water_visual_batch_rebuild_ms,
		"last_water_visual_batch_rebuild_count": _last_water_visual_batch_rebuild_count,
		"last_water_visual_batch_hidden_chunk_count": _last_water_visual_batch_hidden_chunk_count,
		"last_water_visual_batch_vertex_count": _last_water_visual_batch_vertex_count,
		"last_water_visual_batch_index_count": _last_water_visual_batch_index_count,
		"last_water_visual_batch_skipped_heavy_count": _last_water_visual_batch_skipped_heavy_count,
		"water_visual_batch_total_heavy_skips": _water_visual_batch_total_heavy_skips,
		"pending_node_count": pending_nodes.size(),
		"pending_node_sort_needed": pending_nodes_needs_sort,
		"pending_node_sorted_prefix_count": _pending_nodes_sort_size_at_last_sort,
		"pending_node_resort_growth_threshold": pending_node_resort_growth_threshold,
		"last_pending_node_sort_ms": _last_pending_node_sort_ms,
		"last_pending_node_sort_count": _last_pending_node_sort_count,
		"last_pending_node_sort_skipped": _last_pending_node_sort_skipped,
		"last_pending_node_finalize_count": _last_pending_node_finalize_count,
		"pending_node_finalize_max_per_frame": pending_node_finalize_max_per_frame,
		"pending_node_initial_finalize_max_per_frame": pending_node_initial_finalize_max_per_frame,
		"pending_node_runtime_render_commits_per_frame": pending_node_runtime_render_commits_per_frame,
		"spawn_zone_pending_node_finalize_max_per_frame": spawn_zone_pending_node_finalize_max_per_frame,
		"spawn_zone_pending_node_finalize_budget_ms": spawn_zone_pending_node_finalize_budget_ms,
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
		"last_terrain_stream_update_gate_reason": _last_terrain_stream_update_gate_reason,
		"terrain_stream_update_idle_skip_count": _terrain_stream_update_idle_skip_count,
		"terrain_stream_min_chunk_target": _get_min_loaded_stream_chunk_count(),
		"terrain_stream_under_target": active_chunks.size() < _get_min_loaded_stream_chunk_count(),
		"last_fallback_unloads": _last_fallback_unloads,
		"last_fallback_unload_ms": _last_fallback_unload_ms,
		"last_update_backend": _last_update_backend,
		"last_terrain_finalization_defer_reason": _last_terrain_finalization_defer_reason,
		"last_update_duration_ms": _last_update_duration_ms,
		"completed_generation_queue_count": _get_completed_generation_queue_count(),
		"completed_generation_drain_limit_per_frame": completed_generation_drain_limit_per_frame,
		"completed_generation_drain_budget_ms": completed_generation_drain_budget_ms,
		"last_completed_generation_drain_ms": _last_completed_generation_drain_ms,
		"last_completed_generation_drain_count": _last_completed_generation_drain_count,
		"terrain_gpu_separate_water_meshing": terrain_gpu_separate_water_meshing,
		"terrain_gpu_mesh_slices_per_chunk": terrain_gpu_mesh_slices_per_chunk,
		"terrain_gpu_mesh_slice_delay_ms": terrain_gpu_mesh_slice_delay_ms,
		"terrain_native_cpu_meshing_enabled": terrain_native_cpu_meshing_enabled,
		"terrain_skip_dry_water_density_dispatch": terrain_skip_dry_water_density_dispatch,
		"water_render_enabled": water_render_enabled,
		"water_screen_refraction_enabled": water_screen_refraction_enabled,
		"last_gpu_generation_dispatch_ms": _last_gpu_generation_dispatch_ms,
		"last_gpu_generation_dispatch_coord": str(_last_gpu_generation_dispatch_coord),
		"last_gpu_generation_mod_sync_ms": _last_gpu_generation_mod_sync_ms,
		"last_gpu_generation_batch_ms": _last_gpu_generation_batch_ms,
		"last_gpu_generation_batch_chunk_count": _last_gpu_generation_batch_chunk_count,
		"last_gpu_generation_sync_ms": _last_gpu_generation_sync_ms,
		"last_gpu_meshing_dispatch_ms": _last_gpu_meshing_dispatch_ms,
		"last_gpu_meshing_sync_ms": _last_gpu_meshing_sync_ms,
		"last_gpu_mesh_readback_ms": _last_gpu_mesh_readback_ms,
		"last_gpu_mesh_readback_chunk_count": _last_gpu_mesh_readback_chunk_count,
		"last_gpu_mesh_readback_terrain_vertices": _last_gpu_mesh_readback_terrain_vertices,
		"last_gpu_mesh_readback_water_vertices": _last_gpu_mesh_readback_water_vertices,
		"last_gpu_mesh_slice_count": _last_gpu_mesh_slice_count,
		"last_gpu_mesh_slice_max_sync_ms": _last_gpu_mesh_slice_max_sync_ms,
		"last_gpu_water_density_dispatched": _last_gpu_water_density_dispatched,
		"gpu_water_density_skipped_count": _gpu_water_density_skipped_count,
		"last_gpu_water_density_skipped_coord": str(_last_gpu_water_density_skipped_coord),
		"last_gpu_generation_batch_event_id": _last_gpu_generation_batch_event_id,
		"last_cpu_mesh_build_ms": _last_cpu_mesh_build_ms,
		"last_cpu_mesh_build_terrain_ms": _last_cpu_mesh_build_terrain_ms,
		"last_cpu_mesh_build_water_ms": _last_cpu_mesh_build_water_ms,
		"last_cpu_mesh_build_queue_wait_ms": _last_cpu_mesh_build_queue_wait_ms,
		"last_cpu_mesh_build_terrain_vertices": _last_cpu_mesh_build_terrain_vertices,
		"last_cpu_mesh_build_water_vertices": _last_cpu_mesh_build_water_vertices,
		"last_cpu_mesh_build_coord": str(_last_cpu_mesh_build_coord),
		"last_cpu_mesh_build_event_id": _last_cpu_mesh_build_event_id,
		"last_pending_node_process_ms": _last_pending_node_process_ms,
		"last_finalize_terrain_ms": _last_finalize_terrain_ms,
		"last_finalize_water_ms": _last_finalize_water_ms,
		"last_chunk_update_ms": _last_chunk_update_ms,
		"last_modify_terrain_ms": _last_modify_terrain_ms,
		"last_world_map_entry_ms": _last_world_map_entry_ms,
		"last_spawn_zone_far_reset_ms": _last_spawn_zone_far_reset_ms,
		"last_spawn_zone_far_reset_cleared_chunks": _last_spawn_zone_far_reset_cleared_chunks,
		"spawn_zone_far_reset_count": _spawn_zone_far_reset_count,
		"generated_water_surface_skip_count": _generated_water_surface_skip_count,
		"last_generated_water_surface_skip_coord": str(_last_generated_water_surface_skip_coord),
		"runtime_power_mode_enabled": runtime_power_mode_enabled,
		"runtime_power_mode": _runtime_power_mode,
		"runtime_power_target_fps": _runtime_power_target_fps,
		"runtime_power_active_max_fps": runtime_power_active_max_fps,
		"runtime_power_idle_max_fps": runtime_power_idle_max_fps,
		"runtime_power_deep_idle_max_fps": runtime_power_deep_idle_max_fps,
		"runtime_power_idle_seconds": _runtime_power_idle_seconds,
		"runtime_power_active_frame_count": _runtime_power_active_frame_count,
		"runtime_power_idle_frame_count": _runtime_power_idle_frame_count,
		"runtime_power_deep_idle_frame_count": _runtime_power_deep_idle_frame_count,
		"runtime_power_active_reason": _runtime_power_active_reason,
		"runtime_power_viewer_moved": _runtime_power_viewer_moved_last,
		"runtime_power_terrain_busy": _runtime_power_terrain_busy_last,
		"runtime_power_foreground_terrain_busy": _runtime_power_foreground_terrain_busy_last,
		"runtime_power_external_world_busy": _runtime_power_external_world_busy_last,
		"runtime_power_disabled_reason": _runtime_power_disabled_reason,
		"runtime_power_suspend_render_loop_in_deep_idle": runtime_power_suspend_render_loop_in_deep_idle,
		"runtime_power_render_loop_suspended": _runtime_power_render_loop_suspended,
		"runtime_power_render_loop_enabled": _get_runtime_power_render_loop_enabled(),
		"runtime_power_suspend_background_world_work": runtime_power_suspend_background_world_work,
		"runtime_power_viewport_scaling_enabled": runtime_power_viewport_scaling_enabled,
		"runtime_power_viewport_scale_supported": _runtime_power_viewport_scale_supported,
		"runtime_power_viewport_scale_current": _get_runtime_power_viewport_scale(),
		"runtime_power_active_3d_scale": runtime_power_active_3d_scale,
		"runtime_power_idle_3d_scale": runtime_power_idle_3d_scale,
		"runtime_power_deep_idle_3d_scale": runtime_power_deep_idle_3d_scale,
		"runtime_power_world_work_suspended": _runtime_power_world_work_suspended,
		"runtime_power_world_work_suspended_frame_count": _runtime_power_world_work_suspended_frame_count,
		"runtime_power_world_work_suspend_count": _runtime_power_world_work_suspend_count,
		"runtime_power_world_work_resume_count": _runtime_power_world_work_resume_count,
		"runtime_power_world_work_suspend_reason": _runtime_power_world_work_suspend_reason,
		"runtime_power_world_work_resume_reason": _runtime_power_world_work_resume_reason,
		"runtime_power_recent_events": _runtime_power_recent_events.duplicate(true),
		"retired_chunk_node_root_count": _retired_chunk_node_roots.size(),
		"last_retired_chunk_node_cleanup_ms": _last_retired_chunk_node_cleanup_ms,
		"last_retired_chunk_node_cleanup_count": _last_retired_chunk_node_cleanup_count,
		"world_map_load_profile": _last_world_map_load_profile.duplicate(true),
		"world_map_lod_chunk_count": _world_map_lod_chunks.size(),
		"world_map_lod_node_count": _get_world_map_lod_node_count(),
		"world_map_lod_merged": _is_world_map_lod_merged(),
		"distant_world_map_lod_enabled": distant_world_map_lod_enabled,
		"distant_world_map_lod_defer_until_initial_viewer_move": distant_world_map_lod_defer_until_initial_viewer_move,
		"distant_world_map_lod_deferred": _last_world_map_lod_deferred,
		"distant_world_map_lod_throttled_update": _last_world_map_lod_throttled_update,
		"last_world_map_lod_update_ms": _last_world_map_lod_update_ms,
		"last_world_map_lod_merge_ms": _last_world_map_lod_merge_ms,
		"last_world_map_lod_loads": _last_world_map_lod_loads,
		"last_world_map_lod_unloads": _last_world_map_lod_unloads,
		"world_map_lod_load_candidate_count": _world_map_lod_load_candidates.size(),
		"world_map_lod_unload_candidate_count": _world_map_lod_unload_candidates.size(),
		"world_map_lod_load_cursor": _world_map_lod_load_cursor,
		"world_map_lod_unload_cursor": _world_map_lod_unload_cursor,
		"world_map_lod_pending_candidate_count": maxi(_world_map_lod_load_candidates.size() - _world_map_lod_load_cursor, 0) + maxi(_world_map_lod_unload_candidates.size() - _world_map_lod_unload_cursor, 0),
		"distant_world_map_lod_distance": distant_world_map_lod_distance,
		"distant_world_map_lod_overlap": distant_world_map_lod_overlap,
		"distant_world_map_lod_sample_step": distant_world_map_lod_sample_step,
		"distant_world_map_lod_budget_per_frame": distant_world_map_lod_budget_per_frame,
		"hot_frame_backoff_remaining_frames": _hot_frame_backoff_remaining_frames,
		"world_map_building_count": _world_map_buildings.size(),
		"world_map_excavation_mask_count": _world_map_excavation_masks.size(),
		"world_map_excavation_buffer_count": _world_map_excavation_buffers.size(),
		"render_resource_prewarm_started": _render_resource_prewarm_started,
		"render_resource_prewarm_active": _is_render_resource_prewarm_active(),
		"render_resource_prewarm_frames_remaining": _get_render_resource_prewarm_frames_remaining(),
		"native_backends_ready": _native_backends_ready
	}

func _start_render_resource_prewarm() -> void:
	if render_resource_prewarm_frames <= 0 or _render_resource_prewarm_started:
		return

	_render_resource_prewarm_started = true
	var materials: Array = []
	_append_render_prewarm_material(materials, material_terrain)
	_append_render_prewarm_material(materials, material_water)
	if world_map_active:
		_append_render_prewarm_material(materials, _get_world_map_lod_material())
	_append_render_prewarm_material(materials, BuildingVisuals.get_shared_wood_block_material())
	_append_render_prewarm_material(materials, BuildingVisuals.get_shared_building_material())

	if materials.is_empty():
		return

	var prewarmer: Node = RenderResourcePrewarm.new()
	prewarmer.name = "RenderResourcePrewarm"
	add_child(prewarmer)
	_render_resource_prewarm_node = prewarmer
	prewarmer.configure(materials, render_resource_prewarm_frames)

func _append_render_prewarm_material(materials: Array, material: Material) -> void:
	if material and not materials.has(material):
		materials.append(material)

func _ensure_chunk_node_root() -> Node3D:
	if _chunk_node_root and is_instance_valid(_chunk_node_root):
		return _chunk_node_root

	_chunk_node_root = Node3D.new()
	_chunk_node_root.name = "ChunkNodes"
	add_child(_chunk_node_root)
	return _chunk_node_root

func _reset_chunk_node_root() -> void:
	if _chunk_node_root and is_instance_valid(_chunk_node_root):
		_chunk_node_root.visible = false
		_chunk_node_root.process_mode = Node.PROCESS_MODE_DISABLED
		_retired_chunk_node_roots.append(_chunk_node_root)
	_chunk_node_root = null
	_ensure_chunk_node_root()

func _process_retired_chunk_node_cleanup() -> void:
	_last_retired_chunk_node_cleanup_count = 0
	_last_retired_chunk_node_cleanup_ms = 0.0
	if _retired_chunk_node_roots.is_empty():
		return

	var start_us := Time.get_ticks_usec()
	var remaining_budget := retired_chunk_node_cleanup_budget_per_frame
	var root_index := _retired_chunk_node_roots.size() - 1
	while root_index >= 0 and remaining_budget > 0:
		var root := _retired_chunk_node_roots[root_index]
		if not is_instance_valid(root):
			_retired_chunk_node_roots.remove_at(root_index)
			root_index -= 1
			continue

		while root.get_child_count() > 0 and remaining_budget > 0:
			var child := root.get_child(root.get_child_count() - 1)
			root.remove_child(child)
			child.queue_free()
			remaining_budget -= 1
			_last_retired_chunk_node_cleanup_count += 1

		if root.get_child_count() == 0:
			_retired_chunk_node_roots.remove_at(root_index)
			root.queue_free()
		root_index -= 1

	_last_retired_chunk_node_cleanup_ms = float(Time.get_ticks_usec() - start_us) / 1000.0

func _is_render_resource_prewarm_active() -> bool:
	return _render_resource_prewarm_node != null and is_instance_valid(_render_resource_prewarm_node)

func _get_render_resource_prewarm_frames_remaining() -> int:
	if not _is_render_resource_prewarm_active():
		return 0
	if not _render_resource_prewarm_node.has_method("get_frames_remaining"):
		return 0
	return int(_render_resource_prewarm_node.get_frames_remaining())


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

func _world_map_lod_distance_sq(coord: Vector2i, center: Vector2i) -> int:
	var dx := coord.x - center.x
	var dz := coord.y - center.y
	return dx * dx + dz * dz

func _world_map_lod_inner_distance() -> int:
	return maxi(render_distance - distant_world_map_lod_overlap, 0)

func _has_visible_world_map_terrain_chunk(coord: Vector2i) -> bool:
	var terrain_coord := Vector3i(coord.x, 0, coord.y)
	if not active_chunks.has(terrain_coord):
		return false

	var data = active_chunks[terrain_coord]
	if data == null:
		return false

	return data.node_terrain != null and is_instance_valid(data.node_terrain)

func _compare_world_map_lod_coord_distance(a: Vector2i, b: Vector2i) -> bool:
	return _world_map_lod_distance_sq(a, _world_map_lod_sort_center) < _world_map_lod_distance_sq(b, _world_map_lod_sort_center)

func _get_world_map_lod_builder() -> Object:
	if _world_map_lod_builder and is_instance_valid(_world_map_lod_builder):
		return _world_map_lod_builder
	if not ClassDB.class_exists("MeshBuilder"):
		return null
	_world_map_lod_builder = ClassDB.instantiate("MeshBuilder")
	return _world_map_lod_builder

func _get_world_map_lod_material() -> ShaderMaterial:
	if _world_map_lod_material and is_instance_valid(_world_map_lod_material):
		return _world_map_lod_material

	var base_material := material_terrain as ShaderMaterial
	if not base_material:
		return null

	_world_map_lod_material = base_material.duplicate() as ShaderMaterial
	_world_map_lod_material.set_shader_parameter("use_world_map", true)
	_world_map_lod_material.set_shader_parameter("world_map_fragment_lookup_enabled", true)
	_world_map_lod_material.set_shader_parameter("world_map_texture_scale", 1.0 / world_map_size)
	if _world_map_biome_texture:
		_world_map_lod_material.set_shader_parameter("world_map_biome_map", _world_map_biome_texture)
	if _world_map_road_texture:
		_world_map_lod_material.set_shader_parameter("world_map_road_map", _world_map_road_texture)
	return _world_map_lod_material

func _is_world_map_lod_merged() -> bool:
	return _world_map_lod_merged_node != null and is_instance_valid(_world_map_lod_merged_node)

func _get_world_map_lod_node_count() -> int:
	return 1 if _is_world_map_lod_merged() else _world_map_lod_chunks.size()

func _reset_world_map_lod_candidates() -> void:
	_world_map_lod_load_candidates.clear()
	_world_map_lod_unload_candidates.clear()
	_world_map_lod_load_cursor = 0
	_world_map_lod_unload_cursor = 0

func _rebuild_world_map_lod_candidates(center: Vector2i) -> void:
	_reset_world_map_lod_candidates()
	_world_map_lod_sort_center = center

	var inner_distance := _world_map_lod_inner_distance()
	var outer_distance := maxi(distant_world_map_lod_distance, inner_distance)
	var inner_sq := inner_distance * inner_distance
	var outer_sq := outer_distance * outer_distance

	for coord_variant in _world_map_lod_chunks.keys():
		var coord: Vector2i = coord_variant
		var dist_sq := _world_map_lod_distance_sq(coord, center)
		if dist_sq <= inner_sq or dist_sq > outer_sq or _has_visible_world_map_terrain_chunk(coord):
			_world_map_lod_unload_candidates.append(coord)

	for x in range(center.x - outer_distance, center.x + outer_distance + 1):
		for z in range(center.y - outer_distance, center.y + outer_distance + 1):
			var coord := Vector2i(x, z)
			var dist_sq := _world_map_lod_distance_sq(coord, center)
			if dist_sq <= inner_sq or dist_sq > outer_sq:
				continue
			if _world_map_lod_chunks.has(coord):
				continue
			if _has_visible_world_map_terrain_chunk(coord):
				continue
			_world_map_lod_load_candidates.append(coord)

	_world_map_lod_unload_candidates.sort_custom(_compare_world_map_lod_coord_distance)
	_world_map_lod_load_candidates.sort_custom(_compare_world_map_lod_coord_distance)

func _clear_world_map_lod_chunks(immediate: bool = false, reset_initial_defer: bool = true) -> void:
	var released_node_ids: Dictionary = {}
	for node_variant in _world_map_lod_chunks.values():
		var node := node_variant as Node
		if not node:
			continue
		var node_id := node.get_instance_id()
		if released_node_ids.has(node_id):
			continue
		released_node_ids[node_id] = true
		if immediate:
			node.free()
		else:
			node.queue_free()
	if _world_map_lod_merged_node and is_instance_valid(_world_map_lod_merged_node):
		var merged_node_id := _world_map_lod_merged_node.get_instance_id()
		if not released_node_ids.has(merged_node_id):
			if immediate:
				_world_map_lod_merged_node.free()
			else:
				_world_map_lod_merged_node.queue_free()
	_world_map_lod_merged_node = null
	_world_map_lod_chunks.clear()
	_reset_world_map_lod_candidates()
	_last_world_map_lod_center = Vector2i(2147483647, 2147483647)
	_last_world_map_lod_inner_distance = -1
	_last_world_map_lod_outer_distance = -1
	_last_world_map_lod_deferred = false
	_last_world_map_lod_merge_ms = 0.0
	if reset_initial_defer:
		_world_map_lod_initial_viewer_chunk = Vector2i(2147483647, 2147483647)
		_world_map_lod_initial_defer_released = false

func _unload_world_map_lod_chunk(coord: Vector2i, immediate: bool = false) -> bool:
	if not _world_map_lod_chunks.has(coord):
		return false
	if _is_world_map_lod_merged():
		_clear_world_map_lod_chunks(immediate)
		return true
	var node := _world_map_lod_chunks[coord] as Node
	_world_map_lod_chunks.erase(coord)
	if node:
		if immediate:
			node.free()
		else:
			node.queue_free()
	return true

func _load_world_map_lod_chunk(coord: Vector2i) -> bool:
	if _world_map_heightmap_data.is_empty() or _world_map_heightmap_width <= 0 or _world_map_heightmap_height <= 0:
		return false
	if _world_map_lod_chunks.has(coord):
		return false
	if _has_visible_world_map_terrain_chunk(coord):
		return false

	var builder := _get_world_map_lod_builder()
	if not builder or not builder.has_method("build_world_map_lod_mesh"):
		return false

	var mesh: ArrayMesh = builder.build_world_map_lod_mesh(
		_world_map_heightmap_data,
		_world_map_heightmap_width,
		_world_map_heightmap_height,
		coord.x,
		coord.y,
		CHUNK_STRIDE,
		distant_world_map_lod_sample_step,
		world_map_half,
		world_map_max_height
	)
	if mesh == null:
		return false

	var lod_node := MeshInstance3D.new()
	lod_node.name = "WorldMapLOD_%d_%d" % [coord.x, coord.y]
	lod_node.mesh = mesh
	lod_node.material_override = _get_world_map_lod_material()
	lod_node.position = Vector3(coord.x * CHUNK_STRIDE, 0.0, coord.y * CHUNK_STRIDE)
	lod_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	lod_node.add_to_group("world_map_lod")
	add_child(lod_node)
	_world_map_lod_chunks[coord] = lod_node
	return true

func _merge_world_map_lod_chunks() -> void:
	_last_world_map_lod_merge_ms = 0.0
	if _is_world_map_lod_merged() or _world_map_lod_chunks.size() <= 1:
		return

	var merge_start_us := Time.get_ticks_usec()
	var merged_vertices := PackedVector3Array()
	var merged_normals := PackedVector3Array()
	var merged_colors := PackedColorArray()
	var merged_uvs := PackedVector2Array()
	var merged_indices := PackedInt32Array()
	var loaded_coords: Array[Vector2i] = []
	var released_node_ids: Dictionary = {}

	for coord_variant in _world_map_lod_chunks.keys():
		var coord: Vector2i = coord_variant
		var mesh_instance := _world_map_lod_chunks[coord] as MeshInstance3D
		if not mesh_instance or not is_instance_valid(mesh_instance):
			continue
		var mesh := mesh_instance.mesh as ArrayMesh
		if mesh == null or mesh.get_surface_count() <= 0:
			continue
		var arrays := mesh.surface_get_arrays(0)
		if arrays.size() <= Mesh.ARRAY_INDEX:
			continue

		var src_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var src_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var src_colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var src_uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var src_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if src_vertices.is_empty() or src_indices.is_empty():
			continue

		var vertex_offset := merged_vertices.size()
		var world_offset := mesh_instance.position
		for vertex in src_vertices:
			merged_vertices.append(vertex + world_offset)
		for normal in src_normals:
			merged_normals.append(normal)
		for color in src_colors:
			merged_colors.append(color)
		for uv in src_uvs:
			merged_uvs.append(uv)
		for index in src_indices:
			merged_indices.append(vertex_offset + int(index))

		loaded_coords.append(coord)
		released_node_ids[mesh_instance.get_instance_id()] = mesh_instance

	if loaded_coords.size() <= 1 or merged_vertices.is_empty() or merged_indices.is_empty():
		_last_world_map_lod_merge_ms = float(Time.get_ticks_usec() - merge_start_us) / 1000.0
		return

	var merged_arrays := []
	merged_arrays.resize(Mesh.ARRAY_MAX)
	merged_arrays[Mesh.ARRAY_VERTEX] = merged_vertices
	if merged_normals.size() == merged_vertices.size():
		merged_arrays[Mesh.ARRAY_NORMAL] = merged_normals
	if merged_colors.size() == merged_vertices.size():
		merged_arrays[Mesh.ARRAY_COLOR] = merged_colors
	if merged_uvs.size() == merged_vertices.size():
		merged_arrays[Mesh.ARRAY_TEX_UV] = merged_uvs
	merged_arrays[Mesh.ARRAY_INDEX] = merged_indices

	var merged_mesh := ArrayMesh.new()
	merged_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged_arrays)
	var lod_material := _get_world_map_lod_material()
	if lod_material:
		merged_mesh.surface_set_material(0, lod_material)

	var merged_node := MeshInstance3D.new()
	merged_node.name = "WorldMapLOD_Merged"
	merged_node.mesh = merged_mesh
	merged_node.material_override = lod_material
	merged_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	merged_node.add_to_group("world_map_lod")
	add_child(merged_node)

	for node_variant in released_node_ids.values():
		var node := node_variant as Node
		if node and is_instance_valid(node):
			node.queue_free()

	_world_map_lod_merged_node = merged_node
	for coord in loaded_coords:
		_world_map_lod_chunks[coord] = merged_node
	_last_world_map_lod_merge_ms = float(Time.get_ticks_usec() - merge_start_us) / 1000.0

func _has_world_map_lod_initial_viewer_chunk() -> bool:
	return _world_map_lod_initial_viewer_chunk.x <= 2000000000

func _release_world_map_lod_initial_defer() -> void:
	_world_map_lod_initial_defer_released = true
	_last_world_map_lod_deferred = false

func _should_defer_world_map_lod_for_initial_viewer(center: Vector2i) -> bool:
	_last_world_map_lod_deferred = false
	if not distant_world_map_lod_defer_until_initial_viewer_move or _world_map_lod_initial_defer_released:
		return false
	if initial_load_phase:
		if not _has_world_map_lod_initial_viewer_chunk():
			_world_map_lod_initial_viewer_chunk = center
		_last_world_map_lod_deferred = true
		return true
	if not _has_world_map_lod_initial_viewer_chunk():
		_release_world_map_lod_initial_defer()
		return false
	if center == _world_map_lod_initial_viewer_chunk:
		_last_world_map_lod_deferred = true
		return true
	_release_world_map_lod_initial_defer()
	return false

func _world_map_lod_background_fill_allowed() -> bool:
	return distant_world_map_lod_enabled \
		and world_map_active \
		and not initial_load_phase \
		and pending_spawn_zones.is_empty() \
		and not _world_map_heightmap_data.is_empty()

func _update_world_map_lod_chunks(throttled_background: bool = false) -> void:
	var start_us := Time.get_ticks_usec()
	_last_world_map_lod_loads = 0
	_last_world_map_lod_unloads = 0
	_last_world_map_lod_throttled_update = throttled_background

	var inner_distance := _world_map_lod_inner_distance()
	if not distant_world_map_lod_enabled or not world_map_active or _world_map_heightmap_data.is_empty() or distant_world_map_lod_distance <= inner_distance:
		_last_world_map_lod_deferred = false
		_last_world_map_lod_throttled_update = false
		if not _world_map_lod_chunks.is_empty():
			_clear_world_map_lod_chunks()
		_last_world_map_lod_update_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
		return

	var p_pos := get_viewer_position()
	var center := Vector2i(int(floor(p_pos.x / CHUNK_STRIDE)), int(floor(p_pos.z / CHUNK_STRIDE)))
	if _should_defer_world_map_lod_for_initial_viewer(center):
		_last_world_map_lod_throttled_update = false
		_last_world_map_lod_update_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
		return
	if center != _last_world_map_lod_center or inner_distance != _last_world_map_lod_inner_distance or distant_world_map_lod_distance != _last_world_map_lod_outer_distance:
		if _is_world_map_lod_merged():
			_clear_world_map_lod_chunks(false, false)
		_last_world_map_lod_center = center
		_last_world_map_lod_inner_distance = inner_distance
		_last_world_map_lod_outer_distance = distant_world_map_lod_distance
		_rebuild_world_map_lod_candidates(center)

	var budget := distant_world_map_lod_budget_per_frame
	while budget > 0 and _world_map_lod_unload_cursor < _world_map_lod_unload_candidates.size():
		var coord_to_unload := _world_map_lod_unload_candidates[_world_map_lod_unload_cursor]
		_world_map_lod_unload_cursor += 1
		if _unload_world_map_lod_chunk(coord_to_unload):
			_last_world_map_lod_unloads += 1
			budget -= 1

	while budget > 0 and _world_map_lod_load_cursor < _world_map_lod_load_candidates.size():
		var coord_to_load := _world_map_lod_load_candidates[_world_map_lod_load_cursor]
		_world_map_lod_load_cursor += 1
		if _has_visible_world_map_terrain_chunk(coord_to_load):
			continue
		if _load_world_map_lod_chunk(coord_to_load):
			_last_world_map_lod_loads += 1
		budget -= 1

	if _world_map_lod_unload_cursor >= _world_map_lod_unload_candidates.size() and _world_map_lod_load_cursor >= _world_map_lod_load_candidates.size():
		_reset_world_map_lod_candidates()
		_merge_world_map_lod_chunks()

	_last_world_map_lod_update_ms = float(Time.get_ticks_usec() - start_us) / 1000.0

func _get_terrain_visual_batch_root() -> Node3D:
	if _terrain_visual_batch_root and is_instance_valid(_terrain_visual_batch_root):
		return _terrain_visual_batch_root
	_terrain_visual_batch_root = Node3D.new()
	_terrain_visual_batch_root.name = "TerrainVisualBatches"
	add_child(_terrain_visual_batch_root)
	return _terrain_visual_batch_root

func _get_terrain_visual_batch_builder() -> Object:
	if _terrain_visual_batch_builder and is_instance_valid(_terrain_visual_batch_builder):
		return _terrain_visual_batch_builder
	if not ClassDB.class_exists("MeshBuilder"):
		return null
	_terrain_visual_batch_builder = ClassDB.instantiate("MeshBuilder")
	return _terrain_visual_batch_builder

func _use_world_map_visual_batch_profile() -> bool:
	return world_map_visual_batch_profile_enabled and world_map_active

func _effective_terrain_visual_batch_size() -> int:
	if _use_world_map_visual_batch_profile():
		return maxi(world_map_terrain_visual_batch_size, 1)
	return maxi(terrain_visual_batch_size, 1)

func _effective_terrain_visual_batch_max_vertices() -> int:
	if _use_world_map_visual_batch_profile():
		return world_map_terrain_visual_batch_max_vertices
	return terrain_visual_batch_max_vertices

func _effective_terrain_visual_batch_near_cull_radius() -> int:
	if world_map_active:
		return 0
	return maxi(procedural_terrain_visual_batch_near_cull_radius_chunks, 0)

func _effective_water_visual_batch_size() -> int:
	if _use_world_map_visual_batch_profile():
		return maxi(world_map_water_visual_batch_size, 1)
	return maxi(water_visual_batch_size, 1)

func _effective_water_visual_batch_max_vertices() -> int:
	if _use_world_map_visual_batch_profile():
		return world_map_water_visual_batch_max_vertices
	return water_visual_batch_max_vertices

func _effective_water_visual_batch_near_cull_radius() -> int:
	if world_map_active:
		return 0
	return maxi(procedural_water_visual_batch_near_cull_radius_chunks, 0)

func _is_water_visual_batch_active() -> bool:
	return water_visual_batching_enabled \
		and water_render_enabled \
		and (world_map_active or procedural_water_visual_batching_enabled)

func _is_terrain_visual_batch_active() -> bool:
	return terrain_visual_batching_enabled \
		and (world_map_active or procedural_terrain_visual_batching_enabled)

func _viewer_visual_batch_chunk() -> Vector2i:
	var p_pos := get_viewer_position()
	return Vector2i(
		int(floor(p_pos.x / CHUNK_STRIDE)),
		int(floor(p_pos.z / CHUNK_STRIDE))
	)

func _is_chunk_near_viewer_for_visual_batch(coord: Vector3i, radius_chunks: int) -> bool:
	if radius_chunks <= 0:
		return false
	var viewer_chunk := _viewer_visual_batch_chunk()
	return maxi(absi(coord.x - viewer_chunk.x), absi(coord.z - viewer_chunk.y)) <= radius_chunks

func _count_near_cull_visual_batch_chunks(radius_chunks: int) -> int:
	if radius_chunks <= 0:
		return 0
	var count := 0
	for coord_variant in active_chunks.keys():
		var coord: Vector3i = coord_variant
		if coord.y == 0 and _is_chunk_near_viewer_for_visual_batch(coord, radius_chunks):
			count += 1
	return count

func _should_terrain_cast_shadow(coord: Vector3i) -> bool:
	if not terrain_shadow_lod_enabled or world_map_active:
		return true
	var viewer_chunk := _viewer_visual_batch_chunk()
	return maxi(absi(coord.x - viewer_chunk.x), absi(coord.z - viewer_chunk.y)) <= terrain_shadow_lod_radius_chunks

func _set_mesh_shadow_casting(mesh_instance: MeshInstance3D, enabled: bool) -> bool:
	if mesh_instance == null or not is_instance_valid(mesh_instance):
		return false
	var target := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if mesh_instance.cast_shadow == target:
		return false
	mesh_instance.cast_shadow = target
	return true

func _sync_terrain_node_shadow_lod(coord: Vector3i, data) -> bool:
	if data == null or data.node_terrain == null or not is_instance_valid(data.node_terrain):
		return false
	var mesh_instance := _get_chunk_mesh_instance(data.node_terrain)
	if mesh_instance == null:
		return false
	return _set_mesh_shadow_casting(mesh_instance, _should_terrain_cast_shadow(coord))

func _terrain_batch_shadow_coord(key: Vector2i) -> Vector3i:
	var batch_size := _effective_terrain_visual_batch_size()
	return Vector3i(
		key.x * batch_size + int(floor(float(batch_size) * 0.5)),
		0,
		key.y * batch_size + int(floor(float(batch_size) * 0.5))
	)

func _sync_terrain_shadow_lod() -> void:
	var viewer_chunk := _viewer_visual_batch_chunk()
	var active_chunk_count := active_chunks.size()
	var batch_count := _terrain_visual_batches.size()
	if viewer_chunk == _last_terrain_shadow_lod_viewer_chunk \
		and active_chunk_count == _last_terrain_shadow_lod_active_chunk_count \
		and batch_count == _last_terrain_shadow_lod_batch_count \
		and terrain_shadow_lod_enabled == _last_terrain_shadow_lod_enabled_setting \
		and terrain_shadow_lod_radius_chunks == _last_terrain_shadow_lod_radius_setting:
		_last_terrain_shadow_lod_update_count = 0
		_last_terrain_shadow_lod_ms = 0.0
		return

	var start_us := Time.get_ticks_usec()
	var enabled_count := 0
	var disabled_count := 0
	var updated_count := 0

	for coord_variant in active_chunks.keys():
		var coord: Vector3i = coord_variant
		if coord.y != 0:
			continue
		var should_cast := _should_terrain_cast_shadow(coord)
		if should_cast:
			enabled_count += 1
		else:
			disabled_count += 1
		var data = active_chunks.get(coord, null)
		if _sync_terrain_node_shadow_lod(coord, data):
			updated_count += 1

	for key_variant in _terrain_visual_batches.keys():
		var key: Vector2i = key_variant
		var batch_node := _terrain_visual_batches.get(key, null) as MeshInstance3D
		if batch_node == null or not is_instance_valid(batch_node):
			continue
		var should_batch_cast := _should_terrain_cast_shadow(_terrain_batch_shadow_coord(key))
		if _set_mesh_shadow_casting(batch_node, should_batch_cast):
			updated_count += 1

	_last_terrain_shadow_lod_enabled_count = enabled_count
	_last_terrain_shadow_lod_disabled_count = disabled_count
	_last_terrain_shadow_lod_update_count = updated_count
	_last_terrain_shadow_lod_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
	_last_terrain_shadow_lod_viewer_chunk = viewer_chunk
	_last_terrain_shadow_lod_active_chunk_count = active_chunk_count
	_last_terrain_shadow_lod_batch_count = batch_count
	_last_terrain_shadow_lod_enabled_setting = terrain_shadow_lod_enabled
	_last_terrain_shadow_lod_radius_setting = terrain_shadow_lod_radius_chunks

func _terrain_visual_batch_key(coord: Vector3i) -> Vector2i:
	var batch_size := _effective_terrain_visual_batch_size()
	return Vector2i(
		int(floor(float(coord.x) / float(batch_size))),
		int(floor(float(coord.z) / float(batch_size)))
	)

func _register_terrain_visual_batch_member(coord: Vector3i) -> void:
	if coord.y != 0:
		return
	var key := _terrain_visual_batch_key(coord)
	var batch_members: Dictionary = _terrain_visual_batch_members.get(key, {})
	if batch_members.has(coord):
		return
	batch_members[coord] = true
	_terrain_visual_batch_members[key] = batch_members

func _unregister_terrain_visual_batch_member(coord: Vector3i) -> void:
	if coord.y != 0:
		return
	var key := _terrain_visual_batch_key(coord)
	if not _terrain_visual_batch_members.has(key):
		return
	var batch_members: Dictionary = _terrain_visual_batch_members[key]
	batch_members.erase(coord)
	if batch_members.is_empty():
		_terrain_visual_batch_members.erase(key)
	else:
		_terrain_visual_batch_members[key] = batch_members

func _terrain_visual_batch_cache_key(key: Vector2i, coords: Array[Vector3i]) -> String:
	var sorted_coords := coords.duplicate()
	sorted_coords.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		if a.y != b.y:
			return a.y < b.y
		return a.z < b.z
	)

	var parts := PackedStringArray()
	parts.append("%d,%d" % [key.x, key.y])
	for coord in sorted_coords:
		var data = active_chunks.get(coord, null)
		var version := int(data.mod_version) if data != null else -1
		parts.append("%d,%d,%d:%d" % [coord.x, coord.y, coord.z, version])
	return "|".join(parts)

func _clear_terrain_visual_batch_mesh_cache() -> void:
	_terrain_visual_batch_mesh_cache.clear()
	_terrain_visual_batch_mesh_cache_order.clear()
	_terrain_visual_batch_builds_in_flight.clear()
	if _completed_terrain_visual_batch_mutex:
		_completed_terrain_visual_batch_mutex.lock()
		_completed_terrain_visual_batch_builds.clear()
		_completed_terrain_visual_batch_mutex.unlock()
	else:
		_completed_terrain_visual_batch_builds.clear()
	_terrain_visual_batch_mesh_cache_hits = 0
	_terrain_visual_batch_mesh_cache_misses = 0
	_last_terrain_visual_batch_cache_hit = false
	_last_terrain_visual_batch_cached_rebuild_count = 0
	_last_terrain_visual_batch_cached_rebuild_ms = 0.0
	_last_terrain_visual_batch_cached_rebuild_attempts = 0
	_last_terrain_visual_batch_async_queued_count = 0
	_last_terrain_visual_batch_async_apply_count = 0
	_last_terrain_visual_batch_async_apply_ms = 0.0
	_last_terrain_visual_batch_async_stale_count = 0

func _remember_terrain_visual_batch_mesh(cache_key: String, mesh: ArrayMesh) -> void:
	if terrain_visual_batch_mesh_cache_limit <= 0 or cache_key.is_empty() or mesh == null:
		return
	if not _terrain_visual_batch_mesh_cache.has(cache_key):
		_terrain_visual_batch_mesh_cache_order.append(cache_key)
	_terrain_visual_batch_mesh_cache[cache_key] = mesh
	while _terrain_visual_batch_mesh_cache_order.size() > terrain_visual_batch_mesh_cache_limit:
		var evicted_key: String = str(_terrain_visual_batch_mesh_cache_order.pop_front())
		_terrain_visual_batch_mesh_cache.erase(evicted_key)

func _enqueue_completed_terrain_visual_batch_build(item: Dictionary) -> void:
	if not _completed_terrain_visual_batch_mutex:
		return
	_completed_terrain_visual_batch_mutex.lock()
	_completed_terrain_visual_batch_builds.append(item)
	_completed_terrain_visual_batch_mutex.unlock()

func _pop_completed_terrain_visual_batch_build() -> Dictionary:
	if not _completed_terrain_visual_batch_mutex:
		return {}
	_completed_terrain_visual_batch_mutex.lock()
	var item := {}
	if not _completed_terrain_visual_batch_builds.is_empty():
		item = _completed_terrain_visual_batch_builds.pop_front()
	_completed_terrain_visual_batch_mutex.unlock()
	return item

func _get_chunk_mesh_instance(node: Node) -> MeshInstance3D:
	if node == null:
		return null
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _get_chunk_mesh_instance(child)
		if found:
			return found
	return null

func _get_chunk_terrain_visual_mesh(data) -> Mesh:
	if data == null:
		return null
	if data.terrain_visual_mesh:
		return data.terrain_visual_mesh
	if data.node_terrain == null or not is_instance_valid(data.node_terrain):
		return null
	var mesh_instance := _get_chunk_mesh_instance(data.node_terrain)
	if mesh_instance and mesh_instance.mesh:
		data.terrain_visual_mesh = mesh_instance.mesh as ArrayMesh
		return mesh_instance.mesh
	return null

func _get_mesh_surface_vertex_count(mesh: Mesh) -> int:
	if mesh == null or mesh.get_surface_count() <= 0:
		return 0
	if mesh.has_method("surface_get_array_len"):
		return int(mesh.surface_get_array_len(0))
	var arrays := mesh.surface_get_arrays(0)
	if arrays.size() <= Mesh.ARRAY_VERTEX:
		return 0
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	return vertices.size()

func _get_mesh_surface_index_count(mesh: Mesh) -> int:
	if mesh == null or mesh.get_surface_count() <= 0:
		return 0
	if mesh.has_method("surface_get_array_index_len"):
		return int(mesh.surface_get_array_index_len(0))
	var arrays := mesh.surface_get_arrays(0)
	if arrays.size() <= Mesh.ARRAY_INDEX:
		return _get_mesh_surface_vertex_count(mesh)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	return indices.size() if not indices.is_empty() else _get_mesh_surface_vertex_count(mesh)

func _ensure_chunk_terrain_mesh_instance(data) -> MeshInstance3D:
	if data == null or data.node_terrain == null or not is_instance_valid(data.node_terrain):
		return null
	var mesh := _get_chunk_terrain_visual_mesh(data)
	if mesh == null:
		return null
	var mesh_instance := _get_chunk_mesh_instance(data.node_terrain)
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		data.node_terrain.add_child(mesh_instance)
	mesh_instance.mesh = mesh
	if data.chunk_material:
		mesh_instance.material_override = data.chunk_material
	return mesh_instance

func _is_chunk_eligible_for_terrain_visual_batch(coord: Vector3i, data) -> bool:
	if not _is_terrain_visual_batch_active() or coord.y != 0:
		return false
	if _is_chunk_near_viewer_for_visual_batch(coord, _effective_terrain_visual_batch_near_cull_radius()):
		return false
	if data == null or data.node_terrain == null or not is_instance_valid(data.node_terrain):
		return false
	if data.node_terrain is StaticBody3D:
		return false
	if data.mod_version != 0:
		return false
	if data.chunk_material != material_terrain:
		return false
	return _get_chunk_terrain_visual_mesh(data) != null

func _queue_terrain_visual_mesh_retire(coord: Vector3i) -> void:
	if coord.y != 0 or _terrain_visual_mesh_retire_queued.has(coord):
		return
	_terrain_visual_mesh_retire_queue.append(coord)
	_terrain_visual_mesh_retire_queued[coord] = true

func _retire_chunk_terrain_mesh_instance(data) -> void:
	if data == null or not bool(data.terrain_visual_batched):
		return
	if data.node_terrain == null or not is_instance_valid(data.node_terrain):
		return
	var existing_mesh_instance := _get_chunk_mesh_instance(data.node_terrain)
	if existing_mesh_instance == null:
		return
	if existing_mesh_instance.mesh:
		data.terrain_visual_mesh = existing_mesh_instance.mesh as ArrayMesh
	existing_mesh_instance.visible = false
	var mesh_parent := existing_mesh_instance.get_parent()
	if mesh_parent:
		mesh_parent.remove_child(existing_mesh_instance)
	existing_mesh_instance.queue_free()

func _process_terrain_visual_mesh_retire_queue() -> void:
	if _terrain_visual_mesh_retire_queue.is_empty():
		return
	if initial_load_phase or _visual_batch_streaming_busy():
		return
	if _last_frame_ms > 1000.0 / 60.0:
		return

	var retired := 0
	while retired < terrain_visual_mesh_retire_budget_per_frame and not _terrain_visual_mesh_retire_queue.is_empty():
		var coord: Vector3i = _terrain_visual_mesh_retire_queue.pop_front()
		_terrain_visual_mesh_retire_queued.erase(coord)
		if not active_chunks.has(coord):
			continue
		var data = active_chunks[coord]
		if data == null or not bool(data.terrain_visual_batched):
			continue
		_retire_chunk_terrain_mesh_instance(data)
		retired += 1

func _set_chunk_mesh_visible(data, visible: bool, coord: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)) -> void:
	if data == null or data.node_terrain == null or not is_instance_valid(data.node_terrain):
		return
	if visible:
		var mesh_instance := _ensure_chunk_terrain_mesh_instance(data)
		if mesh_instance:
			mesh_instance.visible = true
		data.terrain_visual_batched = false
		return

	var existing_mesh_instance := _get_chunk_mesh_instance(data.node_terrain)
	if existing_mesh_instance:
		existing_mesh_instance.visible = false
	data.terrain_visual_batched = true
	if coord != Vector3i(2147483647, 2147483647, 2147483647):
		_queue_terrain_visual_mesh_retire(coord)

func _show_individual_terrain_visuals_for_batch(key: Vector2i) -> void:
	var batch_members: Dictionary = _terrain_visual_batch_members.get(key, {})
	for coord_variant in batch_members:
		var coord: Vector3i = coord_variant
		var data = active_chunks.get(coord, null)
		_set_chunk_mesh_visible(data, true, coord)

func _mark_terrain_visual_batch_dirty(coord: Vector3i, invalidate_visible_batch: bool = false) -> void:
	if not _is_terrain_visual_batch_active() or coord.y != 0:
		return
	var key := _terrain_visual_batch_key(coord)
	_terrain_visual_batch_dirty[key] = true
	if invalidate_visible_batch and _terrain_visual_batches.has(key):
		var batch_node := _terrain_visual_batches[key] as MeshInstance3D
		if batch_node and is_instance_valid(batch_node):
			batch_node.visible = false
		_show_individual_terrain_visuals_for_batch(key)

func _clear_terrain_visual_batches(immediate: bool = false) -> void:
	for batch_variant in _terrain_visual_batch_members.keys():
		var key: Vector2i = batch_variant
		_show_individual_terrain_visuals_for_batch(key)
	for batch_variant in _terrain_visual_batches.values():
		var batch_node := batch_variant as Node
		if not batch_node:
			continue
		if immediate:
			batch_node.free()
		else:
			batch_node.queue_free()
	_terrain_visual_batches.clear()
	_terrain_visual_batch_dirty.clear()
	_terrain_visual_mesh_retire_queue.clear()
	_terrain_visual_mesh_retire_queued.clear()
	_last_terrain_visual_batch_hidden_chunk_count = 0
	_last_terrain_visual_batch_vertex_count = 0
	_last_terrain_visual_batch_index_count = 0
	_last_terrain_visual_batch_skipped_heavy_count = 0
	_terrain_visual_batch_total_heavy_skips = 0
	_terrain_visual_batch_hot_rebuild_frame_counter = 0
	_last_terrain_visual_batch_hot_rebuild = false

func _visual_batch_streaming_busy() -> bool:
	return _last_update_loads > 0 or _last_update_unloads > 0 or not pending_nodes.is_empty() or _get_completed_generation_queue_count() > 0 or _get_task_queue_count() > 0 or _get_cpu_task_queue_count() > 0

func _has_pending_spawn_zone_work() -> bool:
	return not pending_spawn_zones.is_empty()

func _terrain_visual_batch_rebuild_busy(_hot_frame: bool) -> bool:
	return _last_update_loads > 0 or _last_update_unloads > 0 or not pending_nodes.is_empty() or _get_completed_generation_queue_count() > 0 or _get_task_queue_count() > 0 or _get_cpu_task_queue_count() > 0

func _terrain_visual_batch_paused_for_active_gameplay() -> bool:
	return runtime_power_mode_enabled and (_runtime_power_viewer_moved_last or _runtime_power_foreground_terrain_busy_last)

func _has_terrain_visual_batch_polish_work() -> bool:
	var has_terrain_work := _is_terrain_visual_batch_active() \
		and (
			not _terrain_visual_batch_dirty.is_empty()
			or not _terrain_visual_batch_builds_in_flight.is_empty()
			or not _completed_terrain_visual_batch_builds.is_empty()
			or not _terrain_visual_mesh_retire_queue.is_empty()
		)
	return has_terrain_work or _has_water_visual_batch_polish_work()

func _process_idle_terrain_visual_batch_polish() -> void:
	_last_terrain_visual_batch_idle_polish = false
	if not terrain_visual_batch_idle_polish_enabled or not _has_terrain_visual_batch_polish_work():
		return
	if _terrain_visual_batch_paused_for_active_gameplay():
		return

	_last_terrain_visual_batch_idle_polish = true
	_terrain_visual_batch_idle_polish_frame_count += 1
	_process_completed_terrain_visual_batch_builds()
	_process_terrain_visual_batch_rebuilds()
	_process_terrain_visual_mesh_retire_queue()
	_process_water_visual_batch_rebuilds()
	_sync_terrain_shadow_lod()

func _process_completed_terrain_visual_batch_builds() -> void:
	_last_terrain_visual_batch_async_apply_count = 0
	_last_terrain_visual_batch_async_apply_ms = 0.0
	_last_terrain_visual_batch_async_stale_count = 0
	if not _is_terrain_visual_batch_active():
		return
	if _terrain_visual_batch_paused_for_active_gameplay():
		return
	if terrain_visual_batch_async_apply_per_frame <= 0:
		return
	var start_us := Time.get_ticks_usec()
	var applied := 0
	var stale := 0
	while applied < terrain_visual_batch_async_apply_per_frame:
		if applied > 0:
			var elapsed_ms := float(Time.get_ticks_usec() - start_us) / 1000.0
			if elapsed_ms >= terrain_visual_batch_async_apply_budget_ms:
				break
		var item := _pop_completed_terrain_visual_batch_build()
		if item.is_empty():
			break

		var key: Vector2i = item.get("batch_key", Vector2i.ZERO)
		var cache_key := str(item.get("cache_key", ""))
		_terrain_visual_batch_builds_in_flight.erase(cache_key)
		var merged_mesh := item.get("mesh", null) as ArrayMesh
		if merged_mesh == null:
			var mesh_result: Dictionary = item.get("mesh_result", {})
			if not mesh_result.is_empty():
				mesh_result = _materialize_deferred_mesh_result(mesh_result, material_terrain)
				merged_mesh = mesh_result.get("mesh", null) as ArrayMesh
		if merged_mesh == null or cache_key.is_empty():
			stale += 1
			continue

		_remember_terrain_visual_batch_mesh(cache_key, merged_mesh)
		var collected := _collect_terrain_visual_batch_inputs(key)
		var eligible_coords: Array[Vector3i] = collected.get("eligible_coords", [])
		if eligible_coords.is_empty():
			stale += 1
			continue
		if _terrain_visual_batch_cache_key(key, eligible_coords) != cache_key:
			stale += 1
			continue

		_apply_terrain_visual_batch_mesh(key, eligible_coords, merged_mesh)
		_terrain_visual_batch_dirty.erase(key)
		applied += 1

	_last_terrain_visual_batch_async_apply_count = applied
	_last_terrain_visual_batch_async_stale_count = stale
	_last_terrain_visual_batch_async_apply_ms = float(Time.get_ticks_usec() - start_us) / 1000.0

func _process_terrain_visual_batch_rebuilds() -> void:
	_last_terrain_visual_batch_rebuild_count = 0
	_last_terrain_visual_batch_rebuild_ms = 0.0
	_last_terrain_visual_batch_hot_rebuild = false
	_last_terrain_visual_batch_skipped_heavy_count = 0
	_last_terrain_visual_batch_cached_rebuild_count = 0
	_last_terrain_visual_batch_cached_rebuild_ms = 0.0
	_last_terrain_visual_batch_cached_rebuild_attempts = 0
	_last_terrain_visual_batch_async_queued_count = 0
	_last_terrain_visual_batch_streaming_async_queued_count = 0
	if _terrain_visual_batch_paused_for_active_gameplay():
		_terrain_visual_batch_stream_idle_frames = 0
		return
	if not _is_terrain_visual_batch_active():
		if not _terrain_visual_batches.is_empty():
			_clear_terrain_visual_batches()
		return
	if _terrain_visual_batch_dirty.is_empty():
		_terrain_visual_batch_hot_rebuild_frame_counter = 0
		return
	if initial_load_phase:
		return
	var hot_frame := _last_frame_ms > 1000.0 / 60.0
	if hot_frame:
		if _terrain_visual_batch_dirty.size() < terrain_visual_batch_hot_rebuild_dirty_threshold:
			return
		_terrain_visual_batch_hot_rebuild_frame_counter += 1
		if _terrain_visual_batch_hot_rebuild_frame_counter < terrain_visual_batch_hot_rebuild_interval_frames:
			return
		_terrain_visual_batch_hot_rebuild_frame_counter = 0
	else:
		_terrain_visual_batch_hot_rebuild_frame_counter = 0
	if _terrain_visual_batch_rebuild_busy(hot_frame):
		_terrain_visual_batch_stream_idle_frames = 0
		_process_cached_terrain_visual_batch_rebuilds()
		if terrain_visual_batch_async_during_streaming and terrain_visual_batch_async_build_enabled and not hot_frame:
			var streaming_builder := _get_terrain_visual_batch_builder()
			if streaming_builder and streaming_builder.has_method("build_merged_array_mesh"):
				_queue_streaming_terrain_visual_batch_builds(streaming_builder)
		return
	if hot_frame:
		_last_terrain_visual_batch_hot_rebuild = true
	else:
		_terrain_visual_batch_stream_idle_frames += 1
		if _terrain_visual_batch_stream_idle_frames < 20:
			return

	var builder := _get_terrain_visual_batch_builder()
	if not builder or not builder.has_method("build_merged_array_mesh"):
		return

	var start_us := Time.get_ticks_usec()
	var rebuilt := 0
	var keys := _terrain_visual_batch_dirty.keys()
	if terrain_visual_batch_async_build_enabled:
		var queued_or_applied := 0
		for key_variant in keys:
			if queued_or_applied >= terrain_visual_batch_async_builds_per_frame:
				break
			var key: Vector2i = key_variant
			if _terrain_visual_batch_key_in_flight(key):
				continue
			var queued_before := _last_terrain_visual_batch_async_queued_count
			if _rebuild_terrain_visual_batch(key, builder):
				_terrain_visual_batch_dirty.erase(key)
				rebuilt += 1
				queued_or_applied += 1
			elif _last_terrain_visual_batch_async_queued_count > queued_before:
				queued_or_applied += 1
		_last_terrain_visual_batch_rebuild_count = rebuilt
		_last_terrain_visual_batch_rebuild_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
		return

	if terrain_visual_batch_rebuilds_per_frame <= 1 and keys.size() > 1:
		var key := _select_nearest_terrain_visual_batch_key(keys)
		if _rebuild_terrain_visual_batch(key, builder):
			_terrain_visual_batch_dirty.erase(key)
			rebuilt = 1
		_last_terrain_visual_batch_rebuild_count = rebuilt
		_last_terrain_visual_batch_rebuild_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
		return

	for key_variant in keys:
		if rebuilt >= terrain_visual_batch_rebuilds_per_frame:
			break
		var key: Vector2i = key_variant
		if _rebuild_terrain_visual_batch(key, builder):
			_terrain_visual_batch_dirty.erase(key)
			rebuilt += 1

	_last_terrain_visual_batch_rebuild_count = rebuilt
	_last_terrain_visual_batch_rebuild_ms = float(Time.get_ticks_usec() - start_us) / 1000.0

func _queue_streaming_terrain_visual_batch_builds(builder: Object) -> void:
	if terrain_visual_batch_streaming_async_queue_per_frame <= 0:
		return
	if _terrain_visual_batch_dirty.is_empty():
		return
	if _terrain_visual_batch_builds_in_flight.size() >= terrain_visual_batch_async_build_queue_limit:
		return
	# Do not let visual merge work compete with chunk mesh construction.
	if _get_cpu_task_queue_count() > 0 or not _completed_terrain_visual_batch_builds.is_empty():
		return

	var queued := 0
	var keys := _get_terrain_visual_batch_keys_sorted_by_viewer()
	for key_variant in keys:
		if queued >= terrain_visual_batch_streaming_async_queue_per_frame:
			break
		if _terrain_visual_batch_builds_in_flight.size() >= terrain_visual_batch_async_build_queue_limit:
			break
		var key: Vector2i = key_variant
		if _terrain_visual_batch_key_in_flight(key):
			continue

		var queued_before := _last_terrain_visual_batch_async_queued_count
		if _rebuild_terrain_visual_batch(key, builder):
			_terrain_visual_batch_dirty.erase(key)
			continue
		if _last_terrain_visual_batch_async_queued_count > queued_before:
			queued += 1
			_last_terrain_visual_batch_streaming_async_queued_count += 1

func _process_cached_terrain_visual_batch_rebuilds() -> void:
	if terrain_visual_batch_cached_rebuilds_per_frame <= 0 or terrain_visual_batch_mesh_cache_limit <= 0:
		return
	if _terrain_visual_batch_dirty.is_empty() or _terrain_visual_batch_mesh_cache.is_empty():
		return

	var start_us := Time.get_ticks_usec()
	var rebuilt := 0
	var attempts := 0
	var keys := _terrain_visual_batch_dirty.keys()
	for key_variant in keys:
		if rebuilt >= terrain_visual_batch_cached_rebuilds_per_frame:
			break
		if attempts > 0:
			var elapsed_ms := float(Time.get_ticks_usec() - start_us) / 1000.0
			if elapsed_ms >= terrain_visual_batch_cached_rebuild_budget_ms:
				break

		var key: Vector2i = key_variant
		attempts += 1
		if _rebuild_terrain_visual_batch(key, null, true):
			_terrain_visual_batch_dirty.erase(key)
			rebuilt += 1

	_last_terrain_visual_batch_cached_rebuild_count = rebuilt
	_last_terrain_visual_batch_cached_rebuild_attempts = attempts
	_last_terrain_visual_batch_cached_rebuild_ms = float(Time.get_ticks_usec() - start_us) / 1000.0

func _get_terrain_visual_batch_keys_sorted_by_viewer() -> Array:
	var keys := _terrain_visual_batch_dirty.keys()
	if keys.size() <= 1:
		return keys

	var p_pos := get_viewer_position()
	var center_key := _terrain_visual_batch_key(Vector3i(
		int(floor(p_pos.x / CHUNK_STRIDE)),
		0,
		int(floor(p_pos.z / CHUNK_STRIDE))
	))
	keys.sort_custom(func(a, b) -> bool:
		var key_a: Vector2i = a
		var key_b: Vector2i = b
		var dx_a := key_a.x - center_key.x
		var dz_a := key_a.y - center_key.y
		var dx_b := key_b.x - center_key.x
		var dz_b := key_b.y - center_key.y
		return dx_a * dx_a + dz_a * dz_a < dx_b * dx_b + dz_b * dz_b
	)
	return keys

func _terrain_visual_batch_key_in_flight(key: Vector2i) -> bool:
	for in_flight_key_variant in _terrain_visual_batch_builds_in_flight.values():
		var in_flight_key: Vector2i = in_flight_key_variant
		if in_flight_key == key:
			return true
	return false

func _select_nearest_terrain_visual_batch_key(keys: Array) -> Vector2i:
	var p_pos := get_viewer_position()
	var center_coord := Vector3i(
		int(floor(p_pos.x / CHUNK_STRIDE)),
		0,
		int(floor(p_pos.z / CHUNK_STRIDE))
	)
	var center_key := _terrain_visual_batch_key(center_coord)
	var best_key: Vector2i = keys[0]
	var best_score := 2147483647
	for key_variant in keys:
		var key: Vector2i = key_variant
		var dx := key.x - center_key.x
		var dz := key.y - center_key.y
		var score := dx * dx + dz * dz
		if score < best_score:
			best_score = score
			best_key = key
	return best_key

func _collect_terrain_visual_batch_inputs(key: Vector2i) -> Dictionary:
	var merge_inputs: Array[Dictionary] = []
	var eligible_coords: Array[Vector3i] = []
	var total_vertices := 0
	var total_indices := 0

	var batch_members: Dictionary = _terrain_visual_batch_members.get(key, {})
	for coord_variant in batch_members:
		var coord: Vector3i = coord_variant
		var data = active_chunks.get(coord, null)
		if not _is_chunk_eligible_for_terrain_visual_batch(coord, data):
			_set_chunk_mesh_visible(data, true, coord)
			continue
		var terrain_mesh := _get_chunk_terrain_visual_mesh(data)
		if terrain_mesh == null:
			_set_chunk_mesh_visible(data, true, coord)
			continue
		if terrain_mesh.get_surface_count() <= 0:
			_set_chunk_mesh_visible(data, true, coord)
			continue
		var surface_arrays := terrain_mesh.surface_get_arrays(0)
		if surface_arrays.size() <= Mesh.ARRAY_VERTEX:
			_set_chunk_mesh_visible(data, true, coord)
			continue
		var surface_vertices: PackedVector3Array = surface_arrays[Mesh.ARRAY_VERTEX]
		if surface_vertices.is_empty():
			_set_chunk_mesh_visible(data, true, coord)
			continue
		var vertex_count := _get_mesh_surface_vertex_count(terrain_mesh)
		var index_count := _get_mesh_surface_index_count(terrain_mesh)
		total_vertices += vertex_count
		total_indices += index_count
		merge_inputs.append({
			"arrays": surface_arrays,
			"offset": data.node_terrain.position
		})
		eligible_coords.append(coord)

	return {
		"merge_inputs": merge_inputs,
		"eligible_coords": eligible_coords,
		"total_vertices": total_vertices,
		"total_indices": total_indices
	}

func _apply_terrain_visual_batch_mesh(key: Vector2i, eligible_coords: Array[Vector3i], merged_mesh: ArrayMesh) -> void:
	var batch_node: MeshInstance3D = null
	if _terrain_visual_batches.has(key):
		batch_node = _terrain_visual_batches[key] as MeshInstance3D
		if not is_instance_valid(batch_node):
			batch_node = null
	if batch_node == null:
		batch_node = MeshInstance3D.new()
		batch_node.name = "TerrainBatch_%d_%d" % [key.x, key.y]
		batch_node.material_override = material_terrain
		batch_node.add_to_group("terrain_visual_batch")
		_get_terrain_visual_batch_root().add_child(batch_node)
		_terrain_visual_batches[key] = batch_node

	batch_node.position = Vector3.ZERO
	batch_node.mesh = merged_mesh
	_set_mesh_shadow_casting(batch_node, _should_terrain_cast_shadow(_terrain_batch_shadow_coord(key)))
	batch_node.visible = true
	for coord in eligible_coords:
		var data = active_chunks.get(coord, null)
		_set_chunk_mesh_visible(data, false, coord)
	_last_terrain_visual_batch_hidden_chunk_count = _count_hidden_terrain_visual_batch_chunks()

func _queue_terrain_visual_batch_build(key: Vector2i, cache_key: String, merge_inputs: Array[Dictionary]) -> bool:
	if not terrain_visual_batch_async_build_enabled or cache_key.is_empty() or merge_inputs.is_empty():
		return false
	if _terrain_visual_batch_builds_in_flight.has(cache_key):
		return true
	if _terrain_visual_batch_builds_in_flight.size() >= terrain_visual_batch_async_build_queue_limit:
		return false
	_terrain_visual_batch_builds_in_flight[cache_key] = key
	cpu_mutex.lock()
	cpu_task_queue.append({
		"type": "terrain_visual_batch",
		"batch_key": key,
		"cache_key": cache_key,
		"merge_inputs": merge_inputs
	})
	cpu_mutex.unlock()
	cpu_semaphore.post()
	_last_terrain_visual_batch_async_queued_count += 1
	return true

func _rebuild_terrain_visual_batch(key: Vector2i, builder: Object, cache_only: bool = false) -> bool:
	var collected := _collect_terrain_visual_batch_inputs(key)
	var merge_inputs: Array[Dictionary] = collected.get("merge_inputs", [])
	var eligible_coords: Array[Vector3i] = collected.get("eligible_coords", [])
	var total_vertices := int(collected.get("total_vertices", 0))
	var total_indices := int(collected.get("total_indices", 0))

	_last_terrain_visual_batch_vertex_count = total_vertices
	_last_terrain_visual_batch_index_count = total_indices

	if merge_inputs.is_empty():
		if _terrain_visual_batches.has(key):
			var old_node := _terrain_visual_batches[key] as Node
			_terrain_visual_batches.erase(key)
			if old_node:
				old_node.queue_free()
		return true

	var terrain_batch_max_vertices := _effective_terrain_visual_batch_max_vertices()
	if terrain_batch_max_vertices > 0 and total_vertices > terrain_batch_max_vertices:
		if cache_only:
			return false
		if _terrain_visual_batches.has(key):
			var heavy_old_node := _terrain_visual_batches[key] as Node
			_terrain_visual_batches.erase(key)
			if heavy_old_node:
				heavy_old_node.queue_free()
		_show_individual_terrain_visuals_for_batch(key)
		_last_terrain_visual_batch_skipped_heavy_count += 1
		_terrain_visual_batch_total_heavy_skips += 1
		_last_terrain_visual_batch_hidden_chunk_count = _count_hidden_terrain_visual_batch_chunks()
		return true

	var cache_key := _terrain_visual_batch_cache_key(key, eligible_coords)
	var merged_mesh: ArrayMesh = null
	if terrain_visual_batch_mesh_cache_limit > 0 and _terrain_visual_batch_mesh_cache.has(cache_key):
		merged_mesh = _terrain_visual_batch_mesh_cache[cache_key] as ArrayMesh
		_last_terrain_visual_batch_cache_hit = merged_mesh != null
	else:
		_last_terrain_visual_batch_cache_hit = false

	if merged_mesh == null:
		if cache_only:
			return false
		if terrain_visual_batch_async_build_enabled:
			_queue_terrain_visual_batch_build(key, cache_key, merge_inputs)
			return false
		if builder == null or not builder.has_method("build_merged_array_mesh"):
			return false
		merged_mesh = builder.build_merged_array_mesh(merge_inputs)
		_terrain_visual_batch_mesh_cache_misses += 1
		_remember_terrain_visual_batch_mesh(cache_key, merged_mesh)
	else:
		_terrain_visual_batch_mesh_cache_hits += 1

	if merged_mesh == null:
		if cache_only:
			return false
		_show_individual_terrain_visuals_for_batch(key)
		return true

	_apply_terrain_visual_batch_mesh(key, eligible_coords, merged_mesh)
	return true

func _count_hidden_terrain_visual_batch_chunks() -> int:
	var count := 0
	for batch_variant in _terrain_visual_batch_members.keys():
		var key: Vector2i = batch_variant
		var batch_members: Dictionary = _terrain_visual_batch_members.get(key, {})
		for coord_variant in batch_members:
			var coord: Vector3i = coord_variant
			var data = active_chunks.get(coord, null)
			if not _is_chunk_eligible_for_terrain_visual_batch(coord, data):
				continue
			if bool(data.terrain_visual_batched):
				count += 1
	return count

func _get_water_visual_batch_root() -> Node3D:
	if _water_visual_batch_root and is_instance_valid(_water_visual_batch_root):
		return _water_visual_batch_root
	_water_visual_batch_root = Node3D.new()
	_water_visual_batch_root.name = "WaterVisualBatches"
	add_child(_water_visual_batch_root)
	return _water_visual_batch_root

func _water_visual_batch_key(coord: Vector3i) -> Vector2i:
	var batch_size := _effective_water_visual_batch_size()
	return Vector2i(
		int(floor(float(coord.x) / float(batch_size))),
		int(floor(float(coord.z) / float(batch_size)))
	)

func _water_visual_batch_origin(key: Vector2i) -> Vector3:
	var batch_size := _effective_water_visual_batch_size()
	var center_x := (float(key.x * batch_size) + float(batch_size) * 0.5) * float(CHUNK_STRIDE)
	var center_z := (float(key.y * batch_size) + float(batch_size) * 0.5) * float(CHUNK_STRIDE)
	return Vector3(center_x, 0.0, center_z)

func _register_water_visual_batch_member(coord: Vector3i) -> void:
	if coord.y != 0:
		return
	var key := _water_visual_batch_key(coord)
	var batch_members: Dictionary = _water_visual_batch_members.get(key, {})
	if batch_members.has(coord):
		return
	batch_members[coord] = true
	_water_visual_batch_members[key] = batch_members

func _unregister_water_visual_batch_member(coord: Vector3i) -> void:
	if coord.y != 0:
		return
	var key := _water_visual_batch_key(coord)
	if not _water_visual_batch_members.has(key):
		return
	var batch_members: Dictionary = _water_visual_batch_members[key]
	batch_members.erase(coord)
	if batch_members.is_empty():
		_water_visual_batch_members.erase(key)
	else:
		_water_visual_batch_members[key] = batch_members

func _get_chunk_water_visual_mesh(data) -> Mesh:
	if data == null:
		return null
	if data.water_visual_mesh:
		return data.water_visual_mesh
	if data.node_water == null or not is_instance_valid(data.node_water):
		return null
	var mesh_instance := _get_chunk_mesh_instance(data.node_water)
	if mesh_instance and mesh_instance.mesh:
		if mesh_instance.mesh is ArrayMesh:
			data.water_visual_mesh = mesh_instance.mesh as ArrayMesh
		return mesh_instance.mesh
	return null

func _ensure_chunk_water_mesh_instance(data) -> MeshInstance3D:
	if data == null or data.node_water == null or not is_instance_valid(data.node_water):
		return null
	var mesh := _get_chunk_water_visual_mesh(data)
	if mesh == null:
		return null
	var mesh_instance := _get_chunk_mesh_instance(data.node_water)
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		data.node_water.add_child(mesh_instance)
	mesh_instance.mesh = mesh
	mesh_instance.material_override = material_water
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mesh_instance

func _is_chunk_eligible_for_water_visual_batch(coord: Vector3i, data) -> bool:
	if not _is_water_visual_batch_active() or coord.y != 0:
		return false
	if _is_chunk_near_viewer_for_visual_batch(coord, _effective_water_visual_batch_near_cull_radius()):
		return false
	if data == null or data.node_water == null or not is_instance_valid(data.node_water):
		return false
	return _get_chunk_water_visual_mesh(data) != null

func _set_chunk_water_mesh_visible(data, visible: bool) -> void:
	if data == null or data.node_water == null or not is_instance_valid(data.node_water):
		return
	if visible:
		var mesh_instance := _ensure_chunk_water_mesh_instance(data)
		if mesh_instance:
			mesh_instance.visible = true
		data.water_visual_batched = false
		return

	var existing_mesh_instance := _get_chunk_mesh_instance(data.node_water)
	if existing_mesh_instance:
		existing_mesh_instance.visible = false
	data.water_visual_batched = true

func _show_individual_water_visuals_for_batch(key: Vector2i) -> void:
	var batch_members: Dictionary = _water_visual_batch_members.get(key, {})
	for coord_variant in batch_members:
		var coord: Vector3i = coord_variant
		var data = active_chunks.get(coord, null)
		_set_chunk_water_mesh_visible(data, true)

func _mark_water_visual_batch_dirty(coord: Vector3i, invalidate_visible_batch: bool = false) -> void:
	if not _is_water_visual_batch_active() or coord.y != 0:
		return
	var key := _water_visual_batch_key(coord)
	_water_visual_batch_dirty[key] = true
	if invalidate_visible_batch and _water_visual_batches.has(key):
		var batch_node := _water_visual_batches[key] as MeshInstance3D
		if batch_node and is_instance_valid(batch_node):
			batch_node.visible = false
		_show_individual_water_visuals_for_batch(key)

func _clear_water_visual_batches(immediate: bool = false) -> void:
	for batch_variant in _water_visual_batch_members.keys():
		var key: Vector2i = batch_variant
		_show_individual_water_visuals_for_batch(key)
	for batch_variant in _water_visual_batches.values():
		var batch_node := batch_variant as Node
		if not batch_node:
			continue
		if immediate:
			batch_node.free()
		else:
			batch_node.queue_free()
	_water_visual_batches.clear()
	_water_visual_batch_dirty.clear()
	_last_water_visual_batch_hidden_chunk_count = 0
	_last_water_visual_batch_vertex_count = 0
	_last_water_visual_batch_index_count = 0
	_last_water_visual_batch_skipped_heavy_count = 0
	_water_visual_batch_total_heavy_skips = 0

func _collect_terrain_visual_batch_member_coords() -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	var seen := {}
	for batch_members_variant in _terrain_visual_batch_members.values():
		var batch_members: Dictionary = batch_members_variant
		for coord_variant in batch_members.keys():
			var coord: Vector3i = coord_variant
			if seen.has(coord):
				continue
			seen[coord] = true
			coords.append(coord)
	if coords.is_empty():
		for coord_variant in active_chunks.keys():
			var coord: Vector3i = coord_variant
			if coord.y == 0:
				coords.append(coord)
	return coords

func _collect_water_visual_batch_member_coords() -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	var seen := {}
	for batch_members_variant in _water_visual_batch_members.values():
		var batch_members: Dictionary = batch_members_variant
		for coord_variant in batch_members.keys():
			var coord: Vector3i = coord_variant
			if seen.has(coord):
				continue
			seen[coord] = true
			coords.append(coord)
	if coords.is_empty():
		for coord_variant in active_chunks.keys():
			var coord: Vector3i = coord_variant
			if coord.y != 0:
				continue
			var data = active_chunks.get(coord, null)
			if data != null and data.node_water != null and is_instance_valid(data.node_water):
				coords.append(coord)
	return coords

func _rebuild_terrain_visual_batch_members_for_profile() -> void:
	var coords := _collect_terrain_visual_batch_member_coords()
	_clear_terrain_visual_batches()
	_clear_terrain_visual_batch_mesh_cache()
	_terrain_visual_batch_members.clear()
	for coord in coords:
		_register_terrain_visual_batch_member(coord)
	for key_variant in _terrain_visual_batch_members.keys():
		_terrain_visual_batch_dirty[key_variant] = true

func _rebuild_water_visual_batch_members_for_profile() -> void:
	var coords := _collect_water_visual_batch_member_coords()
	_clear_water_visual_batches()
	_water_visual_batch_members.clear()
	for coord in coords:
		_register_water_visual_batch_member(coord)
	for key_variant in _water_visual_batch_members.keys():
		_water_visual_batch_dirty[key_variant] = true

func _sync_visual_batch_profile() -> void:
	var terrain_size := _effective_terrain_visual_batch_size()
	var terrain_max_vertices := _effective_terrain_visual_batch_max_vertices()
	var terrain_near_cull_radius := _effective_terrain_visual_batch_near_cull_radius()
	var terrain_profile_changed := _last_effective_terrain_visual_batch_size >= 0 \
		and (
			terrain_size != _last_effective_terrain_visual_batch_size \
			or terrain_max_vertices != _last_effective_terrain_visual_batch_max_vertices
		)
	var terrain_near_cull_changed := _last_effective_terrain_visual_batch_near_cull_radius >= 0 \
		and terrain_near_cull_radius != _last_effective_terrain_visual_batch_near_cull_radius
	var previous_terrain_near_cull_radius := _last_effective_terrain_visual_batch_near_cull_radius
	_last_effective_terrain_visual_batch_size = terrain_size
	_last_effective_terrain_visual_batch_max_vertices = terrain_max_vertices
	_last_effective_terrain_visual_batch_near_cull_radius = terrain_near_cull_radius
	if terrain_profile_changed and _is_terrain_visual_batch_active():
		_rebuild_terrain_visual_batch_members_for_profile()

	var water_size := _effective_water_visual_batch_size()
	var water_max_vertices := _effective_water_visual_batch_max_vertices()
	var water_near_cull_radius := _effective_water_visual_batch_near_cull_radius()
	var water_profile_changed := _last_effective_water_visual_batch_size >= 0 \
		and (
			water_size != _last_effective_water_visual_batch_size \
			or water_max_vertices != _last_effective_water_visual_batch_max_vertices
		)
	var water_near_cull_changed := _last_effective_water_visual_batch_near_cull_radius >= 0 \
		and water_near_cull_radius != _last_effective_water_visual_batch_near_cull_radius
	var previous_water_near_cull_radius := _last_effective_water_visual_batch_near_cull_radius
	_last_effective_water_visual_batch_size = water_size
	_last_effective_water_visual_batch_max_vertices = water_max_vertices
	_last_effective_water_visual_batch_near_cull_radius = water_near_cull_radius
	if water_profile_changed and _is_water_visual_batch_active():
		_rebuild_water_visual_batch_members_for_profile()
	_sync_visual_batch_near_cull_dirty(
		terrain_near_cull_radius,
		water_near_cull_radius,
		terrain_near_cull_changed,
		water_near_cull_changed,
		previous_terrain_near_cull_radius,
		previous_water_near_cull_radius
	)

func _mark_visual_batch_near_cull_dirty(center_chunk: Vector2i, terrain_radius: int, water_radius: int) -> void:
	var radius := maxi(maxi(terrain_radius, water_radius), 0)
	if radius <= 0 or center_chunk.x > 2000000000:
		return
	for x in range(center_chunk.x - radius, center_chunk.x + radius + 1):
		for z in range(center_chunk.y - radius, center_chunk.y + radius + 1):
			var coord := Vector3i(x, 0, z)
			if terrain_radius > 0 and maxi(absi(coord.x - center_chunk.x), absi(coord.z - center_chunk.y)) <= terrain_radius:
				var terrain_key := _terrain_visual_batch_key(coord)
				if _terrain_visual_batch_members.has(terrain_key) or _terrain_visual_batches.has(terrain_key):
					_terrain_visual_batch_dirty[terrain_key] = true
			if water_radius > 0 and maxi(absi(coord.x - center_chunk.x), absi(coord.z - center_chunk.y)) <= water_radius:
				var water_key := _water_visual_batch_key(coord)
				if _water_visual_batch_members.has(water_key) or _water_visual_batches.has(water_key):
					_water_visual_batch_dirty[water_key] = true

func _sync_visual_batch_near_cull_dirty(
	terrain_radius: int,
	water_radius: int,
	terrain_radius_changed: bool,
	water_radius_changed: bool,
	previous_terrain_radius: int,
	previous_water_radius: int
) -> void:
	if not _is_terrain_visual_batch_active() and not _is_water_visual_batch_active():
		_last_visual_batch_near_cull_viewer_chunk = Vector2i(2147483647, 2147483647)
		return
	var max_radius := maxi(terrain_radius, water_radius)
	var previous_max_radius := maxi(maxi(previous_terrain_radius, previous_water_radius), 0)
	if max_radius <= 0 and previous_max_radius <= 0:
		_last_visual_batch_near_cull_viewer_chunk = Vector2i(2147483647, 2147483647)
		return
	var viewer_chunk := _viewer_visual_batch_chunk()
	var first_sync := _last_visual_batch_near_cull_viewer_chunk.x > 2000000000
	var viewer_changed := not first_sync and viewer_chunk != _last_visual_batch_near_cull_viewer_chunk
	if first_sync:
		_mark_visual_batch_near_cull_dirty(viewer_chunk, terrain_radius, water_radius)
	elif viewer_changed or terrain_radius_changed or water_radius_changed:
		_mark_visual_batch_near_cull_dirty(
			_last_visual_batch_near_cull_viewer_chunk,
			maxi(previous_terrain_radius, 0),
			maxi(previous_water_radius, 0)
		)
		_mark_visual_batch_near_cull_dirty(viewer_chunk, terrain_radius, water_radius)
	_last_visual_batch_near_cull_viewer_chunk = viewer_chunk

func _has_water_visual_batch_polish_work() -> bool:
	return _is_water_visual_batch_active() and not _water_visual_batch_dirty.is_empty()

func _process_water_visual_batch_rebuilds() -> void:
	_last_water_visual_batch_rebuild_count = 0
	_last_water_visual_batch_rebuild_ms = 0.0
	_last_water_visual_batch_skipped_heavy_count = 0
	if not _is_water_visual_batch_active():
		if not _water_visual_batches.is_empty():
			_clear_water_visual_batches()
		return
	if _water_visual_batch_dirty.is_empty():
		return
	if initial_load_phase:
		return
	if world_map_active and _terrain_visual_batch_paused_for_active_gameplay():
		return
	if _last_frame_ms > 1000.0 / 60.0:
		return
	if _visual_batch_streaming_busy():
		return

	var builder := _get_terrain_visual_batch_builder()
	if not builder or not builder.has_method("build_merged_array_mesh"):
		return

	var start_us := Time.get_ticks_usec()
	var rebuilt := 0
	var keys := _get_water_visual_batch_keys_sorted_by_viewer()
	for key_variant in keys:
		if rebuilt >= water_visual_batch_rebuilds_per_frame:
			break
		var key: Vector2i = key_variant
		if _rebuild_water_visual_batch(key, builder):
			_water_visual_batch_dirty.erase(key)
			rebuilt += 1

	_last_water_visual_batch_rebuild_count = rebuilt
	_last_water_visual_batch_rebuild_ms = float(Time.get_ticks_usec() - start_us) / 1000.0

func _get_water_visual_batch_keys_sorted_by_viewer() -> Array:
	var keys := _water_visual_batch_dirty.keys()
	if keys.size() <= 1:
		return keys

	var p_pos := get_viewer_position()
	var center_key := _water_visual_batch_key(Vector3i(
		int(floor(p_pos.x / CHUNK_STRIDE)),
		0,
		int(floor(p_pos.z / CHUNK_STRIDE))
	))
	keys.sort_custom(func(a, b) -> bool:
		var key_a: Vector2i = a
		var key_b: Vector2i = b
		var dx_a := key_a.x - center_key.x
		var dz_a := key_a.y - center_key.y
		var dx_b := key_b.x - center_key.x
		var dz_b := key_b.y - center_key.y
		return dx_a * dx_a + dz_a * dz_a < dx_b * dx_b + dz_b * dz_b
	)
	return keys

func _collect_water_visual_batch_inputs(key: Vector2i) -> Dictionary:
	var merge_inputs: Array[Dictionary] = []
	var eligible_coords: Array[Vector3i] = []
	var total_vertices := 0
	var total_indices := 0
	var batch_origin := _water_visual_batch_origin(key)

	var batch_members: Dictionary = _water_visual_batch_members.get(key, {})
	for coord_variant in batch_members:
		var coord: Vector3i = coord_variant
		var data = active_chunks.get(coord, null)
		if not _is_chunk_eligible_for_water_visual_batch(coord, data):
			_set_chunk_water_mesh_visible(data, true)
			continue
		var water_mesh := _get_chunk_water_visual_mesh(data)
		if water_mesh == null:
			_set_chunk_water_mesh_visible(data, true)
			continue
		if water_mesh.get_surface_count() <= 0:
			_set_chunk_water_mesh_visible(data, true)
			continue
		var surface_arrays := water_mesh.surface_get_arrays(0)
		if surface_arrays.size() <= Mesh.ARRAY_VERTEX:
			_set_chunk_water_mesh_visible(data, true)
			continue
		var surface_vertices: PackedVector3Array = surface_arrays[Mesh.ARRAY_VERTEX]
		if surface_vertices.is_empty():
			_set_chunk_water_mesh_visible(data, true)
			continue
		var vertex_count := _get_mesh_surface_vertex_count(water_mesh)
		var index_count := _get_mesh_surface_index_count(water_mesh)
		total_vertices += vertex_count
		total_indices += index_count
		merge_inputs.append({
			"arrays": surface_arrays,
			"offset": data.node_water.position - batch_origin
		})
		eligible_coords.append(coord)

	return {
		"merge_inputs": merge_inputs,
		"eligible_coords": eligible_coords,
		"total_vertices": total_vertices,
		"total_indices": total_indices
	}

func _apply_water_visual_batch_mesh(key: Vector2i, eligible_coords: Array[Vector3i], merged_mesh: ArrayMesh) -> void:
	var batch_node: MeshInstance3D = null
	if _water_visual_batches.has(key):
		batch_node = _water_visual_batches[key] as MeshInstance3D
		if not is_instance_valid(batch_node):
			batch_node = null
	if batch_node == null:
		batch_node = MeshInstance3D.new()
		batch_node.name = "WaterBatch_%d_%d" % [key.x, key.y]
		batch_node.material_override = material_water
		batch_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		batch_node.add_to_group("water_visual_batch")
		_get_water_visual_batch_root().add_child(batch_node)
		_water_visual_batches[key] = batch_node

	batch_node.position = _water_visual_batch_origin(key)
	batch_node.mesh = merged_mesh
	batch_node.visible = true
	for coord in eligible_coords:
		var data = active_chunks.get(coord, null)
		_set_chunk_water_mesh_visible(data, false)
	_last_water_visual_batch_hidden_chunk_count = _count_hidden_water_visual_batch_chunks()

func _rebuild_water_visual_batch(key: Vector2i, builder: Object) -> bool:
	var collected := _collect_water_visual_batch_inputs(key)
	var merge_inputs: Array[Dictionary] = collected.get("merge_inputs", [])
	var eligible_coords: Array[Vector3i] = collected.get("eligible_coords", [])
	var total_vertices := int(collected.get("total_vertices", 0))
	var total_indices := int(collected.get("total_indices", 0))

	_last_water_visual_batch_vertex_count = total_vertices
	_last_water_visual_batch_index_count = total_indices

	if merge_inputs.is_empty():
		if _water_visual_batches.has(key):
			var old_node := _water_visual_batches[key] as Node
			_water_visual_batches.erase(key)
			if old_node:
				old_node.queue_free()
		return true

	var water_batch_max_vertices := _effective_water_visual_batch_max_vertices()
	if water_batch_max_vertices > 0 and total_vertices > water_batch_max_vertices:
		if _water_visual_batches.has(key):
			var heavy_old_node := _water_visual_batches[key] as Node
			_water_visual_batches.erase(key)
			if heavy_old_node:
				heavy_old_node.queue_free()
		_show_individual_water_visuals_for_batch(key)
		_last_water_visual_batch_skipped_heavy_count += 1
		_water_visual_batch_total_heavy_skips += 1
		_last_water_visual_batch_hidden_chunk_count = _count_hidden_water_visual_batch_chunks()
		return true

	if builder == null or not builder.has_method("build_merged_array_mesh"):
		return false
	var merged_mesh := builder.build_merged_array_mesh(merge_inputs) as ArrayMesh
	if merged_mesh == null:
		_show_individual_water_visuals_for_batch(key)
		return true

	_apply_water_visual_batch_mesh(key, eligible_coords, merged_mesh)
	return true

func _count_hidden_water_visual_batch_chunks() -> int:
	var count := 0
	for batch_variant in _water_visual_batch_members.keys():
		var key: Vector2i = batch_variant
		var batch_members: Dictionary = _water_visual_batch_members.get(key, {})
		for coord_variant in batch_members:
			var coord: Vector3i = coord_variant
			var data = active_chunks.get(coord, null)
			if not _is_chunk_eligible_for_water_visual_batch(coord, data):
				continue
			if bool(data.water_visual_batched):
				count += 1
	return count

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

func _clear_vegetation_runtime_chunks_for_world_reset() -> bool:
	var vegetation_manager := get_tree().get_first_node_in_group("vegetation_manager")
	if not vegetation_manager:
		vegetation_manager = get_tree().root.find_child("VegetationManager", true, false)
	if not vegetation_manager or not vegetation_manager.has_method("clear_loaded_chunk_data"):
		return false

	vegetation_manager.clear_loaded_chunk_data(false)
	return true


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

func _has_pending_priority_gpu_tasks_or_exit() -> bool:
	mutex.lock()
	var has_tasks := exit_thread or not priority_task_queue.is_empty()
	mutex.unlock()
	return has_tasks


func _find_urgent_background_gpu_task_index(queue: Array[Dictionary]) -> int:
	for i in range(queue.size() - 1, -1, -1):
		var queued_task: Dictionary = queue[i]
		var task_type := str(queued_task.get("type", ""))
		if task_type == "free" or task_type == "free_many" or task_type == "modify":
			return i
	return -1


func _pop_next_gpu_task() -> Dictionary:
	mutex.lock()
	var task: Dictionary = {}
	if not priority_task_queue.is_empty():
		var modify_index := -1
		for i in range(priority_task_queue.size()):
			var queued_task: Dictionary = priority_task_queue[i]
			if str(queued_task.get("type", "")) == "modify":
				modify_index = i
				break
		if modify_index >= 0:
			task = priority_task_queue[modify_index]
			priority_task_queue.remove_at(modify_index)
		else:
			task = priority_task_queue.pop_front()
	elif not task_queue.is_empty():
		if _runtime_power_world_work_suspended:
			var urgent_index := _find_urgent_background_gpu_task_index(task_queue)
			if urgent_index >= 0:
				task = task_queue[urgent_index]
				task_queue.remove_at(urgent_index)
		else:
			task = task_queue.pop_back()
	mutex.unlock()
	return task

func _get_chunk_layer_mod_version(data: ChunkData, layer: int) -> int:
	if data == null:
		return 0
	return int(data.water_mod_version) if layer == 1 else int(data.mod_version)

func _set_generated_mod_version(data: ChunkData, stored_mod_version: int) -> void:
	if data == null:
		return
	data.mod_version = maxi(data.mod_version, stored_mod_version)
	data.water_mod_version = maxi(data.water_mod_version, stored_mod_version)

func _bump_chunk_layer_mod_version(data: ChunkData, layer: int, stored_mod_version: int) -> int:
	if data == null:
		return 0
	if layer == 1:
		data.water_mod_version = maxi(data.water_mod_version + 1, stored_mod_version)
		return data.water_mod_version
	data.mod_version = maxi(data.mod_version + 1, stored_mod_version)
	return data.mod_version


func _clear_gpu_task_queues(discard_free_tasks: bool = false) -> void:
	mutex.lock()
	if discard_free_tasks:
		priority_task_queue.clear()
		task_queue.clear()
	else:
		_keep_only_gpu_free_tasks(priority_task_queue)
		_keep_only_gpu_free_tasks(task_queue)
	mutex.unlock()


func _keep_only_gpu_free_tasks(queue: Array[Dictionary]) -> void:
	var i := queue.size() - 1
	while i >= 0:
		var task: Dictionary = queue[i]
		var task_type := str(task.get("type", ""))
		if task_type != "free" and task_type != "free_many":
			queue.remove_at(i)
		i -= 1


func _queue_gpu_free_tasks(tasks: Array[Dictionary]) -> void:
	if tasks.is_empty() or not mutex or not semaphore:
		return

	mutex.lock()
	if tasks.size() == 1:
		task_queue.append(tasks[0])
	else:
		var rids := []
		for t in tasks:
			var rid: RID = t.get("rid", RID())
			if rid.is_valid():
				rids.append(rid)
		if not rids.is_empty():
			task_queue.append({"type": "free_many", "rids": rids})
	mutex.unlock()

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


func _append_cpu_task_free_tasks(item: Dictionary, cleanup_tasks: Array[Dictionary]) -> void:
	var dens_t: RID = item.get("dens_buf_terrain", RID())
	if dens_t.is_valid():
		cleanup_tasks.append({"type": "free", "rid": dens_t})
	var dens_w: RID = item.get("dens_buf_water", RID())
	if dens_w.is_valid():
		cleanup_tasks.append({"type": "free", "rid": dens_w})
	var mat_t: RID = item.get("mat_buf_terrain", RID())
	if mat_t.is_valid():
		cleanup_tasks.append({"type": "free", "rid": mat_t})


func _drain_cpu_task_free_tasks() -> Array[Dictionary]:
	var cleanup_tasks: Array[Dictionary] = []
	if not cpu_mutex:
		return cleanup_tasks

	cpu_mutex.lock()
	for item in cpu_task_queue:
		if item is Dictionary:
			_append_cpu_task_free_tasks(item, cleanup_tasks)
	cpu_task_queue.clear()
	cpu_mutex.unlock()

	return cleanup_tasks


func _free_gpu_cleanup_tasks_now(rd: RenderingDevice, tasks: Array[Dictionary]) -> void:
	for task in tasks:
		var task_type := str(task.get("type", ""))
		if task_type == "free_many":
			for rid_variant in task.get("rids", []):
				var rid_many: RID = rid_variant
				if rid_many.is_valid():
					rd.free_rid(rid_many)
		else:
			var rid: RID = task.get("rid", RID())
			if rid.is_valid():
				rd.free_rid(rid)


func _append_completed_generation_free_tasks(item: Dictionary, cleanup_tasks: Array[Dictionary]) -> void:
	var dens_t: RID = item.get("dens_t", RID())
	if dens_t.is_valid():
		cleanup_tasks.append({"type": "free", "rid": dens_t})
	var dens_w: RID = item.get("dens_w", RID())
	if dens_w.is_valid():
		cleanup_tasks.append({"type": "free", "rid": dens_w})
	var mat_t: RID = item.get("mat_t", RID())
	if mat_t.is_valid():
		cleanup_tasks.append({"type": "free", "rid": mat_t})


func _drain_completed_generation_free_tasks() -> Array[Dictionary]:
	var cleanup_tasks: Array[Dictionary] = []
	if not completed_generation_mutex:
		return cleanup_tasks

	completed_generation_mutex.lock()
	for item in completed_generation_queue:
		if item is Dictionary:
			_append_completed_generation_free_tasks(item, cleanup_tasks)
	completed_generation_queue.clear()
	completed_generation_mutex.unlock()
	_last_completed_generation_drain_count = 0
	_last_completed_generation_drain_ms = 0.0

	return cleanup_tasks


func _enqueue_completed_generation(item: Dictionary) -> void:
	if not completed_generation_mutex:
		call_deferred("_complete_generation_from_queue_item", item)
		return

	completed_generation_mutex.lock()
	completed_generation_queue.append(item)
	completed_generation_mutex.unlock()


func _get_completed_generation_queue_count() -> int:
	if not completed_generation_mutex:
		return 0
	completed_generation_mutex.lock()
	var count := completed_generation_queue.size()
	completed_generation_mutex.unlock()
	return count


func _pop_completed_generation_item() -> Dictionary:
	if not completed_generation_mutex:
		return {}
	completed_generation_mutex.lock()
	var item := {}
	if not completed_generation_queue.is_empty():
		item = completed_generation_queue.pop_back()
	completed_generation_mutex.unlock()
	return item


func _drain_completed_generation_queue() -> void:
	if not completed_generation_mutex:
		_last_completed_generation_drain_count = 0
		_last_completed_generation_drain_ms = 0.0
		return

	var start_us := Time.get_ticks_usec()
	var drained := 0
	while drained < completed_generation_drain_limit_per_frame:
		if drained > 0:
			var elapsed_ms := float(Time.get_ticks_usec() - start_us) / 1000.0
			if elapsed_ms >= completed_generation_drain_budget_ms:
				break

		var item := _pop_completed_generation_item()
		if item.is_empty():
			break

		_complete_generation_from_queue_item(item)
		drained += 1

	_last_completed_generation_drain_count = drained
	_last_completed_generation_drain_ms = float(Time.get_ticks_usec() - start_us) / 1000.0


func _complete_generation_from_queue_item(item: Dictionary) -> void:
	complete_generation(
		item.get("coord", Vector3i.ZERO),
		item.get("result_t", {}),
		item.get("dens_t", RID()),
		item.get("result_w", {}),
		item.get("dens_w", RID()),
		item.get("cpu_dens_w", PackedFloat32Array()),
		item.get("cpu_dens_t", PackedFloat32Array()),
		item.get("height_map_t", PackedFloat32Array()),
		item.get("mat_t", RID()),
		item.get("cpu_mat_t", PackedByteArray()),
		int(item.get("stored_mod_version", 0))
	)


func _drain_pending_finalization_free_tasks() -> Array[Dictionary]:
	var cleanup_tasks: Array[Dictionary] = []
	if not pending_nodes_mutex:
		return cleanup_tasks

	pending_nodes_mutex.lock()
	for item in pending_nodes:
		if item is Dictionary:
			_append_pending_finalization_free_tasks(item, cleanup_tasks)
	pending_nodes.clear()
	_reset_pending_node_sort_state()
	pending_nodes_mutex.unlock()

	return cleanup_tasks


func _reset_pending_node_sort_state() -> void:
	pending_nodes_needs_sort = false
	_pending_nodes_sort_center = Vector3i(2147483647, 2147483647, 2147483647)
	_pending_nodes_sort_size_at_last_sort = 0
	_last_pending_node_sort_ms = 0.0
	_last_pending_node_sort_count = 0
	_last_pending_node_sort_skipped = false


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

	_update_runtime_power_mode(delta)
	_sync_visual_batch_profile()

	if skip_terrain_chunk_updates_for_test:
		return

	if _runtime_power_world_work_suspended:
		_record_runtime_power_world_work_suspended_frame()
		if _world_map_lod_background_fill_allowed():
			_update_world_map_lod_chunks(true)
		_process_idle_terrain_visual_batch_polish()
		_sync_terrain_shadow_lod()
		return

	_process_retired_chunk_node_cleanup()

	var spawn_zone_work_pending := _has_pending_spawn_zone_work()
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
		if _terrain_stream_update_needed():
			update_chunks()
			_record_terrain_stream_update_key()
		else:
			_skip_terrain_stream_update()

		_drain_completed_generation_queue()
		process_pending_nodes()
	else:
		if _terrain_stream_update_needed():
			update_chunk_unloads_only()
			_record_terrain_stream_update_key()
		else:
			_skip_terrain_stream_update()
		if spawn_zone_work_pending:
			_drain_completed_generation_queue()
			process_pending_nodes(true)

	update_collision_proximity() # Enable/disable collision based on player distance
	process_pending_terrain_collision_creates()
	if not pending_spawn_zones.is_empty():
		_check_spawn_zone_readiness(Vector3i(2147483647, 2147483647, 2147483647))
	if not defer_terrain_finalization and (not loading_paused or _world_map_lod_background_fill_allowed()):
		_update_world_map_lod_chunks(loading_paused)
	_process_completed_terrain_visual_batch_builds()
	_process_terrain_visual_batch_rebuilds()
	_process_terrain_visual_mesh_retire_queue()
	_process_water_visual_batch_rebuilds()
	_sync_terrain_shadow_lod()

var debug_chunk_bounds: bool = false

func _unhandled_input(_event):
	if runtime_power_mode_enabled and (_runtime_power_world_work_suspended or _runtime_power_render_loop_suspended):
		_runtime_power_idle_seconds = 0.0
		_runtime_power_active_grace_remaining_s = runtime_power_active_grace_s
		_runtime_power_active_reason = "input_event"
		_set_runtime_power_world_work_suspended(false, "input_event")
		_apply_runtime_power_fps("active", runtime_power_active_max_fps)

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

func _get_runtime_power_env_int(name: String, default_value: int) -> int:
	var raw := OS.get_environment(name).strip_edges()
	if raw.is_empty() or not raw.is_valid_int():
		return default_value
	var value := int(raw)
	return value if value > 0 else default_value

func _get_runtime_power_env_int_range(name: String, default_value: int, min_value: int, max_value: int) -> int:
	var raw := OS.get_environment(name).strip_edges()
	if raw.is_empty() or not raw.is_valid_int():
		return default_value
	return clampi(int(raw), min_value, max_value)

func _get_runtime_power_env_float(name: String, default_value: float) -> float:
	var raw := OS.get_environment(name).strip_edges()
	if raw.is_empty() or not raw.is_valid_float():
		return default_value
	var value := float(raw)
	return value if value > 0.0 else default_value

func _get_runtime_power_env_bool(name: String, default_value: bool) -> bool:
	var raw := OS.get_environment(name).strip_edges().to_lower()
	if raw.is_empty():
		return default_value
	if raw == "1" or raw == "true" or raw == "yes" or raw == "on":
		return true
	if raw == "0" or raw == "false" or raw == "no" or raw == "off":
		return false
	return default_value

func _configure_runtime_power_mode_from_env() -> void:
	_runtime_power_disabled_reason = ""
	if OS.get_environment("TOWN_STALL_DISABLE_RUNTIME_POWER_MODE") == "1":
		runtime_power_mode_enabled = false
		_runtime_power_disabled_reason = "disabled_by_env"
	elif not OS.get_environment("TOWN_STALL_MAX_FPS").strip_edges().is_empty() and OS.get_environment("TOWN_STALL_ENABLE_RUNTIME_POWER_MODE") != "1":
		runtime_power_mode_enabled = false
		_runtime_power_disabled_reason = "fixed_max_fps_test_override"

	runtime_power_active_max_fps = _get_runtime_power_env_int("TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS", runtime_power_active_max_fps)
	runtime_power_idle_max_fps = _get_runtime_power_env_int("TOWN_STALL_RUNTIME_POWER_IDLE_FPS", runtime_power_idle_max_fps)
	runtime_power_deep_idle_max_fps = _get_runtime_power_env_int("TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS", runtime_power_deep_idle_max_fps)
	runtime_power_idle_enter_delay_s = _get_runtime_power_env_float("TOWN_STALL_RUNTIME_POWER_IDLE_DELAY_S", runtime_power_idle_enter_delay_s)
	runtime_power_deep_idle_enter_delay_s = _get_runtime_power_env_float("TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_DELAY_S", runtime_power_deep_idle_enter_delay_s)
	runtime_power_active_grace_s = _get_runtime_power_env_float("TOWN_STALL_RUNTIME_POWER_ACTIVE_GRACE_S", runtime_power_active_grace_s)
	runtime_power_suspend_render_loop_in_deep_idle = _get_runtime_power_env_bool("TOWN_STALL_RUNTIME_POWER_SUSPEND_RENDER_LOOP", runtime_power_suspend_render_loop_in_deep_idle)
	runtime_power_suspend_background_world_work = _get_runtime_power_env_bool("TOWN_STALL_RUNTIME_POWER_SUSPEND_BACKGROUND_WORLD_WORK", runtime_power_suspend_background_world_work)
	runtime_power_viewport_scaling_enabled = _get_runtime_power_env_bool("TOWN_STALL_RUNTIME_POWER_VIEWPORT_SCALING", runtime_power_viewport_scaling_enabled)
	runtime_power_active_3d_scale = clampf(_get_runtime_power_env_float("TOWN_STALL_RUNTIME_POWER_ACTIVE_3D_SCALE", runtime_power_active_3d_scale), 0.5, 1.0)
	runtime_power_idle_3d_scale = clampf(_get_runtime_power_env_float("TOWN_STALL_RUNTIME_POWER_IDLE_3D_SCALE", runtime_power_idle_3d_scale), 0.5, 1.0)
	runtime_power_deep_idle_3d_scale = clampf(_get_runtime_power_env_float("TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_3D_SCALE", runtime_power_deep_idle_3d_scale), 0.5, 1.0)
	runtime_power_idle_max_fps = mini(runtime_power_idle_max_fps, runtime_power_active_max_fps)
	runtime_power_deep_idle_max_fps = mini(runtime_power_deep_idle_max_fps, runtime_power_idle_max_fps)
	runtime_power_deep_idle_enter_delay_s = maxf(runtime_power_deep_idle_enter_delay_s, runtime_power_idle_enter_delay_s)

	if runtime_power_mode_enabled:
		_apply_runtime_power_fps("active", runtime_power_active_max_fps)
	else:
		_apply_runtime_power_viewport_scale("active")

func _configure_terrain_gpu_mode_from_env() -> void:
	terrain_gpu_separate_water_meshing = _get_runtime_power_env_bool("TOWN_STALL_TERRAIN_GPU_SEPARATE_WATER_MESHING", terrain_gpu_separate_water_meshing)
	terrain_gpu_mesh_slices_per_chunk = _get_runtime_power_env_int_range("TOWN_STALL_TERRAIN_GPU_MESH_SLICES", terrain_gpu_mesh_slices_per_chunk, 1, 8)
	terrain_gpu_mesh_slice_delay_ms = _get_runtime_power_env_int_range("TOWN_STALL_TERRAIN_GPU_MESH_SLICE_DELAY_MS", terrain_gpu_mesh_slice_delay_ms, 0, 20)
	terrain_native_cpu_meshing_enabled = _get_runtime_power_env_bool("TOWN_STALL_TERRAIN_NATIVE_CPU_MESHING", terrain_native_cpu_meshing_enabled)
	terrain_skip_dry_water_density_dispatch = _get_runtime_power_env_bool("TOWN_STALL_SKIP_DRY_WATER_DENSITY_DISPATCH", terrain_skip_dry_water_density_dispatch)
	water_screen_refraction_enabled = _get_runtime_power_env_bool("TOWN_STALL_WATER_SCREEN_REFRACTION", water_screen_refraction_enabled)
	if OS.get_environment("TOWN_STALL_DISABLE_WATER_RENDER") == "1":
		water_render_enabled = false
	shared_terrain_collision_create_budget_per_frame = _get_runtime_power_env_int_range("TOWN_STALL_SHARED_TERRAIN_COLLISION_CREATE_BUDGET", shared_terrain_collision_create_budget_per_frame, 1, 64)
	terrain_visual_batching_enabled = _get_runtime_power_env_bool("TOWN_STALL_TERRAIN_VISUAL_BATCHING", terrain_visual_batching_enabled)
	procedural_terrain_visual_batching_enabled = _get_runtime_power_env_bool("TOWN_STALL_PROCEDURAL_TERRAIN_VISUAL_BATCHING", procedural_terrain_visual_batching_enabled)
	world_map_visual_batch_profile_enabled = _get_runtime_power_env_bool("TOWN_STALL_WORLD_MAP_VISUAL_BATCH_PROFILE", world_map_visual_batch_profile_enabled)
	distant_world_map_lod_enabled = _get_runtime_power_env_bool("TOWN_STALL_DISTANT_WORLD_MAP_LOD", distant_world_map_lod_enabled)
	distant_world_map_lod_distance = _get_runtime_power_env_int_range("TOWN_STALL_DISTANT_WORLD_MAP_LOD_DISTANCE", distant_world_map_lod_distance, 1, 64)
	distant_world_map_lod_overlap = _get_runtime_power_env_int_range("TOWN_STALL_DISTANT_WORLD_MAP_LOD_OVERLAP", distant_world_map_lod_overlap, 0, 8)
	distant_world_map_lod_sample_step = _get_runtime_power_env_int_range("TOWN_STALL_DISTANT_WORLD_MAP_LOD_SAMPLE_STEP", distant_world_map_lod_sample_step, 1, 16)
	distant_world_map_lod_budget_per_frame = _get_runtime_power_env_int_range("TOWN_STALL_DISTANT_WORLD_MAP_LOD_BUDGET", distant_world_map_lod_budget_per_frame, 1, 16)
	distant_world_map_lod_defer_until_initial_viewer_move = _get_runtime_power_env_bool("TOWN_STALL_DISTANT_WORLD_MAP_LOD_DEFER_INITIAL", distant_world_map_lod_defer_until_initial_viewer_move)
	var terrain_batch_size_overridden := not OS.get_environment("TOWN_STALL_TERRAIN_VISUAL_BATCH_SIZE").is_empty()
	var terrain_batch_max_overridden := not OS.get_environment("TOWN_STALL_TERRAIN_VISUAL_BATCH_MAX_VERTICES").is_empty()
	var water_batch_size_overridden := not OS.get_environment("TOWN_STALL_WATER_VISUAL_BATCH_SIZE").is_empty()
	var water_batch_max_overridden := not OS.get_environment("TOWN_STALL_WATER_VISUAL_BATCH_MAX_VERTICES").is_empty()
	terrain_visual_batch_size = _get_runtime_power_env_int_range("TOWN_STALL_TERRAIN_VISUAL_BATCH_SIZE", terrain_visual_batch_size, 1, 16)
	world_map_terrain_visual_batch_size = _get_runtime_power_env_int_range("TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_SIZE", world_map_terrain_visual_batch_size, 1, 16)
	if terrain_batch_size_overridden and OS.get_environment("TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_SIZE").is_empty():
		world_map_terrain_visual_batch_size = terrain_visual_batch_size
	terrain_visual_batch_max_vertices = _get_runtime_power_env_int_range("TOWN_STALL_TERRAIN_VISUAL_BATCH_MAX_VERTICES", terrain_visual_batch_max_vertices, 0, 200000)
	world_map_terrain_visual_batch_max_vertices = _get_runtime_power_env_int_range("TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_MAX_VERTICES", world_map_terrain_visual_batch_max_vertices, 0, 200000)
	if terrain_batch_max_overridden and OS.get_environment("TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_MAX_VERTICES").is_empty():
		world_map_terrain_visual_batch_max_vertices = terrain_visual_batch_max_vertices
	terrain_visual_batch_async_during_streaming = _get_runtime_power_env_bool("TOWN_STALL_TERRAIN_BATCH_STREAMING_ASYNC", terrain_visual_batch_async_during_streaming)
	terrain_visual_batch_streaming_async_queue_per_frame = _get_runtime_power_env_int_range("TOWN_STALL_TERRAIN_BATCH_STREAMING_ASYNC_QUEUE", terrain_visual_batch_streaming_async_queue_per_frame, 0, 8)
	terrain_visual_batch_idle_polish_enabled = _get_runtime_power_env_bool("TOWN_STALL_TERRAIN_BATCH_IDLE_POLISH", terrain_visual_batch_idle_polish_enabled)
	procedural_terrain_visual_batch_near_cull_radius_chunks = _get_runtime_power_env_int_range("TOWN_STALL_PROCEDURAL_TERRAIN_VISUAL_BATCH_NEAR_CULL_RADIUS", procedural_terrain_visual_batch_near_cull_radius_chunks, 0, 8)
	terrain_shadow_lod_enabled = _get_runtime_power_env_bool("TOWN_STALL_TERRAIN_SHADOW_LOD", terrain_shadow_lod_enabled)
	terrain_shadow_lod_radius_chunks = _get_runtime_power_env_int_range("TOWN_STALL_TERRAIN_SHADOW_LOD_RADIUS", terrain_shadow_lod_radius_chunks, 0, 32)
	water_visual_batching_enabled = _get_runtime_power_env_bool("TOWN_STALL_WATER_VISUAL_BATCHING", water_visual_batching_enabled)
	procedural_water_visual_batching_enabled = _get_runtime_power_env_bool("TOWN_STALL_PROCEDURAL_WATER_VISUAL_BATCHING", procedural_water_visual_batching_enabled)
	water_visual_batch_size = _get_runtime_power_env_int_range("TOWN_STALL_WATER_VISUAL_BATCH_SIZE", water_visual_batch_size, 1, 16)
	world_map_water_visual_batch_size = _get_runtime_power_env_int_range("TOWN_STALL_WORLD_MAP_WATER_VISUAL_BATCH_SIZE", world_map_water_visual_batch_size, 1, 16)
	if water_batch_size_overridden and OS.get_environment("TOWN_STALL_WORLD_MAP_WATER_VISUAL_BATCH_SIZE").is_empty():
		world_map_water_visual_batch_size = water_visual_batch_size
	water_visual_batch_rebuilds_per_frame = _get_runtime_power_env_int_range("TOWN_STALL_WATER_VISUAL_BATCH_REBUILDS_PER_FRAME", water_visual_batch_rebuilds_per_frame, 1, 8)
	water_visual_batch_max_vertices = _get_runtime_power_env_int_range("TOWN_STALL_WATER_VISUAL_BATCH_MAX_VERTICES", water_visual_batch_max_vertices, 0, 200000)
	world_map_water_visual_batch_max_vertices = _get_runtime_power_env_int_range("TOWN_STALL_WORLD_MAP_WATER_VISUAL_BATCH_MAX_VERTICES", world_map_water_visual_batch_max_vertices, 0, 200000)
	if water_batch_max_overridden and OS.get_environment("TOWN_STALL_WORLD_MAP_WATER_VISUAL_BATCH_MAX_VERTICES").is_empty():
		world_map_water_visual_batch_max_vertices = water_visual_batch_max_vertices
	procedural_water_visual_batch_near_cull_radius_chunks = _get_runtime_power_env_int_range("TOWN_STALL_PROCEDURAL_WATER_VISUAL_BATCH_NEAR_CULL_RADIUS", procedural_water_visual_batch_near_cull_radius_chunks, 0, 8)

func _runtime_power_input_active() -> bool:
	var actions := ["move_forward", "move_backward", "move_left", "move_right", "sprint", "jump"]
	for action in actions:
		if InputMap.has_action(action) and Input.is_action_pressed(action):
			return true
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		return true
	return false

func _get_runtime_power_view_forward() -> Vector3:
	var camera := get_viewport().get_camera_3d()
	if is_instance_valid(camera):
		return (-camera.global_transform.basis.z).normalized()
	if viewer and is_instance_valid(viewer):
		return (-viewer.global_transform.basis.z).normalized()
	return Vector3.ZERO

func _runtime_power_viewer_moved() -> bool:
	var viewer_pos := get_viewer_position()
	var first_position_sample := false
	var position_changed := false
	if _runtime_power_last_viewer_pos.x > 9.0e19:
		first_position_sample = true
		_runtime_power_last_viewer_pos = viewer_pos
	else:
		position_changed = viewer_pos.distance_squared_to(_runtime_power_last_viewer_pos) > runtime_power_position_epsilon * runtime_power_position_epsilon
		_runtime_power_last_viewer_pos = viewer_pos

	var view_forward := _get_runtime_power_view_forward()
	var first_orientation_sample := false
	var orientation_changed := false
	if view_forward != Vector3.ZERO:
		if _runtime_power_last_view_forward.x > 9.0e19:
			first_orientation_sample = true
		else:
			orientation_changed = view_forward.distance_squared_to(_runtime_power_last_view_forward) > runtime_power_orientation_epsilon * runtime_power_orientation_epsilon
		_runtime_power_last_view_forward = view_forward

	return first_position_sample or first_orientation_sample or position_changed or orientation_changed

func _runtime_power_terrain_busy() -> bool:
	return initial_load_phase \
		or _last_update_loads > 0 \
		or _last_update_unloads > 0 \
		or not pending_nodes.is_empty() \
		or _get_completed_generation_queue_count() > 0 \
		or _get_task_queue_count() > 0 \
		or _get_cpu_task_queue_count() > 0 \
		or not pending_terrain_collision_creates.is_empty() \
		or not _terrain_visual_batch_dirty.is_empty() \
		or not _terrain_visual_batch_builds_in_flight.is_empty() \
		or not _completed_terrain_visual_batch_builds.is_empty() \
		or not _water_visual_batch_dirty.is_empty()

func _runtime_power_foreground_terrain_busy(terrain_busy: bool) -> bool:
	if not terrain_busy:
		return false
	if initial_load_phase or active_chunks.is_empty() or not pending_spawn_zones.is_empty():
		return true
	var min_loaded_chunk_count := _get_min_loaded_stream_chunk_count()
	return min_loaded_chunk_count > 0 and active_chunks.size() < min_loaded_chunk_count

func _get_cached_runtime_power_node(group_name: String, fallback_name: String, cached_node: Node) -> Node:
	if cached_node and is_instance_valid(cached_node):
		return cached_node
	var node := get_tree().get_first_node_in_group(group_name)
	if not node:
		node = get_tree().root.find_child(fallback_name, true, false)
	return node

func _runtime_power_external_world_busy() -> bool:
	_cached_prefab_spawner = _get_cached_runtime_power_node("prefab_spawner", "PrefabSpawner", _cached_prefab_spawner)
	if _cached_prefab_spawner:
		if _cached_prefab_spawner.has_method("has_pending_spawn_jobs") and _cached_prefab_spawner.has_pending_spawn_jobs():
			return true
		if _cached_prefab_spawner.has_method("has_pending_world_map_baked_payload_jobs") and _cached_prefab_spawner.has_pending_world_map_baked_payload_jobs():
			return true

	_cached_building_manager = _get_cached_runtime_power_node("building_manager", "BuildingManager", _cached_building_manager)
	if _cached_building_manager:
		if _cached_building_manager.has_method("has_pending_building_work") and _cached_building_manager.has_pending_building_work():
			return true
		if _cached_building_manager.has_method("has_pending_visual_batch_work") and _cached_building_manager.has_pending_visual_batch_work():
			return true
		if _cached_building_manager.has_method("has_pending_world_map_baked_object_spawns") and _cached_building_manager.has_pending_world_map_baked_object_spawns():
			return true

	_cached_vegetation_manager = _get_cached_runtime_power_node("vegetation_manager", "VegetationManager", _cached_vegetation_manager)
	if _cached_vegetation_manager:
		if _cached_vegetation_manager.has_method("is_vegetation_ready") and not _cached_vegetation_manager.is_vegetation_ready():
			return true
		if _cached_vegetation_manager.has_method("get_pending_chunks_count") and int(_cached_vegetation_manager.get_pending_chunks_count()) > 0:
			return true

	return false

func _record_runtime_power_event(label: String, details: Dictionary = {}) -> void:
	if label.is_empty():
		return
	var event := {
		"label": label,
		"frame": int(Engine.get_process_frames()) if Engine.has_method("get_process_frames") else 0,
		"timestamp": Time.get_ticks_msec(),
		"epoch": Time.get_unix_time_from_system()
	}
	if not details.is_empty():
		event["details"] = details.duplicate(true)
	_runtime_power_recent_events.append(event)
	while _runtime_power_recent_events.size() > 32:
		_runtime_power_recent_events.pop_front()

func _apply_runtime_power_fps(mode: String, target_fps_value: int) -> void:
	var previous_mode := _runtime_power_mode
	_runtime_power_mode = mode
	_runtime_power_target_fps = target_fps_value
	if Engine.max_fps != target_fps_value:
		Engine.max_fps = target_fps_value
	if previous_mode != mode:
		_record_runtime_power_event("runtime_power_mode_changed", {
			"from": previous_mode,
			"to": mode,
			"target_fps": target_fps_value,
			"idle_seconds": _runtime_power_idle_seconds,
			"reason": _runtime_power_active_reason
		})
	_apply_runtime_power_viewport_scale(mode)
	if previous_mode != mode or _runtime_power_render_loop_suspended or mode == "deep_idle":
		_apply_runtime_power_render_loop_mode(mode)

func _get_runtime_power_viewport_scale() -> float:
	var viewport := get_viewport()
	_runtime_power_viewport_scale_supported = viewport != null and "scaling_3d_scale" in viewport
	if not _runtime_power_viewport_scale_supported:
		return 0.0
	_runtime_power_viewport_scale_current = float(viewport.scaling_3d_scale)
	return _runtime_power_viewport_scale_current

func _runtime_power_target_viewport_scale(mode: String) -> float:
	if mode == "deep_idle":
		return runtime_power_deep_idle_3d_scale
	if mode == "idle":
		return runtime_power_idle_3d_scale
	return runtime_power_active_3d_scale

func _apply_runtime_power_viewport_scale(mode: String) -> void:
	var viewport := get_viewport()
	_runtime_power_viewport_scale_supported = viewport != null and "scaling_3d_scale" in viewport
	if not _runtime_power_viewport_scale_supported:
		return

	if not _runtime_power_viewport_scale_captured:
		_runtime_power_viewport_scale_original = float(viewport.scaling_3d_scale)
		_runtime_power_viewport_scale_current = _runtime_power_viewport_scale_original
		_runtime_power_viewport_scale_captured = true

	if not runtime_power_viewport_scaling_enabled:
		_restore_runtime_power_viewport_scale(mode)
		return

	var target_scale := clampf(_runtime_power_target_viewport_scale(mode), 0.5, 1.0)
	if absf(float(viewport.scaling_3d_scale) - target_scale) <= 0.001:
		_runtime_power_viewport_scale_current = float(viewport.scaling_3d_scale)
		return

	viewport.scaling_3d_scale = target_scale
	_runtime_power_viewport_scale_current = float(viewport.scaling_3d_scale)
	_record_runtime_power_event("runtime_power_viewport_scale_changed", {
		"mode": mode,
		"scale": _runtime_power_viewport_scale_current,
		"idle_seconds": _runtime_power_idle_seconds
	})

func _restore_runtime_power_viewport_scale(reason: String) -> void:
	if not _runtime_power_viewport_scale_captured:
		return
	var viewport := get_viewport()
	if viewport == null or not ("scaling_3d_scale" in viewport):
		return
	if absf(float(viewport.scaling_3d_scale) - _runtime_power_viewport_scale_original) <= 0.001:
		_runtime_power_viewport_scale_current = float(viewport.scaling_3d_scale)
		return
	viewport.scaling_3d_scale = _runtime_power_viewport_scale_original
	_runtime_power_viewport_scale_current = float(viewport.scaling_3d_scale)
	_record_runtime_power_event("runtime_power_viewport_scale_restored", {
		"reason": reason,
		"scale": _runtime_power_viewport_scale_current
	})

func _get_runtime_power_render_loop_enabled() -> bool:
	if not RenderingServer.has_method("is_render_loop_enabled"):
		return true
	return bool(RenderingServer.call("is_render_loop_enabled"))

func _apply_runtime_power_render_loop_mode(mode: String) -> void:
	if not RenderingServer.has_method("set_render_loop_enabled"):
		_runtime_power_render_loop_suspended = false
		return

	var should_suspend := runtime_power_mode_enabled \
		and runtime_power_suspend_render_loop_in_deep_idle \
		and mode == "deep_idle"
	if should_suspend:
		if not _runtime_power_render_loop_restore_captured:
			_runtime_power_render_loop_restore_enabled = _get_runtime_power_render_loop_enabled()
			_runtime_power_render_loop_restore_captured = true
		if not _runtime_power_render_loop_suspended:
			RenderingServer.call("set_render_loop_enabled", false)
			_runtime_power_render_loop_suspended = true
			_record_runtime_power_event("runtime_power_render_loop_suspended", {
				"mode": mode,
				"target_fps": _runtime_power_target_fps,
				"idle_seconds": _runtime_power_idle_seconds
			})
		return

	if _runtime_power_render_loop_suspended:
		var restore_enabled := _runtime_power_render_loop_restore_enabled if _runtime_power_render_loop_restore_captured else true
		RenderingServer.call("set_render_loop_enabled", restore_enabled)
		_runtime_power_render_loop_suspended = false
		_record_runtime_power_event("runtime_power_render_loop_resumed", {
			"mode": mode,
			"restore_enabled": restore_enabled,
			"idle_seconds": _runtime_power_idle_seconds
		})

func _update_runtime_power_mode(delta: float) -> void:
	if not runtime_power_mode_enabled:
		_set_runtime_power_world_work_suspended(false, "runtime_power_disabled")
		_apply_runtime_power_viewport_scale("active")
		_apply_runtime_power_render_loop_mode("active")
		return

	var input_active := _runtime_power_input_active()
	var viewer_moved := _runtime_power_viewer_moved()
	var terrain_busy := _runtime_power_terrain_busy()
	var foreground_terrain_busy := _runtime_power_foreground_terrain_busy(terrain_busy)
	var external_world_busy := _runtime_power_external_world_busy()
	_runtime_power_viewer_moved_last = viewer_moved
	_runtime_power_terrain_busy_last = terrain_busy
	_runtime_power_foreground_terrain_busy_last = foreground_terrain_busy
	_runtime_power_external_world_busy_last = external_world_busy
	var active_now := input_active or viewer_moved or foreground_terrain_busy or external_world_busy
	if active_now:
		if input_active:
			_runtime_power_active_reason = "input"
		elif viewer_moved:
			_runtime_power_active_reason = "viewer_moved"
		elif foreground_terrain_busy:
			_runtime_power_active_reason = "terrain_foreground"
		elif external_world_busy:
			_runtime_power_active_reason = "external_world"
		else:
			_runtime_power_active_reason = "active"
		_runtime_power_idle_seconds = 0.0
		_runtime_power_active_grace_remaining_s = runtime_power_active_grace_s
	else:
		if _runtime_power_active_grace_remaining_s > 0.0:
			_runtime_power_active_reason = "active_grace"
			_runtime_power_active_grace_remaining_s = maxf(0.0, _runtime_power_active_grace_remaining_s - delta)
			_runtime_power_idle_seconds = 0.0
		else:
			_runtime_power_active_reason = "terrain_background_idle" if terrain_busy else "idle"
			_runtime_power_idle_seconds += delta

	if _runtime_power_idle_seconds >= runtime_power_deep_idle_enter_delay_s and not foreground_terrain_busy:
		_runtime_power_deep_idle_frame_count += 1
		_apply_runtime_power_fps("deep_idle", runtime_power_deep_idle_max_fps)
	elif _runtime_power_idle_seconds >= runtime_power_idle_enter_delay_s:
		_runtime_power_idle_frame_count += 1
		_apply_runtime_power_fps("idle", runtime_power_idle_max_fps)
	else:
		_runtime_power_active_frame_count += 1
		_apply_runtime_power_fps("active", runtime_power_active_max_fps)

	var suspend_world_work := runtime_power_suspend_background_world_work \
		and _runtime_power_idle_seconds >= runtime_power_idle_enter_delay_s \
		and not foreground_terrain_busy \
		and not external_world_busy
	var suspend_reason := _runtime_power_active_reason
	if terrain_busy and not foreground_terrain_busy:
		suspend_reason = "background_world_work_idle"
	elif not terrain_busy:
		suspend_reason = "world_idle"
	_set_runtime_power_world_work_suspended(suspend_world_work, suspend_reason)

func _get_viewer_chunk_coord() -> Vector3i:
	var p_pos := get_viewer_position()
	return Vector3i(
		int(floor(p_pos.x / CHUNK_STRIDE)),
		int(floor(p_pos.y / CHUNK_STRIDE)),
		int(floor(p_pos.z / CHUNK_STRIDE))
	)

func _chunk_disk_count(radius: int) -> int:
	if radius <= 0:
		return 0
	var radius_sq := radius * radius
	var count := 0
	for x in range(-radius, radius + 1):
		for z in range(-radius, radius + 1):
			if x * x + z * z <= radius_sq:
				count += 1
	return count

func _get_min_loaded_stream_chunk_count() -> int:
	if render_distance <= 0:
		return 0
	var render_target := _chunk_disk_count(render_distance)
	return maxi(initial_load_target_chunks, render_target)

func _terrain_stream_update_needed() -> bool:
	if initial_load_phase:
		_last_terrain_stream_update_gate_reason = "initial_load"
		return true
	if active_chunks.is_empty():
		_last_terrain_stream_update_gate_reason = "empty_world"
		return true
	var min_loaded_chunk_count := _get_min_loaded_stream_chunk_count()
	if min_loaded_chunk_count > 0 and active_chunks.size() < min_loaded_chunk_count:
		_last_terrain_stream_update_gate_reason = "below_stream_target"
		return true
	if _last_update_loads > 0 or _last_update_unloads > 0:
		_last_terrain_stream_update_gate_reason = "continuing_stream_burst"
		return true
	if not pending_spawn_zones.is_empty():
		_last_terrain_stream_update_gate_reason = "spawn_zone_pending"
		return true
	if _modification_coord_cache_dirty:
		_last_terrain_stream_update_gate_reason = "modification_cache_dirty"
		return true
	var center_chunk := _get_viewer_chunk_coord()
	if center_chunk != _last_terrain_stream_update_center_chunk:
		_last_terrain_stream_update_gate_reason = "viewer_chunk_changed"
		return true
	if render_distance != _last_terrain_stream_update_render_distance:
		_last_terrain_stream_update_gate_reason = "render_distance_changed"
		return true
	if loading_paused != _last_terrain_stream_update_loading_paused:
		_last_terrain_stream_update_gate_reason = "loading_pause_changed"
		return true
	_last_terrain_stream_update_gate_reason = "idle_same_chunk"
	return false

func _record_terrain_stream_update_key() -> void:
	_last_terrain_stream_update_center_chunk = _get_viewer_chunk_coord()
	_last_terrain_stream_update_render_distance = render_distance
	_last_terrain_stream_update_loading_paused = loading_paused

func _skip_terrain_stream_update() -> void:
	_terrain_stream_update_idle_skip_count += 1
	_last_update_backend = "idle_gate"
	_last_update_loads = 0
	_last_update_unloads = 0
	_last_update_duration_ms = 0.0

func is_world_work_suspended() -> bool:
	return _runtime_power_world_work_suspended

func _wake_suspended_background_workers() -> void:
	var gpu_wake_count := 0
	if mutex and semaphore:
		mutex.lock()
		gpu_wake_count = task_queue.size()
		mutex.unlock()
	for _gpu_wake_index in range(gpu_wake_count):
		semaphore.post()

	var cpu_wake_count := 0
	if cpu_mutex and cpu_semaphore:
		cpu_mutex.lock()
		cpu_wake_count = cpu_task_queue.size()
		cpu_mutex.unlock()
	for _cpu_wake_index in range(cpu_wake_count):
		cpu_semaphore.post()

func _set_runtime_power_world_work_suspended(suspended: bool, reason: String) -> void:
	var target_suspended := runtime_power_mode_enabled and runtime_power_suspend_background_world_work and suspended
	if _runtime_power_world_work_suspended == target_suspended:
		if target_suspended:
			_runtime_power_world_work_suspend_reason = reason
		return

	_runtime_power_world_work_suspended = target_suspended
	if target_suspended:
		_runtime_power_world_work_suspend_count += 1
		_runtime_power_world_work_suspend_reason = reason
		_record_runtime_power_event("runtime_power_world_work_suspended", {
			"reason": reason,
			"idle_seconds": _runtime_power_idle_seconds
		})
	else:
		_runtime_power_world_work_resume_count += 1
		_runtime_power_world_work_resume_reason = reason
		_record_runtime_power_event("runtime_power_world_work_resumed", {
			"reason": reason,
			"idle_seconds": _runtime_power_idle_seconds
		})
		_wake_suspended_background_workers()

func _record_runtime_power_world_work_suspended_frame() -> void:
	_runtime_power_world_work_suspended_frame_count += 1
	_skip_terrain_stream_update()
	_last_terrain_finalization_defer_reason = "runtime_power_world_work_suspended"
	_last_completed_generation_drain_count = 0
	_last_completed_generation_drain_ms = 0.0
	_last_pending_node_finalize_count = 0
	_last_pending_node_process_ms = 0.0
	_last_collision_proximity_update_ms = 0.0
	_last_collision_proximity_enable_count = 0
	_last_collision_proximity_disable_count = 0
	_last_collision_proximity_prewarm_queued = 0
	_last_terrain_collision_create_count = 0
	_last_terrain_collision_create_ms = 0.0
	_last_terrain_collision_create_skipped_far = 0
	_last_terrain_collision_create_stale = 0
	_last_terrain_collision_create_deferred_prewarm = 0
	_last_terrain_collision_candidate_checks = 0
	_last_retired_chunk_node_cleanup_count = 0
	_last_retired_chunk_node_cleanup_ms = 0.0
	_last_world_map_lod_update_ms = 0.0
	_last_world_map_lod_loads = 0
	_last_world_map_lod_unloads = 0
	_last_terrain_visual_batch_rebuild_count = 0
	_last_terrain_visual_batch_rebuild_ms = 0.0
	_last_terrain_visual_batch_cached_rebuild_count = 0
	_last_terrain_visual_batch_cached_rebuild_ms = 0.0
	_last_terrain_visual_batch_cached_rebuild_attempts = 0
	_last_terrain_visual_batch_async_queued_count = 0
	_last_terrain_visual_batch_streaming_async_queued_count = 0
	_last_terrain_visual_batch_async_apply_count = 0
	_last_terrain_visual_batch_async_apply_ms = 0.0
	_last_terrain_visual_batch_async_stale_count = 0
	_last_terrain_visual_batch_idle_polish = false

var _last_collision_center_chunk: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _last_collision_active_count: int = -1
var _terrain_collision_active_coords: Dictionary = {}
var _terrain_collision_space_attached_coords: Dictionary = {}
var _shared_terrain_collision_cluster_bodies: Dictionary = {}
var _shared_terrain_collision_cluster_shape_coords: Dictionary = {}
var _shared_terrain_collision_shape_indices: Dictionary = {}
var _shared_terrain_collision_shape_clusters: Dictionary = {}
var _shared_terrain_collision_shape_coords: Array[Vector3i] = []
var _shared_terrain_collision_space: RID = RID()
var _terrain_collision_body_cache: Dictionary = {}
var _terrain_collision_body_cache_order: Array[Vector3i] = []
var _last_collision_proximity_update_ms: float = 0.0
var _last_collision_proximity_enable_count: int = 0
var _last_collision_proximity_disable_count: int = 0
var _last_collision_proximity_prewarm_queued: int = 0
var _terrain_collision_body_cache_hits: int = 0
var _terrain_collision_body_cache_misses: int = 0
var _terrain_collision_body_cache_stores: int = 0
var _terrain_collision_body_cache_evictions: int = 0
var pending_terrain_collision_creates: Dictionary = {}
var _pending_terrain_collision_candidates: Array[Vector3i] = []
var _pending_terrain_collision_candidate_index: int = 0
var _pending_terrain_collision_candidates_dirty: bool = true
var _pending_terrain_collision_sort_center: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)
var _last_terrain_collision_create_ms: float = 0.0
var _last_terrain_collision_create_count: int = 0
var _last_terrain_collision_create_skipped_far: int = 0
var _last_terrain_collision_create_stale: int = 0
var _last_terrain_collision_create_deferred_prewarm: int = 0
var _last_terrain_collision_candidate_checks: int = 0
@export_range(1, 16, 1) var terrain_collision_create_budget_per_frame: int = 1
@export_range(1, 256, 1) var terrain_collision_candidate_checks_per_frame: int = 64

func _can_use_shared_terrain_collision_body(data) -> bool:
	return shared_terrain_collision_body_enabled and data != null and not (data.node_terrain is StaticBody3D) and not data.body_rid_terrain.is_valid()

func _has_terrain_collision_server_shape(data) -> bool:
	return data != null and (data.body_rid_terrain.is_valid() or int(data.terrain_collision_shared_shape_index) >= 0)

func _shared_terrain_collision_distance() -> int:
	return maxi(collision_distance, collision_prewarm_distance)

func _floor_div_i(value: int, divisor: int) -> int:
	return floori(float(value) / float(maxi(divisor, 1)))

func _shared_terrain_collision_cluster_coord(coord: Vector3i) -> Vector3i:
	var cluster_size := maxi(shared_terrain_collision_cluster_size, 1)
	return Vector3i(
		_floor_div_i(coord.x, cluster_size),
		coord.y,
		_floor_div_i(coord.z, cluster_size)
	)

func _ensure_shared_terrain_collision_body(world: World3D) -> bool:
	if not shared_terrain_collision_body_enabled or not world:
		return false
	if not is_in_group("terrain"):
		add_to_group("terrain")
	if _shared_terrain_collision_space != world.space:
		for cluster_variant in _shared_terrain_collision_cluster_bodies.keys():
			var body_rid: RID = _shared_terrain_collision_cluster_bodies[cluster_variant]
			if body_rid.is_valid():
				PhysicsServer3D.body_set_space(body_rid, world.space)
		_shared_terrain_collision_space = world.space
	return true

func _ensure_shared_terrain_collision_cluster_body(cluster_coord: Vector3i, world: World3D) -> RID:
	if not _ensure_shared_terrain_collision_body(world):
		return RID()
	var body_rid: RID = _shared_terrain_collision_cluster_bodies.get(cluster_coord, RID())
	if body_rid.is_valid():
		return body_rid
	body_rid = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body_rid, 1 | 512)
	PhysicsServer3D.body_set_collision_mask(body_rid, 1)
	PhysicsServer3D.body_attach_object_instance_id(body_rid, get_instance_id())
	PhysicsServer3D.body_set_space(body_rid, world.space)
	_shared_terrain_collision_cluster_bodies[cluster_coord] = body_rid
	_shared_terrain_collision_cluster_shape_coords[cluster_coord] = []
	_shared_terrain_collision_space = world.space
	return body_rid

func _add_shared_terrain_collision_shape_for_chunk(coord: Vector3i, data: ChunkData, world: World3D) -> bool:
	if data == null:
		return false
	if int(data.terrain_collision_shared_shape_index) >= 0:
		data.terrain_collision_enabled = true
		data.terrain_collision_body_in_space = true
		_mark_terrain_collision_active(coord, true)
		_mark_terrain_collision_space_attached(coord, true)
		_set_terrain_collision_ready(coord, data, true)
		return true
	if not data.node_terrain or not data.terrain_shape:
		return false
	var cluster_coord := _shared_terrain_collision_cluster_coord(coord)
	var body_rid := _ensure_shared_terrain_collision_cluster_body(cluster_coord, world)
	if not body_rid.is_valid():
		return false

	var chunk_pos := Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
	var cluster_coords: Array = _shared_terrain_collision_cluster_shape_coords.get(cluster_coord, [])
	var shape_index := cluster_coords.size()
	PhysicsServer3D.body_add_shape(
		body_rid,
		data.terrain_shape.get_rid(),
		Transform3D(Basis(), chunk_pos),
		false
	)
	_shared_terrain_collision_shape_indices[coord] = shape_index
	_shared_terrain_collision_shape_clusters[coord] = cluster_coord
	cluster_coords.append(coord)
	_shared_terrain_collision_cluster_shape_coords[cluster_coord] = cluster_coords
	_shared_terrain_collision_shape_coords.append(coord)
	data.terrain_collision_shared_shape_index = shape_index
	data.terrain_collision_enabled = true
	data.terrain_collision_body_in_space = true
	_mark_terrain_collision_active(coord, true)
	_mark_terrain_collision_space_attached(coord, true)
	_set_terrain_collision_ready(coord, data, true)
	return true

func _remove_shared_terrain_collision_shape_for_chunk(coord: Vector3i, data: ChunkData) -> void:
	if data == null:
		return
	var shape_index := int(data.terrain_collision_shared_shape_index)
	var cluster_coord: Vector3i = _shared_terrain_collision_shape_clusters.get(coord, _shared_terrain_collision_cluster_coord(coord))
	var cluster_coords: Array = _shared_terrain_collision_cluster_shape_coords.get(cluster_coord, [])
	if shape_index < 0 and _shared_terrain_collision_shape_indices.has(coord):
		shape_index = int(_shared_terrain_collision_shape_indices[coord])
	if shape_index >= 0 and shape_index < cluster_coords.size():
		var body_rid: RID = _shared_terrain_collision_cluster_bodies.get(cluster_coord, RID())
		if body_rid.is_valid():
			PhysicsServer3D.body_remove_shape(body_rid, shape_index)
		_shared_terrain_collision_shape_indices.erase(coord)
		_shared_terrain_collision_shape_clusters.erase(coord)
		cluster_coords.remove_at(shape_index)
		for i in range(shape_index, cluster_coords.size()):
			var moved_coord: Vector3i = cluster_coords[i]
			_shared_terrain_collision_shape_indices[moved_coord] = i
			var moved_data = active_chunks.get(moved_coord, null)
			if moved_data != null:
				moved_data.terrain_collision_shared_shape_index = i
		if cluster_coords.is_empty():
			if body_rid.is_valid():
				PhysicsServer3D.free_rid(body_rid)
			_shared_terrain_collision_cluster_bodies.erase(cluster_coord)
			_shared_terrain_collision_cluster_shape_coords.erase(cluster_coord)
		else:
			_shared_terrain_collision_cluster_shape_coords[cluster_coord] = cluster_coords
	else:
		_shared_terrain_collision_shape_indices.erase(coord)
		_shared_terrain_collision_shape_clusters.erase(coord)
	_shared_terrain_collision_shape_coords.erase(coord)
	data.terrain_collision_shared_shape_index = -1
	data.terrain_collision_enabled = false
	data.terrain_collision_body_in_space = false
	data.terrain_collision_ready = false
	data.terrain_collision_ready_reported = false
	_mark_terrain_collision_active(coord, false)
	_mark_terrain_collision_space_attached(coord, false)
	_set_terrain_collision_ready(coord, data, false)

func _clear_shared_terrain_collision_body() -> void:
	for cluster_variant in _shared_terrain_collision_cluster_bodies.keys():
		var body_rid: RID = _shared_terrain_collision_cluster_bodies[cluster_variant]
		if body_rid.is_valid():
			PhysicsServer3D.free_rid(body_rid)
	_shared_terrain_collision_cluster_bodies.clear()
	_shared_terrain_collision_cluster_shape_coords.clear()
	_shared_terrain_collision_shape_indices.clear()
	_shared_terrain_collision_shape_clusters.clear()
	_shared_terrain_collision_shape_coords.clear()
	_shared_terrain_collision_space = RID()

func update_collision_proximity():
	var update_start_us := Time.get_ticks_usec()
	_last_collision_proximity_enable_count = 0
	_last_collision_proximity_disable_count = 0
	_last_collision_proximity_prewarm_queued = 0

	var p_pos = get_viewer_position()
	var p_chunk_x = int(floor(p_pos.x / CHUNK_STRIDE))
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE))
	var p_chunk_z = int(floor(p_pos.z / CHUNK_STRIDE))
	var center_chunk = Vector3i(p_chunk_x, p_chunk_y, p_chunk_z)
	var active_count := active_chunks.size()
	if center_chunk == _last_collision_center_chunk and active_count == _last_collision_active_count:
		_last_collision_proximity_update_ms = 0.0
		return
	_last_collision_center_chunk = center_chunk
	_last_collision_active_count = active_count
	var world := get_world_3d()
	if not terrain_grid or not terrain_grid.has_method("get_collision_proximity_update"):
		_last_collision_proximity_update_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0
		return

	var proximity_update: Dictionary = terrain_grid.get_collision_proximity_update(
		center_chunk,
		collision_distance,
		collision_prewarm_distance,
		MIN_Y_LAYER,
		MAX_Y_LAYER,
		shared_terrain_collision_body_enabled
	)

	for coord_variant in proximity_update.get("enable", []):
		var coord: Vector3i = coord_variant
		var data = active_chunks.get(coord, null)
		if data == null:
			continue
		var was_enabled := bool(data.terrain_collision_enabled)
		_sync_terrain_collision_state(coord, data, true, world)
		if not was_enabled and bool(data.terrain_collision_enabled):
			_last_collision_proximity_enable_count += 1

	for coord_variant in proximity_update.get("disable", []):
		var coord: Vector3i = coord_variant
		if not active_chunks.has(coord):
			_terrain_collision_active_coords.erase(coord)
			if terrain_grid and terrain_grid.has_method("set_chunk_collision_active"):
				terrain_grid.set_chunk_collision_active(coord, false)
			continue
		var data = active_chunks[coord]
		if data == null:
			_terrain_collision_active_coords.erase(coord)
			if terrain_grid and terrain_grid.has_method("set_chunk_collision_active"):
				terrain_grid.set_chunk_collision_active(coord, false)
			continue
		var was_enabled := bool(data.terrain_collision_enabled)
		_sync_terrain_collision_state(coord, data, false, world)
		if was_enabled and not bool(data.terrain_collision_enabled):
			_last_collision_proximity_disable_count += 1

	if shared_terrain_collision_body_enabled:
		_last_collision_proximity_update_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0
		return
	for coord_variant in proximity_update.get("prewarm", []):
		var coord: Vector3i = coord_variant
		var data = active_chunks.get(coord, null)
		if data == null or _has_terrain_collision_server_shape(data) or not data.node_terrain or not data.terrain_shape:
			continue
		var was_pending := pending_terrain_collision_creates.has(coord)
		_queue_terrain_collision_create(coord)
		if not was_pending and pending_terrain_collision_creates.has(coord):
			_last_collision_proximity_prewarm_queued += 1

	_last_collision_proximity_update_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0

func _should_have_terrain_collision(coord: Vector3i, center_chunk: Vector3i, collision_distance_sq: int) -> bool:
	var dx = coord.x - center_chunk.x
	var dy = coord.y - center_chunk.y
	var dz = coord.z - center_chunk.z
	var dist_xz_sq = dx * dx + dz * dz
	return dist_xz_sq <= collision_distance_sq and abs(dy) <= 2

func _should_prewarm_terrain_collision(coord: Vector3i, center_chunk: Vector3i, prewarm_distance_sq: int) -> bool:
	var dx = coord.x - center_chunk.x
	var dy = coord.y - center_chunk.y
	var dz = coord.z - center_chunk.z
	var dist_xz_sq = dx * dx + dz * dz
	return dist_xz_sq <= prewarm_distance_sq and abs(dy) <= 2

func _queue_terrain_collision_create(coord: Vector3i) -> void:
	if pending_terrain_collision_creates.has(coord):
		return
	if active_chunks.has(coord):
		var data = active_chunks[coord]
		if _has_terrain_collision_server_shape(data):
			return
	pending_terrain_collision_creates[coord] = true
	_pending_terrain_collision_candidates_dirty = true

func _mark_terrain_collision_active(coord: Vector3i, active: bool) -> void:
	if active:
		_terrain_collision_active_coords[coord] = true
	else:
		_terrain_collision_active_coords.erase(coord)
	if terrain_grid and terrain_grid.has_method("set_chunk_collision_active"):
		terrain_grid.set_chunk_collision_active(coord, active)

func _mark_terrain_collision_space_attached(coord: Vector3i, attached: bool) -> void:
	if attached:
		_terrain_collision_space_attached_coords[coord] = true
	else:
		_terrain_collision_space_attached_coords.erase(coord)

func _can_cache_terrain_collision_body(coord: Vector3i, data: ChunkData) -> bool:
	if terrain_collision_body_cache_limit <= 0 or data == null:
		return false
	if not data.terrain_shape:
		return false
	if int(data.mod_version) != 0:
		return false
	if stored_modifications.has(coord):
		return false
	return true

func _drop_terrain_collision_body_cache_entry(coord: Vector3i) -> void:
	if not _terrain_collision_body_cache.has(coord):
		return
	var entry: Dictionary = _terrain_collision_body_cache[coord]
	var body_rid: RID = entry.get("body_rid", RID())
	if body_rid.is_valid():
		PhysicsServer3D.free_rid(body_rid)
	_terrain_collision_body_cache.erase(coord)
	_terrain_collision_body_cache_order.erase(coord)

func _remember_terrain_collision_body(coord: Vector3i, data: ChunkData, body_rid: RID) -> bool:
	if not body_rid.is_valid() or not _can_cache_terrain_collision_body(coord, data):
		return false

	_drop_terrain_collision_body_cache_entry(coord)
	_terrain_collision_body_cache[coord] = {
		"body_rid": body_rid,
		"shape": data.terrain_shape
	}
	_terrain_collision_body_cache_order.append(coord)
	_terrain_collision_body_cache_stores += 1

	while _terrain_collision_body_cache_order.size() > terrain_collision_body_cache_limit:
		var evict_coord: Vector3i = _terrain_collision_body_cache_order.pop_front()
		if _terrain_collision_body_cache.has(evict_coord):
			_drop_terrain_collision_body_cache_entry(evict_coord)
			_terrain_collision_body_cache_evictions += 1
	return true

func _take_cached_terrain_collision_body(coord: Vector3i) -> Dictionary:
	if stored_modifications.has(coord):
		_drop_terrain_collision_body_cache_entry(coord)
		_terrain_collision_body_cache_misses += 1
		return {}
	if not _terrain_collision_body_cache.has(coord):
		_terrain_collision_body_cache_misses += 1
		return {}

	var entry: Dictionary = _terrain_collision_body_cache[coord]
	_terrain_collision_body_cache.erase(coord)
	_terrain_collision_body_cache_order.erase(coord)
	var body_rid: RID = entry.get("body_rid", RID())
	var shape: Shape3D = entry.get("shape", null)
	if not body_rid.is_valid() or shape == null:
		if body_rid.is_valid():
			PhysicsServer3D.free_rid(body_rid)
		_terrain_collision_body_cache_misses += 1
		return {}

	_terrain_collision_body_cache_hits += 1
	return {
		"body_rid": body_rid,
		"shape": shape
	}

func _clear_terrain_collision_body_cache() -> void:
	for coord_variant in _terrain_collision_body_cache.keys():
		var coord: Vector3i = coord_variant
		var entry: Dictionary = _terrain_collision_body_cache[coord]
		var body_rid: RID = entry.get("body_rid", RID())
		if body_rid.is_valid():
			PhysicsServer3D.free_rid(body_rid)
	_terrain_collision_body_cache.clear()
	_terrain_collision_body_cache_order.clear()

func _set_terrain_collision_ready(coord: Vector3i, data, ready: bool) -> void:
	if data != null:
		var already_reported: bool = bool(data.terrain_collision_ready_reported)
		var previous_ready: bool = bool(data.terrain_collision_ready)
		data.terrain_collision_ready = ready
		if not terrain_grid or not terrain_grid.has_method("set_chunk_collision_ready"):
			data.terrain_collision_ready_reported = false
			return
		if already_reported and previous_ready == ready:
			return
		data.terrain_collision_ready_reported = true
	elif not terrain_grid or not terrain_grid.has_method("set_chunk_collision_ready"):
		return
	terrain_grid.set_chunk_collision_ready(coord, ready)

func _set_terrain_body_collision_enabled(coord: Vector3i, data, world, enabled: bool) -> void:
	if data != null and int(data.terrain_collision_shared_shape_index) >= 0:
		if enabled and world:
			_ensure_shared_terrain_collision_body(world)
			data.terrain_collision_enabled = true
			data.terrain_collision_body_in_space = _shared_terrain_collision_space == world.space
			_mark_terrain_collision_active(coord, true)
			_mark_terrain_collision_space_attached(coord, bool(data.terrain_collision_body_in_space))
			_set_terrain_collision_ready(coord, data, true)
		else:
			_remove_shared_terrain_collision_shape_for_chunk(coord, data)
		return
	if data == null or not data.body_rid_terrain.is_valid():
		_mark_terrain_collision_active(coord, false)
		_mark_terrain_collision_space_attached(coord, false)
		_set_terrain_collision_ready(coord, data, false)
		return
	if enabled and not world:
		_mark_terrain_collision_active(coord, false)
		_mark_terrain_collision_space_attached(coord, false)
		_set_terrain_collision_ready(coord, data, false)
		return
	var keep_disabled_in_space := keep_disabled_terrain_collision_bodies_in_space and world != null
	var should_attach_to_space := enabled or keep_disabled_in_space
	if bool(data.terrain_collision_enabled) == enabled and bool(data.terrain_collision_body_in_space) == should_attach_to_space:
		_mark_terrain_collision_active(coord, enabled)
		_mark_terrain_collision_space_attached(coord, should_attach_to_space)
		_set_terrain_collision_ready(coord, data, enabled)
		return

	if should_attach_to_space:
		PhysicsServer3D.body_set_space(data.body_rid_terrain, world.space)
		data.terrain_collision_body_in_space = true
	else:
		PhysicsServer3D.body_set_space(data.body_rid_terrain, RID())
		data.terrain_collision_body_in_space = false
	_mark_terrain_collision_space_attached(coord, bool(data.terrain_collision_body_in_space))

	if enabled:
		PhysicsServer3D.body_set_collision_layer(data.body_rid_terrain, 1 | 512)
		PhysicsServer3D.body_set_collision_mask(data.body_rid_terrain, 1)
	else:
		PhysicsServer3D.body_set_collision_layer(data.body_rid_terrain, 0)
		PhysicsServer3D.body_set_collision_mask(data.body_rid_terrain, 0)

	data.terrain_collision_enabled = enabled
	_mark_terrain_collision_active(coord, enabled)
	_set_terrain_collision_ready(coord, data, enabled)

func _sync_terrain_collision_state(coord: Vector3i, data, should_have_collision: bool, world = null) -> void:
	if data == null:
		return

	# Modified terrain chunks use a real node-based StaticBody3D, so we can
	# just toggle the shape there.
	if data.node_terrain is StaticBody3D:
		var ready := should_have_collision and data.collision_shape_terrain != null
		if data.collision_shape_terrain:
			var desired_disabled: bool = not should_have_collision
			if data.collision_shape_terrain.disabled != desired_disabled:
				data.collision_shape_terrain.disabled = desired_disabled
		data.terrain_collision_enabled = ready
		data.terrain_collision_body_in_space = false
		_mark_terrain_collision_active(coord, ready)
		_mark_terrain_collision_space_attached(coord, false)
		_set_terrain_collision_ready(coord, data, ready)
		pending_terrain_collision_creates.erase(coord)
		return

	# Initial-load terrain chunks use a PhysicsServer RID so we can keep the
	# visual mesh alive while only paying collision cost when the player is near.
	# Body creation is budgeted separately so entering town does not wake the
	# entire collision neighborhood in one frame.
	if should_have_collision:
		if int(data.terrain_collision_shared_shape_index) >= 0:
			_set_terrain_body_collision_enabled(coord, data, world, true)
			pending_terrain_collision_creates.erase(coord)
			return
		if data.body_rid_terrain.is_valid():
			_set_terrain_body_collision_enabled(coord, data, world, true)
			pending_terrain_collision_creates.erase(coord)
			return
		if not data.node_terrain or not data.terrain_shape:
			_set_terrain_collision_ready(coord, data, false)
			return

		_queue_terrain_collision_create(coord)
		_set_terrain_collision_ready(coord, data, false)
	else:
		if int(data.terrain_collision_shared_shape_index) >= 0:
			_remove_shared_terrain_collision_shape_for_chunk(coord, data)
			pending_terrain_collision_creates.erase(coord)
		elif data.body_rid_terrain.is_valid():
			_set_terrain_body_collision_enabled(coord, data, world, false)
			pending_terrain_collision_creates.erase(coord)
		else:
			data.terrain_collision_enabled = false
			data.terrain_collision_body_in_space = false
			data.terrain_collision_shared_shape_index = -1
			_mark_terrain_collision_active(coord, false)
			_mark_terrain_collision_space_attached(coord, false)
			_set_terrain_collision_ready(coord, data, false)

func _terrain_collision_sort_score(coord: Vector3i, center_chunk: Vector3i) -> int:
	var dx = coord.x - center_chunk.x
	var dy = coord.y - center_chunk.y
	var dz = coord.z - center_chunk.z
	return dx * dx + dz * dz + abs(dy) * 10

func process_pending_terrain_collision_creates():
	if pending_terrain_collision_creates.is_empty():
		_pending_terrain_collision_candidate_index = 0
		_pending_terrain_collision_candidates.clear()
		_pending_terrain_collision_candidates_dirty = true
		_last_terrain_collision_create_count = 0
		_last_terrain_collision_create_ms = 0.0
		_last_terrain_collision_create_skipped_far = 0
		_last_terrain_collision_create_stale = 0
		_last_terrain_collision_create_deferred_prewarm = 0
		_last_terrain_collision_candidate_checks = 0
		return

	var start_us := Time.get_ticks_usec()
	var p_pos = get_viewer_position()
	var center_chunk = Vector3i(
		int(floor(p_pos.x / CHUNK_STRIDE)),
		int(floor(p_pos.y / CHUNK_STRIDE)),
		int(floor(p_pos.z / CHUNK_STRIDE))
	)
	var collision_distance_sq := collision_distance * collision_distance
	var collision_prewarm_distance_sq := maxi(collision_prewarm_distance, collision_distance) * maxi(collision_prewarm_distance, collision_distance)
	var world = get_world_3d()
	if not world:
		_last_terrain_collision_create_count = 0
		_last_terrain_collision_create_ms = 0.0
		_last_terrain_collision_create_skipped_far = 0
		_last_terrain_collision_create_stale = 0
		_last_terrain_collision_create_deferred_prewarm = 0
		_last_terrain_collision_candidate_checks = 0
		return
	if _pending_terrain_collision_candidates_dirty or center_chunk != _pending_terrain_collision_sort_center or _pending_terrain_collision_candidate_index >= _pending_terrain_collision_candidates.size():
		_rebuild_pending_terrain_collision_candidates(center_chunk)

	var created := 0
	var skipped_far := 0
	var stale := 0
	var deferred_prewarm := 0
	var candidate_checks := 0
	var frame_budget_ms := 1000.0 / 60.0
	var can_create_prewarm := _last_frame_ms <= frame_budget_ms and _hot_frame_backoff_remaining_frames <= 0 and pending_nodes.is_empty() and _terrain_visual_batch_dirty.is_empty() and _water_visual_batch_dirty.is_empty()
	var create_budget := shared_terrain_collision_create_budget_per_frame if shared_terrain_collision_body_enabled else terrain_collision_create_budget_per_frame
	while _pending_terrain_collision_candidate_index < _pending_terrain_collision_candidates.size():
		if created >= create_budget:
			break
		if candidate_checks >= terrain_collision_candidate_checks_per_frame:
			break

		var coord: Vector3i = _pending_terrain_collision_candidates[_pending_terrain_collision_candidate_index]
		_pending_terrain_collision_candidate_index += 1
		candidate_checks += 1

		if not pending_terrain_collision_creates.has(coord):
			continue
		if not active_chunks.has(coord):
			pending_terrain_collision_creates.erase(coord)
			stale += 1
			continue

		var data = active_chunks[coord]
		if data == null:
			pending_terrain_collision_creates.erase(coord)
			stale += 1
			continue
		var should_have_collision := _should_have_terrain_collision(coord, center_chunk, collision_distance_sq)
		var should_prewarm_collision := _should_prewarm_terrain_collision(coord, center_chunk, collision_prewarm_distance_sq)
		if shared_terrain_collision_body_enabled:
			should_have_collision = should_prewarm_collision
		if _has_terrain_collision_server_shape(data):
			_set_terrain_body_collision_enabled(coord, data, world, should_have_collision)
			pending_terrain_collision_creates.erase(coord)
			continue
		if not data.node_terrain or not data.terrain_shape:
			_set_terrain_collision_ready(coord, data, false)
			pending_terrain_collision_creates.erase(coord)
			stale += 1
			continue
		if not should_have_collision and not should_prewarm_collision:
			_set_terrain_collision_ready(coord, data, false)
			pending_terrain_collision_creates.erase(coord)
			skipped_far += 1
			continue
		if not shared_terrain_collision_body_enabled and not should_have_collision and not can_create_prewarm:
			deferred_prewarm += 1
			continue

		_create_terrain_body_rid_for_chunk(coord, data, world, should_have_collision)
		pending_terrain_collision_creates.erase(coord)
		created += 1

	if pending_terrain_collision_creates.is_empty():
		_pending_terrain_collision_candidate_index = 0
		_pending_terrain_collision_candidates.clear()
		_pending_terrain_collision_candidates_dirty = true
	elif _pending_terrain_collision_candidate_index >= _pending_terrain_collision_candidates.size():
		_pending_terrain_collision_candidate_index = 0
		_pending_terrain_collision_candidates.clear()
		_pending_terrain_collision_candidates_dirty = true

	_last_terrain_collision_create_count = created
	_last_terrain_collision_create_skipped_far = skipped_far
	_last_terrain_collision_create_stale = stale
	_last_terrain_collision_create_deferred_prewarm = deferred_prewarm
	_last_terrain_collision_candidate_checks = candidate_checks
	_last_terrain_collision_create_ms = float(Time.get_ticks_usec() - start_us) / 1000.0


func _create_terrain_body_rid_for_chunk(coord: Vector3i, data: ChunkData, world: World3D, enable_body: bool = true) -> bool:
	if data == null:
		return false
	if int(data.terrain_collision_shared_shape_index) >= 0:
		if enable_body:
			_set_terrain_body_collision_enabled(coord, data, world, true)
		return true
	if data.body_rid_terrain.is_valid():
		return true
	if not data.node_terrain or not data.terrain_shape:
		return false
	if _can_use_shared_terrain_collision_body(data):
		var added := _add_shared_terrain_collision_shape_for_chunk(coord, data, world)
		if added:
			pending_terrain_collision_creates.erase(coord)
		return added

	var cached_body := _take_cached_terrain_collision_body(coord)
	var body_rid: RID = cached_body.get("body_rid", RID())
	if body_rid.is_valid():
		data.terrain_shape = cached_body.get("shape", data.terrain_shape)
	else:
		body_rid = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_add_shape(body_rid, data.terrain_shape.get_rid())
	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
	PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), chunk_pos))
	PhysicsServer3D.body_attach_object_instance_id(body_rid, data.node_terrain.get_instance_id())
	data.body_rid_terrain = body_rid
	data.terrain_collision_body_in_space = false
	data.terrain_collision_enabled = false
	_set_terrain_body_collision_enabled(coord, data, world, enable_body)
	pending_terrain_collision_creates.erase(coord)
	return true


func ensure_collision_ready_at(position: Vector3, radius: int = 1) -> bool:
	var world := get_world_3d()
	if not world:
		return false

	var center_x := int(floor(position.x / CHUNK_STRIDE))
	var center_z := int(floor(position.z / CHUNK_STRIDE))
	var center_ready := false
	var radius_clamped := maxi(radius, 0)
	for dx in range(-radius_clamped, radius_clamped + 1):
		for dz in range(-radius_clamped, radius_clamped + 1):
			var is_center_column := dx == 0 and dz == 0
			for y in range(MIN_Y_LAYER, 2):
				var coord := Vector3i(center_x + dx, y, center_z + dz)
				if not active_chunks.has(coord):
					continue
				var data: ChunkData = active_chunks[coord]
				if data == null:
					continue
				if data.node_terrain is StaticBody3D:
					var has_shape := data.collision_shape_terrain != null
					if has_shape and data.collision_shape_terrain.disabled:
						data.collision_shape_terrain.disabled = false
					data.terrain_collision_enabled = has_shape
					_mark_terrain_collision_active(coord, has_shape)
					_set_terrain_collision_ready(coord, data, has_shape)
					center_ready = center_ready or (is_center_column and has_shape)
					continue
				if int(data.terrain_collision_shared_shape_index) >= 0:
					_set_terrain_body_collision_enabled(coord, data, world, true)
					pending_terrain_collision_creates.erase(coord)
					center_ready = center_ready or is_center_column
					continue
				if data.body_rid_terrain.is_valid():
					_set_terrain_body_collision_enabled(coord, data, world, true)
					pending_terrain_collision_creates.erase(coord)
					center_ready = center_ready or is_center_column
					continue
				if _create_terrain_body_rid_for_chunk(coord, data, world):
					center_ready = center_ready or is_center_column

	return center_ready

# Process pending node creations - TIME-DISTRIBUTED to eliminate burst loading
func process_pending_nodes(force_spawn_zone_progress: bool = false):
	if pending_nodes.is_empty():
		_last_pending_node_finalize_count = 0
		return

	# Skip entirely if loading is paused due to low FPS
	if loading_paused and not force_spawn_zone_progress:
		_last_pending_node_finalize_count = 0
		return
	var process_start_us := Time.get_ticks_usec()
	var use_spawn_zone_budget := force_spawn_zone_progress and not initial_load_phase
	var budget_ms := spawn_zone_pending_node_finalize_budget_ms if use_spawn_zone_budget else maxf(adaptive_frame_budget_ms, 0.1)
	var max_items := pending_node_initial_finalize_max_per_frame if initial_load_phase else pending_node_finalize_max_per_frame
	if not initial_load_phase:
		max_items = mini(max_items, pending_node_runtime_render_commits_per_frame)
	if use_spawn_zone_budget:
		max_items = mini(max_items, spawn_zone_pending_node_finalize_max_per_frame)
	var processed := 0
	_last_pending_node_sort_skipped = false

	while processed < max_items:
		pending_nodes_mutex.lock()
		if pending_nodes.is_empty():
			if processed == 0:
				_last_pending_node_finalize_count = 0
			pending_nodes_mutex.unlock()
			break

		if processed == 0:
			if _should_resort_pending_nodes():
				var sort_start_us := Time.get_ticks_usec()
				_sort_pending_by_distance()
				_last_pending_node_sort_ms = float(Time.get_ticks_usec() - sort_start_us) / 1000.0
				_last_pending_node_sort_count = pending_nodes.size()
				_pending_nodes_sort_center = _get_pending_node_viewer_chunk()
				_pending_nodes_sort_size_at_last_sort = pending_nodes.size()
				pending_nodes_needs_sort = false
			elif pending_nodes_needs_sort:
				_last_pending_node_sort_skipped = true

		var item := _pop_next_pending_node_item()
		if pending_nodes.is_empty():
			_reset_pending_node_sort_state()
		pending_nodes_mutex.unlock()

		_finalize_chunk_creation(item)
		processed += 1
		last_finalization_time_ms = Time.get_ticks_msec()

		if processed >= max_items:
			break
		var elapsed_ms := float(Time.get_ticks_usec() - process_start_us) / 1000.0
		if elapsed_ms >= budget_ms:
			break

	_last_pending_node_finalize_count = processed
	_last_pending_node_process_ms = float(Time.get_ticks_usec() - process_start_us) / 1000.0


func _get_pending_node_viewer_chunk() -> Vector3i:
	var p_pos = get_viewer_position()
	return Vector3i(
		int(floor(p_pos.x / CHUNK_STRIDE)),
		int(floor(p_pos.y / CHUNK_STRIDE)),
		int(floor(p_pos.z / CHUNK_STRIDE))
	)


func _should_resort_pending_nodes() -> bool:
	if not pending_nodes_needs_sort:
		return false
	if pending_nodes.size() <= 1 or not viewer:
		return false

	var viewer_chunk := _get_pending_node_viewer_chunk()
	if _pending_nodes_sort_size_at_last_sort <= 0:
		return true
	if viewer_chunk != _pending_nodes_sort_center:
		return true

	return pending_nodes.size() >= _pending_nodes_sort_size_at_last_sort + pending_node_resort_growth_threshold


func _pop_next_pending_node_item() -> Dictionary:
	var pop_index := pending_nodes.size() - 1
	if pending_nodes_needs_sort and _pending_nodes_sort_size_at_last_sort > 0:
		_pending_nodes_sort_size_at_last_sort = mini(_pending_nodes_sort_size_at_last_sort, pending_nodes.size())
		pop_index = _pending_nodes_sort_size_at_last_sort - 1

	var item: Dictionary = pending_nodes[pop_index]
	pending_nodes.remove_at(pop_index)

	if _pending_nodes_sort_size_at_last_sort > 0:
		if pop_index < _pending_nodes_sort_size_at_last_sort:
			_pending_nodes_sort_size_at_last_sort -= 1
		_pending_nodes_sort_size_at_last_sort = mini(_pending_nodes_sort_size_at_last_sort, pending_nodes.size())

	return item


func _pending_node_type_priority(item: Dictionary) -> int:
	var item_type := str(item.get("type", ""))
	if item_type == "final_terrain":
		return 0
	if item_type == "final_water":
		return 1
	return 2


# Sort pending nodes by distance to player (closest first)
func _sort_pending_by_distance():
	if pending_nodes.size() <= 1 or not viewer:
		return
	var viewer_chunk := _get_pending_node_viewer_chunk()
	pending_nodes.sort_custom(func(a, b):
		var dist_a = (a.coord - viewer_chunk).length_squared()
		var dist_b = (b.coord - viewer_chunk).length_squared()
		if dist_a == dist_b:
			return _pending_node_type_priority(a) > _pending_node_type_priority(b)
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
	if data == null:
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

	if data.cpu_density_water.is_empty() and bool(data.generated_water_density_available):
		var sample_world_pos = chunk_origin + Vector3(ix, iy, iz)
		return _get_generated_water_density(sample_world_pos)

	if data.cpu_density_water.is_empty():
		return 1.0

	var index = ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)

	if index >= 0 and index < data.cpu_density_water.size():
		return data.cpu_density_water[index]

	return 1.0

func _shader_water_hash(p: Vector3) -> float:
	var h := Vector3(
		p.x * 0.3183099 + 0.1,
		p.y * 0.3183099 + 0.1,
		p.z * 0.3183099 + 0.1
	)
	h = Vector3(h.x - floor(h.x), h.y - floor(h.y), h.z - floor(h.z))
	h *= 17.0
	var value := h.x * h.y * h.z * (h.x + h.y + h.z)
	return value - floor(value)

func _shader_water_noise(p: Vector3) -> float:
	var i := Vector3(floor(p.x), floor(p.y), floor(p.z))
	var f := Vector3(p.x - i.x, p.y - i.y, p.z - i.z)
	var fi := Vector3(
		f.x * f.x * (3.0 - 2.0 * f.x),
		f.y * f.y * (3.0 - 2.0 * f.y),
		f.z * f.z * (3.0 - 2.0 * f.z)
	)

	var h000 := _shader_water_hash(i + Vector3(0, 0, 0))
	var h100 := _shader_water_hash(i + Vector3(1, 0, 0))
	var h010 := _shader_water_hash(i + Vector3(0, 1, 0))
	var h110 := _shader_water_hash(i + Vector3(1, 1, 0))
	var h001 := _shader_water_hash(i + Vector3(0, 0, 1))
	var h101 := _shader_water_hash(i + Vector3(1, 0, 1))
	var h011 := _shader_water_hash(i + Vector3(0, 1, 1))
	var h111 := _shader_water_hash(i + Vector3(1, 1, 1))

	return lerp(
		lerp(lerp(h000, h100, fi.x), lerp(h010, h110, fi.x), fi.y),
		lerp(lerp(h001, h101, fi.x), lerp(h011, h111, fi.x), fi.y),
		fi.z
	)

func _shader_smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func _get_generated_water_density(world_pos: Vector3) -> float:
	if world_map_active:
		if _world_map_water_image == null:
			return 1.0
		var water_width := _world_map_water_image.get_width()
		var water_height := _world_map_water_image.get_height()
		if water_width <= 0 or water_height <= 0 or world_map_size <= 0.0:
			return 1.0
		var px := clampi(int(world_pos.x + world_map_half), 0, water_width - 1)
		var pz := clampi(int(world_pos.z + world_map_half), 0, water_height - 1)
		var water_pixel := _world_map_water_image.get_pixel(px, pz)
		if water_pixel.r > 0.5019608:
			return world_pos.y - water_level
		return 100.0

	var mask_value := _shader_water_noise(Vector3(world_pos.x, 0.0, world_pos.z) * (noise_frequency * 0.1))
	mask_value = (mask_value * 2.0) - 1.0
	var water_mask := _shader_smoothstep(-0.3, 0.3, mask_value)
	var effective_height := water_level - (1.0 - water_mask) * 20.0
	return world_pos.y - effective_height

func _get_dry_water_density_bytes() -> PackedByteArray:
	if not _dry_water_density_bytes.is_empty():
		return _dry_water_density_bytes

	var values := PackedFloat32Array()
	values.resize(DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
	for i in range(values.size()):
		values[i] = 100.0
	_dry_water_density_bytes = values.to_byte_array()
	return _dry_water_density_bytes

func _get_generated_water_surface_height(global_x: float, global_z: float) -> float:
	if world_map_active:
		if _world_map_water_image == null:
			return -INF
		var water_width := _world_map_water_image.get_width()
		var water_height := _world_map_water_image.get_height()
		if water_width <= 0 or water_height <= 0 or world_map_size <= 0.0:
			return -INF
		var px := clampi(int(global_x + world_map_half), 0, water_width - 1)
		var pz := clampi(int(global_z + world_map_half), 0, water_height - 1)
		var water_pixel := _world_map_water_image.get_pixel(px, pz)
		return water_level if water_pixel.r > 0.5019608 else -INF

	var mask_value := _shader_water_noise(Vector3(global_x, 0.0, global_z) * (noise_frequency * 0.1))
	mask_value = (mask_value * 2.0) - 1.0
	var water_mask := _shader_smoothstep(-0.3, 0.3, mask_value)
	return water_level - (1.0 - water_mask) * 20.0

func _chunk_may_have_generated_water_surface(coord: Vector3i) -> bool:
	var chunk_min_y := float(coord.y * CHUNK_STRIDE)
	var chunk_max_y := chunk_min_y + float(CHUNK_SIZE)
	var min_surface_y := chunk_min_y - 0.5
	var max_surface_y := chunk_max_y + 0.5
	var chunk_origin_x := coord.x * CHUNK_STRIDE
	var chunk_origin_z := coord.z * CHUNK_STRIDE

	if world_map_active:
		if _world_map_water_image == null:
			return false
		for local_x in range(0, DENSITY_GRID_SIZE):
			var global_x := float(chunk_origin_x + local_x)
			for local_z in range(0, DENSITY_GRID_SIZE):
				var surface_y := _get_generated_water_surface_height(global_x, float(chunk_origin_z + local_z))
				if surface_y >= min_surface_y and surface_y <= max_surface_y:
					return true
		return false

	# Procedural water changes very slowly, so a small conservative grid is
	# enough to skip clearly dry chunks without doing a full density scan.
	const PROCEDURAL_WATER_SURFACE_SAMPLE_STEP := 4
	for local_x in range(0, DENSITY_GRID_SIZE, PROCEDURAL_WATER_SURFACE_SAMPLE_STEP):
		var global_x := float(chunk_origin_x + local_x)
		for local_z in range(0, DENSITY_GRID_SIZE, PROCEDURAL_WATER_SURFACE_SAMPLE_STEP):
			var surface_y := _get_generated_water_surface_height(global_x, float(chunk_origin_z + local_z))
			if surface_y >= min_surface_y and surface_y <= max_surface_y:
				return true
	return false

## Returns true when initial terrain chunks are visually ready (meshes created)
func is_initial_load_complete() -> bool:
	pending_nodes_mutex.lock()
	var nodes_empty = pending_nodes.is_empty()
	pending_nodes_mutex.unlock()
	if initial_load_phase or not nodes_empty:
		return false
	if viewer:
		if not ensure_collision_ready_at(viewer.global_position, 1):
			return false
	return true

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

func _get_world_map_pixel(global_x: float, global_z: float, image: Image) -> Vector2i:
	if image == null or world_map_size <= 0.0:
		return Vector2i(-1, -1)
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return Vector2i(-1, -1)

	var px_f := global_x + world_map_half
	var pz_f := global_z + world_map_half
	if px_f < 0.0 or pz_f < 0.0 or px_f >= world_map_size or pz_f >= world_map_size:
		return Vector2i(-1, -1)

	return Vector2i(
		clampi(int(floor(px_f)), 0, width - 1),
		clampi(int(floor(pz_f)), 0, height - 1)
	)

func _read_world_map_biome_pixel(pixel: Vector2i) -> int:
	if _world_map_biome_image == null or pixel.x < 0 or pixel.y < 0:
		return -1
	return int(round(_world_map_biome_image.get_pixel(pixel.x, pixel.y).r * 255.0))

func _is_world_map_road_pixel(pixel: Vector2i) -> bool:
	if _world_map_road_image == null or pixel.x < 0 or pixel.y < 0:
		return false
	var road_width := _world_map_road_image.get_width()
	var road_height := _world_map_road_image.get_height()
	if pixel.x >= road_width or pixel.y >= road_height:
		return false
	return _world_map_road_image.get_pixel(pixel.x, pixel.y).r > 0.5

func _sample_world_map_height(global_x: float, global_z: float) -> float:
	if _world_map_heightmap_data.is_empty() or _world_map_heightmap_width <= 0 or _world_map_heightmap_height <= 0:
		return -1000.0
	var px := clampf(global_x + world_map_half, 0.0, float(_world_map_heightmap_width - 1))
	var pz := clampf(global_z + world_map_half, 0.0, float(_world_map_heightmap_height - 1))
	var x0 := int(floor(px))
	var z0 := int(floor(pz))
	var x1 := mini(x0 + 1, _world_map_heightmap_width - 1)
	var z1 := mini(z0 + 1, _world_map_heightmap_height - 1)
	var tx := px - float(x0)
	var tz := pz - float(z0)

	var h00 := float(_world_map_heightmap_data[z0 * _world_map_heightmap_width + x0]) / 255.0
	var h10 := float(_world_map_heightmap_data[z0 * _world_map_heightmap_width + x1]) / 255.0
	var h01 := float(_world_map_heightmap_data[z1 * _world_map_heightmap_width + x0]) / 255.0
	var h11 := float(_world_map_heightmap_data[z1 * _world_map_heightmap_width + x1]) / 255.0
	var h0: float = lerpf(h00, h10, tx)
	var h1: float = lerpf(h01, h11, tx)
	return clampf(lerpf(h0, h1, tz) * world_map_max_height, 1.0, 28.0)

func get_surface_material_at(global_x: float, global_z: float, include_roads: bool = true) -> int:
	if not world_map_active:
		return -1
	var pixel := _get_world_map_pixel(global_x, global_z, _world_map_biome_image)
	if pixel.x < 0:
		return -1

	var biome_id := _read_world_map_biome_pixel(pixel)
	if include_roads and (_is_world_map_road_pixel(pixel) or biome_id == MaterialRegistry.ROAD):
		return MaterialRegistry.ROAD
	if biome_id == MaterialRegistry.ROAD:
		return MaterialRegistry.DEFAULT_SURFACE_MATERIAL
	return MaterialRegistry.normalize_world_map_biome_id(biome_id)

func _get_world_map_material_at(global_pos: Vector3) -> int:
	var surface_material := get_surface_material_at(global_pos.x, global_pos.z, true)
	if surface_material < 0:
		return -1

	var surface_height := _sample_world_map_height(global_pos.x, global_pos.z)
	if surface_height < -100.0:
		return surface_material

	var depth := surface_height - global_pos.y
	if depth > 10.0:
		return MaterialRegistry.STONE
	if surface_material == MaterialRegistry.ROAD and depth >= 2.0:
		return MaterialRegistry.GRASS
	return surface_material

## Get material ID at world position (reads from CPU-cached chunk data)
## Returns -1 if position is outside loaded chunks or no material data
func get_material_at(global_pos: Vector3) -> int:
	# Find Chunk (3D coordinates)
	var chunk_x = int(floor(global_pos.x / CHUNK_STRIDE))
	var chunk_y = int(floor(global_pos.y / CHUNK_STRIDE))
	var chunk_z = int(floor(global_pos.z / CHUNK_STRIDE))
	var coord = Vector3i(chunk_x, chunk_y, chunk_z)

	if not active_chunks.has(coord):
		if world_map_active:
			return _get_world_map_material_at(global_pos)
		return -1 # Chunk not loaded

	var data = active_chunks[coord]
	if data == null or data.cpu_material_terrain.is_empty():
		if world_map_active:
			return _get_world_map_material_at(global_pos)
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
	if _modification_coord_cache_dirty:
		_modification_coord_cache.clear()
		var seen: Dictionary = {}
		for coord_variant in _world_map_terrain_modifications.keys():
			var coord: Vector3i = coord_variant
			seen[coord] = true
			_modification_coord_cache.append(coord)
		for coord_variant in stored_modifications.keys():
			var coord: Vector3i = coord_variant
			if seen.has(coord):
				continue
			_modification_coord_cache.append(coord)
		_modification_coord_cache_dirty = false
	return _modification_coord_cache

func _mark_modification_coord_cache_dirty() -> void:
	_modification_coord_cache_dirty = true

func _append_stored_modification(coord: Vector3i, modification: Dictionary) -> int:
	_drop_terrain_collision_body_cache_entry(coord)
	stored_modifications_mutex.lock()
	if not stored_modifications.has(coord):
		stored_modifications[coord] = []
	var coord_mods: Array = stored_modifications[coord]
	coord_mods.append(modification)
	stored_modifications[coord] = coord_mods
	var stored_count := coord_mods.size()
	stored_modifications_mutex.unlock()
	_mark_modification_coord_cache_dirty()
	return stored_count

func _rebuild_pending_terrain_collision_candidates(center_chunk: Vector3i) -> void:
	_pending_terrain_collision_candidates.clear()
	_pending_terrain_collision_candidate_index = 0
	_pending_terrain_collision_sort_center = center_chunk
	for coord_variant in pending_terrain_collision_creates.keys():
		_pending_terrain_collision_candidates.append(coord_variant)
	_pending_terrain_collision_candidates.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return _terrain_collision_sort_score(a, center_chunk) < _terrain_collision_sort_score(b, center_chunk)
	)
	_pending_terrain_collision_candidates_dirty = false

func _get_modification_snapshot_for_chunk(coord: Vector3i) -> Dictionary:
	stored_modifications_mutex.lock()
	var runtime_mods: Array = stored_modifications.get(coord, []).duplicate()
	var stored_count: int = runtime_mods.size()
	stored_modifications_mutex.unlock()
	return {
		"mods": runtime_mods,
		"version": stored_count
	}

func _get_modifications_for_chunk(coord: Vector3i) -> Array:
	var mods_for_chunk: Array = []
	var snapshot := _get_modification_snapshot_for_chunk(coord)
	var runtime_mods: Array = snapshot.get("mods", [])
	if not runtime_mods.is_empty():
		mods_for_chunk.append_array(runtime_mods)
	return mods_for_chunk

func _get_stored_modification_count(coord: Vector3i) -> int:
	stored_modifications_mutex.lock()
	var stored_count := 0
	if stored_modifications.has(coord):
		var coord_mods: Array = stored_modifications[coord]
		stored_count = coord_mods.size()
	stored_modifications_mutex.unlock()
	return stored_count

func _get_stored_modifications_after(coord: Vector3i, after_version: int) -> Array:
	var mods_after: Array = []
	stored_modifications_mutex.lock()
	var coord_mods: Array = stored_modifications.get(coord, [])
	var start_index: int = clampi(after_version, 0, coord_mods.size())
	for i in range(start_index, coord_mods.size()):
		mods_after.append(coord_mods[i])
	stored_modifications_mutex.unlock()
	return mods_after

func _cache_world_map_terrain_modifications(raw_mods: Array) -> void:
	_world_map_terrain_modifications.clear()
	_world_map_excavation_masks.clear()
	_mark_modification_coord_cache_dirty()
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


func _get_world_map_excavation_buffer(coord: Vector3i, rd: RenderingDevice) -> RID:
	if _world_map_excavation_buffers.has(coord):
		var existing: RID = _world_map_excavation_buffers[coord]
		if existing.is_valid():
			return existing

	var mask: PackedByteArray = _world_map_excavation_masks.get(coord, PackedByteArray())
	if mask.size() != EXCAVATION_MASK_BYTE_COUNT:
		return _world_map_empty_excavation_buf

	if not rd:
		return _world_map_empty_excavation_buf

	var buffer := rd.storage_buffer_create(mask.size(), mask)
	_world_map_excavation_buffers[coord] = buffer
	return buffer

func _free_world_map_excavation_buffers(rd: RenderingDevice) -> void:
	for buffer_rid in _world_map_excavation_buffers.values():
		if buffer_rid.is_valid():
			rd.free_rid(buffer_rid)
	_world_map_excavation_buffers.clear()
	if _world_map_empty_excavation_buf.is_valid():
		rd.free_rid(_world_map_empty_excavation_buf)
		_world_map_empty_excavation_buf = RID()

func _scan_density_column_local(density: PackedFloat32Array, local_x: int, local_z: int) -> float:
	if density.size() < DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE:
		return -1000.0
	if local_x < 0 or local_x >= DENSITY_GRID_SIZE or local_z < 0 or local_z >= DENSITY_GRID_SIZE:
		return -1000.0

	var prev_density = 1.0
	var col_offset = local_x + (local_z * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
	var stride_y = DENSITY_GRID_SIZE

	for iy in range(DENSITY_GRID_SIZE - 1, -1, -1):
		var index = col_offset + (iy * stride_y)
		var density_value = density[index]

		if density_value < 0.0:
			if iy < DENSITY_GRID_SIZE - 1:
				var t = prev_density / (prev_density - density_value)
				return float(iy + 1) - t
			return float(iy)

		prev_density = density_value

	return -1000.0

func _build_height_map_from_density(density: PackedFloat32Array) -> PackedFloat32Array:
	if density.is_empty():
		return PackedFloat32Array()

	if terrain_grid and terrain_grid.has_method("get_chunk_height_map"):
		return terrain_grid.get_chunk_height_map(density, CHUNK_STRIDE, 1)

	var heights := PackedFloat32Array()
	heights.resize(CHUNK_STRIDE * CHUNK_STRIDE)
	var write_idx := 0
	for x in range(CHUNK_STRIDE):
		for z in range(CHUNK_STRIDE):
			heights[write_idx] = _scan_density_column_local(density, x, z)
			write_idx += 1
	return heights

func _sample_height_map_local(data, local_x: int, local_z: int) -> float:
	if data == null or data.cpu_height_map_terrain.is_empty():
		return -1000.0

	var map_size: int = int(data.cpu_height_map_size)
	if map_size <= 0:
		map_size = CHUNK_STRIDE
	if local_x < 0 or local_z < 0:
		return -1000.0
	if local_x >= map_size:
		local_x = map_size - 1
	if local_z >= map_size:
		local_z = map_size - 1

	var index: int = local_x * map_size + local_z
	if index < 0 or index >= data.cpu_height_map_terrain.size():
		return -1000.0
	return data.cpu_height_map_terrain[index]

func get_cached_chunk_height_map(coord: Vector2i, chunk_stride: int, step: int) -> PackedFloat32Array:
	var chunk_key = Vector3i(coord.x, 0, coord.y)
	if not active_chunks.has(chunk_key):
		return PackedFloat32Array()

	var data = active_chunks[chunk_key]
	if data == null:
		return PackedFloat32Array()

	if data.cpu_height_map_terrain.is_empty() and not data.cpu_density_terrain.is_empty():
		data.cpu_height_map_terrain = _build_height_map_from_density(data.cpu_density_terrain)
		data.cpu_height_map_size = CHUNK_STRIDE if not data.cpu_height_map_terrain.is_empty() else 0

	if data.cpu_height_map_terrain.is_empty():
		return PackedFloat32Array()

	var heights := PackedFloat32Array()
	var count := 0
	for _x in range(0, chunk_stride, step):
		count += 1
	heights.resize(count * count)

	var write_idx := 0
	var chunk_base_y = float(chunk_key.y * CHUNK_STRIDE)
	for x in range(0, chunk_stride, step):
		for z in range(0, chunk_stride, step):
			var local_height = _sample_height_map_local(data, x, z)
			heights[write_idx] = local_height + chunk_base_y if local_height > -100.0 else local_height
			write_idx += 1

	return heights

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
		if data == null:
			continue

		var chunk_base_y = chunk_y * CHUNK_STRIDE
		var cached_height = _sample_height_map_local(data, local_x, local_z)
		if cached_height > -100.0:
			return chunk_base_y + cached_height

		if data.cpu_density_terrain.is_empty():
			continue

		# Scan Y column from top to bottom within this chunk
		var density_height = _scan_density_column_local(data.cpu_density_terrain, local_x, local_z)
		if density_height > -100.0:
			var world_height = chunk_base_y + density_height
			if world_height > best_height:
				best_height = world_height
			# Found surface in this chunk, stop searching
			return best_height

	return best_height # Return -1000.0 if no terrain found

# Optimized height lookup that only checks a specific chunk (much faster for vegetation placement)
func get_chunk_surface_height(coord: Vector3i, local_x: int, local_z: int) -> float:
	if not active_chunks.has(coord):
		return -1000.0

	var data = active_chunks[coord]
	if data == null:
		return -1000.0

	var chunk_base_y = coord.y * CHUNK_STRIDE

	# Safety check for bounds
	if local_x < 0 or local_x >= DENSITY_GRID_SIZE or local_z < 0 or local_z >= DENSITY_GRID_SIZE:
		return -1000.0

	var cached_height = _sample_height_map_local(data, local_x, local_z)
	if cached_height > -100.0:
		return chunk_base_y + cached_height

	if data.cpu_density_terrain.is_empty():
		return -1000.0

	var density_height = _scan_density_column_local(data.cpu_density_terrain, local_x, local_z)
	if density_height > -100.0:
		return chunk_base_y + density_height

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
				var stored_mod_version := _append_stored_modification(coord, {
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
							var start_mod_version := _bump_chunk_layer_mod_version(data, layer, stored_mod_version)

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
						_register_active_chunk_with_grid(coord)
						_register_terrain_visual_batch_member(coord)
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
		for t in tasks_to_add:
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
				var stored_mod_version := _append_stored_modification(coord, {
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
							var start_mod_version := _bump_chunk_layer_mod_version(data, layer, stored_mod_version)
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
								"material_id": - 1,
								"start_mod_version": start_mod_version
							})
				else:
					active_chunks[coord] = null
					_register_active_chunk_with_grid(coord)
					_register_terrain_visual_batch_member(coord)
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
		for t in tasks_to_add:
			t["batch_id"] = modification_batch_id
			t["batch_count"] = batch_count
			priority_task_queue.append(t)
		mutex.unlock()

		for i in range(batch_count):
			semaphore.post()

func _exit_tree():
	if _shutdown_cleanup_started:
		return
	_shutdown_cleanup_started = true
	set_process(false)
	loading_paused = true
	_set_runtime_power_world_work_suspended(false, "exit_tree")
	_restore_runtime_power_viewport_scale("exit_tree")
	_apply_runtime_power_render_loop_mode("active")

	# CRITICAL: Clean up all GPU resources BEFORE terminating threads
	# This fixes 682 resource leaks (StorageBuffers, Meshes, Collision, Materials)

	# 1. Unload all active chunks (frees meshes, collision, GPU buffers)
	_clear_world_map_lod_chunks(true)
	_clear_terrain_visual_batches(true)
	_clear_terrain_visual_batch_mesh_cache()
	_clear_water_visual_batches(true)
	var coords_to_unload = active_chunks.keys()
	for coord in coords_to_unload:
		_unload_chunk(coord)
	_clear_terrain_collision_body_cache()
	_clear_shared_terrain_collision_body()
	_terrain_collision_active_coords.clear()

	# 2. Clear pending nodes queue (prevents creating nodes after cleanup)
	_queue_gpu_free_tasks(_drain_completed_generation_free_tasks())
	_queue_gpu_free_tasks(_drain_pending_finalization_free_tasks())

	# 3. Signal threads to exit
	mutex.lock()
	exit_thread = true
	_shutdown_cpu_workers_finished = false
	mutex.unlock()

	# Signal all CPU workers to exit
	for i in range(_cpu_worker_count):
		cpu_semaphore.post()

	# 5. Wait for CPU workers first. They can enqueue completed payloads that
	# still contain GPU RIDs, so the GPU thread must not free its local device
	# until this join is complete and those late queues have been drained.
	for i in range(cpu_threads.size()):
		var thread = cpu_threads[i]
		if thread:
			thread.wait_to_finish()
	cpu_threads.clear()

	_queue_gpu_free_tasks(_drain_cpu_task_free_tasks())
	_queue_gpu_free_tasks(_drain_completed_generation_free_tasks())
	_queue_gpu_free_tasks(_drain_pending_finalization_free_tasks())
	mutex.lock()
	_shutdown_cpu_workers_finished = true
	mutex.unlock()

	# Signal GPU thread to drain remaining free tasks, then exit.
	semaphore.post()

	# 6. Wait for GPU thread to finish (processes remaining "free" tasks)
	if compute_thread:
		compute_thread.wait_to_finish()
		compute_thread = null

	# Drop helper references and any leftover queued payloads now that workers are done.
	if terrain_grid and terrain_grid.has_method("clear"):
		terrain_grid.clear()
	terrain_grid = null
	_native_backends_ready = false
	_clear_gpu_task_queues(true)
	pending_spawn_zones.clear()
	pending_batches.clear()
	_pending_terrain_collision_candidates.clear()
	_pending_terrain_collision_candidate_index = 0
	_pending_terrain_collision_candidates_dirty = true
	active_chunks.clear()
	PrefabGeometry.clear_cache()



func update_chunks():
	if not _native_backends_ready or not terrain_grid or not is_instance_valid(terrain_grid):
		return
	_update_chunks_native()

func _register_active_chunk_with_grid(coord: Vector3i) -> void:
	if terrain_grid and is_instance_valid(terrain_grid) and terrain_grid.has_method("add_chunk"):
		terrain_grid.add_chunk(coord)

func update_chunk_unloads_only():
	if not _native_backends_ready or not terrain_grid or not is_instance_valid(terrain_grid):
		return

	var update_start_us := Time.get_ticks_usec()
	_last_update_backend = "native_unload_only"

	var p_pos = get_viewer_position()
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE))
	var is_above_ground = p_chunk_y >= 0
	var result = terrain_grid.update(p_pos, render_distance, is_above_ground, CHUNK_STRIDE, 0, terrain_unload_budget_per_frame)
	var unload_count := 0
	for coord in result["unload"]:
		unload_count += 1
		_unload_chunk(coord)
		terrain_grid.remove_chunk(coord)
	var fallback_unloads := _unload_grid_mismatch_chunks(int(floor(p_pos.x / CHUNK_STRIDE)), p_chunk_y, int(floor(p_pos.z / CHUNK_STRIDE)), terrain_unload_budget_per_frame)
	_last_update_loads = 0
	_last_update_unloads = unload_count + fallback_unloads
	_last_update_duration_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0

func _update_chunks_native():
	var update_start_us := Time.get_ticks_usec()
	_last_update_backend = "native"

	var p_pos = get_viewer_position()
	var p_chunk_x = int(floor(p_pos.x / CHUNK_STRIDE))
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE))
	var p_chunk_z = int(floor(p_pos.z / CHUNK_STRIDE))
	if loading_paused:
		var is_above_ground = p_chunk_y >= 0
		var paused_result = terrain_grid.update(p_pos, render_distance, is_above_ground, CHUNK_STRIDE, 0, terrain_unload_budget_per_frame)
		var paused_unloads := 0
		for coord in paused_result["unload"]:
			paused_unloads += 1
			_unload_chunk(coord)
			terrain_grid.remove_chunk(coord)
		var paused_fallback_unloads := _unload_grid_mismatch_chunks(p_chunk_x, p_chunk_y, p_chunk_z, terrain_unload_budget_per_frame)
		_last_update_loads = 0
		_last_update_unloads = paused_unloads + paused_fallback_unloads
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

	# 3. Process Loads
	var chunks_queued = 0
	for coord in result["load"]:
		if chunks_queued >= chunks_per_frame_limit:
			break

		# Safe check, though Grid should handle it
		if active_chunks.has(coord):
			continue

		_load_chunk(coord)
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
				chunks_queued += 1

	var fallback_unloads := _unload_grid_mismatch_chunks(p_chunk_x, p_chunk_y, p_chunk_z, terrain_unload_budget_per_frame)

	_last_update_loads = chunks_queued
	_last_update_unloads = unload_count + fallback_unloads
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

func _unload_grid_mismatch_chunks(center_x: int, center_y: int, center_z: int, budget: int) -> int:
	_last_fallback_unloads = 0
	_last_fallback_unload_ms = 0.0
	if budget <= 0:
		return 0
	if not terrain_grid or not is_instance_valid(terrain_grid) or not terrain_grid.has_method("get_active_chunk_count"):
		return 0

	var native_grid_active_count := int(terrain_grid.get_active_chunk_count())
	_last_native_grid_active_chunk_count = native_grid_active_count
	if active_chunks.size() <= native_grid_active_count + budget * 2:
		return 0

	var unload_start_us := Time.get_ticks_usec()
	var unloaded := _unload_out_of_range_chunks(center_x, center_y, center_z, budget)
	_last_fallback_unloads = unloaded
	if unloaded > 0:
		_last_fallback_unload_ms = float(Time.get_ticks_usec() - unload_start_us) / 1000.0
	return unloaded

func _load_chunk(coord: Vector3i):
	active_chunks[coord] = null
	_register_active_chunk_with_grid(coord)
	_register_terrain_visual_batch_member(coord)

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

func _append_chunk_gpu_free_tasks(data: ChunkData, tasks: Array[Dictionary]) -> void:
	if data.density_buffer_terrain.is_valid():
		tasks.append({"type": "free", "rid": data.density_buffer_terrain})
	if data.density_buffer_water.is_valid():
		tasks.append({"type": "free", "rid": data.density_buffer_water})
	if data.material_buffer_terrain.is_valid():
		tasks.append({"type": "free", "rid": data.material_buffer_terrain})
		data.material_buffer_terrain = RID()

func _free_chunk_body_rid(data: ChunkData, coord: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)) -> void:
	if int(data.terrain_collision_shared_shape_index) >= 0:
		_remove_shared_terrain_collision_shape_for_chunk(coord, data)
		return
	if not data.body_rid_terrain.is_valid():
		data.terrain_collision_enabled = false
		data.terrain_collision_body_in_space = false
		data.terrain_collision_shared_shape_index = -1
		data.terrain_collision_ready = false
		data.terrain_collision_ready_reported = false
		_mark_terrain_collision_active(coord, false)
		_mark_terrain_collision_space_attached(coord, false)
		return

	var body_rid := data.body_rid_terrain
	var world = get_world_3d()
	if world:
		PhysicsServer3D.body_set_space(body_rid, RID())
	data.terrain_collision_body_in_space = false
	PhysicsServer3D.body_set_collision_layer(body_rid, 0)
	PhysicsServer3D.body_set_collision_mask(body_rid, 0)
	if coord == Vector3i(2147483647, 2147483647, 2147483647) or not _remember_terrain_collision_body(coord, data, body_rid):
		PhysicsServer3D.free_rid(body_rid)
	data.body_rid_terrain = RID()
	data.terrain_collision_shared_shape_index = -1
	data.terrain_collision_enabled = false
	data.terrain_collision_ready = false
	data.terrain_collision_ready_reported = false
	_mark_terrain_collision_active(coord, false)
	_mark_terrain_collision_space_attached(coord, false)

func _unload_chunk(coord: Vector3i, queue_nodes: bool = true, emit_unloaded: bool = true):
	if not active_chunks.has(coord):
		return

	_remove_pending_generate_tasks_for_coord(coord)

	var data = active_chunks[coord]
	_unregister_terrain_visual_batch_member(coord)
	_unregister_water_visual_batch_member(coord)
	if data:
		_mark_terrain_visual_batch_dirty(coord, true)
		_mark_water_visual_batch_dirty(coord, true)
		_set_terrain_collision_ready(coord, data, false)
		pending_terrain_collision_creates.erase(coord)
		if queue_nodes:
			if data.node_terrain: data.node_terrain.queue_free()
			if data.node_water: data.node_water.queue_free()

		var tasks: Array[Dictionary] = []
		_free_chunk_body_rid(data, coord)
		_append_chunk_gpu_free_tasks(data, tasks)
		_queue_gpu_free_tasks(tasks)

	active_chunks.erase(coord)
	if emit_unloaded:
		chunk_unloaded.emit(coord)

## Atomic world reset: cancels all background work and clears active chunks
## Used during Save/Load to prevent "double rendering" and redundant processing
func clear_all_chunks(preserve_world_map_lod_initial_defer: bool = false):

	# 1. Clear background task queues immediately
	_clear_gpu_task_queues()
	_clear_world_map_lod_chunks(false, not preserve_world_map_lod_initial_defer)
	_clear_terrain_visual_batches()
	_clear_terrain_visual_batch_mesh_cache()
	_clear_water_visual_batches()
	_clear_terrain_collision_body_cache()
	_clear_shared_terrain_collision_body()
	_terrain_collision_active_coords.clear()
	_terrain_collision_space_attached_coords.clear()

	var cpu_cleanup_tasks := _drain_cpu_task_free_tasks()
	_queue_gpu_free_tasks(cpu_cleanup_tasks)

	# 2. Clear finalization queue
	_queue_gpu_free_tasks(_drain_completed_generation_free_tasks())
	_queue_gpu_free_tasks(_drain_pending_finalization_free_tasks())
	pending_terrain_collision_creates.clear()
	_pending_terrain_collision_candidates.clear()
	_pending_terrain_collision_candidate_index = 0
	_pending_terrain_collision_candidates_dirty = true
	_last_terrain_collision_create_count = 0
	_last_terrain_collision_create_ms = 0.0
	_last_terrain_collision_create_skipped_far = 0
	_last_terrain_collision_create_stale = 0
	_last_terrain_collision_candidate_checks = 0

	# 3. Wipe all active chunks (frees Meshes, RIDs, and Collision)
	# Working on a copy of keys because _unload_chunk modifies the dictionary
	var coords = active_chunks.keys()
	_reset_chunk_node_root()
	var vegetation_bulk_cleared := _clear_vegetation_runtime_chunks_for_world_reset()
	var gpu_free_tasks: Array[Dictionary] = []
	for coord in coords:
		var data: ChunkData = active_chunks.get(coord, null)
		if data:
			pending_terrain_collision_creates.erase(coord)
			_free_chunk_body_rid(data, coord)
			_append_chunk_gpu_free_tasks(data, gpu_free_tasks)
		if not vegetation_bulk_cleared:
			chunk_unloaded.emit(coord)
	_queue_gpu_free_tasks(gpu_free_tasks)
	_clear_terrain_collision_body_cache()
	_clear_shared_terrain_collision_body()
	_terrain_collision_active_coords.clear()
	_terrain_collision_space_attached_coords.clear()
	_terrain_visual_batch_members.clear()
	_water_visual_batch_members.clear()

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
	_last_terrain_stream_update_center_chunk = Vector3i(2147483647, 2147483647, 2147483647)
	_last_terrain_stream_update_render_distance = -1
	_terrain_stream_update_idle_skip_count = 0
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
			_mark_terrain_visual_batch_dirty(coord, true)
			_mark_water_visual_batch_dirty(coord, true)
			_set_terrain_collision_ready(coord, data, false)
			if data.node_terrain: data.node_terrain.queue_free()
			if data.node_water: data.node_water.queue_free()

			# Free Physics Body RID
			_free_chunk_body_rid(data, coord)

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

		_unregister_terrain_visual_batch_member(coord)
		_unregister_water_visual_batch_member(coord)
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
					_register_active_chunk_with_grid(coord)
					_register_terrain_visual_batch_member(coord)

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
				_register_active_chunk_with_grid(coord)
				_register_terrain_visual_batch_member(coord)
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
					_register_active_chunk_with_grid(coord)
					_register_terrain_visual_batch_member(coord)

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
		# Exploration pacing should only yield to priority work such as edits,
		# spawn-zone requests, or shutdown. Normal background generation waits.
		var has_pending_gpu_task = _has_pending_priority_gpu_tasks_or_exit()

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

	# Use the baked biome bytes already loaded with the world map.
	# The minimap only needs the byte values, so there is no need to spend
	# startup time recomputing them through a separate GPU pass.
	gpu_biome_map = PackedByteArray()
	if world_map_active and not _startup_world_map_data.is_empty():
		var startup_biomes_variant: Variant = _startup_world_map_data.get("biomes", null)
		if startup_biomes_variant is Image:
			gpu_biome_map = (startup_biomes_variant as Image).get_data()

	# === World Map Buffers (uploaded from editor PNGs) ===

	_world_map_buildings = []
	_world_map_water_image = null
	_world_map_terrain_modifications.clear()
	_world_map_excavation_masks.clear()
	_mark_modification_coord_cache_dirty()
	var world_map_setup_start_us := 0
	if world_map_active and world_definition_path != "":
		world_map_setup_start_us = Time.get_ticks_usec()
		var loaded: Dictionary = {}
		if not _startup_world_map_data.is_empty():
			loaded = _startup_world_map_data
			_startup_world_map_data = {}
			_last_world_map_load_profile = _startup_world_map_load_profile
		else:
			var world_map_load_profile: Dictionary = {}
			loaded = WorldMapData.load_world(world_definition_path, world_map_data_cache_enabled, false, world_map_load_profile, ["heightmap", "biomes", "roads", "water"])
			_last_world_map_load_profile = world_map_load_profile

		if loaded.has("heightmap") and loaded.has("biomes") and loaded.has("roads"):
			var h_bytes: PackedByteArray = _world_map_heightmap_data
			var h_width := _world_map_heightmap_width
			var h_height := _world_map_heightmap_height
			if h_bytes.is_empty() or h_width <= 0 or h_height <= 0:
				var hmap: Image = loaded.heightmap
				h_bytes = hmap.get_data()
				h_width = hmap.get_width()
				h_height = hmap.get_height()
				_world_map_heightmap_data = h_bytes
				_world_map_heightmap_width = h_width
				_world_map_heightmap_height = h_height
			var bmap: Image = loaded.biomes
			var rmap: Image = loaded.roads
			_world_map_biome_image = bmap
			_world_map_road_image = rmap
			gpu_biome_map = bmap.get_data()

			# Upload raw bytes as storage buffers
			var b_bytes = bmap.get_data()
			var r_bytes = rmap.get_data()

			# Pad to 4-byte alignment for uint packing
			if h_bytes.size() % 4 != 0:
				h_bytes = h_bytes.duplicate()
			while h_bytes.size() % 4 != 0: h_bytes.append(0)
			while b_bytes.size() % 4 != 0: b_bytes.append(0)
			while r_bytes.size() % 4 != 0: r_bytes.append(0)

			_world_map_heightmap_buf = rd.storage_buffer_create(h_bytes.size(), h_bytes)
			_world_map_biome_buf = rd.storage_buffer_create(b_bytes.size(), b_bytes)
			_world_map_road_buf = rd.storage_buffer_create(r_bytes.size(), r_bytes)

			# Upload water map if available
			if loaded.has("water"):
				var wmap: Image = loaded.water
				_world_map_water_image = wmap
				var w_bytes = wmap.get_data()
				while w_bytes.size() % 4 != 0: w_bytes.append(0)
				_world_map_water_buf = rd.storage_buffer_create(w_bytes.size(), w_bytes)

			# Load baked buildings and terrain edits
			_world_map_buildings = []
			_world_map_terrain_modifications.clear()
			_mark_modification_coord_cache_dirty()
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
	const MAX_IN_FLIGHT = 1 # Keep gameplay frames smooth by avoiding multi-chunk GPU sync spikes.
	var output_bytes_size = MAX_TRIANGLES * 3 * LEGACY_VERTEX_FLOATS * 4
	var output_index_bytes_size = MAX_TRIANGLES * 3 * 4
	var buffer_slots: Array[Dictionary] = []
	for _slot in range(MAX_IN_FLIGHT):
		var counter_data_t = PackedByteArray()
		counter_data_t.resize(12)
		counter_data_t.encode_u32(0, 0)
		counter_data_t.encode_u32(4, 0)
		counter_data_t.encode_u32(8, 0)
		var counter_data_w = PackedByteArray()
		counter_data_w.resize(12)
		counter_data_w.encode_u32(0, 0)
		counter_data_w.encode_u32(4, 0)
		counter_data_w.encode_u32(8, 0)
		buffer_slots.append({
			"vertex_buffer_terrain": rd.storage_buffer_create(output_bytes_size),
			"counter_buffer_terrain": rd.storage_buffer_create(12, counter_data_t),
			"index_buffer_terrain": rd.storage_buffer_create(output_index_bytes_size),
			"vertex_buffer_water": rd.storage_buffer_create(output_bytes_size),
			"counter_buffer_water": rd.storage_buffer_create(12, counter_data_w),
			"index_buffer_water": rd.storage_buffer_create(output_index_bytes_size)
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
			mutex.lock()
			var should_exit = exit_thread
			var cpu_workers_finished := _shutdown_cpu_workers_finished
			mutex.unlock()
			# Only complete in-flight when no tasks pending
			_flush_generation_batch(rd, in_flight, sid_mesh, pipe_mesh, buffer_slots)
			if should_exit and not cpu_workers_finished:
				OS.delay_msec(10)
				continue
			if should_exit:
				break
			if _runtime_power_world_work_suspended:
				_interruptible_delay(50)
			continue

		# 2. Handle task types
		if task.type == "modify":
			# HIGHEST PRIORITY: Process modifications immediately, sync all pending work first
			_flush_generation_batch(rd, in_flight, sid_mesh, pipe_mesh, buffer_slots)
			process_modify(rd, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, buffer_slots[0]["vertex_buffer_terrain"], buffer_slots[0]["counter_buffer_terrain"], buffer_slots[0]["index_buffer_terrain"], modify_mesh_builder)
		elif task.type == "generate":
			var task_has_stored_mods := _get_stored_modification_count(task.coord) > 0
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
		elif task.type == "free_many":
			# Keep batched resource frees ordered after any pending GPU work.
			_flush_generation_batch(rd, in_flight, sid_mesh, pipe_mesh, buffer_slots)
			for rid_variant in task.get("rids", []):
				var rid: RID = rid_variant
				if rid.is_valid():
					rd.free_rid(rid)

	# Cleanup
	_free_gpu_cleanup_tasks_now(rd, _drain_cpu_task_free_tasks())
	_free_gpu_cleanup_tasks_now(rd, _drain_completed_generation_free_tasks())
	_free_gpu_cleanup_tasks_now(rd, _drain_pending_finalization_free_tasks())
	for slot in buffer_slots:
		rd.free_rid(slot["vertex_buffer_terrain"])
		rd.free_rid(slot["counter_buffer_terrain"])
		rd.free_rid(slot["index_buffer_terrain"])
		rd.free_rid(slot["vertex_buffer_water"])
		rd.free_rid(slot["counter_buffer_water"])
		rd.free_rid(slot["index_buffer_water"])
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

	var batch_start_us := Time.get_ticks_usec()
	var batch_count := in_flight.size()
	var needs_submit := false
	for flight_data in in_flight:
		if bool(flight_data.get("needs_submit", true)):
			needs_submit = true
			break

	var generation_sync_start_us := Time.get_ticks_usec()
	if needs_submit:
		rd.submit()
		rd.sync()
	var generation_sync_ms := float(Time.get_ticks_usec() - generation_sync_start_us) / 1000.0 if needs_submit else 0.0

	var mesh_readbacks: Array[Dictionary] = []
	var synced_mesh_readbacks: Array[Dictionary] = []
	var meshing_dispatch_start_us := Time.get_ticks_usec()
	for flight_data in in_flight:
		var slot_index := int(flight_data.get("buffer_slot", 0))
		if slot_index < 0 or slot_index >= buffer_slots.size():
			slot_index = 0
		var slot: Dictionary = buffer_slots[slot_index]
		var mesh_readback: Dictionary = _dispatch_chunk_meshing(
			rd,
			flight_data,
			sid_mesh,
			pipe_mesh,
			slot["vertex_buffer_terrain"],
			slot["counter_buffer_terrain"],
			slot["index_buffer_terrain"],
			slot["vertex_buffer_water"],
			slot["counter_buffer_water"],
			slot["index_buffer_water"]
		)
		if bool(mesh_readback.get("already_synced", false)):
			synced_mesh_readbacks.append(mesh_readback)
		else:
			mesh_readbacks.append(mesh_readback)
	var meshing_dispatch_ms := float(Time.get_ticks_usec() - meshing_dispatch_start_us) / 1000.0

	var meshing_sync_ms := 0.0
	var mesh_readback_ms := 0.0
	var mesh_readback_count := 0
	var terrain_vertex_count := 0
	var water_vertex_count := 0
	var mesh_slice_count := 0
	var mesh_slice_max_sync_ms := 0.0
	for readback in synced_mesh_readbacks:
		meshing_sync_ms += float(readback.get("mesh_sync_ms", 0.0))
		mesh_readback_ms += float(readback.get("mesh_readback_ms", 0.0))
		mesh_slice_count += int(readback.get("mesh_slice_count", 0))
		mesh_slice_max_sync_ms = maxf(mesh_slice_max_sync_ms, float(readback.get("mesh_slice_max_sync_ms", 0.0)))
		var readback_summary: Dictionary = _complete_chunk_readback(rd, readback)
		mesh_readback_count += 1
		terrain_vertex_count += int(readback_summary.get("terrain_vertex_count", 0))
		water_vertex_count += int(readback_summary.get("water_vertex_count", 0))
	if not mesh_readbacks.is_empty():
		var needs_mesh_submit := false
		for readback in mesh_readbacks:
			if not bool(readback.get("native_cpu_meshing", false)):
				needs_mesh_submit = true
				break
		if needs_mesh_submit:
			var meshing_sync_start_us := Time.get_ticks_usec()
			rd.submit()
			rd.sync()
			meshing_sync_ms = float(Time.get_ticks_usec() - meshing_sync_start_us) / 1000.0
		var mesh_readback_start_us := Time.get_ticks_usec()
		for readback in mesh_readbacks:
			var readback_summary: Dictionary = _complete_chunk_readback(rd, readback)
			mesh_readback_count += 1
			terrain_vertex_count += int(readback_summary.get("terrain_vertex_count", 0))
			water_vertex_count += int(readback_summary.get("water_vertex_count", 0))
		mesh_readback_ms = float(Time.get_ticks_usec() - mesh_readback_start_us) / 1000.0

	_last_gpu_generation_batch_ms = float(Time.get_ticks_usec() - batch_start_us) / 1000.0
	_last_gpu_generation_batch_chunk_count = batch_count
	_last_gpu_generation_sync_ms = generation_sync_ms
	_last_gpu_meshing_dispatch_ms = meshing_dispatch_ms
	_last_gpu_meshing_sync_ms = meshing_sync_ms
	_last_gpu_mesh_readback_ms = mesh_readback_ms
	_last_gpu_mesh_readback_chunk_count = mesh_readback_count
	_last_gpu_mesh_readback_terrain_vertices = terrain_vertex_count
	_last_gpu_mesh_readback_water_vertices = water_vertex_count
	_last_gpu_mesh_slice_count = mesh_slice_count
	_last_gpu_mesh_slice_max_sync_ms = mesh_slice_max_sync_ms
	_last_gpu_generation_batch_event_id += 1

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
	var dispatch_start_us := Time.get_ticks_usec()
	var chunk_pos = task.pos
	var coord = task.coord
	var density_bytes = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4
	var material_bytes = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4 # uint per voxel

	var modification_snapshot := _get_modification_snapshot_for_chunk(coord)
	var mods_for_chunk: Array = modification_snapshot.get("mods", [])
	var stored_mod_version := int(modification_snapshot.get("version", 0))
	var needs_material_readback := false
	var needs_terrain_density_readback := false
	var needs_water_density_readback := false
	var water_surface_possible := _chunk_may_have_generated_water_surface(coord)
	for mod in mods_for_chunk:
		if int(mod.get("material_id", -1)) >= 0:
			needs_material_readback = true
		var mod_layer := int(mod.get("layer", 0))
		if mod_layer == 0:
			needs_terrain_density_readback = true
		else:
			needs_water_density_readback = true
			water_surface_possible = true

	# Create density and material buffers (will persist until readback)
	var dens_buf_terrain = rd.storage_buffer_create(density_bytes)
	# The surface test is conservative and already gates water meshing below, so
	# dry generated chunks do not need a water-density compute dispatch either.
	var skip_dry_water_density_dispatch := terrain_skip_dry_water_density_dispatch and not water_surface_possible
	var dens_buf_water = rd.storage_buffer_create(density_bytes, _get_dry_water_density_bytes()) if skip_dry_water_density_dispatch else rd.storage_buffer_create(density_bytes)
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
	u_excavation_t.add_id(_get_world_map_excavation_buffer(coord, rd))

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
	var set_gen_w = RID()
	if not skip_dry_water_density_dispatch:
		var u_density_w = RDUniform.new()
		u_density_w.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u_density_w.binding = 0
		u_density_w.add_id(dens_buf_water)

		set_gen_w = rd.uniform_set_create([u_density_w], sid_gen_water, 0)
		list = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipe_gen_water)
		rd.compute_list_bind_uniform_set(list, set_gen_w, 0)
		rd.compute_list_bind_uniform_set(list, _world_map_water_set1, 1)
		var use_wm_w = 1.0 if world_map_active else 0.0
		var push_data_w = PackedFloat32Array([chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0, noise_frequency, water_level, use_wm_w, world_map_size, world_map_half, 0.0, 0.0, 0.0])
		rd.compute_list_set_push_constant(list, push_data_w.to_byte_array(), push_data_w.size() * 4)
		rd.compute_list_dispatch(list, 9, 9, 9)
		rd.compute_list_end()
		_last_gpu_water_density_dispatched = true
	else:
		_last_gpu_water_density_dispatched = false
		_gpu_water_density_skipped_count += 1
		_last_gpu_water_density_skipped_coord = coord

	# Apply runtime terrain edits only.
	# Baked world-map excavation is injected directly into gen_density.glsl via _world_map_excavation_buffers.
	var modification_sync_ms := 0.0

	if mods_for_chunk.size() > 0:
		# Debug: show when mods are applied to underground chunks
		# Need to sync before modifications since they read/write density
		var modification_sync_start_us := Time.get_ticks_usec()
		rd.submit()
		rd.sync()
		modification_sync_ms += float(Time.get_ticks_usec() - modification_sync_start_us) / 1000.0
		for mod in mods_for_chunk:
			var mod_layer := int(mod.get("layer", 0))
			var target_buffer = dens_buf_terrain if mod_layer == 0 else dens_buf_water
			_apply_modification_to_buffer(rd, sid_mod, pipe_mod, target_buffer, mat_buf_terrain, chunk_pos, mod)

	# Free uniform sets
	if set_gen_t.is_valid(): rd.free_rid(set_gen_t)
	if set_gen_w.is_valid(): rd.free_rid(set_gen_w)

	# Return in-flight data for later readback
	var flight_data := {
		"coord": coord,
		"chunk_pos": chunk_pos,
		"dens_buf_terrain": dens_buf_terrain,
		"dens_buf_water": dens_buf_water,
		"mat_buf_terrain": mat_buf_terrain,
		"needs_material_readback": needs_material_readback,
		"needs_terrain_density_readback": needs_terrain_density_readback,
		"needs_water_density_readback": needs_water_density_readback,
		"water_surface_possible": water_surface_possible,
		"stored_mod_version": stored_mod_version,
		"needs_submit": mods_for_chunk.is_empty()
	}
	_last_gpu_generation_dispatch_ms = float(Time.get_ticks_usec() - dispatch_start_us) / 1000.0
	_last_gpu_generation_dispatch_coord = coord
	_last_gpu_generation_mod_sync_ms = modification_sync_ms
	return flight_data

# Dispatch terrain and water meshing without syncing so the whole chunk batch can complete together.
func _dispatch_chunk_meshing(rd: RenderingDevice, flight_data: Dictionary, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, index_buffer_terrain, vertex_buffer_water, counter_buffer_water, index_buffer_water) -> Dictionary:
	var chunk_pos = flight_data.chunk_pos
	var dens_buf_terrain = flight_data.dens_buf_terrain
	var dens_buf_water = flight_data.dens_buf_water
	var mat_buf_terrain = flight_data.mat_buf_terrain
	var water_surface_possible := bool(flight_data.get("water_surface_possible", true))
	var skip_water_mesh := not water_surface_possible

	if terrain_native_cpu_meshing_enabled:
		return {
			"flight_data": flight_data,
			"skip_water_mesh": skip_water_mesh,
			"native_cpu_meshing": true
		}

	if terrain_gpu_separate_water_meshing and not skip_water_mesh and terrain_gpu_mesh_slices_per_chunk <= 1:
		var terrain_mesh: Dictionary = run_gpu_meshing_immediate_readback(rd, sid_mesh, pipe_mesh, dens_buf_terrain, mat_buf_terrain, chunk_pos, vertex_buffer_terrain, counter_buffer_terrain, index_buffer_terrain)
		if terrain_gpu_mesh_slice_delay_ms > 0:
			OS.delay_msec(terrain_gpu_mesh_slice_delay_ms)
		var water_mesh: Dictionary = run_gpu_meshing_immediate_readback(rd, sid_mesh, pipe_mesh, dens_buf_water, mat_buf_terrain, chunk_pos, vertex_buffer_water, counter_buffer_water, index_buffer_water)
		return {
			"flight_data": flight_data,
			"skip_water_mesh": skip_water_mesh,
			"already_synced": true,
			"mesh_data_terrain": terrain_mesh.get("mesh_data", {}),
			"mesh_data_water": water_mesh.get("mesh_data", {}),
			"mesh_sync_ms": float(terrain_mesh.get("sync_ms", 0.0)) + float(water_mesh.get("sync_ms", 0.0)),
			"mesh_readback_ms": float(terrain_mesh.get("readback_ms", 0.0)) + float(water_mesh.get("readback_ms", 0.0)),
			"mesh_slice_count": 2,
			"mesh_slice_max_sync_ms": maxf(float(terrain_mesh.get("sync_ms", 0.0)), float(water_mesh.get("sync_ms", 0.0)))
		}

	if terrain_gpu_mesh_slices_per_chunk > 1:
		var terrain_slices: Dictionary = run_gpu_meshing_sliced_readback(rd, sid_mesh, pipe_mesh, dens_buf_terrain, mat_buf_terrain, chunk_pos, vertex_buffer_terrain, counter_buffer_terrain, index_buffer_terrain)
		var water_slices: Dictionary = {"mesh_data": {}, "sync_ms": 0.0, "readback_ms": 0.0, "slice_count": 0, "max_slice_sync_ms": 0.0}
		if not skip_water_mesh:
			water_slices = run_gpu_meshing_sliced_readback(rd, sid_mesh, pipe_mesh, dens_buf_water, mat_buf_terrain, chunk_pos, vertex_buffer_water, counter_buffer_water, index_buffer_water)
		return {
			"flight_data": flight_data,
			"skip_water_mesh": skip_water_mesh,
			"already_synced": true,
			"mesh_data_terrain": terrain_slices.get("mesh_data", {}),
			"mesh_data_water": water_slices.get("mesh_data", {}),
			"mesh_sync_ms": float(terrain_slices.get("sync_ms", 0.0)) + float(water_slices.get("sync_ms", 0.0)),
			"mesh_readback_ms": float(terrain_slices.get("readback_ms", 0.0)) + float(water_slices.get("readback_ms", 0.0)),
			"mesh_slice_count": int(terrain_slices.get("slice_count", 0)) + int(water_slices.get("slice_count", 0)),
			"mesh_slice_max_sync_ms": maxf(float(terrain_slices.get("max_slice_sync_ms", 0.0)), float(water_slices.get("max_slice_sync_ms", 0.0)))
		}

	var set_mesh_t = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, dens_buf_terrain, mat_buf_terrain, chunk_pos, vertex_buffer_terrain, counter_buffer_terrain, index_buffer_terrain)
	var set_mesh_w = RID()
	if not skip_water_mesh:
		set_mesh_w = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, dens_buf_water, mat_buf_terrain, chunk_pos, vertex_buffer_water, counter_buffer_water, index_buffer_water)

	return {
		"flight_data": flight_data,
		"set_mesh_t": set_mesh_t,
		"set_mesh_w": set_mesh_w,
		"skip_water_mesh": skip_water_mesh,
		"vertex_buffer_terrain": vertex_buffer_terrain,
		"counter_buffer_terrain": counter_buffer_terrain,
		"index_buffer_terrain": index_buffer_terrain,
		"vertex_buffer_water": vertex_buffer_water,
		"counter_buffer_water": counter_buffer_water,
		"index_buffer_water": index_buffer_water
	}

# Complete readback and queue to CPU workers (called after density and mesh syncs)
func _complete_chunk_readback(rd: RenderingDevice, readback: Dictionary) -> Dictionary:
	var flight_data: Dictionary = readback.flight_data
	var coord = flight_data.coord
	var chunk_pos = flight_data.chunk_pos
	var dens_buf_terrain = flight_data.dens_buf_terrain
	var dens_buf_water = flight_data.dens_buf_water
	var mat_buf_terrain = flight_data.mat_buf_terrain

	if bool(readback.get("native_cpu_meshing", false)):
		var native_density_bytes_t: PackedByteArray = rd.buffer_get_data(dens_buf_terrain)
		var native_density_bytes_w := PackedByteArray()
		if not bool(readback.get("skip_water_mesh", false)):
			native_density_bytes_w = rd.buffer_get_data(dens_buf_water)
		var native_material_bytes: PackedByteArray = rd.buffer_get_data(mat_buf_terrain)

		var native_cpu_density_floats_w = PackedFloat32Array()
		var native_generated_water_density := true
		if bool(flight_data.get("needs_water_density_readback", false)):
			native_cpu_density_floats_w = native_density_bytes_w.to_float32_array()
			native_generated_water_density = false

		var native_cpu_density_floats_t = PackedFloat32Array()
		if bool(flight_data.get("needs_terrain_density_readback", false)):
			native_cpu_density_floats_t = native_density_bytes_t.to_float32_array()

		var native_cpu_material_bytes = PackedByteArray()
		if bool(flight_data.get("needs_material_readback", false)):
			native_cpu_material_bytes = native_material_bytes

		cpu_mutex.lock()
		cpu_task_queue.append({
			"coord": coord,
			"chunk_pos": chunk_pos,
			"native_cpu_meshing": true,
			"density_bytes_terrain": native_density_bytes_t,
			"density_bytes_water": native_density_bytes_w,
			"mesh_material_bytes": native_material_bytes,
			"skip_water_mesh": bool(readback.get("skip_water_mesh", false)),
			"cpu_dens_w": native_cpu_density_floats_w,
			"generated_water_density": native_generated_water_density,
			"cpu_dens_t": native_cpu_density_floats_t,
			"cpu_mat_t": native_cpu_material_bytes,
			"dens_buf_terrain": dens_buf_terrain,
			"dens_buf_water": dens_buf_water,
			"mat_buf_terrain": mat_buf_terrain,
			"stored_mod_version": int(flight_data.get("stored_mod_version", 0)),
			"queued_for_cpu_us": Time.get_ticks_usec()
		})
		cpu_mutex.unlock()
		cpu_semaphore.post()
		return {
			"terrain_vertex_count": 0,
			"water_vertex_count": 0
		}

	var mesh_data_terrain: Dictionary = readback.get("mesh_data_terrain", {})
	if mesh_data_terrain.is_empty():
		mesh_data_terrain = run_gpu_meshing_readback(rd, readback.vertex_buffer_terrain, readback.counter_buffer_terrain, readback.index_buffer_terrain, readback.set_mesh_t)
	var mesh_data_water: Dictionary = readback.get("mesh_data_water", {})
	if not bool(readback.get("skip_water_mesh", false)):
		if mesh_data_water.is_empty():
			mesh_data_water = run_gpu_meshing_readback(rd, readback.vertex_buffer_water, readback.counter_buffer_water, readback.index_buffer_water, readback.set_mesh_w)

	# Water and terrain density remain full CPU mirrors only for modified chunks.
	# Normal generated chunks answer water queries from the shader-equivalent
	# CPU formula and terrain queries from compact height maps.
	var cpu_density_floats_w = PackedFloat32Array()
	var generated_water_density := true
	if bool(flight_data.get("needs_water_density_readback", false)):
		var cpu_density_bytes_w = rd.buffer_get_data(dens_buf_water)
		cpu_density_floats_w = cpu_density_bytes_w.to_float32_array()
		generated_water_density = false
	var cpu_density_floats_t = PackedFloat32Array()
	var needs_terrain_density_readback := bool(flight_data.get("needs_terrain_density_readback", false))
	if not bool(mesh_data_terrain.get("packed", false)):
		needs_terrain_density_readback = true
	if needs_terrain_density_readback:
		var cpu_density_bytes_t = rd.buffer_get_data(dens_buf_terrain)
		cpu_density_floats_t = cpu_density_bytes_t.to_float32_array()

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
		"generated_water_density": generated_water_density,
		"cpu_dens_t": cpu_density_floats_t,
		"cpu_mat_t": cpu_material_bytes, # Material data for 3D texture
		"dens_buf_terrain": dens_buf_terrain,
		"dens_buf_water": dens_buf_water,
		"mat_buf_terrain": mat_buf_terrain, # Material buffer for modify path
		"stored_mod_version": int(flight_data.get("stored_mod_version", 0)),
		"queued_for_cpu_us": Time.get_ticks_usec()
	})
	cpu_mutex.unlock()
	cpu_semaphore.post()
	return {
		"terrain_vertex_count": int(mesh_data_terrain.get("vertex_count", 0)),
		"water_vertex_count": int(mesh_data_water.get("vertex_count", 0))
	}

func run_gpu_meshing_immediate_readback(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer, index_buffer) -> Dictionary:
	var set_mesh = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer, index_buffer)
	rd.submit()
	var sync_start_us := Time.get_ticks_usec()
	rd.sync()
	var sync_ms := float(Time.get_ticks_usec() - sync_start_us) / 1000.0

	var readback_start_us := Time.get_ticks_usec()
	var mesh_data := run_gpu_meshing_readback(rd, vertex_buffer, counter_buffer, index_buffer, set_mesh)
	var readback_ms := float(Time.get_ticks_usec() - readback_start_us) / 1000.0
	return {
		"mesh_data": mesh_data,
		"sync_ms": sync_ms,
		"readback_ms": readback_ms
	}


func run_gpu_meshing_sliced_readback(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer, index_buffer) -> Dictionary:
	var target_cells := CHUNK_SIZE - 1
	var requested_slices := clampi(terrain_gpu_mesh_slices_per_chunk, 1, 8)
	var slice_height := maxi(1, int(ceil(float(target_cells) / float(requested_slices))))
	var mesh_slices: Array[Dictionary] = []
	var total_sync_ms := 0.0
	var total_readback_ms := 0.0
	var max_slice_sync_ms := 0.0
	var actual_slice_count := 0

	for slice_y in range(0, target_cells, slice_height):
		var slice_count = mini(slice_height, target_cells - slice_y)
		if slice_count <= 0:
			continue
		var set_mesh = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer, index_buffer, slice_y, slice_count)
		rd.submit()
		var sync_start_us := Time.get_ticks_usec()
		rd.sync()
		var sync_ms := float(Time.get_ticks_usec() - sync_start_us) / 1000.0
		total_sync_ms += sync_ms
		max_slice_sync_ms = maxf(max_slice_sync_ms, sync_ms)

		var readback_start_us := Time.get_ticks_usec()
		var mesh_data := run_gpu_meshing_readback(rd, vertex_buffer, counter_buffer, index_buffer, set_mesh)
		total_readback_ms += float(Time.get_ticks_usec() - readback_start_us) / 1000.0
		actual_slice_count += 1
		if int(mesh_data.get("vertex_count", 0)) > 0:
			mesh_slices.append(mesh_data)

		if terrain_gpu_mesh_slice_delay_ms > 0 and slice_y + slice_count < target_cells:
			OS.delay_msec(terrain_gpu_mesh_slice_delay_ms)

	return {
		"mesh_data": _merge_packed_mesh_slices(mesh_slices),
		"sync_ms": total_sync_ms,
		"readback_ms": total_readback_ms,
		"slice_count": actual_slice_count,
		"max_slice_sync_ms": max_slice_sync_ms
	}


func _merge_packed_mesh_slices(mesh_slices: Array[Dictionary]) -> Dictionary:
	var merged_vertices := PackedByteArray()
	var merged_indices := PackedByteArray()
	var total_vertex_count := 0
	var total_index_count := 0

	for mesh_data in mesh_slices:
		if not bool(mesh_data.get("indexed", false)):
			return mesh_data
		var vertex_bytes: PackedByteArray = mesh_data.get("bytes", PackedByteArray())
		var index_bytes: PackedByteArray = mesh_data.get("indices", PackedByteArray())
		var vertex_count := int(mesh_data.get("vertex_count", 0))
		var index_count := int(mesh_data.get("index_count", index_bytes.size() / 4))
		if vertex_count <= 0 or vertex_bytes.is_empty() or index_count <= 0 or index_bytes.is_empty():
			continue

		merged_vertices.append_array(vertex_bytes)
		var index_base_byte := merged_indices.size()
		merged_indices.resize(index_base_byte + index_count * 4)
		for index_i in range(index_count):
			var local_index := int(index_bytes.decode_u32(index_i * 4))
			merged_indices.encode_u32(index_base_byte + index_i * 4, local_index + total_vertex_count)
		total_vertex_count += vertex_count
		total_index_count += index_count

	return {
		"bytes": merged_vertices,
		"indices": merged_indices,
		"floats": PackedFloat32Array(),
		"vertex_count": total_vertex_count,
		"index_count": total_index_count,
		"packed": true,
		"indexed": true
	}

# GPU meshing dispatch only - NO sync, returns uniform set for later cleanup
func run_gpu_meshing_dispatch(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer, index_buffer, slice_y_offset: int = 0, slice_y_count: int = CHUNK_SIZE - 1) -> RID:
	# Reset Counter to 0
	var zero_data = PackedByteArray()
	zero_data.resize(12)
	zero_data.encode_u32(0, 0)
	zero_data.encode_u32(4, 0)
	zero_data.encode_u32(8, 0)
	rd.buffer_update(counter_buffer, 0, 12, zero_data)

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

	var u_index = RDUniform.new()
	u_index.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_index.binding = 4
	u_index.add_id(index_buffer)

	var set_mesh = rd.uniform_set_create([u_vert, u_count, u_dens, u_mat, u_index], sid_mesh, 0)

	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mesh)
	rd.compute_list_bind_uniform_set(list, set_mesh, 0)

	var push_data = PackedFloat32Array([
		chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0,
		noise_frequency, terrain_height, float(slice_y_offset), float(slice_y_count)
	])
	rd.compute_list_set_push_constant(list, push_data.to_byte_array(), push_data.size() * 4)

	var groups = CHUNK_SIZE / 8
	var groups_y = int(ceil(float(slice_y_count) / 8.0))
	rd.compute_list_dispatch(list, groups, groups_y, groups)
	rd.compute_list_end()
	# NO submit/sync here - caller handles it

	return set_mesh

# Readback packed mesh data AFTER sync has been called.
func run_gpu_meshing_readback(rd: RenderingDevice, vertex_buffer, counter_buffer, index_buffer, set_mesh: RID) -> Dictionary:
	# Read back vertex data
	var count_bytes = rd.buffer_get_data(counter_buffer)
	if count_bytes.size() < 4:
		if set_mesh.is_valid(): rd.free_rid(set_mesh)
		return {
			"bytes": PackedByteArray(),
			"indices": PackedByteArray(),
			"floats": PackedFloat32Array(),
			"vertex_count": 0,
			"index_count": 0,
			"packed": false,
			"indexed": false
		}

	var tri_count = count_bytes.decode_u32(0)
	var index_count = tri_count * 3
	var vertex_count = index_count

	var output_format_magic := 0
	if count_bytes.size() >= 8:
		output_format_magic = count_bytes.decode_u32(4)
	var indexed := output_format_magic == PACKED_INDEXED_OUTPUT_MAGIC
	if indexed and count_bytes.size() >= 12:
		vertex_count = count_bytes.decode_u32(8)
	elif indexed:
		indexed = false

	var vertex_bytes = PackedByteArray()
	var index_bytes = PackedByteArray()
	var vert_floats = PackedFloat32Array()
	if tri_count > 0:
		if indexed:
			if vertex_count > 0:
				var total_vertex_bytes = vertex_count * PACKED_VERTEX_UINTS * 4
				var total_index_bytes = index_count * 4
				vertex_bytes = rd.buffer_get_data(vertex_buffer, 0, total_vertex_bytes)
				index_bytes = rd.buffer_get_data(index_buffer, 0, total_index_bytes)
		elif output_format_magic == PACKED_OUTPUT_MAGIC:
			var total_bytes = vertex_count * PACKED_VERTEX_UINTS * 4
			vertex_bytes = rd.buffer_get_data(vertex_buffer, 0, total_bytes)
		else:
			var total_float_bytes = vertex_count * LEGACY_VERTEX_FLOATS * 4
			vert_floats = rd.buffer_get_data(vertex_buffer, 0, total_float_bytes).to_float32_array()

	if set_mesh.is_valid(): rd.free_rid(set_mesh)

	return {
		"bytes": vertex_bytes,
		"indices": index_bytes,
		"floats": vert_floats,
		"vertex_count": vertex_count,
		"index_count": index_count,
		"packed": output_format_magic == PACKED_OUTPUT_MAGIC or indexed,
		"indexed": indexed
	}

# Legacy function for modify path (still needs sync inline)
func run_gpu_meshing(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer, index_buffer) -> Dictionary:
	var set_mesh = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer, index_buffer)
	rd.submit()
	rd.sync()
	return run_gpu_meshing_readback(rd, vertex_buffer, counter_buffer, index_buffer, set_mesh)

func _process_cpu_terrain_visual_batch_task(builder: Object, task: Dictionary) -> bool:
	if str(task.get("type", "")) != "terrain_visual_batch":
		return false

	var merged_mesh = null
	var merged_mesh_result: Dictionary = {}
	if builder.has_method("build_merged_array_mesh_data"):
		merged_mesh_result = builder.build_merged_array_mesh_data(task.get("merge_inputs", []))
	elif builder.has_method("build_merged_array_mesh"):
		merged_mesh = builder.build_merged_array_mesh(task.get("merge_inputs", []))
	_enqueue_completed_terrain_visual_batch_build({
		"batch_key": task.get("batch_key", Vector2i.ZERO),
		"cache_key": str(task.get("cache_key", "")),
		"mesh": merged_mesh,
		"mesh_result": merged_mesh_result
	})
	return true

func _pop_suspended_terrain_visual_batch_task() -> Dictionary:
	var task: Dictionary = {}
	cpu_mutex.lock()
	for i in range(cpu_task_queue.size() - 1, -1, -1):
		var candidate_variant: Variant = cpu_task_queue[i]
		if typeof(candidate_variant) != TYPE_DICTIONARY:
			continue
		var candidate: Dictionary = candidate_variant
		if str(candidate.get("type", "")) != "terrain_visual_batch":
			continue
		task = candidate
		cpu_task_queue.remove_at(i)
		break
	cpu_mutex.unlock()
	return task

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

		if _runtime_power_world_work_suspended and not should_exit:
			var suspended_visual_batch_task := _pop_suspended_terrain_visual_batch_task()
			if suspended_visual_batch_task.is_empty():
				_interruptible_delay(50)
				continue
			_process_cpu_terrain_visual_batch_task(builder, suspended_visual_batch_task)
			continue

		cpu_mutex.lock()
		if cpu_task_queue.is_empty():
			cpu_mutex.unlock()
			if should_exit:
				break
			continue

		var task = cpu_task_queue.pop_back()
		cpu_mutex.unlock()

		if _process_cpu_terrain_visual_batch_task(builder, task):
			continue

		# Build terrain mesh and collision (CPU intensive)
		var cpu_build_start_us := Time.get_ticks_usec()
		var queued_for_cpu_us := int(task.get("queued_for_cpu_us", 0))
		var cpu_queue_wait_ms := 0.0
		if queued_for_cpu_us > 0:
			cpu_queue_wait_ms = float(cpu_build_start_us - queued_for_cpu_us) / 1000.0
		var mesh_terrain = null
		var shape_terrain = null
		var height_map_terrain := PackedFloat32Array()
		var native_cpu_meshing := bool(task.get("native_cpu_meshing", false))
		var mesh_data_terrain: Dictionary = task.get("mesh_data_terrain", {})
		var built_terrain_result: Dictionary = {}
		var terrain_vertex_count := int(mesh_data_terrain.get("vertex_count", 0))
		var terrain_build_ms := 0.0
		if native_cpu_meshing:
			var terrain_build_start_us := Time.get_ticks_usec()
			var density_bytes_terrain: PackedByteArray = task.get("density_bytes_terrain", PackedByteArray())
			var mesh_material_bytes: PackedByteArray = task.get("mesh_material_bytes", PackedByteArray())
			if not density_bytes_terrain.is_empty() and builder.has_method("build_density_marching_cubes_mesh_data_height_map"):
				built_terrain_result = builder.build_density_marching_cubes_mesh_data_height_map(density_bytes_terrain, mesh_material_bytes, DENSITY_GRID_SIZE, CHUNK_SIZE, CHUNK_STRIDE)
				height_map_terrain = built_terrain_result.get("height_map", PackedFloat32Array())
				terrain_vertex_count = int(built_terrain_result.get("source_vertex_count", 0))
			elif not density_bytes_terrain.is_empty() and builder.has_method("build_density_marching_cubes_mesh_collision_height_map"):
				built_terrain_result = builder.build_density_marching_cubes_mesh_collision_height_map(density_bytes_terrain, mesh_material_bytes, DENSITY_GRID_SIZE, CHUNK_SIZE, CHUNK_STRIDE)
				mesh_terrain = built_terrain_result.get("mesh", null)
				if mesh_terrain:
					mesh_terrain.surface_set_material(0, material_terrain)
					built_terrain_result["mesh"] = mesh_terrain
				shape_terrain = built_terrain_result.get("shape", null)
				height_map_terrain = built_terrain_result.get("height_map", PackedFloat32Array())
				terrain_vertex_count = int(built_terrain_result.get("source_vertex_count", 0))
			terrain_build_ms = float(Time.get_ticks_usec() - terrain_build_start_us) / 1000.0
		elif int(mesh_data_terrain.get("vertex_count", 0)) > 0:
			var terrain_build_start_us := Time.get_ticks_usec()
			var built_terrain := build_packed_mesh_and_collision(mesh_data_terrain, material_terrain, builder, true)
			mesh_terrain = built_terrain.get("mesh", null)
			shape_terrain = built_terrain.get("shape", null)
			height_map_terrain = built_terrain.get("height_map", PackedFloat32Array())
			terrain_build_ms = float(Time.get_ticks_usec() - terrain_build_start_us) / 1000.0

		# Build water mesh and collision (CPU intensive)
		var mesh_water = null
		var shape_water = null
		var mesh_data_water: Dictionary = task.get("mesh_data_water", {})
		var built_water_result: Dictionary = {}
		var water_vertex_count := int(mesh_data_water.get("vertex_count", 0))
		var water_build_ms := 0.0
		if native_cpu_meshing and not bool(task.get("skip_water_mesh", false)):
			var water_build_start_us := Time.get_ticks_usec()
			var density_bytes_water: PackedByteArray = task.get("density_bytes_water", PackedByteArray())
			var mesh_material_bytes_water: PackedByteArray = task.get("mesh_material_bytes", PackedByteArray())
			if not density_bytes_water.is_empty() and builder.has_method("build_density_marching_cubes_mesh_data"):
				built_water_result = builder.build_density_marching_cubes_mesh_data(density_bytes_water, mesh_material_bytes_water, DENSITY_GRID_SIZE, CHUNK_SIZE)
				water_vertex_count = int(built_water_result.get("source_vertex_count", 0))
			elif not density_bytes_water.is_empty() and builder.has_method("build_density_marching_cubes_mesh_and_collision"):
				built_water_result = builder.build_density_marching_cubes_mesh_and_collision(density_bytes_water, mesh_material_bytes_water, DENSITY_GRID_SIZE, CHUNK_SIZE)
				mesh_water = built_water_result.get("mesh", null)
				if mesh_water:
					mesh_water.surface_set_material(0, material_water)
					built_water_result["mesh"] = mesh_water
				shape_water = built_water_result.get("shape", null)
				water_vertex_count = int(built_water_result.get("source_vertex_count", 0))
			water_build_ms = float(Time.get_ticks_usec() - water_build_start_us) / 1000.0
		elif int(mesh_data_water.get("vertex_count", 0)) > 0:
			var water_build_start_us := Time.get_ticks_usec()
			var built_water := build_packed_mesh_and_collision(mesh_data_water, material_water, builder)
			mesh_water = built_water.get("mesh", null)
			shape_water = built_water.get("shape", null)
			water_build_ms = float(Time.get_ticks_usec() - water_build_start_us) / 1000.0

		_last_cpu_mesh_build_ms = float(Time.get_ticks_usec() - cpu_build_start_us) / 1000.0
		_last_cpu_mesh_build_terrain_ms = terrain_build_ms
		_last_cpu_mesh_build_water_ms = water_build_ms
		_last_cpu_mesh_build_queue_wait_ms = cpu_queue_wait_ms
		_last_cpu_mesh_build_terrain_vertices = terrain_vertex_count
		_last_cpu_mesh_build_water_vertices = water_vertex_count
		_last_cpu_mesh_build_coord = task.coord
		_last_cpu_mesh_build_event_id += 1

		# Package results
		var result_t: Dictionary = built_terrain_result.duplicate() if not built_terrain_result.is_empty() else {"mesh": mesh_terrain, "shape": shape_terrain}
		var result_w: Dictionary = built_water_result.duplicate() if not built_water_result.is_empty() else {"mesh": mesh_water, "shape": shape_water}
		result_w["generated_density"] = bool(task.get("generated_water_density", false))

		# Send to the main thread through a bounded queue. A call_deferred per
		# chunk can flood Engine: Process when render distance 10 completes a
		# large town burst; the queue preserves every result while draining under
		# the same frame-budget discipline as node finalization.
		_enqueue_completed_generation({
			"coord": task.coord,
			"result_t": result_t,
			"dens_t": task.dens_buf_terrain,
			"result_w": result_w,
			"dens_w": task.dens_buf_water,
			"cpu_dens_w": task.cpu_dens_w,
			"cpu_dens_t": task.cpu_dens_t,
			"height_map_t": height_map_terrain,
			"mat_t": task.mat_buf_terrain,
			"cpu_mat_t": task.cpu_mat_t,
			"stored_mod_version": int(task.get("stored_mod_version", 0))
		})

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

func process_modify(rd: RenderingDevice, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, vertex_buffer, counter_buffer, index_buffer, builder_override: Object = null):
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
	var result = run_meshing(rd, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, material, vertex_buffer, counter_buffer, index_buffer, builder_override)

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

func build_packed_mesh_and_collision(mesh_data: Dictionary, material_instance: Material, builder_override: Object = null, include_height_map: bool = false) -> Dictionary:
	var vertex_count := int(mesh_data.get("vertex_count", 0))
	if not bool(mesh_data.get("packed", true)):
		var legacy_floats: PackedFloat32Array = mesh_data.get("floats", PackedFloat32Array())
		return build_mesh_and_collision(legacy_floats, material_instance, builder_override)

	var indexed := bool(mesh_data.get("indexed", false))
	var vertex_bytes: PackedByteArray = mesh_data.get("bytes", PackedByteArray())
	if vertex_count <= 0 or vertex_bytes.is_empty():
		return {"mesh": null, "shape": null}

	var native_builder = builder_override
	if not native_builder:
		native_builder = ClassDB.instantiate("MeshBuilder")
		if not native_builder:
			push_error("[ChunkManager] MeshBuilder GDExtension is required for packed mesh/collision building.")
			return {"mesh": null, "shape": null}

	if indexed:
		var index_count := int(mesh_data.get("index_count", 0))
		var index_bytes: PackedByteArray = mesh_data.get("indices", PackedByteArray())
		if index_count <= 0 or index_bytes.is_empty():
			return {"mesh": null, "shape": null}

		if include_height_map and native_builder.has_method("build_packed_indexed_mesh_collision_height_map"):
			var indexed_height_result: Dictionary = native_builder.build_packed_indexed_mesh_collision_height_map(vertex_bytes, index_bytes, vertex_count, index_count, CHUNK_STRIDE)
			var indexed_height_mesh = indexed_height_result.get("mesh", null)
			if indexed_height_mesh:
				indexed_height_mesh.surface_set_material(0, material_instance)
				indexed_height_result["mesh"] = indexed_height_mesh
			return indexed_height_result

		if not native_builder.has_method("build_packed_indexed_mesh_and_collision"):
			push_error("[ChunkManager] MeshBuilder.build_packed_indexed_mesh_and_collision() is required for indexed packed terrain meshes.")
			return {"mesh": null, "shape": null}

		var indexed_result: Dictionary = native_builder.build_packed_indexed_mesh_and_collision(vertex_bytes, index_bytes, vertex_count, index_count)
		var indexed_mesh = indexed_result.get("mesh", null)
		if indexed_mesh:
			indexed_mesh.surface_set_material(0, material_instance)
			indexed_result["mesh"] = indexed_mesh
		return indexed_result

	if include_height_map and native_builder.has_method("build_packed_mesh_collision_height_map"):
		var height_result: Dictionary = native_builder.build_packed_mesh_collision_height_map(vertex_bytes, vertex_count, CHUNK_STRIDE)
		var height_mesh = height_result.get("mesh", null)
		if height_mesh:
			height_mesh.surface_set_material(0, material_instance)
			height_result["mesh"] = height_mesh
		return height_result

	if not native_builder.has_method("build_packed_mesh_and_collision"):
		push_error("[ChunkManager] MeshBuilder.build_packed_mesh_and_collision() is required for packed terrain meshes.")
		return {"mesh": null, "shape": null}

	var result: Dictionary = native_builder.build_packed_mesh_and_collision(vertex_bytes, vertex_count)
	var native_mesh = result.get("mesh", null)
	if native_mesh:
		native_mesh.surface_set_material(0, material_instance)
		result["mesh"] = native_mesh
	return result

func run_meshing(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, material_instance: Material, vertex_buffer, counter_buffer, index_buffer, builder_override: Object = null):
	var set_mesh = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer, index_buffer)
	rd.submit()
	rd.sync()

	var mesh_data := run_gpu_meshing_readback(rd, vertex_buffer, counter_buffer, index_buffer, set_mesh)
	if int(mesh_data.get("vertex_count", 0)) <= 0:
		return {"mesh": null, "shape": null}

	var built := build_packed_mesh_and_collision(mesh_data, material_instance, builder_override)
	return {
		"mesh": built.get("mesh", null),
		"shape": built.get("shape", null)
	}

func complete_generation(coord: Vector3i, result_t: Dictionary, dens_t: RID, result_w: Dictionary, dens_w: RID, cpu_dens_w: PackedFloat32Array, cpu_dens_t: PackedFloat32Array, height_map_t: PackedFloat32Array = PackedFloat32Array(), mat_t: RID = RID(), cpu_mat_t: PackedByteArray = PackedByteArray(), stored_mod_version: int = 0):
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
		"height_map": height_map_t,
		"cpu_mat": cpu_mat_t,
		"stored_mod_version": stored_mod_version
	})

	# Task 2: Water (Lighter - ~2ms)
	pending_nodes.append({
		"type": "final_water",
		"coord": coord,
		"result": result_w,
		"dens": dens_w,
		"cpu_dens": cpu_dens_w,
		"generated_density": bool(result_w.get("generated_density", false)),
		"stored_mod_version": stored_mod_version
	})
	pending_nodes_needs_sort = true

	pending_nodes_mutex.unlock()

func _queue_stored_modifications_after(coord: Vector3i, data: ChunkData, after_version: int, target_layer: int) -> void:
	if data == null:
		return
	var missed_mods := _get_stored_modifications_after(coord, after_version)
	if missed_mods.is_empty():
		return

	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
	var tasks_to_add: Array[Dictionary] = []
	_set_generated_mod_version(data, after_version)

	for mod_variant in missed_mods:
		if not (mod_variant is Dictionary):
			continue
		var mod: Dictionary = mod_variant
		var mod_layer := int(mod.get("layer", 0))
		if mod_layer != target_layer:
			continue
		var target_buffer: RID = data.density_buffer_terrain if mod_layer == 0 else data.density_buffer_water
		if not target_buffer.is_valid():
			continue

		var brush_pos: Vector3 = mod.get("brush_pos", Vector3.ZERO)
		var start_mod_version := _bump_chunk_layer_mod_version(data, mod_layer, after_version)
		var task := {
			"type": "modify",
			"coord": coord,
			"rid": target_buffer,
			"material_rid": data.material_buffer_terrain,
			"pos": chunk_pos,
			"brush_pos": brush_pos,
			"radius": float(mod.get("radius", 0.0)),
			"value": float(mod.get("value", 0.0)),
			"shape": int(mod.get("shape", 0)),
			"layer": mod_layer,
			"material_id": int(mod.get("material_id", -1)),
			"start_mod_version": start_mod_version
		}
		if int(task.get("shape", 0)) == 2:
			task["y_min"] = float(mod.get("y_min", brush_pos.y))
			task["y_max"] = float(mod.get("y_max", brush_pos.y))
		tasks_to_add.append(task)

	if tasks_to_add.is_empty():
		return

	mutex.lock()
	for task in tasks_to_add:
		priority_task_queue.append(task)
	mutex.unlock()

	for i in range(tasks_to_add.size()):
		semaphore.post()

func _materialize_deferred_mesh_result(mesh_result: Dictionary, material_instance: Material) -> Dictionary:
	if not bool(mesh_result.get("deferred_mesh_data", false)):
		var existing_mesh = mesh_result.get("mesh", null)
		if existing_mesh and material_instance and existing_mesh.get_surface_count() > 0:
			existing_mesh.surface_set_material(0, material_instance)
			mesh_result["mesh"] = existing_mesh
		return mesh_result

	var arrays: Array = mesh_result.get("arrays", [])
	if arrays.is_empty():
		mesh_result["mesh"] = null
		mesh_result["shape"] = null
		return mesh_result

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material_instance and mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, material_instance)

	var shape = null
	var faces: PackedVector3Array = mesh_result.get("faces", PackedVector3Array())
	if not faces.is_empty():
		shape = ConcavePolygonShape3D.new()
		shape.set_faces(faces)

	mesh_result["mesh"] = mesh
	mesh_result["shape"] = shape
	return mesh_result

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
		var terrain_mesh_result := _materialize_deferred_mesh_result(item.result, chunk_material)

		# Create Node (VISUALS ONLY)
		# Pass defer_collision=true to prevent create_chunk_node from creating a StaticBody3D/CollisionShape3D
		var result = create_chunk_node(terrain_mesh_result.get("mesh", null), null, chunk_pos, false, chunk_material, true, coord)

		# Update Data
		var data = active_chunks[coord]
		if data == null:
			data = ChunkData.new()
			active_chunks[coord] = data

		data.node_terrain = result.node if not result.is_empty() else null
		if coord.y == 0 and data.node_terrain:
			_unload_world_map_lod_chunk(Vector2i(coord.x, coord.z))
		data.terrain_visual_mesh = terrain_mesh_result.get("mesh", null)
		data.terrain_visual_batched = false
		_set_generated_mod_version(data, int(item.get("stored_mod_version", 0)))
		_register_terrain_visual_batch_member(coord)

		# CRITICAL: Keep Shape3D resource alive!
		# If we don't store this, the RefCount goes to 0 -> RID freed -> No Collision
		data.terrain_shape = terrain_mesh_result.get("shape", null)

		data.density_buffer_terrain = item.dens
		data.material_buffer_terrain = item.get("mat_buf", RID())
		data.cpu_density_terrain = item.cpu_dens
		data.cpu_height_map_terrain = item.get("height_map", PackedFloat32Array())
		if data.cpu_height_map_terrain.is_empty() and not data.cpu_density_terrain.is_empty():
			data.cpu_height_map_terrain = _build_height_map_from_density(data.cpu_density_terrain)
		data.cpu_height_map_size = CHUNK_STRIDE if not data.cpu_height_map_terrain.is_empty() else 0
		data.chunk_material = chunk_material
		data.cpu_material_terrain = item.get("cpu_mat", PackedByteArray())

		var p_pos = get_viewer_position()
		var center_chunk = Vector3i(
			int(floor(p_pos.x / CHUNK_STRIDE)),
			int(floor(p_pos.y / CHUNK_STRIDE)),
			int(floor(p_pos.z / CHUNK_STRIDE))
		)
		var collision_distance_sq := collision_distance * collision_distance
		var collision_prewarm_distance_sq := maxi(collision_prewarm_distance, collision_distance) * maxi(collision_prewarm_distance, collision_distance)
		var should_have_collision := _should_have_terrain_collision(coord, center_chunk, collision_distance_sq)
		_sync_terrain_collision_state(coord, data, should_have_collision, get_world_3d())
		if not should_have_collision and _should_prewarm_terrain_collision(coord, center_chunk, collision_prewarm_distance_sq):
			_queue_terrain_collision_create(coord)
		_mark_terrain_visual_batch_dirty(coord)
		_queue_stored_modifications_after(coord, data, int(item.get("stored_mod_version", 0)), 0)

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

		# Update Data
		var data = active_chunks[coord]
		if data == null:
			data = ChunkData.new()
		active_chunks[coord] = data

		var create_water_node := water_render_enabled
		if create_water_node and world_map_active and bool(item.get("generated_density", false)) and not _chunk_may_have_generated_water_surface(coord):
			create_water_node = false
			_generated_water_surface_skip_count += 1
			_last_generated_water_surface_skip_coord = coord

		_unregister_water_visual_batch_member(coord)
		_mark_water_visual_batch_dirty(coord, true)
		data.water_visual_mesh = null
		data.water_visual_batched = false
		if data.node_water:
			data.node_water.queue_free()
			data.node_water = null

		var water_mesh_result := {}
		if create_water_node:
			water_mesh_result = _materialize_deferred_mesh_result(item.result, material_water)
			# World-map swimming/underwater checks use density sampling, not Area3D
			# overlap state, so the water mesh can stay visual-only in that mode.
			var result = create_chunk_node(water_mesh_result.get("mesh", null), water_mesh_result.get("shape", null), chunk_pos, true, null, world_map_active, coord)
			data.node_water = result.node if not result.is_empty() else null
		else:
			data.node_water = null
		if data.node_water:
			data.water_visual_mesh = water_mesh_result.get("mesh", null)
			data.water_visual_batched = false
			_register_water_visual_batch_member(coord)
			_mark_water_visual_batch_dirty(coord)
		data.density_buffer_water = item.dens
		data.cpu_density_water = item.cpu_dens
		data.generated_water_density_available = bool(item.get("generated_density", false))
		_set_generated_mod_version(data, int(item.get("stored_mod_version", 0)))
		_queue_stored_modifications_after(coord, data, int(item.get("stored_mod_version", 0)), 1)

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
			if chunk_data != null and start_mod_version > 0 and start_mod_version < _get_chunk_layer_mod_version(chunk_data, layer):
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
		if chunk_data != null and start_mod_version > 0 and start_mod_version < _get_chunk_layer_mod_version(chunk_data, layer):
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
	if data != null and start_mod_version > 0 and start_mod_version < _get_chunk_layer_mod_version(data, layer):
		return

	var update_start_us := Time.get_ticks_usec()
	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)

	if layer == 0: # Terrain
		_mark_terrain_visual_batch_dirty(coord, true)
		# CRITICAL: Free the PhysicsServer body RID first (contains stale collision)
		_set_terrain_collision_ready(coord, data, false)
		pending_terrain_collision_creates.erase(coord)
		_free_chunk_body_rid(data, coord)
		if data.node_terrain: data.node_terrain.queue_free()

		# Recreate chunk material with updated 3D texture
		var chunk_material = _create_chunk_material(chunk_pos, cpu_mat)
		var p_pos = get_viewer_position()
		var center_chunk = Vector3i(
			int(floor(p_pos.x / CHUNK_STRIDE)),
			int(floor(p_pos.y / CHUNK_STRIDE)),
			int(floor(p_pos.z / CHUNK_STRIDE))
		)

		var result_node = create_chunk_node(result.mesh, result.shape, chunk_pos, false, chunk_material, false, coord)
		data.node_terrain = result_node.node if not result_node.is_empty() else null
		if coord.y == 0 and data.node_terrain:
			_unload_world_map_lod_chunk(Vector2i(coord.x, coord.z))
		data.terrain_visual_mesh = result.mesh
		data.terrain_visual_batched = false
		data.collision_shape_terrain = result_node.collision_shape if not result_node.is_empty() else null
		data.chunk_material = chunk_material
		if not cpu_dens.is_empty():
			data.cpu_density_terrain = cpu_dens
			data.cpu_height_map_terrain = _build_height_map_from_density(cpu_dens)
			data.cpu_height_map_size = CHUNK_STRIDE if not data.cpu_height_map_terrain.is_empty() else 0
		if not cpu_mat.is_empty():
			data.cpu_material_terrain = cpu_mat
		var collision_distance_sq := collision_distance * collision_distance
		var collision_prewarm_distance_sq := maxi(collision_prewarm_distance, collision_distance) * maxi(collision_prewarm_distance, collision_distance)
		var should_have_collision := _should_have_terrain_collision(coord, center_chunk, collision_distance_sq)
		_sync_terrain_collision_state(coord, data, should_have_collision, get_world_3d())
		if not should_have_collision and _should_prewarm_terrain_collision(coord, center_chunk, collision_prewarm_distance_sq):
			_queue_terrain_collision_create(coord)
		_mark_terrain_visual_batch_dirty(coord)
		# Signal vegetation manager that chunk node changed (update references, don't regenerate)
		chunk_modified.emit(coord, data.node_terrain)
	else: # Water
		_unregister_water_visual_batch_member(coord)
		_mark_water_visual_batch_dirty(coord, true)
		data.water_visual_mesh = null
		data.water_visual_batched = false
		if data.node_water: data.node_water.queue_free()
		if water_render_enabled:
			var result_node = create_chunk_node(result.mesh, result.shape, chunk_pos, true, null, world_map_active, coord)
			data.node_water = result_node.node if not result_node.is_empty() else null
		else:
			data.node_water = null
		if data.node_water:
			data.water_visual_mesh = result.mesh
			data.water_visual_batched = false
			_register_water_visual_batch_member(coord)
			_mark_water_visual_batch_dirty(coord)
		if not cpu_dens.is_empty():
			data.cpu_density_water = cpu_dens
			data.generated_water_density_available = false
	_last_chunk_update_ms = float(Time.get_ticks_usec() - update_start_us) / 1000.0

func create_chunk_node(mesh: ArrayMesh, shape: Shape3D, position: Vector3, is_water: bool = false, custom_material: Material = null, defer_collision: bool = false, coord: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)) -> Dictionary:
	if mesh == null:
		return {}

	var node: Node3D

	if is_water:
		if defer_collision:
			node = Node3D.new()
			node.set_meta("visual_water_only", true)
		else:
			var water_area := Area3D.new()
			# Ensure it's monitorable so legacy/procedural water can still be
			# detected through Area3D physics when collision is requested.
			water_area.monitorable = true
			water_area.monitoring = false # Terrain chunks don't need to monitor others
			node = water_area
		node.add_to_group("water")
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
	elif coord != Vector3i(2147483647, 2147483647, 2147483647):
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if _should_terrain_cast_shadow(coord) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	node.add_child(mesh_instance)

	var collision_shape: CollisionShape3D = null
	if not defer_collision:
		collision_shape = CollisionShape3D.new()
		if shape:
			collision_shape.shape = shape
		node.add_child(collision_shape)

	# Optimization: Add to tree LAST to perform single update
	_ensure_chunk_node_root().add_child(node)

	# Return both node and collision_shape for tracking
	return {"node": node, "collision_shape": collision_shape, "mesh_instance": mesh_instance}

# ============ SPAWN ZONE API ============
# These methods enable save/load to wait for terrain before spawning players/entities

## Request priority loading of chunks around a spawn position
## The spawn_zones_ready signal will be emitted when all chunks are loaded
func request_spawn_zone(position: Vector3, radius: int = 2):
	var chunk_x = int(floor(position.x / CHUNK_STRIDE))
	var chunk_y = int(floor(position.y / CHUNK_STRIDE))
	var chunk_z = int(floor(position.z / CHUNK_STRIDE))
	if distant_world_map_lod_enabled and distant_world_map_lod_defer_until_initial_viewer_move:
		# Spawn-zone loads can be teleports/save-loads. If a world already exists,
		# do not let this reset become a new permanent "initial viewer" LOD defer.
		if not active_chunks.is_empty() or _has_world_map_lod_initial_viewer_chunk():
			_release_world_map_lod_initial_defer()
	_reset_far_chunks_before_spawn_zone(chunk_x, chunk_y, chunk_z)

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
					_register_active_chunk_with_grid(coord)
					_register_terrain_visual_batch_member(coord)
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
		pending_spawn_zones.append({
			"position": position,
			"radius": radius,
			"pending_coords": pending_coords
		})
		call_deferred("_check_spawn_zone_readiness", Vector3i(2147483647, 2147483647, 2147483647))
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


func _reset_far_chunks_before_spawn_zone(chunk_x: int, _chunk_y: int, chunk_z: int) -> void:
	_last_spawn_zone_far_reset_ms = 0.0
	_last_spawn_zone_far_reset_cleared_chunks = 0
	if spawn_zone_far_reset_distance_chunks <= 0 or active_chunks.is_empty():
		return

	var reset_distance := maxi(render_distance + 2, spawn_zone_far_reset_distance_chunks)
	var reset_distance_sq := reset_distance * reset_distance
	var nearby_chunks := 0
	var stale_chunks := 0
	for coord_variant in active_chunks.keys():
		var coord: Vector3i = coord_variant
		var dx := coord.x - chunk_x
		var dz := coord.z - chunk_z
		if dx * dx + dz * dz <= reset_distance_sq:
			nearby_chunks += 1
		else:
			stale_chunks += 1

	if stale_chunks < 64 or stale_chunks <= nearby_chunks:
		return

	var clear_start_us := Time.get_ticks_usec()
	var cleared_chunks := active_chunks.size()
	clear_all_chunks(true)
	_spawn_zone_far_reset_count += 1
	_last_spawn_zone_far_reset_cleared_chunks = cleared_chunks
	_last_spawn_zone_far_reset_ms = float(Time.get_ticks_usec() - clear_start_us) / 1000.0
	_capture_terrain_telemetry("spawn_zone_far_reset", {
		"target_chunk_x": chunk_x,
		"target_chunk_z": chunk_z,
		"cleared_chunks": cleared_chunks,
		"nearby_chunks": nearby_chunks,
		"stale_chunks": stale_chunks,
		"elapsed_ms": _last_spawn_zone_far_reset_ms
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


func is_spawn_zone_ready(position: Vector3, radius: int = 2) -> bool:
	if not are_chunks_ready_around(position, radius):
		return false
	return ensure_collision_ready_at(position, 1)


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
		if _has_terrain_collision_server_shape(data):
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
			var zone_radius := int(zone.get("radius", 2))
			if not is_spawn_zone_ready(zone.position, zone_radius):
				continue
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
