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
	manager.tree_render_enabled = true
	manager.grass_render_enabled = false
	manager.rock_render_enabled = false
	manager.tree_mesh = manager.create_basic_tree_mesh()

	var coord := Vector2i.ZERO
	var chunk_node := Node3D.new()
	root.add_child(chunk_node)
	var tree: Dictionary = manager._make_vegetation_generated(
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
	var mmi = manager._create_chunk_multimesh_handle("tree", coord, manager.tree_mesh)
	manager.chunk_tree_data[coord] = {
		"multimesh": mmi,
		"trees": [tree],
		"chunk_node": chunk_node
	}

	manager._sync_multimesh_from_instances(mmi, manager.chunk_tree_data[coord].trees, terrain.CHUNK_STRIDE)
	manager._sync_global_vegetation_render_coord_now("tree", coord)
	if not _expect(manager._global_tree_render_instance_count == 1, "initial global tree batch should contain one live tree"):
		return 1

	if not _expect(manager.chop_tree_at_index(coord, 0), "tree chop should succeed"):
		return 1
	if not _expect(manager._global_tree_render_instance_count == 0, "tree chop should immediately remove the tree from the global render batch"):
		return 1
	if not _expect(not manager._global_tree_render_dirty, "tree chop refresh should not leave the affected render cluster dirty"):
		return 1

	manager.free()
	chunk_node.free()
	terrain.free()
	print("[VEGETATION_TREE_CHOP_RENDER_REFRESH_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_TREE_CHOP_RENDER_REFRESH_TEST] FAIL: %s" % message)
	return false
