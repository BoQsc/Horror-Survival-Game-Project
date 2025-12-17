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

signal player_entered(player_node: Node3D)
signal player_exited(player_node: Node3D)


func _ready() -> void:
	super._ready()
	add_to_group("vehicle")
	add_to_group("interactable")  # For E key interaction
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	# Set collision layer 4 for vehicle detection (bit 3)
	collision_layer = collision_layer | (1 << 3)


func enter_vehicle(player_node: Node3D) -> void:
	occupant = player_node
	is_player_controlled = true
	player_entered.emit(player_node)


func exit_vehicle() -> Node3D:
	var exiting = occupant
	occupant = null
	is_player_controlled = false
	player_exited.emit(exiting)
	return exiting


## Override to use WASD controls and respect player control state
func get_input(delta: float) -> void:
	if not is_player_controlled:
		player_steer = 0.0
		player_acceleration = 0.0
		player_braking = 0.0
		return
	
	# WASD controls - override addon's up/down/left/right
	player_input.x = Input.get_axis("move_right", "move_left")
	player_steer = move_toward(player_steer, player_input.x * max_steer, steer_damping * delta)
	
	# W/S for forward/backward
	player_input.y = Input.get_axis("move_backward", "move_forward")
	if player_input.y > 0.01:
		# Accelerating forward
		player_acceleration = player_input.y
		player_braking = 0.0
	elif player_input.y < -0.01:
		# Trying to brake or reverse
		if going_forward():
			# Brake
			player_braking = -player_input.y * max_brake_force
			player_acceleration = 0.0
		else:
			# Reverse
			player_braking = 0.0
			player_acceleration = player_input.y
	else:
		player_acceleration = 0.0
		player_braking = 0.0


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	_apply_water_physics(delta)


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


## Interaction prompt for "Press E to..." system
func get_interaction_prompt() -> String:
	if is_player_controlled:
		return "Press E to exit vehicle"
	return "Press E to enter vehicle"


## Gets a safe position for player to exit (beside the vehicle)
func get_exit_position() -> Vector3:
	# Exit to the left side of the vehicle
	var exit_offset = global_transform.basis.x * -2.0  # 2 meters to the left
	return global_position + exit_offset + Vector3(0, 0.5, 0)


## Enable or disable the follow camera
func set_camera_active(active: bool) -> void:
	# Camera3D is nested inside: FollowCamera/Pivot/SpringArm3D/Camera3D
	var cam = get_node_or_null("FollowCamera/Pivot/SpringArm3D/Camera3D")
	if cam and cam is Camera3D:
		cam.current = active
		print("[Vehicle] Camera active: %s" % active)

