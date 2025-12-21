extends Node
class_name PlayerCamera
## PlayerCamera - Handles first-person camera control (mouse look)
## Controls camera pitch/yaw and provides raycast targeting.

# Sensitivity
const MOUSE_SENSITIVITY: float = 0.002
const PITCH_LIMIT: float = 89.0 # Degrees

# References
var player: CharacterBody3D = null
var camera: Camera3D = null

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("PlayerCamera: Must be child of Player/Components node")
		return
	
	# Find camera as sibling of Components node
	camera = player.get_node_or_null("Camera3D")
	if not camera:
		push_error("PlayerCamera: Camera3D not found as child of Player")
		return
	
	# Capture mouse
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	print("PlayerCamera: Component initialized")
	print("  - Player: %s" % player.name)
	print("  - Camera: %s" % camera.name)

func _input(event: InputEvent) -> void:
	# Toggle mouse capture with Escape
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# Handle mouse look
	if not player or not camera:
		return
	
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		handle_mouse_look(event.relative)

func handle_mouse_look(motion: Vector2) -> void:
	# Horizontal rotation (yaw) - rotate player body
	player.rotate_y(-motion.x * MOUSE_SENSITIVITY)
	
	# Vertical rotation (pitch) - rotate camera only
	camera.rotate_x(-motion.y * MOUSE_SENSITIVITY)
	
	# Clamp pitch to prevent flipping
	camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(-PITCH_LIMIT), deg_to_rad(PITCH_LIMIT))

## Get the camera's forward direction (for targeting)
func get_look_direction() -> Vector3:
	if camera:
		return -camera.global_transform.basis.z
	return Vector3.FORWARD

## Get the camera's global position
func get_camera_position() -> Vector3:
	if camera:
		return camera.global_position
	return Vector3.ZERO

## Perform a raycast from camera center
func raycast(distance: float = 10.0, collision_mask: int = 0xFFFFFFFF) -> Dictionary:
	if not camera:
		print("PlayerCamera: raycast - no camera!")
		return {}
	
	var space_state = player.get_world_3d().direct_space_state
	
	# Use camera position and direction for raycast
	var from = camera.global_position
	var direction = - camera.global_transform.basis.z
	var to = from + direction * distance
	
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	query.exclude = [player]
	
	var result = space_state.intersect_ray(query)
	
	if result.is_empty():
		print("PlayerCamera: raycast - no hit (range: %.1f)" % distance)
	else:
		print("PlayerCamera: raycast HIT %s at %s" % [result.collider.name, result.position])
	
	return result
