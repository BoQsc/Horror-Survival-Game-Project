extends RigidBody3D

func _ready():
	# Bump up to avoid floor clipping
	global_position.y += 0.1
	
	# Lay flat on its side! (Pistols don't stand up)
	# Assuming Z-axis rotation lays it down
	rotation_degrees.z = 90.0
	rotation_degrees.x = 0.0 # Keep it aligned with placement grid otherwise
	
	# Physics Settings for Stability
	mass = 5.0 # Heavy enough to be stable
	linear_damp = 2.0 # Stop sliding quickly
	angular_damp = 5.0 # Stop spinning quickly
	
	# Create and assign a high-friction material dynamically
	var phys_mat = PhysicsMaterial.new()
	phys_mat.friction = 1.0
	phys_mat.bounce = 0.0
	phys_mat.absorbent = true # Absorb energy on collision
	physics_material_override = phys_mat
	
	# Ensure active
	freeze = false
	sleeping = false
	can_sleep = true
	continuous_cd = true
