extends SceneTree

const VegetationManagerScript := preload("res://world_vegetation/vegetation_manager.gd")


class FakeTerrainManager:
	extends Node3D

	const CHUNK_STRIDE := 16

	var world_seed: int = 12345
	var world_definition_path: String = ""
	var world_map_active: bool = false
	var water_level: float = 0.0
	var procedural_roads_enabled: bool = true
	var procedural_road_spacing: float = 32.0
	var procedural_road_width: float = 4.0
	var initial_load_phase: bool = false
	var modified: bool = false

	func has_modifications_at_xz(_x: int, _z: int) -> bool:
		return modified


func _init() -> void:
	call_deferred("_run_deferred")


func _run_deferred() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	var terrain := FakeTerrainManager.new()
	root.add_child(terrain)
	manager.terrain_manager = terrain
	manager.global_render_batches_enabled = true
	manager.tree_render_enabled = false
	manager.grass_render_enabled = false
	manager.rock_render_enabled = false
	manager.tree_mesh = manager.create_basic_tree_mesh()
	manager.grass_mesh = manager.create_basic_grass_mesh()
	manager.rock_mesh = manager.create_basic_rock_mesh()

	var coord := Vector2i.ZERO
	var chunk_node := Node3D.new()
	root.add_child(chunk_node)
	_populate_chunk(manager, coord, chunk_node)
	manager._on_chunk_unloaded(Vector3i(coord.x, 0, coord.y))

	if not _expect(manager.chunk_tree_data.is_empty(), "unload should release active tree data"):
		return 1
	if not _expect(manager._vegetation_chunk_placement_cache.size() == 1, "complete unchanged chunk should enter the placement cache"):
		return 1

	var restored_chunk_node := Node3D.new()
	root.add_child(restored_chunk_node)
	manager._on_chunk_generated(Vector3i(coord.x, 0, coord.y), restored_chunk_node)
	if not _expect(manager.pending_chunks.is_empty(), "cache hit should skip the three-stage placement queue"):
		return 1
	if not _expect(manager.chunk_tree_data.has(coord) and manager.chunk_grass_data.has(coord) and manager.chunk_rock_data.has(coord), "cache hit should restore all vegetation kinds"):
		return 1
	if not _expect(manager.chunk_tree_data[coord].trees.size() == 1, "tree placement should restore"):
		return 1
	if not _expect(manager.chunk_grass_data[coord].grass_list.size() == 1, "grass placement should restore"):
		return 1
	if not _expect(manager.chunk_rock_data[coord].rock_list.size() == 1, "rock placement should restore"):
		return 1

	var telemetry := manager.get_telemetry_snapshot()
	if not _expect(int(telemetry.get("vegetation_chunk_placement_cache_hits", 0)) == 1, "cache hit telemetry should increment"):
		return 1
	if not _expect(int(telemetry.get("vegetation_chunk_placement_cache_restored_instances", 0)) == 3, "restored instance telemetry should increment"):
		return 1

	manager._on_chunk_unloaded(Vector3i(coord.x, 0, coord.y))
	manager._on_chunk_modified(Vector3i(coord.x, 0, coord.y), restored_chunk_node)
	if not _expect(manager._vegetation_chunk_placement_cache.is_empty(), "terrain edit should invalidate cached vegetation"):
		return 1

	_populate_chunk(manager, coord, restored_chunk_node)
	manager._on_chunk_unloaded(Vector3i(coord.x, 0, coord.y))
	manager.grass_sample_step += 1
	var settings_changed_chunk_node := Node3D.new()
	root.add_child(settings_changed_chunk_node)
	manager._on_chunk_generated(Vector3i(coord.x, 0, coord.y), settings_changed_chunk_node)
	if not _expect(manager.pending_chunks.size() == 1, "settings mismatch should fall back to placement generation"):
		return 1
	if not _expect(manager._vegetation_chunk_placement_cache.is_empty(), "settings mismatch should discard stale cache entry"):
		return 1

	manager.clear_loaded_chunk_data()
	manager.vegetation_chunk_placement_cache_max_instances = 2
	_populate_chunk(manager, coord, settings_changed_chunk_node)
	manager._on_chunk_unloaded(Vector3i(coord.x, 0, coord.y))
	if not _expect(manager._vegetation_chunk_placement_cache.is_empty(), "oversize chunk should not enter the cache"):
		return 1
	if not _expect(manager._vegetation_chunk_placement_cache_oversize_skips == 1, "oversize skip telemetry should increment"):
		return 1

	manager.free()
	root.remove_child(terrain)
	root.remove_child(chunk_node)
	root.remove_child(restored_chunk_node)
	root.remove_child(settings_changed_chunk_node)
	terrain.free()
	chunk_node.free()
	restored_chunk_node.free()
	settings_changed_chunk_node.free()
	print("[VEGETATION_CHUNK_PLACEMENT_CACHE_TEST] PASS")
	return 0


func _populate_chunk(manager: VegetationManager, coord: Vector2i, chunk_node: Node3D) -> void:
	var tree: Dictionary = manager._make_vegetation_generated(
		Vector3(1.0, 0.0, 1.0),
		Vector3(1.0, 0.0, 1.0),
		Vector3(1.0, 0.0, 1.0),
		0.0,
		1.0,
		0,
		1.0,
		false,
		Transform3D.IDENTITY.translated(Vector3(1.0, 0.0, 1.0))
	)
	var grass: Dictionary = manager._make_vegetation_generated(
		Vector3(2.0, 0.0, 2.0),
		Vector3(2.0, 0.0, 2.0),
		Vector3(2.0, 0.0, 2.0),
		0.0,
		1.0,
		0,
		1.0,
		false,
		Transform3D.IDENTITY.translated(Vector3(2.0, 0.0, 2.0))
	)
	var rock: Dictionary = manager._make_vegetation_generated(
		Vector3(3.0, 0.0, 3.0),
		Vector3(3.0, 0.0, 3.0),
		Vector3(3.0, 0.0, 3.0),
		0.0,
		1.0,
		0,
		1.0,
		false,
		Transform3D.IDENTITY.translated(Vector3(3.0, 0.0, 3.0))
	)
	manager.chunk_tree_data[coord] = {
		"multimesh": manager._create_chunk_multimesh_handle("tree", coord, manager.tree_mesh),
		"trees": [tree],
		"chunk_node": chunk_node
	}
	manager.chunk_grass_data[coord] = {
		"multimesh": manager._create_chunk_multimesh_handle("grass", coord, manager.grass_mesh),
		"grass_list": [grass],
		"chunk_node": chunk_node
	}
	manager.chunk_rock_data[coord] = {
		"multimesh": manager._create_chunk_multimesh_handle("rock", coord, manager.rock_mesh),
		"rock_list": [rock],
		"chunk_node": chunk_node
	}


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_CHUNK_PLACEMENT_CACHE_TEST] FAIL: %s" % message)
	return false
