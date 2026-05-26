extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	manager.global_render_batches_enabled = true
	manager.vegetation_defer_initial_global_render_flush = true
	manager.vegetation_global_render_stream_flush_interval_frames = 1
	manager._global_tree_render_dirty = true
	manager.pending_chunks = [{"coord": Vector2i.ZERO, "stage": 0}]
	manager.is_initial_load_batch = true

	if not _expect(not manager._should_flush_global_vegetation_render_batch(), "initial load should defer dirty cluster flushes while chunks remain pending"):
		manager.free()
		return 1
	if not _expect(int(manager.get_telemetry_snapshot().get("initial_global_render_flush_deferred_count", 0)) == 1, "deferred flush telemetry should increment"):
		manager.free()
		return 1

	manager.pending_chunks.clear()
	if not _expect(manager._should_flush_global_vegetation_render_batch(), "initial load should flush once pending chunks are complete"):
		manager.free()
		return 1

	manager.pending_chunks = [{"coord": Vector2i.ZERO, "stage": 0}]
	manager.is_initial_load_batch = false
	manager._global_tree_render_dirty = true
	if not _expect(manager._should_flush_global_vegetation_render_batch(), "streaming flush interval should still work after initial load"):
		manager.free()
		return 1

	manager.pending_chunks = [{"coord": Vector2i.ZERO, "stage": 0}]
	manager.is_initial_load_batch = false
	manager._initial_chunk_stream_defer_active = true
	manager._global_tree_render_dirty = true
	if not _expect(not manager._should_flush_global_vegetation_render_batch(), "fresh initial terrain chunk stream should defer partial cluster uploads"):
		manager.free()
		return 1
	manager.pending_chunks.clear()
	if not _expect(manager._should_flush_global_vegetation_render_batch(), "fresh initial terrain chunk stream should flush final clusters when complete"):
		manager.free()
		return 1
	if not _expect(not bool(manager.get_telemetry_snapshot().get("initial_chunk_stream_defer_active", true)), "initial chunk stream defer flag should clear after pending chunks drain"):
		manager.free()
		return 1

	manager.free()
	print("[VEGETATION_INITIAL_FLUSH_DEFER_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_INITIAL_FLUSH_DEFER_TEST] FAIL: %s" % message)
	return false
