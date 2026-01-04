extends Node
class_name PlayerMovement
## PlayerMovement - Handles player locomotion (walk, sprint, jump, gravity, swim)

# Movement constants
const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 8.5  # ~70% faster than walking
const SWIM_SPEED: float = 4.0
const JUMP_VELOCITY: float = 4.5

# Footstep sound settings - matched to original project
const FOOTSTEP_INTERVAL: float = 0.5  # Time between footsteps walking
const FOOTSTEP_INTERVAL_SPRINT: float = 0.3  # Faster footsteps when sprinting
var footstep_timer: float = 0.0
var footstep_sounds: Array[AudioStream] = []
var footstep_player: AudioStreamPlayer3D = null

# State
var is_sprinting: bool = false

# References
var player: CharacterBody3D = null
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# State
var was_on_floor: bool = true
var is_swimming: bool = false
var was_swimming: bool = false

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("PlayerMovement: Must be child of Player/Components node")
	
	# Defer footstep setup to ensure player is in scene tree
	call_deferred("_setup_footstep_sounds")
	
	DebugManager.log_player("PlayerMovement: Component initialized")

func _setup_footstep_sounds() -> void:
	# Preload the footstep sounds
	footstep_sounds = [
		preload("res://game/sound/st1-footstep-sfx-323053.mp3"),
		preload("res://game/sound/st2-footstep-sfx-323055.mp3"),
		preload("res://game/sound/st3-footstep-sfx-323056.mp3")
	]
	
	# Create audio player as child of player (like original)
	footstep_player = AudioStreamPlayer3D.new()
	footstep_player.name = "FootstepPlayer"
	player.add_child(footstep_player)
	
	DebugManager.log_player("PlayerMovement: Loaded %d footstep sounds" % footstep_sounds.size())

func _physics_process(delta: float) -> void:
	if not player:
		return
	
	_update_water_state()
	
	if is_swimming:
		_handle_swimming(delta)
	else:
		_handle_walking(delta)
	
	player.move_and_slide()
	
	# Detect landing
	check_landing()

func _update_water_state() -> void:
	# Check Center of Mass (+0.9 is approx center of 1.8m player)
	var center_pos = player.global_position + Vector3(0, 0.9, 0)
	var body_density = 1.0 # Default to air
	
	# Access terrain manager to get density
	if "terrain_manager" in player and player.terrain_manager and player.terrain_manager.has_method("get_water_density"):
		body_density = player.terrain_manager.get_water_density(center_pos)
	
	was_swimming = is_swimming
	# Negative density means inside water (as per ChunkManager convention)
	is_swimming = body_density < 0.0
	
	# Handle entry/exit transitions
	if is_swimming and not was_swimming:
		player.velocity.y *= 0.1 # Dampen entry velocity
	elif not is_swimming and was_swimming:
		# Jump out of water if holding jump
		if Input.is_action_pressed("ui_accept"):
			player.velocity.y = JUMP_VELOCITY

func _handle_walking(delta: float) -> void:
	apply_gravity(delta)
	handle_jump()
	handle_movement()
	handle_footsteps(delta)

func _handle_swimming(delta: float) -> void:
	# Neutral buoyancy or slight sinking/floating
	# Apply drag to existing velocity
	player.velocity = player.velocity.move_toward(Vector3.ZERO, 2.0 * delta)
	
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	# Swim in camera direction
	var cam_basis = Basis()
	if "camera_component" in player and player.camera_component and player.camera_component.camera:
		cam_basis = player.camera_component.camera.global_transform.basis
	else:
		cam_basis = player.global_transform.basis
		
	var direction = (cam_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		player.velocity += direction * SWIM_SPEED * delta * 5.0 # Acceleration
		if player.velocity.length() > SWIM_SPEED:
			player.velocity = player.velocity.normalized() * SWIM_SPEED
	
	# Space to swim up (surface) explicitly
	if Input.is_action_pressed("ui_accept"):
		player.velocity.y += 5.0 * delta

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
	
	# Check for sprint (Shift key)
	# On floor: sprint if holding shift and moving
	# In air: preserve sprint if still holding shift (momentum preservation)
	if player.is_on_floor():
		is_sprinting = Input.is_action_pressed("sprint") and direction != Vector3.ZERO
	else:
		# In air: keep sprinting if still holding shift (preserves jump momentum)
		if not Input.is_action_pressed("sprint"):
			is_sprinting = false
	
	var current_speed = SPRINT_SPEED if is_sprinting else WALK_SPEED
	
	if direction:
		player.velocity.x = direction.x * current_speed
		player.velocity.z = direction.z * current_speed
	else:
		player.velocity.x = move_toward(player.velocity.x, 0, current_speed)
		player.velocity.z = move_toward(player.velocity.z, 0, current_speed)

# Matches original project's footstep logic exactly
func handle_footsteps(delta: float) -> void:
	# Get horizontal velocity only (ignore vertical/falling)
	var horizontal_velocity = Vector2(player.velocity.x, player.velocity.z)
	
	# Check: Is player on floor? Is player moving?
	if player.is_on_floor() and horizontal_velocity.length() > 0.1:
		footstep_timer -= delta
		if footstep_timer <= 0:
			_play_random_footstep()
			# Use faster footstep interval when sprinting
			footstep_timer = FOOTSTEP_INTERVAL_SPRINT if is_sprinting else FOOTSTEP_INTERVAL
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
