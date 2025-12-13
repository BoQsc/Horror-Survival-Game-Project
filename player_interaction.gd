extends Node

@export var terrain_manager: Node3D
@export var building_manager: Node3D
@export var vegetation_manager: Node3D
@export var road_manager: Node3D  # Road placement system

@onready var mode_label: Label = $"../../../UI/ModeLabel"
@onready var camera: Camera3D = $".."
@onready var selection_box: MeshInstance3D = $"../../../SelectionBox"
@onready var player = $"../.."

enum Mode { PLAYING, TERRAIN, WATER, BUILDING, ROAD, MATERIAL }
var current_mode: Mode = Mode.PLAYING
var terrain_blocky_mode: bool = true # Default to blocky as requested
var current_block_id: int = 1
var current_rotation: int = 0
var current_material_id: int = 102  # Start with Sand (100=Grass, 101=Stone, 102=Sand, 103=Snow)

# Road building state
var road_start_pos: Vector3 = Vector3.ZERO
var is_placing_road: bool = false
var road_type: int = 1  # 1=Flatten, 2=Mask Only, 3=Normalize

# PLAYING mode placeable items
enum PlaceableItem { ROCK, GRASS }
var current_placeable: PlaceableItem = PlaceableItem.ROCK

var current_voxel_pos: Vector3
var current_remove_voxel_pos: Vector3
var has_target: bool = false
var voxel_grid_visualizer: MeshInstance3D

func _ready():
	# Create Grid Visualizer
	voxel_grid_visualizer = MeshInstance3D.new()
	var mesh = ImmediateMesh.new()
	voxel_grid_visualizer.mesh = mesh
	voxel_grid_visualizer.material_override = StandardMaterial3D.new()
	voxel_grid_visualizer.material_override.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	voxel_grid_visualizer.material_override.albedo_color = Color(1, 1, 1, 0.2)
	voxel_grid_visualizer.material_override.vertex_color_use_as_albedo = true
	get_tree().root.add_child.call_deferred(voxel_grid_visualizer)
	
	update_ui()

func _process(_delta):
	if current_mode == Mode.PLAYING:
		# No selection box in playing mode
		selection_box.visible = false
		voxel_grid_visualizer.visible = false
	elif current_mode == Mode.BUILDING or ((current_mode == Mode.TERRAIN or current_mode == Mode.WATER) and terrain_blocky_mode):
		update_selection_box()
		update_grid_visualizer()
	else:
		selection_box.visible = false
		voxel_grid_visualizer.visible = false

func update_grid_visualizer():
	if not has_target or not terrain_blocky_mode:
		voxel_grid_visualizer.visible = false
		return

	voxel_grid_visualizer.visible = true
	var mesh = voxel_grid_visualizer.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	# Draw a 3x3x3 grid around the target voxel
	var center = floor(current_voxel_pos)
	var radius = 1
	var step = 1.0
	var color = Color(0.5, 0.5, 0.5, 0.3)
	
	for x in range(-radius, radius + 2):
		for y in range(-radius, radius + 2):
			# Z lines
			mesh.surface_set_color(color)
			mesh.surface_add_vertex(center + Vector3(x, y, -radius))
			mesh.surface_add_vertex(center + Vector3(x, y, radius + 1))
			
	for x in range(-radius, radius + 2):
		for z in range(-radius, radius + 2):
			# Y lines
			mesh.surface_set_color(color)
			mesh.surface_add_vertex(center + Vector3(x, -radius, z))
			mesh.surface_add_vertex(center + Vector3(x, radius + 1, z))
			
	for y in range(-radius, radius + 2):
		for z in range(-radius, radius + 2):
			# X lines
			mesh.surface_set_color(color)
			mesh.surface_add_vertex(center + Vector3(-radius, y, z))
			mesh.surface_add_vertex(center + Vector3(radius + 1, y, z))
			
	mesh.surface_end()

func _unhandled_input(event):
	if event.is_action_pressed("ui_focus_next"): # Tab
		toggle_mode()
		
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_G:
			terrain_blocky_mode = not terrain_blocky_mode
			update_ui()
		elif event.keycode == KEY_1:
			if current_mode == Mode.ROAD:
				road_type = 1
			elif current_mode == Mode.PLAYING:
				current_placeable = PlaceableItem.ROCK
			elif current_mode == Mode.MATERIAL:
				current_material_id = 100  # Grass
			else:
				current_block_id = 1
			update_ui()
		elif event.keycode == KEY_2:
			if current_mode == Mode.ROAD:
				road_type = 2
			elif current_mode == Mode.PLAYING:
				current_placeable = PlaceableItem.GRASS
			elif current_mode == Mode.MATERIAL:
				current_material_id = 101  # Stone
			else:
				current_block_id = 2
			update_ui()
		elif event.keycode == KEY_3:
			if current_mode == Mode.ROAD:
				road_type = 3
			elif current_mode == Mode.MATERIAL:
				current_material_id = 102  # Sand
			else:
				current_block_id = 3
			update_ui()
		elif event.keycode == KEY_4:
			if current_mode == Mode.MATERIAL:
				current_material_id = 103  # Snow
			else:
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
				if current_mode == Mode.PLAYING:
					handle_playing_input(event)
				elif current_mode == Mode.TERRAIN or current_mode == Mode.WATER:
					handle_terrain_input(event)
				elif current_mode == Mode.BUILDING and has_target:
					handle_building_input(event)
				elif current_mode == Mode.ROAD:
					handle_road_input(event)
				elif current_mode == Mode.MATERIAL:
					handle_material_input(event)

func toggle_mode():
	if current_mode == Mode.PLAYING:
		current_mode = Mode.TERRAIN
	elif current_mode == Mode.TERRAIN:
		current_mode = Mode.WATER
	elif current_mode == Mode.WATER:
		current_mode = Mode.BUILDING
	elif current_mode == Mode.BUILDING:
		current_mode = Mode.ROAD
		is_placing_road = false  # Reset road state
	elif current_mode == Mode.ROAD:
		current_mode = Mode.MATERIAL
	else:
		current_mode = Mode.PLAYING
	update_ui()

func update_ui():
	if current_mode == Mode.PLAYING:
		var item_str = "Rock" if current_placeable == PlaceableItem.ROCK else "Grass"
		mode_label.text = "Mode: PLAYING\nL-Click: Chop/Harvest\nR-Click: Place %s\n[1] Rock [2] Grass\n[TAB] Switch Mode" % item_str
	elif current_mode == Mode.TERRAIN:
		var mode_str = "Blocky" if terrain_blocky_mode else "Smooth"
		mode_label.text = "Mode: TERRAIN (%s)\nL-Click: Dig, R-Click: Place\n[G] Toggle Grid Mode" % mode_str
	elif current_mode == Mode.WATER:
		var mode_str = "Blocky" if terrain_blocky_mode else "Smooth"
		mode_label.text = "Mode: WATER (%s)\nL-Click: Remove, R-Click: Add\n[G] Toggle Grid Mode" % mode_str
	elif current_mode == Mode.BUILDING:
		var block_name = "Cube"
		if current_block_id == 2: block_name = "Ramp"
		elif current_block_id == 3: block_name = "Sphere"
		elif current_block_id == 4: block_name = "Stairs"
		
		mode_label.text = "Mode: BUILDING (Blocky)\nBlock: %s (Rot: %d)\nL-Click: Remove, R-Click: Add\nCTRL+Scroll: Rotate" % [block_name, current_rotation]
	elif current_mode == Mode.ROAD:
		var road_status = "Click to start" if not is_placing_road else "Click to end"
		var type_names = ["", "Flatten", "Mask Only", "Normalize"]
		var type_name = type_names[road_type] if road_type < type_names.size() else "Type %d" % road_type
		mode_label.text = "Mode: ROAD (%s)\n%s\nR-Click: Place road\n[1-3] Road Type" % [type_name, road_status]
	elif current_mode == Mode.MATERIAL:
		var mat_names = ["Grass", "Stone", "Sand", "Snow"]
		var mat_index = current_material_id - 100  # 100+ offset
		var mat_name = mat_names[mat_index] if mat_index >= 0 and mat_index < mat_names.size() else "Mat %d" % current_material_id
		mode_label.text = "Mode: MATERIAL\nPlacing: %s\nL-Click: Dig, R-Click: Place\n[1-4] Select Material" % mat_name

func update_selection_box():
	# If in Terrain/Water Blocky mode, we only care about hit
	if (current_mode == Mode.TERRAIN or current_mode == Mode.WATER) and terrain_blocky_mode:
		var hit_areas = (current_mode == Mode.WATER)
		var hit = raycast(10.0, hit_areas)
		if hit:
			# Calculate grid position
			var pos = hit.position - hit.normal * 0.1 # Move slightly inside
			var voxel_pos = Vector3(floor(pos.x), floor(pos.y), floor(pos.z))
			
			current_voxel_pos = voxel_pos
			selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
			selection_box.visible = true
			has_target = true
		else:
			selection_box.visible = false
			has_target = false
		return

	var hit_areas = (current_mode == Mode.WATER)
	var terrain_hit = raycast(10.0, hit_areas)
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

func handle_playing_input(event):
	# PLAYING mode - interact with world objects (trees, grass, rocks)
	# Use collide_with_areas=true to detect grass/rocks (Area3D)
	# Use exclude_water=true so we can harvest vegetation BELOW water surface
	var hit = raycast(100.0, true, true)  # collide_areas=true, exclude_water=true
	
	if event.button_index == MOUSE_BUTTON_LEFT:
		# L-Click: Harvest/Chop
		if hit and hit.collider:
			if hit.collider.is_in_group("trees"):
				if vegetation_manager:
					vegetation_manager.chop_tree_by_collider(hit.collider)
			elif hit.collider.is_in_group("grass"):
				if vegetation_manager:
					vegetation_manager.harvest_grass_by_collider(hit.collider)
			elif hit.collider.is_in_group("rocks"):
				if vegetation_manager:
					vegetation_manager.harvest_rock_by_collider(hit.collider)
	
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		# R-Click: Place selected item on terrain (use normal raycast without areas)
		var terrain_hit = raycast(100.0, false)
		if terrain_hit and vegetation_manager:
			if current_placeable == PlaceableItem.ROCK:
				vegetation_manager.place_rock(terrain_hit.position)
			else:
				vegetation_manager.place_grass(terrain_hit.position)

func handle_terrain_input(event):
	var hit_areas = (current_mode == Mode.WATER)
	var hit = raycast(100.0, hit_areas)
	if hit:
		var layer = 0 # Terrain
		if current_mode == Mode.WATER:
			layer = 1
			
		if terrain_blocky_mode:
			# Blocky interaction
			var target_pos
			var val = 0.0
			
			if event.button_index == MOUSE_BUTTON_LEFT: # Dig / Remove
				# Target the voxel inside the terrain
				var p = hit.position - hit.normal * 0.1
				target_pos = Vector3(floor(p.x), floor(p.y), floor(p.z)) + Vector3(0.5, 0.5, 0.5)
				val = 0.5 # Dig (Positive density)
				
			elif event.button_index == MOUSE_BUTTON_RIGHT: # Place / Add
				# Target the voxel outside the terrain
				var p = hit.position + hit.normal * 0.1
				target_pos = Vector3(floor(p.x), floor(p.y), floor(p.z)) + Vector3(0.5, 0.5, 0.5)
				val = -0.5 # Place (Negative density)
			
			if target_pos:
				terrain_manager.modify_terrain(target_pos, 0.6, val, 1, layer) # Shape 1 = Box
				
		else:
			# Smooth interaction
			if event.button_index == MOUSE_BUTTON_LEFT:
				terrain_manager.modify_terrain(hit.position, 4.0, 1.0, 0, layer) # Dig
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				terrain_manager.modify_terrain(hit.position, 4.0, -1.0, 0, layer) # Place

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
		var hit = raycast(10.0, false) # Never hit water when removing buildings
		
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

func raycast(length: float, collide_areas: bool = false, exclude_water: bool = false):
	var space_state = camera.get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from - camera.global_transform.basis.z * length
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player.get_rid()]
	query.collide_with_areas = collide_areas
	
	if exclude_water:
		# Cast ray, if we hit water, continue through it
		var result = space_state.intersect_ray(query)
		while result and result.collider and result.collider.is_in_group("water"):
			# Add hit collider to exclude list and raycast again from hit point
			query.exclude.append(result.collider.get_rid())
			query.from = result.position + (to - from).normalized() * 0.01  # Move slightly past
			result = space_state.intersect_ray(query)
		return result
	
	return space_state.intersect_ray(query)

## Handle material placement mode input
func handle_material_input(event):
	var hit = raycast(100.0, false)
	if hit:
		var target_pos
		var val = 0.0
		
		if event.button_index == MOUSE_BUTTON_LEFT: # Dig
			var p = hit.position - hit.normal * 0.1
			target_pos = Vector3(floor(p.x), floor(p.y), floor(p.z)) + Vector3(0.5, 0.5, 0.5)
			val = 0.5 # Dig (Positive density)
			terrain_manager.modify_terrain(target_pos, 0.6, val, 1, 0, -1)  # -1 = no material change
			
		elif event.button_index == MOUSE_BUTTON_RIGHT: # Place with material
			var p = hit.position + hit.normal * 0.1
			target_pos = Vector3(floor(p.x), floor(p.y), floor(p.z)) + Vector3(0.5, 0.5, 0.5)
			val = -0.5 # Place (Negative density)
			terrain_manager.modify_terrain(target_pos, 0.6, val, 1, 0, current_material_id)

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

## Road placement input handler
func handle_road_input(event: InputEventMouseButton):
	if not road_manager:
		return
	
	# Right click to place road points
	if event.button_index == MOUSE_BUTTON_RIGHT:
		var hit = raycast(50.0, false)  # Longer range for roads
		if hit:
			var pos = hit.position
			
			if not is_placing_road:
				# First click - start road
				road_start_pos = pos
				is_placing_road = true
				road_manager.start_road(false)  # false = not a trail
				road_manager.add_road_point(pos)
				update_ui()
			else:
				# Second click - end road and apply terrain modification based on type
				road_manager.add_road_point(pos)
				var segment_id = road_manager.finish_road(false)
				
				if segment_id >= 0:
					# Apply terrain modification based on road_type
					if road_type == 1:
						_flatten_road_segment(road_start_pos, pos)  # Full flatten
					elif road_type == 2:
						pass  # Mask only - no terrain modification
					elif road_type == 3:
						_normalize_road_segment(road_start_pos, pos)  # Light normalize
				
				is_placing_road = false
				update_ui()
	
	# Left click to cancel
	elif event.button_index == MOUSE_BUTTON_LEFT and is_placing_road:
		is_placing_road = false
		road_manager.current_road_points.clear()
		road_manager.is_building_road = false
		update_ui()

## Flatten terrain along a road segment
func _flatten_road_segment(start: Vector3, end: Vector3):
	if not terrain_manager:
		return
	
	var road_width = road_manager.road_width if road_manager else 5.0
	var direction = (end - start).normalized()
	var length = start.distance_to(end)
	var steps = int(length / 2.0)  # Every 2 meters
	
	# Average Y height for flat road
	var avg_y = (start.y + end.y) / 2.0
	
	for i in range(steps + 1):
		var t = float(i) / float(steps) if steps > 0 else 0.0
		var pos = start.lerp(end, t)
		pos.y = avg_y
		
		# Flatten terrain at this point (box shape = 1)
		terrain_manager.modify_terrain(pos, road_width / 2.0, 0.0, 1, 0)

## Road Type 3: Custom terrain normalization with relaxed slope
## Creates a smooth drivable surface - follows slope between clicked points
func _normalize_road_segment(start: Vector3, end: Vector3):
	if not terrain_manager:
		return
	
	var road_width = road_manager.road_width if road_manager else 10.0
	var brush_radius = road_width  # Larger brush for stronger effect
	
	var start_y = start.y
	var end_y = end.y
	
	print("Road Type 3: Start Y=%.1f -> End Y=%.1f" % [start_y, end_y])
	
	# Fewer steps = faster, larger brush compensates
	var length_2d = Vector2(start.x, start.z).distance_to(Vector2(end.x, end.z))
	var steps = int(length_2d / 4.0) + 1  # Every 4 meters (fewer ops = faster)
	
	for i in range(steps + 1):
		var t = float(i) / float(steps) if steps > 0 else 0.0
		var pos_x = lerpf(start.x, end.x, t)
		var pos_z = lerpf(start.z, end.z, t)
		var target_y = lerpf(start_y, end_y, t)  # Slope from start to end
		
		# STRONG dig above road level
		var dig_pos = Vector3(pos_x, target_y + brush_radius * 0.5, pos_z)
		terrain_manager.modify_terrain(dig_pos, brush_radius, 2.0, 0, 0)  # Strong dig
		
		# STRONG fill below road level
		var fill_pos = Vector3(pos_x, target_y - brush_radius * 0.5, pos_z)
		terrain_manager.modify_terrain(fill_pos, brush_radius, -2.0, 0, 0)  # Strong fill
