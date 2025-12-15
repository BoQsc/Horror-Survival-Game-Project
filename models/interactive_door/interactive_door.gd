extends Node3D
class_name InteractiveDoor

## Interactive door that can be opened/closed with E key
## Has two collision types:
## 1. Blocking collision - toggles on/off to block/allow player passage
## 2. Interaction Area3D - always on for raycast detection

@export var is_open: bool = false

var animation_player: AnimationPlayer = null
var door_static_body: StaticBody3D = null
var door_collision: CollisionShape3D = null
var interaction_area: Area3D = null

func _ready():
	# Add to interactable group for player detection (also tells building_chunk to skip collision)
	add_to_group("interactable")
	add_to_group("placed_objects")
	
	# Find AnimationPlayer in the door model
	_find_animation_player(self)
	
	if animation_player:
		print("Door: Found AnimationPlayer with animations: ", animation_player.get_animation_list())
	else:
		print("Door: No AnimationPlayer found!")
	
	# Create collision shapes
	_create_door_collision()
	_create_interaction_area()
	
	# Set initial collision state
	_set_collision_enabled(not is_open)

func _find_animation_player(node: Node):
	if node is AnimationPlayer:
		animation_player = node
		return
	for child in node.get_children():
		if animation_player:
			return
		_find_animation_player(child)

## Create a box collision shape for blocking the player (toggleable)
func _create_door_collision():
	door_static_body = StaticBody3D.new()
	door_static_body.name = "DoorBlocker"
	door_static_body.add_to_group("placed_objects")
	
	door_collision = CollisionShape3D.new()
	# Door size: 1 wide, 2 tall, 0.2 deep
	var box = BoxShape3D.new()
	box.size = Vector3(1.0, 2.0, 0.2)
	door_collision.shape = box
	door_collision.position = Vector3(0.0, 1.0, 0.0)
	
	door_static_body.add_child(door_collision)
	add_child(door_static_body)
	
	print("Door: Created blocking collision")

## Create an Area3D for interaction detection (always active)
func _create_interaction_area():
	interaction_area = Area3D.new()
	interaction_area.name = "InteractionArea"
	interaction_area.add_to_group("interactable")
	interaction_area.add_to_group("placed_objects")
	# Store reference to this door for interaction
	interaction_area.set_meta("door", self)
	
	var collision = CollisionShape3D.new()
	# Slightly larger than the door for easy targeting
	var box = BoxShape3D.new()
	box.size = Vector3(1.2, 2.2, 0.4)
	collision.shape = box
	collision.position = Vector3(0.0, 1.0, 0.0)
	
	interaction_area.add_child(collision)
	add_child(interaction_area)
	
	print("Door: Created interaction area")

## Enable or disable door blocking collision (not interaction area)
func _set_collision_enabled(enabled: bool):
	if door_collision:
		door_collision.disabled = not enabled
		print("Door blocking collision: %s" % ("enabled" if enabled else "disabled"))

## Called when player presses E while looking at this door
func interact():
	if is_open:
		close_door()
	else:
		open_door()

func open_door():
	if animation_player and animation_player.has_animation("HN_Door_Open"):
		animation_player.play("HN_Door_Open")
	is_open = true
	_set_collision_enabled(false)  # Disable blocking collision when open
	print("Door opened")

func close_door():
	if animation_player and animation_player.has_animation("HN_Door_Close"):
		animation_player.play("HN_Door_Close")
	is_open = false
	_set_collision_enabled(true)  # Enable blocking collision when closed
	print("Door closed")

## Get interaction prompt text for UI
func get_interaction_prompt() -> String:
	if is_open:
		return "Press E to close"
	else:
		return "Press E to open"
