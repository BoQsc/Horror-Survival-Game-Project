extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

class FakeTerrainManager:
	extends Node3D
	var world_map_active: bool = false

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var exit_code := _run()
	quit(exit_code)

func _run() -> int:
	var manager: VegetationManager = VegetationManagerScript.new()
	manager.vegetation_render_prewarm_frames = 0
	root.add_child(manager)

	if not _expect(_mesh_has_alpha_surface(manager.tree_mesh), "tree alpha-cutout surface must be preserved"):
		manager.free()
		return 1
	if not _expect(_mesh_has_alpha_surface(manager.grass_mesh), "grass alpha-cutout surface must be preserved"):
		manager.free()
		return 1
	if not _expect(_mesh_surface_is_opaque(manager.rock_mesh), "rock material should remain opaque"):
		manager.free()
		return 1

	var telemetry := manager.get_telemetry_snapshot()
	if not _expect(telemetry.has("last_global_render_upload_bytes"), "telemetry should expose last render upload bytes"):
		manager.free()
		return 1
	if not _expect(int(telemetry.get("tree_mesh_primitives", 0)) > 0, "telemetry should report cached tree mesh primitive count"):
		manager.free()
		return 1
	if not _expect(
			not bool(telemetry.get("vegetation_global_render_ignore_occlusion_culling", true)),
			"global vegetation batches should allow occlusion culling by default"
	):
		manager.free()
		return 1
	var counts: Dictionary = telemetry.get("vegetation_opaque_material_optimization_counts", {})
	if not _expect(int(counts.get("tree_scanned_surfaces", 0)) == 1, "tree scanned surface count mismatch"):
		manager.free()
		return 1
	if not _expect(int(counts.get("grass_scanned_surfaces", 0)) == 1, "grass scanned surface count mismatch"):
		manager.free()
		return 1
	if not _expect(int(counts.get("rock_scanned_surfaces", 0)) == 1, "rock scanned surface count mismatch"):
		manager.free()
		return 1
	if not _expect(int(counts.get("tree_optimized_surfaces", 0)) == 0, "tree alpha surface should not be optimized"):
		manager.free()
		return 1
	if not _expect(int(counts.get("grass_optimized_surfaces", 0)) == 0, "grass alpha surface should not be optimized"):
		manager.free()
		return 1
	if not _expect(int(counts.get("rock_optimized_surfaces", 0)) == 0, "rock should not need optimization"):
		manager.free()
		return 1
	if not _expect(counts.has("tree_alpha_split_surfaces"), "tree alpha split telemetry should be present"):
		manager.free()
		return 1
	if not _expect(
			int(counts.get("tree_alpha_split_surfaces", 0)) > 0,
			"tree alpha split should move the opaque subset out of alpha scissor; counts=%s" % str(counts)
	):
		manager.free()
		return 1
	if not _expect(
			int(counts.get("tree_alpha_split_opaque_triangles", 0)) > 0,
			"tree alpha split should find opaque tree triangles; counts=%s" % str(counts)
	):
		manager.free()
		return 1
	var default_tree_batch := manager._get_global_render_multimesh("tree", Vector2i.ZERO)
	if not _expect(
			default_tree_batch is MultiMeshInstance3D and not default_tree_batch.ignore_occlusion_culling,
			"default tree render batch should participate in occlusion culling"
	):
		manager.free()
		return 1
	manager.vegetation_global_render_ignore_occlusion_culling = true
	var override_tree_batch := manager._get_global_render_multimesh("tree", Vector2i(1, 0))
	if not _expect(
			override_tree_batch is MultiMeshInstance3D and override_tree_batch.ignore_occlusion_culling,
			"explicit vegetation occlusion override should still be honored"
	):
		manager.free()
		return 1
	if not _expect(is_equal_approx(default_tree_batch.lod_bias, 1.0), "default non-world-map tree render batch should use default LOD bias"):
		manager.free()
		return 1

	var terrain := FakeTerrainManager.new()
	terrain.world_map_active = true
	root.add_child(terrain)
	manager.terrain_manager = terrain
	manager.vegetation_global_render_ignore_occlusion_culling = false
	if not _expect(
			manager.world_map_vegetation_render_cluster_size == 1
			and manager._effective_vegetation_render_cluster_size("tree") == 1,
			"world-map tree render batches should default to one terrain chunk for tighter culling/LOD"
	):
		manager.free()
		terrain.free()
		return 1
	var world_map_tree_batch := manager._get_global_render_multimesh("tree", Vector2i.ZERO)
	if not _expect(
			world_map_tree_batch is MultiMeshInstance3D and is_equal_approx(world_map_tree_batch.lod_bias, manager.world_map_tree_render_lod_bias),
			"world-map tree render batch should use the tree-specific LOD bias"
	):
		manager.free()
		terrain.free()
		return 1
	var world_map_grass_batch := manager._get_global_render_multimesh("grass", Vector2i(2, 0))
	if not _expect(
			world_map_grass_batch is MultiMeshInstance3D and is_equal_approx(world_map_grass_batch.lod_bias, manager.vegetation_render_lod_bias),
			"world-map grass render batch should keep the general vegetation LOD bias"
	):
		manager.free()
		terrain.free()
		return 1
	var world_map_telemetry := manager.get_telemetry_snapshot()
	if not _expect(
			is_equal_approx(float(world_map_telemetry.get("effective_vegetation_tree_render_lod_bias", -1.0)), manager.world_map_tree_render_lod_bias),
			"telemetry should expose the effective world-map tree LOD bias"
	):
		manager.free()
		terrain.free()
		return 1

	terrain.free()
	manager.free()
	print("[VEGETATION_OPAQUE_MATERIAL_OPTIMIZATION_TEST] PASS")
	return 0

func _mesh_surface_is_opaque(mesh: Mesh) -> bool:
	if mesh == null or mesh.get_surface_count() <= 0:
		return false
	var material := mesh.surface_get_material(0)
	if material is not BaseMaterial3D:
		return false
	return (material as BaseMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_DISABLED

func _mesh_has_alpha_surface(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	for surface_index in range(mesh.get_surface_count()):
		var material := mesh.surface_get_material(surface_index)
		if material is not BaseMaterial3D:
			continue
		if (material as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return true
	return false

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_OPAQUE_MATERIAL_OPTIMIZATION_TEST] FAIL: %s" % message)
	return false
