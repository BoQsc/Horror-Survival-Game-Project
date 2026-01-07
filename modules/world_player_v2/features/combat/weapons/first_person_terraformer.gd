extends Node
class_name FirstPersonShovelV2
## FirstPersonShovel - Handles grid-snapped terrain dig/fill with material selection
## CTRL + 1-7 to select material, Left-click to dig, Right-click to fill

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

# References
var player: CharacterBody3D = null
var terrain_manager: Node = null

# Selection box visualization
var selection_box: MeshInstance3D = null
var current_target_pos: Vector3 = Vector3.ZERO
var has_target: bool = false

# Constants
const RAYCAST_DISTANCE: float = 10.0
const BRUSH_SIZE: float = 0.5  # Exactly covers one grid cell (center ±0.5)
const BRUSH_SHAPE: int = 1  # 1 = Box shape in modify_density.glsl

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
	
	print("SHOVEL: Initialized, default material = %s" % MATERIALS[material_index].name)

func _find_terrain_manager() -> void:
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if not terrain_manager:
		push_warning("FirstPersonShovel: terrain_manager not found")

func _create_selection_box() -> void:
	selection_box = MeshInstance3D.new()
	# Use generated Diamond (Octahedron) mesh instead of BoxMesh
	selection_box.mesh = _create_diamond_mesh()
	
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.2, 0.8, 0.4, 0.4)  # Green for terraformer
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	selection_box.material_override = material
	selection_box.visible = false
	
	get_tree().root.add_child.call_deferred(selection_box)

func _create_diamond_mesh() -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Octahedron vertices (Diamond shape)
	# Size 0.6 from center = 1.2 total width (fits grid 1.0 nicely with logic)
	# Adjusted to match BoxMesh sizing roughly (0.5 + small padding)
	# BoxMesh was 1.02. Diamond endpoints being at 0.51 will touch the boundary.
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

func _process(_delta: float) -> void:
	if not is_active or not player:
		if selection_box:
			selection_box.visible = false
		return
	
	_update_targeting()

func _input(event: InputEvent) -> void:
	if not is_active:
		return
	
	# CTRL + 1-7 for material selection
	if event is InputEventKey and event.pressed and not event.echo:
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
		print("SHOVEL: Equipped - CTRL+1-7 to select material, current = %s" % MATERIALS[material_index].name)
		# Emit current material for HUD
		if has_node("/root/PlayerSignals") and PlayerSignals.has_signal("terraformer_material_changed"):
			PlayerSignals.terraformer_material_changed.emit(MATERIALS[material_index].name)
	elif was_active:
		# Was equipped, now unequipped - clear HUD
		if has_node("/root/PlayerSignals") and PlayerSignals.has_signal("terraformer_material_changed"):
			PlayerSignals.terraformer_material_changed.emit("")
		if selection_box:
			selection_box.visible = false

func _set_material(index: int) -> void:
	if index < 0 or index >= MATERIALS.size():
		return
	
	material_index = index
	var mat = MATERIALS[material_index]
	print("SHOVEL: Material selected = %s (id=%d)" % [mat.name, mat.id])
	
	# Emit signal for HUD update
	if has_node("/root/PlayerSignals") and PlayerSignals.has_signal("terraformer_material_changed"):
		PlayerSignals.terraformer_material_changed.emit(mat.name)

func _update_targeting() -> void:
	if not player or not selection_box:
		return
	
	var hit = _raycast(RAYCAST_DISTANCE)
	if hit.is_empty():
		selection_box.visible = false
		has_target = false
		return
	
	has_target = true
	
	# Step away from surface by 0.51 (just over half voxel) to get adjacent voxel
	var placement_pos = hit.position + hit.normal * 0.51
	
	# Floor to discrete grid position
	current_target_pos = Vector3(floor(placement_pos.x), floor(placement_pos.y), floor(placement_pos.z))
	
	# Show cursor at voxel center (voxels are centered at integer coordinates)
	selection_box.global_position = current_target_pos
	selection_box.visible = true

## Call this from combat_system for left-click
func do_primary_action() -> void:
	if not is_active or not terrain_manager:
		return
	
	# Emit animation signal for visual shovel
	if has_node("/root/PlayerSignals"):
		PlayerSignals.axe_fired.emit()
	
	var hit = _raycast(RAYCAST_DISTANCE)
	if hit.is_empty():
		return
	
	# Dig: step INTO the surface to get the voxel to remove
	var pos = hit.position - hit.normal * 0.1
	var target = Vector3(floor(pos.x), floor(pos.y), floor(pos.z))
	
	# DIG: Positive density = Air
	# Use +10.0 for "Hard Dig" (Instant removal)
	terrain_manager.modify_terrain(target, BRUSH_SIZE, 10.0, BRUSH_SHAPE, 0, -1)
	print("SHOVEL: Dig at %s" % target)

## Call this from combat_system for right-click
func do_secondary_action() -> void:
	if not is_active or not terrain_manager:
		return
	
	# Emit animation signal
	if has_node("/root/PlayerSignals"):
		PlayerSignals.axe_fired.emit()
	
	# Use the EXACT position the cursor shows (NO separate raycast)
	if not has_target:
		return
	
	var target = current_target_pos  # Use what cursor calculated
	
	# Place terrain
	var mat_id = MATERIALS[material_index].id + 100
	terrain_manager.modify_terrain(target, BRUSH_SIZE, -10.0, BRUSH_SHAPE, 0, mat_id)
	print("SHOVEL: Placed at %s (cursor position)" % target)

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

## Get current material name (for HUD)
func get_current_material_name() -> String:
	return MATERIALS[material_index].name

## Get current material ID
func get_current_material_id() -> int:
	return MATERIALS[material_index].id
