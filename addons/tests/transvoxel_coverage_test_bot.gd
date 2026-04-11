extends Node3D

const MeshBuilderClass := "MeshBuilder"
const TransvoxelLayoutClass := preload("res://world_marching_cubes/transvoxel_layout.gd")
const RAY_TOP := 256.0
const RAY_BOTTOM := -64.0

func _ready() -> void:
	print("[TRANSVOXEL_COVERAGE] Starting coverage validation")
	call_deferred("_run_tests")


func _run_tests() -> void:
	if not ClassDB.class_exists(MeshBuilderClass):
		print("[TRANSVOXEL_COVERAGE] ERROR: MeshBuilder GDExtension class not available")
		get_tree().quit(1)
		return

	var builder: Object = ClassDB.instantiate(MeshBuilderClass)
	if builder == null:
		print("[TRANSVOXEL_COVERAGE] ERROR: Could not instantiate MeshBuilder")
		get_tree().quit(1)
		return

	var layout_builder: Object = TransvoxelLayoutClass.new()
	var layout: Dictionary = layout_builder.build_layout(Vector2i(0, 0), 8, 128, 32, 8)
	if not await _run_layout_case(builder, layout):
		get_tree().quit(1)
		return

	print("[TRANSVOXEL_COVERAGE] Coverage validation passed")
	get_tree().quit(0)


func _run_layout_case(builder: Object, layout: Dictionary) -> bool:
	var root := Node3D.new()
	root.name = "TransvoxelCoverageRoot"
	add_child(root)

	var blocks: Array = layout.get("blocks", [])
	var meshes: Array = []
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF

	for block in blocks:
		min_x = min(min_x, float(block.get("min_x", 0.0)))
		max_x = max(max_x, float(block.get("max_x", 0.0)))
		min_z = min(min_z, float(block.get("min_z", 0.0)))
		max_z = max(max_z, float(block.get("max_z", 0.0)))
		var mesh: ArrayMesh = builder.build_transvoxel_heightfield_mesh(
			_build_heightmap_gradient(128, 128, 8, 28),
			128,
			128,
			128.0,
			32.0,
			Vector3(float(block.get("min_x", 0.0)), 0.0, float(block.get("min_z", 0.0))),
			Vector3(float(block.get("block_size", 0.0)), 32.0, float(block.get("block_size", 0.0))),
			int(block.get("subdivisions", 8)),
			int(block.get("transition_mask", 0))
		)
		if mesh == null or mesh.get_surface_count() == 0:
			print("[TRANSVOXEL_COVERAGE] ERROR: %s produced no mesh" % String(block.get("block_kind", "block")))
			root.queue_free()
			return false
		var arrays: Array = mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if vertices.is_empty() or indices.is_empty():
			print("[TRANSVOXEL_COVERAGE] ERROR: %s produced empty mesh arrays" % String(block.get("block_kind", "block")))
			root.queue_free()
			return false
		meshes.append(mesh)
		var body := StaticBody3D.new()
		body.name = String(block.get("block_kind", "block"))
		body.collision_layer = 1
		body.collision_mask = 1
		root.add_child(body)
		var collision_shape := CollisionShape3D.new()
		collision_shape.shape = mesh.create_trimesh_shape()
		if collision_shape.shape == null:
			print("[TRANSVOXEL_COVERAGE] ERROR: Failed to build collision for %s" % String(block.get("block_kind", "block")))
			root.queue_free()
			return false
		body.add_child(collision_shape)

	await get_tree().physics_frame
	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space_state == null:
		print("[TRANSVOXEL_COVERAGE] ERROR: Could not access physics space")
		root.queue_free()
		return false

	var widest_block_world: float = float(layout.get("max_block_world", layout.get("coarse_block_world", 1.0)))
	var sample_step: int = max(48, int(round(widest_block_world / 4.0)))
	var sample_count := 0
	var hit_count := 0
	var x: int = int(floor(min_x)) + sample_step / 2
	while x < int(ceil(max_x)):
		var z: int = int(floor(min_z)) + sample_step / 2
		while z < int(ceil(max_z)):
			sample_count += 1
			if _ray_hits(space_state, Vector3(float(x), RAY_TOP, float(z)), Vector3(float(x), RAY_BOTTOM, float(z))):
				hit_count += 1
			else:
				print("[TRANSVOXEL_COVERAGE] ERROR: Coverage ray missed at x=%d z=%d" % [x, z])
				root.queue_free()
				return false
			z += sample_step
		x += sample_step

	root.queue_free()
	await get_tree().physics_frame

	if hit_count != sample_count or sample_count == 0:
		print("[TRANSVOXEL_COVERAGE] ERROR: Coverage counts suspicious hits=%d samples=%d" % [hit_count, sample_count])
		return false

	print("[TRANSVOXEL_COVERAGE] Coverage validation passed samples=%d" % sample_count)
	return true


func _ray_hits(space_state: PhysicsDirectSpaceState3D, origin: Vector3, target: Vector3) -> bool:
	var params := PhysicsRayQueryParameters3D.create(origin, target)
	params.collide_with_areas = false
	params.collide_with_bodies = true
	params.hit_from_inside = false
	var result: Dictionary = space_state.intersect_ray(params)
	return not result.is_empty()


func _build_heightmap_gradient(width: int, height: int, low_value: int, high_value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(width * height)
	for z in range(height):
		for x in range(width):
			var tx := float(x) / float(max(1, width - 1))
			var tz := float(z) / float(max(1, height - 1))
			var t := clamp((tx + tz) * 0.5, 0.0, 1.0)
			bytes[z * width + x] = int(round(lerp(float(low_value), float(high_value), t)))
	return bytes
