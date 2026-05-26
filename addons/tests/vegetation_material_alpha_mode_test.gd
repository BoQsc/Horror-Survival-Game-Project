extends SceneTree

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var scene: PackedScene = load("res://models/tree/1/pine_tree_-_ps1_low_poly.glb")
	if scene == null:
		printerr("[VEGETATION_MATERIAL_ALPHA_MODE_TEST] FAIL: tree GLB failed to load")
		quit(1)
		return
	var instance := scene.instantiate()
	var mesh := _find_mesh(instance)
	if mesh == null:
		printerr("[VEGETATION_MATERIAL_ALPHA_MODE_TEST] FAIL: tree mesh not found")
		instance.free()
		quit(1)
		return
	if mesh.get_surface_count() != 1:
		printerr("[VEGETATION_MATERIAL_ALPHA_MODE_TEST] FAIL: expected one tree surface, got %d" % mesh.get_surface_count())
		instance.free()
		quit(1)
		return
	var material := mesh.surface_get_material(0)
	if material is not BaseMaterial3D:
		printerr("[VEGETATION_MATERIAL_ALPHA_MODE_TEST] FAIL: expected BaseMaterial3D")
		instance.free()
		quit(1)
		return
	var base := material as BaseMaterial3D
	print("[VEGETATION_MATERIAL_ALPHA_MODE_TEST] transparency=%d alpha_scissor=%.3f cull_mode=%d" % [
		base.transparency,
		base.alpha_scissor_threshold,
		base.cull_mode
	])
	if base.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
		printerr("[VEGETATION_MATERIAL_ALPHA_MODE_TEST] FAIL: glTF MASK tree should import as alpha scissor, got %d" % base.transparency)
		instance.free()
		quit(1)
		return
	instance.free()
	print("[VEGETATION_MATERIAL_ALPHA_MODE_TEST] PASS")
	quit(0)

func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return (node as MeshInstance3D).mesh
	for child in node.get_children():
		var mesh := _find_mesh(child)
		if mesh != null:
			return mesh
	return null
