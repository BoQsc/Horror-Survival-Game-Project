extends Node
class_name PlayerInteractionV2
## PlayerInteraction - Handles E key interactions (global in all modes)
## Doors, vehicles, pickups, barricading

var player: Node = null
var hotbar: Node = null
var inventory: Node = null

var building_manager: Node = null
var vehicle_manager: Node = null
var entity_manager: Node = null

var current_target: Node = null
var current_prompt: String = ""
var is_holding_e: bool = false
var hold_time: float = 0.0
const BARRICADE_HOLD_TIME: float = 1.0
const VEHICLE_RADIAL_HOLD_TIME: float = 0.3  # Time to hold E to open radial menu

var is_in_vehicle: bool = false
var current_vehicle: Node3D = null
var terrain_manager: Node = null

# Radial menu for vehicle options
var radial_menu: Control = null
var radial_menu_open: bool = false

# V2 local path for ItemDefinitions
const ItemDefs = preload("res://modules/world_player_v2/features/data_inventory/item_definitions.gd")
const RadialMenuScript = preload("res://modules/world_player_v2/features/tool_interaction/radial_menu.gd")

func _ready() -> void:
	player = get_parent().get_parent()
	
	hotbar = get_node_or_null("../../Systems/Hotbar")
	
	inventory = get_node_or_null("../../Systems/Inventory")
	if not inventory:
		inventory = get_tree().get_first_node_in_group("inventory")
	if not inventory and player:
		inventory = player.find_child("Inventory", true, false)
	
	await get_tree().process_frame
	building_manager = get_tree().get_first_node_in_group("building_manager")
	vehicle_manager = get_tree().get_first_node_in_group("vehicle_manager")
	entity_manager = get_tree().get_first_node_in_group("entity_manager")
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	# Create radial menu
	_setup_radial_menu()

func _setup_radial_menu() -> void:
	radial_menu = RadialMenuScript.new()
	radial_menu.name = "RadialMenu"
	
	# Add to player HUD
	var hud = get_tree().get_first_node_in_group("player_hud")
	if hud:
		hud.add_child(radial_menu)
	else:
		# Fallback: add to CanvasLayer or root
		var canvas = player.find_child("PlayerHUD", true, false)
		if canvas:
			canvas.add_child(radial_menu)
	
	# Connect signals
	radial_menu.option_selected.connect(_on_radial_option_selected)
	radial_menu.menu_cancelled.connect(_on_radial_menu_cancelled)

func _process(delta: float) -> void:
	if radial_menu_open:
		return  # Don't update targets while radial menu is open
	
	# Sync player position to vehicle while inside (so zombies track correctly)
	if is_in_vehicle and current_vehicle and player:
		player.global_position = current_vehicle.global_position
	
	_update_interaction_target()
	
	if is_holding_e:
		hold_time += delta
		
		# Vehicle-specific: show radial menu after short hold
		if current_target and current_target.is_in_group("vehicle"):
			if hold_time >= VEHICLE_RADIAL_HOLD_TIME:
				_show_vehicle_radial_menu(current_target)
				is_holding_e = false
				hold_time = 0.0
		# Non-vehicle: barricade after long hold
		elif hold_time >= BARRICADE_HOLD_TIME and current_target:
			_do_barricade()
			is_holding_e = false
			hold_time = 0.0

func _input(event: InputEvent) -> void:
	# Handle radial menu exit
	if radial_menu_open:
		if event is InputEventKey and event.keycode == KEY_E and not event.pressed:
			radial_menu.hide_menu(true)  # Emit selection
			radial_menu_open = false
		return
	
	if is_in_vehicle:
		if event is InputEventKey and event.pressed and event.keycode == KEY_E:
			_exit_vehicle()
		return
	
	# Skip E key processing if container UI is open or was just closed
	var container_panel = get_tree().get_first_node_in_group("container_panel")
	if container_panel and (container_panel.visible or container_panel.just_closed):
		return
	
	if event is InputEventKey:
		if event.keycode == KEY_E:
			if event.pressed and not event.echo:
				is_holding_e = true
				hold_time = 0.0
			elif not event.pressed:
				# On release: if short tap on vehicle, enter directly
				if current_target and current_target.is_in_group("vehicle"):
					if hold_time < VEHICLE_RADIAL_HOLD_TIME:
						_enter_vehicle(current_target)
				elif hold_time < BARRICADE_HOLD_TIME and current_target:
					_do_interaction()
				is_holding_e = false
				hold_time = 0.0

func _update_interaction_target() -> void:
	if not player or not player.has_method("raycast"):
		return
	
	var hit = player.raycast(5.0)
	
	if hit.is_empty():
		_clear_target()
		return
	
	var collider = hit.get("collider")
	if not collider:
		_clear_target()
		return
	
	if collider.has_meta("door"):
		var door = collider.get_meta("door")
		if door and door.is_in_group("interactable"):
			_set_target(door)
			return
	
	var node = collider
	while node:
		if node.is_in_group("interactable") or node.is_in_group("vehicle"):
			_set_target(node)
			return
		node = node.get_parent()
	
	_clear_target()

func _set_target(target: Node) -> void:
	if target == current_target:
		return
	
	current_target = target
	
	if target.has_method("get_interaction_prompt"):
		current_prompt = target.get_interaction_prompt()
	elif target.is_in_group("vehicle"):
		current_prompt = "[E] Enter Vehicle"
	else:
		current_prompt = "[E] Interact"
	
	if has_node("/root/PlayerSignals"):
		PlayerSignals.interaction_available.emit(current_target, current_prompt)

func _clear_target() -> void:
	if current_target != null:
		current_target = null
		current_prompt = ""
		if has_node("/root/PlayerSignals"):
			PlayerSignals.interaction_unavailable.emit()

func _do_interaction() -> void:
	if not current_target:
		return
	
	if current_target.is_in_group("vehicle"):
		_enter_vehicle(current_target)
		return
	
	if current_target.has_method("interact"):
		current_target.interact()
		if has_node("/root/PlayerSignals"):
			PlayerSignals.interaction_performed.emit(current_target, "interact")
		return
	
	var is_physics_prop = (current_target is RigidBody3D and current_target.is_in_group("interactable") and not current_target.is_in_group("vehicle"))
	if current_target.is_in_group("pickups") or current_target.is_in_group("props") or current_target.is_in_group("pickup_items") or current_target.has_meta("item_data") or is_physics_prop:
		_pickup_item(current_target)
		return

func _pickup_item(target: Node) -> void:
	if not target:
		return
	
	var item_data: Dictionary = {}
	var item_count: int = 1  # Default to 1 if not specified
	
	# Get item data
	if target.has_method("get_item_data"):
		item_data = target.get_item_data()
	elif target.has_meta("item_data"):
		item_data = target.get_meta("item_data")
	else:
		var target_name = target.name.to_lower()
		
		if "pistol" in target_name:
			item_data = ItemDefs.get_heavy_pistol_definition()
		
		if item_data.is_empty():
			item_data = {
				"id": target_name,
				"name": target.name,
				"category": 6, # PROP
				"stack_size": 16,
				"scene": ""
			}
	
	# Get item count from target (PickupItem has item_count property)
	if "item_count" in target:
		item_count = target.item_count
	elif target.has_meta("item_count"):
		item_count = target.get_meta("item_count")
	
	var hotbar_node = get_node_or_null("../../Systems/Hotbar")
	var inv = get_node_or_null("../../Systems/Inventory")
	var remaining = item_count
	
	# Try to add to hotbar first
	if hotbar_node:
		var preferred_slot = -1
		if "preferred_slot" in target:
			preferred_slot = target.preferred_slot
		elif target.has_meta("preferred_slot"):
			preferred_slot = target.get_meta("preferred_slot")
		
		# Try preferred slot first
		if preferred_slot >= 0 and hotbar_node.has_method("get_count_at") and hotbar_node.has_method("set_item_at"):
			if hotbar_node.get_count_at(preferred_slot) == 0:
				hotbar_node.set_item_at(preferred_slot, item_data, 1)
				remaining -= 1
		
		# Add remaining to hotbar one at a time
		if hotbar_node.has_method("add_item"):
			while remaining > 0:
				if hotbar_node.add_item(item_data):
					remaining -= 1
				else:
					break  # Hotbar full
	
	# Add overflow to inventory
	if remaining > 0 and inv and inv.has_method("add_item"):
		var leftover = inv.add_item(item_data, remaining)
		remaining = leftover
	
	# Destroy target if we collected at least one item
	if remaining < item_count:
		# Play pickup sound
		_play_pickup_sound()
		
		if remaining <= 0:
			target.queue_free()
		elif "item_count" in target:
			target.item_count = remaining  # Update remaining count
		if has_node("/root/PlayerSignals"):
			PlayerSignals.interaction_performed.emit(target, "pickup")

func _play_pickup_sound() -> void:
	if not player:
		return
	
	var audio_player = AudioStreamPlayer3D.new()
	var sound = load("res://game/sound/player-pickup-item/item-equip-6904.mp3")
	
	if sound:
		audio_player.stream = sound
		audio_player.volume_db = 0.0
		audio_player.max_distance = 20.0
		player.add_child(audio_player)
		audio_player.play()
		
		# Auto-cleanup after sound finishes
		await audio_player.finished
		if is_instance_valid(audio_player):
			audio_player.queue_free()

func _do_barricade() -> void:
	if not current_target or not hotbar or not building_manager:
		return
	
	var item = hotbar.get_selected_item()
	var category = item.get("category", 0)
	
	if category not in [5, 6]:
		return
	
	var target_pos = current_target.global_position
	var object_id = item.get("object_id", 1)
	
	if building_manager.has_method("place_object"):
		var success = building_manager.place_object(target_pos, object_id, 0)
		if success and has_node("/root/PlayerSignals"):
			PlayerSignals.interaction_performed.emit(current_target, "barricade")

func _enter_vehicle(vehicle: Node3D) -> void:
	if not vehicle or not vehicle.has_method("enter_vehicle"):
		return
	
	is_in_vehicle = true
	current_vehicle = vehicle
	
	vehicle.enter_vehicle(player)
	
	player.process_mode = Node.PROCESS_MODE_DISABLED
	player.visible = false
	
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	if vehicle.has_method("set_camera_active"):
		vehicle.set_camera_active(true)
	
	if vehicle_manager and "current_player_vehicle" in vehicle_manager:
		vehicle_manager.current_player_vehicle = vehicle
		if vehicle_manager.has_signal("player_entered_vehicle"):
			vehicle_manager.player_entered_vehicle.emit(vehicle)
	
	if terrain_manager and "viewer" in terrain_manager:
		terrain_manager.viewer = vehicle
	
	if entity_manager and "viewer" in entity_manager:
		entity_manager.viewer = vehicle
	
	if has_node("/root/PlayerSignals"):
		PlayerSignals.interaction_performed.emit(vehicle, "enter_vehicle")

func _exit_vehicle() -> void:
	if not is_in_vehicle or not current_vehicle:
		return
	
	# Store reference and clear state FIRST to stop _process() position sync
	var exiting_vehicle = current_vehicle
	is_in_vehicle = false
	current_vehicle = null
	
	# === BULLETPROOF COLLISION PREVENTION ===
	# Add collision exception BEFORE enabling player physics
	# This guarantees 100% no collision between player and vehicle
	if player is PhysicsBody3D and exiting_vehicle is PhysicsBody3D:
		player.add_collision_exception_with(exiting_vehicle)
		exiting_vehicle.add_collision_exception_with(player)
	
	# Stop the vehicle FIRST (before player is positioned)
	if exiting_vehicle.has_method("exit_vehicle"):
		exiting_vehicle.exit_vehicle()
	
	# Calculate exit position BEFORE enabling physics
	var exit_pos: Vector3
	if exiting_vehicle.has_method("get_exit_position"):
		exit_pos = exiting_vehicle.get_exit_position()
	else:
		# Fallback: 4 meters to the left of vehicle (relative to vehicle orientation)
		var exit_offset = exiting_vehicle.global_transform.basis.x * -4.0
		exit_pos = exiting_vehicle.global_position + exit_offset + Vector3(0, 1.5, 0)
	
	# Set position BEFORE enabling physics (player still frozen at this point)
	player.global_position = exit_pos
	
	# Face the same direction as the vehicle (add PI to flip 180 degrees due to model orientation)
	player.rotation.y = exiting_vehicle.rotation.y + PI
	
	# NOW enable player physics (they are already at safe position with collision exception)
	player.process_mode = Node.PROCESS_MODE_INHERIT
	player.visible = true
	
	# Remove collision exception after physics frames ensure separation
	_remove_vehicle_collision_exception_deferred(exiting_vehicle)
	
	if exiting_vehicle.has_method("set_camera_active"):
		exiting_vehicle.set_camera_active(false)
	
	if vehicle_manager and "current_player_vehicle" in vehicle_manager:
		vehicle_manager.current_player_vehicle = null
		if vehicle_manager.has_signal("player_exited_vehicle"):
			vehicle_manager.player_exited_vehicle.emit(exiting_vehicle)
	
	if terrain_manager and "viewer" in terrain_manager:
		terrain_manager.viewer = player
	
	if entity_manager and "viewer" in entity_manager:
		entity_manager.viewer = player
	
	if has_node("/root/PlayerSignals"):
		PlayerSignals.interaction_performed.emit(null, "exit_vehicle")


## Remove collision exception after multiple physics frames to ensure safe separation
func _remove_vehicle_collision_exception_deferred(vehicle: Node3D) -> void:
	# Wait for 3 physics frames to ensure complete separation
	for i in range(3):
		await get_tree().physics_frame
	
	# Only remove if both still valid
	if is_instance_valid(player) and is_instance_valid(vehicle):
		if player is PhysicsBody3D and vehicle is PhysicsBody3D:
			player.remove_collision_exception_with(vehicle)
			vehicle.remove_collision_exception_with(player)


## Show radial menu for vehicle options
func _show_vehicle_radial_menu(vehicle: Node3D) -> void:
	if not radial_menu or radial_menu_open:
		return
	
	var options: Array[String] = ["Enter", "Pick Up", "Cancel"]
	radial_menu.show_menu(options, vehicle)
	radial_menu_open = true

## Handle radial menu selection
func _on_radial_option_selected(option: String) -> void:
	radial_menu_open = false
	var target = radial_menu.target_node
	
	match option:
		"Enter":
			if target and target.is_in_group("vehicle"):
				_enter_vehicle(target)
		"Pick Up":
			if target and target.is_in_group("vehicle"):
				_pickup_vehicle(target)
		"Cancel":
			print("[PlayerInteraction] Radial menu cancelled")

## Handle radial menu cancel
func _on_radial_menu_cancelled() -> void:
	radial_menu_open = false
	print("[PlayerInteraction] Radial menu cancelled")

## Pick up a vehicle (despawn and return Car Keys)
func _pickup_vehicle(vehicle: Node3D) -> void:
	if not vehicle_manager or not vehicle_manager.has_method("pickup_vehicle"):
		print("[PlayerInteraction] No vehicle_manager or pickup_vehicle method")
		return
	
	var success = vehicle_manager.pickup_vehicle(vehicle)
	if success:
		print("[PlayerInteraction] Vehicle picked up")
		# Optionally add Car Keys back to inventory
		# var car_keys = ItemDefs.get_car_keys_definition()
		# if hotbar and hotbar.has_method("add_item"):
		#     hotbar.add_item(car_keys)
