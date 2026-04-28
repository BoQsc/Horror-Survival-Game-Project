extends Node
class_name BuildingMesher

const BuildingVisuals = preload("res://world_building_system/building_visuals.gd")

var thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var exit_thread: bool = false

var queue: Array = [] # Array of { chunk: BuildingChunk, chunk_id: int }
var _queued_chunk_ids: Dictionary = {}
var pending_apply_queue: Array = []
var pending_apply_queue_index: int = 0
var compute_shader: RDShaderFile
var native_builder: Object = null
var _native_backend_ready: bool = false
const BUILDING_MESH_CACHE_LIMIT: int = 96
const BUILDING_MESH_CACHE_VERSION: int = 7
const BUILDING_CHUNK_SIZE: int = 16
const BUILDING_CHUNK_VOLUME: int = BUILDING_CHUNK_SIZE * BUILDING_CHUNK_SIZE * BUILDING_CHUNK_SIZE
const BUILDING_APPLY_BUDGET_PER_FRAME: int = 4
const BUILDING_APPLY_BUDGET_MS_PER_FRAME: float = 4.0
var _building_mesh_cache: Dictionary = {}
var _building_mesh_cache_order: Array[String] = []

# Building voxel IDs (see `modules/world_player_v2/api/building_api.gd` and legacy notes).
# These blocks are not full cubes (stairs/ramp/slab-style). Treating them as solid voxels when
# generating merged collision boxes can turn them into full-height walls.
const STAIR_BLOCK_ID: int = 4
const STAIR_2STEP_BLOCK_ID: int = 5
const SLAB_BLOCK_ID: int = 9

# DEBUG: Track GPU mesh generation
static var mesh_gen_count: int = 0
const BYTES_PER_CALL: int = 32768 # ~32KB per call (2x 16KB textures + sampler + uniform_set)

## GPU RESOURCE CLEANUP TOGGLE
## ============================
## If you experience crashes related to building/mesh generation:
## 1. Set this to FALSE to disable cleanup
## 2. Test if crashes stop
## 3. If crashes stop, the freeing order may need more research
## 4. The original code had this disabled due to crashes (pre-Godot 4.5)
## 
## With cleanup ON: GPU memory is freed properly (no leak)
## With cleanup OFF: GPU memory leaks ~32KB per mesh generation
const ENABLE_GPU_CLEANUP: bool = true

func _init():
	mutex = Mutex.new()
	semaphore = Semaphore.new()
	set_process(true)

	if not ClassDB.class_exists("MeshBuilder"):
		push_error("[BuildingMesher] MeshBuilder GDExtension is required.")
		return
	
	compute_shader = load("res://world_greedy_meshing/greedy_meshing.glsl")
	
	thread = Thread.new()
	thread.start(_thread_loop)
	_native_backend_ready = true

func _process(_delta: float) -> void:
	var apply_items: Array = []
	mutex.lock()
	var start_us := Time.get_ticks_usec()
	var effective_apply_budget := BUILDING_APPLY_BUDGET_PER_FRAME
	if pending_apply_queue_index < pending_apply_queue.size():
		var next_chunk = pending_apply_queue[pending_apply_queue_index].get("chunk", null)
		if is_instance_valid(next_chunk) and next_chunk.manager and next_chunk.manager.world_map_mode:
			effective_apply_budget = mini(effective_apply_budget, 2)

	while pending_apply_queue_index < pending_apply_queue.size() and apply_items.size() < effective_apply_budget:
		apply_items.append(pending_apply_queue[pending_apply_queue_index])
		pending_apply_queue_index += 1
		if float(Time.get_ticks_usec() - start_us) / 1000.0 >= BUILDING_APPLY_BUDGET_MS_PER_FRAME:
			break
	if pending_apply_queue_index >= pending_apply_queue.size():
		pending_apply_queue.clear()
		pending_apply_queue_index = 0
	mutex.unlock()

	for item_variant in apply_items:
		if typeof(item_variant) != TYPE_DICTIONARY:
			continue
		var item: Dictionary = item_variant
		var chunk = item.get("chunk", null)
		if not is_instance_valid(chunk):
			continue
		chunk.apply_mesh(
			item.get("arrays", []),
			item.get("shape", null),
			item.get("mesh", null),
			item.get("collision_boxes", [])
		)

func _get_native_builder() -> Object:
	if native_builder and is_instance_valid(native_builder):
		return native_builder
	if not ClassDB.class_exists("MeshBuilder"):
		push_error("[BuildingMesher] MeshBuilder GDExtension is required.")
		return null
	native_builder = ClassDB.instantiate("MeshBuilder")
	if not native_builder:
		push_error("[BuildingMesher] Failed to instantiate MeshBuilder GDExtension.")
	return native_builder

func _make_building_mesh_cache_key(voxel_bytes: PackedByteArray, voxel_meta: PackedByteArray, collision_mode: String) -> String:
	return "%d:%s:%d:%d:%d:%d" % [
		BUILDING_MESH_CACHE_VERSION,
		collision_mode,
		hash(voxel_bytes),
		hash(voxel_meta),
		voxel_bytes.size(),
		voxel_meta.size()
	]

func _get_cached_building_mesh(voxel_bytes: PackedByteArray, voxel_meta: PackedByteArray, collision_mode: String) -> Dictionary:
	var cache_key := _make_building_mesh_cache_key(voxel_bytes, voxel_meta, collision_mode)
	if not _building_mesh_cache.has(cache_key):
		return {}

	var cached_entry: Dictionary = _building_mesh_cache[cache_key]
	var cached_voxel_bytes: PackedByteArray = cached_entry.get("voxel_bytes", PackedByteArray())
	var cached_voxel_meta: PackedByteArray = cached_entry.get("voxel_meta", PackedByteArray())
	if cached_voxel_bytes != voxel_bytes or cached_voxel_meta != voxel_meta:
		_building_mesh_cache.erase(cache_key)
		_building_mesh_cache_order.erase(cache_key)
		return {}

	if _building_mesh_cache_order.has(cache_key):
		_building_mesh_cache_order.erase(cache_key)
	_building_mesh_cache_order.append(cache_key)
	return cached_entry

func _voxels_need_detailed_collision(voxel_bytes: PackedByteArray) -> bool:
	# Cheap O(n) scan (n=4096). This runs only when generating world-map building meshes.
	for v in voxel_bytes:
		if v == STAIR_BLOCK_ID or v == STAIR_2STEP_BLOCK_ID or v == SLAB_BLOCK_ID:
			return true
	return false

func _store_cached_building_mesh(voxel_bytes: PackedByteArray, voxel_meta: PackedByteArray, collision_mode: String, mesh: ArrayMesh, shape: Shape3D, collision_boxes: Array) -> void:
	if not mesh:
		return

	BuildingVisuals.apply_shared_surface_materials(mesh, voxel_bytes)

	var cache_key := _make_building_mesh_cache_key(voxel_bytes, voxel_meta, collision_mode)
	if _building_mesh_cache.has(cache_key):
		_building_mesh_cache_order.erase(cache_key)
	elif _building_mesh_cache_order.size() >= BUILDING_MESH_CACHE_LIMIT:
		var evict_key: String = _building_mesh_cache_order.pop_front()
		_building_mesh_cache.erase(evict_key)

	_building_mesh_cache[cache_key] = {
		"voxel_bytes": voxel_bytes.duplicate(),
		"voxel_meta": voxel_meta.duplicate(),
		"mesh": mesh,
		"shape": shape,
		"collision_boxes": collision_boxes.duplicate(true)
	}
	_building_mesh_cache_order.append(cache_key)

func pack_world_map_block_batches(rotated_blocks: Array, spawn_pos: Vector3, chunk_size: int) -> Array:
	var builder := _get_native_builder()
	if not builder or not builder.has_method("pack_world_map_block_batches"):
		push_error("[BuildingMesher] MeshBuilder.pack_world_map_block_batches() is required.")
		return []
	return builder.pack_world_map_block_batches(rotated_blocks, spawn_pos, chunk_size)

func pack_rotated_world_map_block_batches(prefab_blocks: Array, rotation: int, spawn_pos: Vector3, chunk_size: int) -> Array:
	var builder := _get_native_builder()
	if not builder or not builder.has_method("pack_rotated_world_map_block_batches"):
		push_error("[BuildingMesher] MeshBuilder.pack_rotated_world_map_block_batches() is required.")
		return []
	return builder.pack_rotated_world_map_block_batches(prefab_blocks, rotation, spawn_pos, chunk_size)

func build_world_map_baked_building_payload(prefab_blocks: Array, rotation: int, spawn_pos: Vector3, chunk_size: int, chunk_stride: int) -> Dictionary:
	var builder := _get_native_builder()
	if not builder or not builder.has_method("build_world_map_baked_building_payload"):
		push_error("[BuildingMesher] MeshBuilder.build_world_map_baked_building_payload() is required.")
		return {}
	return builder.build_world_map_baked_building_payload(prefab_blocks, rotation, spawn_pos, chunk_size, chunk_stride)

func voxels_need_detailed_collision(voxel_bytes: PackedByteArray) -> bool:
	return _voxels_need_detailed_collision(voxel_bytes)

func build_building_mesh_from_voxels(voxel_bytes: PackedByteArray, voxel_meta: PackedByteArray, use_box_collision: bool, chunk_size: int) -> Dictionary:
	var builder := _get_native_builder()
	if not builder or not builder.has_method("build_building_mesh_from_voxels"):
		push_error("[BuildingMesher] MeshBuilder.build_building_mesh_from_voxels() is required.")
		return {}
	return builder.build_building_mesh_from_voxels(voxel_bytes, voxel_meta, use_box_collision, chunk_size)

func build_trimesh_collision_shape_from_faces(faces: PackedVector3Array) -> Shape3D:
	var builder := _get_native_builder()
	if not builder or not builder.has_method("build_trimesh_collision_shape_from_faces"):
		push_error("[BuildingMesher] MeshBuilder.build_trimesh_collision_shape_from_faces() is required.")
		return null
	return builder.build_trimesh_collision_shape_from_faces(faces)

func request_mesh_generation(chunk: BuildingChunk):
	if not _native_backend_ready or not chunk or not is_instance_valid(chunk):
		return
	var chunk_id := chunk.get_instance_id()
	mutex.lock()
	if not _queued_chunk_ids.has(chunk_id):
		queue.append({
			"chunk": chunk,
			"chunk_id": chunk_id
		})
		_queued_chunk_ids[chunk_id] = true
		mutex.unlock()
		semaphore.post()
		return
	mutex.unlock()

func _thread_loop():
	var rd = RenderingServer.create_local_rendering_device()
	if not rd: return
	
	var shader_spirv = compute_shader.get_spirv()
	var shader = rd.shader_create_from_spirv(shader_spirv)
	var pipeline = rd.compute_pipeline_create(shader)
	
	# Create Reusable Buffers
	var grid_size = Vector3i(16, 16, 16)
	var max_vertices = grid_size.x * grid_size.y * grid_size.z * 128 # Increased from 24 for complex shapes
	var max_indices = max_vertices * 2
	
	var vertex_buffer = rd.storage_buffer_create(max_vertices * 12)
	var normal_buffer = rd.storage_buffer_create(max_vertices * 12)
	var uv_buffer = rd.storage_buffer_create(max_vertices * 8)
	var index_buffer = rd.storage_buffer_create(max_indices * 4)
	
	var counter_data = PackedByteArray()
	counter_data.resize(4)
	counter_data.encode_u32(0, 0)
	var counter_buffer = rd.storage_buffer_create(4, counter_data)
	var index_counter_buffer = rd.storage_buffer_create(4, counter_data) # Reuse same 0-init data
	
	while true:
		semaphore.wait()
		
		mutex.lock()
		if exit_thread:
			mutex.unlock()
			break
			
		if queue.is_empty():
			mutex.unlock()
			continue
			
		var task: Dictionary = queue.pop_back()
		var chunk_id := int(task.get("chunk_id", -1))
		if chunk_id >= 0:
			_queued_chunk_ids.erase(chunk_id)
		var chunk = task.get("chunk", null)
		# IMPORTANT: Copy data inside lock to ensure thread safety
		if not is_instance_valid(chunk):
			mutex.unlock()
			continue
			
		var voxel_bytes = chunk.voxel_bytes.duplicate()
		var voxel_meta = chunk.voxel_meta.duplicate()
		mutex.unlock()
		
		# Generate
		var arrays = []
		var shape = null
		var mesh: ArrayMesh = null
		var collision_boxes: Array = []
		var mesh_generate_start_us := Time.get_ticks_usec()
		var cached_hit := false
		var mesh_dispatch_elapsed_ms := 0.0
		var mesh_build_elapsed_ms := 0.0
		var collision_shape_elapsed_ms := 0.0
		# World-map buildings prefer merged box colliders to avoid expensive shape cooking
		# during town entry. However, stair blocks are not full cubes; treating them as
		# solid voxels in merged boxes can make stairs behave like walls. For any chunk
		# containing stair blocks, fall back to the detailed collision shape path.
		var is_world_map_mode: bool = bool(is_instance_valid(chunk) and chunk.manager != null and chunk.manager.world_map_mode)
		var use_box_collision: bool = is_world_map_mode and not _voxels_need_detailed_collision(voxel_bytes)
		var collision_mode: String = "boxes" if use_box_collision else "shape"
		var cached_result := _get_cached_building_mesh(voxel_bytes, voxel_meta, collision_mode)
		if not cached_result.is_empty():
			cached_hit = true
			arrays = cached_result.get("arrays", [])
			shape = cached_result.get("shape", null)
			mesh = cached_result.get("mesh", null)
			collision_boxes = cached_result.get("collision_boxes", [])
		else:
			var result = _generate_mesh(rd, shader, pipeline, voxel_bytes, voxel_meta, vertex_buffer, normal_buffer, uv_buffer, index_buffer, counter_buffer, index_counter_buffer, use_box_collision)
			if result is Dictionary:
				arrays = result.get("arrays", [])
				shape = result.get("shape", null)
				mesh = result.get("mesh", null)
				collision_boxes = result.get("collision_boxes", [])
				mesh_dispatch_elapsed_ms = float(result.get("dispatch_elapsed_ms", 0.0))
				mesh_build_elapsed_ms = float(result.get("mesh_build_elapsed_ms", 0.0))
				collision_shape_elapsed_ms = float(result.get("collision_shape_elapsed_ms", 0.0))
			else:
				arrays = result
			if mesh:
				_store_cached_building_mesh(voxel_bytes, voxel_meta, collision_mode, mesh, shape, collision_boxes)

		# Callback
		if is_instance_valid(chunk):
			mutex.lock()
			pending_apply_queue.append({
				"chunk": chunk,
				"arrays": arrays,
				"shape": shape,
				"mesh": mesh,
				"collision_boxes": collision_boxes
			})
			mutex.unlock()
	
	# Cleanup persistent resources
	rd.free_rid(vertex_buffer)
	rd.free_rid(normal_buffer)
	rd.free_rid(uv_buffer)
	rd.free_rid(index_buffer)
	rd.free_rid(counter_buffer)
	rd.free_rid(index_counter_buffer)
	
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	rd.free()

func _generate_mesh(rd: RenderingDevice, shader: RID, pipeline: RID, v_bytes: PackedByteArray, v_meta: PackedByteArray, vertex_buffer, normal_buffer, uv_buffer, index_buffer, counter_buffer, index_counter_buffer, use_box_collision: bool) -> Dictionary:
	# DEBUG: Track GPU mesh generation calls
	mesh_gen_count += 1
	var cleanup_status = "CLEANUP ON" if ENABLE_GPU_CLEANUP else "CLEANUP OFF (LEAKING!)"
	if mesh_gen_count <= 3 or mesh_gen_count % 50 == 0:
		var estimated_kb = mesh_gen_count * BYTES_PER_CALL / 1024.0
	
	# 16x16x16
	var grid_size = Vector3i(16, 16, 16)
	
	# Reset Counters
	var zero_data = PackedByteArray()
	zero_data.resize(4)
	zero_data.encode_u32(0, 0)
	rd.buffer_update(counter_buffer, 0, 4, zero_data)
	rd.buffer_update(index_counter_buffer, 0, 4, zero_data)
	
	var builder = _get_native_builder()
	if not builder:
		return {
			"arrays": [],
			"shape": null,
			"mesh": null,
			"collision_boxes": [],
			"dispatch_elapsed_ms": 0.0,
			"mesh_build_elapsed_ms": 0.0,
			"collision_shape_elapsed_ms": 0.0
		}
	var arrays: Array = []
	var shape: Shape3D = null
	var mesh: ArrayMesh = null
	var collision_boxes: Array = []
	var dispatch_elapsed_ms := 0.0
	var mesh_build_elapsed_ms := 0.0
	var collision_shape_elapsed_ms := 0.0

	if builder and builder.has_method("build_building_mesh_from_voxels"):
		var native_build_start_us := Time.get_ticks_usec()
		var native_result = builder.build_building_mesh_from_voxels(v_bytes, v_meta, use_box_collision, BUILDING_CHUNK_SIZE)
		var native_build_elapsed_ms := float(Time.get_ticks_usec() - native_build_start_us) / 1000.0
		if native_result is Dictionary:
			arrays = []
			shape = native_result.get("shape", null)
			mesh = native_result.get("mesh", null)
			collision_boxes = native_result.get("collision_boxes", [])
			mesh_build_elapsed_ms = native_build_elapsed_ms
			collision_shape_elapsed_ms = 0.0
			return {
				"arrays": arrays,
				"shape": shape,
				"mesh": mesh,
				"collision_boxes": collision_boxes,
				"dispatch_elapsed_ms": 0.0,
				"mesh_build_elapsed_ms": mesh_build_elapsed_ms,
				"collision_shape_elapsed_ms": collision_shape_elapsed_ms
			}
		
	# Convert Data to Floats
	var float_data = builder.bytes_to_floats(v_bytes)
		
	# Convert Meta to Floats
	var meta_data = builder.bytes_to_floats(v_meta)
	
	# Texture 0: IDs
	var fmt = RDTextureFormat.new()
	fmt.width = grid_size.x
	fmt.height = grid_size.y
	fmt.depth = grid_size.z
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	var texture_rid = rd.texture_create(fmt, RDTextureView.new(), [float_data.to_byte_array()])
	
	# Texture 1: Meta (Binding 7)
	var meta_rid = rd.texture_create(fmt, RDTextureView.new(), [meta_data.to_byte_array()])
	
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
	
	var u_index_counter = RDUniform.new()
	u_index_counter.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_index_counter.binding = 6
	u_index_counter.add_id(index_counter_buffer)
	uniforms.append(u_index_counter)
	
	# Meta Texture (Binding 7)
	var u_meta = RDUniform.new()
	u_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_meta.binding = 7
	u_meta.add_id(sampler_rid) # Reuse sampler
	u_meta.add_id(meta_rid)
	uniforms.append(u_meta)
	
	var uniform_set = rd.uniform_set_create(uniforms, shader, 0)
	
	# Dispatch
	var dispatch_start_us := Time.get_ticks_usec()
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	var push_constants = PackedInt32Array([grid_size.x, grid_size.y, grid_size.z, 0])
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
	
	rd.compute_list_dispatch(compute_list, 4, 4, 4) # 16/4 = 4
	rd.compute_list_end()
	
	rd.submit()
	rd.sync ()
	
	# Read
	var counter_bytes = rd.buffer_get_data(counter_buffer)
	var actual_vertex_count = counter_bytes.decode_u32(0)
	
	# Read Index Count
	var index_counter_bytes = rd.buffer_get_data(index_counter_buffer)
	var actual_index_count = index_counter_bytes.decode_u32(0)
	dispatch_elapsed_ms = float(Time.get_ticks_usec() - dispatch_start_us) / 1000.0

	if actual_vertex_count > 0 and actual_index_count > 0:
		var vertex_bytes = rd.buffer_get_data(vertex_buffer, 0, actual_vertex_count * 12)
		var normal_bytes = rd.buffer_get_data(normal_buffer, 0, actual_vertex_count * 12)
		var uv_bytes = rd.buffer_get_data(uv_buffer, 0, actual_vertex_count * 8)
		var index_bytes = rd.buffer_get_data(index_buffer, 0, actual_index_count * 4)
		
		# Convert
		var build_start_us := Time.get_ticks_usec()
		mesh = builder.build_building_mesh(vertex_bytes, normal_bytes, uv_bytes, index_bytes, actual_vertex_count, actual_index_count)
		mesh_build_elapsed_ms = float(Time.get_ticks_usec() - build_start_us) / 1000.0
		if mesh and not use_box_collision:
			var collision_start_us := Time.get_ticks_usec()
			shape = builder.build_collision_shape_indexed(vertex_bytes, index_bytes, actual_vertex_count, actual_index_count)
			collision_shape_elapsed_ms = float(Time.get_ticks_usec() - collision_start_us) / 1000.0

		if use_box_collision:
			collision_boxes = builder.build_collision_boxes_from_voxels(v_bytes, BUILDING_CHUNK_SIZE)

		# Cleanup GPU resources - controlled by ENABLE_GPU_CLEANUP toggle
		# ORDER MATTERS: Free uniform_set FIRST (it holds references to textures/sampler)
	if ENABLE_GPU_CLEANUP:
		if uniform_set.is_valid():
			rd.free_rid(uniform_set)
		if texture_rid.is_valid():
			rd.free_rid(texture_rid)
		if meta_rid.is_valid():
			rd.free_rid(meta_rid)
		if sampler_rid.is_valid():
			rd.free_rid(sampler_rid)
	
	return {
		"arrays": arrays,
		"shape": shape,
		"mesh": mesh,
		"collision_boxes": collision_boxes,
		"dispatch_elapsed_ms": dispatch_elapsed_ms,
		"mesh_build_elapsed_ms": mesh_build_elapsed_ms,
		"collision_shape_elapsed_ms": collision_shape_elapsed_ms
	}

func _exit_tree():
	mutex.lock()
	exit_thread = true
	mutex.unlock()
	semaphore.post()
	thread.wait_to_finish()
	mutex.lock()
	queue.clear()
	_queued_chunk_ids.clear()
	mutex.unlock()
