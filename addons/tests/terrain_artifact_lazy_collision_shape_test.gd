extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var manager := ChunkManagerScript.new()
	manager.terrain_artifact_store_collision_faces = false

	var source_faces := PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.FORWARD])
	var artifact_result: Dictionary = manager._mesh_result_to_artifact_data({
		"deferred_mesh_data": true,
		"arrays": _triangle_arrays(),
		"faces": source_faces,
		"source_vertex_count": 3,
		"source_index_count": 3
	})
	var stored_faces: PackedVector3Array = artifact_result.get("faces", PackedVector3Array())
	if not _expect(stored_faces.is_empty(), "compact terrain artifacts should not store collision faces by default"):
		manager.free()
		return 1
	if not _expect(not bool(artifact_result.get("collision_faces_stored", true)), "artifact telemetry should report that collision faces were omitted"):
		manager.free()
		return 1

	var materialized := manager._materialize_deferred_mesh_result(artifact_result, null)
	var mesh_variant: Variant = materialized.get("mesh", null)
	if not _expect(mesh_variant is ArrayMesh, "compact artifact should still materialize an ArrayMesh"):
		manager.free()
		return 1
	if not _expect(materialized.get("shape", null) == null, "compact artifact should defer collision shape creation"):
		manager.free()
		return 1

	var data := ChunkManagerScript.ChunkData.new()
	data.node_terrain = Node3D.new()
	data.terrain_visual_mesh = mesh_variant as ArrayMesh
	if not _expect(manager._ensure_terrain_shape_from_mesh(data), "collision shape should rebuild lazily from the visual mesh"):
		data.node_terrain.free()
		manager.free()
		return 1
	if not _expect(data.terrain_shape is ConcavePolygonShape3D, "lazy collision rebuild should produce a concave shape"):
		data.node_terrain.free()
		manager.free()
		return 1

	data.node_terrain.free()
	manager.free()
	print("[TERRAIN_ARTIFACT_LAZY_COLLISION_SHAPE_TEST] PASS")
	return 0


func _triangle_arrays() -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3.ZERO,
		Vector3.RIGHT,
		Vector3.FORWARD
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.UP,
		Vector3.UP,
		Vector3.UP
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	return arrays


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_ARTIFACT_LAZY_COLLISION_SHAPE_TEST] FAIL: %s" % message)
	return false
