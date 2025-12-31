@tool
class_name DebugPreset
extends Resource
## Saveable debug configuration preset.
## Create .tres files in presets/ folder to save configurations.
## Click "Activate This Preset" button in Inspector to apply.

@export var preset_name: String = ""
@export_multiline var description: String = ""

# === ACTIVATE BUTTON ===
## Click to apply this preset to DebugManager
@export var _activate_preset: bool = false:
	set(value):
		if value and Engine.is_editor_hint():
			_activate_preset = false  # Reset button
			_do_activate()

func _do_activate() -> void:
	# Find DebugManager autoload and apply this preset
	var tree = Engine.get_main_loop()
	if tree and tree.root:
		var dm = tree.root.get_node_or_null("DebugManager")
		if dm and dm.has_method("apply_preset"):
			dm.apply_preset(self)
			print("[DebugPreset] Activated: ", preset_name)
		else:
			push_warning("[DebugPreset] DebugManager not found. Is game running?")

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
@export var show_terrain_target_marker := false  # Yellow sphere + material name
@export var show_road_zones := false
@export var show_chunk_bounds := false

# === FEATURE TAGS ===
@export_group("Feature Tags")
@export var active_tags: Array[String] = []
