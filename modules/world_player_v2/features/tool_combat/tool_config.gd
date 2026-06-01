extends Node
## ToolConfig - Consolidated configuration for combat tools and debug visuals
## Replaces 5 separate autoloads: PickaxeDigConfig, PickaxeDurabilityConfig,
## HitMarkerConfig, PistolHitMarkerConfig, PickaxeTargetVisualizer

# ============================================================================
# PICKAXE DIG CONFIG
# ============================================================================

## When enabled, pickaxes use blocky grid-snapped terrain removal (like editor mode)
## with block durability requiring multiple hits.
## When disabled, pickaxes use sphere-based instant terrain removal.
var pickaxe_dig_enabled: bool = true

## Attack cooldown in seconds (time between swings)
## Range: 0.1 - 1.0, Default: 0.3
var pickaxe_attack_cooldown: float = 0.3

## Mining radius for terrain removal
## Range: 0.5 - 3.0, Default: 1.0
var pickaxe_mining_radius: float = 1.0

# ============================================================================
# PICKAXE DURABILITY CONFIG
# ============================================================================

## When enabled (default), pickaxes require multiple hits to break terrain blocks
## When disabled, pickaxes break terrain instantly (like terraformer)
## This setting works for BOTH block mode (box) and sphere mode
var pickaxe_durability_enabled: bool = false

# ============================================================================
# HIT MARKER CONFIG
# ============================================================================

## When enabled, shows red glowing spheres at hit positions for debugging
var hit_marker_enabled: bool = false

## When enabled, shows pistol hit markers
var pistol_hit_marker_enabled: bool = true

# ============================================================================
# TARGET VISUALIZER
# ============================================================================

var _target_visualizer_enabled: bool = false
var target_visualizer_enabled: bool:
	get:
		return _target_visualizer_enabled
	set(value):
		_target_visualizer_enabled = value
		_sync_target_visualizer_processing()
var _vegetation_interaction_visualizer_enabled: bool = false
var vegetation_interaction_visualizer_enabled: bool:
	get:
		return _vegetation_interaction_visualizer_enabled
	set(value):
		_vegetation_interaction_visualizer_enabled = value
		_sync_target_visualizer_processing()
var _target_box: MeshInstance3D = null
var _hit_marker: MeshInstance3D = null
var _vegetation_ray: MeshInstance3D = null
var _vegetation_target_marker: MeshInstance3D = null
var _vegetation_target_volume: MeshInstance3D = null
var _vegetation_ray_material: StandardMaterial3D = null
var _vegetation_marker_materials: Dictionary = {}
var _vegetation_volume_materials: Dictionary = {}
var _visualizer_nodes_created: bool = false

const VEGETATION_VISUALIZER_REACH_DISTANCE: float = 5.0

func _ready() -> void:
	_sync_target_visualizer_processing()

func _ensure_visualizer_nodes() -> void:
	if _visualizer_nodes_created or not is_inside_tree():
		return
	_create_visualizer()
	_visualizer_nodes_created = true

func _create_visualizer() -> void:
	# Create target box (shows grid-snapped block)
	_target_box = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.0, 1.0, 1.0)
	_target_box.mesh = box_mesh
	
	var box_mat = StandardMaterial3D.new()
	box_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box_mat.albedo_color = Color(1.0, 0.0, 0.0, 0.5)
	box_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	box_mat.disable_receive_shadows = true
	_target_box.material_override = box_mat
	_target_box.visible = false
	_target_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	get_tree().root.call_deferred("add_child", _target_box)
	
	# Create hit marker (shows exact raycast hit point)
	_hit_marker = MeshInstance3D.new()
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 0.1
	sphere_mesh.height = 0.2
	_hit_marker.mesh = sphere_mesh
	
	var marker_mat = StandardMaterial3D.new()
	marker_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker_mat.albedo_color = Color(0.0, 1.0, 0.0)
	marker_mat.emission_enabled = true
	marker_mat.emission = Color(0.0, 1.0, 0.0)
	marker_mat.emission_energy_multiplier = 2.0
	_hit_marker.material_override = marker_mat
	_hit_marker.visible = false
	_hit_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	get_tree().root.call_deferred("add_child", _hit_marker)

	_vegetation_ray = MeshInstance3D.new()
	_vegetation_ray.name = "VegetationInteractionRayDebug"
	_vegetation_ray.mesh = ImmediateMesh.new()
	_vegetation_ray.visible = false
	_vegetation_ray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vegetation_ray_material = _make_debug_material(Color(0.1, 0.85, 1.0, 0.65))
	get_tree().root.call_deferred("add_child", _vegetation_ray)

	_vegetation_target_volume = MeshInstance3D.new()
	_vegetation_target_volume.name = "VegetationInteractionVolumeDebug"
	var vegetation_volume_mesh := CylinderMesh.new()
	vegetation_volume_mesh.top_radius = 1.0
	vegetation_volume_mesh.bottom_radius = 1.0
	vegetation_volume_mesh.height = 1.0
	_vegetation_target_volume.mesh = vegetation_volume_mesh
	_vegetation_target_volume.visible = false
	_vegetation_target_volume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().root.call_deferred("add_child", _vegetation_target_volume)

	_vegetation_target_marker = MeshInstance3D.new()
	_vegetation_target_marker.name = "VegetationInteractionTargetDebug"
	var vegetation_sphere := SphereMesh.new()
	vegetation_sphere.radius = 0.18
	vegetation_sphere.height = 0.36
	_vegetation_target_marker.mesh = vegetation_sphere
	_vegetation_target_marker.visible = false
	_vegetation_target_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().root.call_deferred("add_child", _vegetation_target_marker)

func _process(_delta: float) -> void:
	_ensure_visualizer_nodes()
	var player = get_tree().get_first_node_in_group("player")
	if not player or not player.has_method("raycast"):
		_hide_target_visualizer()
		_hide_vegetation_interaction_visualizer()
		return
	
	# Check if holding a tool (pickaxe, axe, etc.)
	var hotbar = player.get_node_or_null("Systems/Hotbar")
	if not hotbar or not hotbar.has_method("get_selected_item"):
		_hide_target_visualizer()
		_hide_vegetation_interaction_visualizer()
		return
	
	var item = hotbar.get_selected_item()
	var category = item.get("category", 0)
	var is_tool := int(category) == 1
	var is_empty_hand := int(category) == 0
	if _target_visualizer_enabled and is_tool:
		_update_target_visualizer(player)
	else:
		_hide_target_visualizer()
	if _vegetation_interaction_visualizer_enabled and (is_tool or is_empty_hand):
		_update_vegetation_interaction_visualizer(player)
	else:
		_hide_vegetation_interaction_visualizer()

func _exit_tree() -> void:
	if _target_box:
		_target_box.queue_free()
		_target_box = null
	if _hit_marker:
		_set_hit_marker_visible(false)
		_hit_marker.queue_free()
		_hit_marker = null
	if _vegetation_ray:
		_vegetation_ray.queue_free()
		_vegetation_ray = null
	if _vegetation_target_volume:
		_vegetation_target_volume.queue_free()
		_vegetation_target_volume = null
	if _vegetation_target_marker:
		_vegetation_target_marker.queue_free()
		_vegetation_target_marker = null
	_visualizer_nodes_created = false


func _set_hit_marker_visible(enabled: bool) -> void:
	if not _hit_marker:
		return

	if _hit_marker.visible == enabled:
		return

	_hit_marker.visible = enabled


func _sync_target_visualizer_processing() -> void:
	var should_process := _target_visualizer_enabled or _vegetation_interaction_visualizer_enabled
	if should_process:
		_ensure_visualizer_nodes()
	set_process(should_process)
	if not _target_visualizer_enabled:
		_hide_target_visualizer()
	if not _vegetation_interaction_visualizer_enabled:
		_hide_vegetation_interaction_visualizer()


func _hide_target_visualizer() -> void:
	if _target_box:
		_target_box.visible = false
	if _hit_marker:
		_set_hit_marker_visible(false)


func _update_target_visualizer(player: Node) -> void:
	var hit = player.raycast(5.0, 0xFFFFFFFF, true, true)
	if hit.is_empty():
		_hide_target_visualizer()
		return

	var position = hit.get("position", Vector3.ZERO)
	var normal = hit.get("normal", Vector3.UP)

	if _hit_marker and is_instance_valid(_hit_marker) and _hit_marker.is_inside_tree():
		_hit_marker.global_position = position
		_set_hit_marker_visible(true)

	var snapped_pos = position - normal * 0.1
	var block_pos = Vector3i(floor(snapped_pos.x), floor(snapped_pos.y), floor(snapped_pos.z))

	if _target_box and is_instance_valid(_target_box) and _target_box.is_inside_tree():
		_target_box.global_position = Vector3(block_pos.x + 0.5, block_pos.y + 0.5, block_pos.z + 0.5)
		_target_box.scale = Vector3(1.05, 1.05, 1.05)
		_target_box.visible = true


func _update_vegetation_interaction_visualizer(player: Node) -> void:
	if not player.has_method("get_camera_position") or not player.has_method("get_look_direction"):
		_hide_vegetation_interaction_visualizer()
		return
	var origin: Vector3 = player.get_camera_position()
	var direction: Vector3 = player.get_look_direction()
	if direction.length_squared() <= 0.000001:
		_hide_vegetation_interaction_visualizer()
		return
	direction = direction.normalized()

	var max_distance := VEGETATION_VISUALIZER_REACH_DISTANCE
	var limited_distance := max_distance
	var physics_hit = player.raycast(max_distance, 0xFFFFFFFF, true, true)
	if not physics_hit.is_empty() and physics_hit.has("position"):
		var hit_position: Vector3 = physics_hit.get("position", origin + direction * max_distance)
		var hit_distance := origin.distance_to(hit_position)
		if hit_distance > 0.0:
			limited_distance = minf(max_distance, hit_distance)

	var end_point := origin + direction * limited_distance
	_update_vegetation_ray_mesh(origin, end_point)

	var vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	if not vegetation_manager or not vegetation_manager.has_method("find_nearest_vegetation_along_ray"):
		_set_vegetation_target_marker_visible(false)
		_set_vegetation_target_volume_visible(false)
		return
	var data_hit: Dictionary = vegetation_manager.find_nearest_vegetation_along_ray(origin, direction, limited_distance, true, true, true)
	if data_hit.is_empty():
		_set_vegetation_target_marker_visible(false)
		_set_vegetation_target_volume_visible(false)
		return
	var kind := str(data_hit.get("kind", ""))
	var position: Vector3 = data_hit.get("position", end_point)
	var marker_position: Vector3 = data_hit.get("debug_position", position)
	_update_vegetation_target_volume(kind, data_hit, position)
	_update_vegetation_target_marker(kind, marker_position)


func _update_vegetation_ray_mesh(origin: Vector3, end_point: Vector3) -> void:
	if not _vegetation_ray or not is_instance_valid(_vegetation_ray) or not _vegetation_ray.is_inside_tree():
		return
	var mesh := _vegetation_ray.mesh as ImmediateMesh
	if not mesh:
		return
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, _vegetation_ray_material)
	mesh.surface_add_vertex(origin)
	mesh.surface_add_vertex(end_point)
	mesh.surface_end()
	_vegetation_ray.visible = true


func _update_vegetation_target_marker(kind: String, position: Vector3) -> void:
	if not _vegetation_target_marker or not is_instance_valid(_vegetation_target_marker) or not _vegetation_target_marker.is_inside_tree():
		return
	_vegetation_target_marker.global_position = position
	_vegetation_target_marker.scale = _vegetation_marker_scale(kind)
	_vegetation_target_marker.material_override = _vegetation_marker_material(kind)
	_set_vegetation_target_marker_visible(true)


func _update_vegetation_target_volume(kind: String, hit: Dictionary, fallback_position: Vector3) -> void:
	if not _vegetation_target_volume or not is_instance_valid(_vegetation_target_volume) or not _vegetation_target_volume.is_inside_tree():
		return
	var radius := maxf(0.05, float(hit.get("interaction_radius", _vegetation_default_interaction_radius(kind))))
	var height := maxf(0.05, float(hit.get("interaction_height", _vegetation_default_interaction_height(kind))))
	var base_position: Vector3 = hit.get("base_position", fallback_position - Vector3.UP * (height * 0.5))
	_vegetation_target_volume.global_position = base_position + Vector3.UP * (height * 0.5)
	_vegetation_target_volume.scale = Vector3(radius, height, radius)
	_vegetation_target_volume.material_override = _vegetation_volume_material(kind)
	_set_vegetation_target_volume_visible(true)


func _hide_vegetation_interaction_visualizer() -> void:
	if _vegetation_ray:
		_vegetation_ray.visible = false
		var mesh := _vegetation_ray.mesh as ImmediateMesh
		if mesh:
			mesh.clear_surfaces()
	_set_vegetation_target_volume_visible(false)
	_set_vegetation_target_marker_visible(false)


func _set_vegetation_target_volume_visible(enabled: bool) -> void:
	if not _vegetation_target_volume:
		return
	if _vegetation_target_volume.visible == enabled:
		return
	_vegetation_target_volume.visible = enabled


func _set_vegetation_target_marker_visible(enabled: bool) -> void:
	if not _vegetation_target_marker:
		return
	if _vegetation_target_marker.visible == enabled:
		return
	_vegetation_target_marker.visible = enabled


func _vegetation_marker_scale(kind: String) -> Vector3:
	match kind:
		"tree":
			return Vector3(1.6, 1.6, 1.6)
		"rock":
			return Vector3(1.1, 1.1, 1.1)
		"grass":
			return Vector3(0.75, 0.75, 0.75)
	return Vector3.ONE


func _vegetation_marker_material(kind: String) -> StandardMaterial3D:
	if _vegetation_marker_materials.has(kind):
		return _vegetation_marker_materials[kind]
	var color := Color(0.1, 0.85, 1.0, 0.45)
	match kind:
		"tree":
			color = Color(1.0, 0.78, 0.1, 0.45)
		"grass":
			color = Color(0.2, 1.0, 0.2, 0.45)
		"rock":
			color = Color(0.72, 0.72, 0.78, 0.45)
	var mat := _make_debug_material(color)
	_vegetation_marker_materials[kind] = mat
	return mat


func _vegetation_volume_material(kind: String) -> StandardMaterial3D:
	if _vegetation_volume_materials.has(kind):
		return _vegetation_volume_materials[kind]
	var color := Color(0.1, 0.85, 1.0, 0.18)
	match kind:
		"tree":
			color = Color(1.0, 0.78, 0.1, 0.18)
		"grass":
			color = Color(0.2, 1.0, 0.2, 0.18)
		"rock":
			color = Color(0.72, 0.72, 0.78, 0.18)
	var mat := _make_debug_material(color)
	mat.emission_energy_multiplier = 0.65
	_vegetation_volume_materials[kind] = mat
	return mat


func _vegetation_default_interaction_radius(kind: String) -> float:
	match kind:
		"tree":
			return 0.5
		"rock":
			return 0.4
		"grass":
			return 0.3
	return 0.35


func _vegetation_default_interaction_height(kind: String) -> float:
	match kind:
		"tree":
			return 8.0
		"rock":
			return 0.4
		"grass":
			return 0.5
	return 1.0


func _make_debug_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	return mat
