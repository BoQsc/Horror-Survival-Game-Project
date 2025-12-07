extends CharacterBody3D

const WALK_SPEED = 5.0
const SWIM_SPEED = 4.0
const JUMP_VELOCITY = 4.5

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var water_overlap_count: int = 0
var is_swimming: bool = false

@onready var camera = $Camera3D

func _ready():
	# Create Water Detector
	var area = Area3D.new()
	area.name = "WaterDetector"
	# Monitorable false (we don't want others to detect us via this area), Monitoring true (we detect water)
	area.monitorable = false
	area.monitoring = true
	
	var collision = CollisionShape3D.new()
	var cap = CapsuleShape3D.new()
	cap.radius = 0.5
	cap.height = 1.8 # Match player height roughly
	collision.shape = cap
	# Move up slightly to center on body (CharacterBody usually pivots at feet or center? 
	# Standard Godot CharacterBody3D usually pivots at feet if collision shape is moved up, 
	# but if just Shape, it centers on origin. 
	# Let's assume origin is at feet for now based on scene transform y=127.
	# Actually, usually CapsuleShape is centered. 
	# If I add it as child, it centers on Player origin. 
	# Let's verify PlayerShape in scene.
	
	area.add_child(collision)
	add_child(area)
	
	area.area_entered.connect(_on_water_entered)
	area.area_exited.connect(_on_water_exited)

func _on_water_entered(area):
	if area.is_in_group("water"):
		water_overlap_count += 1
		check_swimming_state()

func _on_water_exited(area):
	if area.is_in_group("water"):
		water_overlap_count -= 1
		check_swimming_state()

func check_swimming_state():
	var was_swimming = is_swimming
	is_swimming = water_overlap_count > 0
	
	if is_swimming and not was_swimming:
		# Entered water
		velocity.y *= 0.1 # Dampen entry impact
	elif not is_swimming and was_swimming:
		# Exited water
		if Input.is_action_pressed("ui_accept"): # Jumping out
			velocity.y = JUMP_VELOCITY 

func _physics_process(delta: float) -> void:
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