extends SceneTree

const VegetationRegistry = preload("res://world_vegetation/types/vegetation_registry.gd")
const VegetationRuntime = preload("res://world_vegetation/runtime/vegetation_runtime.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node3D.new()
	root.add_child(host)

	var runtime: VegetationRuntime = VegetationRuntime.new()
	host.add_child(runtime)
	runtime.configure({
		"registry": VegetationRegistry.create_default(),
		"use_mock_terrain": true,
		"render_enabled": true,
		"enable_streaming": true,
		"auto_spawn_benchmark_content": true,
		"profile": &"world_dense_max_trees",
		"initial_stream_radius_chunks": 1,
		"active_stream_radius_chunks": 1,
		"max_generations_per_frame": 128,
		"max_rebuilds_per_frame": 128,
		"max_render_cluster_rebuilds_per_frame": 128,
		"initial_generation_budget_ms": 0.0,
		"initial_rebuild_budget_ms": 0.0,
		"initial_render_upload_budget_ms": 0.0,
		"use_instanced_render_clusters": false,
		"use_instanced_grass_clusters": false,
		"camera_cull_chunk_mesh_records": false
	})
	runtime.bootstrap()

	for _i in range(16):
		await process_frame

	var telemetry := runtime.get_telemetry_snapshot()
	var renderer_stats: Dictionary = telemetry.get("renderer", {})
	var multimesh_count := int(renderer_stats.get("multimesh_count", 0))
	var chunk_mesh_count := int(renderer_stats.get("chunk_mesh_count", 0))
	var chunk_instance_count := int(renderer_stats.get("chunk_instance_count", 0))
	var chunk_batches := int(telemetry.get("global_chunk_mesh_render_batch_count", 0))
	var vegetation_instances := int(telemetry.get("global_grass_render_instances", 0)) \
		+ int(telemetry.get("global_tree_render_instances", 0)) \
		+ int(telemetry.get("global_bush_render_instances", 0)) \
		+ int(telemetry.get("global_rock_render_instances", 0))

	runtime.clear_for_shutdown()
	host.queue_free()

	if multimesh_count != 0:
		push_error("Expected chunk-mesh runtime to avoid MultiMesh, got %d MultiMeshes" % multimesh_count)
		quit(1)
		return
	if chunk_mesh_count <= 0 or chunk_instance_count <= 0 or chunk_batches <= 0 or vegetation_instances <= 0:
		push_error("Expected chunk-mesh vegetation, meshes=%d instances=%d batches=%d vegetation=%d" % [
			chunk_mesh_count,
			chunk_instance_count,
			chunk_batches,
			vegetation_instances
		])
		quit(1)
		return

	print("vegetation_runtime_chunk_mesh_verify: ok meshes=%d batches=%d vegetation=%d" % [
		chunk_mesh_count,
		chunk_batches,
		vegetation_instances
	])
	quit(0)
