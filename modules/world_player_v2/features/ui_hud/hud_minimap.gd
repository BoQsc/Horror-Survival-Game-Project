extends Control
class_name HUDMinimap
## HUD Minimap — shows player position on the world map
## Only visible in world map mode

const MINIMAP_SIZE: int = 180  # Pixels on screen
const MINIMAP_RADIUS: int = 120  # World units shown around player

var _texture_rect: TextureRect
var _player_arrow: Polygon2D
var _border: Panel
var _coord_label: Label
var _minimap_image: Image  # Cached full-map preview
var _terrain_manager: Node = null
var _player: Node = null

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
	
	# Deferred setup
	call_deferred("_deferred_init")

func _deferred_init() -> void:
	_terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	_player = get_tree().get_first_node_in_group("player")
	
	if _terrain_manager and "world_map_active" in _terrain_manager and _terrain_manager.world_map_active:
		_build_minimap_image()
		visible = true

func _build_minimap_image() -> void:
	# Load world map images to build a colored minimap
	if not _terrain_manager or not "world_definition_path" in _terrain_manager:
		return
	
	var path = _terrain_manager.world_definition_path
	if path == "":
		return
	
	var WorldMapGen = load("res://world_editor/world_map_generator.gd")
	var loaded = WorldMapGen.load_world(path)
	
	if not loaded.has("heightmap") or not loaded.has("biomes"):
		return
	
	var hmap: Image = loaded.heightmap
	var bmap: Image = loaded.biomes
	var rmap: Image = loaded.get("roads", null)
	var wmap: Image = loaded.get("water", null)
	
	var w = hmap.get_width()
	var h = hmap.get_height()
	
	var h_data = hmap.get_data()
	var b_data = bmap.get_data()
	var r_data = rmap.get_data() if rmap else PackedByteArray()
	var w_data = wmap.get_data() if wmap else PackedByteArray()
	
	# Build RGB image
	var rgb_bytes = PackedByteArray()
	rgb_bytes.resize(w * h * 3)
	
	for i in range(w * h):
		var height_val = float(h_data[i]) / 255.0
		var shade = 0.5 + height_val * 0.5
		var biome = b_data[i]
		
		# Biome colors
		var r: int = 80; var g: int = 160; var b: int = 60  # Grass default
		if biome == 3: r = 194; g = 178; b = 128  # Sand
		elif biome == 5: r = 230; g = 230; b = 240  # Snow
		elif biome == 4: r = 140; g = 130; b = 115  # Gravel
		elif biome == 6: r = 64; g = 64; b = 77  # Road
		
		# Road overlay
		if r_data.size() > 0:
			var ri = i * 2
			if ri < r_data.size() and r_data[ri] > 128:
				r = 64; g = 64; b = 77
		
		# Water overlay
		if w_data.size() > 0 and i < w_data.size() and w_data[i] > 128:
			r = 40; g = 80; b = 160
		
		var pi = i * 3
		rgb_bytes[pi] = int(clampf(r * shade, 0, 255))
		rgb_bytes[pi + 1] = int(clampf(g * shade, 0, 255))
		rgb_bytes[pi + 2] = int(clampf(b * shade, 0, 255))
	
	_minimap_image = Image.create_from_data(w, h, false, Image.FORMAT_RGB8, rgb_bytes)
	print("[Minimap] Built %dx%d minimap image" % [w, h])

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
	
	# Crop region around player
	var crop_size = MINIMAP_RADIUS * 2
	var x0 = int(px - MINIMAP_RADIUS)
	var z0 = int(pz - MINIMAP_RADIUS)
	
	# Clamp to image bounds
	x0 = clampi(x0, 0, int(map_size) - crop_size)
	z0 = clampi(z0, 0, int(map_size) - crop_size)
	
	# Extract sub-region
	var cropped = _minimap_image.get_region(Rect2i(x0, z0, crop_size, crop_size))
	cropped.resize(MINIMAP_SIZE, MINIMAP_SIZE, Image.INTERPOLATE_NEAREST)
	
	_texture_rect.texture = ImageTexture.create_from_image(cropped)
	
	# Rotate arrow to match player facing direction
	var forward = -_player.global_transform.basis.z
	var angle = atan2(forward.x, -forward.z)  # North (-Z) is 0 rad (UP)
	_player_arrow.rotation = angle
	
	# Update coordinate label
	_coord_label.text = "%d, %d" % [int(player_pos.x), int(player_pos.z)]
