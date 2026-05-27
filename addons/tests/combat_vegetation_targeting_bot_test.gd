extends SceneTree

const CombatSystemScript = preload("res://modules/world_player_v2/features/tool_combat/combat_system.gd")

class BotPlayer:
	extends Node

	var ray_hit: Dictionary = {}
	var camera_origin: Vector3 = Vector3.ZERO
	var look_direction: Vector3 = Vector3.FORWARD
	var body_position: Vector3 = Vector3.ZERO

	func move_to(pos: Vector3) -> void:
		body_position = pos
		camera_origin = pos + Vector3(0.0, 1.6, 0.0)

	func aim_at(pos: Vector3) -> void:
		look_direction = (pos - camera_origin).normalized()

	func raycast(_distance: float, _mask: int, _collide_with_areas: bool, _exclude_water: bool) -> Dictionary:
		return ray_hit

	func get_camera_position() -> Vector3:
		return camera_origin

	func get_look_direction() -> Vector3:
		return look_direction

class FakeHotbar:
	extends Node

	var added_item_ids: Array[String] = []

	func add_item(item: Dictionary) -> bool:
		added_item_ids.append(str(item.get("id", "")))
		return true

	func count_item(item_id: String) -> int:
		var count := 0
		for added_id in added_item_ids:
			if added_id == item_id:
				count += 1
		return count

class FakeTerrain:
	extends Node

class FakeVegetationManager:
	extends Node

	const AIM_PRIORITY_DELTA_SQ := 0.01

	var entries: Array[Dictionary] = []
	var harvested_kind: String = ""
	var chopped_count: int = 0

	func set_entries(new_entries: Array[Dictionary]) -> void:
		entries = new_entries
		harvested_kind = ""

	func find_nearest_vegetation_along_ray(
			origin: Vector3,
			direction: Vector3,
			max_distance: float,
			include_trees: bool = true,
			include_grass: bool = true,
			include_rocks: bool = true
	) -> Dictionary:
		var ray_dir := direction.normalized()
		var best_hit: Dictionary = {}
		for entry in entries:
			if not bool(entry.get("alive", true)):
				continue
			var kind := str(entry.get("kind", ""))
			if kind == "tree" and not include_trees:
				continue
			if kind == "grass" and not include_grass:
				continue
			if kind == "rock" and not include_rocks:
				continue
			var pos: Vector3 = entry.get("position", Vector3.ZERO)
			var to_entry := pos - origin
			var along := to_entry.dot(ray_dir)
			if along < 0.0 or along > max_distance:
				continue
			var closest := origin + ray_dir * along
			var radius := float(entry.get("radius", 0.35))
			var aim_distance_sq := closest.distance_squared_to(pos)
			if aim_distance_sq > radius * radius:
				continue
			var hit := {
				"kind": kind,
				"coord": entry.get("coord", Vector2i.ZERO),
				"index": int(entry.get("index", -1)),
				"position": pos,
				"distance": along,
				"distance_sq_to_ray": aim_distance_sq
			}
			if _is_better_hit(hit, best_hit):
				best_hit = hit
		return best_hit

	func _is_better_hit(candidate: Dictionary, current: Dictionary) -> bool:
		if candidate.is_empty():
			return false
		if current.is_empty():
			return true
		var candidate_aim_sq := float(candidate.get("distance_sq_to_ray", 0.0))
		var current_aim_sq := float(current.get("distance_sq_to_ray", 0.0))
		var aim_delta_sq := candidate_aim_sq - current_aim_sq
		if absf(aim_delta_sq) > AIM_PRIORITY_DELTA_SQ:
			return aim_delta_sq < 0.0
		var candidate_distance := float(candidate.get("distance", 0.0))
		var current_distance := float(current.get("distance", 0.0))
		if not is_equal_approx(candidate_distance, current_distance):
			return candidate_distance < current_distance
		return candidate_aim_sq < current_aim_sq

	func harvest_data_hit(hit: Dictionary) -> bool:
		var kind := str(hit.get("kind", ""))
		for i in range(entries.size()):
			if int(entries[i].get("index", -1)) == int(hit.get("index", -2)) and str(entries[i].get("kind", "")) == kind:
				entries[i]["alive"] = false
				harvested_kind = kind
				return true
		return false

	func chop_tree_at_index(_coord: Vector2i, tree_index: int) -> bool:
		for i in range(entries.size()):
			if str(entries[i].get("kind", "")) == "tree" and int(entries[i].get("index", -1)) == tree_index:
				entries[i]["alive"] = false
				chopped_count += 1
				return true
		return false

	func chop_tree_by_collider(_target: Node) -> bool:
		chopped_count += 1
		return true

	func harvest_grass_by_collider(_target: Node) -> bool:
		harvested_kind = "grass"
		return true

	func harvest_rock_by_collider(_target: Node) -> bool:
		harvested_kind = "rock"
		return true

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var combat: CombatSystemFeature = CombatSystemScript.new()
	var player := BotPlayer.new()
	var vegetation := FakeVegetationManager.new()
	var terrain := FakeTerrain.new()
	var hotbar := FakeHotbar.new()
	root.add_child(player)
	root.add_child(vegetation)
	root.add_child(terrain)
	root.add_child(hotbar)
	root.add_child(combat)
	combat.player = player
	combat.vegetation_manager = vegetation
	combat.terrain_manager = terrain
	combat.hotbar = hotbar

	var pickaxe_item := {"id": "pickaxe_stone", "damage": 2}
	var axe_item := {"id": "axe_stone", "damage": 3}

	player.move_to(Vector3.ZERO)
	vegetation.set_entries([
		{"kind": "tree", "index": 0, "position": Vector3(0.8, 1.3, 1.5), "radius": 1.0, "alive": true},
		{"kind": "grass", "index": 1, "position": Vector3(0.0, 1.3, 2.8), "radius": 0.35, "alive": true}
	])
	player.aim_at(Vector3(0.0, 1.3, 2.8))
	player.ray_hit = {}
	combat.do_tool_attack(pickaxe_item)
	combat._on_pickaxe_hit_moment()
	if not _expect(vegetation.harvested_kind == "grass", "bot pickaxe should harvest aimed grass even when a tree bound is closer on the same ray"):
		return 1
	if not _expect(hotbar.count_item("veg_fiber") == 1, "bot pickaxe grass hit should add fiber"):
		return 1
	if not _expect(hotbar.count_item("veg_wood") == 0 and combat.tree_damage.is_empty(), "bot pickaxe grass hit should not damage or collect tree wood"):
		return 1
	combat._on_axe_ready()

	vegetation.set_entries([
		{"kind": "tree", "index": 0, "position": Vector3(1.8, 1.3, 1.5), "radius": 1.0, "alive": true},
		{"kind": "rock", "index": 2, "position": Vector3(1.0, 1.3, 2.8), "radius": 0.35, "alive": true}
	])
	player.aim_at(Vector3(1.0, 1.3, 2.8))
	combat.do_tool_attack(pickaxe_item)
	combat._on_pickaxe_hit_moment()
	if not _expect(vegetation.harvested_kind == "rock", "bot pickaxe should harvest aimed rock instead of nearer tree wood"):
		return 1
	if not _expect(hotbar.count_item("veg_rock") == 1 and hotbar.count_item("veg_wood") == 0, "bot pickaxe rock hit should add rock and no wood"):
		return 1
	combat._on_axe_ready()

	var tree_collider := StaticBody3D.new()
	tree_collider.add_to_group("trees")
	root.add_child(tree_collider)
	vegetation.set_entries([
		{"kind": "grass", "index": 3, "position": Vector3(0.0, 1.3, 2.8), "radius": 0.35, "alive": true}
	])
	player.aim_at(Vector3(0.0, 1.3, 2.8))
	player.ray_hit = {
		"collider": tree_collider,
		"position": Vector3(0.0, 1.3, 1.6),
		"normal": Vector3.UP
	}
	combat.do_tool_attack(pickaxe_item)
	combat._on_pickaxe_hit_moment()
	if not _expect(int(combat.tree_damage.get(tree_collider.get_rid(), 0)) == 2, "direct tree collider hit should affect the tree collider instead of vegetation behind it"):
		return 1
	if not _expect(vegetation.harvested_kind != "grass", "data vegetation behind a direct tree collider hit should not be harvested"):
		return 1
	tree_collider.free()
	player.ray_hit = {}
	combat.tree_damage.clear()

	combat._on_axe_ready()
	var terrain_collider := Node.new()
	terrain_collider.add_to_group("terrain")
	root.add_child(terrain_collider)
	vegetation.set_entries([
		{"kind": "tree", "index": 8, "position": Vector3(0.0, 1.3, 2.8), "radius": 1.0, "alive": true}
	])
	vegetation.harvested_kind = ""
	player.aim_at(Vector3(0.0, 1.3, 2.8))
	player.ray_hit = {
		"collider": terrain_collider,
		"position": Vector3(0.0, 1.3, 1.2),
		"normal": Vector3.UP
	}
	combat.do_tool_attack(pickaxe_item)
	combat._on_pickaxe_hit_moment()
	if not _expect(combat.tree_damage.is_empty() and vegetation.chopped_count == 0, "terrain hit should block data vegetation behind it instead of chopping a nearby tree"):
		return 1
	terrain_collider.free()
	player.ray_hit = {}
	combat.tree_damage.clear()
	combat._on_axe_ready()

	vegetation.set_entries([
		{"kind": "tree", "index": 4, "position": Vector3(0.0, 1.44, 2.5), "radius": 1.0, "alive": true}
	])
	player.aim_at(Vector3(0.0, 1.44, 2.5))
	for _i in range(3):
		combat.do_tool_attack(axe_item)
		combat._on_axe_hit_moment()
		combat._on_axe_ready()
	if not _expect(vegetation.chopped_count == 1, "bot axe should chop aimed tree through data targeting"):
		return 1
	if not _expect(hotbar.count_item("veg_wood") == 1, "bot axe tree chop should add wood once"):
		return 1

	vegetation.set_entries([
		{"kind": "grass", "index": 5, "position": Vector3(3.0, 1.3, 2.8), "radius": 0.35, "alive": true}
	])
	vegetation.harvested_kind = ""
	player.aim_at(Vector3(3.0, 1.3, 2.8))
	var fiber_before := hotbar.count_item("veg_fiber")
	combat.do_tool_attack(axe_item)
	combat._on_axe_hit_moment()
	if not _expect(vegetation.harvested_kind == "grass" and hotbar.count_item("veg_fiber") == fiber_before + 1, "bot axe should harvest the aimed grass target instead of enforcing tool category policy"):
		return 1
	combat._on_axe_ready()

	vegetation.set_entries([
		{"kind": "tree", "index": 6, "position": Vector3(0.8, 1.3, 1.5), "radius": 1.0, "alive": true},
		{"kind": "grass", "index": 7, "position": Vector3(0.0, 1.3, 2.8), "radius": 0.35, "alive": true}
	])
	vegetation.harvested_kind = ""
	player.aim_at(Vector3(0.0, 1.3, 2.8))
	combat.do_tool_attack({"id": "debug_probe", "damage": 1})
	if not _expect(vegetation.harvested_kind == "grass" and hotbar.count_item("veg_wood") == 1, "generic tool attack should still use target-first vegetation selection"):
		return 1

	combat.free()
	hotbar.free()
	terrain.free()
	vegetation.free()
	player.free()
	print("[COMBAT_VEGETATION_TARGETING_BOT_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[COMBAT_VEGETATION_TARGETING_BOT_TEST] FAIL: %s" % message)
	return false
