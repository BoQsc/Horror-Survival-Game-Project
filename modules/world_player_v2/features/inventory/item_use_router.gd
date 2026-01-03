extends Node
class_name ItemUseRouterV2
## ItemUseRouter - Routes primary/secondary actions to appropriate mode handlers
## Now delegates to ModePlay, ModeBuild, and ModeEditor

# References
var hotbar: Node = null
var mode_manager: Node = null
var player: Node = null  # WorldPlayerV2 or CharacterBody3D

# Mode handlers
var combat_system: Node = null  # Replaces mode_play
var mode_build: Node = null
var mode_editor: Node = null
var terrain_interaction: Node = null

# Hold-to-attack state
var is_primary_held: bool = false
var is_secondary_held: bool = false
var primary_triggered_this_frame: bool = false # Skip _process trigger on click frame

func _ready() -> void:
	# Find sibling components
	hotbar = get_node_or_null("../Hotbar")
	mode_manager = get_node_or_null("../ModeManager")
	
	# Find mode handlers (siblings in Modes node)
	combat_system = get_node_or_null("../../Modes/CombatSystem")
	mode_build = get_node_or_null("../../Modes/ModeBuild")
	mode_editor = get_node_or_null("../../Modes/ModeEditor")
	terrain_interaction = get_node_or_null("../../Modes/TerrainInteraction")
	
	# Find player (parent of Systems node)
	player = get_parent().get_parent()
	
	await get_tree().process_frame
	
	print("ItemUseRouter: Initialized")
	print("  - Hotbar: %s" % ("OK" if hotbar else "MISSING"))
	print("  - ModeManager: %s" % ("OK" if mode_manager else "MISSING"))
	print("  - CombatSystem: %s" % ("OK" if combat_system else "MISSING"))
	print("  - ModeBuild: %s" % ("OK" if mode_build else "MISSING"))
	print("  - ModeEditor: %s" % ("OK" if mode_editor else "MISSING"))

func _process(_delta: float) -> void:
	# Hold-to-attack: continuously trigger actions while mouse is held
	# The attack cooldown in mode handlers ensures proper timing
	if not hotbar or not player:
		return
	
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		is_primary_held = false
		is_secondary_held = false
		return
	
	# Continuous primary action while holding left mouse
	# Skip on the same frame as the initial click (already triggered from _input)
	# Terrain system now handles rapid mods with per-chunk versioning (stale update detection)
	if is_primary_held:
		if primary_triggered_this_frame:
			primary_triggered_this_frame = false # Reset for next frame
		else:
			var item = hotbar.get_selected_item()
			route_primary_action(item)

func _input(event: InputEvent) -> void:
	if not hotbar or not player:
		return
	
	# Only process mouse clicks when captured
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			is_primary_held = event.pressed
			# Trigger immediately on press
			if event.pressed:
				primary_triggered_this_frame = true # Prevent double-trigger from _process
				var item = hotbar.get_selected_item()
				print("ItemUseRouter: LMB pressed, item=%s" % item.get("name", "none"))
				route_primary_action(item)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			is_secondary_held = event.pressed
			# Right-click only triggers once (placement/secondary actions)
			if event.pressed:
				var item = hotbar.get_selected_item()
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
		if combat_system and combat_system.has_method("handle_primary"):
			combat_system.handle_primary(item)

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
		var category = item.get("category", 0)
		
		# TERRAFORMER (shovel) - route to combat_system for fill action
		if category == 7:
			if combat_system and combat_system.has_method("handle_secondary"):
				combat_system.handle_secondary(item)
			return
		
		# VEHICLE (car keys) - spawn vehicle in front of player
		if category == 8:  # ItemCategory.VEHICLE
			print("[ItemUseRouter] Car Keys detected, spawning vehicle...")
			_spawn_vehicle(item)
			return
		
		# Other items - terrain interaction for bucket/resource placement
		if terrain_interaction and terrain_interaction.has_method("handle_secondary"):
			terrain_interaction.handle_secondary(item)
		elif combat_system and combat_system.has_method("handle_secondary"):
			combat_system.handle_secondary(item)

## Spawn vehicle from VEHICLE category item (Car Keys)
func _spawn_vehicle(item: Dictionary) -> void:
	var vehicle_scene_path = item.get("vehicle_scene", "")
	if vehicle_scene_path == "":
		print("ItemUseRouter: No vehicle_scene in item %s" % item.get("name", "unknown"))
		return
	
	# Find vehicle manager
	var vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	if not vehicle_manager:
		print("ItemUseRouter: No vehicle_manager found")
		return
	
	# Check if vehicle manager has method
	if not vehicle_manager.has_method("spawn_vehicle"):
		print("ItemUseRouter: vehicle_manager has no spawn_vehicle method")
		return
	
	# Spawn in front of player
	if player:
		var spawn_pos = player.global_position + player.global_basis.z * -3.0
		var v = vehicle_manager.spawn_vehicle(spawn_pos)
		if has_node("/root/PlayerSignals"):
			PlayerSignals.vehicle_spawned.emit()
		print("[ItemUseRouter] Spawned vehicle from Car Keys at %s" % v.global_position)
