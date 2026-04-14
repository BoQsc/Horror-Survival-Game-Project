@tool
extends PanelContainer

const ViewerData = preload("res://addons/world_prefab_viewer/prefab_viewer_data.gd")
const ViewerMesher = preload("res://addons/world_prefab_viewer/prefab_viewer_mesher.gd")
const OPTIONAL_WOOD_TEXTURE_PATH := "res://world_greedy_meshing/wood-block-texture.png"
const WOOD_BLOCK_ATLAS_SHADER := preload("res://world_building_system/wood_block_atlas.gdshader")
const RUNTIME_MATERIAL_CACHE_KEY := -999
const TERRAIN_DIRT_MATERIAL_CACHE_KEY := -1000
const TERRAIN_GRASS_MATERIAL_CACHE_KEY := -1001
const TERRAIN_MARGIN := 3
const SLICE_MODE_ALL := 0
const SLICE_MODE_UP_TO := 1
const SLICE_MODE_ONLY := 2
const SURFACE_OVERLAY_COLOR := Color(0.22, 0.78, 0.40, 0.18)
const RESERVATION_OVERLAY_COLOR := Color(0.27, 0.53, 0.90, 0.12)
const EXCAVATION_OVERLAY_COLOR := Color(0.85, 0.28, 0.28, 0.14)
const SELECTION_OVERLAY_COLOR := Color(1.0, 0.92, 0.28, 0.22)
const PRIMARY_SELECTION_OVERLAY_COLOR := Color(1.0, 0.68, 0.18, 0.28)
const OBJECT_SELECTION_OVERLAY_COLOR := Color(0.28, 0.86, 1.0, 0.20)
const PRIMARY_OBJECT_SELECTION_OVERLAY_COLOR := Color(0.16, 0.62, 1.0, 0.28)
const PREFAB_WATCH_INTERVAL := 0.5
const CAMERA_FLY_SPEED := 8.0
const CAMERA_FLY_FAST_MULTIPLIER := 2.5

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
var _camera_preset := "iso"
var _last_bounds_min := Vector3.ZERO
var _last_bounds_max := Vector3.ONE
var _camera_initialized := false
var _pending_camera_fit := true
var _real_object_count := 0
var _fallback_object_count := 0
var _selected_cells: Dictionary = {}
var _primary_selected_key := ""
var _selected_objects: Dictionary = {}
var _primary_selected_object_key := ""
var _watched_prefab_mtime: int = -1
var _watch_elapsed := 0.0
var _fly_keys := {
	KEY_W: false,
	KEY_A: false,
	KEY_S: false,
	KEY_D: false,
	KEY_Q: false,
	KEY_E: false,
	KEY_SHIFT: false
}

var _prefab_list: ItemList
var _rotation_option: OptionButton
var _slice_mode_option: OptionButton
var _slice_y_spin: SpinBox
var _show_terrain_toggle: CheckBox
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
	set_process(true)


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
	fit_button.pressed.connect(_fit_camera_to_last_bounds)
	toolbar.add_child(fit_button)

	var copy_selection_button := Button.new()
	copy_selection_button.text = "Copy Selected"
	copy_selection_button.pressed.connect(_copy_selected_positions)
	toolbar.add_child(copy_selection_button)

	var clear_selection_button := Button.new()
	clear_selection_button.text = "Clear Sel"
	clear_selection_button.pressed.connect(_clear_selection)
	toolbar.add_child(clear_selection_button)

	var iso_button := Button.new()
	iso_button.text = "Iso"
	iso_button.pressed.connect(func() -> void: _set_camera_preset("iso"))
	toolbar.add_child(iso_button)

	var top_button := Button.new()
	top_button.text = "Top"
	top_button.pressed.connect(func() -> void: _set_camera_preset("top"))
	toolbar.add_child(top_button)

	var front_button := Button.new()
	front_button.text = "Front"
	front_button.pressed.connect(func() -> void: _set_camera_preset("front"))
	toolbar.add_child(front_button)

	var right_button := Button.new()
	right_button.text = "Right"
	right_button.pressed.connect(func() -> void: _set_camera_preset("right"))
	toolbar.add_child(right_button)

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

	var slice_label := Label.new()
	slice_label.text = "Slice"
	toolbar.add_child(slice_label)

	_slice_mode_option = OptionButton.new()
	_slice_mode_option.add_item("All", SLICE_MODE_ALL)
	_slice_mode_option.add_item("Y <= ", SLICE_MODE_UP_TO)
	_slice_mode_option.add_item("Only Y", SLICE_MODE_ONLY)
	_slice_mode_option.item_selected.connect(_on_slice_mode_changed)
	toolbar.add_child(_slice_mode_option)

	_slice_y_spin = SpinBox.new()
	_slice_y_spin.min_value = 0
	_slice_y_spin.max_value = 0
	_slice_y_spin.step = 1
	_slice_y_spin.rounded = true
	_slice_y_spin.custom_minimum_size = Vector2(70.0, 0.0)
	_slice_y_spin.value_changed.connect(_rerender_current_prefab)
	toolbar.add_child(_slice_y_spin)

	_show_terrain_toggle = CheckBox.new()
	_show_terrain_toggle.text = "Terrain"
	_show_terrain_toggle.button_pressed = true
	_show_terrain_toggle.toggled.connect(_rerender_current_prefab)
	toolbar.add_child(_show_terrain_toggle)

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

	var legend_bar := HBoxContainer.new()
	legend_bar.add_theme_constant_override("separation", 14)
	root.add_child(legend_bar)

	var legend_label := Label.new()
	legend_label.text = "Legend"
	legend_bar.add_child(legend_label)

	legend_bar.add_child(_build_legend_item(SURFACE_OVERLAY_COLOR, "Surface"))
	legend_bar.add_child(_build_legend_item(RESERVATION_OVERLAY_COLOR, "Reservation"))
	legend_bar.add_child(_build_legend_item(EXCAVATION_OVERLAY_COLOR, "Excavation"))

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
	_info_label.selection_enabled = true
	_info_label.focus_mode = Control.FOCUS_CLICK
	_info_label.custom_minimum_size = Vector2(0.0, 140.0)
	_info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_panel.add_child(_info_label)

	_viewport_container = SubViewportContainer.new()
	_viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viewport_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_container.custom_minimum_size = Vector2(320.0, 240.0)
	_viewport_container.stretch = true
	_viewport_container.focus_mode = Control.FOCUS_ALL
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
	var previous_path := str(_current_prefab.get("path", ""))
	_current_prefab = ViewerData.load_prefab(str(entry.get("path", "")))
	if previous_path != str(_current_prefab.get("path", "")):
		_clear_selection_state()
	_pending_camera_fit = (previous_path != str(_current_prefab.get("path", ""))) or not _camera_initialized
	_watched_prefab_mtime = _get_prefab_modified_time(str(_current_prefab.get("path", "")))
	_update_slice_controls()
	_update_info()
	_render_current_prefab()


func _rerender_current_prefab(_arg = null) -> void:
	_render_current_prefab()


func _process(delta: float) -> void:
	_watch_elapsed += delta
	if _watch_elapsed >= PREFAB_WATCH_INTERVAL:
		_watch_elapsed = 0.0
		_watch_current_prefab_for_changes()
	_update_fly_camera(delta)


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
	_real_object_count = 0
	_fallback_object_count = 0
	var bounds := {
		"min": Vector3(INF, INF, INF),
		"max": Vector3(-INF, -INF, -INF)
	}
	var rotation := _rotation_option.get_selected_id()

	if _show_terrain_toggle.button_pressed:
		var terrain_bounds := _add_terrain_nodes(rotation)
		if terrain_bounds.has("min"):
			_include_bounds(bounds, terrain_bounds.get("min"), terrain_bounds.get("max"))

	_add_axes(bounds)

	var rendered_runtime := false
	if _show_runtime_mesh_toggle.button_pressed:
		rendered_runtime = _render_runtime_blocks(rotation, bounds)

	if not rendered_runtime:
		for cell in _current_prefab.get("cells", []):
			if not _should_render_cell(cell):
				continue
			var block_node := _create_block_node(cell, rotation)
			_preview_root.add_child(block_node)
			var rotated_pos: Vector3i = ViewerData.rotate_block_offset(cell.get("pos", Vector3i.ZERO), rotation)
			_include_bounds(bounds, Vector3(rotated_pos), Vector3(rotated_pos) + Vector3.ONE)

	if _show_objects_toggle.button_pressed:
		for obj in _current_prefab.get("objects", []):
			if not _should_render_object(obj):
				continue
			var object_preview := _create_object_node(obj, rotation)
			_preview_root.add_child(object_preview.get("node"))
			_include_bounds(bounds, object_preview.get("min"), object_preview.get("max"))

	if _show_overlays_toggle.button_pressed:
		var overlay_bounds := _add_overlay_nodes(rotation)
		if overlay_bounds.has("min"):
			_include_bounds(bounds, overlay_bounds.get("min"), overlay_bounds.get("max"))

	var selection_bounds := _add_selection_overlays(rotation)
	if selection_bounds.has("min"):
		_include_bounds(bounds, selection_bounds.get("min"), selection_bounds.get("max"))

	var bounds_min: Vector3 = bounds.get("min", Vector3.ZERO)
	var bounds_max: Vector3 = bounds.get("max", Vector3.ONE)
	if bounds_min.x == INF or bounds_max.x == -INF:
		bounds_min = Vector3.ZERO
		bounds_max = Vector3.ONE

	_last_bounds_min = bounds_min
	_last_bounds_max = bounds_max
	if _pending_camera_fit or not _camera_initialized:
		_frame_camera(bounds_min, bounds_max)
		_pending_camera_fit = false
		_camera_initialized = true
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
	axis.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
	var preview := _get_object_preview_data(obj, prefab_rotation)
	var info: Dictionary = preview.get("info", {})
	var base_size: Vector3 = preview.get("base_size", Vector3.ONE)
	var combined_rotation := int(preview.get("combined_rotation", 0))
	var target_corner: Vector3 = preview.get("target_corner", Vector3.ZERO)
	var center: Vector3 = preview.get("center", Vector3.ZERO)
	var rendered_size: Vector3 = preview.get("rendered_size", Vector3.ONE)
	var fractional_y := float(obj.get("fractional_y", 0.0))

	var object_node := _create_runtime_object_preview(info, target_corner, base_size, combined_rotation, fractional_y)
	if object_node:
		_real_object_count += 1
		return {
			"node": object_node,
			"min": preview.get("min", center - (rendered_size * 0.5)),
			"max": preview.get("max", center + (rendered_size * 0.5))
		}

	_fallback_object_count += 1
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = rendered_size
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _make_solid_material(info.get("color", Color(0.75, 0.75, 0.75, 1.0)), true)
	mesh_instance.position = center
	mesh_instance.rotation_degrees.y = float(combined_rotation * 90)
	return {
		"node": mesh_instance,
		"min": preview.get("min", center - (rendered_size * 0.5)),
		"max": preview.get("max", center + (rendered_size * 0.5))
	}


func _get_object_preview_data(obj: Dictionary, prefab_rotation: int) -> Dictionary:
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
	return {
		"info": info,
		"base_size": base_size,
		"combined_rotation": combined_rotation,
		"rendered_size": rendered_size,
		"target_corner": target_corner,
		"center": center,
		"min": center - (rendered_size * 0.5),
		"max": center + (rendered_size * 0.5)
	}


func _create_runtime_object_preview(info: Dictionary, target_corner: Vector3, base_size: Vector3, combined_rotation: int, fractional_y: float) -> Node3D:
	var scene_path := str(info.get("scene", ""))
	if scene_path.is_empty():
		return null
	if not ResourceLoader.exists(scene_path):
		return null

	var packed := load(scene_path) as PackedScene
	if not packed:
		return null

	var instance := packed.instantiate()
	if not instance is Node3D:
		if instance:
			instance.free()
		return null

	var preview_root := Node3D.new()
	preview_root.name = "ObjectPreview"
	var object_root := instance as Node3D
	_strip_preview_runtime_behavior(object_root)
	preview_root.add_child(object_root)

	var offset_x := base_size.x * 0.5
	var offset_z := base_size.z * 0.5
	if combined_rotation == 1 or combined_rotation == 3:
		var temp := offset_x
		offset_x = offset_z
		offset_z = temp

	preview_root.position = target_corner + Vector3(offset_x, fractional_y, offset_z)
	preview_root.rotation_degrees.y = float(combined_rotation * 90)
	return preview_root


func _strip_preview_runtime_behavior(node: Node) -> void:
	node.process_mode = Node.PROCESS_MODE_DISABLED
	node.set_process(false)
	node.set_physics_process(false)
	node.set_process_input(false)
	node.set_process_unhandled_input(false)
	node.set_process_shortcut_input(false)
	node.set_process_unhandled_key_input(false)
	if node.get_script() != null:
		node.set_script(null)
	if node is CollisionObject3D:
		var collision_object := node as CollisionObject3D
		collision_object.collision_layer = 0
		collision_object.collision_mask = 0
	for child in node.get_children():
		_strip_preview_runtime_behavior(child)


func _add_terrain_nodes(rotation: int) -> Dictionary:
	var placement: Dictionary = _current_prefab.get("placement", {})
	var grade_y := int(placement.get("grade_y", 0))
	var surface_rect := ViewerData.rotate_rect(ViewerData.get_surface_rect(_current_prefab), rotation)
	var terrain_columns := _build_terrain_column_sets(rotation, grade_y)
	var occupied_cells: Dictionary = terrain_columns.get("occupied", {})
	var surface_columns: Dictionary = terrain_columns.get("surface", {})
	var excavation_volumes: Array = []
	var min_excavation_y := grade_y
	for volume in placement.get("excavation_volumes", []):
		var rotated_volume := ViewerData.rotate_volume(volume, rotation)
		excavation_volumes.append(rotated_volume)
		min_excavation_y = min(min_excavation_y, int(rotated_volume.get("min", Vector3i.ZERO).y))

	var excavation_rect := _rect_from_volumes(excavation_volumes)
	var terrain_rect := _expand_rect(_choose_terrain_rect(surface_rect, excavation_rect), TERRAIN_MARGIN)
	if terrain_rect.is_empty():
		return {}

	var terrain_floor_y := min(0, min_excavation_y - 2)
	var terrain_top_voxel_y := grade_y - 1
	var terrain_bounds := {}
	for x in range(terrain_rect.get("min", Vector2i.ZERO).x, terrain_rect.get("max", Vector2i.ZERO).x + 1):
		for z in range(terrain_rect.get("min", Vector2i.ZERO).y, terrain_rect.get("max", Vector2i.ZERO).y + 1):
			var column_pos := Vector2i(x, z)
			var column_key := _column_key(column_pos.x, column_pos.y)

			var run_start := INF
			var top_solid_y := -INF
			for y in range(terrain_floor_y, terrain_top_voxel_y + 1):
				var cell_pos := Vector3i(x, y, z)
				var solid := (
					not _is_excavated_cell(cell_pos, excavation_volumes)
					and not occupied_cells.has(_voxel_key(cell_pos))
				)
				if solid:
					if run_start == INF:
						run_start = y
					top_solid_y = y
				elif run_start != INF:
					if _matches_slice_range(int(run_start), y - 1):
						var segment_bounds := _add_terrain_segment(x, int(run_start), y - 1, z)
						terrain_bounds = _merge_bounds(terrain_bounds, segment_bounds)
					run_start = INF
			if run_start != INF and _matches_slice_range(int(run_start), terrain_top_voxel_y):
				var last_segment_bounds := _add_terrain_segment(x, int(run_start), terrain_top_voxel_y, z)
				terrain_bounds = _merge_bounds(terrain_bounds, last_segment_bounds)

			if (
				top_solid_y == terrain_top_voxel_y
				and not surface_columns.has(column_key)
				and _matches_slice_range(terrain_top_voxel_y, terrain_top_voxel_y)
			):
				var cap_bounds := _add_terrain_cap(x, grade_y, z)
				terrain_bounds = _merge_bounds(terrain_bounds, cap_bounds)

	return terrain_bounds


func _choose_terrain_rect(surface_rect: Dictionary, excavation_rect: Dictionary) -> Dictionary:
	return _merge_rects(surface_rect, excavation_rect)


func _expand_rect(rect: Dictionary, margin: int) -> Dictionary:
	if rect.is_empty():
		return {}
	var min_corner: Vector2i = rect.get("min", Vector2i.ZERO)
	var max_corner: Vector2i = rect.get("max", Vector2i.ZERO)
	var expanded_min := Vector2i(min_corner.x - margin, min_corner.y - margin)
	var expanded_max := Vector2i(max_corner.x + margin, max_corner.y + margin)
	return {
		"min": expanded_min,
		"max": expanded_max,
		"footprint": Vector2i(expanded_max.x - expanded_min.x + 1, expanded_max.y - expanded_min.y + 1)
	}


func _build_terrain_column_sets(rotation: int, grade_y: int) -> Dictionary:
	var occupied := {}
	var surface := {}
	for cell in _current_prefab.get("cells", []):
		var rotated_pos: Vector3i = ViewerData.rotate_block_offset(cell.get("pos", Vector3i.ZERO), rotation)
		if rotated_pos.y < grade_y:
			occupied[_voxel_key(rotated_pos)] = true
		else:
			surface[_column_key(rotated_pos.x, rotated_pos.z)] = true
	return {
		"occupied": occupied,
		"surface": surface
	}


func _column_key(x: int, z: int) -> String:
	return "%d,%d" % [x, z]


func _voxel_key(pos: Vector3i) -> String:
	return "%d,%d,%d" % [pos.x, pos.y, pos.z]


func _rect_contains(rect: Dictionary, pos: Vector2i) -> bool:
	if rect.is_empty():
		return false
	var min_corner: Vector2i = rect.get("min", Vector2i.ZERO)
	var max_corner: Vector2i = rect.get("max", Vector2i.ZERO)
	return (
		pos.x >= min_corner.x
		and pos.x <= max_corner.x
		and pos.y >= min_corner.y
		and pos.y <= max_corner.y
	)


func _is_excavated_cell(pos: Vector3i, volumes: Array) -> bool:
	for volume in volumes:
		var min_corner: Vector3i = volume.get("min", Vector3i.ZERO)
		var max_corner: Vector3i = volume.get("max", Vector3i.ZERO)
		if (
			pos.x >= min_corner.x and pos.x <= max_corner.x
			and pos.y >= min_corner.y and pos.y <= max_corner.y
			and pos.z >= min_corner.z and pos.z <= max_corner.z
		):
			return true
	return false


func _add_terrain_segment(x: int, y_min: int, y_max: int, z: int) -> Dictionary:
	var size := Vector3(1.0, float(y_max - y_min + 1), 1.0)
	var center := Vector3(float(x) + 0.5, (float(y_min + y_max) + 1.0) * 0.5, float(z) + 0.5)
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	mesh_instance.material_override = _get_terrain_dirt_material()
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.position = center
	_preview_root.add_child(mesh_instance)
	return {
		"min": center - (size * 0.5),
		"max": center + (size * 0.5)
	}


func _add_terrain_cap(x: int, y: int, z: int) -> Dictionary:
	var size := Vector3(1.0, 0.04, 1.0)
	var center := Vector3(float(x) + 0.5, float(y) + (size.y * 0.5), float(z) + 0.5)
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	mesh_instance.material_override = _get_terrain_grass_material()
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.position = center
	_preview_root.add_child(mesh_instance)
	return {
		"min": center - (size * 0.5),
		"max": center + (size * 0.5)
	}


func _add_overlay_nodes(rotation: int) -> Dictionary:
	var overlay_bounds := {}
	var placement: Dictionary = _current_prefab.get("placement", {})
	var grade_y := float(placement.get("grade_y", 0))

	var surface_rect := ViewerData.rotate_rect(ViewerData.get_surface_rect(_current_prefab), rotation)
	if not surface_rect.is_empty():
		var surface_bounds := _add_rect_overlay(surface_rect, grade_y + 0.02, SURFACE_OVERLAY_COLOR)
		overlay_bounds = _merge_bounds(overlay_bounds, surface_bounds)

	var reservation_rect := ViewerData.rotate_rect(ViewerData.get_reservation_rect(_current_prefab), rotation)
	if not reservation_rect.is_empty():
		var reservation_bounds := _add_rect_overlay(reservation_rect, grade_y + 0.07, RESERVATION_OVERLAY_COLOR)
		overlay_bounds = _merge_bounds(overlay_bounds, reservation_bounds)

	for volume in placement.get("excavation_volumes", []):
		var rotated_volume := ViewerData.rotate_volume(volume, rotation)
		var volume_bounds := _add_volume_overlay(rotated_volume, EXCAVATION_OVERLAY_COLOR)
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
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.position = center
	_preview_root.add_child(mesh_instance)

	return {
		"min": center - (size * 0.5),
		"max": center + (size * 0.5)
	}


func _add_selection_overlays(rotation: int) -> Dictionary:
	if _selected_cells.is_empty() and _selected_objects.is_empty():
		return {}

	var combined_bounds := {}
	for key in _get_sorted_selected_keys():
		var cell: Dictionary = _selected_cells.get(key, {})
		if cell.is_empty() or not _should_render_cell(cell):
			continue

		var rotated_pos: Vector3i = ViewerData.rotate_block_offset(cell.get("pos", Vector3i.ZERO), rotation)
		var is_primary: bool = key == _primary_selected_key
		var size := Vector3(1.04, 1.04, 1.04)
		var overlay_color := SELECTION_OVERLAY_COLOR
		if is_primary:
			size = Vector3(1.06, 1.06, 1.06)
			overlay_color = PRIMARY_SELECTION_OVERLAY_COLOR
		var center := Vector3(rotated_pos) + Vector3(0.5, 0.5, 0.5)
		var mesh_instance := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mesh_instance.mesh = box
		mesh_instance.material_override = _make_solid_material(overlay_color, true, true)
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh_instance.position = center
		_preview_root.add_child(mesh_instance)
		combined_bounds = _merge_bounds(combined_bounds, {
			"min": center - (size * 0.5),
			"max": center + (size * 0.5)
		})

	for key in _get_sorted_selected_object_keys():
		var obj: Dictionary = _selected_objects.get(key, {})
		if obj.is_empty() or not _should_render_object(obj):
			continue
		var preview := _get_object_preview_data(obj, rotation)
		var min_corner: Vector3 = preview.get("min", Vector3.ZERO)
		var max_corner: Vector3 = preview.get("max", Vector3.ONE)
		var center := (min_corner + max_corner) * 0.5
		var size := (max_corner - min_corner) + Vector3.ONE * 0.08
		var overlay_color := OBJECT_SELECTION_OVERLAY_COLOR
		if key == _primary_selected_object_key:
			size += Vector3.ONE * 0.04
			overlay_color = PRIMARY_OBJECT_SELECTION_OVERLAY_COLOR
		var mesh_instance := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mesh_instance.mesh = box
		mesh_instance.material_override = _make_solid_material(overlay_color, true, true)
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh_instance.position = center
		_preview_root.add_child(mesh_instance)
		combined_bounds = _merge_bounds(combined_bounds, {
			"min": center - (size * 0.5),
			"max": center + (size * 0.5)
		})

	return combined_bounds


func _frame_camera(bounds_min: Vector3, bounds_max: Vector3) -> void:
	if bounds_min.x == INF or bounds_max.x == -INF:
		bounds_min = Vector3.ZERO
		bounds_max = Vector3.ONE

	_camera_initialized = true
	_last_bounds_min = bounds_min
	_last_bounds_max = bounds_max
	_camera_target = (bounds_min + bounds_max) * 0.5
	var extents := bounds_max - bounds_min
	var radius := max(max(extents.x, extents.y), extents.z)
	radius = max(radius, 4.0)

	_camera_distance = max(radius * 2.15, 3.0)
	_apply_camera_preset_angles()
	_apply_camera_transform()
	_camera.far = max(200.0, radius * 10.0)


func _on_viewport_input(event: InputEvent) -> void:
	if not _camera:
		return

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and _viewport_container:
			_viewport_container.grab_focus()
		match mouse_event.button_index:
			MOUSE_BUTTON_LEFT:
				if mouse_event.pressed:
					_select_cell_at_screen_pos(mouse_event.position, mouse_event.shift_pressed)
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
	elif event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.echo:
			return
		var keycode := key_event.keycode
		if _fly_keys.has(keycode):
			_fly_keys[keycode] = key_event.pressed
	elif event is InputEventMouseMotion:
		var motion_event := event as InputEventMouseMotion
		if _is_orbiting:
			_camera_preset = "custom"
			_camera_yaw -= motion_event.relative.x * 0.01
			_camera_pitch = clamp(_camera_pitch + (motion_event.relative.y * 0.01), deg_to_rad(-80.0), deg_to_rad(80.0))
			_apply_camera_look_from_current_position()
		elif _is_panning:
			_pan_camera(motion_event.relative)


func _fit_camera_to_last_bounds() -> void:
	_pending_camera_fit = false
	_frame_camera(_last_bounds_min, _last_bounds_max)


func _set_camera_preset(preset: String) -> void:
	_camera_preset = preset
	_apply_camera_preset_angles()
	_apply_camera_transform()


func _apply_camera_preset_angles() -> void:
	match _camera_preset:
		"top":
			_camera_yaw = PI / 4.0
			_camera_pitch = deg_to_rad(89.0)
		"front":
			_camera_yaw = PI
			_camera_pitch = 0.0
		"right":
			_camera_yaw = PI / 2.0
			_camera_pitch = 0.0
		_:
			_camera_yaw = PI / 4.0
			_camera_pitch = deg_to_rad(30.0)


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


func _update_fly_camera(delta: float) -> void:
	if not _camera or not _viewport_container or not _viewport_container.has_focus():
		return

	var move := Vector3.ZERO
	if _fly_keys.get(KEY_W, false):
		move.z += 1.0
	if _fly_keys.get(KEY_S, false):
		move.z -= 1.0
	if _fly_keys.get(KEY_A, false):
		move.x -= 1.0
	if _fly_keys.get(KEY_D, false):
		move.x += 1.0
	if _fly_keys.get(KEY_E, false):
		move.y += 1.0
	if _fly_keys.get(KEY_Q, false):
		move.y -= 1.0
	if move == Vector3.ZERO:
		return

	_camera_preset = "custom"
	var speed := CAMERA_FLY_SPEED
	if _fly_keys.get(KEY_SHIFT, false):
		speed *= CAMERA_FLY_FAST_MULTIPLIER
	var basis := _camera.global_transform.basis
	var forward := -basis.z.normalized()
	var right := basis.x.normalized()
	var up := Vector3.UP
	var world_move := (
		right * move.x +
		up * move.y +
		forward * move.z
	).normalized() * speed * delta
	_camera_target += world_move
	_apply_camera_transform()


func _apply_camera_transform() -> void:
	var offset := Vector3(
		cos(_camera_pitch) * sin(_camera_yaw),
		sin(_camera_pitch),
		cos(_camera_pitch) * cos(_camera_yaw)
	) * _camera_distance
	_camera.position = _camera_target + offset
	_camera.look_at(_camera_target, Vector3.UP)


func _apply_camera_look_from_current_position() -> void:
	if not _camera:
		return
	var camera_position := _camera.position
	var forward := _get_camera_forward()
	_camera_target = camera_position + (forward * _camera_distance)
	_apply_camera_transform()


func _get_camera_forward() -> Vector3:
	return -Vector3(
		cos(_camera_pitch) * sin(_camera_yaw),
		sin(_camera_pitch),
		cos(_camera_pitch) * cos(_camera_yaw)
	).normalized()


func _watch_current_prefab_for_changes() -> void:
	if _current_prefab.is_empty():
		return
	var path := str(_current_prefab.get("path", ""))
	if path.is_empty():
		return
	var modified_time := _get_prefab_modified_time(path)
	if modified_time < 0:
		return
	if _watched_prefab_mtime < 0:
		_watched_prefab_mtime = modified_time
		return
	if modified_time != _watched_prefab_mtime:
		_watched_prefab_mtime = modified_time
		_reload_current_prefab_from_disk()


func _reload_current_prefab_from_disk() -> void:
	if _current_prefab.is_empty():
		return
	var path := str(_current_prefab.get("path", ""))
	if path.is_empty():
		return
	var selected_positions := _get_selected_positions()
	var selected_object_keys := _get_sorted_selected_object_keys()
	var primary_pos: Variant = null
	if _selected_cells.has(_primary_selected_key):
		primary_pos = _selected_cells[_primary_selected_key].get("pos", null)
	var primary_object_key := _primary_selected_object_key
	_current_prefab = ViewerData.load_prefab(path)
	_restore_selection(selected_positions, primary_pos, selected_object_keys, primary_object_key)
	_update_slice_controls()
	_update_info()
	_render_current_prefab()


func _find_cell_by_local_pos(local_pos: Variant) -> Dictionary:
	if local_pos == null:
		return {}
	for cell in _current_prefab.get("cells", []):
		if cell.get("pos", Vector3i.ZERO) == local_pos:
			return cell
	return {}


func _get_prefab_modified_time(path: String) -> int:
	if path.is_empty() or not FileAccess.file_exists(path):
		return -1
	return int(FileAccess.get_modified_time(path))


func _select_cell_at_screen_pos(screen_pos: Vector2, additive: bool) -> void:
	if _current_prefab.is_empty() or not _camera or not _viewport_container or not _viewport:
		return

	var viewport_size := _viewport_container.size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return

	var viewport_pos := Vector2(
		screen_pos.x * (float(_viewport.size.x) / viewport_size.x),
		screen_pos.y * (float(_viewport.size.y) / viewport_size.y)
	)
	var ray_origin := _camera.project_ray_origin(viewport_pos)
	var ray_direction := _camera.project_ray_normal(viewport_pos).normalized()
	var hit := _pick_prefab_item(ray_origin, ray_direction)
	var hit_type := str(hit.get("type", ""))
	if hit_type.is_empty():
		if not additive:
			_clear_selection()
		return
	if hit_type == "object":
		_update_object_selection(hit.get("object", {}), additive)
	else:
		_update_selection(hit.get("cell", {}), additive)
	_update_info()
	_render_current_prefab()


func _pick_prefab_item(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	var rotation := _rotation_option.get_selected_id()
	var closest_t := INF
	var hit_type := ""
	var hit_cell: Dictionary = {}
	var hit_object: Dictionary = {}
	for cell in _current_prefab.get("cells", []):
		if not _should_render_cell(cell):
			continue
		var rotated_pos: Vector3i = ViewerData.rotate_block_offset(cell.get("pos", Vector3i.ZERO), rotation)
		var aabb := AABB(Vector3(rotated_pos), Vector3.ONE)
		var hit_t := _intersect_ray_aabb(ray_origin, ray_direction, aabb)
		if hit_t >= 0.0 and hit_t < closest_t:
			closest_t = hit_t
			hit_type = "block"
			hit_cell = cell

	for obj in _current_prefab.get("objects", []):
		if not _should_render_object(obj):
			continue
		var preview := _get_object_preview_data(obj, rotation)
		var aabb := AABB(preview.get("min", Vector3.ZERO), preview.get("max", Vector3.ONE) - preview.get("min", Vector3.ZERO))
		var hit_t := _intersect_ray_aabb(ray_origin, ray_direction, aabb)
		if hit_t >= 0.0 and hit_t < closest_t:
			closest_t = hit_t
			hit_type = "object"
			hit_object = obj

	return {
		"type": hit_type,
		"cell": hit_cell,
		"object": hit_object,
		"distance": closest_t
	}


func _update_selection(cell: Dictionary, additive: bool) -> void:
	if cell.is_empty():
		return
	var local_pos: Vector3i = cell.get("pos", Vector3i.ZERO)
	var key := _cell_key_from_pos(local_pos)
	if additive:
		if _selected_cells.has(key):
			_selected_cells.erase(key)
			if _primary_selected_key == key:
				_primary_selected_key = ""
				var remaining_keys := _get_sorted_selected_keys()
				if not remaining_keys.is_empty():
					_primary_selected_key = remaining_keys[remaining_keys.size() - 1]
		else:
			_selected_cells[key] = cell
			_primary_selected_key = key
		return

	_selected_cells = {key: cell}
	_primary_selected_key = key
	_selected_objects.clear()
	_primary_selected_object_key = ""


func _clear_selection() -> void:
	_clear_selection_state()
	_update_info()
	_render_current_prefab()


func _clear_selection_state() -> void:
	_selected_cells.clear()
	_primary_selected_key = ""
	_selected_objects.clear()
	_primary_selected_object_key = ""


func _restore_selection(selected_positions: Array, primary_pos: Variant, selected_object_keys: Array, primary_object_key: String) -> void:
	_clear_selection_state()
	for local_pos in selected_positions:
		var cell := _find_cell_by_local_pos(local_pos)
		if not cell.is_empty():
			var key := _cell_key_from_pos(local_pos)
			_selected_cells[key] = cell
	if primary_pos != null:
		var primary_key := _cell_key_from_pos(primary_pos)
		if _selected_cells.has(primary_key):
			_primary_selected_key = primary_key
	if _primary_selected_key.is_empty():
		var keys := _get_sorted_selected_keys()
		if not keys.is_empty():
			_primary_selected_key = keys[0]
	for object_key in selected_object_keys:
		var obj := _find_object_by_key(object_key)
		if not obj.is_empty():
			_selected_objects[object_key] = obj
	if not primary_object_key.is_empty() and _selected_objects.has(primary_object_key):
		_primary_selected_object_key = primary_object_key
	elif not _selected_objects.is_empty():
		_primary_selected_object_key = _get_sorted_selected_object_keys()[0]


func _get_selected_positions() -> Array:
	var positions: Array = []
	for key in _get_sorted_selected_keys():
		var cell: Dictionary = _selected_cells.get(key, {})
		if not cell.is_empty():
			positions.append(cell.get("pos", Vector3i.ZERO))
	return positions


func _get_sorted_selected_keys() -> Array:
	var keys: Array = _selected_cells.keys()
	keys.sort()
	return keys


func _cell_key_from_pos(local_pos: Variant) -> String:
	if local_pos == null:
		return ""
	var pos: Vector3i = local_pos
	return "%d,%d,%d" % [pos.x, pos.y, pos.z]


func _copy_selected_positions() -> void:
	if _selected_cells.is_empty() and _selected_objects.is_empty():
		return
	var lines: Array[String] = []
	for local_pos in _get_selected_positions():
		lines.append("(%d, %d, %d)" % [local_pos.x, local_pos.y, local_pos.z])
	if not _selected_objects.is_empty():
		if not lines.is_empty():
			lines.append("")
		lines.append("Objects:")
		for object_key in _get_sorted_selected_object_keys():
			var obj: Dictionary = _selected_objects.get(object_key, {})
			if obj.is_empty():
				continue
			lines.append(
				"id=%d pos=(%s, %s, %s) rot=%d" % [
					int(obj.get("object_id", 0)),
					str(obj.get("x", 0.0)),
					str(obj.get("y", 0.0)),
					str(obj.get("z", 0.0)),
					int(obj.get("rotation", 0))
				]
			)
	DisplayServer.clipboard_set("\n".join(lines))


func _update_object_selection(obj: Dictionary, additive: bool) -> void:
	if obj.is_empty():
		return
	var key := _object_key(obj)
	if additive:
		if _selected_objects.has(key):
			_selected_objects.erase(key)
			if _primary_selected_object_key == key:
				_primary_selected_object_key = ""
				var remaining_keys := _get_sorted_selected_object_keys()
				if not remaining_keys.is_empty():
					_primary_selected_object_key = remaining_keys[remaining_keys.size() - 1]
		else:
			_selected_objects[key] = obj
			_primary_selected_object_key = key
		return

	_selected_objects = {key: obj}
	_primary_selected_object_key = key
	_selected_cells.clear()
	_primary_selected_key = ""


func _get_sorted_selected_object_keys() -> Array:
	var keys: Array = _selected_objects.keys()
	keys.sort()
	return keys


func _object_key(obj: Dictionary) -> String:
	return "%d|%s|%s|%s|%d|%s" % [
		int(obj.get("object_id", 0)),
		str(obj.get("x", 0.0)),
		str(obj.get("y", 0.0)),
		str(obj.get("z", 0.0)),
		int(obj.get("rotation", 0)),
		str(obj.get("fractional_y", 0.0))
	]


func _find_object_by_key(object_key: String) -> Dictionary:
	for obj in _current_prefab.get("objects", []):
		if _object_key(obj) == object_key:
			return obj
	return {}


func _intersect_ray_aabb(ray_origin: Vector3, ray_direction: Vector3, aabb: AABB) -> float:
	var t_min := -INF
	var t_max := INF
	var box_min := aabb.position
	var box_max := aabb.position + aabb.size

	for axis in range(3):
		var origin_component := ray_origin[axis]
		var direction_component := ray_direction[axis]
		var min_component := box_min[axis]
		var max_component := box_max[axis]

		if absf(direction_component) < 0.000001:
			if origin_component < min_component or origin_component > max_component:
				return -1.0
			continue

		var inv_direction := 1.0 / direction_component
		var t1 := (min_component - origin_component) * inv_direction
		var t2 := (max_component - origin_component) * inv_direction
		if t1 > t2:
			var temp := t1
			t1 = t2
			t2 = temp

		t_min = max(t_min, t1)
		t_max = min(t_max, t2)
		if t_min > t_max:
			return -1.0

	if t_max < 0.0:
		return -1.0
	return t_min if t_min >= 0.0 else t_max


func _build_legend_item(color: Color, text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(18.0, 12.0)
	swatch.color = color
	row.add_child(swatch)

	var label := Label.new()
	label.text = text
	row.add_child(label)

	return row


func _rect_from_volumes(volumes: Array) -> Dictionary:
	if volumes.is_empty():
		return {}

	var min_corner := Vector2i(999999, 999999)
	var max_corner := Vector2i(-999999, -999999)
	for volume in volumes:
		var local_min: Vector3i = volume.get("min", Vector3i.ZERO)
		var local_max: Vector3i = volume.get("max", Vector3i.ZERO)
		min_corner.x = min(min_corner.x, local_min.x)
		min_corner.y = min(min_corner.y, local_min.z)
		max_corner.x = max(max_corner.x, local_max.x)
		max_corner.y = max(max_corner.y, local_max.z)

	return {
		"min": min_corner,
		"max": max_corner,
		"footprint": Vector2i(max_corner.x - min_corner.x + 1, max_corner.y - min_corner.y + 1)
	}


func _merge_rects(primary: Dictionary, secondary: Dictionary) -> Dictionary:
	if primary.is_empty():
		return secondary
	if secondary.is_empty():
		return primary

	var min_primary: Vector2i = primary.get("min", Vector2i.ZERO)
	var max_primary: Vector2i = primary.get("max", Vector2i.ZERO)
	var min_secondary: Vector2i = secondary.get("min", Vector2i.ZERO)
	var max_secondary: Vector2i = secondary.get("max", Vector2i.ZERO)
	var min_corner := Vector2i(min(min_primary.x, min_secondary.x), min(min_primary.y, min_secondary.y))
	var max_corner := Vector2i(max(max_primary.x, max_secondary.x), max(max_primary.y, max_secondary.y))
	return {
		"min": min_corner,
		"max": max_corner,
		"footprint": Vector2i(max_corner.x - min_corner.x + 1, max_corner.y - min_corner.y + 1)
	}


func _render_runtime_blocks(rotation: int, bounds: Dictionary) -> bool:
	if not _runtime_mesher or not _runtime_mesher.is_available():
		_runtime_error = _runtime_mesher.get_last_error() if _runtime_mesher else "Runtime preview mesher is unavailable."
		return false

	var chunk_map := {}
	var cells: Array = _current_prefab.get("cells", [])
	for cell in cells:
		if not _should_render_cell(cell):
			continue
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
	lines.append("Terrain preview: %s" % ("on" if _show_terrain_toggle and _show_terrain_toggle.button_pressed else "off"))
	lines.append("Object preview: %d real / %d fallback" % [_real_object_count, _fallback_object_count])
	lines.append("Slice: %s" % _get_slice_description())
	if not _selected_cells.is_empty():
		var primary_cell: Dictionary = _selected_cells.get(_primary_selected_key, {})
		var selected_positions := _get_selected_positions()
		lines.append("Selected blocks: %d" % selected_positions.size())
		if not primary_cell.is_empty():
			var selected_local: Vector3i = primary_cell.get("pos", Vector3i.ZERO)
			var selected_rotated: Vector3i = ViewerData.rotate_block_offset(selected_local, _rotation_option.get_selected_id())
			lines.append(
				"Primary block: local %s | preview %s | type %d | meta %d" % [
					selected_local,
					selected_rotated,
					int(primary_cell.get("type", 0)),
					int(primary_cell.get("meta", 0))
				]
			)
		lines.append("Selected local positions:")
		for index in range(min(selected_positions.size(), 16)):
			var local_pos: Vector3i = selected_positions[index]
			lines.append("- (%d, %d, %d)" % [local_pos.x, local_pos.y, local_pos.z])
		if selected_positions.size() > 16:
			lines.append("- ... %d more" % (selected_positions.size() - 16))
	else:
		lines.append("Selected blocks: none")
	if not _selected_objects.is_empty():
		lines.append("Selected objects: %d" % _selected_objects.size())
		var primary_object: Dictionary = _selected_objects.get(_primary_selected_object_key, {})
		if not primary_object.is_empty():
			var object_info := ViewerData.get_object_info(int(primary_object.get("object_id", 0)))
			lines.append(
				"Primary object: %s | id %d | pos (%s, %s, %s) | rot %d" % [
					str(object_info.get("name", "Object")),
					int(primary_object.get("object_id", 0)),
					str(primary_object.get("x", 0.0)),
					str(primary_object.get("y", 0.0)),
					str(primary_object.get("z", 0.0)),
					int(primary_object.get("rotation", 0))
				]
			)
	else:
		lines.append("Selected objects: none")
	lines.append("Controls: LMB select, Shift+LMB toggle, RMB look, Shift+RMB/MMB pan, Wheel zoom, WASD fly, Q/E vertical, Shift fast")

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

	match block_type:
		1:
			var wood_material := _get_runtime_block_material()
			_material_cache[block_type] = wood_material
			return wood_material
		2:
			var material := StandardMaterial3D.new()
			material.roughness = 1.0
			material.albedo_color = Color(0.58, 0.61, 0.64, 1.0)
			_material_cache[block_type] = material
			return material
		3:
			var material := StandardMaterial3D.new()
			material.roughness = 1.0
			material.albedo_color = Color(0.86, 0.62, 0.27, 1.0)
			_material_cache[block_type] = material
			return material
		4:
			var material := StandardMaterial3D.new()
			material.roughness = 1.0
			material.albedo_color = Color(0.93, 0.78, 0.33, 1.0)
			_material_cache[block_type] = material
			return material
		_:
			var material := StandardMaterial3D.new()
			material.roughness = 1.0
			material.albedo_color = Color(0.90, 0.32, 0.78, 1.0)
			_material_cache[block_type] = material
			return material


func _get_runtime_block_material() -> Material:
	if _material_cache.has(RUNTIME_MATERIAL_CACHE_KEY):
		return _material_cache[RUNTIME_MATERIAL_CACHE_KEY]

	var material: Material
	if ResourceLoader.exists(OPTIONAL_WOOD_TEXTURE_PATH):
		var shader_material := ShaderMaterial.new()
		shader_material.shader = WOOD_BLOCK_ATLAS_SHADER
		shader_material.set_shader_parameter("atlas_texture", _get_repeating_texture(load(OPTIONAL_WOOD_TEXTURE_PATH)))
		material = shader_material
	else:
		var fallback_material := StandardMaterial3D.new()
		fallback_material.albedo_color = Color(0.69, 0.53, 0.34, 1.0)
		fallback_material.roughness = 1.0
		material = fallback_material

	_material_cache[RUNTIME_MATERIAL_CACHE_KEY] = material
	return material

func _get_repeating_texture(texture: Texture2D) -> Texture2D:
	if not texture:
		return texture
	var tex: Texture2D = texture
	if tex.resource_path != "":
		var img := Image.load_from_file(tex.resource_path)
		if img:
			var img_tex := ImageTexture.create_from_image(img)
			if img_tex and "repeat" in img_tex:
				img_tex.repeat = true
			return img_tex
	if tex and "repeat" in tex:
		tex.repeat = true
	return tex



func _get_terrain_dirt_material() -> Material:
	if _material_cache.has(TERRAIN_DIRT_MATERIAL_CACHE_KEY):
		return _material_cache[TERRAIN_DIRT_MATERIAL_CACHE_KEY]

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.38, 0.32, 0.24, 1.0)
	material.roughness = 1.0
	_material_cache[TERRAIN_DIRT_MATERIAL_CACHE_KEY] = material
	return material


func _get_terrain_grass_material() -> Material:
	if _material_cache.has(TERRAIN_GRASS_MATERIAL_CACHE_KEY):
		return _material_cache[TERRAIN_GRASS_MATERIAL_CACHE_KEY]

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.32, 0.60, 0.25, 1.0)
	material.roughness = 1.0
	_material_cache[TERRAIN_GRASS_MATERIAL_CACHE_KEY] = material
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


func _on_slice_mode_changed(_index: int) -> void:
	if _slice_y_spin:
		_slice_y_spin.editable = _slice_mode_option.get_selected_id() != SLICE_MODE_ALL
	_render_current_prefab()


func _update_slice_controls() -> void:
	if not _slice_y_spin:
		return
	var actual_size: Vector3i = _current_prefab.get("actual_size", Vector3i.ONE)
	_slice_y_spin.max_value = max(0, actual_size.y - 1)
	if _slice_y_spin.value > _slice_y_spin.max_value:
		_slice_y_spin.value = _slice_y_spin.max_value
	_slice_y_spin.editable = _slice_mode_option.get_selected_id() != SLICE_MODE_ALL


func _should_render_cell(cell: Dictionary) -> bool:
	var pos: Vector3i = cell.get("pos", Vector3i.ZERO)
	return _matches_slice_range(pos.y, pos.y)


func _should_render_object(obj: Dictionary) -> bool:
	var object_id := int(obj.get("object_id", 0))
	var info := ViewerData.get_object_info(object_id)
	var base_size: Vector3 = info.get("size", Vector3.ONE)
	var min_y: int = int(floor(float(obj.get("y", 0.0))))
	var max_y: int = min_y + maxi(1, int(ceil(base_size.y))) - 1
	return _matches_slice_range(min_y, max_y)


func _matches_slice_range(min_y: int, max_y: int) -> bool:
	if not _slice_mode_option:
		return true
	var mode := _slice_mode_option.get_selected_id()
	if mode == SLICE_MODE_ALL:
		return true
	var slice_y: int = int(round(_slice_y_spin.value)) if _slice_y_spin else 0
	if mode == SLICE_MODE_UP_TO:
		return min_y <= slice_y
	return slice_y >= min_y and slice_y <= max_y


func _get_slice_description() -> String:
	if not _slice_mode_option:
		return "All"
	var mode := _slice_mode_option.get_selected_id()
	if mode == SLICE_MODE_UP_TO:
		return "Y <= %d" % int(round(_slice_y_spin.value))
	if mode == SLICE_MODE_ONLY:
		return "Only Y = %d" % int(round(_slice_y_spin.value))
	return "All"
