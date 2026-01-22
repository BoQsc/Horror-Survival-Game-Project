@tool
class_name DebugPreset
extends Resource
## Saveable debug configuration preset.

const ACTIVE_PRESET_CONFIG = "user://debug_active_preset.cfg"

@export var preset_name: String = ""
@export_multiline var description: String = ""
@export var is_active: bool = false:
	set(value):
		var was_active = is_active
		is_active = value
		# Only trigger on actual user change in editor (not on resource load)
		if Engine.is_editor_hint() and resource_path != "" and was_active != value:
			_on_active_changed(value)
@export var activate_along: bool = false:
	set(value):
		var was_along = activate_along
		activate_along = value
		if Engine.is_editor_hint() and resource_path != "" and was_along != value:
			_on_along_changed(value)

# === CONSOLE LOGGING ===
@export_group("Console Logging")
@export var log_chunk := false
@export var log_vegetation := false
@export var log_entities := false
@export var log_building := false
@export var log_save := false
@export var log_vehicles := false
@export var log_player := false
@export var log_roads := false
@export var log_water := false
@export var log_performance := false

# === VISUAL DEBUG ===
@export_group("Visual Debug")
@export var debug_draw_enabled := false
@export var show_vegetation_collisions := false
@export var show_terrain_target_marker := false
@export var show_road_zones := false
@export var show_chunk_bounds := false

# === FEATURE TAGS ===
@export_group("Feature Tags")
@export var active_tags: Array[String] = []

func _on_active_changed(active: bool) -> void:
	if active:
		# Deactivate all other PRIMARY presets (not addon ones)
		_deactivate_other_presets(false)  # false = only deactivate is_active, not activate_along
		
		# Save this preset's path to config
		var config = ConfigFile.new()
		config.load(ACTIVE_PRESET_CONFIG)  # Load existing to preserve addons
		config.set_value("debug", "active_preset", resource_path)
		config.save(ACTIVE_PRESET_CONFIG)
		print("[DebugPreset] Set active: %s (%s)" % [preset_name, resource_path])
	else:
		# Clear active preset
		var config = ConfigFile.new()
		config.load(ACTIVE_PRESET_CONFIG)
		config.set_value("debug", "active_preset", "")
		config.save(ACTIVE_PRESET_CONFIG)
		print("[DebugPreset] Deactivated: ", preset_name)


func _on_along_changed(active: bool) -> void:
	# Addon presets are stored in a separate list
	var config = ConfigFile.new()
	config.load(ACTIVE_PRESET_CONFIG)
	var addons: Array = config.get_value("debug", "addon_presets", [])
	
	if active:
		if resource_path not in addons:
			addons.append(resource_path)
		print("[DebugPreset] Added addon: %s" % preset_name)
	else:
		addons.erase(resource_path)
		print("[DebugPreset] Removed addon: %s" % preset_name)
	
	config.set_value("debug", "addon_presets", addons)
	config.save(ACTIVE_PRESET_CONFIG)


func _deactivate_other_presets(include_addons: bool = false) -> void:
	# Scan all presets in the presets folder and deactivate them
	var presets_dir = "res://modules/debug_module/presets/"
	var dir = DirAccess.open(presets_dir)
	if not dir:
		return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres") and not dir.current_is_dir():
			var preset_path = presets_dir + file_name
			if preset_path != resource_path:  # Don't modify self
				var preset = load(preset_path) as DebugPreset
				if preset:
					var has_changed = false
					if preset.is_active:
						preset.is_active = false
						has_changed = true
					if include_addons and preset.activate_along:
						preset.activate_along = false
						has_changed = true
					if has_changed:
						ResourceSaver.save(preset, preset_path)
		file_name = dir.get_next()
	dir.list_dir_end()


static func get_active_preset_path() -> String:
	var config = ConfigFile.new()
	if config.load(ACTIVE_PRESET_CONFIG) == OK:
		return config.get_value("debug", "active_preset", "")
	return ""


static func get_addon_preset_paths() -> Array:
	var config = ConfigFile.new()
	if config.load(ACTIVE_PRESET_CONFIG) == OK:
		return config.get_value("debug", "addon_presets", [])
	return []
