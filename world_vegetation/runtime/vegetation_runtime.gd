extends Node
class_name VegetationRuntime

const VegetationType = preload("res://world_vegetation/types/vegetation_type.gd")
const VegetationRegistry = preload("res://world_vegetation/types/vegetation_registry.gd")
const VegetationChunk = preload("res://world_vegetation/runtime/vegetation_chunk.gd")
const VegetationSpatialGrid = preload("res://world_vegetation/runtime/vegetation_spatial_grid.gd")
const VegetationRendererRS = preload("res://world_vegetation/runtime/vegetation_renderer_rs.gd")

signal vegetation_ready_changed(ready: bool)
signal chunk_rebuilt(chunk_coord: Vector2i)
signal terrain_changed(bounds: AABB)

const DEFAULT_CHUNK_SIZE := 31
const TERRAIN_CHUNK_STRIDE := 31.0
const GRASS_CARD_HALF_WIDTH := 0.055
const GRASS_CARD_HEIGHT := 0.48
const GRASS_CARD_PRIMITIVES := 2
const MAX_RENDER_CLUSTER_DEFER_FRAMES := 30
const RENDER_CLUSTER_RETRY_FRAMES := 4

var registry: VegetationRegistry
var terrain_manager: Node = null
var renderer: VegetationRendererRS
var spatial_grid: VegetationSpatialGrid = VegetationSpatialGrid.new()
var chunks: Dictionary = {}
var native_chunk_builder: Object = null
var native_spatial_grid: Object = null

var world_seed: int = 12345
var chunk_size: int = DEFAULT_CHUNK_SIZE
var initial_stream_radius_chunks: int = 10
var active_stream_radius_chunks: int = 10
var profile: StringName = &"grass_field"
var use_mock_terrain: bool = false
var auto_spawn_benchmark_content: bool = true
var enable_streaming: bool = true
var render_enabled: bool = true
var focus_position: Vector3 = Vector3.ZERO
var mock_terrain_base_height: float = 0.0
var mock_terrain_wave_amplitude: float = 1.5
var mock_terrain_wave_frequency: float = 0.05
var mock_terrain_carves: Array[Dictionary] = []
var max_rebuilds_per_frame: int = 16
var max_generations_per_frame: int = 24
var max_render_cluster_rebuilds_per_frame: int = 8
var initial_generation_budget_ms: float = 6.0
var stream_generation_budget_ms: float = 1.5
var initial_rebuild_budget_ms: float = 5.0
var stream_rebuild_budget_ms: float = 1.5
var initial_render_upload_budget_ms: float = 5.0
var stream_render_upload_budget_ms: float = 1.5
var use_native_chunk_builder: bool = true
var use_native_spatial_grid: bool = true
var use_grass_source_meshes: bool = true
var allow_debug_grass_cards: bool = false
var road_clearance: float = 2.0
var individual_tree_radius_chunks: int = 0
var render_cluster_size_chunks: int = 4
var batch_individual_records_in_render_clusters: bool = true
var use_instanced_render_clusters: bool = false
var use_instanced_grass_clusters: bool = false
var individual_record_radius_chunks: int = 0
var camera_cull_chunk_mesh_records: bool = true
var camera_cull_instanced_records: bool = true
var camera_full_detail_radius_chunks: int = 3
var camera_cone_margin_degrees: float = 10.0
var zoom_cone_margin_degrees: float = 5.0
var camera_prefetch_margin_degrees: float = 12.0
var zoom_prefetch_margin_degrees: float = 8.0
var instanced_record_cone_margin_degrees: float = 6.0
var instanced_record_prefetch_margin_degrees: float = 5.0
var zoom_instanced_record_cone_margin_degrees: float = 4.0
var zoom_instanced_record_prefetch_margin_degrees: float = 3.0
var screen_occlusion_cull_tree_records: bool = true
var screen_occlusion_grid_columns: int = 96
var screen_occlusion_grid_rows: int = 54
var visibility_hide_grace_frames: int = 180
var zoom_fov_threshold_degrees: float = 42.0
var max_visibility_sync_chunks_per_frame: int = 96
var hidden_instance_grace_frames: int = 180
var max_hidden_instance_frees_per_frame: int = 16
var max_hidden_instance_eviction_chunks_per_frame: int = 16
var grass_scale_multiplier: float = 1.0
var grass_y_offset: float = 0.0
var tree_y_offset: float = 0.0
var rock_scale_multiplier: float = 1.0
var rock_y_offset: float = 0.0
var has_render_camera: bool = false
var render_camera_position: Vector3 = Vector3.ZERO
var render_camera_forward: Vector3 = Vector3.FORWARD
var render_camera_right: Vector3 = Vector3.RIGHT
var render_camera_up: Vector3 = Vector3.UP
var render_camera_fov_degrees: float = 75.0
var render_camera_aspect: float = 1.777778
var _has_visibility_request_state: bool = false
var _last_visibility_request_position: Vector3 = Vector3.ZERO
var _last_visibility_request_forward: Vector3 = Vector3.FORWARD
var _last_visibility_request_fov_degrees: float = 75.0

var _bootstrapped: bool = false
var _next_record_id: int = 1
var _pending_generation_queue: Array[Vector2i] = []
var _pending_generation_reasons: Dictionary = {}
var _pending_generation_retry_after_frames: Dictionary = {}
var _pending_rebuilds: Array[Vector2i] = []
var _pending_render_cluster_rebuilds: Array[Vector2i] = []
var _pending_render_cluster_lookup: Dictionary = {}
var _pending_render_cluster_retry_after_frames: Dictionary = {}
var _render_cluster_first_request_frames: Dictionary = {}
var _pending_visibility_sync_chunks: Array[Vector2i] = []
var _pending_visibility_sync_lookup: Dictionary = {}
var _chunk_visibility_class: Dictionary = {}
var _chunk_last_visible_frame: Dictionary = {}
var _render_cluster_surface_counts: Dictionary = {}
var _render_cluster_chunk_surface_counts: Dictionary = {}
var _render_cluster_instanced_keys: Dictionary = {}
var _render_cluster_instanced_counts: Dictionary = {}
var _render_cluster_instanced_batch_counts: Dictionary = {}
var _render_cluster_instanced_batch_counts_by_kind: Dictionary = {}
var _render_cluster_instanced_instance_counts_by_kind: Dictionary = {}
var _render_cluster_instanced_max_instances_by_kind: Dictionary = {}
var _render_cluster_camera_culled_counts_by_kind: Dictionary = {}
var _render_cluster_visibility: Dictionary = {}
var _regrowth_chunk_coords: Dictionary = {}
var _last_ready_state: bool = false
var _last_rebuild_time_ms: float = 0.0
var _last_support_refresh_time_ms: float = 0.0
var _last_generation_time_ms: float = 0.0
var _last_native_grass_build_time_ms: float = 0.0
var _last_visibility_sync_time_ms: float = 0.0
var _last_visibility_sync_chunk_count: int = 0
var _last_visibility_sync_queued_count: int = 0
var _last_visibility_sync_changed_count: int = 0
var _hidden_instance_count: int = 0
var _last_hidden_instance_eviction_count: int = 0
var _last_hidden_instance_eviction_ms: float = 0.0
var _hidden_instance_eviction_cursor: int = 0
var _last_focus_chunk: Vector2i = Vector2i(2147483647, 2147483647)
var _last_support_refresh_count: int = 0
var _terrain_streaming_ready: bool = false
var _initial_stream_complete: bool = false
var _last_generation_processed_count: int = 0
var _last_rebuild_processed_count: int = 0
var _last_render_cluster_rebuild_processed_count: int = 0
var _type_mesh_primitive_count_cache: Dictionary = {}
var _type_visual_bounds_cache: Dictionary = {}
var _types_by_category_cache: Dictionary = {}
var _native_grass_type_colors_cache: Dictionary = {}
var _source_surface_arrays_cache: Dictionary = {}
var _prepared_source_surface_cache: Dictionary = {}

const VISIBILITY_CLASS_NONE := 0
const VISIBILITY_CLASS_FULL := 1
const VISIBILITY_CLASS_CONE := 2
const RECORD_HIDDEN_FRAME_KEY := "render_hidden_frame"
const MULTIMESH_FLOATS_PER_INSTANCE_3D := 12


func _ready() -> void:
	set_process(true)


func configure(options: Dictionary) -> void:
	if options.has("registry"):
		registry = options.get("registry", registry) as VegetationRegistry
		_type_mesh_primitive_count_cache.clear()
		_type_visual_bounds_cache.clear()
		_types_by_category_cache.clear()
		_native_grass_type_colors_cache.clear()
		_source_surface_arrays_cache.clear()
		_prepared_source_surface_cache.clear()
	if options.has("terrain_manager"):
		terrain_manager = options.get("terrain_manager", terrain_manager)
		if _bootstrapped:
			_connect_terrain_manager()
	if options.has("world_seed"):
		world_seed = int(options.get("world_seed", world_seed))
	if options.has("chunk_size"):
		chunk_size = maxi(1, int(options.get("chunk_size", chunk_size)))
	if options.has("initial_stream_radius_chunks"):
		initial_stream_radius_chunks = maxi(0, int(options.get("initial_stream_radius_chunks", initial_stream_radius_chunks)))
	if options.has("active_stream_radius_chunks"):
		active_stream_radius_chunks = maxi(0, int(options.get("active_stream_radius_chunks", active_stream_radius_chunks)))
	if options.has("profile"):
		profile = StringName(str(options.get("profile", profile)))
	if options.has("use_mock_terrain"):
		use_mock_terrain = bool(options.get("use_mock_terrain", use_mock_terrain))
	if options.has("auto_spawn_benchmark_content"):
		auto_spawn_benchmark_content = bool(options.get("auto_spawn_benchmark_content", auto_spawn_benchmark_content))
	if options.has("enable_streaming"):
		enable_streaming = bool(options.get("enable_streaming", enable_streaming))
	if options.has("render_enabled"):
		render_enabled = bool(options.get("render_enabled", render_enabled))
	if options.has("focus_position"):
		focus_position = options.get("focus_position", focus_position)
	if options.has("mock_terrain_base_height"):
		mock_terrain_base_height = float(options.get("mock_terrain_base_height", mock_terrain_base_height))
	if options.has("mock_terrain_wave_amplitude"):
		mock_terrain_wave_amplitude = float(options.get("mock_terrain_wave_amplitude", mock_terrain_wave_amplitude))
	if options.has("mock_terrain_wave_frequency"):
		mock_terrain_wave_frequency = float(options.get("mock_terrain_wave_frequency", mock_terrain_wave_frequency))
	if options.has("max_rebuilds_per_frame"):
		max_rebuilds_per_frame = maxi(1, int(options.get("max_rebuilds_per_frame", max_rebuilds_per_frame)))
	if options.has("max_generations_per_frame"):
		max_generations_per_frame = maxi(1, int(options.get("max_generations_per_frame", max_generations_per_frame)))
	if options.has("max_render_cluster_rebuilds_per_frame"):
		max_render_cluster_rebuilds_per_frame = maxi(1, int(options.get("max_render_cluster_rebuilds_per_frame", max_render_cluster_rebuilds_per_frame)))
	if options.has("initial_generation_budget_ms"):
		initial_generation_budget_ms = maxf(0.0, float(options.get("initial_generation_budget_ms", initial_generation_budget_ms)))
	if options.has("stream_generation_budget_ms"):
		stream_generation_budget_ms = maxf(0.0, float(options.get("stream_generation_budget_ms", stream_generation_budget_ms)))
	if options.has("initial_rebuild_budget_ms"):
		initial_rebuild_budget_ms = maxf(0.0, float(options.get("initial_rebuild_budget_ms", initial_rebuild_budget_ms)))
	if options.has("stream_rebuild_budget_ms"):
		stream_rebuild_budget_ms = maxf(0.0, float(options.get("stream_rebuild_budget_ms", stream_rebuild_budget_ms)))
	if options.has("initial_render_upload_budget_ms"):
		initial_render_upload_budget_ms = maxf(0.0, float(options.get("initial_render_upload_budget_ms", initial_render_upload_budget_ms)))
	if options.has("stream_render_upload_budget_ms"):
		stream_render_upload_budget_ms = maxf(0.0, float(options.get("stream_render_upload_budget_ms", stream_render_upload_budget_ms)))
	if options.has("use_native_chunk_builder"):
		use_native_chunk_builder = bool(options.get("use_native_chunk_builder", use_native_chunk_builder))
	if options.has("use_native_spatial_grid"):
		use_native_spatial_grid = bool(options.get("use_native_spatial_grid", use_native_spatial_grid))
	if options.has("use_grass_source_meshes"):
		use_grass_source_meshes = bool(options.get("use_grass_source_meshes", use_grass_source_meshes))
	if options.has("allow_debug_grass_cards"):
		allow_debug_grass_cards = bool(options.get("allow_debug_grass_cards", allow_debug_grass_cards))
	if options.has("road_clearance"):
		road_clearance = maxf(0.0, float(options.get("road_clearance", road_clearance)))
	if options.has("individual_tree_radius_chunks"):
		individual_tree_radius_chunks = maxi(0, int(options.get("individual_tree_radius_chunks", individual_tree_radius_chunks)))
	if options.has("render_cluster_size_chunks"):
		render_cluster_size_chunks = maxi(1, int(options.get("render_cluster_size_chunks", render_cluster_size_chunks)))
	if options.has("batch_individual_records_in_render_clusters"):
		batch_individual_records_in_render_clusters = bool(options.get("batch_individual_records_in_render_clusters", batch_individual_records_in_render_clusters))
	if options.has("use_instanced_render_clusters"):
		use_instanced_render_clusters = bool(options.get("use_instanced_render_clusters", use_instanced_render_clusters))
	if options.has("use_instanced_grass_clusters"):
		use_instanced_grass_clusters = bool(options.get("use_instanced_grass_clusters", use_instanced_grass_clusters))
	if options.has("individual_record_radius_chunks"):
		individual_record_radius_chunks = maxi(0, int(options.get("individual_record_radius_chunks", individual_record_radius_chunks)))
	if options.has("camera_cull_chunk_mesh_records"):
		camera_cull_chunk_mesh_records = bool(options.get("camera_cull_chunk_mesh_records", camera_cull_chunk_mesh_records))
	if options.has("camera_cull_instanced_records"):
		camera_cull_instanced_records = bool(options.get("camera_cull_instanced_records", camera_cull_instanced_records))
	if options.has("camera_full_detail_radius_chunks"):
		camera_full_detail_radius_chunks = maxi(0, int(options.get("camera_full_detail_radius_chunks", camera_full_detail_radius_chunks)))
	if options.has("camera_cone_margin_degrees"):
		camera_cone_margin_degrees = clampf(float(options.get("camera_cone_margin_degrees", camera_cone_margin_degrees)), 0.0, 90.0)
	if options.has("zoom_cone_margin_degrees"):
		zoom_cone_margin_degrees = clampf(float(options.get("zoom_cone_margin_degrees", zoom_cone_margin_degrees)), 0.0, 90.0)
	if options.has("camera_prefetch_margin_degrees"):
		camera_prefetch_margin_degrees = clampf(float(options.get("camera_prefetch_margin_degrees", camera_prefetch_margin_degrees)), 0.0, 120.0)
	if options.has("zoom_prefetch_margin_degrees"):
		zoom_prefetch_margin_degrees = clampf(float(options.get("zoom_prefetch_margin_degrees", zoom_prefetch_margin_degrees)), 0.0, 120.0)
	if options.has("instanced_record_cone_margin_degrees"):
		instanced_record_cone_margin_degrees = clampf(float(options.get("instanced_record_cone_margin_degrees", instanced_record_cone_margin_degrees)), 0.0, 90.0)
	if options.has("instanced_record_prefetch_margin_degrees"):
		instanced_record_prefetch_margin_degrees = clampf(float(options.get("instanced_record_prefetch_margin_degrees", instanced_record_prefetch_margin_degrees)), 0.0, 90.0)
	if options.has("zoom_instanced_record_cone_margin_degrees"):
		zoom_instanced_record_cone_margin_degrees = clampf(float(options.get("zoom_instanced_record_cone_margin_degrees", zoom_instanced_record_cone_margin_degrees)), 0.0, 90.0)
	if options.has("zoom_instanced_record_prefetch_margin_degrees"):
		zoom_instanced_record_prefetch_margin_degrees = clampf(float(options.get("zoom_instanced_record_prefetch_margin_degrees", zoom_instanced_record_prefetch_margin_degrees)), 0.0, 90.0)
	if options.has("screen_occlusion_cull_tree_records"):
		screen_occlusion_cull_tree_records = bool(options.get("screen_occlusion_cull_tree_records", screen_occlusion_cull_tree_records))
	if options.has("screen_occlusion_grid_columns"):
		screen_occlusion_grid_columns = clampi(int(options.get("screen_occlusion_grid_columns", screen_occlusion_grid_columns)), 16, 256)
	if options.has("screen_occlusion_grid_rows"):
		screen_occlusion_grid_rows = clampi(int(options.get("screen_occlusion_grid_rows", screen_occlusion_grid_rows)), 9, 144)
	if options.has("visibility_hide_grace_frames"):
		visibility_hide_grace_frames = maxi(0, int(options.get("visibility_hide_grace_frames", visibility_hide_grace_frames)))
	if options.has("zoom_fov_threshold_degrees"):
		zoom_fov_threshold_degrees = clampf(float(options.get("zoom_fov_threshold_degrees", zoom_fov_threshold_degrees)), 1.0, 90.0)
	if options.has("max_visibility_sync_chunks_per_frame"):
		max_visibility_sync_chunks_per_frame = maxi(1, int(options.get("max_visibility_sync_chunks_per_frame", max_visibility_sync_chunks_per_frame)))
	if options.has("hidden_instance_grace_frames"):
		hidden_instance_grace_frames = maxi(0, int(options.get("hidden_instance_grace_frames", hidden_instance_grace_frames)))
	if options.has("max_hidden_instance_frees_per_frame"):
		max_hidden_instance_frees_per_frame = maxi(1, int(options.get("max_hidden_instance_frees_per_frame", max_hidden_instance_frees_per_frame)))
	if options.has("max_hidden_instance_eviction_chunks_per_frame"):
		max_hidden_instance_eviction_chunks_per_frame = maxi(1, int(options.get("max_hidden_instance_eviction_chunks_per_frame", max_hidden_instance_eviction_chunks_per_frame)))
	if options.has("grass_scale_multiplier"):
		grass_scale_multiplier = maxf(0.001, float(options.get("grass_scale_multiplier", grass_scale_multiplier)))
	if options.has("grass_y_offset"):
		grass_y_offset = float(options.get("grass_y_offset", grass_y_offset))
	if options.has("tree_y_offset"):
		tree_y_offset = float(options.get("tree_y_offset", tree_y_offset))
	if options.has("rock_scale_multiplier"):
		rock_scale_multiplier = maxf(0.001, float(options.get("rock_scale_multiplier", rock_scale_multiplier)))
	if options.has("rock_y_offset"):
		rock_y_offset = float(options.get("rock_y_offset", rock_y_offset))


func bootstrap() -> void:
	if _bootstrapped:
		return
	if registry == null:
		registry = VegetationRegistry.create_default() as VegetationRegistry
		_type_mesh_primitive_count_cache.clear()
	if render_enabled and renderer == null:
		renderer = VegetationRendererRS.new()
		renderer.name = "VegetationRendererRS"
		add_child(renderer)
	_ensure_native_backends()
	_bind_renderer_world()
	_connect_terrain_manager()
	_bootstrapped = true
	# Do not seed against an unready terrain manager. Early streaming can lock in
	# bad support heights before the real surface data exists.
	_terrain_streaming_ready = use_mock_terrain or _is_terrain_ready_for_streaming()
	if enable_streaming and _terrain_streaming_ready:
		_refresh_streaming_request()
	if _terrain_streaming_ready and auto_spawn_benchmark_content:
		_seed_initial_chunks()
	_update_ready_state()


func _ensure_native_backends() -> void:
	if use_native_chunk_builder and native_chunk_builder == null and ClassDB.class_exists("VegetationChunkBuilder"):
		native_chunk_builder = ClassDB.instantiate("VegetationChunkBuilder")
	if use_native_spatial_grid and native_spatial_grid == null and ClassDB.class_exists("VegetationSpatialGridNative"):
		native_spatial_grid = ClassDB.instantiate("VegetationSpatialGridNative")


func is_vegetation_ready() -> bool:
	if not _terrain_streaming_ready and not use_mock_terrain:
		return false
	return _pending_generation_queue.is_empty() \
		and _pending_rebuilds.is_empty() \
		and _pending_render_cluster_rebuilds.is_empty() \
		and _pending_visibility_sync_chunks.is_empty() \
		and not _has_dirty_chunks()


func get_pending_chunks_count() -> int:
	return _pending_generation_queue.size() \
		+ _pending_rebuilds.size() \
		+ _pending_render_cluster_rebuilds.size() \
		+ _pending_visibility_sync_chunks.size()


func clear_all_data(immediate_free: bool = false) -> void:
	_pending_rebuilds.clear()
	_pending_generation_queue.clear()
	_pending_generation_reasons.clear()
	_pending_generation_retry_after_frames.clear()
	_regrowth_chunk_coords.clear()
	_pending_render_cluster_rebuilds.clear()
	_pending_render_cluster_lookup.clear()
	_pending_render_cluster_retry_after_frames.clear()
	_render_cluster_first_request_frames.clear()
	_pending_visibility_sync_chunks.clear()
	_pending_visibility_sync_lookup.clear()
	_chunk_visibility_class.clear()
	_chunk_last_visible_frame.clear()
	_has_visibility_request_state = false
	_hidden_instance_count = 0
	_last_hidden_instance_eviction_count = 0
	_last_hidden_instance_eviction_ms = 0.0
	_hidden_instance_eviction_cursor = 0
	_initial_stream_complete = false
	_render_cluster_surface_counts.clear()
	_render_cluster_chunk_surface_counts.clear()
	_render_cluster_instanced_keys.clear()
	_render_cluster_instanced_counts.clear()
	_render_cluster_instanced_batch_counts.clear()
	_render_cluster_instanced_batch_counts_by_kind.clear()
	_render_cluster_instanced_instance_counts_by_kind.clear()
	_render_cluster_instanced_max_instances_by_kind.clear()
	_render_cluster_camera_culled_counts_by_kind.clear()
	_render_cluster_visibility.clear()
	if native_spatial_grid != null:
		native_spatial_grid.clear()
	for chunk_coord_variant in chunks.keys():
		var chunk: VegetationChunk = chunks[chunk_coord_variant] as VegetationChunk
		_destroy_chunk_render_state(chunk, immediate_free)
	chunks.clear()
	spatial_grid.clear()
	mock_terrain_carves.clear()
	_next_record_id = 1
	_last_focus_chunk = Vector2i(2147483647, 2147483647)
	_terrain_streaming_ready = false
	if renderer:
		renderer.clear_all(immediate_free)
	_update_ready_state()


func clear_for_shutdown() -> void:
	clear_all_data(true)
	_bootstrapped = false
	set_process(false)


func get_telemetry_snapshot() -> Dictionary:
	var live_chunk_count := 0
	var dirty_chunk_count := 0
	var tree_chunk_count := 0
	var grass_chunk_count := 0
	var rock_chunk_count := 0
	var total_grass_cells := 0
	var total_tree_records := 0
	var total_bush_records := 0
	var total_rock_records := 0
	var global_tree_render_instances := 0
	var global_grass_render_instances := 0
	var global_rock_render_instances := 0
	var global_bush_render_instances := 0
	var global_tree_render_batches := 0
	var global_grass_render_batches := 0
	var global_rock_render_batches := 0
	var global_bush_render_batches := 0
	var global_chunk_mesh_render_batches := 0
	var global_built_chunk_mesh_render_batches := 0
	var global_instanced_render_batches := 0
	var global_built_instanced_render_batches := 0
	var global_visible_render_cluster_count := 0
	var global_built_render_cluster_count := 0
	var global_instanced_render_instances := 0
	var global_built_instanced_render_instances := 0
	var global_tree_render_chunk_payloads := 0
	var global_grass_render_chunk_payloads := 0
	var global_rock_render_chunk_payloads := 0
	var global_bush_render_chunk_payloads := 0
	var global_chunked_tree_render_instances := 0
	var global_chunked_bush_render_instances := 0
	var global_chunked_rock_render_instances := 0
	var global_grass_instanced_render_batches := 0
	var global_tree_instanced_render_batches := 0
	var global_bush_instanced_render_batches := 0
	var global_rock_instanced_render_batches := 0
	var global_grass_instanced_render_instances := 0
	var global_tree_instanced_render_instances := 0
	var global_bush_instanced_render_instances := 0
	var global_rock_instanced_render_instances := 0
	var global_tree_camera_culled_records := 0
	var global_bush_camera_culled_records := 0
	var global_rock_camera_culled_records := 0
	var tree_mesh_primitives := 0
	var grass_mesh_primitives := 0
	var bush_mesh_primitives := 0
	var rock_mesh_primitives := 0
	var global_tree_estimated_primitives := 0
	var global_grass_estimated_primitives := 0
	var global_bush_estimated_primitives := 0
	var global_rock_estimated_primitives := 0
	var global_grass_max_batch_instances := 0
	var global_tree_max_batch_instances := 0
	var global_bush_max_batch_instances := 0
	var global_rock_max_batch_instances := 0
	var support_points_total := 0
	var renderer_stats: Dictionary = renderer.get_stats() if renderer else {}
	for cluster_coord_variant in _render_cluster_surface_counts.keys():
		var cluster_coord: Vector2i = cluster_coord_variant
		var surface_count := int(_render_cluster_surface_counts[cluster_coord_variant])
		var instanced_batch_count := int(_render_cluster_instanced_batch_counts.get(cluster_coord, 0))
		var chunk_surface_count := int(_render_cluster_chunk_surface_counts.get(cluster_coord, maxi(0, surface_count - instanced_batch_count)))
		var instanced_instance_count := int(_render_cluster_instanced_counts.get(cluster_coord, 0))
		global_built_render_cluster_count += 1
		global_built_chunk_mesh_render_batches += chunk_surface_count
		global_built_instanced_render_batches += instanced_batch_count
		global_built_instanced_render_instances += instanced_instance_count
		if bool(_render_cluster_visibility.get(cluster_coord, true)):
			global_visible_render_cluster_count += 1
			global_chunk_mesh_render_batches += chunk_surface_count
			global_instanced_render_batches += instanced_batch_count
			global_instanced_render_instances += instanced_instance_count
			var batch_counts_by_kind: Dictionary = _render_cluster_instanced_batch_counts_by_kind.get(cluster_coord, {})
			var instance_counts_by_kind: Dictionary = _render_cluster_instanced_instance_counts_by_kind.get(cluster_coord, {})
			var max_instances_by_kind: Dictionary = _render_cluster_instanced_max_instances_by_kind.get(cluster_coord, {})
			var grass_instanced_batches := int(batch_counts_by_kind.get("grass", 0))
			var tree_instanced_batches := int(batch_counts_by_kind.get("tree", 0))
			var bush_instanced_batches := int(batch_counts_by_kind.get("bush", 0))
			var rock_instanced_batches := int(batch_counts_by_kind.get("rock", 0))
			global_grass_instanced_render_batches += grass_instanced_batches
			global_tree_instanced_render_batches += tree_instanced_batches
			global_bush_instanced_render_batches += bush_instanced_batches
			global_rock_instanced_render_batches += rock_instanced_batches
			global_grass_render_batches += grass_instanced_batches
			global_tree_render_batches += tree_instanced_batches
			global_bush_render_batches += bush_instanced_batches
			global_rock_render_batches += rock_instanced_batches
			global_grass_instanced_render_instances += int(instance_counts_by_kind.get("grass", 0))
			global_tree_instanced_render_instances += int(instance_counts_by_kind.get("tree", 0))
			global_bush_instanced_render_instances += int(instance_counts_by_kind.get("bush", 0))
			global_rock_instanced_render_instances += int(instance_counts_by_kind.get("rock", 0))
			global_grass_max_batch_instances = maxi(global_grass_max_batch_instances, int(max_instances_by_kind.get("grass", 0)))
			global_tree_max_batch_instances = maxi(global_tree_max_batch_instances, int(max_instances_by_kind.get("tree", 0)))
			global_bush_max_batch_instances = maxi(global_bush_max_batch_instances, int(max_instances_by_kind.get("bush", 0)))
			global_rock_max_batch_instances = maxi(global_rock_max_batch_instances, int(max_instances_by_kind.get("rock", 0)))
			var camera_culled_counts_by_kind: Dictionary = _render_cluster_camera_culled_counts_by_kind.get(cluster_coord, {})
			global_tree_camera_culled_records += int(camera_culled_counts_by_kind.get("tree", 0))
			global_bush_camera_culled_records += int(camera_culled_counts_by_kind.get("bush", 0))
			global_rock_camera_culled_records += int(camera_culled_counts_by_kind.get("rock", 0))
	for chunk_variant in chunks.values():
		var chunk: VegetationChunk = chunk_variant as VegetationChunk
		if chunk == null:
			continue
		var cluster_coord := _render_cluster_coord_for_chunk(chunk.chunk_coord)
		var cluster_visible := bool(_render_cluster_visibility.get(cluster_coord, true))
		var visible_grass_cell_count := chunk.visible_grass_cell_count if cluster_visible else 0
		var visible_chunked_tree_count := chunk.visible_chunked_tree_record_count if cluster_visible else 0
		var visible_chunked_bush_count := chunk.visible_chunked_bush_record_count if cluster_visible else 0
		var visible_chunked_rock_count := chunk.visible_chunked_rock_record_count if cluster_visible else 0
		if chunk.is_live():
			live_chunk_count += 1
		if chunk.has_pending_rebuild():
			dirty_chunk_count += 1
		total_grass_cells += chunk.get_grass_cell_count()
		total_tree_records += chunk.get_tree_record_count()
		total_bush_records += chunk.get_bush_record_count()
		total_rock_records += chunk.get_rock_record_count()
		if chunk.get_tree_record_count() > 0:
			tree_chunk_count += 1
		if chunk.get_grass_cell_count() > 0:
			grass_chunk_count += 1
		if chunk.get_rock_record_count() > 0:
			rock_chunk_count += 1
		global_grass_render_instances += visible_grass_cell_count
		global_tree_render_instances += chunk.visible_individual_tree_record_count + visible_chunked_tree_count
		global_bush_render_instances += chunk.visible_individual_bush_record_count + visible_chunked_bush_count
		global_rock_render_instances += chunk.visible_individual_rock_record_count + visible_chunked_rock_count
		global_chunked_tree_render_instances += visible_chunked_tree_count
		global_chunked_bush_render_instances += visible_chunked_bush_count
		global_chunked_rock_render_instances += visible_chunked_rock_count
		grass_mesh_primitives = maxi(grass_mesh_primitives, chunk.grass_mesh_primitive_count)
		tree_mesh_primitives = maxi(tree_mesh_primitives, chunk.tree_mesh_primitive_count)
		bush_mesh_primitives = maxi(bush_mesh_primitives, chunk.bush_mesh_primitive_count)
		rock_mesh_primitives = maxi(rock_mesh_primitives, chunk.rock_mesh_primitive_count)
		if cluster_visible:
			global_grass_estimated_primitives += chunk.grass_estimated_primitive_count
		global_tree_estimated_primitives += chunk.individual_tree_estimated_primitive_count
		global_bush_estimated_primitives += chunk.individual_bush_estimated_primitive_count
		global_rock_estimated_primitives += chunk.individual_rock_estimated_primitive_count
		if cluster_visible:
			global_tree_estimated_primitives += chunk.chunked_tree_estimated_primitive_count
			global_bush_estimated_primitives += chunk.chunked_bush_estimated_primitive_count
			global_rock_estimated_primitives += chunk.chunked_rock_estimated_primitive_count
		support_points_total += chunk.support_points_total
		var grass_chunk_mesh_visible := visible_grass_cell_count > 0 and not use_instanced_grass_clusters
		if grass_chunk_mesh_visible:
			global_grass_max_batch_instances = maxi(global_grass_max_batch_instances, visible_grass_cell_count)
		if grass_chunk_mesh_visible:
			global_grass_render_batches += 1
			global_grass_render_chunk_payloads += 1
		if chunk.visible_individual_tree_record_count > 0:
			global_tree_render_batches += chunk.visible_individual_tree_record_count
			global_tree_max_batch_instances = maxi(global_tree_max_batch_instances, 1)
			global_tree_render_chunk_payloads += 1
		if visible_chunked_tree_count > 0:
			global_tree_render_chunk_payloads += 1
		if chunk.visible_individual_bush_record_count > 0:
			global_bush_render_batches += chunk.visible_individual_bush_record_count
			global_bush_max_batch_instances = maxi(global_bush_max_batch_instances, 1)
			global_bush_render_chunk_payloads += 1
		if visible_chunked_bush_count > 0:
			global_bush_render_chunk_payloads += 1
		if chunk.visible_individual_rock_record_count > 0:
			global_rock_render_batches += chunk.visible_individual_rock_record_count
			global_rock_max_batch_instances = maxi(global_rock_max_batch_instances, 1)
			global_rock_render_chunk_payloads += 1
		if visible_chunked_rock_count > 0:
			global_rock_render_chunk_payloads += 1
	var global_render_batch_count := global_tree_render_batches \
		+ global_grass_render_batches \
		+ global_bush_render_batches \
		+ global_rock_render_batches
	var pending_chunk_count := get_pending_chunks_count()
	var render_dirty_kinds: Array[String] = []
	if dirty_chunk_count > 0:
		render_dirty_kinds.append("vegetation")
	return {
		"profile": String(profile),
		"world_seed": world_seed,
		"chunk_size": chunk_size,
		"chunk_count": chunks.size(),
		"live_chunk_count": live_chunk_count,
		"visible_chunk_count": live_chunk_count,
		"dirty_chunk_count": dirty_chunk_count,
		"pending_generation_count": _pending_generation_queue.size(),
		"pending_rebuild_count": _pending_rebuilds.size(),
		"pending_render_cluster_rebuild_count": _pending_render_cluster_rebuilds.size(),
		"pending_visibility_sync_count": _pending_visibility_sync_chunks.size(),
		"pending_chunk_count": pending_chunk_count,
		"pending_chunks_count": pending_chunk_count,
		"pending_chunks": pending_chunk_count,
		"regrowth_chunk_count": _regrowth_chunk_coords.size(),
		"vegetation_ready": is_vegetation_ready(),
		"render_enabled": render_enabled,
		"vegetation_render_enabled": render_enabled,
		"tree_chunk_count": tree_chunk_count,
		"grass_chunk_count": grass_chunk_count,
		"rock_chunk_count": rock_chunk_count,
		"grass_cell_count": total_grass_cells,
		"tree_record_count": total_tree_records,
		"bush_record_count": total_bush_records,
		"rock_record_count": total_rock_records,
		"global_render_batch_count": global_render_batch_count,
		"global_chunk_mesh_render_batch_count": global_chunk_mesh_render_batches,
		"global_built_chunk_mesh_render_batch_count": global_built_chunk_mesh_render_batches,
		"global_instanced_render_batch_count": global_instanced_render_batches,
		"global_built_instanced_render_batch_count": global_built_instanced_render_batches,
		"global_visible_render_cluster_count": global_visible_render_cluster_count,
		"global_built_render_cluster_count": global_built_render_cluster_count,
		"global_instanced_render_instances": global_instanced_render_instances,
		"global_built_instanced_render_instances": global_built_instanced_render_instances,
		"global_tree_render_instances": global_tree_render_instances,
		"global_grass_render_instances": global_grass_render_instances,
		"global_rock_render_instances": global_rock_render_instances,
		"global_bush_render_instances": global_bush_render_instances,
		"global_chunked_tree_render_instances": global_chunked_tree_render_instances,
		"global_chunked_bush_render_instances": global_chunked_bush_render_instances,
		"global_chunked_rock_render_instances": global_chunked_rock_render_instances,
		"global_grass_instanced_render_batch_count": global_grass_instanced_render_batches,
		"global_tree_instanced_render_batch_count": global_tree_instanced_render_batches,
		"global_bush_instanced_render_batch_count": global_bush_instanced_render_batches,
		"global_rock_instanced_render_batch_count": global_rock_instanced_render_batches,
		"global_grass_instanced_render_instances": global_grass_instanced_render_instances,
		"global_tree_instanced_render_instances": global_tree_instanced_render_instances,
		"global_bush_instanced_render_instances": global_bush_instanced_render_instances,
		"global_rock_instanced_render_instances": global_rock_instanced_render_instances,
		"global_tree_camera_culled_records": global_tree_camera_culled_records,
		"global_bush_camera_culled_records": global_bush_camera_culled_records,
		"global_rock_camera_culled_records": global_rock_camera_culled_records,
		"global_tree_render_batch_count": global_tree_render_batches,
		"global_grass_render_batch_count": global_grass_render_batches,
		"global_rock_render_batch_count": global_rock_render_batches,
		"global_bush_render_batch_count": global_bush_render_batches,
		"global_tree_render_chunk_payloads": global_tree_render_chunk_payloads,
		"global_grass_render_chunk_payloads": global_grass_render_chunk_payloads,
		"global_rock_render_chunk_payloads": global_rock_render_chunk_payloads,
		"global_bush_render_chunk_payloads": global_bush_render_chunk_payloads,
		"global_render_dirty_kinds": render_dirty_kinds,
		"last_global_render_sync_ms": _last_rebuild_time_ms,
		"last_global_render_collect_ms": _last_support_refresh_time_ms,
		"last_global_render_pack_ms": _last_generation_time_ms,
		"last_global_render_sync_kind": "vegetation" if dirty_chunk_count > 0 else "",
		"last_global_render_sync_chunk_count": dirty_chunk_count,
		"last_global_render_candidate_chunk_count": chunks.size(),
		"world_map_vegetation_render_profile_enabled": true,
		"world_map_vegetation_render_profile_active": not String(profile).is_empty(),
		"world_map_vegetation_render_cluster_size": render_cluster_size_chunks,
		"world_map_vegetation_grass_render_cluster_size": render_cluster_size_chunks,
		"effective_vegetation_render_cluster_size": render_cluster_size_chunks,
		"effective_vegetation_grass_render_cluster_size": render_cluster_size_chunks,
		"vegetation_render_cluster_size": render_cluster_size_chunks,
		"vegetation_grass_render_cluster_size": render_cluster_size_chunks,
		"vegetation_coverage_radius_world": float(active_stream_radius_chunks * chunk_size),
		"vegetation_coverage_render_distance_equivalent": float(active_stream_radius_chunks * chunk_size) / 31.0,
		"vegetation_render_lod_bias": 1.0,
		"vegetation_batch_individual_records_in_render_clusters": batch_individual_records_in_render_clusters,
		"vegetation_use_instanced_render_clusters": use_instanced_render_clusters,
		"vegetation_use_instanced_grass_clusters": use_instanced_grass_clusters,
		"vegetation_individual_record_radius_chunks": individual_record_radius_chunks,
		"vegetation_camera_cull_chunk_mesh_records": camera_cull_chunk_mesh_records,
		"vegetation_camera_cull_instanced_records": camera_cull_instanced_records,
		"vegetation_stable_render_membership": not _record_camera_culling_active(),
		"vegetation_global_render_bounds_padding": float(chunk_size),
		"vegetation_global_render_ignore_occlusion_culling": false,
		"vegetation_render_prewarm_frames": 0,
		"vegetation_render_prewarm_mesh_count": 0,
		"vegetation_render_prewarm_active": false,
		"vegetation_render_prewarm_frames_remaining": 0,
		"vegetation_camera_culling_active": has_render_camera,
		"vegetation_camera_full_detail_radius_chunks": camera_full_detail_radius_chunks,
		"vegetation_camera_cone_margin_degrees": camera_cone_margin_degrees,
		"vegetation_zoom_cone_margin_degrees": zoom_cone_margin_degrees,
		"vegetation_camera_prefetch_margin_degrees": camera_prefetch_margin_degrees,
		"vegetation_zoom_prefetch_margin_degrees": zoom_prefetch_margin_degrees,
		"vegetation_instanced_record_cone_margin_degrees": instanced_record_cone_margin_degrees,
		"vegetation_instanced_record_prefetch_margin_degrees": instanced_record_prefetch_margin_degrees,
		"vegetation_zoom_instanced_record_cone_margin_degrees": zoom_instanced_record_cone_margin_degrees,
		"vegetation_zoom_instanced_record_prefetch_margin_degrees": zoom_instanced_record_prefetch_margin_degrees,
		"vegetation_visibility_hide_grace_frames": visibility_hide_grace_frames,
		"vegetation_zoom_fov_threshold_degrees": zoom_fov_threshold_degrees,
		"vegetation_render_camera_fov_degrees": render_camera_fov_degrees,
		"vegetation_max_generations_per_frame": max_generations_per_frame,
		"vegetation_max_rebuilds_per_frame": max_rebuilds_per_frame,
		"vegetation_max_render_cluster_rebuilds_per_frame": max_render_cluster_rebuilds_per_frame,
		"vegetation_initial_generation_budget_ms": initial_generation_budget_ms,
		"vegetation_stream_generation_budget_ms": stream_generation_budget_ms,
		"vegetation_initial_rebuild_budget_ms": initial_rebuild_budget_ms,
		"vegetation_stream_rebuild_budget_ms": stream_rebuild_budget_ms,
		"vegetation_initial_render_upload_budget_ms": initial_render_upload_budget_ms,
		"vegetation_stream_render_upload_budget_ms": stream_render_upload_budget_ms,
		"vegetation_initial_stream_complete": _initial_stream_complete,
		"vegetation_last_generation_processed_count": _last_generation_processed_count,
		"vegetation_last_rebuild_processed_count": _last_rebuild_processed_count,
		"vegetation_last_render_cluster_rebuild_processed_count": _last_render_cluster_rebuild_processed_count,
		"vegetation_pending_visibility_sync_chunks": _pending_visibility_sync_chunks.size(),
		"vegetation_last_visibility_sync_ms": _last_visibility_sync_time_ms,
		"vegetation_last_visibility_sync_chunk_count": _last_visibility_sync_chunk_count,
		"vegetation_last_visibility_sync_queued_count": _last_visibility_sync_queued_count,
		"vegetation_last_visibility_sync_changed_count": _last_visibility_sync_changed_count,
		"vegetation_visibility_class_count": _chunk_visibility_class.size(),
		"vegetation_hidden_instance_count": _hidden_instance_count,
		"vegetation_hidden_instance_grace_frames": hidden_instance_grace_frames,
		"vegetation_last_hidden_instance_eviction_count": _last_hidden_instance_eviction_count,
		"vegetation_last_hidden_instance_eviction_ms": _last_hidden_instance_eviction_ms,
		"tree_mesh_primitives": tree_mesh_primitives,
		"grass_mesh_primitives": grass_mesh_primitives,
		"rock_mesh_primitives": rock_mesh_primitives,
		"bush_mesh_primitives": bush_mesh_primitives,
		"global_tree_render_estimated_primitives": global_tree_estimated_primitives,
		"global_grass_render_estimated_primitives": global_grass_estimated_primitives,
		"global_rock_render_estimated_primitives": global_rock_estimated_primitives,
		"global_bush_render_estimated_primitives": global_bush_estimated_primitives,
		"global_render_estimated_primitives": global_tree_estimated_primitives \
			+ global_grass_estimated_primitives \
			+ global_rock_estimated_primitives \
			+ global_bush_estimated_primitives,
		"global_tree_max_batch_instances": global_tree_max_batch_instances,
		"global_grass_max_batch_instances": global_grass_max_batch_instances,
		"global_rock_max_batch_instances": global_rock_max_batch_instances,
		"global_bush_max_batch_instances": global_bush_max_batch_instances,
		"global_tree_max_batch_estimated_primitives": tree_mesh_primitives * global_tree_max_batch_instances,
		"global_grass_max_batch_estimated_primitives": grass_mesh_primitives * global_grass_max_batch_instances,
		"global_rock_max_batch_estimated_primitives": rock_mesh_primitives * global_rock_max_batch_instances,
		"global_bush_max_batch_estimated_primitives": bush_mesh_primitives * global_bush_max_batch_instances,
		"support_points_total": support_points_total,
		"renderer": renderer_stats,
		"last_rebuild_time_ms": _last_rebuild_time_ms,
		"last_support_refresh_time_ms": _last_support_refresh_time_ms,
		"last_generation_time_ms": _last_generation_time_ms,
		"last_native_grass_build_time_ms": _last_native_grass_build_time_ms,
		"native_chunk_builder_active": native_chunk_builder != null,
		"native_spatial_grid_active": native_spatial_grid != null,
		"use_grass_source_meshes": use_grass_source_meshes,
		"allow_debug_grass_cards": allow_debug_grass_cards,
		"last_focus_chunk": "%d,%d" % [_last_focus_chunk.x, _last_focus_chunk.y],
		"focus_position": focus_position,
		"mock_terrain_carve_count": mock_terrain_carves.size(),
		"bootstrapped": _bootstrapped,
		"terrain_streaming_ready": _terrain_streaming_ready,
		"terrain_manager_valid": terrain_manager != null and is_instance_valid(terrain_manager),
		"ready": is_vegetation_ready()
	}


func set_focus_position(position: Vector3) -> void:
	focus_position = position
	if enable_streaming and _terrain_streaming_ready:
		_refresh_streaming_request()


func set_render_camera(
		position: Vector3,
		forward: Vector3,
		fov_degrees: float,
		right: Vector3 = Vector3.RIGHT,
		up: Vector3 = Vector3.UP,
		aspect: float = 1.777778
) -> void:
	var normalized_forward := forward.normalized()
	if normalized_forward.length_squared() <= 0.0001:
		normalized_forward = Vector3.FORWARD
	var normalized_right := right.normalized()
	if normalized_right.length_squared() <= 0.0001:
		normalized_right = Vector3.RIGHT
	var normalized_up := up.normalized()
	if normalized_up.length_squared() <= 0.0001:
		normalized_up = Vector3.UP
	var clamped_fov := clampf(fov_degrees, 1.0, 120.0)
	var clamped_aspect := clampf(aspect, 0.25, 4.0)
	var visibility_forward := normalized_forward
	visibility_forward.y = 0.0
	if visibility_forward.length_squared() > 0.0001:
		visibility_forward = visibility_forward.normalized()
	else:
		visibility_forward = normalized_forward
	has_render_camera = true
	render_camera_position = position
	render_camera_forward = normalized_forward
	render_camera_right = normalized_right
	render_camera_up = normalized_up
	render_camera_fov_degrees = clamped_fov
	render_camera_aspect = clamped_aspect
	var move_threshold := maxf(float(chunk_size) * 0.5, 8.0)
	var angular_threshold_degrees := 1.5 if clamped_fov <= zoom_fov_threshold_degrees else 4.0
	var min_forward_dot := cos(deg_to_rad(angular_threshold_degrees))
	var rotation_visibility_active := camera_cull_chunk_mesh_records \
		or _record_camera_culling_active() \
		or _individual_record_visibility_sync_active() \
		or individual_record_radius_chunks > camera_full_detail_radius_chunks
	var should_resync := not _has_visibility_request_state \
		or position.distance_squared_to(_last_visibility_request_position) > move_threshold * move_threshold
	if rotation_visibility_active:
		should_resync = should_resync \
			or visibility_forward.dot(_last_visibility_request_forward) < min_forward_dot \
			or absf(clamped_fov - _last_visibility_request_fov_degrees) > 2.0
	if should_resync:
		_has_visibility_request_state = true
		_last_visibility_request_position = position
		_last_visibility_request_forward = visibility_forward
		_last_visibility_request_fov_degrees = clamped_fov
		_queue_changed_visibility_syncs()


func apply_mock_dig(bounds: AABB, depth: float = 6.0) -> void:
	mock_terrain_carves.append({
		"bounds": bounds,
		"depth": maxf(0.0, depth)
	})
	notify_terrain_changed(bounds)


func notify_terrain_changed(bounds: AABB) -> void:
	terrain_changed.emit(bounds)
	for chunk_coord in _query_chunk_coords_in_bounds(bounds):
		_queue_chunk_rebuild(chunk_coord, VegetationChunk.DirtyReason.TERRAIN_CHANGED)


func clear_vegetation_in_area(center: Vector3, radius: float) -> void:
	if radius <= 0.0:
		return
	var radius_sq := radius * radius
	var bounds := AABB(center - Vector3(radius, radius, radius), Vector3(radius * 2.0, radius * 2.0, radius * 2.0))
	for chunk in _query_chunks_in_bounds(bounds):
		var modified := false
		for cell in chunk.grass_cells:
			if bool(cell.get("harvested", false)):
				continue
			var position: Vector3 = cell.get("position", Vector3.ZERO)
			if _distance_sq_xz(position, center) <= radius_sq:
				cell["harvested"] = true
				cell["regrow_time"] = 0.0
				modified = true
		for bush in chunk.cosmetic_bushes:
			if bool(bush.get("harvested", false)):
				continue
			var bush_position: Vector3 = bush.get("position", Vector3.ZERO)
			if _distance_sq_xz(bush_position, center) <= radius_sq:
				bush["harvested"] = true
				bush["regrow_time"] = 0.0
				bush["health"] = 0.0
				modified = true
		for rock in chunk.rock_records:
			if bool(rock.get("harvested", false)):
				continue
			var rock_position: Vector3 = rock.get("position", Vector3.ZERO)
			if _distance_sq_xz(rock_position, center) <= radius_sq:
				rock["harvested"] = true
				rock["regrow_time"] = 0.0
				rock["health"] = 0.0
				modified = true
		for tree in chunk.tree_records:
			if bool(tree.get("chopped", false)) or bool(tree.get("harvested", false)):
				continue
			var tree_position: Vector3 = tree.get("position", Vector3.ZERO)
			if _distance_sq_xz(tree_position, center) <= radius_sq:
				tree["chopped"] = true
				tree["harvested"] = true
				tree["health"] = 0.0
				modified = true
		if modified:
			_queue_chunk_rebuild(chunk.chunk_coord, VegetationChunk.DirtyReason.TERRAIN_CHANGED)


func harvest_area(position: Vector3, radius: float, tool: StringName = &"hand") -> Dictionary:
	var bounds := AABB(position - Vector3.ONE * radius, Vector3.ONE * radius * 2.0)
	var drops: Dictionary = {}
	var harvested_count := 0
	for chunk in _query_chunks_in_bounds(bounds):
		harvested_count += _harvest_chunk_area(chunk, position, radius, tool, drops)
	return {
		"harvested_count": harvested_count,
		"drops": drops,
		"bounds": bounds
	}


func find_nearest_vegetation_along_ray(
		origin: Vector3,
		direction: Vector3,
		max_distance: float,
		include_grass: bool = true,
		include_rocks: bool = true,
		include_trees: bool = true,
		include_bushes: bool = true
) -> Dictionary:
	if max_distance <= 0.0 or direction.length_squared() <= 0.000001:
		return {}
	var ray_dir := direction.normalized()
	var ray_bounds := AABB(origin - Vector3.ONE * max_distance, Vector3.ONE * max_distance * 2.0)
	var best_hit: Dictionary = {}
	for chunk in _query_chunks_in_bounds(ray_bounds):
		if chunk == null:
			continue
		if include_grass:
			for cell_variant in chunk.grass_cells:
				var cell: Dictionary = cell_variant
				var hit := _build_ray_hit("grass", chunk, cell, null, origin, ray_dir, max_distance, 0.35, 0.8)
				if _is_better_hit(hit, best_hit):
					best_hit = hit
		if include_bushes:
			for bush_variant in chunk.cosmetic_bushes:
				var bush: Dictionary = bush_variant
				var bush_type := _get_type(StringName(str(bush.get("type_id", ""))))
				var hit := _build_ray_hit("bush", chunk, bush, bush_type, origin, ray_dir, max_distance, 0.7, 1.0)
				if _is_better_hit(hit, best_hit):
					best_hit = hit
		if include_trees:
			for tree_variant in chunk.tree_records:
				var tree: Dictionary = tree_variant
				var tree_type := _get_type(StringName(str(tree.get("type_id", ""))))
				var hit := _build_ray_hit("tree", chunk, tree, tree_type, origin, ray_dir, max_distance, 1.1, 8.0)
				if _is_better_hit(hit, best_hit):
					best_hit = hit
		if include_rocks:
			for rock_variant in chunk.rock_records:
				var rock: Dictionary = rock_variant
				var rock_type := _get_type(StringName(str(rock.get("type_id", ""))))
				var hit := _build_ray_hit("rock", chunk, rock, rock_type, origin, ray_dir, max_distance, 0.65, 0.7)
				if _is_better_hit(hit, best_hit):
					best_hit = hit
	return best_hit


func harvest_data_hit(hit: Dictionary) -> bool:
	if hit.is_empty():
		return false
	var kind := str(hit.get("kind", ""))
	var chunk_coord_variant: Variant = hit.get("coord", Vector2i.ZERO)
	var chunk_coord: Vector2i = chunk_coord_variant if chunk_coord_variant is Vector2i else Vector2i.ZERO
	var record_id := int(hit.get("record_id", hit.get("index", -1)))
	var type_id := StringName(str(hit.get("type_id", "")))
	var type := _get_type(type_id)
	var tool := type.required_tool if type and not String(type.required_tool).is_empty() else &"hand"
	var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
	if chunk == null or record_id < 0:
		return false
	match kind:
		"grass":
			return _harvest_grass_index(chunk, record_id)
		"tree":
			if String(tool).is_empty():
				tool = &"axe"
			return _damage_tree_index(chunk, record_id, 9999.0, tool)
		"bush":
			return _damage_bush_index(chunk, record_id, 9999.0, tool)
		"rock":
			return _damage_rock_index(chunk, record_id, 9999.0, tool)
	return false


func chop_tree_at_index(chunk_coord: Vector2i, index: int, damage: float = 9999.0) -> bool:
	var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
	if chunk == null:
		return false
	return _damage_tree_index(chunk, index, damage, &"axe")


func chop_tree_by_collider(_target: Object) -> bool:
	return _harvest_from_collider(_target, "tree")


func harvest_grass_by_collider(_target: Object) -> bool:
	return _harvest_from_collider(_target, "grass")


func harvest_rock_by_collider(_target: Object) -> bool:
	return _harvest_from_collider(_target, "rock")


func resolve_tree_body_collision(body_origin: Vector3, body_radius: float = 0.4, body_height: float = 1.8) -> Dictionary:
	if body_radius <= 0.0 or body_height <= 0.0:
		return {}
	var body_bounds := AABB(
		Vector3(body_origin.x - body_radius, body_origin.y, body_origin.z - body_radius),
		Vector3(body_radius * 2.0, body_height, body_radius * 2.0)
	)
	var total_push := Vector3.ZERO
	var hit_count := 0
	var body_min_y := body_origin.y
	var body_max_y := body_origin.y + body_height
	for chunk in _query_chunks_in_bounds(body_bounds):
		if chunk == null:
			continue
		for tree_variant in chunk.tree_records:
			var tree: Dictionary = tree_variant
			if bool(tree.get("chopped", false)) or bool(tree.get("harvested", false)):
				continue
			var type := _get_type(StringName(str(tree.get("type_id", ""))))
			if type == null:
				continue
			if type.category != VegetationType.Category.TREE and type.category != VegetationType.Category.LOG:
				continue
			if type.support_rule == VegetationType.SupportRule.NONE:
				continue
			var position: Vector3 = tree.get("position", Vector3.ZERO)
			var tree_scale := maxf(0.1, float(tree.get("scale", type.instance_scale)))
			var tree_radius := maxf(type.support_radius * tree_scale, 0.3)
			var tree_height := maxf(type.support_height * tree_scale, body_height)
			var tree_min_y := position.y
			var tree_max_y := position.y + tree_height
			if body_max_y < tree_min_y or body_min_y > tree_max_y:
				continue
			var dx := body_origin.x - position.x
			var dz := body_origin.z - position.z
			var dist_sq := dx * dx + dz * dz
			var combined_radius := tree_radius + body_radius
			if dist_sq >= combined_radius * combined_radius:
				continue
			var dist := sqrt(maxf(dist_sq, 0.0001))
			var penetration := combined_radius - dist
			var push_dir := Vector3(dx / dist, 0.0, dz / dist)
			if dist_sq <= 0.000001:
				push_dir = Vector3(1.0, 0.0, 0.0)
			total_push += push_dir * penetration
			hit_count += 1
	if hit_count == 0:
		return {}
	return {
		"push": total_push,
		"hits": hit_count
	}


func place_grass(position: Vector3) -> bool:
	var support_height := _try_get_precise_support_height(position)
	if support_height <= -100.0:
		return false
	position.y = support_height + grass_y_offset
	var chunk_coord := _world_to_chunk_coord(position)
	var chunk := _ensure_chunk(chunk_coord, VegetationChunk.DirtyReason.BIOME_CHANGED)
	if chunk == null:
		return false
	var rng := _rng_for_position(position, _next_record_id)
	var type := _pick_grass_type(rng)
	if type == null:
		return false
	var cell := _make_grass_cell(chunk, type, position, rng.randf_range(0.5, 1.0), 1.0, false, rng)
	chunk.grass_cells.append(cell)
	_queue_chunk_rebuild(chunk_coord, VegetationChunk.DirtyReason.HARVESTED)
	return true


func place_rock(position: Vector3) -> bool:
	var support_height := _try_get_precise_support_height(position)
	if support_height <= -100.0:
		return false
	position.y = support_height + rock_y_offset
	var chunk_coord := _world_to_chunk_coord(position)
	var chunk := _ensure_chunk(chunk_coord, VegetationChunk.DirtyReason.BIOME_CHANGED)
	if chunk == null:
		return false
	var rng := _rng_for_position(position, _next_record_id)
	var type := _pick_rock_type(rng)
	if type == null:
		return false
	var record := _make_individual_record(type, chunk_coord, position, false, rng)
	chunk.rock_records.append(record)
	_queue_chunk_rebuild(chunk_coord, VegetationChunk.DirtyReason.HARVESTED)
	return true


func _harvest_from_collider(target: Object, kind: String) -> bool:
	if target == null:
		return false
	var coord_key := "%s_coord" % kind
	var index_key := "%s_index" % kind
	var record_id_key := "%s_record_id" % kind
	if not target.has_meta(coord_key) or (not target.has_meta(index_key) and not target.has_meta(record_id_key)):
		return false
	var coord_variant: Variant = target.get_meta(coord_key, Vector2i.ZERO)
	var coord: Vector2i = coord_variant if coord_variant is Vector2i else Vector2i.ZERO
	var record_id := int(target.get_meta(record_id_key, target.get_meta(index_key, -1)))
	if record_id < 0:
		return false
	match kind:
		"tree":
			return chop_tree_at_index(coord, record_id)
		"grass":
			var grass_chunk: VegetationChunk = chunks.get(coord, null) as VegetationChunk
			return grass_chunk != null and _harvest_grass_index(grass_chunk, record_id)
		"rock":
			var rock_chunk: VegetationChunk = chunks.get(coord, null) as VegetationChunk
			return rock_chunk != null and _damage_rock_index(rock_chunk, record_id, 9999.0, &"hand")
		_:
			return false


func _process(delta: float) -> void:
	if not _bootstrapped:
		return
	if not _terrain_streaming_ready and _is_terrain_ready_for_streaming():
		_terrain_streaming_ready = true
		if auto_spawn_benchmark_content:
			_seed_initial_chunks()
		elif enable_streaming:
			_refresh_streaming_request()
	_process_regrowth(delta)
	if not _terrain_streaming_ready and not use_mock_terrain:
		_update_ready_state()
		return
	_process_streaming()
	_process_pending_generations()
	_process_pending_rebuilds()
	_process_pending_visibility_syncs()
	_process_hidden_instance_evictions()
	_process_pending_render_cluster_rebuilds()
	_update_ready_state()


func _seed_initial_chunks() -> void:
	_refresh_streaming_request()


func _refresh_streaming_request() -> void:
	if not enable_streaming:
		return
	var focus_chunk := _get_focus_chunk()
	if focus_chunk == _last_focus_chunk:
		return
	var previous_focus_chunk := _last_focus_chunk
	_last_focus_chunk = focus_chunk
	var radius := active_stream_radius_chunks if active_stream_radius_chunks > 0 else initial_stream_radius_chunks
	_evict_far_chunks(focus_chunk, radius)
	var requested_coords: Array[Vector2i] = []
	for x in range(focus_chunk.x - radius, focus_chunk.x + radius + 1):
		for z in range(focus_chunk.y - radius, focus_chunk.y + radius + 1):
			var dx := x - focus_chunk.x
			var dz := z - focus_chunk.y
			if dx * dx + dz * dz > radius * radius:
				continue
			requested_coords.append(Vector2i(x, z))
	requested_coords.sort_custom(_compare_pending_chunk_distance)
	for chunk_coord in requested_coords:
		_queue_chunk_generation(chunk_coord, VegetationChunk.DirtyReason.STREAMED_IN)
	_queue_tree_render_mode_rebuilds(previous_focus_chunk, focus_chunk)
	_sort_pending_generation_queue_by_focus()
	_sort_pending_render_work_by_focus()
	_queue_changed_visibility_syncs()


func _process_streaming() -> void:
	if enable_streaming and _terrain_streaming_ready:
		_refresh_streaming_request()


func _evict_far_chunks(center: Vector2i, radius: int) -> void:
	var to_remove: Array[Vector2i] = []
	var radius_sq := radius * radius
	for chunk_coord_variant in chunks.keys():
		var chunk_coord: Vector2i = chunk_coord_variant
		var dx := chunk_coord.x - center.x
		var dz := chunk_coord.y - center.y
		if dx * dx + dz * dz > radius_sq:
			to_remove.append(chunk_coord)
	for chunk_coord in to_remove:
		_remove_chunk(chunk_coord, true)


func _current_generation_budget_ms() -> float:
	return initial_generation_budget_ms if not _initial_stream_complete else stream_generation_budget_ms


func _current_rebuild_budget_ms() -> float:
	return initial_rebuild_budget_ms if not _initial_stream_complete else stream_rebuild_budget_ms


func _current_render_upload_budget_ms() -> float:
	return initial_render_upload_budget_ms if not _initial_stream_complete else stream_render_upload_budget_ms


func _budget_exhausted(start_us: int, budget_ms: float, processed_count: int) -> bool:
	if processed_count <= 0 or budget_ms <= 0.0:
		return false
	return float(Time.get_ticks_usec() - start_us) / 1000.0 >= budget_ms


func _process_pending_rebuilds() -> void:
	var start_us := Time.get_ticks_usec()
	var budget_ms := _current_rebuild_budget_ms()
	var rebuild_count := 0
	while rebuild_count < max_rebuilds_per_frame \
			and not _pending_rebuilds.is_empty() \
			and not _budget_exhausted(start_us, budget_ms, rebuild_count):
		var chunk_coord: Vector2i = _pending_rebuilds.pop_front()
		var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
		if chunk == null:
			continue
		_rebuild_chunk(chunk)
		rebuild_count += 1
	_last_rebuild_processed_count = rebuild_count


func _process_pending_visibility_syncs() -> void:
	if not render_enabled or renderer == null:
		_pending_visibility_sync_chunks.clear()
		_pending_visibility_sync_lookup.clear()
		return
	var start_us := Time.get_ticks_usec()
	var sync_count := 0
	var max_inspections := _pending_visibility_sync_chunks.size()
	var inspected_count := 0
	while sync_count < max_visibility_sync_chunks_per_frame \
			and inspected_count < max_inspections \
			and not _pending_visibility_sync_chunks.is_empty():
		inspected_count += 1
		var chunk_coord: Vector2i = _pending_visibility_sync_chunks.pop_front()
		_pending_visibility_sync_lookup.erase(chunk_coord)
		var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
		if chunk == null or chunk.state == VegetationChunk.State.UNLOADED or chunk.has_pending_rebuild():
			continue
		_sync_individual_instances(chunk)
		sync_count += 1
	_last_visibility_sync_chunk_count = sync_count
	_last_visibility_sync_time_ms = float(Time.get_ticks_usec() - start_us) / 1000.0


func _process_pending_render_cluster_rebuilds() -> void:
	if not render_enabled or renderer == null:
		_pending_render_cluster_rebuilds.clear()
		_pending_render_cluster_lookup.clear()
		_pending_render_cluster_retry_after_frames.clear()
		return
	var start_us := Time.get_ticks_usec()
	var budget_ms := _current_render_upload_budget_ms()
	var rebuild_count := 0
	var current_frame := Engine.get_process_frames()
	var inspected_count := 0
	var max_inspections := _pending_render_cluster_rebuilds.size()
	while rebuild_count < max_render_cluster_rebuilds_per_frame \
			and inspected_count < max_inspections \
			and not _pending_render_cluster_rebuilds.is_empty() \
			and not _budget_exhausted(start_us, budget_ms, rebuild_count):
		inspected_count += 1
		var cluster_coord: Vector2i = _pending_render_cluster_rebuilds.pop_front()
		var retry_after_frame := int(_pending_render_cluster_retry_after_frames.get(cluster_coord, 0))
		if retry_after_frame > current_frame:
			_pending_render_cluster_rebuilds.append(cluster_coord)
			continue
		if _should_defer_render_cluster_rebuild(cluster_coord, current_frame):
			_pending_render_cluster_retry_after_frames[cluster_coord] = current_frame + RENDER_CLUSTER_RETRY_FRAMES
			_pending_render_cluster_rebuilds.append(cluster_coord)
			continue
		_rebuild_render_cluster(cluster_coord)
		_pending_render_cluster_lookup.erase(cluster_coord)
		_pending_render_cluster_retry_after_frames.erase(cluster_coord)
		_render_cluster_first_request_frames.erase(cluster_coord)
		rebuild_count += 1
	_last_render_cluster_rebuild_processed_count = rebuild_count


func _process_regrowth(delta: float) -> void:
	var refresh_count := 0
	if _regrowth_chunk_coords.is_empty():
		_last_support_refresh_count = 0
		return
	for chunk_coord_variant in _regrowth_chunk_coords.keys():
		var chunk_coord: Vector2i = chunk_coord_variant
		var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
		if chunk == null:
			_regrowth_chunk_coords.erase(chunk_coord)
			continue
		var chunk_changed := false
		var chunk_still_has_regrowth := false
		for cell in chunk.grass_cells:
			if not bool(cell.get("harvested", false)):
				continue
			var regrow_time := float(cell.get("regrow_time", 0.0))
			if regrow_time <= 0.0:
				continue
			regrow_time = maxf(0.0, regrow_time - delta)
			cell["regrow_time"] = regrow_time
			if regrow_time <= 0.0:
				cell["harvested"] = false
				chunk_changed = true
				refresh_count += 1
			else:
				chunk_still_has_regrowth = true
		for bush in chunk.cosmetic_bushes:
			if not bool(bush.get("harvested", false)):
				continue
			var regrow_time := float(bush.get("regrow_time", 0.0))
			if regrow_time <= 0.0:
				continue
			regrow_time = maxf(0.0, regrow_time - delta)
			bush["regrow_time"] = regrow_time
			if regrow_time <= 0.0:
				bush["harvested"] = false
				bush["health"] = _type_health(StringName(str(bush.get("type_id", ""))), 1.0)
				chunk_changed = true
				refresh_count += 1
			else:
				chunk_still_has_regrowth = true
		for rock in chunk.rock_records:
			if not bool(rock.get("harvested", false)):
				continue
			var regrow_time := float(rock.get("regrow_time", 0.0))
			if regrow_time <= 0.0:
				continue
			regrow_time = maxf(0.0, regrow_time - delta)
			rock["regrow_time"] = regrow_time
			if regrow_time <= 0.0:
				rock["harvested"] = false
				rock["health"] = _type_health(StringName(str(rock.get("type_id", ""))), 1.0)
				chunk_changed = true
				refresh_count += 1
			else:
				chunk_still_has_regrowth = true
		if chunk_changed:
			_queue_chunk_rebuild(chunk.chunk_coord, VegetationChunk.DirtyReason.REGROWTH)
		if not chunk_still_has_regrowth:
			_regrowth_chunk_coords.erase(chunk.chunk_coord)
	_last_support_refresh_count = refresh_count


func _queue_chunk_generation(chunk_coord: Vector2i, reason: int) -> void:
	var chunk := _ensure_chunk(chunk_coord, reason)
	if chunk == null:
		return
	if chunk.state != VegetationChunk.State.UNLOADED:
		if chunk.has_pending_rebuild():
			_queue_chunk_rebuild(chunk_coord, reason)
		return
	if _pending_generation_reasons.has(chunk_coord):
		_pending_generation_reasons[chunk_coord] = reason
		return
	_pending_generation_queue.append(chunk_coord)
	_pending_generation_reasons[chunk_coord] = reason


func _sort_pending_generation_queue_by_focus() -> void:
	if _pending_generation_queue.size() <= 1:
		return
	_pending_generation_queue.sort_custom(_compare_pending_chunk_distance)


func _sort_pending_render_work_by_focus() -> void:
	if _pending_rebuilds.size() > 1:
		_pending_rebuilds.sort_custom(_compare_pending_chunk_distance)
	if _pending_render_cluster_rebuilds.size() > 1:
		_pending_render_cluster_rebuilds.sort_custom(_compare_pending_render_cluster_distance)
	if _pending_visibility_sync_chunks.size() > 1:
		_pending_visibility_sync_chunks.sort_custom(_compare_visibility_chunk_priority)


func _compare_pending_chunk_distance(a: Vector2i, b: Vector2i) -> bool:
	var a_distance := _chunk_distance_sq_from_focus(a)
	var b_distance := _chunk_distance_sq_from_focus(b)
	if a_distance == b_distance:
		if a.x == b.x:
			return a.y < b.y
		return a.x < b.x
	return a_distance < b_distance


func _compare_pending_render_cluster_distance(a: Vector2i, b: Vector2i) -> bool:
	var a_distance := _render_cluster_distance_sq_from_focus(a)
	var b_distance := _render_cluster_distance_sq_from_focus(b)
	if a_distance == b_distance:
		if a.x == b.x:
			return a.y < b.y
		return a.x < b.x
	return a_distance < b_distance


func _compare_visibility_chunk_priority(a: Vector2i, b: Vector2i) -> bool:
	var a_score := _visibility_chunk_priority_score(a)
	var b_score := _visibility_chunk_priority_score(b)
	if is_equal_approx(a_score, b_score):
		return _compare_pending_chunk_distance(a, b)
	return a_score < b_score


func _visibility_chunk_priority_score(chunk_coord: Vector2i) -> float:
	var distance_score := float(_chunk_distance_sq_from_focus(chunk_coord))
	if not has_render_camera:
		return distance_score
	var chunk_center := Vector3(
		(float(chunk_coord.x) + 0.5) * float(chunk_size),
		render_camera_position.y,
		(float(chunk_coord.y) + 0.5) * float(chunk_size)
	)
	var to_chunk := chunk_center - render_camera_position
	to_chunk.y = 0.0
	if to_chunk.length_squared() <= 0.0001:
		return -100000.0
	var ahead := render_camera_forward.dot(to_chunk.normalized())
	return distance_score - ahead * 1000.0


func _chunk_distance_sq_from_focus(chunk_coord: Vector2i) -> int:
	var dx := chunk_coord.x - _last_focus_chunk.x
	var dz := chunk_coord.y - _last_focus_chunk.y
	return dx * dx + dz * dz


func _render_cluster_distance_sq_from_focus(cluster_coord: Vector2i) -> int:
	var size := maxi(1, render_cluster_size_chunks)
	var min_x := cluster_coord.x * size
	var min_z := cluster_coord.y * size
	var max_x := min_x + size - 1
	var max_z := min_z + size - 1
	var dx := 0
	if _last_focus_chunk.x < min_x:
		dx = min_x - _last_focus_chunk.x
	elif _last_focus_chunk.x > max_x:
		dx = _last_focus_chunk.x - max_x
	var dz := 0
	if _last_focus_chunk.y < min_z:
		dz = min_z - _last_focus_chunk.y
	elif _last_focus_chunk.y > max_z:
		dz = _last_focus_chunk.y - max_z
	return dx * dx + dz * dz


func _render_cluster_coord_for_chunk(chunk_coord: Vector2i) -> Vector2i:
	var size := maxi(1, render_cluster_size_chunks)
	return Vector2i(
		int(floor(float(chunk_coord.x) / float(size))),
		int(floor(float(chunk_coord.y) / float(size)))
	)


func _render_cluster_origin(cluster_coord: Vector2i) -> Vector3:
	var size := maxi(1, render_cluster_size_chunks)
	return Vector3(
		float(cluster_coord.x * size * chunk_size),
		0.0,
		float(cluster_coord.y * size * chunk_size)
	)


func _render_cluster_key(cluster_coord: Vector2i) -> String:
	return "vegetation_cluster_%d_%d" % [cluster_coord.x, cluster_coord.y]


func _get_chunks_in_render_cluster(cluster_coord: Vector2i) -> Array[VegetationChunk]:
	var result: Array[VegetationChunk] = []
	var size := maxi(1, render_cluster_size_chunks)
	var start_x := cluster_coord.x * size
	var start_z := cluster_coord.y * size
	for x in range(start_x, start_x + size):
		for z in range(start_z, start_z + size):
			var chunk: VegetationChunk = chunks.get(Vector2i(x, z), null) as VegetationChunk
			if chunk != null and chunk.state != VegetationChunk.State.UNLOADED and _is_chunk_inside_stream_radius(chunk.chunk_coord):
				result.append(chunk)
	return result


func _queue_tree_render_mode_rebuilds(previous_focus_chunk: Vector2i, current_focus_chunk: Vector2i) -> void:
	if previous_focus_chunk.x == 2147483647:
		return
	if not batch_individual_records_in_render_clusters or individual_record_radius_chunks <= 0:
		return
	for chunk_coord_variant in chunks.keys():
		var chunk_coord: Vector2i = chunk_coord_variant
		var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
		if chunk == null:
			continue
		if chunk.tree_records.is_empty() and chunk.cosmetic_bushes.is_empty() and chunk.rock_records.is_empty():
			continue
		var was_individual := _is_chunk_within_individual_record_radius(chunk_coord, previous_focus_chunk)
		var is_individual := _is_chunk_within_individual_record_radius(chunk_coord, current_focus_chunk)
		if was_individual != is_individual:
			_queue_visibility_sync(chunk_coord)
			_queue_render_cluster_rebuild(_render_cluster_coord_for_chunk(chunk_coord))


func _is_chunk_within_individual_tree_radius(chunk_coord: Vector2i, focus_chunk: Vector2i) -> bool:
	if individual_tree_radius_chunks <= 0:
		return false
	var dx := chunk_coord.x - focus_chunk.x
	var dz := chunk_coord.y - focus_chunk.y
	return dx * dx + dz * dz <= individual_tree_radius_chunks * individual_tree_radius_chunks


func _is_chunk_within_individual_record_radius(chunk_coord: Vector2i, focus_chunk: Vector2i) -> bool:
	if individual_record_radius_chunks <= 0:
		return false
	var radius := individual_record_radius_chunks
	var dx := chunk_coord.x - focus_chunk.x
	var dz := chunk_coord.y - focus_chunk.y
	return dx * dx + dz * dz <= radius * radius


func _queue_chunk_rebuild(chunk_coord: Vector2i, reason: int) -> void:
	var chunk := _ensure_chunk(chunk_coord, reason)
	if chunk == null:
		return
	if not _pending_rebuilds.has(chunk_coord):
		_pending_rebuilds.append(chunk_coord)
	chunk.set_dirty(reason, Engine.get_process_frames())


func _queue_render_cluster_rebuild(cluster_coord: Vector2i) -> void:
	if not render_enabled or renderer == null:
		return
	_pending_render_cluster_retry_after_frames[cluster_coord] = Engine.get_process_frames() + 8
	if _pending_render_cluster_lookup.has(cluster_coord):
		return
	_pending_render_cluster_lookup[cluster_coord] = true
	_render_cluster_first_request_frames[cluster_coord] = Engine.get_process_frames()
	_pending_render_cluster_rebuilds.append(cluster_coord)


func _queue_visibility_sync(chunk_coord: Vector2i) -> void:
	if not render_enabled or renderer == null:
		return
	if _pending_visibility_sync_lookup.has(chunk_coord):
		return
	_pending_visibility_sync_lookup[chunk_coord] = true
	_pending_visibility_sync_chunks.append(chunk_coord)


func _queue_changed_visibility_syncs() -> void:
	if not render_enabled or renderer == null:
		return
	var changed_count := 0
	var record_culling_active := _record_camera_culling_active()
	var individual_visibility_active := _individual_record_visibility_sync_active()
	for chunk_coord_variant in chunks.keys():
		var chunk_coord: Vector2i = chunk_coord_variant
		var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
		if chunk == null or chunk.state == VegetationChunk.State.UNLOADED:
			continue
		var new_class := _chunk_visibility_class_for_camera(chunk_coord)
		var old_class := int(_chunk_visibility_class.get(chunk_coord, -1))
		if old_class == new_class:
			if individual_visibility_active and new_class == VISIBILITY_CLASS_CONE:
				_queue_visibility_sync(chunk_coord)
			if record_culling_active and new_class == VISIBILITY_CLASS_CONE:
				_queue_render_cluster_rebuild(_render_cluster_coord_for_chunk(chunk_coord))
			continue
		_chunk_visibility_class[chunk_coord] = new_class
		_queue_visibility_sync(chunk_coord)
		_sync_render_cluster_visibility(_render_cluster_coord_for_chunk(chunk_coord))
		if record_culling_active and (old_class == VISIBILITY_CLASS_CONE or new_class == VISIBILITY_CLASS_CONE):
			_queue_render_cluster_rebuild(_render_cluster_coord_for_chunk(chunk_coord))
		changed_count += 1
	if changed_count > 1:
		_pending_visibility_sync_chunks.sort_custom(_compare_visibility_chunk_priority)
	_last_visibility_sync_queued_count = changed_count
	_last_visibility_sync_changed_count = changed_count


func _chunk_visibility_class_for_camera(chunk_coord: Vector2i) -> int:
	var full_radius := maxi(0, camera_full_detail_radius_chunks)
	if full_radius > 0 and _chunk_distance_sq_from_focus(chunk_coord) <= full_radius * full_radius:
		_chunk_last_visible_frame[chunk_coord] = Engine.get_process_frames()
		return VISIBILITY_CLASS_FULL
	if not has_render_camera:
		_chunk_last_visible_frame[chunk_coord] = Engine.get_process_frames()
		return VISIBILITY_CLASS_FULL
	var chunk_center := Vector3(
		(float(chunk_coord.x) + 0.5) * float(chunk_size),
		focus_position.y + 4.0,
		(float(chunk_coord.y) + 0.5) * float(chunk_size)
	)
	var to_chunk := chunk_center - render_camera_position
	var chunk_radius := float(chunk_size) * 0.70710678 + 18.0
	var max_distance := float(maxi(active_stream_radius_chunks, initial_stream_radius_chunks) * chunk_size) + float(chunk_size) + chunk_radius
	if to_chunk.length_squared() > max_distance * max_distance:
		return _visibility_class_after_grace(chunk_coord)
	if to_chunk.length_squared() <= 0.0001:
		_chunk_last_visible_frame[chunk_coord] = Engine.get_process_frames()
		return VISIBILITY_CLASS_FULL
	var margin := zoom_cone_margin_degrees if render_camera_fov_degrees <= zoom_fov_threshold_degrees else camera_cone_margin_degrees
	var prefetch_margin := zoom_prefetch_margin_degrees if render_camera_fov_degrees <= zoom_fov_threshold_degrees else camera_prefetch_margin_degrees
	if _is_sphere_in_camera_view(chunk_center, chunk_radius, margin, prefetch_margin):
		_chunk_last_visible_frame[chunk_coord] = Engine.get_process_frames()
		return VISIBILITY_CLASS_CONE
	return _visibility_class_after_grace(chunk_coord)


func _is_sphere_in_camera_view(center: Vector3, radius: float, margin_degrees: float, prefetch_degrees: float = 0.0) -> bool:
	if not has_render_camera:
		return true
	var to_center := center - render_camera_position
	var distance_sq := to_center.length_squared()
	var safe_radius := maxf(radius, 0.1)
	if distance_sq <= safe_radius * safe_radius:
		return true
	var forward_distance := render_camera_forward.dot(to_center)
	if forward_distance < -safe_radius:
		return false
	var distance := sqrt(distance_sq)
	var edge_angle := asin(clampf(safe_radius / maxf(distance, 0.001), 0.0, 0.95))
	var margin_radians := deg_to_rad(maxf(0.0, margin_degrees + prefetch_degrees))
	var vertical_half := deg_to_rad(render_camera_fov_degrees * 0.5) + margin_radians + edge_angle
	var horizontal_half := atan(tan(deg_to_rad(render_camera_fov_degrees * 0.5)) * render_camera_aspect) + margin_radians + edge_angle
	var safe_forward := maxf(forward_distance, 0.001)
	var horizontal_angle := absf(atan2(render_camera_right.dot(to_center), safe_forward))
	var vertical_angle := absf(atan2(render_camera_up.dot(to_center), safe_forward))
	return horizontal_angle <= horizontal_half and vertical_angle <= vertical_half


func _visibility_class_after_grace(chunk_coord: Vector2i) -> int:
	if visibility_hide_grace_frames <= 0:
		_chunk_last_visible_frame.erase(chunk_coord)
		return VISIBILITY_CLASS_NONE
	var current_frame := Engine.get_process_frames()
	var last_visible_frame := int(_chunk_last_visible_frame.get(chunk_coord, -1000000))
	if current_frame - last_visible_frame <= visibility_hide_grace_frames:
		return VISIBILITY_CLASS_CONE
	_chunk_last_visible_frame.erase(chunk_coord)
	return VISIBILITY_CLASS_NONE


func _should_defer_render_cluster_rebuild(cluster_coord: Vector2i, current_frame: int) -> bool:
	var first_request_frame := int(_render_cluster_first_request_frames.get(cluster_coord, current_frame))
	if current_frame - first_request_frame >= MAX_RENDER_CLUSTER_DEFER_FRAMES:
		return false
	return _has_pending_generation_in_render_cluster(cluster_coord) or _has_pending_chunk_rebuild_in_render_cluster(cluster_coord)


func _has_pending_generation_in_render_cluster(cluster_coord: Vector2i) -> bool:
	for chunk_coord in _pending_generation_queue:
		if _is_chunk_inside_render_cluster(chunk_coord, cluster_coord) and _is_chunk_inside_stream_radius(chunk_coord):
			return true
	return false


func _has_pending_chunk_rebuild_in_render_cluster(cluster_coord: Vector2i) -> bool:
	for chunk_coord in _pending_rebuilds:
		if _is_chunk_inside_render_cluster(chunk_coord, cluster_coord) and _is_chunk_inside_stream_radius(chunk_coord):
			return true
	return false


func _is_chunk_inside_render_cluster(chunk_coord: Vector2i, cluster_coord: Vector2i) -> bool:
	return _render_cluster_coord_for_chunk(chunk_coord) == cluster_coord


func _track_regrowth_if_needed(chunk_coord: Vector2i, regrow_time: float) -> void:
	if regrow_time > 0.0:
		_regrowth_chunk_coords[chunk_coord] = true


func _ensure_chunk(chunk_coord: Vector2i, reason: int) -> VegetationChunk:
	if chunks.has(chunk_coord):
		return chunks[chunk_coord] as VegetationChunk
	var chunk := VegetationChunk.new()
	chunk.chunk_coord = chunk_coord
	chunk.bounds = _make_chunk_bounds(chunk_coord)
	chunk.state = VegetationChunk.State.UNLOADED
	chunks[chunk_coord] = chunk
	_chunk_visibility_class[chunk_coord] = _chunk_visibility_class_for_camera(chunk_coord)
	spatial_grid.set_chunk(chunk)
	if native_spatial_grid != null:
		native_spatial_grid.set_chunk(chunk_coord)
	return chunk


func _process_pending_generations() -> void:
	var start_us := Time.get_ticks_usec()
	var budget_ms := _current_generation_budget_ms()
	var generation_count := 0
	var inspected_count := 0
	var max_inspections := _pending_generation_queue.size()
	var current_frame := Engine.get_process_frames()
	while generation_count < max_generations_per_frame \
			and inspected_count < max_inspections \
			and not _pending_generation_queue.is_empty() \
			and not _budget_exhausted(start_us, budget_ms, generation_count):
		inspected_count += 1
		var chunk_coord: Vector2i = _pending_generation_queue.pop_front()
		var reason := int(_pending_generation_reasons.get(chunk_coord, VegetationChunk.DirtyReason.STREAMED_IN))
		_pending_generation_reasons.erase(chunk_coord)
		var retry_after_frame := int(_pending_generation_retry_after_frames.get(chunk_coord, 0))
		if retry_after_frame > current_frame:
			_pending_generation_queue.append(chunk_coord)
			_pending_generation_reasons[chunk_coord] = reason
			continue
		_pending_generation_retry_after_frames.erase(chunk_coord)
		var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
		if chunk == null or chunk.state != VegetationChunk.State.UNLOADED:
			continue
		if not use_mock_terrain and not _is_vegetation_chunk_support_ready(chunk_coord):
			_defer_chunk_generation(chunk_coord, reason)
			generation_count += 1
			continue
		_populate_chunk(chunk, reason)
		_queue_chunk_rebuild(chunk_coord, reason)
		generation_count += 1
	_last_generation_processed_count = generation_count


func _defer_chunk_generation(chunk_coord: Vector2i, reason: int) -> void:
	_pending_generation_retry_after_frames[chunk_coord] = Engine.get_process_frames() + 15
	if not _pending_generation_reasons.has(chunk_coord):
		_pending_generation_queue.append(chunk_coord)
	_pending_generation_reasons[chunk_coord] = reason


func _is_vegetation_chunk_support_ready(chunk_coord: Vector2i) -> bool:
	if use_mock_terrain:
		return true
	if _chunk_has_surface_support_samples(chunk_coord):
		return true
	if terrain_manager and is_instance_valid(terrain_manager) and terrain_manager.has_method("get_pending_nodes_count"):
		return int(terrain_manager.get_pending_nodes_count()) <= 0
	return false


func _chunk_has_surface_support_samples(chunk_coord: Vector2i) -> bool:
	var origin_x := float(chunk_coord.x * chunk_size)
	var origin_z := float(chunk_coord.y * chunk_size)
	var sample_fracs := [0.2, 0.5, 0.8]
	for fx in sample_fracs:
		for fz in sample_fracs:
			var sample_pos := Vector3(
				origin_x + float(fx) * float(chunk_size),
				0.0,
				origin_z + float(fz) * float(chunk_size)
			)
			if _try_get_support_height(sample_pos) > -100.0:
				return true
	return false


func _rebuild_chunk(chunk: VegetationChunk) -> void:
	if chunk == null:
		return
	var start_ms := Time.get_ticks_msec()
	var rebuild_reason := chunk.dirty_reason
	if rebuild_reason == VegetationChunk.DirtyReason.TERRAIN_CHANGED:
		_refresh_chunk_support(chunk)
	else:
		chunk.last_support_refresh_time_ms = 0.0
		_last_support_refresh_time_ms = 0.0
	if render_enabled and renderer != null:
		_chunk_visibility_class[chunk.chunk_coord] = _chunk_visibility_class_for_camera(chunk.chunk_coord)
		_sync_individual_instances(chunk)
		_queue_render_cluster_rebuild(_render_cluster_coord_for_chunk(chunk.chunk_coord))
	else:
		chunk.visible_grass_cell_count = 0
		chunk.visible_tree_record_count = 0
		chunk.visible_individual_tree_record_count = 0
		chunk.visible_chunked_tree_record_count = 0
		chunk.visible_bush_record_count = 0
		chunk.visible_individual_bush_record_count = 0
		chunk.visible_chunked_bush_record_count = 0
		chunk.visible_rock_record_count = 0
		chunk.visible_individual_rock_record_count = 0
		chunk.visible_chunked_rock_record_count = 0
		chunk.grass_mesh_primitive_count = 0
		chunk.tree_mesh_primitive_count = 0
		chunk.bush_mesh_primitive_count = 0
		chunk.rock_mesh_primitive_count = 0
		chunk.grass_estimated_primitive_count = 0
		chunk.tree_estimated_primitive_count = 0
		chunk.individual_tree_estimated_primitive_count = 0
		chunk.chunked_tree_estimated_primitive_count = 0
		chunk.bush_estimated_primitive_count = 0
		chunk.individual_bush_estimated_primitive_count = 0
		chunk.chunked_bush_estimated_primitive_count = 0
		chunk.rock_estimated_primitive_count = 0
		chunk.individual_rock_estimated_primitive_count = 0
		chunk.chunked_rock_estimated_primitive_count = 0
		chunk.support_points_total = 0
	chunk.mark_live(Engine.get_process_frames())
	chunk.last_rebuild_time_ms = float(Time.get_ticks_msec() - start_ms)
	_last_rebuild_time_ms = chunk.last_rebuild_time_ms
	chunk_rebuilt.emit(chunk.chunk_coord)


func _rebuild_render_cluster(cluster_coord: Vector2i) -> void:
	if renderer == null:
		return
	var start_ms := Time.get_ticks_msec()
	var cluster_chunks := _get_chunks_in_render_cluster(cluster_coord)
	var cluster_key := _render_cluster_key(cluster_coord)
	if cluster_chunks.is_empty():
		_destroy_render_cluster(cluster_coord)
		_last_rebuild_time_ms = float(Time.get_ticks_msec() - start_ms)
		return
	var cluster_origin := _render_cluster_origin(cluster_coord)
	var previous_instanced_keys: Array = _render_cluster_instanced_keys.get(cluster_coord, []).duplicate()
	var payload := _build_render_cluster_mesh_payload(cluster_chunks, cluster_origin)
	_clear_render_cluster_tracking(cluster_coord)
	var surface_arrays: Array = payload.get("surface_arrays", [])
	var render_batch_count := 0
	var chunk_surface_count := 0
	if not surface_arrays.is_empty():
		var mesh_rid := renderer.create_chunk_mesh_surfaces(
			cluster_key,
			surface_arrays,
			payload.get("surface_materials", []),
			payload.get("bounds", AABB())
		)
		var instance_rid := renderer.create_chunk_instance(
			cluster_key,
			mesh_rid,
			Transform3D.IDENTITY.translated(cluster_origin)
		)
		if mesh_rid.is_valid() and instance_rid.is_valid():
			chunk_surface_count = surface_arrays.size()
			render_batch_count += chunk_surface_count
	else:
		renderer.destroy_chunk(cluster_key)
	var instanced_keys: Array[String] = []
	var instanced_key_lookup: Dictionary = {}
	var instanced_instance_count := 0
	var instanced_batch_counts_by_kind: Dictionary = {}
	var instanced_instance_counts_by_kind: Dictionary = {}
	var instanced_max_instances_by_kind: Dictionary = {}
	var camera_culled_counts_by_kind: Dictionary = payload.get("camera_culled_counts_by_kind", {})
	for instance_payload_variant in payload.get("instance_payloads", []):
		var instance_payload: Dictionary = instance_payload_variant
		var instance_key := str(instance_payload.get("key", ""))
		var mesh_rid: RID = instance_payload.get("mesh_rid", RID())
		var instance_count := int(instance_payload.get("instance_count", 0))
		var instance_kind := str(instance_payload.get("kind", "unknown"))
		var buffer: PackedFloat32Array = instance_payload.get("buffer", PackedFloat32Array())
		if instance_key.is_empty() or not mesh_rid.is_valid() or instance_count <= 0 or buffer.is_empty():
			continue
		var instance_rid := renderer.create_or_update_multimesh_instance(
			instance_key,
			mesh_rid,
			buffer,
			instance_count,
			instance_payload.get("bounds", AABB()),
			instance_payload.get("material", null),
			{
				"kind": instance_kind,
				"type_id": str(instance_payload.get("type_id", "")),
				"instance_count": instance_count
			}
		)
		if instance_rid.is_valid():
			instanced_keys.append(instance_key)
			instanced_key_lookup[instance_key] = true
			instanced_instance_count += instance_count
			render_batch_count += 1
			_increment_int_dict(instanced_batch_counts_by_kind, instance_kind, 1)
			_increment_int_dict(instanced_instance_counts_by_kind, instance_kind, instance_count)
			_max_int_dict(instanced_max_instances_by_kind, instance_kind, instance_count)
	for previous_key_variant in previous_instanced_keys:
		var previous_key := str(previous_key_variant)
		if not instanced_key_lookup.has(previous_key):
			renderer.destroy_multimesh_instance(previous_key)
	if render_batch_count > 0:
		_render_cluster_surface_counts[cluster_coord] = render_batch_count
		if chunk_surface_count > 0:
			_render_cluster_chunk_surface_counts[cluster_coord] = chunk_surface_count
		if not instanced_keys.is_empty():
			_render_cluster_instanced_keys[cluster_coord] = instanced_keys
			_render_cluster_instanced_counts[cluster_coord] = instanced_instance_count
			_render_cluster_instanced_batch_counts[cluster_coord] = instanced_keys.size()
			_render_cluster_instanced_batch_counts_by_kind[cluster_coord] = instanced_batch_counts_by_kind
			_render_cluster_instanced_instance_counts_by_kind[cluster_coord] = instanced_instance_counts_by_kind
			_render_cluster_instanced_max_instances_by_kind[cluster_coord] = instanced_max_instances_by_kind
		if not camera_culled_counts_by_kind.is_empty():
			_render_cluster_camera_culled_counts_by_kind[cluster_coord] = camera_culled_counts_by_kind
		_sync_render_cluster_visibility(cluster_coord)
	else:
		_render_cluster_visibility.erase(cluster_coord)
	_last_rebuild_time_ms = float(Time.get_ticks_msec() - start_ms)


func _clear_render_cluster_tracking(cluster_coord: Vector2i) -> void:
	_render_cluster_surface_counts.erase(cluster_coord)
	_render_cluster_chunk_surface_counts.erase(cluster_coord)
	_render_cluster_instanced_keys.erase(cluster_coord)
	_render_cluster_instanced_counts.erase(cluster_coord)
	_render_cluster_instanced_batch_counts.erase(cluster_coord)
	_render_cluster_instanced_batch_counts_by_kind.erase(cluster_coord)
	_render_cluster_instanced_instance_counts_by_kind.erase(cluster_coord)
	_render_cluster_instanced_max_instances_by_kind.erase(cluster_coord)
	_render_cluster_camera_culled_counts_by_kind.erase(cluster_coord)


func _destroy_render_cluster(cluster_coord: Vector2i) -> void:
	if renderer != null:
		renderer.destroy_chunk(_render_cluster_key(cluster_coord))
		for key_variant in _render_cluster_instanced_keys.get(cluster_coord, []):
			renderer.destroy_multimesh_instance(str(key_variant))
	_clear_render_cluster_tracking(cluster_coord)
	_render_cluster_visibility.erase(cluster_coord)
	_render_cluster_first_request_frames.erase(cluster_coord)


func _sync_render_cluster_visibility(cluster_coord: Vector2i) -> void:
	if renderer == null:
		return
	var visible := _should_render_cluster_visible(cluster_coord)
	_render_cluster_visibility[cluster_coord] = visible
	renderer.set_chunk_visible(_render_cluster_key(cluster_coord), visible)
	for key_variant in _render_cluster_instanced_keys.get(cluster_coord, []):
		renderer.set_multimesh_visible(str(key_variant), visible)


func _should_render_cluster_visible(cluster_coord: Vector2i) -> bool:
	if not camera_cull_chunk_mesh_records:
		return true
	for chunk in _get_chunks_in_render_cluster(cluster_coord):
		if chunk == null:
			continue
		var visibility_class := VISIBILITY_CLASS_FULL
		if _chunk_visibility_class.has(chunk.chunk_coord):
			visibility_class = int(_chunk_visibility_class[chunk.chunk_coord])
		else:
			visibility_class = _chunk_visibility_class_for_camera(chunk.chunk_coord)
			_chunk_visibility_class[chunk.chunk_coord] = visibility_class
		if visibility_class != VISIBILITY_CLASS_NONE:
			return true
	return false


func _record_camera_culling_active() -> bool:
	return camera_cull_instanced_records and camera_cull_chunk_mesh_records and batch_individual_records_in_render_clusters


func _individual_record_visibility_sync_active() -> bool:
	return camera_cull_chunk_mesh_records and (not batch_individual_records_in_render_clusters or individual_record_radius_chunks > 0)


func _is_instanced_record_camera_visible(chunk: VegetationChunk, record: Dictionary, type: VegetationType) -> bool:
	if chunk == null or type == null:
		return false
	if not _record_camera_culling_active():
		return true
	if not has_render_camera:
		return true
	var full_radius := maxi(0, camera_full_detail_radius_chunks)
	if full_radius > 0 and _chunk_distance_sq_from_focus(chunk.chunk_coord) <= full_radius * full_radius:
		return true
	var visibility_class := VISIBILITY_CLASS_FULL
	if _chunk_visibility_class.has(chunk.chunk_coord):
		visibility_class = int(_chunk_visibility_class[chunk.chunk_coord])
	else:
		visibility_class = _chunk_visibility_class_for_camera(chunk.chunk_coord)
		_chunk_visibility_class[chunk.chunk_coord] = visibility_class
	if visibility_class == VISIBILITY_CLASS_NONE:
		return false
	var world_position: Vector3 = record.get("position", Vector3.ZERO)
	var max_distance := float(maxi(active_stream_radius_chunks, initial_stream_radius_chunks) * chunk_size) + float(chunk_size)
	var record_scale := maxf(0.05, float(record.get("scale", type.instance_scale)))
	var record_radius := maxf(maxf(type.support_radius, _get_type_visual_radius(type)) * record_scale, 0.5)
	if world_position.distance_squared_to(render_camera_position) > (max_distance + record_radius) * (max_distance + record_radius):
		return false
	var margin := zoom_instanced_record_cone_margin_degrees if render_camera_fov_degrees <= zoom_fov_threshold_degrees else instanced_record_cone_margin_degrees
	var prefetch_margin := zoom_instanced_record_prefetch_margin_degrees if render_camera_fov_degrees <= zoom_fov_threshold_degrees else instanced_record_prefetch_margin_degrees
	var sphere := _record_camera_sphere(type, record)
	return _is_sphere_in_camera_view(
		sphere.get("center", world_position),
		float(sphere.get("radius", record_radius)),
		margin,
		prefetch_margin
	)


func _build_render_cluster_mesh_payload(cluster_chunks: Array[VegetationChunk], cluster_origin: Vector3) -> Dictionary:
	var surface_arrays: Array = []
	var surface_materials: Array = []
	var instance_payloads: Array = []
	var bounds := AABB()
	var has_bounds := false
	var grass_cells: Array = []
	var grass_type: VegetationType = null
	var grass_groups: Dictionary = {}
	var grass_group_types: Dictionary = {}
	var record_groups: Dictionary = {}
	var record_group_types: Dictionary = {}
	var camera_culled_counts_by_kind: Dictionary = {}
	var screen_occlusion_grid: Dictionary = {}
	var ordered_cluster_chunks := cluster_chunks.duplicate()
	if _screen_occlusion_culling_active():
		ordered_cluster_chunks.sort_custom(_compare_chunk_camera_distance)

	for chunk in ordered_cluster_chunks:
		if chunk == null:
			continue
		chunk.visible_grass_cell_count = 0
		chunk.visible_chunked_tree_record_count = 0
		chunk.visible_chunked_bush_record_count = 0
		chunk.visible_chunked_rock_record_count = 0
		chunk.visible_tree_record_count = chunk.visible_individual_tree_record_count
		chunk.visible_bush_record_count = chunk.visible_individual_bush_record_count
		chunk.visible_rock_record_count = chunk.visible_individual_rock_record_count
		chunk.grass_mesh_primitive_count = 0
		chunk.grass_estimated_primitive_count = 0
		chunk.chunked_tree_estimated_primitive_count = 0
		chunk.chunked_bush_estimated_primitive_count = 0
		chunk.chunked_rock_estimated_primitive_count = 0
		chunk.tree_estimated_primitive_count = chunk.individual_tree_estimated_primitive_count
		chunk.bush_estimated_primitive_count = chunk.individual_bush_estimated_primitive_count
		chunk.rock_estimated_primitive_count = chunk.individual_rock_estimated_primitive_count

		if _should_include_chunk_mesh_records_in_cluster(chunk):
			for cell_variant in chunk.grass_cells:
				var cell: Dictionary = cell_variant
				if bool(cell.get("harvested", false)):
					continue
				var cell_type := _get_type(StringName(str(cell.get("type_id", ""))))
				if cell_type == null or not cell_type.is_chunk_mesh():
					continue
				if grass_type == null:
					grass_type = cell_type
				if use_instanced_grass_clusters:
					_append_source_record_group(grass_groups, grass_group_types, "grass", cell_type, cell)
				else:
					grass_cells.append(cell)
				chunk.visible_grass_cell_count += 1
				var grass_primitives := _get_type_mesh_primitive_count(cell_type)
				chunk.grass_mesh_primitive_count = maxi(chunk.grass_mesh_primitive_count, grass_primitives)
				chunk.grass_estimated_primitive_count += grass_primitives
		for tree_variant in chunk.tree_records:
			var tree: Dictionary = tree_variant
			var tree_type := _get_type(StringName(str(tree.get("type_id", ""))))
			if not _should_chunk_render_record(chunk, tree, tree_type):
				continue
			if not _is_instanced_record_camera_visible(chunk, tree, tree_type):
				_increment_int_dict(camera_culled_counts_by_kind, _type_render_kind(tree_type), 1)
				continue
			if _is_record_screen_occluded(tree_type, tree, screen_occlusion_grid):
				_increment_int_dict(camera_culled_counts_by_kind, _type_render_kind(tree_type), 1)
				continue
			if use_instanced_render_clusters:
				_append_source_record_group(record_groups, record_group_types, "record", tree_type, tree)
			else:
				_append_source_record_group(record_groups, record_group_types, "record_mesh", tree_type, tree)
			_mark_record_screen_occluder(tree_type, tree, screen_occlusion_grid)
			chunk.visible_chunked_tree_record_count += 1
			var tree_primitives := _get_type_mesh_primitive_count(tree_type)
			chunk.tree_mesh_primitive_count = maxi(chunk.tree_mesh_primitive_count, tree_primitives)
			chunk.chunked_tree_estimated_primitive_count += tree_primitives
		for bush_variant in chunk.cosmetic_bushes:
			var bush: Dictionary = bush_variant
			var bush_type := _get_type(StringName(str(bush.get("type_id", ""))))
			if not _should_chunk_render_record(chunk, bush, bush_type):
				continue
			if not _is_instanced_record_camera_visible(chunk, bush, bush_type):
				_increment_int_dict(camera_culled_counts_by_kind, _type_render_kind(bush_type), 1)
				continue
			if use_instanced_render_clusters:
				_append_source_record_group(record_groups, record_group_types, "record", bush_type, bush)
			else:
				_append_source_record_group(record_groups, record_group_types, "record_mesh", bush_type, bush)
			chunk.visible_chunked_bush_record_count += 1
			var bush_primitives := _get_type_mesh_primitive_count(bush_type)
			chunk.bush_mesh_primitive_count = maxi(chunk.bush_mesh_primitive_count, bush_primitives)
			chunk.chunked_bush_estimated_primitive_count += bush_primitives
		for rock_variant in chunk.rock_records:
			var rock: Dictionary = rock_variant
			var rock_type := _get_type(StringName(str(rock.get("type_id", ""))))
			if not _should_chunk_render_record(chunk, rock, rock_type):
				continue
			if not _is_instanced_record_camera_visible(chunk, rock, rock_type):
				_increment_int_dict(camera_culled_counts_by_kind, _type_render_kind(rock_type), 1)
				continue
			if use_instanced_render_clusters:
				_append_source_record_group(record_groups, record_group_types, "record", rock_type, rock)
			else:
				_append_source_record_group(record_groups, record_group_types, "record_mesh", rock_type, rock)
			chunk.visible_chunked_rock_record_count += 1
			var rock_primitives := _get_type_mesh_primitive_count(rock_type)
			chunk.rock_mesh_primitive_count = maxi(chunk.rock_mesh_primitive_count, rock_primitives)
			chunk.chunked_rock_estimated_primitive_count += rock_primitives

		chunk.visible_tree_record_count = chunk.visible_individual_tree_record_count + chunk.visible_chunked_tree_record_count
		chunk.visible_bush_record_count = chunk.visible_individual_bush_record_count + chunk.visible_chunked_bush_record_count
		chunk.visible_rock_record_count = chunk.visible_individual_rock_record_count + chunk.visible_chunked_rock_record_count
		chunk.tree_estimated_primitive_count = chunk.individual_tree_estimated_primitive_count + chunk.chunked_tree_estimated_primitive_count
		chunk.bush_estimated_primitive_count = chunk.individual_bush_estimated_primitive_count + chunk.chunked_bush_estimated_primitive_count
		chunk.rock_estimated_primitive_count = chunk.individual_rock_estimated_primitive_count + chunk.chunked_rock_estimated_primitive_count

	if use_instanced_grass_clusters:
		for grass_group_key_variant in grass_groups.keys():
			var grass_group_key := str(grass_group_key_variant)
			var grouped_grass_type: VegetationType = grass_group_types.get(grass_group_key, null) as VegetationType
			var grouped_grass_records: Array = grass_groups.get(grass_group_key, [])
			if grouped_grass_type == null or grouped_grass_records.is_empty():
				continue
			var grass_instance_payload := _build_render_cluster_multimesh_payload(cluster_origin, grass_group_key, grouped_grass_type, grouped_grass_records, false, true)
			if not grass_instance_payload.is_empty():
				instance_payloads.append(grass_instance_payload)
	elif grass_type != null and not grass_cells.is_empty():
		var grass_result := _build_native_source_records_surface(grass_type, grass_cells, cluster_origin, false)
		if not grass_result.is_empty():
			surface_arrays.append(grass_result.get("arrays", []))
			surface_materials.append(_get_grass_material(grass_type))
			var grass_bounds: AABB = grass_result.get("bounds", AABB())
			bounds = grass_bounds if not has_bounds else _merge_aabb(bounds, grass_bounds)
			has_bounds = true
	for group_key_variant in record_groups.keys():
		var group_key := str(group_key_variant)
		var group_type: VegetationType = record_group_types.get(group_key, null) as VegetationType
		var records: Array = record_groups.get(group_key, [])
		if group_type == null or records.is_empty():
			continue
		if use_instanced_render_clusters:
			var instance_payload := _build_render_cluster_multimesh_payload(cluster_origin, group_key, group_type, records, true, true)
			if not instance_payload.is_empty():
				instance_payloads.append(instance_payload)
			continue
		var record_result := _build_native_source_records_surface(group_type, records, cluster_origin, true)
		if record_result.is_empty():
			continue
		surface_arrays.append(record_result.get("arrays", []))
		surface_materials.append(group_type.get_material_for_surface(0))
		var record_bounds: AABB = record_result.get("bounds", AABB())
		bounds = record_bounds if not has_bounds else _merge_aabb(bounds, record_bounds)
		has_bounds = true

	return {
		"surface_arrays": surface_arrays,
		"surface_materials": surface_materials,
		"instance_payloads": instance_payloads,
		"camera_culled_counts_by_kind": camera_culled_counts_by_kind,
		"bounds": bounds
	}


func _build_render_cluster_multimesh_payload(
		cluster_origin: Vector3,
		group_key: String,
		type: VegetationType,
		records: Array,
		rotation_is_turns: bool = true,
		resolve_record_type: bool = false
) -> Dictionary:
	if type == null or records.is_empty():
		return {}
	var source_mesh := type.source_mesh if type.source_mesh != null else type.get_source_mesh()
	if source_mesh == null:
		return {}
	var visible_records: Array = []
	for record_variant in records:
		var record: Dictionary = record_variant
		var record_type := type
		if resolve_record_type:
			record_type = _get_type(StringName(str(record.get("type_id", type.id))))
			if record_type == null:
				continue
			var record_source_mesh := record_type.source_mesh if record_type.source_mesh != null else record_type.get_source_mesh()
			if record_source_mesh != source_mesh:
				continue
		if not _is_render_record_visible(record, record_type):
			continue
		visible_records.append(record)
	if visible_records.is_empty():
		return {}
	var buffer := PackedFloat32Array()
	var bounds := AABB()
	var native_payload := _try_build_multimesh_transform_payload(type, source_mesh, visible_records, rotation_is_turns)
	if not native_payload.is_empty():
		buffer = native_payload.get("buffer", PackedFloat32Array())
		bounds = native_payload.get("bounds", AABB())
	else:
		var fallback := _build_gdscript_multimesh_transform_payload(type, visible_records, rotation_is_turns)
		if fallback.is_empty():
			return {}
		buffer = fallback.get("buffer", PackedFloat32Array())
		bounds = fallback.get("bounds", AABB())
	if buffer.is_empty():
		return {}
	var cluster_coord := _render_cluster_coord_for_origin(cluster_origin)
	return {
		"key": "%s_%s" % [_render_cluster_key(cluster_coord), group_key],
		"kind": _type_render_kind(type),
		"type_id": String(type.id),
		"mesh_rid": source_mesh.get_rid(),
		"buffer": buffer,
		"instance_count": int(buffer.size() / MULTIMESH_FLOATS_PER_INSTANCE_3D),
		"bounds": bounds,
		"material": type.get_material_for_surface(0)
	}


func _try_build_multimesh_transform_payload(type: VegetationType, source_mesh: Mesh, records: Array, rotation_is_turns: bool) -> Dictionary:
	if native_chunk_builder == null:
		_ensure_native_backends()
	if native_chunk_builder == null or not native_chunk_builder.has_method("build_multimesh_transform_buffer"):
		return {}
	if type == null or source_mesh == null or records.is_empty():
		return {}
	var source_transform := type.mesh_source_transform if type.source_mesh != null else type.get_source_transform()
	var result: Dictionary = native_chunk_builder.build_multimesh_transform_buffer(
		records,
		source_transform,
		source_mesh.get_aabb(),
		rotation_is_turns
	)
	if result.is_empty() or int(result.get("visible_count", 0)) <= 0:
		return {}
	var buffer: PackedFloat32Array = result.get("buffer", PackedFloat32Array())
	return result if not buffer.is_empty() else {}


func _build_gdscript_multimesh_transform_payload(type: VegetationType, records: Array, rotation_is_turns: bool) -> Dictionary:
	var transforms: Array[Transform3D] = []
	var bounds := AABB()
	var has_bounds := false
	for record_variant in records:
		var record: Dictionary = record_variant
		var transform := _build_render_record_world_transform(type, record, rotation_is_turns)
		transforms.append(transform)
		var record_bounds := _record_render_bounds(type, record, rotation_is_turns)
		bounds = bounds.merge(record_bounds) if has_bounds else record_bounds
		has_bounds = true
	if transforms.is_empty():
		return {}
	return {
		"buffer": _pack_transform_buffer(transforms),
		"bounds": bounds
	}


func _type_render_kind(type: VegetationType) -> String:
	if type == null:
		return "unknown"
	match type.category:
		VegetationType.Category.GRASS, VegetationType.Category.WEED, VegetationType.Category.FLOWER:
			return "grass"
		VegetationType.Category.TREE, VegetationType.Category.STUMP, VegetationType.Category.LOG:
			return "tree"
		VegetationType.Category.BUSH:
			return "bush"
		VegetationType.Category.ROCK:
			return "rock"
		_:
			return "unknown"


func _build_render_record_world_transform(type: VegetationType, record: Dictionary, rotation_is_turns: bool = true) -> Transform3D:
	var rotation := float(record.get("rotation", 0.0))
	if rotation_is_turns:
		rotation *= TAU
	var scale := maxf(0.01, float(record.get("scale", type.instance_scale)))
	var transform := Transform3D.IDENTITY
	transform = transform.rotated(Vector3.UP, rotation)
	transform = transform.scaled(Vector3.ONE * scale)
	transform.origin = record.get("position", Vector3.ZERO)
	var source_transform := type.mesh_source_transform if type.source_mesh != null else type.get_source_transform()
	return transform * source_transform


func _render_cluster_coord_for_origin(cluster_origin: Vector3) -> Vector2i:
	var size := maxi(1, render_cluster_size_chunks * chunk_size)
	return Vector2i(
		int(floor(cluster_origin.x / float(size))),
		int(floor(cluster_origin.z / float(size)))
	)


func _record_render_bounds(type: VegetationType, record: Dictionary, rotation_is_turns: bool = true) -> AABB:
	var position: Vector3 = record.get("position", Vector3.ZERO)
	var scale := maxf(0.05, float(record.get("scale", type.instance_scale)))
	if type.category != VegetationType.Category.GRASS \
			and type.category != VegetationType.Category.WEED \
			and type.category != VegetationType.Category.FLOWER:
		var local_bounds := _get_type_visual_bounds(type)
		if local_bounds.size != Vector3.ZERO:
			var rotation := float(record.get("rotation", 0.0))
			if rotation_is_turns:
				rotation *= TAU
			var transform := Transform3D.IDENTITY
			transform = transform.rotated(Vector3.UP, rotation)
			transform = transform.scaled(Vector3.ONE * scale)
			transform.origin = position
			return _transform_aabb(local_bounds, transform)
	var radius := maxf(type.support_radius * scale, 0.5)
	var height := maxf(type.support_height * scale, radius * 2.0)
	if type.category == VegetationType.Category.GRASS or type.category == VegetationType.Category.WEED or type.category == VegetationType.Category.FLOWER:
		height = maxf(height, 1.25 * scale)
	return AABB(
		Vector3(position.x - radius, position.y - radius, position.z - radius),
		Vector3(radius * 2.0, height + radius * 2.0, radius * 2.0)
	)


func _get_type_visual_bounds(type: VegetationType) -> AABB:
	if type == null:
		return AABB()
	var cache_key := String(type.id)
	if _type_visual_bounds_cache.has(cache_key):
		return _type_visual_bounds_cache[cache_key]
	var source_mesh := type.source_mesh if type.source_mesh != null else type.get_source_mesh()
	if source_mesh == null:
		_type_visual_bounds_cache[cache_key] = AABB()
		return AABB()
	var source_transform := type.mesh_source_transform if type.source_mesh != null else type.get_source_transform()
	var bounds := _transform_aabb(source_mesh.get_aabb(), source_transform)
	_type_visual_bounds_cache[cache_key] = bounds
	return bounds


func _get_type_visual_radius(type: VegetationType) -> float:
	var bounds := _get_type_visual_bounds(type)
	if bounds.size == Vector3.ZERO:
		return 0.0
	var min_v := bounds.position
	var max_v := bounds.position + bounds.size
	return maxf(maxf(absf(min_v.x), absf(max_v.x)), maxf(absf(min_v.z), absf(max_v.z)))


func _transform_aabb(aabb: AABB, transform: Transform3D) -> AABB:
	if aabb.size == Vector3.ZERO:
		return aabb
	var min_v := aabb.position
	var max_v := aabb.position + aabb.size
	var points := [
		Vector3(min_v.x, min_v.y, min_v.z),
		Vector3(max_v.x, min_v.y, min_v.z),
		Vector3(min_v.x, max_v.y, min_v.z),
		Vector3(max_v.x, max_v.y, min_v.z),
		Vector3(min_v.x, min_v.y, max_v.z),
		Vector3(max_v.x, min_v.y, max_v.z),
		Vector3(min_v.x, max_v.y, max_v.z),
		Vector3(max_v.x, max_v.y, max_v.z)
	]
	var transformed := AABB(transform * points[0], Vector3.ZERO)
	for i in range(1, points.size()):
		transformed = transformed.expand(transform * points[i])
	return transformed


func _pack_transform_buffer(transforms: Array[Transform3D]) -> PackedFloat32Array:
	var buffer := PackedFloat32Array()
	buffer.resize(transforms.size() * MULTIMESH_FLOATS_PER_INSTANCE_3D)
	var write_index := 0
	for transform in transforms:
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


func _append_source_record_group(record_groups: Dictionary, record_group_types: Dictionary, prefix: String, type: VegetationType, record: Dictionary) -> void:
	if type == null or record.is_empty():
		return
	var source_mesh := type.source_mesh if type.source_mesh != null else type.get_source_mesh()
	if source_mesh == null:
		return
	var material := type.get_material_for_surface(0)
	var material_id := material.get_instance_id() if material != null else 0
	var group_key := "%s_%s_%d_%d" % [prefix, _type_render_kind(type), source_mesh.get_instance_id(), material_id]
	if not record_groups.has(group_key):
		record_groups[group_key] = []
		record_group_types[group_key] = type
	var records: Array = record_groups[group_key]
	records.append(record)
	record_groups[group_key] = records


func _increment_int_dict(counts: Dictionary, key: String, amount: int) -> void:
	counts[key] = int(counts.get(key, 0)) + amount


func _max_int_dict(counts: Dictionary, key: String, value: int) -> void:
	counts[key] = maxi(int(counts.get(key, 0)), value)


func _append_record_group(record_groups: Dictionary, record_group_types: Dictionary, type: VegetationType, record: Dictionary) -> void:
	if type == null or record.is_empty():
		return
	var group_key := String(type.id)
	if not record_groups.has(group_key):
		record_groups[group_key] = []
		record_group_types[group_key] = type
	var records: Array = record_groups[group_key]
	records.append(record)
	record_groups[group_key] = records


func _should_include_chunk_mesh_records_in_cluster(chunk: VegetationChunk) -> bool:
	if chunk == null:
		return false
	return true


func _build_native_source_records_surface(type: VegetationType, records: Array, render_origin: Vector3, rotation_is_turns: bool) -> Dictionary:
	if type == null or records.is_empty():
		return {}
	if native_chunk_builder == null:
		_ensure_native_backends()
	if native_chunk_builder == null:
		return _build_gdscript_source_records_surface(type, records, render_origin)
	var source_mesh := type.source_mesh if type.source_mesh != null else type.get_source_mesh()
	if source_mesh == null or source_mesh.get_surface_count() <= 0:
		return {}
	var source_arrays := _get_cached_minimal_source_surface_arrays(source_mesh, 0) if _type_uses_minimal_chunk_arrays(type) else _get_cached_source_surface_arrays(source_mesh, 0)
	if source_arrays.is_empty():
		return {}
	var source_transform := type.mesh_source_transform if type.source_mesh != null else type.get_source_transform()
	var result: Dictionary = native_chunk_builder.build_source_mesh_instances(
		records,
		source_arrays,
		source_transform,
		render_origin,
		_get_native_grass_type_colors(),
		rotation_is_turns
	)
	if result.is_empty() or int(result.get("visible_count", 0)) <= 0:
		return {}
	var arrays: Array = result.get("arrays", [])
	return result if not arrays.is_empty() else {}


func _build_gdscript_source_records_surface(type: VegetationType, records: Array, render_origin: Vector3) -> Dictionary:
	var source_mesh := type.source_mesh if type.source_mesh != null else type.get_source_mesh()
	if source_mesh == null or source_mesh.get_surface_count() <= 0:
		return {}
	var payload := _make_mesh_payload()
	var source_cache: Dictionary = {}
	for record_variant in records:
		var record: Dictionary = record_variant
		if not _is_render_record_visible(record, type):
			continue
		var transform := _build_record_transform_for_origin(type, record, render_origin)
		_append_chunk_mesh_source(type, source_mesh, transform, payload, source_cache)
	if int(payload.get("vertex_count", 0)) <= 0:
		return {}
	return payload


func _refresh_chunk_support(chunk: VegetationChunk) -> void:
	if chunk == null:
		return
	var start_ms := Time.get_ticks_msec()
	var refresh_count := 0
	for cell in chunk.grass_cells:
		if bool(cell.get("harvested", false)):
			continue
		var position: Vector3 = cell.get("position", Vector3.ZERO)
		if not _is_position_supported(position, 0.1):
			cell["harvested"] = true
			cell["regrow_time"] = 0.0
			refresh_count += 1
	for bush in chunk.cosmetic_bushes:
		if bool(bush.get("harvested", false)):
			continue
		var position: Vector3 = bush.get("position", Vector3.ZERO)
		if not _is_position_supported(position, 0.35):
			bush["harvested"] = true
			bush["regrow_time"] = _type_regrow_seconds(StringName(str(bush.get("type_id", ""))), 0.0)
			refresh_count += 1
	for rock in chunk.rock_records:
		if bool(rock.get("harvested", false)):
			continue
		var position: Vector3 = rock.get("position", Vector3.ZERO)
		if not _is_position_supported(position, 0.2):
			rock["harvested"] = true
			rock["regrow_time"] = _type_regrow_seconds(StringName(str(rock.get("type_id", ""))), 0.0)
			refresh_count += 1
	for tree in chunk.tree_records:
		if bool(tree.get("chopped", false)):
			continue
		var position: Vector3 = tree.get("position", Vector3.ZERO)
		if not _is_tree_supported(tree, position):
			_mark_tree_for_stump(chunk, tree)
			refresh_count += 1
	chunk.last_support_refresh_time_ms = float(Time.get_ticks_msec() - start_ms)
	_last_support_refresh_time_ms = chunk.last_support_refresh_time_ms


func _sync_individual_instances(chunk: VegetationChunk) -> void:
	_chunk_visibility_class[chunk.chunk_coord] = _chunk_visibility_class_for_camera(chunk.chunk_coord)
	var tree_stats := _sync_record_list_instances(chunk, chunk.tree_records)
	var bush_stats := _sync_record_list_instances(chunk, chunk.cosmetic_bushes)
	var rock_stats := _sync_record_list_instances(chunk, chunk.rock_records)
	chunk.visible_individual_tree_record_count = int(tree_stats.get("visible_count", 0))
	chunk.visible_chunked_tree_record_count = 0
	chunk.visible_tree_record_count = chunk.visible_individual_tree_record_count
	chunk.visible_individual_bush_record_count = int(bush_stats.get("visible_count", 0))
	chunk.visible_chunked_bush_record_count = 0
	chunk.visible_bush_record_count = chunk.visible_individual_bush_record_count
	chunk.visible_individual_rock_record_count = int(rock_stats.get("visible_count", 0))
	chunk.visible_chunked_rock_record_count = 0
	chunk.visible_rock_record_count = chunk.visible_individual_rock_record_count
	chunk.tree_mesh_primitive_count = int(tree_stats.get("max_mesh_primitives", 0))
	chunk.bush_mesh_primitive_count = int(bush_stats.get("max_mesh_primitives", 0))
	chunk.rock_mesh_primitive_count = int(rock_stats.get("max_mesh_primitives", 0))
	chunk.individual_tree_estimated_primitive_count = int(tree_stats.get("estimated_primitives", 0))
	chunk.chunked_tree_estimated_primitive_count = 0
	chunk.tree_estimated_primitive_count = chunk.individual_tree_estimated_primitive_count
	chunk.individual_bush_estimated_primitive_count = int(bush_stats.get("estimated_primitives", 0))
	chunk.chunked_bush_estimated_primitive_count = 0
	chunk.bush_estimated_primitive_count = chunk.individual_bush_estimated_primitive_count
	chunk.individual_rock_estimated_primitive_count = int(rock_stats.get("estimated_primitives", 0))
	chunk.chunked_rock_estimated_primitive_count = 0
	chunk.rock_estimated_primitive_count = chunk.individual_rock_estimated_primitive_count
	chunk.support_points_total = int(tree_stats.get("support_points_total", 0)) \
		+ int(bush_stats.get("support_points_total", 0)) \
		+ int(rock_stats.get("support_points_total", 0))


func _sync_record_list_instances(chunk: VegetationChunk, records: Array) -> Dictionary:
	if renderer == null:
		return {}
	var visible_count := 0
	var estimated_primitives := 0
	var max_mesh_primitives := 0
	var support_points_total := 0
	for record_variant in records:
		var record: Dictionary = record_variant
		var type := _get_type(StringName(str(record.get("type_id", ""))))
		if type == null:
			continue
		var record_id := int(record.get("id", 0))
		var instance_rid: RID = record.get("instance_rid", RID())
		if _should_chunk_render_record(chunk, record, type):
			if instance_rid.is_valid():
				renderer.destroy_instance(instance_rid)
				record["instance_rid"] = RID()
				_clear_record_hidden_state(record)
			chunk.individual_instance_rids.erase(record_id)
			spatial_grid.register_record(type.id, record_id, chunk.chunk_coord, record)
			continue
		if not type.is_individual_instance():
			if instance_rid.is_valid():
				renderer.destroy_instance(instance_rid)
				record["instance_rid"] = RID()
				_clear_record_hidden_state(record)
			chunk.individual_instance_rids.erase(record_id)
			spatial_grid.register_record(type.id, record_id, chunk.chunk_coord, record)
			continue
		if not _should_render_individual_record(chunk, record, type):
			if instance_rid.is_valid():
				renderer.set_instance_visible(instance_rid, false)
				_mark_record_hidden(record)
			chunk.individual_instance_rids.erase(record_id)
			spatial_grid.register_record(type.id, record_id, chunk.chunk_coord, record)
			continue
		var type_is_stump := type.category == VegetationType.Category.STUMP
		var should_hide := bool(record.get("harvested", false))
		if bool(record.get("chopped", false)) and not type_is_stump:
			should_hide = true
		var health := float(record.get("health", type.health))
		if health <= 0.0 and not type_is_stump:
			should_hide = true
		if should_hide:
			if instance_rid.is_valid():
				renderer.destroy_instance(instance_rid)
			record["instance_rid"] = RID()
			_clear_record_hidden_state(record)
			chunk.individual_instance_rids.erase(record_id)
			spatial_grid.register_record(type.id, record_id, chunk.chunk_coord, record)
			continue
		var transform := _build_individual_transform(type, record)
		if instance_rid.is_valid():
			_clear_record_hidden_state(record)
			renderer.set_instance_visible(instance_rid, true)
			renderer.set_instance_transform(instance_rid, transform)
		else:
			var source_mesh := type.source_mesh if type.source_mesh != null else type.get_source_mesh()
			if source_mesh == null:
				continue
			instance_rid = renderer.create_instance(source_mesh.get_rid(), transform)
			record["instance_rid"] = instance_rid
			_clear_record_hidden_state(record)
			renderer.set_instance_visible(instance_rid, true)
		if type.material != null:
			renderer.set_instance_material_override(instance_rid, type.material)
		chunk.individual_instance_rids[record_id] = instance_rid
		spatial_grid.register_record(type.id, record_id, chunk.chunk_coord, record)
		visible_count += 1
		var primitive_count := _get_type_mesh_primitive_count(type)
		max_mesh_primitives = maxi(max_mesh_primitives, primitive_count)
		estimated_primitives += primitive_count
		if type.category == VegetationType.Category.TREE or type.category == VegetationType.Category.STUMP or type.category == VegetationType.Category.LOG:
			support_points_total += type.support_points.size()
	return {
		"visible_count": visible_count,
		"estimated_primitives": estimated_primitives,
		"max_mesh_primitives": max_mesh_primitives,
		"support_points_total": support_points_total
	}


func _build_chunk_mesh_payload(chunk: VegetationChunk) -> Dictionary:
	var grass_payload := _make_mesh_payload()
	var bush_payload := _make_mesh_payload()
	var rock_payload := _make_mesh_payload()
	var tree_payload := _make_mesh_payload()
	var bush_source_cache: Dictionary = {}
	var rock_source_cache: Dictionary = {}
	var tree_source_cache: Dictionary = {}
	var grass_material: Material = null
	var bush_material: Material = null
	var rock_material: Material = null
	var tree_material: Material = null
	var visible_grass_cell_count := 0
	var visible_bush_record_count := 0
	var visible_rock_record_count := 0
	var chunked_tree_record_count := 0
	var grass_estimated_primitives := 0
	var bush_estimated_primitives := 0
	var rock_estimated_primitives := 0
	var chunked_tree_estimated_primitives := 0
	var grass_mesh_primitives := 0
	var bush_mesh_primitives := 0
	var rock_mesh_primitives := 0
	var grass_max_batch_instances := 0
	var native_grass_payload := _try_build_native_grass_source_payload(chunk, grass_payload)
	if native_grass_payload.is_empty() and allow_debug_grass_cards:
		native_grass_payload = _try_build_native_grass_payload(chunk, grass_payload)
	if not native_grass_payload.is_empty():
		visible_grass_cell_count = int(native_grass_payload.get("visible_count", 0))
		grass_estimated_primitives = int(native_grass_payload.get("primitive_count", 0))
		grass_mesh_primitives = int(ceil(float(grass_estimated_primitives) / float(visible_grass_cell_count))) if visible_grass_cell_count > 0 else 0
		var native_type := _get_type(StringName(str(native_grass_payload.get("first_type_id", ""))))
		if native_type != null:
			grass_material = _get_grass_material(native_type)
	elif allow_debug_grass_cards:
		for cell_variant in chunk.grass_cells:
			var cell: Dictionary = cell_variant
			if bool(cell.get("harvested", false)):
				continue
			var type := _get_type(StringName(str(cell.get("type_id", ""))))
			if type == null or not type.is_chunk_mesh():
				continue
			var primitive_count := GRASS_CARD_PRIMITIVES
			visible_grass_cell_count += 1
			grass_estimated_primitives += primitive_count
			grass_mesh_primitives = maxi(grass_mesh_primitives, primitive_count)
			if grass_material == null:
				grass_material = _get_grass_material(type)
			if not _append_grass_card_to_payload(type, cell, grass_payload):
				continue

	for bush_variant in chunk.cosmetic_bushes:
		var bush: Dictionary = bush_variant
		var bush_type := _get_type(StringName(str(bush.get("type_id", ""))))
		if not _is_chunk_mesh_record_visible(bush, bush_type):
			continue
		_destroy_record_instance_if_any(chunk, bush)
		var bush_mesh := bush_type.source_mesh if bush_type.source_mesh != null else bush_type.get_source_mesh()
		if bush_mesh == null or bush_mesh.get_surface_count() <= 0:
			continue
		if bush_material == null:
			bush_material = bush_type.get_material_for_surface(0)
		var bush_transform := _build_chunk_record_transform(bush_type, bush, chunk)
		if not _append_chunk_mesh_source(bush_type, bush_mesh, bush_transform, bush_payload, bush_source_cache):
			continue
		visible_bush_record_count += 1
		var bush_primitive_count := _get_type_mesh_primitive_count(bush_type)
		bush_mesh_primitives = maxi(bush_mesh_primitives, bush_primitive_count)
		bush_estimated_primitives += bush_primitive_count

	for rock_variant in chunk.rock_records:
		var rock: Dictionary = rock_variant
		var rock_type := _get_type(StringName(str(rock.get("type_id", ""))))
		if not _is_chunk_mesh_record_visible(rock, rock_type):
			continue
		_destroy_record_instance_if_any(chunk, rock)
		var rock_mesh := rock_type.source_mesh if rock_type.source_mesh != null else rock_type.get_source_mesh()
		if rock_mesh == null or rock_mesh.get_surface_count() <= 0:
			continue
		if rock_material == null:
			rock_material = rock_type.get_material_for_surface(0)
		var rock_transform := _build_chunk_record_transform(rock_type, rock, chunk)
		if not _append_chunk_mesh_source(rock_type, rock_mesh, rock_transform, rock_payload, rock_source_cache):
			continue
		visible_rock_record_count += 1
		var rock_primitive_count := _get_type_mesh_primitive_count(rock_type)
		rock_mesh_primitives = maxi(rock_mesh_primitives, rock_primitive_count)
		rock_estimated_primitives += rock_primitive_count

	for tree_variant in chunk.tree_records:
		var tree: Dictionary = tree_variant
		var tree_type := _get_type(StringName(str(tree.get("type_id", ""))))
		if not _should_chunk_render_record(chunk, tree, tree_type):
			continue
		if not _is_render_record_visible(tree, tree_type):
			continue
		var tree_mesh := tree_type.source_mesh if tree_type.source_mesh != null else tree_type.get_source_mesh()
		if tree_mesh == null or tree_mesh.get_surface_count() <= 0:
			continue
		if tree_material == null:
			tree_material = tree_type.get_material_for_surface(0)
		var tree_transform := _build_chunk_record_transform(tree_type, tree, chunk)
		if not _append_chunk_mesh_source(tree_type, tree_mesh, tree_transform, tree_payload, tree_source_cache):
			continue
		chunked_tree_record_count += 1
		var tree_primitive_count := _get_type_mesh_primitive_count(tree_type)
		chunked_tree_estimated_primitives += tree_primitive_count

	var surface_arrays: Array = []
	var surface_materials: Array = []
	_append_payload_surface(grass_payload, grass_material, surface_arrays, surface_materials)
	_append_payload_surface(bush_payload, bush_material, surface_arrays, surface_materials)
	_append_payload_surface(rock_payload, rock_material, surface_arrays, surface_materials)
	_append_payload_surface(tree_payload, tree_material, surface_arrays, surface_materials)
	if surface_arrays.is_empty():
		return {
			"visible_grass_cell_count": 0,
			"visible_bush_record_count": 0,
			"visible_rock_record_count": 0,
			"grass_estimated_primitives": 0,
			"bush_estimated_primitives": 0,
			"rock_estimated_primitives": 0,
			"grass_mesh_primitive_count": 0,
			"bush_mesh_primitive_count": 0,
			"rock_mesh_primitive_count": 0,
			"grass_max_batch_instances": 0
		}
	grass_max_batch_instances = visible_grass_cell_count
	return {
		"surface_arrays": surface_arrays,
		"surface_materials": surface_materials,
		"bounds": _merge_aabb(_merge_aabb(_merge_aabb(grass_payload.get("bounds", AABB()), bush_payload.get("bounds", AABB())), rock_payload.get("bounds", AABB())), tree_payload.get("bounds", AABB())),
		"visible_grass_cell_count": visible_grass_cell_count,
		"visible_bush_record_count": visible_bush_record_count,
		"visible_rock_record_count": visible_rock_record_count,
		"grass_estimated_primitives": grass_estimated_primitives,
		"bush_estimated_primitives": bush_estimated_primitives,
		"rock_estimated_primitives": rock_estimated_primitives,
		"chunked_tree_record_count": chunked_tree_record_count,
		"chunked_tree_estimated_primitives": chunked_tree_estimated_primitives,
		"grass_mesh_primitive_count": grass_mesh_primitives,
		"bush_mesh_primitive_count": bush_mesh_primitives,
		"rock_mesh_primitive_count": rock_mesh_primitives,
		"grass_max_batch_instances": grass_max_batch_instances
	}


func _append_payload_surface(payload: Dictionary, material: Material, surface_arrays: Array, surface_materials: Array) -> void:
	if int(payload.get("vertex_count", 0)) <= 0:
		return
	var arrays: Array = payload.get("arrays", [])
	if arrays.is_empty():
		return
	surface_arrays.append(arrays)
	surface_materials.append(material)


func _try_build_native_grass_payload(chunk: VegetationChunk, payload: Dictionary) -> Dictionary:
	if chunk == null or chunk.grass_cells.is_empty():
		return {}
	if native_chunk_builder == null:
		_ensure_native_backends()
	if native_chunk_builder == null:
		return {}
	var start_us := Time.get_ticks_usec()
	var result: Dictionary = native_chunk_builder.build_grass_card_mesh(
		chunk.grass_cells,
		_get_native_grass_type_colors(),
		GRASS_CARD_HALF_WIDTH,
		GRASS_CARD_HEIGHT
	)
	_last_native_grass_build_time_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
	if result.is_empty() or int(result.get("visible_count", 0)) <= 0:
		return {}
	var arrays: Array = result.get("arrays", [])
	if arrays.is_empty():
		return {}
	payload["arrays"] = arrays
	payload["vertex_count"] = int(result.get("vertex_count", 0))
	payload["bounds"] = result.get("bounds", AABB())
	payload["has_bounds"] = bool(result.get("has_bounds", false))
	return result


func _try_build_native_grass_source_payload(chunk: VegetationChunk, payload: Dictionary) -> Dictionary:
	if not use_grass_source_meshes or chunk == null or chunk.grass_cells.is_empty():
		return {}
	if native_chunk_builder == null:
		_ensure_native_backends()
	if native_chunk_builder == null:
		return {}
	var source_type: VegetationType = null
	for cell_variant in chunk.grass_cells:
		var cell: Dictionary = cell_variant
		if bool(cell.get("harvested", false)):
			continue
		source_type = _get_type(StringName(str(cell.get("type_id", ""))))
		if source_type != null:
			break
	if source_type == null:
		return {}
	var source_mesh := source_type.source_mesh if source_type.source_mesh != null else source_type.get_source_mesh()
	if source_mesh == null or source_mesh.get_surface_count() <= 0:
		return {}
	var source_arrays := _get_cached_minimal_source_surface_arrays(source_mesh, 0)
	if source_arrays.is_empty():
		return {}
	var source_transform := source_type.mesh_source_transform if source_type.source_mesh != null else source_type.get_source_transform()
	var chunk_origin := Vector3(chunk.chunk_coord.x * chunk_size, 0.0, chunk.chunk_coord.y * chunk_size)
	var start_us := Time.get_ticks_usec()
	var result: Dictionary = native_chunk_builder.build_source_mesh_instances(
		chunk.grass_cells,
		source_arrays,
		source_transform,
		chunk_origin,
		_get_native_grass_type_colors(),
		false
	)
	_last_native_grass_build_time_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
	if result.is_empty() or int(result.get("visible_count", 0)) <= 0:
		return {}
	var arrays: Array = result.get("arrays", [])
	if arrays.is_empty():
		return {}
	payload["arrays"] = arrays
	payload["vertex_count"] = int(result.get("vertex_count", 0))
	payload["bounds"] = result.get("bounds", AABB())
	payload["has_bounds"] = bool(result.get("has_bounds", false))
	return result


func _get_native_grass_type_colors() -> Dictionary:
	if not _native_grass_type_colors_cache.is_empty():
		return _native_grass_type_colors_cache
	if registry == null:
		return {}
	for type in _get_types_for_category(VegetationType.Category.GRASS):
		if type == null:
			continue
		_native_grass_type_colors_cache[type.id] = _grass_color_for_type(type, 1.0)
	if _native_grass_type_colors_cache.is_empty():
		var fallback := _get_type(&"grass_green")
		if fallback != null:
			_native_grass_type_colors_cache[fallback.id] = _grass_color_for_type(fallback, 1.0)
	return _native_grass_type_colors_cache


func _get_grass_material(type: VegetationType) -> Material:
	if type != null and type.material != null:
		return type.material
	var source_mesh: Mesh = null
	if type != null:
		source_mesh = type.source_mesh if type.source_mesh != null else type.get_source_mesh()
	if source_mesh == null:
		source_mesh = _get_fallback_grass_mesh()
	if source_mesh != null and source_mesh.get_surface_count() > 0:
		return source_mesh.surface_get_material(0)
	return null


func _get_cached_source_surface_arrays(source_mesh: Mesh, surface_index: int = 0) -> Array:
	if source_mesh == null or source_mesh.get_surface_count() <= surface_index:
		return []
	var cache_key := "%d:%d" % [source_mesh.get_instance_id(), surface_index]
	if _source_surface_arrays_cache.has(cache_key):
		return _source_surface_arrays_cache[cache_key]
	var arrays := source_mesh.surface_get_arrays(surface_index)
	if not arrays.is_empty():
		_source_surface_arrays_cache[cache_key] = arrays
	return arrays


func _type_uses_minimal_chunk_arrays(type: VegetationType) -> bool:
	if type == null:
		return false
	return type.category == VegetationType.Category.GRASS \
		or type.category == VegetationType.Category.WEED \
		or type.category == VegetationType.Category.FLOWER


func _get_cached_minimal_source_surface_arrays(source_mesh: Mesh, surface_index: int = 0) -> Array:
	if source_mesh == null or source_mesh.get_surface_count() <= surface_index:
		return []
	var cache_key := "minimal:%d:%d" % [source_mesh.get_instance_id(), surface_index]
	if _source_surface_arrays_cache.has(cache_key):
		return _source_surface_arrays_cache[cache_key]
	var source_arrays := source_mesh.surface_get_arrays(surface_index)
	if source_arrays.is_empty() or source_arrays.size() <= Mesh.ARRAY_VERTEX or source_arrays[Mesh.ARRAY_VERTEX] == null:
		return []
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = source_arrays[Mesh.ARRAY_VERTEX]
	if source_arrays.size() > Mesh.ARRAY_TEX_UV and source_arrays[Mesh.ARRAY_TEX_UV] != null:
		arrays[Mesh.ARRAY_TEX_UV] = source_arrays[Mesh.ARRAY_TEX_UV]
	if source_arrays.size() > Mesh.ARRAY_INDEX and source_arrays[Mesh.ARRAY_INDEX] != null:
		arrays[Mesh.ARRAY_INDEX] = source_arrays[Mesh.ARRAY_INDEX]
	_source_surface_arrays_cache[cache_key] = arrays
	return arrays


func _grass_color_for_type(type: VegetationType, maturity: float = 1.0) -> Color:
	var type_id := String(type.id) if type != null else ""
	var color := Color(0.25, 0.44, 0.16, 1.0)
	match type_id:
		"grass_dry":
			color = Color(0.48, 0.40, 0.18, 1.0)
		"grass_tall":
			color = Color(0.22, 0.42, 0.14, 1.0)
		"reed":
			color = Color(0.36, 0.42, 0.20, 1.0)
		_:
			color = Color(0.25, 0.44, 0.16, 1.0)
	var maturity_scale := lerpf(0.72, 1.0, clampf(maturity, 0.0, 1.0))
	return Color(color.r * maturity_scale, color.g * maturity_scale, color.b * maturity_scale, color.a)


func _append_grass_card_to_payload(type: VegetationType, cell: Dictionary, payload: Dictionary) -> bool:
	if type == null or cell.is_empty():
		return false
	var arrays: Array = payload.get("arrays", [])
	if arrays.is_empty():
		return false
	if arrays.size() < Mesh.ARRAY_MAX:
		arrays.resize(Mesh.ARRAY_MAX)
	if arrays[Mesh.ARRAY_VERTEX] == null:
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	if arrays[Mesh.ARRAY_NORMAL] == null:
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array()
	if arrays[Mesh.ARRAY_TEX_UV] == null:
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array()
	if arrays[Mesh.ARRAY_COLOR] == null:
		arrays[Mesh.ARRAY_COLOR] = PackedColorArray()
	if arrays[Mesh.ARRAY_INDEX] == null:
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array()

	var vertices: PackedVector3Array = _as_packed_vector3_array(arrays[Mesh.ARRAY_VERTEX])
	var normals: PackedVector3Array = _as_packed_vector3_array(arrays[Mesh.ARRAY_NORMAL])
	var uvs: PackedVector2Array = _as_packed_vector2_array(arrays[Mesh.ARRAY_TEX_UV])
	var colors: PackedColorArray = _as_packed_color_array(arrays[Mesh.ARRAY_COLOR])
	var indices: PackedInt32Array = _as_packed_int32_array(arrays[Mesh.ARRAY_INDEX])
	var local_position: Vector3 = cell.get("local_position", Vector3.ZERO)
	var rotation := float(cell.get("rotation", 0.0))
	var scale := maxf(0.01, float(cell.get("scale", type.instance_scale * grass_scale_multiplier)))
	var half_width := GRASS_CARD_HALF_WIDTH * scale
	var height := GRASS_CARD_HEIGHT * scale
	var right := Vector3(cos(rotation) * half_width, 0.0, sin(rotation) * half_width)
	var up := Vector3(0.0, height, 0.0)
	var start_index := int(payload.get("vertex_count", 0))
	var p0 := local_position - right
	var p1 := local_position + right
	var p2 := local_position + right + up
	var p3 := local_position - right + up
	vertices.append(p0)
	vertices.append(p1)
	vertices.append(p2)
	vertices.append(p3)
	var normal := Vector3(-right.z, 0.0, right.x).normalized()
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	var cell_color := _grass_color_for_type(type, float(cell.get("maturity", 1.0)))
	colors.append(cell_color)
	colors.append(cell_color)
	colors.append(cell_color)
	colors.append(cell_color)
	uvs.append(Vector2(0.0, 1.0))
	uvs.append(Vector2(1.0, 1.0))
	uvs.append(Vector2(1.0, 0.0))
	uvs.append(Vector2(0.0, 0.0))
	indices.append(start_index)
	indices.append(start_index + 1)
	indices.append(start_index + 2)
	indices.append(start_index)
	indices.append(start_index + 2)
	indices.append(start_index + 3)

	var bounds: AABB = payload.get("bounds", AABB())
	var has_bounds := bool(payload.get("has_bounds", false))
	if not has_bounds:
		bounds = AABB(p0, Vector3.ZERO)
		has_bounds = true
	else:
		bounds = bounds.expand(p0)
	bounds = bounds.expand(p1)
	bounds = bounds.expand(p2)
	bounds = bounds.expand(p3)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	payload["arrays"] = arrays
	payload["vertex_count"] = start_index + 4
	payload["bounds"] = bounds
	payload["has_bounds"] = has_bounds
	return true


func _append_chunk_mesh_source(type: VegetationType, source_mesh: Mesh, transform: Transform3D, payload: Dictionary, source_cache: Dictionary) -> bool:
	if type == null or source_mesh == null or source_mesh.get_surface_count() <= 0:
		return false
	var cache_key := str(source_mesh.get_instance_id())
	var source_data: Dictionary = source_cache.get(cache_key, {})
	if source_data.is_empty():
		source_data = _get_prepared_source_surface_data(source_mesh, 0)
		if source_data.is_empty():
			return false
		source_cache[cache_key] = source_data
	_append_prepared_source_surface_to_payload(source_data, transform, payload)
	return true


func _get_prepared_source_surface_data(source_mesh: Mesh, surface_index: int = 0) -> Dictionary:
	if source_mesh == null or source_mesh.get_surface_count() <= surface_index:
		return {}
	var cache_key := "%d:%d" % [source_mesh.get_instance_id(), surface_index]
	if _prepared_source_surface_cache.has(cache_key):
		return _prepared_source_surface_cache[cache_key]
	var source_data := _prepare_source_surface_data(source_mesh, surface_index)
	if not source_data.is_empty():
		_prepared_source_surface_cache[cache_key] = source_data
	return source_data


func _is_chunk_mesh_record_visible(record: Dictionary, type: VegetationType) -> bool:
	if type == null or not type.is_chunk_mesh():
		return false
	return _is_render_record_visible(record, type)


func _is_render_record_visible(record: Dictionary, type: VegetationType) -> bool:
	if type == null:
		return false
	if bool(record.get("harvested", false)):
		return false
	if bool(record.get("chopped", false)) and type.category != VegetationType.Category.STUMP:
		return false
	var health := float(record.get("health", type.health))
	return health > 0.0


func _should_render_individual_record(chunk: VegetationChunk, record: Dictionary, type: VegetationType) -> bool:
	if chunk == null or type == null or not type.is_individual_instance():
		return false
	if not _is_record_rendered_by_camera(chunk, record, type):
		return false
	return _should_keep_record_individual(chunk, record, type)


func _is_record_rendered_by_camera(chunk: VegetationChunk, record: Dictionary, type: VegetationType) -> bool:
	if chunk == null or type == null or not type.is_individual_instance():
		return false
	if not _is_render_record_visible(record, type):
		return false
	if not camera_cull_chunk_mesh_records:
		return true
	var visibility_class := VISIBILITY_CLASS_FULL
	if _chunk_visibility_class.has(chunk.chunk_coord):
		visibility_class = int(_chunk_visibility_class[chunk.chunk_coord])
	else:
		visibility_class = _chunk_visibility_class_for_camera(chunk.chunk_coord)
		_chunk_visibility_class[chunk.chunk_coord] = visibility_class
	if visibility_class == VISIBILITY_CLASS_NONE:
		return false
	if visibility_class == VISIBILITY_CLASS_FULL:
		return true
	var full_radius := maxi(0, camera_full_detail_radius_chunks)
	if full_radius > 0 and _chunk_distance_sq_from_focus(chunk.chunk_coord) <= full_radius * full_radius:
		return true
	if not has_render_camera:
		return true
	var world_position: Vector3 = record.get("position", Vector3.ZERO)
	var max_distance := float(maxi(active_stream_radius_chunks, initial_stream_radius_chunks) * chunk_size) + float(chunk_size)
	if world_position.distance_squared_to(render_camera_position) > max_distance * max_distance:
		return false
	var margin := zoom_cone_margin_degrees if render_camera_fov_degrees <= zoom_fov_threshold_degrees else camera_cone_margin_degrees
	var prefetch_margin := zoom_prefetch_margin_degrees if render_camera_fov_degrees <= zoom_fov_threshold_degrees else camera_prefetch_margin_degrees
	var sphere := _record_camera_sphere(type, record)
	return _is_sphere_in_camera_view(
		sphere.get("center", world_position),
		float(sphere.get("radius", maxf(type.support_radius, 0.5))),
		margin,
		prefetch_margin
	)


func _record_camera_sphere(type: VegetationType, record: Dictionary) -> Dictionary:
	var scale := maxf(0.05, float(record.get("scale", type.instance_scale if type != null else 1.0)))
	var position: Vector3 = record.get("position", Vector3.ZERO)
	if type == null:
		return {
			"center": position,
			"radius": 0.75 * scale
		}
	var visual_radius := maxf(maxf(type.support_radius, _get_type_visual_radius(type)) * scale, 0.5)
	var visual_height := maxf(type.support_height * scale, visual_radius * 2.0)
	var center := position + Vector3(0.0, visual_height * 0.5, 0.0)
	return {
		"center": center,
		"radius": maxf(visual_radius, visual_height * 0.5)
	}


func _screen_occlusion_culling_active() -> bool:
	return screen_occlusion_cull_tree_records \
		and has_render_camera \
		and batch_individual_records_in_render_clusters \
		and camera_cull_instanced_records \
		and camera_cull_chunk_mesh_records


func _compare_chunk_camera_distance(a: VegetationChunk, b: VegetationChunk) -> bool:
	if a == null or b == null:
		return a != null
	var a_center := Vector3(
		(float(a.chunk_coord.x) + 0.5) * float(chunk_size),
		focus_position.y,
		(float(a.chunk_coord.y) + 0.5) * float(chunk_size)
	)
	var b_center := Vector3(
		(float(b.chunk_coord.x) + 0.5) * float(chunk_size),
		focus_position.y,
		(float(b.chunk_coord.y) + 0.5) * float(chunk_size)
	)
	return a_center.distance_squared_to(render_camera_position) < b_center.distance_squared_to(render_camera_position)


func _is_record_screen_occluded(type: VegetationType, record: Dictionary, screen_grid: Dictionary) -> bool:
	if not _screen_occlusion_culling_active() or screen_grid.is_empty():
		return false
	if type == null or type.category != VegetationType.Category.TREE:
		return false
	var position: Vector3 = record.get("position", Vector3.ZERO)
	var full_radius_world := float(camera_full_detail_radius_chunks * chunk_size)
	if position.distance_squared_to(focus_position) <= full_radius_world * full_radius_world:
		return false
	var rect := _record_screen_rect(type, record, 0.85)
	if rect.is_empty():
		return false
	var min_x := int(rect.get("min_x", 0))
	var max_x := int(rect.get("max_x", -1))
	var min_y := int(rect.get("min_y", 0))
	var max_y := int(rect.get("max_y", -1))
	if max_x < min_x or max_y < min_y:
		return false
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			if not screen_grid.has(_screen_grid_key(x, y)):
				return false
	return true


func _mark_record_screen_occluder(type: VegetationType, record: Dictionary, screen_grid: Dictionary) -> void:
	if not _screen_occlusion_culling_active():
		return
	if type == null or type.category != VegetationType.Category.TREE:
		return
	var rect := _record_screen_rect(type, record, 0.72)
	if rect.is_empty():
		return
	var min_x := int(rect.get("min_x", 0))
	var max_x := int(rect.get("max_x", -1))
	var min_y := int(rect.get("min_y", 0))
	var max_y := int(rect.get("max_y", -1))
	if max_x - min_x >= 2:
		min_x += 1
		max_x -= 1
	if max_y - min_y >= 2:
		min_y += 1
		max_y -= 1
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			screen_grid[_screen_grid_key(x, y)] = true


func _record_screen_rect(type: VegetationType, record: Dictionary, radius_scale: float) -> Dictionary:
	if not has_render_camera:
		return {}
	var sphere := _record_camera_sphere(type, record)
	var center: Vector3 = sphere.get("center", Vector3.ZERO)
	var radius := maxf(0.1, float(sphere.get("radius", 0.5)) * maxf(0.1, radius_scale))
	var to_center := center - render_camera_position
	var forward_distance := render_camera_forward.dot(to_center)
	if forward_distance <= radius:
		return {}
	var half_vertical_tan := tan(deg_to_rad(render_camera_fov_degrees * 0.5))
	var half_horizontal_tan := half_vertical_tan * render_camera_aspect
	if half_vertical_tan <= 0.0001 or half_horizontal_tan <= 0.0001:
		return {}
	var ndc_x := render_camera_right.dot(to_center) / (forward_distance * half_horizontal_tan)
	var ndc_y := render_camera_up.dot(to_center) / (forward_distance * half_vertical_tan)
	var ndc_radius_x := radius / (forward_distance * half_horizontal_tan)
	var ndc_radius_y := radius / (forward_distance * half_vertical_tan)
	if ndc_x + ndc_radius_x < -1.0 or ndc_x - ndc_radius_x > 1.0:
		return {}
	if ndc_y + ndc_radius_y < -1.0 or ndc_y - ndc_radius_y > 1.0:
		return {}
	var columns := maxi(1, screen_occlusion_grid_columns)
	var rows := maxi(1, screen_occlusion_grid_rows)
	var min_x := clampi(int(floor(((ndc_x - ndc_radius_x) * 0.5 + 0.5) * float(columns))), 0, columns - 1)
	var max_x := clampi(int(floor(((ndc_x + ndc_radius_x) * 0.5 + 0.5) * float(columns))), 0, columns - 1)
	var min_y := clampi(int(floor(((ndc_y - ndc_radius_y) * 0.5 + 0.5) * float(rows))), 0, rows - 1)
	var max_y := clampi(int(floor(((ndc_y + ndc_radius_y) * 0.5 + 0.5) * float(rows))), 0, rows - 1)
	return {
		"min_x": min_x,
		"max_x": max_x,
		"min_y": min_y,
		"max_y": max_y
	}


func _screen_grid_key(x: int, y: int) -> int:
	return y * maxi(1, screen_occlusion_grid_columns) + x


func _should_keep_record_individual(chunk: VegetationChunk, _record: Dictionary, type: VegetationType) -> bool:
	if chunk == null or type == null or not type.is_individual_instance():
		return false
	if not batch_individual_records_in_render_clusters:
		return true
	if individual_record_radius_chunks <= 0:
		return false
	var radius := individual_record_radius_chunks
	return _chunk_distance_sq_from_focus(chunk.chunk_coord) <= radius * radius


func _should_chunk_render_record(chunk: VegetationChunk, record: Dictionary, type: VegetationType) -> bool:
	if chunk == null or type == null or not batch_individual_records_in_render_clusters:
		return false
	if not _is_render_record_visible(record, type):
		return false
	return not _should_keep_record_individual(chunk, record, type)


func _destroy_record_instance_if_any(chunk: VegetationChunk, record: Dictionary) -> void:
	if renderer == null:
		return
	var instance_rid: RID = record.get("instance_rid", RID())
	if not instance_rid.is_valid():
		return
	renderer.destroy_instance(instance_rid)
	record["instance_rid"] = RID()
	_clear_record_hidden_state(record)
	chunk.individual_instance_rids.erase(int(record.get("id", 0)))


func _mark_record_hidden(record: Dictionary) -> void:
	if record.has(RECORD_HIDDEN_FRAME_KEY):
		return
	record[RECORD_HIDDEN_FRAME_KEY] = Engine.get_process_frames()
	_hidden_instance_count += 1


func _clear_record_hidden_state(record: Dictionary) -> void:
	if not record.has(RECORD_HIDDEN_FRAME_KEY):
		return
	record.erase(RECORD_HIDDEN_FRAME_KEY)
	_hidden_instance_count = maxi(0, _hidden_instance_count - 1)


func _process_hidden_instance_evictions() -> void:
	_last_hidden_instance_eviction_count = 0
	_last_hidden_instance_eviction_ms = 0.0
	if renderer == null or _hidden_instance_count <= 0 or hidden_instance_grace_frames < 0:
		return
	var chunk_keys := chunks.keys()
	if chunk_keys.is_empty():
		return
	var start_us := Time.get_ticks_usec()
	var current_frame := Engine.get_process_frames()
	var frees_left := maxi(1, max_hidden_instance_frees_per_frame)
	var chunks_left := maxi(1, max_hidden_instance_eviction_chunks_per_frame)
	_hidden_instance_eviction_cursor = clampi(_hidden_instance_eviction_cursor, 0, chunk_keys.size() - 1)
	while frees_left > 0 and chunks_left > 0 and not chunk_keys.is_empty():
		var chunk_coord: Vector2i = chunk_keys[_hidden_instance_eviction_cursor]
		var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
		if chunk != null:
			frees_left -= _evict_hidden_instances_from_records(chunk, chunk.tree_records, current_frame, frees_left)
			if frees_left > 0:
				frees_left -= _evict_hidden_instances_from_records(chunk, chunk.cosmetic_bushes, current_frame, frees_left)
			if frees_left > 0:
				frees_left -= _evict_hidden_instances_from_records(chunk, chunk.rock_records, current_frame, frees_left)
		chunks_left -= 1
		_hidden_instance_eviction_cursor += 1
		if _hidden_instance_eviction_cursor >= chunk_keys.size():
			_hidden_instance_eviction_cursor = 0
		if _hidden_instance_eviction_cursor == 0 and chunks_left > 0 and chunk_keys.size() <= max_hidden_instance_eviction_chunks_per_frame:
			break
	_last_hidden_instance_eviction_ms = float(Time.get_ticks_usec() - start_us) / 1000.0


func _evict_hidden_instances_from_records(chunk: VegetationChunk, records: Array, current_frame: int, free_budget: int) -> int:
	if free_budget <= 0:
		return 0
	var evicted_count := 0
	for record_variant in records:
		if evicted_count >= free_budget:
			break
		var record: Dictionary = record_variant
		if not record.has(RECORD_HIDDEN_FRAME_KEY):
			continue
		var instance_rid: RID = record.get("instance_rid", RID())
		if not instance_rid.is_valid():
			_clear_record_hidden_state(record)
			continue
		var hidden_frame := int(record.get(RECORD_HIDDEN_FRAME_KEY, current_frame))
		if current_frame - hidden_frame < hidden_instance_grace_frames:
			continue
		renderer.destroy_instance(instance_rid)
		record["instance_rid"] = RID()
		_clear_record_hidden_state(record)
		chunk.individual_instance_rids.erase(int(record.get("id", 0)))
		evicted_count += 1
	_last_hidden_instance_eviction_count += evicted_count
	return evicted_count


func _build_chunk_record_transform(type: VegetationType, record: Dictionary, chunk: VegetationChunk) -> Transform3D:
	var chunk_origin := Vector3(chunk.chunk_coord.x * chunk_size, 0.0, chunk.chunk_coord.y * chunk_size)
	return _build_record_transform_for_origin(type, record, chunk_origin)


func _build_record_transform_for_origin(type: VegetationType, record: Dictionary, render_origin: Vector3) -> Transform3D:
	var rotation := float(record.get("rotation", 0.0)) * TAU
	var scale := maxf(0.05, float(record.get("scale", type.instance_scale)))
	var world_position: Vector3 = record.get("position", Vector3.ZERO)
	var transform := Transform3D.IDENTITY
	transform = transform.rotated(Vector3.UP, rotation)
	transform = transform.scaled(Vector3.ONE * scale)
	transform.origin = world_position - render_origin
	var source_transform := type.mesh_source_transform if type.source_mesh != null else type.get_source_transform()
	return transform * source_transform


func _prepare_source_surface_data(source_mesh: Mesh, surface_index: int) -> Dictionary:
	if source_mesh == null or source_mesh.get_surface_count() <= surface_index:
		return {}
	var source_arrays: Array = _get_cached_source_surface_arrays(source_mesh, surface_index)
	if source_arrays.is_empty():
		return {}
	if source_arrays.size() < Mesh.ARRAY_MAX:
		source_arrays.resize(Mesh.ARRAY_MAX)
	if source_arrays[Mesh.ARRAY_VERTEX] == null:
		return {}
	var source_vertices: PackedVector3Array = _as_packed_vector3_array(source_arrays[Mesh.ARRAY_VERTEX])
	if source_vertices.is_empty():
		return {}
	var source_normals: PackedVector3Array = _as_packed_vector3_array(source_arrays[Mesh.ARRAY_NORMAL])
	var source_uvs: PackedVector2Array = _as_packed_vector2_array(source_arrays[Mesh.ARRAY_TEX_UV])
	var source_uv2: PackedVector2Array = _as_packed_vector2_array(source_arrays[Mesh.ARRAY_TEX_UV2])
	var source_colors: PackedColorArray = _as_packed_color_array(source_arrays[Mesh.ARRAY_COLOR])
	var source_indices: PackedInt32Array = _as_packed_int32_array(source_arrays[Mesh.ARRAY_INDEX])
	if source_indices.is_empty():
		source_indices.resize(source_vertices.size())
		for i in range(source_vertices.size()):
			source_indices[i] = i
	return {
		"vertices": source_vertices,
		"normals": source_normals,
		"uvs": source_uvs,
		"uv2": source_uv2,
		"colors": source_colors,
		"indices": source_indices,
		"use_normals": source_normals.size() == source_vertices.size() and source_normals.size() > 0,
		"use_uvs": source_uvs.size() == source_vertices.size() and source_uvs.size() > 0,
		"use_uv2": source_uv2.size() == source_vertices.size() and source_uv2.size() > 0,
		"use_colors": source_colors.size() == source_vertices.size() and source_colors.size() > 0
	}


func _append_prepared_source_surface_to_payload(source_data: Dictionary, transform: Transform3D, payload: Dictionary) -> void:
	if source_data.is_empty():
		return
	var source_vertices: PackedVector3Array = source_data.get("vertices", PackedVector3Array())
	if source_vertices.is_empty():
		return
	var arrays: Array = payload.get("arrays", [])
	if arrays.is_empty():
		return
	if arrays.size() < Mesh.ARRAY_MAX:
		arrays.resize(Mesh.ARRAY_MAX)
	if arrays[Mesh.ARRAY_VERTEX] == null:
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	if arrays[Mesh.ARRAY_INDEX] == null:
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array()
	var vertices: PackedVector3Array = _as_packed_vector3_array(arrays[Mesh.ARRAY_VERTEX])
	var normals: PackedVector3Array = _as_packed_vector3_array(arrays[Mesh.ARRAY_NORMAL]) if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var uvs: PackedVector2Array = _as_packed_vector2_array(arrays[Mesh.ARRAY_TEX_UV]) if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var uv2: PackedVector2Array = _as_packed_vector2_array(arrays[Mesh.ARRAY_TEX_UV2]) if arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
	var colors: PackedColorArray = _as_packed_color_array(arrays[Mesh.ARRAY_COLOR]) if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
	var indices: PackedInt32Array = _as_packed_int32_array(arrays[Mesh.ARRAY_INDEX])
	var source_normals: PackedVector3Array = source_data.get("normals", PackedVector3Array())
	var source_uvs: PackedVector2Array = source_data.get("uvs", PackedVector2Array())
	var source_uv2: PackedVector2Array = source_data.get("uv2", PackedVector2Array())
	var source_colors: PackedColorArray = source_data.get("colors", PackedColorArray())
	var source_indices: PackedInt32Array = source_data.get("indices", PackedInt32Array())
	var use_normals := bool(source_data.get("use_normals", false))
	var use_uvs := bool(source_data.get("use_uvs", false))
	var use_uv2 := bool(source_data.get("use_uv2", false))
	var use_colors := bool(source_data.get("use_colors", false))
	var start_index := int(payload.get("vertex_count", 0))
	var append_normals := use_normals or normals.size() > 0
	var append_uvs := use_uvs or uvs.size() > 0
	var append_uv2 := use_uv2 or uv2.size() > 0
	var append_colors := use_colors or colors.size() > 0
	if append_normals and arrays[Mesh.ARRAY_NORMAL] == null:
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array()
		normals = _as_packed_vector3_array(arrays[Mesh.ARRAY_NORMAL])
	while append_normals and normals.size() < start_index:
		normals.append(Vector3.UP)
	if append_uvs and arrays[Mesh.ARRAY_TEX_UV] == null:
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array()
		uvs = _as_packed_vector2_array(arrays[Mesh.ARRAY_TEX_UV])
	while append_uvs and uvs.size() < start_index:
		uvs.append(Vector2.ZERO)
	if append_uv2 and arrays[Mesh.ARRAY_TEX_UV2] == null:
		arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array()
		uv2 = _as_packed_vector2_array(arrays[Mesh.ARRAY_TEX_UV2])
	while append_uv2 and uv2.size() < start_index:
		uv2.append(Vector2.ZERO)
	if append_colors and arrays[Mesh.ARRAY_COLOR] == null:
		arrays[Mesh.ARRAY_COLOR] = PackedColorArray()
		colors = _as_packed_color_array(arrays[Mesh.ARRAY_COLOR])
	while append_colors and colors.size() < start_index:
		colors.append(Color.WHITE)
	var bounds: AABB = payload.get("bounds", AABB())
	var has_bounds := bool(payload.get("has_bounds", false))
	for i in range(source_vertices.size()):
		var local_vertex := transform * source_vertices[i]
		vertices.append(local_vertex)
		if not has_bounds:
			bounds = AABB(local_vertex, Vector3.ZERO)
			has_bounds = true
		else:
			bounds = bounds.expand(local_vertex)
		if append_normals:
			normals.append((transform.basis * source_normals[i]).normalized() if use_normals else Vector3.UP)
		if append_uvs:
			uvs.append(source_uvs[i] if use_uvs else Vector2.ZERO)
		if append_uv2:
			uv2.append(source_uv2[i] if use_uv2 else Vector2.ZERO)
		if append_colors:
			colors.append(source_colors[i] if use_colors else Color.WHITE)
	for source_index in source_indices:
		indices.append(start_index + int(source_index))
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals if append_normals else null
	arrays[Mesh.ARRAY_TEX_UV] = uvs if append_uvs else null
	arrays[Mesh.ARRAY_TEX_UV2] = uv2 if append_uv2 else null
	arrays[Mesh.ARRAY_COLOR] = colors if append_colors else null
	arrays[Mesh.ARRAY_INDEX] = indices
	payload["arrays"] = arrays
	payload["vertex_count"] = start_index + source_vertices.size()
	payload["bounds"] = bounds
	payload["has_bounds"] = has_bounds


func _make_mesh_payload() -> Dictionary:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array()
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array()
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array()
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray()
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array()
	return {
		"arrays": arrays,
		"vertex_count": 0,
		"bounds": AABB(),
		"has_bounds": false
	}


func _as_packed_vector3_array(value: Variant) -> PackedVector3Array:
	if value is PackedVector3Array:
		return value
	return PackedVector3Array()


func _as_packed_vector2_array(value: Variant) -> PackedVector2Array:
	if value is PackedVector2Array:
		return value
	return PackedVector2Array()


func _as_packed_color_array(value: Variant) -> PackedColorArray:
	if value is PackedColorArray:
		return value
	return PackedColorArray()


func _as_packed_int32_array(value: Variant) -> PackedInt32Array:
	if value is PackedInt32Array:
		return value
	return PackedInt32Array()


func _mesh_primitive_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var primitive_count := 0
	for surface_index in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		if arrays.is_empty():
			continue
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var vertices: PackedVector3Array = _as_packed_vector3_array(arrays[Mesh.ARRAY_VERTEX])
		if vertices.is_empty():
			continue
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
			var indices: PackedInt32Array = _as_packed_int32_array(arrays[Mesh.ARRAY_INDEX])
			if not indices.is_empty():
				primitive_count += int(indices.size() / 3)
				continue
		primitive_count += int(vertices.size() / 3)
	return primitive_count


func _get_type_mesh_primitive_count(type: VegetationType) -> int:
	if type == null:
		return 0
	var cache_key := String(type.id)
	if _type_mesh_primitive_count_cache.has(cache_key):
		return int(_type_mesh_primitive_count_cache[cache_key])
	var primitive_count := _mesh_primitive_count(type.get_source_mesh())
	_type_mesh_primitive_count_cache[cache_key] = primitive_count
	return primitive_count


func _destroy_grass_render(chunk: VegetationChunk) -> void:
	if renderer == null or chunk == null:
		return
	if chunk.render_chunk_key.is_empty():
		if chunk.grass_mesh_rid.is_valid():
			renderer.free_rid_safely(chunk.grass_mesh_rid)
		if chunk.grass_instance_rid.is_valid():
			renderer.free_rid_safely(chunk.grass_instance_rid)
	else:
		renderer.destroy_chunk(chunk.render_chunk_key)
	chunk.grass_mesh_rid = RID()
	chunk.grass_instance_rid = RID()
	chunk.render_chunk_key = ""


func _destroy_chunk_render_state(chunk: VegetationChunk, immediate_free: bool) -> void:
	if chunk == null:
		return
	_destroy_grass_render(chunk)
	if renderer:
		for tree in chunk.tree_records:
			var tree_rid: RID = tree.get("instance_rid", RID())
			if tree_rid.is_valid():
				renderer.destroy_instance(tree_rid)
			_clear_record_hidden_state(tree)
		for bush in chunk.cosmetic_bushes:
			var bush_rid: RID = bush.get("instance_rid", RID())
			if bush_rid.is_valid():
				renderer.destroy_instance(bush_rid)
			_clear_record_hidden_state(bush)
		for rock in chunk.rock_records:
			var rock_rid: RID = rock.get("instance_rid", RID())
			if rock_rid.is_valid():
				renderer.destroy_instance(rock_rid)
			_clear_record_hidden_state(rock)
		if chunk.grass_mesh_rid.is_valid():
			renderer.free_rid_safely(chunk.grass_mesh_rid, immediate_free)
		if chunk.grass_instance_rid.is_valid():
			renderer.free_rid_safely(chunk.grass_instance_rid, immediate_free)
	chunk.individual_instance_rids.clear()
	chunk.grass_mesh_rid = RID()
	chunk.grass_instance_rid = RID()
	chunk.render_chunk_key = ""


func _remove_chunk(chunk_coord: Vector2i, immediate_free: bool = false) -> void:
	_remove_pending_generation(chunk_coord)
	_remove_pending_visibility_sync(chunk_coord)
	_chunk_visibility_class.erase(chunk_coord)
	_chunk_last_visible_frame.erase(chunk_coord)
	_regrowth_chunk_coords.erase(chunk_coord)
	var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
	if chunk == null:
		return
	var render_cluster_coord := _render_cluster_coord_for_chunk(chunk_coord)
	_destroy_chunk_render_state(chunk, immediate_free)
	for tree in chunk.tree_records:
		spatial_grid.unregister_record(int(tree.get("id", 0)))
	for bush in chunk.cosmetic_bushes:
		spatial_grid.unregister_record(int(bush.get("id", 0)))
	for rock in chunk.rock_records:
		spatial_grid.unregister_record(int(rock.get("id", 0)))
	if native_spatial_grid != null:
		native_spatial_grid.remove_chunk(chunk_coord)
	spatial_grid.remove_chunk(chunk_coord)
	chunks.erase(chunk_coord)
	if _get_chunks_in_render_cluster(render_cluster_coord).is_empty():
		_destroy_render_cluster(render_cluster_coord)
	else:
		_queue_render_cluster_rebuild(render_cluster_coord)


func _remove_pending_visibility_sync(chunk_coord: Vector2i) -> void:
	_pending_visibility_sync_lookup.erase(chunk_coord)
	for i in range(_pending_visibility_sync_chunks.size() - 1, -1, -1):
		if _pending_visibility_sync_chunks[i] == chunk_coord:
			_pending_visibility_sync_chunks.remove_at(i)


func _remove_pending_generation(chunk_coord: Vector2i) -> void:
	if _pending_generation_reasons.has(chunk_coord):
		_pending_generation_reasons.erase(chunk_coord)
	if _pending_generation_retry_after_frames.has(chunk_coord):
		_pending_generation_retry_after_frames.erase(chunk_coord)
	for i in range(_pending_generation_queue.size() - 1, -1, -1):
		if _pending_generation_queue[i] == chunk_coord:
			_pending_generation_queue.remove_at(i)


func _connect_terrain_manager() -> void:
	if terrain_manager == null:
		return
	if terrain_manager.has_signal("chunk_generated") and not terrain_manager.chunk_generated.is_connected(_on_terrain_chunk_generated):
		terrain_manager.chunk_generated.connect(_on_terrain_chunk_generated)
	if terrain_manager.has_signal("chunk_modified") and not terrain_manager.chunk_modified.is_connected(_on_terrain_chunk_modified):
		terrain_manager.chunk_modified.connect(_on_terrain_chunk_modified)
	if terrain_manager.has_signal("chunk_unloaded") and not terrain_manager.chunk_unloaded.is_connected(_on_terrain_chunk_unloaded):
		terrain_manager.chunk_unloaded.connect(_on_terrain_chunk_unloaded)


func _bind_renderer_world() -> void:
	if renderer == null:
		return
	var host := get_parent() as Node3D
	if host and host.get_world_3d():
		renderer.bind_world_3d(host.get_world_3d())


func _on_terrain_chunk_generated(coord: Vector3i, _chunk_node: Node3D) -> void:
	if coord.y != 0:
		return
	for chunk_coord in _vegetation_chunk_coords_for_terrain_chunk(coord):
		if _is_chunk_inside_stream_radius(chunk_coord):
			var existing: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
			if existing != null and existing.terrain_support_missing:
				_remove_chunk(chunk_coord, false)
			_queue_chunk_generation(chunk_coord, VegetationChunk.DirtyReason.STREAMED_IN)


func _on_terrain_chunk_modified(coord: Vector3i, _chunk_node: Node3D) -> void:
	if coord.y != 0:
		return
	notify_terrain_changed(_terrain_chunk_bounds(coord))


func _on_terrain_chunk_unloaded(coord: Vector3i) -> void:
	if coord.y != 0:
		return
	for chunk_coord in _vegetation_chunk_coords_for_terrain_chunk(coord):
		if chunks.has(chunk_coord) and not _is_chunk_inside_stream_radius(chunk_coord):
			_remove_chunk(chunk_coord, false)


func _get_focus_chunk() -> Vector2i:
	return Vector2i(
		int(floor(focus_position.x / float(chunk_size))),
		int(floor(focus_position.z / float(chunk_size)))
	)


func _world_to_chunk_coord(world_position: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(world_position.x / float(chunk_size))),
		int(floor(world_position.z / float(chunk_size)))
	)


func _query_chunk_coords_in_bounds(bounds: AABB) -> Array[Vector2i]:
	if native_spatial_grid != null:
		var native_coords: Array = native_spatial_grid.query_chunk_coords_in_aabb(bounds, chunk_size)
		var native_result: Array[Vector2i] = []
		for coord_variant in native_coords:
			var coord: Vector2i = coord_variant
			if chunks.has(coord):
				native_result.append(coord)
		return native_result
	var end := bounds.position + bounds.size
	var min_x := minf(bounds.position.x, end.x)
	var max_x := maxf(bounds.position.x, end.x)
	var min_z := minf(bounds.position.z, end.z)
	var max_z := maxf(bounds.position.z, end.z)
	var min_coord := _world_to_chunk_coord(Vector3(min_x, 0.0, min_z))
	var max_coord := _world_to_chunk_coord(Vector3(max_x, 0.0, max_z))
	var result: Array[Vector2i] = []
	for x in range(min_coord.x, max_coord.x + 1):
		for z in range(min_coord.y, max_coord.y + 1):
			var chunk_coord := Vector2i(x, z)
			if chunks.has(chunk_coord):
				result.append(chunk_coord)
	return result


func _query_chunks_in_bounds(bounds: AABB) -> Array[VegetationChunk]:
	var result: Array[VegetationChunk] = []
	for chunk_coord in _query_chunk_coords_in_bounds(bounds):
		var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
		if chunk != null:
			result.append(chunk)
	return result


func _terrain_chunk_bounds(coord: Vector3i) -> AABB:
	return AABB(
		Vector3(float(coord.x) * TERRAIN_CHUNK_STRIDE, -4096.0, float(coord.z) * TERRAIN_CHUNK_STRIDE),
		Vector3(TERRAIN_CHUNK_STRIDE, 8192.0, TERRAIN_CHUNK_STRIDE)
	)


func _vegetation_chunk_coords_for_terrain_chunk(coord: Vector3i) -> Array[Vector2i]:
	var bounds := _terrain_chunk_bounds(coord)
	var min_coord := _world_to_chunk_coord(bounds.position)
	var max_coord := _world_to_chunk_coord(bounds.position + Vector3(bounds.size.x, 0.0, bounds.size.z))
	var result: Array[Vector2i] = []
	for x in range(min_coord.x, max_coord.x + 1):
		for z in range(min_coord.y, max_coord.y + 1):
			result.append(Vector2i(x, z))
	return result


func _is_chunk_inside_stream_radius(chunk_coord: Vector2i, margin: int = 0) -> bool:
	var focus_chunk := _get_focus_chunk()
	var radius := (active_stream_radius_chunks if active_stream_radius_chunks > 0 else initial_stream_radius_chunks) + margin
	var dx := chunk_coord.x - focus_chunk.x
	var dz := chunk_coord.y - focus_chunk.y
	return dx * dx + dz * dz <= radius * radius


func _make_chunk_bounds(chunk_coord: Vector2i) -> AABB:
	return AABB(
		Vector3(chunk_coord.x * chunk_size, -4096.0, chunk_coord.y * chunk_size),
		Vector3(chunk_size, 8192.0, chunk_size)
	)


func _chunk_key(chunk_coord: Vector2i) -> String:
	return "%d_%d" % [chunk_coord.x, chunk_coord.y]


func _random_point_in_chunk(rng: RandomNumberGenerator, chunk_origin: Vector3) -> Vector3:
	return Vector3(
		chunk_origin.x + rng.randf_range(1.0, float(chunk_size) - 1.0),
		0.0,
		chunk_origin.z + rng.randf_range(1.0, float(chunk_size) - 1.0)
	)


func _jittered_grid_point(rng: RandomNumberGenerator, chunk_origin: Vector3, x: int, z: int, spacing: int) -> Vector3:
	var max_offset := maxf(1.0, float(spacing) - 1.0)
	return Vector3(
		clampf(chunk_origin.x + float(x) + rng.randf_range(1.0, max_offset), chunk_origin.x + 1.0, chunk_origin.x + float(chunk_size) - 1.0),
		0.0,
		clampf(chunk_origin.z + float(z) + rng.randf_range(1.0, max_offset), chunk_origin.z + 1.0, chunk_origin.z + float(chunk_size) - 1.0)
	)


func _is_spawn_rejected(global_x: float, terrain_y: float, global_z: float, water_clearance: float) -> bool:
	if _is_spawn_blocked_by_modified_terrain(global_x, global_z):
		return true
	if _is_spawn_blocked_by_road(global_x, global_z):
		return true
	if _is_spawn_underwater(Vector3(global_x, terrain_y, global_z), water_clearance):
		return true
	return false


func _is_spawn_blocked_by_modified_terrain(_global_x: float, _global_z: float) -> bool:
	# Terrain modification flags are chunk-wide. Rejecting an entire terrain
	# chunk here erased vegetation around roads and towns. Actual holes/removals
	# are handled by support-height checks and terrain_changed refresh.
	return false


func _is_spawn_blocked_by_road(global_x: float, global_z: float) -> bool:
	if terrain_manager == null or not is_instance_valid(terrain_manager):
		return false
	if terrain_manager.has_method("is_road_at_position"):
		return bool(terrain_manager.is_road_at_position(global_x, global_z, road_clearance))
	if "procedural_roads_enabled" in terrain_manager and not bool(terrain_manager.procedural_roads_enabled):
		return false
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


func _is_spawn_underwater(world_position: Vector3, clearance: float) -> bool:
	if terrain_manager == null or not is_instance_valid(terrain_manager):
		return false
	if "water_level" in terrain_manager:
		return world_position.y + clearance < float(terrain_manager.water_level)
	return false


func _profile_settings() -> Dictionary:
	# Densities below are per spawn attempt, not normalized world coverage.
	match String(profile):
		"world_dense_max_trees":
			return {
				"grass_step": 2,
				"grass_density": 0.84,
				"grass_maturity": 0.86,
				"bush_density": 0.46,
				"tree_density": 0.62,
				"rock_density": 0.42,
				"tree_spacing": 10,
				"bush_spacing": 14,
				"rock_spacing": 12
			}
		"world_dense":
			return {
				"grass_step": 2,
				"grass_density": 0.84,
				"grass_maturity": 0.86,
				"bush_density": 0.46,
				"tree_density": 0.31,
				"rock_density": 0.42,
				"tree_spacing": 10,
				"bush_spacing": 14,
				"rock_spacing": 12
			}
		"grass_field":
			return {
				"grass_step": 2,
				"grass_density": 0.92,
				"grass_maturity": 0.62,
				"bush_density": 0.42,
				"tree_density": 0.24,
				"rock_density": 0.38,
				"tree_spacing": 28,
				"bush_spacing": 16,
				"rock_spacing": 16
			}
		"forest":
			return {
				"grass_step": 3,
				"grass_density": 0.80,
				"grass_maturity": 0.88,
				"bush_density": 0.40,
				"tree_density": 0.68,
				"rock_density": 0.32,
				"tree_spacing": 10,
				"bush_spacing": 14,
				"rock_spacing": 14
			}
		"harvest":
			return {
				"grass_step": 3,
				"grass_density": 0.82,
				"grass_maturity": 0.90,
				"bush_density": 0.36,
				"tree_density": 0.24,
				"rock_density": 0.26,
				"tree_spacing": 28,
				"bush_spacing": 16,
				"rock_spacing": 18
			}
		"digging_support":
			return {
				"grass_step": 3,
				"grass_density": 0.74,
				"grass_maturity": 0.80,
				"bush_density": 0.24,
				"tree_density": 0.30,
				"rock_density": 0.30,
				"tree_spacing": 24,
				"bush_spacing": 18,
				"rock_spacing": 16
			}
		"streaming":
			return {
				"grass_step": 3,
				"grass_density": 0.76,
				"grass_maturity": 0.82,
				"bush_density": 0.22,
				"tree_density": 0.28,
				"rock_density": 0.24,
				"tree_spacing": 28,
				"bush_spacing": 20,
				"rock_spacing": 18
			}
		_:
			return {
				"grass_step": 2,
				"grass_density": 0.84,
				"grass_maturity": 0.86,
				"bush_density": 0.46,
				"tree_density": 0.31,
				"rock_density": 0.42,
				"tree_spacing": 10,
				"bush_spacing": 14,
				"rock_spacing": 12
			}


func _chunk_seed(chunk_coord: Vector2i) -> int:
	return int(world_seed) ^ (chunk_coord.x * 73856093) ^ (chunk_coord.y * 19349663) ^ int(String(profile).hash())


func _category_to_kind_name(category: int) -> String:
	match category:
		VegetationType.Category.GRASS:
			return "grass"
		VegetationType.Category.BUSH:
			return "bush"
		VegetationType.Category.TREE:
			return "tree"
		VegetationType.Category.ROCK:
			return "rock"
		VegetationType.Category.STUMP:
			return "stump"
		VegetationType.Category.LOG:
			return "log"
		VegetationType.Category.FLOWER:
			return "flower"
		VegetationType.Category.WEED:
			return "weed"
		_:
			return "unknown"


func _pick_grass_type(rng: RandomNumberGenerator) -> VegetationType:
	if registry == null:
		return null
	var types := _get_types_for_category(VegetationType.Category.GRASS)
	if types.is_empty():
		return registry.get_type(&"grass_green")
	if rng == null:
		rng = _rng_for_position(focus_position, 17)
	return types[rng.randi_range(0, types.size() - 1)]


func _pick_tree_type(rng: RandomNumberGenerator) -> VegetationType:
	if registry == null:
		return null
	var types := _get_types_for_category(VegetationType.Category.TREE)
	if types.is_empty():
		return registry.get_type(&"pine_tree")
	if rng == null:
		rng = _rng_for_position(focus_position, 29)
	return types[rng.randi_range(0, types.size() - 1)]


func _pick_bush_type(rng: RandomNumberGenerator) -> VegetationType:
	if registry == null:
		return null
	var types := _get_types_for_category(VegetationType.Category.BUSH)
	if types.is_empty():
		return registry.get_type(&"berry_bush")
	if rng == null:
		rng = _rng_for_position(focus_position, 31)
	return types[rng.randi_range(0, types.size() - 1)]


func _pick_rock_type(rng: RandomNumberGenerator) -> VegetationType:
	if registry == null:
		return null
	var types := _get_types_for_category(VegetationType.Category.ROCK)
	if types.is_empty():
		return registry.get_type(&"small_rock")
	if rng == null:
		rng = _rng_for_position(focus_position, 37)
	return types[rng.randi_range(0, types.size() - 1)]


func _get_fallback_grass_mesh() -> Mesh:
	var type := _get_type(&"grass_green")
	return type.get_source_mesh() if type else null


func _get_support_height(world_position: Vector3) -> float:
	var height := _try_get_precise_support_height(world_position)
	if height > -100.0:
		return height
	return maxf(world_position.y, mock_terrain_base_height)


func _try_get_precise_support_height(world_position: Vector3) -> float:
	if not use_mock_terrain and terrain_manager and is_instance_valid(terrain_manager):
		var x0 := floorf(world_position.x)
		var z0 := floorf(world_position.z)
		var x1 := x0 + 1.0
		var z1 := z0 + 1.0
		if terrain_manager.has_method("get_chunk_surface_height"):
			var fast_h00 := _try_get_fast_chunk_surface_height(x0, z0)
			var fast_h10 := _try_get_fast_chunk_surface_height(x1, z0)
			var fast_h01 := _try_get_fast_chunk_surface_height(x0, z1)
			var fast_h11 := _try_get_fast_chunk_surface_height(x1, z1)
			if fast_h00 > -100.0 and fast_h10 > -100.0 and fast_h01 > -100.0 and fast_h11 > -100.0:
				return _interpolate_height(world_position, x0, z0, fast_h00, fast_h10, fast_h01, fast_h11)
		if terrain_manager.has_method("get_terrain_height"):
			var h00 := float(terrain_manager.get_terrain_height(x0, z0))
			var h10 := float(terrain_manager.get_terrain_height(x1, z0))
			var h01 := float(terrain_manager.get_terrain_height(x0, z1))
			var h11 := float(terrain_manager.get_terrain_height(x1, z1))
			if h00 > -100.0 and h10 > -100.0 and h01 > -100.0 and h11 > -100.0:
				return _interpolate_height(world_position, x0, z0, h00, h10, h01, h11)
		if terrain_manager.has_method("get_surface_height_at_world_position"):
			var surface_height := float(terrain_manager.get_surface_height_at_world_position(world_position.x, world_position.z))
			if surface_height > -100.0:
				return surface_height
	return _try_get_support_height(world_position)


func _try_get_precise_support_height_cached(world_position: Vector3, height_cache: Dictionary) -> float:
	var height_map_height := _try_get_chunk_height_map_support(world_position, height_cache)
	if height_map_height > -100.0:
		return height_map_height
	if not use_mock_terrain and terrain_manager and is_instance_valid(terrain_manager) and terrain_manager.has_method("get_chunk_surface_height"):
		var x0 := floorf(world_position.x)
		var z0 := floorf(world_position.z)
		var x1 := x0 + 1.0
		var z1 := z0 + 1.0
		var fast_h00 := _try_get_cached_fast_chunk_surface_height(x0, z0, height_cache)
		var fast_h10 := _try_get_cached_fast_chunk_surface_height(x1, z0, height_cache)
		var fast_h01 := _try_get_cached_fast_chunk_surface_height(x0, z1, height_cache)
		var fast_h11 := _try_get_cached_fast_chunk_surface_height(x1, z1, height_cache)
		if fast_h00 > -100.0 and fast_h10 > -100.0 and fast_h01 > -100.0 and fast_h11 > -100.0:
			return _interpolate_height(world_position, x0, z0, fast_h00, fast_h10, fast_h01, fast_h11)
	return _try_get_precise_support_height(world_position)


func _try_get_chunk_height_map_support(world_position: Vector3, height_cache: Dictionary) -> float:
	if use_mock_terrain or terrain_manager == null or not is_instance_valid(terrain_manager):
		return -1000.0
	if not terrain_manager.has_method("get_cached_chunk_height_map"):
		return -1000.0
	var terrain_stride := int(TERRAIN_CHUNK_STRIDE)
	if chunk_size != terrain_stride:
		return -1000.0
	var chunk_coord := Vector2i(
		int(floor(world_position.x / float(terrain_stride))),
		int(floor(world_position.z / float(terrain_stride)))
	)
	var cache_key := "height_map:%d,%d" % [chunk_coord.x, chunk_coord.y]
	var height_map: PackedFloat32Array = height_cache.get(cache_key, PackedFloat32Array())
	if height_map.is_empty():
		height_map = terrain_manager.get_cached_chunk_height_map(chunk_coord, terrain_stride, 1)
		if height_map.is_empty():
			height_cache[cache_key] = height_map
			return -1000.0
		height_cache[cache_key] = height_map
	return _sample_height_map_world(height_map, chunk_coord, world_position, terrain_stride)


func _sample_height_map_world(height_map: PackedFloat32Array, chunk_coord: Vector2i, world_position: Vector3, terrain_stride: int) -> float:
	if height_map.is_empty() or terrain_stride <= 0:
		return -1000.0
	var map_size := int(round(sqrt(float(height_map.size()))))
	if map_size <= 0:
		map_size = terrain_stride
	var local_xf := clampf(world_position.x - float(chunk_coord.x * terrain_stride), 0.0, float(map_size - 1))
	var local_zf := clampf(world_position.z - float(chunk_coord.y * terrain_stride), 0.0, float(map_size - 1))
	var x0 := clampi(int(floorf(local_xf)), 0, map_size - 1)
	var z0 := clampi(int(floorf(local_zf)), 0, map_size - 1)
	var x1 := mini(x0 + 1, map_size - 1)
	var z1 := mini(z0 + 1, map_size - 1)
	var h00 := _sample_height_map_index(height_map, map_size, x0, z0)
	var h10 := _sample_height_map_index(height_map, map_size, x1, z0)
	var h01 := _sample_height_map_index(height_map, map_size, x0, z1)
	var h11 := _sample_height_map_index(height_map, map_size, x1, z1)
	if h00 <= -100.0 or h10 <= -100.0 or h01 <= -100.0 or h11 <= -100.0:
		return -1000.0
	var tx := local_xf - float(x0)
	var tz := local_zf - float(z0)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func _sample_height_map_index(height_map: PackedFloat32Array, map_size: int, local_x: int, local_z: int) -> float:
	var index := local_x * map_size + local_z
	if index < 0 or index >= height_map.size():
		return -1000.0
	return float(height_map[index])


func _try_get_cached_fast_chunk_surface_height(global_x: float, global_z: float, height_cache: Dictionary) -> float:
	var key := "%d,%d" % [int(global_x), int(global_z)]
	if height_cache.has(key):
		return float(height_cache[key])
	var height := _try_get_fast_chunk_surface_height(global_x, global_z)
	height_cache[key] = height
	return height


func _try_get_fast_chunk_surface_height(global_x: float, global_z: float) -> float:
	if terrain_manager == null or not is_instance_valid(terrain_manager):
		return -1000.0
	var chunk_x := int(floor(global_x / TERRAIN_CHUNK_STRIDE))
	var chunk_z := int(floor(global_z / TERRAIN_CHUNK_STRIDE))
	var local_x := int(round(global_x - float(chunk_x) * TERRAIN_CHUNK_STRIDE))
	var local_z := int(round(global_z - float(chunk_z) * TERRAIN_CHUNK_STRIDE))
	return float(terrain_manager.get_chunk_surface_height(Vector3i(chunk_x, 0, chunk_z), local_x, local_z))


func _interpolate_height(world_position: Vector3, x0: float, z0: float, h00: float, h10: float, h01: float, h11: float) -> float:
	var tx := clampf(world_position.x - x0, 0.0, 1.0)
	var tz := clampf(world_position.z - z0, 0.0, 1.0)
	var hx0 := lerpf(h00, h10, tx)
	var hx1 := lerpf(h01, h11, tx)
	return lerpf(hx0, hx1, tz)


func _try_get_support_height(world_position: Vector3) -> float:
	if not use_mock_terrain and terrain_manager and is_instance_valid(terrain_manager):
		if terrain_manager.has_method("get_chunk_surface_height"):
			var chunk_x := int(floor(world_position.x / TERRAIN_CHUNK_STRIDE))
			var chunk_z := int(floor(world_position.z / TERRAIN_CHUNK_STRIDE))
			var local_x := int(round(world_position.x - float(chunk_x) * TERRAIN_CHUNK_STRIDE))
			var local_z := int(round(world_position.z - float(chunk_z) * TERRAIN_CHUNK_STRIDE))
			var fast_chunk_height := float(terrain_manager.get_chunk_surface_height(Vector3i(chunk_x, 0, chunk_z), local_x, local_z))
			if fast_chunk_height > -100.0:
				return fast_chunk_height
		if terrain_manager.has_method("get_surface_height_at_world_position"):
			var fast_surface_height := float(terrain_manager.get_surface_height_at_world_position(world_position.x, world_position.z))
			if fast_surface_height > -100.0:
				return fast_surface_height
		if terrain_manager.has_method("get_terrain_height"):
			var terrain_height := float(terrain_manager.get_terrain_height(world_position.x, world_position.z))
			if terrain_height > -100.0:
				return terrain_height
		return -1000.0
	var height := mock_terrain_base_height
	height += sin((world_position.x + float(world_seed)) * mock_terrain_wave_frequency) * mock_terrain_wave_amplitude
	height += cos((world_position.z - float(world_seed)) * mock_terrain_wave_frequency) * mock_terrain_wave_amplitude * 0.75
	for carve_variant in mock_terrain_carves:
		var carve: Dictionary = carve_variant
		var carve_bounds: AABB = carve.get("bounds", AABB())
		if carve_bounds.has_point(Vector3(world_position.x, height, world_position.z)):
			height -= float(carve.get("depth", 0.0))
	return height


func _is_position_supported(world_position: Vector3, required_clearance: float) -> bool:
	var support_height := _get_support_height(world_position)
	return absf(world_position.y - support_height) <= required_clearance


func _is_tree_supported(record: Dictionary, position: Vector3) -> bool:
	var type := _get_type(StringName(str(record.get("type_id", ""))))
	if type == null or type.support_rule == VegetationType.SupportRule.NONE:
		return true
	var support_points: Array = type.support_points
	if support_points.is_empty():
		support_points = [Vector3.ZERO]
	for point_variant in support_points:
		var support_point: Vector3 = point_variant
		if not _is_position_supported(position + support_point, maxf(0.35, type.support_radius * 0.5)):
			return false
	return true


func _mark_tree_for_stump(chunk: VegetationChunk, record: Dictionary) -> void:
	var stump_type := _get_type(&"stump")
	if stump_type == null:
		record["chopped"] = true
		record["health"] = 0.0
		return
	var old_rid: RID = record.get("instance_rid", RID())
	if old_rid.is_valid() and renderer:
		renderer.destroy_instance(old_rid)
	var stump_transform := _build_individual_transform(stump_type, record)
	var stump_mesh := stump_type.get_source_mesh()
	var stump_rid := RID()
	if stump_mesh and renderer:
		stump_rid = renderer.create_instance(stump_mesh.get_rid(), stump_transform)
	record["instance_rid"] = stump_rid
	record["stump_instance_rid"] = stump_rid
	record["type_id"] = stump_type.id
	record["health"] = 1.0
	record["chopped"] = true
	record["harvested"] = false
	record["support_state"] = "stump"
	record["regrow_time"] = 0.0
	spatial_grid.register_record(stump_type.id, int(record.get("id", 0)), chunk.chunk_coord, record)


func _seeded_rotation_for_position(position: Vector3, record_id: int) -> float:
	var rng := _rng_for_position(position, record_id)
	return rng.randf()


func _make_grass_cell(chunk: VegetationChunk, type: VegetationType, world_position: Vector3, density: float, maturity: float, harvested: bool = false, rng: RandomNumberGenerator = null) -> Dictionary:
	var record_id := _next_record_id
	_next_record_id += 1
	if rng == null:
		rng = _rng_for_position(world_position, record_id)
	var chunk_origin := Vector3(chunk.chunk_coord.x * chunk_size, 0.0, chunk.chunk_coord.y * chunk_size)
	var local_position := world_position - chunk_origin
	var scale := maxf(0.01, type.instance_scale * grass_scale_multiplier * lerpf(0.7, 1.15, clampf((density + maturity) * 0.5, 0.0, 1.0)))
	var cell := {
		"id": record_id,
		"type_id": type.id,
		"coord": Vector2i(int(floor(world_position.x)), int(floor(world_position.z))),
		"position": world_position,
		"local_position": local_position,
		"rotation": rng.randf_range(0.0, TAU),
		"scale": scale,
		"density": density,
		"maturity": maturity,
		"harvested": harvested,
		"regrow_time": type.regrow_seconds,
		"instance_rid": RID(),
		"kind": "grass"
	}
	return cell


func _make_individual_record(type: VegetationType, chunk_coord: Vector2i, world_position: Vector3, harvested: bool = false, rng: RandomNumberGenerator = null) -> Dictionary:
	var record_id := _next_record_id
	_next_record_id += 1
	if rng == null:
		rng = _rng_for_position(world_position, record_id)
	var scale := type.instance_scale * rng.randf_range(0.85, 1.15)
	if type.category == VegetationType.Category.ROCK:
		scale *= rock_scale_multiplier
	var record := {
		"id": record_id,
		"type_id": type.id,
		"coord": chunk_coord,
		"position": world_position,
		"rotation": rng.randf(),
		"scale": scale,
		"health": type.health,
		"chopped": false,
		"harvested": harvested,
		"support_state": "supported",
		"regrow_time": type.regrow_seconds,
		"instance_rid": RID(),
		"stump_instance_rid": RID(),
		"kind": _category_to_kind_name(type.category)
	}
	spatial_grid.register_record(type.id, record_id, chunk_coord, record)
	return record


func _build_individual_transform(type: VegetationType, record: Dictionary) -> Transform3D:
	var rotation := float(record.get("rotation", 0.0)) * TAU
	var scale := maxf(0.05, float(record.get("scale", type.instance_scale)))
	var transform := Transform3D.IDENTITY
	transform = transform.rotated(Vector3.UP, rotation)
	transform = transform.scaled(Vector3.ONE * scale)
	transform.origin = record.get("position", Vector3.ZERO)
	var source_transform := type.mesh_source_transform if type.source_mesh != null else type.get_source_transform()
	return transform * source_transform


func _build_ray_hit(kind: String, chunk: VegetationChunk, record: Dictionary, type: VegetationType, origin: Vector3, ray_dir: Vector3, max_distance: float, fallback_radius: float, fallback_height: float) -> Dictionary:
	if record.is_empty() or bool(record.get("harvested", false)) or bool(record.get("chopped", false)):
		return {}
	var position: Vector3 = record.get("position", Vector3.ZERO)
	var radius := fallback_radius
	var height := fallback_height
	if type:
		radius = maxf(radius, type.support_radius)
		height = maxf(height, type.support_height)
	var center := position + Vector3(0.0, height * 0.5, 0.0)
	var to_candidate := center - origin
	var distance_along_ray := to_candidate.dot(ray_dir)
	if distance_along_ray < 0.0 or distance_along_ray > max_distance:
		return {}
	var ray_point := origin + ray_dir * distance_along_ray
	if ray_point.y < position.y - radius or ray_point.y > position.y + height + radius:
		return {}
	var dx := center.x - ray_point.x
	var dz := center.z - ray_point.z
	var distance_sq_to_ray := dx * dx + dz * dz
	if distance_sq_to_ray > radius * radius:
		return {}
	var record_id := int(record.get("id", -1))
	return {
		"kind": kind,
		"type_id": String(type.id) if type else str(record.get("type_id", "")),
		"coord": chunk.chunk_coord,
		"index": record_id,
		"record_id": record_id,
		"position": center,
		"distance": distance_along_ray,
		"distance_sq_to_ray": distance_sq_to_ray
	}


func _is_better_hit(candidate: Dictionary, current: Dictionary) -> bool:
	if candidate.is_empty():
		return false
	if current.is_empty():
		return true
	var candidate_distance := float(candidate.get("distance", 0.0))
	var current_distance := float(current.get("distance", 0.0))
	if not is_equal_approx(candidate_distance, current_distance):
		return candidate_distance < current_distance
	return float(candidate.get("distance_sq_to_ray", 0.0)) < float(current.get("distance_sq_to_ray", 0.0))


func _harvest_chunk_area(chunk: VegetationChunk, position: Vector3, radius: float, tool: StringName, drops: Dictionary) -> int:
	var count := 0
	var modified := false
	for cell in chunk.grass_cells:
		if bool(cell.get("harvested", false)):
			continue
		var type := _get_type(StringName(str(cell.get("type_id", ""))))
		if type == null or not type.is_harvestable:
			continue
		if cell.get("position", Vector3.ZERO).distance_to(position) > radius:
			continue
		if not _tool_matches(type, tool):
			continue
		cell["harvested"] = true
		cell["regrow_time"] = type.regrow_seconds
		_track_regrowth_if_needed(chunk.chunk_coord, type.regrow_seconds)
		_accumulate_drops(drops, type)
		count += 1
		modified = true
	for bush in chunk.cosmetic_bushes:
		if bool(bush.get("harvested", false)):
			continue
		var type := _get_type(StringName(str(bush.get("type_id", ""))))
		if type == null or not type.is_harvestable:
			continue
		if bush.get("position", Vector3.ZERO).distance_to(position) > radius:
			continue
		if not _tool_matches(type, tool):
			continue
		bush["harvested"] = true
		bush["regrow_time"] = type.regrow_seconds
		_track_regrowth_if_needed(chunk.chunk_coord, type.regrow_seconds)
		_accumulate_drops(drops, type)
		count += 1
		modified = true
	for rock in chunk.rock_records:
		if bool(rock.get("harvested", false)):
			continue
		var type := _get_type(StringName(str(rock.get("type_id", ""))))
		if type == null or not type.is_harvestable:
			continue
		if rock.get("position", Vector3.ZERO).distance_to(position) > radius:
			continue
		if not _tool_matches(type, tool):
			continue
		rock["harvested"] = true
		rock["regrow_time"] = type.regrow_seconds
		_track_regrowth_if_needed(chunk.chunk_coord, type.regrow_seconds)
		_accumulate_drops(drops, type)
		count += 1
		modified = true
	if modified:
		_queue_chunk_rebuild(chunk.chunk_coord, VegetationChunk.DirtyReason.HARVESTED)
	return count


func _harvest_grass_index(chunk: VegetationChunk, record_id: int) -> bool:
	for cell in chunk.grass_cells:
		if int(cell.get("id", -1)) != record_id:
			continue
		if bool(cell.get("harvested", false)):
			return false
		var type := _get_type(StringName(str(cell.get("type_id", ""))))
		cell["harvested"] = true
		cell["regrow_time"] = float(type.regrow_seconds) if type else 0.0
		_track_regrowth_if_needed(chunk.chunk_coord, float(cell.get("regrow_time", 0.0)))
		_queue_chunk_rebuild(chunk.chunk_coord, VegetationChunk.DirtyReason.HARVESTED)
		return true
	return false


func _damage_tree_index(chunk: VegetationChunk, record_id: int, damage: float, tool: StringName) -> bool:
	for tree in chunk.tree_records:
		if int(tree.get("id", -1)) != record_id:
			continue
		var type := _get_type(StringName(str(tree.get("type_id", ""))))
		if type == null or not _tool_matches(type, tool):
			return false
		var health := float(tree.get("health", 0.0)) - damage
		tree["health"] = health
		if health <= 0.0:
			_mark_tree_for_stump(chunk, tree)
			_queue_chunk_rebuild(chunk.chunk_coord, VegetationChunk.DirtyReason.HARVESTED)
		return true
	return false


func _damage_bush_index(chunk: VegetationChunk, record_id: int, damage: float, tool: StringName) -> bool:
	for bush in chunk.cosmetic_bushes:
		if int(bush.get("id", -1)) != record_id:
			continue
		var type := _get_type(StringName(str(bush.get("type_id", ""))))
		if type == null or not _tool_matches(type, tool):
			return false
		var health := float(bush.get("health", 0.0)) - damage
		bush["health"] = health
		if health <= 0.0:
			bush["harvested"] = true
			bush["regrow_time"] = type.regrow_seconds
			_track_regrowth_if_needed(chunk.chunk_coord, type.regrow_seconds)
			_queue_chunk_rebuild(chunk.chunk_coord, VegetationChunk.DirtyReason.HARVESTED)
		return true
	return false


func _damage_rock_index(chunk: VegetationChunk, record_id: int, damage: float, tool: StringName) -> bool:
	for rock in chunk.rock_records:
		if int(rock.get("id", -1)) != record_id:
			continue
		var type := _get_type(StringName(str(rock.get("type_id", ""))))
		if type == null or not _tool_matches(type, tool):
			return false
		var health := float(rock.get("health", 0.0)) - damage
		rock["health"] = health
		if health <= 0.0:
			rock["harvested"] = true
			rock["regrow_time"] = type.regrow_seconds
			_track_regrowth_if_needed(chunk.chunk_coord, type.regrow_seconds)
			_queue_chunk_rebuild(chunk.chunk_coord, VegetationChunk.DirtyReason.HARVESTED)
		return true
	return false


func _tool_matches(type: VegetationType, tool: StringName) -> bool:
	if type == null:
		return false
	if String(type.required_tool).is_empty():
		return true
	return type.required_tool == tool


func _accumulate_drops(drops: Dictionary, type: VegetationType) -> void:
	for drop in type.drops:
		if not (drop is Dictionary):
			continue
		var drop_dict: Dictionary = drop
		var drop_id := StringName(str(drop_dict.get("id", "")))
		if String(drop_id).is_empty():
			continue
		drops[drop_id] = int(drops.get(drop_id, 0)) + int(drop_dict.get("amount", 1))


func _update_ready_state() -> void:
	var ready := is_vegetation_ready()
	if ready and not _initial_stream_complete:
		_initial_stream_complete = true
	if ready != _last_ready_state:
		_last_ready_state = ready
		vegetation_ready_changed.emit(ready)


func _is_terrain_ready_for_streaming() -> bool:
	if use_mock_terrain:
		return true
	if terrain_manager == null or not is_instance_valid(terrain_manager):
		return false
	if terrain_manager.has_method("is_initial_load_complete"):
		return bool(terrain_manager.is_initial_load_complete())
	if terrain_manager.has_method("get_pending_nodes_count") and int(terrain_manager.get_pending_nodes_count()) > 0:
		return false
	if "initial_load_phase" in terrain_manager and bool(terrain_manager.initial_load_phase):
		return false
	var readiness_radius := maxi(2, initial_stream_radius_chunks)
	if terrain_manager.has_method("is_spawn_zone_ready") and bool(terrain_manager.is_spawn_zone_ready(focus_position, readiness_radius)):
		return true
	if terrain_manager.has_method("are_chunks_ready_around") and bool(terrain_manager.are_chunks_ready_around(focus_position, readiness_radius)):
		return true
	if _try_get_support_height(focus_position) > -100.0:
		return true
	if terrain_manager.has_method("get_telemetry_snapshot"):
		var terrain_telemetry: Dictionary = terrain_manager.get_telemetry_snapshot()
		var active_count := int(terrain_telemetry.get("active_chunk_count", 0))
		var loaded_count := int(terrain_telemetry.get("loaded_chunk_count", 0))
		var surface_count := int(terrain_telemetry.get("rendered_terrain_chunk_count", 0))
		var collision_count := int(terrain_telemetry.get("collision_ready_chunk_count", 0))
		if collision_count <= 0:
			collision_count = int(terrain_telemetry.get("collision_chunk_count", 0))
		return loaded_count > 0 and active_count > 0 and (surface_count > 0 or collision_count > 0)
	if "initial_load_phase" in terrain_manager:
		return not bool(terrain_manager.initial_load_phase)
	return false


func _has_dirty_chunks() -> bool:
	for chunk_coord_variant in chunks.keys():
		var chunk: VegetationChunk = chunks[chunk_coord_variant] as VegetationChunk
		if chunk and chunk.has_pending_rebuild():
			return true
	return false


func _populate_chunk(chunk: VegetationChunk, _reason: int) -> void:
	if chunk == null:
		return
	var start_ms := Time.get_ticks_msec()
	chunk.grass_cells.clear()
	chunk.cosmetic_bushes.clear()
	chunk.tree_records.clear()
	chunk.rock_records.clear()
	chunk.individual_instance_rids.clear()
	chunk.render_chunk_key = ""
	chunk.grass_mesh_rid = RID()
	chunk.grass_instance_rid = RID()
	var rng := RandomNumberGenerator.new()
	rng.seed = _chunk_seed(chunk.chunk_coord)
	var settings := _profile_settings()
	var chunk_origin := Vector3(chunk.chunk_coord.x * chunk_size, 0.0, chunk.chunk_coord.y * chunk_size)
	var had_surface_support := _chunk_has_surface_support_samples(chunk.chunk_coord)
	var support_height_cache: Dictionary = {}

	var grass_step := maxi(1, int(settings.get("grass_step", 4)))
	var grass_density := float(settings.get("grass_density", 0.65))
	var grass_maturity := float(settings.get("grass_maturity", 0.8))
	var bush_density := float(settings.get("bush_density", 0.08))
	var tree_density := float(settings.get("tree_density", 0.06))
	var rock_density := float(settings.get("rock_density", 0.04))
	var tree_spacing := maxi(4, int(settings.get("tree_spacing", 24)))
	var bush_spacing := maxi(4, int(settings.get("bush_spacing", 16)))
	var rock_spacing := maxi(4, int(settings.get("rock_spacing", 12)))
	var focus_distance_sq := _chunk_distance_sq_from_focus(chunk.chunk_coord)
	if focus_distance_sq > 16:
		grass_step = maxi(grass_step, 3)
		grass_density *= 0.78
	elif focus_distance_sq > 4:
		grass_density *= 0.9

	for x in range(0, chunk_size, grass_step):
		for z in range(0, chunk_size, grass_step):
			if rng.randf() > grass_density:
				continue
			var grass_type := _pick_grass_type(rng)
			if grass_type == null:
				continue
			var world_x := chunk_origin.x + float(x) + rng.randf_range(-0.35, 0.35)
			var world_z := chunk_origin.z + float(z) + rng.randf_range(-0.35, 0.35)
			var support_height := _try_get_precise_support_height_cached(Vector3(world_x, 0.0, world_z), support_height_cache)
			if support_height <= -100.0:
				continue
			if _is_spawn_rejected(world_x, support_height, world_z, 0.5):
				continue
			var world_pos := Vector3(world_x, support_height + grass_y_offset, world_z)
			chunk.grass_cells.append(_make_grass_cell(chunk, grass_type, world_pos, rng.randf_range(0.5, 1.0), grass_maturity, false, rng))

	for x in range(0, chunk_size, tree_spacing):
		for z in range(0, chunk_size, tree_spacing):
			if rng.randf() > tree_density:
				continue
			var tree_type := _pick_tree_type(rng)
			if tree_type == null:
				continue
			var tree_pos := _jittered_grid_point(rng, chunk_origin, x, z, tree_spacing)
			var tree_support_height := _try_get_precise_support_height_cached(tree_pos, support_height_cache)
			if tree_support_height <= -100.0:
				continue
			if _is_spawn_rejected(tree_pos.x, tree_support_height, tree_pos.z, 1.0):
				continue
			tree_pos.y = tree_support_height + tree_y_offset
			chunk.tree_records.append(_make_individual_record(tree_type, chunk.chunk_coord, tree_pos, false, rng))

	for x in range(0, chunk_size, bush_spacing):
		for z in range(0, chunk_size, bush_spacing):
			if rng.randf() > bush_density:
				continue
			var bush_type := _pick_bush_type(rng)
			if bush_type == null:
				continue
			var bush_pos := _jittered_grid_point(rng, chunk_origin, x, z, bush_spacing)
			var bush_support_height := _try_get_precise_support_height_cached(bush_pos, support_height_cache)
			if bush_support_height <= -100.0:
				continue
			if _is_spawn_rejected(bush_pos.x, bush_support_height, bush_pos.z, 0.5):
				continue
			bush_pos.y = bush_support_height
			chunk.cosmetic_bushes.append(_make_individual_record(bush_type, chunk.chunk_coord, bush_pos, false, rng))

	for x in range(0, chunk_size, rock_spacing):
		for z in range(0, chunk_size, rock_spacing):
			if rng.randf() > rock_density:
				continue
			var rock_type := _pick_rock_type(rng)
			if rock_type == null:
				continue
			var rock_pos := _jittered_grid_point(rng, chunk_origin, x, z, rock_spacing)
			var rock_support_height := _try_get_precise_support_height_cached(rock_pos, support_height_cache)
			if rock_support_height <= -100.0:
				continue
			if _is_spawn_rejected(rock_pos.x, rock_support_height, rock_pos.z, 0.5):
				continue
			rock_pos.y = rock_support_height + rock_y_offset
			chunk.rock_records.append(_make_individual_record(rock_type, chunk.chunk_coord, rock_pos, false, rng))

	chunk.state = VegetationChunk.State.DATA_READY
	chunk.terrain_support_missing = not had_surface_support \
		and chunk.grass_cells.is_empty() \
		and chunk.cosmetic_bushes.is_empty() \
		and chunk.tree_records.is_empty() \
		and chunk.rock_records.is_empty()
	chunk.last_generated_frame = Engine.get_process_frames()
	_last_generation_time_ms = float(Time.get_ticks_msec() - start_ms)


func _merge_aabb(a: AABB, b: AABB) -> AABB:
	if a.size == Vector3.ZERO:
		return b
	if b.size == Vector3.ZERO:
		return a
	var a_min := a.position
	var a_max := a.position + a.size
	var b_min := b.position
	var b_max := b.position + b.size
	var min_v := Vector3(minf(a_min.x, b_min.x), minf(a_min.y, b_min.y), minf(a_min.z, b_min.z))
	var max_v := Vector3(maxf(a_max.x, b_max.x), maxf(a_max.y, b_max.y), maxf(a_max.z, b_max.z))
	return AABB(min_v, max_v - min_v)


func _get_type(type_id: StringName) -> VegetationType:
	if registry == null:
		return null
	return registry.get_type(type_id)


func _get_types_for_category(category: int) -> Array[VegetationType]:
	if registry == null:
		return []
	if _types_by_category_cache.has(category):
		return _types_by_category_cache[category]
	var types := registry.get_types_by_category(category)
	_types_by_category_cache[category] = types
	return types


func _type_health(type_id: StringName, fallback: float = 1.0) -> float:
	var type := _get_type(type_id)
	if type == null:
		return fallback
	return type.health


func _type_regrow_seconds(type_id: StringName, fallback: float = 0.0) -> float:
	var type := _get_type(type_id)
	if type == null:
		return fallback
	return type.regrow_seconds


func _rng_for_position(position: Vector3, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(world_seed) ^ int(position.x * 1000.0) ^ int(position.z * 1000.0) ^ salt
	return rng


func _distance_sq_xz(a: Vector3, b: Vector3) -> float:
	var dx := a.x - b.x
	var dz := a.z - b.z
	return dx * dx + dz * dz
