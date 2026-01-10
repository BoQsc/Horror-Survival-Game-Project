extends Node

@export var stiffness: float = 300.0
@export var damping: float = 10.0
@export var active: bool = true

var skeleton: Skeleton3D
var bones: Array[PhysicalBone3D] = []

func _ready():
	# Find config
	var sim = get_parent() as PhysicalBoneSimulator3D
	if not sim:
		sim = get_node("../PhysicalBoneSimulator3D")
	
	if not sim:
		printerr("ActiveRagdoll: No Simulator found.")
		return
		
	skeleton = sim.get_parent() as Skeleton3D
	
	for child in sim.get_children():
		if child is PhysicalBone3D:
			bones.append(child)
			
	print("Active Ragdoll Initialized with ", bones.size(), " bones.")

func _physics_process(delta):
	if not active or not skeleton: return
	
	for pb in bones:
		_apply_torque(pb, delta)

func _apply_torque(pb: PhysicalBone3D, delta: float):
	if pb.bone_name.is_empty(): return
	
	var bone_idx = skeleton.find_bone(pb.bone_name)
	if bone_idx == -1: return
	
	# Target Rotation: The global rotation of the bone in the animated skeleton
	var target_transform = skeleton.global_transform * skeleton.get_bone_global_pose(bone_idx)
	var target_basis = target_transform.basis
	
	# Current Physics Rotation
	var current_basis = pb.global_transform.basis
	
	# Rotation Difference (Quaternion)
	var q_diff = (target_basis * current_basis.inverse()).get_rotation_quaternion()
	
	# Angle to cover
	var angle = q_diff.get_angle()
	if angle < 0.001: return
	
	var axis = q_diff.get_axis().normalized()
	
	# Calculate torque (Spring-Damper)
	# Torque = (k * angle) - (d * angular_velocity)
	# We strictly just want to push towards target.
	
	# NOTE: This is a simplified P-Controller.
	# Correct quaternion difference might need shortest path check.
	if q_diff.w < 0:
		axis = -axis
		angle = -angle
		
	var torque = axis * (angle * stiffness) - (pb.angular_velocity * damping)
	
	# Manual Torque Integration (PhysicalBone3D lacks apply_torque)
	# Torque = I * alpha -> alpha = Torque / I. We ignore I (assumed 1.0).
	# w += alpha * delta
	pb.angular_velocity += torque * delta
