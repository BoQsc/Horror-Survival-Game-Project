extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")
const CombatSystemScript = preload("res://modules/world_player_v2/features/tool_combat/combat_system.gd")

class FakePlayer:
	extends Node

	var ray_hit: Dictionary = {}
	var camera_origin: Vector3 = Vector3.ZERO
	var look_direction: Vector3 = Vector3.FORWARD

	func raycast(_distance: float, _mask: int, _collide_with_areas: bool, _exclude_water: bool) -> Dictionary:
		return ray_hit

	func get_camera_position() -> Vector3:
		return camera_origin

	func get_look_direction() -> Vector3:
		return look_direction

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	root.add_child(manager)
	manager.tree_y_offset = 9.5
	manager.tree_mesh = manager.create_basic_tree_mesh()
	var glb_result: Dictionary = manager.load_tree_mesh_from_glb(manager.tree_model_path)
	if glb_result.get("mesh", null) != null:
		manager.tree_mesh = glb_result.mesh
		manager.tree_base_transform = glb_result.get("transform", Transform3D.IDENTITY)
		manager.tree_base_transform.origin = Vector3.ZERO

	var scene_tree_transform := manager._build_vegetation_transform(
		manager.tree_base_transform,
		manager.tree_rotation_fix,
		0.0,
		1.0,
		Vector3(0.0, manager.tree_y_offset, 0.0)
	)
	var visual_aabb := manager._get_tree_visual_interaction_aabb(1.0, scene_tree_transform)
	if not _expect(visual_aabb.size.y > manager.collision_height, "real tree visual height should exceed legacy fixed cylinder height"):
		return 1
	if not _expect(visual_aabb.size.x > manager.collision_radius * 2.0 or visual_aabb.size.z > manager.collision_radius * 2.0, "real tree visual width should exceed legacy fixed cylinder width"):
		return 1

	var coord := Vector2i.ZERO
	manager.chunk_tree_data[coord] = {
		"trees": [
			manager._make_vegetation_generated(
				Vector3(0.0, manager.tree_y_offset, 0.0),
				Vector3(0.0, manager.tree_y_offset, 0.0),
				Vector3.ZERO,
				0.0,
				1.0,
				0,
				1.0,
				false,
				Transform3D.IDENTITY
			)
		]
	}

	var left_edge_x := visual_aabb.position.x + maxf(0.2, visual_aabb.size.x * 0.15)
	var origin := Vector3(left_edge_x, visual_aabb.position.y + visual_aabb.size.y * 0.5, visual_aabb.position.z + visual_aabb.size.z + 4.0)
	var direction := Vector3.FORWARD
	var hit := manager.find_nearest_vegetation_along_ray(origin, direction, 12.0, true, false, false)
	if not _expect(hit.get("kind", "") == "tree", "data ray should hit the real visual tree footprint, not only a tiny center cylinder"):
		return 1

	var player := FakePlayer.new()
	var combat: CombatSystemFeature = CombatSystemScript.new()
	root.add_child(player)
	root.add_child(combat)
	player.camera_origin = origin
	player.look_direction = direction
	combat.player = player
	combat.vegetation_manager = manager
	var axe_item := {"id": "axe_stone", "damage": 1}
	combat._do_axe_damage(axe_item)
	var tree_key := "tree:0:0:0"
	if not _expect(int(combat.tree_damage.get(tree_key, 0)) == 3, "axe hit on visual tree footprint should apply tree damage"):
		return 1

	combat.free()
	player.free()
	manager.free()
	print("[VEGETATION_TREE_TARGETING_GEOMETRY_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_TREE_TARGETING_GEOMETRY_TEST] FAIL: %s" % message)
	return false
