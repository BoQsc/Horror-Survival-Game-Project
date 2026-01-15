extends Node
class_name ModeEditorV2
## ModeEditor - Handles EDITOR mode behaviors
## Terrain sculpting, water editing, roads, prefabs, fly mode

# V2 path
const TerrainAPIScript = preload("res://modules/world_player_v2/api/terrain_api.gd")

# References
var player: Node = null
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
	player = get_parent().get_parent()
	
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
			terrain_api.blocky_mode = blocky_mode
			if player and player.has_method("raycast"):
				var hit = player.raycast(100.0)
				terrain_api.update_targeting(hit)
		else:
			terrain_api.hide_visuals()
	else:
		if terrain_api:
			terrain_api.hide_visuals()

func _physics_process(delta: float) -> void:
	if mode_manager and mode_manager.is_fly_active():
		_process_fly_movement(delta)

func _input(event: InputEvent) -> void:
	if not mode_manager or not mode_manager.is_editor_mode():
		return
	
	if event is InputEventKey and event.pressed and not event.echo:
		var submode = mode_manager.editor_submode
		
		match event.keycode:
			KEY_G:
				blocky_mode = not blocky_mode
				print("ModeEditor: Blocky mode -> %s" % ("ON" if blocky_mode else "OFF"))
			KEY_R:
				if submode == 3: # PREFAB
					prefab_rotation = (prefab_rotation + 1) % 4
					print("ModeEditor: Prefab rotation -> %d°" % (prefab_rotation * 90))
			KEY_BRACKETLEFT:
				if submode == 3 and available_prefabs.size() > 0:
					current_prefab_index = (current_prefab_index - 1 + available_prefabs.size()) % available_prefabs.size()
					print("ModeEditor: Prefab -> %s" % _get_current_prefab_name())
			KEY_BRACKETRIGHT:
				if submode == 3 and available_prefabs.size() > 0:
					current_prefab_index = (current_prefab_index + 1) % available_prefabs.size()
					print("ModeEditor: Prefab -> %s" % _get_current_prefab_name())
	
	if event is InputEventMouseButton and event.pressed:
		if event.shift_pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				brush_size = min(brush_size + 0.5, 20.0)
				print("ModeEditor: Brush size -> %.1f" % brush_size)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				brush_size = max(brush_size - 0.5, 0.5)
				print("ModeEditor: Brush size -> %.1f" % brush_size)

func handle_primary(item: Dictionary) -> void:
	if not mode_manager:
		return
	
	# If item is not an editor tool, delegate based on category
	if not item.has("editor_submode"):
		var category = item.get("category", 0)
		var build_mode = get_node_or_null("../ModeBuild")
		var combat = get_node_or_null("../CombatSystem")
		
		# Building items (BLOCK=4, OBJECT=5, PROP=6) -> build_mode
		if category in [4, 5, 6] and build_mode and build_mode.has_method("handle_primary"):
			build_mode.handle_primary(item)
		# Everything else (empty, tools, etc.) -> combat for punching/attacking
		elif combat and combat.has_method("handle_primary"):
			combat.handle_primary(item)
		return
	
	var submode = mode_manager.editor_submode
	
	match submode:
		0: _do_terrain_dig()
		1: _do_water_remove()
		2: _do_road_click()
		3: pass
		5: _do_legacy_dirt_dig()

func handle_secondary(item: Dictionary) -> void:
	if not mode_manager:
		return
	
	# If item is not an editor tool, delegate based on category
	if not item.has("editor_submode"):
		var category = item.get("category", 0)
		var build_mode = get_node_or_null("../ModeBuild")
		var combat = get_node_or_null("../CombatSystem")
		
		# Building items (BLOCK=4, OBJECT=5, PROP=6) -> build_mode
		if category in [4, 5, 6] and build_mode and build_mode.has_method("handle_secondary"):
			build_mode.handle_secondary(item)
		# Everything else -> combat
		elif combat and combat.has_method("handle_secondary"):
			combat.handle_secondary(item)
		return
	
	var submode = mode_manager.editor_submode
	
	match submode:
		0: _do_terrain_place()
		1: _do_water_add()
		2: _do_road_click()
		3: _do_prefab_place()
		5: _do_legacy_dirt_place()

func _do_terrain_dig() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0) if player.has_method("raycast") else {}
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var shape = brush_shape
	var size = brush_size if not blocky_mode else 0.6
	
	if blocky_mode:
		position = position - hit.get("normal", Vector3.ZERO) * 0.1
		position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
		shape = 1
	
	terrain_manager.modify_terrain(position, size, 1.0, shape, 0)

func _do_terrain_place() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0) if player.has_method("raycast") else {}
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var shape = brush_shape
	var size = brush_size if not blocky_mode else 0.6
	
	if blocky_mode:
		position = position + hit.get("normal", Vector3.ZERO) * 0.1
		position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
		shape = 1
	
	terrain_manager.modify_terrain(position, size, -1.0, shape, 0)

func _do_water_remove() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0) if player.has_method("raycast") else {}
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	terrain_manager.modify_terrain(position, brush_size, 1.0, 0, 1)

func _do_water_add() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0) if player.has_method("raycast") else {}
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	terrain_manager.modify_terrain(position, brush_size, -1.0, 0, 1)

func _do_road_click() -> void:
	if not player or not road_manager:
		return
	
	var hit = player.raycast(100.0) if player.has_method("raycast") else {}
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	
	if not is_placing_road:
		road_start_pos = position
		is_placing_road = true
		if road_manager.has_method("start_road"):
			road_manager.start_road(position, road_type)
	else:
		if road_manager.has_method("end_road"):
			road_manager.end_road(position)
		is_placing_road = false

func _do_prefab_place() -> void:
	if not player or not prefab_spawner:
		return
	
	if available_prefabs.is_empty():
		return
	
	var hit = player.raycast(100.0) if player.has_method("raycast") else {}
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var prefab_path = available_prefabs[current_prefab_index]
	
	if prefab_spawner.has_method("spawn_prefab"):
		prefab_spawner.spawn_prefab(prefab_path, position, prefab_rotation)

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
	
	if Input.is_action_pressed("ui_accept"):
		player.velocity.y = fly_speed
	if Input.is_key_pressed(KEY_SHIFT):
		player.velocity.y = - fly_speed
	
	player.move_and_slide()

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

func _get_current_prefab_name() -> String:
	if available_prefabs.is_empty():
		return "None"
	return available_prefabs[current_prefab_index].get_file().get_basename()

func _do_legacy_dirt_dig() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0) if player.has_method("raycast") else {}
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	position = position - hit.get("normal", Vector3.ZERO) * 0.1
	position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
	
	terrain_manager.modify_terrain(position, 0.6, 0.5, 1, 0)

func _do_legacy_dirt_place() -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(100.0) if player.has_method("raycast") else {}
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	position = position + hit.get("normal", Vector3.ZERO) * 0.1
	position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
	
	terrain_manager.modify_terrain(position, 0.6, -0.5, 1, 0)
