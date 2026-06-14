extends SceneTree

const TerrainArtifactCache = preload("res://world_performance/terrain_artifact_cache.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var cache = TerrainArtifactCache.new()
	cache.configure(true, 200, 2)

	var coord_a := Vector3i(1, 0, 1)
	var coord_b := Vector3i(2, 0, 1)
	var coord_c := Vector3i(3, 0, 1)
	if not _expect(cache.store(coord_a, _artifact("sig", 0, 80)), "first artifact should store"):
		return 1
	if not _expect(cache.store(coord_b, _artifact("sig", 0, 80)), "second artifact should store"):
		return 1
	if not _expect(not cache.lookup(coord_a, "sig", 0).is_empty(), "matching artifact should hit"):
		return 1
	if not _expect(cache.store(coord_c, _artifact("sig", 0, 80)), "third artifact should store"):
		return 1
	if not _expect(cache.lookup(coord_b, "sig", 0).is_empty(), "least recently used artifact should evict"):
		return 1
	if not _expect(cache.lookup(coord_a, "sig", 1).is_empty(), "modification version mismatch should invalidate"):
		return 1

	var coord_d := Vector3i(4, 0, 1)
	if not _expect(cache.store(coord_d, _artifact("sig", 1, 80, "edit:1:test")), "edited artifact should store"):
		return 1
	if not _expect(not cache.lookup(coord_d, "sig", 1, "edit:1:test").is_empty(), "matching edited artifact should hit"):
		return 1
	if not _expect(cache.lookup(coord_d, "sig", 1, "edit:1:stale").is_empty(), "edit signature mismatch should invalidate"):
		return 1

	var snapshot: Dictionary = cache.get_snapshot()
	if not _expect(int(snapshot.get("hit_count", 0)) == 2, "cache hits should be counted"):
		return 1
	if not _expect(int(snapshot.get("eviction_count", 0)) == 1, "eviction should be counted"):
		return 1
	if not _expect(int(snapshot.get("invalidation_count", 0)) == 2, "invalidation should be counted"):
		return 1

	print("[TERRAIN_ARTIFACT_CACHE_TEST] PASS")
	return 0


func _artifact(signature: String, stored_mod_version: int, byte_size: int, edit_signature: String = "") -> Dictionary:
	return {
		"settings_signature": signature,
		"stored_mod_version": stored_mod_version,
		"edit_signature": edit_signature if not edit_signature.is_empty() else "base",
		"byte_size": byte_size
	}


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_ARTIFACT_CACHE_TEST] FAIL: %s" % message)
	return false
