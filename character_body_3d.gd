extends CharacterBody3D

const WALK_SPEED = 5.0
const SWIM_SPEED = 4.0
const JUMP_VELOCITY = 4.5

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var is_swimming: bool = false
var terrain_manager: Node = null

@onready var camera = $Camera3D

func _ready():
	terrain_manager = get_node_or_null("../TerrainManager")

func _physics_process(delta: float) -> void:
	if not terrain_manager:
		process_walking(delta)
		move_and_slide()
		return
		
	# Physics: Check Center of Mass
	# +0.9 is approx center of 1.8m player
	var center_pos = global_position + Vector3(0, 0.9, 0)
	var body_density = terrain_manager.get_water_density(center_pos)
	
	var was_swimming = is_swimming
	# Negative density means inside water
	is_swimming = body_density < 0.0
	
	if is_swimming and not was_swimming:
		velocity.y *= 0.1 # Dampen entry
	elif not is_swimming and was_swimming:
		if Input.is_action_pressed("ui_accept"):
			velocity.y = JUMP_VELOCITY # Jump out
	
	# Visuals: Check Camera Eye
	var cam_density = terrain_manager.get_water_density(camera.global_position)
	var is_cam_underwater = cam_density < 0.0
	
	var ui = get_node_or_null("../UI/UnderwaterEffect")
	if ui:
		ui.visible = is_cam_underwater

	if is_swimming:
		process_swimming(delta)
	else:
		process_walking(delta)
	
	move_and_slide()

func process_walking(delta: float):
	# Add the gravity.
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * WALK_SPEED
		velocity.z = direction.z * WALK_SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, WALK_SPEED)
		velocity.z = move_toward(velocity.z, 0, WALK_SPEED)

func process_swimming(delta: float):
	# Neutral buoyancy or slight sinking/floating
	# Let's apply a drag to existing velocity
	velocity = velocity.move_toward(Vector3.ZERO, 2.0 * delta)
	
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	# Swim in camera direction
	var cam_basis = camera.global_transform.basis
	var direction = (cam_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		velocity += direction * SWIM_SPEED * delta * 5.0 # Acceleration
		if velocity.length() > SWIM_SPEED:
			velocity = velocity.normalized() * SWIM_SPEED
	
	# Space to swim up (surface) explicitly
	if Input.is_action_pressed("ui_accept"):
		velocity.y += 5.0 * delta
