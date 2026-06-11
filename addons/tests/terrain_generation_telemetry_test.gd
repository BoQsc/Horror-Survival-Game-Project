extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var manager := ChunkManagerScript.new()
	manager.begin_terrain_measurement_window("startup")
	manager._record_terrain_generation_complete(Vector3i(0, 0, 0), 0, true)
	manager._complete_initial_load_measurement("test")
	manager.begin_terrain_measurement_window("revisit")
	manager._record_terrain_generation_complete(Vector3i(1, 0, 1), 0, true)
	manager._record_terrain_generation_complete(Vector3i(1, 0, 1), 0, true)
	manager._record_terrain_generation_complete(Vector3i(2, 0, 1), 3, false)
	manager._gpu_generation_batch_count += 2
	manager._gpu_generation_batch_chunk_total += 7
	manager._gpu_generation_batch_total_ms += 12.0
	manager._gpu_generation_sync_total_ms += 3.0
	manager._gpu_meshing_sync_total_ms += 2.0
	manager._gpu_mesh_readback_total_ms += 4.0

	var window: Dictionary = manager.get_terrain_measurement_window_snapshot()
	if not _expect(str(window.get("label", "")) == "revisit", "measurement window label should be retained"):
		return 1
	if not _expect(int(window.get("generation_complete_count", 0)) == 3, "generation completions should be counted"):
		return 1
	if not _expect(int(window.get("generation_repeat_count", 0)) == 1, "repeat generation should be counted"):
		return 1
	if not _expect(int(window.get("generation_discarded_count", 0)) == 1, "discarded generation should be counted"):
		return 1
	if not _expect(int(window.get("gpu_generation_batch_count", 0)) == 2, "GPU generation batches should be counted per measurement window"):
		return 1
	if not _expect(int(window.get("gpu_generation_batch_chunk_count", 0)) == 7, "GPU generation batch chunks should be counted"):
		return 1
	if not _expect(is_equal_approx(float(window.get("gpu_generation_batch_avg_ms", 0.0)), 6.0), "GPU generation batch average should be reported"):
		return 1
	if not _expect(is_equal_approx(float(window.get("gpu_mesh_readback_total_ms", 0.0)), 4.0), "GPU mesh readback total should be reported"):
		return 1

	var initial_window: Dictionary = manager._terrain_initial_load_measurement
	if not _expect(int(initial_window.get("generation_complete_count", 0)) == 1, "initial load measurement should be retained"):
		return 1
	if not _expect(manager._terrain_measurement_window_history.size() == 1, "completed measurement windows should be retained"):
		return 1

	var trace: Dictionary = manager._terrain_trace.get_snapshot()
	var event_counts: Dictionary = trace.get("event_counts", {})
	if not _expect(int(event_counts.get("chunk_generation_completed", 0)) == 2, "noteworthy generation events should be traced"):
		return 1

	manager.stored_modifications_mutex = Mutex.new()
	manager._terrain_artifact_cache.configure(true, 1024 * 1024, 8)
	manager.terrain_artifact_disk_cache_enabled = true
	manager.terrain_artifact_disk_cache_path = "user://terrain_generation_telemetry_artifacts_%d" % Time.get_ticks_usec()
	manager.terrain_artifact_disk_cache_entries_per_world = 8
	manager._refresh_terrain_artifact_settings_signature()
	var artifact_bytes := PackedByteArray()
	artifact_bytes.resize(manager._get_terrain_artifact_buffer_bytes())
	var artifact_coord := Vector3i(4, 0, 4)
	manager._store_terrain_artifact_from_generation(
		artifact_coord,
		{"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array()},
		{"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array(), "generated_density": true},
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedByteArray(),
		0,
		{
			"artifact_density_bytes_terrain": artifact_bytes,
			"artifact_density_bytes_water": artifact_bytes,
			"artifact_material_bytes_terrain": artifact_bytes
		}
	)
	var restore_task: Dictionary = manager._build_chunk_request_task(artifact_coord, Vector3.ZERO)
	if not _expect(str(restore_task.get("type", "")) == "restore_artifact", "cached chunk should request artifact restore"):
		return 1
	manager._terrain_artifact_cache.clear("test")
	var disk_restore_task: Dictionary = manager._build_chunk_request_task(artifact_coord, Vector3.ZERO)
	if not _expect(str(disk_restore_task.get("type", "")) == "restore_artifact", "disk artifact should restore after session clear"):
		return 1
	if not _expect(str(disk_restore_task.get("artifact_source", "")) == "disk", "disk restore should record its source"):
		return 1
	manager.terrain_artifact_cache_enabled = false
	var disabled_task: Dictionary = manager._build_chunk_request_task(artifact_coord, Vector3.ZERO)
	if not _expect(str(disabled_task.get("type", "")) == "restore_artifact", "disk cache should still restore when session cache is disabled"):
		return 1
	if not _expect(str(disabled_task.get("artifact_source", "")) == "disk", "disabled session cache should fall through to disk"):
		return 1
	manager.terrain_artifact_cache_enabled = true
	manager.terrain_artifact_disk_cache_enabled = false
	manager._invalidate_terrain_artifact(artifact_coord, "test")
	var generate_task: Dictionary = manager._build_chunk_request_task(artifact_coord, Vector3.ZERO)
	if not _expect(str(generate_task.get("type", "")) == "generate", "invalidated chunk should request generation"):
		return 1

	manager.terrain_artifact_disk_cache_enabled = true
	manager.initial_load_phase = true
	if not _expect(manager._terrain_artifact_disk_write_queue.start(manager._terrain_artifact_disk_writer_store), "async disk writer should start"):
		return 1
	var async_coord := Vector3i(7, 0, 7)
	manager._store_terrain_artifact_from_generation(
		async_coord,
		{"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array()},
		{"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array(), "generated_density": true},
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedByteArray(),
		0,
		{
			"artifact_density_bytes_terrain": artifact_bytes,
			"artifact_density_bytes_water": artifact_bytes,
			"artifact_material_bytes_terrain": artifact_bytes
		}
	)
	var async_queue_snapshot: Dictionary = manager._terrain_artifact_disk_write_queue.get_snapshot()
	manager._terrain_artifact_disk_write_queue.shutdown(true)
	if not _expect(int(async_queue_snapshot.get("enqueue_count", 0)) == 1, "eligible artifact should enqueue for async disk persistence"):
		return 1
	manager._terrain_artifact_cache.clear("test")
	var async_disk_restore_task: Dictionary = manager._build_chunk_request_task(async_coord, Vector3.ZERO)
	if not _expect(str(async_disk_restore_task.get("artifact_source", "")) == "disk", "async writer artifact should restore through the foreground disk store"):
		return 1

	manager._terrain_artifact_cache.clear("test")
	manager._terrain_artifact_disk_store.clear_all()
	manager.initial_load_phase = false
	if not _expect(not manager.terrain_artifact_disk_store_runtime_chunks, "runtime disk writes should be disabled by default"):
		return 1
	var runtime_coord := Vector3i(5, 0, 5)
	manager._store_terrain_artifact_from_generation(
		runtime_coord,
		{"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array()},
		{"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array(), "generated_density": true},
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedByteArray(),
		0,
		{
			"artifact_density_bytes_terrain": artifact_bytes,
			"artifact_density_bytes_water": artifact_bytes,
			"artifact_material_bytes_terrain": artifact_bytes
		}
	)
	manager._terrain_artifact_cache.clear("test")
	var runtime_task: Dictionary = manager._build_chunk_request_task(runtime_coord, Vector3.ZERO)
	if not _expect(str(runtime_task.get("type", "")) == "generate", "runtime disk writes should not add gameplay disk work by default"):
		return 1

	manager.terrain_artifact_disk_store_runtime_chunks = true
	manager._terrain_artifact_cache.clear("test")
	manager._terrain_artifact_disk_store.clear_all()
	var enabled_runtime_coord := Vector3i(8, 0, 8)
	manager._store_terrain_artifact_from_generation(
		enabled_runtime_coord,
		{"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array()},
		{"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array(), "generated_density": true},
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedByteArray(),
		0,
		{
			"artifact_density_bytes_terrain": artifact_bytes,
			"artifact_density_bytes_water": artifact_bytes,
			"artifact_material_bytes_terrain": artifact_bytes
		}
	)
	manager._terrain_artifact_cache.clear("test")
	var enabled_runtime_task: Dictionary = manager._build_chunk_request_task(enabled_runtime_coord, Vector3.ZERO)
	if not _expect(str(enabled_runtime_task.get("type", "")) == "restore_artifact", "runtime disk writes should restore when explicitly enabled"):
		return 1
	if not _expect(str(enabled_runtime_task.get("artifact_source", "")) == "disk", "explicit runtime artifact restore should record disk source"):
		return 1
	manager.terrain_artifact_disk_store_runtime_chunks = false

	manager.terrain_artifact_disk_cache_enabled = false
	manager._terrain_artifact_cache.clear("test")
	var edited_coord := Vector3i(6, 0, 6)
	manager.stored_modifications[edited_coord] = [{"layer": 0, "value": 1.0}]
	var edited_data = ChunkManagerScript.ChunkData.new()
	if not _expect(
		manager._store_terrain_artifact_after_edit(
			edited_coord,
			edited_data,
			1,
			artifact_bytes,
			artifact_bytes,
			artifact_bytes
		),
		"completed edit should refresh its session artifact"
	):
		return 1
	var edited_restore_task: Dictionary = manager._build_chunk_request_task(edited_coord, Vector3.ZERO)
	if not _expect(str(edited_restore_task.get("type", "")) == "restore_artifact", "edited chunk should restore without first-revisit generation"):
		return 1
	var edited_artifact: Dictionary = edited_restore_task.get("artifact", {})
	if not _expect(int(edited_artifact.get("stored_mod_version", 0)) == 1, "edited artifact should retain the current modification version"):
		return 1
	if not _expect(int(manager._terrain_artifact_edit_refresh_count) == 1, "edit artifact refresh should be counted"):
		return 1

	var triangle_arrays := []
	triangle_arrays.resize(Mesh.ARRAY_MAX)
	triangle_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3.ZERO,
		Vector3.RIGHT,
		Vector3.FORWARD
	])
	triangle_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var session_ready_coord := Vector3i(12, 0, 12)
	manager._store_terrain_artifact_from_generation(
		session_ready_coord,
		{
			"deferred_mesh_data": true,
			"arrays": triangle_arrays,
			"faces": PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.FORWARD])
		},
		{"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array(), "generated_density": true},
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedByteArray(),
		0,
		{
			"artifact_density_bytes_terrain": artifact_bytes,
			"artifact_density_bytes_water": artifact_bytes,
			"artifact_material_bytes_terrain": artifact_bytes
		}
	)
	var session_ready_task: Dictionary = manager._build_chunk_request_task(session_ready_coord, Vector3.ZERO)
	var session_ready_artifact: Dictionary = session_ready_task.get("artifact", {})
	var session_ready_result: Dictionary = session_ready_artifact.get("result_t", {})
	if not _expect(session_ready_result.get("mesh_resource", null) is ArrayMesh, "session artifact should keep the ready mesh resource"):
		return 1
	if not _expect(session_ready_result.get("shape_resource", null) is ConcavePolygonShape3D, "session artifact should keep the ready collision resource"):
		return 1

	manager.terrain_artifact_disk_cache_enabled = true
	manager.initial_load_phase = true
	manager._terrain_artifact_disk_store.clear_all()
	manager._terrain_artifact_cache.clear("test")
	var disk_ready_coord := Vector3i(13, 0, 12)
	manager._store_terrain_artifact_from_generation(
		disk_ready_coord,
		{
			"deferred_mesh_data": true,
			"arrays": triangle_arrays,
			"faces": PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.FORWARD])
		},
		{"deferred_mesh_data": true, "arrays": [], "faces": PackedVector3Array(), "generated_density": true},
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedByteArray(),
		0,
		{
			"artifact_density_bytes_terrain": artifact_bytes,
			"artifact_density_bytes_water": artifact_bytes,
			"artifact_material_bytes_terrain": artifact_bytes
		}
	)
	manager._terrain_artifact_cache.clear("test")
	var disk_ready_task: Dictionary = manager._build_chunk_request_task(disk_ready_coord, Vector3.ZERO)
	if not _expect(str(disk_ready_task.get("artifact_source", "")) == "disk", "ready sidecar artifact should restore from disk after session clear"):
		return 1
	var disk_ready_artifact: Dictionary = disk_ready_task.get("artifact", {})
	var disk_ready_result: Dictionary = disk_ready_artifact.get("result_t", {})
	if not _expect(not disk_ready_result.has("mesh_resource"), "disk sidecar artifact should not embed mesh resources"):
		return 1
	if not _expect(ResourceLoader.exists(str(disk_ready_result.get("mesh_resource_path", ""))), "disk sidecar artifact should keep a loadable mesh path"):
		return 1
	if not _expect(ResourceLoader.exists(str(disk_ready_result.get("shape_resource_path", ""))), "disk sidecar artifact should keep a loadable collision path"):
		return 1
	var disk_ready_restore_count_before := manager._terrain_artifact_ready_resource_restore_count
	var disk_ready_materialized := manager._materialize_deferred_mesh_result(disk_ready_result, null)
	if not _expect(disk_ready_materialized.get("mesh", null) is ArrayMesh, "disk sidecar restore should load the ready mesh resource"):
		return 1
	if not _expect(disk_ready_materialized.get("shape", null) is ConcavePolygonShape3D, "disk sidecar restore should load the ready collision resource"):
		return 1
	if not _expect(manager._terrain_artifact_ready_resource_restore_count == disk_ready_restore_count_before + 1, "disk sidecar ready restore should be counted"):
		return 1
	manager.terrain_artifact_disk_cache_enabled = false

	var materialized: Dictionary = manager._materialize_deferred_mesh_result(
		{
			"deferred_mesh_data": true,
			"arrays": triangle_arrays,
			"faces": PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.FORWARD])
		},
		null
	)
	var materialized_mesh := materialized.get("mesh", null) as ArrayMesh
	if not _expect(materialized_mesh != null and materialized_mesh.get_surface_count() == 1, "deferred artifact arrays should rebuild an ArrayMesh surface"):
		return 1
	var materialized_shape := materialized.get("shape", null) as ConcavePolygonShape3D
	if not _expect(materialized_shape != null and materialized_shape.get_faces().size() == 3, "deferred artifact faces should rebuild collision shape data"):
		return 1

	var ready_artifact_result := manager._mesh_result_to_artifact_data({
		"deferred_mesh_data": true,
		"arrays": triangle_arrays,
		"faces": PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.FORWARD])
	})
	if not _expect(bool(ready_artifact_result.get("ready_mesh_resource", false)), "artifact conversion should store a ready ArrayMesh resource"):
		return 1
	if not _expect(ready_artifact_result.get("mesh_resource", null) is ArrayMesh, "ready artifact should carry the mesh resource"):
		return 1
	if not _expect(ready_artifact_result.get("shape_resource", null) is ConcavePolygonShape3D, "ready artifact should carry the collision shape resource"):
		return 1
	var ready_restore_count_before := manager._terrain_artifact_ready_resource_restore_count
	var ready_materialized: Dictionary = manager._materialize_deferred_mesh_result(ready_artifact_result, null)
	if not _expect(ready_materialized.get("mesh", null) is ArrayMesh, "ready artifact restore should reuse the ArrayMesh resource"):
		return 1
	if not _expect(ready_materialized.get("shape", null) is ConcavePolygonShape3D, "ready artifact restore should reuse the collision shape resource"):
		return 1
	if not _expect(manager._terrain_artifact_ready_resource_restore_count == ready_restore_count_before + 1, "ready resource restore path should be counted"):
		return 1

	manager._terrain_artifact_disk_store.clear_all()
	manager.free()
	print("[TERRAIN_GENERATION_TELEMETRY_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_GENERATION_TELEMETRY_TEST] FAIL: %s" % message)
	return false
