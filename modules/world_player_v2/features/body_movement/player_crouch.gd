extends Node
class_name PlayerCrouchFeature
## PlayerCrouch - Handles crouch/sit mechanic using CTRL key
## Reduces collision height to pass through obstructed doorways

# Crouch settings
const STAND_HEIGHT: float = 1.8
const CROUCH_HEIGHT: float = 1.0
const STAND_COLLISION_Y: float = 0.9   # CollisionShape Y position when standing
const CROUCH_COLLISION_Y: float = 0.5  # CollisionShape Y position when crouched
const STAND_CAMERA_Y: float = 1.6      # Camera Y position when standing
const CROUCH_CAMERA_Y: float = 0.8     # Camera Y position when crouched
const CROUCH_TRANSITION_SPEED: float = 10.0  # How fast to transition
const CROUCH_SPEED: float = 2.5  # Movement speed when crouched

# State
var is_crouching: bool = false

# References
var player: CharacterBody3D = null
var collision_shape: CollisionShape3D = null
var camera: Camera3D = null


func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("PlayerCrouch: Must be child of Player/Components node")
		return
	
	# Get collision shape and camera references
	collision_shape = player.get_node_or_null("CollisionShape3D")
	camera = player.get_node_or_null("Camera3D")
	
	DebugManager.log_player("PlayerCrouchFeature: Initialized")


## Call this from player_movement._handle_walking()
func update(delta: float) -> void:
	if not player:
		return
	
	# Check if CTRL is held (works mid-air too)
	is_crouching = Input.is_key_pressed(KEY_CTRL)
	
	# Target values based on crouch state
	var target_height = CROUCH_HEIGHT if is_crouching else STAND_HEIGHT
	var target_collision_y = CROUCH_COLLISION_Y if is_crouching else STAND_COLLISION_Y
	var target_camera_y = CROUCH_CAMERA_Y if is_crouching else STAND_CAMERA_Y
	
	# Smoothly transition collision shape
	if collision_shape and collision_shape.shape is CapsuleShape3D:
		var capsule = collision_shape.shape as CapsuleShape3D
		capsule.height = lerp(capsule.height, target_height, CROUCH_TRANSITION_SPEED * delta)
		collision_shape.position.y = lerp(collision_shape.position.y, target_collision_y, CROUCH_TRANSITION_SPEED * delta)
	
	# Smoothly transition camera
	if camera:
		camera.position.y = lerp(camera.position.y, target_camera_y, CROUCH_TRANSITION_SPEED * delta)


## Get current movement speed multiplier
func get_speed() -> float:
	return CROUCH_SPEED
