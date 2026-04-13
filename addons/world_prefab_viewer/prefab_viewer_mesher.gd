@tool
extends RefCounted

const CHUNK_SIZE := 16
const CHUNK_VOLUME := CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE
const MAX_VERTICES := CHUNK_VOLUME * 128
const MAX_INDICES := MAX_VERTICES * 2
const SHADER_PATH := "res://world_greedy_meshing/greedy_meshing.glsl"

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _vertex_buffer: RID
var _normal_buffer: RID
var _uv_buffer: RID
var _index_buffer: RID
var _counter_buffer: RID
var _index_counter_buffer: RID
var _shader_file: RDShaderFile
var _available := false
var _attempted_init := false
var _last_error := ""


func is_available() -> bool:
	return _ensure_device()


func get_last_error() -> String:
	return _last_error


func generate_arrays(voxel_bytes: PackedByteArray, voxel_meta: PackedByteArray) -> Array:
	if voxel_bytes.size() != CHUNK_VOLUME or voxel_meta.size() != CHUNK_VOLUME:
		_last_error = "Preview mesher expected 16x16x16 chunk byte arrays."
		return []

	if not _ensure_device():
		return []

	return _generate_mesh(voxel_bytes, voxel_meta)


func dispose() -> void:
	if _rd:
		if _vertex_buffer.is_valid():
			_rd.free_rid(_vertex_buffer)
		if _normal_buffer.is_valid():
			_rd.free_rid(_normal_buffer)
		if _uv_buffer.is_valid():
			_rd.free_rid(_uv_buffer)
		if _index_buffer.is_valid():
			_rd.free_rid(_index_buffer)
		if _counter_buffer.is_valid():
			_rd.free_rid(_counter_buffer)
		if _index_counter_buffer.is_valid():
			_rd.free_rid(_index_counter_buffer)
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
		_rd.free()

	_rd = null
	_shader = RID()
	_pipeline = RID()
	_vertex_buffer = RID()
	_normal_buffer = RID()
	_uv_buffer = RID()
	_index_buffer = RID()
	_counter_buffer = RID()
	_index_counter_buffer = RID()
	_available = false
	_attempted_init = false


func _ensure_device() -> bool:
	if _available:
		return true
	if _attempted_init:
		return false

	_attempted_init = true
	_last_error = ""

	if not ClassDB.class_exists("MeshBuilder"):
		_last_error = "Missing MeshBuilder GDExtension."
		return false

	if not ResourceLoader.exists(SHADER_PATH):
		_last_error = "Missing greedy meshing shader: %s" % SHADER_PATH
		return false

	_shader_file = load(SHADER_PATH) as RDShaderFile
	if not _shader_file:
		_last_error = "Failed to load greedy meshing shader."
		return false

	_rd = RenderingServer.create_local_rendering_device()
	if not _rd:
		_last_error = "Local rendering device is unavailable in the editor."
		return false

	var shader_spirv := _shader_file.get_spirv()
	_shader = _rd.shader_create_from_spirv(shader_spirv)
	if not _shader.is_valid():
		_last_error = "Failed to compile greedy meshing shader."
		dispose()
		return false

	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_last_error = "Failed to create greedy meshing compute pipeline."
		dispose()
		return false

	_vertex_buffer = _rd.storage_buffer_create(MAX_VERTICES * 12)
	_normal_buffer = _rd.storage_buffer_create(MAX_VERTICES * 12)
	_uv_buffer = _rd.storage_buffer_create(MAX_VERTICES * 8)
	_index_buffer = _rd.storage_buffer_create(MAX_INDICES * 4)

	var counter_data := PackedByteArray()
	counter_data.resize(4)
	counter_data.encode_u32(0, 0)
	_counter_buffer = _rd.storage_buffer_create(4, counter_data)
	_index_counter_buffer = _rd.storage_buffer_create(4, counter_data)

	_available = (
		_vertex_buffer.is_valid()
		and _normal_buffer.is_valid()
		and _uv_buffer.is_valid()
		and _index_buffer.is_valid()
		and _counter_buffer.is_valid()
		and _index_counter_buffer.is_valid()
	)
	if not _available:
		_last_error = "Failed to allocate preview meshing buffers."
		dispose()
		return false

	return true


func _generate_mesh(v_bytes: PackedByteArray, v_meta: PackedByteArray) -> Array:
	var zero_data := PackedByteArray()
	zero_data.resize(4)
	zero_data.encode_u32(0, 0)
	_rd.buffer_update(_counter_buffer, 0, 4, zero_data)
	_rd.buffer_update(_index_counter_buffer, 0, 4, zero_data)

	var texture_rid := RID()
	var meta_rid := RID()
	var sampler_rid := RID()
	var uniform_set := RID()

	var builder = ClassDB.instantiate("MeshBuilder")
	if not builder:
		_last_error = "Missing MeshBuilder GDExtension."
		_cleanup_transient(texture_rid, meta_rid, sampler_rid, uniform_set)
		return []

	var float_data: PackedFloat32Array = builder.bytes_to_floats(v_bytes)
	var meta_data: PackedFloat32Array = builder.bytes_to_floats(v_meta)

	var fmt := RDTextureFormat.new()
	fmt.width = CHUNK_SIZE
	fmt.height = CHUNK_SIZE
	fmt.depth = CHUNK_SIZE
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)

	texture_rid = _rd.texture_create(fmt, RDTextureView.new(), [float_data.to_byte_array()])
	meta_rid = _rd.texture_create(fmt, RDTextureView.new(), [meta_data.to_byte_array()])
	if not texture_rid.is_valid() or not meta_rid.is_valid():
		_last_error = "Failed to create preview voxel textures."
		_cleanup_transient(texture_rid, meta_rid, sampler_rid, uniform_set)
		return []

	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_rid = _rd.sampler_create(sampler_state)

	var uniforms: Array[RDUniform] = []

	var u_voxel := RDUniform.new()
	u_voxel.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_voxel.binding = 0
	u_voxel.add_id(sampler_rid)
	u_voxel.add_id(texture_rid)
	uniforms.append(u_voxel)

	var u_vertex := RDUniform.new()
	u_vertex.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_vertex.binding = 1
	u_vertex.add_id(_vertex_buffer)
	uniforms.append(u_vertex)

	var u_normal := RDUniform.new()
	u_normal.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_normal.binding = 2
	u_normal.add_id(_normal_buffer)
	uniforms.append(u_normal)

	var u_uv := RDUniform.new()
	u_uv.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_uv.binding = 3
	u_uv.add_id(_uv_buffer)
	uniforms.append(u_uv)

	var u_index := RDUniform.new()
	u_index.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_index.binding = 4
	u_index.add_id(_index_buffer)
	uniforms.append(u_index)

	var u_counter := RDUniform.new()
	u_counter.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_counter.binding = 5
	u_counter.add_id(_counter_buffer)
	uniforms.append(u_counter)

	var u_index_counter := RDUniform.new()
	u_index_counter.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_index_counter.binding = 6
	u_index_counter.add_id(_index_counter_buffer)
	uniforms.append(u_index_counter)

	var u_meta := RDUniform.new()
	u_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_meta.binding = 7
	u_meta.add_id(sampler_rid)
	u_meta.add_id(meta_rid)
	uniforms.append(u_meta)

	uniform_set = _rd.uniform_set_create(uniforms, _shader, 0)
	if not uniform_set.is_valid():
		_last_error = "Failed to create preview meshing uniform set."
		_cleanup_transient(texture_rid, meta_rid, sampler_rid, uniform_set)
		return []

	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)

	var push_constants := PackedInt32Array([CHUNK_SIZE, CHUNK_SIZE, CHUNK_SIZE, 0])
	_rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
	_rd.compute_list_dispatch(compute_list, 4, 4, 4)
	_rd.compute_list_end()

	_rd.submit()
	_rd.sync()

	var counter_bytes := _rd.buffer_get_data(_counter_buffer)
	var actual_vertex_count := counter_bytes.decode_u32(0)
	var index_counter_bytes := _rd.buffer_get_data(_index_counter_buffer)
	var actual_index_count := index_counter_bytes.decode_u32(0)

	var arrays: Array = []
	if actual_vertex_count > 0 and actual_index_count > 0:
		var vertex_bytes := _rd.buffer_get_data(_vertex_buffer, 0, actual_vertex_count * 12)
		var normal_bytes := _rd.buffer_get_data(_normal_buffer, 0, actual_vertex_count * 12)
		var uv_bytes := _rd.buffer_get_data(_uv_buffer, 0, actual_vertex_count * 8)
		var index_bytes := _rd.buffer_get_data(_index_buffer, 0, actual_index_count * 4)

		var mesh: ArrayMesh = builder.build_building_mesh(
			vertex_bytes,
			normal_bytes,
			uv_bytes,
			index_bytes,
			actual_vertex_count,
			actual_index_count
		)
		if mesh:
			for surface_index in range(mesh.get_surface_count()):
				arrays = mesh.surface_get_arrays(surface_index)

	_cleanup_transient(texture_rid, meta_rid, sampler_rid, uniform_set)
	return arrays


func _cleanup_transient(texture_rid: RID, meta_rid: RID, sampler_rid: RID, uniform_set: RID) -> void:
	if not _rd:
		return
	if uniform_set.is_valid():
		_rd.free_rid(uniform_set)
	if texture_rid.is_valid():
		_rd.free_rid(texture_rid)
	if meta_rid.is_valid():
		_rd.free_rid(meta_rid)
	if sampler_rid.is_valid():
		_rd.free_rid(sampler_rid)
