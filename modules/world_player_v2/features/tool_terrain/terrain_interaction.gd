extends Node
class_name TerrainInteractionFeature
## TerrainInteraction - Handles terrain targeting, mining, bucket actions, and resource placement
## Extracted from ModePlay for feature isolation

# Local signals reference
var signals: Node = null

# References (set by parent)
var player: Node = null
var terrain_manager: Node = null
var vegetation_manager: Node = null
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
const ItemDefs = preload("res://modules/world_player_v2/features/data_inventory/item_definitions.gd")

func _ready() -> void:
	# Try to find local signals node
	signals = get_node_or_null("../signals")
	if not signals:
		signals = get_node_or_null("signals")
	
	# Auto-discover player and managers
	player = get_parent().get_parent()  # Modes/TerrainInteraction -> WorldPlayerV2
	call_deferred("_find_managers")
	
	_create_selection_box()
	_create_material_target_marker()
	
	DebugManager.log_player("TerrainInteractionFeature: Initialized")

func _find_managers() -> void:
	if not terrain_manager:
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if not vegetation_manager:
		vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	if not hotbar and player:
		hotbar = player.get_node_or_null("Systems/Hotbar")

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
	
	var hit = _raycast(10.0)  # V1 uses 10.0 range for material detection
	if hit.is_empty():
		if last_target_material != "":
			last_target_material = ""
			_emit_target_material_changed("")
		if material_target_marker:
			material_target_marker.visible = false
		return
	
	var target = hit.get("collider")
	var hit_pos = hit.get("position", Vector3.ZERO)
	var hit_normal = hit.get("normal", Vector3.UP)
	var mat_name = ""
	
	# Update debug marker position (respects DebugManager preset)
	if material_target_marker:
		material_target_marker.global_position = hit_pos
		var show_marker = false  # Default OFF
		if has_node("/root/DebugManager"):
			show_marker = get_node("/root/DebugManager").should_show_terrain_marker()
		material_target_marker.visible = show_marker
	
	# Check if we hit terrain (StaticBody3D in 'terrain' group)
	if target and target.is_in_group("terrain"):
		# Step 1: Try to get material from mesh vertex color (most accurate)
		var mat_id = _get_material_from_mesh(target, hit_pos)
		
		# Step 2: Fallback to buffer sampling if mesh reading failed
		if mat_id < 0:
			# Sample INSIDE the terrain, not at the surface
			var sample_pos = hit_pos - hit_normal * 0.1
			mat_id = _get_material_at(sample_pos)
		
		mat_name = MATERIAL_NAMES.get(mat_id, "Unknown (%d)" % mat_id)
	elif target and target.is_in_group("building_chunks"):
		mat_name = "Building Block"
	elif target and target.is_in_group("trees"):
		mat_name = "Tree"
	elif target and target.is_in_group("placed_objects"):
		mat_name = "Object"
	
	if mat_name != last_target_material:
		last_target_material = mat_name
		_emit_target_material_changed(mat_name)

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
	DebugManager.log_player("TerrainInteraction: Collected water at %s" % current_target_pos)

## Place water from bucket
func do_bucket_place() -> void:
	if not player or not terrain_manager:
		return
	
	if has_target:
		var center = current_target_pos + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(center, 0.6, -0.5, 1, 1)  # Box shape, fill, water layer
		if has_node("/root/PlayerSignals"):
			PlayerSignals.bucket_placed.emit()
		DebugManager.log_player("TerrainInteraction: Placed water at %s" % current_target_pos)
	else:
		var hit = _raycast(5.0)
		if hit.is_empty():
			return
		var pos = hit.position + hit.normal * 0.5
		terrain_manager.modify_terrain(pos, 0.6, -0.5, 1, 1)
		if has_node("/root/PlayerSignals"):
			PlayerSignals.bucket_placed.emit()

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
		if has_node("/root/PlayerSignals"):
			PlayerSignals.resource_placed.emit()
		DebugManager.log_player("TerrainInteraction: Placed %s (mat:%d) at %s" % [item.get("name", "resource"), mat_id, current_target_pos])
	else:
		var hit = _raycast(5.0)
		if hit.is_empty():
			return
		var p = hit.position + hit.normal * 0.1
		var target_pos = Vector3(floor(p.x), floor(p.y), floor(p.z)) + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(target_pos, 0.6, -0.5, 1, 0, mat_id)
		_consume_selected_item()

## Place vegetation (grass or rock) at raycast hit position - V1 EXACT
func _do_vegetation_place(veg_type: String) -> void:
	if not player or not vegetation_manager:
		DebugManager.log_player("TerrainInteraction: Cannot place vegetation - missing player or vegetation_manager")
		return
	
	var hit = _raycast(5.0)
	if hit.is_empty():
		DebugManager.log_player("TerrainInteraction: Cannot place vegetation - no hit")
		return
	
	if veg_type == "grass":
		vegetation_manager.place_grass(hit.position)
		_consume_selected_item()
		DebugManager.log_player("TerrainInteraction: Placed grass at %s" % hit.position)
	elif veg_type == "rock":
		vegetation_manager.place_rock(hit.position)
		_consume_selected_item()
		DebugManager.log_player("TerrainInteraction: Placed rock at %s" % hit.position)

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

## Get material ID from mesh vertex color at hit point (100% accurate)
## Finds the exact triangle containing the hit point and interpolates vertex colors
## Returns -1 if unable to read from mesh
func _get_material_from_mesh(terrain_node: Node, hit_pos: Vector3) -> int:
	# Find the MeshInstance3D child of the terrain node
	var mesh_instance: MeshInstance3D = null
	for child in terrain_node.get_children():
		if child is MeshInstance3D:
			mesh_instance = child
			break
	
	if not mesh_instance or not mesh_instance.mesh:
		return -1
	
	var mesh = mesh_instance.mesh
	if not mesh is ArrayMesh:
		return -1
	
	# Get mesh data
	var arrays = mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return -1
	
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	var colors = arrays[Mesh.ARRAY_COLOR]
	
	if vertices.is_empty() or colors.is_empty():
		return -1
	
	# Convert hit position to local mesh space
	var local_pos = mesh_instance.global_transform.affine_inverse() * hit_pos
	
	# Find the triangle containing the hit point
	# Mesh is triangle list, so every 3 vertices form a triangle
	var best_mat_id = -1
	var best_dist = INF
	
	for i in range(0, vertices.size(), 3):
		if i + 2 >= vertices.size():
			break
		
		var v0 = vertices[i]
		var v1 = vertices[i + 1]
		var v2 = vertices[i + 2]
		
		# Check distance from point to triangle plane first (quick rejection)
		var tri_center = (v0 + v1 + v2) / 3.0
		var dist_to_center = local_pos.distance_squared_to(tri_center)
		
		# Only check triangles within reasonable distance
		if dist_to_center > 4.0: # Skip triangles > 2 units away
			continue
		
		# Compute closest point on triangle to local_pos
		var closest_on_tri = _closest_point_on_triangle(local_pos, v0, v1, v2)
		var dist = local_pos.distance_squared_to(closest_on_tri)
		
		if dist < best_dist:
			best_dist = dist
			# Get barycentric coordinates for interpolation
			var bary = _barycentric(closest_on_tri, v0, v1, v2)
			var c0 = colors[i]
			var c1 = colors[i + 1]
			var c2 = colors[i + 2]
			# Interpolate color using barycentric weights
			var interp_color = c0 * bary.x + c1 * bary.y + c2 * bary.z
			best_mat_id = int(round(interp_color.r * 255.0))
	
	return best_mat_id

## Compute barycentric coordinates of point P in triangle (A, B, C)
func _barycentric(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 = b - a
	var v1 = c - a
	var v2 = p - a
	
	var d00 = v0.dot(v0)
	var d01 = v0.dot(v1)
	var d11 = v1.dot(v1)
	var d20 = v2.dot(v0)
	var d21 = v2.dot(v1)
	
	var denom = d00 * d11 - d01 * d01
	if abs(denom) < 0.00001:
		return Vector3(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0) # Degenerate - equal weights
	
	var v = (d11 * d20 - d01 * d21) / denom
	var w = (d00 * d21 - d01 * d20) / denom
	var u = 1.0 - v - w
	
	return Vector3(u, v, w)

## Find the closest point on a triangle to a given point
func _closest_point_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	# Check if P projects inside the triangle
	var ab = b - a
	var ac = c - a
	var ap = p - a
	
	var d1 = ab.dot(ap)
	var d2 = ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a # Closest to vertex A
	
	var bp = p - b
	var d3 = ab.dot(bp)
	var d4 = ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b # Closest to vertex B
	
	var vc = d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		var v = d1 / (d1 - d3)
		return a + ab * v # Closest to edge AB
	
	var cp = p - c
	var d5 = ab.dot(cp)
	var d6 = ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c # Closest to vertex C
	
	var vb = d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		var w = d2 / (d2 - d6)
		return a + ac * w # Closest to edge AC
	
	var va = d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		var w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w # Closest to edge BC
	
	# P projects inside the triangle
	var denom = 1.0 / (va + vb + vc)
	var v = vb * denom
	var w = vc * denom
	return a + ab * v + ac * w

## Get material ID at a given world position (fallback - uses chunk_manager's buffer lookup)
func _get_material_at(pos: Vector3) -> int:
	if terrain_manager and terrain_manager.has_method("get_material_at"):
		return terrain_manager.get_material_at(pos)
	return -1 # Unknown

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
