extends Node
## PickaxeTargetVisualizer - Shows real-time targeting boxes for any equipped tool
## Displays continuously while holding pickaxe/axe to show exactly what you'll hit

var target_box: MeshInstance3D = null
var hit_marker: MeshInstance3D = null
var enabled: bool = false

func _ready() -> void:
	_create_visuals()
	print("PickaxeTargetVisualizer: Initialized")

func _create_visuals() -> void:
	# Create target box (shows grid-snapped block)
	target_box = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.0, 1.0, 1.0)
	target_box.mesh = box_mesh
	
	var box_mat = StandardMaterial3D.new()
	box_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box_mat.albedo_color = Color(1.0, 0.0, 0.0, 0.5)  # Bright red, 50% transparent
	box_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	box_mat.disable_receive_shadows = true
	target_box.material_override = box_mat
	target_box.visible = false
	target_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	get_tree().root.call_deferred("add_child", target_box)
	
	# Create hit marker (shows exact raycast hit point)
	hit_marker = MeshInstance3D.new()
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 0.1
	sphere_mesh.height = 0.2
	hit_marker.mesh = sphere_mesh
	
	var marker_mat = StandardMaterial3D.new()
	marker_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker_mat.albedo_color = Color(0.0, 1.0, 0.0)  # Bright green
	marker_mat.emission_enabled = true
	marker_mat.emission = Color(0.0, 1.0, 0.0)
	marker_mat.emission_energy_multiplier = 2.0
	hit_marker.material_override = marker_mat
	hit_marker.visible = false
	hit_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	get_tree().root.call_deferred("add_child", hit_marker)

func _process(_delta: float) -> void:
	if not enabled:
		if target_box:
			target_box.visible = false
		if hit_marker:
			hit_marker.visible = false
		return
	
	var player = get_tree().get_first_node_in_group("player")
	if not player or not player.has_method("raycast"):
		if target_box:
			target_box.visible = false
		if hit_marker:
			hit_marker.visible = false
		return
	
	# Check if holding a tool (pickaxe, axe, etc.)
	var hotbar = player.get_node_or_null("Systems/Hotbar")
	if not hotbar or not hotbar.has_method("get_selected_item"):
		if target_box:
			target_box.visible = false
		if hit_marker:
			hit_marker.visible = false
		return
	
	var item = hotbar.get_selected_item()
	var item_id = item.get("id", "")
	var category = item.get("category", 0)
	
	# Only show for tools (category 1: pickaxe, axe, shovel, etc.)
	if category != 1:
		if target_box:
			target_box.visible = false
		if hit_marker:
			hit_marker.visible = false
		return
	
	# Perform raycast
	var hit = player.raycast(5.0, 0xFFFFFFFF, true, true)
	if hit.is_empty():
		if target_box:
			target_box.visible = false
		if hit_marker:
			hit_marker.visible = false
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var normal = hit.get("normal", Vector3.UP)
	
	# Show hit marker at exact raycast point
	if hit_marker and is_instance_valid(hit_marker) and hit_marker.is_inside_tree():
		hit_marker.global_position = position
		hit_marker.visible = true
	
	# Calculate grid-snapped block position (same logic as combat_system)
	var snapped_pos = position - normal * 0.1
	var block_pos = Vector3i(floor(snapped_pos.x), floor(snapped_pos.y), floor(snapped_pos.z))
	
	# Show target box at grid position
	if target_box and is_instance_valid(target_box) and target_box.is_inside_tree():
		target_box.global_position = Vector3(block_pos.x + 0.5, block_pos.y + 0.5, block_pos.z + 0.5)
		target_box.scale = Vector3(1.05, 1.05, 1.05)
		target_box.visible = true

func _exit_tree() -> void:
	if target_box:
		target_box.queue_free()
	if hit_marker:
		hit_marker.queue_free()
