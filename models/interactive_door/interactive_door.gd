extends Node3D
class_name InteractiveDoor

## Interactive door that can be opened/closed with E key
## Uses collision shapes defined in the scene:
## - "opened door collision layer" - Blocking collision (toggles on/off)
## - "door interaction layer" - Interaction Area3D (always on for raycast detection)

@export var is_open: bool = false

var animation_player: AnimationPlayer = null
var door_static_body: StaticBody3D = null
var door_collision: CollisionShape3D = null
var interaction_area: Area3D = null
var interaction_collision: CollisionShape3D = null

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
	
	# Setup collision using scene-defined shapes
	_setup_door_collision()
	_setup_interaction_area()
	
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

## Find the "closed door collision layer" from scene and wrap it in a StaticBody3D
func _setup_door_collision():
	# Find the existing collision shape from the scene (blocks player when door is closed)
	var existing_shape = _find_node_by_name(self, "closed door collision layer")
	
	if existing_shape and existing_shape is CollisionShape3D:
		door_collision = existing_shape
		
		# Create StaticBody3D to be the parent
		door_static_body = StaticBody3D.new()
		door_static_body.name = "DoorBlocker"
		door_static_body.add_to_group("placed_objects")
		
		# Store original parent and transform
		var original_parent = door_collision.get_parent()
		var global_xform = door_collision.global_transform
		
		# Reparent: remove from old parent
		original_parent.remove_child(door_collision)
		
		# Add StaticBody to the door root
		add_child(door_static_body)
		
		# Add collision shape to StaticBody
		door_static_body.add_child(door_collision)
		
		# Restore global transform
		door_collision.global_transform = global_xform
		
		print("Door: Using scene-defined blocking collision")
	else:
		print("Door: WARNING - 'opened door collision layer' not found in scene!")

## Find the "door interaction layer" from scene and wrap it in an Area3D
func _setup_interaction_area():
	# Find the existing collision shape from the scene
	var existing_shape = _find_node_by_name(self, "door interaction layer")
	
	if existing_shape and existing_shape is CollisionShape3D:
		interaction_collision = existing_shape
		
		# Create Area3D for interaction detection
		interaction_area = Area3D.new()
		interaction_area.name = "InteractionArea"
		interaction_area.add_to_group("interactable")
		interaction_area.add_to_group("placed_objects")
		interaction_area.set_meta("door", self)
		
		# Store original parent and transform
		var original_parent = interaction_collision.get_parent()
		var global_xform = interaction_collision.global_transform
		
		# Reparent: remove from old parent
		original_parent.remove_child(interaction_collision)
		
		# Add Area3D to the door root
		add_child(interaction_area)
		
		# Add collision shape to Area3D
		interaction_area.add_child(interaction_collision)
		
		# Restore global transform
		interaction_collision.global_transform = global_xform
		
		print("Door: Using scene-defined interaction area")
	else:
		print("Door: WARNING - 'door interaction layer' not found in scene!")

## Recursively find a node by name
func _find_node_by_name(root: Node, target_name: String) -> Node:
	if root.name == target_name:
		return root
	for child in root.get_children():
		var found = _find_node_by_name(child, target_name)
		if found:
			return found
	return null

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
