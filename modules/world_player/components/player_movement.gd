extends Node
class_name PlayerMovement
## PlayerMovement - Handles player locomotion (walk, jump, gravity)
## Minimal implementation to start - sprint, swim, fly will be added later.

# Movement constants
const WALK_SPEED: float = 5.0
const JUMP_VELOCITY: float = 4.5

# Footstep sound settings - matched to original project
const FOOTSTEP_INTERVAL: float = 0.5  # Time between footsteps
var footstep_timer: float = 0.0
var footstep_sounds: Array[AudioStream] = []
var footstep_player: AudioStreamPlayer3D = null

# References
var player: CharacterBody3D = null
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# State
var was_on_floor: bool = true

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("PlayerMovement: Must be child of Player/Components node")
	
	# Defer footstep setup to ensure player is in scene tree
	call_deferred("_setup_footstep_sounds")
	
	DebugSettings.log_player("PlayerMovement: Component initialized")

func _setup_footstep_sounds() -> void:
	# Preload the footstep sounds
	footstep_sounds = [
		preload("res://sound/st1-footstep-sfx-323053.mp3"),
		preload("res://sound/st2-footstep-sfx-323055.mp3"),
		preload("res://sound/st3-footstep-sfx-323056.mp3")
	]
	
	# Create audio player as child of player (like original)
	footstep_player = AudioStreamPlayer3D.new()
	footstep_player.name = "FootstepPlayer"
	player.add_child(footstep_player)
	
	DebugSettings.log_player("PlayerMovement: Loaded %d footstep sounds" % footstep_sounds.size())

func _physics_process(delta: float) -> void:
	if not player:
		return
	
	apply_gravity(delta)
	handle_jump()
	handle_movement()
	handle_footsteps(delta)
	
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

# Matches original project's footstep logic exactly
func handle_footsteps(delta: float) -> void:
	# Get horizontal velocity only (ignore vertical/falling)
	var horizontal_velocity = Vector2(player.velocity.x, player.velocity.z)
	
	# Check: Is player on floor? Is player moving?
	if player.is_on_floor() and horizontal_velocity.length() > 0.1:
		footstep_timer -= delta
		if footstep_timer <= 0:
			_play_random_footstep()
			footstep_timer = FOOTSTEP_INTERVAL
	else:
		# Reset timer so step plays immediately when movement starts
		footstep_timer = 0.0

func _play_random_footstep() -> void:
	if footstep_sounds.is_empty() or not footstep_player:
		return
	
	# Safety check - ensure player is in scene tree
	if not footstep_player.is_inside_tree():
		return
	
	footstep_player.stream = footstep_sounds.pick_random()
	footstep_player.pitch_scale = randf_range(0.9, 1.1)
	footstep_player.play()

func check_landing() -> void:
	var on_floor_now = player.is_on_floor()
	if on_floor_now and not was_on_floor:
		PlayerSignals.player_landed.emit()
		# Play footstep on landing too
		_play_random_footstep()
	was_on_floor = on_floor_now
