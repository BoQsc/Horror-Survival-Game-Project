extends Node3D

signal tree_chopped(world_position: Vector3)
signal grass_harvested(world_position: Vector3)

@export var terrain_manager: Node3D
@export var tree_model_path: String = "res://models/pine_tree_-_ps1_low_poly.glb"
@export var tree_scale: float = 1.0
@export var tree_y_offset: float = 0.0  # GLB model has Y=11.76 origin built-in
@export var tree_rotation_fix: Vector3 = Vector3.ZERO
@export var collision_radius: float = 0.5
@export var collision_height: float = 8.0
@export var collider_distance: float = 30.0  # Only trees within this distance get colliders

# Grass settings
@export var grass_model_path: String = "res://models/grass/0/realistics_grass_06.glb"
@export var grass_scale: float = 0.5
@export var grass_y_offset: float = 0.0
@export var grass_collision_radius: float = 0.3
@export var grass_collision_height: float = 0.5

var tree_mesh: Mesh
var tree_base_transform: Transform3D = Transform3D()  # Orientation fix from GLB
var grass_mesh: Mesh
var grass_base_transform: Transform3D = Transform3D()
var forest_noise: FastNoiseLite
var grass_noise: FastNoiseLite
var player: Node3D

# Queue for deferred vegetation placement
var pending_chunks: Array[Dictionary] = []

# Tree data per chunk coord -> { multimesh, trees[], collision_container }
var chunk_tree_data: Dictionary = {}

# Pool of active colliders (reusable)
var active_colliders: Dictionary = {}  # tree_key -> StaticBody3D
var collider_pool: Array[StaticBody3D] = []
const MAX_ACTIVE_COLLIDERS = 50  # Limit active colliders for performance

# Grass data per chunk coord -> { multimesh, grass_list[] }
var chunk_grass_data: Dictionary = {}
var active_grass_colliders: Dictionary = {}  # grass_key -> StaticBody3D
var grass_collider_pool: Array[StaticBody3D] = []
const MAX_ACTIVE_GRASS_COLLIDERS = 30

func _ready():
	# Load tree mesh from GLB model with its orientation transform
	var glb_result = load_tree_mesh_from_glb(tree_model_path)
	if glb_result.mesh:
		tree_mesh = glb_result.mesh
		tree_base_transform = glb_result.transform
		tree_base_transform.origin = Vector3.ZERO  # Remove position, keep rotation/scale
	else:
		push_warning("Failed to load tree model, falling back to basic mesh")
		tree_mesh = create_basic_tree_mesh()
	
	forest_noise = FastNoiseLite.new()
	forest_noise.frequency = 0.05
	forest_noise.seed = 12345
	
	# Load grass mesh
	var grass_result = load_tree_mesh_from_glb(grass_model_path)
	if grass_result.mesh:
		grass_mesh = grass_result.mesh
		grass_base_transform = grass_result.transform
		grass_base_transform.origin = Vector3.ZERO
	else:
		push_warning("Failed to load grass model")
		grass_mesh = create_basic_grass_mesh()
	
	grass_noise = FastNoiseLite.new()
	grass_noise.frequency = 0.08  # Different pattern from trees
	grass_noise.seed = 54321
	
	if terrain_manager:
		terrain_manager.chunk_generated.connect(_on_chunk_generated)
	
	# Find player
	player = get_tree().get_first_node_in_group("player")

func _on_chunk_generated(coord: Vector2i, chunk_node: Node3D):
	if chunk_node == null:
		return
	
	if chunk_tree_data.has(coord):
		_cleanup_chunk_trees(coord)
	if chunk_grass_data.has(coord):
		_cleanup_chunk_grass(coord)
	
	pending_chunks.append({
		"coord": coord,
		"chunk_node": chunk_node,
		"frames_waited": 0
	})

func _cleanup_chunk_trees(coord: Vector2i):
	if chunk_tree_data.has(coord):
		# Return colliders to pool
		var data = chunk_tree_data[coord]
		for tree in data.trees:
			var key = _tree_key(coord, tree.index)
			if active_colliders.has(key):
				_return_collider_to_pool(active_colliders[key])
				active_colliders.erase(key)
		chunk_tree_data.erase(coord)

func _cleanup_chunk_grass(coord: Vector2i):
	if chunk_grass_data.has(coord):
		var data = chunk_grass_data[coord]
		for grass in data.grass_list:
			var key = _grass_key(coord, grass.index)
			if active_grass_colliders.has(key):
				_return_grass_collider_to_pool(active_grass_colliders[key])
				active_grass_colliders.erase(key)
		chunk_grass_data.erase(coord)

func _physics_process(_delta):
	# Process only ONE pending chunk per physics frame (rate limited)
	if not pending_chunks.is_empty():
		var item = pending_chunks[0]
		item.frames_waited += 1
		
		# Wait 5 frames for colliders, then process
		if item.frames_waited >= 5:
			pending_chunks.pop_front()
			if is_instance_valid(item.chunk_node):
				# Place vegetation - this does raycasting so only one per frame
				_place_vegetation_for_chunk(item.coord, item.chunk_node)
				_place_grass_for_chunk(item.coord, item.chunk_node)
			# Only process one chunk per frame to prevent stutter
			return
	
	# Only update colliders if we didn't just place vegetation (spread work)
	collider_update_counter += 1
	if collider_update_counter >= 15:  # Increased from 10 to reduce work
		collider_update_counter = 0
		_update_proximity_colliders()
		_update_grass_proximity_colliders()

var collider_update_counter: int = 0

func _update_proximity_colliders():
	if not player:
		player = get_tree().get_first_node_in_group("player")
		if not player:
			print("VegetationManager: Player not found in 'player' group!")
			return
	
	var player_pos = player.global_position
	var dist_sq = collider_distance * collider_distance
	var chunk_stride = 31
	var chunk_check_dist = collider_distance + chunk_stride  # Only check nearby chunks
	
	# Collect trees that need colliders (only from nearby chunks)
	var trees_needing_colliders: Array[Dictionary] = []
	
	for coord in chunk_tree_data:
		# Early-out: skip chunks too far from player
		var chunk_center_x = coord.x * chunk_stride + chunk_stride / 2.0
		var chunk_center_z = coord.y * chunk_stride + chunk_stride / 2.0
		var chunk_dist = Vector2(player_pos.x, player_pos.z).distance_to(Vector2(chunk_center_x, chunk_center_z))
		if chunk_dist > chunk_check_dist:
			continue
		
		var data = chunk_tree_data[coord]
		for tree in data.trees:
			if not tree.alive:
				continue
			
			var tree_dist_sq = player_pos.distance_squared_to(tree.world_pos)
			if tree_dist_sq < dist_sq:
				trees_needing_colliders.append({
					"coord": coord,
					"tree": tree,
					"dist_sq": tree_dist_sq
				})
	
	# Sort by distance (closest first)
	trees_needing_colliders.sort_custom(func(a, b): return a.dist_sq < b.dist_sq)
	
	# Limit to MAX_ACTIVE_COLLIDERS
	var wanted_keys: Dictionary = {}
	for i in range(min(trees_needing_colliders.size(), MAX_ACTIVE_COLLIDERS)):
		var item = trees_needing_colliders[i]
		var key = _tree_key(item.coord, item.tree.index)
		wanted_keys[key] = item
	
	# Remove colliders that are no longer needed
	var keys_to_remove = []
	for key in active_colliders:
		if not wanted_keys.has(key):
			keys_to_remove.append(key)
	
	for key in keys_to_remove:
		_return_collider_to_pool(active_colliders[key])
		active_colliders.erase(key)
	
	# Add colliders for trees that need them
	for key in wanted_keys:
		if not active_colliders.has(key):
			var item = wanted_keys[key]
			var collider = _get_collider_from_pool()
			# Use hit_pos (ground level) as base, then offset up by half height to center the cylinder on the trunk
			collider.global_position = item.tree.hit_pos
			collider.global_position.y += (collision_height * item.tree.scale) / 2.0
			
			# Update collision shape size if needed
			var shape = collider.get_child(0).shape as CylinderShape3D
			shape.radius = collision_radius * item.tree.scale
			shape.height = collision_height * item.tree.scale
			
			# Store reference for chopping
			collider.set_meta("tree_coord", item.coord)
			collider.set_meta("tree_index", item.tree.index)
			
			active_colliders[key] = collider

func _tree_key(coord: Vector2i, index: int) -> String:
	return "%d_%d_%d" % [coord.x, coord.y, index]

@export var debug_collision: bool = false

# ... (existing variables)

func _get_collider_from_pool() -> StaticBody3D:
	if collider_pool.size() > 0:
		var collider = collider_pool.pop_back()
		collider.visible = debug_collision # Use the flag
		collider.collision_layer = 1
		return collider
	
	# Create new collider
	var body = StaticBody3D.new()
	body.add_to_group("trees")
	body.collision_layer = 1  # Layer 1 - same as terrain
	
	var shape_node = CollisionShape3D.new()
	var shape = CylinderShape3D.new()
	shape.radius = collision_radius
	shape.height = collision_height
	shape_node.shape = shape
	body.add_child(shape_node)
	
	# DEBUG: Add visible mesh to see collider position
	var mesh_instance = MeshInstance3D.new()
	var cylinder_mesh = CylinderMesh.new()
	cylinder_mesh.top_radius = collision_radius
	cylinder_mesh.bottom_radius = collision_radius
	cylinder_mesh.height = collision_height
	mesh_instance.mesh = cylinder_mesh
	var debug_mat = StandardMaterial3D.new()
	debug_mat.albedo_color = Color(1, 0, 0, 0.5)
	debug_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = debug_mat
	body.add_child(mesh_instance)
	
	body.visible = debug_collision # Set initial visibility
	
	add_child(body)
	return body

func _return_collider_to_pool(collider: StaticBody3D):
	collider.collision_layer = 0  # Disable collision
	collider.visible = false
	collider_pool.append(collider)

# ========== GRASS HELPER FUNCTIONS ==========

func _grass_key(coord: Vector2i, index: int) -> String:
	return "g_%d_%d_%d" % [coord.x, coord.y, index]

func _get_grass_collider_from_pool() -> StaticBody3D:
	if grass_collider_pool.size() > 0:
		var collider = grass_collider_pool.pop_back()
		collider.visible = debug_collision
		collider.collision_layer = 1
		return collider
	
	# Create new collider
	var body = StaticBody3D.new()
	body.add_to_group("grass")
	body.collision_layer = 1
	
	var shape_node = CollisionShape3D.new()
	var shape = CylinderShape3D.new()
	shape.radius = grass_collision_radius
	shape.height = grass_collision_height
	shape_node.shape = shape
	body.add_child(shape_node)
	
	# DEBUG: Add visible mesh to see collider position
	var mesh_instance = MeshInstance3D.new()
	var cylinder_mesh = CylinderMesh.new()
	cylinder_mesh.top_radius = grass_collision_radius
	cylinder_mesh.bottom_radius = grass_collision_radius
	cylinder_mesh.height = grass_collision_height
	mesh_instance.mesh = cylinder_mesh
	var debug_mat = StandardMaterial3D.new()
	debug_mat.albedo_color = Color(0, 1, 0, 0.5)  # Green for grass
	debug_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = debug_mat
	body.add_child(mesh_instance)
	
	body.visible = debug_collision
	
	add_child(body)
	return body

func _return_grass_collider_to_pool(collider: StaticBody3D):
	collider.collision_layer = 0
	collider.visible = false
	grass_collider_pool.append(collider)

func _update_grass_proximity_colliders():
	if not player:
		return
	
	var player_pos = player.global_position
	var dist_sq = collider_distance * collider_distance
	var chunk_stride = 31
	var chunk_check_dist = collider_distance + chunk_stride
	
	# Collect grass that needs colliders
	var grass_needing_colliders: Array[Dictionary] = []
	
	for coord in chunk_grass_data:
		var chunk_center_x = coord.x * chunk_stride + chunk_stride / 2.0
		var chunk_center_z = coord.y * chunk_stride + chunk_stride / 2.0
		var chunk_dist = Vector2(player_pos.x, player_pos.z).distance_to(Vector2(chunk_center_x, chunk_center_z))
		if chunk_dist > chunk_check_dist:
			continue
		
		var data = chunk_grass_data[coord]
		for grass in data.grass_list:
			if not grass.alive:
				continue
			
			var grass_dist_sq = player_pos.distance_squared_to(grass.world_pos)
			if grass_dist_sq < dist_sq:
				grass_needing_colliders.append({
					"coord": coord,
					"grass": grass,
					"dist_sq": grass_dist_sq
				})
	
	# Sort by distance (closest first)
	grass_needing_colliders.sort_custom(func(a, b): return a.dist_sq < b.dist_sq)
	
	# Limit to MAX_ACTIVE_GRASS_COLLIDERS
	var wanted_keys: Dictionary = {}
	for i in range(min(grass_needing_colliders.size(), MAX_ACTIVE_GRASS_COLLIDERS)):
		var item = grass_needing_colliders[i]
		var key = _grass_key(item.coord, item.grass.index)
		wanted_keys[key] = item
	
	# Remove colliders that are no longer needed
	var keys_to_remove = []
	for key in active_grass_colliders:
		if not wanted_keys.has(key):
			keys_to_remove.append(key)
	
	for key in keys_to_remove:
		_return_grass_collider_to_pool(active_grass_colliders[key])
		active_grass_colliders.erase(key)
	
	# Add colliders for grass that needs them
	for key in wanted_keys:
		if not active_grass_colliders.has(key):
			var item = wanted_keys[key]
			var collider = _get_grass_collider_from_pool()
			collider.global_position = item.grass.hit_pos
			collider.global_position.y += (grass_collision_height * item.grass.scale) / 2.0
			
			# Update collision shape size
			var shape = collider.get_child(0).shape as CylinderShape3D
			shape.radius = grass_collision_radius * item.grass.scale
			shape.height = grass_collision_height * item.grass.scale
			
			# Store reference for harvesting
			collider.set_meta("grass_coord", item.coord)
			collider.set_meta("grass_index", item.grass.index)
			
			active_grass_colliders[key] = collider

func _place_vegetation_for_chunk(coord: Vector2i, chunk_node: Node3D):
	var mmi = MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.mesh = tree_mesh
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	
	var tree_list = []
	var valid_transforms = []
	var chunk_stride = 31
	var chunk_origin_x = coord.x * chunk_stride
	var chunk_origin_z = coord.y * chunk_stride
	var chunk_world_pos = chunk_node.global_position
	
	var space_state = get_world_3d().direct_space_state
	
	for x in range(0, chunk_stride, 4):
		for z in range(0, chunk_stride, 4):
			var gx = chunk_origin_x + x
			var gz = chunk_origin_z + z
			
			var noise_val = forest_noise.get_noise_2d(gx, gz)
			if noise_val < 0.4:
				continue
			
			var ray_origin = Vector3(gx, 100.0, gz)
			var ray_end = Vector3(gx, -10.0, gz)
			
			var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
			query.collision_mask = 0xFFFFFFFF
			query.collide_with_areas = false
			
			var result = space_state.intersect_ray(query)
			if result.is_empty():
				continue
			
			var hit_pos = result.position
			
			var water_dens = terrain_manager.get_water_density(Vector3(gx, hit_pos.y + 1.0, gz))
			if water_dens < 0.0:
				continue
			
			var local_pos = hit_pos - chunk_world_pos
			local_pos.y += tree_y_offset
			
			var world_pos = hit_pos
			world_pos.y += tree_y_offset
			
			var random_scale = randf_range(0.8, 1.2)
			var final_scale = tree_scale * random_scale
			var rotation_angle = randf() * TAU
			
			# Start with GLB's base transform (includes orientation fix)
			var t = tree_base_transform
			# Apply manual rotation fix
			t.basis = t.basis * Basis.from_euler(tree_rotation_fix)
			# Apply random Y rotation
			t = t.rotated(Vector3.UP, rotation_angle)
			# Apply scaling
			t = t.scaled(Vector3(final_scale, final_scale, final_scale))
			t.origin = local_pos
			
			valid_transforms.append(t)
			
			var tree_index = valid_transforms.size() - 1
			tree_list.append({
				"world_pos": world_pos,
				"local_pos": local_pos,
				"hit_pos": hit_pos, # Raw ground position (World)
				"rotation_angle": rotation_angle,
				"random_scale_factor": random_scale,
				"index": tree_index,
				"alive": true,
				"scale": final_scale
			})

	
	if valid_transforms.size() > 0:
		mmi.multimesh.instance_count = valid_transforms.size()
		for i in range(valid_transforms.size()):
			mmi.multimesh.set_instance_transform(i, valid_transforms[i])
		chunk_node.add_child(mmi)
	
	chunk_tree_data[coord] = {
		"multimesh": mmi,
		"trees": tree_list,
		"chunk_node": chunk_node
	}

func chop_tree_by_collider(collider: Node) -> bool:
	if not collider.has_meta("tree_coord"):
		return false
	
	var coord = collider.get_meta("tree_coord")
	var tree_index = collider.get_meta("tree_index")
	
	if not chunk_tree_data.has(coord):
		return false
	
	var data = chunk_tree_data[coord]
	for tree in data.trees:
		if tree.index == tree_index and tree.alive:
			tree.alive = false
			
			# Hide in MultiMesh
			var mmi = data.multimesh as MultiMeshInstance3D
			if mmi and mmi.multimesh:
				var t = Transform3D()
				t = t.scaled(Vector3.ZERO)
				t.origin = tree.local_pos
				mmi.multimesh.set_instance_transform(tree.index, t)
			
			# Remove collider
			var key = _tree_key(coord, tree_index)
			if active_colliders.has(key):
				_return_collider_to_pool(active_colliders[key])
				active_colliders.erase(key)
			
			tree_chopped.emit(tree.world_pos)
			return true
	
	return false

# ========== GRASS SPAWNING AND HARVESTING ==========

func _place_grass_for_chunk(coord: Vector2i, chunk_node: Node3D):
	if not grass_mesh:
		return
	
	var mmi = MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.mesh = grass_mesh
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	
	var grass_list = []
	var valid_transforms = []
	var chunk_stride = 31
	var chunk_origin_x = coord.x * chunk_stride
	var chunk_origin_z = coord.y * chunk_stride
	var chunk_world_pos = chunk_node.global_position
	
	var space_state = get_world_3d().direct_space_state
	
	# Sparse grass - every 5 meters (similar to trees)
	for x in range(0, chunk_stride, 5):
		for z in range(0, chunk_stride, 5):
			var gx = chunk_origin_x + x
			var gz = chunk_origin_z + z
			
			var noise_val = grass_noise.get_noise_2d(gx, gz)
			if noise_val < 0.3:  # Similar threshold to trees
				continue
			
			var ray_origin = Vector3(gx, 100.0, gz)
			var ray_end = Vector3(gx, -10.0, gz)
			
			var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
			query.collision_mask = 0xFFFFFFFF
			query.collide_with_areas = false
			
			var result = space_state.intersect_ray(query)
			if result.is_empty():
				continue
			
			var hit_pos = result.position
			
			# Skip if underwater
			var water_dens = terrain_manager.get_water_density(Vector3(gx, hit_pos.y + 0.5, gz))
			if water_dens < 0.0:
				continue
			
			# Skip steep slopes (grass only on flat-ish terrain)
			if result.normal.y < 0.7:
				continue
			
			var local_pos = hit_pos - chunk_world_pos
			local_pos.y += grass_y_offset
			
			var world_pos = hit_pos
			world_pos.y += grass_y_offset
			
			var random_scale = randf_range(0.8, 1.2)
			var final_scale = grass_scale * random_scale
			var rotation_angle = randf() * TAU
			
			var t = grass_base_transform
			t = t.rotated(Vector3.UP, rotation_angle)
			t = t.scaled(Vector3(final_scale, final_scale, final_scale))
			t.origin = local_pos
			
			valid_transforms.append(t)
			
			var grass_index = valid_transforms.size() - 1
			grass_list.append({
				"world_pos": world_pos,
				"local_pos": local_pos,
				"hit_pos": hit_pos,
				"rotation_angle": rotation_angle,
				"index": grass_index,
				"alive": true,
				"scale": final_scale,
				"placed_by_player": false
			})
	
	if valid_transforms.size() > 0:
		mmi.multimesh.instance_count = valid_transforms.size()
		for i in range(valid_transforms.size()):
			mmi.multimesh.set_instance_transform(i, valid_transforms[i])
		chunk_node.add_child(mmi)
	
	chunk_grass_data[coord] = {
		"multimesh": mmi,
		"grass_list": grass_list,
		"chunk_node": chunk_node
	}

func harvest_grass_by_collider(collider: Node) -> bool:
	if not collider.has_meta("grass_coord"):
		return false
	
	var coord = collider.get_meta("grass_coord")
	var grass_index = collider.get_meta("grass_index")
	
	if not chunk_grass_data.has(coord):
		return false
	
	var data = chunk_grass_data[coord]
	for grass in data.grass_list:
		if grass.index == grass_index and grass.alive:
			grass.alive = false
			
			# Hide in MultiMesh
			var mmi = data.multimesh as MultiMeshInstance3D
			if mmi and mmi.multimesh:
				var t = Transform3D()
				t = t.scaled(Vector3.ZERO)
				t.origin = grass.local_pos
				mmi.multimesh.set_instance_transform(grass.index, t)
			
			# Remove collider
			var key = _grass_key(coord, grass_index)
			if active_grass_colliders.has(key):
				_return_grass_collider_to_pool(active_grass_colliders[key])
				active_grass_colliders.erase(key)
			
			grass_harvested.emit(grass.world_pos)
			return true
	
	return false

func place_grass(world_pos: Vector3) -> bool:
	# Find which chunk this position belongs to
	var chunk_stride = 31
	var coord = Vector2i(floor(world_pos.x / chunk_stride), floor(world_pos.z / chunk_stride))
	
	if not chunk_grass_data.has(coord):
		print("Cannot place grass - chunk not loaded")
		return false
	
	var data = chunk_grass_data[coord]
	var chunk_node = data.chunk_node
	if not is_instance_valid(chunk_node):
		return false
	
	var chunk_world_pos = chunk_node.global_position
	var local_pos = world_pos - chunk_world_pos
	local_pos.y += grass_y_offset
	
	var random_scale = randf_range(0.8, 1.2)
	var final_scale = grass_scale * random_scale
	var rotation_angle = randf() * TAU
	
	var t = grass_base_transform
	t = t.rotated(Vector3.UP, rotation_angle)
	t = t.scaled(Vector3(final_scale, final_scale, final_scale))
	t.origin = local_pos
	
	# Add to MultiMesh - need to expand instance count
	var mmi = data.multimesh as MultiMeshInstance3D
	if mmi and mmi.multimesh:
		var old_count = mmi.multimesh.instance_count
		mmi.multimesh.instance_count = old_count + 1
		mmi.multimesh.set_instance_transform(old_count, t)
		
		var grass_entry = {
			"world_pos": world_pos + Vector3(0, grass_y_offset, 0),
			"local_pos": local_pos,
			"hit_pos": world_pos,
			"rotation_angle": rotation_angle,
			"index": old_count,
			"alive": true,
			"scale": final_scale,
			"placed_by_player": true
		}
		data.grass_list.append(grass_entry)
		print("Placed grass at ", world_pos)
		return true
	
	return false

func load_tree_mesh_from_glb(path: String) -> Dictionary:
	var scene = load(path)
	if scene == null:
		push_error("Could not load GLB: " + path)
		return { "mesh": null, "transform": Transform3D() }
	
	var instance = scene.instantiate()
	# Need to add to tree temporarily to get global_transform
	add_child(instance)
	var result = find_mesh_and_transform_in_node(instance)
	instance.queue_free()
	
	if result.mesh:
		print("Loaded tree mesh from: ", path)
		print("Mesh transform: ", result.transform)
	
	return result

func find_mesh_and_transform_in_node(node: Node) -> Dictionary:
	if node is MeshInstance3D:
		return { "mesh": node.mesh, "transform": node.global_transform }
	
	for child in node.get_children():
		var result = find_mesh_and_transform_in_node(child)
		if result.mesh:
			return result
	
	return { "mesh": null, "transform": Transform3D() }

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

func create_basic_grass_mesh() -> Mesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var grass_mat = StandardMaterial3D.new()
	grass_mat.albedo_color = Color(0.2, 0.6, 0.1)
	grass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(grass_mat)
	
	var height = 0.5
	var width = 0.2
	
	# Simple quad for grass blade
	st.add_vertex(Vector3(-width/2, 0, 0))
	st.add_vertex(Vector3(width/2, 0, 0))
	st.add_vertex(Vector3(0, height, 0))
	
	st.index()
	return st.commit()
