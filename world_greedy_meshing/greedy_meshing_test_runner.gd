extends Node3D

var building_manager: Node

func _ready():
	# Instantiate the BuildingManager
	building_manager = load("res://world_building_system/building_manager.gd").new()
	add_child(building_manager)
	
	# Create an initial chunk at (0,0,0) with a solid sphere
	print("Generating initial test data...")
	var size = 16
	var center = Vector3(size/2.0, size/2.0, size/2.0)
	var radius = 6.0
	
	for x in range(size):
		for y in range(size):
			for z in range(size):
				var pos = Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5)
				if pos.distance_to(center) <= radius:
					# Set voxel in world space
					building_manager.set_voxel(Vector3(x, y, z), 1.0)

func _unhandled_input(event):
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_handle_click(false) # Remove
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_handle_click(true) # Add

func _handle_click(add_block: bool):
	var camera = get_viewport().get_camera_3d()
	if not camera: return
	
	var mouse_pos = get_viewport().get_mouse_position()
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 100.0
	
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space_state.intersect_ray(query)
	
	if result:
		var hit_pos = result.position
		var normal = result.normal
		
		# Move slightly inside/outside based on action
		var target_pos = hit_pos - normal * 0.5 if not add_block else hit_pos + normal * 0.5
		
		building_manager.set_voxel(target_pos, 1.0 if add_block else 0.0)
