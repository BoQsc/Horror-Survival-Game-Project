extends Node

@export var terrain_manager: Node3D
@export var building_manager: Node3D

@onready var mode_label: Label = $"../../../UI/ModeLabel"
@onready var camera: Camera3D = $".."
@onready var selection_box: MeshInstance3D = $"../../../SelectionBox"
@onready var player = $"../.."

enum Mode { TERRAIN, BUILDING }
var current_mode: Mode = Mode.TERRAIN
var current_block_id: int = 1
var current_rotation: int = 0

var current_voxel_pos: Vector3
var current_remove_voxel_pos: Vector3
var has_target: bool = false

func _ready():
	update_ui()

func _process(_delta):
	if current_mode == Mode.BUILDING:
		update_selection_box()
	else:
		selection_box.visible = false

func _unhandled_input(event):
	if event.is_action_pressed("ui_focus_next"): # Tab
		toggle_mode()
	
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_1:
			current_block_id = 1
			update_ui()
		elif event.keycode == KEY_2:
			current_block_id = 2
			update_ui()
		elif event.keycode == KEY_3:
			current_block_id = 3
			update_ui()
		elif event.keycode == KEY_4:
			current_block_id = 4
			update_ui()
	
	if event is InputEventMouseButton:
		if event.pressed:
			if event.ctrl_pressed:
				if event.button_index == MOUSE_BUTTON_WHEEL_UP:
					current_rotation = (current_rotation + 1) % 4
					update_ui()
				elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					current_rotation = (current_rotation - 1 + 4) % 4
					update_ui()
			elif Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
				if current_mode == Mode.TERRAIN:
					handle_terrain_input(event)
				elif current_mode == Mode.BUILDING and has_target:
					handle_building_input(event)

func toggle_mode():
	if current_mode == Mode.TERRAIN:
		current_mode = Mode.BUILDING
	else:
		current_mode = Mode.TERRAIN
	update_ui()

func update_ui():
	if current_mode == Mode.TERRAIN:
		mode_label.text = "Mode: TERRAIN (Smooth)\nL-Click: Dig, R-Click: Place"
	else:
		var block_name = "Cube"
		if current_block_id == 2: block_name = "Ramp"
		elif current_block_id == 3: block_name = "Sphere"
		elif current_block_id == 4: block_name = "Stairs"
		
		mode_label.text = "Mode: BUILDING (Blocky)\nBlock: %s (Rot: %d)\nL-Click: Remove, R-Click: Add\nCTRL+Scroll: Rotate" % [block_name, current_rotation]

func update_selection_box():
	var terrain_hit = raycast(10.0)
	var voxel_hit = raycast_voxel_grid(camera.global_position, -camera.global_transform.basis.z, 10.0)
	
	var final_hit_pos = Vector3.ZERO
	var final_normal = Vector3.ZERO
	var is_voxel_hit = false
	
	# Determine which hit to use
	if voxel_hit and terrain_hit:
		# Bias towards voxel hit slightly to prioritize block side placement
		# 0.1 margin allows selecting blocks even if slightly occluded by rough terrain mesh
		if voxel_hit.distance <= terrain_hit.position.distance_to(camera.global_position) + 0.1:
			is_voxel_hit = true
		else:
			is_voxel_hit = false
	elif voxel_hit:
		is_voxel_hit = true
	elif terrain_hit:
		is_voxel_hit = false
	
	if is_voxel_hit:
		current_remove_voxel_pos = voxel_hit.voxel_pos
		current_voxel_pos = voxel_hit.voxel_pos + voxel_hit.normal
		
		selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
		selection_box.visible = true
		has_target = true
	elif terrain_hit:
		var pos = terrain_hit.position
		var normal = terrain_hit.normal
		
		# Terrain placement logic
		var check_pos = pos + normal * 0.01
		var voxel_x = floor(check_pos.x)
		var voxel_y = floor(check_pos.y)
		var voxel_z = floor(check_pos.z)
		
		current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
		# For terrain hit, remove target is vaguely defined, assume same as placement for now or invalid
		current_remove_voxel_pos = current_voxel_pos # Probably won't hit anything if empty
		
		selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
		selection_box.visible = true
		has_target = true
	else:
		selection_box.visible = false
		has_target = false

func handle_terrain_input(event):
	var hit = raycast(100.0)
	if hit:
		if event.button_index == MOUSE_BUTTON_LEFT:
			terrain_manager.modify_terrain(hit.position, 4.0, 1.0) # Dig
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			terrain_manager.modify_terrain(hit.position, 4.0, -1.0) # Place

func handle_building_input(event):
	# current_voxel_pos is the GHOST block (Placement Target)
	# current_remove_voxel_pos is the SOLID block (Removal Target)
	
	if event.button_index == MOUSE_BUTTON_RIGHT: # Add
		# Place at the ghost position
		building_manager.set_voxel(current_voxel_pos, current_block_id, current_rotation)
		
	elif event.button_index == MOUSE_BUTTON_LEFT: # Remove
		# Remove the block that was highlighted
		building_manager.set_voxel(current_remove_voxel_pos, 0.0)

func raycast(length: float):
	var space_state = camera.get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from - camera.global_transform.basis.z * length
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player.get_rid()]
	return space_state.intersect_ray(query)

func raycast_voxel_grid(origin: Vector3, direction: Vector3, max_dist: float):
	# Normalize direction just in case, though usually it is.
	direction = direction.normalized()
	
	var x = floor(origin.x)
	var y = floor(origin.y)
	var z = floor(origin.z)

	var step_x = sign(direction.x)
	var step_y = sign(direction.y)
	var step_z = sign(direction.z)

	var t_delta_x = 1.0 / abs(direction.x) if direction.x != 0 else 1e30
	var t_delta_y = 1.0 / abs(direction.y) if direction.y != 0 else 1e30
	var t_delta_z = 1.0 / abs(direction.z) if direction.z != 0 else 1e30

	var t_max_x
	if direction.x > 0: t_max_x = (floor(origin.x) + 1 - origin.x) * t_delta_x
	else: t_max_x = (origin.x - floor(origin.x)) * t_delta_x
	if abs(direction.x) < 0.00001: t_max_x = 1e30
	
	var t_max_y
	if direction.y > 0: t_max_y = (floor(origin.y) + 1 - origin.y) * t_delta_y
	else: t_max_y = (origin.y - floor(origin.y)) * t_delta_y
	if abs(direction.y) < 0.00001: t_max_y = 1e30

	var t_max_z
	if direction.z > 0: t_max_z = (floor(origin.z) + 1 - origin.z) * t_delta_z
	else: t_max_z = (origin.z - floor(origin.z)) * t_delta_z
	if abs(direction.z) < 0.00001: t_max_z = 1e30
	
	var normal = Vector3.ZERO
	var t = 0.0
	
	# Prevent infinite loops
	var max_steps = 100
	var steps = 0
	
	while t < max_dist and steps < max_steps:
		steps += 1
		# Check current voxel (don't check origin if inside a block? maybe we do want to)
		# If we are inside a block, normal is inverted or zero.
		# But usually camera is outside.
		if building_manager.get_voxel(Vector3(x, y, z)) > 0:
			return {
				"voxel_pos": Vector3(x, y, z),
				"normal": normal,
				"position": origin + direction * t,
				"distance": t
			}
			
		if t_max_x < t_max_y:
			if t_max_x < t_max_z:
				x += step_x
				t = t_max_x
				t_max_x += t_delta_x
				normal = Vector3(-step_x, 0, 0)
			else:
				z += step_z
				t = t_max_z
				t_max_z += t_delta_z
				normal = Vector3(0, 0, -step_z)
		else:
			if t_max_y < t_max_z:
				y += step_y
				t = t_max_y
				t_max_y += t_delta_y
				normal = Vector3(0, -step_y, 0)
			else:
				z += step_z
				t = t_max_z
				t_max_z += t_delta_z
				normal = Vector3(0, 0, -step_z)
				
	return null
