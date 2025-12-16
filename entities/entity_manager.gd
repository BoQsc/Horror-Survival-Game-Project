extends Node3D
## Entity Manager - handles spawning, tracking, and despawning of entities
## Entities use the terrain's physics for movement and collision

signal entity_spawned(entity: Node3D)
signal entity_despawned(entity: Node3D)

@export var terrain_manager: Node3D  # Reference to ChunkManager for terrain interaction
@export var max_entities: int = 50  # Maximum number of active entities
@export var spawn_radius: float = 80.0  # Range around player where entities can spawn
@export var despawn_radius: float = 120.0  # Distance at which entities despawn

# Entity scene to spawn (can be overridden per entity type)
@export var default_entity_scene: PackedScene

var player: Node3D
var active_entities: Array[Node3D] = []
var entity_pool: Array[Node3D] = []  # Pooled inactive entities

func _ready():
	# Find player
	player = get_tree().get_first_node_in_group("player")
	if not player:
		push_warning("EntityManager: Player not found in 'player' group!")

func _physics_process(_delta):
	if not player:
		player = get_tree().get_first_node_in_group("player")
		if not player:
			return
	
	_update_entity_proximity()

## Check for entities that need to be despawned (too far from player)
func _update_entity_proximity():
	var player_pos = player.global_position
	var despawn_dist_sq = despawn_radius * despawn_radius
	
	# Find entities to despawn
	var to_despawn: Array[Node3D] = []
	for entity in active_entities:
		if not is_instance_valid(entity):
			to_despawn.append(entity)
			continue
		
		var dist_sq = entity.global_position.distance_squared_to(player_pos)
		if dist_sq > despawn_dist_sq:
			to_despawn.append(entity)
	
	# Despawn far entities
	for entity in to_despawn:
		despawn_entity(entity)

## Spawn an entity at a world position
func spawn_entity(world_pos: Vector3, entity_scene: PackedScene = null) -> Node3D:
	if active_entities.size() >= max_entities:
		push_warning("EntityManager: Max entities reached!")
		return null
	
	var scene_to_use = entity_scene if entity_scene else default_entity_scene
	if not scene_to_use:
		push_error("EntityManager: No entity scene provided!")
		return null
	
	var entity: Node3D
	
	# Try to get from pool
	if entity_pool.size() > 0:
		entity = entity_pool.pop_back()
		entity.visible = true
		entity.process_mode = Node.PROCESS_MODE_INHERIT
	else:
		# Create new instance
		entity = scene_to_use.instantiate()
		add_child(entity)
	
	# Set position
	entity.global_position = world_pos
	
	# Track
	active_entities.append(entity)
	
	# Initialize entity if it has the method
	if entity.has_method("on_spawn"):
		entity.on_spawn(self)
	
	entity_spawned.emit(entity)
	return entity

## Despawn an entity (return to pool)
func despawn_entity(entity: Node3D):
	if not is_instance_valid(entity):
		active_entities.erase(entity)
		return
	
	# Remove from active
	active_entities.erase(entity)
	
	# Notify entity
	if entity.has_method("on_despawn"):
		entity.on_despawn()
	
	# Return to pool
	entity.visible = false
	entity.process_mode = Node.PROCESS_MODE_DISABLED
	entity_pool.append(entity)
	
	entity_despawned.emit(entity)

## Spawn an entity at a random position around the player on terrain surface
func spawn_entity_near_player(entity_scene: PackedScene = null) -> Node3D:
	if not player:
		return null
	
	var player_pos = player.global_position
	
	# Random angle and distance
	var angle = randf() * TAU
	var distance = randf_range(spawn_radius * 0.5, spawn_radius)
	
	var spawn_x = player_pos.x + cos(angle) * distance
	var spawn_z = player_pos.z + sin(angle) * distance
	
	# Get terrain height at spawn position
	var terrain_y = player_pos.y  # Default to player Y if no terrain manager
	if terrain_manager and terrain_manager.has_method("get_terrain_height"):
		terrain_y = terrain_manager.get_terrain_height(spawn_x, spawn_z)
		if terrain_y < -100.0:  # No terrain found
			# Try nearby position
			terrain_y = player_pos.y
	
	var spawn_pos = Vector3(spawn_x, terrain_y + 1.0, spawn_z)  # +1 to spawn above ground
	return spawn_entity(spawn_pos, entity_scene)

## Get all active entities
func get_entities() -> Array[Node3D]:
	return active_entities

## Get entity count
func get_entity_count() -> int:
	return active_entities.size()

## Despawn all entities
func despawn_all():
	for entity in active_entities.duplicate():
		despawn_entity(entity)

## Find nearest entity to a position
func find_nearest_entity(world_pos: Vector3) -> Node3D:
	var nearest: Node3D = null
	var nearest_dist_sq = INF
	
	for entity in active_entities:
		if not is_instance_valid(entity):
			continue
		var dist_sq = entity.global_position.distance_squared_to(world_pos)
		if dist_sq < nearest_dist_sq:
			nearest_dist_sq = dist_sq
			nearest = entity
	
	return nearest

## Save/Load persistence
func get_save_data() -> Dictionary:
	var entities_data: Array = []
	
	for entity in active_entities:
		if not is_instance_valid(entity):
			continue
		
		var entity_data = {
			"position": [entity.global_position.x, entity.global_position.y, entity.global_position.z],
			"rotation": entity.rotation.y,
		}
		
		# Store entity type if available
		if entity.has_meta("entity_type"):
			entity_data["type"] = entity.get_meta("entity_type")
		elif entity.scene_file_path:
			entity_data["scene_path"] = entity.scene_file_path
		
		entities_data.append(entity_data)
	
	return { "entities": entities_data }

func load_save_data(data: Dictionary):
	# Despawn all existing entities first
	despawn_all()
	
	if not data.has("entities"):
		return
	
	for ent_data in data.entities:
		var pos = Vector3(ent_data.position[0], ent_data.position[1], ent_data.position[2])
		var rotation_y = ent_data.get("rotation", 0.0)
		
		var entity: Node3D = null
		
		# Spawn using scene path or default
		if ent_data.has("scene_path") and ResourceLoader.exists(ent_data.scene_path):
			var scene = load(ent_data.scene_path)
			entity = spawn_entity(pos, scene)
		elif default_entity_scene:
			entity = spawn_entity(pos, default_entity_scene)
		
		if entity:
			entity.rotation.y = rotation_y
			if ent_data.has("type"):
				entity.set_meta("entity_type", ent_data.type)
	
	print("EntityManager: Loaded %d entities" % data.entities.size())

