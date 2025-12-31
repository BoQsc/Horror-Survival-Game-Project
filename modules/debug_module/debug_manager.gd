extends Node
## DebugManager - Autoload singleton that manages debug presets.
## Register as Autoload: Project Settings > Autoload > Add "DebugManager"

@export var current_preset: DebugPreset = null
var addon_presets: Array[DebugPreset] = []

# Cached references to managers (found on ready)
var _vegetation_manager: Node = null
var _chunk_manager: Node = null
var _terrain_interaction: Node = null

# Tag-based logging storage
var active_tags: Array[String] = []

# Merged state (primary + addons)
var _merged_log_chunk := false
var _merged_log_vegetation := false
var _merged_log_entities := false
var _merged_log_building := false
var _merged_log_save := false
var _merged_log_vehicles := false
var _merged_log_player := false
var _merged_log_roads := false
var _merged_log_water := false
var _merged_log_performance := false
var _merged_debug_draw := false
var _merged_show_vegetation := false
var _merged_show_terrain_marker := false
var _merged_show_road_zones := false
var _merged_show_chunk_bounds := false


func _ready() -> void:
	# Load primary preset from config
	if not current_preset:
		var active_path = DebugPreset.get_active_preset_path()
		if active_path and ResourceLoader.exists(active_path):
			current_preset = load(active_path)
			print("[DebugManager] Loaded primary preset: ", active_path)
		else:
			var default_path = "res://modules/debug_module/presets/default.tres"
			if ResourceLoader.exists(default_path):
				current_preset = load(default_path)
	
	# Load addon presets
	addon_presets.clear()
	var addon_paths = DebugPreset.get_addon_preset_paths()
	for path in addon_paths:
		if ResourceLoader.exists(path):
			var addon = load(path) as DebugPreset
			if addon:
				addon_presets.append(addon)
				print("[DebugManager] Loaded addon preset: ", path)
	
	call_deferred("_find_managers")
	call_deferred("_apply_current_preset")


func _find_managers() -> void:
	_vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	_chunk_manager = get_tree().get_first_node_in_group("terrain_manager")


func apply_preset(preset: DebugPreset) -> void:
	current_preset = preset
	_apply_current_preset()
	print("[DebugManager] Applied preset: ", preset.preset_name if preset else "None")


func _apply_current_preset() -> void:
	# Merge all presets (primary + addons) using OR logic
	_merge_all_presets()
	
	# Apply merged logging flags to DebugSettings
	if has_node("/root/DebugSettings"):
		var ds = get_node("/root/DebugSettings")
		ds.LOG_CHUNK = _merged_log_chunk
		ds.LOG_VEGETATION = _merged_log_vegetation
		ds.LOG_ENTITIES = _merged_log_entities
		ds.LOG_BUILDING = _merged_log_building
		ds.LOG_SAVE = _merged_log_save
		ds.LOG_VEHICLES = _merged_log_vehicles
		ds.LOG_PLAYER = _merged_log_player
		ds.LOG_ROADS = _merged_log_roads
		ds.LOG_WATER = _merged_log_water
		ds.LOG_PERFORMANCE = _merged_log_performance
	
	# Apply DebugDraw state
	if ClassDB.class_exists("DebugDraw"):
		DebugDraw.enabled = _merged_debug_draw
	
	# Apply vegetation collision visibility
	if _vegetation_manager and "debug_collision" in _vegetation_manager:
		_vegetation_manager.debug_collision = _merged_show_vegetation
	
	# Apply chunk manager visual debug
	if _chunk_manager:
		if "debug_show_road_zones" in _chunk_manager:
			_chunk_manager.debug_show_road_zones = _merged_show_road_zones
		if "debug_chunk_bounds" in _chunk_manager:
			_chunk_manager.debug_chunk_bounds = _merged_show_chunk_bounds


func _merge_all_presets() -> void:
	# Start with primary preset or defaults
	if current_preset:
		_merged_log_chunk = current_preset.log_chunk
		_merged_log_vegetation = current_preset.log_vegetation
		_merged_log_entities = current_preset.log_entities
		_merged_log_building = current_preset.log_building
		_merged_log_save = current_preset.log_save
		_merged_log_vehicles = current_preset.log_vehicles
		_merged_log_player = current_preset.log_player
		_merged_log_roads = current_preset.log_roads
		_merged_log_water = current_preset.log_water
		_merged_log_performance = current_preset.log_performance
		_merged_debug_draw = current_preset.debug_draw_enabled
		_merged_show_vegetation = current_preset.show_vegetation_collisions
		_merged_show_terrain_marker = current_preset.show_terrain_target_marker
		_merged_show_road_zones = current_preset.show_road_zones
		_merged_show_chunk_bounds = current_preset.show_chunk_bounds
		active_tags = current_preset.active_tags.duplicate()
	else:
		_merged_log_chunk = false
		_merged_log_vegetation = false
		_merged_log_entities = false
		_merged_log_building = false
		_merged_log_save = false
		_merged_log_vehicles = false
		_merged_log_player = false
		_merged_log_roads = false
		_merged_log_water = false
		_merged_log_performance = false
		_merged_debug_draw = false
		_merged_show_vegetation = false
		_merged_show_terrain_marker = false
		_merged_show_road_zones = false
		_merged_show_chunk_bounds = false
		active_tags.clear()
	
	# OR in addon presets
	for addon in addon_presets:
		_merged_log_chunk = _merged_log_chunk or addon.log_chunk
		_merged_log_vegetation = _merged_log_vegetation or addon.log_vegetation
		_merged_log_entities = _merged_log_entities or addon.log_entities
		_merged_log_building = _merged_log_building or addon.log_building
		_merged_log_save = _merged_log_save or addon.log_save
		_merged_log_vehicles = _merged_log_vehicles or addon.log_vehicles
		_merged_log_player = _merged_log_player or addon.log_player
		_merged_log_roads = _merged_log_roads or addon.log_roads
		_merged_log_water = _merged_log_water or addon.log_water
		_merged_log_performance = _merged_log_performance or addon.log_performance
		_merged_debug_draw = _merged_debug_draw or addon.debug_draw_enabled
		_merged_show_vegetation = _merged_show_vegetation or addon.show_vegetation_collisions
		_merged_show_terrain_marker = _merged_show_terrain_marker or addon.show_terrain_target_marker
		_merged_show_road_zones = _merged_show_road_zones or addon.show_road_zones
		_merged_show_chunk_bounds = _merged_show_chunk_bounds or addon.show_chunk_bounds
		for tag in addon.active_tags:
			if tag not in active_tags:
				active_tags.append(tag)


# ============================================================================
# TAG-BASED LOGGING
# ============================================================================

## Log a message if the tag is in active_tags
func log_tagged(tag: String, message: String) -> void:
	if tag in active_tags:
		print("[%s] %s" % [tag, message])


## Check if a tag is active
func is_tag_active(tag: String) -> bool:
	return tag in active_tags


## Add a tag at runtime
func add_tag(tag: String) -> void:
	if tag not in active_tags:
		active_tags.append(tag)


## Remove a tag at runtime
func remove_tag(tag: String) -> void:
	active_tags.erase(tag)


# ============================================================================
# VISUAL DEBUG QUERIES (for other scripts to check)
# ============================================================================

func should_show_terrain_marker() -> bool:
	return _merged_show_terrain_marker


func should_show_vegetation_collisions() -> bool:
	return _merged_show_vegetation
