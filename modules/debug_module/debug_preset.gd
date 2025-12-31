class_name DebugPreset
extends Resource
## Saveable debug configuration preset.
## Create .tres files in presets/ folder to save configurations.

@export var preset_name: String = ""
@export_multiline var description: String = ""

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
