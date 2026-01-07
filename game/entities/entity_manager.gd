extends Node3D
## Entity Manager - handles spawning, tracking, and despawning of entities
## Uses distance-based zones: Active -> Frozen -> Despawn

signal entity_spawned(entity: Node3D)
signal entity_despawned(entity: Node3D)

# Debug signals - connect from external observer for debugging
signal debug_load_started()
signal debug_entities_cleared(killed_count: int)
signal debug_entities_loaded(loaded_count: int, active_total: int)
signal debug_chunk_spawn_blocked(chunk: Vector2i, reason: String)
signal debug_chunk_spawn_processed(chunk: Vector2i)
signal debug_load_complete(zombies_in_group: int, active_entities: int)

@export var terrain_manager: Node3D # Reference to ChunkManager for terrain interaction
@export var max_entities: int = 50 # Maximum number of active entities
@export var spawn_radius: float = 50.0 # Range around player where entities can spawn
@export var freeze_radius: float = 60.0 # Distance at which entities freeze (physics disabled)
@export var despawn_radius: float = 100.0 # Distance at which entities are removed

# Procedural spawning settings
@export var procedural_spawning_enabled: bool = true
@export var spawn_chance_per_chunk: float = 0.50 # 50% chance per surface chunk
@export var min_spawn_distance_from_player: float = 40.0 # Don't spawn too close
@export var max_spawns_per_chunk: int = 3

# Entity scene to spawn (can be overridden per entity type)
@export var default_entity_scene: PackedScene

var player: Node3D
var viewer: Node3D  # What to track for spawning (player or vehicle)
var active_entities: Array[Node3D] = []
var frozen_entities: Dictionary = {} # entity -> { position: Vector3 }
var dormant_entities: Array = [] # Stored entities: { position, scene_path, health, state }
var entity_pool: Array[Node3D] = [] # Pooled inactive entities

# Deferred spawning - wait for terrain to load
var pending_spawns: Array = []

# Procedural spawning tracking
var spawned_chunks: Dictionary = {} # Vector2i -> true (tracks which chunks already spawned entities)
var zombie_scene: PackedScene = null # Cached zombie scene
var biome_noise: FastNoiseLite = null # For biome detection (must match GPU)
var is_loading_save: bool = false # Flag to disable procedural spawning during save load

# Biome-based spawn rules: biome_id -> { "zombie_chance": float }
# Biome IDs: 0=Grass, 3=Sand, 4=Gravel, 5=Snow
var spawn_rules = {
	0: {"zombie_chance": 0.6}, # Grass - moderate danger
	3: {"zombie_chance": 0.3}, # Sand - peaceful desert
	4: {"zombie_chance": 0.9}, # Gravel - high danger ruins
	5: {"zombie_chance": 0.5}, # Snow - cold hostile
}

func _ready():
	# Register in group for lookup by other systems
	add_to_group("entity_manager")
	
	# Keep running even when player is disabled (e.g., in vehicle)
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	# Find player
	player = get_tree().get_first_node_in_group("player")
	viewer = player  # Default viewer is the player
	if not player:
		push_warning("EntityManager: Player not found in 'player' group!")
	
	# CRITICAL FIX: Check if we're in the middle of a QuickLoad
	# If so, skip procedural spawning - load_save_data will handle entities
	var save_manager = get_node_or_null("/root/SaveManager")
	if save_manager and save_manager.get("is_quickloading"):
		DebugManager.log_entities("QuickLoad detected - skipping procedural spawning setup")
		is_loading_save = true  # Also block procedural spawns via the flag
		return
	
	# Setup procedural spawning
	_setup_procedural_spawning()

func _physics_process(_delta):
	if not player:
		player = get_tree().get_first_node_in_group("player")
		viewer = player
		if not player:
			return
	
	# Use viewer for position tracking (player or vehicle)
	if not viewer or not is_instance_valid(viewer):
		viewer = player
	
	PerformanceMonitor.start_measure("Entity Proximity")
	_update_entity_proximity()
	PerformanceMonitor.end_measure("Entity Proximity", 2.0)
	
	PerformanceMonitor.start_measure("Entity Dormant Check")
	_check_dormant_respawns()
	PerformanceMonitor.end_measure("Entity Dormant Check", 2.0)
	
	# Process spawn queue - spawns when terrain is ready
	if not pending_spawns.is_empty():
		PerformanceMonitor.start_measure("Entity Spawn Queue")
		_process_spawn_queue()
		PerformanceMonitor.end_measure("Entity Spawn Queue", 3.0)

## Manage entity states based on distance: Active -> Frozen -> Despawn
func _update_entity_proximity():
	var player_pos = viewer.global_position if viewer else player.global_position
	var freeze_dist_sq = freeze_radius * freeze_radius
	var despawn_dist_sq = despawn_radius * despawn_radius
	
	var to_despawn: Array[Node3D] = []
	var invalid_entities: Array = [] # Track indices of invalid entities for cleanup
	
	for i in range(active_entities.size()):
		var entity = active_entities[i]
		if not is_instance_valid(entity):
			invalid_entities.append(i)
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
	
	# Clean up invalid entities from tracking (reverse order to preserve indices)
	for i in range(invalid_entities.size() - 1, -1, -1):
		active_entities.remove_at(invalid_entities[i])
	
	# Despawn far entities
	for entity in to_despawn:
		despawn_entity(entity)

## Freeze an entity - disable physics to prevent falling
func _freeze_entity(entity: Node3D):
	if frozen_entities.has(entity):
		return # Already frozen
	
	# Store current state
	frozen_entities[entity] = {
		"position": entity.global_position
	}
	
	# Disable physics processing
	entity.set_physics_process(false)
	
	# Zero velocity if CharacterBody3D
	if entity is CharacterBody3D:
		entity.velocity = Vector3.ZERO
	
	DebugManager.log_entities("Frozen entity at distance")

## Unfreeze an entity - re-enable physics
func _unfreeze_entity(entity: Node3D):
	if not frozen_entities.has(entity):
		return # Not frozen
	
	if not player:
		return # No player reference
	
	var pos = entity.global_position
	
	# Check if within collision range (where terrain collision is enabled)
	var dist_to_player = Vector2(pos.x, pos.z).distance_to(Vector2(player.global_position.x, player.global_position.z))
	var collision_range = 93.0 # 3 chunks * 31 stride
	if terrain_manager and "collision_distance" in terrain_manager:
		collision_range = terrain_manager.collision_distance * 31.0
	
	if dist_to_player > collision_range:
		# Outside collision range - stay frozen to prevent falling through
		return
	
	# Use RAYCAST to verify terrain collision is actually active (not just mesh loaded)
	var space_state = get_world_3d().direct_space_state
	var ray_from = Vector3(pos.x, pos.y + 10.0, pos.z) # Start above entity
	var ray_to = Vector3(pos.x, pos.y - 50.0, pos.z) # Cast down
	
	var query = PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	query.collision_mask = 1 # Only terrain layer
	query.exclude = [entity] # Don't hit self
	var result = space_state.intersect_ray(query)
	
	if result.is_empty():
		# No terrain collision detected - stay frozen
		return
	
	# Collision verified! Re-enable physics
	entity.set_physics_process(true)
	frozen_entities.erase(entity)
	
	# Restart animation by re-triggering current state (fixes stuck pose after freeze)
	if entity.has_method("change_state") and "current_state" in entity:
		var current = entity.current_state
		# Force state change by temporarily clearing, then restoring
		entity.current_state = ""
		entity.change_state(current)
	
	DebugManager.log_entities("Unfrozen entity - terrain ready")

## Check if any dormant entities should be respawned (player returned to their area)
func _check_dormant_respawns():
	if dormant_entities.is_empty() or not viewer:
		return
	
	var player_pos = viewer.global_position
	var completed: Array[int] = []
	
	for i in range(dormant_entities.size()):
		var data = dormant_entities[i]
		var pos = data.position
		
		# Check distance to player
		var dist = Vector2(pos.x, pos.z).distance_to(Vector2(player_pos.x, player_pos.z))
		
		# Must be within spawn radius
		if dist > spawn_radius:
			continue # Still too far
		
		# Must be within collision range (where collision is actually enabled)
		var collision_range = 93.0 # 3 chunks * 31 stride
		if terrain_manager and "collision_distance" in terrain_manager:
			collision_range = terrain_manager.collision_distance * 31.0
		
		if dist > collision_range:
			continue # Collision disabled at this location, wait
		
		# Use RAYCAST to check if terrain collision is ready - spawn immediately when hit
		var space_state = get_world_3d().direct_space_state
		var ray_from = Vector3(pos.x, 200.0, pos.z)
		var ray_to = Vector3(pos.x, -50.0, pos.z)
		
		var query = PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		query.collision_mask = 1 # Only terrain layer
		var result = space_state.intersect_ray(query)
		
		if result.is_empty():
			continue # Terrain collision not ready yet, try next frame
		
		# Terrain found! Spawn immediately at exact collision point
		var terrain_y = result.position.y
		var scene_path = data.scene_path
		if scene_path != "":
			var scene = load(scene_path)
			if scene:
				var respawn_pos = Vector3(pos.x, terrain_y + 1.5, pos.z)
				var entity = spawn_entity(respawn_pos, scene)
				if entity:
					# Restore state
					if data.health > 0 and "current_health" in entity:
						entity.current_health = data.health
					DebugManager.log_entities("Respawned dormant entity at %s (terrain_y=%.1f)" % [respawn_pos, terrain_y])
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
	
	# CRITICAL: Spawn frozen by default to prevent falling through unloaded collision
	# The _update_entity_proximity loop will unfreeze when collision is verified via raycast
	entity.set_physics_process(false)
	if entity is CharacterBody3D:
		entity.velocity = Vector3.ZERO
	frozen_entities[entity] = {"position": world_pos}
	
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
		DebugManager.log_entities("Entity stored for respawn at %s" % entity_data.position)
	
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
	if not viewer:
		return null
	
	var player_pos = viewer.global_position
	
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

## Process spawn queue - spawns entities immediately when terrain collision is ready via raycast
## Event-driven: no hardcoded delays, spawn as soon as raycast hits terrain
func _process_spawn_queue():
	if pending_spawns.is_empty() or not viewer:
		return
	
	var completed: Array[int] = []
	var current_time = Time.get_ticks_msec() / 1000.0
	
	for i in range(pending_spawns.size()):
		var spawn_data = pending_spawns[i]
		var pos = spawn_data.position
		
		# Check if spawn point is within collision range of player
		# Collision is only enabled within collision_distance chunks (~93 units for distance=3)
		# Spawning outside this range = zombie falls through disabled collision
		var player_pos = viewer.global_position
		var dist_to_player = Vector2(pos.x, pos.z).distance_to(Vector2(player_pos.x, player_pos.z))
		
		# Get collision distance from terrain manager (default ~93 units = 3 chunks * 31)
		var collision_range = 93.0 # 3 chunks * 31 stride
		if terrain_manager and "collision_distance" in terrain_manager:
			collision_range = terrain_manager.collision_distance * 31.0
		
		# Only spawn if within collision range (where collision is actually enabled)
		if dist_to_player > collision_range:
			# Too far from player - collision disabled there, wait until player gets closer
			continue
		
		# Also check despawn radius for non-procedural spawns
		var is_procedural = spawn_data.get("procedural", false)
		if not is_procedural:
			if dist_to_player > despawn_radius:
				completed.append(i)
				continue
		
		# Use RAYCAST to check if terrain collision is ready - spawn immediately when hit
		var space_state = get_world_3d().direct_space_state
		var ray_from = Vector3(pos.x, 200.0, pos.z) # Start high above terrain
		var ray_to = Vector3(pos.x, -50.0, pos.z) # End below expected terrain
		
		var query = PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		query.collision_mask = 1 # Only terrain layer
		var result = space_state.intersect_ray(query)
		
		if result.is_empty():
			# No collision found - terrain not ready yet, keep waiting
			if not spawn_data.has("wait_start"):
				spawn_data["wait_start"] = current_time
			elif current_time - spawn_data.wait_start > 10.0:
				# Waited too long (10s), give up on this spawn
				DebugManager.log_entities("Spawn timeout at (%.0f, %.0f) - no collision found" % [pos.x, pos.z])
				completed.append(i)
			continue
		
		# Terrain found! Verify it's actually terrain (in "terrain" group)
		var hit_collider = result.collider
		var terrain_y = result.position.y
		
		# DEBUG: Log what we hit
		var collider_name = hit_collider.name if hit_collider else "null"
		var collider_groups = hit_collider.get_groups() if hit_collider else []
		DebugManager.log_entities("Raycast hit: %s at Y=%.1f, groups=%s" % [collider_name, terrain_y, collider_groups])
		
		# Only spawn if we hit actual terrain
		if hit_collider and hit_collider.is_in_group("terrain"):
			var spawn_pos = Vector3(pos.x, terrain_y + 1.5, pos.z)
			var entity = spawn_entity(spawn_pos, spawn_data.scene)
			if entity:
				DebugManager.log_entities("Spawned entity at %s (terrain_y=%.1f)" % [spawn_pos, terrain_y])
			completed.append(i)
		else:
			# Hit something that's not terrain - keep waiting for actual terrain
			DebugManager.log_entities("Hit non-terrain collider '%s', waiting for terrain..." % collider_name)
			# Don't mark as completed - keep trying
	
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
		
		# Skip dead entities - they're pending deletion and shouldn't be saved
		if "current_state" in entity and entity.current_state == "DEAD":
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
	# Disable procedural spawning during load to prevent duplicates
	is_loading_save = true
	
	# CRITICAL FIX: Clear any pending procedural spawns queued during scene load
	# These were queued BEFORE is_loading_save was set, so they would duplicate!
	pending_spawns.clear()
	
	# CRITICAL FIX: Clear dormant entities - these get populated by despawn_all()
	# and would be respawned by _check_dormant_respawns(), duplicating saved zombies!
	dormant_entities.clear()
	
	# NUCLEAR OPTION: Kill ALL zombies by group, not just those in active_entities
	# This catches any zombies that spawned via pending_spawns or other paths
	# IMPORTANT: Use free() not queue_free() for IMMEDIATE removal
	var zombies_killed = 0
	for zombie in get_tree().get_nodes_in_group("zombies").duplicate():  # duplicate to avoid modifying during iteration
		if is_instance_valid(zombie):
			zombie.free()  # Immediate deletion, not deferred
			zombies_killed += 1
	debug_entities_cleared.emit(zombies_killed)
	
	# Clear tracking arrays since we already freed the entities
	active_entities.clear()
	frozen_entities.clear()
	
	# Restore spawned_chunks tracking to prevent duplicate procedural spawns
	spawned_chunks.clear()
	if data.has("spawned_chunks"):
		for chunk_arr in data.spawned_chunks:
			if chunk_arr.size() >= 2:
				spawned_chunks[Vector2i(int(chunk_arr[0]), int(chunk_arr[1]))] = true
		DebugManager.log_entities("Restored %d spawned chunk records" % spawned_chunks.size())
	
	if not data.has("entities"):
		debug_entities_loaded.emit(0, 0)
		call_deferred("_finish_load")
		return
	
	debug_load_started.emit()
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
	
	debug_entities_loaded.emit(data.entities.size(), active_entities.size())
	DebugManager.log_entities("Loaded %d entities" % data.entities.size())
	
	# Re-enable procedural spawning after load completes
	call_deferred("_finish_load")

## Called after load completes to re-enable procedural spawning
func _finish_load():
	var zombies_in_group = get_tree().get_nodes_in_group("zombies").size()
	debug_load_complete.emit(zombies_in_group, active_entities.size())
	is_loading_save = false
	# Setup procedural spawning now (we skipped it in _ready during QuickLoad)
	if procedural_spawning_enabled and zombie_scene == null:
		_setup_procedural_spawning()
	DebugManager.log_entities("Entity load complete - procedural spawning re-enabled")

# ============ PROCEDURAL SPAWNING ============

## Setup procedural spawning - connect to terrain signals
func _setup_procedural_spawning():
	if not procedural_spawning_enabled:
		return
	
	# Load zombie scene for procedural spawning
	if ResourceLoader.exists("res://game/entities/zombie_base.tscn"):
		zombie_scene = load("res://game/entities/zombie_base.tscn")
		DebugManager.log_entities("Loaded zombie scene for procedural spawning")
	else:
		push_warning("[EntityManager] Zombie scene not found - procedural spawning disabled")
		procedural_spawning_enabled = false
		return
	
	# Setup biome noise (must match gen_density.glsl fbm)
	biome_noise = FastNoiseLite.new()
	biome_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	biome_noise.frequency = 0.002 # Match GPU biome scale
	biome_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	biome_noise.fractal_octaves = 3
	
	# Connect to terrain chunk_generated signal
	if not terrain_manager:
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	if terrain_manager and terrain_manager.has_signal("chunk_generated"):
		# CRITICAL FIX: Check if already connected to prevent duplicate connections during QuickLoad
		# Without this check, scene reload creates duplicate connections = zombies spawn twice!
		if not terrain_manager.chunk_generated.is_connected(_on_chunk_generated):
			terrain_manager.chunk_generated.connect(_on_chunk_generated)
			DebugManager.log_entities("Connected to chunk_generated signal - procedural spawning active")
		else:
			DebugManager.log_entities("Already connected to chunk_generated - skipping duplicate")
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
	
	# CRITICAL: Mark chunk as processed FIRST, before is_loading_save check
	# This prevents duplicate spawning after load completes
	spawned_chunks[chunk_key] = true
	
	# Skip procedural spawning if currently loading a save (but chunk is still marked)
	if is_loading_save:
		debug_chunk_spawn_blocked.emit(chunk_key, "loading_save")
		return
	
	debug_chunk_spawn_processed.emit(chunk_key)
	DebugManager.log_entities("Processing chunk %s for spawns" % chunk_key)
	
	# Deterministic RNG based on chunk coordinate
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(chunk_key) + (terrain_manager.world_seed if "world_seed" in terrain_manager else 12345)
	
	# Roll spawn chance
	if rng.randf() > spawn_chance_per_chunk:
		return # No spawn this chunk
	
	# Calculate chunk center for biome detection
	var chunk_center = Vector3(coord.x * 31.0 + 16.0, 0, coord.z * 31.0 + 16.0) # CHUNK_STRIDE = 31
	
	# Determine biome at chunk center
	var biome_id = _get_biome_at(chunk_center.x, chunk_center.z)
	var rules = spawn_rules.get(biome_id, spawn_rules[0]) # Default to grass rules
	
	# Roll for zombie spawn based on biome
	var zombie_chance = rules.get("zombie_chance", 0.3)
	
	var spawns_this_chunk = 0
	for i in range(max_spawns_per_chunk):
		if spawns_this_chunk >= max_spawns_per_chunk:
			break
		
		if rng.randf() > zombie_chance:
			continue # Failed this spawn roll
		
		# Random position within chunk
		var offset_x = rng.randf_range(2.0, 29.0) # Avoid chunk edges
		var offset_z = rng.randf_range(2.0, 29.0)
		var spawn_x = coord.x * 31.0 + offset_x
		var spawn_z = coord.z * 31.0 + offset_z
		
		# Queue spawn (will be processed when terrain collision is ready)
		pending_spawns.append({
			"position": Vector3(spawn_x, 0, spawn_z),
			"scene": zombie_scene,
			"procedural": true, # Mark as procedurally spawned
			"chunk_key": chunk_key
		})
		spawns_this_chunk += 1
	
	if spawns_this_chunk > 0:
		DebugManager.log_entities("Queued %d zombie(s) in chunk %s (biome %d)" % [spawns_this_chunk, chunk_key, biome_id])

## Get biome ID at world position (must match gen_density.glsl)
func _get_biome_at(world_x: float, world_z: float) -> int:
	if not biome_noise:
		return 0 # Default grass
	
	# FBM noise value (matches GPU fbm function)
	var val = biome_noise.get_noise_2d(world_x, world_z)
	
	# Same thresholds as gen_density.glsl
	if val < -0.2:
		return 3 # Sand biome
	if val > 0.6:
		return 5 # Snow biome
	if val > 0.2:
		return 4 # Gravel biome
	return 0 # Grass (default)

## Clear spawned chunks tracking (called on new game)
func clear_spawned_chunks():
	spawned_chunks.clear()
	DebugManager.log_entities("Cleared spawned chunks tracking")
