extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

var _native: Object = null

class FakeTerrainManager:
	extends Node3D
	const CHUNK_STRIDE := 16
	var world_seed := 12345
	signal chunk_generated(coord: Vector3i, chunk_node: Node3D)
	signal chunk_modified(coord: Vector3i, chunk_node: Node3D)
	signal spawn_zones_ready(positions: Array)

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
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
	if native == null or not native.has_method("pick_nearest_pending_vegetation_chunk"):
		return _fail("native pending chunk selector is unavailable")

	var pending_chunks: Array[Dictionary] = [
		{"coord": Vector2i(5, 0)},
		{"coord": Vector2i(0, 0)},
		{"coord": Vector2i(-2, 0)},
		{"coord": Vector2i(0, 3)}
	]
	var viewer_pos := Vector3(8.0, 0.0, 8.0)
	var native_index := int(native.pick_nearest_pending_vegetation_chunk(pending_chunks, viewer_pos, FakeTerrainManager.CHUNK_STRIDE))
	if not _expect(native_index == 1, "native selector should pick nearest pending chunk"):
		return 1

	var tied_chunks: Array[Dictionary] = [
		{"coord": Vector2i(0, 0)},
		{"coord": Vector2i(0, 0)}
	]
	native_index = int(native.pick_nearest_pending_vegetation_chunk(tied_chunks, viewer_pos, FakeTerrainManager.CHUNK_STRIDE))
	if not _expect(native_index == 0, "native selector should keep first equal-distance chunk"):
		return 1
	if not _expect(int(native.pick_nearest_pending_vegetation_chunk([], viewer_pos, FakeTerrainManager.CHUNK_STRIDE)) == -1, "empty pending list should return -1"):
		return 1
	if not _expect(int(native.pick_nearest_pending_vegetation_chunk(pending_chunks, viewer_pos, 0)) == 0, "invalid stride should preserve fallback index 0"):
		return 1

	var manager: VegetationManager = VegetationManagerScript.new()
	var terrain := FakeTerrainManager.new()
	manager.terrain_manager = terrain
	root.add_child(terrain)
	root.add_child(manager)
	manager.global_position = viewer_pos
	manager.pending_chunks = pending_chunks.duplicate(true)
	var manager_index := manager._get_next_pending_chunk_index()
	if not _expect(manager_index == native_index or manager_index == 1, "manager should use nearest pending chunk selection"):
		manager.free()
		terrain.free()
		return 1
	var telemetry := manager.get_telemetry_snapshot()
	if not _expect(str(telemetry.get("last_pending_chunk_selection_backend", "")) == "native", "manager should record native scheduler backend"):
		manager.free()
		terrain.free()
		return 1
	if not _expect(int(telemetry.get("pending_chunk_selection_native_calls", 0)) == 1, "manager should count native scheduler call"):
		manager.free()
		terrain.free()
		return 1
	if not _expect(int(telemetry.get("last_pending_chunk_selection_scan_count", 0)) == pending_chunks.size(), "manager should report pending scan size"):
		manager.free()
		terrain.free()
		return 1

	manager.free()
	terrain.free()
	print("[VEGETATION_PENDING_CHUNK_SCHEDULER_NATIVE_TEST] PASS")
	return 0

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_PENDING_CHUNK_SCHEDULER_NATIVE_TEST] FAIL: %s" % message)
	return false

func _fail(message: String) -> int:
	printerr("[VEGETATION_PENDING_CHUNK_SCHEDULER_NATIVE_TEST] FAIL: %s" % message)
	return 1
