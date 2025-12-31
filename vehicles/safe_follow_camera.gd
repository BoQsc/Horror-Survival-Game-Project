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
@export var follow_smoothness: float = 8.0
@export var rotation_smoothness: float = 4.0

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
	
	# Find the actual Camera3D node
	camera_node = find_child("Camera3D", true, false)
	if not camera_node:
		camera_node = get_node_or_null("Pivot/SpringArm3D/Camera3D")
	
	# CRITICAL: Make camera completely independent of parent transforms
	if camera_node:
		camera_node.top_level = true
	
	# Initialize camera position
	if follow_target and is_instance_valid(follow_target):
		cam_position = follow_target.global_position + Vector3(0, follow_height, follow_distance)
		var car_forward = -follow_target.global_transform.basis.z
		car_forward.y = 0
		if car_forward.length() > 0.1:
			target_yaw = atan2(car_forward.x, car_forward.z)
			current_yaw = target_yaw
		# Immediately position camera
		if camera_node:
			camera_node.global_position = cam_position
			camera_node.look_at(follow_target.global_position + Vector3(0, 1, 0), Vector3.UP)
	
	print("[VehicleCam] GTA5-style ready - camera: %s, top_level: %s" % [camera_node, camera_node.top_level if camera_node else false])


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
	
	# Get car's forward direction (Y rotation only, stay level)
	var car_forward = -follow_target.global_transform.basis.z
	car_forward.y = 0
	if car_forward.length() > 0.1:
		car_forward = car_forward.normalized()
		target_yaw = atan2(car_forward.x, car_forward.z)
	
	# Mouse idle timer - return to behind car
	if is_mouse_looking:
		mouse_idle_timer += delta
		if mouse_idle_timer > 1.0:
			mouse_offset_yaw = lerp(mouse_offset_yaw, 0.0, return_speed * delta)
			mouse_offset_pitch = lerp(mouse_offset_pitch, 0.0, return_speed * delta)
			if abs(mouse_offset_yaw) < 0.01 and abs(mouse_offset_pitch) < 0.01:
				is_mouse_looking = false
	
	# Smooth rotation to follow car + mouse offset
	var desired_yaw = target_yaw + mouse_offset_yaw
	current_yaw = lerp_angle(current_yaw, desired_yaw, rotation_smoothness * delta)
	
	# Calculate camera position (orbit around car)
	var offset = Vector3.ZERO
	offset.x = sin(current_yaw) * follow_distance
	offset.z = cos(current_yaw) * follow_distance
	offset.y = follow_height
	
	# Smooth position follow
	var target_pos = follow_target.global_position + offset
	cam_position = cam_position.lerp(target_pos, follow_smoothness * delta)
	
	# Look target
	var look_target = follow_target.global_position + Vector3(0, 1.0, 0)
	
	# DIRECTLY set camera transform (top_level=true ensures this sticks)
	camera_node.global_position = cam_position
	camera_node.look_at(look_target, Vector3.UP)
	camera_node.rotate_object_local(Vector3.RIGHT, mouse_offset_pitch)
