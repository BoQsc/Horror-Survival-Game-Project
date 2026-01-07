extends Node

@export var terrain_manager: Node3D
@export var building_manager: Node3D
@export var vegetation_manager: Node3D
@export var road_manager: Node3D  # Road placement system
@export var entity_manager: Node3D  # Entity spawning system
@export var vehicle_manager: Node  # Vehicle spawning/tracking system

@onready var mode_label: Label = $"../../../UI/ModeLabel"
@onready var camera: Camera3D = $".."
@onready var selection_box: MeshInstance3D = $"../../../SelectionBox"
@onready var player = $"../.."
@onready var interaction_label: Label = get_node_or_null("../../../UI/InteractionLabel")  # Created dynamically if null

enum Mode { PLAYING, TERRAIN, WATER, BUILDING, OBJECT, CONSTRUCT, ROAD, MATERIAL, PREFAB }
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

# Construct mode (combined block+object) - unified item ID
# 1-4 = blocks (Cube, Ramp, Sphere, Stairs)
# 5-9 = objects (Cardboard Box, Long Crate, Table, Door, Window)
# 0 = vegetation (toggles between Rock/Grass)
var construct_item_id: int = 1
var construct_rotation: int = 0
var construct_vegetation_type: int = 0  # 0=Rock, 1=Grass

# Prefab placement state
var available_prefabs: Array[String] = []
var current_prefab_index: int = 0
var prefab_rotation: int = 0  # 0, 1, 2, 3 = 0°, 90°, 180°, 270°
var prefab_carve_mode: bool = false  # If true, carve terrain and submerge. If false, place on top.
var prefab_foundation_fill: bool = false  # If true, grow terrain under prefab foundation to fill gaps
var prefab_carve_fill_mode: bool = false  # If true, carve first then fill after delay
var prefab_snap_to_road: bool = false  # If true, snap prefab Y to nearest road height
var prefab_road_snap_y_offset: int = 0  # Manual Y offset when using road snap (scroll wheel)
var prefab_interior_carve: bool = false  # If true, carve terrain inside prefab footprint on placement
var prefab_preview_nodes: Array[MeshInstance3D] = []  # Ghost blocks for preview
var prefab_spawner: Node = null  # Cached reference

# Placement mode (applies to BUILDING and OBJECT modes)
enum PlacementMode { SNAP, EMBED, AUTO }
var placement_mode: PlacementMode = PlacementMode.AUTO  # Default to AUTO (smart hybrid)
var auto_embed_threshold: float = 0.2  # If snapped Y floats more than this above terrain, embed instead
var placement_y_offset: int = 0  # Manual Y offset adjustment

# Computed surface_snap_placement for compatibility with existing code
var surface_snap_placement: bool:
	get:
		return placement_mode != PlacementMode.EMBED

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

# Vehicle system
var is_in_vehicle: bool = false
var current_vehicle: Node3D = null

# Freestyle Placement State
var is_freestyle_placement: bool = false
var freestyle_rotation_offset: float = 0.0 # Additional rotation in degrees
var smart_surface_align: bool = true # Default to true as requested


# Prop Pickup / Physics Drag State
var held_prop_instance: Node3D = null
var held_prop_id: int = -1
var held_prop_rotation: int = 0

# Debug Visualization
var pickup_debug_mesh: MeshInstance3D = null
var debug_timer: float = 0.0



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
	
	# Create Debug Visualizer for Pickup
	pickup_debug_mesh = MeshInstance3D.new()
	var debug_mesh = ImmediateMesh.new()
	pickup_debug_mesh.mesh = debug_mesh
	pickup_debug_mesh.material_override = StandardMaterial3D.new()
	pickup_debug_mesh.material_override.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pickup_debug_mesh.material_override.vertex_color_use_as_albedo = true
	get_tree().root.add_child.call_deferred(pickup_debug_mesh)
	
	update_ui()

func _process(_delta):
	# Block all construction visuals while in vehicle - only show exit prompt
	if is_in_vehicle:
		selection_box.visible = false
		voxel_grid_visualizer.visible = false
		_destroy_preview()
		_show_vehicle_exit_prompt()
		return
		
	# Update Held Prop Position (if holding one)
	if held_prop_instance and is_instance_valid(held_prop_instance):
		var cam = get_viewport().get_camera_3d()
		if cam:
			# Float 2 meters in front of camera
			var target_pos = cam.global_position - cam.global_transform.basis.z * 2.0
			# Smoothly interpolate
			held_prop_instance.global_position = held_prop_instance.global_position.lerp(target_pos, _delta * 15.0)
			# Match camera rotation (yaw only) or keep static?
			var cam_rot_y = cam.global_rotation.y
			held_prop_instance.rotation.y = lerp_angle(held_prop_instance.rotation.y, cam_rot_y + deg_to_rad(held_prop_rotation * 90.0), _delta * 10.0)

	# Handle input for Freestyle Placement Mode (Hold MMB)
	if current_mode == Mode.OBJECT:
		var was_freestyle = is_freestyle_placement
		is_freestyle_placement = Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)
		
		# If mode changed, refresh UI or Preview
		if was_freestyle != is_freestyle_placement:
			update_ui()
			_update_or_create_preview()
			
	# Auto-clear debug lines after 0.1s
	debug_timer += _delta
	if debug_timer > 0.1:
		debug_timer = 0.0
		if pickup_debug_mesh and pickup_debug_mesh.mesh:
			pickup_debug_mesh.mesh.clear_surfaces()
	
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
		_check_interaction_target()  # Allow door interaction in all modes
	elif current_mode == Mode.CONSTRUCT:
		# CONSTRUCT mode: unified block (1-4), object (5-9), and vegetation (0) placement
		update_selection_box()
		if construct_item_id == 0:
			# Vegetation mode - no grid or preview needed
			selection_box.visible = false
			voxel_grid_visualizer.visible = false
			_destroy_preview()
		elif construct_item_id <= 4:
			# Block mode - show grid
			update_grid_visualizer()
			_destroy_preview()
		else:
			# Object mode - show preview
			selection_box.visible = false
			voxel_grid_visualizer.visible = false
			_update_or_create_construct_preview()
		_check_interaction_target()  # Allow door interaction in all modes
	elif current_mode == Mode.BUILDING or ((current_mode == Mode.TERRAIN or current_mode == Mode.WATER) and terrain_blocky_mode):
		update_selection_box()
		update_grid_visualizer()
		_check_interaction_target()  # Allow door interaction in all modes
	elif current_mode == Mode.PREFAB:
		selection_box.visible = false
		voxel_grid_visualizer.visible = false
		_process_prefab_preview()
		_check_interaction_target()
	else:
		selection_box.visible = false
		voxel_grid_visualizer.visible = false
		_destroy_preview()  # Ensure preview is cleaned up
		_check_interaction_target()  # Allow door interaction in all modes

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
	# Block most input while in vehicle - only allow E key to exit
	if is_in_vehicle:
		if event is InputEventKey and event.pressed and event.keycode == KEY_E:
			_exit_vehicle()
		return
	
	# Handle Unified E-Key Input (Freestyle, Pickup, Drop, Interact)
	if event is InputEventKey and event.keycode == KEY_E:
		# 1. DROP PROP (Release) - High Priority
		if not event.pressed and held_prop_instance:
			_drop_held_prop()
			# Consume event so we don't trigger other release logic?
			# Actually, we might also want to turn off freestyle if it was on.
		
		# 2. FREESTYLE TOGGLE (Press/Release) - Only in OBJECT mode
		if current_mode == Mode.OBJECT:
			if event.pressed and not event.echo:
				# Only enable freestyle if NOT interacting with something else
				if not interaction_target and not held_prop_instance:
					is_freestyle_placement = true
					freestyle_rotation_offset = 0.0
					print("Freestyle Placement: ON")
			elif not event.pressed:
				is_freestyle_placement = false
				# print("Freestyle Placement: OFF") # Reduce spam
		
		# 3. INTERACT / PICKUP (Press Only)
		if event.pressed and not event.echo:
			var interaction_handled = false
			
			# Check vehicle/interact priority
			if interaction_target:
				if interaction_target.is_in_group("vehicle"):
					_enter_vehicle(interaction_target)
					interaction_handled = true
				elif interaction_target.has_method("interact"):
					interaction_target.interact()
					interaction_handled = true
			
			# Fallback: Try Pickup if not holding and no interaction occurred
			if not interaction_handled and not held_prop_instance:
				_try_pickup_prop()
					
		# Return early if E handled? 
		# If we don't return, it might fall through to the 'pressed' block below?
		# The 'pressed' block below has 'elif event.keycode == KEY_E' which would catch it if we didn't remove it.
		# But we ARE removing the other block in the next step.
		# For now, let's keep it clean.
	
	if event.is_action_pressed("ui_focus_next"): # Tab
		toggle_mode()
		
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_G:
			if current_mode == Mode.OBJECT:
				object_show_grid = not object_show_grid
			else:
				terrain_blocky_mode = not terrain_blocky_mode
			update_ui()
		elif event.keycode == KEY_Z:
			if current_mode == Mode.OBJECT:
				smart_surface_align = not smart_surface_align
				print("Smart Surface Align: %s" % ("ON" if smart_surface_align else "OFF"))
				update_ui()
		elif event.keycode == KEY_1:
			if current_mode == Mode.CONSTRUCT:
				construct_item_id = 1  # Cube block
			elif current_mode == Mode.ROAD:
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
			if current_mode == Mode.CONSTRUCT:
				construct_item_id = 2  # Ramp block
			elif current_mode == Mode.ROAD:
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
			if current_mode == Mode.CONSTRUCT:
				construct_item_id = 3  # Sphere block
			elif current_mode == Mode.ROAD:
				road_type = 3
			elif current_mode == Mode.MATERIAL:
				current_material_id = 102  # Sand
			elif current_mode == Mode.OBJECT:
				current_object_id = 3  # Table
			else:
				current_block_id = 3
			update_ui()
		elif event.keycode == KEY_4:
			if current_mode == Mode.CONSTRUCT:
				construct_item_id = 4  # Stairs block
			elif current_mode == Mode.MATERIAL:
				current_material_id = 103  # Snow
			elif current_mode == Mode.OBJECT:
				current_object_id = 4  # Door
			else:
				current_block_id = 4
			update_ui()
		elif event.keycode == KEY_5:
			if current_mode == Mode.CONSTRUCT:
				construct_item_id = 5  # Cardboard Box object
			elif current_mode == Mode.OBJECT:
				current_object_id = 5  # Window
			elif current_mode == Mode.MATERIAL:
				material_brush_index = 0  # Small brush
				material_brush_radius = material_brush_sizes[material_brush_index]
			update_ui()
			update_ui()
		elif event.keycode == KEY_6:
			if current_mode == Mode.CONSTRUCT:
				construct_item_id = 6  # Long Crate object
			elif current_mode == Mode.MATERIAL:
				material_brush_index = 1  # Medium brush
				material_brush_radius = material_brush_sizes[material_brush_index]
			elif current_mode == Mode.OBJECT:
				current_object_id = 6  # Heavy Pistol
			update_ui()
		elif event.keycode == KEY_7:
			if current_mode == Mode.CONSTRUCT:
				construct_item_id = 7  # Table object
			elif current_mode == Mode.MATERIAL:
				material_brush_index = 2  # Large brush
				material_brush_radius = material_brush_sizes[material_brush_index]
			update_ui()
		elif event.keycode == KEY_8:
			if current_mode == Mode.CONSTRUCT:
				construct_item_id = 8  # Door object
				update_ui()
		elif event.keycode == KEY_9:
			if current_mode == Mode.CONSTRUCT:
				construct_item_id = 9  # Window object
				update_ui()
		elif event.keycode == KEY_0:
			if current_mode == Mode.CONSTRUCT:
				# Toggle between Rock (0) and Grass (1) when pressing 0
				construct_item_id = 0  # Vegetation mode
				construct_vegetation_type = (construct_vegetation_type + 1) % 2
				update_ui()
		elif event.keycode == KEY_Q:
			if current_mode == Mode.MATERIAL:
				# Toggle through brush sizes: 0 -> 1 -> 2 -> 0...
				material_brush_index = (material_brush_index + 1) % 3
				material_brush_radius = material_brush_sizes[material_brush_index]
				update_ui()
		elif event.keycode == KEY_V:
			if current_mode == Mode.BUILDING or current_mode == Mode.OBJECT or current_mode == Mode.CONSTRUCT:
				# Cycle through: AUTO -> SNAP -> EMBED -> AUTO
				placement_mode = (placement_mode + 1) % 3 as PlacementMode
				var mode_names = ["SNAP (Surface)", "EMBED", "AUTO (Hybrid)"]
				print("[Placement] Mode: %s" % mode_names[placement_mode])
				update_ui()
		elif event.keycode == KEY_R:
			# R key: rotate in OBJECT, BUILDING, CONSTRUCT, or PREFAB mode
			if current_mode == Mode.CONSTRUCT:
				construct_rotation = (construct_rotation + 1) % 4
				update_ui()
			elif current_mode == Mode.OBJECT:
				current_object_rotation = (current_object_rotation + 1) % 4
				update_ui()
			elif current_mode == Mode.BUILDING:
				current_rotation = (current_rotation + 1) % 4
				update_ui()
			elif current_mode == Mode.PREFAB:
				prefab_rotation = (prefab_rotation + 1) % 4
				_update_prefab_preview()
				update_ui()
		elif event.keycode == KEY_BRACKETLEFT:
			# [ key: previous prefab
			if current_mode == Mode.PREFAB and available_prefabs.size() > 0:
				current_prefab_index = (current_prefab_index - 1 + available_prefabs.size()) % available_prefabs.size()
				_update_prefab_preview()
				update_ui()
		elif event.keycode == KEY_BRACKETRIGHT:
			# ] key: next prefab
			if current_mode == Mode.PREFAB and available_prefabs.size() > 0:
				current_prefab_index = (current_prefab_index + 1) % available_prefabs.size()
				_update_prefab_preview()
				update_ui()
		elif event.keycode == KEY_C:
			# C key: cycle prefab placement mode (Surface -> Carve -> Fill -> Carve+Fill -> Surface)
			if current_mode == Mode.PREFAB:
				if not prefab_carve_mode and not prefab_foundation_fill and not prefab_carve_fill_mode:
					# Surface -> Carve
					prefab_carve_mode = true
					prefab_foundation_fill = false
					prefab_carve_fill_mode = false
				elif prefab_carve_mode and not prefab_foundation_fill and not prefab_carve_fill_mode:
					# Carve -> Fill
					prefab_carve_mode = false
					prefab_foundation_fill = true
					prefab_carve_fill_mode = false
				elif not prefab_carve_mode and prefab_foundation_fill and not prefab_carve_fill_mode:
					# Fill -> Carve+Fill
					prefab_carve_mode = false
					prefab_foundation_fill = false
					prefab_carve_fill_mode = true
				else:
					# Carve+Fill -> Surface
					prefab_carve_mode = false
					prefab_foundation_fill = false
					prefab_carve_fill_mode = false
				var mode_str = _get_prefab_mode_str()
				print("[PREFAB] Placement mode: %s" % mode_str)
				update_ui()
		elif event.keycode == KEY_T:
			# T key: toggle road snap in PREFAB mode
			if current_mode == Mode.PREFAB:
				prefab_snap_to_road = not prefab_snap_to_road
				print("[PREFAB] Road snap: %s" % ("ON" if prefab_snap_to_road else "OFF"))
				update_ui()
		elif event.keycode == KEY_I:
			# I key: toggle interior carve in PREFAB mode
			if current_mode == Mode.PREFAB:
				prefab_interior_carve = not prefab_interior_carve
				print("[PREFAB] Interior carve: %s" % ("ON" if prefab_interior_carve else "OFF"))
				update_ui()

		elif event.keycode == KEY_F10:
			# F10: Spawn test entity (default capsule)
			if entity_manager and entity_manager.has_method("spawn_entity_near_player"):
				var entity = entity_manager.spawn_entity_near_player()
				if entity:
					print("Spawned entity at %s (Total: %d)" % [entity.global_position, entity_manager.get_entity_count()])
		elif event.keycode == KEY_F11:
			# F11: Spawn zombie
			if entity_manager and entity_manager.has_method("spawn_entity_near_player"):
				var zombie_scene = load("res://game/entities/zombie_base.tscn")
				if zombie_scene:
					var zombie = entity_manager.spawn_entity_near_player(zombie_scene)
					if zombie:
						print("Spawned ZOMBIE at %s (Total: %d)" % [zombie.global_position, entity_manager.get_entity_count()])
	
	if event is InputEventMouseButton:
		if event.pressed:
			if event.ctrl_pressed:
				if event.button_index == MOUSE_BUTTON_WHEEL_UP:
					if current_mode == Mode.CONSTRUCT:
						construct_rotation = (construct_rotation + 1) % 4
					elif current_mode == Mode.OBJECT:
						if is_freestyle_placement:
							# Freestyle: Fine rotation (15 degrees)
							freestyle_rotation_offset -= 15.0
						else:
							current_object_rotation = (current_object_rotation + 1) % 4
					elif current_mode == Mode.PREFAB and prefab_snap_to_road:
						# Ctrl+Scroll Up in PREFAB road snap: raise Y
						prefab_road_snap_y_offset += 1
						print("[PREFAB] Road snap Y offset: %d" % prefab_road_snap_y_offset)
					else:
						current_rotation = (current_rotation + 1) % 4
					update_ui()
				elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					if current_mode == Mode.CONSTRUCT:
						construct_rotation = (construct_rotation - 1 + 4) % 4
					elif current_mode == Mode.OBJECT:
						if is_freestyle_placement:
							# Freestyle: Fine rotation (15 degrees)
							freestyle_rotation_offset += 15.0
						else:
							current_object_rotation = (current_object_rotation - 1 + 4) % 4
					elif current_mode == Mode.PREFAB and prefab_snap_to_road:
						# Ctrl+Scroll Down in PREFAB road snap: lower Y
						prefab_road_snap_y_offset -= 1
						print("[PREFAB] Road snap Y offset: %d" % prefab_road_snap_y_offset)
					else:
						current_rotation = (current_rotation - 1 + 4) % 4
					update_ui()
			elif event.shift_pressed:
				# Shift+Scroll: adjust placement Y offset
				if current_mode == Mode.BUILDING or current_mode == Mode.OBJECT or current_mode == Mode.CONSTRUCT:
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
				elif current_mode == Mode.CONSTRUCT and has_target:
					handle_construct_input(event)
				elif current_mode == Mode.ROAD:
					handle_road_input(event)
				elif current_mode == Mode.MATERIAL:
					handle_material_input(event)
				elif current_mode == Mode.PREFAB:
					handle_prefab_input(event)

func toggle_mode():
	if current_mode == Mode.PLAYING:
		current_mode = Mode.TERRAIN
		# Clean up interaction system when leaving PLAYING mode
		interaction_target = null
		_hide_interaction_prompt()
	elif current_mode == Mode.TERRAIN:
		current_mode = Mode.WATER
	elif current_mode == Mode.WATER:
		current_mode = Mode.BUILDING
	elif current_mode == Mode.BUILDING:
		current_mode = Mode.OBJECT
	elif current_mode == Mode.OBJECT:
		current_mode = Mode.CONSTRUCT
		_destroy_preview()  # Clean up preview when leaving OBJECT mode
	elif current_mode == Mode.CONSTRUCT:
		current_mode = Mode.ROAD
		is_placing_road = false
		_destroy_preview()  # Clean up preview when leaving CONSTRUCT mode
	elif current_mode == Mode.ROAD:
		current_mode = Mode.MATERIAL
	elif current_mode == Mode.MATERIAL:
		current_mode = Mode.PREFAB
		_load_available_prefabs()
	elif current_mode == Mode.PREFAB:
		current_mode = Mode.PLAYING
		_destroy_prefab_preview()
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
		var mode_names = ["Snap", "Embed", "Auto"]
		var mode_str = mode_names[placement_mode]
		mode_label.text = "Mode: BUILDING (%s)\nBlock: %s (Rot: %d)\nL-Click: Remove, R-Click: Add\nCTRL+Scroll: Rotate, [V] Mode" % [mode_str, block_name, current_rotation]
	elif current_mode == Mode.OBJECT:
		var obj = ObjectRegistry.get_object(current_object_id)
		var obj_name = obj.name if obj else "Unknown"
		var grid_str = "Grid ON" if object_show_grid else "Grid OFF"
		var align_str = "Align ON" if smart_surface_align else "Align OFF"
		mode_label.text = "Mode: OBJECT (%s, %s)\nObject: %s (Rot: %d)\nL-Click: Remove, R-Click: Place\n[1-5] Select, [R] Rotate, [G] Grid\n[MMB] Hold Free, [E] Hold Grab, [Z] Align" % [grid_str, align_str, obj_name, current_object_rotation]
	elif current_mode == Mode.CONSTRUCT:
		var item_name = _get_construct_item_name(construct_item_id)
		var type_str: String
		if construct_item_id == 0:
			type_str = "Vegetation"
		elif construct_item_id <= 4:
			type_str = "Block"
		else:
			type_str = "Object"
		var mode_names = ["Snap", "Embed", "Auto"]
		var mode_str = mode_names[placement_mode]
		mode_label.text = "Mode: CONSTRUCT (%s, %s)\n%s (Rot: %d)\n[1-4] Blocks [5-9] Objects [0] Veg\n[R] Rotate [V] Mode" % [type_str, mode_str, item_name, construct_rotation]
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
	elif current_mode == Mode.PREFAB:
		var prefab_name = "None"
		if available_prefabs.size() > 0 and current_prefab_index < available_prefabs.size():
			prefab_name = available_prefabs[current_prefab_index]
		var rot_deg = prefab_rotation * 90
		var mode_str = _get_prefab_mode_str()
		var road_snap_str = ""
		if prefab_snap_to_road:
			if prefab_road_snap_y_offset != 0:
				road_snap_str = " ROAD Y%+d" % prefab_road_snap_y_offset
			else:
				road_snap_str = " ROAD"
		var carve_str = " CARVE" if prefab_interior_carve else ""
		mode_label.text = "Mode: PREFAB (%s%s%s)\n%s (Rot: %d°)\n[</>/] Select, [R] Rotate, [C] Mode\n[T] Road, [I] Carve, Ctrl+Scroll: Y"  % [mode_str, road_snap_str, carve_str, prefab_name, rot_deg]

## Get the current prefab placement mode string
func _get_prefab_mode_str() -> String:
	if prefab_carve_fill_mode:
		return "Carve+Fill"
	elif prefab_carve_mode:
		return "Carve"
	elif prefab_foundation_fill:
		return "Fill"
	else:
		return "Surface"

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
	var hit = raycast(10.0, hit_areas)
	
	if not hit:
		selection_box.visible = false
		has_target = false
		return
	
	var pos = hit.position
	var normal = hit.normal
	
	# Check what we hit
	var hit_building = hit.collider and hit.collider.get_parent() is BuildingChunk
	var hit_placed_object = hit.collider and hit.collider.is_in_group("placed_objects")
	
	var voxel_x: int
	var voxel_y: int
	var voxel_z: int
	
	# Store precise hit Y for object placement
	current_precise_hit_y = pos.y + 0.05
	
	if current_mode == Mode.BUILDING:
		# BUILDING MODE: Simple physics-based targeting
		# Round normal to nearest grid axis for consistent placement
		var grid_normal = _round_to_axis(normal)
		
		if hit_building:
			# Hit a building block: place ADJACENT using grid-aligned normal
			var inside_pos = pos - normal * 0.01
			voxel_x = int(floor(inside_pos.x))
			voxel_y = int(floor(inside_pos.y))
			voxel_z = int(floor(inside_pos.z))
			current_remove_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
			
			# Place adjacent to the hit block
			current_voxel_pos = current_remove_voxel_pos + grid_normal
		else:
			# Hit terrain or other: use placement mode
			if placement_mode == PlacementMode.EMBED:
				# Embed mode: place inside terrain
				voxel_x = int(floor(pos.x))
				voxel_y = int(floor(pos.y))
				voxel_z = int(floor(pos.z))
			else:
				# SNAP or AUTO mode: place on surface
				var offset_pos = pos + normal * 0.6
				voxel_x = int(floor(offset_pos.x))
				voxel_y = int(floor(offset_pos.y)) + placement_y_offset
				voxel_z = int(floor(offset_pos.z))
				
				# AUTO mode: Check if block would float too much
				if placement_mode == PlacementMode.AUTO:
					var terrain_y = _get_terrain_height_at(float(voxel_x) + 0.5, float(voxel_z) + 0.5)
					var float_distance = float(voxel_y) - terrain_y
					if float_distance > auto_embed_threshold:
						voxel_y = int(floor(terrain_y))
			
			current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
			current_remove_voxel_pos = current_voxel_pos
		
		# SAFETY: Never allow placing inside an existing block
		if building_manager.get_voxel(current_voxel_pos) > 0:
			# Target would overlap with existing block - invalidate
			selection_box.visible = false
			has_target = false
			return
		
		selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
		
	elif current_mode == Mode.OBJECT:
		if is_freestyle_placement:
			# FREESTYLE MODE: Use exact raycast hit
			current_voxel_pos = pos # Store exact pos
			current_precise_hit_y = pos.y
			
			# Smart Surface Align: Prevent clipping into terrain or objects
			if smart_surface_align: # Works on everything now
				# Sample terrain at object corners + center to find highest point
				var obj_size = ObjectRegistry.get_rotated_size(current_object_id, current_object_rotation)
				var half_x = float(obj_size.x) / 2.0
				var half_z = float(obj_size.z) / 2.0
				
				# Corners + Center
				var points = [
					pos, # Center
					Vector3(pos.x - half_x, 0, pos.z - half_z),
					Vector3(pos.x + half_x, 0, pos.z - half_z),
					Vector3(pos.x - half_x, 0, pos.z + half_z),
					Vector3(pos.x + half_x, 0, pos.z + half_z)
				]
				
				var max_y = -999.0
				for p in points:
					# Use physics raycast instead of math height for perfect mesh alignment
					# Start search from the hit position's Y
					var h = _get_physics_height_at(p.x, p.z, pos.y)
					if h > max_y:
						max_y = h
				
				if max_y > -900:
					# Base height is the surface
					current_precise_hit_y = max_y
					
					# Add pivot offset from preview instance (if available)
					# This handles centered pivots vs bottom pivots
					if preview_instance and preview_object_id == current_object_id:
						var pivot_offset = _calculate_pivot_offset(preview_instance)
						current_precise_hit_y += pivot_offset
					else:
						# Fallback safety margin
						current_precise_hit_y += 0.02
			
			# Apply manual offset (Shift+Scroll) - finer control for freestyle (0.1 steps)
			if placement_y_offset != 0:
				current_precise_hit_y += float(placement_y_offset) * 0.1
				
			current_voxel_pos.y = current_precise_hit_y
			
			# Align logic for preview (will be handled by _update_preview)
			
			# Align logic for preview (will be handled by _update_preview)
			# We don't snap to grid.
			selection_box.visible = false 
			# Let's show box at exact pos for feedback
			selection_box.global_position = current_voxel_pos + Vector3(0, 0.5, 0)
			
			# Freestyle is always valid (physics handles the rest)
			_set_preview_validity(true)
			
		elif hit_placed_object or hit_building:
			# Hit an object/building: place adjacent (same as BUILDING mode)
			var grid_normal = _round_to_axis(normal)
			var inside_pos = pos - normal * 0.01  # Find the hit block
			voxel_x = int(floor(inside_pos.x))
			voxel_y = int(floor(inside_pos.y))
			voxel_z = int(floor(inside_pos.z))
			current_remove_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
			
			# Place adjacent to the hit block
			current_voxel_pos = current_remove_voxel_pos + grid_normal
			current_precise_hit_y = current_voxel_pos.y
			selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
		elif surface_snap_placement:
			# Terrain: use fractional Y for natural placement
			voxel_x = int(floor(pos.x))
			voxel_z = int(floor(pos.z))
			voxel_y = int(round(pos.y))
			
			current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
			current_remove_voxel_pos = current_voxel_pos
			selection_box.global_position = Vector3(voxel_x + 0.5, current_precise_hit_y + 0.5, voxel_z + 0.5)
		else:
			# Embed mode for objects
			voxel_x = int(floor(pos.x))
			voxel_y = int(floor(pos.y))
			voxel_z = int(floor(pos.z))
			current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
			current_remove_voxel_pos = current_voxel_pos
			selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
	
	elif current_mode == Mode.CONSTRUCT:
		# CONSTRUCT MODE - unified targeting for blocks (1-4) and objects (5-9)
		if construct_item_id <= 4:
			# Block targeting - allow placing adjacent to buildings OR placed objects
			var grid_normal = _round_to_axis(normal)
			
			if hit_building or hit_placed_object:
				var inside_pos = pos - normal * 0.01
				voxel_x = int(floor(inside_pos.x))
				voxel_y = int(floor(inside_pos.y))
				voxel_z = int(floor(inside_pos.z))
				current_remove_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
				current_voxel_pos = current_remove_voxel_pos + grid_normal
			else:
				if placement_mode == PlacementMode.EMBED:
					voxel_x = int(floor(pos.x))
					voxel_y = int(floor(pos.y))
					voxel_z = int(floor(pos.z))
				else:
					var offset_pos = pos + normal * 0.6
					voxel_x = int(floor(offset_pos.x))
					voxel_y = int(floor(offset_pos.y)) + placement_y_offset
					voxel_z = int(floor(offset_pos.z))
					
					if placement_mode == PlacementMode.AUTO:
						var terrain_y = _get_terrain_height_at(float(voxel_x) + 0.5, float(voxel_z) + 0.5)
						var float_distance = float(voxel_y) - terrain_y
						if float_distance > auto_embed_threshold:
							voxel_y = int(floor(terrain_y))
				
				current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
				current_remove_voxel_pos = current_voxel_pos
			
			# SAFETY: Never allow placing inside an existing block
			if building_manager.get_voxel(current_voxel_pos) > 0:
				selection_box.visible = false
				has_target = false
				return
			
			selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
		else:
			# Object targeting (same as OBJECT mode)
			if hit_placed_object or hit_building:
				var grid_normal = _round_to_axis(normal)
				var inside_pos = pos - normal * 0.01
				voxel_x = int(floor(inside_pos.x))
				voxel_y = int(floor(inside_pos.y))
				voxel_z = int(floor(inside_pos.z))
				current_remove_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
				current_voxel_pos = current_remove_voxel_pos + grid_normal
				current_precise_hit_y = current_voxel_pos.y
				selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
			elif surface_snap_placement:
				voxel_x = int(floor(pos.x))
				voxel_z = int(floor(pos.z))
				voxel_y = int(round(pos.y))
				current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
				current_remove_voxel_pos = current_voxel_pos
				selection_box.global_position = Vector3(voxel_x + 0.5, current_precise_hit_y + 0.5, voxel_z + 0.5)
			else:
				voxel_x = int(floor(pos.x))
				voxel_y = int(floor(pos.y))
				voxel_z = int(floor(pos.z))
				current_voxel_pos = Vector3(voxel_x, voxel_y, voxel_z)
				current_remove_voxel_pos = current_voxel_pos
				selection_box.global_position = current_voxel_pos + Vector3(0.5, 0.5, 0.5)
	
	selection_box.visible = true
	has_target = true

## Round a vector to the nearest axis-aligned unit vector
func _round_to_axis(v: Vector3) -> Vector3:
	var ax = abs(v.x)
	var ay = abs(v.y)
	var az = abs(v.z)
	if ax >= ay and ax >= az:
		return Vector3(sign(v.x), 0, 0)
	elif ay >= ax and ay >= az:
		return Vector3(0, sign(v.y), 0)
	else:
		return Vector3(0, 0, sign(v.z))

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
	
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed: # Place object
		# Build position with fractional Y for natural terrain placement
		var final_pos = Vector3(
			floor(current_voxel_pos.x),  # Grid-snapped X
			current_precise_hit_y,        # Fractional Y (sits on terrain)
			floor(current_voxel_pos.z)   # Grid-snapped Z
		)
		var final_rotation = current_object_rotation
		
		if is_freestyle_placement:
			# Freestyle placement: Center the object on the exact hit point
			# We must compensate for BuildingChunk's auto-centering (Size/2)
			var obj_size = ObjectRegistry.get_rotated_size(current_object_id, current_object_rotation)
			var offset_x = float(obj_size.x) / 2.0
			var offset_z = float(obj_size.z) / 2.0
			
			var compensation = Vector3(offset_x, 0, offset_z)
			final_pos = current_voxel_pos - compensation
			
			# Rotation is currently limited to 90 degree increments by backend
			# Future: Support fine rotation in backend
		
		var success = building_manager.place_object(final_pos, current_object_id, final_rotation)
		
		# FREESTYLE RETRY LOGIC:
		# If direct placement failed (cell occupied), try to find a nearby empty cell to use as an anchor.
		if not success and is_freestyle_placement:
			var chunk_x = floor(final_pos.x / building_manager.CHUNK_SIZE)
			var chunk_y = floor(final_pos.y / building_manager.CHUNK_SIZE)
			var chunk_z = floor(final_pos.z / building_manager.CHUNK_SIZE)
			var chunk_key = Vector3i(chunk_x, chunk_y, chunk_z)
			
			if building_manager.chunks.has(chunk_key):
				var chunk = building_manager.chunks[chunk_key]
				# Calculate local coord relative to chunk
				var local_x = int(floor(final_pos.x)) % building_manager.CHUNK_SIZE
				var local_y = int(floor(final_pos.y)) % building_manager.CHUNK_SIZE
				var local_z = int(floor(final_pos.z)) % building_manager.CHUNK_SIZE
				if local_x < 0: local_x += building_manager.CHUNK_SIZE
				if local_y < 0: local_y += building_manager.CHUNK_SIZE
				if local_z < 0: local_z += building_manager.CHUNK_SIZE
				
				var base_anchor = Vector3i(local_x, local_y, local_z)
				
				# Expanded search: Check 2-block radius (5x5x5 volume)
				var range_r = 2
				for dx in range(-range_r, range_r + 1):
					for dy in range(-range_r, range_r + 1):
						for dz in range(-range_r, range_r + 1):
							if dx == 0 and dy == 0 and dz == 0: continue
							
							var try_anchor = base_anchor + Vector3i(dx, dy, dz)
							if chunk.is_cell_available(try_anchor):
								# Found a free cell! Use it as the anchor.
								var anchor_world_pos = Vector3(chunk_key) * building_manager.CHUNK_SIZE + Vector3(try_anchor)
								var new_fractional = final_pos - anchor_world_pos
								
								var cells: Array[Vector3i] = [try_anchor] 
								var obj_def = ObjectRegistry.get_object(current_object_id)
								var packed = load(obj_def.scene)
								var instance = packed.instantiate()
								
								instance.rotation_degrees.y = final_rotation * 90
								
								# Use internal place method
								chunk.place_object(try_anchor, current_object_id, final_rotation, cells, instance, new_fractional)
								
								print("Freestyle Placement: Redirected anchor to ", try_anchor)
								print("Placed object %d at %s" % [current_object_id, final_pos])
								return

		if success:
			print("Placed object %d at %s" % [current_object_id, final_pos])
		else:
			print("Cannot place object - cells not available")

	elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed: # Remove object
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

## Handle CONSTRUCT mode input - unified block (1-4), object (5-9), and vegetation (0) placement
func handle_construct_input(event):
	if construct_item_id == 0:
		# Vegetation placement (Rock/Grass)
		_handle_construct_vegetation_input(event)
	elif construct_item_id <= 4:
		# Block placement (1-4)
		_handle_construct_block_input(event)
	else:
		# Object placement (5-9)
		_handle_construct_object_input(event)

## Handle block placement in CONSTRUCT mode
func _handle_construct_block_input(event):
	if event.button_index == MOUSE_BUTTON_RIGHT: # Add block
		building_manager.set_voxel(current_voxel_pos, construct_item_id, construct_rotation)
		
	elif event.button_index == MOUSE_BUTTON_LEFT: # Remove block
		var hit = raycast(10.0, false)
		if hit and hit.collider:
			if hit.collider.get_parent() is BuildingChunk:
				var remove_pos = hit.position - hit.normal * 0.01
				var voxel_pos = Vector3(floor(remove_pos.x), floor(remove_pos.y), floor(remove_pos.z))
				building_manager.set_voxel(voxel_pos, 0.0)

## Handle object placement in CONSTRUCT mode
func _handle_construct_object_input(event):
	# Object IDs in construct: 5-9 map to ObjectRegistry IDs 1-5
	var object_id = construct_item_id - 4
	
	if event.button_index == MOUSE_BUTTON_RIGHT: # Place object
		var placement_pos = Vector3(
			floor(current_voxel_pos.x),
			current_precise_hit_y,
			floor(current_voxel_pos.z)
		)
		var success = building_manager.place_object(placement_pos, object_id, construct_rotation)
		if success:
			print("Placed object %d at %s" % [object_id, placement_pos])
		else:
			print("Cannot place object - cells not available")
	
	elif event.button_index == MOUSE_BUTTON_LEFT: # Remove object
		var hit = raycast(10.0, false)
		if hit and hit.collider:
			if hit.collider.is_in_group("placed_objects"):
				if hit.collider.has_meta("anchor") and hit.collider.has_meta("chunk"):
					var anchor = hit.collider.get_meta("anchor")
					var chunk = hit.collider.get_meta("chunk")
					if anchor != null and chunk != null:
						var success = chunk.remove_object(anchor)
						if success:
							print("Removed object at anchor %s" % anchor)
						return
			
			var remove_pos = hit.position - hit.normal * 0.01
			var success = building_manager.remove_object_at(remove_pos)
			if success:
				print("Removed object at %s" % remove_pos)

## Handle vegetation placement in CONSTRUCT mode (Rock/Grass)
func _handle_construct_vegetation_input(event):
	if event.button_index == MOUSE_BUTTON_RIGHT: # Place vegetation
		var hit = raycast(100.0, false)
		if hit and vegetation_manager:
			if construct_vegetation_type == 0:
				vegetation_manager.place_rock(hit.position)
				print("Placed rock at %s" % hit.position)
			else:
				vegetation_manager.place_grass(hit.position)
				print("Placed grass at %s" % hit.position)
	
	elif event.button_index == MOUSE_BUTTON_LEFT: # Harvest vegetation
		var hit = raycast(100.0, true)  # Include areas for vegetation detection
		if hit and hit.collider and vegetation_manager:
			if hit.collider.is_in_group("rocks"):
				vegetation_manager.harvest_rock_by_collider(hit.collider)
			elif hit.collider.is_in_group("grass"):
				vegetation_manager.harvest_grass_by_collider(hit.collider)

## Get human-readable name for construct item ID
func _get_construct_item_name(id: int) -> String:
	if id == 0:
		return "Rock" if construct_vegetation_type == 0 else "Grass"
	match id:
		1: return "Cube"
		2: return "Ramp"
		3: return "Sphere"
		4: return "Stairs"
		5: return "Cardboard Box"
		6: return "Long Crate"
		7: return "Table"
		8: return "Door"
		9: return "Window"
		_: return "Unknown"

## Update or create preview for CONSTRUCT mode (objects only, id >= 5)
func _update_or_create_construct_preview():
	if not has_target or construct_item_id <= 4:
		_destroy_preview()
		return
	
	# Object IDs in construct: 5-9 map to ObjectRegistry IDs 1-5
	var object_id = construct_item_id - 4
	
	# Check if we need to create a new preview (object changed)
	if preview_object_id != object_id or preview_instance == null:
		_destroy_preview()
		_create_construct_preview(object_id)
	
	# Update preview position and rotation
	if preview_instance and has_target:
		var size = ObjectRegistry.get_rotated_size(object_id, construct_rotation)
		var offset_x = float(size.x) / 2.0
		var offset_z = float(size.z) / 2.0
		preview_instance.position = Vector3(
			current_voxel_pos.x + offset_x,
			current_precise_hit_y,
			current_voxel_pos.z + offset_z
		)
		preview_instance.rotation_degrees.y = construct_rotation * 90
		preview_instance.visible = true
		
		# Check validity
		var check_pos = Vector3(floor(current_voxel_pos.x), floor(current_precise_hit_y), floor(current_voxel_pos.z))
		var can_place = building_manager.can_place_object(check_pos, object_id, construct_rotation)
		_set_preview_validity(can_place)
	elif preview_instance:
		preview_instance.visible = false

## Create preview for CONSTRUCT mode object
func _create_construct_preview(object_id: int):
	var obj_def = ObjectRegistry.get_object(object_id)
	if obj_def.is_empty():
		return
	
	var packed = load(obj_def.scene) as PackedScene
	if not packed:
		return
	
	preview_instance = packed.instantiate()
	preview_object_id = object_id
	
	get_tree().root.add_child(preview_instance)
	_apply_preview_material(preview_instance)
	_disable_preview_collisions(preview_instance)

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

## Get terrain height at a world position (for AUTO placement mode)
func _get_terrain_height_at(x: float, z: float) -> float:
	if terrain_manager and terrain_manager.has_method("get_terrain_height"):
		return terrain_manager.get_terrain_height(x, z)
	return 0.0

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
		
		if is_freestyle_placement:
			# Freestyle: Preview matches exact hit position
			# We show the object centered on the hit point
			preview_instance.position = current_voxel_pos
			
			# Apply fine rotation
			var base_rot = current_object_rotation * 90
			preview_instance.rotation_degrees.y = base_rot + freestyle_rotation_offset
		else:
			# Snapped: Preview matches grid position + centering
			preview_instance.position = Vector3(
				current_voxel_pos.x + offset_x,
				current_precise_hit_y,
				current_voxel_pos.z + offset_z
			)
			preview_instance.rotation_degrees.y = current_object_rotation * 90
			
		preview_instance.visible = true
		
		# Check validity
		if is_freestyle_placement:
			# Freestyle is valid (physics will handle collision)
			_set_preview_validity(true)
		else:
			# Standard grid check
			var check_pos = Vector3(floor(current_voxel_pos.x), floor(current_precise_hit_y), floor(current_voxel_pos.z))
			var can_place = building_manager.can_place_object(
				check_pos,
				current_object_id,
				current_object_rotation
			)
			_set_preview_validity(can_place)
	elif preview_instance:
		preview_instance.visible = false

## Get exact physics height at position using a vertical raycast
func _get_physics_height_at(x: float, z: float, start_y: float) -> float:
	var space_state = player.get_world_3d().direct_space_state
	var from = Vector3(x, start_y + 2.0, z) # Start 2 meters above
	var to = Vector3(x, start_y - 2.0, z)   # Cast 2 meters below
	
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player.get_rid()] # Exclude player
	# We want to hit everything solid (Terrain, Buildings, other Objects)
	
	var result = space_state.intersect_ray(query)
	if result:
		return result.position.y
	
	return -1000.0 # No hit

## Calculate how much to raise the object so its bottom sits at Y=0
func _calculate_pivot_offset(node: Node3D) -> float:
	var min_y = 0.0
	var found = false
	
	# Recursively check meshes
	var meshes = _find_all_mesh_instances(node)
	if meshes.is_empty():
		return 0.0
		
	for mesh in meshes:
		var aabb = mesh.get_aabb()
		# Transform AABB corners to node local space
		# The mesh might be a child with its own transform
		var tr = node.global_transform.affine_inverse() * mesh.global_transform
		
		for i in range(8):
			var corner = aabb.get_endpoint(i)
			var local_pt = tr * corner
			if not found or local_pt.y < min_y:
				min_y = local_pt.y
				found = true
	
	# If min_y is -0.5, we need to raise by 0.5.
	# If min_y is 0, we raise by 0.
	# Return positive offset
	return -min_y if found else 0.0

func _find_all_mesh_instances(node: Node, list: Array = []) -> Array:
	if node is MeshInstance3D:
		list.append(node)
	for child in node.get_children():
		_find_all_mesh_instances(child, list)
	return list

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

## Show vehicle exit prompt when player is in a vehicle
func _show_vehicle_exit_prompt():
	if not interaction_label:
		_create_interaction_label()
	
	if interaction_label:
		interaction_label.text = "Press E to exit vehicle"
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

## ============== VEHICLE SYSTEM ==============

## Enter a vehicle
func _enter_vehicle(vehicle: Node3D) -> void:
	if not vehicle or not vehicle.has_method("enter_vehicle"):
		return
	
	print("[Vehicle] Entering vehicle")
	is_in_vehicle = true
	current_vehicle = vehicle
	
	# Tell vehicle player is entering
	vehicle.enter_vehicle(player)
	
	# Disable player CharacterBody3D movement and hide it
	player.process_mode = Node.PROCESS_MODE_DISABLED
	player.visible = false
	
	# Keep this controller active so we can still receive input to exit after player is disabled
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	# Enable vehicle camera
	if vehicle.has_method("set_camera_active"):
		vehicle.set_camera_active(true)
	
	# Track in vehicle manager
	if vehicle_manager:
		vehicle_manager.current_player_vehicle = vehicle
		vehicle_manager.player_entered_vehicle.emit(vehicle)
	
	# Switch terrain generation to follow the vehicle
	if terrain_manager and "viewer" in terrain_manager:
		terrain_manager.viewer = vehicle
		print("[Interaction] Switched terrain viewer to Vehicle")
	
	# Show exit prompt
	_show_interaction_prompt()


## Exit the current vehicle
func _exit_vehicle() -> void:
	if not current_vehicle or not current_vehicle.has_method("exit_vehicle"):
		return
	
	print("[Vehicle] Exiting vehicle")
	
	# Get exit position from vehicle
	var exit_pos = current_vehicle.global_position + Vector3(0, 1, 0)
	if current_vehicle.has_method("get_exit_position"):
		exit_pos = current_vehicle.get_exit_position()
	
	# Ensure exit position is above terrain
	if terrain_manager and terrain_manager.has_method("get_terrain_height"):
		var terrain_y = terrain_manager.get_terrain_height(exit_pos.x, exit_pos.z)
		# Place player at least 0.5 units above terrain (half player capsule height)
		if exit_pos.y < terrain_y + 0.5:
			exit_pos.y = terrain_y + 0.5
	
	# Disable vehicle camera first
	if current_vehicle.has_method("set_camera_active"):
		current_vehicle.set_camera_active(false)
	
	# Tell vehicle player is exiting
	current_vehicle.exit_vehicle()
	
	# Move player to exit position and re-enable
	player.global_position = exit_pos
	player.visible = true
	player.process_mode = Node.PROCESS_MODE_INHERIT
	player.velocity = Vector3.ZERO
	
	# Make player camera current again
	camera.current = true
	
	# Switch terrain generation back to player
	if terrain_manager and "viewer" in terrain_manager:
		terrain_manager.viewer = player
		print("[Interaction] Switched terrain viewer to Player")
	
	# Track in vehicle manager
	if vehicle_manager:
		vehicle_manager.player_exited_vehicle.emit(current_vehicle)
		vehicle_manager.current_player_vehicle = null
	
	is_in_vehicle = false
	current_vehicle = null
	
	# Restore normal process mode (inherit from parent)
	process_mode = Node.PROCESS_MODE_INHERIT
	
	# Hide interaction prompt
	_hide_interaction_prompt()

# ============ PREFAB PLACEMENT SYSTEM ============

func _load_available_prefabs():
	# Get prefab spawner reference
	if not prefab_spawner:
		prefab_spawner = get_node_or_null("/root/MainGame/PrefabSpawner")
	
	if prefab_spawner and prefab_spawner.has_method("get_available_prefabs"):
		available_prefabs = prefab_spawner.get_available_prefabs()
		current_prefab_index = 0
		prefab_rotation = 0
		print("[PREFAB] Loaded %d prefabs" % available_prefabs.size())
		if available_prefabs.size() > 0:
			_update_prefab_preview()
	else:
		available_prefabs = []
		print("[PREFAB] No PrefabSpawner found or no prefabs available")

func handle_prefab_input(event):
	if event.button_index == MOUSE_BUTTON_RIGHT:
		# Place prefab
		_place_current_prefab()

func _place_current_prefab():
	if available_prefabs.size() == 0 or current_prefab_index >= available_prefabs.size():
		print("[PREFAB] No prefab selected")
		return
	
	var prefab_name = available_prefabs[current_prefab_index]
	print("[PREFAB] Attempting to place: %s" % prefab_name)
	
	# Get spawn position from raycast
	var hit = raycast(50.0, false)
	if not hit:
		print("[PREFAB] No valid placement position - raycast returned nothing")
		return
	
	print("[PREFAB] Raycast hit at: %v" % hit.position)
	
	# Use floor for X/Z grid alignment, ceil for Y to place ON terrain (not into it)
	var spawn_pos = Vector3(floor(hit.position.x), ceil(hit.position.y), floor(hit.position.z))
	
	# Road snap: override Y position to snap to road height
	# Subtract 1 so the door (at Y=1 in prefab) is at road level, not the floor
	# Add manual Y offset from scroll wheel
	if prefab_snap_to_road:
		var road_y = _get_road_height_at(spawn_pos.x, spawn_pos.z)
		if road_y > 0:
			spawn_pos.y = floor(road_y) - 1 + prefab_road_snap_y_offset
			print("[PREFAB] Snapped to road height: Y = %.1f (offset: %d)" % [spawn_pos.y, prefab_road_snap_y_offset])
	
	print("[PREFAB] Spawn position: %v" % spawn_pos)
	
	# Ensure prefab_spawner reference
	if not prefab_spawner:
		prefab_spawner = get_node_or_null("/root/MainGame/PrefabSpawner")
		print("[PREFAB] Found PrefabSpawner: %s" % (prefab_spawner != null))
	
	# Spawn via PrefabSpawner
	if prefab_spawner and prefab_spawner.has_method("spawn_user_prefab"):
		var mode_str = _get_prefab_mode_str()
		
		if prefab_carve_fill_mode:
			# Carve+Fill mode: First carve (no blocks), wait 10 seconds, then fill+place blocks
			print("[PREFAB] Carve+Fill mode: Carving terrain (no blocks yet)...")
			# Step 1: Carve terrain only - skip_blocks=true means no blocks placed
			var carve_success = prefab_spawner.spawn_user_prefab(prefab_name, spawn_pos, 1, prefab_rotation, true, false, true)
			if carve_success:
				print("[PREFAB] Carve complete. Waiting 10 seconds before fill+blocks...")
				# Step 2: Wait 10 seconds, then fill terrain AND place blocks
				_schedule_prefab_fill(prefab_name, spawn_pos, prefab_rotation)
			else:
				print("[PREFAB] Carve failed for %s" % prefab_name)
		else:
			# Normal modes: Surface, Carve, or Fill
			var submerge = 1 if prefab_carve_mode else 0
			var success = prefab_spawner.spawn_user_prefab(prefab_name, spawn_pos, submerge, prefab_rotation, prefab_carve_mode, prefab_foundation_fill, false, prefab_interior_carve)
			if success:
				print("[PREFAB] Placed %s at %v (rot: %d, mode: %s)" % [prefab_name, spawn_pos, prefab_rotation * 90, mode_str])
			else:
				print("[PREFAB] Failed to place %s" % prefab_name)
	else:
		print("[PREFAB] ERROR: PrefabSpawner not found or missing spawn_user_prefab method")

## Calculate road height at a given X, Z position by finding nearest road and sampling terrain
func _get_road_height_at(x: float, z: float) -> float:
	if not terrain_manager:
		return -1.0
	
	# Get road spacing from terrain manager
	var spacing = 100.0  # Default
	if "procedural_road_spacing" in terrain_manager:
		spacing = terrain_manager.procedural_road_spacing
	
	if spacing <= 0:
		return -1.0  # No roads
	
	# Find nearest road (roads are at grid edges: x % spacing == 0 or z % spacing == 0)
	# Check both the X-aligned and Z-aligned roads and use the closer one
	var nearest_x_road = round(x / spacing) * spacing  # Nearest road running along X
	var nearest_z_road = round(z / spacing) * spacing  # Nearest road running along Z
	
	var dist_to_x_road = abs(x - nearest_x_road)
	var dist_to_z_road = abs(z - nearest_z_road)
	
	# Sample terrain height ON the road (at the road center)
	var road_x: float
	var road_z: float
	
	if dist_to_x_road < dist_to_z_road:
		# Closer to an X-aligned road (vertical line at x = nearest_x_road)
		road_x = nearest_x_road
		road_z = z
	else:
		# Closer to a Z-aligned road (horizontal line at z = nearest_z_road)
		road_x = x
		road_z = nearest_z_road
	
	# Query actual terrain height at the road position
	if terrain_manager.has_method("get_terrain_height"):
		return terrain_manager.get_terrain_height(road_x, road_z)
	
	return -1.0

## Schedule the fill step for Carve+Fill mode with a 10-second delay
func _schedule_prefab_fill(prefab_name: String, spawn_pos: Vector3, rotation: int):
	print("[PREFAB] Scheduling fill in 10 seconds for %s at %v" % [prefab_name, spawn_pos])
	# Capture spawner reference now (before timer fires)
	var spawner = prefab_spawner
	if not spawner:
		spawner = get_node_or_null("/root/MainGame/PrefabSpawner")
	
	if not spawner:
		print("[PREFAB] ERROR: No PrefabSpawner found for scheduled fill!")
		return
	
	var timer = get_tree().create_timer(10.0)
	timer.timeout.connect(func():
		print("[PREFAB] Timer fired! Executing fill step...")
		if spawner and spawner.has_method("spawn_user_prefab"):
			print("[PREFAB] Carve+Fill mode: Now filling terrain and placing blocks...")
			# Call with submerge=0 (same as standalone Fill mode), foundation_fill=true
			# This fills terrain AND places blocks at the surface level
			var fill_success = spawner.spawn_user_prefab(prefab_name, spawn_pos, 0, rotation, false, true, false)
			if fill_success:
				print("[PREFAB] Fill+blocks complete for %s at %v" % [prefab_name, spawn_pos])
			else:
				print("[PREFAB] Fill failed for %s" % prefab_name)
		else:
			print("[PREFAB] ERROR: Spawner invalid in timer callback!")
	)

func _update_prefab_preview():
	# Destroy existing preview
	_destroy_prefab_preview()
	
	if available_prefabs.size() == 0 or current_prefab_index >= available_prefabs.size():
		return
	
	var prefab_name = available_prefabs[current_prefab_index]
	
	# Load prefab data to get block positions
	if not prefab_spawner:
		prefab_spawner = get_node_or_null("/root/MainGame/PrefabSpawner")
	
	if not prefab_spawner or not prefab_spawner.has_method("load_prefab_from_file"):
		return
	
	# Ensure prefab is loaded
	prefab_spawner.load_prefab_from_file(prefab_name)
	
	# Get blocks from the prefabs dictionary
	if not "prefabs" in prefab_spawner:
		return
	
	if not prefab_spawner.prefabs.has(prefab_name):
		return
	
	var blocks = prefab_spawner.prefabs[prefab_name]
	
	# Create transparent preview mesh for each block
	var preview_material = StandardMaterial3D.new()
	preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_material.albedo_color = Color(0.3, 0.8, 0.3, 0.4)  # Green, 40% opacity
	preview_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	preview_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	
	for block in blocks:
		var offset = block.offset
		var rotated_offset = _rotate_offset(offset, prefab_rotation)
		
		var mesh_inst = MeshInstance3D.new()
		var box = BoxMesh.new()
		box.size = Vector3(0.95, 0.95, 0.95)  # Slightly smaller to prevent z-fighting
		mesh_inst.mesh = box
		mesh_inst.material_override = preview_material
		mesh_inst.set_meta("offset", rotated_offset)
		
		get_tree().root.add_child(mesh_inst)
		prefab_preview_nodes.append(mesh_inst)

func _rotate_offset(offset: Vector3i, rotation: int) -> Vector3i:
	match rotation:
		0: return offset  # No rotation
		1: return Vector3i(-offset.z, offset.y, offset.x)   # 90°
		2: return Vector3i(-offset.x, offset.y, -offset.z)  # 180°
		3: return Vector3i(offset.z, offset.y, -offset.x)   # 270°
	return offset

func _destroy_prefab_preview():
	for node in prefab_preview_nodes:
		if is_instance_valid(node):
			node.queue_free()
	prefab_preview_nodes.clear()

func _process_prefab_preview():
	# Update preview positions based on cursor
	if current_mode != Mode.PREFAB or prefab_preview_nodes.size() == 0:
		return
	
	var hit = raycast(50.0, false)
	if not hit:
		# Hide preview when no valid target
		for node in prefab_preview_nodes:
			if is_instance_valid(node):
				node.visible = false
		return
	
	# Get base position - match the placement logic
	# Surface mode: submerge=0 (on terrain), Carve mode: submerge=1 (buried)
	var submerge = 1 if prefab_carve_mode else 0
	var base_pos = Vector3(floor(hit.position.x), ceil(hit.position.y) - submerge, floor(hit.position.z))
	
	# Road snap: override Y position to snap to road height
	# Subtract 1 so the door (at Y=1 in prefab) is at road level, not the floor
	# Add manual Y offset from scroll wheel
	if prefab_snap_to_road:
		var road_y = _get_road_height_at(base_pos.x, base_pos.z)
		if road_y > 0:
			base_pos.y = floor(road_y) - 1 - submerge + prefab_road_snap_y_offset
	
	# Position each preview block
	for node in prefab_preview_nodes:
		if is_instance_valid(node):
			var offset = node.get_meta("offset", Vector3i.ZERO)
			node.global_position = base_pos + Vector3(offset) + Vector3(0.5, 0.5, 0.5)
			node.visible = true

## ============== PROP PICKUP SYSTEM =============

func _draw_debug_line(start: Vector3, end: Vector3, color: Color):
	if not pickup_debug_mesh or not pickup_debug_mesh.mesh: return
	pickup_debug_mesh.mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	pickup_debug_mesh.mesh.surface_set_color(color)
	pickup_debug_mesh.mesh.surface_add_vertex(start)
	pickup_debug_mesh.mesh.surface_add_vertex(end)
	pickup_debug_mesh.mesh.surface_end()

func _draw_debug_sphere(center: Vector3, radius: float, color: Color):
	if not pickup_debug_mesh or not pickup_debug_mesh.mesh: return
	# Draw 3 circles (XY, XZ, YZ)
	var steps = 16
	pickup_debug_mesh.mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	pickup_debug_mesh.mesh.surface_set_color(color)
	for i in range(steps + 1):
		var angle = (float(i) / steps) * TAU
		pickup_debug_mesh.mesh.surface_add_vertex(center + Vector3(cos(angle) * radius, sin(angle) * radius, 0))
	pickup_debug_mesh.mesh.surface_end()
	
	pickup_debug_mesh.mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	pickup_debug_mesh.mesh.surface_set_color(color)
	for i in range(steps + 1):
		var angle = (float(i) / steps) * TAU
		pickup_debug_mesh.mesh.surface_add_vertex(center + Vector3(cos(angle) * radius, 0, sin(angle) * radius))
	pickup_debug_mesh.mesh.surface_end()
	
	pickup_debug_mesh.mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	pickup_debug_mesh.mesh.surface_set_color(color)
	for i in range(steps + 1):
		var angle = (float(i) / steps) * TAU
		pickup_debug_mesh.mesh.surface_add_vertex(center + Vector3(0, cos(angle) * radius, sin(angle) * radius))
	pickup_debug_mesh.mesh.surface_end()

func _get_pickup_target() -> Node:
	# Debug Setup
	if pickup_debug_mesh and pickup_debug_mesh.mesh:
		pickup_debug_mesh.mesh.clear_surfaces()
		
	var came_node = get_viewport().get_camera_3d()
	var origin = came_node.global_position
	var forward = -came_node.global_transform.basis.z
	
	# 1. OPTION A: PRECISE RAYCAST
	var hit = raycast(5.0, false)
	
	# Visualize Ray
	var ray_end = origin + forward * 5.0
	if hit: ray_end = hit.position
	_draw_debug_line(origin - Vector3(0, 0.1, 0), ray_end, Color.RED) # Slight offset to see it
	
	if hit and hit.collider:
		if hit.collider.is_in_group("placed_objects") and hit.collider.has_meta("anchor"):
			print("Pickup: Direct Hit on %s" % hit.collider.name)
			_draw_debug_sphere(hit.collider.global_position, 0.2, Color.GREEN)
			return hit.collider
			
	# 2. OPTION B: SPHERE ASSIST
	var search_origin = hit.position if hit else (origin + forward * 2.0)
	
	_draw_debug_sphere(search_origin, 0.4, Color.YELLOW) # Visualize search area
	
	var space_state = came_node.get_world_3d().direct_space_state
	var params = PhysicsShapeQueryParameters3D.new()
	params.shape = SphereShape3D.new()
	params.shape.radius = 0.4 # 40cm forgiveness radius
	params.transform = Transform3D(Basis(), search_origin)
	params.collision_mask = 0xFFFFFFFF 
	params.exclude = [player.get_rid()]
	
	var results = space_state.intersect_shape(params, 5) 
	var best_target = null
	var best_dist = 999.0
	
	for result in results:
		var col = result.collider
		if col.is_in_group("placed_objects") and col.has_meta("anchor"):
			var d = col.global_position.distance_to(search_origin)
			if d < best_dist:
				best_dist = d
				best_target = col
	
	if best_target:
		print("Pickup: Assisted Hit on %s" % best_target.name)
		_draw_debug_sphere(best_target.global_position, 0.3, Color.CYAN)
		return best_target
			
	return null

func _try_pickup_prop():
	var target = _get_pickup_target()
	
	if target:
		print("Pickup Found: ", target.name)
		var anchor = target.get_meta("anchor")
		var chunk = target.get_meta("chunk")
	
		# We need to read the object data BEFORE removing it to know what we picked up
		# BuildingChunk stores objects in 'objects' dict
		if chunk.objects.has(anchor):
			var data = chunk.objects[anchor]
			held_prop_id = data["object_id"]
			# Default rotation if missing
			held_prop_rotation = data.get("rotation", 0)
			
			# Remove from world (Logical + Visual)
			chunk.remove_object(anchor)
			
			# Spawn temporary held visual
			var obj_def = ObjectRegistry.get_object(held_prop_id)
			if obj_def.has("scene"):
				var packed = load(obj_def.scene)
				held_prop_instance = packed.instantiate()
				
				# Strip physics/collision for holding
				if held_prop_instance is RigidBody3D:
					held_prop_instance.freeze = true
					held_prop_instance.collision_layer = 0
					held_prop_instance.collision_mask = 0
				
				# Recursive disable collision for children
				_disable_preview_collisions(held_prop_instance)
				
				get_tree().root.add_child(held_prop_instance)
				# Start at camera grab point (not random hit pos)
				var cam = get_viewport().get_camera_3d()
				held_prop_instance.global_position = cam.global_position - cam.global_transform.basis.z * 2.0
				
				print("Picked up Prop ID %d" % held_prop_id)

func _drop_held_prop():
	if not held_prop_instance: return
	
	print("Release detected. Dropping prop.")
	
	# Drop exactly where held (User control)
	var drop_pos = held_prop_instance.global_position
	
	# COMPENSATE FOR CHUNK CENTERING:
	# The building system automatically adds "Half Size" centering.
	# For precise physics drops, we must pre-subtract this so the final result is exactly drop_pos.
	var drop_obj_def = ObjectRegistry.get_object(held_prop_id)
	var size = drop_obj_def.get("size", Vector3i(1, 1, 1))
	var offset_x = float(size.x) / 2.0
	var offset_z = float(size.z) / 2.0
	
	if held_prop_rotation == 1 or held_prop_rotation == 3:
		var temp = offset_x
		offset_x = offset_z
		offset_z = temp
	
	var center_offset = Vector3(offset_x, 0, offset_z)
	var adjusted_drop_pos = drop_pos - center_offset
	
	# Reuse Placement Logic with ADJUSTED position
	var success = building_manager.place_object(adjusted_drop_pos, held_prop_id, held_prop_rotation)
	
	# If direct placement failed, try "Smart Search" (Stacking)
	if not success:
		var chunk_x = floor(drop_pos.x / building_manager.CHUNK_SIZE)
		var chunk_y = floor(drop_pos.y / building_manager.CHUNK_SIZE)
		var chunk_z = floor(drop_pos.z / building_manager.CHUNK_SIZE)
		var chunk_key = Vector3i(chunk_x, chunk_y, chunk_z)
		
		if building_manager.chunks.has(chunk_key):
			var chunk = building_manager.chunks[chunk_key]
			var local_x = int(floor(drop_pos.x)) % building_manager.CHUNK_SIZE
			var local_y = int(floor(drop_pos.y)) % building_manager.CHUNK_SIZE
			var local_z = int(floor(drop_pos.z)) % building_manager.CHUNK_SIZE
			if local_x < 0: local_x += building_manager.CHUNK_SIZE
			if local_y < 0: local_y += building_manager.CHUNK_SIZE
			if local_z < 0: local_z += building_manager.CHUNK_SIZE
			var base_anchor = Vector3i(local_x, local_y, local_z)
			
			var range_r = 2
			for dx in range(-range_r, range_r + 1):
				for dy in range(-range_r, range_r + 1):
					for dz in range(-range_r, range_r + 1):
						if dx == 0 and dy == 0 and dz == 0: continue
						var try_anchor = base_anchor + Vector3i(dx, dy, dz)
						if chunk.is_cell_available(try_anchor):
							var anchor_world_pos = Vector3(chunk_key) * building_manager.CHUNK_SIZE + Vector3(try_anchor)
							var new_fractional = drop_pos - anchor_world_pos
							var cells: Array[Vector3i] = [try_anchor] 
							var obj_def = ObjectRegistry.get_object(held_prop_id)
							var packed = load(obj_def.scene)
							var instance = packed.instantiate()
							instance.position = Vector3(try_anchor) + new_fractional
							instance.rotation_degrees.y = held_prop_rotation * 90
							chunk.place_object(try_anchor, held_prop_id, held_prop_rotation, cells, instance, new_fractional)
							
							print("Dropped Prop (Staked to %s)" % try_anchor)
							# Break inner/outer loops
							success = true
							break
					if success: break
				if success: break
	
	# CRITICAL: Always clean up, whether placement succeeded or not
	if held_prop_instance:
		held_prop_instance.queue_free()
	held_prop_instance = null
	held_prop_id = -1
	print("Prop Release Complete")
