extends SceneTree

const CombatSystemScript = preload("res://modules/world_player_v2/features/tool_combat/combat_system.gd")

class FakePlayer:
	extends Node

	func raycast(_distance: float, _mask: int, _collide_with_areas: bool, _exclude_water: bool) -> Dictionary:
		return {}

	func get_camera_position() -> Vector3:
		return Vector3.ZERO

	func get_look_direction() -> Vector3:
		return Vector3.FORWARD

class FakeVegetationManager:
	extends Node

	var query_count: int = 0
	var chopped_count: int = 0

	func find_nearest_vegetation_along_ray(
			_origin: Vector3,
			_direction: Vector3,
			_max_distance: float,
			include_trees: bool = true,
			include_grass: bool = true,
			include_rocks: bool = true
	) -> Dictionary:
		query_count += 1
		if include_trees and not include_grass and not include_rocks:
			return {
				"kind": "tree",
				"coord": Vector2i.ZERO,
				"index": 0,
				"position": Vector3(0.0, 1.0, 2.0),
				"distance": 2.0
			}
		if include_grass:
			return {
				"kind": "grass",
				"coord": Vector2i.ZERO,
				"index": 0,
				"position": Vector3(0.0, 0.2, 1.0),
				"distance": 1.0
			}
		if not include_trees:
			return {}
		return {
			"kind": "tree",
			"coord": Vector2i.ZERO,
			"index": 0,
			"position": Vector3(0.0, 1.0, 2.0),
			"distance": 2.0
		}

	func chop_tree_at_index(_coord: Vector2i, _index: int) -> bool:
		chopped_count += 1
		return true

	func harvest_data_hit(_hit: Dictionary) -> bool:
		return true

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var combat: CombatSystemFeature = CombatSystemScript.new()
	var player := FakePlayer.new()
	var vegetation := FakeVegetationManager.new()
	root.add_child(player)
	root.add_child(vegetation)
	root.add_child(combat)
	combat.player = player
	combat.vegetation_manager = vegetation

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

	combat.free()
	player.free()
	vegetation.free()
	print("[COMBAT_EMPTY_RAY_VEGETATION_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[COMBAT_EMPTY_RAY_VEGETATION_TEST] FAIL: %s" % message)
	return false
