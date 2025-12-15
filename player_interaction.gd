extends Node

@export var terrain_manager: Node3D
@export var building_manager: Node3D
@export var vegetation_manager: Node3D
@export var road_manager: Node3D  # Road placement system
@export var entity_manager: Node3D  # Entity spawning system

@onready var mode_label: Label = $"../../../UI/ModeLabel"
@onready var camera: Camera3D = $".."
@onready var selection_box: MeshInstance3D = $"../../../SelectionBox"
@onready var player = $"../.."
@onready var interaction_label: Label = get_node_or_null("../../../UI/InteractionLabel")  # Created dynamically if null

enum Mode { PLAYING, TERRAIN, WATER, BUILDING, OBJECT, ROAD, MATERIAL }
var current_mode: Mode = Mode.PLAYING
var terrain_blocky_mode: bool = true # Default to blocky as requested
var current_block_id: int = 1
var current_rotation: int = 0
var current_material_id: int = 102  # Start with Sand (100=Grass, 101=Stone, 102=Sand, 103=Snow)
var material_brush_sizes: Array = [0.6, 1.5, 3.0]  # Small, Medium, Large
var material_brush_index: int = 1  # Default to medium (index 1)
var material_brush_radius: float = 1.5  # Computed from index

# Road building state
var road_start_pos: Vector3 = Vector3.ZERO
var is_placing_road: bool = false
var road_type: int = 1  # 1=Flatten, 2=Mask Only, 3=Normalize

# Object placement state
var current_object_id: int = 1  # From ObjectRegistry
var current_object_rotation: int = 0

# Placement snap mode (applies to BUILDING and OBJECT modes)
var surface_snap_placement: bool = true  # true = place ON TOP of terrain, false = embedded
var placement_y_offset: int = 0  # Manual Y offset adjustment

# PLAYING mode placeable items
enum PlaceableItem { ROCK, GRASS }
var current_placeable: PlaceableItem = PlaceableItem.ROCK

var current_voxel_pos: Vector3
var current_remove_voxel_pos: Vector3
var current_precise_hit_y: float = 0.0  # Precise Y for object placement (fractional)
var has_target: bool = false
var voxel_grid_visualizer: MeshInstance3D
var last_stable_voxel_y: float = 0.0  # For hysteresis in surface snap mode

# Object preview system
var preview_instance: Node3D = null
var preview_object_id: int = -1  # Track which object the preview is for
var preview_valid: bool = true  # Whether current placement is valid
var object_show_grid: bool = false  # Toggle to show selection box/grid in OBJECT mode (default off)

# Interaction system
var interaction_target: Node3D = null  # Current interactable being looked at

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
		_destroy_preview()  # Ensure preview is cleaned up
		# Check for interactable objects
		_check_interaction_target()
	elif current_mode == Mode.OBJECT:
		# OBJECT mode: use preview, optionally show grid helpers
		update_selection_box()  # Still calculate target position
		if object_show_grid:
			update_grid_visualizer()
			# Selection box visibility is set in update_selection_box
		else:
			selection_box.visible = false
			voxel_grid_visualizer.visible = false
		_update_or_create_preview()
	elif current_mode == Mode.BUILDING or ((current_mode == Mode.TERRAIN or current_mode == Mode.WATER) and terrain_blocky_mode):
		update_selection_box()
		update_grid_visualizer()
	else:
		selection_box.visible = false
		voxel_grid_visualizer.visible = false
		_destroy_preview()  # Ensure preview is cleaned up

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
			if current_mode == Mode.OBJECT:
				object_show_grid = not object_show_grid
			else:
				terrain_blocky_mode = not terrain_blocky_mode
			update_ui()
		elif event.keycode == KEY_1:
			if current_mode == Mode.ROAD:
				road_type = 1
			elif current_mode == Mode.PLAYING:
				current_placeable = PlaceableItem.ROCK
			elif current_mode == Mode.MATERIAL:
				current_material_id = 100  # Grass
			elif current_mode == Mode.OBJECT:
				current_object_id = 1  # Wooden Crate
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
			elif current_mode == Mode.OBJECT:
				current_object_id = 2  # Long Crate
			else:
				current_block_id = 2
			update_ui()
		elif event.keycode == KEY_3:
			if current_mode == Mode.ROAD:
				road_type = 3
			elif current_mode == Mode.MATERIAL:
				current_material_id = 102  # Sand
			elif current_mode == Mode.OBJECT:
				current_object_id = 3  # Table
			else:
				current_block_id = 3
			update_ui()
		elif event.keycode == KEY_4:
			if current_mode == Mode.MATERIAL:
				current_material_id = 103  # Snow
			elif current_mode == Mode.OBJECT:
				current_object_id = 4  # Door
			else:
				current_block_id = 4
			update_ui()
		elif event.keycode == KEY_5:
			if current_mode == Mode.OBJECT:
				current_object_id = 5  # Window
			elif current_mode == Mode.MATERIAL:
				material_brush_index = 0  # Small brush
				material_brush_radius = material_brush_sizes[material_brush_index]
			update_ui()
		elif event.keycode == KEY_6:
			if current_mode == Mode.MATERIAL:
				material_brush_index = 1  # Medium brush
				material_brush_radius = material_brush_sizes[material_brush_index]
				update_ui()
		elif event.keycode == KEY_7:
			if current_mode == Mode.MATERIAL:
				material_brush_index = 2  # Large brush
				material_brush_radius = material_brush_sizes[material_brush_index]
				update_ui()
		elif event.keycode == KEY_Q:
			if current_mode == Mode.MATERIAL:
				# Toggle through brush sizes: 0 -> 1 -> 2 -> 0...
				material_brush_index = (material_brush_index + 1) % 3
				material_brush_radius = material_brush_sizes[material_brush_index]
				update_ui()
		elif event.keycode == KEY_V:
			if current_mode == Mode.BUILDING or current_mode == Mode.OBJECT:
				surface_snap_placement = not surface_snap_placement
				var snap_str = "ON TOP (surface)" if surface_snap_placement else "EMBEDDED"
				print("[Placement] Snap mode: %s" % snap_str)
				update_ui()
		elif event.keycode == KEY_R:
			# R key: rotate in OBJECT or BUILDING mode
			if current_mode == Mode.OBJECT:
				current_object_rotation = (current_object_rotation + 1) % 4
				update_ui()
			elif current_mode == Mode.BUILDING:
				current_rotation = (current_rotation + 1) % 4
				update_ui()
		elif event.keycode == KEY_E:
			# E key: interact with objects in PLAYING mode
			if current_mode == Mode.PLAYING and interaction_target:
				if interaction_target.has_method("interact"):
					interaction_target.interact()
		elif event.keycode == KEY_F10:
			# F10: Spawn test entity
			if entity_manager and entity_manager.has_method("spawn_entity_near_player"):
				var entity = entity_manager.spawn_entity_near_player()
				if entity:
					print("Spawned entity at %s (Total: %d)" % [entity.global_position, entity_manager.get_entity_count()])
	
	if event is InputEventMouseButton:
		if event.pressed:
			if event.ctrl_pressed:
				if event.button_index == MOUSE_BUTTON_WHEEL_UP:
					if current_mode == Mode.OBJECT:
						current_object_rotation = (current_object_rotation + 1) % 4
					else:
						current_rotation = (current_rotation + 1) % 4
					update_ui()
				elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					if current_mode == Mode.OBJECT:
						current_object_rotation = (current_object_rotation - 1 + 4) % 4
					else:
						current_rotation = (current_rotation - 1 + 4) % 4
					update_ui()
			elif event.shift_pressed:
				# Shift+Scroll: adjust placement Y offset
				if current_mode == Mode.BUILDING or current_mode == Mode.OBJECT:
					if event.button_index == MOUSE_BUTTON_WHEEL_UP:
						placement_y_offset += 1
						print("Placement Y offset: %d" % placement_y_offset)
					elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
						placement_y_offset -= 1
						print("Placement Y offset: %d" % placement_y_offset)
		elif Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
				if current_mode == Mode.PLAYING:
					handle_playing_input(event)
				elif current_mode == Mode.TERRAIN or current_mode == Mode.WATER:
					handle_terrain_input(event)
				elif current_mode == Mode.BUILDING and has_target:
					handle_building_input(event)
				elif current_mode == Mode.OBJECT and has_target:
					handle_object_input(event)
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
		current_mode = Mode.OBJECT
	elif current_mode == Mode.OBJECT:
		current_mode = Mode.ROAD
		is_placing_road = false
		_destroy_preview()  # Clean up preview when leaving OBJECT mode
	elif current_mode == Mode.ROAD:
		current_mode = Mode.MATERIAL
	else:
		current_mode = Mode.PLAYING
		_destroy_preview()  # Clean up preview
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
		var snap_str = "Surface" if surface_snap_placement else "Embed"
		mode_label.text = "Mode: BUILDING (%s)\nBlock: %s (Rot: %d)\nL-Click: Remove, R-Click: Add\nCTRL+Scroll: Rotate, [V] Snap" % [snap_str, block_name, current_rotation]
	elif current_mode == Mode.OBJECT:
		var obj = ObjectRegistry.get_object(current_object_id)
		var obj_name = obj.name if obj else "Unknown"
		var grid_str = "Grid ON" if object_show_grid else "Grid OFF"
		mode_label.text = "Mode: OBJECT (%s)\nObject: %s (Rot: %d)\nL-Click: Remove, R-Click: Place\n[1-5] Select, [R] Rotate, [G] Grid" % [grid_str, obj_name, current_object_rotation]
	elif current_mode == Mode.ROAD:
		var road_status = "Click to start" if not is_placing_road else "Click to end"
		var type_names = ["", "Flatten", "Mask Only", "Normalize"]
		var type_name = type_names[road_type] if road_type < type_names.size() else "Type %d" % road_type
		mode_label.text = "Mode: ROAD (%s)\n%s\nR-Click: Place road\n[1-3] Road Type" % [type_name, road_status]
	elif current_mode == Mode.MATERIAL:
		var mat_names = ["Grass", "Stone", "Sand", "Snow"]
		var mat_index = current_material_id - 100  # 100+ offset
		var mat_name = mat_names[mat_index] if mat_index >= 0 and mat_index < mat_names.size() else "Mat %d" % current_material_id
		var brush_size_names = ["Small", "Medium", "Large"]
		var brush_size_name = brush_size_names[material_brush_index]
		mode_label.text = "Mode: MATERIAL\nPlacing: %s\nBrush: %s (%.1f)\nL-Click: Dig, R-Click: Place\n[1-4] Material, [5-7] Size, [Q] Toggle" % [mat_name, brush_size_name, material_brush_radius]

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
		
		# For OBJECT mode on blocks: precise Y is the top of the block
		if current_mode == Mode.OBJECT:
			current_precise_hit_y = voxel_hit.voxel_pos.y + 1.0  # Top of block
		
		selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
		selection_box.visible = true
		has_target = true
	elif terrain_hit:
		# Building/Object mode terrain hit
		var pos = terrain_hit.position
		var normal = terrain_hit.normal
		
		var voxel_x: int
		var voxel_y: int
		var voxel_z: int
		
		# Check if we hit a placed object (should use grid placement like blocks)
		var hit_placed_object = terrain_hit.collider and terrain_hit.collider.is_in_group("placed_objects")
		
		# Store precise hit Y for object placement (with small offset above surface)
		current_precise_hit_y = pos.y + 0.05  # Tiny offset to sit just above surface
		
		if hit_placed_object:
			# Hit a placed object: use normal to place ABOVE/BESIDE it (like blocks)
			# Move position along normal by 1 unit to get the adjacent placement cell
			var offset_pos = pos + normal * 1.0
			voxel_x = int(floor(offset_pos.x))
			voxel_y = int(floor(offset_pos.y))
			voxel_z = int(floor(offset_pos.z))
			current_precise_hit_y = float(voxel_y)  # Use grid Y for objects too
			
			current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
			current_remove_voxel_pos = Vector3(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z)))
			selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
		elif current_mode == Mode.OBJECT and surface_snap_placement:
			# OBJECT mode on terrain: Use fractional Y for natural terrain placement
			# X/Z grid-snapped, Y at terrain surface level
			voxel_x = int(floor(pos.x))
			voxel_z = int(floor(pos.z))
			# For selection, still use an integer Y for the preview box
			voxel_y = int(round(pos.y))
			
			current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
			current_remove_voxel_pos = current_voxel_pos
			
			# Position selection box at ACTUAL terrain level (fractional Y)
			selection_box.global_position = Vector3(voxel_x + 0.5, current_precise_hit_y + 0.5, voxel_z + 0.5)
		else:
			# BUILDING mode: Full grid snap for block stacking
			if surface_snap_placement:
				var offset = normal * 0.6
				var placement_pos = pos + offset
				voxel_x = int(floor(placement_pos.x))
				voxel_y = int(floor(placement_pos.y)) + placement_y_offset
				voxel_z = int(floor(placement_pos.z))
			else:
				voxel_x = int(floor(pos.x))
				voxel_y = int(floor(pos.y))
				voxel_z = int(floor(pos.z))
			
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

func handle_object_input(event):
	# Object placement uses grid X/Z but fractional Y for terrain surface placement
	
	if event.button_index == MOUSE_BUTTON_RIGHT: # Place object
		# Build position with fractional Y for natural terrain placement
		var placement_pos = Vector3(
			floor(current_voxel_pos.x),  # Grid-snapped X
			current_precise_hit_y,        # Fractional Y (sits on terrain)
			floor(current_voxel_pos.z)   # Grid-snapped Z
		)
		var success = building_manager.place_object(placement_pos, current_object_id, current_object_rotation)
		if success:
			print("Placed object %d at %s" % [current_object_id, placement_pos])
		else:
			print("Cannot place object - cells not available")
	
	elif event.button_index == MOUSE_BUTTON_LEFT: # Remove object
		var hit = raycast(10.0, false)
		if hit and hit.collider:
			# Check if we hit a placed object (either the root or a child StaticBody)
			if hit.collider.is_in_group("placed_objects"):
				# Get anchor and chunk from metadata (check if they exist first)
				if hit.collider.has_meta("anchor") and hit.collider.has_meta("chunk"):
					var anchor = hit.collider.get_meta("anchor")
					var chunk = hit.collider.get_meta("chunk")
					if anchor != null and chunk != null:
						var success = chunk.remove_object(anchor)
						if success:
							print("Removed object at anchor %s" % anchor)
						return
			
			# Fallback: try position-based removal
			var remove_pos = hit.position - hit.normal * 0.01
			var success = building_manager.remove_object_at(remove_pos)
			if success:
				print("Removed object at %s" % remove_pos)

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
			terrain_manager.modify_terrain(target_pos, material_brush_radius, val, 1, 0, current_material_id)

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

## ============== OBJECT PREVIEW SYSTEM ==============

## Create or update preview for the current object
func _update_or_create_preview():
	if current_mode != Mode.OBJECT:
		_destroy_preview()
		return
	
	# Check if we need to create a new preview (object changed)
	if preview_object_id != current_object_id or preview_instance == null:
		_destroy_preview()
		_create_preview()
	
	# Update preview position and rotation
	if preview_instance and has_target:
		var size = ObjectRegistry.get_rotated_size(current_object_id, current_object_rotation)
		var offset_x = float(size.x) / 2.0
		var offset_z = float(size.z) / 2.0
		preview_instance.position = Vector3(
			current_voxel_pos.x + offset_x,
			current_precise_hit_y,
			current_voxel_pos.z + offset_z
		)
		preview_instance.rotation_degrees.y = current_object_rotation * 90
		preview_instance.visible = true
		
		# Check validity
		var can_place = building_manager.can_place_object(
			Vector3(current_voxel_pos.x, current_precise_hit_y, current_voxel_pos.z),
			current_object_id,
			current_object_rotation
		)
		_set_preview_validity(can_place)
	elif preview_instance:
		preview_instance.visible = false

## Create a preview instance for the current object
func _create_preview():
	var obj_def = ObjectRegistry.get_object(current_object_id)
	if obj_def.is_empty():
		return
	
	var packed = load(obj_def.scene) as PackedScene
	if not packed:
		return
	
	preview_instance = packed.instantiate()
	preview_object_id = current_object_id
	
	# Add to scene (not as child of anything specific, just to world)
	get_tree().root.add_child(preview_instance)
	
	# Apply transparent preview material to all meshes
	_apply_preview_material(preview_instance)
	
	# Disable collisions on preview (it shouldn't interact with physics)
	_disable_preview_collisions(preview_instance)

## Destroy the current preview instance
func _destroy_preview():
	if preview_instance and is_instance_valid(preview_instance):
		preview_instance.queue_free()
	preview_instance = null
	preview_object_id = -1

## Apply semi-transparent preview material to all MeshInstance3D children
func _apply_preview_material(node: Node):
	if node is MeshInstance3D:
		var mesh_inst = node as MeshInstance3D
		var mat = StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.2, 1.0, 0.3, 0.5)  # Green, semi-transparent
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true  # Render on top
		mesh_inst.material_override = mat
	
	for child in node.get_children():
		_apply_preview_material(child)

## Set preview color based on validity (green = valid, red = invalid)
func _set_preview_validity(valid: bool):
	preview_valid = valid
	var color = Color(0.2, 1.0, 0.3, 0.5) if valid else Color(1.0, 0.2, 0.2, 0.5)
	_set_preview_color(preview_instance, color)

## Recursively set preview color on all materials
func _set_preview_color(node: Node, color: Color):
	if node is MeshInstance3D:
		var mesh_inst = node as MeshInstance3D
		if mesh_inst.material_override is StandardMaterial3D:
			mesh_inst.material_override.albedo_color = color
	
	for child in node.get_children():
		_set_preview_color(child, color)

## Disable all collisions on the preview node
func _disable_preview_collisions(node: Node):
	if node is CollisionShape3D:
		node.disabled = true
	elif node is StaticBody3D or node is CharacterBody3D or node is RigidBody3D:
		node.collision_layer = 0
		node.collision_mask = 0
	
	for child in node.get_children():
		_disable_preview_collisions(child)

## ============== INTERACTION SYSTEM ==============

## Check for interactable objects player is looking at
func _check_interaction_target():
	var hit = raycast(5.0, true)  # Short range, WITH areas for door detection
	
	if hit and hit.collider:
		# Check if we hit an Area3D with a door reference
		if hit.collider is Area3D and hit.collider.has_meta("door"):
			var door = hit.collider.get_meta("door")
			if door and door.is_in_group("interactable"):
				interaction_target = door
				_show_interaction_prompt()
				return
		
		# Walk up the tree to find an interactable parent
		var node = hit.collider
		while node:
			if node.is_in_group("interactable"):
				interaction_target = node
				_show_interaction_prompt()
				return
			node = node.get_parent()
	
	# No interactable found
	interaction_target = null
	_hide_interaction_prompt()

## Show interaction prompt (creates label if needed)
func _show_interaction_prompt():
	if not interaction_label:
		_create_interaction_label()
	
	if interaction_label and interaction_target:
		if interaction_target.has_method("get_interaction_prompt"):
			interaction_label.text = interaction_target.get_interaction_prompt()
		else:
			interaction_label.text = "Press E to interact"
		interaction_label.visible = true

## Hide interaction prompt
func _hide_interaction_prompt():
	if interaction_label:
		interaction_label.visible = false

## Create the interaction label if it doesn't exist
func _create_interaction_label():
	var ui_node = get_node_or_null("../../../UI")
	if ui_node:
		interaction_label = Label.new()
		interaction_label.name = "InteractionLabel"
		interaction_label.text = "Press E to interact"
		interaction_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		interaction_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		interaction_label.anchor_left = 0.5
		interaction_label.anchor_right = 0.5
		interaction_label.anchor_top = 0.6
		interaction_label.anchor_bottom = 0.6
		interaction_label.offset_left = -100
		interaction_label.offset_right = 100
		interaction_label.offset_top = -20
		interaction_label.offset_bottom = 20
		interaction_label.add_theme_font_size_override("font_size", 20)
		interaction_label.visible = false
		ui_node.add_child(interaction_label)
