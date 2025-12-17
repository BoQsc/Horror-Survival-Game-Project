extends VehicleBody3D

@export_category("Car Settings")
## max steer in radians for the front wheels- defaults to 0.45
@export var max_steer : float = 0.45
## the maximum torque that the engine will sent to the rear wheels- defaults to 300
@export var max_torque : float = 300.0
## the maximum amount of braking force applied to the wheel. Default is 1.0
@export var max_brake_force : float = 1.0
## the maximum rear wheel rpm. The actual engine torque is scaled in a linear vector to ensure the rear wheels will never go beyond this given rpm.
## The default value is 600rpm
@export var max_wheel_rpm : float = 600.0
## How quickly the wheel responds to player input- equates to seconds to reach maximum steer. Default is 2.0
@export var steer_damping = 2.0
## How sticky are the front wheels. Default is 5. 0 is frictionless._add_constant_central_force
@export var front_wheel_grip : float = 5.0
## How sticky are the rear wheel. Default is 5. Try lower value for a more drift experience
@export var rear_wheel_grip : float = 5.0


#local member variables
var player_acceleration : float = 0.0
var player_braking : float = 0.0
var player_steer : float = 0.0
var player_input : Vector2 = Vector2.ZERO

#an exporetd array of driving wheels so we can limit rom of each wheel when we process input
@onready var driving_wheels : Array[VehicleWheel3D] = [$WheelBackLeft,$WheelBackRight]
@onready var steering_wheels : Array[VehicleWheel3D] = [$WheelFrontLeft,$WheelFrontRight]


func _ready() -> void:
	#set wheel friction slip
	for wheel in steering_wheels:
		wheel.wheel_friction_slip = front_wheel_grip
	for wheel in driving_wheels:
		wheel.wheel_friction_slip = rear_wheel_grip


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	get_input(delta)
	#now process steering and braking
	steering = player_steer
	brake = player_braking
	#cos we want to limit rpm- control each driving wheel individually
	for wheel in driving_wheels:
		#linearly reduce engine force based on the wheels current rpm and the player input
		var actual_force : float = player_acceleration * ((-max_torque/max_wheel_rpm) * abs(wheel.get_rpm()) + max_torque) 
		wheel.engine_force = actual_force


## sets the variables player_steer, player_brake and player_acceleration based on the player input
func get_input(delta : float):
	#steer first
	player_input.x = Input.get_axis("right","left")
	player_steer = move_toward(player_steer, player_input.x * max_steer,steer_damping * delta)
	#now acceleration and/or braking
	player_input.y = Input.get_axis("down","up")
	if player_input.y > 0.01:
		#accelerating
		player_acceleration = player_input.y
		player_braking = 0.0
	elif player_input.y < -0.01:
		#we are trying to brake or reverse
		if going_forward():
			#brake
			player_braking = -player_input.y * max_brake_force
			player_acceleration = 0.0
		else:
			#reverse
			player_braking = 0.0
			player_acceleration = player_input.y
	else:
		player_acceleration = 0.0
		player_braking = 0.0

## helper function to see if we are moving forward
func going_forward() -> bool:
	var relative_speed : float = basis.z.dot(linear_velocity.normalized())
	if relative_speed > 0.01:
		return true
	else:
		return false
	
