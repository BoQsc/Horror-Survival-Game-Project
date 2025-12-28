extends Node
class_name TerrainInteractionFeature
## TerrainInteraction - Handles terrain targeting, mining, bucket actions, and resource placement
## Extracted from ModePlay for feature isolation

# Local signals reference
var signals: Node = null

# References (set by parent)
var player: Node = null
var terrain_manager: Node = null
var hotbar: Node = null

# Selection box for RESOURCE/BUCKET placement
var selection_box: MeshInstance3D = null
var current_target_pos: Vector3 = Vector3.ZERO
var has_target: bool = false

# Material display - lookup and tracking
const MATERIAL_NAMES = {
	-1: "Unknown",
	0: "Grass",
	1: "Stone",
	2: "Ore",
	3: "Sand",
	4: "Gravel",
	5: "Snow",
	6: "Road",
	9: "Granite",
	100: "[P] Grass",
	101: "[P] Stone",
	102: "[P] Sand",
	103: "[P] Snow"
}
var last_target_material: String = ""
var material_target_marker: MeshInstance3D = null

# Preload item definitions
const ItemDefs = preload("res://modules/world_player_v2/features/inventory/item_definitions.gd")

func _ready() -> void:
	# Try to find local signals node
	signals = get_node_or_null("../signals")
	if not signals:
		signals = get_node_or_null("signals")
	
	_create_selection_box()
	_create_material_target_marker()
	
	DebugSettings.log_player("TerrainInteractionFeature: Initialized")

func _process(_delta: float) -> void:
	_update_terrain_targeting()
	_update_target_material()

## Initialize references (called by parent after scene ready)
func initialize(p_player: Node, p_terrain: Node, p_hotbar: Node) -> void:
	player = p_player
	terrain_manager = p_terrain
	hotbar = p_hotbar

# ============================================================================
# MODE INTERFACE (called by ItemUseRouter)
# ============================================================================

## Handle secondary action (right click) - bucket/resource placement
func handle_secondary(item: Dictionary) -> void:
	var category = item.get("category", 0)
	
	match category:
		2:  # BUCKET
			do_bucket_place()
		3:  # RESOURCE
			do_resource_place(item)
		_:
			pass

func _create_selection_box() -> void:
	selection_box = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.01, 1.01, 1.01)
	selection_box.mesh = box_mesh
	
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.4, 0.8, 0.3, 0.5)  # Green/brown for terrain
	selection_box.material_override = material
	selection_box.visible = false
	
	get_tree().root.add_child.call_deferred(selection_box)

func _create_material_target_marker() -> void:
	material_target_marker = MeshInstance3D.new()
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 0.1
	sphere_mesh.height = 0.2
	material_target_marker.mesh = sphere_mesh
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color.YELLOW
	mat.emission_enabled = true
	mat.emission = Color.YELLOW
	mat.emission_energy_multiplier = 1.0
	material_target_marker.material_override = mat
	material_target_marker.visible = false
	
	get_tree().root.add_child.call_deferred(material_target_marker)

func _update_terrain_targeting() -> void:
	if not player or not hotbar or not selection_box:
		return
	
	var item = hotbar.get_selected_item()
	var category = item.get("category", 0)
	
	# Categories: 2=BUCKET, 3=RESOURCE
	if category != 2 and category != 3:
		selection_box.visible = false
		has_target = false
		return
	
	# Raycast to find target
	var hit = _raycast(5.0)
	if hit.is_empty():
		selection_box.visible = false
		has_target = false
		return
	
	has_target = true
	
	# Calculate adjacent voxel position (where block will be placed)
	var pos = hit.position + hit.normal * 0.1
	current_target_pos = Vector3(floor(pos.x), floor(pos.y), floor(pos.z))
	
	# Update selection box position
	selection_box.global_position = current_target_pos + Vector3(0.5, 0.5, 0.5)
	selection_box.visible = true

func _update_target_material() -> void:
	if not player or not terrain_manager:
		if material_target_marker:
			material_target_marker.visible = false
		return
	
	var hit = _raycast(5.0)
	if hit.is_empty():
		if last_target_material != "":
			last_target_material = ""
			_emit_target_material_changed("")
		if material_target_marker:
			material_target_marker.visible = false
		return
	
	var position = hit.get("position", Vector3.ZERO)
	
	# Get material at hit position
	var mat_id = -1
	if terrain_manager.has_method("get_material_at"):
		mat_id = terrain_manager.get_material_at(position)
	
	var mat_name = MATERIAL_NAMES.get(mat_id, "Unknown (%d)" % mat_id)
	
	if mat_name != last_target_material:
		last_target_material = mat_name
		_emit_target_material_changed(mat_name)
	
	# Update debug marker position
	if material_target_marker:
		material_target_marker.global_position = position
		material_target_marker.visible = true

# ============================================================================
# BUCKET ACTIONS
# ============================================================================

## Collect water with bucket
func do_bucket_collect() -> void:
	if not player or not terrain_manager:
		return
	
	if not has_target:
		return
	
	var center = current_target_pos + Vector3(0.5, 0.5, 0.5)
	terrain_manager.modify_terrain(center, 0.6, 0.5, 1, 1)  # Same as placement but positive value
	DebugSettings.log_player("TerrainInteraction: Collected water at %s" % current_target_pos)

## Place water from bucket
func do_bucket_place() -> void:
	if not player or not terrain_manager:
		return
	
	if has_target:
		var center = current_target_pos + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(center, 0.6, -0.5, 1, 1)  # Box shape, fill, water layer
		DebugSettings.log_player("TerrainInteraction: Placed water at %s" % current_target_pos)
	else:
		var hit = _raycast(5.0)
		if hit.is_empty():
			return
		var pos = hit.position + hit.normal * 0.5
		terrain_manager.modify_terrain(pos, 0.6, -0.5, 1, 1)

# ============================================================================
# RESOURCE PLACEMENT
# ============================================================================

## Place resource (terrain material) - paints voxel with resource's material ID
func do_resource_place(item: Dictionary) -> void:
	if not player or not terrain_manager:
		return
	
	var item_id = item.get("id", "")
	
	# Check if this is a vegetation resource
	if item_id == "veg_fiber":
		_do_vegetation_place("grass")
		return
	elif item_id == "veg_rock":
		_do_vegetation_place("rock")
		return
	
	# Get material ID from resource item
	var mat_id = item.get("mat_id", -1)
	if mat_id < 0:
		mat_id = item.get("material_id", 0)
	
	# Add 100 offset for player-placed materials
	if mat_id < 100:
		mat_id += 100
	
	if has_target:
		var center = current_target_pos + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(center, 0.6, -0.5, 1, 0, mat_id)
		_consume_selected_item()
		DebugSettings.log_player("TerrainInteraction: Placed %s (mat:%d) at %s" % [item.get("name", "resource"), mat_id, current_target_pos])
	else:
		var hit = _raycast(5.0)
		if hit.is_empty():
			return
		var p = hit.position + hit.normal * 0.1
		var target_pos = Vector3(floor(p.x), floor(p.y), floor(p.z)) + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(target_pos, 0.6, -0.5, 1, 0, mat_id)
		_consume_selected_item()

func _do_vegetation_place(veg_type: String) -> void:
	DebugSettings.log_player("TerrainInteraction: Vegetation placement not implemented for %s" % veg_type)
	# TODO: Spawn vegetation instance

func _consume_selected_item() -> void:
	if hotbar and hotbar.has_method("decrement_slot"):
		var selected_slot = hotbar.get_selected_index()
		hotbar.decrement_slot(selected_slot, 1)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

func _raycast(distance: float) -> Dictionary:
	if player and player.has_method("raycast"):
		return player.raycast(distance)
	return {}

func _emit_target_material_changed(material_name: String) -> void:
	if signals and signals.has_signal("target_material_changed"):
		signals.target_material_changed.emit(material_name)
	if has_node("/root/PlayerSignals"):
		PlayerSignals.target_material_changed.emit(material_name)

## Get selection state for external queries
func get_target_position() -> Vector3:
	return current_target_pos

func is_targeting() -> bool:
	return has_target

func get_current_material_name() -> String:
	return last_target_material
