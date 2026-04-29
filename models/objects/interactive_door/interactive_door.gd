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

# Audio
var door_open_sound: AudioStreamPlayer3D = null
var door_close_sound: AudioStreamPlayer3D = null
const DOOR_OPEN_SOUND_FILE = preload("res://game/sound/door/opening-door-411632.mp3")
const DOOR_CLOSE_SOUND_FILE = preload("res://game/sound/door/door-close-79921.mp3")

static var _cached_animation_player_path: NodePath = NodePath()
static var _cached_door_collider_path: NodePath = NodePath()
static var _cached_frame_collider_path: NodePath = NodePath()
static var _cached_auto_static_body_paths: Array = []
static var _cached_door_scene_ready: bool = false

func _ready():
	current_hp = max_hp
	
	add_to_group("interactable")
	add_to_group("placed_objects")
	add_to_group("breakable")
	
	# Defer heavy initialization to first frame to spread load
	call_deferred("_deferred_init")

func _deferred_init():
	var door_model = get_node_or_null("DoorModel")
	if not door_model:
		return
	_ensure_cached_door_scene_paths(door_model)
	_resolve_animation_player(door_model)
	_disable_glb_collisions(door_model)
	_setup_collisions(door_model)

func _ensure_audio() -> void:
	if door_open_sound and is_instance_valid(door_open_sound) and door_close_sound and is_instance_valid(door_close_sound):
		return

	# Open sound
	if not door_open_sound or not is_instance_valid(door_open_sound):
		door_open_sound = AudioStreamPlayer3D.new()
		door_open_sound.stream = DOOR_OPEN_SOUND_FILE
		door_open_sound.volume_db = -5.0
		door_open_sound.max_distance = 20.0
		add_child(door_open_sound)
	
	# Close sound
	if not door_close_sound or not is_instance_valid(door_close_sound):
		door_close_sound = AudioStreamPlayer3D.new()
		door_close_sound.stream = DOOR_CLOSE_SOUND_FILE
		door_close_sound.volume_db = -5.0
		door_close_sound.max_distance = 20.0
		add_child(door_close_sound)

func _ensure_cached_door_scene_paths(door_model: Node) -> void:
	if _cached_door_scene_ready:
		return
	_cached_door_scene_ready = true
	_cached_auto_static_body_paths.clear()
	_cache_door_scene_paths_recursive(door_model, door_model)


func _cache_door_scene_paths_recursive(root: Node, node: Node) -> void:
	if not root or not node:
		return

	if node is AnimationPlayer and _cached_animation_player_path.is_empty():
		_cached_animation_player_path = root.get_path_to(node)

	if node.name == "DoorCollider" and _cached_door_collider_path.is_empty():
		_cached_door_collider_path = root.get_path_to(node)
	elif node.name == "FrameCollider" and _cached_frame_collider_path.is_empty():
		_cached_frame_collider_path = root.get_path_to(node)
	elif node is StaticBody3D and node.name not in ["DoorCollider", "FrameCollider"]:
		var static_body_path := root.get_path_to(node)
		if not _cached_auto_static_body_paths.has(static_body_path):
			_cached_auto_static_body_paths.append(static_body_path)

	for child in node.get_children():
		_cache_door_scene_paths_recursive(root, child)


func _resolve_animation_player(door_model: Node) -> void:
	if animation_player and is_instance_valid(animation_player):
		return
	if not door_model:
		return
	if not _cached_animation_player_path.is_empty():
		animation_player = door_model.get_node_or_null(_cached_animation_player_path) as AnimationPlayer
		if animation_player:
			return
	animation_player = _find_animation_player_recursive(door_model)
	if animation_player:
		_cached_animation_player_path = door_model.get_path_to(animation_player)


func _find_animation_player_recursive(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player_recursive(child)
		if found:
			return found
	return null

## Find and configure scene-defined StaticBody3D collisions
func _setup_collisions(door_model: Node):
	if not door_model:
		push_warning("[Door] DoorModel not found!")
		return
	
	# Find DoorCollider (attached to bone for animation)
	door_static_body = _resolve_cached_static_body(door_model, _cached_door_collider_path, "DoorCollider")
	if door_static_body:
		door_static_body.add_to_group("placed_objects")
		door_static_body.set_meta("door", self)
		door_static_body.set_meta("is_door_panel", true)
	else:
		push_warning("[Door] DoorCollider not found!")
	
	# Find FrameCollider (static frame)
	frame_static_body = _resolve_cached_static_body(door_model, _cached_frame_collider_path, "FrameCollider")
	if frame_static_body:
		frame_static_body.add_to_group("placed_objects")
		frame_static_body.set_meta("door", self)
		frame_static_body.set_meta("is_frame", true)
	else:
		push_warning("[Door] FrameCollider not found!")

## Disable GLB auto-generated StaticBody3D collisions
func _disable_glb_collisions(door_model: Node):
	if not door_model:
		return
	if _cached_auto_static_body_paths.is_empty():
		_cache_door_scene_paths_recursive(door_model, door_model)
	for body_path_variant in _cached_auto_static_body_paths:
		var body_node := door_model.get_node_or_null(body_path_variant)
		if body_node is StaticBody3D:
			(body_node as StaticBody3D).queue_free()

func _resolve_cached_static_body(door_model: Node, cached_path: NodePath, target_name: String) -> StaticBody3D:
	if door_model and not cached_path.is_empty():
		var cached_node := door_model.get_node_or_null(cached_path)
		if cached_node is StaticBody3D:
			return cached_node

	var found := _find_node_by_name(door_model, target_name)
	if found and found is StaticBody3D:
		var body := found as StaticBody3D
		var discovered_path := door_model.get_path_to(body)
		if target_name == "DoorCollider":
			_cached_door_collider_path = discovered_path
		elif target_name == "FrameCollider":
			_cached_frame_collider_path = discovered_path
		return body
	return null

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
	_ensure_audio()
	if door_open_sound:
		door_open_sound.play()
	if animation_player and animation_player.has_animation("HN_Door_Open"):
		animation_player.play("HN_Door_Open")
	is_open = true

func close_door():
	_ensure_audio()
	if door_close_sound:
		door_close_sound.play()
	if animation_player and animation_player.has_animation("HN_Door_Close"):
		animation_player.play("HN_Door_Close")
	is_open = false

func get_interaction_prompt() -> String:
	return "Press E to close" if is_open else "Press E to open"

#region Damage System

func take_damage(amount: int) -> void:
	current_hp = max(0, current_hp - amount)
	
	var hp_percent = float(current_hp) / float(max_hp)
	for i in range(DAMAGE_THRESHOLDS.size()):
		if hp_percent <= DAMAGE_THRESHOLDS[i] and i > current_damage_stage:
			current_damage_stage = i
			break
	
	PlayerSignals.durability_hit.emit(current_hp, max_hp, "Door", self)
	
	if current_hp <= 0:
		_on_destroyed()

func _on_destroyed() -> void:
	PlayerSignals.durability_cleared.emit()
	
	if has_meta("anchor") and has_meta("chunk"):
		var anchor = get_meta("anchor")
		var chunk = get_meta("chunk")
		if chunk and chunk.has_method("remove_object"):
			chunk.remove_object(anchor)
	
	queue_free()

#endregion
