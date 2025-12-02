extends MeshInstance3D

var rd: RenderingDevice
var shader_rid: RID
var pipeline: RID

# Resolution of our chunk
const CHUNK_SIZE = 32
# Max possible triangles (Worst case: 5 triangles per cube * 32^3 cubes)
# This is a large buffer, optimization strategies exist but this is safest for now.
const MAX_TRIANGLES = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 5

func _ready():
	# 1. Initialize GPU API
	rd = RenderingServer.create_local_rendering_device()
	
	# 2. Load and Compile Shader
	var shader_file = load("res://marching_cubes.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader_rid = rd.shader_create_from_spirv(shader_spirv)
	
	# 3. Create Buffers
	generate_terrain()

func generate_terrain():
	# A. OUTPUT VERTEX BUFFER
	# -----------------------
	# 3 vertices per triangle * 3 floats per vertex * 4 bytes per float
	var output_bytes_size = MAX_TRIANGLES * 3 * 3 * 4
	var vertex_buffer = rd.storage_buffer_create(output_bytes_size)
	var vertex_uniform = RDUniform.new()
	vertex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	vertex_uniform.binding = 0
	vertex_uniform.add_id(vertex_buffer)
	
	# B. COUNTER BUFFER (Atomic Counter)
	# -----------------------
	# Holds a single uint (4 bytes) initialized to 0.
	var counter_data = PackedByteArray()
	counter_data.resize(4) 
	counter_data.encode_u32(0, 0) # Initialize count to 0
	var counter_buffer = rd.storage_buffer_create(4, counter_data)
	
	var counter_uniform = RDUniform.new()
	counter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counter_uniform.binding = 1
	counter_uniform.add_id(counter_buffer)
	
	# C. PREPARE PIPELINE
	# -----------------------
	var uniform_set = rd.uniform_set_create([vertex_uniform, counter_uniform], shader_rid, 0)
	pipeline = rd.compute_pipeline_create(shader_rid)
	
	# D. DISPATCH
	# -----------------------
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# We dispatch groups. Our shader uses local_size 8,8,8.
	# So we need CHUNK_SIZE / 8 groups.
	var groups = CHUNK_SIZE / 8
	rd.compute_list_dispatch(compute_list, groups, groups, groups)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync() # Wait for GPU to finish
	
	# E. RETRIEVE DATA
	# -----------------------
	
	# 1. Read the counter to see how many triangles we actually made
	var count_output_bytes = rd.buffer_get_data(counter_buffer)
	var triangle_count = count_output_bytes.decode_u32(0)
	
	print("Generated Triangles: ", triangle_count)
	
	if triangle_count == 0:
		return
		
	# 2. Read the vertices
	# We only read the relevant part of the buffer (triangle_count * bytes per tri)
	var total_floats = triangle_count * 9
	var vertices_bytes = rd.buffer_get_data(vertex_buffer, 0, total_floats * 4)
	var vertices_floats = vertices_bytes.to_float32_array()
	
	# F. CONSTRUCT MESH
	# -----------------------
	build_mesh(vertices_floats)
	
	# Cleanup
	rd.free_rid(vertex_buffer)
	rd.free_rid(counter_buffer)

func build_mesh(floats: PackedFloat32Array):
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Iterate 3 floats at a time to create vectors
	for i in range(0, floats.size(), 3):
		var v = Vector3(floats[i], floats[i+1], floats[i+2])
		st.add_vertex(v)
	
	st.generate_normals() # Auto-calculate normals (smooth or flat based on smoothing)
	
	# Optional: Indexing creates a smaller mesh file but takes CPU time to process
	st.index() 
	
	self.mesh = st.commit()
