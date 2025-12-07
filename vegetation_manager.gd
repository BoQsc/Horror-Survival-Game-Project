extends Node3D

@export var terrain_manager: Node3D

var tree_mesh: Mesh
var forest_noise: FastNoiseLite

func _ready():
	# Create a simple placeholder mesh for the tree
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
		
	# Each chunk gets its own MultiMeshInstance
	var mmi = MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.mesh = tree_mesh
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	# Max trees per chunk? 
	# 32x32 = 1024 columns. Maybe 100 trees max?
	# We will calculate valid spots first.
	
	var valid_transforms = []
	var chunk_stride = 31 # Hardcoded for now, match ChunkManager
	var chunk_origin_x = coord.x * chunk_stride
	var chunk_origin_z = coord.y * chunk_stride
	
	for x in range(chunk_stride):
		for z in range(chunk_stride):
			var gx = chunk_origin_x + x
			var gz = chunk_origin_z + z
			
			# 1. Check Forest Mask
			var noise_val = forest_noise.get_noise_2d(gx, gz)
			if noise_val < 0.2: # Only plant if noise > 0.2
				continue
				
			# 2. Get Height
			var y = terrain_manager.get_terrain_height(gx, gz)
			if y < -500.0: # No ground found
				continue
				
			# 3. Check Water Level (Optional, but good)
			# We can check if y < water_level. 
			# For now let's just assume trees don't grow underwater 
			# But we don't have water_level var here easily.
			# Let's rely on height. If it's too low it might be underwater.
			# Actually, we can check density at a slightly higher point to see if it's water?
			# Using get_water_density(Vector3(gx, y + 1, gz))
			var water_dens = terrain_manager.get_water_density(Vector3(gx, y + 1.0, gz))
			if water_dens < 0.0: # Underwater
				continue
				
			# Place Tree
			var t = Transform3D()
			t.origin = Vector3(gx, y, gz)
			# Random Rotation
			t = t.rotated(Vector3.UP, randf() * TAU)
			# Random Scale
			var s = randf_range(0.8, 1.2)
			t = t.scaled(Vector3(s, s, s))
			
			valid_transforms.append(t)
			
	if valid_transforms.size() > 0:
		mmi.multimesh.instance_count = valid_transforms.size()
		for i in range(valid_transforms.size()):
			mmi.multimesh.set_instance_transform(i, valid_transforms[i])
			
		# Make the trees a child of the chunk node so they unload together!
		chunk_node.add_child(mmi)

func create_basic_tree_mesh() -> Mesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Trunk (Cylinder)
	var trunk_mat = StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.5, 0.2, 0.0)
	st.set_material(trunk_mat)
	
	var trunk_height = 5.0
	var trunk_radius = 0.5
	
	# Add cylinder (simple version for placeholder)
	for i in range(8):
		var angle1 = float(i) / 8.0 * PI * 2.0
		var angle2 = float(i+1) / 8.0 * PI * 2.0
		var p1 = Vector3(cos(angle1) * trunk_radius, 0, sin(angle1) * trunk_radius)
		var p2 = Vector3(cos(angle2) * trunk_radius, 0, sin(angle2) * trunk_radius)
		var p3 = Vector3(cos(angle2) * trunk_radius, trunk_height, sin(angle2) * trunk_radius)
		var p4 = Vector3(cos(angle1) * trunk_radius, trunk_height, sin(angle1) * trunk_radius)
		
		# Side faces
		st.add_vertex(p1)
		st.add_vertex(p2)
		st.add_vertex(p3)
		st.add_vertex(p1)
		st.add_vertex(p3)
		st.add_vertex(p4)
	
	# Leaves (Cone)
	var leaves_mat = StandardMaterial3D.new()
	leaves_mat.albedo_color = Color(0.0, 0.5, 0.1)
	st.set_material(leaves_mat)
	
	var leaves_height = 7.0
	var leaves_radius = 3.0
	var leaves_base_y = trunk_height * 0.8
	
	# Add cone (simple version)
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
