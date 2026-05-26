extends SceneTree

func _init() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	if not _expect(ClassDB.class_exists("MeshBuilder"), "MeshBuilder should be available"):
		return 1
	var builder = ClassDB.instantiate("MeshBuilder")
	if builder == null:
		return _fail("MeshBuilder could not be instantiated")

	var bytes := PackedByteArray()
	_append_packed_vertex(bytes, Vector3(0, 0, 0), 0x00010001, 0x00000001, 0x00000101)
	_append_packed_vertex(bytes, Vector3(1, 0, 0), 0x00010001, 0x00000001, 0x00000101)
	_append_packed_vertex(bytes, Vector3(0, 1, 0), 0x00010001, 0x00000001, 0x00000101)
	_append_packed_vertex(bytes, Vector3(0, 0, 0), 0x00010001, 0x00000001, 0x00000101)
	_append_packed_vertex(bytes, Vector3(1, 0, 0), 0x00020002, 0x00000002, 0x00000101)
	_append_packed_vertex(bytes, Vector3(0, 1, 0), 0x00010001, 0x00000001, 0x00000201)

	var result: Dictionary = builder.build_packed_mesh_and_collision(bytes, 6)
	if not _expect(int(result.get("source_vertex_count", 0)) == 6, "source vertex count should be reported"):
		return 1
	if not _expect(int(result.get("unique_vertex_count", 0)) == 5, "full vertex unique count should include normal/material splits"):
		return 1
	if not _expect(int(result.get("position_unique_vertex_count", 0)) == 3, "position unique count should merge same-position vertices"):
		return 1
	if not _expect(int(result.get("position_material_unique_vertex_count", 0)) == 4, "position+material unique count should preserve material splits"):
		return 1

	print("[TERRAIN_MESH_DUPLICATE_TELEMETRY_TEST] PASS")
	return 0

func _append_packed_vertex(bytes: PackedByteArray, position: Vector3, normal_xy: int, normal_z: int, material_payload: int) -> void:
	bytes.append_array(PackedFloat32Array([position.x, position.y, position.z]).to_byte_array())
	_append_u32_le(bytes, normal_xy)
	_append_u32_le(bytes, normal_z)
	_append_u32_le(bytes, material_payload)

func _append_u32_le(bytes: PackedByteArray, value: int) -> void:
	bytes.append(value & 0xFF)
	bytes.append((value >> 8) & 0xFF)
	bytes.append((value >> 16) & 0xFF)
	bytes.append((value >> 24) & 0xFF)

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	return _fail(message)

func _fail(message: String) -> bool:
	printerr("[TERRAIN_MESH_DUPLICATE_TELEMETRY_TEST] FAIL: %s" % message)
	return false
