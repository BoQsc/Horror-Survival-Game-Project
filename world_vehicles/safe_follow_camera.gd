extends Node3D
## GTA5-style vehicle camera - orbits around the CAR.
## Controls THIS node's position/rotation, lets SpringArm handle camera.

@export var follow_target: Node3D

# Camera settings
@export_category("Follow Settings")
@export var follow_distance: float = 8.0
@export var follow_height: float = 2.0
@export var rotation_smoothing: float = 8.0  # Higher = snappier, Lower = more lag

# Mouse orbit settings  
@export_category("Mouse Orbit Settings")
@export var mouse_sensitivity: float = 0.003
@export var return_speed: float = 2.0
@export var return_delay: float = 5.0  # Wait 5 seconds before auto-return
@export var max_pitch_deg: float = 60.0
@export var min_pitch_deg: float = -20.0

# Zoom settings
@export_category("Zoom Settings")
@export var zoom_speed: float = 2.0
@export var min_distance: float = 4.0
@export var max_distance: float = 20.0

# State
var orbit_yaw: float = 0.0      # Actual camera rotation (smoothed)
var target_orbit_yaw: float = 0.0  # Target rotation (follows car + mouse)
var orbit_pitch: float = -0.27   # Match original scene Pivot angle (~15 degrees down)
var mouse_idle_timer: float = 0.0
var last_car_yaw: float = 0.0

# Child nodes
@onready var pivot: Node3D = $Pivot
@onready var springarm: SpringArm3D = $Pivot/SpringArm3D


func _ready() -> void:
	set_process_input(true)
	
	if not follow_target:
		follow_target = get_parent()
	
	# Configure spring arm for our distance
	if springarm:
		springarm.spring_length = follow_distance
	if pivot:
		pivot.position.y = follow_height
	
	# Initialize orbit yaw to be behind car
	if follow_target:
		var car_forward = -follow_target.global_transform.basis.z
		car_forward.y = 0
		if car_forward.length() > 0.1:
			orbit_yaw = atan2(car_forward.x, car_forward.z)
			target_orbit_yaw = orbit_yaw
			last_car_yaw = orbit_yaw
	
	print("[VehicleCam] Ready - controlling FollowCamera node, target: %s" % follow_target)


func _input(event: InputEvent) -> void:
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	
	# Zoom with mouse wheel
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			follow_distance = clampf(follow_distance - zoom_speed, min_distance, max_distance)
			if springarm:
				springarm.spring_length = follow_distance
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			follow_distance = clampf(follow_distance + zoom_speed, min_distance, max_distance)
			if springarm:
				springarm.spring_length = follow_distance
	
	# Mouse orbit
	if event is InputEventMouseMotion:
		target_orbit_yaw -= event.relative.x * mouse_sensitivity
		orbit_pitch -= event.relative.y * mouse_sensitivity
		orbit_pitch = clamp(orbit_pitch, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
		mouse_idle_timer = 0.0


func _physics_process(delta: float) -> void:
	if not follow_target or not is_instance_valid(follow_target):
		return
	
	# === TRACK CAR ROTATION ===
	var car_forward = -follow_target.global_transform.basis.z
	car_forward.y = 0
	if car_forward.length() > 0.1:
		var current_car_yaw = atan2(car_forward.x, car_forward.z)
		var car_yaw_delta = current_car_yaw - last_car_yaw
		
		# Handle wrap-around
		if car_yaw_delta > PI:
			car_yaw_delta -= TAU
		elif car_yaw_delta < -PI:
			car_yaw_delta += TAU
		
		# Apply CHANGE in car rotation to TARGET (preserves mouse offset)
		target_orbit_yaw += car_yaw_delta
		last_car_yaw = current_car_yaw
	
	# === SMOOTH INTERPOLATION ===
	# This creates the lag when the car turns
	var yaw_diff = target_orbit_yaw - orbit_yaw
	# Handle wrap-around for shortest path
	if yaw_diff > PI:
		yaw_diff -= TAU
	elif yaw_diff < -PI:
		yaw_diff += TAU
	orbit_yaw += yaw_diff * rotation_smoothing * delta
	
	
	# === AUTO-RETURN (DISABLED - was fighting with camera lag) ===
	# mouse_idle_timer += delta
	# if mouse_idle_timer > return_delay:
	# 	var behind_yaw = last_car_yaw
	# 	var yaw_diff = behind_yaw - orbit_yaw
	# 	if yaw_diff > PI:
	# 		yaw_diff -= TAU
	# 	elif yaw_diff < -PI:
	# 		yaw_diff += TAU
	# 	orbit_yaw += yaw_diff * return_speed * delta
	# 	orbit_pitch = lerp(orbit_pitch, -0.27, return_speed * delta)
	
	# === POSITION THIS NODE AT CAR ===
	global_position = follow_target.global_position
	
	# === ROTATE THIS NODE TO ORBIT YAW (smoothed above) ===
	# This rotates the entire Pivot/SpringArm/Camera hierarchy around the car
	var target_basis = Basis.looking_at(Vector3(sin(orbit_yaw), 0, cos(orbit_yaw)), Vector3.UP)
	global_basis = target_basis
	
	# === APPLY PITCH TO PIVOT ===
	if pivot:
		pivot.rotation.x = -orbit_pitch
