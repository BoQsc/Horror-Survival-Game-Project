extends CharacterBody3D

class_name PlayerController

# Configuration
const WALK_SPEED = 5.0
const SPRINT_SPEED = 8.0 # Added Sprint
const SWIM_SPEED = 4.0
const FLY_SPEED = 15.0
const JUMP_VELOCITY = 4.5
const GRAVITY_MULTIPLIER = 1.0

# Dependencies
@onready var camera: Camera3D = $Camera3D
# We expect TerrainManager to be in the scene. 
# In the new structure, we might want to find it more robustly or use a global reference.
# For now, we search relative or via group.
var terrain_manager: Node = null

# State
enum State {IDLE, WALK, SPRINT, AIR, SWIM, FLY}
var current_state: State = State.IDLE
var is_flying_toggle: bool = false

# System
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

func _ready() -> void:
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if not terrain_manager:
		printerr("PlayerController: TerrainManager not found!")

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F:
		toggle_flight_mode()

func _physics_process(delta: float) -> void:
	update_state_logic(delta)
	move_and_slide()

func update_state_logic(delta: float) -> void:
	# 1. Check Environmental Conditions (Water)
	var in_water = check_water_immersion()
	
	# 2. Determine State Transition
	if is_flying_toggle:
		set_state(State.FLY)
	elif in_water:
		set_state(State.SWIM)
	else:
		if is_on_floor():
			if Input.is_action_pressed("move_forward") or Input.is_action_pressed("move_backward") or \
			   Input.is_action_pressed("move_left") or Input.is_action_pressed("move_right"):
				if Input.is_key_pressed(KEY_SHIFT):
					set_state(State.SPRINT)
				else:
					set_state(State.WALK)
			else:
				set_state(State.IDLE)
		else:
			set_state(State.AIR)

	# 3. Apply Forces/Velocity based on State
	match current_state:
		State.IDLE:
			process_ground_movement(delta, 0.0)
		State.WALK:
			process_ground_movement(delta, WALK_SPEED)
		State.SPRINT:
			process_ground_movement(delta, SPRINT_SPEED)
		State.AIR:
			process_air_movement(delta)
		State.SWIM:
			process_swim_movement(delta)
		State.FLY:
			process_fly_movement(delta)

func set_state(new_state: State) -> void:
	if current_state == new_state:
		return
	
	# Exit logic (if any)
	if current_state == State.SWIM and new_state == State.AIR:
		# Jump out of water boost
		if Input.is_action_pressed("ui_accept"):
			velocity.y = JUMP_VELOCITY
			
	if current_state == State.SWIM and new_state != State.SWIM:
		# Reset any water drag if needed?
		pass
		
	# Enter logic (if any)
	if new_state == State.SWIM and current_state != State.SWIM:
		velocity.y *= 0.1 # Dampen entry impact
		
	current_state = new_state

# --- Environmental Checks ---
func check_water_immersion() -> bool:
	if not terrain_manager:
		return false
		
	# Physics CoM approximation
	var center_pos = global_position + Vector3(0, 0.9, 0)
	var body_density = terrain_manager.get_water_density(center_pos)
	
	# Update Camera Underwater Effect
	if camera:
		var cam_check_pos = camera.global_position - Vector3(0, 0.5, 0)
		var cam_density = terrain_manager.get_water_density(cam_check_pos)
		var ui = get_node_or_null("../UI/UnderwaterEffect")
		if ui:
			ui.visible = cam_density < 0.0
			
	return body_density < 0.0

# --- Movement Processors ---
func process_ground_movement(delta: float, speed: float) -> void:
	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * GRAVITY_MULTIPLIER * delta
		
	# Jump
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY
		# Prevent immediate snap back to ground
		set_state(State.AIR)
		return

	# Friction/Movement
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

func process_air_movement(delta: float) -> void:
	# Gravity
	velocity.y -= gravity * GRAVITY_MULTIPLIER * delta
	
	# Air Control (Usually less than ground, but we'll keep it responsive for now)
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		velocity.x = move_toward(velocity.x, direction.x * WALK_SPEED, WALK_SPEED * delta * 2.0)
		velocity.z = move_toward(velocity.z, direction.z * WALK_SPEED, WALK_SPEED * delta * 2.0)

func process_swim_movement(delta: float) -> void:
	# Buoyancy / Drag
	velocity = velocity.move_toward(Vector3.ZERO, 2.0 * delta)
	
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	# Swim in camera direction
	var cam_basis = camera.global_transform.basis
	var direction = (cam_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		velocity += direction * SWIM_SPEED * delta * 5.0
		if velocity.length() > SWIM_SPEED:
			velocity = velocity.normalized() * SWIM_SPEED
			
	# Surface logic
	if Input.is_action_pressed("ui_accept"):
		velocity.y += 5.0 * delta

func process_fly_movement(_delta: float) -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var cam_basis = camera.global_transform.basis
	var direction = (cam_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	velocity = Vector3.ZERO
	if direction:
		velocity = direction * FLY_SPEED
		
	if Input.is_action_pressed("ui_accept"):
		velocity.y = FLY_SPEED
	if Input.is_key_pressed(KEY_SHIFT):
		velocity.y = - FLY_SPEED

func toggle_flight_mode() -> void:
	is_flying_toggle = !is_flying_toggle
	print("Fly mode: ", "ON" if is_flying_toggle else "OFF")

# Hooks for interaction raycast?
# The interaction controller is typically a child node scanning where the camera looks.
# We can expose the viewing direction or camera easily if needed.
func get_view_basis() -> Basis:
	return camera.global_transform.basis
