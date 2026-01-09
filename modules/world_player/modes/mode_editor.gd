extends Node
class_name ModeEditor
## ModeEditor - Handles EDITOR mode behaviors
## Terrain sculpting, water editing, roads, prefabs, fly mode

# Preload API scripts
const TerrainAPIScript = preload("res://modules/world_player/api/terrain_api.gd")

# References
var player: WorldPlayer = null
var mode_manager: Node = null
var movement_component: Node = null

# Manager references
var terrain_manager: Node = null
var road_manager: Node = null
var prefab_spawner: Node = null

# API reference for terrain visualization
var terrain_api: Node = null

# Editor state
var brush_size: float = 4.0
var brush_shape: int = 0 # 0=Sphere, 1=Box
var blocky_mode: bool = true

# Fly mode state
var fly_speed: float = 15.0

# Road state
var is_placing_road: bool = false
var road_start_pos: Vector3 = Vector3.ZERO
var road_type: int = 1 # 1=Flatten, 2=Mask, 3=Normalize

# Prefab state
var available_prefabs: Array[String] = []
var current_prefab_index: int = 0
var prefab_rotation: int = 0

func _ready() -> void:
	# Find player
	player = get_parent().get_parent() as WorldPlayer
	
	# Find siblings - ModeManager is in Systems node (sibling of Modes)
	mode_manager = get_node_or_null("../../Systems/ModeManager")
	
	# Find movement component
	if player:
		movement_component = player.get_node_or_null("Components/Movement")
	
	# Find managers via groups
	await get_tree().process_frame
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	road_manager = get_tree().get_first_node_in_group("road_manager")
	
	# Find prefab spawner
	prefab_spawner = get_tree().get_first_node_in_group("prefab_spawner")
	if not prefab_spawner:
		prefab_spawner = get_tree().root.find_child("PrefabSpawner", true, false)
	
	# Load available prefabs
	_load_prefabs()
	
	# Create terrain API for selection box visualization
	terrain_api = TerrainAPIScript.new()
	add_child(terrain_api)
	terrain_api.initialize(player)
	
	print("ModeEditor: Initialized")

func _process(_delta: float) -> void:
	# Update selection box when in editor terrain/water mode
	if mode_manager and mode_manager.is_editor_mode() and terrain_api:
		var submode = mode_manager.editor_submode
		if submode == 0 or submode == 1: # TERRAIN or WATER
			# Sync blocky mode to API
			terrain_api.blocky_mode = blocky_mode
			
			# Update targeting from player raycast
			if player:
				var hit = player.raycast(100.0)
				terrain_api.update_targeting(hit)
		else:
			# Hide selection box in other submodes
			terrain_api.hide_visuals()
	else:
		# Hide when not in editor mode
		if terrain_api:
			terrain_api.hide_visuals()

func _physics_process(delta: float) -> void:
	# Handle fly movement when in editor mode + fly enabled
	if mode_manager and mode_manager.is_fly_active():
		_process_fly_movement(delta)

func _input(event: InputEvent) -> void:
	# Only handle input in EDITOR mode
	if not mode_manager or not mode_manager.is_editor_mode():
		return
	
	if event is InputEventKey and event.pressed and not event.echo:
		var submode = mode_manager.editor_submode
		
		match event.keycode:
			KEY_G:
				# Toggle blocky mode (terrain/water)
				blocky_mode = not blocky_mode
				print("ModeEditor: Blocky mode -> %s" % ("ON" if blocky_mode else "OFF"))
			KEY_R:
				# Rotate prefab
				if submode == 3: # PREFAB
					prefab_rotation = (prefab_rotation + 1) % 4
					print("ModeEditor: Prefab rotation -> %d°" % (prefab_rotation * 90))
			KEY_BRACKETLEFT:
				# Previous prefab
				if submode == 3 and available_prefabs.size() > 0:
					current_prefab_index = (current_prefab_index - 1 + available_prefabs.size()) % available_prefabs.size()
					print("ModeEditor: Prefab -> %s" % _get_current_prefab_name())
			KEY_BRACKETRIGHT:
				# Next prefab
				if submode == 3 and available_prefabs.size() > 0:
					current_prefab_index = (current_prefab_index + 1) % available_prefabs.size()
					print("ModeEditor: Prefab -> %s" % _get_current_prefab_name())
	
	# Scroll to change brush size
	if event is InputEventMouseButton and event.pressed:
		if event.shift_pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				brush_size = min(brush_size + 0.5, 20.0)
				print("ModeEditor: Brush size -> %.1f" % brush_size)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				brush_size = max(brush_size - 0.5, 0.5)
				print("ModeEditor: Brush size -> %.1f" % brush_size)

## Handle primary action (left click) in EDITOR mode
func handle_primary(_item: Dictionary) -> void:
	if not mode_manager:
		return
	
	var submode = mode_manager.editor_submode
	
	match submode:
		0: # TERRAIN
			_do_terrain_dig()
		1: # WATER
			_do_water_remove()
		2: # ROAD
			_do_road_click()
		3: # PREFAB
			pass # No primary action for prefab (use secondary to place)
		5: # OLDDIRT (legacy)
			_do_legacy_dirt_dig()

## Handle secondary action (right click) in EDITOR mode
func handle_secondary(_item: Dictionary) -> void:
	if not mode_manager:
		return
	
	var submode = mode_manager.editor_submode
	
	match submode:
		0: # TERRAIN
			_do_terrain_place()
		1: # WATER
			_do_water_add()
		2: # ROAD
			_do_road_click() # Same as primary for roads
		3: # PREFAB
			_do_prefab_place()
		5: # OLDDIRT (legacy)
			_do_legacy_dirt_place()

## Terrain sculpting - dig
func _do_terrain_dig() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var shape = brush_shape
	var size = brush_size if not blocky_mode else 0.6
	
	if blocky_mode:
		# Blocky dig - target voxel inside terrain
		position = position - hit.get("normal", Vector3.ZERO) * 0.1
		position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
		shape = 1 # Box
	
	terrain_manager.modify_terrain(position, size, 1.0, shape, 0)
	print("ModeEditor: Dug terrain at %s (size: %.1f, blocky: %s)" % [position, size, blocky_mode])

## Terrain sculpting - place
func _do_terrain_place() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var shape = brush_shape
	var size = brush_size if not blocky_mode else 0.6
	
	if blocky_mode:
		# Blocky place - target voxel outside terrain
		position = position + hit.get("normal", Vector3.ZERO) * 0.1
		position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
		shape = 1 # Box
	
	terrain_manager.modify_terrain(position, size, -1.0, shape, 0)
	print("ModeEditor: Placed terrain at %s" % position)

## Water editing - remove
func _do_water_remove() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	terrain_manager.modify_terrain(position, brush_size, 1.0, 0, 1) # Layer 1 = water
	print("ModeEditor: Removed water at %s" % position)

## Water editing - add
func _do_water_add() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	terrain_manager.modify_terrain(position, brush_size, -1.0, 0, 1)
	print("ModeEditor: Added water at %s" % position)

## Road placement click
func _do_road_click() -> void:
	if not player or not road_manager:
		print("ModeEditor: Road manager not found")
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	
	if not is_placing_road:
		# Start road
		road_start_pos = position
		is_placing_road = true
		if road_manager.has_method("start_road"):
			road_manager.start_road(position, road_type)
		print("ModeEditor: Road start at %s (type: %d)" % [position, road_type])
	else:
		# End road
		if road_manager.has_method("end_road"):
			road_manager.end_road(position)
		print("ModeEditor: Road end at %s" % position)
		is_placing_road = false

## Prefab placement
func _do_prefab_place() -> void:
	if not player or not prefab_spawner:
		print("ModeEditor: Prefab spawner not found")
		return
	
	if available_prefabs.is_empty():
		print("ModeEditor: No prefabs available")
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var prefab_path = available_prefabs[current_prefab_index]
	
	if prefab_spawner.has_method("spawn_prefab"):
		prefab_spawner.spawn_prefab(prefab_path, position, prefab_rotation)
		print("ModeEditor: Placed prefab %s at %s (rot: %d°)" % [_get_current_prefab_name(), position, prefab_rotation * 90])

## Process fly movement
func _process_fly_movement(_delta: float) -> void:
	if not player:
		return
	
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var camera = player.get_node_or_null("Camera3D")
	
	if not camera:
		return
	
	var cam_basis = camera.global_transform.basis
	var direction = (cam_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	player.velocity = Vector3.ZERO
	
	if direction:
		player.velocity = direction * fly_speed
	
	# Vertical movement
	if Input.is_action_pressed("ui_accept"):
		player.velocity.y = fly_speed
	if Input.is_key_pressed(KEY_SHIFT):
		player.velocity.y = - fly_speed
	
	player.move_and_slide()

## Load available prefabs from directory
func _load_prefabs() -> void:
	available_prefabs.clear()
	
	var prefab_dir = "res://world_prefabs/"
	var dir = DirAccess.open(prefab_dir)
	
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(".json"):
				available_prefabs.append(prefab_dir + file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
	
	print("ModeEditor: Loaded %d prefabs" % available_prefabs.size())

## Get current prefab filename
func _get_current_prefab_name() -> String:
	if available_prefabs.is_empty():
		return "None"
	return available_prefabs[current_prefab_index].get_file().get_basename()

#region Legacy Dirt Placement (OldDirt submode)

## Legacy dirt - dig (removes terrain at blocky grid position)
func _do_legacy_dirt_dig() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	# Target voxel inside terrain
	position = position - hit.get("normal", Vector3.ZERO) * 0.1
	position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
	
	terrain_manager.modify_terrain(position, 0.6, 0.5, 1, 0) # Box shape, dig, terrain layer
	print("ModeEditor: [OldDirt] Dug at %s" % position)

## Legacy dirt - place (adds terrain at blocky grid position)  
func _do_legacy_dirt_place() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	# Target voxel outside terrain (adjacent to hit surface)
	position = position + hit.get("normal", Vector3.ZERO) * 0.1
	position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
	
	terrain_manager.modify_terrain(position, 0.6, -0.5, 1, 0) # Box shape, fill, terrain layer
	print("ModeEditor: [OldDirt] Placed at %s" % position)

#endregion
