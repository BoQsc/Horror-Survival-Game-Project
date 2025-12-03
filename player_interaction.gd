extends Node

@export var terrain_manager: Node3D
@export var building_manager: Node3D

@onready var mode_label: Label = $"../../../UI/ModeLabel"
@onready var camera: Camera3D = $".."

enum Mode { TERRAIN, BUILDING }
var current_mode: Mode = Mode.TERRAIN

func _ready():
	update_ui()

func _unhandled_input(event):
	if event.is_action_pressed("ui_focus_next"): # Tab
		toggle_mode()
	
	if event is InputEventMouseButton and event.pressed and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if current_mode == Mode.TERRAIN:
			handle_terrain_input(event)
		elif current_mode == Mode.BUILDING:
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

func handle_terrain_input(event):
	# Delegate to terrain manager logic, but manually triggered here
	# We need to call 'modify_terrain' on the manager
	var hit = raycast(100.0)
	if hit:
		if event.button_index == MOUSE_BUTTON_LEFT:
			terrain_manager.modify_terrain(hit.position, 4.0, 1.0) # Dig
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			terrain_manager.modify_terrain(hit.position, 4.0, -1.0) # Place

func handle_building_input(event):
	var hit = raycast(10.0) # Shorter reach for building
	if hit:
		var pos = hit.position
		var normal = hit.normal
		
		if event.button_index == MOUSE_BUTTON_RIGHT: # Add
			var target = pos + normal * 0.5
			building_manager.set_voxel(target, 1.0)
		elif event.button_index == MOUSE_BUTTON_LEFT: # Remove
			var target = pos - normal * 0.5
			building_manager.set_voxel(target, 0.0)

func raycast(length: float):
	var space_state = camera.get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from - camera.global_transform.basis.z * length
	var query = PhysicsRayQueryParameters3D.create(from, to)
	return space_state.intersect_ray(query)
