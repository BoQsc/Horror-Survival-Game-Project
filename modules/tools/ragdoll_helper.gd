@tool
extends Node

## Ragdoll Helper
## 1. SETUP: Makes the ragdoll stiff (like a statue) so it doesn't crumple.
## 2. RUNTIME: Holds the Root/Hips up so it stands.

@export_group("1. Joint Setup (Editor)")
@export var max_rotation_angle: float = 30.0 ## Max degrees a joint can bend from straight. (e.g. 0=Rigid, 30=Stiff, 90=Flexible)
@export var joint_damping: float = 5.0 ## Resistance to motion.
@export var run_setup: bool = false : set = _on_run_setup

@export_group("2. Runtime Balance")
@export var active: bool = true
## 0.0 = Heavy/Fall, 1.0 = Weightless/Float. 0.95 is good for 'Standing'.
@export var gravity_cancel: float = 0.95 
## Force to keep hips vertical.
@export var balance_power: float = 4000.0

var root_bone: PhysicalBone3D
var all_bones: Array[PhysicalBone3D] = []

func _ready():
	if Engine.is_editor_hint(): return
	
	# Find Root Bone at Runtime
	var sim = _find_simulator()
	if sim:
		for child in sim.get_children():
			if child is PhysicalBone3D:
				all_bones.append(child)
				# Heuristic: First bone or name match
				if not root_bone: root_bone = child
				elif "root" in child.name.to_lower() or "pelvis" in child.name.to_lower():
					root_bone = child
					# break # Don't break, need to find all bones
		if root_bone:
			print("RagdollHelper: Managed ", all_bones.size(), " bones. Holding Root: ", root_bone.name)

func _physics_process(delta):
	if Engine.is_editor_hint() or not active or not root_bone: return
	
	# 1. Anti-Gravity (Float) - Apply to ALL BONES
	# Otherwise heavy limbs drag the root down.
	var g_vec = ProjectSettings.get_setting("physics/3d/default_gravity_vector")
	var g_mag = ProjectSettings.get_setting("physics/3d/default_gravity")
	# acceleration = -g * cancel
	var counter_accel = -g_vec * g_mag * gravity_cancel
	
	for pb in all_bones:
		# Manual Velocity Integration
		# v += a * dt
		pb.linear_velocity += counter_accel * delta
	
	# 2. Balance (Keep Upright)
	# Torque to align Local UP with World UP
	var current_up = root_bone.global_transform.basis.y
	var target_up = Vector3.UP
	
	var axis = current_up.cross(target_up).normalized()
	var angle = current_up.angle_to(target_up)
	
	if angle > 0.01:
		var torque = axis * (angle * balance_power) * root_bone.mass
		# Damping
		torque -= root_bone.angular_velocity * 20.0
		root_bone.angular_velocity += torque * delta


# EDITOR TOOL: JOINT SETUP
func _on_run_setup(val):
	if val:
		_apply_joint_setup()
		run_setup = false

func _apply_joint_setup():
	var sim = _find_simulator()
	if not sim:
		print("Error: Could not find PhysicalBoneSimulator3D (Checked self, children, and parent).")
		return
		
	var count = 0
	for child in sim.get_children():
		if child is PhysicalBone3D:
			# 1. Rigid Joint Type
			child.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			
			# 2. Tight Limits (Stiffness)
			# swing_span: Side-to-side rotation limit.
			# twist_span: Twisting rotation limit.
			child.set("joint_constraints/swing_span", max_rotation_angle)
			child.set("joint_constraints/twist_span", max_rotation_angle)
			
			# 3. High Damping (No jitter)
			child.set("joint_constraints/damping", joint_damping)
			
			# 4. Remove Bias (Jolt cleanup)
			child.set("joint_constraints/bias", 0.0)
			
			count += 1
			
	print("RagdollHelper: Limited ", count, " bones to ", max_rotation_angle, " degrees.")

func _find_simulator():
	# 1. Is it this node?
	# 1. Is it this node? (Skipped to avoid static type error)
	# if self is PhysicalBoneSimulator3D: return self
	
	# 2. Search Children Recursive (e.g. attached to Scene Root)
	var found = find_child("PhysicalBoneSimulator3D", true, false)
	if found: return found
	
	# 3. Check Parent (e.g. attached to Skeleton)
	var p = get_parent()
	if p is PhysicalBoneSimulator3D: return p
	
	# 4. Search Parent's Children (Sibling)
	if p:
		var sibling = p.find_child("PhysicalBoneSimulator3D", true, false)
		if sibling: return sibling
		
	return null
