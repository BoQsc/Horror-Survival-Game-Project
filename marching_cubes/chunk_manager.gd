extends Node3D

# 32 Voxels wide
const CHUNK_SIZE = 32
# Overlap chunks by 1 unit to prevent gaps (seams)
const CHUNK_STRIDE = CHUNK_SIZE - 1 
const DENSITY_GRID_SIZE = 33 # 0..32

# Max triangles estimation
const MAX_TRIANGLES = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 5

@export var viewer: Node3D
@export var render_distance: int = 5
@export var terrain_height: float = 10.0
@export var noise_frequency: float = 0.1

# Threading
var compute_thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var exit_thread: bool = false

# Task Queue
var task_queue: Array[Dictionary] = []

# Batching for synchronized updates
var modification_batch_id: int = 0
var pending_batches: Dictionary = {}

# Shaders (SPIR-V Data)
var shader_gen_spirv: RDShaderSPIRV
var shader_mod_spirv: RDShaderSPIRV
var shader_mesh_spirv: RDShaderSPIRV

var terrain_material: Material
class ChunkData:
	var node: Node3D
	var density_buffer: RID
	
var active_chunks: Dictionary = {} 

func _ready():
	mutex = Mutex.new()
	semaphore = Semaphore.new()
	
	if not viewer:
		viewer = get_tree().get_first_node_in_group("player")
		if not viewer:
			viewer = get_node_or_null("../CharacterBody3D")
	
	if viewer:
		print("Viewer found: ", viewer.name)
	else:
		print("Viewer NOT found! Terrain generation will not start.")

	# Load shaders (Data only, safe on Main Thread)
	shader_gen_spirv = load("res://marching_cubes/gen_density.glsl").get_spirv()
	shader_mod_spirv = load("res://marching_cubes/modify_density.glsl").get_spirv()
	shader_mesh_spirv = load("res://marching_cubes/marching_cubes.glsl").get_spirv()
	
	# Setup Terrain Shader Material
	var shader = load("res://marching_cubes/terrain.gdshader")
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = shader
	
	terrain_material.set_shader_parameter("texture_grass", load("res://marching_cubes/green-grass-texture.jpg"))
	terrain_material.set_shader_parameter("texture_rock", load("res://marching_cubes/rocky-texture.jpg"))
	terrain_material.set_shader_parameter("texture_sand", load("res://marching_cubes/sand-texture.jpg"))
	terrain_material.set_shader_parameter("texture_snow", load("res://marching_cubes/snow-texture.jpg"))
	terrain_material.set_shader_parameter("uv_scale", 0.5) 
	terrain_material.set_shader_parameter("global_snow_amount", 0.0)
	
	compute_thread = Thread.new()
	compute_thread.start(_thread_function)

func _process(_delta):
	if not viewer:
		return
	update_chunks()

func modify_terrain(pos: Vector3, radius: float, value: float):
	# Calculate bounds of the modification sphere
	var min_pos = pos - Vector3(radius, 0, radius)
	var max_pos = pos + Vector3(radius, 0, radius)
	
	var min_chunk_x = floor(min_pos.x / CHUNK_STRIDE)
	var max_chunk_x = floor(max_pos.x / CHUNK_STRIDE)
	var min_chunk_z = floor(min_pos.z / CHUNK_STRIDE)
	var max_chunk_z = floor(max_pos.z / CHUNK_STRIDE)
	
	var tasks_to_add = []

	for x in range(min_chunk_x, max_chunk_x + 1):
		for z in range(min_chunk_z, max_chunk_z + 1):
			var coord = Vector2i(x, z)
			
			if active_chunks.has(coord):
				var data = active_chunks[coord]
				if data != null and data.density_buffer.is_valid():
					var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, 0, coord.y * CHUNK_STRIDE)
					
					var task = {
						"type": "modify",
						"coord": coord,
						"rid": data.density_buffer,
						"pos": chunk_pos,
						"brush_pos": pos,
						"radius": radius,
						"value": value
					}
					tasks_to_add.append(task)
	
	if tasks_to_add.size() > 0:
		modification_batch_id += 1
		var batch_count = tasks_to_add.size()
		
		mutex.lock()
		for t in tasks_to_add:
			t["batch_id"] = modification_batch_id
			t["batch_count"] = batch_count
			task_queue.append(t)
		mutex.unlock()
		
		for i in range(batch_count):
			semaphore.post()

func _exit_tree():
	mutex.lock()
	exit_thread = true
	mutex.unlock()
	
	semaphore.post()
	
	if compute_thread and compute_thread.is_alive():
		compute_thread.wait_to_finish()

func update_chunks():
	var p_pos = viewer.global_position
	var p_chunk_x = floor(p_pos.x / CHUNK_STRIDE)
	var p_chunk_z = floor(p_pos.z / CHUNK_STRIDE)
	var center_chunk = Vector2i(p_chunk_x, p_chunk_z)

	# 1. Unload far chunks
	var chunks_to_remove = []
	for coord in active_chunks:
		var dist = Vector2(coord.x, coord.y).distance_to(Vector2(center_chunk.x, center_chunk.y))
		if dist > render_distance + 2:
			chunks_to_remove.append(coord)
			
	for coord in chunks_to_remove:
		mutex.lock()
		var i = task_queue.size() - 1
		while i >= 0:
			var t = task_queue[i]
			if t.type == "generate" and t.coord == coord:
				task_queue.remove_at(i)
			i -= 1
		mutex.unlock()
		
		var data = active_chunks[coord]
		if data: 
			if data.node:
				data.node.queue_free()
			
			if data.density_buffer.is_valid():
				var task = { "type": "free", "rid": data.density_buffer }
				mutex.lock()
				task_queue.append(task)
				mutex.unlock()
				semaphore.post()
		
		active_chunks.erase(coord)

	# 2. Load new chunks
	for x in range(center_chunk.x - render_distance, center_chunk.x + render_distance + 1):
		for z in range(center_chunk.y - render_distance, center_chunk.y + render_distance + 1):
			var coord = Vector2i(x, z)
			
			if active_chunks.has(coord):
				continue
			
			if Vector2(x, z).distance_to(Vector2(center_chunk.x, center_chunk.y)) > render_distance:
				continue

			active_chunks[coord] = null
			
			var chunk_pos = Vector3(x * CHUNK_STRIDE, 0, z * CHUNK_STRIDE)
			
			var task = {
				"type": "generate",
				"coord": coord,
				"pos": chunk_pos
			}
			
			mutex.lock()
			task_queue.append(task)
			mutex.unlock()
			semaphore.post()

func _thread_function():
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		return

	var sid_gen = rd.shader_create_from_spirv(shader_gen_spirv)
	var sid_mod = rd.shader_create_from_spirv(shader_mod_spirv)
	var sid_mesh = rd.shader_create_from_spirv(shader_mesh_spirv)
	
	var pipe_gen = rd.compute_pipeline_create(sid_gen)
	var pipe_mod = rd.compute_pipeline_create(sid_mod)
	var pipe_mesh = rd.compute_pipeline_create(sid_mesh)
	
	# Create REUSABLE Buffers
	var output_bytes_size = MAX_TRIANGLES * 3 * 6 * 4
	var vertex_buffer = rd.storage_buffer_create(output_bytes_size)
	
	var counter_data = PackedByteArray()
	counter_data.resize(4) 
	counter_data.encode_u32(0, 0)
	var counter_buffer = rd.storage_buffer_create(4, counter_data)
	
	while true:
		semaphore.wait()
		
		mutex.lock()
		if exit_thread:
			mutex.unlock()
			break
			
		if task_queue.is_empty():
			mutex.unlock()
			continue
			
		var task = task_queue.pop_front()
		mutex.unlock()
		
		if task.type == "generate":
			process_generate(rd, task, sid_gen, sid_mesh, pipe_gen, pipe_mesh, vertex_buffer, counter_buffer)
		elif task.type == "modify":
			process_modify(rd, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, vertex_buffer, counter_buffer)
		elif task.type == "free":
			if task.rid.is_valid():
				rd.free_rid(task.rid)
	
	# Cleanup
	rd.free_rid(vertex_buffer)
	rd.free_rid(counter_buffer)
	rd.free_rid(pipe_gen)
	rd.free_rid(pipe_mod)
	rd.free_rid(pipe_mesh)
	rd.free_rid(sid_gen)
	rd.free_rid(sid_mod)
	rd.free_rid(sid_mesh)
	
	rd.free()

func process_generate(rd: RenderingDevice, task, sid_gen, sid_mesh, pipe_gen, pipe_mesh, vertex_buffer, counter_buffer):
	var chunk_pos = task.pos
	
	var density_bytes = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4
	var density_buffer = rd.storage_buffer_create(density_bytes)
	
	var u_density = RDUniform.new()
	u_density.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density.binding = 0
	u_density.add_id(density_buffer)
	
	var set_gen = rd.uniform_set_create([u_density], sid_gen, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_gen)
	rd.compute_list_bind_uniform_set(list, set_gen, 0)
	
	var push_data = PackedFloat32Array([
		chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0, 
		noise_frequency, terrain_height, 0.0, 0.0
	])
	rd.compute_list_set_push_constant(list, push_data.to_byte_array(), push_data.size() * 4)
	
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	if set_gen.is_valid(): rd.free_rid(set_gen)
	
	var mesh = run_meshing(rd, sid_mesh, pipe_mesh, density_buffer, chunk_pos, terrain_material, vertex_buffer, counter_buffer)
	
	call_deferred("complete_generation", task.coord, mesh, density_buffer)

func process_modify(rd: RenderingDevice, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, vertex_buffer, counter_buffer):
	var density_buffer = task.rid
	var chunk_pos = task.pos
	
	var u_density = RDUniform.new()
	u_density.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density.binding = 0
	u_density.add_id(density_buffer)
	
	var set_mod = rd.uniform_set_create([u_density], sid_mod, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mod)
	rd.compute_list_bind_uniform_set(list, set_mod, 0)
	
	var push_data = PackedFloat32Array([
		chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0,
		task.brush_pos.x, task.brush_pos.y, task.brush_pos.z, task.radius,
		task.value, 0.0, 0.0, 0.0
	])
	rd.compute_list_set_push_constant(list, push_data.to_byte_array(), push_data.size() * 4)
	
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	if set_mod.is_valid(): rd.free_rid(set_mod)
	
	var mesh = run_meshing(rd, sid_mesh, pipe_mesh, density_buffer, chunk_pos, terrain_material, vertex_buffer, counter_buffer)
	
	var b_id = task.get("batch_id", -1)
	var b_count = task.get("batch_count", 1)
	
	call_deferred("complete_modification", task.coord, mesh, b_id, b_count)

func build_mesh(data: PackedFloat32Array, material_instance: Material) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	st.set_material(material_instance)
	
	for i in range(0, data.size(), 6):
		var v = Vector3(data[i], data[i+1], data[i+2])
		var n = Vector3(data[i+3], data[i+4], data[i+5])
		st.set_normal(n)
		st.add_vertex(v)
	
	return st.commit()

func run_meshing(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, chunk_pos, material_instance: Material, vertex_buffer, counter_buffer):
	# Reset Counter to 0
	var zero_data = PackedByteArray()
	zero_data.resize(4)
	zero_data.encode_u32(0, 0)
	rd.buffer_update(counter_buffer, 0, 4, zero_data)
	
	var u_vert = RDUniform.new()
	u_vert.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_vert.binding = 0
	u_vert.add_id(vertex_buffer)
	
	var u_count = RDUniform.new()
	u_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_count.binding = 1
	u_count.add_id(counter_buffer)
	
	var u_dens = RDUniform.new()
	u_dens.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_dens.binding = 2
	u_dens.add_id(density_buffer)
	
	var set_mesh = rd.uniform_set_create([u_vert, u_count, u_dens], sid_mesh, 0)
	
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mesh)
	rd.compute_list_bind_uniform_set(list, set_mesh, 0)
	
	var push_data = PackedFloat32Array([
		chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0, 
		noise_frequency, terrain_height, 0.0, 0.0
	])
	rd.compute_list_set_push_constant(list, push_data.to_byte_array(), push_data.size() * 4)
	
	var groups = CHUNK_SIZE / 8
	rd.compute_list_dispatch(list, groups, groups, groups)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	# Read back
	var count_bytes = rd.buffer_get_data(counter_buffer)
	var tri_count = count_bytes.decode_u32(0)
	
	var mesh = null
	if tri_count > 0:
		var total_floats = tri_count * 3 * 6
		var vert_bytes = rd.buffer_get_data(vertex_buffer, 0, total_floats * 4)
		var vert_floats = vert_bytes.to_float32_array()
		mesh = build_mesh(vert_floats, material_instance)
		
	# Only free the uniform set (linking logic)
	if set_mesh.is_valid(): rd.free_rid(set_mesh)
	
	return mesh

func complete_generation(coord: Vector2i, mesh: ArrayMesh, density_buffer: RID):
	# If we were cancelled/removed while generating
	if not active_chunks.has(coord):
		# Queue free immediately
		var task = { "type": "free", "rid": density_buffer }
		mutex.lock()
		task_queue.append(task)
		mutex.unlock()
		semaphore.post()
		return
		
	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, 0, coord.y * CHUNK_STRIDE)
	var node = create_chunk_node(mesh, chunk_pos)
	
	var data = ChunkData.new()
	data.node = node
	data.density_buffer = density_buffer
	
	active_chunks[coord] = data

func complete_modification(coord: Vector2i, mesh: ArrayMesh, batch_id: int = -1, batch_count: int = 1):
	if batch_id == -1:
		_apply_chunk_update(coord, mesh)
		return
	
	if not pending_batches.has(batch_id):
		pending_batches[batch_id] = { "received": 0, "expected": batch_count, "updates": [] }
	
	var batch = pending_batches[batch_id]
	batch.received += 1
	
	# Store update only if chunk is still relevant
	if active_chunks.has(coord):
		batch.updates.append({ "coord": coord, "mesh": mesh })
		
	if batch.received >= batch.expected:
		for update in batch.updates:
			_apply_chunk_update(update.coord, update.mesh)
		pending_batches.erase(batch_id)

func _apply_chunk_update(coord: Vector2i, mesh: ArrayMesh):
	if not active_chunks.has(coord):
		return
	
	var data = active_chunks[coord]
	# Update mesh
	if data.node:
		data.node.queue_free()
		
	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, 0, coord.y * CHUNK_STRIDE)
	data.node = create_chunk_node(mesh, chunk_pos)

func create_chunk_node(mesh: ArrayMesh, position: Vector3) -> Node3D:
	if mesh == null:
		return null
		
	var static_body = StaticBody3D.new()
	static_body.position = position
	add_child(static_body)
	
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = mesh
	static_body.add_child(mesh_instance)
	
	var collision_shape = CollisionShape3D.new()
	collision_shape.shape = mesh.create_trimesh_shape()
	static_body.add_child(collision_shape)
	
	return static_body
