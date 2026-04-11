extends Node3D

const MeshBuilderClass := "MeshBuilder"
const TransvoxelLayoutClass := preload("res://world_marching_cubes/transvoxel_layout.gd")
const FACE_MASKS := {
	"west": 1 << 1,
	"east": 1 << 0,
	"south": 1 << 5,
	"north": 1 << 4
}
const SAMPLE_STEP := 8
const RAY_TOP := 128.0
const RAY_BOTTOM := -32.0
const RAY_OFFSETS := [-0.25, 0.0, 0.25]

func _ready() -> void:
	print("[TRANSVOXEL_SEAM_GAP] Starting seam-gap validation")
	call_deferred("_run_tests")


func _run_tests() -> void:
	if not ClassDB.class_exists(MeshBuilderClass):
		print("[TRANSVOXEL_SEAM_GAP] ERROR: MeshBuilder GDExtension class not available")
		get_tree().quit(1)
		return

	var builder: Object = ClassDB.instantiate(MeshBuilderClass)
	if builder == null:
		print("[TRANSVOXEL_SEAM_GAP] ERROR: Could not instantiate MeshBuilder")
		get_tree().quit(1)
		return

	var layout_builder: Object = TransvoxelLayoutClass.new()
	var layout: Dictionary = layout_builder.build_layout(Vector2i(0, 0), 6, 128, 32, 8)
	if not await _run_layout_case(builder, layout):
		get_tree().quit(1)
		return

	print("[TRANSVOXEL_SEAM_GAP] All seam-gap cases passed")
	get_tree().quit(0)


func _run_layout_case(builder: Object, layout: Dictionary) -> bool:
	var root := Node3D.new()
	root.name = "TransvoxelSeamGapRoot"
	add_child(root)

	var blocks: Array = layout.get("blocks", [])
	var meshes: Array = []
	for block in blocks:
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
			print("[TRANSVOXEL_SEAM_GAP] ERROR: %s produced no mesh" % String(block.get("block_kind", "block")))
			root.queue_free()
			return false
		var arrays: Array = mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if vertices.is_empty() or indices.is_empty():
			print("[TRANSVOXEL_SEAM_GAP] ERROR: %s produced empty mesh arrays" % String(block.get("block_kind", "block")))
			root.queue_free()
			return false
		meshes.append(mesh)
		if not _add_collision_block(root, block, mesh):
			print("[TRANSVOXEL_SEAM_GAP] ERROR: %s failed to build collision" % String(block.get("block_kind", "block")))
			root.queue_free()
			return false

	await get_tree().physics_frame

	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space_state == null:
		print("[TRANSVOXEL_SEAM_GAP] ERROR: Could not access physics space")
		root.queue_free()
		return false

	if not _sweep_transition_faces(space_state, blocks):
		root.queue_free()
		return false
	if not _sweep_transition_corners(space_state, blocks):
		root.queue_free()
		return false

	root.queue_free()
	await get_tree().physics_frame

	print("[TRANSVOXEL_SEAM_GAP] Layout passed with %d meshes" % meshes.size())
	return true


func _add_collision_block(parent: Node3D, block: Dictionary, mesh: ArrayMesh) -> bool:
	var body := StaticBody3D.new()
	body.name = String(block.get("block_kind", "Block"))
	body.collision_layer = 1
	body.collision_mask = 1
	parent.add_child(body)

	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "CollisionShape"
	var shape := mesh.create_trimesh_shape()
	if shape == null:
		return false
	collision_shape.shape = shape
	body.add_child(collision_shape)
	return true


func _sweep_transition_faces(space_state: PhysicsDirectSpaceState3D, blocks: Array) -> bool:
	for block in blocks:
		var mask := int(block.get("transition_mask", 0))
		if mask == 0:
			continue
		var min_x := float(block.get("min_x", 0.0))
		var max_x := float(block.get("max_x", 0.0))
		var min_z := float(block.get("min_z", 0.0))
		var max_z := float(block.get("max_z", 0.0))
		if mask & int(FACE_MASKS["west"]) != 0:
			if not _sweep_face_line(space_state, String(block.get("block_kind", "block")), "west", min_x, min_z, max_z, "z"):
				return false
		if mask & int(FACE_MASKS["east"]) != 0:
			if not _sweep_face_line(space_state, String(block.get("block_kind", "block")), "east", max_x, min_z, max_z, "z"):
				return false
		if mask & int(FACE_MASKS["south"]) != 0:
			if not _sweep_face_line(space_state, String(block.get("block_kind", "block")), "south", min_z, min_x, max_x, "x"):
				return false
		if mask & int(FACE_MASKS["north"]) != 0:
			if not _sweep_face_line(space_state, String(block.get("block_kind", "block")), "north", max_z, min_x, max_x, "x"):
				return false
	return true


func _sweep_transition_corners(space_state: PhysicsDirectSpaceState3D, blocks: Array) -> bool:
	var corner_points: Dictionary = {}
	for block in blocks:
		if int(block.get("transition_mask", 0)) == 0:
			continue
		var min_x := float(block.get("min_x", 0.0))
		var max_x := float(block.get("max_x", 0.0))
		var min_z := float(block.get("min_z", 0.0))
		var max_z := float(block.get("max_z", 0.0))
		corner_points["%s|%s" % [str(min_x), str(min_z)]] = Vector2(min_x, min_z)
		corner_points["%s|%s" % [str(min_x), str(max_z)]] = Vector2(min_x, max_z)
		corner_points["%s|%s" % [str(max_x), str(min_z)]] = Vector2(max_x, min_z)
		corner_points["%s|%s" % [str(max_x), str(max_z)]] = Vector2(max_x, max_z)

	for corner in corner_points.values():
		var seam_x: float = float(corner.x)
		var seam_z: float = float(corner.y)
		for offset_x in RAY_OFFSETS:
			for offset_z in RAY_OFFSETS:
				var origin := Vector3(seam_x + float(offset_x), RAY_TOP, seam_z + float(offset_z))
				var target := Vector3(seam_x + float(offset_x), RAY_BOTTOM, seam_z + float(offset_z))
				if not _ray_hits(space_state, origin, target):
					print("[TRANSVOXEL_SEAM_GAP] ERROR: Corner ray missed at x=%.2f z=%.2f" % [origin.x, origin.z])
					return false
	return true


func _sweep_face_line(space_state: PhysicsDirectSpaceState3D, block_kind: String, face_name: String, seam_value: float, span_min: float, span_max: float, axis: String) -> bool:
	var sample_start := int(floor(span_min))
	var sample_end := int(ceil(span_max))
	for sample in range(sample_start, sample_end + 1, SAMPLE_STEP):
		for offset in RAY_OFFSETS:
			var origin: Vector3
			var target: Vector3
			if axis == "z":
				var sample_z: float = float(sample)
				var sample_x: float = seam_value + float(offset)
				origin = Vector3(sample_x, RAY_TOP, sample_z)
				target = Vector3(sample_x, RAY_BOTTOM, sample_z)
				if not _ray_hits(space_state, origin, target):
					print("[TRANSVOXEL_SEAM_GAP] ERROR: %s face %s ray missed at x=%.2f z=%.2f" % [block_kind, face_name, sample_x, sample_z])
					return false
			else:
				var sample_x2: float = float(sample)
				var sample_z2: float = seam_value + float(offset)
				origin = Vector3(sample_x2, RAY_TOP, sample_z2)
				target = Vector3(sample_x2, RAY_BOTTOM, sample_z2)
				if not _ray_hits(space_state, origin, target):
					print("[TRANSVOXEL_SEAM_GAP] ERROR: %s face %s ray missed at x=%.2f z=%.2f" % [block_kind, face_name, sample_x2, sample_z2])
					return false
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
