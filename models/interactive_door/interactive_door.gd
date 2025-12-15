extends Node3D
class_name InteractiveDoor

## Interactive door that can be opened/closed with E key
## Requires AnimationPlayer child from GLB with animations:
##   - HN_Door_Open
##   - HN_Door_Close
##   - HN_Door_Open_Idle

@export var is_open: bool = false

var animation_player: AnimationPlayer = null

func _ready():
	# Add to interactable group for player detection
	add_to_group("interactable")
	add_to_group("placed_objects")
	
	# Find AnimationPlayer in the door model
	_find_animation_player(self)
	
	if animation_player:
		print("Door: Found AnimationPlayer with animations: ", animation_player.get_animation_list())
	else:
		print("Door: No AnimationPlayer found!")

func _find_animation_player(node: Node):
	if node is AnimationPlayer:
		animation_player = node
		return
	for child in node.get_children():
		if animation_player:
			return
		_find_animation_player(child)

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
	print("Door opened")

func close_door():
	if animation_player and animation_player.has_animation("HN_Door_Close"):
		animation_player.play("HN_Door_Close")
	is_open = false
	print("Door closed")

## Get interaction prompt text for UI
func get_interaction_prompt() -> String:
	if is_open:
		return "Press E to close"
	else:
		return "Press E to open"
