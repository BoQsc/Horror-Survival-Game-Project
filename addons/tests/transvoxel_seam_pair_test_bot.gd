extends Node

const MeshBuilderClass := "MeshBuilder"
const SEAM_X := 0.0
const POSITION_EPSILON := 0.25
const HEIGHT_EPSILON := 0.75

func _ready() -> void:
	print("[TRANSVOXEL_SEAM] Starting seam-pair validation")
	call_deferred("_run_tests")


func _run_tests() -> void:
	if not ClassDB.class_exists(MeshBuilderClass):
		print("[TRANSVOXEL_SEAM] ERROR: MeshBuilder GDExtension class not available")
		get_tree().quit(1)
		return

	var builder: Object = ClassDB.instantiate(MeshBuilderClass)
	if builder == null:
		print("[TRANSVOXEL_SEAM] ERROR: Could not instantiate MeshBuilder")
		get_tree().quit(1)
		return

	var heightmap := _build_heightmap_slope(128, 128, 8, 28)
	var fine_mesh: ArrayMesh = builder.build_transvoxel_heightfield_mesh(
		heightmap,
		128,
		128,
		128.0,
		32.0,
		Vector3(-64, 0, -64),
		Vector3(64, 32, 64),
		8,
		1 << 0
	)
	var coarse_mesh: ArrayMesh = builder.build_transvoxel_heightfield_mesh(
		heightmap,
		128,
		128,
		128.0,
		32.0,
		Vector3(0, 0, -64),
		Vector3(128, 64, 128),
		8,
		1 << 1
	)

	if fine_mesh == null or coarse_mesh == null:
		print("[TRANSVOXEL_SEAM] ERROR: One of the seam meshes failed to build")
		get_tree().quit(1)
		return

	var fine_vertices: PackedVector3Array = fine_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var coarse_vertices: PackedVector3Array = coarse_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if fine_vertices.is_empty() or coarse_vertices.is_empty():
		print("[TRANSVOXEL_SEAM] ERROR: Seam meshes have no vertices")
		get_tree().quit(1)
		return

	var fine_profile := _build_seam_profile(fine_vertices)
	var coarse_profile := _build_seam_profile(coarse_vertices)
	if fine_profile.is_empty() or coarse_profile.is_empty():
		print("[TRANSVOXEL_SEAM] ERROR: Seam profiles are empty")
		get_tree().quit(1)
		return

	var matched := 0
	var max_delta := 0.0
	for z_key in coarse_profile.keys():
		var coarse_y := float(coarse_profile[z_key])
		var fine_match := _nearest_profile_value(fine_profile, float(z_key))
		if fine_match == null:
			continue
		matched += 1
		max_delta = max(max_delta, abs(coarse_y - float(fine_match)))

	if matched < max(4, coarse_profile.size() / 2):
		print("[TRANSVOXEL_SEAM] ERROR: Too few matching seam samples (%d matched of %d)" % [matched, coarse_profile.size()])
		get_tree().quit(1)
		return
	if max_delta > HEIGHT_EPSILON:
		print("[TRANSVOXEL_SEAM] ERROR: Seam height mismatch too large (%.3f)" % max_delta)
		get_tree().quit(1)
		return

	print("[TRANSVOXEL_SEAM] Seam pair passed with %d matched samples and max delta %.3f" % [matched, max_delta])
	get_tree().quit(0)


func _build_heightmap_slope(width: int, height: int, low_value: int, high_value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(width * height)
	for z in range(height):
		for x in range(width):
			var t := float(x) / float(max(1, width - 1))
			bytes[z * width + x] = int(round(lerp(float(low_value), float(high_value), t)))
	return bytes


func _build_seam_profile(vertices: PackedVector3Array) -> Dictionary:
	var profile: Dictionary = {}
	for v in vertices:
		if abs(v.x - SEAM_X) > POSITION_EPSILON:
			continue
		var z_key := snappedf(v.z, POSITION_EPSILON)
		var current := profile.get(z_key, null)
		if current == null or v.y > float(current):
			profile[z_key] = v.y
	return profile


func _nearest_profile_value(profile: Dictionary, z_key: float) -> Variant:
	var best_value = null
	var best_distance := 1.0e20
	for candidate_key in profile.keys():
		var candidate_z := float(candidate_key)
		var distance := abs(candidate_z - z_key)
		if distance < best_distance:
			best_distance = distance
			best_value = profile[candidate_key]
	return best_value
