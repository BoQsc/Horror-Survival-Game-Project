extends SceneTree

const PlayerHUDScript := preload("res://modules/world_player_v2/features/ui_hud/player_hud.gd")

class TestHUD:
	extends PlayerHUDV2

	func _ready() -> void:
		pass

class FakePlayer:
	extends Node

	var ray_hit: Dictionary = {}

	func _init() -> void:
		add_to_group("player")

	func raycast(_distance: float, _mask: int, _collide_with_areas: bool, _exclude_water: bool) -> Dictionary:
		return ray_hit

	func get_camera_position() -> Vector3:
		return Vector3.ZERO

	func get_look_direction() -> Vector3:
		return Vector3.FORWARD

class FakeVegetationManager:
	extends Node

	func _init() -> void:
		add_to_group("vegetation_manager")

	func find_nearest_vegetation_along_ray(
			_origin: Vector3,
			_direction: Vector3,
			_max_distance: float,
			include_trees: bool = true,
			_include_grass: bool = true,
			_include_rocks: bool = true
	) -> Dictionary:
		if _max_distance < 2.0:
			return {}
		if not include_trees:
			return {}
		return {
			"kind": "tree",
			"coord": Vector2i.ZERO,
			"index": 0,
			"position": Vector3(0.0, 1.0, 2.0),
			"distance": 2.0
		}

func _init() -> void:
	call_deferred("_run_deferred")

func _run_deferred() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var player := FakePlayer.new()
	var vegetation := FakeVegetationManager.new()
	var hud := TestHUD.new()
	var bar := ProgressBar.new()
	bar.name = "DurabilityBar"
	hud.add_child(bar)
	root.add_child(player)
	root.add_child(vegetation)
	root.add_child(hud)
	hud.durability_bar = bar

	hud._on_durability_hit(5, 8, "Tree", "tree:0:0:0")
	hud._update_durability_visibility()

	if not _expect(bar.visible, "tree durability HUD should stay visible for data-ray trees without physics hits"):
		return 1
	if not _expect(is_equal_approx(bar.value, 62.5), "tree durability HUD should keep the latest HP percentage"):
		return 1

	var blocker := Node.new()
	root.add_child(blocker)
	player.ray_hit = {
		"collider": blocker,
		"position": Vector3(0.0, 0.0, 1.0),
		"normal": Vector3.UP
	}
	hud._update_durability_visibility()
	if not _expect(bar.visible, "tree durability HUD should not be clamped out by a nearby terrain physics hit"):
		return 1

	hud.free()
	blocker.free()
	vegetation.free()
	player.free()
	print("[VEGETATION_TREE_HUD_NO_PHYSICS_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_TREE_HUD_NO_PHYSICS_TEST] FAIL: %s" % message)
	return false
