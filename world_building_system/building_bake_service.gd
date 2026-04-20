extends RefCounted
class_name BuildingBakeService

const WorldMapBakeProxy = preload("res://world_building_system/world_map_bake_proxy.gd")
const BuildingManagerScript = preload("res://world_building_system/building_manager.gd")
const PrefabSpawnerScript = preload("res://world_building_system/prefab_spawner.gd")


func bake_world_buildings(
		context_node: Node,
		save_path: String,
		buildings: Array,
		building_map: Image,
		world_seed: int,
		road_spacing: float,
		terrain_height: float,
		water_level: float,
		road_width: float
	) -> bool:
	if context_node == null or not is_instance_valid(context_node) or not context_node.is_inside_tree():
		push_warning("[BuildingBakeService] Invalid bake context node")
		return false
	if buildings.is_empty():
		return true

	var bake_root := Node3D.new()
	bake_root.name = "BuildingBakeRoot"
	context_node.add_child(bake_root)

	var terrain_proxy := WorldMapBakeProxy.new()
	terrain_proxy.name = "WorldMapBakeProxy"
	terrain_proxy.world_map_active = true
	terrain_proxy.world_seed = world_seed
	terrain_proxy.procedural_road_spacing = road_spacing
	terrain_proxy.terrain_height = terrain_height
	terrain_proxy.water_level = water_level
	terrain_proxy.procedural_road_width = road_width
	terrain_proxy._world_map_buildings = buildings
	terrain_proxy._world_map_building_map = building_map
	bake_root.add_child(terrain_proxy)

	var building_manager := BuildingManagerScript.new()
	building_manager.name = "BakedBuildingManager"
	building_manager.world_map_mode = true
	building_manager.render_distance = 999999
	bake_root.add_child(building_manager)

	var prefab_spawner := PrefabSpawnerScript.new()
	prefab_spawner.name = "BakedPrefabSpawner"
	prefab_spawner.terrain_manager = terrain_proxy
	prefab_spawner.building_manager = building_manager
	bake_root.add_child(prefab_spawner)

	await context_node.get_tree().process_frame
	await context_node.get_tree().process_frame

	for bldg in buildings:
		if typeof(bldg) != TYPE_DICTIONARY:
			continue
		var prefab_name := str(bldg.get("type", "small_house"))
		var rotation := int(bldg.get("rotation", 0))
		var spawn_pos := Vector3(
			float(bldg.get("spawn_origin_x", bldg.get("x", 0.0))),
			float(bldg.get("spawn_origin_y", bldg.get("y", 0.0))),
			float(bldg.get("spawn_origin_z", bldg.get("z", 0.0)))
		)
		if not prefab_spawner.spawn_user_prefab(prefab_name, spawn_pos, 0, rotation, false, false, false, false, false, false, 0, false):
			continue

	var bake_start_ms := Time.get_ticks_msec()
	while building_manager.has_pending_building_work() or building_manager.has_dirty_chunks() or building_manager.has_pending_visual_batch_work():
		building_manager.flush_dirty_chunks()
		if building_manager.has_method("flush_global_visual_batches"):
			building_manager.flush_global_visual_batches()
		await context_node.get_tree().process_frame
		if Time.get_ticks_msec() - bake_start_ms > 120000:
			push_warning("[BuildingBakeService] Building bake timed out")
			break

	building_manager.flush_dirty_chunks()
	if building_manager.has_method("flush_global_visual_batches"):
		building_manager.flush_global_visual_batches()

	var manifest := building_manager.save_baked_buildings_to_dir(save_path)
	var success := not manifest.is_empty()

	bake_root.queue_free()
	await context_node.get_tree().process_frame
	return success
