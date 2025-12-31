extends Node3D
## GTA5-style vehicle camera.
## - Stays perfectly level (no pitch/roll from car)
## - Smoothly follows behind the car
## - Free mouse look that gradually returns to behind car

@export var follow_target: Node3D

# Camera follow settings
@export_category("Follow Settings")
@export var follow_distance: float = 8.0
@export var follow_height: float = 3.0
@export var follow_smoothness: float = 15.0  # Higher = tighter follow
@export var rotation_smoothness: float = 20.0  # Much snappier rotation

# Mouse look settings
@export_category("Mouse Look Settings")
@export var mouse_sensitivity: float = 0.003
@export var return_speed: float = 1.5
@export var max_pitch: float = 45.0
@export var min_pitch: float = -20.0

# Zoom settings
@export_category("Zoom Settings")
@export var zoom_speed: float = 2.0
@export var min_distance: float = 4.0
@export var max_distance: float = 20.0

# Internal state
var target_yaw: float = 0.0
var current_yaw: float = 0.0
var mouse_offset_yaw: float = 0.0
var mouse_offset_pitch: float = 0.0
var is_mouse_looking: bool = false
var mouse_idle_timer: float = 0.0
var cam_position: Vector3 = Vector3.ZERO

# References
var camera_node: Camera3D = null


func _ready() -> void:
	set_process_input(true)
	
	# Get follow target - if not set, use parent (the car)
	if not follow_target:
		follow_target = get_parent()
	
	# Find the actual Camera3D node
	camera_node = find_child("Camera3D", true, false)
	if not camera_node:
		camera_node = get_node_or_null("Pivot/SpringArm3D/Camera3D")
	
	# CRITICAL: Make camera completely independent of parent transforms
	if camera_node:
		camera_node.top_level = true
	
	# Initialize camera position
	if follow_target and is_instance_valid(follow_target) and camera_node:
		var car_forward = -follow_target.global_transform.basis.z
		car_forward.y = 0
		if car_forward.length() < 0.1:
			car_forward = Vector3.FORWARD
		car_forward = car_forward.normalized()
		
		var cam_offset = car_forward * -follow_distance + Vector3(0, follow_height, 0)
		camera_node.global_position = follow_target.global_position + cam_offset
		camera_node.look_at(follow_target.global_position + Vector3(0, 1, 0), Vector3.UP)
	
	print("[VehicleCam] Ready - target: %s, camera: %s" % [follow_target, camera_node])


func _input(event: InputEvent) -> void:
	if not camera_node or Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	
	# Mouse wheel zoom
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			follow_distance = clampf(follow_distance - zoom_speed, min_distance, max_distance)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			follow_distance = clampf(follow_distance + zoom_speed, min_distance, max_distance)
	
	# Mouse look
	if event is InputEventMouseMotion:
		mouse_offset_yaw -= event.relative.x * mouse_sensitivity
		mouse_offset_pitch -= event.relative.y * mouse_sensitivity
		mouse_offset_pitch = clamp(mouse_offset_pitch, deg_to_rad(min_pitch), deg_to_rad(max_pitch))
		is_mouse_looking = true
		mouse_idle_timer = 0.0


func _physics_process(delta: float) -> void:
	if not follow_target or not is_instance_valid(follow_target) or not camera_node:
		return
	
	# Get car's forward direction (horizontal only)
	var car_forward = -follow_target.global_transform.basis.z
	car_forward.y = 0
	if car_forward.length() < 0.1:
		car_forward = Vector3.FORWARD
	car_forward = car_forward.normalized()
	
	# Camera position = directly behind car (NO SMOOTHING)
	var cam_offset = car_forward * follow_distance + Vector3(0, follow_height, 0)
	var target_pos = follow_target.global_position + cam_offset
	
	# Look at car
	var look_target = follow_target.global_position + Vector3(0, 1.0, 0)
	
	# FORCE camera position every frame
	camera_node.global_position = target_pos
	camera_node.look_at(look_target, Vector3.UP)
