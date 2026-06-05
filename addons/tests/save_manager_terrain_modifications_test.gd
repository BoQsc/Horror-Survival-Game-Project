extends SceneTree

const SaveManagerScript = preload("res://save_manager/save_manager_v2.gd")


class FakeChunkManager:
	extends Node

	var stored_modifications: Dictionary = {}
	var clear_all_chunks_count: int = 0

	func clear_all_chunks() -> void:
		clear_all_chunks_count += 1
		stored_modifications.clear()


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var save_manager := SaveManagerScript.new()
	var chunk_manager := FakeChunkManager.new()
	save_manager.chunk_manager = chunk_manager

	var edited_coord := Vector3i(3, 0, -2)
	chunk_manager.stored_modifications[edited_coord] = [
		{
			"brush_pos": Vector3(1.5, 2.0, -3.25),
			"radius": 4.0,
			"value": 1.0,
			"shape": 2,
			"layer": 0,
			"material_id": 7
		}
	]

	var saved_data: Dictionary = save_manager._get_terrain_data()
	if not _expect(saved_data.has("3,0,-2"), "terrain save should key modifications by chunk coordinate"):
		return _cleanup(save_manager, chunk_manager, 1)
	var saved_mods: Array = saved_data.get("3,0,-2", [])
	if not _expect(saved_mods.size() == 1, "terrain save should preserve one edit entry"):
		return _cleanup(save_manager, chunk_manager, 1)
	var saved_mod: Dictionary = saved_mods[0]
	if not _expect(_array3_equal_approx(saved_mod.get("brush_pos", []), [1.5, 2.0, -3.25]), "terrain save should serialize brush position"):
		return _cleanup(save_manager, chunk_manager, 1)
	if not _expect(is_equal_approx(float(saved_mod.get("radius", 0.0)), 4.0), "terrain save should serialize radius"):
		return _cleanup(save_manager, chunk_manager, 1)
	if not _expect(int(saved_mod.get("material_id", -1)) == 7, "terrain save should serialize material id"):
		return _cleanup(save_manager, chunk_manager, 1)

	chunk_manager.stored_modifications[Vector3i(99, 0, 99)] = [{"brush_pos": Vector3.ZERO, "radius": 1.0, "value": 0.0, "shape": 0, "layer": 0}]
	var loaded_coord := Vector3i(-4, 1, 5)
	save_manager._load_terrain_data({
		"-4,1,5": [
			{
				"brush_pos": [10.0, 2.25, 11.5],
				"radius": 3.5,
				"value": -1.0,
				"shape": 1,
				"layer": 2,
				"material_id": 5
			}
		],
		"invalid_coord": [
			{
				"brush_pos": [0.0, 0.0, 0.0],
				"radius": 1.0,
				"value": 1.0,
				"shape": 0,
				"layer": 0
			}
		]
	})
	if not _expect(chunk_manager.clear_all_chunks_count == 1, "terrain load should clear live chunks before restoring saved edits"):
		return _cleanup(save_manager, chunk_manager, 1)
	if not _expect(not chunk_manager.stored_modifications.has(Vector3i(99, 0, 99)), "terrain load should discard stale in-memory edits"):
		return _cleanup(save_manager, chunk_manager, 1)
	if not _expect(chunk_manager.stored_modifications.has(loaded_coord), "terrain load should restore saved edit coordinate"):
		return _cleanup(save_manager, chunk_manager, 1)
	if not _expect(chunk_manager.stored_modifications.size() == 1, "terrain load should ignore invalid coordinate keys"):
		return _cleanup(save_manager, chunk_manager, 1)
	var loaded_mods: Array = chunk_manager.stored_modifications[loaded_coord]
	var loaded_mod: Dictionary = loaded_mods[0]
	if not _expect(loaded_mod.get("brush_pos", Vector3.ZERO).is_equal_approx(Vector3(10.0, 2.25, 11.5)), "terrain load should restore brush position"):
		return _cleanup(save_manager, chunk_manager, 1)
	if not _expect(is_equal_approx(float(loaded_mod.get("radius", 0.0)), 3.5), "terrain load should restore radius"):
		return _cleanup(save_manager, chunk_manager, 1)
	if not _expect(int(loaded_mod.get("layer", -1)) == 2, "terrain load should restore layer"):
		return _cleanup(save_manager, chunk_manager, 1)
	if not _expect(int(loaded_mod.get("material_id", -1)) == 5, "terrain load should restore material id"):
		return _cleanup(save_manager, chunk_manager, 1)

	save_manager._load_terrain_data({})
	if not _expect(chunk_manager.clear_all_chunks_count == 2, "empty terrain load should still clear live chunks"):
		return _cleanup(save_manager, chunk_manager, 1)
	if not _expect(chunk_manager.stored_modifications.is_empty(), "empty terrain load should leave no modifications"):
		return _cleanup(save_manager, chunk_manager, 1)

	print("[SAVE_MANAGER_TERRAIN_MODIFICATIONS_TEST] PASS")
	return _cleanup(save_manager, chunk_manager, 0)


func _array3_equal_approx(actual: Array, expected: Array) -> bool:
	if actual.size() != 3 or expected.size() != 3:
		return false
	for index in range(3):
		if not is_equal_approx(float(actual[index]), float(expected[index])):
			return false
	return true


func _cleanup(save_manager: Node, chunk_manager: Node, exit_code: int) -> int:
	save_manager.free()
	chunk_manager.free()
	return exit_code


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[SAVE_MANAGER_TERRAIN_MODIFICATIONS_TEST] FAIL: %s" % message)
	return false
