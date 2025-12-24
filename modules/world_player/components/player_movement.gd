extends Node
class_name PlayerMovement
## PlayerMovement - Handles player locomotion (walk, jump, gravity)
## Minimal implementation to start - sprint, swim, fly will be added later.

# Movement constants
const WALK_SPEED: float = 5.0
const JUMP_VELOCITY: float = 4.5

# References
var player: CharacterBody3D = null
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# State
var was_on_floor: bool = true

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("PlayerMovement: Must be child of Player/Components node")
	DebugSettings.log_player("PlayerMovement: Component initialized")

func _physics_process(delta: float) -> void:
	if not player:
		return
	
	apply_gravity(delta)
	handle_jump()
	handle_movement()
	
	player.move_and_slide()
	
	# Detect landing
	check_landing()

func apply_gravity(delta: float) -> void:
	if not player.is_on_floor():
		player.velocity.y -= gravity * delta

func handle_jump() -> void:
	if Input.is_action_just_pressed("ui_accept") and player.is_on_floor():
		player.velocity.y = JUMP_VELOCITY
		PlayerSignals.player_jumped.emit()

func handle_movement() -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (player.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		player.velocity.x = direction.x * WALK_SPEED
		player.velocity.z = direction.z * WALK_SPEED
	else:
		player.velocity.x = move_toward(player.velocity.x, 0, WALK_SPEED)
		player.velocity.z = move_toward(player.velocity.z, 0, WALK_SPEED)

func check_landing() -> void:
	var on_floor_now = player.is_on_floor()
	if on_floor_now and not was_on_floor:
		PlayerSignals.player_landed.emit()
	was_on_floor = on_floor_now
