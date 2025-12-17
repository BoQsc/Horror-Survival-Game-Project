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

# Reference to the actual camera
var camera_node: Camera3D = null

# Current yaw offset applied to pivot (in radians)  
var current_yaw: float = 0.0


func _ready() -> void:
	super._ready()
	set_process_input(true)
	
	# Get reference to the camera
	camera_node = get_node_or_null("Pivot/SpringArm3D/Camera3D")
	print("[VehicleCam] Ready - camera: %s, pivot: %s" % [camera_node, pivot])


func _input(event: InputEvent) -> void:
	if not camera_node:
		return
		
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
	
	# Smoothly rotate base towards car direction
	global_basis = global_basis.slerp(desired_basis, rotation_damping * delta)
	
	# Gradually return yaw to zero (auto-center horizontal)
	if pivot and return_speed > 0:
		pivot.rotation.y = move_toward(pivot.rotation.y, 0.0, return_speed * delta)
	
	# Gradually return pitch to zero (auto-center vertical)
	if camera_node and return_speed > 0:
		camera_node.rotation.x = move_toward(camera_node.rotation.x, 0.0, return_speed * delta * 0.5)
