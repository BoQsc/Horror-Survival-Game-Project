extends SceneTree

var _native: Object = null

func _init() -> void:
	var exit_code := _run()
	_release_native()
	quit(exit_code)

func _release_native() -> void:
	if _native == null or not is_instance_valid(_native):
		_native = null
		return
	if _native is RefCounted:
		_native.unreference()
		if is_instance_valid(_native):
			_native.free()
	else:
		_native.free()
	_native = null

func _run() -> int:
	if not ClassDB.class_exists("PrefabGeometryNative"):
		return _fail("PrefabGeometryNative is not registered")
	_native = ClassDB.instantiate("PrefabGeometryNative")
	var native := _native
	if native == null or not native.has_method("filter_removed_vegetation_entries"):
		return _fail("filter_removed_vegetation_entries is not available")

	var entries := [
		{
			"world_pos": Vector3(1.8, 3.0, 2.1),
			"hit_pos": Vector3(1.8, 2.5, 2.1),
			"index": 99,
			"alive": true
		},
		{
			"world_pos": Vector3(-0.2, 3.0, -0.8),
			"index": 99,
			"alive": true
		},
		"non_dictionary_entry",
		{
			"world_pos": Vector3(5.0, 3.0, 6.0),
			"hit_pos": Vector3(5.0, 2.5, 6.0),
			"index": 99,
			"alive": true
		}
	]
	var removed := {
		"1_2": true,
		"-1_-1": true
	}

	var filtered: Array = native.filter_removed_vegetation_entries(entries, removed)
	if not _expect(filtered.size() == 2, "native filter should remove hit_pos and fallback world_pos matches"):
		return 1
	if not _expect(filtered[0] == "non_dictionary_entry", "native filter should preserve non-dictionary entries"):
		return 1
	if not _expect(filtered[1] is Dictionary, "remaining vegetation entry should be preserved"):
		return 1
	if not _expect(int(filtered[1].get("index", -1)) == 1, "native filter should reindex dictionary entries after filtering"):
		return 1
	var hit_pos: Vector3 = filtered[1].get("hit_pos", Vector3.ZERO)
	if not _expect(hit_pos.is_equal_approx(Vector3(5.0, 2.5, 6.0)), "native filter should preserve surviving entry data"):
		return 1

	print("[VEGETATION_REMOVED_FILTER_NATIVE_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_REMOVED_FILTER_NATIVE_TEST] FAIL: %s" % message)
	return false

func _fail(message: String) -> int:
	printerr("[VEGETATION_REMOVED_FILTER_NATIVE_TEST] FAIL: %s" % message)
	return 1
