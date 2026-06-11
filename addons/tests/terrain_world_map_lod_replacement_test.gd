extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var manager := ChunkManagerScript.new()
	if not _expect(not manager.distant_world_map_lod_enabled, "world-map LOD must be opt-in by default"):
		manager.free()
		return 1
	if not _expect(not manager.world_map_lod_replace_active_chunks_enabled, "active chunk LOD replacement must be opt-in by default"):
		manager.free()
		return 1

	var viewer := Node3D.new()
	viewer.position = Vector3.ZERO
	manager.viewer = viewer
	manager.world_map_active = true
	manager.distant_world_map_lod_enabled = true
	manager.world_map_lod_replace_active_chunks_enabled = true
	manager.render_distance = 10
	manager.distant_world_map_lod_distance = 10
	manager.world_map_lod_full_res_visual_radius_chunks = 5
	manager._world_map_heightmap_data = PackedByteArray([1])
	manager._world_map_heightmap_width = 1
	manager._world_map_heightmap_height = 1

	if not _expect(manager._world_map_lod_inner_distance() == 5, "full-res inner LOD distance should use replacement radius"):
		return _cleanup_and_fail(manager, viewer)
	if not _expect(manager._world_map_lod_outer_distance() == 10, "LOD outer distance should cover active render distance"):
		return _cleanup_and_fail(manager, viewer)

	var near_coord := Vector3i(5, 0, 0)
	var far_coord := Vector3i(6, 0, 0)
	var edited_far_coord := Vector3i(7, 0, 0)
	manager.active_chunks[near_coord] = _make_chunk_data()
	manager.active_chunks[far_coord] = _make_chunk_data()
	var edited_data = _make_chunk_data()
	edited_data.mod_version = 1
	manager.active_chunks[edited_far_coord] = edited_data

	if not _expect(not manager._wants_active_world_map_lod_replacement(near_coord), "near chunk must stay full resolution"):
		return _cleanup_and_fail(manager, viewer)
	if not _expect(manager._wants_active_world_map_lod_replacement(far_coord), "far unmodified chunk should request LOD replacement"):
		return _cleanup_and_fail(manager, viewer)
	if not _expect(not manager._should_replace_active_world_map_chunk_with_lod(far_coord), "far chunk should not hide before LOD visual exists"):
		return _cleanup_and_fail(manager, viewer)
	if not _expect(not manager._wants_active_world_map_lod_replacement(edited_far_coord), "edited chunks must not use world-map LOD replacement"):
		return _cleanup_and_fail(manager, viewer)

	var lod_node := MeshInstance3D.new()
	manager._world_map_lod_chunks[Vector2i(far_coord.x, far_coord.z)] = lod_node
	if not _expect(manager._should_replace_active_world_map_chunk_with_lod(far_coord), "far chunk should replace once LOD visual exists"):
		lod_node.free()
		return _cleanup_and_fail(manager, viewer)

	manager._set_chunk_mesh_lod_replaced(manager.active_chunks[far_coord], far_coord, true)
	if not _expect(int(manager._count_world_map_lod_replaced_terrain_chunks()) == 1, "replacement counter should report one hidden full-res chunk"):
		lod_node.free()
		return _cleanup_and_fail(manager, viewer)

	lod_node.free()
	_cleanup(manager, viewer)
	print("[TERRAIN_WORLD_MAP_LOD_REPLACEMENT_TEST] PASS")
	return 0

func _make_chunk_data():
	var data = ChunkManagerScript.ChunkData.new()
	data.node_terrain = Node3D.new()
	return data

func _cleanup_and_fail(manager, viewer: Node) -> int:
	_cleanup(manager, viewer)
	return 1

func _cleanup(manager, viewer: Node) -> void:
	if manager:
		for data_variant in manager.active_chunks.values():
			var data = data_variant
			if data != null and data.node_terrain != null and is_instance_valid(data.node_terrain):
				data.node_terrain.free()
				data.node_terrain = null
		manager.free()
	if viewer:
		viewer.free()

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_WORLD_MAP_LOD_REPLACEMENT_TEST] FAIL: %s" % message)
	return false
