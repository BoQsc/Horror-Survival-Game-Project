extends Node
class_name PlayerInteraction
## PlayerInteraction - Handles E key interactions (global in all modes)
## Doors, vehicles, pickups, barricading

# References
var player: WorldPlayer = null
var hotbar: Node = null

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

func _ready() -> void:
	# Find player
	player = get_parent().get_parent() as WorldPlayer
	
	# Find hotbar
	hotbar = get_node_or_null("../../Systems/Hotbar")
	
	# Find managers via groups
	await get_tree().process_frame
	building_manager = get_tree().get_first_node_in_group("building_manager")
	vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	entity_manager = get_tree().get_first_node_in_group("entity_manager")
	
	print("PlayerInteraction: Initialized")

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
func _update_interaction_target() -> void:
	if not player:
		return
	
	var hit = player.raycast(3.0) # Interaction range
	
	if hit.is_empty():
		_clear_target()
		return
	
	var target = hit.get("collider")
	if not target:
		_clear_target()
		return
	
	# Determine interaction prompt
	var prompt = _get_interaction_prompt(target)
	
	if prompt.is_empty():
		_clear_target()
		return
	
	# Only emit if target/prompt changed
	if target != current_target or prompt != current_prompt:
		current_target = target
		current_prompt = prompt
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
	if target.is_in_group("pickups") or target.is_in_group("props"):
		return "[E] Take"
	
	# Generic interactables
	if target.is_in_group("interactable"):
		return "[E] Interact"
	
	return ""

## Perform the standard interaction
func _do_interaction() -> void:
	if not current_target:
		return
	
	print("PlayerInteraction: Interacting with %s" % current_target.name)
	
	# Doors
	if current_target.is_in_group("doors"):
		if current_target.has_method("toggle"):
			current_target.toggle()
		elif current_target.has_method("interact"):
			current_target.interact()
		PlayerSignals.interaction_performed.emit(current_target, "toggle_door")
		return
	
	# Vehicles
	if current_target.is_in_group("vehicles"):
		if vehicle_manager and vehicle_manager.has_method("enter_vehicle"):
			vehicle_manager.enter_vehicle(current_target)
		elif current_target.has_method("enter"):
			current_target.enter(player)
		PlayerSignals.interaction_performed.emit(current_target, "enter_vehicle")
		return
	
	# Pickups
	if current_target.is_in_group("pickups") or current_target.is_in_group("props"):
		_pickup_item(current_target)
		return
	
	# Generic
	if current_target.has_method("interact"):
		current_target.interact()
		PlayerSignals.interaction_performed.emit(current_target, "interact")

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
		item_data = {
			"id": target.name.to_lower(),
			"name": target.name,
			"category": 6, # PROP
			"stack_size": 16
		}
	
	# Add to inventory
	var inventory = get_node_or_null("../../Systems/Inventory")
	if inventory and inventory.has_method("add_item"):
		var leftover = inventory.add_item(item_data, 1)
		if leftover == 0:
			# Successfully picked up - remove from world
			target.queue_free()
			print("PlayerInteraction: Picked up %s" % item_data.get("name", target.name))
			PlayerSignals.interaction_performed.emit(target, "pickup")
		else:
			print("PlayerInteraction: Inventory full!")
	else:
		print("PlayerInteraction: No inventory system found")

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
			print("PlayerInteraction: Barricaded with %s" % item.get("name", "object"))
			PlayerSignals.interaction_performed.emit(current_target, "barricade")
			# TODO: Remove item from hotbar
		else:
			print("PlayerInteraction: Could not place barricade")
