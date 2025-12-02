extends Node

var rd: RenderingDevice
var texture_rid: RID
var pipeline: RID
var uniform_set: RID
var texture_rd: Texture2DRD

@export var texture_size := Vector2i(1024, 1024)
@export var shader_file: RDShaderFile
@export var target_mesh: MeshInstance3D 

func _ready():
	# 1. Get the Global Rendering Device
	rd = RenderingServer.get_rendering_device()
	
	if not rd:
		push_error("No RenderingDevice. Switch to Forward+ or Mobile backend.")
		return
	
	# 2. Create the Output Texture on the GPU
	var fmt = RDTextureFormat.new()
	fmt.width = texture_size.x
	fmt.height = texture_size.y
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT # Matches r32f in GLSL
	
	# --- FIX: Using parentheses prevents the Parse Error ---
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	
	var view = RDTextureView.new()
	texture_rid = rd.texture_create(fmt, view, [])
	
	# 3. Compile the Shader
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	var shader_rid = rd.shader_create_from_spirv(shader_spirv)
	
	# 4. Create the Uniform Set (Bind the texture to the shader)
	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture_rid)
	uniform_set = rd.uniform_set_create([uniform], shader_rid, 0)
	
	# 5. Create the Pipeline
	pipeline = rd.compute_pipeline_create(shader_rid)

	# 6. Execute!
	dispatch_compute()
	
	# 7. Bridge to Material
	setup_material()

func dispatch_compute():
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# Calculate group size (ceiling division)
	var x_groups = int(ceil(texture_size.x / 8.0))
	var y_groups = int(ceil(texture_size.y / 8.0))
	
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
	rd.compute_list_end()
	
	# Force execution immediately (optional)
	# rd.submit() 

func setup_material():
	# [cite_start]Create a Texture2DRD to wrap the GPU RID [cite: 1, 2]
	texture_rd = Texture2DRD.new()
	texture_rd.texture_rd_rid = texture_rid
	
	# Assign to the mesh material
	if target_mesh and target_mesh.material_override:
		var material = target_mesh.material_override as ShaderMaterial
		if material:
			material.set_shader_parameter("heightmap", texture_rd)
	else:
		push_warning("Please assign a MeshInstance3D with a ShaderMaterial in the Inspector.")
