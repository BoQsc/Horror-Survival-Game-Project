extends Control
class_name WorldEditorUI
## World Editor - Generate, preview, paint, and save world definitions
## Acts as the "New Game" flow: generate → tweak → save → play

const WorldMapGen = preload("res://world_editor/world_map_generator.gd")
const SAVE_BASE = "user://worlds/"

# UI References
@onready var canvas: TextureRect = $HSplit/CanvasPanel/Canvas
@onready var progress_bar: ProgressBar = $TopBar/ProgressBar
@onready var progress_label: Label = $TopBar/ProgressLabel
@onready var seed_input: SpinBox = $HSplit/SettingsPanel/VBox/SeedRow/SeedInput
@onready var height_input: SpinBox = $HSplit/SettingsPanel/VBox/HeightRow/HeightInput
@onready var preset_option: OptionButton = $HSplit/SettingsPanel/VBox/PresetRow/PresetOption
@onready var freq_input: SpinBox = $HSplit/SettingsPanel/VBox/FreqRow/FreqInput
@onready var road_spacing_input: SpinBox = $HSplit/SettingsPanel/VBox/RoadSpacingRow/RoadSpacingInput
@onready var world_name_input: LineEdit = $HSplit/SettingsPanel/VBox/NameRow/NameInput
@onready var generate_btn: Button = $TopBar/GenerateBtn
@onready var save_btn: Button = $TopBar/SaveBtn
@onready var load_btn: Button = $TopBar/LoadBtn
@onready var play_btn: Button = $TopBar/PlayBtn
@onready var exit_btn: Button = $TopBar/ExitBtn
@onready var world_list: ItemList = $HSplit/SettingsPanel/VBox/WorldList

var generator: WorldMapGenerator = null
var current_images: Dictionary = {}
var preview_texture: ImageTexture = null
var is_generating: bool = false
var gen_thread: Thread = null

# Terrain presets: [terrain_height, noise_freq]
const TERRAIN_PRESETS = {
	0: {"name": "Flat", "height": 3.0, "freq": 0.02},
	1: {"name": "Plains", "height": 5.0, "freq": 0.05},
	2: {"name": "Hills", "height": 10.0, "freq": 0.1},
	3: {"name": "Mountains", "height": 14.0, "freq": 0.15},
}
var loaded_world_path: String = ""

# Paint state
enum Tool { NONE, PAINT_BIOME, PAINT_ROAD, STAMP_BUILDING, ERASE }
var current_tool: Tool = Tool.NONE
var brush_size: int = 5
var paint_biome_id: int = 0
var is_painting: bool = false

func _ready() -> void:
	seed_input.value = 12345
	height_input.value = 10.0
	freq_input.value = 0.1
	road_spacing_input.value = 100.0
	world_name_input.text = "my_world"
	
	generate_btn.pressed.connect(_on_generate_pressed)
	save_btn.pressed.connect(_on_save_pressed)
	load_btn.pressed.connect(_on_load_pressed)
	play_btn.pressed.connect(_on_play_pressed)
	exit_btn.pressed.connect(_on_exit_pressed)
	preset_option.item_selected.connect(_on_preset_selected)
	world_list.item_selected.connect(_on_world_selected)
	
	progress_bar.visible = false
	progress_label.text = "Ready"
	save_btn.disabled = true
	play_btn.disabled = true
	
	# Scan for existing worlds on startup
	_refresh_world_list()
	print("[WorldEditor] Ready — found %d existing worlds" % world_list.item_count)

# ============================================================================
# WORLD LIST — scan + load existing worlds
# ============================================================================

func _refresh_world_list() -> void:
	world_list.clear()
	
	if not DirAccess.dir_exists_absolute(SAVE_BASE):
		return
	
	var dir = DirAccess.open(SAVE_BASE)
	if not dir:
		return
	
	dir.list_dir_begin()
	var folder = dir.get_next()
	while folder != "":
		if dir.current_is_dir() and folder != "." and folder != "..":
			# Check if it has a world_meta.json (valid world)
			var meta_path = SAVE_BASE + folder + "/world_meta.json"
			if FileAccess.file_exists(meta_path):
				# Read metadata for display
				var file = FileAccess.open(meta_path, FileAccess.READ)
				var display_text = folder
				if file:
					var json = JSON.new()
					if json.parse(file.get_as_text()) == OK:
						var meta = json.get_data()
						var created = meta.get("created", "")
						var seed_val = meta.get("world_seed", "?")
						display_text = "%s  (seed: %s, %s)" % [folder, str(seed_val), created]
					file.close()
				
				world_list.add_item(display_text)
				world_list.set_item_metadata(world_list.item_count - 1, folder)
		folder = dir.get_next()
	dir.list_dir_end()

func _on_world_selected(index: int) -> void:
	var folder_name = world_list.get_item_metadata(index)
	world_name_input.text = folder_name

func _on_preset_selected(index: int) -> void:
	if TERRAIN_PRESETS.has(index):
		var preset = TERRAIN_PRESETS[index]
		height_input.value = preset.height
		freq_input.value = preset.freq
		print("[WorldEditor] Preset '%s': height=%.1f, freq=%.3f" % [preset.name, preset.height, preset.freq])

func _on_exit_pressed() -> void:
	get_tree().quit()

func _on_load_pressed() -> void:
	var world_name = world_name_input.text.strip_edges()
	if world_name.is_empty():
		progress_label.text = "Enter a world name first"
		return
	
	var world_path = SAVE_BASE + world_name
	
	if not DirAccess.dir_exists_absolute(world_path):
		progress_label.text = "World not found: %s" % world_name
		return
	
	progress_label.text = "Loading %s..." % world_name
	
	var loaded = WorldMapGen.load_world(world_path)
	if loaded.is_empty():
		progress_label.text = "Failed to load %s" % world_name
		return
	
	current_images = {}
	for key in ["heightmap", "biomes", "roads", "water", "buildings"]:
		if loaded.has(key):
			current_images[key] = loaded[key]
	
	# Restore settings from metadata
	if loaded.has("metadata"):
		var meta = loaded.metadata
		seed_input.value = float(meta.get("world_seed", 12345))
		height_input.value = float(meta.get("terrain_height", 10.0))
		freq_input.value = float(meta.get("noise_freq", 0.1))
		road_spacing_input.value = float(meta.get("road_spacing", 100.0))
	
	loaded_world_path = world_path
	save_btn.disabled = false
	play_btn.disabled = false
	
	_update_preview()
	progress_label.text = "Loaded: %s (%d images)" % [world_name, current_images.size()]
	print("[WorldEditor] Loaded world: %s" % world_path)

# ============================================================================
# GENERATE
# ============================================================================

func _on_generate_pressed() -> void:
	if is_generating:
		return
	
	is_generating = true
	generate_btn.disabled = true
	progress_bar.visible = true
	progress_bar.value = 0
	progress_label.text = "Generating..."
	
	generator = WorldMapGen.new()
	generator.world_seed = int(seed_input.value)
	generator.terrain_height = height_input.value
	generator.noise_freq = freq_input.value
	generator.road_spacing = road_spacing_input.value
	generator.progress_callback = Callable(self, "_on_gen_progress")
	
	gen_thread = Thread.new()
	gen_thread.start(_threaded_generate)

func _threaded_generate() -> void:
	var images = generator.generate_world()
	call_deferred("_on_generation_complete", images)

func _on_gen_progress(percent: float, stage: String) -> void:
	call_deferred("_update_progress", percent, stage)

func _update_progress(percent: float, stage: String) -> void:
	progress_bar.value = percent
	progress_label.text = "%s (%.0f%%)" % [stage, percent]

func _on_generation_complete(images: Dictionary) -> void:
	if gen_thread and gen_thread.is_alive():
		gen_thread.wait_to_finish()
	gen_thread = null
	
	current_images = images
	is_generating = false
	generate_btn.disabled = false
	progress_bar.visible = false
	save_btn.disabled = false
	play_btn.disabled = false
	
	_update_preview()
	
	# Auto-save after generation
	_on_save_pressed()
	progress_label.text = "Generated & saved — %d×%d" % [WorldMapGen.MAP_SIZE, WorldMapGen.MAP_SIZE]
	print("[WorldEditor] Generation complete — auto-saved")

# ============================================================================
# PREVIEW — colorized composite of heightmap + biomes + roads
# ============================================================================

func _update_preview() -> void:
	if not current_images.has("heightmap") or not current_images.has("biomes"):
		return
	
	var hmap: Image = current_images.heightmap
	var bmap: Image = current_images.biomes
	var rmap: Image = current_images.roads if current_images.has("roads") else null
	var w = hmap.get_width()
	var h = hmap.get_height()
	
	# Use raw byte arrays for fast preview generation
	var h_data = hmap.get_data()
	var b_data = bmap.get_data()
	var r_data = rmap.get_data() if rmap else PackedByteArray()
	var wmap: Image = current_images.water if current_images.has("water") else null
	var w_data = wmap.get_data() if wmap else PackedByteArray()
	
	var preview_bytes = PackedByteArray()
	preview_bytes.resize(w * h * 3)  # RGB8
	
	# Biome color LUT (RGB bytes)
	var biome_lut = {
		0: [77, 153, 51],    # Grass
		1: [128, 128, 128],  # Stone
		3: [217, 199, 140],  # Sand
		4: [140, 128, 115],  # Gravel
		5: [230, 235, 242],  # Snow
		6: [64, 64, 77],     # Road
		9: [153, 140, 128],  # Granite
	}
	var default_color = [77, 153, 51]  # Grass fallback
	
	for i in w * h:
		var h_val = float(h_data[i]) / 255.0
		var biome_id = b_data[i]
		var shade = 0.6 + h_val * 0.8
		
		var base = biome_lut.get(biome_id, default_color)
		
		# Road overlay
		if r_data.size() > 0:
			var ri = i * 2
			if ri < r_data.size() and r_data[ri] > 128:
				base = [64, 64, 77]
		
		# Water overlay (blue)
		if w_data.size() > 0 and i < w_data.size() and w_data[i] > 128:
			base = [40, 80, 160]
		
		var pi = i * 3
		preview_bytes[pi] = int(clampf(base[0] * shade, 0, 255))
		preview_bytes[pi + 1] = int(clampf(base[1] * shade, 0, 255))
		preview_bytes[pi + 2] = int(clampf(base[2] * shade, 0, 255))
	
	var preview = Image.create_from_data(w, h, false, Image.FORMAT_RGB8, preview_bytes)
	
	if preview_texture:
		preview_texture.update(preview)
	else:
		preview_texture = ImageTexture.create_from_image(preview)
	canvas.texture = preview_texture

# ============================================================================
# SAVE
# ============================================================================

func _on_save_pressed() -> void:
	if current_images.is_empty():
		return
	
	var world_name = world_name_input.text.strip_edges()
	if world_name.is_empty():
		world_name = "unnamed_world"
	
	var save_path = SAVE_BASE + world_name
	
	if not generator:
		generator = WorldMapGen.new()
		generator.world_seed = int(seed_input.value)
		generator.terrain_height = height_input.value
		generator.noise_freq = freq_input.value
		generator.road_spacing = road_spacing_input.value
	
	var success = generator.save_world(save_path, current_images)
	if success:
		progress_label.text = "Saved: %s" % world_name
		_refresh_world_list()  # Update list to show new world
	else:
		progress_label.text = "Save FAILED!"

# ============================================================================
# PLAY — transition to game with this world loaded
# ============================================================================

func _on_play_pressed() -> void:
	var world_name = world_name_input.text.strip_edges()
	if world_name.is_empty():
		world_name = "unnamed_world"
	
	var world_path = SAVE_BASE + world_name
	
	# Save first to ensure PNGs are on disk
	_on_save_pressed()
	
	# Set the path on SaveManager autoload (persists across scene changes)
	var sm = get_node_or_null("/root/SaveManager")
	if sm and "pending_world_definition_path" in sm:
		sm.pending_world_definition_path = world_path
		print("[WorldEditor] Play → world_path set on SaveManager: %s" % world_path)
	else:
		push_error("[WorldEditor] SaveManager not found! Cannot transition to game.")
		progress_label.text = "ERROR: SaveManager autoload missing"
		return
	
	# Transition to the game scene
	progress_label.text = "Launching game..."
	get_tree().change_scene_to_file.call_deferred("res://modules/world_module/world_test_world_player_v2.tscn")

# ============================================================================
# PAINT TOOLS
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if current_tool == Tool.NONE or current_images.is_empty():
		return
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			is_painting = event.pressed
			if is_painting:
				_paint_at_mouse(event.global_position)
	elif event is InputEventMouseMotion and is_painting:
		_paint_at_mouse(event.global_position)

func _paint_at_mouse(_mouse_pos: Vector2) -> void:
	if not canvas or not canvas.texture:
		return
	
	var local = canvas.get_local_mouse_position()
	var tex_size = Vector2(canvas.texture.get_width(), canvas.texture.get_height())
	var canvas_size = canvas.size
	
	var px = int(local.x / canvas_size.x * tex_size.x)
	var py = int(local.y / canvas_size.y * tex_size.y)
	
	if px < 0 or py < 0 or px >= int(tex_size.x) or py >= int(tex_size.y):
		return
	
	match current_tool:
		Tool.PAINT_BIOME:
			_paint_biome(px, py)
		Tool.PAINT_ROAD:
			_paint_road(px, py)
		Tool.ERASE:
			_erase_at(px, py)

func _paint_biome(cx: int, cz: int) -> void:
	if not current_images.has("biomes"):
		return
	var bmap: Image = current_images.biomes
	var biome_norm = float(paint_biome_id) / 255.0
	
	for dx in range(-brush_size, brush_size + 1):
		for dz in range(-brush_size, brush_size + 1):
			if dx * dx + dz * dz <= brush_size * brush_size:
				var x = cx + dx
				var z = cz + dz
				if x >= 0 and x < bmap.get_width() and z >= 0 and z < bmap.get_height():
					bmap.set_pixel(x, z, Color(biome_norm, 0, 0, 1))
	_update_preview()

func _paint_road(cx: int, cz: int) -> void:
	if not current_images.has("roads"):
		return
	var rmap: Image = current_images.roads
	
	for dx in range(-brush_size, brush_size + 1):
		for dz in range(-brush_size, brush_size + 1):
			if dx * dx + dz * dz <= brush_size * brush_size:
				var x = cx + dx
				var z = cz + dz
				if x >= 0 and x < rmap.get_width() and z >= 0 and z < rmap.get_height():
					var existing = rmap.get_pixel(x, z)
					rmap.set_pixel(x, z, Color(1.0, existing.g, 0, 1))
	_update_preview()

func _erase_at(cx: int, cz: int) -> void:
	if not current_images.has("biomes") or not current_images.has("roads"):
		return
	var bmap: Image = current_images.biomes
	var rmap: Image = current_images.roads
	
	for dx in range(-brush_size, brush_size + 1):
		for dz in range(-brush_size, brush_size + 1):
			if dx * dx + dz * dz <= brush_size * brush_size:
				var x = cx + dx
				var z = cz + dz
				if x >= 0 and x < bmap.get_width() and z >= 0 and z < bmap.get_height():
					bmap.set_pixel(x, z, Color(0, 0, 0, 1))
					rmap.set_pixel(x, z, Color(0, 0, 0, 1))
	_update_preview()

func _process(_delta: float) -> void:
	if Input.is_key_pressed(KEY_1):
		current_tool = Tool.PAINT_BIOME
		paint_biome_id = WorldMapGen.MaterialID.SAND
	elif Input.is_key_pressed(KEY_2):
		current_tool = Tool.PAINT_BIOME
		paint_biome_id = WorldMapGen.MaterialID.SNOW
	elif Input.is_key_pressed(KEY_3):
		current_tool = Tool.PAINT_BIOME
		paint_biome_id = WorldMapGen.MaterialID.GRAVEL
	elif Input.is_key_pressed(KEY_4):
		current_tool = Tool.PAINT_ROAD
	elif Input.is_key_pressed(KEY_5):
		current_tool = Tool.ERASE
	elif Input.is_key_pressed(KEY_0):
		current_tool = Tool.NONE
