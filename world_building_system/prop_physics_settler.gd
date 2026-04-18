extends RigidBody3D

const ItemDefinitions = preload("res://modules/world_player_v2/features/data_inventory/item_definitions.gd")
@export var world_map_mode: bool = false
var _sleep_timer: Timer = null

func _ready():
	# Bump up significantly to ensure we clear any terrain noise
	global_position.y += 0.5
	
	# Lay flat on its side
	rotation_degrees.z = 90.0
	rotation_degrees.x = 0.0 

	if world_map_mode:
		# World-map towns do not need the pistol to physically settle. Keep the
		# pickup shell interactive, but stop the rigid body from waking/simulating.
		_generate_precise_collision()
		freeze = true
		sleeping = true
		can_sleep = false
		continuous_cd = false
		set_physics_process(false)
		return
	
	# Keep authored collision shapes when present.
	# The heavy pistol scene already has a box collider, so we only generate
	# a convex hull when no collision shape exists at all.
	_generate_precise_collision()
	
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

	# Enable sleep via timer as a backup
	_sleep_timer = Timer.new()
	_sleep_timer.one_shot = true
	_sleep_timer.wait_time = 2.0
	_sleep_timer.timeout.connect(_on_sleep_timer_timeout)
	add_child(_sleep_timer)
	_sleep_timer.start()

var life_time: float = 0.0
@export var freeze_on_sleep: bool = true

func _physics_process(delta):
	life_time += delta
	
	# Give it 1.0s to fall and bounce before we even consider freezing
	if life_time < 1.0:
		return

	# If we are effectively stopped, freeze to save perf
	if linear_velocity.length_squared() < 0.005 and angular_velocity.length_squared() < 0.005 and can_sleep:
		sleeping = true
		
	if freeze_on_sleep and sleeping:
		freeze = true
		set_physics_process(false)


func _on_sleep_timer_timeout() -> void:
	can_sleep = true
	if _sleep_timer and is_instance_valid(_sleep_timer):
		_sleep_timer.queue_free()
	_sleep_timer = null

func _generate_precise_collision():
	# Keep authored collision shapes when they already exist.
	for child in get_children():
		if child is CollisionShape3D or child is CollisionPolygon3D:
			return
			
	# Find meshes and generate convex hulls
	var mesh_instances = []
	_find_meshes_recursive(self, mesh_instances)
	
	if mesh_instances.is_empty():
		return
		
	for mesh_inst in mesh_instances:
		if not mesh_inst.mesh:
			continue
			
		# Create a precise convex shape from the mesh geometry
		# This ensures the physics shape MATCHES the visuals 1:1
		var shape = mesh_inst.mesh.create_convex_shape()
		if not shape:
			continue
			
		var col_node = CollisionShape3D.new()
		col_node.shape = shape
		
		# Match the transform of the mesh exactly
		# We need the transform relative to the RigidBody (self)
		col_node.transform = self.global_transform.affine_inverse() * mesh_inst.global_transform
		
		add_child(col_node)

func _find_meshes_recursive(node: Node, result: Array):
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_find_meshes_recursive(child, result)

## Get item data for pickup (called by PlayerInteraction)
func get_item_data() -> Dictionary:
	var data = {}
	
	# 1. Prefer existing metadata but validate it
	if has_meta("item_data"):
		data = get_meta("item_data").duplicate()
	
	# 2. Check identity
	var my_name = name.to_lower()
	var my_scene = scene_file_path
	var is_pistol = ("pistol" in my_name or "heavy_pistol" in my_scene)
	
	# 3. If it is a pistol, FORCE canonical definition from Single Source of Truth
	if is_pistol:
		data = ItemDefinitions.get_heavy_pistol_definition()
	
	# 4. Fallback if no data found and not a pistol
	if data.is_empty():
		data = {
			"id": my_name,
			"name": name,
			"category": 6, # PROP
			"stack_size": 16
		}
		
	return data
