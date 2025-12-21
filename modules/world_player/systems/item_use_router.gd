extends Node
class_name ItemUseRouter
## ItemUseRouter - Routes primary/secondary actions to appropriate mode handlers
## Now delegates to ModePlay, ModeBuild, and ModeEditor

# References
var hotbar: Node = null
var mode_manager: Node = null
var player: WorldPlayer = null

# Mode handlers
var mode_play: Node = null
var mode_build: Node = null
var mode_editor: Node = null

func _ready() -> void:
	# Find sibling components
	hotbar = get_node_or_null("../Hotbar")
	mode_manager = get_node_or_null("../ModeManager")
	
	# Find mode handlers (siblings in Modes node)
	mode_play = get_node_or_null("../../Modes/ModePlay")
	mode_build = get_node_or_null("../../Modes/ModeBuild")
	mode_editor = get_node_or_null("../../Modes/ModeEditor")
	
	# Find player (parent of Systems node)
	player = get_parent().get_parent() as WorldPlayer
	
	await get_tree().process_frame
	
	print("ItemUseRouter: Initialized")
	print("  - Hotbar: %s" % ("OK" if hotbar else "MISSING"))
	print("  - ModeManager: %s" % ("OK" if mode_manager else "MISSING"))
	print("  - ModePlay: %s" % ("OK" if mode_play else "MISSING"))
	print("  - ModeBuild: %s" % ("OK" if mode_build else "MISSING"))
	print("  - ModeEditor: %s" % ("OK" if mode_editor else "MISSING"))

func _input(event: InputEvent) -> void:
	if not hotbar or not player:
		return
	
	# Only process mouse clicks when captured
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	
	if event is InputEventMouseButton and event.pressed:
		var item = hotbar.get_selected_item()
		print("ItemUseRouter: Mouse button %d pressed, item=%s" % [event.button_index, item.get("name", "none")])
		
		if event.button_index == MOUSE_BUTTON_LEFT:
			route_primary_action(item)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			route_secondary_action(item)

## Route left-click action to appropriate mode handler
func route_primary_action(item: Dictionary) -> void:
	if not mode_manager:
		return
	
	# Route to mode handler
	if mode_manager.is_editor_mode():
		if mode_editor and mode_editor.has_method("handle_primary"):
			mode_editor.handle_primary(item)
	elif mode_manager.is_build_mode():
		if mode_build and mode_build.has_method("handle_primary"):
			mode_build.handle_primary(item)
	else: # PLAY mode
		if mode_play and mode_play.has_method("handle_primary"):
			mode_play.handle_primary(item)

## Route right-click action to appropriate mode handler
func route_secondary_action(item: Dictionary) -> void:
	if not mode_manager:
		return
	
	# Route to mode handler
	if mode_manager.is_editor_mode():
		if mode_editor and mode_editor.has_method("handle_secondary"):
			mode_editor.handle_secondary(item)
	elif mode_manager.is_build_mode():
		if mode_build and mode_build.has_method("handle_secondary"):
			mode_build.handle_secondary(item)
	else: # PLAY mode
		if mode_play and mode_play.has_method("handle_secondary"):
			mode_play.handle_secondary(item)
