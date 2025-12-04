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
	var hit = raycast(10.0)
	if hit:
		var pos = hit.position
		var normal = hit.normal
		
		# Highlight the PLACEMENT target (Adjacent Voxel)
		# Move slightly OUTSIDE the object along normal
		var outside_pos = pos + normal * 0.05
		var voxel_x = floor(outside_pos.x)
		var voxel_y = floor(outside_pos.y)
		var voxel_z = floor(outside_pos.z)
		
		current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
		
		# Selection box is centered
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
	
	if event.button_index == MOUSE_BUTTON_RIGHT: # Add
		# Place at the ghost position
		building_manager.set_voxel(current_voxel_pos, current_block_id, current_rotation)
		
	elif event.button_index == MOUSE_BUTTON_LEFT: # Remove
		# Remove requires the EXISTING block, not the ghost.
		# Re-calculate based on raycast (Hit - Normal)
		var hit = raycast(10.0)
		if hit:
			var normal = hit.normal
			var inside_pos = hit.position - normal * 0.05
			var target_remove = floor(inside_pos)
			building_manager.set_voxel(target_remove, 0.0)

func raycast(length: float):
	var space_state = camera.get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from - camera.global_transform.basis.z * length
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player.get_rid()]
	return space_state.intersect_ray(query)
