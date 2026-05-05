extends Node3D
## Entity Manager - handles spawning, tracking, and despawning of entities
## Uses distance-based zones: Active -> Frozen -> Despawn

const RenderResourcePrewarm = preload("res://world_render_prewarm/render_resource_prewarm.gd")
const ZOMBIE_SCENE_PATH := "res://game/entities/zombie_base.tscn"
const TERRAIN_CHUNK_STRIDE := 31.0

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
@export var active_physics_radius: float = 55.0 # Entities outside this range stay frozen until they matter
@export var freeze_radius: float = 60.0 # Fallback freeze distance when terrain collision range is unavailable
@export var despawn_radius: float = 100.0 # Distance at which entities are removed
@export_range(0.0, 31.0, 0.5) var freeze_collision_margin: float = 8.0 # Keep entities active until near the collision-ready edge
@export_range(0.1, 5.0, 0.1) var proximity_update_budget_ms: float = 0.8
@export_range(1, 256, 1) var pending_spawn_checks_per_frame: int = 16
@export_range(1, 256, 1) var dormant_respawn_checks_per_frame: int = 16
@export_range(0.1, 5.0, 0.1) var spawn_queue_budget_ms: float = 0.5
@export_range(0.1, 5.0, 0.1) var dormant_respawn_budget_ms: float = 0.5
@export_range(0.5, 8.0, 0.5) var entity_maintenance_budget_ms: float = 1.5
@export_range(0.0, 1.0, 0.01) var proximity_update_interval: float = 0.10
@export_range(0.0, 1.0, 0.01) var spawn_queue_update_interval: float = 0.10
@export_range(0.0, 1.0, 0.01) var dormant_respawn_update_interval: float = 0.25
@export_range(0, 60, 1) var entity_render_prewarm_frames: int = 12
@export_range(1, 128, 1) var deferred_spawn_chunks_per_frame: int = 32

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
var _scene_cache: Dictionary = {} # scene_path -> PackedScene
var _proximity_scan_cursor: int = 0
var _pending_spawn_scan_cursor: int = 0
var _dormant_scan_cursor: int = 0
var _proximity_update_accumulator: float = 0.0
var _spawn_queue_update_accumulator: float = 0.0
var _dormant_respawn_update_accumulator: float = 0.0
var _last_proximity_update_ms: float = 0.0
var _last_proximity_processed: int = 0
var _last_spawn_queue_update_ms: float = 0.0
var _last_spawn_queue_processed: int = 0
var _last_spawn_queue_raycasts: int = 0
var _last_spawn_queue_spawned: int = 0
var _last_dormant_respawn_update_ms: float = 0.0
var _last_dormant_respawn_processed: int = 0
var _last_dormant_respawn_raycasts: int = 0
var _last_dormant_respawn_spawned: int = 0
var _deferred_spawn_chunk_cursor: int = 0
var _entity_render_resource_prewarm_node: Node = null
var _entity_render_resource_prewarm_mesh_count: int = 0
var _entity_render_resource_prewarm_started: bool = false

# Deferred spawning - wait for terrain to load
var pending_spawns: Array = []
var deferred_spawn_chunks: Dictionary = {} # Vector2i -> { coord: Vector3i, spawns: Array[Dictionary] }
var deferred_spawn_chunk_keys: Array[Vector2i] = [] # Stable ring queue to avoid copying Dictionary.keys() each update

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


func _reset_frame_entity_stats() -> void:
	return


func _bump_frame_entity_stat(key: String, amount: int = 1) -> void:
	return


func _capture_entity_telemetry() -> void:
	return


func get_telemetry_snapshot() -> Dictionary:
	return {
		"active_entities": active_entities.size(),
		"frozen_entities": frozen_entities.size(),
		"dormant_entities": dormant_entities.size(),
		"entity_pool_size": entity_pool.size(),
		"pending_spawns": pending_spawns.size(),
		"deferred_spawn_chunks": deferred_spawn_chunks.size(),
		"deferred_spawn_chunk_keys": deferred_spawn_chunk_keys.size(),
		"deferred_spawn_plans": _get_deferred_spawn_plan_count(),
		"spawned_chunks": spawned_chunks.size(),
		"max_entities": max_entities,
		"spawn_radius": spawn_radius,
		"active_physics_radius": active_physics_radius,
		"freeze_radius": freeze_radius,
		"despawn_radius": despawn_radius,
		"procedural_spawning_enabled": procedural_spawning_enabled,
		"is_loading_save": is_loading_save,
		"pending_spawn_checks_per_frame": pending_spawn_checks_per_frame,
		"dormant_respawn_checks_per_frame": dormant_respawn_checks_per_frame,
		"proximity_update_budget_ms": proximity_update_budget_ms,
		"proximity_update_interval": proximity_update_interval,
		"spawn_queue_update_interval": spawn_queue_update_interval,
		"dormant_respawn_update_interval": dormant_respawn_update_interval,
		"last_proximity_update_ms": _last_proximity_update_ms,
		"last_proximity_processed": _last_proximity_processed,
		"last_spawn_queue_update_ms": _last_spawn_queue_update_ms,
		"last_spawn_queue_processed": _last_spawn_queue_processed,
		"last_spawn_queue_raycasts": _last_spawn_queue_raycasts,
		"last_spawn_queue_spawned": _last_spawn_queue_spawned,
		"last_dormant_respawn_update_ms": _last_dormant_respawn_update_ms,
		"last_dormant_respawn_processed": _last_dormant_respawn_processed,
		"last_dormant_respawn_raycasts": _last_dormant_respawn_raycasts,
		"last_dormant_respawn_spawned": _last_dormant_respawn_spawned,
		"entity_render_prewarm_frames": entity_render_prewarm_frames,
		"entity_render_prewarm_mesh_count": _entity_render_resource_prewarm_mesh_count,
		"entity_render_prewarm_active": _is_entity_render_resource_prewarm_active(),
		"entity_render_prewarm_frames_remaining": _get_entity_render_resource_prewarm_frames_remaining(),
		"viewer_present": is_instance_valid(viewer),
		"player_present": is_instance_valid(player)
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

	_cache_procedural_entity_scenes()
	_start_entity_render_resource_prewarm()
	
	# CRITICAL FIX: Check if we're in the middle of a QuickLoad
	# If so, skip procedural spawning - load_save_data will handle entities
	var save_manager = get_node_or_null("/root/SaveManager")
	if save_manager and save_manager.get("is_quickloading"):
		is_loading_save = true  # Also block procedural spawns via the flag
		return
	
	# Setup procedural spawning
	_setup_procedural_spawning()
	_start_entity_render_resource_prewarm()

func _physics_process(_delta):
	if not player:
		player = get_tree().get_first_node_in_group("player")
		viewer = player
		if not player:
			return
	
	# Use viewer for position tracking (player or vehicle)
	if not viewer or not is_instance_valid(viewer):
		viewer = player

	var entity_maintenance_start_us := Time.get_ticks_usec()
	var entity_maintenance_budget_hit := false

	var has_active_entities := not active_entities.is_empty()
	_proximity_update_accumulator += _delta
	if _should_run_interval(_proximity_update_accumulator, proximity_update_interval, has_active_entities):
		_proximity_update_accumulator = 0.0
		_update_entity_proximity()
		entity_maintenance_budget_hit = _is_entity_maintenance_budget_exhausted(entity_maintenance_start_us)
	elif not has_active_entities:
		_last_proximity_update_ms = 0.0
		_last_proximity_processed = 0

	# Process spawn queue - spawns when terrain is ready
	var has_pending_spawns := not pending_spawns.is_empty() or not deferred_spawn_chunks.is_empty()
	_spawn_queue_update_accumulator += _delta
	if not entity_maintenance_budget_hit and _should_run_interval(_spawn_queue_update_accumulator, spawn_queue_update_interval, has_pending_spawns):
		_spawn_queue_update_accumulator = 0.0
		_process_deferred_spawn_chunks()
		_process_spawn_queue()
		entity_maintenance_budget_hit = _is_entity_maintenance_budget_exhausted(entity_maintenance_start_us)
	elif not has_pending_spawns:
		_last_spawn_queue_update_ms = 0.0
		_last_spawn_queue_processed = 0
		_last_spawn_queue_raycasts = 0
		_last_spawn_queue_spawned = 0

	var has_dormant_entities := not dormant_entities.is_empty()
	_dormant_respawn_update_accumulator += _delta
	if not entity_maintenance_budget_hit and _should_run_interval(_dormant_respawn_update_accumulator, dormant_respawn_update_interval, has_dormant_entities):
		_dormant_respawn_update_accumulator = 0.0
		_check_dormant_respawns()
		entity_maintenance_budget_hit = _is_entity_maintenance_budget_exhausted(entity_maintenance_start_us)
	elif not has_dormant_entities:
		_last_dormant_respawn_update_ms = 0.0
		_last_dormant_respawn_processed = 0
		_last_dormant_respawn_raycasts = 0
		_last_dormant_respawn_spawned = 0


func _should_run_interval(elapsed: float, interval: float, has_work: bool) -> bool:
	if not has_work:
		return false
	return interval <= 0.0 or elapsed >= interval


func _is_entity_maintenance_budget_exhausted(start_time_us: int) -> bool:
	if entity_maintenance_budget_ms <= 0.0:
		return false
	return float(Time.get_ticks_usec() - start_time_us) / 1000.0 >= entity_maintenance_budget_ms

## Manage entity states based on distance: Active -> Frozen -> Despawn
func _update_entity_proximity():
	var start_time := Time.get_ticks_usec()
	var player_pos = viewer.global_position if viewer else player.global_position
	var freeze_dist_sq = _get_effective_freeze_radius_squared()
	var active_physics_dist_sq = _get_effective_active_physics_radius_squared(freeze_dist_sq)
	var despawn_dist_sq = despawn_radius * despawn_radius
	
	if active_entities.is_empty():
		_last_proximity_update_ms = 0.0
		_last_proximity_processed = 0
		return

	var total := active_entities.size()
	if total <= 0:
		return

	var start_index := _proximity_scan_cursor % total
	var processed := 0
	var to_despawn: Array[Node3D] = []
	var invalid_indices: Array[int] = []
	var collision_range_sq := _get_collision_range_squared()
	var space_state = get_world_3d().direct_space_state if not frozen_entities.is_empty() else null

	while processed < total:
		if processed > 0:
			var elapsed_ms := float(Time.get_ticks_usec() - start_time) / 1000.0
			if elapsed_ms >= proximity_update_budget_ms:
				break

		var idx := (start_index + processed) % total
		var entity = active_entities[idx]
		processed += 1

		if not is_instance_valid(entity):
			invalid_indices.append(idx)
			continue

		var dist_sq = _planar_distance_squared(entity.global_position, player_pos)

		if dist_sq > despawn_dist_sq:
			# Beyond despawn radius - remove entity
			to_despawn.append(entity)
		elif dist_sq > active_physics_dist_sq:
			# Keep mid-distance entities present but asleep. This prevents town
			# entry from simulating every spawned zombie at once.
			_freeze_entity(entity)
		elif not is_loading_save:
			# In active zone - ensure physics enabled (ONLY if not loading)
			_unfreeze_entity(entity, collision_range_sq, space_state)

	_proximity_scan_cursor = (start_index + processed) % total
	_bump_frame_entity_stat("proximity_processed", processed)
	_bump_frame_entity_stat("proximity_invalid", invalid_indices.size())
	_bump_frame_entity_stat("proximity_despawned", to_despawn.size())
	_last_proximity_processed = processed
	_last_proximity_update_ms = float(Time.get_ticks_usec() - start_time) / 1000.0

	for i in range(invalid_indices.size() - 1, -1, -1):
		active_entities.remove_at(invalid_indices[i])

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
	if entity.has_method("on_frozen"):
		entity.on_frozen()
	
	# Zero velocity if CharacterBody3D
	if entity is CharacterBody3D:
		entity.velocity = Vector3.ZERO
	

## Unfreeze an entity - re-enable physics
func _unfreeze_entity(entity: Node3D, collision_range_sq: float, space_state):
	if is_loading_save:
		return # Block unfreezing while world is still loading
		
	if not frozen_entities.has(entity):
		return # Not frozen
	
	if not player:
		return # No player reference
	
	var pos = entity.global_position
	_bump_frame_entity_stat("unfreeze_attempts")
	
	# Check if within collision range (where terrain collision is enabled)
	var dist_to_player_sq = _planar_distance_squared(pos, player.global_position)
	if dist_to_player_sq > collision_range_sq:
		# Outside collision range - stay frozen to prevent falling through
		return

	if not _is_terrain_collision_ready(pos):
		return
	
	# Use RAYCAST to verify terrain collision is actually active (not just mesh loaded)
	var ray_from = Vector3(pos.x, pos.y + 10.0, pos.z) # Start above entity
	var ray_to = Vector3(pos.x, pos.y - 50.0, pos.z) # Cast down
	
	var query = PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	query.collision_mask = 1 # Only terrain layer
	query.exclude = [entity] # Don't hit self
	_bump_frame_entity_stat("unfreeze_raycasts")
	var result = space_state.intersect_ray(query)
	
	if result.is_empty():
		# No terrain collision detected - stay frozen
		return
	
	# Collision verified! Re-enable physics
	entity.set_physics_process(true)
	frozen_entities.erase(entity)
	if entity.has_method("on_unfrozen"):
		entity.on_unfrozen()
	
	# Restart animation by re-triggering current state (fixes stuck pose after freeze)
	if entity.has_method("change_state") and "current_state" in entity:
		var current = entity.current_state
		# Force state change by temporarily clearing, then restoring
		entity.current_state = ""
		entity.change_state(current)
	

## Check if any dormant entities should be respawned (player returned to their area)
func _check_dormant_respawns():
	var start_time := Time.get_ticks_usec()
	_last_dormant_respawn_processed = 0
	_last_dormant_respawn_raycasts = 0
	_last_dormant_respawn_spawned = 0
	if dormant_entities.is_empty() or not viewer:
		_last_dormant_respawn_update_ms = 0.0
		return
	
	var player_pos = viewer.global_position
	var completed: Array[int] = []
	var collision_range_sq := _get_collision_range_squared()
	var space_state = get_world_3d().direct_space_state
	var total := dormant_entities.size()
	var checks := mini(dormant_respawn_checks_per_frame, total)
	var start_index := _dormant_scan_cursor % total
	var processed := 0
	
	while processed < checks:
		if processed > 0:
			var elapsed_ms := float(Time.get_ticks_usec() - start_time) / 1000.0
			if elapsed_ms >= dormant_respawn_budget_ms:
				break

		var i := (start_index + processed) % total
		var data = dormant_entities[i]
		var pos = data.position
		_bump_frame_entity_stat("dormant_candidates")
		processed += 1
		
		# Check distance to player
		var dist_sq = _planar_distance_squared(pos, player_pos)
		
		# Must be within spawn radius
		if dist_sq > spawn_radius * spawn_radius:
			continue # Still too far
		
		# Must be within collision range (where collision is actually enabled)
		if dist_sq > collision_range_sq:
			continue # Collision disabled at this location, wait

		if not _is_terrain_collision_ready(pos):
			continue
		
		# Use RAYCAST to check if terrain collision is ready - spawn immediately when hit
		var ray_from = Vector3(pos.x, 200.0, pos.z)
		var ray_to = Vector3(pos.x, -50.0, pos.z)
		
		var query = PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		query.collision_mask = 1 # Only terrain layer
		_bump_frame_entity_stat("dormant_raycasts")
		_last_dormant_respawn_raycasts += 1
		var result = space_state.intersect_ray(query)
		
		if result.is_empty():
			continue # Terrain collision not ready yet, try next frame
		
		# Terrain found! Spawn immediately at exact collision point
		var terrain_y = result.position.y
		var scene_path = data.scene_path
		if scene_path != "":
			var scene = _get_cached_scene(scene_path)
			if scene:
				var respawn_pos = Vector3(pos.x, terrain_y + 1.5, pos.z)
				var entity = spawn_entity(respawn_pos, scene)
				if entity:
					# Restore state
					if data.health > 0 and "current_health" in entity:
						entity.current_health = data.health
					completed.append(i)
					_bump_frame_entity_stat("dormant_respawns")
					_last_dormant_respawn_spawned += 1

	_dormant_scan_cursor = (start_index + processed) % max(1, dormant_entities.size())
	_last_dormant_respawn_processed = processed
	_last_dormant_respawn_update_ms = float(Time.get_ticks_usec() - start_time) / 1000.0
	completed.sort()

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
	var start_time := Time.get_ticks_usec()
	_last_spawn_queue_processed = 0
	_last_spawn_queue_raycasts = 0
	_last_spawn_queue_spawned = 0
	if pending_spawns.is_empty() or not viewer:
		_last_spawn_queue_update_ms = 0.0
		return
	
	var completed: Array[int] = []
	var current_time = Time.get_ticks_msec() / 1000.0
	var player_pos = viewer.global_position
	var collision_range_sq := _get_collision_range_squared()
	var space_state = get_world_3d().direct_space_state
	var total := pending_spawns.size()
	var checks := mini(pending_spawn_checks_per_frame, total)
	var start_index := _pending_spawn_scan_cursor % total
	var processed := 0
	
	while processed < checks:
		if processed > 0:
			var elapsed_ms := float(Time.get_ticks_usec() - start_time) / 1000.0
			if elapsed_ms >= spawn_queue_budget_ms:
				break

		var i := (start_index + processed) % total
		var spawn_data = pending_spawns[i]
		var pos = spawn_data.position
		_bump_frame_entity_stat("spawn_queue_candidates")
		processed += 1
		
		# Check if spawn point is within collision range of player
		# Collision is only enabled within collision_distance chunks (~93 units for distance=3)
		# Spawning outside this range = zombie falls through disabled collision
		var dist_to_player_sq = _planar_distance_squared(pos, player_pos)
		
		# Only spawn if within collision range (where collision is actually enabled)
		if dist_to_player_sq > collision_range_sq:
			# Too far from player - collision disabled there, wait until player gets closer
			continue
		
		# Also check despawn radius for non-procedural spawns
		var is_procedural = spawn_data.get("procedural", false)
		if not is_procedural:
			if dist_to_player_sq > despawn_radius * despawn_radius:
				completed.append(i)
				continue

		if not _is_terrain_collision_ready(pos):
			if not spawn_data.has("wait_start"):
				spawn_data["wait_start"] = current_time
			elif current_time - spawn_data.wait_start > 10.0:
				completed.append(i)
			continue
		
		# Use RAYCAST to check if terrain collision is ready - spawn immediately when hit
		var ray_from = Vector3(pos.x, 200.0, pos.z) # Start high above terrain
		var ray_to = Vector3(pos.x, -50.0, pos.z) # End below expected terrain
		
		var query = PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		query.collision_mask = 1 # Only terrain layer
		_bump_frame_entity_stat("spawn_queue_raycasts")
		_last_spawn_queue_raycasts += 1
		var result = space_state.intersect_ray(query)
		
		if result.is_empty():
			# No collision found - terrain not ready yet, keep waiting
			if not spawn_data.has("wait_start"):
				spawn_data["wait_start"] = current_time
			elif current_time - spawn_data.wait_start > 10.0:
				# Waited too long (10s), give up on this spawn
				completed.append(i)
			continue
		
		# Terrain found! Verify it's actually terrain (in "terrain" group)
		var hit_collider = result.collider
		var terrain_y = result.position.y
		
		# Only spawn if we hit actual terrain
		if hit_collider and hit_collider.is_in_group("terrain"):
			var spawn_pos = Vector3(pos.x, terrain_y + 1.5, pos.z)
			var entity = spawn_entity(spawn_pos, spawn_data.scene)
			if entity:
				_bump_frame_entity_stat("spawn_queue_spawns")
				_last_spawn_queue_spawned += 1
			completed.append(i)
		else:
			# Hit something that's not terrain - keep waiting for actual terrain
			# Don't mark as completed - keep trying
				pass

	_pending_spawn_scan_cursor = (start_index + processed) % max(1, pending_spawns.size())
	_last_spawn_queue_processed = processed
	_last_spawn_queue_update_ms = float(Time.get_ticks_usec() - start_time) / 1000.0
	completed.sort()
	
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
		
		# Store health if available
		if "current_health" in entity:
			entity_data["health"] = entity.current_health
		
		# Store AI state if available
		if "current_state" in entity:
			entity_data["state"] = entity.current_state
		
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
	
	# Serialize dormant entities (despawned due to distance but still alive)
	var dormant_data: Array = []
	for d in dormant_entities:
		var d_entry = {
			"position": [d.position.x, d.position.y, d.position.z],
			"scene_path": d.get("scene_path", ""),
			"health": d.get("health", -1),
			"state": d.get("state", "")
		}
		dormant_data.append(d_entry)
	
	return {
		"entities": entities_data,
		"spawned_chunks": chunks_data,
		"dormant_entities": dormant_data
	}

func clear_all_entities():
	# CRITICAL FIX: Clear any pending procedural spawns queued during scene load
	# These were queued BEFORE is_loading_save was set, so they would duplicate!
	pending_spawns.clear()
	_clear_deferred_spawn_chunks()
	_pending_spawn_scan_cursor = 0
	
	# CRITICAL FIX: Clear dormant entities - these get populated by despawn_all()
	# and would be respawned by _check_dormant_respawns(), duplicating saved zombies!
	dormant_entities.clear()
	_dormant_scan_cursor = 0
	
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

func load_save_data(data: Dictionary):
	# Disable procedural spawning during load to prevent duplicates
	is_loading_save = true
	
	# Perform immediate cleanup
	clear_all_entities()
	
	# Restore spawned_chunks tracking to prevent duplicate procedural spawns
	spawned_chunks.clear()
	if data.has("spawned_chunks"):
		for chunk_arr in data.spawned_chunks:
			if chunk_arr.size() >= 2:
				spawned_chunks[Vector2i(int(chunk_arr[0]), int(chunk_arr[1]))] = true
	
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
		if ent_data.has("scene_path"):
			var scene = _get_cached_scene(ent_data.scene_path)
			entity = spawn_entity(pos, scene)
		elif default_entity_scene:
			entity = spawn_entity(pos, default_entity_scene)
		
		if entity:
			entity.rotation.y = rotation_y
			
			# Restore health/state BEFORE first frame
			if ent_data.has("health") and "current_health" in entity:
				entity.current_health = ent_data.health
			
			if ent_data.has("state") and entity.has_method("change_state"):
				entity.change_state(ent_data.state)
			
			if ent_data.has("type"):
				entity.set_meta("entity_type", ent_data.type)
	
	debug_entities_loaded.emit(data.entities.size(), active_entities.size())
	
	# Restore dormant entities (despawned due to distance in previous session)
	if data.has("dormant_entities"):
		for d in data.dormant_entities:
			var pos = Vector3(d.position[0], d.position[1], d.position[2])
			dormant_entities.append({
				"position": pos,
				"scene_path": d.get("scene_path", ""),
				"health": d.get("health", -1),
				"state": d.get("state", "")
			})
	
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


func _get_cached_scene(scene_path: String) -> PackedScene:
	if scene_path.is_empty():
		return null
	if _scene_cache.has(scene_path):
		return _scene_cache[scene_path]
	if not ResourceLoader.exists(scene_path):
		_scene_cache[scene_path] = null
		return null

	var packed := load(scene_path) as PackedScene
	_scene_cache[scene_path] = packed
	return packed

func _cache_procedural_entity_scenes() -> void:
	if procedural_spawning_enabled and zombie_scene == null:
		zombie_scene = _get_cached_scene(ZOMBIE_SCENE_PATH)

func _start_entity_render_resource_prewarm() -> void:
	if entity_render_prewarm_frames <= 0 or _entity_render_resource_prewarm_started or _is_entity_render_resource_prewarm_active():
		return

	var mesh_entries := _collect_entity_render_resource_prewarm_entries()
	_entity_render_resource_prewarm_mesh_count = mesh_entries.size()
	if mesh_entries.is_empty():
		return

	var prewarmer: Node = RenderResourcePrewarm.new()
	prewarmer.name = "EntityRenderResourcePrewarm"
	add_child(prewarmer)
	_entity_render_resource_prewarm_node = prewarmer
	_entity_render_resource_prewarm_started = true
	prewarmer.configure([], entity_render_prewarm_frames, mesh_entries)

func _collect_entity_render_resource_prewarm_entries() -> Array:
	var entries: Array = []
	var unique_meshes: Array = []
	_append_entity_scene_render_prewarm_entries(entries, unique_meshes, default_entity_scene)
	_append_entity_scene_render_prewarm_entries(entries, unique_meshes, zombie_scene)
	return entries

func _append_entity_scene_render_prewarm_entries(entries: Array, unique_meshes: Array, scene: PackedScene) -> void:
	if not scene:
		return

	var instance := scene.instantiate()
	if not instance:
		return

	_append_entity_node_render_prewarm_entries(entries, unique_meshes, instance, Transform3D.IDENTITY)
	instance.free()

func _append_entity_node_render_prewarm_entries(entries: Array, unique_meshes: Array, node: Node, parent_transform: Transform3D) -> void:
	var node_transform := parent_transform
	if node is Node3D:
		var node_3d := node as Node3D
		node_transform = parent_transform * node_3d.transform

		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			_append_entity_mesh_render_prewarm_entry(entries, unique_meshes, mesh_instance.mesh, node_transform)
		elif node is MultiMeshInstance3D:
			var multimesh_instance := node as MultiMeshInstance3D
			if multimesh_instance.multimesh:
				_append_entity_mesh_render_prewarm_entry(entries, unique_meshes, multimesh_instance.multimesh.mesh, node_transform)

	for child in node.get_children():
		_append_entity_node_render_prewarm_entries(entries, unique_meshes, child, node_transform)

func _append_entity_mesh_render_prewarm_entry(entries: Array, unique_meshes: Array, mesh: Mesh, transform: Transform3D) -> void:
	if not mesh or unique_meshes.has(mesh):
		return

	unique_meshes.append(mesh)
	entries.append({
		"mesh": mesh,
		"transform": transform
	})

func _is_entity_render_resource_prewarm_active() -> bool:
	return _entity_render_resource_prewarm_node != null and is_instance_valid(_entity_render_resource_prewarm_node)

func _get_entity_render_resource_prewarm_frames_remaining() -> int:
	if not _is_entity_render_resource_prewarm_active():
		return 0
	if not _entity_render_resource_prewarm_node.has_method("get_frames_remaining"):
		return 0
	return int(_entity_render_resource_prewarm_node.get_frames_remaining())

# ============ PROCEDURAL SPAWNING ============

## Setup procedural spawning - connect to terrain signals
func _setup_procedural_spawning():
	if not procedural_spawning_enabled:
		return
	
	# Load zombie scene for procedural spawning
	zombie_scene = _get_cached_scene(ZOMBIE_SCENE_PATH)
	if not zombie_scene:
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
		else:
			pass
		if terrain_manager.has_signal("chunk_unloaded") and not terrain_manager.chunk_unloaded.is_connected(_on_chunk_unloaded):
			terrain_manager.chunk_unloaded.connect(_on_chunk_unloaded)
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
	if spawned_chunks.has(chunk_key) or deferred_spawn_chunks.has(chunk_key):
		return
	
	# Save loads still mark chunks as processed to prevent duplicate procedural
	# spawns after load completes. Normal runtime chunks may be deferred until
	# the player is close enough for collision-backed spawning.
	if is_loading_save:
		spawned_chunks[chunk_key] = true
		debug_chunk_spawn_blocked.emit(chunk_key, "loading_save")
		return

	_process_procedural_spawn_chunk(coord, chunk_key, not _is_procedural_spawn_chunk_near_viewer(coord))


func _on_chunk_unloaded(coord: Vector3i) -> void:
	if coord.y != 0:
		return
	# Deferred spawn plans are simulation state for explored chunks, not terrain
	# node state. Keep them across unloads so moving away and back cannot reduce
	# the deterministic population for that chunk.


func _process_deferred_spawn_chunks() -> void:
	if deferred_spawn_chunks.is_empty() or not viewer:
		if deferred_spawn_chunks.is_empty():
			_clear_deferred_spawn_chunks()
		return

	if deferred_spawn_chunk_keys.is_empty():
		_rebuild_deferred_spawn_chunk_keys()

	var total := deferred_spawn_chunk_keys.size()
	if total <= 0:
		_deferred_spawn_chunk_cursor = 0
		return

	var checks := mini(deferred_spawn_chunks_per_frame, total)
	var start_index := _deferred_spawn_chunk_cursor % total
	var stale_count := 0
	for offset in range(checks):
		var chunk_key: Vector2i = deferred_spawn_chunk_keys[(start_index + offset) % total]
		if not deferred_spawn_chunks.has(chunk_key):
			stale_count += 1
			continue

		var deferred_data_variant: Variant = deferred_spawn_chunks.get(chunk_key, {})
		if typeof(deferred_data_variant) != TYPE_DICTIONARY:
			deferred_spawn_chunks.erase(chunk_key)
			stale_count += 1
			continue

		var deferred_data: Dictionary = deferred_data_variant
		var coord_variant: Variant = deferred_data.get("coord", Vector3i.ZERO)
		if typeof(coord_variant) != TYPE_VECTOR3I:
			deferred_spawn_chunks.erase(chunk_key)
			stale_count += 1
			continue

		var coord: Vector3i = coord_variant
		if not _is_procedural_spawn_chunk_near_viewer(coord):
			continue

		deferred_spawn_chunks.erase(chunk_key)
		_activate_procedural_spawn_plan(chunk_key, deferred_data.get("spawns", []))

	if deferred_spawn_chunks.is_empty():
		_clear_deferred_spawn_chunks()
		return

	_deferred_spawn_chunk_cursor = (start_index + checks) % maxi(1, deferred_spawn_chunk_keys.size())
	if stale_count > 0 and deferred_spawn_chunk_keys.size() > deferred_spawn_chunks.size() + deferred_spawn_chunks_per_frame:
		_rebuild_deferred_spawn_chunk_keys()


func _defer_spawn_chunk(chunk_key: Vector2i, coord: Vector3i, spawns: Array) -> void:
	if deferred_spawn_chunks.has(chunk_key):
		return
	deferred_spawn_chunks[chunk_key] = {
		"coord": coord,
		"spawns": spawns
	}
	deferred_spawn_chunk_keys.append(chunk_key)


func _clear_deferred_spawn_chunks() -> void:
	deferred_spawn_chunks.clear()
	deferred_spawn_chunk_keys.clear()
	_deferred_spawn_chunk_cursor = 0


func _rebuild_deferred_spawn_chunk_keys() -> void:
	var rebuilt_keys: Array[Vector2i] = []
	var seen: Dictionary = {}
	for key in deferred_spawn_chunk_keys:
		if deferred_spawn_chunks.has(key) and not seen.has(key):
			rebuilt_keys.append(key)
			seen[key] = true
	for key_variant in deferred_spawn_chunks.keys():
		var key: Vector2i = key_variant
		if not seen.has(key):
			rebuilt_keys.append(key)
			seen[key] = true
	deferred_spawn_chunk_keys = rebuilt_keys
	if deferred_spawn_chunk_keys.is_empty():
		_deferred_spawn_chunk_cursor = 0
	else:
		_deferred_spawn_chunk_cursor = _deferred_spawn_chunk_cursor % deferred_spawn_chunk_keys.size()


func _is_procedural_spawn_chunk_near_viewer(coord: Vector3i) -> bool:
	if not viewer or not is_instance_valid(viewer):
		return false

	var chunk_center := Vector3(
		float(coord.x) * TERRAIN_CHUNK_STRIDE + TERRAIN_CHUNK_STRIDE * 0.5,
		0.0,
		float(coord.z) * TERRAIN_CHUNK_STRIDE + TERRAIN_CHUNK_STRIDE * 0.5
	)
	var spawn_queue_radius := spawn_radius + TERRAIN_CHUNK_STRIDE
	return _planar_distance_squared(chunk_center, viewer.global_position) <= spawn_queue_radius * spawn_queue_radius


func _process_procedural_spawn_chunk(coord: Vector3i, chunk_key: Vector2i, defer_activation: bool = false) -> void:
	if spawned_chunks.has(chunk_key) or deferred_spawn_chunks.has(chunk_key):
		return

	var spawn_plan := _build_procedural_spawn_plan(coord, chunk_key)
	if spawn_plan.is_empty():
		spawned_chunks[chunk_key] = true
		debug_chunk_spawn_processed.emit(chunk_key)
		return

	if defer_activation:
		_defer_spawn_chunk(chunk_key, coord, spawn_plan)
		debug_chunk_spawn_blocked.emit(chunk_key, "deferred_activation")
		return

	_activate_procedural_spawn_plan(chunk_key, spawn_plan)


func _build_procedural_spawn_plan(coord: Vector3i, chunk_key: Vector2i) -> Array:
	# Deterministic RNG based on chunk coordinate
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(chunk_key) + (terrain_manager.world_seed if "world_seed" in terrain_manager else 12345)
	
	# Roll spawn chance
	if rng.randf() > spawn_chance_per_chunk:
		return [] # No spawn this chunk
	
	# Calculate chunk center for biome detection
	var chunk_center = Vector3(coord.x * TERRAIN_CHUNK_STRIDE + 16.0, 0, coord.z * TERRAIN_CHUNK_STRIDE + 16.0)
	
	# Determine biome at chunk center
	var biome_id = _get_biome_at(chunk_center.x, chunk_center.z)
	var rules = spawn_rules.get(biome_id, spawn_rules[0]) # Default to grass rules
	
	# Roll for zombie spawn based on biome
	var zombie_chance = rules.get("zombie_chance", 0.3)
	
	var spawn_plan: Array = []
	var spawns_this_chunk = 0
	for i in range(max_spawns_per_chunk):
		if spawns_this_chunk >= max_spawns_per_chunk:
			break
		
		if rng.randf() > zombie_chance:
			continue # Failed this spawn roll
		
		# Random position within chunk
		var offset_x = rng.randf_range(2.0, 29.0) # Avoid chunk edges
		var offset_z = rng.randf_range(2.0, 29.0)
		var spawn_x = coord.x * TERRAIN_CHUNK_STRIDE + offset_x
		var spawn_z = coord.z * TERRAIN_CHUNK_STRIDE + offset_z
		
		spawn_plan.append({
			"position": Vector3(spawn_x, 0, spawn_z),
			"scene": zombie_scene,
			"procedural": true, # Mark as procedurally spawned
			"chunk_key": chunk_key
		})
		spawns_this_chunk += 1
	
	return spawn_plan


func _enqueue_procedural_spawn_plan(spawn_plan: Array) -> void:
	for spawn_data in spawn_plan:
		if spawn_data is Dictionary:
			pending_spawns.append(spawn_data)


func _activate_procedural_spawn_plan(chunk_key: Vector2i, spawn_plan: Array) -> void:
	if spawned_chunks.has(chunk_key):
		return
	spawned_chunks[chunk_key] = true
	debug_chunk_spawn_processed.emit(chunk_key)
	_enqueue_procedural_spawn_plan(spawn_plan)


func _get_deferred_spawn_plan_count() -> int:
	var total := 0
	for deferred_data_variant in deferred_spawn_chunks.values():
		if typeof(deferred_data_variant) != TYPE_DICTIONARY:
			continue
		var deferred_data: Dictionary = deferred_data_variant
		var spawns: Array = deferred_data.get("spawns", [])
		total += spawns.size()
	return total

## Get biome ID at world position (must match gen_density.glsl)
func _get_biome_at(world_x: float, world_z: float) -> int:
	if terrain_manager and terrain_manager.has_method("get_surface_material_at"):
		var terrain_biome := int(terrain_manager.get_surface_material_at(world_x, world_z, false))
		if terrain_biome >= 0:
			return terrain_biome

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
	_clear_deferred_spawn_chunks()


func is_entity_frozen(entity: Node3D) -> bool:
	return frozen_entities.has(entity)


func _get_collision_range() -> float:
	var collision_range = 93.0 # 3 chunks * 31 stride
	if terrain_manager and "collision_distance" in terrain_manager:
		collision_range = terrain_manager.collision_distance * 31.0
	return collision_range


func _get_collision_range_squared() -> float:
	var collision_range := _get_collision_range()
	return collision_range * collision_range


func _get_effective_freeze_radius() -> float:
	var effective_radius := freeze_radius
	var collision_radius := _get_collision_range()
	if collision_radius > 0.0:
		effective_radius = collision_radius - freeze_collision_margin
		if effective_radius <= 0.0:
			effective_radius = collision_radius

	return minf(effective_radius, despawn_radius - 1.0)


func _get_effective_freeze_radius_squared() -> float:
	var effective_radius := _get_effective_freeze_radius()
	return effective_radius * effective_radius


func _get_effective_active_physics_radius_squared(freeze_dist_sq: float) -> float:
	if active_physics_radius <= 0.0:
		return freeze_dist_sq
	var active_radius_sq := active_physics_radius * active_physics_radius
	return minf(active_radius_sq, freeze_dist_sq)


func _is_terrain_collision_ready(position: Vector3) -> bool:
	if (not terrain_manager or not is_instance_valid(terrain_manager)):
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")

	if not terrain_manager:
		return true

	_bump_frame_entity_stat("terrain_ready_checks")

	if terrain_manager.has_method("is_collision_ready_at"):
		if not terrain_manager.is_collision_ready_at(position):
			_bump_frame_entity_stat("terrain_ready_misses")
			return false
		return true

	if terrain_manager.has_method("are_chunks_ready_around"):
		if not terrain_manager.are_chunks_ready_around(position, 0):
			_bump_frame_entity_stat("terrain_ready_misses")
			return false

	return true


func _planar_distance_squared(a: Vector3, b: Vector3) -> float:
	var dx := a.x - b.x
	var dz := a.z - b.z
	return dx * dx + dz * dz
