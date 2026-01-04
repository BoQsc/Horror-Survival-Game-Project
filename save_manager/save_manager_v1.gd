class_name SaveManagerV1
extends RefCounted
## SaveManagerV1 - Handles loading v1 save files
## Static class that delegates to SaveManagerV2 for actual execution

static func load_v1_save(save_data: Dictionary, save_manager: Node) -> bool:
	DebugManager.log_save("Loading v1 save file...")
	
	# Use existing v1 load logic
	# Load prefabs first (prevents respawning during chunk generation)
	save_manager._load_prefab_data(save_data.get("prefabs", {}))
	save_manager._load_building_spawn_data(save_data.get("building_spawns", {}))
	
	# Set loading flag - entities will be deferred until terrain is ready
	save_manager.is_loading_game = true
	save_manager.pending_entity_data = save_data.get("entities", {})
	
	# Load core systems
	save_manager._load_player_data(save_data.get("player", {}))
	save_manager._load_terrain_data(save_data.get("terrain_modifications", {}))
	save_manager._load_building_data(save_data.get("buildings", {}))
	save_manager._load_vegetation_data(save_data.get("vegetation", {}))
	save_manager._load_road_data(save_data.get("roads", {}))
	
	# Defer doors and vehicles
	save_manager.call_deferred("_load_door_data", save_data.get("doors", {}))
	save_manager.pending_vehicle_data = save_data.get("vehicles", {})
	
	DebugManager.log_save("V1 load complete (new systems will use defaults)")
	return true

