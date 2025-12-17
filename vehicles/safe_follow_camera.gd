extends "res://addons/srcoder_simplecar/assets/scripts/follow_camera.gd"
## Extended follow camera with hybrid mouse look.
## Follows the car but allows mouse offset that gradually returns to center.
## Does NOT modify the addon - inherits and overrides.

# Mouse look settings
@export_category("Mouse Look Settings")
@export var mouse_sensitivity: float = 0.003
@export var return_speed: float = 2.0
@export var max_pitch: float = 45.0
@export var min_pitch: float = -30.0

# Zoom settings
@export_category("Zoom Settings")
@export var zoom_speed: float = 2.0
@export var min_distance: float = 3.0
@export var max_distance: float = 20.0

# Reference to the actual camera
var camera_node: Camera3D = null
var spring_arm: SpringArm3D = null

# Current yaw offset applied to pivot (in radians)  
var current_yaw: float = 0.0


func _ready() -> void:
	super._ready()
	set_process_input(true)
	
	# Get references to camera and spring arm
	camera_node = get_node_or_null("Pivot/SpringArm3D/Camera3D")
	spring_arm = get_node_or_null("Pivot/SpringArm3D")
	print("[VehicleCam] Ready - camera: %s, spring_arm: %s" % [camera_node, spring_arm])


func _input(event: InputEvent) -> void:
	if not camera_node:
		return
	
	# Mouse wheel zoom
	if event is InputEventMouseButton and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if spring_arm:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
				# Zoom in (reduce distance)
				spring_arm.spring_length = clampf(spring_arm.spring_length - zoom_speed, min_distance, max_distance)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
				# Zoom out (increase distance)
				spring_arm.spring_length = clampf(spring_arm.spring_length + zoom_speed, min_distance, max_distance)
	
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		# Apply yaw (horizontal) to pivot - like player camera rotates parent
		if pivot:
			pivot.rotate_y(-event.relative.x * mouse_sensitivity)
			current_yaw = pivot.rotation.y
		
		# Apply pitch (vertical) to camera - like player camera
		camera_node.rotate_object_local(Vector3.RIGHT, -event.relative.y * mouse_sensitivity)
		
		# Clamp pitch
		camera_node.rotation.x = clamp(camera_node.rotation.x, deg_to_rad(min_pitch), deg_to_rad(max_pitch))


func _physics_process(delta: float) -> void:
	if not follow_target or not is_instance_valid(follow_target):
		return
	
	# Follow position
	global_position = follow_target.global_position
	
	# Calculate base car direction (horizontal only)
	var target_horizontal_direction = follow_target.global_basis.z.slide(Vector3.UP).normalized()
	var desired_basis = Basis.looking_at(-target_horizontal_direction)
	
	# Velocity-based camera lag - the faster we go, the more the camera lags behind
	# This creates a cinematic feel where the camera smoothly follows during turns
	var velocity = follow_target.linear_velocity if follow_target is RigidBody3D else Vector3.ZERO
	var speed = velocity.length()
	
	# Base damping is low (0.3) and gets even lower at high speeds
	# At 0 speed: damping = 0.3 (fairly responsive)
	# At 20+ m/s: damping = 0.1 (very floaty/laggy)
	var speed_factor = clampf(speed / 30.0, 0.0, 1.0)  # 0-1 based on speed up to 30 m/s
	var effective_damping = lerpf(0.4, 0.15, speed_factor)  # Lower values = more lag
	
	# Smoothly rotate base towards car direction
	global_basis = global_basis.slerp(desired_basis, effective_damping * delta)
	
	# Gradually return yaw to zero (auto-center horizontal)
	if pivot and return_speed > 0:
		pivot.rotation.y = move_toward(pivot.rotation.y, 0.0, return_speed * delta)
	
	# Gradually return pitch to zero (auto-center vertical)
	if camera_node and return_speed > 0:
		camera_node.rotation.x = move_toward(camera_node.rotation.x, 0.0, return_speed * delta * 0.5)
