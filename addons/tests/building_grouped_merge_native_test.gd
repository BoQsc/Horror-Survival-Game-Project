extends SceneTree

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	if not _expect(ClassDB.class_exists("MeshBuilder"), "MeshBuilder should be available"):
		return 1
	var builder = ClassDB.instantiate("MeshBuilder")
	if builder == null or not builder.has_method("build_grouped_merged_array_mesh"):
		return _fail("MeshBuilder grouped merge method is unavailable")

	var chunks := [
		{
			"arrays": _make_triangle_arrays(Vector3.ZERO, false),
			"offset": Vector3(1.0, 0.0, 0.0),
			"material_key": "a"
		},
		{
			"arrays": _make_triangle_arrays(Vector3(2.0, 0.0, 0.0), true),
			"offset": Vector3(10.0, 0.0, 0.0),
			"material_key": "a"
		},
		{
			"arrays": _make_triangle_arrays(Vector3(0.0, 3.0, 0.0), true),
			"offset": Vector3.ZERO,
			"material_key": "b"
		}
	]

	var result: Dictionary = builder.build_grouped_merged_array_mesh(chunks)
	var mesh := result.get("mesh", null) as ArrayMesh
	if not _expect(mesh != null, "native grouped merge should return a mesh"):
		return 1
	if not _expect(int(result.get("source_surfaces", 0)) == 3, "source surface count should be reported"):
		return 1
	if not _expect(int(result.get("output_surfaces", 0)) == 2, "same material key should merge into one output surface"):
		return 1
	if not _expect(int(result.get("output_vertex_count", 0)) == 9, "output vertex count should be reported"):
		return 1
	if not _expect(int(result.get("output_index_count", 0)) == 9, "output index count should be reported"):
		return 1
	if not _expect(mesh.get_surface_count() == 2, "mesh should have two material-grouped surfaces"):
		return 1
	var material_keys: Array = result.get("material_keys", [])
	if not _expect(material_keys == ["a", "b"], "native merge should report material group order for GDScript assignment"):
		return 1

	var surface_a: Array = mesh.surface_get_arrays(0)
	var vertices_a: PackedVector3Array = surface_a[Mesh.ARRAY_VERTEX]
	var uvs_a: PackedVector2Array = surface_a[Mesh.ARRAY_TEX_UV]
	var indices_a: PackedInt32Array = surface_a[Mesh.ARRAY_INDEX]
	if not _expect(vertices_a.size() == 6, "surface A should contain two merged triangles"):
		return 1
	if not _expect(vertices_a[0].is_equal_approx(Vector3(1.0, 0.0, 0.0)), "first offset should be applied"):
		return 1
	if not _expect(vertices_a[3].is_equal_approx(Vector3(12.0, 0.0, 0.0)), "second offset should be applied"):
		return 1
	if not _expect(uvs_a.size() == 6 and uvs_a[4].is_equal_approx(Vector2(1.0, 0.0)), "UVs should be preserved"):
		return 1
	if not _expect(indices_a == PackedInt32Array([0, 1, 2, 3, 4, 5]), "indexed and non-indexed surfaces should remap correctly"):
		return 1

	print("[BUILDING_GROUPED_MERGE_NATIVE_TEST] PASS")
	return 0

func _make_triangle_arrays(origin: Vector3, indexed: bool) -> Array:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		origin,
		origin + Vector3(1.0, 0.0, 0.0),
		origin + Vector3(0.0, 1.0, 0.0)
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.UP])
	if indexed:
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	return arrays

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	return _fail(message)

func _fail(message: String) -> bool:
	printerr("[BUILDING_GROUPED_MERGE_NATIVE_TEST] FAIL: %s" % message)
	return false
