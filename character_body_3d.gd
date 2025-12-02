extends Node3D

var rd: RenderingDevice
var shader_rid: RID

# 32 Voxels wide
const CHUNK_SIZE = 32
# Generate chunks with NO overlap - use larger chunks instead
const CHUNK_STRIDE = CHUNK_SIZE

# Max triangles estimation
const MAX_TRIANGLES = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 5

func _ready():
	rd = RenderingServer.create_local_rendering_device()
	
	# Load shader
	var shader_file = load("res://marching_cubes.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader_rid = rd.shader_create_from_spirv(shader_spirv)
	
	# Spawn a 3x3 grid of chunks centered on 0,0,0
	spawn_chunk_grid(3)

func spawn_chunk_grid(grid_size: int):
	var start = -floor(grid_size / 2.0)
	var end = floor(grid_size / 2.0) + 1
	
	for x in range(start, end):
		for z in range(start, end):
			# Calculate World Position for this chunk - NO OVERLAP
			var chunk_pos = Vector3(x * CHUNK_STRIDE, 0, z * CHUNK_STRIDE)
			generate_chunk(chunk_pos)

func generate_chunk(offset: Vector3):
	# 1. Setup Buffers
	var output_bytes_size = MAX_TRIANGLES * 3 * 3 * 4
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
	
	# Send Push Constants (Offset)
	var push_data = PackedFloat32Array([offset.x, offset.y, offset.z, 0.0])
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
		var total_floats = triangle_count * 9
		var vertices_bytes = rd.buffer_get_data(vertex_buffer, 0, total_floats * 4)
		var vertices_floats = vertices_bytes.to_float32_array()
		
		build_mesh_instance(vertices_floats, offset)
	
	# Cleanup
	rd.free_rid(vertex_buffer)
	rd.free_rid(counter_buffer)

func build_mesh_instance(floats: PackedFloat32Array, position: Vector3):
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.7, 0.3)
	st.set_material(mat)
	
	for i in range(0, floats.size(), 3):
		var v = Vector3(floats[i], floats[i+1], floats[i+2])
		st.add_vertex(v)
	
	st.generate_normals()
	
	var mesh = st.commit()
	
	# Create the node in the scene
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.position = position
	add_child(mesh_instance)
