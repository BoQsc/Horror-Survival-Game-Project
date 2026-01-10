@tool
extends Node

## Physical Bone Scaler (Interactive)
## Stores original dimensions in metadata to allow non-destructive scaling.
## Adjust 'Scale Factor' to resize relative to the INITIAL state found when the script first ran.

@export var simulator_path: NodePath
@export var scale_factor: float = 1.0 : set = _set_scale_factor
@export var debug_mode: bool = false
@export_group("Operations")
@export var reset_storage: bool = false : set = _on_reset_storage
@export var remove_fingers: bool = false : set = _on_remove_fingers

func _set_scale_factor(val):
	scale_factor = val
	apply_scale_to_hierarchy()

func _on_reset_storage(val):
	if val:
		_clear_metadata()
		reset_storage = false

func _on_remove_fingers(val):
	if val:
		_delete_finger_bones()
		remove_fingers = false

func _delete_finger_bones():
	var sim_node = get_node_or_null(simulator_path)
	if not sim_node: 
		if simulator_path.is_empty(): sim_node = self
		else: return

	if sim_node is Skeleton3D:
		var found = sim_node.find_child("PhysicalBoneSimulator3D")
		if found: sim_node = found
	
	var bones = sim_node.find_children("*", "PhysicalBone3D", true)
	var count = 0
	for bone in bones:
		if "finger" in bone.name.to_lower():
			bone.free() # Immediate free for tool script
			count += 1
	
	print("PBS: Removed ", count, " finger bones.")

func apply_scale_to_hierarchy():
	if simulator_path.is_empty():
		simulator_path = "."
	var sim_node = get_node_or_null(simulator_path)
	if not sim_node:
		return

	if sim_node is Skeleton3D:
		var found = sim_node.find_child("PhysicalBoneSimulator3D")
		if found: sim_node = found
	
	if debug_mode: print("PBS: Updating scale to x", scale_factor)
	
	var bones = sim_node.find_children("*", "PhysicalBone3D", true)
	for bone in bones:
		if bone is PhysicalBone3D:
			_scale_physical_bone(bone)

func _scale_physical_bone(pb: PhysicalBone3D):
	# 1. POSITION: Scale relative to the skeleton hierarchy
	pb.position = _get_scaled_value(pb, "init_bone_pos", pb.position)
	
	# 2. BASIS SCALING (Fixes Giant Gizmos):
	# We must normalize the basis (remove import scale) and apply scale_factor
	# for the Node itself, and its offsets.

	# Node Basis
	if not pb.has_meta("init_basis"): pb.set_meta("init_basis", pb.transform.basis)
	var node_basis: Basis = pb.get_meta("init_basis")
	pb.transform.basis = node_basis.orthonormalized().scaled(Vector3.ONE * scale_factor)

	# Body Offset Basis (Fixes Body Gizmo size)
	var body_off = pb.body_offset
	if not pb.has_meta("init_body_basis"): pb.set_meta("init_body_basis", body_off.basis)
	var body_basis: Basis = pb.get_meta("init_body_basis")
	body_off.basis = body_basis.orthonormalized().scaled(Vector3.ONE * scale_factor)
	# Body Offset Origin
	body_off.origin = _get_scaled_value(pb, "init_body_off_orig", body_off.origin)
	pb.body_offset = body_off
	
	# Joint Offset Basis (Fixes Joint Gizmo size)
	var joint_off = pb.joint_offset
	if not pb.has_meta("init_joint_basis"): pb.set_meta("init_joint_basis", joint_off.basis)
	var joint_basis: Basis = pb.get_meta("init_joint_basis")
	joint_off.basis = joint_basis.orthonormalized().scaled(Vector3.ONE * scale_factor)
	# Joint Offset Origin
	joint_off.origin = _get_scaled_value(pb, "init_joint_off_orig", joint_off.origin)
	pb.joint_offset = joint_off

	# Handle Children
	for child in pb.get_children():
		if child is CollisionShape3D:
			_scale_collision_shape(child)

const MIN_SIZE = 0.005 # 5mm minimum to satisfy Jolt

func _scale_collision_shape(cshape: CollisionShape3D):
	# Position (stored on CS node) - UN-SCALED because parent pb.scale handles it?
	# Wait. If parent pb.scale is 0.06, and we want position X.
	# The global position is pb.global_transform * local_pos.
	# pb.transform is scaled 0.06. So local_pos is multiplied by 0.06.
	# So we should set local_pos to the ORIGINAL unscaled value.
	cshape.position = _get_base_value(cshape, "init_pos", cshape.position)
	
	# SHAPE PARAMETERS: Inherit Parent Scale (0.06).
	# Use Base (Unscaled) values.
	var s = cshape.shape
	
	if s is CapsuleShape3D:
		s.radius = max(_get_scaled_value(cshape, "init_radius", s.radius), MIN_SIZE)
		s.height = max(_get_scaled_value(cshape, "init_height", s.height), MIN_SIZE)
	elif s is SphereShape3D:
		s.radius = max(_get_scaled_value(cshape, "init_radius", s.radius), MIN_SIZE)
	elif s is BoxShape3D:
		var sz = _get_scaled_value(cshape, "init_size", s.size)
		s.size = Vector3(max(sz.x, MIN_SIZE), max(sz.y, MIN_SIZE), max(sz.z, MIN_SIZE))
	elif s is CylinderShape3D:
		s.radius = max(_get_scaled_value(cshape, "init_radius", s.radius), MIN_SIZE)
		s.height = max(_get_scaled_value(cshape, "init_height", s.height), MIN_SIZE)
	elif s is SeparationRayShape3D:
		s.length = max(_get_scaled_value(cshape, "init_len", s.length), MIN_SIZE)

# Helper to retrieve original, store if missing, and return scaled
func _get_scaled_value(storage_node: Node, key: String, current_value):
	if not storage_node.has_meta(key):
		storage_node.set_meta(key, current_value)
		if debug_mode: print("  Stored base ", key, " for ", storage_node.name)
		
	var original = storage_node.get_meta(key)
	return original * scale_factor

# Helper to get base value WITHOUT scaling (for shapes that inherit node scale)
func _get_base_value(storage_node: Node, key: String, current_value):
	if not storage_node.has_meta(key):
		storage_node.set_meta(key, current_value) # Store current (which should be base if huge)
		if debug_mode: print("  Stored base ", key, " for ", storage_node.name)
	return storage_node.get_meta(key)

func _clear_metadata():
	var sim_node = get_node_or_null(simulator_path)
	if not sim_node: return
	if sim_node is Skeleton3D: sim_node = sim_node.find_child("PhysicalBoneSimulator3D")
	
	var nodes = sim_node.find_children("*", "PhysicalBone3D", true)
	
	# Gather all CollisionShapes too
	var all_nodes = []
	all_nodes.append_array(nodes)
	for n in nodes:
		all_nodes.append_array(n.find_children("*", "CollisionShape3D"))
		
	var keys = ["init_basis", "init_body_basis", "init_joint_basis", "init_bone_pos", "init_body_off_orig", "init_joint_off_orig", "init_pos", "init_radius", "init_height", "init_size", "init_len"]
	
	for n in all_nodes:
		for k in keys:
			if n.has_meta(k):
				n.remove_meta(k)
	
	print("PBS: Metadata cleared. Current sizes are now the new 'Base' 1.0 sizes.")
