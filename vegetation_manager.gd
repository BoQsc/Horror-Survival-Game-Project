extends Node3D

signal tree_chopped(world_position: Vector3)

@export var terrain_manager: Node3D
@export var tree_model_path: String = "res://models/rigged_animated_cinematic_quality_tree_4.glb"
@export var tree_scale: float = 1.0  # Adjust if model is too big/small
@export var tree_y_offset: float = -3.0  # Negative to sink trees into ground
@export var collision_radius: float = 0.5  # Trunk collision radius
@export var collision_height: float = 8.0  # Trunk collision height

var tree_mesh: Mesh
var forest_noise: FastNoiseLite

# Queue for deferred vegetation placement (wait for physics colliders)
var pending_chunks: Array[Dictionary] = []

# Tree data storage per chunk: coord -> { multimesh: MMI, trees: [{pos, alive, collider}...] }
var chunk_tree_data: Dictionary = {}

func _ready():
	# Load tree mesh from GLB model
	tree_mesh = load_tree_mesh_from_glb(tree_model_path)
	if tree_mesh == null:
		push_warning("Failed to load tree model, falling back to basic mesh")
		tree_mesh = create_basic_tree_mesh()
	
	# Setup Forest Noise
	forest_noise = FastNoiseLite.new()
	forest_noise.frequency = 0.05
	forest_noise.seed = 12345
	
	if terrain_manager:
		terrain_manager.chunk_generated.connect(_on_chunk_generated)

func _on_chunk_generated(coord: Vector2i, chunk_node: Node3D):
	if chunk_node == null:
		return
	
	# Clean up old data if chunk was regenerated
	if chunk_tree_data.has(coord):
		_cleanup_chunk_trees(coord)
	
	# Queue for deferred processing - physics colliders need a frame to register
	pending_chunks.append({
		"coord": coord,
		"chunk_node": chunk_node,
		"frames_waited": 0
	})

func _cleanup_chunk_trees(coord: Vector2i):
	if chunk_tree_data.has(coord):
		var data = chunk_tree_data[coord]
		# Colliders are children of chunk_node, will be freed when chunk unloads
		chunk_tree_data.erase(coord)

func _physics_process(_delta):
	if pending_chunks.is_empty():
		return
	
	# Process one chunk per frame to avoid spikes
	var item = pending_chunks[0]
	item.frames_waited += 1
	
	# Wait 5 physics frames for colliders to be fully registered
	if item.frames_waited < 5:
		return
	
	pending_chunks.pop_front()
	
	# Check if chunk node is still valid (might have been unloaded)
	if not is_instance_valid(item.chunk_node):
		return
	
	_place_vegetation_for_chunk(item.coord, item.chunk_node)

func _place_vegetation_for_chunk(coord: Vector2i, chunk_node: Node3D):
	var mmi = MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.mesh = tree_mesh
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	
	var tree_list = []  # Store tree data for this chunk
	var valid_transforms = []
	var chunk_stride = 31
	var chunk_origin_x = coord.x * chunk_stride
	var chunk_origin_z = coord.y * chunk_stride
	
	# Get chunk node's world position for coordinate conversion
	var chunk_world_pos = chunk_node.global_position
	
	# Container for collision shapes
	var collision_container = Node3D.new()
	collision_container.name = "TreeColliders"
	chunk_node.add_child(collision_container)
	
	var space_state = get_world_3d().direct_space_state
	
	# Reduced density: Step by 4 instead of 1
	for x in range(0, chunk_stride, 4):
		for z in range(0, chunk_stride, 4):
			var gx = chunk_origin_x + x
			var gz = chunk_origin_z + z
			
			# 1. Check Forest Mask
			var noise_val = forest_noise.get_noise_2d(gx, gz)
			if noise_val < 0.4:
				continue
			
			# 2. Raycast to find exact terrain surface height
			var ray_origin = Vector3(gx, 100.0, gz)
			var ray_end = Vector3(gx, -10.0, gz)
			
			var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
			query.collision_mask = 0xFFFFFFFF
			query.collide_with_areas = false
			
			var result = space_state.intersect_ray(query)
			if result.is_empty():
				continue
			
			var hit_pos = result.position
			
			# 3. Check if underwater using water density
			var water_dens = terrain_manager.get_water_density(Vector3(gx, hit_pos.y + 1.0, gz))
			if water_dens < 0.0:
				continue
			
			# Calculate positions
			var local_pos = hit_pos - chunk_world_pos
			local_pos.y += tree_y_offset
			
			var world_pos = hit_pos
			world_pos.y += tree_y_offset
			
			# Build visual transform
			var random_scale = randf_range(0.8, 1.2)
			var final_scale = tree_scale * random_scale
			var rotation_angle = randf() * TAU
			
			var t = Transform3D()
			t = t.rotated(Vector3.UP, rotation_angle)
			t = t.scaled(Vector3(final_scale, final_scale, final_scale))
			t.origin = local_pos
			
			valid_transforms.append(t)
			
			# Create collision body for this tree
			var collider = _create_tree_collider(local_pos, final_scale)
			collision_container.add_child(collider)
			
			# Store tree data
			var tree_index = valid_transforms.size() - 1
			tree_list.append({
				"world_pos": world_pos,
				"local_pos": local_pos,
				"index": tree_index,
				"alive": true,
				"collider": collider,
				"scale": final_scale
			})
	
	if valid_transforms.size() > 0:
		mmi.multimesh.instance_count = valid_transforms.size()
		for i in range(valid_transforms.size()):
			mmi.multimesh.set_instance_transform(i, valid_transforms[i])
		
		chunk_node.add_child(mmi)
	
	# Store chunk data
	chunk_tree_data[coord] = {
		"multimesh": mmi,
		"trees": tree_list,
		"chunk_node": chunk_node
	}

func _create_tree_collider(local_pos: Vector3, scale: float) -> StaticBody3D:
	var body = StaticBody3D.new()
	body.add_to_group("trees")
	body.position = local_pos
	body.position.y += (collision_height * scale) / 2.0  # Center the cylinder
	
	var shape = CollisionShape3D.new()
	var cylinder = CylinderShape3D.new()
	cylinder.radius = collision_radius * scale
	cylinder.height = collision_height * scale
	shape.shape = cylinder
	body.add_child(shape)
	
	return body

# Call this to chop a tree at the given world position (from raycast hit)
func chop_tree_at(world_pos: Vector3, search_radius: float = 2.0) -> bool:
	for coord in chunk_tree_data:
		var data = chunk_tree_data[coord]
		for tree in data.trees:
			if not tree.alive:
				continue
			
			var dist = tree.world_pos.distance_to(world_pos)
			if dist < search_radius:
				# Found the tree! Mark as dead
				tree.alive = false
				
				# Hide in MultiMesh by scaling to 0
				var mmi = data.multimesh as MultiMeshInstance3D
				if mmi and mmi.multimesh:
					var t = Transform3D()
					t = t.scaled(Vector3.ZERO)
					t.origin = tree.local_pos
					mmi.multimesh.set_instance_transform(tree.index, t)
				
				# Remove collision
				if tree.collider and is_instance_valid(tree.collider):
					tree.collider.queue_free()
					tree.collider = null
				
				# Emit signal
				tree_chopped.emit(tree.world_pos)
				return true
	
	return false

# Alternative: Chop tree by collider reference (from raycast result)
func chop_tree_by_collider(collider: Node) -> bool:
	for coord in chunk_tree_data:
		var data = chunk_tree_data[coord]
		for tree in data.trees:
			if tree.collider == collider and tree.alive:
				tree.alive = false
				
				# Hide in MultiMesh
				var mmi = data.multimesh as MultiMeshInstance3D
				if mmi and mmi.multimesh:
					var t = Transform3D()
					t = t.scaled(Vector3.ZERO)
					t.origin = tree.local_pos
					mmi.multimesh.set_instance_transform(tree.index, t)
				
				# Remove collision
				if is_instance_valid(tree.collider):
					tree.collider.queue_free()
					tree.collider = null
				
				tree_chopped.emit(tree.world_pos)
				return true
	
	return false

func load_tree_mesh_from_glb(path: String) -> Mesh:
	var scene = load(path)
	if scene == null:
		push_error("Could not load GLB: " + path)
		return null
	
	var instance = scene.instantiate()
	var mesh = find_mesh_in_node(instance)
	instance.queue_free()
	
	if mesh:
		print("Loaded tree mesh from: ", path, " with ", mesh.get_surface_count(), " surfaces")
	
	return mesh

func find_mesh_in_node(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return node.mesh
	
	for child in node.get_children():
		var mesh = find_mesh_in_node(child)
		if mesh:
			return mesh
	
	return null

func create_basic_tree_mesh() -> Mesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var trunk_mat = StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.5, 0.2, 0.0)
	st.set_material(trunk_mat)
	
	var trunk_height = 5.0
	var trunk_radius = 0.5
	
	for i in range(8):
		var angle1 = float(i) / 8.0 * PI * 2.0
		var angle2 = float(i+1) / 8.0 * PI * 2.0
		var p1 = Vector3(cos(angle1) * trunk_radius, 0, sin(angle1) * trunk_radius)
		var p2 = Vector3(cos(angle2) * trunk_radius, 0, sin(angle2) * trunk_radius)
		var p3 = Vector3(cos(angle2) * trunk_radius, trunk_height, sin(angle2) * trunk_radius)
		var p4 = Vector3(cos(angle1) * trunk_radius, trunk_height, sin(angle1) * trunk_radius)
		
		st.add_vertex(p1)
		st.add_vertex(p2)
		st.add_vertex(p3)
		st.add_vertex(p1)
		st.add_vertex(p3)
		st.add_vertex(p4)
	
	var leaves_mat = StandardMaterial3D.new()
	leaves_mat.albedo_color = Color(0.0, 0.5, 0.1)
	st.set_material(leaves_mat)
	
	var leaves_height = 7.0
	var leaves_radius = 3.0
	var leaves_base_y = trunk_height * 0.8
	
	for i in range(8):
		var angle1 = float(i) / 8.0 * PI * 2.0
		var angle2 = float(i+1) / 8.0 * PI * 2.0
		var p1 = Vector3(cos(angle1) * leaves_radius, leaves_base_y, sin(angle1) * leaves_radius)
		var p2 = Vector3(cos(angle2) * leaves_radius, leaves_base_y, sin(angle2) * leaves_radius)
		var p_top = Vector3(0, leaves_base_y + leaves_height, 0)
		
		st.add_vertex(p1)
		st.add_vertex(p2)
		st.add_vertex(p_top)
	
	st.index()
	return st.commit()
