extends "res://addons/srcoder_simplecar/assets/scripts/car.gd"
## Extended car script with WASD controls, player interaction, and water physics.
## Does NOT modify the addon - inherits and overrides.

# Player control state
var is_player_controlled: bool = false
var occupant: Node3D = null

# Water physics
var terrain_manager: Node = null
const BUOYANCY_FORCE: float = 15.0
const WATER_DRAG: float = 2.0

# Flip recovery threshold
const FLIP_THRESHOLD: float = 0.3       # Consider flipped when nearly on side

# Boost
const BOOST_MULTIPLIER: float = 1.5   # Acceleration boost when holding shift
var is_boosting: bool = false

# Audio
@onready var engine_start_audio: AudioStreamPlayer3D = $EngineStartAudio
@onready var engine_idle_audio: AudioStreamPlayer3D = $EngineIdleAudio
const ENGINE_MIN_PITCH: float = 0.8   # Pitch at idle/stationary
const ENGINE_MAX_PITCH: float = 1.8   # Pitch at top speed
const ENGINE_SPEED_REF: float = 40.0  # Speed (m/s) for max pitch

signal player_entered(player_node: Node3D)
signal player_exited(player_node: Node3D)


func _ready() -> void:
	super._ready()
	add_to_group("vehicle")
	add_to_group("interactable")
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	# Set collision layer 4 for vehicle detection (bit 3)
	collision_layer = collision_layer | (1 << 3)
	
	# === ARCADE CAR PHYSICS (GTA-STYLE) ===
	# Lighter mass for snappy acceleration/braking
	mass = 800.0  # Light arcade feel
	
	# Center of mass - LOW for stability
	center_of_mass_mode = CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.5, 0)  # Low center = less tippy
	
	# High damping - CRITICAL for high-speed stability
	angular_damp = 4.5  # Prevent high-speed oscillation/hopping
	linear_damp = 0.15  # Quick slow-down when not accelerating
	
	# Engine - POWERFUL for arcade feel
	max_torque = 5000.0      # Very strong acceleration
	max_wheel_rpm = 3000.0   # Fast top speed
	
	# Tire grip - BALANCED (arcade grip with controllable slide)
	front_wheel_grip = 12.0   # High grip, allows turning
	rear_wheel_grip = 10.0    # Lower for fun oversteer/drifting
	
	# === ARCADE SUSPENSION (High-Speed Stable) ===
	# Stiffer for high-speed stability without losing bump absorption
	# Very strong damping to kill oscillation during fast turns
	max_steer = 0.35  # Responsive but not twitchy at speed
	steer_damping = 6.0  # Fast response with stability
	
	for wheel in steering_wheels:
		wheel.wheel_friction_slip = front_wheel_grip
		wheel.suspension_stiffness = 150.0   # Stiffer for high-speed stability
		wheel.damping_compression = 10.0     # Very strong damping
		wheel.damping_relaxation = 15.0      # Kill bounce instantly
		wheel.suspension_travel = 0.2        # Moderate travel
	for wheel in driving_wheels:
		wheel.wheel_friction_slip = rear_wheel_grip
		wheel.suspension_stiffness = 150.0   # Stiffer for high-speed stability
		wheel.damping_compression = 10.0     # Very strong damping
		wheel.damping_relaxation = 15.0      # Kill bounce instantly
		wheel.suspension_travel = 0.2        # Moderate travel


func enter_vehicle(player_node: Node3D) -> void:
	occupant = player_node
	is_player_controlled = true
	player_entered.emit(player_node)
	_start_engine_audio()


func exit_vehicle() -> Node3D:
	var exiting = occupant
	occupant = null
	is_player_controlled = false
	
	# CRITICAL: Stop the car completely when player exits
	# This prevents the car from rolling away or flying off
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	brake = 1.0  # Apply full brake
	
	player_exited.emit(exiting)
	_stop_engine_audio()
	return exiting


## Override to use WASD controls and respect player control state
## ARCADE BRAKING: Instant, powerful response
const ARCADE_BRAKE_POWER: float = 8.0  # Strong instant braking

func get_input(delta: float) -> void:
	if not is_player_controlled:
		player_steer = 0.0
		player_acceleration = 0.0
		player_braking = 0.0
		is_boosting = false
		return
	
	# Check for boost (Shift key)
	is_boosting = Input.is_action_pressed("sprint")
	
	# WASD controls
	player_input.x = Input.get_axis("move_right", "move_left")
	player_steer = move_toward(player_steer, player_input.x * max_steer, steer_damping * delta)
	
	# W/S for forward/backward
	player_input.y = Input.get_axis("move_backward", "move_forward")
	
	# Apply boost multiplier to acceleration
	var accel_mult: float = BOOST_MULTIPLIER if is_boosting else 1.0
	
	# SIMPLIFIED ARCADE CONTROLS
	if player_input.y > 0.01:
		# Forward acceleration
		player_acceleration = player_input.y * accel_mult
		player_braking = 0.0
	elif player_input.y < -0.01:
		# Reverse/Brake - simple arcade logic
		var forward_speed = _get_forward_speed()
		
		if forward_speed > 2.0:
			# Moving forward - brake hard
			player_braking = ARCADE_BRAKE_POWER
			player_acceleration = 0.0
		else:
			# Stopped or slow - instant reverse
			player_braking = 0.0
			player_acceleration = player_input.y * accel_mult
	else:
		# No input - coast (no brake)
		player_acceleration = 0.0
		player_braking = 0.0


## Get current forward speed in m/s (positive = forward, negative = reverse)
func _get_forward_speed() -> float:
	return -basis.z.dot(linear_velocity)


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	_apply_water_physics(delta)
	_apply_low_speed_steering_assist(delta)
	_check_flip_recovery()
	_update_engine_audio()


func _apply_water_physics(delta: float) -> void:
	if not terrain_manager or not terrain_manager.has_method("get_water_density"):
		return
	
	var density = terrain_manager.get_water_density(global_position)
	if density < 0.0:  # Underwater (negative = inside water)
		# Buoyancy - push up proportional to depth
		var submerge_depth = -density  # How deep (approx)
		apply_central_force(Vector3.UP * BUOYANCY_FORCE * min(submerge_depth, 3.0))
		# Water drag - slow down movement
		linear_velocity = linear_velocity.lerp(Vector3.ZERO, WATER_DRAG * delta)


## ARCADE LOW-SPEED STEERING ASSIST
## VehicleBody3D steering is velocity-dependent, so at low speeds turning is sluggish.
## This adds manual angular velocity to ensure sharp turns even when barely moving.
const LOW_SPEED_THRESHOLD: float = 8.0  # Below this speed, apply steering assist
const STEERING_ASSIST_STRENGTH: float = 0.5  # Angular velocity multiplier (subtle low-speed assist)

func _apply_low_speed_steering_assist(delta: float) -> void:
	if not is_player_controlled or player_steer == 0.0:
		return
	
	var speed = linear_velocity.length()
	if speed < LOW_SPEED_THRESHOLD:
		# Calculate assist factor (1.0 at standstill, 0.0 at threshold)
		var assist_factor = 1.0 - (speed / LOW_SPEED_THRESHOLD)
		assist_factor = ease(assist_factor, 0.5)  # Smooth curve
		
		# Apply angular velocity for instant arcade turning
		var turn_direction = player_steer  # Fixed rotation direction
		var assist_torque = turn_direction * STEERING_ASSIST_STRENGTH * assist_factor
		angular_velocity.y += assist_torque * delta * 60.0  # Frame-independent


## Check if player wants to flip the car back over (B key)
func _check_flip_recovery() -> void:
	if not is_player_controlled:
		return
	
	# Check if B key is pressed
	if Input.is_key_pressed(KEY_B):
		var up = global_transform.basis.y
		var uprightness = up.dot(Vector3.UP)
		
		# Only allow flip recovery when actually flipped or heavily tilted
		if uprightness < FLIP_THRESHOLD:
			_flip_vehicle_upright()


## Flip the vehicle back to upright position
func _flip_vehicle_upright() -> void:
	# Get current position and forward direction
	var pos = global_position
	var forward = -global_transform.basis.z
	forward.y = 0
	forward = forward.normalized()
	
	if forward.length() < 0.1:
		forward = Vector3.FORWARD
	
	# Create upright transform keeping the forward direction
	var new_basis = Basis.looking_at(forward, Vector3.UP)
	
	# Lift the car slightly and reset rotation
	global_position = pos + Vector3(0, 1.0, 0)
	global_transform.basis = new_basis
	
	# Reset velocities
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	
	print("[Vehicle] Flipped upright!")


## Interaction prompt for "Press E to..." system
func get_interaction_prompt() -> String:
	if is_player_controlled:
		return "Press E to exit vehicle"
	return "Press E to enter vehicle"


## Gets a safe position for player to exit (beside the vehicle)
func get_exit_position() -> Vector3:
	# Exit 4m to the left (vehicle-relative)
	var exit_offset = global_transform.basis.x * -4.0
	var base_position = global_position + exit_offset
	
	# Raycast down to find terrain surface
	var space_state = get_world_3d().direct_space_state
	var ray_start = base_position + Vector3(0, 50.0, 0)  # Start high above
	var ray_end = base_position + Vector3(0, -50.0, 0)   # Check down
	
	var query = PhysicsRayQueryParameters3D.create(ray_start, ray_end)
	query.collision_mask = 1  # Only terrain (layer 1)
	query.exclude = [get_rid()]  # Don't hit the car
	
	var result = space_state.intersect_ray(query)
	
	if result:
		# Found terrain - place player 1m above surface
		return result.position + Vector3(0, 1.0, 0)
	else:
		# No terrain found - use car height as fallback
		return base_position + Vector3(0, 1.0, 0)


## Enable or disable the follow camera
func set_camera_active(active: bool) -> void:
	# Camera3D is nested inside: FollowCamera/Pivot/SpringArm3D/Camera3D
	var cam = get_node_or_null("FollowCamera/Pivot/SpringArm3D/Camera3D")
	if cam and cam is Camera3D:
		cam.current = active
		print("[Vehicle] Camera active: %s" % active)


# === ENGINE AUDIO ===
const ENGINE_STARTUP_DURATION: float = 5.0  # Seconds startup plays before stopping
const ENGINE_LOOP_START: float = 0.10  # Loop start point (skip click)
const ENGINE_LOOP_END: float = 2.30    # Loop end point (avoid end artifact)

## Start engine sound - plays startup while driving loop runs on top
func _start_engine_audio() -> void:
	# Play startup sound at full volume
	if engine_start_audio:
		engine_start_audio.volume_db = -3.0  # Full startup volume
		engine_start_audio.play()
	
	# Start driving loop immediately - responds to W/S right away
	if engine_idle_audio and engine_idle_audio.stream:
		# Enable looping on the stream
		if engine_idle_audio.stream is AudioStreamMP3:
			engine_idle_audio.stream.loop = true
			engine_idle_audio.stream.loop_offset = 0.10  # Skip first 100ms to avoid click
		# Start quiet then fade in to avoid pop/click
		engine_idle_audio.volume_db = -40.0  # Start silent
		engine_idle_audio.play()
		_fade_in_driving_loop()
		print("[Vehicle] Engine started - startup + driving loop layered")
	
	# Stop startup after 5 seconds (driving loop continues)
	_stop_startup_after_delay()


## Fade in driving loop over 0.2 seconds to avoid click
func _fade_in_driving_loop() -> void:
	var fade_time: float = 0.2
	var steps: int = 10
	var step_time: float = fade_time / steps
	var target_volume: float = 10.0  # Match the LOUD idle volume
	
	for i in range(steps + 1):
		if not is_player_controlled or not engine_idle_audio:
			break
		var t: float = float(i) / float(steps)
		engine_idle_audio.volume_db = lerp(-40.0, target_volume, t)
		await get_tree().create_timer(step_time).timeout


## Stop startup sound after duration, keep driving loop going
func _stop_startup_after_delay() -> void:
	await get_tree().create_timer(ENGINE_STARTUP_DURATION).timeout
	if engine_start_audio and is_player_controlled:
		engine_start_audio.stop()
		print("[Vehicle] Startup complete - driving loop continues")


## Stop engine sound
func _stop_engine_audio() -> void:
	if engine_start_audio:
		engine_start_audio.stop()
	if engine_idle_audio:
		engine_idle_audio.stop()
	print("[Vehicle] Engine stopped")


## Update engine pitch based on vehicle speed
func _update_engine_audio() -> void:
	if not is_player_controlled or not engine_idle_audio:
		return
	
	if engine_idle_audio.playing:
		# Manual loop boundary check (seek back when reaching end point)
		var playback_pos = engine_idle_audio.get_playback_position()
		if playback_pos >= ENGINE_LOOP_END:
			engine_idle_audio.seek(ENGINE_LOOP_START)
		
		# Calculate speed factor (0.0 to 1.0)
		var speed = linear_velocity.length()
		var speed_factor = clamp(speed / ENGINE_SPEED_REF, 0.0, 1.0)
		
		# Lerp pitch between min and max based on speed
		engine_idle_audio.pitch_scale = lerp(ENGINE_MIN_PITCH, ENGINE_MAX_PITCH, speed_factor)
		
		# Volume responds to speed - LOUD driving loop (no limiter)
		engine_idle_audio.volume_db = lerp(10.0, 15.0, speed_factor)
