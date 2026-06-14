extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")
const WorldMapGeneratorScript = preload("res://world_map_generator/world_map_generator.gd")
const WorldTerrainArtifactBaker = preload("res://world_performance/world_terrain_artifact_baker.gd")
const WorldMapData = preload("res://world_map_data/world_map_data.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	if not _expect(ClassDB.class_exists("MeshBuilder"), "MeshBuilder GDExtension should be available for live terrain bake"):
		return 1
	if not _expect(ClassDB.class_exists("TerrainGrid"), "TerrainGrid GDExtension should be available for live terrain bake"):
		return 1

	var world_path := "user://worlds/world_terrain_artifact_baker_live_%d" % Time.get_ticks_usec()
	var generator: WorldMapGenerator = WorldMapGeneratorScript.new()
	generator.world_seed = 5151
	generator.noise_freq = 0.1
	generator.terrain_height = 10.0
	generator.water_level = 13.0
	generator.road_spacing = 100.0
	generator.road_width = 8.0
	generator.use_grid_roads = false
	generator.deep_lakes_enabled = true
	if not _expect(generator.save_world(world_path, _build_test_images()), "synthetic world should save before live terrain bake"):
		return 1
	WorldMapData.invalidate_world(world_path)
	_write_status(world_path, "world_saved")

	var baker := WorldTerrainArtifactBaker.new()
	_write_status(world_path, "baker_created")
	root.add_child(baker)
	_write_status(world_path, "baker_added_to_tree")
	baker.bake_radius_chunks = 0
	baker.timeout_seconds = 90.0
	baker.store_ready_mesh_resources = true
	baker.synchronous_disk_writes = true
	baker.vertical_layer_radius = 0
	baker.use_disk_radius_shape = true
	baker.offline_cpu_chunks_per_frame = 64
	var bake_origins: Array[Vector3] = [
		Vector3.ZERO,
		Vector3(float(ChunkManagerScript.CHUNK_STRIDE), 0.0, 0.0)
	]
	baker._world_path = world_path
	baker._origin = bake_origins[0]
	baker._origins = bake_origins
	baker._radius = 0
	baker._bake_coords = baker._build_bake_coords_for_origins(
		bake_origins,
		0,
		baker.vertical_layer_radius,
		baker.use_disk_radius_shape
	)
	baker._expected_chunks = baker._bake_coords.size()
	baker._started_usec = Time.get_ticks_usec()
	_write_status(world_path, "offline_bake_configured", {
		"origin_count": bake_origins.size(),
		"expected_chunks": baker._expected_chunks
	})
	baker._create_manager(false)
	_write_status(world_path, "off_tree_manager_created")
	baker._start_offline_cpu_bake("live_smoke_native_offline")
	_write_status(world_path, "offline_bake_started", {
		"offline_active": baker._offline_cpu_bake_active,
		"final_profile": baker.get_profile()
	})
	while baker._offline_cpu_bake_active:
		baker._process_offline_cpu_bake()

	var final_profile: Dictionary = baker.get_profile()
	_write_status(world_path, "offline_bake_finished", final_profile)
	if bool(final_profile.get("failed", false)):
		baker.queue_free()
		return _fail("live terrain artifact bake failed: %s" % str(final_profile.get("failure_reason", "unknown")))
	var artifact_root := WorldMapData.get_world_terrain_artifact_root(world_path)
	var manifest_path := WorldMapData.get_world_terrain_artifact_manifest_path(world_path)
	if not _expect(bool(final_profile.get("completed", false)), "live bake profile should report completion"):
		return 1
	if not _expect(int(final_profile.get("origin_count", 0)) == 2, "live bake profile should report two baked origins"):
		return 1
	if not _expect(int(final_profile.get("artifact_count", 0)) >= 2, "two-origin radius-zero bake should persist ready terrain mesh artifacts"):
		return 1
	if not _expect(int(final_profile.get("native_density_payload_count", 0)) >= 2, "offline live bake should build density payloads in native code"):
		return 1
	if not _expect(int(final_profile.get("gdscript_density_payload_count", 0)) == 0, "offline live bake should not fall back to GDScript density payload loops"):
		return 1
	if not _expect(bool(final_profile.get("offline_cpu_parallel_started", false)), "offline live bake should use the parallel native bake path"):
		return 1
	if not _expect(int(final_profile.get("offline_cpu_parallel_worker_count", 0)) > 0, "parallel live bake should report worker count"):
		return 1
	if not _expect(FileAccess.file_exists(manifest_path), "live bake should write a world-local artifact manifest"):
		return 1
	if not _expect(_count_files_named(artifact_root, "artifact_pack.var") >= 1, "live bake should write a packed terrain artifact payload"):
		return 1
	if not _expect(_count_files_with_extension(artifact_root, ".res") > 0, "ready live bake should write mesh/collision .res sidecars"):
		return 1
	var restore_report := _warm_manager_restore_report(world_path, bake_origins, baker.vertical_layer_radius)
	if not _expect(bool(restore_report.get("ok", false)), "fresh terrain startup should restore the baked artifacts from disk"):
		return 1
	if not _expect(int(restore_report.get("disk_restore_count", 0)) >= 2, "fresh terrain startup should restore ready baked artifacts from disk"):
		return 1
	if not _expect(int(restore_report.get("materialized_mesh_count", 0)) > 0, "fresh terrain startup should materialize at least one compact mesh artifact"):
		return 1
	if not _expect(int(restore_report.get("ready_sidecar_restore_count", 0)) > 0, "fresh terrain startup should find ready mesh sidecars"):
		return 1
	if not _expect(int(restore_report.get("ready_sidecar_materialized_count", 0)) > 0, "fresh terrain startup should load ready mesh sidecars"):
		return 1

	_write_status(world_path, "restore_verified", {
		"artifact_count": int(final_profile.get("artifact_count", 0)),
		"origin_count": int(final_profile.get("origin_count", 0)),
		"manifest_written": bool(final_profile.get("manifest_written", false)),
		"disk_restore_count": int(restore_report.get("disk_restore_count", 0)),
		"materialized_mesh_count": int(restore_report.get("materialized_mesh_count", 0)),
		"ready_sidecar_restore_count": int(restore_report.get("ready_sidecar_restore_count", 0)),
		"ready_sidecar_materialized_count": int(restore_report.get("ready_sidecar_materialized_count", 0)),
		"artifact_root": artifact_root
	})
	print("[WORLD_TERRAIN_ARTIFACT_BAKER_LIVE_SMOKE_TEST] PASS artifacts=%d root=%s" % [
		int(final_profile.get("artifact_count", 0)),
		artifact_root
	])
	return 0


func _warm_manager_restore_report(world_path: String, origins: Array[Vector3], vertical_layer_radius: int) -> Dictionary:
	var report := {
		"ok": true,
		"disk_restore_count": 0,
		"materialized_mesh_count": 0,
		"ready_sidecar_restore_count": 0,
		"ready_sidecar_materialized_count": 0
	}
	var manager := ChunkManagerScript.new()
	manager.mutex = Mutex.new()
	manager.semaphore = Semaphore.new()
	manager.pending_nodes_mutex = Mutex.new()
	manager.cpu_mutex = Mutex.new()
	manager.completed_generation_mutex = Mutex.new()
	manager.stored_modifications_mutex = Mutex.new()
	manager.world_definition_path = world_path
	manager.world_map_active = true
	manager.terrain_artifact_disk_cache_enabled = true
	manager.terrain_artifact_use_world_local_disk_cache = true
	manager.terrain_artifact_disk_cache_entries_per_world = 16
	manager.terrain_artifact_disk_cache_budget_mb = 1024
	manager._prepare_world_definition_cpu_state("live_smoke_restore_check")
	manager._sync_terrain_artifact_cache_configuration()
	manager._sync_terrain_artifact_disk_store_configuration()
	manager._refresh_terrain_artifact_settings_signature()

	for origin in origins:
		var chunk_x := int(floor(origin.x / float(ChunkManagerScript.CHUNK_STRIDE)))
		var chunk_y := int(floor(origin.y / float(ChunkManagerScript.CHUNK_STRIDE)))
		var chunk_z := int(floor(origin.z / float(ChunkManagerScript.CHUNK_STRIDE)))
		for dy in range(-vertical_layer_radius, vertical_layer_radius + 1):
			var coord := Vector3i(chunk_x, chunk_y + dy, chunk_z)
			var task: Dictionary = manager._build_chunk_request_task(
				coord,
				Vector3(
					coord.x * ChunkManagerScript.CHUNK_STRIDE,
					coord.y * ChunkManagerScript.CHUNK_STRIDE,
					coord.z * ChunkManagerScript.CHUNK_STRIDE
				)
			)
			if str(task.get("type", "")) != "restore_artifact":
				manager.free()
				_fail("fresh startup should restore baked artifact for %s but got %s" % [str(coord), str(task.get("type", ""))])
				report["ok"] = false
				return report
			if str(task.get("artifact_source", "")) != "disk":
				manager.free()
				_fail("fresh startup restore for %s should come from disk" % str(coord))
				report["ok"] = false
				return report
			report["disk_restore_count"] = int(report.get("disk_restore_count", 0)) + 1
			var artifact: Dictionary = task.get("artifact", {})
			var terrain_result: Dictionary = artifact.get("result_t", {})
			var before_count := manager._terrain_artifact_ready_resource_restore_count
			var materialized: Dictionary = manager._materialize_deferred_mesh_result(terrain_result, null)
			if materialized.get("mesh", null) is ArrayMesh:
				report["materialized_mesh_count"] = int(report.get("materialized_mesh_count", 0)) + 1
			if bool(terrain_result.get("ready_mesh_resource", false)) and ResourceLoader.exists(str(terrain_result.get("mesh_resource_path", ""))):
				report["ready_sidecar_restore_count"] = int(report.get("ready_sidecar_restore_count", 0)) + 1
				if materialized.get("mesh", null) is ArrayMesh and manager._terrain_artifact_ready_resource_restore_count > before_count:
					report["ready_sidecar_materialized_count"] = int(report.get("ready_sidecar_materialized_count", 0)) + 1

	manager.free()
	return report


func _build_test_images() -> Dictionary:
	var size := 4
	var total := size * size
	var height_bytes := PackedByteArray()
	height_bytes.resize(total)
	var biome_bytes := PackedByteArray()
	biome_bytes.resize(total)
	var road_bytes := PackedByteArray()
	road_bytes.resize(total * 2)
	var water_bytes := PackedByteArray()
	water_bytes.resize(total)
	var building_bytes := PackedByteArray()
	building_bytes.resize(total)

	for index in range(total):
		height_bytes[index] = 96
		biome_bytes[index] = 0
		water_bytes[index] = 0
		building_bytes[index] = 0
		road_bytes[index * 2] = 0
		road_bytes[index * 2 + 1] = 0

	return {
		"heightmap": Image.create_from_data(size, size, false, Image.FORMAT_R8, height_bytes),
		"biomes": Image.create_from_data(size, size, false, Image.FORMAT_R8, biome_bytes),
		"roads": Image.create_from_data(size, size, false, Image.FORMAT_RG8, road_bytes),
		"water": Image.create_from_data(size, size, false, Image.FORMAT_R8, water_bytes),
		"building_map": Image.create_from_data(size, size, false, Image.FORMAT_R8, building_bytes),
		"buildings": [],
		"towns": [],
		"terrain_modifications": []
	}


func _count_files_with_extension(path: String, extension: String) -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	var count := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		var child_path := path.path_join(file_name)
		if dir.current_is_dir():
			count += _count_files_with_extension(child_path, extension)
		elif file_name.ends_with(extension):
			count += 1
		file_name = dir.get_next()
	dir.list_dir_end()
	return count


func _count_files_named(path: String, expected_name: String) -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	var count := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		var child_path := path.path_join(file_name)
		if dir.current_is_dir():
			count += _count_files_named(child_path, expected_name)
		elif file_name == expected_name:
			count += 1
		file_name = dir.get_next()
	dir.list_dir_end()
	return count


func _write_status(world_path: String, stage: String, extra: Dictionary = {}) -> void:
	var status := {
		"stage": stage,
		"msec": Time.get_ticks_msec()
	}
	for key in extra:
		status[key] = extra[key]
	var path := world_path.path_join("live_smoke_status.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(status, "\t"))
		file.close()


func _fail(message: String) -> int:
	printerr("[WORLD_TERRAIN_ARTIFACT_BAKER_LIVE_SMOKE_TEST] FAIL: %s" % message)
	return 1


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	_fail(message)
	return false
