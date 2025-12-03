extends Node
class_name BuildingMesher

var thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var exit_thread: bool = false

var queue: Array = [] # Array of BuildingChunk
var compute_shader: RDShaderFile

func _init():
	mutex = Mutex.new()
	semaphore = Semaphore.new()
	
	compute_shader = load("res://greedy_meshing/greedy_meshing.glsl")
	
	thread = Thread.new()
	thread.start(_thread_loop)

func request_mesh_generation(chunk: BuildingChunk):
	mutex.lock()
	if not queue.has(chunk):
		queue.append(chunk)
	mutex.unlock()
	semaphore.post()

func _thread_loop():
	var rd = RenderingServer.create_local_rendering_device()
	if not rd: return
	
	var shader_spirv = compute_shader.get_spirv()
	var shader = rd.shader_create_from_spirv(shader_spirv)
	var pipeline = rd.compute_pipeline_create(shader)
	
	while true:
		semaphore.wait()
		
		mutex.lock()
		if exit_thread:
			mutex.unlock()
			break
			
		if queue.is_empty():
			mutex.unlock()
			continue
			
		var chunk = queue.pop_front()
		# IMPORTANT: Copy data inside lock to ensure thread safety
		if not is_instance_valid(chunk): 
			mutex.unlock()
			continue
			
		var voxel_bytes = chunk.voxel_bytes.duplicate()
		mutex.unlock()
		
		# Generate
		var arrays = _generate_mesh(rd, shader, pipeline, voxel_bytes)
		
		# Callback
		if is_instance_valid(chunk):
			chunk.call_deferred("apply_mesh", arrays)
	
	rd.free()

func _generate_mesh(rd: RenderingDevice, shader: RID, pipeline: RID, v_bytes: PackedByteArray) -> Array:
	# 16x16x16
	var grid_size = Vector3i(16, 16, 16)
	
	# Texture
	var fmt = RDTextureFormat.new()
	fmt.width = grid_size.x
	fmt.height = grid_size.y
	fmt.depth = grid_size.z
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	var texture_rid = rd.texture_create(fmt, RDTextureView.new(), [v_bytes])
	
	# Buffers
	var max_vertices = grid_size.x * grid_size.y * grid_size.z * 24
	var max_indices = max_vertices * 2
	
	var vertex_buffer = rd.storage_buffer_create(max_vertices * 12)
	var normal_buffer = rd.storage_buffer_create(max_vertices * 12)
	var uv_buffer = rd.storage_buffer_create(max_vertices * 8)
	var index_buffer = rd.storage_buffer_create(max_indices * 4)
	
	var counter_data = PackedByteArray()
	counter_data.resize(4)
	counter_data.encode_u32(0, 0)
	var counter_buffer = rd.storage_buffer_create(4, counter_data)
	
	# Uniforms
	var uniforms = []
	
	var u_voxel = RDUniform.new()
	u_voxel.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_voxel.binding = 0
	var sampler_state = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	var sampler_rid = rd.sampler_create(sampler_state)
	u_voxel.add_id(sampler_rid)
	u_voxel.add_id(texture_rid)
	uniforms.append(u_voxel)
	
	var u_vertex = RDUniform.new()
	u_vertex.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_vertex.binding = 1
	u_vertex.add_id(vertex_buffer)
	uniforms.append(u_vertex)
	
	var u_normal = RDUniform.new()
	u_normal.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_normal.binding = 2
	u_normal.add_id(normal_buffer)
	uniforms.append(u_normal)
	
	var u_uv = RDUniform.new()
	u_uv.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_uv.binding = 3
	u_uv.add_id(uv_buffer)
	uniforms.append(u_uv)
	
	var u_index = RDUniform.new()
	u_index.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_index.binding = 4
	u_index.add_id(index_buffer)
	uniforms.append(u_index)
	
	var u_counter = RDUniform.new()
	u_counter.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_counter.binding = 5
	u_counter.add_id(counter_buffer)
	uniforms.append(u_counter)
	
	var uniform_set = rd.uniform_set_create(uniforms, shader, 0)
	
	# Dispatch
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	var push_constants = PackedInt32Array([grid_size.x, grid_size.y, grid_size.z, 0])
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
	
	rd.compute_list_dispatch(compute_list, 4, 4, 4) # 16/4 = 4
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	# Read
	var counter_bytes = rd.buffer_get_data(counter_buffer)
	var actual_vertex_count = counter_bytes.decode_u32(0)
	
	var arrays = []
	
	if actual_vertex_count > 0:
		var vertex_bytes = rd.buffer_get_data(vertex_buffer, 0, actual_vertex_count * 12)
		var normal_bytes = rd.buffer_get_data(normal_buffer, 0, actual_vertex_count * 12)
		var uv_bytes = rd.buffer_get_data(uv_buffer, 0, actual_vertex_count * 8)
		
		var quad_count = actual_vertex_count / 4
		var index_bytes = rd.buffer_get_data(index_buffer, 0, quad_count * 6 * 4)
		
		# Convert
		var vertices = []
		var vertices_floats = vertex_bytes.to_float32_array()
		vertices.resize(actual_vertex_count)
		for i in range(actual_vertex_count):
			vertices[i] = Vector3(vertices_floats[i*3], vertices_floats[i*3+1], vertices_floats[i*3+2])
			
		var normals = []
		var normals_floats = normal_bytes.to_float32_array()
		normals.resize(actual_vertex_count)
		for i in range(actual_vertex_count):
			normals[i] = Vector3(normals_floats[i*3], normals_floats[i*3+1], normals_floats[i*3+2])

		var uvs = []
		var uvs_floats = uv_bytes.to_float32_array()
		uvs.resize(actual_vertex_count)
		for i in range(actual_vertex_count):
			uvs[i] = Vector2(uvs_floats[i*2], uvs_floats[i*2+1])
			
		var indices = index_bytes.to_int32_array()

		arrays.resize(ArrayMesh.ARRAY_MAX)
		arrays[ArrayMesh.ARRAY_VERTEX] = PackedVector3Array(vertices)
		arrays[ArrayMesh.ARRAY_NORMAL] = PackedVector3Array(normals)
		arrays[ArrayMesh.ARRAY_TEX_UV] = PackedVector2Array(uvs)
		arrays[ArrayMesh.ARRAY_INDEX] = indices
		
	# Cleanup
	rd.free_rid(texture_rid)
	rd.free_rid(sampler_rid)
	rd.free_rid(vertex_buffer)
	rd.free_rid(normal_buffer)
	rd.free_rid(uv_buffer)
	rd.free_rid(index_buffer)
	rd.free_rid(counter_buffer)
	
	return arrays

func _exit_tree():
	mutex.lock()
	exit_thread = true
	mutex.unlock()
	semaphore.post()
	thread.wait_to_finish()
