@tool
extends Node
## DebugManager - Autoload singleton that manages debug presets.
## Register as Autoload: Project Settings > Autoload > Add "DebugManager"

@export var current_preset: DebugPreset = null
var addon_presets: Array[DebugPreset] = []

# Cached references to managers (found on ready)
var _vegetation_manager: Node = null
var _chunk_manager: Node = null

var _merged_debug_draw := false
var _merged_show_vegetation := false
var _merged_show_terrain_marker := false
var _merged_show_road_zones := false
var _merged_show_chunk_bounds := false

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if not OS.has_feature("debug"):
		return

	# Load primary preset from config
	if not current_preset:
		var active_path = DebugPreset.get_active_preset_path()
		if active_path and ResourceLoader.exists(active_path):
			current_preset = load(active_path)
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

	call_deferred("_find_managers")
	call_deferred("_apply_current_preset")


func _find_managers() -> void:
	_vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	_chunk_manager = get_tree().get_first_node_in_group("terrain_manager")


func apply_preset(preset: DebugPreset) -> void:
	current_preset = preset
	_apply_current_preset()


func _apply_current_preset() -> void:
	if not OS.has_feature("debug"):
		return

	# Merge all presets (primary + addons) using OR logic
	_merge_all_presets()

	# Apply DebugDraw state (use dynamic access to avoid parser errors if addon not present)
	if Engine.has_singleton("DebugDraw"):
		var debug_draw = Engine.get_singleton("DebugDraw")
		if debug_draw:
			debug_draw.enabled = _merged_debug_draw

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
		_merged_debug_draw = current_preset.debug_draw_enabled
		_merged_show_vegetation = current_preset.show_vegetation_collisions
		_merged_show_terrain_marker = current_preset.show_terrain_target_marker
		_merged_show_road_zones = current_preset.show_road_zones
		_merged_show_chunk_bounds = current_preset.show_chunk_bounds
	else:
		_merged_debug_draw = false
		_merged_show_vegetation = false
		_merged_show_terrain_marker = false
		_merged_show_road_zones = false
		_merged_show_chunk_bounds = false

	# OR in addon presets
	for addon in addon_presets:
		_merged_debug_draw = _merged_debug_draw or addon.debug_draw_enabled
		_merged_show_vegetation = _merged_show_vegetation or addon.show_vegetation_collisions
		_merged_show_terrain_marker = _merged_show_terrain_marker or addon.show_terrain_target_marker
		_merged_show_road_zones = _merged_show_road_zones or addon.show_road_zones
		_merged_show_chunk_bounds = _merged_show_chunk_bounds or addon.show_chunk_bounds


# ============================================================================
# VISUAL DEBUG QUERIES (for other scripts to check)
# ============================================================================

func should_show_terrain_marker() -> bool:
	return _merged_show_terrain_marker

func set_show_terrain_marker(enabled: bool) -> void:
	_merged_show_terrain_marker = enabled


func should_show_vegetation_collisions() -> bool:
	return _merged_show_vegetation
