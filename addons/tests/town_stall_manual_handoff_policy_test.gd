extends SceneTree

const TownStallHarness = preload("res://addons/tests/town_stall_test_harness.gd")
const WorldPlayerScript = preload("res://modules/world_player_v2/player.gd")

class FakeModeManager:
	extends Node
	var current_mode: int = 0
	var previous_mode: int = 0
	var is_flying: bool = false

	func set_mode(new_mode: int) -> void:
		current_mode = new_mode

	func is_play_mode() -> bool:
		return current_mode == 0

	func is_editor_mode() -> bool:
		return current_mode == 2

	func is_fly_active() -> bool:
		return current_mode == 2 and is_flying

	func toggle_editor_mode() -> void:
		if current_mode == 2:
			current_mode = previous_mode
			is_flying = false
		else:
			previous_mode = current_mode
			current_mode = 2

	func toggle_fly_mode() -> void:
		if current_mode == 2:
			is_flying = not is_flying


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var harness := TownStallHarness.new()
	if not _expect(not bool(harness.manual_handoff_wait_for_idle_enabled), "manual handoff should not wait for idle by default"):
		harness.free()
		return 1
	harness.manual_handoff_wait_for_idle_enabled = true
	if not _expect(bool(harness.manual_handoff_wait_for_idle_enabled), "explicit manual handoff idle wait should remain available"):
		harness.free()
		return 1
	harness.free()
	var restore_exit_code := _run_restore_forces_play_mode()
	if restore_exit_code != 0:
		return restore_exit_code
	print("[TOWN_STALL_MANUAL_HANDOFF_POLICY_TEST] PASS")
	return 0


func _run_restore_forces_play_mode() -> int:
	var harness := TownStallHarness.new()
	var player: WorldPlayerV2 = WorldPlayerScript.new()
	var systems := Node.new()
	systems.name = "Systems"
	player.add_child(systems)
	var mode_manager := FakeModeManager.new()
	mode_manager.name = "ModeManager"
	systems.add_child(mode_manager)
	mode_manager.set("current_mode", 2)
	mode_manager.set("previous_mode", 0)
	mode_manager.set("is_flying", true)

	var modes := Node.new()
	modes.name = "Modes"
	player.add_child(modes)
	var mode_editor := Node.new()
	mode_editor.name = "ModeEditor"
	mode_editor.set_process(true)
	mode_editor.set_physics_process(true)
	modes.add_child(mode_editor)

	var components := Node.new()
	components.name = "Components"
	player.add_child(components)
	var movement := Node.new()
	movement.name = "Movement"
	movement.set_process(false)
	movement.set_physics_process(false)
	components.add_child(movement)
	var camera := Node.new()
	camera.name = "Camera"
	camera.set_process(false)
	camera.set_physics_process(false)
	components.add_child(camera)

	harness.player = player
	harness.mode_manager = mode_manager
	harness.mode_editor = mode_editor
	harness.movement_component = movement
	harness.camera_component = camera
	harness._restore_player_control()

	if not _expect(bool(mode_manager.call("is_play_mode")), "manual handoff restore should force PLAY mode"):
		harness.free()
		player.free()
		return 1
	if not _expect(not bool(mode_manager.call("is_fly_active")), "manual handoff restore should disable editor fly"):
		harness.free()
		player.free()
		return 1
	if not _expect(not bool(mode_editor.is_processing()), "manual handoff restore should leave editor processing disabled"):
		harness.free()
		player.free()
		return 1
	if not _expect(not bool(mode_editor.is_physics_processing()), "manual handoff restore should leave editor physics disabled"):
		harness.free()
		player.free()
		return 1
	if not _expect(bool(movement.is_processing()), "manual handoff restore should re-enable movement processing"):
		harness.free()
		player.free()
		return 1
	if not _expect(bool(movement.is_physics_processing()), "manual handoff restore should re-enable movement physics"):
		harness.free()
		player.free()
		return 1
	harness.free()
	player.free()
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TOWN_STALL_MANUAL_HANDOFF_POLICY_TEST] FAIL: %s" % message)
	return false
