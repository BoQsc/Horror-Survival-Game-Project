extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var root := get_root()
	var manager := ChunkManagerScript.new()
	var viewer := Node3D.new()
	var camera := Camera3D.new()
	manager.viewer = viewer
	manager.add_child(viewer)
	root.add_child(manager)
	root.add_child(camera)
	camera.current = true
	camera.global_position = Vector3.ZERO
	camera.global_rotation = Vector3.ZERO

	var mesh := _make_triangle_mesh()
	var key := Vector2i(0, -2)
	manager.terrain_render_server_batches_enabled = false
	manager._apply_terrain_visual_batch_mesh(key, [], mesh)
	var fallback_entry: Variant = manager._terrain_visual_batches.get(key, null)
	if not _expect(fallback_entry is MeshInstance3D, "disabled server backend should create a MeshInstance3D fallback batch"):
		return 1
	if not _expect(manager._terrain_visual_batch_entry_mesh(fallback_entry) == mesh, "fallback batch should expose its mesh through the backend helper"):
		return 1
	manager._set_terrain_visual_batch_entry_visible(fallback_entry, false)
	if not _expect(not manager._terrain_visual_batch_entry_visible(fallback_entry), "fallback batch visibility helper should hide the node"):
		return 1
	manager._clear_terrain_visual_batches(true)

	manager.terrain_render_server_batches_enabled = true
	var server_entry := manager._create_terrain_visual_server_batch_entry(key, mesh)
	if server_entry.is_empty():
		if not _expect(manager._terrain_render_server_batch_fallback_count > 0, "unavailable RenderingServer backend should be recorded as a fallback"):
			return 1
	else:
		if not _expect(manager._terrain_visual_batch_entry_is_server(server_entry), "server batch entry should be marked as RenderingServer-backed"):
			return 1
		if not _expect(manager._terrain_visual_batch_entry_mesh(server_entry) == mesh, "server batch entry should keep its mesh resource alive"):
			return 1
		manager._set_terrain_visual_batch_entry_visible(server_entry, false)
		if not _expect(not manager._terrain_visual_batch_entry_visible(server_entry), "server batch visibility helper should track hidden state"):
			return 1
		manager._free_terrain_visual_batch_entry(server_entry, true)

	var front := MeshInstance3D.new()
	var back := MeshInstance3D.new()
	manager.add_child(front)
	manager.add_child(back)
	manager._terrain_visual_batches[Vector2i(0, -2)] = front
	manager._terrain_visual_batches[Vector2i(0, 2)] = back
	manager.terrain_render_visibility_culling_enabled = true
	manager.terrain_render_visibility_near_keep_radius_chunks = 0
	manager.terrain_render_visibility_half_angle_degrees = 60.0
	manager.terrain_render_visibility_update_interval_frames = 0
	manager._sync_terrain_render_visibility()
	if not _expect(front.visible, "front terrain batch should stay visible"):
		return 1
	if not _expect(not back.visible, "rear terrain batch should be hidden by camera-facing culling"):
		return 1
	if not _expect(manager._last_terrain_render_visibility_batch_visible_count == 1, "visibility telemetry should count visible batches"):
		return 1
	if not _expect(manager._last_terrain_render_visibility_batch_hidden_count == 1, "visibility telemetry should count hidden batches"):
		return 1

	manager.queue_free()
	camera.queue_free()
	return 0


func _make_triangle_mesh() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3.ZERO,
		Vector3.RIGHT,
		Vector3.FORWARD
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error("[TERRAIN_RENDER_BACKEND_TEST] " + message)
	return false
