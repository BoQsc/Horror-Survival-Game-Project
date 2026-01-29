extends Node3D

@export var start_delay: float = 1.5

func _ready():
	print("Ragdoll Test: Starting in ", start_delay, " seconds...")
	await get_tree().create_timer(start_delay).timeout
	start_ragdoll()

func _input(event):
	if event.is_action_pressed("ui_accept"): # Spacebar
		start_ragdoll()

func start_ragdoll():
	var skeleton = find_child("Skeleton3D", true)
	if not skeleton:
		print("Error: No Skeleton3D found.")
		return
		
	var simulator = skeleton.find_child("PhysicalBoneSimulator3D")
	if not simulator:
		# Fallback: maybe the simulator IS the child, or maybe we use standard physical bones on skeleton?
		# Assuming Jolt uses PhysicalBoneSimulator3D
		print("Error: No PhysicalBoneSimulator3D found under Skeleton.")
		return
	
	print("Starting Simulation!")
	simulator.physical_bones_start_simulation()

func _physics_process(_delta):
	# DEBUG CONTROLS
	if Input.is_action_just_pressed("ui_focus_next"): # Tab or similar
		_apply_random_impulse()
	
	if Input.is_key_pressed(KEY_T):
		Engine.time_scale = 0.1
	else:
		Engine.time_scale = 1.0
		
	if Input.is_key_pressed(KEY_R):
		get_tree().reload_current_scene()
		
	_check_for_nan_explosion()

func _check_for_nan_explosion():
	var skeleton = find_child("Skeleton3D", true)
	if not skeleton: return
	
	# Check the first physical bone (usually root)
	var simulator = skeleton.find_child("PhysicalBoneSimulator3D")
	if simulator and simulator.get_child_count() > 0:
		var bone = simulator.get_child(0) as Node3D
		if bone:
			var pos = bone.global_position
			if not is_finite(pos.x) or not is_finite(pos.y) or not is_finite(pos.z):
				print("CRITICAL: Physics Explosion detected! Coordinates are NaN/Inf. Mesh vanished because logic broke.")
				set_physics_process(false) # Stop spamming
			elif pos.length() > 10000.0:
				print("CRITICAL: Ragdoll flew away! Distance > 10,000 units.")
				set_physics_process(false)

func _apply_random_impulse():
	var skeleton = find_child("Skeleton3D", true)
	if not skeleton: return
	var simulator = skeleton.find_child("PhysicalBoneSimulator3D")
	if not simulator: return
	
	# Poke the first bone we find
	for child in simulator.get_children():
		if child is PhysicalBone3D:
			var poke_dir = Vector3(randf()-0.5, randf(), randf()-0.5).normalized()
			print("Poking ", child.name, " with force!")
			child.apply_impulse(poke_dir * 50.0) # Adjust force as needed
			break
