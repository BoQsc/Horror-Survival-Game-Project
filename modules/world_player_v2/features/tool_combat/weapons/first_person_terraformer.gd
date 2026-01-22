extends Node
class_name FirstPersonShovelV2
## FirstPersonShovel - Handles grid-snapped terrain dig/fill with material selection
## P to toggle dig/place mode, CTRL + 1-7 to select material
## Dig mode (red) = remove blocks, Place mode (green) = add blocks

# Material definitions (id matches gen_density.glsl material IDs)
const MATERIALS = [
	{"id": 0, "name": "Grass", "key": KEY_1},
	{"id": 1, "name": "Stone", "key": KEY_2},
	{"id": 2, "name": "Ore", "key": KEY_3},
	{"id": 3, "name": "Sand", "key": KEY_4},
	{"id": 4, "name": "Gravel", "key": KEY_5},
	{"id": 5, "name": "Snow", "key": KEY_6},
	{"id": 9, "name": "Granite", "key": KEY_7}
]

# Current state
var material_index: int = 0  # Default to Grass
var is_active: bool = false  # Whether terraformer is equipped
var dig_mode: bool = false   # false = Place mode (default), true = Dig mode

# References
var player: CharacterBody3D = null
var terrain_manager: Node = null

# Selection box visualization
var selection_box: MeshInstance3D = null
var current_dig_target: Vector3 = Vector3.ZERO    # Voxel-centered position to dig
var current_place_target: Vector3 = Vector3.ZERO  # Voxel-centered position to place
var has_target: bool = false

# Constants
const RAYCAST_DISTANCE: float = 10.0
const BRUSH_SIZE: float = 0.5  # Radius for Box shape to capture single voxel
const BRUSH_SHAPE: int = 1  # 1 = Box shape in modify_density.glsl

# Colors
const COLOR_DIG = Color(0.8, 0.2, 0.2, 0.5)   # Red for dig mode
const COLOR_PLACE = Color(0.2, 0.8, 0.4, 0.5) # Green for place mode

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("FirstPersonShovel: Must be child of Player/Components node")
		return
	
	call_deferred("_find_terrain_manager")
	call_deferred("_create_selection_box")
	
	# Connect to item changes
	if has_node("/root/PlayerSignals"):
		PlayerSignals.item_changed.connect(_on_item_changed)
	
	print("SHOVEL: Initialized, mode = %s, material = %s" % [_get_mode_name(), MATERIALS[material_index].name])

func _find_terrain_manager() -> void:
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if not terrain_manager:
		push_warning("FirstPersonShovel: terrain_manager not found")

func _create_selection_box() -> void:
	selection_box = MeshInstance3D.new()
	selection_box.mesh = _create_diamond_mesh()
	
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = COLOR_PLACE  # Default to place mode color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	selection_box.material_override = material
	selection_box.visible = false
	
	get_tree().root.add_child.call_deferred(selection_box)

func _create_diamond_mesh() -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Octahedron vertices (Diamond shape)
	var s = 0.51
	
	var top = Vector3(0, s, 0)
	var bot = Vector3(0, -s, 0)
	var p1 = Vector3(s, 0, 0)  # Right
	var p2 = Vector3(0, 0, s)  # Back
	var p3 = Vector3(-s, 0, 0) # Left
	var p4 = Vector3(0, 0, -s) # Front
	
	# Top Pyramid
	st.add_vertex(p1); st.add_vertex(top); st.add_vertex(p2)
	st.add_vertex(p2); st.add_vertex(top); st.add_vertex(p3)
	st.add_vertex(p3); st.add_vertex(top); st.add_vertex(p4)
	st.add_vertex(p4); st.add_vertex(top); st.add_vertex(p1)
	
	# Bottom Pyramid
	st.add_vertex(p2); st.add_vertex(bot); st.add_vertex(p1)
	st.add_vertex(p3); st.add_vertex(bot); st.add_vertex(p2)
	st.add_vertex(p4); st.add_vertex(bot); st.add_vertex(p3)
	st.add_vertex(p1); st.add_vertex(bot); st.add_vertex(p4)
	
	st.generate_normals()
	return st.commit()

# ============================================================================
# UNIFIED TARGETING LOGIC - Using voxel-centered approach like combat_system
# ============================================================================

## Calculate dig target using integer grid coordinates
func _get_dig_target(hit: Dictionary) -> Vector3:
	# Round to nearest grid point
	var nearest = Vector3(round(hit.position.x), round(hit.position.y), round(hit.position.z))
	# The solid voxel is AT the hit point (no offset needed)
	return nearest

## Calculate place target using integer grid coordinates
func _get_place_target(hit: Dictionary) -> Vector3:
	# Simply round to the nearest grid point where camera is aimed
	# This targets the empty space you're looking at
	return Vector3(round(hit.position.x), round(hit.position.y), round(hit.position.z))

## Get strongest normal direction (returns unit vector on primary axis)
func _get_strongest_normal_direction(normal: Vector3) -> Vector3:
	var abs_normal = Vector3(abs(normal.x), abs(normal.y), abs(normal.z))
	var max_component = max(abs_normal.x, max(abs_normal.y, abs_normal.z))
	
	var dir = Vector3.ZERO
	if abs_normal.x == max_component:
		dir.x = sign(normal.x)
	elif abs_normal.y == max_component:
		dir.y = sign(normal.y)
	else:
		dir.z = sign(normal.z)
	
	return dir

func _get_mode_name() -> String:
	return "DIG" if dig_mode else "PLACE"

func _update_cursor_color() -> void:
	if selection_box and selection_box.material_override:
		selection_box.material_override.albedo_color = COLOR_DIG if dig_mode else COLOR_PLACE

# ============================================================================
# INPUT HANDLING
# ============================================================================

func _process(_delta: float) -> void:
	if not is_active or not player:
		if selection_box:
			selection_box.visible = false
		return
	
	_update_targeting()

func _input(event: InputEvent) -> void:
	if not is_active:
		return
	
	if event is InputEventKey and event.pressed and not event.echo:
		# P key toggles dig/place mode
		if event.keycode == KEY_P:
			dig_mode = not dig_mode
			_update_cursor_color()
			print("SHOVEL: Mode = %s" % _get_mode_name())
			# Emit mode change for HUD
			if has_node("/root/PlayerSignals") and PlayerSignals.has_signal("terraformer_mode_changed"):
				PlayerSignals.terraformer_mode_changed.emit(_get_mode_name())
			get_viewport().set_input_as_handled()
			return
		
		# CTRL + 1-7 for material selection
		if event.ctrl_pressed:
			for i in range(MATERIALS.size()):
				if event.keycode == MATERIALS[i].key:
					_set_material(i)
					get_viewport().set_input_as_handled()
					return

func _on_item_changed(_slot: int, item: Dictionary) -> void:
	var item_id = item.get("id", "")
	var was_active = is_active
	is_active = (item_id == "shovel")
	
	if is_active:
		print("SHOVEL: Equipped - P to toggle mode, CTRL+1-7 for material. Mode=%s Material=%s" % [_get_mode_name(), MATERIALS[material_index].name])
		# Emit current state for HUD
		if has_node("/root/PlayerSignals"):
			if PlayerSignals.has_signal("terraformer_material_changed"):
				PlayerSignals.terraformer_material_changed.emit(MATERIALS[material_index].name)
			if PlayerSignals.has_signal("terraformer_mode_changed"):
				PlayerSignals.terraformer_mode_changed.emit(_get_mode_name())
		_update_cursor_color()
	elif was_active:
		# Was equipped, now unequipped - clear HUD
		if has_node("/root/PlayerSignals"):
			if PlayerSignals.has_signal("terraformer_material_changed"):
				PlayerSignals.terraformer_material_changed.emit("")
			if PlayerSignals.has_signal("terraformer_mode_changed"):
				PlayerSignals.terraformer_mode_changed.emit("")
		if selection_box:
			selection_box.visible = false

func _set_material(index: int) -> void:
	if index < 0 or index >= MATERIALS.size():
		return
	
	material_index = index
	var mat = MATERIALS[material_index]
	print("SHOVEL: Material = %s (id=%d)" % [mat.name, mat.id])
	
	# Emit signal for HUD update
	if has_node("/root/PlayerSignals") and PlayerSignals.has_signal("terraformer_material_changed"):
		PlayerSignals.terraformer_material_changed.emit(mat.name)

# ============================================================================
# TARGETING - Cursor shows voxel-centered position
# ============================================================================

func _update_targeting() -> void:
	if not player or not selection_box:
		return
	
	var hit = _raycast(RAYCAST_DISTANCE)
	if hit.is_empty():
		selection_box.visible = false
		has_target = false
		return
	
	has_target = true
	
	# Calculate BOTH targets using unified voxel-centered logic
	current_dig_target = _get_dig_target(hit)
	current_place_target = _get_place_target(hit)
	
	# Show cursor at current mode's target
	var display_target = current_dig_target if dig_mode else current_place_target
	selection_box.global_position = display_target
	selection_box.visible = true

# ============================================================================
# ACTIONS - Use pre-calculated voxel-centered targets
# ============================================================================

## Call this from combat_system for left-click (primary action)
func do_primary_action() -> void:
	if not is_active or not terrain_manager or not has_target:
		return
	
	# Emit animation signal for visual shovel
	if has_node("/root/PlayerSignals"):
		PlayerSignals.axe_fired.emit()
	
	if dig_mode:
		_do_dig(current_dig_target)
	else:
		_do_place(current_place_target)

## Call this from combat_system for right-click (secondary = opposite action)
func do_secondary_action() -> void:
	if not is_active or not terrain_manager or not has_target:
		return
	
	# Emit animation signal
	if has_node("/root/PlayerSignals"):
		PlayerSignals.axe_fired.emit()
	
	# Opposite of current mode
	if dig_mode:
		_do_place(current_place_target)
	else:
		_do_dig(current_dig_target)

## Perform dig at voxel-centered position
func _do_dig(target: Vector3) -> void:
	# DIG: Positive density = Air (+10.0 for instant removal)
	terrain_manager.modify_terrain(target, BRUSH_SIZE, 10.0, BRUSH_SHAPE, 0, -1)
	print("SHOVEL: DIG at %s" % target)

## Perform place at voxel-centered position
func _do_place(target: Vector3) -> void:
	# PLACE: Negative density = Solid (-10.0 for instant fill)
	var mat_id = MATERIALS[material_index].id + 100
	terrain_manager.modify_terrain(target, BRUSH_SIZE, -10.0, BRUSH_SHAPE, 0, mat_id)
	print("SHOVEL: PLACE at %s (material=%s)" % [target, MATERIALS[material_index].name])

# ============================================================================
# RAYCAST
# ============================================================================

func _raycast(distance: float) -> Dictionary:
	if not player:
		return {}
	
	var camera = player.get_node_or_null("Head/Camera3D")
	if not camera:
		camera = player.get_node_or_null("Camera3D")  # Fallback
	if not camera:
		return {}
	
	var space_state = player.get_world_3d().direct_space_state
	if not space_state:
		return {}
	
	var from = camera.global_position
	var to = from + (-camera.global_transform.basis.z) * distance
	
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player.get_rid()]
	query.collision_mask = 1 | 512  # Terrain layers
	
	return space_state.intersect_ray(query)

# ============================================================================
# PUBLIC API
# ============================================================================

## Get current material name (for HUD)
func get_current_material_name() -> String:
	return MATERIALS[material_index].name

## Get current material ID
func get_current_material_id() -> int:
	return MATERIALS[material_index].id

## Get current mode name (for HUD)
func get_current_mode() -> String:
	return _get_mode_name()

## Check if in dig mode
func is_dig_mode() -> bool:
	return dig_mode
