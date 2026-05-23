extends Node3D
class_name VegetationRuntimeManager

const VegetationRegistry = preload("res://world_vegetation/types/vegetation_registry.gd")
const VegetationRuntime = preload("res://world_vegetation/runtime/vegetation_runtime.gd")

signal vegetation_ready_changed(ready: bool)
signal all_vegetation_ready

@export var terrain_manager_path: NodePath
@export var terrain_manager: NodePath
@export var registry: VegetationRegistry
@export var world_seed: int = 12345
@export var chunk_size: int = 64
@export var initial_stream_radius_chunks: int = 5
@export var active_stream_radius_chunks: int = 5
@export var benchmark_profile: StringName = &"world_dense"
@export var use_mock_terrain: bool = false
@export var auto_spawn_benchmark_content: bool = true
@export var enable_streaming: bool = true
@export var render_enabled: bool = true
@export var debug_overlay_enabled: bool = true
@export var debug_collision: bool = false
@export var focus_position: Vector3 = Vector3.ZERO
@export var mock_terrain_base_height: float = 0.0
@export var mock_terrain_wave_amplitude: float = 1.5
@export var mock_terrain_wave_frequency: float = 0.05
@export var max_rebuilds_per_frame: int = 1
@export var max_generations_per_frame: int = 1
@export var use_native_chunk_builder: bool = true
@export var use_native_spatial_grid: bool = true
@export var use_grass_source_meshes: bool = true
@export var allow_debug_grass_cards: bool = false
@export var road_clearance: float = 2.0

# Legacy scene compatibility fields. The old node used imported GLB-local
# scale/offset values; the runtime uses normalized meter-ish source meshes.
# Keep these exports loadable, but normalize them before configuring runtime.
@export var tree_y_offset: float = 0.0
@export var grass_scale: float = 0.5
@export var grass_y_offset: float = 0.06
@export var grass_collision_radius: float = 0.3
@export var rock_scale: float = 0.3
@export var rock_y_offset: float = 0.0

var runtime: VegetationRuntime
var _terrain_manager: Node = null
var _bootstrapped: bool = false
var _last_focus_position: Vector3 = Vector3(1.0e20, 1.0e20, 1.0e20)
var _last_global_render_sync_ms: float = 0.0
var _last_global_render_collect_ms: float = 0.0
var _last_global_render_pack_ms: float = 0.0
var _last_global_render_sync_kind: String = ""
var _last_global_render_sync_chunk_count: int = 0
var _last_global_render_candidate_chunk_count: int = 0


func _ready() -> void:
	set_process(true)
	_terrain_manager = _resolve_terrain_manager()
	call_deferred("_bootstrap_impl")


func _process(_delta: float) -> void:
	_sync_terrain_manager_reference()
	if runtime == null:
		var bootstrap_focus := _get_focus_position()
		if bootstrap_focus.distance_squared_to(_last_focus_position) > 0.25:
			_last_focus_position = bootstrap_focus
			focus_position = bootstrap_focus
		return

	var focus := _get_focus_position()
	if focus.distance_squared_to(_last_focus_position) <= 0.25:
		return
	_last_focus_position = focus
	focus_position = focus
	runtime.set_focus_position(focus)


func _bootstrap_impl() -> void:
	if _bootstrapped:
		return
	if registry == null:
		registry = VegetationRegistry.create_default() as VegetationRegistry
	if OS.get_environment("TOWN_STALL_DISABLE_VEGETATION_RENDER").strip_edges() == "1":
		render_enabled = false
	_terrain_manager = _resolve_terrain_manager()
	var initial_focus := _get_focus_position()
	focus_position = initial_focus
	if runtime == null:
		runtime = VegetationRuntime.new()
		runtime.name = "VegetationRuntime"
		add_child(runtime)
	if not runtime.vegetation_ready_changed.is_connected(_on_runtime_vegetation_ready_changed):
		runtime.vegetation_ready_changed.connect(_on_runtime_vegetation_ready_changed)
	runtime.configure({
		"registry": registry,
		"terrain_manager": _terrain_manager,
		"world_seed": world_seed,
		"chunk_size": chunk_size,
		"initial_stream_radius_chunks": initial_stream_radius_chunks,
		"active_stream_radius_chunks": active_stream_radius_chunks,
		"profile": benchmark_profile,
		"use_mock_terrain": use_mock_terrain,
		"auto_spawn_benchmark_content": auto_spawn_benchmark_content,
		"enable_streaming": enable_streaming,
		"render_enabled": render_enabled,
		"focus_position": focus_position,
		"mock_terrain_base_height": mock_terrain_base_height,
		"mock_terrain_wave_amplitude": mock_terrain_wave_amplitude,
		"mock_terrain_wave_frequency": mock_terrain_wave_frequency,
		"grass_scale_multiplier": _runtime_grass_scale(),
		"grass_y_offset": grass_y_offset,
		"tree_y_offset": _runtime_tree_y_offset(),
		"rock_scale_multiplier": _runtime_rock_scale(),
		"rock_y_offset": _runtime_rock_y_offset(),
		"max_rebuilds_per_frame": max_rebuilds_per_frame,
		"max_generations_per_frame": max_generations_per_frame,
		"use_native_chunk_builder": use_native_chunk_builder,
		"use_native_spatial_grid": use_native_spatial_grid,
		"use_grass_source_meshes": use_grass_source_meshes,
		"allow_debug_grass_cards": allow_debug_grass_cards,
		"road_clearance": road_clearance
	})
	runtime.bootstrap()
	_bootstrapped = true
	_last_focus_position = initial_focus
	focus_position = initial_focus
	runtime.set_focus_position(initial_focus)


func is_vegetation_ready() -> bool:
	return runtime != null and runtime.is_vegetation_ready()


func get_pending_chunks_count() -> int:
	return runtime.get_pending_chunks_count() if runtime else 0


func get_telemetry_snapshot() -> Dictionary:
	var telemetry: Dictionary = runtime.get_telemetry_snapshot() if runtime else {}
	_sync_legacy_profile_fields(telemetry)
	return telemetry


func clear_all_data(immediate_free: bool = false) -> void:
	if runtime:
		runtime.clear_all_data(immediate_free)


func clear_for_shutdown() -> void:
	if runtime:
		runtime.clear_for_shutdown()


func clear_loaded_chunk_data(immediate_free: bool = false) -> void:
	clear_all_data(immediate_free)


func initialize_noise() -> void:
	if runtime:
		runtime.clear_all_data(false)


func get_save_data() -> Dictionary:
	return runtime.get_save_data() if runtime and runtime.has_method("get_save_data") else {}


func load_save_data(data: Dictionary) -> void:
	if runtime and runtime.has_method("load_save_data"):
		runtime.load_save_data(data)


func notify_terrain_changed(bounds: AABB) -> void:
	if runtime:
		runtime.notify_terrain_changed(bounds)


func apply_mock_dig(bounds: AABB, depth: float = 6.0) -> void:
	if runtime:
		runtime.apply_mock_dig(bounds, depth)


func clear_vegetation_in_area(center: Vector3, radius: float) -> void:
	if runtime:
		runtime.clear_vegetation_in_area(center, radius)


func set_focus_position(position: Vector3) -> void:
	_last_focus_position = position
	focus_position = position
	if runtime:
		runtime.set_focus_position(position)


func harvest_area(position: Vector3, radius: float, tool: StringName = &"hand") -> Dictionary:
	return runtime.harvest_area(position, radius, tool) if runtime else {}


func find_nearest_vegetation_along_ray(
		origin: Vector3,
		direction: Vector3,
		max_distance: float,
		include_grass: bool = true,
		include_rocks: bool = true,
		include_trees: bool = true,
		include_bushes: bool = true
) -> Dictionary:
	if runtime == null:
		return {}
	return runtime.find_nearest_vegetation_along_ray(origin, direction, max_distance, include_grass, include_rocks, include_trees, include_bushes)


func harvest_data_hit(hit: Dictionary) -> bool:
	return runtime.harvest_data_hit(hit) if runtime else false


func chop_tree_at_index(chunk_coord: Vector2i, index: int, damage: float = 9999.0) -> bool:
	return runtime.chop_tree_at_index(chunk_coord, index, damage) if runtime else false


func chop_tree_by_collider(target: Object) -> bool:
	return runtime.chop_tree_by_collider(target) if runtime else false


func harvest_grass_by_collider(target: Object) -> bool:
	return runtime.harvest_grass_by_collider(target) if runtime else false


func harvest_rock_by_collider(target: Object) -> bool:
	return runtime.harvest_rock_by_collider(target) if runtime else false


func resolve_tree_body_collision(body_origin: Vector3, body_radius: float = 0.4, body_height: float = 1.8) -> Dictionary:
	return runtime.resolve_tree_body_collision(body_origin, body_radius, body_height) if runtime else {}


func place_grass(position: Vector3) -> bool:
	return runtime.place_grass(position) if runtime else false


func place_rock(position: Vector3) -> bool:
	return runtime.place_rock(position) if runtime else false


func get_runtime_node() -> VegetationRuntime:
	return runtime


func _runtime_grass_scale() -> float:
	if use_grass_source_meshes:
		# The migrated scenes still serialize grass_scale=0.01 from an early
		# broken source-mesh pass. The GLB grass source is roughly 1 m tall, so
		# that value makes it effectively invisible.
		if grass_scale > 0.0 and grass_scale < 0.08:
			return 0.5
		return maxf(0.001, grass_scale)
	# Existing town scenes serialize grass_scale=0.01 for the legacy GLB
	# path. Applying that to normalized runtime cards makes grass invisible.
	if grass_scale > 0.0 and grass_scale < 0.08:
		return 1.0
	return maxf(0.05, grass_scale)


func _runtime_tree_y_offset() -> float:
	# Legacy tree placement used a large Y offset to compensate for a GLB
	# origin. Runtime tree placement samples the terrain surface directly.
	if absf(tree_y_offset) > 2.0:
		return 0.0
	return tree_y_offset


func _runtime_rock_scale() -> float:
	return maxf(0.05, rock_scale)


func _runtime_rock_y_offset() -> float:
	# Runtime rock GLBs are grounded at import time. The legacy 0.3 m offset
	# compensated for a center-origin mesh and would make grounded rocks float.
	if use_grass_source_meshes and absf(rock_y_offset) >= 0.2:
		return 0.0
	return rock_y_offset


func _on_runtime_vegetation_ready_changed(ready: bool) -> void:
	vegetation_ready_changed.emit(ready)
	if ready:
		all_vegetation_ready.emit()


func _get_global_render_batch_count() -> int:
	if runtime == null:
		return 0
	var telemetry: Dictionary = runtime.get_telemetry_snapshot()
	_sync_legacy_profile_fields(telemetry)
	var batch_count := int(telemetry.get("global_render_batch_count", -1))
	if batch_count >= 0:
		return batch_count
	var renderer_stats: Dictionary = telemetry.get("renderer", {})
	return int(renderer_stats.get("chunk_mesh_count", 0)) \
		+ int(renderer_stats.get("chunk_instance_count", 0)) \
		+ int(renderer_stats.get("individual_instance_count", 0))


func _get_global_render_dirty_kinds() -> Array[String]:
	if runtime == null:
		return []
	var telemetry: Dictionary = runtime.get_telemetry_snapshot()
	_sync_legacy_profile_fields(telemetry)
	if int(telemetry.get("dirty_chunk_count", 0)) <= 0:
		return []
	return ["vegetation"]


func _sync_legacy_profile_fields(telemetry: Dictionary) -> void:
	_last_global_render_sync_ms = float(telemetry.get("last_global_render_sync_ms", telemetry.get("last_rebuild_time_ms", 0.0)))
	_last_global_render_collect_ms = float(telemetry.get("last_global_render_collect_ms", telemetry.get("last_support_refresh_time_ms", 0.0)))
	_last_global_render_pack_ms = float(telemetry.get("last_global_render_pack_ms", telemetry.get("last_generation_time_ms", 0.0)))
	_last_global_render_sync_kind = str(telemetry.get("last_global_render_sync_kind", ""))
	_last_global_render_sync_chunk_count = int(telemetry.get("last_global_render_sync_chunk_count", telemetry.get("dirty_chunk_count", 0)))
	_last_global_render_candidate_chunk_count = int(telemetry.get("last_global_render_candidate_chunk_count", telemetry.get("chunk_count", 0)))


func _get_focus_position() -> Vector3:
	if _terrain_manager == null or not is_instance_valid(_terrain_manager):
		_terrain_manager = _resolve_terrain_manager()
	if _terrain_manager and is_instance_valid(_terrain_manager):
		var viewer: Node3D = _terrain_manager.get("viewer") as Node3D
		if viewer is Node3D and is_instance_valid(viewer):
			return (viewer as Node3D).global_position
	var player := get_tree().get_first_node_in_group("player")
	if player is Node3D and is_instance_valid(player):
		return (player as Node3D).global_position
	return focus_position


func _sync_terrain_manager_reference() -> void:
	if _terrain_manager != null and is_instance_valid(_terrain_manager):
		return
	_terrain_manager = _resolve_terrain_manager()
	if runtime and _terrain_manager and is_instance_valid(_terrain_manager):
		runtime.configure({"terrain_manager": _terrain_manager})


func _resolve_terrain_manager() -> Node:
	var resolved := get_node_or_null(terrain_manager_path) if not terrain_manager_path.is_empty() else null
	if resolved and is_instance_valid(resolved):
		return resolved
	resolved = get_node_or_null(terrain_manager) if not terrain_manager.is_empty() else null
	if resolved and is_instance_valid(resolved):
		return resolved
	resolved = get_tree().get_first_node_in_group("terrain_manager")
	if resolved and is_instance_valid(resolved):
		return resolved
	var parent_node := get_parent()
	if parent_node:
		resolved = parent_node.find_child("TerrainManager", true, false)
		if resolved and is_instance_valid(resolved):
			return resolved
	return null
