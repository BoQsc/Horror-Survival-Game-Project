@tool
extends PanelContainer

const ViewerData = preload("res://addons/world_prefab_viewer/prefab_viewer_data.gd")
const ViewerMesher = preload("res://addons/world_prefab_viewer/prefab_viewer_mesher.gd")
const OPTIONAL_WOOD_TEXTURE_PATH := "res://world_greedy_meshing/wood-block-texture.png"
const RUNTIME_MATERIAL_CACHE_KEY := -999

var _prefab_entries: Array = []
var _current_prefab: Dictionary = {}
var _material_cache: Dictionary = {}
var _runtime_mesher: RefCounted
var _runtime_error := ""
var _camera_target := Vector3.ZERO
var _camera_distance := 12.0
var _camera_yaw := PI / 4.0
var _camera_pitch := deg_to_rad(30.0)
var _is_orbiting := false
var _is_panning := false

var _prefab_list: ItemList
var _rotation_option: OptionButton
var _show_runtime_mesh_toggle: CheckBox
var _show_objects_toggle: CheckBox
var _show_overlays_toggle: CheckBox
var _info_label: RichTextLabel
var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _preview_root: Node3D
var _camera: Camera3D


func _ready() -> void:
	custom_minimum_size = Vector2(0.0, 420.0)
	_runtime_mesher = ViewerMesher.new()
	_build_ui()
	_build_viewport()
	_reload_prefabs()


func _exit_tree() -> void:
	if _runtime_mesher and _runtime_mesher.has_method("dispose"):
		_runtime_mesher.dispose()
	_runtime_mesher = null


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(root)

	var toolbar := HBoxContainer.new()
	root.add_child(toolbar)

	var refresh_button := Button.new()
	refresh_button.text = "Refresh"
	refresh_button.pressed.connect(_reload_prefabs)
	toolbar.add_child(refresh_button)

	var fit_button := Button.new()
	fit_button.text = "Fit"
	fit_button.pressed.connect(_rerender_current_prefab)
	toolbar.add_child(fit_button)

	var rotation_label := Label.new()
	rotation_label.text = "Rotation"
	toolbar.add_child(rotation_label)

	_rotation_option = OptionButton.new()
	_rotation_option.add_item("0 deg", 0)
	_rotation_option.add_item("90 deg", 1)
	_rotation_option.add_item("180 deg", 2)
	_rotation_option.add_item("270 deg", 3)
	_rotation_option.item_selected.connect(_rerender_current_prefab)
	toolbar.add_child(_rotation_option)

	_show_runtime_mesh_toggle = CheckBox.new()
	_show_runtime_mesh_toggle.text = "Runtime Mesh"
	_show_runtime_mesh_toggle.button_pressed = true
	_show_runtime_mesh_toggle.toggled.connect(_rerender_current_prefab)
	toolbar.add_child(_show_runtime_mesh_toggle)

	_show_objects_toggle = CheckBox.new()
	_show_objects_toggle.text = "Objects"
	_show_objects_toggle.button_pressed = true
	_show_objects_toggle.toggled.connect(_rerender_current_prefab)
	toolbar.add_child(_show_objects_toggle)

	_show_overlays_toggle = CheckBox.new()
	_show_overlays_toggle.text = "Overlays"
	_show_overlays_toggle.button_pressed = true
	_show_overlays_toggle.toggled.connect(_rerender_current_prefab)
	toolbar.add_child(_show_overlays_toggle)

	var stretch := Control.new()
	stretch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(stretch)

	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	var list_panel := VBoxContainer.new()
	list_panel.custom_minimum_size = Vector2(260.0, 0.0)
	list_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(list_panel)

	var list_label := Label.new()
	list_label.text = "Prefab Files"
	list_panel.add_child(list_label)

	_prefab_list = ItemList.new()
	_prefab_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prefab_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_prefab_list.item_selected.connect(_on_prefab_selected)
	list_panel.add_child(_prefab_list)

	var right_panel := VBoxContainer.new()
	right_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(right_panel)

	_info_label = RichTextLabel.new()
	_info_label.bbcode_enabled = true
	_info_label.fit_content = true
	_info_label.scroll_active = false
	_info_label.custom_minimum_size = Vector2(0.0, 140.0)
	_info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_panel.add_child(_info_label)

	_viewport_container = SubViewportContainer.new()
	_viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viewport_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_container.custom_minimum_size = Vector2(320.0, 240.0)
	_viewport_container.stretch = true
	_viewport_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_viewport_container.gui_input.connect(_on_viewport_input)
	right_panel.add_child(_viewport_container)


func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "PreviewViewport"
	_viewport.disable_3d = false
	_viewport.size = Vector2i(640, 480)
	_viewport.msaa_3d = Viewport.MSAA_2X
	_viewport.world_3d = World3D.new()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport_container.add_child(_viewport)

	var world := Node3D.new()
	world.name = "PreviewWorld"
	_viewport.add_child(world)

	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.09, 0.11, 1.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.46, 0.48, 0.52, 1.0)
	env.ambient_light_energy = 0.9
	environment.environment = env
	world.add_child(environment)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, 45.0, 0.0)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	world.add_child(sun)

	var fill_light := OmniLight3D.new()
	fill_light.position = Vector3(-8.0, 8.0, -6.0)
	fill_light.light_energy = 0.55
	fill_light.omni_range = 40.0
	world.add_child(fill_light)

	_preview_root = Node3D.new()
	_preview_root.name = "PreviewRoot"
	world.add_child(_preview_root)

	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 55.0
	_camera.near = 0.05
	_camera.far = 200.0
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.position = Vector3(12.0, 10.0, 12.0)
	world.add_child(_camera)


func _reload_prefabs() -> void:
	var selected_name := ""
	if _prefab_list and _prefab_list.get_selected_items().size() > 0:
		var current_index := _prefab_list.get_selected_items()[0]
		selected_name = str(_prefab_list.get_item_metadata(current_index).get("name", ""))

	_prefab_entries = ViewerData.list_prefabs()
	_prefab_list.clear()
	for entry in _prefab_entries:
		var label := "%s [%s]" % [entry.get("name", ""), entry.get("source", "")]
		_prefab_list.add_item(label)
		var item_index := _prefab_list.item_count - 1
		_prefab_list.set_item_metadata(item_index, entry)
		_prefab_list.set_item_tooltip(item_index, str(entry.get("path", "")))

	if _prefab_entries.is_empty():
		_current_prefab = {}
		_info_label.text = "[b]No prefabs found.[/b]\n\nExpected files in:\n- res://world_prefabs/\n- user://world_prefabs/"
		_clear_preview()
		return

	var target_index := 0
	for i in range(_prefab_entries.size()):
		if str(_prefab_entries[i].get("name", "")) == selected_name:
			target_index = i
			break

	_prefab_list.select(target_index)
	_on_prefab_selected(target_index)


func _on_prefab_selected(index: int) -> void:
	if index < 0 or index >= _prefab_entries.size():
		return
	var entry: Dictionary = _prefab_list.get_item_metadata(index)
	_current_prefab = ViewerData.load_prefab(str(entry.get("path", "")))
	_update_info()
	_render_current_prefab()


func _rerender_current_prefab(_arg = null) -> void:
	_render_current_prefab()


func _clear_preview() -> void:
	if not _preview_root:
		return
	for child in _preview_root.get_children():
		child.free()


func _render_current_prefab() -> void:
	_clear_preview()
	if _current_prefab.is_empty():
		return

	_runtime_error = ""
	var bounds := {
		"min": Vector3(INF, INF, INF),
		"max": Vector3(-INF, -INF, -INF)
	}
	var rotation := _rotation_option.get_selected_id()

	_add_axes(bounds)

	var rendered_runtime := false
	if _show_runtime_mesh_toggle.button_pressed:
		rendered_runtime = _render_runtime_blocks(rotation, bounds)

	if not rendered_runtime:
		for cell in _current_prefab.get("cells", []):
			var block_node := _create_block_node(cell, rotation)
			_preview_root.add_child(block_node)
			var rotated_pos: Vector3i = ViewerData.rotate_block_offset(cell.get("pos", Vector3i.ZERO), rotation)
			_include_bounds(bounds, Vector3(rotated_pos), Vector3(rotated_pos) + Vector3.ONE)

	if _show_objects_toggle.button_pressed:
		for obj in _current_prefab.get("objects", []):
			var object_preview := _create_object_node(obj, rotation)
			_preview_root.add_child(object_preview.get("node"))
			_include_bounds(bounds, object_preview.get("min"), object_preview.get("max"))

	if _show_overlays_toggle.button_pressed:
		var overlay_bounds := _add_overlay_nodes(rotation)
		if overlay_bounds.has("min"):
			_include_bounds(bounds, overlay_bounds.get("min"), overlay_bounds.get("max"))

	_frame_camera(bounds.get("min"), bounds.get("max"))
	_update_info()


func _add_axes(bounds: Dictionary) -> void:
	_add_axis(Vector3(1.0, 0.02, 0.02), Vector3(0.5, 0.0, 0.0), Color(0.91, 0.33, 0.33, 1.0), bounds)
	_add_axis(Vector3(0.02, 1.0, 0.02), Vector3(0.0, 0.5, 0.0), Color(0.38, 0.85, 0.45, 1.0), bounds)
	_add_axis(Vector3(0.02, 0.02, 1.0), Vector3(0.0, 0.0, 0.5), Color(0.42, 0.67, 0.95, 1.0), bounds)


func _add_axis(size: Vector3, position: Vector3, color: Color, bounds: Dictionary) -> void:
	var axis := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	axis.mesh = mesh
	axis.material_override = _make_solid_material(color, false)
	axis.position = position
	_preview_root.add_child(axis)
	_include_bounds(bounds, position - (size * 0.5), position + (size * 0.5))


func _create_block_node(cell: Dictionary, rotation: int) -> Node3D:
	var block_type := int(cell.get("type", 1))
	var meta := int(cell.get("meta", 0))
	var final_meta := ViewerData.rotate_directional_meta(block_type, meta, rotation)
	var rotated_pos: Vector3i = ViewerData.rotate_block_offset(cell.get("pos", Vector3i.ZERO), rotation)
	var anchor := Vector3(rotated_pos)

	if block_type == 4:
		return _create_stair_node(anchor, final_meta, _get_block_material(block_type))

	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _get_block_material(block_type)
	mesh_instance.position = anchor + Vector3(0.5, 0.5, 0.5)
	return mesh_instance


func _create_stair_node(anchor: Vector3, meta: int, material: Material) -> Node3D:
	var root := Node3D.new()
	root.position = anchor + Vector3(0.5, 0.0, 0.5)
	root.rotation_degrees.y = float(posmod(meta, 4) * 90)

	for i in range(3):
		var step := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.0, 1.0 / 3.0, 1.0 / 3.0)
		step.mesh = box
		step.material_override = material
		step.position = Vector3(
			0.0,
			(-0.5 + (1.0 / 6.0)) + (float(i) / 3.0),
			(-0.5 + (1.0 / 6.0)) + (float(i) / 3.0)
		)
		root.add_child(step)

	return root


func _create_object_node(obj: Dictionary, prefab_rotation: int) -> Dictionary:
	var object_id := int(obj.get("object_id", 0))
	var info := ViewerData.get_object_info(object_id)
	var base_size: Vector3 = info.get("size", Vector3.ONE)
	var combined_rotation := posmod(int(obj.get("rotation", 0)) + prefab_rotation, 4)
	var rendered_size := base_size
	if combined_rotation == 1 or combined_rotation == 3:
		rendered_size = Vector3(base_size.z, base_size.y, base_size.x)

	var local_corner := Vector3(
		float(obj.get("x", 0.0)),
		float(obj.get("y", 0.0)),
		float(obj.get("z", 0.0))
	)
	var rotated_corner := ViewerData.rotate_vector_offset(local_corner, prefab_rotation)
	var target_corner := rotated_corner + ViewerData.get_grid_correction(prefab_rotation)
	var center := target_corner + Vector3(rendered_size.x * 0.5, base_size.y * 0.5 + float(obj.get("fractional_y", 0.0)), rendered_size.z * 0.5)

	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = rendered_size
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _make_solid_material(info.get("color", Color(0.75, 0.75, 0.75, 1.0)), true)
	mesh_instance.position = center
	mesh_instance.rotation_degrees.y = float(combined_rotation * 90)

	return {
		"node": mesh_instance,
		"min": center - (rendered_size * 0.5),
		"max": center + (rendered_size * 0.5)
	}


func _add_overlay_nodes(rotation: int) -> Dictionary:
	var overlay_bounds := {}
	var placement: Dictionary = _current_prefab.get("placement", {})
	var grade_y := float(placement.get("grade_y", 0))

	var surface_rect := ViewerData.rotate_rect(ViewerData.get_surface_rect(_current_prefab), rotation)
	if not surface_rect.is_empty():
		var surface_bounds := _add_rect_overlay(surface_rect, grade_y + 0.02, Color(0.22, 0.78, 0.40, 0.18))
		overlay_bounds = _merge_bounds(overlay_bounds, surface_bounds)

	var reservation_rect := ViewerData.rotate_rect(ViewerData.get_reservation_rect(_current_prefab), rotation)
	if not reservation_rect.is_empty():
		var reservation_bounds := _add_rect_overlay(reservation_rect, grade_y + 0.07, Color(0.27, 0.53, 0.90, 0.12))
		overlay_bounds = _merge_bounds(overlay_bounds, reservation_bounds)

	for volume in placement.get("excavation_volumes", []):
		var rotated_volume := ViewerData.rotate_volume(volume, rotation)
		var volume_bounds := _add_volume_overlay(rotated_volume, Color(0.85, 0.28, 0.28, 0.14))
		overlay_bounds = _merge_bounds(overlay_bounds, volume_bounds)

	return overlay_bounds


func _add_rect_overlay(rect: Dictionary, y_level: float, color: Color) -> Dictionary:
	var min_corner: Vector2i = rect.get("min", Vector2i.ZERO)
	var max_corner: Vector2i = rect.get("max", Vector2i.ZERO)
	var footprint: Vector2i = rect.get("footprint", Vector2i.ONE)

	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(float(footprint.x), 0.04, float(footprint.y))
	mesh_instance.mesh = box
	mesh_instance.material_override = _make_solid_material(color, true, true)
	mesh_instance.position = Vector3(
		(float(min_corner.x + max_corner.x) + 1.0) * 0.5,
		y_level,
		(float(min_corner.y + max_corner.y) + 1.0) * 0.5
	)
	_preview_root.add_child(mesh_instance)

	return {
		"min": mesh_instance.position - (box.size * 0.5),
		"max": mesh_instance.position + (box.size * 0.5)
	}


func _add_volume_overlay(volume: Dictionary, color: Color) -> Dictionary:
	if volume.is_empty():
		return {}

	var min_corner: Vector3i = volume.get("min", Vector3i.ZERO)
	var max_corner: Vector3i = volume.get("max", Vector3i.ZERO)
	var size := Vector3(
		float(max_corner.x - min_corner.x + 1),
		float(max_corner.y - min_corner.y + 1),
		float(max_corner.z - min_corner.z + 1)
	)
	var center := Vector3(
		(float(min_corner.x + max_corner.x) + 1.0) * 0.5,
		(float(min_corner.y + max_corner.y) + 1.0) * 0.5,
		(float(min_corner.z + max_corner.z) + 1.0) * 0.5
	)

	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	mesh_instance.material_override = _make_solid_material(color, true, true)
	mesh_instance.position = center
	_preview_root.add_child(mesh_instance)

	return {
		"min": center - (size * 0.5),
		"max": center + (size * 0.5)
	}


func _frame_camera(bounds_min: Vector3, bounds_max: Vector3) -> void:
	if bounds_min.x == INF or bounds_max.x == -INF:
		bounds_min = Vector3.ZERO
		bounds_max = Vector3.ONE

	_camera_target = (bounds_min + bounds_max) * 0.5
	var extents := bounds_max - bounds_min
	var radius := max(max(extents.x, extents.y), extents.z)
	radius = max(radius, 4.0)

	_camera_distance = max(radius * 2.15, 3.0)
	_camera_yaw = PI / 4.0
	_camera_pitch = deg_to_rad(30.0)
	_apply_camera_transform()
	_camera.far = max(200.0, radius * 10.0)


func _on_viewport_input(event: InputEvent) -> void:
	if not _camera:
		return

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		match mouse_event.button_index:
			MOUSE_BUTTON_RIGHT:
				if mouse_event.pressed:
					_is_orbiting = not mouse_event.shift_pressed
					_is_panning = mouse_event.shift_pressed
				else:
					_is_orbiting = false
					_is_panning = false
			MOUSE_BUTTON_MIDDLE:
				_is_panning = mouse_event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if mouse_event.pressed:
					_zoom_camera(0.88)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mouse_event.pressed:
					_zoom_camera(1.14)
	elif event is InputEventMouseMotion:
		var motion_event := event as InputEventMouseMotion
		if _is_orbiting:
			_camera_yaw -= motion_event.relative.x * 0.01
			_camera_pitch = clamp(_camera_pitch + (motion_event.relative.y * 0.01), deg_to_rad(-80.0), deg_to_rad(80.0))
			_apply_camera_transform()
		elif _is_panning:
			_pan_camera(motion_event.relative)


func _zoom_camera(multiplier: float) -> void:
	_camera_distance = clamp(_camera_distance * multiplier, 1.5, 500.0)
	_apply_camera_transform()


func _pan_camera(relative: Vector2) -> void:
	var pan_scale := max(_camera_distance * 0.0025, 0.01)
	var basis := _camera.global_transform.basis
	var right := basis.x.normalized()
	var up := basis.y.normalized()
	_camera_target += (-right * relative.x * pan_scale) + (up * relative.y * pan_scale)
	_apply_camera_transform()


func _apply_camera_transform() -> void:
	var offset := Vector3(
		cos(_camera_pitch) * sin(_camera_yaw),
		sin(_camera_pitch),
		cos(_camera_pitch) * cos(_camera_yaw)
	) * _camera_distance
	_camera.position = _camera_target + offset
	_camera.look_at(_camera_target, Vector3.UP)


func _render_runtime_blocks(rotation: int, bounds: Dictionary) -> bool:
	if not _runtime_mesher or not _runtime_mesher.is_available():
		_runtime_error = _runtime_mesher.get_last_error() if _runtime_mesher else "Runtime preview mesher is unavailable."
		return false

	var chunk_map := {}
	var cells: Array = _current_prefab.get("cells", [])
	for cell in cells:
		var block_type := clampi(int(cell.get("type", 1)), 0, 255)
		var meta := clampi(int(cell.get("meta", 0)), 0, 255)
		var final_meta := ViewerData.rotate_directional_meta(block_type, meta, rotation)
		var rotated_pos: Vector3i = ViewerData.rotate_block_offset(cell.get("pos", Vector3i.ZERO), rotation)
		var chunk_coord := _world_to_chunk(rotated_pos)
		var local_pos := _world_to_chunk_local(rotated_pos)
		var key := "%d,%d,%d" % [chunk_coord.x, chunk_coord.y, chunk_coord.z]

		if not chunk_map.has(key):
			var voxel_bytes := PackedByteArray()
			voxel_bytes.resize(ViewerMesher.CHUNK_VOLUME)
			voxel_bytes.fill(0)
			var voxel_meta := PackedByteArray()
			voxel_meta.resize(ViewerMesher.CHUNK_VOLUME)
			voxel_meta.fill(0)
			chunk_map[key] = {
				"coord": chunk_coord,
				"voxels": voxel_bytes,
				"meta": voxel_meta
			}

		var chunk_data: Dictionary = chunk_map[key]
		var voxel_bytes: PackedByteArray = chunk_data.get("voxels", PackedByteArray())
		var voxel_meta: PackedByteArray = chunk_data.get("meta", PackedByteArray())
		var index := _chunk_index(local_pos)
		voxel_bytes.encode_u8(index, block_type)
		voxel_meta.encode_u8(index, final_meta)
		chunk_data["voxels"] = voxel_bytes
		chunk_data["meta"] = voxel_meta
		chunk_map[key] = chunk_data

		_include_bounds(bounds, Vector3(rotated_pos), Vector3(rotated_pos) + Vector3.ONE)

	var chunk_keys: Array = chunk_map.keys()
	chunk_keys.sort()
	var rendered_any := false
	for key in chunk_keys:
		var chunk_data: Dictionary = chunk_map[key]
		var arrays: Array = _runtime_mesher.generate_arrays(
			chunk_data.get("voxels", PackedByteArray()),
			chunk_data.get("meta", PackedByteArray())
		)
		if arrays.is_empty():
			continue

		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.material_override = _get_runtime_block_material()
		mesh_instance.position = Vector3(chunk_data.get("coord", Vector3i.ZERO)) * float(ViewerMesher.CHUNK_SIZE)
		_preview_root.add_child(mesh_instance)
		rendered_any = true

	if not rendered_any and not cells.is_empty():
		_runtime_error = "Runtime mesher produced no chunk surfaces for this prefab."
		return false

	return true


func _world_to_chunk(world_pos: Vector3i) -> Vector3i:
	return Vector3i(
		int(floor(float(world_pos.x) / float(ViewerMesher.CHUNK_SIZE))),
		int(floor(float(world_pos.y) / float(ViewerMesher.CHUNK_SIZE))),
		int(floor(float(world_pos.z) / float(ViewerMesher.CHUNK_SIZE)))
	)


func _world_to_chunk_local(world_pos: Vector3i) -> Vector3i:
	var local := Vector3i(
		posmod(world_pos.x, ViewerMesher.CHUNK_SIZE),
		posmod(world_pos.y, ViewerMesher.CHUNK_SIZE),
		posmod(world_pos.z, ViewerMesher.CHUNK_SIZE)
	)
	return local


func _chunk_index(local_pos: Vector3i) -> int:
	return local_pos.x + (local_pos.y * ViewerMesher.CHUNK_SIZE) + (local_pos.z * ViewerMesher.CHUNK_SIZE * ViewerMesher.CHUNK_SIZE)


func _update_info() -> void:
	if _current_prefab.is_empty():
		_info_label.text = "[b]No prefab selected.[/b]"
		return

	var placement: Dictionary = _current_prefab.get("placement", {})
	var stats: Dictionary = _current_prefab.get("stats", {})
	var lines: Array[String] = []
	lines.append("[b]%s[/b]" % _current_prefab.get("name", "Prefab"))
	lines.append("%s" % _current_prefab.get("path", ""))
	lines.append("")
	lines.append("Declared size: %s" % _current_prefab.get("size", Vector3i.ONE))
	lines.append("Parsed size: %s" % _current_prefab.get("actual_size", Vector3i.ONE))
	lines.append("Blocks: %d" % int(stats.get("block_count", 0)))
	lines.append("Objects: %d" % int(stats.get("object_count", 0)))
	lines.append("grade_y: %d" % int(placement.get("grade_y", 0)))
	lines.append("Excavation volumes: %d" % placement.get("excavation_volumes", []).size())
	lines.append("Preview mesh: %s" % ("runtime" if _show_runtime_mesh_toggle and _show_runtime_mesh_toggle.button_pressed and _runtime_error.is_empty() else "simple"))
	lines.append("Controls: RMB orbit, Shift+RMB/MMB pan, Wheel zoom")

	var surface_rect := ViewerData.get_surface_rect(_current_prefab)
	if not surface_rect.is_empty():
		lines.append(
			"Surface footprint: %s -> %s" % [surface_rect.get("min", Vector2i.ZERO), surface_rect.get("max", Vector2i.ZERO)]
		)

	var reservation_rect := ViewerData.get_reservation_rect(_current_prefab)
	if not reservation_rect.is_empty():
		lines.append(
			"Reservation footprint: %s -> %s" % [reservation_rect.get("min", Vector2i.ZERO), reservation_rect.get("max", Vector2i.ZERO)]
		)

	var errors: Array = _current_prefab.get("errors", [])
	var warnings: Array = _current_prefab.get("warnings", [])
	if not errors.is_empty():
		lines.append("")
		lines.append("[color=#ff8f8f][b]Errors[/b][/color]")
		for entry in errors:
			lines.append("- %s" % entry)
	if not warnings.is_empty():
		lines.append("")
		lines.append("[color=#ffd48f][b]Warnings[/b][/color]")
		for entry in warnings:
			lines.append("- %s" % entry)

	if not _runtime_error.is_empty():
		lines.append("")
		lines.append("[color=#ffd48f][b]Preview Fallback[/b][/color]")
		lines.append("- %s" % _runtime_error)

	_info_label.text = "\n".join(lines)


func _get_block_material(block_type: int) -> Material:
	if _material_cache.has(block_type):
		return _material_cache[block_type]

	var material := StandardMaterial3D.new()
	material.roughness = 1.0

	match block_type:
		1:
			material.albedo_color = Color(0.69, 0.53, 0.34, 1.0)
			if ResourceLoader.exists(OPTIONAL_WOOD_TEXTURE_PATH):
				material.albedo_texture = load(OPTIONAL_WOOD_TEXTURE_PATH)
				material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		2:
			material.albedo_color = Color(0.58, 0.61, 0.64, 1.0)
		3:
			material.albedo_color = Color(0.86, 0.62, 0.27, 1.0)
		4:
			material.albedo_color = Color(0.93, 0.78, 0.33, 1.0)
		_:
			material.albedo_color = Color(0.90, 0.32, 0.78, 1.0)

	_material_cache[block_type] = material
	return material


func _get_runtime_block_material() -> Material:
	if _material_cache.has(RUNTIME_MATERIAL_CACHE_KEY):
		return _material_cache[RUNTIME_MATERIAL_CACHE_KEY]

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	material.roughness = 1.0
	if ResourceLoader.exists(OPTIONAL_WOOD_TEXTURE_PATH):
		material.albedo_texture = load(OPTIONAL_WOOD_TEXTURE_PATH)
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	else:
		material.albedo_color = Color(0.69, 0.53, 0.34, 1.0)

	_material_cache[RUNTIME_MATERIAL_CACHE_KEY] = material
	return material


func _make_solid_material(color: Color, transparent: bool, unshaded: bool = false) -> Material:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _include_bounds(bounds: Dictionary, entry_min: Vector3, entry_max: Vector3) -> void:
	var current_min: Vector3 = bounds.get("min", Vector3(INF, INF, INF))
	var current_max: Vector3 = bounds.get("max", Vector3(-INF, -INF, -INF))
	bounds["min"] = Vector3(
		min(current_min.x, entry_min.x),
		min(current_min.y, entry_min.y),
		min(current_min.z, entry_min.z)
	)
	bounds["max"] = Vector3(
		max(current_max.x, entry_max.x),
		max(current_max.y, entry_max.y),
		max(current_max.z, entry_max.z)
	)


func _merge_bounds(existing: Dictionary, incoming: Dictionary) -> Dictionary:
	if incoming.is_empty():
		return existing
	if existing.is_empty():
		return {
			"min": incoming.get("min"),
			"max": incoming.get("max")
		}
	return {
		"min": Vector3(
			min(existing.get("min").x, incoming.get("min").x),
			min(existing.get("min").y, incoming.get("min").y),
			min(existing.get("min").z, incoming.get("min").z)
		),
		"max": Vector3(
			max(existing.get("max").x, incoming.get("max").x),
			max(existing.get("max").y, incoming.get("max").y),
			max(existing.get("max").z, incoming.get("max").z)
		)
	}
