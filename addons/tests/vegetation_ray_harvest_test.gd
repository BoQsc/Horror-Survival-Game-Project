extends Node

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

func _ready() -> void:
	_run_and_quit()

func _run_and_quit() -> void:
	var exit_code := _run()
	get_tree().quit(exit_code)

func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	var chunk := Node3D.new()
	var coord := Vector2i(0, 0)

	manager.chunk_grass_data[coord] = {
		"chunk_node": chunk,
		"grass_list": [
			{
				"world_pos": Vector3(0.0, 0.0, 3.0),
				"local_pos": Vector3(0.0, 0.0, 3.0),
				"hit_pos": Vector3(0.0, 0.0, 3.0),
				"index": 0,
				"alive": true,
				"transform": Transform3D.IDENTITY
			}
		]
	}
	manager.chunk_rock_data[coord] = {
		"chunk_node": chunk,
		"rock_list": [
			{
				"world_pos": Vector3(0.0, 0.0, 5.0),
				"local_pos": Vector3(0.0, 0.0, 5.0),
				"hit_pos": Vector3(0.0, 0.0, 5.0),
				"index": 0,
				"alive": true,
				"transform": Transform3D.IDENTITY
			}
		]
	}
	manager.chunk_tree_data[coord] = {
		"chunk_node": chunk,
		"trees": [
			{
				"world_pos": Vector3(0.0, 0.0, 7.0),
				"local_pos": Vector3(0.0, 0.0, 7.0),
				"hit_pos": Vector3(0.0, 0.0, 7.0),
				"index": 0,
				"alive": true,
				"scale": 1.0,
				"transform": Transform3D.IDENTITY
			}
		]
	}

	var low_trunk_origin := Vector3(0.0, 1.6, 0.0)
	var low_trunk_direction := (Vector3(0.0, 0.2, 7.0) - low_trunk_origin).normalized()
	var low_trunk_hit := manager.find_nearest_vegetation_along_ray(low_trunk_origin, low_trunk_direction, 10.0, true, false, false)
	if not _expect(low_trunk_hit.get("kind", "") == "tree", "data ray should hit low trunk cylinder, not only tree center"):
		return 1

	var origin := Vector3(0.0, 0.25, 0.0)
	var direction := Vector3(0.0, 0.0, 1.0)
	var result := manager.harvest_nearest_vegetation_along_ray(origin, direction, 10.0, true, true)
	if not _expect(result.get("type", "") == "grass", "nearest ray harvest should pick grass first"):
		return 1
	if not _expect(not bool(manager.chunk_grass_data[coord].grass_list[0].alive), "grass should be marked dead"):
		return 1
	if not _expect(manager.removed_grass.size() == 1, "grass removal should be persisted"):
		return 1

	result = manager.harvest_nearest_vegetation_along_ray(origin, direction, 10.0, true, true)
	if not _expect(result.get("type", "") == "rock", "second ray harvest should pick rock after grass is dead"):
		return 1
	if not _expect(not bool(manager.chunk_rock_data[coord].rock_list[0].alive), "rock should be marked dead"):
		return 1
	if not _expect(manager.removed_rocks.size() == 1, "rock removal should be persisted"):
		return 1

	result = manager.find_nearest_vegetation_along_ray(origin, direction, 10.0, true, true, true)
	if not _expect(result.get("kind", "") == "tree", "data ray should find trees without tree colliders"):
		return 1
	if not _expect(manager.harvest_data_hit(result), "data hit should chop tree"):
		return 1
	if not _expect(not bool(manager.chunk_tree_data[coord].trees[0].alive), "tree should be marked dead"):
		return 1
	if not _expect(manager.chopped_trees.size() == 1, "tree removal should be persisted"):
		return 1

	result = manager.harvest_nearest_vegetation_along_ray(Vector3(2.0, 0.25, 0.0), direction, 10.0, true, true)
	if not _expect(result.is_empty(), "offset ray should miss harvested vegetation"):
		return 1

	manager.free()
	chunk.free()
	print("[VEGETATION_RAY_HARVEST_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_RAY_HARVEST_TEST] FAIL: %s" % message)
	return false
