@tool
extends Node3D

# This preview uses the same BuildingChunk / BuildingMesher path as the game,
# so merged-face scale and UV behavior should match what the player sees.
# The floor is a full 16x16 chunk so texture repetition is easier to judge.

const BuildingVisuals = preload("res://world_building_system/building_visuals.gd")
const UV_DEBUG_SIZE := 64
const ENABLE_UV_DEBUG := false

class PreviewManager:
	extends Node
	var world_map_mode := true
	var skip_building_chunk_mesh_render_for_test := false
	var skip_building_chunk_collisions_for_test := false
	var skip_building_visual_batches_for_test := true

@onready var reference_block: MeshInstance3D = $ReferenceBlock
@onready var camera: Camera3D = $Camera3D

var _material: Material
var _uv_debug_material: StandardMaterial3D
var _block_mesh: BoxMesh
var _preview_manager: PreviewManager
var _mesher: BuildingMesher
var _rendered_block_chunk: BuildingChunk
var _floor_chunk: BuildingChunk
var _status_label: Label3D
var _mesh_requested: bool = false
var _floor_debug_material_applied: bool = false
var _diagnostics_logged: bool = false


func _ready() -> void:
	_setup_material()
	_setup_uv_debug_material()
	_setup_status_label()
	_reload_building_extension_if_possible()
	_setup_reference_block()
	_setup_real_chunk_preview()

	if is_instance_valid(camera):
		camera.look_at(Vector3.ZERO, Vector3.UP)

	set_process(true)

	call_deferred("_request_preview_mesh")


func _process(delta: float) -> void:
	if is_instance_valid(reference_block):
		reference_block.rotate_y(delta * 0.45)
	_update_preview_diagnostics()


func _setup_material() -> void:
	if _material == null:
		_material = BuildingVisuals.get_shared_building_material()

	if _block_mesh == null:
		_block_mesh = BoxMesh.new()
		_block_mesh.size = Vector3.ONE


func _setup_uv_debug_material() -> void:
	if not ENABLE_UV_DEBUG:
		return
	if _uv_debug_material != null:
		return

	var image := Image.create(UV_DEBUG_SIZE, UV_DEBUG_SIZE, false, Image.FORMAT_RGBA8)
	for y in range(UV_DEBUG_SIZE):
		for x in range(UV_DEBUG_SIZE):
			var color := Color(0.90, 0.88, 0.82, 1.0)
			var cell_x := int(x / 8)
			var cell_y := int(y / 8)
			if ((cell_x + cell_y) % 2) == 0:
				color = Color(0.78, 0.82, 0.95, 1.0)
			else:
				color = Color(0.95, 0.80, 0.76, 1.0)

			if x < 2 or y < 2 or x >= UV_DEBUG_SIZE - 2 or y >= UV_DEBUG_SIZE - 2:
				color = Color(0.95, 0.15, 0.15, 1.0)
			elif x == UV_DEBUG_SIZE / 2 or y == UV_DEBUG_SIZE / 2:
				color = Color(0.10, 0.10, 0.10, 1.0)
			elif x % 8 == 0 or y % 8 == 0:
				color = Color(0.18, 0.18, 0.18, 1.0)

			# Add a simple directional cue so it is obvious when the texture flips.
			if x > UV_DEBUG_SIZE - 14 and abs(y - (UV_DEBUG_SIZE / 2)) <= 3:
				color = Color(0.95, 0.90, 0.10, 1.0)
			if y < 14 and abs(x - (UV_DEBUG_SIZE / 2)) <= 3:
				color = Color(0.10, 0.90, 0.50, 1.0)

			image.set_pixel(x, y, color)

	var texture := ImageTexture.create_from_image(image)
	_uv_debug_material = StandardMaterial3D.new()
	_uv_debug_material.albedo_color = Color.WHITE
	_uv_debug_material.albedo_texture = texture
	_uv_debug_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_uv_debug_material.texture_repeat = true
	_uv_debug_material.set_flag(BaseMaterial3D.FLAG_USE_TEXTURE_REPEAT, true)


func _setup_status_label() -> void:
	if _status_label != null:
		return

	_status_label = Label3D.new()
	_status_label.name = "UvStatusLabel"
	_status_label.position = Vector3(-4.0, 6.0, 0.0)
	_status_label.modulate = Color(0.08, 0.08, 0.08, 1.0)
	_status_label.font_size = 28
	add_child(_status_label)


func _reload_building_extension_if_possible() -> void:
	if not Engine.is_editor_hint():
		return
	if not ClassDB.class_exists("GDExtensionManager"):
		return

	var extension_path := "res://gdextension/bin/high_performance.gdextension"
	var status := GDExtensionManager.reload_extension(extension_path)
	if status != GDExtensionManager.LOAD_STATUS_OK:
		push_warning("Could not reload GDExtension '%s' (status %d)." % [extension_path, status])
	else:
		print("Reloaded GDExtension: %s" % extension_path)
		if is_instance_valid(_status_label):
			_status_label.text = "Reloaded native extension...\nBuilding exact UV preview..."


func _setup_reference_block() -> void:
	if not is_instance_valid(reference_block):
		return

	reference_block.mesh = _block_mesh
	reference_block.material_override = _material
	reference_block.position = Vector3(-12.5, 0.5, 0.0)


func _setup_real_chunk_preview() -> void:
	if not ClassDB.class_exists("MeshBuilder"):
		push_warning("MeshBuilder GDExtension is unavailable, so the exact building preview cannot be generated.")
		return

	_preview_manager = PreviewManager.new()
	add_child(_preview_manager)

	_mesher = BuildingMesher.new()
	if not is_instance_valid(_mesher):
		push_warning("Failed to create BuildingMesher for the exact floor preview.")
		return
	_mesher.name = "PreviewMesher"
	add_child(_mesher)

	_rendered_block_chunk = BuildingChunk.new(Vector3i.ZERO)
	if not is_instance_valid(_rendered_block_chunk):
		push_warning("Failed to create BuildingChunk for the rendered block preview.")
		return
	_rendered_block_chunk.name = "PreviewRenderedBlockChunk"
	_rendered_block_chunk.manager = _preview_manager
	_rendered_block_chunk.mesher = _mesher
	_rendered_block_chunk.position = Vector3(-11.5, 0.0, -0.5)
	add_child(_rendered_block_chunk)
	if not is_instance_valid(_rendered_block_chunk.mesh_instance):
		_rendered_block_chunk._ready()
	_rendered_block_chunk.set_voxel(Vector3i.ZERO, 1, 0)

	_floor_chunk = BuildingChunk.new(Vector3i.ZERO)
	if not is_instance_valid(_floor_chunk):
		push_warning("Failed to create BuildingChunk for the exact floor preview.")
		return
	_floor_chunk.name = "PreviewFloorChunk"
	_floor_chunk.manager = _preview_manager
	_floor_chunk.mesher = _mesher
	_floor_chunk.position = Vector3(-8.0, 0.0, -8.0)
	add_child(_floor_chunk)
	if not is_instance_valid(_floor_chunk.mesh_instance):
		_floor_chunk._ready()

	for z in range(16):
		for x in range(16):
			_floor_chunk.set_voxel(Vector3i(x, 0, z), 1, 0)


func _update_preview_diagnostics() -> void:
	if is_instance_valid(_status_label) and is_instance_valid(camera):
		_status_label.look_at(camera.global_position, Vector3.UP)

	if is_instance_valid(_floor_chunk) and is_instance_valid(_floor_chunk.mesh_instance):
		var floor_mesh := _floor_chunk.mesh_instance.mesh
		if ENABLE_UV_DEBUG and floor_mesh and _floor_chunk.mesh_instance.material_override != _uv_debug_material:
			_floor_chunk.mesh_instance.material_override = _uv_debug_material
			_floor_debug_material_applied = true

		if floor_mesh:
			var uv_summary := _get_uv_summary(floor_mesh)
			if not uv_summary.is_empty():
				if not _diagnostics_logged:
					print("WoodFloorPreview UV summary: min=%s max=%s count=%d" % [
						uv_summary.get("min", Vector2.ZERO),
						uv_summary.get("max", Vector2.ZERO),
						int(uv_summary.get("count", 0))
					])
					_diagnostics_logged = true
				_status_label.text = "Exact floor UV test\nUV min: %s\nUV max: %s\nUV count: %d\nDebug texture: %s" % [
					uv_summary.get("min", Vector2.ZERO),
					uv_summary.get("max", Vector2.ZERO),
					int(uv_summary.get("count", 0)),
					"on" if _floor_debug_material_applied else "off"
				]
			else:
				_status_label.text = "Exact floor UV test\nWaiting for UV data...\nDebug texture: %s" % ("on" if _floor_debug_material_applied else "off")


func _get_uv_summary(mesh: Mesh) -> Dictionary:
	if mesh == null or mesh.get_surface_count() <= 0:
		return {}

	if not (mesh is ArrayMesh):
		return {}

	var array_mesh := mesh as ArrayMesh
	var mesh_data := MeshDataTool.new()
	if mesh_data.create_from_surface(array_mesh, 0) != OK:
		return {}

	var vertex_count := mesh_data.get_vertex_count()
	if vertex_count <= 0:
		return {}

	var min_uv := mesh_data.get_vertex_uv(0)
	var max_uv := min_uv
	for i in range(vertex_count):
		var uv := mesh_data.get_vertex_uv(i)
		if uv.x < min_uv.x:
			min_uv.x = uv.x
		if uv.y < min_uv.y:
			min_uv.y = uv.y
		if uv.x > max_uv.x:
			max_uv.x = uv.x
		if uv.y > max_uv.y:
			max_uv.y = uv.y

	return {
		"min": min_uv,
		"max": max_uv,
		"count": vertex_count
	}


func _request_preview_mesh() -> void:
	if _mesh_requested:
		return
	if not is_instance_valid(_rendered_block_chunk) or not is_instance_valid(_floor_chunk):
		return

	_mesh_requested = true
	_rendered_block_chunk.rebuild_mesh()
	_floor_chunk.rebuild_mesh()
