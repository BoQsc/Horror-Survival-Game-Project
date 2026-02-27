extends Node
class_name PlayerMovementFeature
## PlayerMovement - Handles player locomotion (walk, sprint, jump, gravity, swim)
## Crouch is handled by sibling PlayerCrouchFeature

# Local signals reference
var signals: Node = null

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
var crouch: Node = null  # Sibling crouch component (PlayerCrouchFeature)
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# State
var was_on_floor: bool = true
var is_swimming: bool = false
var was_swimming: bool = false

# Stair Stepping
const MAX_STEP_HEIGHT: float = 0.6
const STEP_FORWARD_MARGIN: float = 0.1
var is_stair_stepping: bool = false

func _ready() -> void:
	# Try to find local signals node
	signals = get_node_or_null("../signals")
	if not signals:
		signals = get_node_or_null("signals")
	
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("PlayerMovement: Must be child of Player/Components node")
		return
	
	# Get sibling crouch component
	crouch = get_node_or_null("../Crouch") as PlayerCrouchFeature
	
	# Defer footstep setup to ensure player is in scene tree
	call_deferred("_setup_footstep_sounds")
	
	DebugManager.log_player("PlayerMovementFeature: Initialized")

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
	PerformanceMonitor.start_measure("Player Movement")
	if not player:
		PerformanceMonitor.end_measure("Player Movement", 1.0)
		return
	
	# Skip movement if container UI is open
	var container_panel = get_tree().get_first_node_in_group("container_panel")
	if container_panel and container_panel.visible:
		PerformanceMonitor.end_measure("Player Movement", 1.0)
		return
	
	_update_water_state()
	
	if is_swimming:
		_handle_swimming(delta)
	else:
		_handle_walking(delta)
	
	var pre_move_pos = player.global_position
	player.move_and_slide()
	
	if not is_swimming:
		_handle_stair_stepping(delta, pre_move_pos)
	
	# Clamp player to world map boundaries (only in world map mode)
	if "terrain_manager" in player and player.terrain_manager \
		and "world_map_active" in player.terrain_manager and player.terrain_manager.world_map_active:
		var half = player.terrain_manager.world_map_half - 6.0  # Margin before the wall
		var pos = player.global_position
		pos.x = clampf(pos.x, -half, half)
		pos.z = clampf(pos.z, -half, half)
		if pos != player.global_position:
			player.global_position = pos
			player.velocity.x = 0.0
			player.velocity.z = 0.0
	
	# Detect landing
	check_landing()
	
	# Reset stair stepping flag for the next frame
	is_stair_stepping = false
	
	PerformanceMonitor.end_measure("Player Movement", 1.0)

func _handle_stair_stepping(delta: float, pre_move_pos: Vector3) -> void:
	if player.velocity.y > JUMP_VELOCITY * 0.5:
		return
		
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	if input_dir.length_squared() < 0.1:
		return
		
	var dir := (player.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if player.get_slide_collision_count() == 0:
		return
		
	var hit_wall = false
	for i in range(player.get_slide_collision_count()):
		var col = player.get_slide_collision(i)
		if col.get_angle() > 0.5:  
			hit_wall = true
			break
			
	if not hit_wall:
		return
		
	var space = player.get_world_3d().direct_space_state
	var move_dist = current_speed() * delta
	
	# Step 1: Can we move forward if we were higher up?
	# We use body_test_motion to sweep the player's entire collision capsule forward
	var params = PhysicsTestMotionParameters3D.new()
	var result = PhysicsTestMotionResult3D.new()
	
	# Start at a theoretical position on top of the maximum step height
	var test_pos = player.global_transform
	test_pos.origin.y += MAX_STEP_HEIGHT
	
	params.from = test_pos
	params.motion = dir * move_dist * 2.0  # Sweep forward
	params.margin = 0.08
	params.exclude_bodies = [player.get_rid()]
	
	var blocked_high = PhysicsServer3D.body_test_motion(player.get_rid(), params, result)
	
	# If we hit a wall even when lifted up, it's too tall to step over
	if blocked_high and result.get_collision_normal().angle_to(Vector3.UP) > 0.5:
		return
		
	# Step 2: Since we can move forward up there, let's find exactly how far down the floor is.
	# We create a shape query matching the player's collider
	# We rely on the player's CollisionShape3D component
	var col_shape_node = player.get_node_or_null("CollisionShape3D")
	if not col_shape_node or not col_shape_node.shape:
		return
		
	# Sweep DOWN from the safely moved-forward high position
	var down_params = PhysicsTestMotionParameters3D.new()
	var down_result = PhysicsTestMotionResult3D.new()
	
	# We position the query slightly forward on XZ, and MAX_STEP_HEIGHT up on Y
	var sweep_start = player.global_transform
	sweep_start.origin += dir * 0.2
	sweep_start.origin.y += MAX_STEP_HEIGHT
	
	down_params.from = sweep_start
	down_params.motion = Vector3(0, -MAX_STEP_HEIGHT - 0.2, 0) # Sweep down past current feet
	down_params.margin = 0.08
	down_params.exclude_bodies = [player.get_rid()]
	
	var hit_floor = PhysicsServer3D.body_test_motion(player.get_rid(), down_params, down_result)
	
	if hit_floor:
		# EXPLICIT TERRAIN CHECK: Only allow stair stepping on actual building blocks, not raw terrain.
		# Check if the collider we are stepping onto is a building.
		var floor_collider = down_result.get_collider()
		if not floor_collider or not (floor_collider is Node) or (not floor_collider.is_in_group("building_chunks") and not floor_collider.is_in_group("placed_objects")):
			# We are trying to step onto natural terrain or something else. Do not engage stair script.
			# DebugManager.log_player("StairStep Ignored: Collider is %s, Groups: %s" % [floor_collider.name if floor_collider is Node else floor_collider, floor_collider.get_groups() if floor_collider is Node else "None"])
			return
			
		var step_y = down_result.get_travel().y
		# The travel vector is how far down it moved before hitting. 
		# We started MAX_STEP_HEIGHT above feet. So if it travels down less than MAX_STEP_HEIGHT,
		# the floor is higher than our current feet.
		
		var diff = MAX_STEP_HEIGHT + step_y # step_y is negative
		
		if diff > 0.05 and diff <= MAX_STEP_HEIGHT:
			var cam = player.get_node_or_null("Camera3D")
			if cam:
				cam.position.y -= diff 
			
			var new_pos = player.global_position
			new_pos.y += diff + 0.001 
			
			# We DO NOT nudge the player forward here. 
			# Adding forward position mathematically causes "hyper speed" climbing on steep, stepped terrain
			# (like a mountain) because it bypasses collision velocity limits. 
			# By only lifting the player up, `move_and_slide` on the NEXT physics frame 
			# will naturally move them forward using their preserved input velocity now that the wall is gone.
			
			player.global_position = new_pos
			is_stair_stepping = true

func current_speed() -> float:
	var is_crouching = crouch.is_crouching if crouch else false
	if is_crouching: return crouch.get_speed() if crouch else WALK_SPEED
	elif is_sprinting: return SPRINT_SPEED
	else: return WALK_SPEED

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
		_emit_underwater_toggled(true)
	elif not is_swimming and was_swimming:
		_emit_underwater_toggled(false)
		# Jump out of water if holding jump
		if Input.is_action_pressed("ui_accept"):
			player.velocity.y = JUMP_VELOCITY

func _emit_underwater_toggled(is_underwater: bool) -> void:
	if signals and signals.has_signal("underwater_toggled"):
		signals.underwater_toggled.emit(is_underwater)
	# Backward compat
	if has_node("/root/PlayerSignals"):
		PlayerSignals.underwater_toggled.emit(is_underwater)

func _handle_walking(delta: float) -> void:
	# Update crouch component (if available)
	if crouch:
		crouch.update(delta)
	
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
		_emit_jumped()

func _emit_jumped() -> void:
	if signals and signals.has_signal("player_jumped"):
		signals.player_jumped.emit()
	# Backward compat
	if has_node("/root/PlayerSignals"):
		PlayerSignals.player_jumped.emit()

func handle_movement() -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (player.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	# Check crouch state from crouch component
	var is_crouching = crouch.is_crouching if crouch else false
	
	# Can't sprint while crouching
	if is_crouching:
		is_sprinting = false
	else:
		# Check for sprint (Shift key)
		# On floor: sprint if holding shift and moving
		# In air: preserve sprint if still holding shift (momentum preservation)
		if player.is_on_floor():
			is_sprinting = Input.is_action_pressed("sprint") and direction != Vector3.ZERO
		else:
			# In air: keep sprinting if still holding shift (preserves jump momentum)
			if not Input.is_action_pressed("sprint"):
				is_sprinting = false
	
	# Select speed based on state: crouch < walk < sprint
	var current_speed: float
	if is_crouching:
		current_speed = crouch.get_speed() if crouch else WALK_SPEED
	elif is_sprinting:
		current_speed = SPRINT_SPEED
	else:
		current_speed = WALK_SPEED
	
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
	# If we are being forced up a step by the custom stair script, 
	# Godot might temporarily think we are airborne.
	# We force 'on_floor_now' to be true here so we don't trigger a landing sound next frame.
	var on_floor_now = player.is_on_floor() or is_stair_stepping
	
	if on_floor_now and not was_on_floor:
		_emit_landed()
		# Play footstep on landing too
		_play_random_footstep()
		
	was_on_floor = on_floor_now

func _emit_landed() -> void:
	if signals and signals.has_signal("player_landed"):
		signals.player_landed.emit()
	# Backward compat
	if has_node("/root/PlayerSignals"):
		PlayerSignals.player_landed.emit()
