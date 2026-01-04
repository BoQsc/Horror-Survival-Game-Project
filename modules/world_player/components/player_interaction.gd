extends Node
class_name PlayerInteraction
## PlayerInteraction - Handles E key interactions (global in all modes)
## Doors, vehicles, pickups, barricading

# References
var player: WorldPlayer = null
var hotbar: Node = null
var inventory: Node = null

# Manager references
var building_manager: Node = null
var vehicle_manager: Node = null
var entity_manager: Node = null

# Interaction state
var current_target: Node = null
var current_prompt: String = ""
var is_holding_e: bool = false
var hold_time: float = 0.0
const BARRICADE_HOLD_TIME: float = 1.0 # Seconds to hold for barricade

# Vehicle state (legacy port)
var is_in_vehicle: bool = false
var current_vehicle: Node3D = null
var terrain_manager: Node = null

func _ready() -> void:
	# Find player
	player = get_parent().get_parent() as WorldPlayer
	
	# Find hotbar
	hotbar = get_node_or_null("../../Systems/Hotbar")
	
	# Find inventory (robust search)
	inventory = get_node_or_null("../../Systems/Inventory")
	if not inventory:
		inventory = get_tree().get_first_node_in_group("inventory")
	if not inventory:
		inventory = get_parent().get_parent().find_child("Inventory", true, false)
		
	if inventory:
		DebugManager.log_player("PlayerInteraction: Found Inventory")
	else:
		DebugManager.log_player("PlayerInteraction: CRITICAL - Inventory not found!")
	
	# Find managers via groups
	await get_tree().process_frame
	building_manager = get_tree().get_first_node_in_group("building_manager")
	vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	entity_manager = get_tree().get_first_node_in_group("entity_manager")
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	DebugManager.log_player("PlayerInteraction: Initialized")

func _process(delta: float) -> void:
	# Check for interactable target
	_update_interaction_target()
	
	# Handle E key hold for barricade
	if is_holding_e:
		hold_time += delta
		if hold_time >= BARRICADE_HOLD_TIME and current_target:
			_do_barricade()
			is_holding_e = false
			hold_time = 0.0

func _input(event: InputEvent) -> void:
	# Handle E key while in vehicle - exit only
	if is_in_vehicle:
		if event is InputEventKey and event.pressed and event.keycode == KEY_E:
			_exit_vehicle()
		return
	
	if event is InputEventKey:
		if event.keycode == KEY_E:
			if event.pressed and not event.echo:
				is_holding_e = true
				hold_time = 0.0
			elif not event.pressed:
				# Released E
				if hold_time < BARRICADE_HOLD_TIME and current_target:
					_do_interaction()
				is_holding_e = false
				hold_time = 0.0

## Update interaction target based on what player is looking at
## Ported from legacy player_interaction.gd _check_interaction_target()
func _update_interaction_target() -> void:
	if not player:
		return
	
	# Use 5.0 range (legacy used 5.0 with Area3D support)
	var hit = player.raycast(5.0)
	
	if hit.is_empty():
		_clear_target()
		return
	
	var collider = hit.get("collider")
	if not collider:
		_clear_target()
		return
	
	# Check if we hit a collider with a door reference (doors with mesh collisions)
	if collider.has_meta("door"):
		var door = collider.get_meta("door")
		if door and door.is_in_group("interactable"):
			_set_target(door)
			return
	
	# Walk up the tree to find an interactable parent (legacy tree traversal)
	var node = collider
	while node:
		if node.is_in_group("interactable") or node.is_in_group("vehicle"):
			_set_target(node)
			return
		node = node.get_parent()
	
	# No interactable found
	_clear_target()

## Set interaction target and get prompt
func _set_target(target: Node) -> void:
	if target == current_target:
		return
	
	current_target = target
	
	# Get prompt from object if it has the method (legacy approach)
	if target.has_method("get_interaction_prompt"):
		current_prompt = target.get_interaction_prompt()
	elif target.is_in_group("vehicle"):
		current_prompt = "[E] Enter Vehicle"
	else:
		current_prompt = "[E] Interact"
	
	PlayerSignals.interaction_available.emit(current_target, current_prompt)

func _clear_target() -> void:
	if current_target != null:
		current_target = null
		current_prompt = ""
		PlayerSignals.interaction_unavailable.emit()

## Determine what interaction prompt to show for a target
func _get_interaction_prompt(target: Node) -> String:
	if not target:
		return ""
	
	# Doors
	if target.is_in_group("doors"):
		var is_open = target.get("is_open") if target.has_method("get") else false
		# Check if we're holding an item for barricade
		if hotbar:
			var item = hotbar.get_selected_item()
			var category = item.get("category", 0)
			if category in [5, 6]: # OBJECT or PROP
				return "[Hold E] Barricade"
		return "[E] Open" if not is_open else "[E] Close"
	
	# Windows
	if target.is_in_group("windows"):
		if hotbar:
			var item = hotbar.get_selected_item()
			var category = item.get("category", 0)
			if category in [5, 6]:
				return "[Hold E] Barricade"
		return "[E] Interact"
	
	# Vehicles
	if target.is_in_group("vehicles"):
		return "[E] Enter"
	
	# Pickups (props on ground that can be picked up)
	var is_physics_prop = (target is RigidBody3D and target.is_in_group("interactable") and not target.is_in_group("vehicle"))
	if target.is_in_group("pickups") or target.is_in_group("props") or target.is_in_group("pickup_items") or target.has_meta("item_data") or is_physics_prop:
		return "[E] Pick up"
	
	# Generic interactables
	if target.is_in_group("interactable"):
		return "[E] Interact"
	
	return ""

## Perform the standard interaction
func _do_interaction() -> void:
	if not current_target:
		return
	
	DebugManager.log_player("PlayerInteraction: Interacting with %s" % current_target.name)
	
	# Vehicles (check first - legacy priority)
	if current_target.is_in_group("vehicle"):
		_enter_vehicle(current_target)
		return
	
	# Generic interactables (doors, etc.) - legacy uses interact() method
	if current_target.has_method("interact"):
		current_target.interact()
		PlayerSignals.interaction_performed.emit(current_target, "interact")
		return
	
	# Pickups (or physics props like pistols)
	var is_physics_prop = (current_target is RigidBody3D and current_target.is_in_group("interactable") and not current_target.is_in_group("vehicle"))
	if current_target.is_in_group("pickups") or current_target.is_in_group("props") or current_target.is_in_group("pickup_items") or current_target.has_meta("item_data") or is_physics_prop:
		_pickup_item(current_target)
		return
	
	# Fallback for objects without interact method
	DebugManager.log_player("PlayerInteraction: No interact method on %s" % current_target.name)

## Pick up an item/prop into inventory
func _pickup_item(target: Node) -> void:
	if not target:
		return
	
	# Get item data from target
	var item_data: Dictionary = {}
	
	if target.has_method("get_item_data"):
		item_data = target.get_item_data()
	elif target.has_meta("item_data"):
		item_data = target.get_meta("item_data")
	else:
		# Create generic item from object
		# RESTORING FIX: Check for known physics props (Pistol) and inject scene path
		var target_name = target.name.to_lower()
		var item_scene = ""
		var friendly_name = target.name
		var item_id = target_name
		
		if "pistol" in target_name:
			item_data = ItemDefinitions.get_heavy_pistol_definition()
		
		# Fallback if not identified above
		if item_data.is_empty():
			item_data = {
				"id": item_id,
				"name": friendly_name,
				"category": 6, # PROP
				"stack_size": 16,
				"scene": item_scene
			}
			if item_scene != "":
				item_data["stack_size"] = 1 # Props usually don't stack well
		
		if item_scene != "":
			item_data["stack_size"] = 1 # Props usually don't stack well
	
	# Add to hotbar first, then inventory
	var hotbar_node = get_node_or_null("../../Systems/Hotbar")
	var inventory = get_node_or_null("../../Systems/Inventory")
	var added = false
	
	# Try hotbar first
	if hotbar_node:
		# Check for preferred slot (from drop)
		var preferred_slot = -1
		if "preferred_slot" in target:
			preferred_slot = target.preferred_slot
		elif target.has_meta("preferred_slot"):
			preferred_slot = target.get_meta("preferred_slot")
			
		if preferred_slot >= 0 and hotbar_node.has_method("get_count_at") and hotbar_node.has_method("set_item_at"):
			# Try to put back in same slot if empty
			if hotbar_node.get_count_at(preferred_slot) == 0:
				hotbar_node.set_item_at(preferred_slot, item_data, 1)
				added = true
				DebugManager.log_player("PlayerInteraction: Returned to preferred slot %d" % preferred_slot)
		
		# Fallback to generic add if not added to preferred
		if not added and hotbar_node.has_method("add_item"):
			if hotbar_node.add_item(item_data):
				added = true
				DebugManager.log_player("PlayerInteraction: Added to hotbar")
	
	# Fallback to inventory
	if not added:
		if inventory and inventory.has_method("add_item"):
			var leftover = inventory.add_item(item_data, 1)
			if leftover == 0:
				added = true
				DebugManager.log_player("PlayerInteraction: Added to inventory")
			else:
				DebugManager.log_player("PlayerInteraction: Inventory full (leftover: %d)" % leftover)
		else:
			DebugManager.log_player("PlayerInteraction: Inventory missing or invalid")
	
	if added:
		# Successfully picked up - remove from world
		target.queue_free()
		PlayerSignals.interaction_performed.emit(target, "pickup")
	else:
		DebugManager.log_player("PlayerInteraction: Could not pick up (Hotbar/Inventory full)")

## Perform barricade action (hold E near door/window with item)
func _do_barricade() -> void:
	if not current_target or not hotbar or not building_manager:
		return
	
	var item = hotbar.get_selected_item()
	var category = item.get("category", 0)
	
	if category not in [5, 6]: # OBJECT or PROP
		return
	
	# Get target position (near the door/window)
	var target_pos = current_target.global_position
	var object_id = item.get("object_id", 1)
	
	# Place the item as close as possible to the opening
	if building_manager.has_method("place_object"):
		var success = building_manager.place_object(target_pos, object_id, 0)
		if success:
			DebugManager.log_player("PlayerInteraction: Barricaded with %s" % item.get("name", "object"))
			PlayerSignals.interaction_performed.emit(current_target, "barricade")
			# TODO: Remove item from hotbar
		else:
			DebugManager.log_player("PlayerInteraction: Could not place barricade")

## Enter a vehicle (ported from legacy player_interaction.gd)
func _enter_vehicle(vehicle: Node3D) -> void:
	if not vehicle or not vehicle.has_method("enter_vehicle"):
		DebugManager.log_player("PlayerInteraction: Vehicle has no enter_vehicle method")
		return
	
	DebugManager.log_player("[Vehicle] Entering vehicle")
	is_in_vehicle = true
	current_vehicle = vehicle
	
	# Tell vehicle player is entering
	vehicle.enter_vehicle(player)
	
	# Disable player CharacterBody3D movement and hide it
	player.process_mode = Node.PROCESS_MODE_DISABLED
	player.visible = false
	
	# Keep this controller active so we can still receive input to exit
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	# Enable vehicle camera
	if vehicle.has_method("set_camera_active"):
		vehicle.set_camera_active(true)
	
	# Track in vehicle manager
	if vehicle_manager and "current_player_vehicle" in vehicle_manager:
		vehicle_manager.current_player_vehicle = vehicle
		if vehicle_manager.has_signal("player_entered_vehicle"):
			vehicle_manager.player_entered_vehicle.emit(vehicle)
	
	# Switch terrain generation to follow the vehicle
	if terrain_manager and "viewer" in terrain_manager:
		terrain_manager.viewer = vehicle
		DebugManager.log_player("[Interaction] Switched terrain viewer to Vehicle")
	
	PlayerSignals.interaction_performed.emit(vehicle, "enter_vehicle")

## Exit current vehicle (ported from legacy player_interaction.gd)
func _exit_vehicle() -> void:
	if not is_in_vehicle or not current_vehicle:
		return
	
	DebugManager.log_player("[Vehicle] Exiting vehicle")
	
	# Tell vehicle player is exiting
	if current_vehicle.has_method("exit_vehicle"):
		current_vehicle.exit_vehicle()
	
	# Re-enable player
	player.process_mode = Node.PROCESS_MODE_INHERIT
	player.visible = true
	
	# Position player near vehicle
	if current_vehicle:
		player.global_position = current_vehicle.global_position + Vector3(2, 1, 0)
	
	# Disable vehicle camera
	if current_vehicle.has_method("set_camera_active"):
		current_vehicle.set_camera_active(false)
	
	# Update vehicle manager
	if vehicle_manager and "current_player_vehicle" in vehicle_manager:
		vehicle_manager.current_player_vehicle = null
		if vehicle_manager.has_signal("player_exited_vehicle"):
			vehicle_manager.player_exited_vehicle.emit(current_vehicle)
	
	# Switch terrain generation back to player
	if terrain_manager and "viewer" in terrain_manager:
		terrain_manager.viewer = player
		DebugManager.log_player("[Interaction] Switched terrain viewer back to Player")
	
	is_in_vehicle = false
	current_vehicle = null
	
	PlayerSignals.interaction_performed.emit(null, "exit_vehicle")
