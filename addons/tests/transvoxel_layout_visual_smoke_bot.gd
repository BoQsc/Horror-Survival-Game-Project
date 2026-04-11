extends Node3D

const MeshBuilderClass := "MeshBuilder"
const LayoutScript := preload("res://world_marching_cubes/transvoxel_layout.gd")

var hold_seconds: float = 15.0
var elapsed_seconds: float = 0.0

func _ready() -> void:
	var hold_text := OS.get_environment("TRANSVOXEL_LAYOUT_VISUAL_HOLD_SECONDS")
	if hold_text.is_valid_float():
		hold_seconds = max(0.0, float(hold_text))
	print("[TRANSVOXEL_LAYOUT_VISUAL] Starting layout smoke scene")
	print("[TRANSVOXEL_LAYOUT_VISUAL] Hold seconds: %.1f" % hold_seconds)
	set_process(true)
	call_deferred("_build_scene")


func _build_scene() -> void:
	if not ClassDB.class_exists(MeshBuilderClass):
		push_error("[TRANSVOXEL_LAYOUT_VISUAL] MeshBuilder GDExtension class not available")
		get_tree().quit(1)
		return

	var builder: Object = ClassDB.instantiate(MeshBuilderClass)
	if builder == null:
		push_error("[TRANSVOXEL_LAYOUT_VISUAL] Could not instantiate MeshBuilder")
		get_tree().quit(1)
		return

	_setup_camera()
	_setup_light()
	_add_layout_blocks(builder)

	print("[TRANSVOXEL_LAYOUT_VISUAL] Scene built. Inspect the block hierarchy.")


func _process(delta: float) -> void:
	if hold_seconds <= 0.0:
		return
	elapsed_seconds += delta
	if elapsed_seconds >= hold_seconds:
		print("[TRANSVOXEL_LAYOUT_VISUAL] Hold complete, quitting...")
		get_tree().quit(0)


func _setup_camera() -> void:
	var camera := Camera3D.new()
	camera.name = "LayoutCamera"
	camera.position = Vector3(0, 96, 144)
	add_child(camera)
	camera.look_at_from_position(camera.position, Vector3(48, 12, 48), Vector3.UP)
	camera.current = true


func _setup_light() -> void:
	var light := DirectionalLight3D.new()
	light.name = "LayoutLight"
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


func _add_layout_blocks(builder: Object) -> void:
	var layout_builder := LayoutScript.new()
	var layout: Dictionary = layout_builder.build_layout(Vector2i(37, -22), 4, 128, 2, 4)
	var blocks: Array = layout.get("blocks", [])
	var heightmap := _build_heightmap_corner(128, 128, 10, 28)

	for block in blocks:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = "%s_%d_%d" % [String(block.get("block_kind", "block")), int(block.get("grid_x", 0)), int(block.get("grid_z", 0))]
		mesh_instance.material_override = _make_material(_color_for_block(block))
		var block_size := float(block.get("block_size", 0.0))
		var mesh: Mesh = builder.build_transvoxel_heightfield_mesh(
			heightmap,
			128,
			128,
			128.0,
			32.0,
			Vector3(float(block.get("min_x", 0.0)), 0.0, float(block.get("min_z", 0.0))),
			Vector3(block_size, 32.0, block_size),
			int(block.get("subdivisions", 4)),
			int(block.get("transition_mask", 0))
		)
		if mesh == null:
			var box := BoxMesh.new()
			box.size = Vector3(block_size, 16.0, block_size)
			mesh = box
			print("[TRANSVOXEL_LAYOUT_VISUAL] Fallback box used for block %s" % mesh_instance.name)
		mesh_instance.mesh = mesh
		if int(block.get("lod_level", 0)) <= 0:
			mesh_instance.position = Vector3(float(block.get("min_x", 0.0)), 0.0, float(block.get("min_z", 0.0)))
		else:
			mesh_instance.position = Vector3.ZERO
		add_child(mesh_instance)


func _color_for_block(block: Dictionary) -> Color:
	if int(block.get("lod_level", 0)) <= 0:
		return Color(0.65, 0.58, 0.34)
	return Color(0.35, 0.62, 0.45)


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_BACK
	return material


func _build_heightmap_corner(width: int, height: int, low_value: int, high_value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(width * height)
	for z in range(height):
		for x in range(width):
			var corner_high := (x >= width / 2 and z >= height / 2)
			bytes[z * width + x] = high_value if corner_high else low_value
	return bytes
