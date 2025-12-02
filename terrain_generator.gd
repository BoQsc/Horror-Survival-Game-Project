extends MeshInstance3D

var rd: RenderingDevice
var shader_rid: RID
var pipeline: RID

const CHUNK_SIZE = 32
const MAX_TRIANGLES = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 5

func _ready():
	rd = RenderingServer.create_local_rendering_device()
	
	# Load shader
	var shader_file = load("res://marching_cubes.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader_rid = rd.shader_create_from_spirv(shader_spirv)
	
	generate_terrain()

func generate_terrain():
	# 1. Buffers
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
	
	# 2. Pipeline & Dispatch
	var uniform_set = rd.uniform_set_create([vertex_uniform, counter_uniform], shader_rid, 0)
	pipeline = rd.compute_pipeline_create(shader_rid)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	var groups = CHUNK_SIZE / 8
	rd.compute_list_dispatch(compute_list, groups, groups, groups)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	# 3. Read Results
	var count_output_bytes = rd.buffer_get_data(counter_buffer)
	var triangle_count = count_output_bytes.decode_u32(0)
	
	print("Triangles Generated: ", triangle_count)
	
	if triangle_count > 0:
		var total_floats = triangle_count * 9
		var vertices_bytes = rd.buffer_get_data(vertex_buffer, 0, total_floats * 4)
		var vertices_floats = vertices_bytes.to_float32_array()
		build_mesh(vertices_floats)
	
	rd.free_rid(vertex_buffer)
	rd.free_rid(counter_buffer)

func build_mesh(floats: PackedFloat32Array):
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.7, 0.3)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED # Helps if triangles are inside-out
	st.set_material(mat)
	
	for i in range(0, floats.size(), 3):
		var v = Vector3(floats[i], floats[i+1], floats[i+2])
		st.add_vertex(v)
	
	st.generate_normals()
	
	self.mesh = st.commit()
