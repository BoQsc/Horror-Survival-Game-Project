extends SceneTree

const TerrainArtifactDiskStore = preload("res://world_performance/terrain_artifact_disk_store.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var root_path := "user://terrain_artifact_disk_store_test_%d" % Time.get_ticks_usec()
	var store = TerrainArtifactDiskStore.new()
	store.configure(true, root_path, 2)

	var coord_a := Vector3i(1, 0, 1)
	var coord_b := Vector3i(2, 0, 1)
	var coord_c := Vector3i(3, 0, 1)
	if not _expect(store.store(coord_a, "sig", _artifact("sig", 0, 80)), "artifact A should store"):
		return 1
	if not _expect(store.store(coord_b, "sig", _artifact("sig", 0, 80)), "artifact B should store"):
		return 1
	if not _expect(not store.lookup(coord_a, "sig").is_empty(), "artifact A should restore"):
		return 1
	if not _expect(store.store(coord_c, "sig", _artifact("sig", 0, 80)), "artifact C should store"):
		return 1
	var artifact_a_present := not store.lookup(coord_a, "sig").is_empty()
	var artifact_b_present := not store.lookup(coord_b, "sig").is_empty()
	if not _expect((1 if artifact_a_present else 0) + (1 if artifact_b_present else 0) == 1, "one older artifact should evict"):
		return 1
	if not _expect(not store.lookup(coord_c, "sig").is_empty(), "new artifact C should remain"):
		return 1
	var replacement_artifact := _artifact("sig", 0, 80)
	replacement_artifact["marker"] = "replacement"
	if not _expect(store.store(coord_c, "sig", replacement_artifact), "existing artifact should replace atomically"):
		return 1
	if not _expect(str(store.lookup(coord_c, "sig").get("marker", "")) == "replacement", "replacement artifact should restore"):
		return 1
	if not _expect(store.lookup(coord_a, "different_sig").is_empty(), "different signature should miss"):
		return 1
	if not _expect(not store.store(Vector3i(4, 0, 1), "sig", _artifact("sig", 1, 80)), "modified artifact should not persist"):
		return 1

	var corrupt_coord := Vector3i(9, 0, 9)
	var corrupt_path: String = store._artifact_path(corrupt_coord, "sig")
	DirAccess.make_dir_recursive_absolute(corrupt_path.get_base_dir())
	var corrupt_file := FileAccess.open(corrupt_path, FileAccess.WRITE)
	if corrupt_file:
		corrupt_file.store_var({"not": "an artifact"}, false)
		corrupt_file.close()
	if not _expect(store.lookup(corrupt_coord, "sig").is_empty(), "corrupt artifact should miss"):
		return 1
	if not _expect(not FileAccess.file_exists(corrupt_path), "corrupt artifact should be removed"):
		return 1

	var stale_coord := Vector3i(10, 0, 9)
	var stale_path: String = store._artifact_path(stale_coord, "sig")
	DirAccess.make_dir_recursive_absolute(stale_path.get_base_dir())
	var stale_file := FileAccess.open(stale_path, FileAccess.WRITE)
	if stale_file:
		stale_file.store_var({
			"magic": TerrainArtifactDiskStore.STORE_MAGIC,
			"version": TerrainArtifactDiskStore.STORE_VERSION - 1,
			"coord": stale_coord,
			"settings_signature": "sig",
			"artifact": _artifact("sig", 0, 80)
		}, false)
		stale_file.close()
	if not _expect(store.lookup(stale_coord, "sig").is_empty(), "stale-version artifact should miss"):
		return 1
	if not _expect(not FileAccess.file_exists(stale_path), "stale-version artifact should be removed"):
		return 1

	var snapshot: Dictionary = store.get_snapshot()
	if not _expect(int(snapshot.get("hit_count", 0)) == 4, "disk hits should be counted"):
		return 1
	if not _expect(int(snapshot.get("eviction_count", 0)) == 1, "disk eviction should be counted"):
		return 1
	if not _expect(int(snapshot.get("store_skipped_count", 0)) == 1, "modified store skip should be counted"):
		return 1
	if not _expect(int(snapshot.get("invalid_count", 0)) == 2, "invalid artifact payloads should be counted"):
		return 1

	var byte_signature := "byte_sig"
	store.configure(true, root_path, 10, 1024 * 1024)
	var byte_coord_a := Vector3i(10, 0, 1)
	var byte_coord_b := Vector3i(11, 0, 1)
	var byte_coord_c := Vector3i(12, 0, 1)
	if not _expect(store.store(byte_coord_a, byte_signature, _artifact(byte_signature, 0, 80)), "byte-budget artifact A should store"):
		return 1
	if not _expect(store.store(byte_coord_b, byte_signature, _artifact(byte_signature, 0, 80)), "byte-budget artifact B should store"):
		return 1
	var byte_budget := _file_size(store._artifact_path(byte_coord_a, byte_signature)) + _file_size(store._artifact_path(byte_coord_b, byte_signature)) + 1
	store.configure(true, root_path, 10, byte_budget)
	if not _expect(store.store(byte_coord_c, byte_signature, _artifact(byte_signature, 0, 80)), "byte-budget artifact C should store"):
		return 1
	var byte_snapshot: Dictionary = store.get_snapshot()
	if not _expect(int(byte_snapshot.get("last_signature_bytes", 0)) <= byte_budget, "disk artifacts should trim to the byte budget"):
		return 1
	if not _expect(int(byte_snapshot.get("last_signature_entry_count", 0)) <= 2, "byte budget should evict at least one older artifact"):
		return 1
	store.configure(true, root_path, 10, 64)
	if not _expect(not store.store(Vector3i(13, 0, 1), byte_signature, _artifact(byte_signature, 0, 80)), "declared oversize artifact should be rejected"):
		return 1

	store.clear_all()
	print("[TERRAIN_ARTIFACT_DISK_STORE_TEST] PASS")
	return 0


func _artifact(signature: String, stored_mod_version: int, byte_size: int) -> Dictionary:
	return {
		"settings_signature": signature,
		"stored_mod_version": stored_mod_version,
		"byte_size": byte_size
	}


func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := int(file.get_length())
	file.close()
	return size


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_ARTIFACT_DISK_STORE_TEST] FAIL: %s" % message)
	return false
