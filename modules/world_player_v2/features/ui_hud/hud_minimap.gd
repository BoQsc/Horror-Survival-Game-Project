extends Control
class_name HUDMinimap
## HUD Minimap — shows player position on the world map
## Only visible in world map mode. Press M for full map view.

const MINIMAP_SIZE: int = 180  # Pixels on screen
const MINIMAP_RADIUS: int = 120  # World units shown around player
const FULLMAP_SIZE: int = 600  # Full map overlay size on screen

var _texture_rect: TextureRect
var _player_arrow: Polygon2D
var _border: Panel
var _coord_label: Label
var _minimap_image: Image  # Live map from PNG — updated in real-time for terrain/building changes
var _minimap_dirty: bool = false  # Set when pixels change; texture re-uploaded once per frame
var _minimap_texture: ImageTexture # VRAM texture representing the full map
var _minimap_atlas: AtlasTexture # GPU region for minimap UI
var _fullmap_atlas: AtlasTexture # GPU region for full map UI
var _terrain_manager: Node = null
var _building_manager: Node = null
var _vehicle_manager: Node = null
var _player: Node = null
var _player_interaction: Node = null
var _focus_target_override: Node3D = null

# Full map overlay
var _fullmap_panel: Panel = null
var _fullmap_texture: TextureRect = null
var _fullmap_arrow: Polygon2D = null
var _fullmap_coord: Label = null
var _fullmap_hint: Label = null
var _fullmap_open: bool = false
var _fullmap_zoom: float = 1.0  # 1.0 = full map, higher = zoomed in
const FULLMAP_ZOOM_MIN: float = 1.0
const FULLMAP_ZOOM_MAX: float = 8.0
const FULLMAP_ZOOM_STEP: float = 0.5

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false  # Hidden until world map is active
	process_mode = Node.PROCESS_MODE_ALWAYS  # Keep updating while the player tree is disabled in a vehicle
	add_to_group("hud_minimap")
	
	# Create border panel
	_border = Panel.new()
	_border.custom_minimum_size = Vector2(MINIMAP_SIZE + 4, MINIMAP_SIZE + 4)
	_border.size = Vector2(MINIMAP_SIZE + 4, MINIMAP_SIZE + 4)
	_border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.border_color = Color(0.6, 0.6, 0.6, 0.8)
	style.set_border_width_all(2)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	_border.add_theme_stylebox_override("panel", style)
	add_child(_border)
	
	# Create texture rect for map
	_texture_rect = TextureRect.new()
	_texture_rect.position = Vector2(2, 2)
	_texture_rect.size = Vector2(MINIMAP_SIZE, MINIMAP_SIZE)
	_texture_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_border.add_child(_texture_rect)
	
	# Create player arrow (centered, rotatable)
	_player_arrow = Polygon2D.new()
	_player_arrow.polygon = PackedVector2Array([
		Vector2(0, -7),   # Tip (forward)
		Vector2(-5, 5),   # Bottom left
		Vector2(0, 2),    # Notch
		Vector2(5, 5)     # Bottom right
	])
	_player_arrow.color = Color(1, 0.15, 0.15, 1.0)  # Red
	_player_arrow.position = Vector2(MINIMAP_SIZE / 2 + 2, MINIMAP_SIZE / 2 + 2)
	_border.add_child(_player_arrow)
	
	# Create coordinate label below minimap
	_coord_label = Label.new()
	_coord_label.position = Vector2(0, MINIMAP_SIZE + 6)
	_coord_label.size = Vector2(MINIMAP_SIZE + 4, 20)
	_coord_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_coord_label.add_theme_font_size_override("font_size", 11)
	_coord_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 0.9))
	_coord_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_border.add_child(_coord_label)
	
	# Create full map overlay (hidden by default)
	_create_fullmap_overlay()
	
	# Deferred setup
	call_deferred("_deferred_init")

func _deferred_init() -> void:
	_terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	_building_manager = get_tree().get_first_node_in_group("building_manager")
	_vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	_player = get_tree().get_first_node_in_group("player")
	if _player:
		_player_interaction = _player.get_node_or_null("Components/Interaction")
	_connect_vehicle_signals()
	_connect_player_signals()
	
	if _terrain_manager and "world_map_active" in _terrain_manager and _terrain_manager.world_map_active:
		_build_minimap_image()
		visible = true
		# World map mode is baked-only: keep the HUD image immutable so runtime
		# placement cannot create double marks or drift from the baked PNG.
		if _building_manager:
			_building_manager.world_map_mode = true
		# Connect to terrain modification signal for real-time map updates
		if _terrain_manager.has_signal("chunk_modified"):
			_terrain_manager.chunk_modified.connect(_on_terrain_modified)


func _connect_vehicle_signals() -> void:
	if not _vehicle_manager or not is_instance_valid(_vehicle_manager):
		_vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	if not _vehicle_manager:
		return
	if _vehicle_manager.has_signal("player_entered_vehicle") and not _vehicle_manager.player_entered_vehicle.is_connected(_on_player_entered_vehicle):
		_vehicle_manager.player_entered_vehicle.connect(_on_player_entered_vehicle)
	if _vehicle_manager.has_signal("player_exited_vehicle") and not _vehicle_manager.player_exited_vehicle.is_connected(_on_player_exited_vehicle):
		_vehicle_manager.player_exited_vehicle.connect(_on_player_exited_vehicle)


func _connect_player_signals() -> void:
	if not has_node("/root/PlayerSignals"):
		return
	if not PlayerSignals.interaction_performed.is_connected(_on_player_interaction_performed):
		PlayerSignals.interaction_performed.connect(_on_player_interaction_performed)


func _refresh_player_context() -> void:
	if not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	if _player and not is_instance_valid(_player_interaction):
		_player_interaction = _player.get_node_or_null("Components/Interaction")
	if not is_instance_valid(_vehicle_manager):
		_vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")


func _get_fallback_focus_target() -> Node3D:
	if _player_interaction and _player_interaction.has_method("get_map_focus_target"):
		var interaction_focus = _player_interaction.call("get_map_focus_target")
		if interaction_focus is Node3D and is_instance_valid(interaction_focus):
			return interaction_focus
	if _terrain_manager:
		var active_viewer = _terrain_manager.get("viewer")
		if active_viewer is Node3D and is_instance_valid(active_viewer):
			return active_viewer
	if _vehicle_manager:
		var active_vehicle = _vehicle_manager.get("current_player_vehicle")
		if active_vehicle is Node3D and is_instance_valid(active_vehicle):
			return active_vehicle
	if is_instance_valid(_player):
		return _player
	return null


func _get_focus_target() -> Node3D:
	if is_instance_valid(_focus_target_override):
		return _focus_target_override
	return _get_fallback_focus_target()


func _on_player_entered_vehicle(vehicle: Node3D) -> void:
	_focus_target_override = vehicle


func _on_player_exited_vehicle(_vehicle: Node3D) -> void:
	call_deferred("_sync_focus_after_vehicle_exit")


func _sync_focus_after_vehicle_exit() -> void:
	_focus_target_override = null


func _on_player_interaction_performed(target: Node, action: String) -> void:
	if action == "enter_vehicle" and target is Node3D:
		_focus_target_override = target
	elif action == "exit_vehicle":
		call_deferred("_sync_focus_after_vehicle_exit")

func _create_fullmap_overlay() -> void:
	# Dark background panel
	_fullmap_panel = Panel.new()
	_fullmap_panel.name = "FullMapOverlay"
	_fullmap_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fullmap_panel.visible = false
	
	var bg_style = StyleBoxFlat.new()
	bg_style.bg_color = Color(0, 0, 0, 0.85)
	bg_style.border_color = Color(0.5, 0.5, 0.5, 0.8)
	bg_style.set_border_width_all(2)
	bg_style.corner_radius_top_left = 6
	bg_style.corner_radius_top_right = 6
	bg_style.corner_radius_bottom_left = 6
	bg_style.corner_radius_bottom_right = 6
	_fullmap_panel.add_theme_stylebox_override("panel", bg_style)
	add_child(_fullmap_panel)
	
	# Map texture
	_fullmap_texture = TextureRect.new()
	_fullmap_texture.position = Vector2(4, 4)
	_fullmap_texture.size = Vector2(FULLMAP_SIZE, FULLMAP_SIZE)
	_fullmap_texture.stretch_mode = TextureRect.STRETCH_SCALE
	_fullmap_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fullmap_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fullmap_panel.add_child(_fullmap_texture)
	
	# Player arrow on full map
	_fullmap_arrow = Polygon2D.new()
	_fullmap_arrow.polygon = PackedVector2Array([
		Vector2(0, -10),
		Vector2(-7, 7),
		Vector2(0, 3),
		Vector2(7, 7)
	])
	_fullmap_arrow.color = Color(1, 0.15, 0.15, 1.0)
	_fullmap_panel.add_child(_fullmap_arrow)
	
	# Coordinate label
	_fullmap_coord = Label.new()
	_fullmap_coord.position = Vector2(4, FULLMAP_SIZE + 8)
	_fullmap_coord.size = Vector2(FULLMAP_SIZE, 20)
	_fullmap_coord.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fullmap_coord.add_theme_font_size_override("font_size", 13)
	_fullmap_coord.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 1))
	_fullmap_coord.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fullmap_panel.add_child(_fullmap_coord)
	
	# Hint label
	_fullmap_hint = Label.new()
	_fullmap_hint.position = Vector2(4, FULLMAP_SIZE + 28)
	_fullmap_hint.size = Vector2(FULLMAP_SIZE, 20)
	_fullmap_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fullmap_hint.text = "Press M or Esc to close"
	_fullmap_hint.add_theme_font_size_override("font_size", 11)
	_fullmap_hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 0.8))
	_fullmap_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fullmap_panel.add_child(_fullmap_hint)

func _show_fullmap() -> void:
	if not _minimap_image:
		return
	_fullmap_open = true
	_fullmap_zoom = 1.0  # Reset zoom on open
	
	# Position centered on screen
	var vp_size = get_viewport().get_visible_rect().size
	var panel_w = FULLMAP_SIZE + 8
	var panel_h = FULLMAP_SIZE + 56
	_fullmap_panel.position = Vector2((vp_size.x - panel_w) / 2, (vp_size.y - panel_h) / 2)
	_fullmap_panel.size = Vector2(panel_w, panel_h)
	
	_fullmap_panel.visible = true
	_border.visible = false  # Hide minimap while full map is open
	_update_fullmap_hint()

func _hide_fullmap() -> void:
	_fullmap_open = false
	_fullmap_panel.visible = false
	_border.visible = true

func _update_fullmap_hint() -> void:
	if _fullmap_zoom <= 1.0:
		_fullmap_hint.text = "Scroll to zoom • Press M or Esc to close"
	else:
		_fullmap_hint.text = "Zoom: %.0fx • Scroll to zoom • M / Esc to close" % _fullmap_zoom

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M:
			if _fullmap_open:
				_hide_fullmap()
			else:
				_show_fullmap()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and _fullmap_open:
			_hide_fullmap()
			get_viewport().set_input_as_handled()
	# Scroll wheel zoom on full map
	if _fullmap_open and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_fullmap_zoom = min(_fullmap_zoom + FULLMAP_ZOOM_STEP, FULLMAP_ZOOM_MAX)
			_update_fullmap_hint()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_fullmap_zoom = max(_fullmap_zoom - FULLMAP_ZOOM_STEP, FULLMAP_ZOOM_MIN)
			_update_fullmap_hint()
			get_viewport().set_input_as_handled()

func _build_minimap_image() -> void:
	# Build FROZEN map once (terrain + roads + water + buildings from PNG).
	# Never modified at runtime — generator is the single source of truth.
	if not _terrain_manager or not "world_definition_path" in _terrain_manager:
		return
	
	var path = _terrain_manager.world_definition_path
	if path == "":
		return
	
	var WorldMapGen = load("res://world_editor/world_map_generator.gd")
	var loaded = WorldMapGen.load_world(path)
	
	if not loaded.has("heightmap"):
		return
	
	var hmap: Image = loaded.heightmap
	var rmap: Image = loaded.get("roads", null)
	var wmap: Image = loaded.get("water", null)
	
	var b_data: PackedByteArray
	if _terrain_manager and "gpu_biome_map" in _terrain_manager and _terrain_manager.gpu_biome_map.size() > 0:
		b_data = _terrain_manager.gpu_biome_map
	elif loaded.has("biomes"):
		b_data = loaded.biomes.get_data()
	else:
		return
	
	# Load building footprints from PNG
	var bldg_map: Image = loaded.get("building_map", null)
	var bldg_data: PackedByteArray = bldg_map.get_data() if bldg_map else PackedByteArray()
	
	var w = hmap.get_width()
	var h = hmap.get_height()
	
	var h_data = hmap.get_data()
	var r_data = rmap.get_data() if rmap else PackedByteArray()
	var w_data = wmap.get_data() if wmap else PackedByteArray()
	
	var map_pixels = PackedByteArray()
	map_pixels.resize(w * h * 3)
	
	for i in range(w * h):
		var height_val = float(h_data[i]) / 255.0
		var shade = 0.5 + height_val * 0.5
		var biome = b_data[i] if i < b_data.size() else 0
		
		var r: int = 80; var g: int = 160; var b: int = 60
		if biome == 3: r = 194; g = 178; b = 128
		elif biome == 5: r = 230; g = 230; b = 240
		elif biome == 4: r = 140; g = 130; b = 115
		
		if r_data.size() > 0:
			var ri = i * 2
			if ri < r_data.size() and r_data[ri] > 128:
				r = 64; g = 64; b = 77
		
		if w_data.size() > 0 and i < w_data.size() and w_data[i] > 128:
			r = 40; g = 80; b = 160
		
		# Building overlay
		if bldg_data.size() > 0 and i < bldg_data.size() and bldg_data[i] > 128:
			r = 220; g = 80; b = 40
		
		var pi = i * 3
		map_pixels[pi] = int(clampf(r * shade, 0, 255))
		map_pixels[pi + 1] = int(clampf(g * shade, 0, 255))
		map_pixels[pi + 2] = int(clampf(b * shade, 0, 255))
	
	_minimap_image = Image.create_from_data(w, h, false, Image.FORMAT_RGB8, map_pixels)
	_minimap_texture = ImageTexture.create_from_image(_minimap_image)
	
	if not _minimap_atlas:
		_minimap_atlas = AtlasTexture.new()
		_texture_rect.texture = _minimap_atlas
	_minimap_atlas.atlas = _minimap_texture
	
	if not _fullmap_atlas:
		_fullmap_atlas = AtlasTexture.new()
		_fullmap_texture.texture = _fullmap_atlas
	_fullmap_atlas.atlas = _minimap_texture
	
	print("[Minimap] Built %dx%d live map (real-time updates enabled)" % [w, h])

## Mark the minimap as needing a GPU texture re-upload (called by building_manager or internally)
func mark_dirty() -> void:
	_minimap_dirty = true

## Called when terrain is modified (dig/build) — update the affected pixel on the minimap
func _on_terrain_modified(coord: Vector3i, _chunk_node: Node3D) -> void:
	if not _minimap_image or not _terrain_manager:
		return
	var map_half = _terrain_manager.world_map_half
	var map_size = _terrain_manager.world_map_size
	var stride = 31  # CHUNK_STRIDE
	# Update all pixels in the modified chunk's XZ footprint
	var base_x = coord.x * stride
	var base_z = coord.z * stride
	for lx in range(0, stride, 4):  # Sample every 4th pixel for performance
		for lz in range(0, stride, 4):
			var wx = float(base_x + lx)
			var wz = float(base_z + lz)
			var px = int(wx + map_half)
			var pz = int(wz + map_half)
			if px < 0 or px >= int(map_size) or pz < 0 or pz >= int(map_size):
				continue
			# Get current terrain height to compute shade
			var h = _terrain_manager.get_terrain_height(wx, wz)
			if h <= -500.0:
				continue
			var max_h = _terrain_manager.terrain_height * 2.5
			var shade = 0.5 + clampf(h / max_h, 0.0, 1.0) * 0.5
			# Use grass color as default for modified terrain
			var r = clampf(80.0 * shade / 255.0, 0.0, 1.0)
			var g = clampf(160.0 * shade / 255.0, 0.0, 1.0)
			var b = clampf(60.0 * shade / 255.0, 0.0, 1.0)
			_minimap_image.set_pixel(px, pz, Color(r, g, b, 1.0))
	_minimap_dirty = true

func _process(_delta: float) -> void:
	# Batch texture re-upload if any pixels were modified this frame
	if _minimap_dirty and _minimap_image and _minimap_texture:
		_minimap_texture.update(_minimap_image)
		_minimap_dirty = false

	_refresh_player_context()
	if not _vehicle_manager or not is_instance_valid(_vehicle_manager):
		_connect_vehicle_signals()
	_connect_player_signals()

	if not _minimap_image:
		return
	
	var focus_target := _get_focus_target()
	if not focus_target:
		return
	
	if not _terrain_manager or not "world_map_active" in _terrain_manager:
		return
	if not _terrain_manager.world_map_active:
		visible = false
		return
	
	# Hide behind ESC menu
	var game_menu = get_parent().get_node_or_null("GameMenu") if get_parent() else null
	if game_menu and game_menu.visible:
		visible = false
		return
	
	visible = true
	
	var player_pos = focus_target.global_position
	var map_half = _terrain_manager.world_map_half
	var map_size = _terrain_manager.world_map_size
	
	# Convert player world pos to pixel coords
	var px = player_pos.x + map_half
	var pz = player_pos.z + map_half
	
	# Player/vehicle facing direction.
	# VehicleBody3D uses MODEL_FRONT (+Z); on-foot actors typically follow camera-style (-Z).
	var forward = _get_focus_forward_vector(focus_target)
	var angle = atan2(forward.x, -forward.z)
	
	# Update full map overlay if open
	if _fullmap_open:
		var img_w = _minimap_image.get_width()
		var img_h = _minimap_image.get_height()
		
		# Compute visible region based on zoom (centered on player)
		var view_size = int(float(img_w) / _fullmap_zoom)
		var cx = int(px) - view_size / 2
		var cz = int(pz) - view_size / 2
		cx = clampi(cx, 0, img_w - view_size)
		cz = clampi(cz, 0, img_h - view_size)
		
		_fullmap_atlas.region = Rect2(cx, cz, view_size, view_size)
		
		# Player arrow position relative to crop
		var scale_fm = float(FULLMAP_SIZE) / float(view_size)
		_fullmap_arrow.position = Vector2((px - float(cx)) * scale_fm + 4, (pz - float(cz)) * scale_fm + 4)
		_fullmap_arrow.rotation = angle
		_fullmap_coord.text = "%d, %d" % [int(player_pos.x), int(player_pos.z)]
		return  # Skip minimap update while full map is open
	
	# Crop region around player
	var crop_size = MINIMAP_RADIUS * 2
	var x0 = int(px - MINIMAP_RADIUS)
	var z0 = int(pz - MINIMAP_RADIUS)
	
	var img_w = _minimap_image.get_width()
	var img_h = _minimap_image.get_height()
	
	# Clamp to image bounds
	x0 = clampi(x0, 0, img_w - crop_size)
	z0 = clampi(z0, 0, img_h - crop_size)
	
	# Update atlas UV coordinates (GPU handles stretching via parent TextureRect)
	if _minimap_atlas.region != Rect2(x0, z0, crop_size, crop_size):
		_minimap_atlas.region = Rect2(x0, z0, crop_size, crop_size)
	
	# Update arrow position dynamically to handle world map borders
	var scale_factor = float(MINIMAP_SIZE) / float(crop_size)
	var arrow_x = (px - float(x0)) * scale_factor + 2.0  # +2 accounts for texture rect margin
	var arrow_y = (pz - float(z0)) * scale_factor + 2.0
	_player_arrow.position = Vector2(arrow_x, arrow_y)
	
	# Rotate arrow to match player facing direction
	_player_arrow.rotation = angle
	
	# Update coordinate label
	_coord_label.text = "%d, %d" % [int(player_pos.x), int(player_pos.z)]


func _get_focus_forward_vector(target: Node3D) -> Vector3:
	if target is VehicleBody3D:
		return target.global_transform.basis.z
	return -target.global_transform.basis.z
