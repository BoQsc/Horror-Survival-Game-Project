extends SceneTree

const VegetationManagerScript = preload("res://world_vegetation/vegetation_manager.gd")

const TREE_COUNT := 256
const TREE_SPACING := 16.0
const TREE_DISTANCE := 260.0

var _world: Node3D
var _camera: Camera3D
var _manager: VegetationManager
var _tree_batch: MultiMeshInstance3D

func _init() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	var exit_code := await _run()
	quit(exit_code)

func _run() -> int:
	_setup_scene()
	var lod_counts: Dictionary = _manager.get_telemetry_snapshot().get("vegetation_mesh_lod_counts", {})
	var tree_lod_levels := int(lod_counts.get("tree_prepared_lod_levels", 0))
	if not _expect(tree_lod_levels > 0, "tree mesh should contain generated Godot LOD data before render validation"):
		return 1

	var baseline_primitives := await _sample_primitives_for_threshold(1.0)
	var aggressive_primitives := await _sample_primitives_for_threshold(100.0)
	print("[VEGETATION_MESH_LOD_RENDER_TEST] baseline_primitives=%d aggressive_primitives=%d tree_lod_levels=%d" % [
		baseline_primitives,
		aggressive_primitives,
		tree_lod_levels,
	])

	_cleanup_scene()
	if not _expect(baseline_primitives > 0, "baseline primitive count should be visible"):
		return 1
	if not _expect(aggressive_primitives > 0, "aggressive primitive count should be visible"):
		return 1
	if not _expect(aggressive_primitives < baseline_primitives, "aggressive mesh_lod_threshold should reduce rendered tree primitives"):
		return 1
	print("[VEGETATION_MESH_LOD_RENDER_TEST] PASS")
	return 0

func _setup_scene() -> void:
	root.mesh_lod_threshold = 1.0
	_world = Node3D.new()
	root.add_child(_world)

	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 70.0
	_camera.position = Vector3(0.0, 18.0, 0.0)
	_world.add_child(_camera)
	_camera.look_at(Vector3(0.0, 8.0, -TREE_DISTANCE), Vector3.UP)

	_manager = VegetationManagerScript.new()
	_manager.vegetation_render_prewarm_frames = 0
	root.add_child(_manager)

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _manager.tree_mesh
	multimesh.instance_count = TREE_COUNT
	var side := int(ceil(sqrt(float(TREE_COUNT))))
	for i in range(TREE_COUNT):
		var x := float(i % side - side / 2) * TREE_SPACING
		var z := -TREE_DISTANCE - float(i / side) * TREE_SPACING
		var transform := _manager.tree_base_transform
		transform.origin = Vector3(x, 0.0, z)
		multimesh.set_instance_transform(i, transform)

	_tree_batch = MultiMeshInstance3D.new()
	_tree_batch.multimesh = multimesh
	_tree_batch.lod_bias = 1.0
	_world.add_child(_tree_batch)

func _cleanup_scene() -> void:
	if is_instance_valid(_tree_batch):
		_tree_batch.free()
	if is_instance_valid(_manager):
		_manager.free()
	if is_instance_valid(_world):
		_world.free()

func _sample_primitives_for_threshold(threshold: float) -> int:
	root.mesh_lod_threshold = threshold
	RenderingServer.force_sync()
	for i in range(20):
		await process_frame
	RenderingServer.force_sync()
	var samples: Array[int] = []
	for i in range(10):
		await process_frame
		var value := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		if value > 0:
			samples.append(value)
	if samples.is_empty():
		return 0
	samples.sort()
	return samples[int(samples.size() / 2)]

func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[VEGETATION_MESH_LOD_RENDER_TEST] FAIL: %s" % message)
	return false
