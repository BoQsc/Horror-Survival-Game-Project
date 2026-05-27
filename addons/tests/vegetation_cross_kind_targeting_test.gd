extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	root.add_child(manager)
	manager.tree_visual_targeting_enabled = false
	manager.collision_radius = 1.0
	manager.collision_height = 2.0
	manager.grass_collision_radius = 0.35
	manager.grass_collision_height = 0.5

	var coord := Vector2i.ZERO
	manager.chunk_tree_data[coord] = {
		"trees": [
			manager._make_vegetation_generated(
				Vector3(0.8, 1.0, 1.5),
				Vector3(0.8, 1.0, 1.5),
				Vector3(0.8, 1.0, 1.5),
				0.0,
				1.0,
				0,
				1.0,
				false,
				Transform3D.IDENTITY
			)
		]
	}
	manager.chunk_grass_data[coord] = {
		"grass_list": [
			manager._make_vegetation_generated(
				Vector3(0.0, 1.0, 2.8),
				Vector3(0.0, 1.0, 2.8),
				Vector3(0.0, 1.0, 2.8),
				0.0,
				1.0,
				1,
				1.0,
				false,
				Transform3D.IDENTITY
			)
		]
	}

	var origin := Vector3(0.0, 1.3, 0.0)
	var grass_hit := manager.find_nearest_vegetation_along_ray(origin, Vector3.BACK, 5.0, true, true, true)
	if not _expect(grass_hit.get("kind", "") == "grass", "cross-kind data ray should prefer the aimed grass over a closer off-axis tree radius"):
		return 1

	var tree_dir := (Vector3(0.8, 1.3, 1.5) - origin).normalized()
	var tree_hit := manager.find_nearest_vegetation_along_ray(origin, tree_dir, 5.0, true, true, true)
	if not _expect(tree_hit.get("kind", "") == "tree", "cross-kind data ray should still select tree when the tree is actually aimed"):
		return 1

	manager.chunk_tree_data[coord]["trees"] = [
		manager._make_vegetation_generated(
			Vector3(0.0, 1.0, 1.5),
			Vector3(0.0, 1.0, 1.5),
			Vector3(0.0, 1.0, 1.5),
			0.0,
			1.0,
			2,
			1.0,
			false,
			Transform3D.IDENTITY
		)
	]
	manager.chunk_grass_data[coord]["grass_list"] = [
		manager._make_vegetation_generated(
			Vector3(0.0, 1.0, 2.8),
			Vector3(0.0, 1.0, 2.8),
			Vector3(0.0, 1.0, 2.8),
			0.0,
			1.0,
			3,
			1.0,
			false,
			Transform3D.IDENTITY
		)
	]
	var centered_tree_hit := manager.find_nearest_vegetation_along_ray(origin, Vector3.BACK, 5.0, true, true, true)
	if not _expect(centered_tree_hit.get("kind", "") == "tree", "centered tree should not lose to farther centered grass just because grass has a smaller radius"):
		return 1

	manager.chunk_tree_data.clear()
	manager.chunk_grass_data[coord]["grass_list"] = [
		manager._make_vegetation_generated(
			Vector3(0.24, 1.0, 1.4),
			Vector3(0.24, 1.0, 1.4),
			Vector3(0.24, 1.0, 1.4),
			0.0,
			1.0,
			4,
			1.0,
			false,
			Transform3D.IDENTITY
		),
		manager._make_vegetation_generated(
			Vector3(0.0, 1.0, 2.8),
			Vector3(0.0, 1.0, 2.8),
			Vector3(0.0, 1.0, 2.8),
			0.0,
			1.0,
			5,
			1.0,
			false,
			Transform3D.IDENTITY
		)
	]
	var same_kind_hit := manager.find_nearest_vegetation_along_ray(origin, Vector3.BACK, 5.0, true, true, true)
	if not _expect(int(same_kind_hit.get("index", -1)) == 5, "same-kind data ray should prefer centered aimed grass over closer off-axis grass"):
		return 1

	manager.free()
	print("[VEGETATION_CROSS_KIND_TARGETING_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_CROSS_KIND_TARGETING_TEST] FAIL: %s" % message)
	return false
