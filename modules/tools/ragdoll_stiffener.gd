@tool
extends Node

@export var apply_changes: bool = false : set = _apply_changes
@export var stiffness_angle: float = 15.0

func _apply_changes(val):
	if val:
		apply_stiffness()
		apply_changes = false

func apply_stiffness():
	var sim = get_node("../PhysicalBoneSimulator3D")
	if not sim:
		sim = get_parent().find_child("PhysicalBoneSimulator3D", true)
	
	if not sim:
		print("Error: Could not find PhysicalBoneSimulator3D")
		return
		
	print("Stiffening Ragdoll Joints...")
	var count = 0
	
	for child in sim.get_children():
		if child is PhysicalBone3D:
			# Switch to Cone Joint (More stable for ragdolls)
			child.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			
			# Remove 'bias' if possible (it's a constraint param, confusing in script)
			# Godot exposes these via set/get param usually, but properties are mapped.
			
			# Set standard limits to prevent "flopping"
			# Cone joint uses swing_span (angular X/Z limit) and twist_span (angular Y limit)
			
			# Note: Godot 4 API for PhysicalBone3D joint params:
			# set("joint_constraints/swing_span", val)
			
			child.set("joint_constraints/swing_span", stiffness_angle)
			child.set("joint_constraints/twist_span", stiffness_angle)
			
			# Trying to set bias to 0 or remove it (Jolt ignores it anyway)
			child.set("joint_constraints/bias", 0.0) 
			
			# Damping helps stability
			child.set("joint_constraints/damping", 5.0) # Higher damping = thicker fluid
			
			count += 1
			
	print("Updated ", count, " bones to Cone Joint with ", stiffness_angle, " degree limits.")
