extends Node3D

signal chunk_generated(coord: Vector2i, chunk_node: Node3D)

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
@export var water_level: float = 14.0 # Raised for surface lakes
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
var shader_gen_water_spirv: RDShaderSPIRV # New
var shader_mod_spirv: RDShaderSPIRV
var shader_mesh_spirv: RDShaderSPIRV

var material_terrain: Material
var material_water: Material

class ChunkData:
	var node_terrain: Node3D
	var node_water: Node3D
	var density_buffer_terrain: RID
	var density_buffer_water: RID
	# CPU mirrors for physics detection
	var cpu_density_water: PackedFloat32Array = PackedFloat32Array()
	var cpu_density_terrain: PackedFloat32Array = PackedFloat32Array()

var active_chunks: Dictionary = {}

# Time-budgeted node creation - prevents stutters from multiple chunks completing at once
var pending_nodes: Array[Dictionary] = []  # Queue of completed chunks waiting for node creation
var pending_nodes_mutex: Mutex
var frame_budget_ms: float = 1.0  # Max ms to spend on node creation per frame 

func _ready():
	mutex = Mutex.new()
	semaphore = Semaphore.new()
	pending_nodes_mutex = Mutex.new()
	
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
	shader_gen_water_spirv = load("res://marching_cubes/gen_water_density.glsl").get_spirv() # New
	shader_mod_spirv = load("res://marching_cubes/modify_density.glsl").get_spirv()
	shader_mesh_spirv = load("res://marching_cubes/marching_cubes.glsl").get_spirv()
	
	# Setup Terrain Shader Material
	var shader = load("res://marching_cubes/terrain.gdshader")
	material_terrain = ShaderMaterial.new()
	material_terrain.shader = shader
	
	material_terrain.set_shader_parameter("texture_grass", load("res://marching_cubes/green-grass-texture.jpg"))
	material_terrain.set_shader_parameter("texture_rock", load("res://marching_cubes/rocky-texture.jpg"))
	material_terrain.set_shader_parameter("texture_sand", load("res://marching_cubes/sand-texture.jpg"))
	material_terrain.set_shader_parameter("uv_scale", 0.5) 
	material_terrain.set_shader_parameter("global_snow_amount", 0.0)
	
	# Setup Water Material
	material_water = ShaderMaterial.new()
	material_water.shader = load("res://marching_cubes/water.gdshader")
	material_water.set_shader_parameter("albedo", Color(0.0, 0.3, 0.8))
	material_water.set_shader_parameter("albedo_deep", Color(0.0, 0.1, 0.2))
	material_water.set_shader_parameter("beer_factor", 0.15)
	material_water.set_shader_parameter("foam_level", 0.8)
	
	compute_thread = Thread.new()
	compute_thread.start(_thread_function)

func _process(_delta):
	if not viewer:
		return
	update_chunks()
	process_pending_nodes()  # Time-budgeted node creation

# Process pending node creations within frame budget
func process_pending_nodes():
	if pending_nodes.is_empty():
		return
	
	var start_time = Time.get_ticks_usec()
	var budget_usec = frame_budget_ms * 1000.0
	
	while not pending_nodes.is_empty():
		# Check time budget
		var elapsed = Time.get_ticks_usec() - start_time
		if elapsed >= budget_usec:
			break  # Out of time, continue next frame
		
		# Get next pending chunk
		pending_nodes_mutex.lock()
		if pending_nodes.is_empty():
			pending_nodes_mutex.unlock()
			break
		var item = pending_nodes.pop_front()
		pending_nodes_mutex.unlock()
		
		# Create the nodes
		_finalize_chunk_creation(item)

func get_water_density(global_pos: Vector3) -> float:
	# 1. Find Chunk
	var x = floor(global_pos.x / CHUNK_STRIDE)
	var z = floor(global_pos.z / CHUNK_STRIDE)
	var coord = Vector2i(x, z)
	
	if not active_chunks.has(coord):
		return 1.0 # Air (Positive is air, Negative is water)
		
	var data = active_chunks[coord]
	if data == null or data.cpu_density_water.is_empty():
		return 1.0
		
	# 2. Find local position
	var chunk_origin = Vector3(x * CHUNK_STRIDE, 0, z * CHUNK_STRIDE)
	var local_pos = global_pos - chunk_origin
	
	# Clamp to grid
	var ix = round(local_pos.x)
	var iy = round(local_pos.y)
	var iz = round(local_pos.z)
	
	if ix < 0 or ix >= DENSITY_GRID_SIZE or iy < 0 or iy >= DENSITY_GRID_SIZE or iz < 0 or iz >= DENSITY_GRID_SIZE:
		return 1.0 # Out of bounds
		
	var index = int(ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE))
	
	if index >= 0 and index < data.cpu_density_water.size():
		return data.cpu_density_water[index]
		
	return 1.0

func get_terrain_height(global_x: float, global_z: float) -> float:
	# 1. Find Chunk
	var x = floor(global_x / CHUNK_STRIDE)
	var z = floor(global_z / CHUNK_STRIDE)
	var coord = Vector2i(x, z)
	
	if not active_chunks.has(coord):
		return -1000.0 # No chunk
		
	var data = active_chunks[coord]
	if data == null or data.cpu_density_terrain.is_empty():
		return -1000.0
		
	# 2. Find local X, Z
	var chunk_origin = Vector3(x * CHUNK_STRIDE, 0, z * CHUNK_STRIDE)
	var local_x = round(global_x - chunk_origin.x)
	var local_z = round(global_z - chunk_origin.z)
	
	if local_x < 0 or local_x >= DENSITY_GRID_SIZE or local_z < 0 or local_z >= DENSITY_GRID_SIZE:
		return -1000.0
		
	# 3. Scan Y column from top (32) to bottom (0)
	# We look for transition from Air (>0) to Ground (<0)
	var ix = int(local_x)
	var iz = int(local_z)
	
	var prev_density = 1.0  # Assume air above the grid
	for iy in range(DENSITY_GRID_SIZE - 1, -1, -1):
		var index = ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
		var density = data.cpu_density_terrain[index]
		
		if density < 0.0:
			# Found ground! Interpolate for accurate isosurface height.
			# The surface is where density = 0, between iy (ground) and iy+1 (air)
			# Linear interpolation: t = prev_density / (prev_density - density)
			# Height = (iy + 1) - t = iy + 1 - prev_density / (prev_density - density)
			if iy < DENSITY_GRID_SIZE - 1:
				var t = prev_density / (prev_density - density)
				return float(iy + 1) - t
			else:
				return float(iy)
		prev_density = density
			
	return -1000.0 # Only air found (hole)

# Updated to accept layer (0=Terrain, 1=Water)
func modify_terrain(pos: Vector3, radius: float, value: float, shape: int = 0, layer: int = 0):
	# Calculate bounds of the modification sphere/box
	var min_pos = pos - Vector3(radius, radius, radius)
	var max_pos = pos + Vector3(radius, radius, radius)
	
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
				if data != null:
					var target_buffer = data.density_buffer_terrain if layer == 0 else data.density_buffer_water
					
					if target_buffer.is_valid():
						var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, 0, coord.y * CHUNK_STRIDE)
						
						var task = {
							"type": "modify",
							"coord": coord,
							"rid": target_buffer,
							"pos": chunk_pos,
							"brush_pos": pos,
							"radius": radius,
							"value": value,
							"shape": shape,
							"layer": layer # Pass layer info
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
			if data.node_terrain: data.node_terrain.queue_free()
			if data.node_water: data.node_water.queue_free()
			
			var tasks = []
			if data.density_buffer_terrain.is_valid():
				tasks.append({ "type": "free", "rid": data.density_buffer_terrain })
			if data.density_buffer_water.is_valid():
				tasks.append({ "type": "free", "rid": data.density_buffer_water })
				
			mutex.lock()
			for t in tasks: task_queue.append(t)
			mutex.unlock()
			
			for t in tasks: semaphore.post()
		
		active_chunks.erase(coord)

	# 2. Load new chunks (rate limited to prevent stutters)
	var chunks_queued_this_frame = 0
	var max_chunks_per_frame = 2  # Limit to reduce stuttering
	
	for x in range(center_chunk.x - render_distance, center_chunk.x + render_distance + 1):
		for z in range(center_chunk.y - render_distance, center_chunk.y + render_distance + 1):
			if chunks_queued_this_frame >= max_chunks_per_frame:
				return  # Stop for this frame, continue next frame
			
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
			
			chunks_queued_this_frame += 1

func _thread_function():
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		return

	var sid_gen = rd.shader_create_from_spirv(shader_gen_spirv)
	var sid_gen_water = rd.shader_create_from_spirv(shader_gen_water_spirv)
	var sid_mod = rd.shader_create_from_spirv(shader_mod_spirv)
	var sid_mesh = rd.shader_create_from_spirv(shader_mesh_spirv)
	
	var pipe_gen = rd.compute_pipeline_create(sid_gen)
	var pipe_gen_water = rd.compute_pipeline_create(sid_gen_water)
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
			process_generate(rd, task, sid_gen, sid_gen_water, sid_mesh, pipe_gen, pipe_gen_water, pipe_mesh, vertex_buffer, counter_buffer)
		elif task.type == "modify":
			process_modify(rd, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, vertex_buffer, counter_buffer)
		elif task.type == "free":
			if task.rid.is_valid():
				rd.free_rid(task.rid)
	
	# Cleanup
	rd.free_rid(vertex_buffer)
	rd.free_rid(counter_buffer)
	rd.free_rid(pipe_gen)
	rd.free_rid(pipe_gen_water)
	rd.free_rid(pipe_mod)
	rd.free_rid(pipe_mesh)
	rd.free_rid(sid_gen)
	rd.free_rid(sid_gen_water)
	rd.free_rid(sid_mod)
	rd.free_rid(sid_mesh)
	
	rd.free()

func process_generate(rd: RenderingDevice, task, sid_gen, sid_gen_water, sid_mesh, pipe_gen, pipe_gen_water, pipe_mesh, vertex_buffer, counter_buffer):
	var chunk_pos = task.pos
	var density_bytes = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4
	
	# 1. Terrain Generation
	var dens_buf_terrain = rd.storage_buffer_create(density_bytes)
	var u_density_t = RDUniform.new()
	u_density_t.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density_t.binding = 0
	u_density_t.add_id(dens_buf_terrain)
	
	var set_gen_t = rd.uniform_set_create([u_density_t], sid_gen, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_gen)
	rd.compute_list_bind_uniform_set(list, set_gen_t, 0)
	var push_data_t = PackedFloat32Array([chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0, noise_frequency, terrain_height, 0.0, 0.0])
	rd.compute_list_set_push_constant(list, push_data_t.to_byte_array(), push_data_t.size() * 4)
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	if set_gen_t.is_valid(): rd.free_rid(set_gen_t)

	var mesh_terrain_result = run_meshing(rd, sid_mesh, pipe_mesh, dens_buf_terrain, chunk_pos, material_terrain, vertex_buffer, counter_buffer)

	# 2. Water Generation
	var dens_buf_water = rd.storage_buffer_create(density_bytes)
	var u_density_w = RDUniform.new()
	u_density_w.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density_w.binding = 0
	u_density_w.add_id(dens_buf_water)
	
	var set_gen_w = rd.uniform_set_create([u_density_w], sid_gen_water, 0)
	list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_gen_water)
	rd.compute_list_bind_uniform_set(list, set_gen_w, 0)
	# Reuse push constant structure but pass water_level as terrain_height
	var push_data_w = PackedFloat32Array([chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0, noise_frequency, water_level, 0.0, 0.0])
	rd.compute_list_set_push_constant(list, push_data_w.to_byte_array(), push_data_w.size() * 4)
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	if set_gen_w.is_valid(): rd.free_rid(set_gen_w)
	
	var mesh_water_result = run_meshing(rd, sid_mesh, pipe_mesh, dens_buf_water, chunk_pos, material_water, vertex_buffer, counter_buffer)

	# Readback Water Density for Physics (CPU)
	var cpu_density_bytes_w = rd.buffer_get_data(dens_buf_water)
	var cpu_density_floats_w = cpu_density_bytes_w.to_float32_array()
	
	# Readback Terrain Density for Vegetation/Physics (CPU)
	var cpu_density_bytes_t = rd.buffer_get_data(dens_buf_terrain)
	var cpu_density_floats_t = cpu_density_bytes_t.to_float32_array()

	call_deferred("complete_generation", task.coord, mesh_terrain_result, dens_buf_terrain, mesh_water_result, dens_buf_water, cpu_density_floats_w, cpu_density_floats_t)

func process_modify(rd: RenderingDevice, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, vertex_buffer, counter_buffer):
	var density_buffer = task.rid
	var chunk_pos = task.pos
	var layer = task.get("layer", 0)
	
	var u_density = RDUniform.new()
	u_density.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density.binding = 0
	u_density.add_id(density_buffer)
	
	var set_mod = rd.uniform_set_create([u_density], sid_mod, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mod)
	rd.compute_list_bind_uniform_set(list, set_mod, 0)
	
	var push_data = PackedByteArray()
	push_data.resize(48)
	var buffer = StreamPeerBuffer.new()
	buffer.data_array = push_data
	
	buffer.put_float(chunk_pos.x)
	buffer.put_float(chunk_pos.y)
	buffer.put_float(chunk_pos.z)
	buffer.put_float(0.0)
	
	buffer.put_float(task.brush_pos.x)
	buffer.put_float(task.brush_pos.y)
	buffer.put_float(task.brush_pos.z)
	buffer.put_float(task.radius)
	
	buffer.put_float(task.value)
	buffer.put_32(task.get("shape", 0))
	buffer.put_float(0.0)
	buffer.put_float(0.0)
	
	rd.compute_list_set_push_constant(list, buffer.data_array, buffer.data_array.size())
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	if set_mod.is_valid(): rd.free_rid(set_mod)
	
	var material = material_terrain if layer == 0 else material_water
	var result = run_meshing(rd, sid_mesh, pipe_mesh, density_buffer, chunk_pos, material, vertex_buffer, counter_buffer)
	
	var cpu_density_floats = PackedFloat32Array()
	# Read back density for this layer
	var cpu_density_bytes = rd.buffer_get_data(density_buffer)
	cpu_density_floats = cpu_density_bytes.to_float32_array()
	
	var b_id = task.get("batch_id", -1)
	var b_count = task.get("batch_count", 1)
	
	call_deferred("complete_modification", task.coord, result, layer, b_id, b_count, cpu_density_floats)

func build_mesh(data: PackedFloat32Array, material_instance: Material) -> ArrayMesh:
	if data.size() == 0:
		return null
	
	var vertex_count = data.size() / 6
	
	# Pre-allocate arrays
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	
	# Fill arrays directly (much faster than SurfaceTool)
	for i in range(vertex_count):
		var idx = i * 6
		vertices[i] = Vector3(data[idx], data[idx + 1], data[idx + 2])
		normals[i] = Vector3(data[idx + 3], data[idx + 4], data[idx + 5])
	
	# Build ArrayMesh directly
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material_instance)
	
	return mesh

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
	var shape = null
	
	if tri_count > 0:
		var total_floats = tri_count * 3 * 6
		var vert_bytes = rd.buffer_get_data(vertex_buffer, 0, total_floats * 4)
		var vert_floats = vert_bytes.to_float32_array()
		mesh = build_mesh(vert_floats, material_instance)
		if mesh:
			shape = mesh.create_trimesh_shape()
		
	if set_mesh.is_valid(): rd.free_rid(set_mesh)
	
	return { "mesh": mesh, "shape": shape }

func complete_generation(coord: Vector2i, result_t: Dictionary, dens_t: RID, result_w: Dictionary, dens_w: RID, cpu_dens_w: PackedFloat32Array, cpu_dens_t: PackedFloat32Array):
	if not active_chunks.has(coord):
		var tasks = []
		tasks.append({ "type": "free", "rid": dens_t })
		tasks.append({ "type": "free", "rid": dens_w })
		mutex.lock()
		for t in tasks: task_queue.append(t)
		mutex.unlock()
		for t in tasks: semaphore.post()
		return
	
	# Queue for time-budgeted node creation instead of immediate creation
	pending_nodes_mutex.lock()
	pending_nodes.append({
		"type": "generation",
		"coord": coord,
		"result_t": result_t,
		"result_w": result_w,
		"dens_t": dens_t,
		"dens_w": dens_w,
		"cpu_dens_w": cpu_dens_w,
		"cpu_dens_t": cpu_dens_t
	})
	pending_nodes_mutex.unlock()

func _finalize_chunk_creation(item: Dictionary):
	if item.type == "generation":
		var coord = item.coord
		
		# Check if chunk is still wanted
		if not active_chunks.has(coord):
			# Free the density buffers
			var tasks = []
			tasks.append({ "type": "free", "rid": item.dens_t })
			tasks.append({ "type": "free", "rid": item.dens_w })
			mutex.lock()
			for t in tasks: task_queue.append(t)
			mutex.unlock()
			for t in tasks: semaphore.post()
			return
		
		var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, 0, coord.y * CHUNK_STRIDE)
		
		var node_t = create_chunk_node(item.result_t.mesh, item.result_t.shape, chunk_pos)
		var node_w = create_chunk_node(item.result_w.mesh, item.result_w.shape, chunk_pos, true)
		
		var data = ChunkData.new()
		data.node_terrain = node_t
		data.node_water = node_w
		data.density_buffer_terrain = item.dens_t
		data.density_buffer_water = item.dens_w
		data.cpu_density_water = item.cpu_dens_w
		data.cpu_density_terrain = item.cpu_dens_t
		
		active_chunks[coord] = data
		
		chunk_generated.emit(coord, node_t)

func complete_modification(coord: Vector2i, result: Dictionary, layer: int, batch_id: int = -1, batch_count: int = 1, cpu_dens: PackedFloat32Array = PackedFloat32Array()):
	if batch_id == -1:
		_apply_chunk_update(coord, result, layer, cpu_dens)
		return
	
	if not pending_batches.has(batch_id):
		pending_batches[batch_id] = { "received": 0, "expected": batch_count, "updates": [] }
	
	var batch = pending_batches[batch_id]
	batch.received += 1
	
	if active_chunks.has(coord):
		batch.updates.append({ "coord": coord, "result": result, "layer": layer, "cpu_dens": cpu_dens })
		
	if batch.received >= batch.expected:
		for update in batch.updates:
			_apply_chunk_update(update.coord, update.result, update.layer, update.cpu_dens)
		pending_batches.erase(batch_id)

func _apply_chunk_update(coord: Vector2i, result: Dictionary, layer: int, cpu_dens: PackedFloat32Array):
	if not active_chunks.has(coord):
		return
	var data = active_chunks[coord]
	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, 0, coord.y * CHUNK_STRIDE)
	
	if layer == 0: # Terrain
		if data.node_terrain: data.node_terrain.queue_free()
		data.node_terrain = create_chunk_node(result.mesh, result.shape, chunk_pos)
		if not cpu_dens.is_empty():
			data.cpu_density_terrain = cpu_dens
	else: # Water
		if data.node_water: data.node_water.queue_free()
		data.node_water = create_chunk_node(result.mesh, result.shape, chunk_pos, true)
		if not cpu_dens.is_empty():
			data.cpu_density_water = cpu_dens

func create_chunk_node(mesh: ArrayMesh, shape: Shape3D, position: Vector3, is_water: bool = false) -> Node3D:
	if mesh == null:
		return null
		
	var node: CollisionObject3D
	
	if is_water:
		node = Area3D.new()
		node.add_to_group("water")
		# Ensure it's monitorable so the player can detect it
		node.monitorable = true
		node.monitoring = false # Terrain chunks don't need to monitor others
	else:
		node = StaticBody3D.new()
		node.add_to_group("terrain")
		
	node.position = position
	add_child(node)
	
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = mesh
	# If water, we might want to ensure it's not casting shadows or has specific render flags if needed, 
	# but the material handles most transparency.
	if is_water:
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		
	node.add_child(mesh_instance)
	
	var collision_shape = CollisionShape3D.new()
	# Use the pre-baked shape!
	collision_shape.shape = shape
	node.add_child(collision_shape)
	
	return node
