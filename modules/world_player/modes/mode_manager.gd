extends Node
class_name ModeManager
## ModeManager - Handles mode transitions (PLAY, BUILD, EDITOR)
## PLAY and BUILD are determined by held item category
## EDITOR is toggled with backtick (`) key

enum Mode {PLAY, BUILD, EDITOR}

var current_mode: Mode = Mode.PLAY
var previous_mode: Mode = Mode.PLAY # For returning from EDITOR

# Reference to hotbar
var hotbar: Hotbar = null

# Preload item definitions
const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")

# EDITOR submodes
enum EditorSubmode {TERRAIN, WATER, ROAD, PREFAB, FLY}
var editor_submode: EditorSubmode = EditorSubmode.TERRAIN
var is_flying: bool = false

func _ready() -> void:
	# Find hotbar in sibling nodes
	hotbar = get_node_or_null("../Hotbar")
	if not hotbar:
		push_warning("ModeManager: Hotbar not found, mode switching will be limited")
	
	# Connect to hotbar item changes
	PlayerSignals.item_changed.connect(_on_item_changed)
	
	print("ModeManager: Initialized in %s mode" % get_mode_name())

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		# Backtick toggles EDITOR mode
		if event.keycode == KEY_QUOTELEFT:
			toggle_editor_mode()
		
		# EDITOR submode keys (only when in EDITOR mode)
		if current_mode == Mode.EDITOR:
			match event.keycode:
				KEY_1:
					set_editor_submode(EditorSubmode.TERRAIN)
				KEY_2:
					set_editor_submode(EditorSubmode.WATER)
				KEY_3:
					set_editor_submode(EditorSubmode.ROAD)
				KEY_4:
					set_editor_submode(EditorSubmode.PREFAB)
				KEY_F:
					toggle_fly_mode()
	
	# Scrollwheel to cycle submodes in EDITOR mode
	if current_mode == Mode.EDITOR:
		if event is InputEventMouseButton and event.pressed:
			if not event.ctrl_pressed and not event.shift_pressed:
				var submode_count = EditorSubmode.FLY + 1 # All submodes including FLY
				if event.button_index == MOUSE_BUTTON_WHEEL_UP:
					var new_submode = (editor_submode - 1 + submode_count) % submode_count
					set_editor_submode(new_submode as EditorSubmode)
					get_viewport().set_input_as_handled()
				elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					var new_submode = (editor_submode + 1) % submode_count
					set_editor_submode(new_submode as EditorSubmode)
					get_viewport().set_input_as_handled()

func _on_item_changed(_slot: int, item: Dictionary) -> void:
	# Don't auto-switch modes while in EDITOR
	if current_mode == Mode.EDITOR:
		return
	
	var new_mode = determine_mode_from_item(item)
	if new_mode != current_mode:
		set_mode(new_mode)

## Determine which mode an item category belongs to
func determine_mode_from_item(item: Dictionary) -> Mode:
	# Use is_build_item which considers special flags like is_firearm
	if ItemDefs.is_build_item(item):
		return Mode.BUILD
	else:
		return Mode.PLAY

## Set the current mode
func set_mode(new_mode: Mode) -> void:
	if new_mode == current_mode:
		return
	
	var old_mode = current_mode
	current_mode = new_mode
	
	print("ModeManager: %s -> %s" % [get_mode_name_for(old_mode), get_mode_name_for(new_mode)])
	
	PlayerSignals.mode_changed.emit(get_mode_name_for(old_mode), get_mode_name_for(new_mode))

## Toggle EDITOR mode on/off
func toggle_editor_mode() -> void:
	if current_mode == Mode.EDITOR:
		# Return to previous mode
		set_mode(previous_mode)
		is_flying = false # Disable fly when exiting editor
	else:
		# Enter editor mode
		previous_mode = current_mode
		set_mode(Mode.EDITOR)
	
	print("ModeManager: EDITOR mode %s (submode: %s)" % [
		"ON" if current_mode == Mode.EDITOR else "OFF",
		get_submode_name()
	])

## Set EDITOR submode
func set_editor_submode(submode: EditorSubmode) -> void:
	if current_mode != Mode.EDITOR:
		return
	
	editor_submode = submode
	print("ModeManager: Editor submode -> %s" % get_submode_name())
	PlayerSignals.editor_submode_changed.emit(editor_submode, get_submode_name())

## Toggle fly mode (EDITOR only)
func toggle_fly_mode() -> void:
	if current_mode != Mode.EDITOR:
		return
	
	is_flying = !is_flying
	print("ModeManager: Fly mode %s" % ("ON" if is_flying else "OFF"))

## Get current mode name
func get_mode_name() -> String:
	return get_mode_name_for(current_mode)

## Get mode name for a specific mode
func get_mode_name_for(mode: Mode) -> String:
	match mode:
		Mode.PLAY: return "PLAY"
		Mode.BUILD: return "BUILD"
		Mode.EDITOR: return "EDITOR"
	return "UNKNOWN"

## Get current submode name
func get_submode_name() -> String:
	match editor_submode:
		EditorSubmode.TERRAIN: return "Terrain"
		EditorSubmode.WATER: return "Water"
		EditorSubmode.ROAD: return "Road"
		EditorSubmode.PREFAB: return "Prefab"
		EditorSubmode.FLY: return "Fly"
	return "Unknown"

## Check if currently in a specific mode
func is_mode(mode: Mode) -> bool:
	return current_mode == mode

## Check if in PLAY mode
func is_play_mode() -> bool:
	return current_mode == Mode.PLAY

## Check if in BUILD mode
func is_build_mode() -> bool:
	return current_mode == Mode.BUILD

## Check if in EDITOR mode
func is_editor_mode() -> bool:
	return current_mode == Mode.EDITOR

## Check if fly mode is active
func is_fly_active() -> bool:
	return current_mode == Mode.EDITOR and is_flying
