extends Node3D
## Entity Manager - handles spawning, tracking, and despawning of entities
## Uses distance-based zones: Active -> Frozen -> Despawn

signal entity_spawned(entity: Node3D)
signal entity_despawned(entity: Node3D)

@export var terrain_manager: Node3D  # Reference to ChunkManager for terrain interaction
@export var max_entities: int = 50  # Maximum number of active entities
@export var spawn_radius: float = 50.0  # Range around player where entities can spawn
@export var freeze_radius: float = 60.0  # Distance at which entities freeze (physics disabled)
@export var despawn_radius: float = 100.0  # Distance at which entities are removed

# Procedural spawning settings
@export var procedural_spawning_enabled: bool = true
@export var spawn_chance_per_chunk: float = 0.50  # 50% chance per surface chunk
@export var min_spawn_distance_from_player: float = 40.0  # Don't spawn too close
@export var max_spawns_per_chunk: int = 3

# Entity scene to spawn (can be overridden per entity type)
@export var default_entity_scene: PackedScene

var player: Node3D
var active_entities: Array[Node3D] = []
var frozen_entities: Dictionary = {}  # entity -> { position: Vector3 }
var dormant_entities: Array = []  # Stored entities: { position, scene_path, health, state }
var entity_pool: Array[Node3D] = []  # Pooled inactive entities

# Deferred spawning - wait for terrain to load
var pending_spawns: Array = []

# Procedural spawning tracking
var spawned_chunks: Dictionary = {}  # Vector2i -> true (tracks which chunks already spawned entities)
var zombie_scene: PackedScene = null  # Cached zombie scene
var biome_noise: FastNoiseLite = null  # For biome detection (must match GPU)

# Biome-based spawn rules: biome_id -> { "zombie_chance": float }
# Biome IDs: 0=Grass, 3=Sand, 4=Gravel, 5=Snow
var spawn_rules = {
	0: { "zombie_chance": 0.6 },   # Grass - moderate danger
	3: { "zombie_chance": 0.3 },   # Sand - peaceful desert
	4: { "zombie_chance": 0.9 },   # Gravel - high danger ruins
	5: { "zombie_chance": 0.5 },  # Snow - cold hostile
}

func _ready():
	# Find player
	player = get_tree().get_first_node_in_group("player")
	if not player:
		push_warning("EntityManager: Player not found in 'player' group!")
	
	# Setup procedural spawning
	_setup_procedural_spawning()

func _physics_process(_delta):
	if not player:
		player = get_tree().get_first_node_in_group("player")
		if not player:
			return
	
	_update_entity_proximity()
	_check_dormant_respawns()
	
	# Process spawn queue - spawns when terrain is ready
	if not pending_spawns.is_empty():
		_process_spawn_queue()

## Manage entity states based on distance: Active -> Frozen -> Despawn
func _update_entity_proximity():
	var player_pos = player.global_position
	var freeze_dist_sq = freeze_radius * freeze_radius
	var despawn_dist_sq = despawn_radius * despawn_radius
	
	var to_despawn: Array[Node3D] = []
	
	for entity in active_entities:
		if not is_instance_valid(entity):
			to_despawn.append(entity)
			continue
		
		var dist_sq = entity.global_position.distance_squared_to(player_pos)
		
		if dist_sq > despawn_dist_sq:
			# Beyond despawn radius - remove entity
			to_despawn.append(entity)
		elif dist_sq > freeze_dist_sq:
			# In freeze zone - disable physics
			_freeze_entity(entity)
		else:
			# In active zone - ensure physics enabled
			_unfreeze_entity(entity)
	
	# Despawn far entities
	for entity in to_despawn:
		despawn_entity(entity)

## Freeze an entity - disable physics to prevent falling
func _freeze_entity(entity: Node3D):
	if frozen_entities.has(entity):
		return  # Already frozen
	
	# Store current state
	frozen_entities[entity] = {
		"position": entity.global_position
	}
	
	# Disable physics processing
	entity.set_physics_process(false)
	
	# Zero velocity if CharacterBody3D
	if entity is CharacterBody3D:
		entity.velocity = Vector3.ZERO
	
	print("[EntityManager] Frozen entity at distance")

## Unfreeze an entity - re-enable physics
func _unfreeze_entity(entity: Node3D):
	if not frozen_entities.has(entity):
		return  # Not frozen
	
	# Check if terrain is ready before unfreezing
	var pos = entity.global_position
	if terrain_manager and terrain_manager.has_method("get_terrain_height"):
		var terrain_y = terrain_manager.get_terrain_height(pos.x, pos.z)
		if terrain_y < -100.0:
			# Terrain not loaded yet - stay frozen
			return
	
	# Re-enable physics
	entity.set_physics_process(true)
	frozen_entities.erase(entity)
	print("[EntityManager] Unfrozen entity - terrain ready")

## Check if any dormant entities should be respawned (player returned to their area)
func _check_dormant_respawns():
	if dormant_entities.is_empty() or not player:
		return
	
	var player_pos = player.global_position
	var spawn_dist_sq = spawn_radius * spawn_radius
	var completed: Array[int] = []
	var current_time = Time.get_ticks_msec() / 1000.0
	
	for i in range(dormant_entities.size()):
		var data = dormant_entities[i]
		var pos = data.position
		
		# Check if within spawn radius
		var dist_sq = Vector2(pos.x, pos.z).distance_squared_to(Vector2(player_pos.x, player_pos.z))
		if dist_sq > spawn_dist_sq:
			continue  # Still too far
		
		# Use RAYCAST to check if terrain collision is ready (same as spawn queue)
		var space_state = get_world_3d().direct_space_state
		var ray_from = Vector3(pos.x, 200.0, pos.z)
		var ray_to = Vector3(pos.x, -50.0, pos.z)
		
		var query = PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		query.collision_mask = 1  # Only terrain layer
		var result = space_state.intersect_ray(query)
		
		if result.is_empty():
			continue  # Terrain collision not ready
		
		# Wait for collision stability
		if not data.has("ready_time"):
			data["ready_time"] = current_time
			data["collision_y"] = result.position.y
			continue
		
		var elapsed = current_time - data.ready_time
		if elapsed < 0.5:
			continue  # Still waiting
		
		# Respawn the entity at collision point!
		var scene_path = data.scene_path
		if scene_path != "":
			var scene = load(scene_path)
			if scene:
				var respawn_pos = Vector3(pos.x, data.collision_y + 0.3, pos.z)
				var entity = spawn_entity(respawn_pos, scene)
				if entity:
					# Restore state
					if data.health > 0 and "current_health" in entity:
						entity.current_health = data.health
					print("[EntityManager] Respawned dormant entity at %s" % respawn_pos)
					completed.append(i)
	
	# Remove respawned entities from dormant list (reverse order)
	for i in range(completed.size() - 1, -1, -1):
		dormant_entities.remove_at(completed[i])

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
	
	# Only use pooling for default entity scene - custom scenes always create new instances
	# This prevents mixing different entity types (e.g., capsules vs zombies)
	var use_pooling = (entity_scene == null) and entity_pool.size() > 0
	
	if use_pooling:
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

## Despawn an entity - store for later respawn
func despawn_entity(entity: Node3D, permanent: bool = false):
	if not is_instance_valid(entity):
		active_entities.erase(entity)
		frozen_entities.erase(entity)
		return
	
	# Store entity data for respawning (unless permanent despawn like death)
	if not permanent:
		var entity_data = {
			"position": entity.global_position,
			"scene_path": entity.scene_file_path if entity.scene_file_path else "",
			"health": entity.current_health if "current_health" in entity else -1,
			"state": entity.current_state if "current_state" in entity else ""
		}
		dormant_entities.append(entity_data)
		print("[EntityManager] Entity stored for respawn at %s" % entity_data.position)
	
	# Remove from tracking
	active_entities.erase(entity)
	frozen_entities.erase(entity)
	
	# Notify entity
	if entity.has_method("on_despawn"):
		entity.on_despawn()
	
	# Free the entity (we'll recreate from stored data)
	entity.queue_free()
	
	entity_despawned.emit(entity)

## Spawn an entity at a random position around the player on terrain surface
## Adds to spawn queue - actual spawning happens in _process_spawn_queue
func spawn_entity_near_player(entity_scene: PackedScene = null) -> Node3D:
	if not player:
		return null
	
	var player_pos = player.global_position
	
	# Random angle and distance
	var angle = randf() * TAU
	var distance = randf_range(15.0, spawn_radius * 0.6)
	
	var spawn_x = player_pos.x + cos(angle) * distance
	var spawn_z = player_pos.z + sin(angle) * distance
	
	# Add to spawn queue - will be processed when terrain is ready
	pending_spawns.append({
		"position": Vector3(spawn_x, 0, spawn_z),
		"scene": entity_scene
	})
	
	# Return null - entity will spawn later via queue processing
	return null

## Process spawn queue - spawns entities when terrain collision is CONFIRMED ready via raycast
func _process_spawn_queue():
	if pending_spawns.is_empty() or not player:
		return
	
	var completed: Array[int] = []
	var current_time = Time.get_ticks_msec() / 1000.0
	
	for i in range(pending_spawns.size()):
		var spawn_data = pending_spawns[i]
		var pos = spawn_data.position
		
		# For procedural spawns, DON'T check distance - they should spawn regardless
		# Only check distance for manually spawned entities
		var is_procedural = spawn_data.get("procedural", false)
		if not is_procedural:
			var player_pos = player.global_position
			var dist_sq = Vector2(pos.x, pos.z).distance_squared_to(Vector2(player_pos.x, player_pos.z))
			if dist_sq > despawn_radius * despawn_radius:
				completed.append(i)
				continue
		
		# Use RAYCAST to check if terrain collision is actually ready
		# This is more reliable than get_terrain_height which only checks mesh, not collision
		var space_state = get_world_3d().direct_space_state
		var ray_from = Vector3(pos.x, 200.0, pos.z)  # Start high above terrain
		var ray_to = Vector3(pos.x, -50.0, pos.z)    # End below expected terrain
		
		var query = PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		query.collision_mask = 1  # Only terrain layer
		var result = space_state.intersect_ray(query)
		
		if result.is_empty():
			# No collision found - terrain not ready yet, keep waiting
			if not spawn_data.has("wait_start"):
				spawn_data["wait_start"] = current_time
			elif current_time - spawn_data.wait_start > 10.0:
				# Waited too long (10s), give up on this spawn
				print("[EntityManager] Spawn timeout at (%.0f, %.0f) - no collision found" % [pos.x, pos.z])
				completed.append(i)
			continue
		
		# Found collision! Now wait a bit for stability
		if not spawn_data.has("ready_time"):
			spawn_data["ready_time"] = current_time
			spawn_data["collision_y"] = result.position.y
			print("[EntityManager] Collision found at (%.0f, %.1f, %.0f), waiting..." % [pos.x, result.position.y, pos.z])
			continue
		
		# Wait 1.5 seconds after collision detected
		var elapsed = current_time - spawn_data.ready_time
		if elapsed < 1.5:
			continue
		
		# Spawn at collision point + small offset (0.3m to avoid clipping)
		var spawn_pos = Vector3(pos.x, spawn_data.collision_y + 0.3, pos.z)
		var entity = spawn_entity(spawn_pos, spawn_data.scene)
		if entity:
			print("[EntityManager] Spawned entity at %s (collision_y=%.1f, after %.1fs)" % [spawn_pos, spawn_data.collision_y, elapsed])
		completed.append(i)
	
	# Remove processed spawns (reverse order)
	for i in range(completed.size() - 1, -1, -1):
		pending_spawns.remove_at(completed[i])

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
	
	# Convert spawned_chunks keys to arrays for JSON serialization
	var chunks_data: Array = []
	for key in spawned_chunks.keys():
		chunks_data.append([key.x, key.y])
	
	return { 
		"entities": entities_data,
		"spawned_chunks": chunks_data
	}

func load_save_data(data: Dictionary):
	# Despawn all existing entities first
	despawn_all()
	
	# Restore spawned_chunks tracking to prevent duplicate procedural spawns
	spawned_chunks.clear()
	if data.has("spawned_chunks"):
		for chunk_arr in data.spawned_chunks:
			if chunk_arr.size() >= 2:
				spawned_chunks[Vector2i(int(chunk_arr[0]), int(chunk_arr[1]))] = true
		print("[EntityManager] Restored %d spawned chunk records" % spawned_chunks.size())
	
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

# ============ PROCEDURAL SPAWNING ============

## Setup procedural spawning - connect to terrain signals
func _setup_procedural_spawning():
	if not procedural_spawning_enabled:
		return
	
	# Load zombie scene for procedural spawning
	if ResourceLoader.exists("res://entities/zombie_base.tscn"):
		zombie_scene = load("res://entities/zombie_base.tscn")
		print("[EntityManager] Loaded zombie scene for procedural spawning")
	else:
		push_warning("[EntityManager] Zombie scene not found - procedural spawning disabled")
		procedural_spawning_enabled = false
		return
	
	# Setup biome noise (must match gen_density.glsl fbm)
	biome_noise = FastNoiseLite.new()
	biome_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	biome_noise.frequency = 0.002  # Match GPU biome scale
	biome_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	biome_noise.fractal_octaves = 3
	
	# Connect to terrain chunk_generated signal
	if not terrain_manager:
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	if terrain_manager and terrain_manager.has_signal("chunk_generated"):
		terrain_manager.chunk_generated.connect(_on_chunk_generated)
		print("[EntityManager] Connected to chunk_generated signal - procedural spawning active")
	else:
		push_warning("[EntityManager] Could not connect to terrain - procedural spawning disabled")
		procedural_spawning_enabled = false

## Called when a terrain chunk is generated
func _on_chunk_generated(coord: Vector3i, _chunk_node: Node3D):
	if not procedural_spawning_enabled:
		return
	
	# Only spawn on surface chunks (Y=0)
	if coord.y != 0:
		return
	
	var chunk_key = Vector2i(coord.x, coord.z)
	
	# Skip if already processed this chunk
	if spawned_chunks.has(chunk_key):
		return
	
	# Mark chunk as processed immediately (signal only fires once)
	spawned_chunks[chunk_key] = true
	
	# DEBUG: Log every chunk we process
	print("[EntityManager] Processing chunk %s for spawns" % chunk_key)
	
	# Deterministic RNG based on chunk coordinate
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(chunk_key) + (terrain_manager.world_seed if "world_seed" in terrain_manager else 12345)
	
	# Roll spawn chance
	if rng.randf() > spawn_chance_per_chunk:
		return  # No spawn this chunk
	
	# Calculate chunk center for biome detection
	var chunk_center = Vector3(coord.x * 31.0 + 16.0, 0, coord.z * 31.0 + 16.0)  # CHUNK_STRIDE = 31
	
	# Determine biome at chunk center
	var biome_id = _get_biome_at(chunk_center.x, chunk_center.z)
	var rules = spawn_rules.get(biome_id, spawn_rules[0])  # Default to grass rules
	
	# Roll for zombie spawn based on biome
	var zombie_chance = rules.get("zombie_chance", 0.3)
	
	var spawns_this_chunk = 0
	for i in range(max_spawns_per_chunk):
		if spawns_this_chunk >= max_spawns_per_chunk:
			break
		
		if rng.randf() > zombie_chance:
			continue  # Failed this spawn roll
		
		# Random position within chunk
		var offset_x = rng.randf_range(2.0, 29.0)  # Avoid chunk edges
		var offset_z = rng.randf_range(2.0, 29.0)
		var spawn_x = coord.x * 31.0 + offset_x
		var spawn_z = coord.z * 31.0 + offset_z
		
		# Queue spawn (will be processed when terrain collision is ready)
		pending_spawns.append({
			"position": Vector3(spawn_x, 0, spawn_z),
			"scene": zombie_scene,
			"procedural": true,  # Mark as procedurally spawned
			"chunk_key": chunk_key
		})
		spawns_this_chunk += 1
	
	if spawns_this_chunk > 0:
		print("[EntityManager] Queued %d zombie(s) in chunk %s (biome %d)" % [spawns_this_chunk, chunk_key, biome_id])

## Get biome ID at world position (must match gen_density.glsl)
func _get_biome_at(world_x: float, world_z: float) -> int:
	if not biome_noise:
		return 0  # Default grass
	
	# FBM noise value (matches GPU fbm function)
	var val = biome_noise.get_noise_2d(world_x, world_z)
	
	# Same thresholds as gen_density.glsl
	if val < -0.2:
		return 3  # Sand biome
	if val > 0.6:
		return 5  # Snow biome
	if val > 0.2:
		return 4  # Gravel biome
	return 0  # Grass (default)

## Clear spawned chunks tracking (called on new game)
func clear_spawned_chunks():
	spawned_chunks.clear()
	print("[EntityManager] Cleared spawned chunks tracking")


