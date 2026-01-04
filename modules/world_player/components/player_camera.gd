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
# State
# State
var is_camera_underwater: bool = false

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
	DebugManager.log_player("PlayerCamera: Component initialized")
	DebugManager.log_player("  - Player: %s" % player.name)
	DebugManager.log_player("  - Camera: %s" % camera.name)

	DebugManager.log_player("  - Player: %s" % player.name)
	DebugManager.log_player("  - Camera: %s" % camera.name)

func _physics_process(_delta: float) -> void:
	check_underwater_visuals()

func check_underwater_visuals() -> void:
	if not player or not camera:
		return
		
	# Access terrain manager from player (WorldPlayer)
	if not "terrain_manager" in player:
		return
		
	var tm = player.terrain_manager
	if not tm or not tm.has_method("get_water_density"):
		return
		
	# Sample density at a point BELOW camera to compensate for water mesh being above density=0
	# The water mesh is rendered ~0.5 units above where density crosses 0 (matched to character_body_3d.gd)
	var cam_check_pos = camera.global_position - Vector3(0, 0.5, 0)
	var cam_density = tm.get_water_density(cam_check_pos)
	var currently_underwater = cam_density < 0.0
	
	if currently_underwater != is_camera_underwater:
		is_camera_underwater = currently_underwater
		PlayerSignals.camera_underwater_toggled.emit(is_camera_underwater)

func _input(event: InputEvent) -> void:
	# Toggle menu with Escape
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		# First, check if inventory is open - close it instead of opening menu
		var inventory = _get_inventory()
		if inventory and inventory.is_open:
			inventory.close_inventory()
			return
		
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			# Open menu, release mouse
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			PlayerSignals.game_menu_toggled.emit(true)
		else:
			# Close menu, capture mouse
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			PlayerSignals.game_menu_toggled.emit(false)
	
	# Handle mouse look
	if not player or not camera:
		return
	
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		handle_mouse_look(event.relative)

## Get inventory reference from player
func _get_inventory() -> Node:
	if player:
		return player.get_node_or_null("Systems/Inventory")
	return null

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
func raycast(distance: float = 10.0, collision_mask: int = 0xFFFFFFFF, collide_with_areas: bool = false, exclude_water: bool = false) -> Dictionary:
	if not camera:
		DebugManager.log_player("PlayerCamera: raycast - no camera!")
		return {}
	
	var space_state = player.get_world_3d().direct_space_state
	
	# Use camera position and direction for raycast
	var from = camera.global_position
	var direction = - camera.global_transform.basis.z
	var to = from + direction * distance
	
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	query.collide_with_areas = collide_with_areas
	query.exclude = [player]
	
	if exclude_water:
		# Cast ray, if we hit water, continue through it
		var result = space_state.intersect_ray(query)
		while result and result.collider and result.collider.is_in_group("water"):
			# Add hit collider to exclude list and raycast again from hit point
			query.exclude.append(result.collider.get_rid())
			query.from = result.position + direction * 0.01 # Move slightly past
			result = space_state.intersect_ray(query)
		return result
	
	return space_state.intersect_ray(query)
