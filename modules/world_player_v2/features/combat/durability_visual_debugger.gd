extends Node3D
class_name DurabilityVisualDebugger
## DurabilityVisualDebugger - Shows transparent boxes around targeted blocks/objects
## Displays what the pickaxe/axe is hitting with visual feedback

var target_box: MeshInstance3D = null
var current_target_ref: Variant = null
var enabled: bool = true  # Can be toggled via debug menu

func _ready() -> void:
	_create_target_box()
	
	if has_node("/root/PlayerSignals"):
		PlayerSignals.durability_hit.connect(_on_durability_hit)
		PlayerSignals.durability_cleared.connect(_on_durability_cleared)

func _create_target_box() -> void:
	target_box = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.0, 1.0, 1.0)
	target_box.mesh = box_mesh
	
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.3, 0.3, 0.35)  # Red transparent
	material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Show from all angles
	target_box.material_override = material
	target_box.visible = false
	target_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	add_child(target_box)

func _on_durability_hit(_current_hp: int, _max_hp: int, _target_name: String, target_ref: Variant) -> void:
	if not enabled:
		return
	
	current_target_ref = target_ref
	_update_box_position()

func _on_durability_cleared() -> void:
	if target_box:
		target_box.visible = false
	current_target_ref = null

func _process(_delta: float) -> void:
	if current_target_ref != null and enabled:
		_update_box_position()
	else:
		if target_box:
			target_box.visible = false

func _update_box_position() -> void:
	if not target_box:
		return
	
	# Handle Vector3i (terrain blocks)
	if current_target_ref is Vector3i:
		var block_pos: Vector3i = current_target_ref
		target_box.global_position = Vector3(block_pos.x + 0.5, block_pos.y + 0.5, block_pos.z + 0.5)
		target_box.scale = Vector3(1.02, 1.02, 1.02)  # Slightly larger than 1x1x1 block
		target_box.visible = true
		return
	
	# Handle RID (trees, zombies, physics objects)
	if current_target_ref is RID:
		var space_state = get_world_3d().direct_space_state
		var collision_object = PhysicsServer3D.body_get_object_instance_id(current_target_ref)
		if collision_object != 0:
			var node = instance_from_id(collision_object)
			if node and node is Node3D:
				_fit_box_to_node(node)
				return
	
	# Handle Node (building blocks, placed objects)
	if current_target_ref is Node:
		if is_instance_valid(current_target_ref) and current_target_ref is Node3D:
			_fit_box_to_node(current_target_ref)
			return
	
	# Fallback: hide if unknown type
	target_box.visible = false

func _fit_box_to_node(node: Node3D) -> void:
	# Try to find AABB bounds
	var aabb := AABB()
	var found_bounds := false
	
	# Check if it has a MeshInstance3D
	if node is MeshInstance3D:
		aabb = node.get_aabb()
		found_bounds = true
	else:
		# Search children for mesh instances
		for child in node.get_children():
			if child is MeshInstance3D:
				var child_aabb = child.get_aabb()
				child_aabb.position += child.position
				if found_bounds:
					aabb = aabb.merge(child_aabb)
				else:
					aabb = child_aabb
					found_bounds = true
	
	if found_bounds:
		target_box.global_position = node. global_position + aabb.get_center()
		target_box.scale = aabb.size * 1.05  # 5% larger for visibility
		target_box.visible = true
	else:
		# Fallback: use node position with default 1x1x1 size
		target_box.global_position = node.global_position
		target_box.scale = Vector3(1.0, 1.0, 1.0)
		target_box.visible = true
