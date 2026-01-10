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
