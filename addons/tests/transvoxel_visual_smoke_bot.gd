extends Node3D

const MeshBuilderClass := "MeshBuilder"

var hold_seconds: float = 15.0
var elapsed_seconds: float = 0.0

func _ready() -> void:
	var hold_text := OS.get_environment("TRANSVOXEL_VISUAL_HOLD_SECONDS")
	if hold_text.is_valid_float():
		hold_seconds = max(0.0, float(hold_text))
	print("[TRANSVOXEL_VISUAL] Starting visual smoke scene")
	print("[TRANSVOXEL_VISUAL] Hold seconds: %.1f" % hold_seconds)
	set_process(true)
	call_deferred("_build_scene")


func _build_scene() -> void:
	if not ClassDB.class_exists(MeshBuilderClass):
		push_error("[TRANSVOXEL_VISUAL] MeshBuilder GDExtension class not available")
		get_tree().quit(1)
		return

	var builder: Object = ClassDB.instantiate(MeshBuilderClass)
	if builder == null:
		push_error("[TRANSVOXEL_VISUAL] Could not instantiate MeshBuilder")
		get_tree().quit(1)
		return

	_setup_camera()
	_setup_light()
	_add_mesh_pair(builder)

	print("[TRANSVOXEL_VISUAL] Scene built. Inspect the seam between the two blocks.")


func _process(delta: float) -> void:
	if hold_seconds <= 0.0:
		return
	elapsed_seconds += delta
	if elapsed_seconds >= hold_seconds:
		print("[TRANSVOXEL_VISUAL] Hold complete, quitting...")
		get_tree().quit(0)


func _setup_camera() -> void:
	var camera := Camera3D.new()
	camera.name = "VisualCamera"
	camera.position = Vector3(0, 64, 96)
	add_child(camera)
	camera.look_at_from_position(camera.position, Vector3(16, 8, 0), Vector3.UP)
	camera.current = true


func _setup_light() -> void:
	var light := DirectionalLight3D.new()
	light.name = "VisualLight"
	light.rotation_degrees = Vector3(-45, 35, 0)
	light.light_energy = 2.0
	add_child(light)

	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	world.environment = env
	add_child(world)


func _add_mesh_pair(builder: Object) -> void:
	var heightmap := _build_heightmap_slope(128, 128, 8, 28)
	var fine_mesh: ArrayMesh = builder.build_transvoxel_heightfield_mesh(
		heightmap,
		128,
		128,
		128.0,
		32.0,
		Vector3(-64, 0, -64),
		Vector3(64, 32, 64),
		8,
		1 << 0
	)
	var coarse_mesh: ArrayMesh = builder.build_transvoxel_heightfield_mesh(
		heightmap,
		128,
		128,
		128.0,
		32.0,
		Vector3(0, 0, -64),
		Vector3(128, 64, 128),
		8,
		1 << 1
	)

	var fine := MeshInstance3D.new()
	fine.name = "FineBlock"
	fine.mesh = fine_mesh
	fine.material_override = _make_material(Color(0.62, 0.55, 0.35))
	add_child(fine)

	var coarse := MeshInstance3D.new()
	coarse.name = "CoarseBlock"
	coarse.mesh = coarse_mesh
	coarse.material_override = _make_material(Color(0.35, 0.62, 0.45))
	add_child(coarse)


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_BACK
	return material


func _build_heightmap_slope(width: int, height: int, low_value: int, high_value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(width * height)
	for z in range(height):
		for x in range(width):
			var t := float(x) / float(max(1, width - 1))
			bytes[z * width + x] = int(round(lerp(float(low_value), float(high_value), t)))
	return bytes
