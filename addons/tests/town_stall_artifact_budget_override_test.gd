extends SceneTree

const HarnessScript := preload("res://addons/tests/town_stall_test_harness.gd")

const TEST_ENV := "TOWN_STALL_TEST_ARTIFACT_BUDGET_OVERRIDE"


class DummyTerrain:
	extends RefCounted

	var terrain_artifact_cache_memory_budget_mb: int = 512


var _harness: Node = null


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	await process_frame
	var exit_code := _run()
	_cleanup()
	await process_frame
	quit(exit_code)


func _cleanup() -> void:
	OS.set_environment(TEST_ENV, "")
	if _harness != null and is_instance_valid(_harness):
		_harness.free()
	_harness = null


func _run() -> int:
	_harness = HarnessScript.new()
	var harness := _harness
	var dummy := DummyTerrain.new()

	OS.set_environment(TEST_ENV, "64")
	harness._apply_int_property_override_from_env(
		dummy,
		TEST_ENV,
		"terrain_artifact_cache_memory_budget_mb",
		"test budget"
	)
	if not _expect(dummy.terrain_artifact_cache_memory_budget_mb == 64, "valid budget override should update property"):
		return 1

	OS.set_environment(TEST_ENV, "not_an_int")
	harness._apply_int_property_override_from_env(
		dummy,
		TEST_ENV,
		"terrain_artifact_cache_memory_budget_mb",
		"test budget"
	)
	if not _expect(dummy.terrain_artifact_cache_memory_budget_mb == 64, "invalid budget override should be ignored"):
		return 1

	OS.set_environment(TEST_ENV, "-1")
	harness._apply_int_property_override_from_env(
		dummy,
		TEST_ENV,
		"terrain_artifact_cache_memory_budget_mb",
		"test budget"
	)
	if not _expect(dummy.terrain_artifact_cache_memory_budget_mb == 64, "negative budget override should be ignored"):
		return 1

	OS.set_environment(TEST_ENV, "32")
	harness._apply_int_property_override_from_env(
		dummy,
		TEST_ENV,
		"missing_budget_property",
		"test budget"
	)
	if not _expect(dummy.terrain_artifact_cache_memory_budget_mb == 64, "missing property override should be ignored"):
		return 1

	print("[TOWN_STALL_ARTIFACT_BUDGET_OVERRIDE_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TOWN_STALL_ARTIFACT_BUDGET_OVERRIDE_TEST] FAIL: %s" % message)
	return false
