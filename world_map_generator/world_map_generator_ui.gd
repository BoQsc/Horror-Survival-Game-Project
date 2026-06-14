extends Control
class_name WorldMapGeneratorUI
## World Map Generator UI - Generate, preview, paint, and save world definitions
## Acts as the "New Game" flow: generate → tweak → save → play

const WorldMapGen = preload("res://world_map_generator/world_map_generator.gd")
const WorldMapData = preload("res://world_map_data/world_map_data.gd")
const MaterialRegistry = preload("res://modules/world_generation/material_registry.gd")
const WorldMapPreviewBuilder = preload("res://world_performance/world_map_preview_builder.gd")
const WorldTerrainArtifactBaker = preload("res://world_performance/world_terrain_artifact_baker.gd")
const WorldGenerationLoadingOverlayScript = preload("res://world_performance/world_generation_loading_overlay.gd")
const SAVE_BASE = "user://worlds/"
const TERRAIN_MESH_BAKE_CHUNK_STRIDE := 31.0

@export_range(128, 1024, 64) var preview_max_size: int = 512
@export var preview_use_full_resolution_reference: bool = false
@export var generation_low_resolution_preview_enabled: bool = true
@export_range(64, 512, 32) var generation_placeholder_size: int = 256
@export var terrain_mesh_bake_enabled: bool = true
@export var terrain_mesh_bake_on_save: bool = true
@export var terrain_mesh_bake_auto_start_on_play: bool = true
@export var terrain_mesh_bake_block_play_until_ready: bool = true
@export_range(0, 16, 1) var terrain_mesh_bake_radius_chunks: int = 3
@export_range(0, 8, 1) var terrain_mesh_bake_vertical_layer_radius: int = 0
@export var terrain_mesh_bake_use_disk_radius_shape: bool = true
@export var terrain_mesh_bake_full_map_enabled: bool = false
@export_range(0, 4, 1) var terrain_mesh_bake_full_map_margin_chunks: int = 1
@export var terrain_mesh_bake_prefer_offline_cpu: bool = true
@export_range(1, 64, 1) var terrain_mesh_bake_offline_cpu_chunks_per_frame: int = 16
@export var terrain_mesh_bake_store_ready_mesh_resources: bool = true
@export var terrain_mesh_bake_store_source_buffers: bool = false
@export var terrain_mesh_bake_synchronous_disk_writes: bool = true
@export var terrain_mesh_bake_refresh_world_list_on_complete: bool = true
@export var terrain_mesh_bake_origin: Vector3 = Vector3.ZERO
@export var terrain_mesh_bake_include_origin: bool = true
@export var terrain_mesh_bake_include_town_centers: bool = true
@export_range(0, 12, 1) var terrain_mesh_bake_max_town_centers: int = 4

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
var last_generation_profile: Dictionary = {}
var last_generation_preview_profile: Dictionary = {}
var last_save_profile: Dictionary = {}
var last_preview_ms: float = 0.0
var last_save_ms: float = 0.0
var last_preview_source_size: Vector2i = Vector2i.ZERO
var last_preview_output_size: Vector2i = Vector2i.ZERO
var last_preview_sample_count: int = 0
var last_preview_backend: String = ""
var last_generation_status: String = ""
var last_generation_backend: String = ""
var last_generation_error: String = ""
var last_generation_preview_ready: bool = false
var generation_started_usec: int = 0
var is_baking_terrain: bool = false
var terrain_baker: WorldTerrainArtifactBaker = null
var last_terrain_bake_profile: Dictionary = {}
var last_terrain_bake_error: String = ""
var _last_placeholder_stage: String = ""
var _last_placeholder_percent_bucket: int = -1
var generation_loading_overlay: Node = null

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

# Programmatic UI
var building_stats_label: Label = null
var legend_container: VBoxContainer = null
var road_mode_toggle: CheckBox = null  # false=Town, true=Grid
var deep_lakes_toggle: CheckBox = null

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
	_ensure_generation_loading_overlay()
	_set_generation_status("Ready - configure and generate world", 0.0, true)
	
	# Create road mode toggle (Town vs Grid)
	var vbox = $HSplit/SettingsPanel/VBox
	var road_mode_row = HBoxContainer.new()
	var road_mode_label = Label.new()
	road_mode_label.text = "Road Mode"
	road_mode_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	road_mode_row.add_child(road_mode_label)
	road_mode_toggle = CheckBox.new()
	road_mode_toggle.text = "Use Legacy Grid"
	road_mode_toggle.tooltip_text = "Off = Town Layout, On = Legacy Grid"
	road_mode_toggle.button_pressed = false  # Default: Town mode (MST)
	road_mode_row.add_child(road_mode_toggle)
	# Insert after RoadSpacingRow
	var idx = vbox.get_child_count()
	for i in range(vbox.get_child_count()):
		if vbox.get_child(i).name == "Sep2":
			idx = i
			break
	vbox.add_child(road_mode_row)
	vbox.move_child(road_mode_row, idx)

	var lake_mode_row = HBoxContainer.new()
	var lake_mode_label = Label.new()
	lake_mode_label.text = "Lake Basin"
	lake_mode_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lake_mode_row.add_child(lake_mode_label)
	deep_lakes_toggle = CheckBox.new()
	deep_lakes_toggle.text = "Deep Carve"
	deep_lakes_toggle.tooltip_text = "Off = water mask only, On = lower terrain into lake basins"
	deep_lakes_toggle.button_pressed = true
	lake_mode_row.add_child(deep_lakes_toggle)
	vbox.add_child(lake_mode_row)
	vbox.move_child(lake_mode_row, idx + 1)
	
	# Scan for existing worlds on startup
	_refresh_world_list()
	_create_building_stats_label()
	_create_map_legend()

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
	
	var loaded = WorldMapData.load_world(world_path)
	if loaded.is_empty():
		progress_label.text = "Failed to load %s" % world_name
		return
	
	current_images = {}
	for key in ["heightmap", "biomes", "roads", "water", "buildings", "building_map", "terrain_modifications"]:
		if loaded.has(key):
			current_images[key] = loaded[key]
	
	# Restore settings from metadata
	if loaded.has("metadata"):
		var meta = loaded.metadata
		seed_input.value = float(meta.get("world_seed", 12345))
		height_input.value = float(meta.get("terrain_height", 10.0))
		freq_input.value = float(meta.get("noise_freq", 0.1))
		road_spacing_input.value = float(meta.get("road_spacing", 100.0))
		if road_mode_toggle:
			road_mode_toggle.button_pressed = bool(meta.get("use_grid_roads", false))
		if deep_lakes_toggle:
			deep_lakes_toggle.button_pressed = bool(meta.get("deep_lakes_enabled", false))
	
	loaded_world_path = world_path
	save_btn.disabled = false
	
	_update_preview()
	var artifact_manifest_status := _get_terrain_artifact_manifest_status(world_path)
	var artifacts_ready := bool(artifact_manifest_status.get("ready", false))
	play_btn.disabled = terrain_mesh_bake_enabled and terrain_mesh_bake_block_play_until_ready and not artifacts_ready and not terrain_mesh_bake_auto_start_on_play
	var artifact_status := "terrain artifacts ready" if artifacts_ready else "terrain artifacts missing"
	progress_label.text = "Loaded: %s (%d images, %s)" % [world_name, current_images.size(), artifact_status]

# ============================================================================
# GENERATE
# ============================================================================

func _on_generate_pressed() -> void:
	if is_generating:
		return
	
	is_generating = true
	generate_btn.disabled = true
	save_btn.disabled = true
	play_btn.disabled = true
	progress_bar.visible = true
	progress_bar.value = 0
	last_generation_profile = {}
	last_generation_preview_profile = {}
	last_generation_backend = ""
	last_generation_error = ""
	last_generation_preview_ready = false
	last_terrain_bake_profile = {}
	last_terrain_bake_error = ""
	generation_started_usec = Time.get_ticks_usec()
	_set_generation_status("Preparing world-map generation", 1.0, true)
	
	generator = WorldMapGen.new()
	generator.world_seed = int(seed_input.value)
	generator.terrain_height = height_input.value
	generator.water_level = generator.terrain_height + 3.0
	generator.noise_freq = freq_input.value
	generator.road_spacing = road_spacing_input.value
	generator.use_grid_roads = road_mode_toggle.button_pressed if road_mode_toggle else false
	generator.deep_lakes_enabled = deep_lakes_toggle.button_pressed if deep_lakes_toggle else true
	generator.progress_callback = Callable(self, "_on_gen_progress")
	
	gen_thread = Thread.new()
	gen_thread.start(_threaded_generate)

func _threaded_generate() -> void:
	if generation_low_resolution_preview_enabled:
		_on_gen_progress(2.0, "Generating low-resolution terrain preview")
		var preview_images := generator.generate_preview(preview_max_size)
		if not preview_images.is_empty():
			call_deferred("_on_generation_preview_ready", preview_images)
		else:
			_on_gen_progress(5.0, "Low-resolution preview unavailable; generating full world")
	else:
		_on_gen_progress(2.0, "Generating full world map")
	var images = generator.generate_world()
	call_deferred("_on_generation_complete", images)


func _on_generation_preview_ready(images: Dictionary) -> void:
	if not is_generating:
		return
	var profile_variant: Variant = images.get("preview_generation_profile", {})
	last_generation_preview_profile = profile_variant.duplicate(true) if profile_variant is Dictionary else {}
	var preview_start_us := Time.get_ticks_usec()
	var preview_result := WorldMapPreviewBuilder.build_preview(images, preview_max_size)
	_apply_preview_result(preview_result, "low_resolution_generation", preview_start_us)
	last_generation_preview_ready = true
	last_generation_backend = str(last_generation_preview_profile.get("backend", "unknown"))
	_set_generation_status(
		"Terrain preview ready (%s); generating full world" % last_generation_backend,
		8.0,
		false
	)


func _on_gen_progress(percent: float, stage: String) -> void:
	call_deferred("_update_progress", percent, stage)

func _update_progress(percent: float, stage: String) -> void:
	_set_generation_status(stage, percent, false)

func _on_generation_complete(images: Dictionary) -> void:
	if gen_thread and gen_thread.is_alive():
		gen_thread.wait_to_finish()
	gen_thread = null
	
	if images.is_empty():
		current_images = {}
		last_generation_error = "World generation returned no images"
		is_generating = false
		generate_btn.disabled = false
		save_btn.disabled = true
		play_btn.disabled = true
		progress_bar.visible = false
		_set_generation_status("Generation failed", 0.0, true)
		_set_generation_loading_failed("Generation failed", {
			"failure": last_generation_error
		})
		return

	current_images = images
	if images.has("generation_profile") and images.generation_profile is Dictionary:
		last_generation_profile = images.generation_profile.duplicate(true)
	elif generator:
		last_generation_profile = generator.last_generation_profile.duplicate(true)
	else:
		last_generation_profile = {}
	last_generation_backend = str(last_generation_profile.get("height_biome_backend", "unknown"))
	is_generating = false
	generate_btn.disabled = false
	progress_bar.visible = false
	save_btn.disabled = false
	play_btn.disabled = false
	
	_update_preview()
	
	# Show building stats if available
	if images.has("building_stats"):
		_update_building_stats(images.building_stats)
	
	# Auto-save after generation
	var saved := _on_save_pressed()
	if is_baking_terrain:
		return
	if not saved:
		progress_label.text = "Generated but save failed"
		last_generation_status = progress_label.text
		_set_generation_loading_failed(progress_label.text)
		return
	var total_ms := float(last_generation_profile.get("total_ms", 0.0))
	progress_label.text = "Generated & saved - %dx%d backend=%s gen=%.0fms save=%.0fms" % [
		WorldMapGen.MAP_SIZE,
		WorldMapGen.MAP_SIZE,
		last_generation_backend,
		total_ms,
		last_save_ms
	]
	last_generation_status = progress_label.text
	_set_generation_loading_complete(progress_label.text, {
		"backend": last_generation_backend,
		"elapsed_ms": total_ms + last_save_ms
	})
	_hide_generation_loading_overlay()

# ============================================================================
# PREVIEW — colorized composite of heightmap + biomes + roads
# ============================================================================

func _update_preview() -> void:
	if preview_use_full_resolution_reference:
		_update_preview_full_resolution_reference()
		last_preview_backend = "full_resolution_reference"
		if current_images.has("heightmap"):
			var source_image: Image = current_images.heightmap
			last_preview_source_size = Vector2i(source_image.get_width(), source_image.get_height())
			last_preview_output_size = last_preview_source_size
			last_preview_sample_count = source_image.get_width() * source_image.get_height()
		return

	var preview_start_us := Time.get_ticks_usec()
	var preview_result := WorldMapPreviewBuilder.build_preview(current_images, preview_max_size)
	_apply_preview_result(preview_result, "bounded", preview_start_us)


func _set_generation_status(stage: String, percent: float, force_placeholder: bool = false, overlay_details: Dictionary = {}) -> void:
	var safe_percent := clampf(percent, 0.0, 100.0)
	var stage_changed := stage != last_generation_status
	if progress_bar:
		progress_bar.value = safe_percent
	if progress_label:
		progress_label.text = "%s (%.0f%%)" % [stage, safe_percent]
	if stage_changed and progress_label:
		print("[WorldMapGeneratorUI] %s" % progress_label.text)
	last_generation_status = stage
	if force_placeholder or not last_generation_preview_ready:
		_show_generation_placeholder(stage, safe_percent)
	if _should_show_generation_loading_overlay(stage):
		_show_generation_loading_overlay(stage, safe_percent, overlay_details, stage_changed)
	elif stage.begins_with("Ready"):
		_hide_generation_loading_overlay()


func _ensure_generation_loading_overlay() -> Node:
	if generation_loading_overlay and is_instance_valid(generation_loading_overlay):
		return generation_loading_overlay
	generation_loading_overlay = WorldGenerationLoadingOverlayScript.new()
	generation_loading_overlay.name = "WorldGenerationLoadingOverlay"
	add_child(generation_loading_overlay)
	if generation_loading_overlay.has_method("hide_overlay"):
		generation_loading_overlay.call("hide_overlay")
	return generation_loading_overlay


func _should_show_generation_loading_overlay(stage: String) -> bool:
	if is_generating or is_baking_terrain:
		return true
	var lower_stage := stage.to_lower()
	return (
		lower_stage.contains("saving")
		or lower_stage.contains("launching")
		or lower_stage.contains("world-map preview")
		or lower_stage.contains("terrain mesh artifact")
		or lower_stage.contains("world-map generation")
	)


func _show_generation_loading_overlay(stage: String, percent: float, details: Dictionary = {}, force_log: bool = false) -> void:
	var overlay := _ensure_generation_loading_overlay()
	if not overlay or not overlay.has_method("show_stage"):
		return
	overlay.call("show_stage", stage, percent, _build_generation_loading_details(details), force_log)


func _set_generation_loading_complete(message: String, details: Dictionary = {}) -> void:
	var overlay := _ensure_generation_loading_overlay()
	if overlay and overlay.has_method("set_complete"):
		overlay.call("set_complete", message, _build_generation_loading_details(details))


func _set_generation_loading_failed(message: String, details: Dictionary = {}) -> void:
	var overlay := _ensure_generation_loading_overlay()
	if overlay and overlay.has_method("set_failed"):
		overlay.call("set_failed", message, _build_generation_loading_details(details))


func _hide_generation_loading_overlay() -> void:
	if generation_loading_overlay and is_instance_valid(generation_loading_overlay) and generation_loading_overlay.has_method("hide_overlay"):
		generation_loading_overlay.call("hide_overlay")


func _get_generation_loading_overlay_snapshot() -> Dictionary:
	if generation_loading_overlay and is_instance_valid(generation_loading_overlay) and generation_loading_overlay.has_method("get_snapshot"):
		var snapshot: Variant = generation_loading_overlay.call("get_snapshot")
		if snapshot is Dictionary:
			return snapshot
	return {}


func _build_generation_loading_details(extra: Dictionary = {}) -> Dictionary:
	var details := {}
	if seed_input:
		details["seed"] = int(seed_input.value)
	if not last_generation_backend.is_empty():
		details["backend"] = last_generation_backend
	if not loaded_world_path.is_empty():
		details["world_path"] = loaded_world_path
	for key in extra.keys():
		details[key] = extra[key]
	return details


func _show_generation_placeholder(stage: String, percent: float) -> void:
	var safe_percent := clampf(percent, 0.0, 100.0)
	var percent_bucket := int(floor(safe_percent / 5.0) * 5.0)
	if _last_placeholder_stage == stage and _last_placeholder_percent_bucket == percent_bucket:
		return
	_last_placeholder_stage = stage
	_last_placeholder_percent_bucket = percent_bucket

	var size := clampi(generation_placeholder_size, 64, 512)
	var seed_value := int(seed_input.value) if seed_input else 12345
	var progress_x := int(float(size - 1) * safe_percent / 100.0)
	var seed_phase := float(seed_value % 997) * 0.017
	var denom := float(maxi(size - 1, 1))
	var bytes := PackedByteArray()
	bytes.resize(size * size * 3)

	for y in range(size):
		var ny := float(y) / denom
		for x in range(size):
			var nx := float(x) / denom
			var ridge := 0.5 + 0.5 * sin((nx + seed_phase) * 12.0) * cos((ny - seed_phase) * 9.0)
			var valley := 0.5 + 0.5 * sin((nx - ny + seed_phase) * 18.0)
			var complete_boost := 1.28 if x <= progress_x else 0.78
			var scanline: bool = safe_percent > 0.0 and safe_percent < 100.0 and abs(float(x - progress_x)) <= 1.0
			var idx := (y * size + x) * 3
			if scanline:
				bytes[idx] = 235
				bytes[idx + 1] = 245
				bytes[idx + 2] = 255
			else:
				bytes[idx] = int(clampf((26.0 + ridge * 70.0 + valley * 18.0) * complete_boost, 0.0, 255.0))
				bytes[idx + 1] = int(clampf((56.0 + ridge * 105.0) * complete_boost, 0.0, 255.0))
				bytes[idx + 2] = int(clampf((78.0 + valley * 95.0) * complete_boost, 0.0, 255.0))

	var image := Image.create_from_data(size, size, false, Image.FORMAT_RGB8, bytes)
	_set_canvas_texture_from_image(image)


func _set_canvas_texture_from_image(image: Image) -> void:
	if image == null or image.is_empty():
		return
	if (
		preview_texture
		and preview_texture.get_width() == image.get_width()
		and preview_texture.get_height() == image.get_height()
	):
		preview_texture.update(image)
	else:
		preview_texture = ImageTexture.create_from_image(image)
	canvas.texture = preview_texture


func _apply_preview_result(preview_result: Dictionary, backend: String, preview_start_us: int = 0) -> void:
	if preview_result.is_empty():
		return
	var preview: Image = preview_result.get("image")
	if preview == null or preview.is_empty():
		return

	_set_canvas_texture_from_image(preview)
	var effective_start_us := preview_start_us if preview_start_us > 0 else Time.get_ticks_usec()
	last_preview_ms = float(Time.get_ticks_usec() - effective_start_us) / 1000.0
	last_preview_source_size = preview_result.get("source_size", Vector2i.ZERO)
	last_preview_output_size = preview_result.get("output_size", Vector2i.ZERO)
	last_preview_sample_count = int(preview_result.get("sample_count", 0))
	last_preview_backend = backend


func _update_preview_full_resolution_reference() -> void:
	if not current_images.has("heightmap") or not current_images.has("biomes"):
		return
	var preview_start_us := Time.get_ticks_usec()
	
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
	var bldg_map: Image = current_images.building_map if current_images.has("building_map") else null
	var bldg_data = bldg_map.get_data() if bldg_map else PackedByteArray()
	
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
		
		# Building overlay (bright red-orange — high contrast against all biomes)
		if bldg_data.size() > 0 and i < bldg_data.size() and bldg_data[i] > 128:
			base = [220, 80, 40]
		
		var pi = i * 3
		preview_bytes[pi] = int(clampf(base[0] * shade, 0, 255))
		preview_bytes[pi + 1] = int(clampf(base[1] * shade, 0, 255))
		preview_bytes[pi + 2] = int(clampf(base[2] * shade, 0, 255))
	
	var preview = Image.create_from_data(w, h, false, Image.FORMAT_RGB8, preview_bytes)
	
	_set_canvas_texture_from_image(preview)
	last_preview_ms = float(Time.get_ticks_usec() - preview_start_us) / 1000.0

# ============================================================================
# SAVE
# ============================================================================

func _on_save_pressed(start_bake_after_save: bool = true) -> bool:
	if current_images.is_empty():
		return false
	if is_baking_terrain:
		progress_label.text = "Terrain mesh artifact bake is still running"
		return false
	
	var world_name = world_name_input.text.strip_edges()
	if world_name.is_empty():
		world_name = "unnamed_world"
	
	var save_path = SAVE_BASE + world_name
	_show_generation_loading_overlay("Saving world definition", 0.0, {
		"world_path": save_path
	}, true)
	
	if not generator:
		generator = WorldMapGen.new()
	generator.world_seed = int(seed_input.value)
	generator.terrain_height = height_input.value
	generator.water_level = generator.terrain_height + 3.0
	generator.noise_freq = freq_input.value
	generator.road_spacing = road_spacing_input.value
	generator.use_grid_roads = road_mode_toggle.button_pressed if road_mode_toggle else false
	generator.deep_lakes_enabled = deep_lakes_toggle.button_pressed if deep_lakes_toggle else true
	
	var save_start_us := Time.get_ticks_usec()
	var success = generator.save_world(save_path, current_images)
	last_save_ms = float(Time.get_ticks_usec() - save_start_us) / 1000.0
	if success:
		last_save_profile = generator.last_save_profile.duplicate(true)
		WorldMapData.invalidate_world(save_path)
		progress_label.text = "Saved: %s" % world_name
		_show_generation_loading_overlay("World definition saved", 100.0, {
			"world_path": save_path,
			"elapsed_ms": last_save_ms
		}, true)
		_refresh_world_list()  # Update list to show new world
		if start_bake_after_save and terrain_mesh_bake_enabled and terrain_mesh_bake_on_save:
			_start_terrain_mesh_bake(save_path)
		else:
			_hide_generation_loading_overlay()
		return true
	else:
		last_save_profile = generator.last_save_profile.duplicate(true)
		progress_label.text = "Save FAILED!"
		_set_generation_loading_failed("Save FAILED", {
			"world_path": save_path,
			"elapsed_ms": last_save_ms
		})
		return false

# ============================================================================
# PLAY — transition to game with this world loaded
# ============================================================================

func _get_terrain_artifact_manifest_status(world_path: String) -> Dictionary:
	var manifest_path := WorldMapData.get_world_terrain_artifact_manifest_path(world_path)
	var status := {
		"manifest_path": manifest_path,
		"exists": false,
		"ready": false,
		"magic": "",
		"expected_chunks": 0,
		"artifact_count": 0,
		"origin_count": 0,
		"radius_chunks": 0,
		"vertical_layer_radius": 0,
		"use_disk_radius_shape": false,
		"store_ready_mesh_resources": false,
		"prefer_offline_cpu_bake": false
	}
	if manifest_path.is_empty() or not FileAccess.file_exists(manifest_path):
		return status
	status["exists"] = true
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null:
		status["read_error"] = true
		return status
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		status["parse_error"] = true
		return status
	var manifest: Dictionary = parsed
	var expected_chunks := int(manifest.get("expected_chunks", 0))
	var artifact_count := int(manifest.get("artifact_count", 0))
	status["magic"] = str(manifest.get("magic", ""))
	status["expected_chunks"] = expected_chunks
	status["artifact_count"] = artifact_count
	status["origin_count"] = int(manifest.get("origin_count", 0))
	status["radius_chunks"] = int(manifest.get("radius_chunks", 0))
	status["vertical_layer_radius"] = int(manifest.get("vertical_layer_radius", 0))
	status["use_disk_radius_shape"] = bool(manifest.get("use_disk_radius_shape", false))
	status["store_ready_mesh_resources"] = bool(manifest.get("store_ready_mesh_resources", false))
	status["prefer_offline_cpu_bake"] = bool(manifest.get("prefer_offline_cpu_bake", false))
	status["ready"] = (
		str(status.get("magic", "")) == WorldTerrainArtifactBaker.MANIFEST_MAGIC
		and expected_chunks > 0
		and artifact_count >= expected_chunks
	)
	return status


func _on_play_pressed() -> void:
	if is_baking_terrain:
		_set_generation_status("Terrain mesh artifact bake still running", progress_bar.value if progress_bar else 0.0, false)
		return

	var world_name = world_name_input.text.strip_edges()
	if world_name.is_empty():
		world_name = "unnamed_world"
	
	var world_path = SAVE_BASE + world_name
	
	var manifest_status := _get_terrain_artifact_manifest_status(world_path)
	var artifacts_ready := bool(manifest_status.get("ready", false))
	var bake_before_play := terrain_mesh_bake_enabled and not artifacts_ready and terrain_mesh_bake_auto_start_on_play

	# Save first to ensure PNGs are on disk. Play-triggered bakes are started
	# explicitly below so the save-only step cannot hide a missing manifest.
	if not _on_save_pressed(false):
		return
	if bake_before_play:
		_start_terrain_mesh_bake(world_path)
		return
	if is_baking_terrain:
		return
	if terrain_mesh_bake_enabled and terrain_mesh_bake_block_play_until_ready:
		manifest_status = _get_terrain_artifact_manifest_status(world_path)
		artifacts_ready = bool(manifest_status.get("ready", false))
		if not artifacts_ready:
			_set_generation_status("Terrain mesh artifacts missing; bake before play", 0.0, false, manifest_status)
			play_btn.disabled = not terrain_mesh_bake_auto_start_on_play
			return
	
	# Set the path on SaveManager autoload (persists across scene changes)
	var sm = get_node_or_null("/root/SaveManager")
	if sm and "pending_world_definition_path" in sm:
		sm.pending_world_definition_path = world_path
	else:
		push_error("[WorldMapGeneratorUI] SaveManager not found! Cannot transition to game.")
		progress_label.text = "ERROR: SaveManager autoload missing"
		return
	
	# Transition to the game scene
	progress_label.text = "Launching game..."
	_show_generation_loading_overlay("Launching game loading screen", 100.0, {
		"world_path": world_path
	}, true)
	await get_tree().process_frame
	get_tree().change_scene_to_file("res://modules/world_module/world_test_world_player_v2.tscn")


func _build_terrain_mesh_bake_origins() -> Array[Vector3]:
	var origins: Array[Vector3] = []
	var seen := {}
	if terrain_mesh_bake_include_origin:
		_append_unique_terrain_mesh_bake_origin(origins, seen, terrain_mesh_bake_origin)
	if not terrain_mesh_bake_include_town_centers or terrain_mesh_bake_max_town_centers <= 0:
		return origins

	var towns_variant: Variant = current_images.get("towns", [])
	if not (towns_variant is Array):
		return origins
	var town_candidates: Array = []
	for town_variant in towns_variant:
		if town_variant is Dictionary and town_variant.has("x") and town_variant.has("z"):
			town_candidates.append(town_variant)
	town_candidates.sort_custom(func(a, b): return _terrain_mesh_bake_town_priority(a) > _terrain_mesh_bake_town_priority(b))

	var added_towns := 0
	for town in town_candidates:
		if added_towns >= terrain_mesh_bake_max_town_centers:
			break
		var origin := Vector3(
			float(town.get("x", 0.0)),
			float(town.get("terrain_y", 0.0)),
			float(town.get("z", 0.0))
		)
		if _append_unique_terrain_mesh_bake_origin(origins, seen, origin):
			added_towns += 1
	return origins


func _build_terrain_mesh_full_map_bake_coords() -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	if not terrain_mesh_bake_full_map_enabled:
		return coords

	var margin := maxi(terrain_mesh_bake_full_map_margin_chunks, 0)
	var vertical_radius := maxi(terrain_mesh_bake_vertical_layer_radius, 0)
	var half_map := float(WorldMapGen.MAP_SIZE) * 0.5
	var min_x := int(floor(-half_map / TERRAIN_MESH_BAKE_CHUNK_STRIDE)) - margin
	var max_x := int(floor((half_map - 1.0) / TERRAIN_MESH_BAKE_CHUNK_STRIDE)) + margin
	var min_z := int(floor(-half_map / TERRAIN_MESH_BAKE_CHUNK_STRIDE)) - margin
	var max_z := int(floor((half_map - 1.0) / TERRAIN_MESH_BAKE_CHUNK_STRIDE)) + margin
	var base_y := int(floor(terrain_mesh_bake_origin.y / TERRAIN_MESH_BAKE_CHUNK_STRIDE))

	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			for dy in range(-vertical_radius, vertical_radius + 1):
				coords.append(Vector3i(x, base_y + dy, z))
	return coords


func _terrain_mesh_bake_town_priority(town: Dictionary) -> float:
	return (
		float(town.get("building_count", 0)) * 1000.0
		+ float(town.get("radius", 0.0)) * 10.0
		+ float(town.get("score", 0.0))
	)


func _append_unique_terrain_mesh_bake_origin(origins: Array[Vector3], seen: Dictionary, origin: Vector3) -> bool:
	var key := "%d:%d:%d" % [
		int(floor(origin.x / TERRAIN_MESH_BAKE_CHUNK_STRIDE)),
		int(floor(origin.y / TERRAIN_MESH_BAKE_CHUNK_STRIDE)),
		int(floor(origin.z / TERRAIN_MESH_BAKE_CHUNK_STRIDE))
	]
	if seen.has(key):
		return false
	seen[key] = true
	origins.append(origin)
	return true


func _start_terrain_mesh_bake(world_path: String) -> void:
	if world_path.strip_edges().is_empty():
		return
	if is_baking_terrain:
		return
	if terrain_baker and is_instance_valid(terrain_baker):
		terrain_baker.queue_free()

	is_baking_terrain = true
	last_terrain_bake_profile = {}
	last_terrain_bake_error = ""
	generate_btn.disabled = true
	save_btn.disabled = true
	play_btn.disabled = true
	progress_bar.visible = true

	terrain_baker = WorldTerrainArtifactBaker.new()
	terrain_baker.name = "WorldTerrainArtifactBaker"
	terrain_baker.bake_radius_chunks = terrain_mesh_bake_radius_chunks
	terrain_baker.vertical_layer_radius = terrain_mesh_bake_vertical_layer_radius
	terrain_baker.use_disk_radius_shape = terrain_mesh_bake_use_disk_radius_shape
	terrain_baker.prefer_offline_cpu_bake = terrain_mesh_bake_prefer_offline_cpu
	terrain_baker.offline_cpu_chunks_per_frame = terrain_mesh_bake_offline_cpu_chunks_per_frame
	terrain_baker.store_ready_mesh_resources = terrain_mesh_bake_store_ready_mesh_resources
	terrain_baker.store_source_buffers = terrain_mesh_bake_store_source_buffers
	terrain_baker.synchronous_disk_writes = terrain_mesh_bake_synchronous_disk_writes
	add_child(terrain_baker)
	terrain_baker.progress_changed.connect(_on_terrain_bake_progress)
	terrain_baker.bake_completed.connect(_on_terrain_bake_completed)
	terrain_baker.bake_failed.connect(_on_terrain_bake_failed)

	var bake_origins: Array[Vector3] = _build_terrain_mesh_bake_origins()
	if bake_origins.is_empty():
		bake_origins.append(terrain_mesh_bake_origin)
	var bake_coords: Array[Vector3i] = _build_terrain_mesh_full_map_bake_coords()
	var coord_mode := "explicit_full_map" if not bake_coords.is_empty() else "origins_radius"
	var target_label := "chunks" if not bake_coords.is_empty() else "origins"
	var target_count := bake_coords.size() if not bake_coords.is_empty() else bake_origins.size()
	_set_generation_status(
		"Preparing terrain mesh artifact bake (%s, %d %s)" % [coord_mode, target_count, target_label],
		0.0,
		false,
		{
			"world_path": world_path,
			"artifact_root": WorldMapData.get_world_terrain_artifact_root(world_path),
			"coord_mode": coord_mode,
			"explicit_coord_count": bake_coords.size(),
			"full_map_enabled": terrain_mesh_bake_full_map_enabled,
			"full_map_margin_chunks": terrain_mesh_bake_full_map_margin_chunks,
			"origin_count": bake_origins.size(),
			"radius_chunks": terrain_mesh_bake_radius_chunks,
			"vertical_layer_radius": terrain_mesh_bake_vertical_layer_radius,
			"use_disk_radius_shape": terrain_mesh_bake_use_disk_radius_shape,
			"prefer_offline_cpu_bake": terrain_mesh_bake_prefer_offline_cpu,
			"offline_cpu_chunks_per_frame": terrain_mesh_bake_offline_cpu_chunks_per_frame,
			"store_ready_mesh_resources": terrain_mesh_bake_store_ready_mesh_resources,
			"store_source_buffers": terrain_mesh_bake_store_source_buffers,
			"synchronous_disk_writes": terrain_mesh_bake_synchronous_disk_writes
		}
	)
	var bake_options := {
		"bake_origins": bake_origins,
		"include_primary_origin": false,
		"store_ready_mesh_resources": terrain_mesh_bake_store_ready_mesh_resources,
		"store_source_buffers": terrain_mesh_bake_store_source_buffers,
		"synchronous_disk_writes": terrain_mesh_bake_synchronous_disk_writes,
		"high_throughput_budgets": true,
		"vertical_layer_radius": terrain_mesh_bake_vertical_layer_radius,
		"use_disk_radius_shape": terrain_mesh_bake_use_disk_radius_shape,
		"prefer_offline_cpu_bake": terrain_mesh_bake_prefer_offline_cpu,
		"offline_cpu_chunks_per_frame": terrain_mesh_bake_offline_cpu_chunks_per_frame
	}
	if not bake_coords.is_empty():
		bake_options["bake_coords"] = bake_coords
	var started := terrain_baker.start_bake(
		world_path,
		bake_origins[0],
		terrain_mesh_bake_radius_chunks,
		bake_options
	)
	if not started:
		_on_terrain_bake_failed({
			"failure_reason": "start_failed",
			"world_path": world_path,
			"artifact_root": WorldMapData.get_world_terrain_artifact_root(world_path)
		})


func _on_terrain_bake_progress(profile: Dictionary) -> void:
	last_terrain_bake_profile = profile.duplicate(true)
	var stage := str(profile.get("stage", "baking terrain mesh artifacts"))
	var percent := float(profile.get("progress_percent", 0.0))
	var artifact_count := int(profile.get("artifact_count", 0))
	var expected_chunks := int(profile.get("expected_chunks", 0))
	var origin_count := int(profile.get("origin_count", 1))
	var coord_mode := str(profile.get("coord_mode", "origins_radius"))
	var explicit_coord_count := int(profile.get("explicit_coord_count", 0))
	var target_summary := "coords=%d" % explicit_coord_count if explicit_coord_count > 0 else "origins=%d" % origin_count
	var artifact_root := str(profile.get("artifact_root", ""))
	_set_generation_status(
		"%s %s %s chunks=%d/%d -> %s" % [stage.capitalize(), coord_mode, target_summary, artifact_count, expected_chunks, artifact_root],
		percent,
		false,
		profile
	)


func _on_terrain_bake_completed(profile: Dictionary) -> void:
	is_baking_terrain = false
	last_terrain_bake_profile = profile.duplicate(true)
	generate_btn.disabled = false
	save_btn.disabled = false
	play_btn.disabled = false
	progress_bar.visible = false
	if terrain_mesh_bake_refresh_world_list_on_complete:
		_refresh_world_list()
	var artifact_root := str(profile.get("artifact_root", ""))
	var artifact_count := int(profile.get("artifact_count", 0))
	var origin_count := int(profile.get("origin_count", 1))
	var coord_mode := str(profile.get("coord_mode", "origins_radius"))
	var explicit_coord_count := int(profile.get("explicit_coord_count", 0))
	var target_summary := "%d explicit coords" % explicit_coord_count if explicit_coord_count > 0 else "%d origins" % origin_count
	var elapsed_ms := float(profile.get("elapsed_ms", 0.0))
	progress_label.text = "Generated, saved, and baked %d terrain mesh artifacts (%s, %s) in %.0fms -> %s" % [
		artifact_count,
		coord_mode,
		target_summary,
		elapsed_ms,
		artifact_root
	]
	last_generation_status = progress_label.text
	_set_generation_loading_complete(progress_label.text, profile)
	_hide_generation_loading_overlay()


func _on_terrain_bake_failed(profile: Dictionary) -> void:
	is_baking_terrain = false
	last_terrain_bake_profile = profile.duplicate(true)
	last_terrain_bake_error = str(profile.get("failure_reason", "unknown"))
	generate_btn.disabled = false
	save_btn.disabled = false
	play_btn.disabled = false
	progress_bar.visible = false
	var artifact_root := str(profile.get("artifact_root", ""))
	progress_label.text = "Terrain mesh artifact bake FAILED (%s) -> %s" % [last_terrain_bake_error, artifact_root]
	last_generation_status = progress_label.text
	_set_generation_loading_failed(progress_label.text, profile)

func get_telemetry_snapshot() -> Dictionary:
	return {
		"is_generating": is_generating,
		"is_baking_terrain": is_baking_terrain,
		"terrain_mesh_bake_enabled": terrain_mesh_bake_enabled,
		"terrain_mesh_bake_on_save": terrain_mesh_bake_on_save,
		"terrain_mesh_bake_auto_start_on_play": terrain_mesh_bake_auto_start_on_play,
		"terrain_mesh_bake_block_play_until_ready": terrain_mesh_bake_block_play_until_ready,
		"terrain_mesh_bake_radius_chunks": terrain_mesh_bake_radius_chunks,
		"terrain_mesh_bake_vertical_layer_radius": terrain_mesh_bake_vertical_layer_radius,
		"terrain_mesh_bake_use_disk_radius_shape": terrain_mesh_bake_use_disk_radius_shape,
		"terrain_mesh_bake_full_map_enabled": terrain_mesh_bake_full_map_enabled,
		"terrain_mesh_bake_full_map_margin_chunks": terrain_mesh_bake_full_map_margin_chunks,
		"terrain_mesh_bake_prefer_offline_cpu": terrain_mesh_bake_prefer_offline_cpu,
		"terrain_mesh_bake_offline_cpu_chunks_per_frame": terrain_mesh_bake_offline_cpu_chunks_per_frame,
		"terrain_mesh_bake_store_ready_mesh_resources": terrain_mesh_bake_store_ready_mesh_resources,
		"terrain_mesh_bake_store_source_buffers": terrain_mesh_bake_store_source_buffers,
		"terrain_mesh_bake_synchronous_disk_writes": terrain_mesh_bake_synchronous_disk_writes,
		"terrain_mesh_bake_include_origin": terrain_mesh_bake_include_origin,
		"terrain_mesh_bake_include_town_centers": terrain_mesh_bake_include_town_centers,
		"terrain_mesh_bake_max_town_centers": terrain_mesh_bake_max_town_centers,
		"current_image_count": current_images.size(),
		"last_preview_ms": last_preview_ms,
		"last_preview_backend": last_preview_backend,
		"preview_max_size": preview_max_size,
		"generation_low_resolution_preview_enabled": generation_low_resolution_preview_enabled,
		"last_preview_source_size": last_preview_source_size,
		"last_preview_output_size": last_preview_output_size,
		"last_preview_sample_count": last_preview_sample_count,
		"last_save_ms": last_save_ms,
		"last_generation_status": last_generation_status,
		"last_generation_backend": last_generation_backend,
		"last_generation_error": last_generation_error,
		"last_generation_preview_ready": last_generation_preview_ready,
		"generation_started_usec": generation_started_usec,
		"last_generation_profile": last_generation_profile.duplicate(true),
		"last_generation_preview_profile": last_generation_preview_profile.duplicate(true),
		"last_save_profile": last_save_profile.duplicate(true),
		"last_terrain_bake_profile": last_terrain_bake_profile.duplicate(true),
		"last_terrain_bake_error": last_terrain_bake_error,
		"generation_loading_overlay": _get_generation_loading_overlay_snapshot()
	}

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
	if not current_images.has("heightmap"):
		return
	
	var local = canvas.get_local_mouse_position()
	var source_image: Image = current_images.heightmap
	var source_size = Vector2(source_image.get_width(), source_image.get_height())
	var canvas_size = canvas.size
	
	var px = int(local.x / canvas_size.x * source_size.x)
	var py = int(local.y / canvas_size.y * source_size.y)
	
	if px < 0 or py < 0 or px >= int(source_size.x) or py >= int(source_size.y):
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
		paint_biome_id = MaterialRegistry.SAND
	elif Input.is_key_pressed(KEY_2):
		current_tool = Tool.PAINT_BIOME
		paint_biome_id = MaterialRegistry.SNOW
	elif Input.is_key_pressed(KEY_3):
		current_tool = Tool.PAINT_BIOME
		paint_biome_id = MaterialRegistry.GRAVEL
	elif Input.is_key_pressed(KEY_4):
		current_tool = Tool.PAINT_ROAD
	elif Input.is_key_pressed(KEY_5):
		current_tool = Tool.ERASE
	elif Input.is_key_pressed(KEY_0):
		current_tool = Tool.NONE

# ============================================================================
# BUILDING STATS + MAP LEGEND
# ============================================================================

func _create_building_stats_label() -> void:
	var vbox = $HSplit/SettingsPanel/VBox
	
	var sep = HSeparator.new()
	sep.name = "BuildingSep"
	vbox.add_child(sep)
	
	building_stats_label = Label.new()
	building_stats_label.name = "BuildingStats"
	building_stats_label.text = "Buildings: Generate a world to see stats"
	building_stats_label.add_theme_font_size_override("font_size", 11)
	building_stats_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.6, 1))
	building_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(building_stats_label)

func _update_building_stats(stats: Dictionary) -> void:
	if not building_stats_label:
		return
	var placed = stats.get("placed", 0)
	var attempted = stats.get("attempted", 0)
	var lines = "Buildings: %d placed / %d intersections\n" % [placed, attempted]
	var rejected_water = stats.get("rejected_water", 0)
	var rejected_slope = stats.get("rejected_slope", 0)
	var rejected_forest = stats.get("rejected_forest", 0)
	var rejected_height = stats.get("rejected_height", 0)
	var rejected_chance = stats.get("rejected_chance", 0)
	var rejected_bounds = stats.get("rejected_bounds", 0)
	var total_rejected = rejected_water + rejected_slope + rejected_forest + rejected_height + rejected_bounds
	lines += "Rejected: %d " % total_rejected
	if total_rejected > 0:
		var reasons = []
		if rejected_water > 0: reasons.append("water:%d" % rejected_water)
		if rejected_slope > 0: reasons.append("slope:%d" % rejected_slope)
		if rejected_forest > 0: reasons.append("forest:%d" % rejected_forest)
		if rejected_height > 0: reasons.append("height:%d" % rejected_height)
		if rejected_bounds > 0: reasons.append("bounds:%d" % rejected_bounds)
		lines += "(%s)" % ", ".join(reasons)
	lines += "\nSkipped (chance): %d" % rejected_chance
	building_stats_label.text = lines

func _create_map_legend() -> void:
	var vbox = $HSplit/SettingsPanel/VBox
	
	var sep = HSeparator.new()
	sep.name = "LegendSep"
	vbox.add_child(sep)
	
	var title = Label.new()
	title.name = "LegendTitle"
	title.text = "Map Legend"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	
	legend_container = VBoxContainer.new()
	legend_container.name = "LegendContainer"
	vbox.add_child(legend_container)
	
	var entries = [
		[Color(0.31, 0.63, 0.24), "Grass"],
		[Color(0.76, 0.70, 0.50), "Sand"],
		[Color(0.90, 0.90, 0.94), "Snow"],
		[Color(0.55, 0.51, 0.45), "Gravel"],
		[Color(0.25, 0.25, 0.30), "Roads"],
		[Color(0.16, 0.31, 0.63), "Water"],
		[Color(0.86, 0.31, 0.16), "Buildings"],
	]
	
	for entry in entries:
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		
		var swatch = ColorRect.new()
		swatch.color = entry[0]
		swatch.custom_minimum_size = Vector2(14, 14)
		row.add_child(swatch)
		
		var lbl = Label.new()
		lbl.text = entry[1]
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 0.9))
		row.add_child(lbl)
		
		legend_container.add_child(row)
