extends Node3D
class_name VegetationBenchmarkScene

const VegetationRuntimeManager = preload("res://world_vegetation/runtime/vegetation_manager.gd")
const VegetationDebugOverlay = preload("res://world_vegetation/debug/vegetation_debug_overlay.gd")

@export var benchmark_profile: StringName = &"grass_field"
@export var world_seed: int = 12345
@export var chunk_size: int = 32
@export var initial_stream_radius_chunks: int = 4
@export var active_stream_radius_chunks: int = 6
@export var focus_position: Vector3 = Vector3.ZERO
@export var use_mock_terrain: bool = true
@export var auto_spawn_benchmark_content: bool = true
@export var enable_streaming: bool = true
@export var debug_overlay_enabled: bool = true
@export var mock_terrain_base_height: float = 0.0
@export var mock_terrain_wave_amplitude: float = 1.5
@export var mock_terrain_wave_frequency: float = 0.05
@export var max_rebuilds_per_frame: int = 2
@export var camera_distance: float = 28.0
@export var camera_height: float = 16.0
@export var ground_size: float = 240.0
@export var ground_y: float = -0.05

var _built := false


func _ready() -> void:
	if _built:
		return
	_built = true
	_build_scene()


func _build_scene() -> void:
	_create_ground()
	_create_camera()
	_create_light()
	_create_runtime_manager()
	_create_debug_overlay()


func _create_ground() -> void:
	var ground := MeshInstance3D.new()
	ground.name = "BenchmarkGround"
	var plane := PlaneMesh.new()
	plane.size = Vector2(ground_size, ground_size)
	ground.mesh = plane
	ground.position = Vector3(0.0, ground_y, 0.0)
	ground.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.18, 0.18, 0.16)
	material.roughness = 1.0
	ground.material_override = material
	add_child(ground)


func _create_camera() -> void:
	var camera := Camera3D.new()
	camera.name = "BenchmarkCamera"
	camera.current = true
	camera.position = focus_position + Vector3(0.0, camera_height, camera_distance)
	add_child(camera)
	camera.look_at(focus_position + Vector3(0.0, 1.5, 0.0), Vector3.UP)


func _create_light() -> void:
	var light := DirectionalLight3D.new()
	light.name = "BenchmarkSun"
	light.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	light.light_energy = 1.3
	light.shadow_enabled = false
	add_child(light)


func _create_runtime_manager() -> void:
	var manager := VegetationRuntimeManager.new()
	manager.name = "VegetationRuntimeManager"
	manager.benchmark_profile = benchmark_profile
	manager.world_seed = world_seed
	manager.chunk_size = chunk_size
	manager.initial_stream_radius_chunks = initial_stream_radius_chunks
	manager.active_stream_radius_chunks = active_stream_radius_chunks
	manager.focus_position = focus_position
	manager.use_mock_terrain = use_mock_terrain
	manager.auto_spawn_benchmark_content = auto_spawn_benchmark_content
	manager.enable_streaming = enable_streaming
	manager.debug_overlay_enabled = debug_overlay_enabled
	manager.mock_terrain_base_height = mock_terrain_base_height
	manager.mock_terrain_wave_amplitude = mock_terrain_wave_amplitude
	manager.mock_terrain_wave_frequency = mock_terrain_wave_frequency
	manager.max_rebuilds_per_frame = max_rebuilds_per_frame
	add_child(manager)


func _create_debug_overlay() -> void:
	if not debug_overlay_enabled:
		return
	var overlay := VegetationDebugOverlay.new()
	overlay.name = "VegetationDebugOverlay"
	overlay.manager_path = NodePath("VegetationRuntimeManager")
	overlay.visible_on_start = true
	add_child(overlay)
