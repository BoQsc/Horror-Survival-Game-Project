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
var _minimap_image: Image  # Base map with buildings baked in (updated in-place on changes)
var _terrain_manager: Node = null
var _building_manager: Node = null
var _player: Node = null

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
	_player = get_tree().get_first_node_in_group("player")
	
	if _terrain_manager and "world_map_active" in _terrain_manager and _terrain_manager.world_map_active:
		_build_minimap_image()
		visible = true
		# Give building_manager a reference so it can update pixels directly
		if _building_manager and _minimap_image:
			_building_manager.minimap_image = _minimap_image

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
	# Build base map ONCE (terrain + roads + water). Buildings added at runtime only.
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
		
		var pi = i * 3
		map_pixels[pi] = int(clampf(r * shade, 0, 255))
		map_pixels[pi + 1] = int(clampf(g * shade, 0, 255))
		map_pixels[pi + 2] = int(clampf(b * shade, 0, 255))
	
	_minimap_image = Image.create_from_data(w, h, false, Image.FORMAT_RGB8, map_pixels)
	print("[Minimap] Built %dx%d base map (buildings added at runtime)" % [w, h])

func _process(_delta: float) -> void:
	if not _minimap_image or not _player:
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
	
	var player_pos = _player.global_position
	var map_half = _terrain_manager.world_map_half
	var map_size = _terrain_manager.world_map_size
	
	# Convert player world pos to pixel coords
	var px = player_pos.x + map_half
	var pz = player_pos.z + map_half
	
	# Player facing direction
	var forward = -_player.global_transform.basis.z
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
		
		var cropped = _minimap_image.get_region(Rect2i(cx, cz, view_size, view_size))
		cropped.resize(FULLMAP_SIZE, FULLMAP_SIZE, Image.INTERPOLATE_BILINEAR)
		_fullmap_texture.texture = ImageTexture.create_from_image(cropped)
		
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
	
	# Clamp to image bounds
	x0 = clampi(x0, 0, int(map_size) - crop_size)
	z0 = clampi(z0, 0, int(map_size) - crop_size)
	
	# Extract sub-region — no building processing, all baked into _minimap_image
	var cropped = _minimap_image.get_region(Rect2i(x0, z0, crop_size, crop_size))
	cropped.resize(MINIMAP_SIZE, MINIMAP_SIZE, Image.INTERPOLATE_NEAREST)
	_texture_rect.texture = ImageTexture.create_from_image(cropped)
	
	# Update arrow position dynamically to handle world map borders
	var scale_factor = float(MINIMAP_SIZE) / float(crop_size)
	var arrow_x = (px - float(x0)) * scale_factor + 2.0  # +2 accounts for texture rect margin
	var arrow_y = (pz - float(z0)) * scale_factor + 2.0
	_player_arrow.position = Vector2(arrow_x, arrow_y)
	
	# Rotate arrow to match player facing direction
	_player_arrow.rotation = angle
	
	# Update coordinate label
	_coord_label.text = "%d, %d" % [int(player_pos.x), int(player_pos.z)]
