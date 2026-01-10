@tool
extends Node

## Ragdoll Helper
## 1. SETUP: Makes the ragdoll stiff (like a statue) so it doesn't crumple.
## 2. RUNTIME: Holds the Root/Hips up so it stands.

@export_group("1. Joint Setup (Editor)")
@export var joint_stiffness_deg: float = 2.0 ## Lower = Stiffer. Limits the angle bones can bend.
@export var joint_damping: float = 10.0 ## Higher = Syrupy usage. Stops wobbling.
@export var run_setup: bool = false : set = _on_run_setup

@export_group("2. Runtime Balance")
@export var active: bool = true
## 0.0 = Heavy/Fall, 1.0 = Weightless/Float. 0.95 is good for 'Standing'.
@export var gravity_cancel: float = 0.95 
## Force to keep hips vertical.
@export var balance_power: float = 4000.0

var root_bone: PhysicalBone3D

func _ready():
	if Engine.is_editor_hint(): return
	
	# Find Root Bone at Runtime
	var sim = _find_simulator()
	if sim:
		for child in sim.get_children():
			if child is PhysicalBone3D:
				# Heuristic: First bone or name match
				if not root_bone: root_bone = child
				elif "root" in child.name.to_lower() or "pelvis" in child.name.to_lower():
					root_bone = child
					break
		if root_bone:
			print("RagdollHelper: Holding up ", root_bone.name)

func _physics_process(delta):
	if Engine.is_editor_hint() or not active or not root_bone: return
	
	# 1. Anti-Gravity (Float)
	# Apply force UP to cancel gravity
	var g_vec = ProjectSettings.get_setting("physics/3d/default_gravity_vector")
	var g_mag = ProjectSettings.get_setting("physics/3d/default_gravity")
	var up_force = -g_vec * g_mag * root_bone.mass * gravity_cancel
	# Manual Force Integration (PhysicalBone3D lacks apply_central_force)
	# F = ma -> a = F/m
	if root_bone.mass > 0:
		var accel = up_force / root_bone.mass
		root_bone.linear_velocity += accel * delta
	
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
			child.set("joint_constraints/swing_span", joint_stiffness_deg)
			child.set("joint_constraints/twist_span", joint_stiffness_deg)
			
			# 3. High Damping (No jitter)
			child.set("joint_constraints/damping", joint_damping)
			
			# 4. Remove Bias (Jolt cleanup)
			child.set("joint_constraints/bias", 0.0)
			
			count += 1
			
	print("RagdollHelper: Stiffened ", count, " bones with ", joint_stiffness_deg, " deg limits.")

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
