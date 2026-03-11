extends Node
class_name PlayerCrouchFeature
## PlayerCrouch - Handles crouch/sit mechanic using CTRL key
## Reduces collision height and drives animation state machine

# Crouch settings
const STAND_HEIGHT: float = 1.8
const CROUCH_HEIGHT: float = 1.0
const STAND_COLLISION_Y: float = 0.9   # CollisionShape Y position when standing
const CROUCH_COLLISION_Y: float = 0.5  # CollisionShape Y position when crouched
const CROUCH_TRANSITION_SPEED: float = 10.0  # How fast to transition
const CROUCH_SPEED: float = 2.5  # Movement speed when crouched

# State
var is_crouching: bool = false

# References
var player: CharacterBody3D = null
var collision_shape: CollisionShape3D = null
var _anim_tree: AnimationTree = null
var _sm_playback: AnimationNodeStateMachinePlayback = null


func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("[CROUCH] Must be child of Player/Components node")
		return
	
	# Get collision shape reference
	collision_shape = player.get_node_or_null("CollisionShape3D")
	
	# Find AnimationTree and get the StateMachine playback
	var full_body = player.get_node_or_null("WorldPlayerFullBody/Superhero_Male_FullBody")
	if full_body:
		_anim_tree = full_body.get_node_or_null("AnimationTree")
		if _anim_tree:
			# The StateMachine is accessed via its path in the BlendTree
			_sm_playback = _anim_tree.get("parameters/StateMachine/playback")
			if _sm_playback:
				print("[CROUCH] StateMachine playback found")
			else:
				push_warning("[CROUCH] StateMachine playback not found - check AnimationTree path")
	
	print("[CROUCH] Initialized")


## Call this from player_movement._handle_walking()
func update(delta: float) -> void:
	if not player:
		return
	
	var was_crouching = is_crouching
	
	# Check if CTRL is held (works mid-air too)
	is_crouching = Input.is_key_pressed(KEY_CTRL)
	
	# Drive animation state machine on state change
	if is_crouching != was_crouching:
		_update_animation_state()
	
	# Target values based on crouch state
	var target_height = CROUCH_HEIGHT if is_crouching else STAND_HEIGHT
	var target_collision_y = CROUCH_COLLISION_Y if is_crouching else STAND_COLLISION_Y
	
	# Smoothly transition collision shape
	if collision_shape and collision_shape.shape is CapsuleShape3D:
		var capsule = collision_shape.shape as CapsuleShape3D
		capsule.height = lerp(capsule.height, target_height, CROUCH_TRANSITION_SPEED * delta)
		collision_shape.position.y = lerp(collision_shape.position.y, target_collision_y, CROUCH_TRANSITION_SPEED * delta)
	
	# Also update animation when movement changes while crouching
	if is_crouching:
		_update_crouch_movement_anim()


func _update_animation_state() -> void:
	if not _sm_playback:
		return
	
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var is_moving = input_dir.length() > 0.1
	
	if is_crouching:
		if is_moving:
			_sm_playback.travel(&"Crouch_Fwd")
		else:
			_sm_playback.travel(&"Crouch_Idle")
	else:
		# player_movement will handle Walk/Sprint/Idle transitions when standing
		# We just need to give it a nudge if standing up
		if is_moving:
			if Input.is_action_pressed("sprint") and player.is_on_floor():
				_sm_playback.travel(&"Sprint")
			else:
				_sm_playback.travel(&"Walk")
		else:
			_sm_playback.travel(&"Idle")

func _update_crouch_movement_anim() -> void:
	if not _sm_playback:
		return
	
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var is_moving = input_dir.length() > 0.1
	var current_node = _sm_playback.get_current_node()
	
	if is_moving and current_node == &"Crouch_Idle":
		_sm_playback.travel(&"Crouch_Fwd")
	elif not is_moving and current_node == &"Crouch_Fwd":
		_sm_playback.travel(&"Crouch_Idle")


## Get current movement speed multiplier
func get_speed() -> float:
	return CROUCH_SPEED

## Set crouch state (for save restoration)
func set_crouch_state(crouch: bool) -> void:
	is_crouching = crouch
	_update_animation_state()
	print("[CROUCH] State restored to %s" % crouch)
