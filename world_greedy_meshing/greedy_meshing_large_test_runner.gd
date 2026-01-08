extends Node3D

var building_manager: Node

# Test Settings
const WORLD_SIZE_CHUNKS = Vector3i(8, 2, 8) # 8x8 chunks flat, 2 high
const CHUNK_SIZE = 16

func _ready():
	# Instantiate the BuildingManager
	building_manager = load("res://world_building_system/building_manager.gd").new()
	add_child(building_manager)
	
	print("Generating LARGE test world...")
	generate_world()

func generate_world():
	var start_time = Time.get_ticks_msec()
	
	# Simple flat terrain with noise
	var noise = FastNoiseLite.new()
	noise.frequency = 0.05
	
	for cx in range(WORLD_SIZE_CHUNKS.x):
		for cz in range(WORLD_SIZE_CHUNKS.z):
			for cy in range(WORLD_SIZE_CHUNKS.y):
				var chunk_base_pos = Vector3i(cx, cy, cz) * CHUNK_SIZE
				
				for lx in range(CHUNK_SIZE):
					for lz in range(CHUNK_SIZE):
						var gx = chunk_base_pos.x + lx
						var gz = chunk_base_pos.z + lz
						
						# Heightmap
						var height = int((noise.get_noise_2d(gx, gz) + 1.0) * 10.0) + 5
						
						for ly in range(CHUNK_SIZE):
							var gy = chunk_base_pos.y + ly
							if gy <= height:
								building_manager.set_voxel(Vector3(gx, gy, gz), 1.0)
	
	var end_time = Time.get_ticks_msec()
	print("World Generation request took: ", end_time - start_time, "ms")
	print("Meshing happens asynchronously...")

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
		var target_pos = hit_pos - normal * 0.5 if not add_block else hit_pos + normal * 0.5
		building_manager.set_voxel(target_pos, 1.0 if add_block else 0.0)
