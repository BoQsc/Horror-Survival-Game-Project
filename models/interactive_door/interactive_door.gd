extends Node3D
class_name InteractiveDoor

## Interactive door that can be opened/closed with E key
## Uses scene-defined StaticBody3D collisions:
## - DoorCollider: Door panel (attached to bone, follows animation)
## - FrameCollider: Door frame (static)

@export var is_open: bool = false

# HP/Damage system
@export var max_hp: int = 15
var current_hp: int = -1

const DAMAGE_THRESHOLDS = [0.66, 0.33, 0.0]
var current_damage_stage: int = 0

var animation_player: AnimationPlayer = null

# Collision bodies (found from scene)
var door_static_body: StaticBody3D = null
var frame_static_body: StaticBody3D = null

func _ready():
	current_hp = max_hp
	
	add_to_group("interactable")
	add_to_group("placed_objects")
	add_to_group("breakable")
	
	_find_animation_player(self)
	
	if animation_player:
		print("[Door] Found AnimationPlayer: %s" % [animation_player.get_animation_list()])
	
	# Disable GLB auto-generated collisions first
	_disable_glb_collisions()
	
	# Find and configure scene-defined collisions
	_setup_collisions()

func _find_animation_player(node: Node):
	if node is AnimationPlayer:
		animation_player = node
		return
	for child in node.get_children():
		if animation_player:
			return
		_find_animation_player(child)

## Find and configure scene-defined StaticBody3D collisions
func _setup_collisions():
	var door_model = get_node_or_null("DoorModel")
	if not door_model:
		push_warning("[Door] DoorModel not found!")
		return
	
	# Find DoorCollider (attached to bone for animation)
	door_static_body = _find_node_by_name(door_model, "DoorCollider") as StaticBody3D
	if door_static_body:
		door_static_body.add_to_group("placed_objects")
		door_static_body.set_meta("door", self)
		door_static_body.set_meta("is_door_panel", true)
		print("[Door] Door collision configured")
	else:
		push_warning("[Door] DoorCollider not found!")
	
	# Find FrameCollider (static frame)
	frame_static_body = _find_node_by_name(door_model, "FrameCollider") as StaticBody3D
	if frame_static_body:
		frame_static_body.add_to_group("placed_objects")
		frame_static_body.set_meta("door", self)
		frame_static_body.set_meta("is_frame", true)
		print("[Door] Frame collision configured")
	else:
		push_warning("[Door] FrameCollider not found!")

## Disable GLB auto-generated StaticBody3D collisions
func _disable_glb_collisions():
	var door_model = get_node_or_null("DoorModel")
	if not door_model:
		return
	_disable_static_bodies_recursive(door_model)

func _disable_static_bodies_recursive(node: Node):
	var children_to_process = []
	for child in node.get_children():
		children_to_process.append(child)
	
	for child in children_to_process:
		# Skip our named colliders and important nodes
		if child.name in ["DoorCollider", "FrameCollider", "BoneAttachment3D", "SKM_Door", "STM_Frame", "Door_Rig"]:
			_disable_static_bodies_recursive(child)  # But still check children
			continue
		
		# Remove auto-generated StaticBody3D from GLB import
		if child is StaticBody3D:
			print("[Door] Removing GLB auto-generated: %s" % child.name)
			child.queue_free()
		else:
			_disable_static_bodies_recursive(child)

## Find node by name recursively
func _find_node_by_name(root: Node, target_name: String) -> Node:
	if root.name == target_name:
		return root
	for child in root.get_children():
		var found = _find_node_by_name(child, target_name)
		if found:
			return found
	return null

## Called when player presses E
func interact():
	if is_open:
		close_door()
	else:
		open_door()

func open_door():
	if animation_player and animation_player.has_animation("HN_Door_Open"):
		animation_player.play("HN_Door_Open")
	is_open = true
	print("[Door] Opened")

func close_door():
	if animation_player and animation_player.has_animation("HN_Door_Close"):
		animation_player.play("HN_Door_Close")
	is_open = false
	print("[Door] Closed")

func get_interaction_prompt() -> String:
	return "Press E to close" if is_open else "Press E to open"

#region Damage System

func take_damage(amount: int) -> void:
	current_hp = max(0, current_hp - amount)
	print("[Door] Took %d damage (%d/%d HP)" % [amount, current_hp, max_hp])
	
	var hp_percent = float(current_hp) / float(max_hp)
	for i in range(DAMAGE_THRESHOLDS.size()):
		if hp_percent <= DAMAGE_THRESHOLDS[i] and i > current_damage_stage:
			current_damage_stage = i
			break
	
	PlayerSignals.durability_hit.emit(current_hp, max_hp, "Door", self)
	
	if current_hp <= 0:
		_on_destroyed()

func _on_destroyed() -> void:
	print("[Door] Destroyed!")
	PlayerSignals.durability_cleared.emit()
	
	if has_meta("anchor") and has_meta("chunk"):
		var anchor = get_meta("anchor")
		var chunk = get_meta("chunk")
		if chunk and chunk.has_method("remove_object"):
			chunk.remove_object(anchor)
	
	queue_free()

#endregion
