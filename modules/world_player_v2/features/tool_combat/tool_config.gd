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

var target_visualizer_enabled: bool = false
var _target_box: MeshInstance3D = null
var _hit_marker: MeshInstance3D = null

func _ready() -> void:
	_create_visualizer()
	print("[TOOL_CONFIG] ToolConfig initialized (consolidated from 5 autoloads)")

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

func _process(_delta: float) -> void:
	if not target_visualizer_enabled:
		if _target_box:
			_target_box.visible = false
		if _hit_marker:
			_hit_marker.visible = false
		return
	
	var player = get_tree().get_first_node_in_group("player")
	if not player or not player.has_method("raycast"):
		if _target_box:
			_target_box.visible = false
		if _hit_marker:
			_hit_marker.visible = false
		return
	
	# Check if holding a tool (pickaxe, axe, etc.)
	var hotbar = player.get_node_or_null("Systems/Hotbar")
	if not hotbar or not hotbar.has_method("get_selected_item"):
		if _target_box:
			_target_box.visible = false
		if _hit_marker:
			_hit_marker.visible = false
		return
	
	var item = hotbar.get_selected_item()
	var category = item.get("category", 0)
	
	# Only show for tools (category 1: pickaxe, axe, shovel, etc.)
	if category != 1:
		if _target_box:
			_target_box.visible = false
		if _hit_marker:
			_hit_marker.visible = false
		return
	
	# Perform raycast
	var hit = player.raycast(5.0, 0xFFFFFFFF, true, true)
	if hit.is_empty():
		if _target_box:
			_target_box.visible = false
		if _hit_marker:
			_hit_marker.visible = false
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var normal = hit.get("normal", Vector3.UP)
	
	# Show hit marker at exact raycast point
	if _hit_marker and is_instance_valid(_hit_marker) and _hit_marker.is_inside_tree():
		_hit_marker.global_position = position
		_hit_marker.visible = true
	
	# Calculate grid-snapped block position (same logic as combat_system)
	var snapped_pos = position - normal * 0.1
	var block_pos = Vector3i(floor(snapped_pos.x), floor(snapped_pos.y), floor(snapped_pos.z))
	
	# Show target box at grid position
	if _target_box and is_instance_valid(_target_box) and _target_box.is_inside_tree():
		_target_box.global_position = Vector3(block_pos.x + 0.5, block_pos.y + 0.5, block_pos.z + 0.5)
		_target_box.scale = Vector3(1.05, 1.05, 1.05)
		_target_box.visible = true

func _exit_tree() -> void:
	if _target_box:
		_target_box.queue_free()
	if _hit_marker:
		_hit_marker.queue_free()
