extends Node3D

# 32 Voxels wide
const CHUNK_SIZE = 32
# Overlap chunks by 1 unit to prevent gaps (seams)
const CHUNK_STRIDE = CHUNK_SIZE - 1 

# Max triangles estimation
const MAX_TRIANGLES = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 5

@export var viewer: Node3D
@export var render_distance: int = 5
@export var terrain_height: float = 10.0
@export var noise_frequency: float = 0.1

# Threading
var threads: Array[Thread] = []
var mutex: Mutex
var semaphore: Semaphore
var exit_thread: bool = false
var chunk_queue: Array[Vector3] = []
var shader_spirv: RDShaderSPIRV

@export var thread_count: int = 1

# Chunk Management
var active_chunks: Dictionary = {} # Vector2i -> Node3D (or null if loading)

func _ready():
	mutex = Mutex.new()
	semaphore = Semaphore.new()
	
	if not viewer:
		viewer = get_tree().get_first_node_in_group("player")
		if not viewer:
			# Fallback: try to find a CharacterBody3D sibling or parent
			viewer = get_node_or_null("../CharacterBody3D")

	# Load shader resource once on main thread to pass data to the thread
	var shader_file = load("res://marching_cubes.glsl")
	shader_spirv = shader_file.get_spirv()
	
	# Create and start threads
	for i in range(thread_count):
		var t = Thread.new()
		t.start(_thread_function)
		threads.append(t)

func _process(_delta):
	if not viewer:
		return
	update_chunks()

func _exit_tree():
	mutex.lock()
	exit_thread = true
	mutex.unlock()
	
	# Wake up all threads so they can exit
	for i in range(threads.size()):
		semaphore.post()
	
	# Wait for all threads to finish
	for t in threads:
		t.wait_to_finish()

func update_chunks():
	var p_pos = viewer.global_position
	var p_chunk_x = floor(p_pos.x / CHUNK_STRIDE)
	var p_chunk_z = floor(p_pos.z / CHUNK_STRIDE)
	var center_chunk = Vector2i(p_chunk_x, p_chunk_z)

	# 1. Unload far chunks
	var chunks_to_remove = []
	for coord in active_chunks:
		var dist = Vector2(coord.x, coord.y).distance_to(Vector2(center_chunk.x, center_chunk.y))
		if dist > render_distance + 2: # Add a small buffer to prevent flickering
			chunks_to_remove.append(coord)
			
	for coord in chunks_to_remove:
		var node = active_chunks[coord]
		if node:
			node.queue_free()
		active_chunks.erase(coord)

	# 2. Load new chunks
	for x in range(center_chunk.x - render_distance, center_chunk.x + render_distance + 1):
		for z in range(center_chunk.y - render_distance, center_chunk.y + render_distance + 1):
			var coord = Vector2i(x, z)
			
			if active_chunks.has(coord):
				continue
			
			# Check circular distance
			if Vector2(x, z).distance_to(Vector2(center_chunk.x, center_chunk.y)) > render_distance:
				continue

			# Mark as loading (null placeholder)
			active_chunks[coord] = null
			
			# Calculate World Position for this chunk
			var chunk_pos = Vector3(x * CHUNK_STRIDE, 0, z * CHUNK_STRIDE)
			
			mutex.lock()
			chunk_queue.append(chunk_pos)
			mutex.unlock()
			semaphore.post()

func _thread_function():
	# Create a local RenderingDevice on this thread
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		return
		
	var shader_rid = rd.shader_create_from_spirv(shader_spirv)
	
	while true:
		semaphore.wait()
		
		mutex.lock()
		if exit_thread:
			mutex.unlock()
			break
			
		if chunk_queue.is_empty():
			mutex.unlock()
			continue
			
		var chunk_pos = chunk_queue.pop_front()
		mutex.unlock()
		
		generate_chunk_on_thread(rd, shader_rid, chunk_pos)
		
	# Cleanup
	rd.free()

func generate_chunk_on_thread(rd: RenderingDevice, shader_rid: RID, offset: Vector3):
	# 1. Setup Buffers
	# We now output Position (3 floats) + Normal (3 floats) = 6 floats per vertex
	var output_bytes_size = MAX_TRIANGLES * 3 * 6 * 4
	var vertex_buffer = rd.storage_buffer_create(output_bytes_size)
	var vertex_uniform = RDUniform.new()
	vertex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	vertex_uniform.binding = 0
	vertex_uniform.add_id(vertex_buffer)
	
	var counter_data = PackedByteArray()
	counter_data.resize(4) 
	counter_data.encode_u32(0, 0)
	var counter_buffer = rd.storage_buffer_create(4, counter_data)
	var counter_uniform = RDUniform.new()
	counter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counter_uniform.binding = 1
	counter_uniform.add_id(counter_buffer)
	
	# 2. Pipeline & Push Constants
	var uniform_set = rd.uniform_set_create([vertex_uniform, counter_uniform], shader_rid, 0)
	var pipeline = rd.compute_pipeline_create(shader_rid)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# Send Push Constants (Offset + Noise Params)
	var push_data = PackedFloat32Array([
		offset.x, offset.y, offset.z, 0.0, 
		noise_frequency, terrain_height,
		0.0, 0.0 # Padding to reach 32 bytes (8 floats)
	])
	var push_bytes = push_data.to_byte_array()
	rd.compute_list_set_push_constant(compute_list, push_bytes, push_bytes.size())
	
	var groups = CHUNK_SIZE / 8
	rd.compute_list_dispatch(compute_list, groups, groups, groups)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	# 3. Read & Build
	var count_output_bytes = rd.buffer_get_data(counter_buffer)
	var triangle_count = count_output_bytes.decode_u32(0)
	
	if triangle_count > 0:
		# 3 vertices per triangle * 6 floats per vertex (pos+normal)
		var total_floats = triangle_count * 3 * 6
		var vertices_bytes = rd.buffer_get_data(vertex_buffer, 0, total_floats * 4)
		var vertices_floats = vertices_bytes.to_float32_array()
		
		var mesh = build_mesh(vertices_floats)
		call_deferred("add_mesh_to_scene", mesh, offset)
	else:
		# Even if empty, we should "load" it (as null or empty node) so we don't retry
		call_deferred("add_empty_chunk", offset)
	
	# Cleanup
	rd.free_rid(vertex_buffer)
	rd.free_rid(counter_buffer)

func build_mesh(data: PackedFloat32Array) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.7, 0.3)
	st.set_material(mat)
	
	# Data stride is 6: px, py, pz, nx, ny, nz
	for i in range(0, data.size(), 6):
		var v = Vector3(data[i], data[i+1], data[i+2])
		var n = Vector3(data[i+3], data[i+4], data[i+5])
		
		st.set_normal(n)
		st.add_vertex(v)
	
	return st.commit()

func add_mesh_to_scene(mesh: ArrayMesh, position: Vector3):
	var chunk_x = round(position.x / CHUNK_STRIDE)
	var chunk_z = round(position.z / CHUNK_STRIDE)
	var coord = Vector2i(chunk_x, chunk_z)
	
	# Check if we still want this chunk
	if not active_chunks.has(coord):
		return
	
	# Create a StaticBody3D to hold both the mesh and collision
	var static_body = StaticBody3D.new()
	static_body.position = position
	add_child(static_body)
	
	# Visual Mesh
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = mesh
	static_body.add_child(mesh_instance)
	
	# Collision
	var collision_shape = CollisionShape3D.new()
	collision_shape.shape = mesh.create_trimesh_shape()
	static_body.add_child(collision_shape)
	
	active_chunks[coord] = static_body

func add_empty_chunk(position: Vector3):
	var chunk_x = round(position.x / CHUNK_STRIDE)
	var chunk_z = round(position.z / CHUNK_STRIDE)
	var coord = Vector2i(chunk_x, chunk_z)
	
	if active_chunks.has(coord):
		# Mark as loaded but empty (could use a dummy node or just keep it null/flagged)
		# To keep logic simple, let's just make sure we don't re-queue it.
		# active_chunks[coord] is already null (from queueing), which means "loading/loaded".
		# But we need to distinguish "loading" from "loaded empty" if we were strict,
		# but here 'null' effectively means "don't queue again". 
		# However, the cleanup loop checks `if node: node.queue_free()`. 
		# If we leave it null, it won't be freed, but it will be erased from dict.
		# That works.
		pass
