extends RigidBody3D

func _ready():
	# Bump up significantly to ensure we clear any terrain noise
	global_position.y += 0.5
	
	# Lay flat on its side
	rotation_degrees.z = 90.0
	rotation_degrees.x = 0.0 
	
	# Physics Settings
	mass = 10.0 # Very heavy to push through micro-collisions and stay put
	linear_damp = 1.0 # High drag
	angular_damp = 3.0 # High rotational drag
	
	# Create high-friction material
	var phys_mat = PhysicsMaterial.new()
	phys_mat.friction = 1.0 # Max friction
	phys_mat.bounce = 0.1   # Slight bounce to prove it's alive
	phys_mat.absorbent = true
	physics_material_override = phys_mat
	
	# FORCE AWAKE: Do not allow sleeping at all initially
	freeze = false
	sleeping = false
	can_sleep = false 
	continuous_cd = true
	
	# Add a small random torque to ensure it doesn't land perfectly flat and stick
	angular_velocity = Vector3(randf(), randf(), randf()) * 2.0
	
	# Enable sleep after 2 seconds
	get_tree().create_timer(2.0).timeout.connect(func(): can_sleep = true)
