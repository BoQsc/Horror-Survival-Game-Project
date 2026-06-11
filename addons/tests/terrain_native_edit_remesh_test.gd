extends SceneTree

const ChunkManagerScript = preload("res://world_marching_cubes/chunk_manager.gd")


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	if not _expect(ClassDB.class_exists("MeshBuilder"), "MeshBuilder GDExtension should be available"):
		return 1

	var manager := ChunkManagerScript.new()
	var builder = ClassDB.instantiate("MeshBuilder")
	if not _expect(builder != null, "MeshBuilder instance should be created"):
		manager.free()
		return 1

	var density_bytes := _build_plane_density_bytes()
	var material_bytes := _build_material_bytes()
	var result := manager._build_native_modified_mesh_result(builder, density_bytes, material_bytes, 0, null)
	if not _expect(bool(result.get("native_cpu_edit_meshing", false)), "edit remesh should use native CPU marching cubes"):
		manager.free()
		return 1
	if not _expect(bool(result.get("deferred_mesh_data", false)), "edit remesh should prefer deferred mesh data"):
		manager.free()
		return 1
	if not _expect(int(result.get("source_vertex_count", 0)) > 0, "edit remesh should produce terrain vertices"):
		manager.free()
		return 1

	var material := StandardMaterial3D.new()
	var materialized := manager._materialize_deferred_mesh_result(result, material)
	var mesh_variant: Variant = materialized.get("mesh", null)
	var shape_variant: Variant = materialized.get("shape", null)
	var height_map: PackedFloat32Array = materialized.get("height_map", PackedFloat32Array())
	if not _expect(mesh_variant is ArrayMesh, "deferred edit mesh should materialize to ArrayMesh"):
		manager.free()
		return 1
	var mesh := mesh_variant as ArrayMesh
	if not _expect(mesh.get_surface_count() > 0, "materialized edit mesh should have a surface"):
		manager.free()
		return 1
	if not _expect(mesh.surface_get_material(0) == material, "materialized edit mesh should receive the supplied material"):
		manager.free()
		return 1
	if not _expect(shape_variant is ConcavePolygonShape3D, "materialized edit mesh should include collision shape"):
		manager.free()
		return 1
	if not _expect(height_map.size() == ChunkManagerScript.CHUNK_STRIDE * ChunkManagerScript.CHUNK_STRIDE, "terrain edit remesh should include a height map"):
		manager.free()
		return 1

	manager.free()
	print("[TERRAIN_NATIVE_EDIT_REMESH_TEST] PASS")
	return 0


func _build_plane_density_bytes() -> PackedByteArray:
	var values := PackedFloat32Array()
	var density_size := ChunkManagerScript.DENSITY_GRID_SIZE
	values.resize(density_size * density_size * density_size)
	var index := 0
	for z in range(density_size):
		for y in range(density_size):
			for x in range(density_size):
				values[index] = float(y) - 8.5
				index += 1
	return values.to_byte_array()


func _build_material_bytes() -> PackedByteArray:
	var density_size := ChunkManagerScript.DENSITY_GRID_SIZE
	var voxel_count := density_size * density_size * density_size
	var bytes := PackedByteArray()
	bytes.resize(voxel_count * 4)
	for i in range(voxel_count):
		bytes.encode_u32(i * 4, 1)
	return bytes


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[TERRAIN_NATIVE_EDIT_REMESH_TEST] FAIL: %s" % message)
	return false
