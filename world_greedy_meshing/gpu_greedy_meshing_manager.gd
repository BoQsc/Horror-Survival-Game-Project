extends Node3D

@export var voxel_grid_size: Vector3i = Vector3i(16, 16, 16)
@export var block_type: int = 1

var compute_shader: RDShaderFile
var mesh_instance: MeshInstance3D
var array_mesh: ArrayMesh
var static_body: StaticBody3D
var collision_shape: CollisionShape3D

# Persistent Voxel Data
var voxel_bytes: PackedByteArray

# Threading
var thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var exit_thread: bool = false
var dirty: bool = false

func _ready():
	mutex = Mutex.new()
	semaphore = Semaphore.new()
	
	# Load compute shader
	compute_shader = load("res://world_greedy_meshing/greedy_meshing.glsl")
	
	if compute_shader:
		print("Compute shader loaded successfully!")
		
		# Setup Physics/Visuals
		static_body = StaticBody3D.new()
		add_child(static_body)
		
		mesh_instance = MeshInstance3D.new()
		static_body.add_child(mesh_instance)
		
		collision_shape = CollisionShape3D.new()
		static_body.add_child(collision_shape)
		
		# Initialize ArrayMesh
		array_mesh = ArrayMesh.new()
		mesh_instance.mesh = array_mesh
		
		_initialize_voxel_data()
		
		# Start Thread
		thread = Thread.new()
		thread.start(_thread_loop)
		
		# Trigger first build
		_trigger_update()
	else:
		print("Failed to load compute shader!")

func _unhandled_input(event):
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_handle_click(false) # Remove
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_handle_click(true) # Add

func _handle_click(add_block: bool):
	var camera = get_viewport().get_camera_3d()
	if not camera: return
	
	var mouse_pos = get_viewport().get_mouse_position()
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 100.0
	
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space_state.intersect_ray(query)
	
	if result:
		var hit_pos = result.position
		var normal = result.normal
		
		var target_pos = hit_pos - normal * 0.5 if not add_block else hit_pos + normal * 0.5
		var voxel_coord = Vector3i(floor(target_pos))
		
		_update_voxel(voxel_coord, 1.0 if add_block else 0.0)

func _update_voxel(coord: Vector3i, value: float):
	if coord.x < 0 or coord.y < 0 or coord.z < 0: return
	if coord.x >= voxel_grid_size.x or coord.y >= voxel_grid_size.y or coord.z >= voxel_grid_size.z: return
	
	var index = coord.x + coord.y * voxel_grid_size.x + coord.z * voxel_grid_size.x * voxel_grid_size.y
	
	mutex.lock()
	var float_bytes = PackedFloat32Array([value]).to_byte_array()
	for i in range(4):
		voxel_bytes[index * 4 + i] = float_bytes[i]
	mutex.unlock()
		
	_trigger_update()

func _trigger_update():
	mutex.lock()
	dirty = true
	mutex.unlock()
	semaphore.post()

func _initialize_voxel_data():
	var voxel_floats = PackedFloat32Array()
	voxel_floats.resize(voxel_grid_size.x * voxel_grid_size.y * voxel_grid_size.z)
	
	var center = Vector3(voxel_grid_size) * 0.5
	var radius = min(voxel_grid_size.x, min(voxel_grid_size.y, voxel_grid_size.z)) * 0.4
	
	for x in range(voxel_grid_size.x):
		for y in range(voxel_grid_size.y):
			for z in range(voxel_grid_size.z):
				var index = x + y * voxel_grid_size.x + z * voxel_grid_size.x * voxel_grid_size.y
				var value = 0.0
				var pos = Vector3(x + 0.5, y + 0.5, z + 0.5)
				if pos.distance_to(center) <= radius:
					value = 1.0
				voxel_floats[index] = value
	
	voxel_bytes = voxel_floats.to_byte_array()

func _thread_loop():
	# Create Persistent RD on Thread
	var rd = RenderingServer.create_local_rendering_device()
	if not rd: return

	# Compile Shader once
	var shader_spirv: RDShaderSPIRV = compute_shader.get_spirv()
	var shader = rd.shader_create_from_spirv(shader_spirv)
	var pipeline = rd.compute_pipeline_create(shader)
	
	while true:
		semaphore.wait()
		
		mutex.lock()
		if exit_thread:
			mutex.unlock()
			break
			
		if not dirty:
			mutex.unlock()
			continue
		
		# Copy data for processing
		var current_voxel_bytes = voxel_bytes.duplicate()
		dirty = false
		mutex.unlock()
		
		# Generate Mesh logic
		var arrays = _generate_mesh_on_gpu(rd, shader, pipeline, current_voxel_bytes)
		
		# Send back to main thread
		call_deferred("_apply_mesh", arrays)
	
	rd.free()

func _generate_mesh_on_gpu(rd: RenderingDevice, shader: RID, pipeline: RID, v_bytes: PackedByteArray):
	# Texture
	var fmt = RDTextureFormat.new()
	fmt.width = voxel_grid_size.x
	fmt.height = voxel_grid_size.y
	fmt.depth = voxel_grid_size.z
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	var texture_rid = rd.texture_create(fmt, RDTextureView.new(), [v_bytes])
	
	# Buffers
	var max_vertices = voxel_grid_size.x * voxel_grid_size.y * voxel_grid_size.z * 24
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
	var dispatch_x = (voxel_grid_size.x + 3) / 4
	var dispatch_y = (voxel_grid_size.y + 3) / 4
	var dispatch_z = (voxel_grid_size.z + 3) / 4
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	var push_constants = PackedInt32Array([
		voxel_grid_size.x, voxel_grid_size.y, voxel_grid_size.z, 0
	])
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
	
	rd.compute_list_dispatch(compute_list, dispatch_x, dispatch_y, dispatch_z)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	# Read Output
	var counter_bytes = rd.buffer_get_data(counter_buffer)
	var actual_vertex_count = counter_bytes.decode_u32(0)
	
	var arrays = []
	
	if actual_vertex_count > 0:
		var vertex_bytes = rd.buffer_get_data(vertex_buffer, 0, actual_vertex_count * 12)
		var normal_bytes = rd.buffer_get_data(normal_buffer, 0, actual_vertex_count * 12)
		var uv_bytes = rd.buffer_get_data(uv_buffer, 0, actual_vertex_count * 8)
		
		var quad_count = actual_vertex_count / 4
		var index_bytes = rd.buffer_get_data(index_buffer, 0, quad_count * 6 * 4)
		
		# Process arrays on thread to save main thread time
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
	
	# Cleanup RIDs
	rd.free_rid(texture_rid)
	rd.free_rid(sampler_rid)
	rd.free_rid(vertex_buffer)
	rd.free_rid(normal_buffer)
	rd.free_rid(uv_buffer)
	rd.free_rid(index_buffer)
	rd.free_rid(counter_buffer)
	
	return arrays

func _apply_mesh(arrays):
	if arrays.size() > 0:
		array_mesh.clear_surfaces()
		array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		
		var material = StandardMaterial3D.new()
		material.albedo_color = Color(0.0, 0.7, 0.2)
		mesh_instance.material_override = material
		
		# This is still somewhat expensive but now only happens after async generation
		if collision_shape.shape:
			collision_shape.shape = null
		collision_shape.shape = array_mesh.create_trimesh_shape()
	else:
		array_mesh.clear_surfaces()
		collision_shape.shape = null

func _exit_tree():
	mutex.lock()
	exit_thread = true
	mutex.unlock()
	semaphore.post()
	thread.wait_to_finish()
