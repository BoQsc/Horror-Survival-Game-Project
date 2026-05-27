extends SceneTree

class FakeHotbar:
	extends Node

	func get_selected_item() -> Dictionary:
		return {"id": "pickaxe_stone", "category": 1}

class FakePlayer:
	extends Node

	func _init() -> void:
		name = "FakePlayer"
		add_to_group("player")
		var systems := Node.new()
		systems.name = "Systems"
		add_child(systems)
		var hotbar := FakeHotbar.new()
		hotbar.name = "Hotbar"
		systems.add_child(hotbar)

	func raycast(_distance: float, _mask: int, _collide_with_areas: bool, _exclude_water: bool) -> Dictionary:
		return {}

	func get_camera_position() -> Vector3:
		return Vector3.ZERO

	func get_look_direction() -> Vector3:
		return Vector3.BACK

class FakeVegetationManager:
	extends Node

	var query_count: int = 0

	func _init() -> void:
		name = "FakeVegetationManager"
		add_to_group("vegetation_manager")

	func find_nearest_vegetation_along_ray(
			origin: Vector3,
			direction: Vector3,
			_max_distance: float,
			_include_trees: bool = true,
			_include_grass: bool = true,
			_include_rocks: bool = true
	) -> Dictionary:
		query_count += 1
		return {
			"kind": "grass",
			"position": origin + direction.normalized() * 2.0,
			"distance": 2.0,
			"base_position": origin + direction.normalized() * 2.0 - Vector3.UP * 0.25,
			"interaction_radius": 0.3,
			"interaction_height": 0.5
		}

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var exit_code: int = await _run()
	quit(exit_code)

func _run() -> int:
	var tool_config = root.get_node_or_null("ToolConfig")
	if not _expect(tool_config != null, "ToolConfig autoload should exist"):
		return 1
	if not _expect("vegetation_interaction_visualizer_enabled" in tool_config, "ToolConfig should expose vegetation interaction visualizer flag"):
		return 1

	var previous_state: bool = tool_config.vegetation_interaction_visualizer_enabled
	tool_config.vegetation_interaction_visualizer_enabled = true
	if not _expect(tool_config.vegetation_interaction_visualizer_enabled, "ToolConfig flag should toggle on"):
		return 1
	tool_config.vegetation_interaction_visualizer_enabled = false
	if not _expect(not tool_config.vegetation_interaction_visualizer_enabled, "ToolConfig flag should toggle off"):
		return 1

	var scene_text := _read_text("res://modules/world_player_v2/features/ui_hud/player_hud.tscn")
	if not _expect(scene_text.contains("VegetationInteractionVisualizerToggle"), "ESC debug menu should contain VegetationInteractionVisualizerToggle"):
		return 1
	if not _expect(scene_text.contains("text = \"Vegetation Target Debug\""), "vegetation debug toggle should have the expected label"):
		return 1

	var hud_script_text := _read_text("res://modules/world_player_v2/features/ui_hud/player_hud.gd")
	if not _expect(hud_script_text.contains("VegetationInteractionVisualizerToggle"), "HUD should look up the vegetation debug toggle"):
		return 1
	if not _expect(hud_script_text.contains("_on_vegetation_interaction_visualizer_toggled"), "HUD should connect the vegetation debug toggle handler"):
		return 1
	if not _expect(hud_script_text.contains("vegetation_interaction_visualizer_enabled = is_enabled"), "HUD toggle handler should update ToolConfig"):
		return 1

	var fake_player := FakePlayer.new()
	var fake_vegetation := FakeVegetationManager.new()
	root.add_child(fake_player)
	root.add_child(fake_vegetation)
	await process_frame

	tool_config.vegetation_interaction_visualizer_enabled = true
	tool_config._process(0.0)
	if not _expect(fake_vegetation.query_count >= 1, "enabled vegetation visualizer should query vegetation data targeting"):
		return 1
	if not _expect(tool_config._vegetation_ray != null and tool_config._vegetation_ray.visible, "enabled vegetation visualizer should show the aim ray"):
		return 1
	if not _expect(tool_config._vegetation_target_marker != null and tool_config._vegetation_target_marker.visible, "enabled vegetation visualizer should show the selected vegetation target"):
		return 1
	if not _expect(tool_config._vegetation_target_volume != null and tool_config._vegetation_target_volume.visible, "enabled vegetation visualizer should show the selected vegetation interaction volume"):
		return 1
	var volume_mat = tool_config._vegetation_target_volume.material_override as StandardMaterial3D
	if not _expect(volume_mat != null and volume_mat.albedo_color.a < 0.5, "vegetation interaction volume should be transparent"):
		return 1

	tool_config.vegetation_interaction_visualizer_enabled = false
	if not _expect(not tool_config._vegetation_ray.visible and not tool_config._vegetation_target_marker.visible and not tool_config._vegetation_target_volume.visible, "disabled vegetation visualizer should hide debug visuals"):
		return 1

	fake_vegetation.free()
	fake_player.free()
	tool_config.vegetation_interaction_visualizer_enabled = previous_state
	print("[HUD_VEGETATION_INTERACTION_TOGGLE_TEST] PASS")
	return 0

func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return ""
	return file.get_as_text()

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[HUD_VEGETATION_INTERACTION_TOGGLE_TEST] FAIL: %s" % message)
	return false
