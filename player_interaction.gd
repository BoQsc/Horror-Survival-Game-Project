extends Node

@export var terrain_manager: Node3D
@export var building_manager: Node3D

@onready var mode_label: Label = $"../../../UI/ModeLabel"
@onready var camera: Camera3D = $".."
@onready var selection_box: MeshInstance3D = $"../../../SelectionBox"
@onready var player = $"../.."

enum Mode { TERRAIN, BUILDING }
var current_mode: Mode = Mode.TERRAIN
var terrain_blocky_mode: bool = true # Default to blocky as requested
var current_block_id: int = 1
var current_rotation: int = 0

var current_voxel_pos: Vector3
var current_remove_voxel_pos: Vector3
var has_target: bool = false

func _ready():
	update_ui()

func _process(_delta):
	if current_mode == Mode.BUILDING or (current_mode == Mode.TERRAIN and terrain_blocky_mode):
		update_selection_box()
	else:
		selection_box.visible = false

func _unhandled_input(event):
	if event.is_action_pressed("ui_focus_next"): # Tab
		toggle_mode()
		
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_G:
			terrain_blocky_mode = not terrain_blocky_mode
			update_ui()
		elif event.keycode == KEY_1:
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
		var mode_str = "Blocky" if terrain_blocky_mode else "Smooth"
		mode_label.text = "Mode: TERRAIN (%s)\nL-Click: Dig, R-Click: Place\n[G] Toggle Grid Mode" % mode_str
	else:
		var block_name = "Cube"
		if current_block_id == 2: block_name = "Ramp"
		elif current_block_id == 3: block_name = "Sphere"
		elif current_block_id == 4: block_name = "Stairs"
		
		mode_label.text = "Mode: BUILDING (Blocky)\nBlock: %s (Rot: %d)\nL-Click: Remove, R-Click: Add\nCTRL+Scroll: Rotate" % [block_name, current_rotation]

func update_selection_box():
	# If in Terrain Blocky mode, we only care about terrain hit
	if current_mode == Mode.TERRAIN and terrain_blocky_mode:
		var terrain_hit = raycast(10.0)
		if terrain_hit:
			# Calculate grid position for terrain
			# Place: adjacent to face
			# Remove: inside face
			# But for visualization, we usually show the target.
			# Let's assume we show the voxel being "looked at".
			var pos = terrain_hit.position - terrain_hit.normal * 0.1 # Move slightly inside to get the voxel 'under' the surface
			var voxel_pos = Vector3(floor(pos.x), floor(pos.y), floor(pos.z))
			
			current_voxel_pos = voxel_pos
			selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
			selection_box.visible = true
			has_target = true
		else:
			selection_box.visible = false
			has_target = false
		return

	var terrain_hit = raycast(10.0)
	var voxel_hit = raycast_voxel_grid(camera.global_position, -camera.global_transform.basis.z, 10.0)
	
	var final_hit_pos = Vector3.ZERO
	var final_normal = Vector3.ZERO
	var is_voxel_hit = false
	
	# Determine which hit to use
	if voxel_hit and terrain_hit:
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
		# Building mode terrain hit logic (remains mostly same, maybe update later)
		var pos = terrain_hit.position
		var normal = terrain_hit.normal
		
		var check_pos = pos + normal * 0.01
		var voxel_x = floor(check_pos.x)
		var voxel_y = floor(check_pos.y)
		var voxel_z = floor(check_pos.z)
		
		current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
		current_remove_voxel_pos = current_voxel_pos 
		
		selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
		selection_box.visible = true
		has_target = true
	else:
		selection_box.visible = false
		has_target = false

func handle_terrain_input(event):
	var hit = raycast(100.0)
	if hit:
		if terrain_blocky_mode:
			# Blocky interaction
			var target_pos
			var val = 0.0
			
			if event.button_index == MOUSE_BUTTON_LEFT: # Dig
				# Target the voxel inside the terrain
				var p = hit.position - hit.normal * 0.1
				target_pos = Vector3(floor(p.x), floor(p.y), floor(p.z)) + Vector3(0.5, 0.5, 0.5)
				val = 1.0 # Dig (Positive density)
				
			elif event.button_index == MOUSE_BUTTON_RIGHT: # Place
				# Target the voxel outside the terrain
				var p = hit.position + hit.normal * 0.1
				target_pos = Vector3(floor(p.x), floor(p.y), floor(p.z)) + Vector3(0.5, 0.5, 0.5)
				val = -1.0 # Place (Negative density)
			
			if target_pos:
				# Radius 0.6 ensures we cover the 0.5 extent from center (total size 1.0) plus margin
				terrain_manager.modify_terrain(target_pos, 0.6, val, 1) # Shape 1 = Box
				
		else:
			# Smooth interaction
			if event.button_index == MOUSE_BUTTON_LEFT:
				terrain_manager.modify_terrain(hit.position, 4.0, 1.0, 0) # Dig
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				terrain_manager.modify_terrain(hit.position, 4.0, -1.0, 0) # Place

func handle_building_input(event):
	# current_voxel_pos is the GHOST block (Placement Target)
	# current_remove_voxel_pos is the SOLID block (Removal Target)
	
	if event.button_index == MOUSE_BUTTON_RIGHT: # Add
		# Place at the ghost position
		building_manager.set_voxel(current_voxel_pos, current_block_id, current_rotation)
		
	elif event.button_index == MOUSE_BUTTON_LEFT: # Remove
		# Laser accurate removal logic (Physics-based)
		# Ignores the 'current_remove_voxel_pos' calculated by grid-casting, 
		# ensuring we hit the exact mesh (like ramps) and not the grid cell behind/in-front.
		var hit = raycast(10.0)
		
		if hit and hit.collider:
			# Check if we hit a building chunk (using trimesh collision)
			if hit.collider.get_parent() is BuildingChunk:
				# Move slightly into the object from the hit point to find the voxel
				# -normal * 0.01 usually works, but if we are inside, or glancing...
				# A safer bet for removal is often `position - normal * 0.01`
				var remove_pos = hit.position - hit.normal * 0.01
				var voxel_pos = Vector3(floor(remove_pos.x), floor(remove_pos.y), floor(remove_pos.z))
				
				building_manager.set_voxel(voxel_pos, 0.0)
			else:
				# Fallback to the grid selection if we hit something else (like terrain) 
				# or if the user wants to remove terrain? (Not requested here)
				pass

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
