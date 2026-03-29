extends Node
class_name BuildingMesher

var thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var exit_thread: bool = false

var queue: Array = [] # Array of BuildingChunk
var pending_apply_queue: Array = []
var pending_apply_queue_index: int = 0
var compute_shader: RDShaderFile
var native_builder: Object = null
const BUILDING_MESH_CACHE_LIMIT: int = 96
const BUILDING_CHUNK_SIZE: int = 16
const BUILDING_CHUNK_VOLUME: int = BUILDING_CHUNK_SIZE * BUILDING_CHUNK_SIZE * BUILDING_CHUNK_SIZE
const BUILDING_APPLY_BUDGET_PER_FRAME: int = 4
const BUILDING_APPLY_BUDGET_MS_PER_FRAME: float = 4.0
var _building_mesh_cache: Dictionary = {}
var _building_mesh_cache_order: Array[String] = []

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
	
	compute_shader = load("res://world_greedy_meshing/greedy_meshing.glsl")
	
	thread = Thread.new()
	thread.start(_thread_loop)

func _process(_delta: float) -> void:
	var apply_items: Array = []
	mutex.lock()
	var start_us := Time.get_ticks_usec()
	while pending_apply_queue_index < pending_apply_queue.size() and apply_items.size() < BUILDING_APPLY_BUDGET_PER_FRAME:
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
	if ClassDB.class_exists("MeshBuilder"):
		native_builder = ClassDB.instantiate("MeshBuilder")
	return native_builder

func _make_building_mesh_cache_key(voxel_bytes: PackedByteArray, voxel_meta: PackedByteArray, collision_mode: String) -> String:
	return "%s:%d:%d:%d:%d" % [
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

func _store_cached_building_mesh(voxel_bytes: PackedByteArray, voxel_meta: PackedByteArray, collision_mode: String, mesh: ArrayMesh, shape: Shape3D, collision_boxes: Array) -> void:
	if not mesh:
		return

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

func _build_collision_boxes_from_voxels(voxel_bytes: PackedByteArray) -> Array:
	var boxes: Array = []
	if voxel_bytes.size() < BUILDING_CHUNK_VOLUME:
		return boxes

	var visited := PackedByteArray()
	visited.resize(BUILDING_CHUNK_VOLUME)
	visited.fill(0)

	for y in range(BUILDING_CHUNK_SIZE):
		for z in range(BUILDING_CHUNK_SIZE):
			for x in range(BUILDING_CHUNK_SIZE):
				var idx := x + y * BUILDING_CHUNK_SIZE + z * BUILDING_CHUNK_SIZE * BUILDING_CHUNK_SIZE
				if visited.decode_u8(idx) != 0:
					continue
				if voxel_bytes.decode_u8(idx) == 0:
					continue

				var x_end := x
				while x_end + 1 < BUILDING_CHUNK_SIZE:
					var next_idx := (x_end + 1) + y * BUILDING_CHUNK_SIZE + z * BUILDING_CHUNK_SIZE * BUILDING_CHUNK_SIZE
					if visited.decode_u8(next_idx) != 0 or voxel_bytes.decode_u8(next_idx) == 0:
						break
					x_end += 1

				var z_end := z
				while z_end + 1 < BUILDING_CHUNK_SIZE:
					var can_expand_z := true
					for xi in range(x, x_end + 1):
						var row_idx := xi + y * BUILDING_CHUNK_SIZE + (z_end + 1) * BUILDING_CHUNK_SIZE * BUILDING_CHUNK_SIZE
						if visited.decode_u8(row_idx) != 0 or voxel_bytes.decode_u8(row_idx) == 0:
							can_expand_z = false
							break
					if not can_expand_z:
						break
					z_end += 1

				var y_end := y
				while y_end + 1 < BUILDING_CHUNK_SIZE:
					var can_expand_y := true
					for zz in range(z, z_end + 1):
						for xi in range(x, x_end + 1):
							var layer_idx := xi + (y_end + 1) * BUILDING_CHUNK_SIZE + zz * BUILDING_CHUNK_SIZE * BUILDING_CHUNK_SIZE
							if visited.decode_u8(layer_idx) != 0 or voxel_bytes.decode_u8(layer_idx) == 0:
								can_expand_y = false
								break
						if not can_expand_y:
							break
					if not can_expand_y:
						break
					y_end += 1

				for yy in range(y, y_end + 1):
					for zz in range(z, z_end + 1):
						for xx in range(x, x_end + 1):
							visited.encode_u8(xx + yy * BUILDING_CHUNK_SIZE + zz * BUILDING_CHUNK_SIZE * BUILDING_CHUNK_SIZE, 1)

				boxes.append({
					"origin": Vector3i(x, y, z),
					"size": Vector3i(x_end - x + 1, y_end - y + 1, z_end - z + 1)
				})

	return boxes

func pack_world_map_block_batches(rotated_blocks: Array, spawn_pos: Vector3, chunk_size: int) -> Array:
	var builder := _get_native_builder()
	if builder and builder.has_method("pack_world_map_block_batches"):
		return builder.pack_world_map_block_batches(rotated_blocks, spawn_pos, chunk_size)
	return _pack_world_map_block_batches_fallback(rotated_blocks, spawn_pos, chunk_size)

func pack_rotated_world_map_block_batches(prefab_blocks: Array, rotation: int, spawn_pos: Vector3, chunk_size: int) -> Array:
	var builder := _get_native_builder()
	if builder and builder.has_method("pack_rotated_world_map_block_batches"):
		return builder.pack_rotated_world_map_block_batches(prefab_blocks, rotation, spawn_pos, chunk_size)
	return _pack_rotated_world_map_block_batches_from_prefab_fallback(prefab_blocks, rotation, spawn_pos, chunk_size)

func _pack_world_map_block_batches_fallback(rotated_blocks: Array, spawn_pos: Vector3, chunk_size: int) -> Array:
	var batches_by_coord: Dictionary = {}
	if rotated_blocks.is_empty() or chunk_size <= 0:
		return []

	for block_data_variant in rotated_blocks:
		if typeof(block_data_variant) != TYPE_DICTIONARY:
			continue
		var block_data: Dictionary = block_data_variant
		var rotated_offset: Vector3i = block_data.get("offset", Vector3i.ZERO)
		var block_global_pos: Vector3 = spawn_pos + Vector3(rotated_offset)
		var global_x: int = int(floor(block_global_pos.x))
		var global_y: int = int(floor(block_global_pos.y))
		var global_z: int = int(floor(block_global_pos.z))
		var chunk_coord := Vector3i(
			int(floor(block_global_pos.x / float(chunk_size))),
			int(floor(block_global_pos.y / float(chunk_size))),
			int(floor(block_global_pos.z / float(chunk_size)))
		)
		var local_x: int = global_x % chunk_size
		var local_y: int = global_y % chunk_size
		var local_z: int = global_z % chunk_size
		if local_x < 0:
			local_x += chunk_size
		if local_y < 0:
			local_y += chunk_size
		if local_z < 0:
			local_z += chunk_size
		var local_index: int = local_x + local_y * chunk_size + local_z * chunk_size * chunk_size
		var batch: Dictionary = batches_by_coord.get(chunk_coord, {})
		if batch.is_empty():
			batch = {
				"coord": chunk_coord,
				"indices": PackedInt32Array(),
				"types": PackedByteArray(),
				"metas": PackedByteArray()
			}
		var indices: PackedInt32Array = batch.get("indices", PackedInt32Array())
		var types: PackedByteArray = batch.get("types", PackedByteArray())
		var metas: PackedByteArray = batch.get("metas", PackedByteArray())
		indices.append(local_index)
		types.append(int(block_data.get("type", 0)))
		metas.append(int(block_data.get("meta", 0)))
		batch["coord"] = chunk_coord
		batch["indices"] = indices
		batch["types"] = types
		batch["metas"] = metas
		batches_by_coord[chunk_coord] = batch

	var batches: Array = []
	for chunk_coord_variant in batches_by_coord.keys():
		batches.append(batches_by_coord[chunk_coord_variant])
	return batches

func _pack_rotated_world_map_block_batches_from_prefab_fallback(prefab_blocks: Array, rotation: int, spawn_pos: Vector3, chunk_size: int) -> Array:
	var rotated_blocks: Array = []
	if prefab_blocks.is_empty() or chunk_size <= 0:
		return []

	for block_data_variant in prefab_blocks:
		if typeof(block_data_variant) != TYPE_DICTIONARY:
			continue
		var block_data: Dictionary = block_data_variant
		var offset: Vector3i = block_data.get("offset", Vector3i.ZERO)
		var rotated_offset: Vector3i = offset
		match rotation & 3:
			1:
				rotated_offset = Vector3i(-offset.z, offset.y, offset.x)
			2:
				rotated_offset = Vector3i(-offset.x, offset.y, -offset.z)
			3:
				rotated_offset = Vector3i(offset.z, offset.y, -offset.x)
		var block_type: int = int(block_data.get("type", 0))
		var block_meta: int = int(block_data.get("meta", 0))
		if block_type == 4 or (block_type == 2 and block_meta >= 1 and block_meta <= 3):
			block_meta = (block_meta + rotation) % 4
		rotated_blocks.append({
			"offset": rotated_offset,
			"type": block_type,
			"meta": block_meta
		})

	return _pack_world_map_block_batches_fallback(rotated_blocks, spawn_pos, chunk_size)

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
			
		var chunk = queue.pop_front()
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
		PerformanceMonitor.start_measure("Building Mesh Generate")
		# World-map buildings use merged box colliders so we keep solid collision
		# while avoiding the more expensive shape cooking path during town entry.
		var use_box_collision: bool = bool(is_instance_valid(chunk) and chunk.manager != null and chunk.manager.world_map_mode)
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
		PerformanceMonitor.end_measure("Building Mesh Generate", 5.0)
		PerformanceMonitor.capture_scope_event("buildings", "mesh_generate_complete", {
			"chunk_coord": str(chunk.chunk_coord),
			"cached_hit": cached_hit,
			"collision_mode": collision_mode,
			"dispatch_elapsed_ms": mesh_dispatch_elapsed_ms,
			"mesh_build_elapsed_ms": mesh_build_elapsed_ms,
			"collision_shape_elapsed_ms": collision_shape_elapsed_ms,
			"voxel_bytes": voxel_bytes.size(),
			"voxel_meta_bytes": voxel_meta.size(),
			"elapsed_ms": float(Time.get_ticks_usec() - mesh_generate_start_us) / 1000.0
		})

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
		DebugManager.log_building("[BuildingMesher] Mesh #%d | %s | Est. GPU use: %.0f KB" % [mesh_gen_count, cleanup_status, estimated_kb if not ENABLE_GPU_CLEANUP else 0])
	
	# 16x16x16
	var grid_size = Vector3i(16, 16, 16)
	
	# Reset Counters
	var zero_data = PackedByteArray()
	zero_data.resize(4)
	zero_data.encode_u32(0, 0)
	rd.buffer_update(counter_buffer, 0, 4, zero_data)
	rd.buffer_update(index_counter_buffer, 0, 4, zero_data)
	
	var builder = _get_native_builder()
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
	var float_data = PackedFloat32Array()
	if builder:
		float_data = builder.bytes_to_floats(v_bytes)
	else:
		float_data.resize(v_bytes.size())
		for i in range(v_bytes.size()):
			float_data[i] = float(v_bytes[i])
		
	# Convert Meta to Floats
	var meta_data = PackedFloat32Array()
	if builder:
		meta_data = builder.bytes_to_floats(v_meta)
	else:
		meta_data.resize(v_meta.size())
		for i in range(v_meta.size()):
			meta_data[i] = float(v_meta[i])
	
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
		if builder:
			mesh = builder.build_building_mesh(vertex_bytes, normal_bytes, uv_bytes, index_bytes, actual_vertex_count, actual_index_count)
		mesh_build_elapsed_ms = float(Time.get_ticks_usec() - build_start_us) / 1000.0
		if mesh and not use_box_collision:
			var collision_start_us := Time.get_ticks_usec()
			shape = builder.build_collision_shape_indexed(vertex_bytes, index_bytes, actual_vertex_count, actual_index_count)
			collision_shape_elapsed_ms = float(Time.get_ticks_usec() - collision_start_us) / 1000.0
		
		# Fallback to GDScript if builder missing
		if not mesh:
			var vertices = []
			var vertices_floats = vertex_bytes.to_float32_array()
			vertices.resize(actual_vertex_count)
			for i in range(actual_vertex_count):
				vertices[i] = Vector3(vertices_floats[i * 3], vertices_floats[i * 3 + 1], vertices_floats[i * 3 + 2])
				
			var normals = []
			var normals_floats = normal_bytes.to_float32_array()
			normals.resize(actual_vertex_count)
			for i in range(actual_vertex_count):
				normals[i] = Vector3(normals_floats[i * 3], normals_floats[i * 3 + 1], normals_floats[i * 3 + 2])

			var uvs = []
			var uvs_floats = uv_bytes.to_float32_array()
			uvs.resize(actual_vertex_count)
			for i in range(actual_vertex_count):
				uvs[i] = Vector2(uvs_floats[i * 2], uvs_floats[i * 2 + 1])
				
			var indices = index_bytes.to_int32_array()

			arrays.resize(ArrayMesh.ARRAY_MAX)
			arrays[ArrayMesh.ARRAY_VERTEX] = PackedVector3Array(vertices)
			arrays[ArrayMesh.ARRAY_NORMAL] = PackedVector3Array(normals)
			arrays[ArrayMesh.ARRAY_TEX_UV] = PackedVector2Array(uvs)
			arrays[ArrayMesh.ARRAY_INDEX] = indices
		
		if use_box_collision:
			if builder and builder.has_method("build_collision_boxes_from_voxels"):
				collision_boxes = builder.build_collision_boxes_from_voxels(v_bytes, BUILDING_CHUNK_SIZE)
			else:
				collision_boxes = _build_collision_boxes_from_voxels(v_bytes)

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
