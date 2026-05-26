extends SceneTree

const CombatSystemScript = preload("res://modules/world_player_v2/features/tool_combat/combat_system.gd")

class FakePlayer:
	extends Node

	var ray_hit: Dictionary = {}

	func raycast(_distance: float, _mask: int, _collide_with_areas: bool, _exclude_water: bool) -> Dictionary:
		return ray_hit

	func get_camera_position() -> Vector3:
		return Vector3.ZERO

	func get_look_direction() -> Vector3:
		return Vector3.FORWARD

class FakeVegetationManager:
	extends Node

	var query_count: int = 0
	var chopped_count: int = 0
	var tree_distance: float = 2.0
	var grass_distance: float = INF
	var harvested_kind: String = ""

	func find_nearest_vegetation_along_ray(
			_origin: Vector3,
			_direction: Vector3,
			_max_distance: float,
			include_trees: bool = true,
			include_grass: bool = true,
			include_rocks: bool = true
	) -> Dictionary:
		query_count += 1
		var best_hit: Dictionary = {}
		if include_trees and tree_distance <= _max_distance:
			best_hit = {
				"kind": "tree",
				"coord": Vector2i.ZERO,
				"index": 0,
				"position": Vector3(0.0, 1.0, tree_distance),
				"distance": tree_distance
			}
		if include_grass and is_finite(grass_distance) and grass_distance <= _max_distance:
			var grass_hit := {
				"kind": "grass",
				"coord": Vector2i.ZERO,
				"index": 0,
				"position": Vector3(0.0, 0.2, grass_distance),
				"distance": grass_distance
			}
			if best_hit.is_empty() or grass_distance < float(best_hit.get("distance", INF)):
				best_hit = grass_hit
		return best_hit

	func chop_tree_at_index(_coord: Vector2i, _index: int) -> bool:
		chopped_count += 1
		return true

	func harvest_data_hit(_hit: Dictionary) -> bool:
		harvested_kind = str(_hit.get("kind", ""))
		return true

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var combat: CombatSystemFeature = CombatSystemScript.new()
	var player := FakePlayer.new()
	var vegetation := FakeVegetationManager.new()
	var terrain_manager := Node.new()
	root.add_child(player)
	root.add_child(vegetation)
	root.add_child(terrain_manager)
	root.add_child(combat)
	combat.player = player
	combat.vegetation_manager = vegetation
	combat.terrain_manager = terrain_manager

	var axe_item := {
		"id": "axe_stone",
		"damage": 1
	}

	combat._do_axe_damage(axe_item)
	if not _expect(vegetation.query_count == 1, "empty physics ray should still query vegetation data"):
		return 1
	if not _expect(int(combat.tree_damage.get("tree:0:0:0", 0)) == 3, "first data-ray tree hit should apply axe damage"):
		return 1

	combat._do_axe_damage(axe_item)
	combat._do_axe_damage(axe_item)
	if not _expect(vegetation.chopped_count == 1, "repeated empty-ray axe hits should chop tree"):
		return 1
	if not _expect(not combat.tree_damage.has("tree:0:0:0"), "tree damage should clear after chop"):
		return 1

	var soft_tree_blocker := Node.new()
	soft_tree_blocker.add_to_group("terrain")
	root.add_child(soft_tree_blocker)
	vegetation.tree_distance = 2.0
	player.ray_hit = {
		"collider": soft_tree_blocker,
		"position": Vector3(0.0, 0.0, 1.0),
		"normal": Vector3.UP
	}
	combat._do_axe_damage(axe_item)
	if not _expect(int(combat.tree_damage.get("tree:0:0:0", 0)) == 3, "soft terrain physics hit should allow a nearby colliderless tree hit"):
		return 1
	combat.tree_damage.clear()
	player.ray_hit = {}
	soft_tree_blocker.free()

	var terrain_blocker := Node.new()
	terrain_blocker.add_to_group("terrain")
	root.add_child(terrain_blocker)
	vegetation.tree_distance = 4.5
	player.ray_hit = {
		"collider": terrain_blocker,
		"position": Vector3(0.0, 0.0, 1.0),
		"normal": Vector3.UP
	}
	combat._do_axe_damage(axe_item)
	if not _expect(not combat.tree_damage.has("tree:0:0:0"), "soft terrain physics hit should still block vegetation far behind the aimed surface"):
		return 1
	combat.tree_damage.clear()
	terrain_blocker.free()

	vegetation.tree_distance = 4.5
	player.ray_hit = {
		"position": Vector3(0.0, 0.0, 1.0),
		"normal": Vector3.UP
	}
	combat._do_axe_damage(axe_item)
	if not _expect(not combat.tree_damage.has("tree:0:0:0"), "server-side terrain physics hit should still block vegetation far behind the aimed surface"):
		return 1
	combat.tree_damage.clear()
	player.ray_hit = {}

	var hard_blocker := Node.new()
	root.add_child(hard_blocker)
	vegetation.tree_distance = 4.5
	player.ray_hit = {
		"collider": hard_blocker,
		"position": Vector3(0.0, 0.0, 1.0),
		"normal": Vector3.UP
	}
	combat._do_axe_damage(axe_item)
	if not _expect(not combat.tree_damage.has("tree:0:0:0"), "non-terrain physics blocker should still block a tree behind it"):
		return 1
	hard_blocker.free()
	player.ray_hit = {}

	vegetation.tree_distance = 4.5
	combat._do_axe_damage(axe_item)
	if not _expect(int(combat.tree_damage.get("tree:0:0:0", 0)) == 3, "axe data-ray tree damage should reach HUD-range trees"):
		return 1
	if not _expect(combat.durability_target == "tree:0:0:0", "data-ray tree durability target should be stored as stable vegetation key"):
		return 1
	combat._check_durability_target()
	if not _expect(combat.durability_target == "tree:0:0:0", "data-ray tree durability target should stay valid without a physics collider"):
		return 1

	combat.tree_damage.clear()
	vegetation.harvested_kind = ""
	vegetation.tree_distance = 3.0
	vegetation.grass_distance = 2.0
	var pickaxe_item := {
		"id": "pickaxe_stone",
		"damage": 1
	}
	var pickaxe_terrain_blocker := Node.new()
	pickaxe_terrain_blocker.add_to_group("terrain")
	root.add_child(pickaxe_terrain_blocker)
	player.ray_hit = {
		"collider": pickaxe_terrain_blocker,
		"position": Vector3(0.0, 0.0, 1.0),
		"normal": Vector3.UP
	}
	combat._do_pickaxe_damage_delayed({"item": pickaxe_item})
	if not _expect(vegetation.harvested_kind == "grass", "pickaxe should not be classified as axe-only tree targeting"):
		return 1
	if not _expect(combat.tree_damage.is_empty(), "pickaxe grass targeting should not apply tree damage"):
		return 1
	pickaxe_terrain_blocker.free()

	vegetation.harvested_kind = ""
	var pickaxe_hard_blocker := Node.new()
	root.add_child(pickaxe_hard_blocker)
	player.ray_hit = {
		"collider": pickaxe_hard_blocker,
		"position": Vector3(0.0, 0.0, 1.0),
		"normal": Vector3.UP
	}
	if not _expect(not combat._try_harvest_vegetation_near_ray(pickaxe_item, 3.5, player.ray_hit), "hard non-terrain physics blockers should still block grass behind them"):
		return 1
	if not _expect(vegetation.harvested_kind == "", "hard blocker should prevent grass data harvest"):
		return 1
	pickaxe_hard_blocker.free()

	combat.free()
	terrain_manager.free()
	player.free()
	vegetation.free()
	print("[COMBAT_EMPTY_RAY_VEGETATION_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[COMBAT_EMPTY_RAY_VEGETATION_TEST] FAIL: %s" % message)
	return false
