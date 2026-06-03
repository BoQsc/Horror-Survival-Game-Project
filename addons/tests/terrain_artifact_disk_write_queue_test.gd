extends SceneTree

const TerrainArtifactDiskWriteQueue = preload("res://world_performance/terrain_artifact_disk_write_queue.gd")


class FakeStore:
	extends RefCounted

	var mutex: Mutex = Mutex.new()
	var stored_coords: Array[Vector3i] = []

	func store(coord: Vector3i, _settings_signature: String, _artifact: Dictionary) -> bool:
		mutex.lock()
		stored_coords.append(coord)
		mutex.unlock()
		return true

	func get_store_count() -> int:
		mutex.lock()
		var count := stored_coords.size()
		mutex.unlock()
		return count


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var queue = TerrainArtifactDiskWriteQueue.new()
	var store := FakeStore.new()
	queue.configure(true, 4, 1024, 0)
	var ok := _expect(queue.start(store), "disk write queue should start")
	ok = _expect(queue.enqueue(Vector3i(1, 0, 1), "sig", _artifact(100)), "first artifact should enqueue") and ok
	ok = _expect(queue.enqueue(Vector3i(2, 0, 1), "sig", _artifact(100)), "second artifact should enqueue") and ok
	queue.shutdown(true)

	var snapshot: Dictionary = queue.get_snapshot()
	ok = _expect(store.get_store_count() == 2, "flush shutdown should persist all pending artifacts") and ok
	ok = _expect(int(snapshot.get("completed_count", 0)) == 2, "completed write telemetry should increment") and ok
	ok = _expect(int(snapshot.get("completed_bytes", 0)) == 200, "completed byte telemetry should increment") and ok
	ok = _expect(int(snapshot.get("pending_entries", 0)) == 0, "queue should be empty after flush shutdown") and ok

	queue.configure(true, 4, 50, 0)
	ok = _expect(queue.start(store), "disk write queue should restart") and ok
	ok = _expect(not queue.enqueue(Vector3i(3, 0, 1), "sig", _artifact(100)), "oversize queued artifact should be rejected") and ok
	queue.shutdown(false)
	snapshot = queue.get_snapshot()
	var drop_reasons: Dictionary = snapshot.get("drop_reasons", {})
	ok = _expect(int(drop_reasons.get("oversize", 0)) == 1, "oversize queue rejection should be counted") and ok

	queue.configure(true, 4, 1024, 1000)
	ok = _expect(queue.start(store), "rate-limited disk write queue should restart") and ok
	ok = _expect(queue.enqueue(Vector3i(4, 0, 1), "sig", _artifact(50)), "first rate-limited artifact should enqueue") and ok
	ok = _expect(_wait_for_store_count(store, 3), "first rate-limited artifact should store") and ok
	ok = _expect(queue.enqueue(Vector3i(5, 0, 1), "sig", _artifact(50)), "second rate-limited artifact should enqueue") and ok
	ok = _expect(_wait_for_store_count(store, 4), "second rate-limited artifact should store") and ok
	queue.shutdown(true)
	snapshot = queue.get_snapshot()
	ok = _expect(int(snapshot.get("max_write_bytes_per_second", 0)) == 1000, "rate limit configuration should be exposed") and ok
	ok = _expect(int(snapshot.get("rate_limit_wait_count", 0)) >= 1, "rate-limited writes should record wait telemetry") and ok
	ok = _expect(float(snapshot.get("rate_limit_total_wait_ms", 0.0)) > 0.0, "rate-limited writes should record wait duration") and ok

	if ok:
		print("[TERRAIN_ARTIFACT_DISK_WRITE_QUEUE_TEST] PASS")
		return 0
	return 1


func _artifact(byte_size: int) -> Dictionary:
	return {
		"byte_size": byte_size,
		"stored_mod_version": 0,
		"settings_signature": "sig"
	}


func _wait_for_store_count(store: FakeStore, expected_count: int) -> bool:
	var deadline_msec := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline_msec:
		if store.get_store_count() >= expected_count:
			return true
		OS.delay_msec(1)
	return false


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_ARTIFACT_DISK_WRITE_QUEUE_TEST] FAIL: %s" % message)
	return false
