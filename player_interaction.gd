extends Node

@export var terrain_manager: Node3D
@export var building_manager: Node3D

@onready var mode_label: Label = $"../../../UI/ModeLabel"
@onready var camera: Camera3D = $".."
@onready var selection_box: MeshInstance3D = $"../../../SelectionBox"

enum Mode { TERRAIN, BUILDING }
var current_mode: Mode = Mode.TERRAIN

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
	
	if event is InputEventMouseButton and event.pressed and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
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
		mode_label.text = "Mode: BUILDING (Blocky)\nL-Click: Remove, R-Click: Add"

func update_selection_box():
	var hit = raycast(10.0)
	if hit:
		var pos = hit.position
		var normal = hit.normal
		
		# Determine target voxel based on implicit action (looking at block -> highlight it)
		# We snap to the block we are looking AT (for removal reference).
		# The user implies "Add" by knowing they will add adjacent.
		# To make it clear, let's just highlight the block we hit.
		
		# Move slightly into the object to handle float precision
		var inside_pos = pos - normal * 0.05
		var voxel_x = floor(inside_pos.x)
		var voxel_y = floor(inside_pos.y)
		var voxel_z = floor(inside_pos.z)
		
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
	# current_voxel_pos is the block we HIT.
	
	if event.button_index == MOUSE_BUTTON_LEFT: # Remove
		# Remove the highlighted block
		building_manager.set_voxel(current_voxel_pos, 0.0)
		
	elif event.button_index == MOUSE_BUTTON_RIGHT: # Add
		# Add adjacent to the highlighted block
		# We need the normal again to know WHICH adjacent
		var hit = raycast(10.0)
		if hit:
			var normal = hit.normal
			# Simple grid addition
			# Normal might be smooth (from terrain), so we need to check dominant axis?
			# Actually, standard math works if we are axis aligned.
			# But if hitting smooth terrain, normal is arbitrary.
			# Robust way:
			var inside_pos = hit.position - normal * 0.05
			var voxel_base = floor(inside_pos) # Should match current_voxel_pos
			
			# Project out
			var outside_pos = hit.position + normal * 0.05
			var target_place = floor(outside_pos)
			
			# Sanity check: ensure we aren't replacing the same block (e.g. inside object)
			if target_place == voxel_base:
				# This happens if we are extremely close to edge or normal is weird.
				# Fallback: Step 1 unit in dominant axis of normal
				var abs_n = normal.abs()
				if abs_n.x > abs_n.y and abs_n.x > abs_n.z:
					target_place.x += sign(normal.x)
				elif abs_n.y > abs_n.x and abs_n.y > abs_n.z:
					target_place.y += sign(normal.y)
				else:
					target_place.z += sign(normal.z)
			
			building_manager.set_voxel(target_place, 1.0)

func raycast(length: float):
	var space_state = camera.get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from - camera.global_transform.basis.z * length
	var query = PhysicsRayQueryParameters3D.create(from, to)
	return space_state.intersect_ray(query)
