extends Node
## DebugManager - Autoload singleton that manages debug presets.
## Register as Autoload: Project Settings > Autoload > Add "DebugManager"

@export var current_preset: DebugPreset = null
var addon_presets: Array[DebugPreset] = []

# Cached references to managers (found on ready)
var _vegetation_manager: Node = null
var _chunk_manager: Node = null


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

# Thread-safe cached flag for performance panel routing
# This is updated from main thread and read from any thread
var _use_debugger_panel: bool = false


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


# ============================================================================
# BACKWARD-COMPATIBLE LOGGING API (replaces DebugSettings)
# ============================================================================

## Helper to send logs to the Performance panel via EngineDebugger
## Thread-safe: uses cached _use_debugger_panel flag
func _send_to_panel(category: String, message: String) -> void:
	var full_message = "[%s] %s" % [category, message]
	
	if _use_debugger_panel and EngineDebugger.is_active():
		EngineDebugger.send_message("perf_monitor:log", [category, full_message])
	else:
		# Fallback to console
		print(full_message)


## Called by PerformanceMonitor when plugin connects/disconnects
func set_debugger_panel_enabled(enabled: bool) -> void:
	_use_debugger_panel = enabled


## Direct logging methods matching DebugSettings API
func log_chunk(message: String) -> void:
	if _merged_log_chunk:
		_send_to_panel("Chunk", message)

func log_vegetation(message: String) -> void:
	if _merged_log_vegetation:
		_send_to_panel("Vegetation", message)

func log_entities(message: String) -> void:
	if _merged_log_entities:
		_send_to_panel("Entities", message)

func log_building(message: String) -> void:
	if _merged_log_building:
		_send_to_panel("Building", message)

func log_save(message: String) -> void:
	if _merged_log_save:
		_send_to_panel("Save", message)

func log_vehicles(message: String) -> void:
	if _merged_log_vehicles:
		_send_to_panel("Vehicles", message)

func log_player(message: String) -> void:
	if _merged_log_player:
		_send_to_panel("Player", message)

func log_roads(message: String) -> void:
	if _merged_log_roads:
		_send_to_panel("Roads", message)

func log_water(message: String) -> void:
	if _merged_log_water:
		_send_to_panel("Water", message)

func log_performance(message: String) -> void:
	if _merged_log_performance:
		if EngineDebugger.is_active():
			EngineDebugger.send_message("perf_monitor:log", ["Performance", message])
		else:
			print(message)


## Category flag accessors (for direct flag checks)
var LOG_CHUNK: bool:
	get: return _merged_log_chunk
var LOG_VEGETATION: bool:
	get: return _merged_log_vegetation
var LOG_ENTITIES: bool:
	get: return _merged_log_entities
var LOG_BUILDING: bool:
	get: return _merged_log_building
var LOG_SAVE: bool:
	get: return _merged_log_save
var LOG_VEHICLES: bool:
	get: return _merged_log_vehicles
var LOG_PLAYER: bool:
	get: return _merged_log_player
var LOG_ROADS: bool:
	get: return _merged_log_roads
var LOG_WATER: bool:
	get: return _merged_log_water
var LOG_PERFORMANCE: bool:
	get: return _merged_log_performance


## Utility methods from original DebugSettings
func enable_all() -> void:
	if current_preset:
		current_preset.log_chunk = true
		current_preset.log_vegetation = true
		current_preset.log_entities = true
		current_preset.log_building = true
		current_preset.log_save = true
		current_preset.log_vehicles = true
		current_preset.log_player = true
		current_preset.log_roads = true
		current_preset.log_water = true
		current_preset.log_performance = true
		_apply_current_preset()

func disable_all() -> void:
	if current_preset:
		current_preset.log_chunk = false
		current_preset.log_vegetation = false
		current_preset.log_entities = false
		current_preset.log_building = false
		current_preset.log_save = false
		current_preset.log_vehicles = false
		current_preset.log_player = false
		current_preset.log_roads = false
		current_preset.log_water = false
		current_preset.log_performance = false
		_apply_current_preset()
