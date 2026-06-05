extends SceneTree

const HarnessScript := preload("res://addons/tests/town_stall_test_harness.gd")

const TEST_ENV := "TOWN_STALL_TEST_ARTIFACT_BUDGET_OVERRIDE"


class DummyTerrain:
	extends RefCounted

	var terrain_artifact_cache_memory_budget_mb: int = 512


func _assert_true(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		quit(1)


func _init() -> void:
	var harness := HarnessScript.new()
	var dummy := DummyTerrain.new()

	OS.set_environment(TEST_ENV, "64")
	harness._apply_int_property_override_from_env(
		dummy,
		TEST_ENV,
		"terrain_artifact_cache_memory_budget_mb",
		"test budget"
	)
	_assert_true(dummy.terrain_artifact_cache_memory_budget_mb == 64, "valid budget override should update property")

	OS.set_environment(TEST_ENV, "not_an_int")
	harness._apply_int_property_override_from_env(
		dummy,
		TEST_ENV,
		"terrain_artifact_cache_memory_budget_mb",
		"test budget"
	)
	_assert_true(dummy.terrain_artifact_cache_memory_budget_mb == 64, "invalid budget override should be ignored")

	OS.set_environment(TEST_ENV, "-1")
	harness._apply_int_property_override_from_env(
		dummy,
		TEST_ENV,
		"terrain_artifact_cache_memory_budget_mb",
		"test budget"
	)
	_assert_true(dummy.terrain_artifact_cache_memory_budget_mb == 64, "negative budget override should be ignored")

	OS.set_environment(TEST_ENV, "32")
	harness._apply_int_property_override_from_env(
		dummy,
		TEST_ENV,
		"missing_budget_property",
		"test budget"
	)
	_assert_true(dummy.terrain_artifact_cache_memory_budget_mb == 64, "missing property override should be ignored")

	OS.set_environment(TEST_ENV, "")
	print("[TOWN_STALL_ARTIFACT_BUDGET_OVERRIDE_TEST] PASS")
	quit(0)
