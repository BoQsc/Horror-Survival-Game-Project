extends Node3D

@export var voxel_grid_size: Vector3i = Vector3i(16, 16, 16)
@export var block_type: int = 1

var compute_shader: RDShaderFile
var mesh_instance: MeshInstance3D
var array_mesh: ArrayMesh

func _ready():
	# Load compute shader
	compute_shader = load("res://greedy_meshing/greedy_meshing.glsl")
	
	if compute_shader:
		print("Compute shader loaded successfully!")
		
		# Create a MeshInstance3D to display the generated mesh
		mesh_instance = MeshInstance3D.new()
		add_child(mesh_instance)
		
		# Initialize ArrayMesh
		array_mesh = ArrayMesh.new()
		mesh_instance.mesh = array_mesh
		
		_generate_greedy_mesh()
	else:
		print("Failed to load compute shader!")

func _create_voxel_data() -> PackedByteArray:
	# Create voxel data as a flat array of floats
	# Each voxel stores a single float value (0.0 = air, 1.0+ = block type)
	var voxel_data = PackedFloat32Array()
	voxel_data.resize(voxel_grid_size.x * voxel_grid_size.y * voxel_grid_size.z)
	
	var center = Vector3(voxel_grid_size) * 0.5
	var radius = min(voxel_grid_size.x, min(voxel_grid_size.y, voxel_grid_size.z)) * 0.4
	
	for x in range(voxel_grid_size.x):
		for y in range(voxel_grid_size.y):
			for z in range(voxel_grid_size.z):
				var index = x + y * voxel_grid_size.x + z * voxel_grid_size.x * voxel_grid_size.y
				var value = 0.0
				
				# Create a solid sphere
				var pos = Vector3(x + 0.5, y + 0.5, z + 0.5)
				if pos.distance_to(center) <= radius:
					value = 1.0
				
				voxel_data[index] = value
	
	return voxel_data.to_byte_array()

func _generate_greedy_mesh():
	print("Generating greedy mesh...")
	
	# Create local rendering device
	var rd = RenderingServer.create_local_rendering_device()
	
	# Load and compile shader
	var shader_file = load("res://greedy_meshing/greedy_meshing.glsl")
	if not shader_file:
		print("Failed to load shader file!")
		return
	
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	var shader = rd.shader_create_from_spirv(shader_spirv)
	
	# Create voxel data buffer
	var voxel_data = _create_voxel_data()
	# Create a Texture3D for the voxel data (better for neighbors than a raw buffer in this specific shader)
	
	var fmt = RDTextureFormat.new()
	fmt.width = voxel_grid_size.x
	fmt.height = voxel_grid_size.y
	fmt.depth = voxel_grid_size.z
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	var texture_rid = rd.texture_create(fmt, RDTextureView.new(), [voxel_data])
	
	# Prepare output buffers
	# Max vertices: Worst case (checkerboard) is half voxels solid * 6 faces * 4 verts
	var max_vertices = voxel_grid_size.x * voxel_grid_size.y * voxel_grid_size.z * 24
	var max_indices = max_vertices * 2 # heuristic
	
	# Vertex buffer (vec3 = 12 bytes each)
	var vertex_data = PackedByteArray()
	vertex_data.resize(max_vertices * 12)
	var vertex_buffer = rd.storage_buffer_create(vertex_data.size(), vertex_data)
	
	# Normal buffer (vec3 = 12 bytes each)
	var normal_data = PackedByteArray()
	normal_data.resize(max_vertices * 12)
	var normal_buffer = rd.storage_buffer_create(normal_data.size(), normal_data)
	
	# UV buffer (vec2 = 8 bytes each)
	var uv_data = PackedByteArray()
	uv_data.resize(max_vertices * 8)
	var uv_buffer = rd.storage_buffer_create(uv_data.size(), uv_data)
	
	# Index buffer (uint32 = 4 bytes each)
	var index_data = PackedByteArray()
	index_data.resize(max_indices * 4)
	var index_buffer = rd.storage_buffer_create(index_data.size(), index_data)
	
	# Counter buffer
	var counter_data = PackedByteArray()
	counter_data.resize(4)
	counter_data.encode_u32(0, 0)
	var counter_buffer = rd.storage_buffer_create(counter_data.size(), counter_data)
	
	# Create uniforms for the buffers
	var uniforms = []
	
	# Voxel data texture uniform
	var u_voxel = RDUniform.new()
	u_voxel.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_voxel.binding = 0
	# We need a sampler state
	var sampler_state = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	var sampler_rid = rd.sampler_create(sampler_state)
	u_voxel.add_id(sampler_rid)
	u_voxel.add_id(texture_rid)
	uniforms.append(u_voxel)
	
	# Vertex buffer uniform
	var u_vertex = RDUniform.new()
	u_vertex.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_vertex.binding = 1
	u_vertex.add_id(vertex_buffer)
	uniforms.append(u_vertex)
	
	# Normal buffer uniform
	var u_normal = RDUniform.new()
	u_normal.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_normal.binding = 2
	u_normal.add_id(normal_buffer)
	uniforms.append(u_normal)
	
	# UV buffer uniform
	var u_uv = RDUniform.new()
	u_uv.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_uv.binding = 3
	u_uv.add_id(uv_buffer)
	uniforms.append(u_uv)
	
	# Index buffer uniform
	var u_index = RDUniform.new()
	u_index.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_index.binding = 4
	u_index.add_id(index_buffer)
	uniforms.append(u_index)
	
	# Counter buffer uniform
	var u_counter = RDUniform.new()
	u_counter.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_counter.binding = 5
	u_counter.add_id(counter_buffer)
	uniforms.append(u_counter)
	
	# Create uniform set
	var uniform_set = rd.uniform_set_create(uniforms, shader, 0)
	
	# Create compute pipeline
	var pipeline = rd.compute_pipeline_create(shader)
	
	# Dispatch compute shader
	var dispatch_x = (voxel_grid_size.x + 3) / 4
	var dispatch_y = (voxel_grid_size.y + 3) / 4
	var dispatch_z = (voxel_grid_size.z + 3) / 4
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# Push Constants (Grid Size)
	var push_constants = PackedInt32Array([
		voxel_grid_size.x, 
		voxel_grid_size.y, 
		voxel_grid_size.z, 
		0 # Padding
	])
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
	
	rd.compute_list_dispatch(compute_list, dispatch_x, dispatch_y, dispatch_z)
	rd.compute_list_end()
	
	# Submit and sync
	rd.submit()
	rd.sync()
	
	# Read back data from buffers
	var counter_bytes = rd.buffer_get_data(counter_buffer)
	var actual_vertex_count = counter_bytes.decode_u32(0)
	
	print("Actual vertex count (Culled): ", actual_vertex_count)
	print("Max potential vertices (Naive): ", max_vertices)
	
	if actual_vertex_count > 0:
		# Read back only what we need (rounded up to nearest 4 bytes alignment if needed)
		var vertex_bytes = rd.buffer_get_data(vertex_buffer, 0, actual_vertex_count * 12)
		var normal_bytes = rd.buffer_get_data(normal_buffer, 0, actual_vertex_count * 12)
		var uv_bytes = rd.buffer_get_data(uv_buffer, 0, actual_vertex_count * 8)
		
		# Calculate index count (6 indices per 4 vertices)
		# This assumes we always output quads.
		var quad_count = actual_vertex_count / 4
		var actual_index_count = quad_count * 6
		var index_bytes = rd.buffer_get_data(index_buffer, 0, actual_index_count * 4)
		
		# Convert byte data to arrays
		# Use Packed*Array.to_float32_array() which is faster, but data is packed
		# Vertices (vec3)
		var vertices_floats = vertex_bytes.to_float32_array()
		var vertices_array = PackedVector3Array()
		vertices_array.resize(actual_vertex_count)
		for i in range(actual_vertex_count):
			vertices_array[i] = Vector3(vertices_floats[i*3], vertices_floats[i*3+1], vertices_floats[i*3+2])
			
		# Normals (vec3)
		var normals_floats = normal_bytes.to_float32_array()
		var normals_array = PackedVector3Array()
		normals_array.resize(actual_vertex_count)
		for i in range(actual_vertex_count):
			normals_array[i] = Vector3(normals_floats[i*3], normals_floats[i*3+1], normals_floats[i*3+2])

		# UVs (vec2)
		var uvs_floats = uv_bytes.to_float32_array()
		var uvs_array = PackedVector2Array()
		uvs_array.resize(actual_vertex_count)
		for i in range(actual_vertex_count):
			uvs_array[i] = Vector2(uvs_floats[i*2], uvs_floats[i*2+1])
			
		# Indices (int32/uint32)
		# buffer_get_data returns bytes. 
		var indices_array = index_bytes.to_int32_array()

		print("Parsed vertices: ", vertices_array.size())
		print("Parsed indices: ", indices_array.size())
		
		var arrays = []
		arrays.resize(ArrayMesh.ARRAY_MAX)
		arrays[ArrayMesh.ARRAY_VERTEX] = vertices_array
		arrays[ArrayMesh.ARRAY_NORMAL] = normals_array
		arrays[ArrayMesh.ARRAY_TEX_UV] = uvs_array
		arrays[ArrayMesh.ARRAY_INDEX] = indices_array
		
		array_mesh.clear_surfaces()
		array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		
		var material = StandardMaterial3D.new()
		material.albedo_color = Color(0.0, 0.7, 0.2)
		material.cull_mode = BaseMaterial3D.CULL_DISABLED # Debug: Show all faces to check for winding issues
		mesh_instance.material_override = material
		print("Mesh created successfully!")
	else:
		print("No valid mesh data to create.")
	
	# Free buffers
	rd.free_rid(texture_rid)
	rd.free_rid(sampler_rid)
	rd.free_rid(vertex_buffer)
	rd.free_rid(normal_buffer)
	rd.free_rid(uv_buffer)
	rd.free_rid(index_buffer)
	rd.free_rid(counter_buffer)
