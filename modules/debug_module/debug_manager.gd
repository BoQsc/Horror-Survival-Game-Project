extends Node
## DebugManager - Autoload singleton that manages debug presets.
## Register as Autoload: Project Settings > Autoload > Add "DebugManager"

@export var current_preset: DebugPreset = null

# Cached references to managers (found on ready)
var _vegetation_manager: Node = null
var _chunk_manager: Node = null
var _terrain_interaction: Node = null

# Tag-based logging storage
var active_tags: Array[String] = []


func _ready() -> void:
	# Load default preset if none assigned
	if not current_preset:
		var default_path = "res://modules/debug_module/presets/default.tres"
		if ResourceLoader.exists(default_path):
			current_preset = load(default_path)
	
	call_deferred("_find_managers")
	call_deferred("_apply_current_preset")


func _find_managers() -> void:
	_vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	_chunk_manager = get_tree().get_first_node_in_group("terrain_manager")
	# TerrainInteraction is per-player, will be found dynamically


func apply_preset(preset: DebugPreset) -> void:
	current_preset = preset
	_apply_current_preset()
	print("[DebugManager] Applied preset: ", preset.preset_name if preset else "None")


func _apply_current_preset() -> void:
	if not current_preset:
		return
	
	var p = current_preset
	
	# Apply logging flags to DebugSettings (backwards compatibility)
	if has_node("/root/DebugSettings"):
		var ds = get_node("/root/DebugSettings")
		ds.LOG_CHUNK = p.log_chunk
		ds.LOG_VEGETATION = p.log_vegetation
		ds.LOG_ENTITIES = p.log_entities
		ds.LOG_BUILDING = p.log_building
		ds.LOG_SAVE = p.log_save
		ds.LOG_VEHICLES = p.log_vehicles
		ds.LOG_PLAYER = p.log_player
		ds.LOG_ROADS = p.log_roads
		ds.LOG_WATER = p.log_water
		ds.LOG_PERFORMANCE = p.log_performance
	
	# Apply DebugDraw state
	if ClassDB.class_exists("DebugDraw"):
		DebugDraw.enabled = p.debug_draw_enabled
	
	# Apply vegetation collision visibility
	if _vegetation_manager and "debug_collision" in _vegetation_manager:
		_vegetation_manager.debug_collision = p.show_vegetation_collisions
	
	# Apply chunk manager visual debug
	if _chunk_manager:
		if "debug_show_road_zones" in _chunk_manager:
			_chunk_manager.debug_show_road_zones = p.show_road_zones
		if "debug_chunk_bounds" in _chunk_manager:
			_chunk_manager.debug_chunk_bounds = p.show_chunk_bounds
	
	# Store active tags for log_tagged() function
	active_tags = p.active_tags.duplicate()


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
	return current_preset != null and current_preset.show_terrain_target_marker


func should_show_vegetation_collisions() -> bool:
	return current_preset != null and current_preset.show_vegetation_collisions
