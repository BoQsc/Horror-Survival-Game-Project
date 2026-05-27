extends SceneTree

const VegetationManagerScript := preload("res://world_vegetation/vegetation_manager.gd")

class FakeTerrainManager:
	extends Node3D
	signal chunk_generated(coord: Vector3i, chunk_node: Node3D)
	signal chunk_modified(coord: Vector3i, chunk_node: Node3D)
	signal chunk_unloaded(coord: Vector3i)
	const CHUNK_STRIDE := 16

func _init() -> void:
	call_deferred("_run_deferred")

func _run_deferred() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	var terrain := FakeTerrainManager.new()
	root.add_child(terrain)
	root.add_child(manager)
	manager.terrain_manager = terrain
	manager.global_render_batches_enabled = true
	manager.tree_render_enabled = false
	manager.grass_render_enabled = true
	manager.rock_render_enabled = true
	manager.grass_mesh = manager.create_basic_grass_mesh()
	manager.rock_mesh = manager.create_basic_rock_mesh()

	var coord := Vector2i.ZERO
	var chunk_node := Node3D.new()
	root.add_child(chunk_node)

	var grass: Dictionary = manager._make_vegetation_generated(
		Vector3.ZERO,
		Vector3.ZERO,
		Vector3.ZERO,
		0.0,
		1.0,
		0,
		1.0,
		false,
		Transform3D.IDENTITY
	)
	var grass_mmi = manager._create_chunk_multimesh_handle("grass", coord, manager.grass_mesh)
	manager.chunk_grass_data[coord] = {
		"multimesh": grass_mmi,
		"grass_list": [grass],
		"chunk_node": chunk_node
	}
	manager._sync_multimesh_from_instances(grass_mmi, manager.chunk_grass_data[coord].grass_list, terrain.CHUNK_STRIDE)
	manager._sync_global_vegetation_render_coord_now("grass", coord)
	if not _expect(manager._global_grass_render_instance_count == 1, "initial global grass batch should contain one live grass instance"):
		return 1
	if not _expect(manager._harvest_grass_at_index(coord, 0), "grass harvest should succeed"):
		return 1
	if not _expect(manager._global_grass_render_instance_count == 0, "grass harvest should immediately remove grass from the global render batch"):
		return 1
	if not _expect(not manager._global_grass_render_dirty, "grass harvest refresh should not leave the affected render cluster dirty"):
		return 1

	var rock: Dictionary = manager._make_vegetation_generated(
		Vector3(2.0, 0.0, 0.0),
		Vector3(2.0, 0.0, 0.0),
		Vector3(2.0, 0.0, 0.0),
		0.0,
		1.0,
		0,
		1.0,
		false,
		Transform3D.IDENTITY.translated(Vector3(2.0, 0.0, 0.0))
	)
	var rock_mmi = manager._create_chunk_multimesh_handle("rock", coord, manager.rock_mesh)
	manager.chunk_rock_data[coord] = {
		"multimesh": rock_mmi,
		"rock_list": [rock],
		"chunk_node": chunk_node
	}
	manager._sync_multimesh_from_instances(rock_mmi, manager.chunk_rock_data[coord].rock_list, terrain.CHUNK_STRIDE)
	manager._sync_global_vegetation_render_coord_now("rock", coord)
	if not _expect(manager._global_rock_render_instance_count == 1, "initial global rock batch should contain one live rock instance"):
		return 1
	if not _expect(manager._harvest_rock_at_index(coord, 0), "rock harvest should succeed"):
		return 1
	if not _expect(manager._global_rock_render_instance_count == 0, "rock harvest should immediately remove rock from the global render batch"):
		return 1
	if not _expect(not manager._global_rock_render_dirty, "rock harvest refresh should not leave the affected render cluster dirty"):
		return 1

	manager.free()
	chunk_node.free()
	terrain.free()
	print("[VEGETATION_HARVEST_RENDER_REFRESH_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_HARVEST_RENDER_REFRESH_TEST] FAIL: %s" % message)
	return false
