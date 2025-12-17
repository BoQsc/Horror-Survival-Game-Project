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
	
	# Follow position only
	global_position = follow_target.global_position
	
	# COUNTER-ROTATE: Cancel out the car's rotation completely
	# Get the car's Y rotation and apply the INVERSE to this node
	# This makes the camera maintain world-space orientation
	var car_y_rotation = follow_target.global_rotation.y
	global_rotation.y = -car_y_rotation + current_yaw
	global_rotation.x = 0
	global_rotation.z = 0

