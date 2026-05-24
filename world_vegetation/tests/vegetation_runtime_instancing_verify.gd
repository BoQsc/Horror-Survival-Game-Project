extends SceneTree

const VegetationRegistry = preload("res://world_vegetation/types/vegetation_registry.gd")
const VegetationRuntime = preload("res://world_vegetation/runtime/vegetation_runtime.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var builder: Object = ClassDB.instantiate("VegetationChunkBuilder")
	if builder == null or not builder.has_method("build_multimesh_transform_buffer"):
		push_error("Expected VegetationChunkBuilder.build_multimesh_transform_buffer to be registered")
		quit(1)
		return
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
		"profile": &"world_dense",
		"initial_stream_radius_chunks": 1,
		"active_stream_radius_chunks": 1,
		"max_generations_per_frame": 64,
		"max_rebuilds_per_frame": 64,
		"max_render_cluster_rebuilds_per_frame": 64,
		"use_instanced_render_clusters": true,
		"use_instanced_grass_clusters": true,
		"camera_cull_chunk_mesh_records": false
	})
	runtime.bootstrap()
	for _i in range(12):
		await process_frame
	var telemetry := runtime.get_telemetry_snapshot()
	var renderer_stats: Dictionary = telemetry.get("renderer", {})
	var multimesh_count := int(renderer_stats.get("multimesh_count", 0))
	var instanced_records := int(telemetry.get("global_instanced_render_instances", 0))
	runtime.clear_for_shutdown()
	host.queue_free()
	if multimesh_count <= 0 or instanced_records <= 0:
		push_error("Expected runtime instanced vegetation, got multimeshes=%d instances=%d" % [multimesh_count, instanced_records])
		quit(1)
		return
	print("vegetation_runtime_instancing_verify: ok multimeshes=%d instances=%d" % [multimesh_count, instanced_records])
	quit(0)
