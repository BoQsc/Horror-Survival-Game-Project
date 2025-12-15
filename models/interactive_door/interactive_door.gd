extends Node3D
class_name InteractiveDoor

## Interactive door that can be opened/closed with E key
## Uses collision shapes defined in the scene:
## - "closed door collision layer" - Blocking collision when door is CLOSED
## - "opened door collision layer" - Blocking collision when door is OPEN (swung position)
## - "door interaction layer" - Interaction Area3D (always on for raycast detection)

@export var is_open: bool = false

var animation_player: AnimationPlayer = null

# Closed door blocking collision
var closed_static_body: StaticBody3D = null
var closed_collision: CollisionShape3D = null

# Opened door blocking collision
var opened_static_body: StaticBody3D = null
var opened_collision: CollisionShape3D = null

# Interaction area
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
	_setup_closed_collision()
	_setup_opened_collision()
	_setup_interaction_area()
	
	# Set initial collision state (door starts closed)
	_update_collision_states()

func _find_animation_player(node: Node):
	if node is AnimationPlayer:
		animation_player = node
		return
	for child in node.get_children():
		if animation_player:
			return
		_find_animation_player(child)

## Find the "closed door collision layer" from scene and wrap it in a StaticBody3D
func _setup_closed_collision():
	var existing_shape = _find_node_by_name(self, "closed door collision layer")
	
	if existing_shape and existing_shape is CollisionShape3D:
		closed_collision = existing_shape
		
		# Create StaticBody3D to be the parent
		closed_static_body = StaticBody3D.new()
		closed_static_body.name = "ClosedDoorBlocker"
		closed_static_body.add_to_group("placed_objects")
		
		# Store original parent and transform
		var original_parent = closed_collision.get_parent()
		var global_xform = closed_collision.global_transform
		
		# Reparent: remove from old parent
		original_parent.remove_child(closed_collision)
		
		# Add StaticBody to the door root
		add_child(closed_static_body)
		
		# Add collision shape to StaticBody
		closed_static_body.add_child(closed_collision)
		
		# Restore global transform
		closed_collision.global_transform = global_xform
		
		print("Door: Using scene-defined CLOSED collision")
	else:
		print("Door: WARNING - 'closed door collision layer' not found in scene!")

## Find the "opened door collision layer" from scene and wrap it in a StaticBody3D
func _setup_opened_collision():
	var existing_shape = _find_node_by_name(self, "opened door collision layer")
	
	if existing_shape and existing_shape is CollisionShape3D:
		opened_collision = existing_shape
		
		# Create StaticBody3D to be the parent
		opened_static_body = StaticBody3D.new()
		opened_static_body.name = "OpenedDoorBlocker"
		opened_static_body.add_to_group("placed_objects")
		
		# Store original parent and transform
		var original_parent = opened_collision.get_parent()
		var global_xform = opened_collision.global_transform
		
		# Reparent: remove from old parent
		original_parent.remove_child(opened_collision)
		
		# Add StaticBody to the door root
		add_child(opened_static_body)
		
		# Add collision shape to StaticBody
		opened_static_body.add_child(opened_collision)
		
		# Restore global transform
		opened_collision.global_transform = global_xform
		
		print("Door: Using scene-defined OPENED collision")
	else:
		print("Door: WARNING - 'opened door collision layer' not found in scene!")

## Find the "door interaction layer" from scene and wrap it in an Area3D
func _setup_interaction_area():
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

## Update both collision states based on is_open
func _update_collision_states():
	# Closed collision: enabled when door is CLOSED
	if closed_collision:
		closed_collision.disabled = is_open
		print("Door CLOSED collision: %s" % ("disabled" if is_open else "enabled"))
	
	# Opened collision: enabled when door is OPEN
	if opened_collision:
		opened_collision.disabled = not is_open
		print("Door OPENED collision: %s" % ("enabled" if is_open else "disabled"))

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
	_update_collision_states()
	print("Door opened")

func close_door():
	if animation_player and animation_player.has_animation("HN_Door_Close"):
		animation_player.play("HN_Door_Close")
	is_open = false
	_update_collision_states()
	print("Door closed")

## Get interaction prompt text for UI
func get_interaction_prompt() -> String:
	if is_open:
		return "Press E to close"
	else:
		return "Press E to open"

