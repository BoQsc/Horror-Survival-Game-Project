extends SceneTree


func _init() -> void:
	var mesh := BoxMesh.new()
	var multimesh_rid := RenderingServer.multimesh_create()
	var expected_origin := Vector3(3.0, 4.0, 5.0)
	RenderingServer.multimesh_allocate_data(
		multimesh_rid,
		1,
		RenderingServer.MULTIMESH_TRANSFORM_3D,
		false,
		false
	)
	RenderingServer.multimesh_set_mesh(multimesh_rid, mesh.get_rid())
	RenderingServer.multimesh_set_buffer(multimesh_rid, PackedFloat32Array([
		1.0, 0.0, 0.0, expected_origin.x,
		0.0, 1.0, 0.0, expected_origin.y,
		0.0, 0.0, 1.0, expected_origin.z
	]))
	RenderingServer.multimesh_set_visible_instances(multimesh_rid, 1)
	var transform := RenderingServer.multimesh_instance_get_transform(multimesh_rid, 0)
	RenderingServer.free_rid(multimesh_rid)
	if transform.origin.distance_squared_to(expected_origin) > 0.0001:
		push_error("Unexpected RenderingServer MultiMesh transform origin: %s" % [transform.origin])
		quit(1)
		return
	print("vegetation_multimesh_rs_verify: ok")
	quit(0)
