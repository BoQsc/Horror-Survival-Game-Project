extends SceneTree

const WorldTerrainArtifactBaker = preload("res://world_performance/world_terrain_artifact_baker.gd")
const WorldMapData = preload("res://world_map_data/world_map_data.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var baker := WorldTerrainArtifactBaker.new()
	var world_path := "user://worlds/world_terrain_artifact_baker_contract_%d" % Time.get_ticks_usec()
	baker._world_path = world_path
	baker._origin = Vector3(31.0, 0.0, -31.0)
	baker._origins = [baker._origin]
	baker._radius = 2
	baker._bake_coords = baker._build_bake_coords_for_origins(baker._origins, baker._radius)
	baker._expected_chunks = baker._bake_coords.size()

	if not _expect(baker._expected_chunks == 75, "radius-two bake should target 75 chunks"):
		baker.free()
		return 1
	if not _expect(baker._count_square_preheat_chunks(5) == 363, "radius-five bake should target 363 chunks"):
		baker.free()
		return 1
	var multi_origin_coords := baker._build_bake_coords_for_origins([
		Vector3(0.0, 0.0, 0.0),
		Vector3(31.0, 0.0, 0.0),
		Vector3(0.0, 0.0, 0.0)
	], 0)
	if not _expect(multi_origin_coords.size() == 6, "multi-origin bake should deduplicate exact duplicate chunk origins"):
		baker.free()
		return 1

	var profile := baker._build_profile("contract")
	if not _expect(str(profile.get("artifact_root", "")) == WorldMapData.get_world_terrain_artifact_root(world_path), "profile should expose world-local artifact root"):
		baker.free()
		return 1
	if not _expect(str(profile.get("manifest_path", "")) == WorldMapData.get_world_terrain_artifact_manifest_path(world_path), "profile should expose artifact manifest path"):
		baker.free()
		return 1

	var completed_profile := {
		"artifact_count": 75,
		"stored_artifact_count": 70,
		"reused_disk_artifact_count": 5,
		"elapsed_ms": 1234.0
	}
	if not _expect(baker._write_manifest(completed_profile), "completed bake should write a world-local manifest"):
		baker.free()
		return 1
	var manifest_path := WorldMapData.get_world_terrain_artifact_manifest_path(world_path)
	if not _expect(FileAccess.file_exists(manifest_path), "manifest file should exist on disk"):
		baker.free()
		return 1

	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if not _expect(file != null, "manifest should be readable"):
		baker.free()
		return 1
	var json := JSON.new()
	var parse_result := json.parse(file.get_as_text())
	file.close()
	if not _expect(parse_result == OK, "manifest should contain valid JSON"):
		baker.free()
		return 1
	var manifest: Dictionary = json.get_data()
	if not _expect(str(manifest.get("magic", "")) == WorldTerrainArtifactBaker.MANIFEST_MAGIC, "manifest should identify terrain artifact bakes"):
		baker.free()
		return 1
	if not _expect(int(manifest.get("expected_chunks", 0)) == 75, "manifest should retain expected chunk count"):
		baker.free()
		return 1
	if not _expect(int(manifest.get("origin_count", 0)) == 1, "manifest should retain terrain bake origin count"):
		baker.free()
		return 1
	var manifest_origins: Array = manifest.get("origins", [])
	if not _expect(manifest_origins.size() == 1, "manifest should retain terrain bake origins"):
		baker.free()
		return 1
	if not _expect(int(manifest.get("artifact_count", 0)) == 75, "manifest should retain artifact count"):
		baker.free()
		return 1
	if not _expect(str(manifest.get("artifact_root", "")) == WorldMapData.get_world_terrain_artifact_root(world_path), "manifest should point at world-local artifacts"):
		baker.free()
		return 1

	baker.free()
	print("[WORLD_TERRAIN_ARTIFACT_BAKER_CONTRACT_TEST] PASS")
	return 0


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_TERRAIN_ARTIFACT_BAKER_CONTRACT_TEST] FAIL: %s" % message)
	return false
