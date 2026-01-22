extends Node3D

signal chunk_generated(coord: Vector3i, chunk_node: Node3D)
signal chunk_modified(coord: Vector3i, chunk_node: Node3D) # For terrain edits - vegetation stays
signal chunk_unloaded(coord: Vector3i) # Emitted when chunk is removed from world
signal spawn_zones_ready(positions: Array) # Emitted when all requested spawn zones have loaded

# 32 Voxels wide
const CHUNK_SIZE = 32
# Overlap chunks by 1 unit to prevent gaps (seams)
const CHUNK_STRIDE = CHUNK_SIZE - 1
const DENSITY_GRID_SIZE = 33 # 0..32

# Y-layer limits for vertical chunk stacking
const MIN_Y_LAYER = -20 # How deep you can dig (in chunk layers)
const MAX_Y_LAYER = 40 # How high you can build (in chunk layers)

# Max triangles estimation
const MAX_TRIANGLES = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 5

@export var viewer: Node3D
@export var render_distance: int = 5 # Visual range
@export var terrain_height: float = 10.0
@export var water_level: float = 13.0 # Lowered to keep roads dry
@export var noise_frequency: float = 0.1
## World generation seed - same seed = same world
## Change this for different world generation
@export var world_seed: int = 12345

## Procedural Road Network (generated with terrain)
@export var procedural_roads_enabled: bool = true # Toggle to disable procedural roads
@export var procedural_road_spacing: float = 100.0 # Distance between roads
@export var procedural_road_width: float = 8.0 # Width of roads
@export var debug_show_road_zones: bool = false # Debug: show road alignment (Yellow=correct, Red=spillover, Green=crack)

# GPU Threading (single thread for compute shaders)
var compute_thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var exit_thread: bool = false

# CPU Worker Pool (for mesh building and collision)
const CPU_WORKER_COUNT = 2
var cpu_threads: Array[Thread] = []
var cpu_task_queue: Array[Dictionary] = []
var cpu_mutex: Mutex
var cpu_semaphore: Semaphore

# Task Queue (GPU tasks)
var task_queue: Array[Dictionary] = []

# Batching for synchronized updates
var modification_batch_id: int = 0
var pending_batches: Dictionary = {}

# Shaders (SPIR-V Data)
var shader_gen_spirv: RDShaderSPIRV
var shader_gen_water_spirv: RDShaderSPIRV # New
var shader_mod_spirv: RDShaderSPIRV
var shader_mesh_spirv: RDShaderSPIRV

var material_terrain: Material
var material_water: Material

class ChunkData:
	var node_terrain: Node3D
	var node_water: Node3D
	var density_buffer_terrain: RID
	var density_buffer_water: RID
	var material_buffer_terrain: RID # Material IDs per voxel (GPU)
	
	# Optimization: Use PhysicsServer3D RIDs directly instead of Nodes for terrain collision
	var body_rid_terrain: RID
	
	var collision_shape_terrain: CollisionShape3D # For dynamic enable/disable
	var terrain_shape: Shape3D # Store the shape for lazy creation
	# CPU mirrors for physics detection
	var cpu_density_water: PackedFloat32Array = PackedFloat32Array()
	var cpu_density_terrain: PackedFloat32Array = PackedFloat32Array()
	# CPU mirror for materials (for 3D texture creation)
	var cpu_material_terrain: PackedByteArray = PackedByteArray()
	# 3D texture for fragment shader sampling
	var material_texture: ImageTexture3D = null
	var chunk_material: ShaderMaterial = null # Per-chunk material instance
	# Modification version - incremented on each modify, used to skip stale updates
	var mod_version: int = 0

var active_chunks: Dictionary = {}

# Collision distance - only enable collision within this range (cheaper than render_distance)
@export var collision_distance: int = 3 # Chunks within this get collision

# Time-budgeted node creation - prevents stutters from multiple chunks completing at once
var pending_nodes: Array[Dictionary] = [] # Queue of completed chunks waiting for node creation
var pending_nodes_mutex: Mutex

# Time-distributed finalization - spreads chunk appearances evenly over time
var last_finalization_time_ms: int = 0
## Minimum time between chunk finalizations (ms). Lower = faster loading, Higher = smoother appearance.
## 100ms = max 10 chunks/second for very smooth visual spread.
@export_range(0, 5000, 10) var min_finalization_interval_ms: int = 100

# Two-phase loading system
# Phase 1 (Initial Load): Fast/aggressive at game start for loading screen
# Phase 2 (Exploration): Slower/throttled when player explores
var initial_load_phase: bool = true
var initial_load_target_chunks: int = 0 # Calculated at startup based on render_distance
var chunks_loaded_initial: int = 0
var underground_load_triggered: bool = false # Track if Y=-1 burst load has been done

## Delay between chunk generation during initial game load (ms). 
## Initial load ends after ~π×render_distance² chunks (e.g., ~78 chunks for render_distance=5).
## Set to 0 for fastest loading. Higher values = slower but smoother loading.
@export_range(0, 100, 1) var initial_load_delay_ms: int = 0

## Delay between chunk generation when player is exploring (ms).
## Higher values reduce FPS drops but make terrain load slower as you move.
## Recommended: 100-200ms for smooth exploration.
@export_range(0, 6000, 10) var exploration_delay_ms: int = 300

# Adaptive loading - throttles based on current FPS
var target_fps: float = 75.0
var min_acceptable_fps: float = 45.0
var current_fps: float = 60.0
var fps_samples: Array[float] = []
var adaptive_frame_budget_ms: float = 1.0 # Dynamically adjusted (reduced for smoother FPS)
var chunks_per_frame_limit: int = 2 # Dynamically adjusted
var loading_paused: bool = false
var terrain_grid = null


# Persistent modification storage - survives chunk unloading
# Format: coord (Vector2i) -> Array of { brush_pos: Vector3, radius: float, value: float, shape: int, layer: int }
var stored_modifications: Dictionary = {}

# Spawn zone tracking - positions waiting for terrain to load
# Format: Array of { "position": Vector3, "radius": int, "pending_coords": Array[Vector3i] }
var pending_spawn_zones: Array = []

func _ready():
	mutex = Mutex.new()
	semaphore = Semaphore.new()
	pending_nodes_mutex = Mutex.new()
	cpu_mutex = Mutex.new()
	cpu_semaphore = Semaphore.new()
	
	if not viewer:
		viewer = get_tree().get_first_node_in_group("player")
		if not viewer:
			viewer = get_node_or_null("../CharacterBody3D")
	
	if viewer:
		DebugManager.log_chunk("Viewer found: %s" % viewer.name)
	else:
		push_warning("Viewer NOT found! Terrain generation will not start.")

	# Check for GDExtension
	if ClassDB.class_exists("MeshBuilder"):
		DebugManager.log_chunk("GDExtension MeshBuilder active")
	else:
		push_warning("[GDExtension] MeshBuilder NOT found. Using slow GDScript fallback.")

	# Check for TerrainGrid
	if ClassDB.class_exists("TerrainGrid"):
		terrain_grid = ClassDB.instantiate("TerrainGrid")
		DebugManager.log_chunk("GDExtension TerrainGrid active")


	# Load shaders (Data only, safe on Main Thread)
	shader_gen_spirv = load("res://world_marching_cubes/gen_density.glsl").get_spirv()
	shader_gen_water_spirv = load("res://world_marching_cubes/gen_water_density.glsl").get_spirv() # New
	shader_mod_spirv = load("res://world_marching_cubes/modify_density.glsl").get_spirv()
	shader_mesh_spirv = load("res://world_marching_cubes/marching_cubes.glsl").get_spirv()
	
	# Setup Terrain Shader Material
	var shader = load("res://world_marching_cubes/terrain.gdshader")
	material_terrain = ShaderMaterial.new()
	material_terrain.shader = shader
	
	material_terrain.set_shader_parameter("texture_grass", load("res://world_marching_cubes/green-grass-texture.jpg"))
	material_terrain.set_shader_parameter("texture_rock", load("res://world_marching_cubes/rocky-texture.jpg"))
	material_terrain.set_shader_parameter("texture_stone", load("res://world_marching_cubes/stone_material.png")) # Underground/gravel
	material_terrain.set_shader_parameter("texture_sand", load("res://world_marching_cubes/sand-texture.jpg"))
	material_terrain.set_shader_parameter("texture_snow", load("res://world_marching_cubes/snow-texture.jpg") if FileAccess.file_exists("res://world_marching_cubes/snow-texture.jpg") else load("res://world_marching_cubes/rocky-texture.jpg"))
	material_terrain.set_shader_parameter("texture_road", load("res://world_marching_cubes/asphalt-texture.png"))
	material_terrain.set_shader_parameter("uv_scale", 0.5)
	material_terrain.set_shader_parameter("global_snow_amount", 0.0)
	# Procedural road texture settings (sync with density shader)
	material_terrain.set_shader_parameter("procedural_road_enabled", procedural_roads_enabled)
	material_terrain.set_shader_parameter("procedural_road_spacing", procedural_road_spacing if procedural_roads_enabled else 0.0)
	material_terrain.set_shader_parameter("procedural_road_width", procedural_road_width)
	# Terrain parameters for per-pixel material calculation (sync with gen_density.glsl)
	material_terrain.set_shader_parameter("terrain_height", terrain_height)
	material_terrain.set_shader_parameter("noise_frequency", noise_frequency)
	# Debug visualization
	material_terrain.set_shader_parameter("debug_show_road_zones", debug_show_road_zones)
	# Road mask will be set by road_manager
	
	# Setup Water Material
	material_water = ShaderMaterial.new()
	material_water.shader = load("res://world_marching_cubes/water.gdshader")
	# Dark green water colors
	material_water.set_shader_parameter("albedo", Color(0.05, 0.18, 0.12))
	material_water.set_shader_parameter("albedo_deep", Color(0.01, 0.06, 0.04))
	material_water.set_shader_parameter("albedo_shallow", Color(0.1, 0.3, 0.2))
	material_water.set_shader_parameter("beer_factor", 0.25)
	# Water normal texture for detailed ripples
	var water_normal = load("res://world_marching_cubes/water_texture.png")
	if water_normal:
		material_water.set_shader_parameter("water_normal_texture", water_normal)
	
	# Start GPU thread
	compute_thread = Thread.new()
	compute_thread.start(_thread_function)
	
	# Start CPU worker pool
	for i in range(CPU_WORKER_COUNT):
		var thread = Thread.new()
		thread.start(_cpu_thread_function)
		cpu_threads.append(thread)
	DebugManager.log_chunk("Started %d CPU workers" % CPU_WORKER_COUNT)
	
	# Calculate initial load target (all chunks within render distance)
	# For ground-level players, we only load Y=0, same chunk count as before
	initial_load_target_chunks = int(PI * render_distance * render_distance)
	DebugManager.log_chunk("Two-phase loading: target=%d chunks, initial=%dms, explore=%dms" % [initial_load_target_chunks, initial_load_delay_ms, exploration_delay_ms])


## Gets the effective viewer position for chunk loading.
## Returns vehicle position when player is driving a vehicle,
## otherwise returns the player's position.
func get_viewer_position() -> Vector3:
	if not viewer:
		return Vector3.ZERO
	
	# Check if player is in a vehicle
	var vm = get_tree().get_first_node_in_group("vehicle_manager")
	if vm and "current_player_vehicle" in vm and vm.current_player_vehicle:
		return vm.current_player_vehicle.global_position
	
	# Default: player's position
	return viewer.global_position


func _process(delta):
	if not viewer:
		return
	
	# Track FPS
	_update_fps_tracking(delta)
	
	# Adjust loading based on FPS
	_adjust_adaptive_loading()
	
	PerformanceMonitor.start_measure("Chunk Update")
	update_chunks()
	PerformanceMonitor.end_measure("Chunk Update", PerformanceMonitor.thresholds.get("chunk_gen", 3.0)) # Should be fast (< 2ms)
	
	PerformanceMonitor.start_measure("Node Finalization")
	process_pending_nodes()
	PerformanceMonitor.end_measure("Node Finalization", 2.0)
	
	update_collision_proximity() # Enable/disable collision based on player distance
	
	# HOTFIX: Ensure all existing chunks have layer 512 (Layer 10) for pickups
	if active_chunks.size() > 0 and not get_meta("collision_fixed", false):
		for coord in active_chunks:
			var data = active_chunks[coord]
			if data:
				if data.body_rid_terrain.is_valid():
					PhysicsServer3D.body_set_collision_layer(data.body_rid_terrain, 1 | 512)
				if data.node_terrain is StaticBody3D:
					data.node_terrain.collision_layer = 1 | 512
		set_meta("collision_fixed", true)
		DebugManager.log_chunk("HOTFIX: Updated existing chunks to layer 1|512")

var debug_chunk_bounds: bool = false

func _unhandled_input(event):
	# F9 toggles chunk boundary visualization
	if event is InputEventKey and event.pressed and event.keycode == KEY_F9:
		debug_chunk_bounds = !debug_chunk_bounds
		DebugManager.log_chunk("Chunk bounds visualization: %s" % ("ON" if debug_chunk_bounds else "OFF"))
		# Update all chunk materials
		for coord in active_chunks:
			var data = active_chunks[coord]
			if data and data.chunk_material:
				data.chunk_material.set_shader_parameter("debug_show_chunk_bounds", debug_chunk_bounds)
		material_terrain.set_shader_parameter("debug_show_chunk_bounds", debug_chunk_bounds)
	
	# F10 toggles road zone visualization (Yellow=correct, Red=spillover, Green=crack)
	if event is InputEventKey and event.pressed and event.keycode == KEY_F10:
		debug_show_road_zones = !debug_show_road_zones
		DebugManager.log_chunk("Road zones visualization: %s" % ("ON" if debug_show_road_zones else "OFF"))
		# Update all chunk materials
		for coord in active_chunks:
			var data = active_chunks[coord]
			if data and data.chunk_material:
				data.chunk_material.set_shader_parameter("debug_show_road_zones", debug_show_road_zones)
		material_terrain.set_shader_parameter("debug_show_road_zones", debug_show_road_zones)

func _update_fps_tracking(delta: float):
	var instant_fps = 1.0 / delta if delta > 0 else 60.0
	fps_samples.append(instant_fps)
	
	# Keep last 30 samples (0.5 seconds at 60fps)
	while fps_samples.size() > 30:
		fps_samples.pop_front()
	
	# Calculate average FPS
	var total = 0.0
	for fps in fps_samples:
		total += fps
	current_fps = total / fps_samples.size()

func _adjust_adaptive_loading():
	if current_fps < min_acceptable_fps:
		# FPS is too low - pause loading completely
		loading_paused = true
		adaptive_frame_budget_ms = 0.0 # Zero work when FPS critical
		chunks_per_frame_limit = 0
	elif current_fps < target_fps:
		# FPS is below target - reduce loading with tighter budget
		loading_paused = false
		var fps_ratio = current_fps / target_fps
		adaptive_frame_budget_ms = lerp(0.25, 1.0, fps_ratio) # Tighter range
		chunks_per_frame_limit = 1
	else:
		# FPS is good - still limit to prevent stutters
		loading_paused = false
		adaptive_frame_budget_ms = 1.5 # Max 1.5ms (reduced from 3ms)
		chunks_per_frame_limit = 1

var collision_update_counter: int = 0
func update_collision_proximity():
	# Only update every 30 frames to reduce overhead
	collision_update_counter += 1
	if collision_update_counter < 30:
		return
	collision_update_counter = 0
	
	var p_pos = get_viewer_position()
	var p_chunk_x = int(floor(p_pos.x / CHUNK_STRIDE))
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE))
	var p_chunk_z = int(floor(p_pos.z / CHUNK_STRIDE))
	var center_chunk = Vector3i(p_chunk_x, p_chunk_y, p_chunk_z)
	
	for coord in active_chunks:
		var data = active_chunks[coord]
		if data == null:
			continue
		
		# 3D distance for collision check
		var dx = coord.x - center_chunk.x
		var dy = coord.y - center_chunk.y
		var dz = coord.z - center_chunk.z
		var dist_xz = sqrt(dx * dx + dz * dz)
		# Enable collision if close horizontally AND within 2 Y layers
		var should_have_collision = dist_xz <= collision_distance and abs(dy) <= 2
		
		# Enable/disable collision shape
		if data.collision_shape_terrain:
			data.collision_shape_terrain.disabled = not should_have_collision

# Process pending node creations - TIME-DISTRIBUTED to eliminate burst loading
func process_pending_nodes():
	if pending_nodes.is_empty():
		return
	
	# Skip entirely if loading is paused due to low FPS
	if loading_paused:
		return
	
	# Time-distributed: Only finalize if enough time has passed since last chunk
	# This spreads chunk appearances evenly over time instead of bursts
	var current_time = Time.get_ticks_msec()
	var time_since_last = current_time - last_finalization_time_ms
	
	# During initial load phase, process faster (50ms interval)
	var effective_interval = 50 if initial_load_phase else min_finalization_interval_ms
	
	if time_since_last < effective_interval:
		return
	
	pending_nodes_mutex.lock()
	if pending_nodes.is_empty():
		pending_nodes_mutex.unlock()
		return
	
	# Sort by distance to player (closest first) for smooth outward loading
	PerformanceMonitor.start_measure("Finalize: Sort")
	_sort_pending_by_distance()
	PerformanceMonitor.end_measure("Finalize: Sort", 0.1)
	
	var item = pending_nodes.pop_front()
	pending_nodes_mutex.unlock()
	
	_finalize_chunk_creation(item)
	last_finalization_time_ms = current_time

# Sort pending nodes by distance to player (closest first)
func _sort_pending_by_distance():
	if pending_nodes.size() <= 1 or not viewer:
		return
	var viewer_chunk = Vector3i(
		int(floor(viewer.global_position.x / CHUNK_STRIDE)),
		int(floor(viewer.global_position.y / CHUNK_STRIDE)),
		int(floor(viewer.global_position.z / CHUNK_STRIDE))
	)
	pending_nodes.sort_custom(func(a, b):
		var dist_a = (a.coord - viewer_chunk).length_squared()
		var dist_b = (b.coord - viewer_chunk).length_squared()
		return dist_a < dist_b
	)


## Get terrain density at world position (reads from CPU-cached chunk data)
## Returns positive for air, negative for solid. Returns 1.0 if chunk not loaded.
func get_terrain_density(global_pos: Vector3) -> float:
	# Find Chunk (3D coordinates)
	var chunk_x = int(floor(global_pos.x / CHUNK_STRIDE))
	var chunk_y = int(floor(global_pos.y / CHUNK_STRIDE))
	var chunk_z = int(floor(global_pos.z / CHUNK_STRIDE))
	var coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not active_chunks.has(coord):
		print("[DENSITY_DEBUG] Chunk %s not loaded for pos %s" % [coord, global_pos])
		return 1.0 # Air (chunk not loaded)
		
	var data = active_chunks[coord]
	if data == null or data.cpu_density_terrain.is_empty():
		print("[DENSITY_DEBUG] Chunk %s has no density data" % coord)
		return 1.0
		
	# Find local position within chunk
	var chunk_origin = Vector3(chunk_x * CHUNK_STRIDE, chunk_y * CHUNK_STRIDE, chunk_z * CHUNK_STRIDE)
	var local_pos = global_pos - chunk_origin
	
	# Round to nearest grid point
	var ix = int(round(local_pos.x))
	var iy = int(round(local_pos.y))
	var iz = int(round(local_pos.z))
	
	if ix < 0 or ix >= DENSITY_GRID_SIZE or iy < 0 or iy >= DENSITY_GRID_SIZE or iz < 0 or iz >= DENSITY_GRID_SIZE:
		print("[DENSITY_DEBUG] Local pos (%d,%d,%d) out of bounds for %s" % [ix, iy, iz, global_pos])
		return 1.0 # Out of bounds
		
	var index = ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
	
	if index >= 0 and index < data.cpu_density_terrain.size():
		var density = data.cpu_density_terrain[index]
		print("[DENSITY_DEBUG] Read density=%.3f at global=%s chunk=%s local=(%d,%d,%d) index=%d" % [density, global_pos, coord, ix, iy, iz, index])
		return density
		
	print("[DENSITY_DEBUG] Index %d out of range (size=%d)" % [index, data.cpu_density_terrain.size()])
	return 1.0

func get_water_density(global_pos: Vector3) -> float:
	# Find Chunk (3D coordinates)
	var chunk_x = int(floor(global_pos.x / CHUNK_STRIDE))
	var chunk_y = int(floor(global_pos.y / CHUNK_STRIDE))
	var chunk_z = int(floor(global_pos.z / CHUNK_STRIDE))
	var coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not active_chunks.has(coord):
		return 1.0 # Air (Positive is air, Negative is water)
		
	var data = active_chunks[coord]
	if data == null or data.cpu_density_water.is_empty():
		return 1.0
		
	# Find local position within chunk
	var chunk_origin = Vector3(chunk_x * CHUNK_STRIDE, chunk_y * CHUNK_STRIDE, chunk_z * CHUNK_STRIDE)
	var local_pos = global_pos - chunk_origin
	
	# Clamp to grid
	var ix = int(round(local_pos.x))
	var iy = int(round(local_pos.y))
	var iz = int(round(local_pos.z))
	
	if ix < 0 or ix >= DENSITY_GRID_SIZE or iy < 0 or iy >= DENSITY_GRID_SIZE or iz < 0 or iz >= DENSITY_GRID_SIZE:
		return 1.0 # Out of bounds
		
	var index = ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
	
	if index >= 0 and index < data.cpu_density_water.size():
		return data.cpu_density_water[index]
		
	return 1.0

## Returns true when initial terrain chunks are visually ready (meshes created)
func is_initial_load_complete() -> bool:
	pending_nodes_mutex.lock()
	var nodes_empty = pending_nodes.is_empty()
	pending_nodes_mutex.unlock()
	return not initial_load_phase and nodes_empty

## Progress: 0.0-1.0 based on chunks loaded during initial phase
func get_loading_progress() -> float:
	if initial_load_target_chunks <= 0:
		return 1.0
	return clamp(float(chunks_loaded_initial) / initial_load_target_chunks, 0.0, 1.0)

## Get count of pending nodes waiting to be finalized (for loading screen)
func get_pending_nodes_count() -> int:
	pending_nodes_mutex.lock()
	var count = pending_nodes.size()
	pending_nodes_mutex.unlock()
	return count

## Get material ID at world position (reads from CPU-cached chunk data)
## Returns -1 if position is outside loaded chunks or no material data
func get_material_at(global_pos: Vector3) -> int:
	# Find Chunk (3D coordinates)
	var chunk_x = int(floor(global_pos.x / CHUNK_STRIDE))
	var chunk_y = int(floor(global_pos.y / CHUNK_STRIDE))
	var chunk_z = int(floor(global_pos.z / CHUNK_STRIDE))
	var coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not active_chunks.has(coord):
		return -1 # Chunk not loaded
		
	var data = active_chunks[coord]
	if data == null or data.cpu_material_terrain.is_empty():
		return -1 # No material data
		
	# Find local position within chunk
	var chunk_origin = Vector3(chunk_x * CHUNK_STRIDE, chunk_y * CHUNK_STRIDE, chunk_z * CHUNK_STRIDE)
	var local_pos = global_pos - chunk_origin
	
	# CRITICAL: Match GPU behavior!
	# GPU marching_cubes.glsl samples material at: pos + vec3(0.5) then uses round()
	# We use floor to find the voxel cube, which is equivalent to GPU's round(pos+0.5) = floor(pos)+1 when pos > 0.5
	# Actually, to EXACTLY match: round(local_pos) gives the nearest voxel
	var ix = int(round(local_pos.x))
	var iy = int(round(local_pos.y))
	var iz = int(round(local_pos.z))
	
	# Clamp to valid range (0-32)
	ix = clampi(ix, 0, DENSITY_GRID_SIZE - 1)
	iy = clampi(iy, 0, DENSITY_GRID_SIZE - 1)
	iz = clampi(iz, 0, DENSITY_GRID_SIZE - 1)
		
	var voxel_index = ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
	
	# CRITICAL: Material buffer stores uint32 per voxel (4 bytes each)
	# We need to read the first byte of each uint32 (material ID is 0-255)
	var byte_offset = voxel_index * 4 # 4 bytes per uint
	
	if byte_offset >= 0 and byte_offset < data.cpu_material_terrain.size():
		return data.cpu_material_terrain[byte_offset] # First byte is the mat_id
		
	return -1


# Check if any Y layer at this X,Z has stored modifications (player-built terrain)
func has_modifications_at_xz(x: int, z: int) -> bool:
	for coord in stored_modifications:
		if coord.x == x and coord.z == z:
			return true
	return false

func get_terrain_height(global_x: float, global_z: float) -> float:
	# Find X,Z chunk coordinates
	var chunk_x = int(floor(global_x / CHUNK_STRIDE))
	var chunk_z = int(floor(global_z / CHUNK_STRIDE))
	
	# Calculate local X,Z within chunk
	var chunk_origin_x = chunk_x * CHUNK_STRIDE
	var chunk_origin_z = chunk_z * CHUNK_STRIDE
	var local_x = int(round(global_x - chunk_origin_x))
	var local_z = int(round(global_z - chunk_origin_z))
	
	if local_x < 0 or local_x >= DENSITY_GRID_SIZE or local_z < 0 or local_z >= DENSITY_GRID_SIZE:
		return -1000.0
	
	# Scan from highest to lowest Y-layer to find terrain surface
	var best_height = -1000.0
	
	for chunk_y in range(MAX_Y_LAYER, MIN_Y_LAYER - 1, -1):
		var coord = Vector3i(chunk_x, chunk_y, chunk_z)
		
		if not active_chunks.has(coord):
			continue
			
		var data = active_chunks[coord]
		if data == null or data.cpu_density_terrain.is_empty():
			continue
		
		var chunk_base_y = chunk_y * CHUNK_STRIDE
		
		# Scan Y column from top to bottom within this chunk
		var prev_density = 1.0 # Assume air above
		for iy in range(DENSITY_GRID_SIZE - 1, -1, -1):
			var index = local_x + (iy * DENSITY_GRID_SIZE) + (local_z * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
			var density = data.cpu_density_terrain[index]
			
			if density < 0.0:
				# Found ground! Interpolate for accurate isosurface height
				var local_height: float
				if iy < DENSITY_GRID_SIZE - 1:
					var t = prev_density / (prev_density - density)
					local_height = float(iy + 1) - t
				else:
					local_height = float(iy)
				
				var world_height = chunk_base_y + local_height
				if world_height > best_height:
					best_height = world_height
				# Found surface in this chunk, stop searching
				return best_height
			prev_density = density
	
	return best_height # Return -1000.0 if no terrain found

# Optimized height lookup that only checks a specific chunk (much faster for vegetation placement)
func get_chunk_surface_height(coord: Vector3i, local_x: int, local_z: int) -> float:
	if not active_chunks.has(coord):
		return -1000.0
		
	var data = active_chunks[coord]
	if data == null or data.cpu_density_terrain.is_empty():
		return -1000.0
		
	# Scan Y column from top to bottom within this chunk
	var chunk_base_y = coord.y * CHUNK_STRIDE
	var prev_density = 1.0 # Assume air above
	
	# Safety check for bounds
	if local_x < 0 or local_x >= DENSITY_GRID_SIZE or local_z < 0 or local_z >= DENSITY_GRID_SIZE:
		return -1000.0
	
	# Pre-calculate index offsets to avoid multiplication in loop
	var col_offset = local_x + (local_z * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
	var stride_y = DENSITY_GRID_SIZE
	
	for iy in range(DENSITY_GRID_SIZE - 1, -1, -1):
		var index = col_offset + (iy * stride_y)
		var density = data.cpu_density_terrain[index]
		
		if density < 0.0:
			# Found ground! Interpolate
			var local_height: float
			if iy < DENSITY_GRID_SIZE - 1:
				var t = prev_density / (prev_density - density)
				local_height = float(iy + 1) - t
			else:
				local_height = float(iy)
			
			return chunk_base_y + local_height
		
		prev_density = density
		
	return -1000.0

# Updated to accept layer (0=Terrain, 1=Water) and optional material_id
# Rate limiting to prevent GPU overload from rapid-fire calls
var _last_modify_time_ms: int = 0
const MODIFY_COOLDOWN_MS: int = 100  # Max 10 modifications per second

func modify_terrain(pos: Vector3, radius: float, value: float, shape: int = 0, layer: int = 0, material_id: int = -1):
	# RATE LIMITING: Skip if called too quickly (prevents 60 GPU ops/sec when holding mouse)
	var now_ms = Time.get_ticks_msec()
	if now_ms - _last_modify_time_ms < MODIFY_COOLDOWN_MS:
		return  # Skip this call, too soon after last one
	_last_modify_time_ms = now_ms
	# Calculate bounds of the modification sphere/box
	# Add extra margin (1.0) to account for material radius extension and shader sampling
	var extra_margin = 1.0 if material_id >= 0 else 0.0
	var min_pos = pos - Vector3(radius + extra_margin, radius + extra_margin, radius + extra_margin)
	var max_pos = pos + Vector3(radius + extra_margin, radius + extra_margin, radius + extra_margin)
	
	var min_chunk_x = int(floor(min_pos.x / CHUNK_STRIDE))
	var max_chunk_x = int(floor(max_pos.x / CHUNK_STRIDE))
	var min_chunk_y = int(floor(min_pos.y / CHUNK_STRIDE))
	var max_chunk_y = int(floor(max_pos.y / CHUNK_STRIDE))
	var min_chunk_z = int(floor(min_pos.z / CHUNK_STRIDE))
	var max_chunk_z = int(floor(max_pos.z / CHUNK_STRIDE))
	
	var tasks_to_add = []
	var chunks_to_generate = [] # Track unloaded chunks that need immediate loading
	
	# Store modification for persistence (all affected chunks)
	for x in range(min_chunk_x, max_chunk_x + 1):
		for y in range(min_chunk_y, max_chunk_y + 1):
			for z in range(min_chunk_z, max_chunk_z + 1):
				var coord = Vector3i(x, y, z)
				
				# Store the modification for this chunk (persists across unloads)
				if not stored_modifications.has(coord):
					stored_modifications[coord] = []
				stored_modifications[coord].append({
					"brush_pos": pos,
					"radius": radius,
					"value": value,
					"shape": shape,
					"layer": layer,
					"material_id": material_id
				})
				

				# Only dispatch GPU task if chunk is currently loaded
				if active_chunks.has(coord):
					var data = active_chunks[coord]
					if data != null:
						var target_buffer = data.density_buffer_terrain if layer == 0 else data.density_buffer_water
						
						if target_buffer.is_valid():
							var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
							
							# Increment chunk's modification version and capture for stale detection
							data.mod_version += 1
							var start_mod_version = data.mod_version
							
							var task = {
								"type": "modify",
								"coord": coord,
								"rid": target_buffer,
								"material_rid": data.material_buffer_terrain, # Pass material buffer
								"pos": chunk_pos,
								"brush_pos": pos,
								"radius": radius,
								"value": value,
								"shape": shape,
								"layer": layer,
								"material_id": material_id,
								"start_mod_version": start_mod_version  # For stale detection
							}
							DebugManager.log_chunk("modify_terrain TASK: coord=%s mat_id=%d mat_buf_valid=%s" % [coord, material_id, data.material_buffer_terrain.is_valid()])
							tasks_to_add.append(task)
				else:
					# Chunk not loaded - trigger immediate generation
					# This handles digging into underground layers (Y=-1, etc.)
					if not active_chunks.has(coord): # Not already queued
						active_chunks[coord] = null # Mark as pending
						var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
						if DebugManager.LOG_CHUNK: DebugManager.log_chunk("modify_terrain triggering Y=%d at (%d, %d)" % [coord.y, coord.x, coord.z])
						chunks_to_generate.append({
							"type": "generate",
							"coord": coord,
							"pos": chunk_pos
						})
	
	# Queue chunk generations with high priority (before other generates but after modifies)
	if chunks_to_generate.size() > 0:
		mutex.lock()
		for gen_task in chunks_to_generate:
			task_queue.push_front(gen_task)
		mutex.unlock()
		for i in range(chunks_to_generate.size()):
			semaphore.post()
	
	if tasks_to_add.size() > 0:
		modification_batch_id += 1
		var batch_count = tasks_to_add.size()
		
		mutex.lock()
		# PRIORITY: Insert modifications at FRONT of queue (not back)
		# This ensures player interactions are instant, not queued behind chunk generation
		for i in range(tasks_to_add.size() - 1, -1, -1): # Reverse order to maintain sequence
			var t = tasks_to_add[i]
			t["batch_id"] = modification_batch_id
			t["batch_count"] = batch_count
			task_queue.push_front(t) # Push to front, not append to back
		mutex.unlock()
		
		for i in range(batch_count):
			semaphore.post()

## Fill a 1x1 vertical column of terrain from y_from to y_to
## Uses Column shape (type=2) for precise vertical fills
func fill_column(x: float, z: float, y_from: float, y_to: float, value: float, layer: int = 0):
	DebugManager.log_chunk("fill_column: x=%.2f z=%.2f y=[%.2f to %.2f] val=%.2f" % [x, z, y_from, y_to, value])
	# Calculate center position (mid-point of column)
	var pos = Vector3(x, (y_from + y_to) / 2.0, z)
	
	# Add margin for Marching Cubes boundary overlap (1.0 is sufficient)
	# This ensures adjacent chunks are also updated when column is near boundary
	var margin = 1.0
	var min_chunk_x = int(floor((x - margin) / CHUNK_STRIDE))
	var max_chunk_x = int(floor((x + margin) / CHUNK_STRIDE))
	var min_chunk_y = int(floor(y_from / CHUNK_STRIDE))
	var max_chunk_y = int(floor(y_to / CHUNK_STRIDE))
	var min_chunk_z = int(floor((z - margin) / CHUNK_STRIDE))
	var max_chunk_z = int(floor((z + margin) / CHUNK_STRIDE))
	
	var tasks_to_add = []
	
	for chunk_x in range(min_chunk_x, max_chunk_x + 1):
		for chunk_y in range(min_chunk_y, max_chunk_y + 1):
			for chunk_z in range(min_chunk_z, max_chunk_z + 1):
				var coord = Vector3i(chunk_x, chunk_y, chunk_z)
				
				# Store modification for persistence
				if not stored_modifications.has(coord):
					stored_modifications[coord] = []
				stored_modifications[coord].append({
					"brush_pos": pos,
					"radius": 0.6, # Minimal radius, column shape uses XZ distance
					"value": value,
					"shape": 2, # Column shape
					"layer": layer,
					"y_min": y_from,
					"y_max": y_to,
					"material_id": - 1
				})
				
				if active_chunks.has(coord):
					var data = active_chunks[coord]
					if data != null:
						var target_buffer = data.density_buffer_terrain if layer == 0 else data.density_buffer_water
						if target_buffer.is_valid():
							var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
							tasks_to_add.append({
								"type": "modify",
								"coord": coord,
								"rid": target_buffer,
								"material_rid": data.material_buffer_terrain,
								"pos": chunk_pos,
								"brush_pos": pos,
								"radius": 0.6,
								"value": value,
								"shape": 2, # Column shape
								"layer": layer,
								"y_min": y_from,
								"y_max": y_to,
								"material_id": - 1
							})
	
	if tasks_to_add.size() > 0:
		modification_batch_id += 1
		var batch_count = tasks_to_add.size()
		
		mutex.lock()
		for i in range(tasks_to_add.size() - 1, -1, -1):
			var t = tasks_to_add[i]
			t["batch_id"] = modification_batch_id
			t["batch_count"] = batch_count
			task_queue.push_front(t)
		mutex.unlock()
		
		for i in range(batch_count):
			semaphore.post()
		DebugManager.log_chunk("fill_column: queued %d tasks" % batch_count)
	else:
		DebugManager.log_chunk("fill_column: NO TASKS QUEUED - chunk not loaded or no valid buffer")

func _exit_tree():
	mutex.lock()
	exit_thread = true
	mutex.unlock()
	
	# Signal GPU thread to exit
	semaphore.post()
	
	# Signal all CPU workers to exit
	for i in range(CPU_WORKER_COUNT):
		cpu_semaphore.post()
	
	# Wait for GPU thread
	if compute_thread and compute_thread.is_alive():
		compute_thread.wait_to_finish()
	
	# Wait for CPU workers
	for thread in cpu_threads:
		if thread and thread.is_alive():
			thread.wait_to_finish()

func update_chunks():
	if terrain_grid:
		_update_chunks_native()
	else:
		_update_chunks_gdscript()

func _update_chunks_native():
	if loading_paused:
		return

	var p_pos = viewer.global_position
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE))
	var is_above_ground = p_chunk_y >= 0
	
	# 1. Update Grid (C++)
	# Returns { "load": [Vector3i], "unload": [Vector3i] }
	var result = terrain_grid.update(p_pos, render_distance, is_above_ground, CHUNK_STRIDE)
	
	# 2. Process Unloads
	for coord in result["unload"]:
		_unload_chunk(coord)
		terrain_grid.remove_chunk(coord)
		
	# 3. Process Loads
	var chunks_queued = 0
	
	for coord in result["load"]:
		if chunks_queued >= chunks_per_frame_limit:
			break
			
		# Safe check, though Grid should handle it
		if active_chunks.has(coord):
			continue
			
		_load_chunk(coord)
		terrain_grid.add_chunk(coord)
		chunks_queued += 1
		
	# 4. Special Case: Stored Modifications (Force load if nearby)
	if chunks_queued < chunks_per_frame_limit and not initial_load_phase:
		for coord in stored_modifications:
			if chunks_queued >= chunks_per_frame_limit: break
			if active_chunks.has(coord): continue
			
			var chunk_origin = Vector3(coord.x * CHUNK_STRIDE, 0, coord.z * CHUNK_STRIDE)
			var dist_xz = Vector2(chunk_origin.x, chunk_origin.z).distance_to(Vector2(p_pos.x, p_pos.z))
			
			if dist_xz <= (render_distance * CHUNK_STRIDE):
				_load_chunk(coord)
				terrain_grid.add_chunk(coord)
				chunks_queued += 1

func _load_chunk(coord: Vector3i):
	active_chunks[coord] = null
	
	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
	var task = {
		"type": "generate",
		"coord": coord,
		"pos": chunk_pos
	}
	
	mutex.lock()
	task_queue.append(task)
	mutex.unlock()
	semaphore.post()

func _unload_chunk(coord: Vector3i):
	mutex.lock()
	var i = task_queue.size() - 1
	while i >= 0:
		var t = task_queue[i]
		if t.type == "generate" and t.coord == coord:
			task_queue.remove_at(i)
		i -= 1
	mutex.unlock()
	
	var data = active_chunks[coord]
	if data:
		if data.node_terrain: data.node_terrain.queue_free()
		if data.node_water: data.node_water.queue_free()
		
		# Free Physics Body RID (Immediate, Main Thread/Thread Safe)
		if data.body_rid_terrain.is_valid():
			PhysicsServer3D.free_rid(data.body_rid_terrain)
		
		var tasks = []
		if data.density_buffer_terrain.is_valid():
			tasks.append({"type": "free", "rid": data.density_buffer_terrain})
		if data.density_buffer_water.is_valid():
			tasks.append({"type": "free", "rid": data.density_buffer_water})
			
		mutex.lock()
		for t in tasks: task_queue.append(t)
		mutex.unlock()
		
		for t in tasks: semaphore.post()
	
	active_chunks.erase(coord)
	chunk_unloaded.emit(coord)

func _update_chunks_gdscript():
	var p_pos = viewer.global_position
	var p_chunk_x = int(floor(p_pos.x / CHUNK_STRIDE))
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE)) # Y uses CHUNK_STRIDE for 1-voxel overlap
	var p_chunk_z = int(floor(p_pos.z / CHUNK_STRIDE))
	var center_chunk = Vector3i(p_chunk_x, p_chunk_y, p_chunk_z)

	# 1. Unload far chunks (3D distance check)
	var chunks_to_remove = []
	for coord in active_chunks:
		# NEVER unload terrain layers from MIN_Y_LAYER to 1 within horizontal range
		# This includes all underground layers we might dig into
		var is_terrain_layer = coord.y >= MIN_Y_LAYER and coord.y <= 1
		
		# XZ distance for horizontal, separate check for Y
		var dx = coord.x - center_chunk.x
		var dy = coord.y - center_chunk.y
		var dz = coord.z - center_chunk.z
		var dist_xz = sqrt(dx * dx + dz * dz)
		
		# Unload if too far horizontally
		if dist_xz > render_distance + 2:
			chunks_to_remove.append(coord)
		# For non-terrain layers, also unload if too far vertically
		elif not is_terrain_layer and abs(dy) > 3:
			chunks_to_remove.append(coord)
			
	for coord in chunks_to_remove:
		mutex.lock()
		var i = task_queue.size() - 1
		while i >= 0:
			var t = task_queue[i]
			if t.type == "generate" and t.coord == coord:
				task_queue.remove_at(i)
			i -= 1
		mutex.unlock()
		
		var data = active_chunks[coord]
		if data:
			if data.node_terrain: data.node_terrain.queue_free()
			if data.node_water: data.node_water.queue_free()
			
			# Free Physics Body RID
			if data.body_rid_terrain.is_valid():
				PhysicsServer3D.free_rid(data.body_rid_terrain)
			
			var tasks = []
			if data.density_buffer_terrain.is_valid():
				tasks.append({"type": "free", "rid": data.density_buffer_terrain})
			if data.density_buffer_water.is_valid():
				tasks.append({"type": "free", "rid": data.density_buffer_water})
				
			mutex.lock()
			for t in tasks: task_queue.append(t)
			mutex.unlock()
			
			for t in tasks: semaphore.post()
		
		active_chunks.erase(coord)
		
		# Notify systems that chunk has unloaded (for vegetation cleanup, etc.)
		chunk_unloaded.emit(coord)

	# 2. Load new chunks (adaptive rate limiting based on FPS)
	if loading_paused:
		return # Skip loading when FPS is too low
	
	var chunks_queued_this_frame = 0
	
	# Fast path for players above ground (the common case)
	# This matches the original 2D loading loop exactly, just with Vector3i(x, 0, z)
	# Only use multi-layer path for underground players (Y < 0)
	var is_above_ground = center_chunk.y >= 0
	
	# Debug loading state (gated)
	if DebugManager.LOG_CHUNK and initial_load_phase and chunks_loaded_initial == 0:
		DebugManager.log_chunk("Loading center=%s chunks_per_frame=%d" % [center_chunk, chunks_per_frame_limit])
	
	if is_above_ground:
		# Only load Y=0 layer for performance
		# Underground chunks load on-demand when player digs (via modify_terrain)
		# They're protected from unloading by is_terrain_layer check
		var y_to_load: Array[int] = [0]
		for x in range(center_chunk.x - render_distance, center_chunk.x + render_distance + 1):
			for z in range(center_chunk.z - render_distance, center_chunk.z + render_distance + 1):
				var dist_xz = Vector2(x, z).distance_to(Vector2(center_chunk.x, center_chunk.z))
				if dist_xz > render_distance:
					continue
				
				for y in y_to_load:
					if chunks_queued_this_frame >= chunks_per_frame_limit:
						return
					
					var coord = Vector3i(x, y, z)
					
					if active_chunks.has(coord):
						continue

					active_chunks[coord] = null
					
					# Debug: track when underground chunks are queued
					if DebugManager.LOG_CHUNK and y < 0:
						DebugManager.log_chunk("Queuing underground Y=%d at (%d, %d)" % [y, x, z])
					
					var chunk_pos = Vector3(x * CHUNK_STRIDE, y * CHUNK_STRIDE, z * CHUNK_STRIDE)
					
					var task = {
						"type": "generate",
						"coord": coord,
						"pos": chunk_pos
					}
					
					mutex.lock()
					task_queue.append(task)
					mutex.unlock()
					semaphore.post()
					
					chunks_queued_this_frame += 1
		
		# Also load chunks with stored modifications (player builds) within range
		if not initial_load_phase:
			for coord in stored_modifications:
				if chunks_queued_this_frame >= chunks_per_frame_limit:
					return
				if active_chunks.has(coord):
					continue
				
				# Check if chunk is within horizontal render distance
				var dist_xz = Vector2(coord.x, coord.z).distance_to(Vector2(center_chunk.x, center_chunk.z))
				if dist_xz > render_distance:
					continue
				
				active_chunks[coord] = null
				var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
				var task = {"type": "generate", "coord": coord, "pos": chunk_pos}
				
				mutex.lock()
				task_queue.append(task)
				mutex.unlock()
				semaphore.post()
				chunks_queued_this_frame += 1
	else:
		# Player is underground or flying - load multiple Y layers
		var y_layers = [center_chunk.y - 1, center_chunk.y, center_chunk.y + 1, 0] # Include terrain layer 0
		
		for x in range(center_chunk.x - render_distance, center_chunk.x + render_distance + 1):
			for z in range(center_chunk.z - render_distance, center_chunk.z + render_distance + 1):
				var dist_xz = Vector2(x, z).distance_to(Vector2(center_chunk.x, center_chunk.z))
				if dist_xz > render_distance:
					continue
				
				for y in y_layers:
					if y < MIN_Y_LAYER or y > MAX_Y_LAYER:
						continue
					if chunks_queued_this_frame >= chunks_per_frame_limit:
						return
					
					var coord = Vector3i(x, y, z)
					
					if active_chunks.has(coord):
						continue

					active_chunks[coord] = null
					
					var chunk_pos = Vector3(x * CHUNK_STRIDE, y * CHUNK_STRIDE, z * CHUNK_STRIDE)
					
					var task = {
						"type": "generate",
						"coord": coord,
						"pos": chunk_pos
					}
					
					mutex.lock()
					task_queue.append(task)
					mutex.unlock()
					semaphore.post()
					
					chunks_queued_this_frame += 1

## Interruptible delay - checks for high-priority tasks every 10ms
## Allows player interactions to interrupt chunk loading delays
func _interruptible_delay(total_ms: int):
	var elapsed = 0
	while elapsed < total_ms:
		# Check if there's any task waiting (player interaction pushed to front)
		mutex.lock()
		var has_priority_task = not task_queue.is_empty()
		mutex.unlock()
		
		if has_priority_task:
			return # Stop delaying, process immediately
		
		# Sleep in small chunks
		var sleep_time = min(10, total_ms - elapsed)
		OS.delay_msec(sleep_time)
		elapsed += sleep_time

func _thread_function():
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		return

	var sid_gen = rd.shader_create_from_spirv(shader_gen_spirv)
	var sid_gen_water = rd.shader_create_from_spirv(shader_gen_water_spirv)
	var sid_mod = rd.shader_create_from_spirv(shader_mod_spirv)
	var sid_mesh = rd.shader_create_from_spirv(shader_mesh_spirv)
	
	var pipe_gen = rd.compute_pipeline_create(sid_gen)
	var pipe_gen_water = rd.compute_pipeline_create(sid_gen_water)
	var pipe_mod = rd.compute_pipeline_create(sid_mod)
	var pipe_mesh = rd.compute_pipeline_create(sid_mesh)
	
	# Create REUSABLE Buffers for meshing (9 floats per vertex: pos + normal + color)
	# TERRAIN buffers
	var output_bytes_size = MAX_TRIANGLES * 3 * 9 * 4
	var vertex_buffer_terrain = rd.storage_buffer_create(output_bytes_size)
	var counter_data = PackedByteArray()
	counter_data.resize(4)
	counter_data.encode_u32(0, 0)
	var counter_buffer_terrain = rd.storage_buffer_create(4, counter_data)
	
	# WATER buffers (separate to enable batch dispatching - reduces GPU syncs by 50%)
	var vertex_buffer_water = rd.storage_buffer_create(output_bytes_size)
	var counter_data_w = PackedByteArray()
	counter_data_w.resize(4)
	counter_data_w.encode_u32(0, 0)
	var counter_buffer_water = rd.storage_buffer_create(4, counter_data_w)
	
	# In-flight chunks: dispatched but not yet read back
	var in_flight: Array[Dictionary] = []
	const MAX_IN_FLIGHT = 1 # Limit to prevent GPU overload
	
	while true:
		# 1. Check for new tasks FIRST (prioritize modifications before completing in-flight work)
		semaphore.wait()
		
		mutex.lock()
		if exit_thread:
			mutex.unlock()
			break
			
		if task_queue.is_empty():
			mutex.unlock()
			# Only complete in-flight when no tasks pending
			if in_flight.size() > 0:
				rd.sync()
				for flight_data in in_flight:
					_complete_chunk_readback(rd, flight_data, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, vertex_buffer_water, counter_buffer_water)
				in_flight.clear()
			continue
			
		var task = task_queue.pop_front()
		mutex.unlock()
		
		# 2. Handle task types
		if task.type == "modify":
			# HIGHEST PRIORITY: Process modifications immediately, sync all pending work first
			if in_flight.size() > 0:
				rd.sync()
				for fd in in_flight:
					_complete_chunk_readback(rd, fd, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, vertex_buffer_water, counter_buffer_water)
				in_flight.clear()
			process_modify(rd, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain)
		elif task.type == "generate":
			# Complete any in-flight before starting new generation
			if in_flight.size() > 0:
				rd.sync()
				for flight_data in in_flight:
					_complete_chunk_readback(rd, flight_data, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, vertex_buffer_water, counter_buffer_water)
				in_flight.clear()
			
			# Dispatch all GPU work, NO sync - will be completed next iteration
			var flight_data = _dispatch_chunk_generation(rd, task, sid_gen, sid_gen_water, sid_mod, pipe_gen, pipe_gen_water, pipe_mod)
			if flight_data:
				in_flight.append(flight_data)
				rd.submit() # Submit but don't sync - let GPU work while we process more
				
				# If at max in-flight, immediately complete to avoid GPU buildup
				if in_flight.size() >= MAX_IN_FLIGHT:
					rd.sync()
					for fd in in_flight:
						_complete_chunk_readback(rd, fd, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, vertex_buffer_water, counter_buffer_water)
					in_flight.clear()
					
					# Two-phase loading: fast initial load, then throttled exploration
					if initial_load_phase:
						chunks_loaded_initial += 1
						if chunks_loaded_initial >= initial_load_target_chunks:
							initial_load_phase = false
							DebugManager.log_chunk("Initial load complete! Exploration mode delay=%dms" % exploration_delay_ms)
						# During initial load: minimal or no delay for fast loading
						if initial_load_delay_ms > 0:
							_interruptible_delay(initial_load_delay_ms)
					else:
						# Exploration phase: longer delay to prevent stutters
						# Use interruptible delay so modifications can break through
						_interruptible_delay(exploration_delay_ms)
		elif task.type == "free":
			if task.rid.is_valid():
				rd.free_rid(task.rid)
	
	# Cleanup
	rd.free_rid(vertex_buffer_terrain)
	rd.free_rid(counter_buffer_terrain)
	rd.free_rid(vertex_buffer_water)
	rd.free_rid(counter_buffer_water)
	rd.free_rid(pipe_gen)
	rd.free_rid(pipe_gen_water)
	rd.free_rid(pipe_mod)
	rd.free_rid(pipe_mesh)
	rd.free_rid(sid_gen)
	rd.free_rid(sid_gen_water)
	rd.free_rid(sid_mod)
	rd.free_rid(sid_mesh)
	
	rd.free()

# Dispatch generation work WITHOUT syncing - returns in-flight data for later readback
func _dispatch_chunk_generation(rd: RenderingDevice, task, sid_gen, sid_gen_water, sid_mod, pipe_gen, pipe_gen_water, pipe_mod) -> Dictionary:
	var chunk_pos = task.pos
	var coord = task.coord
	var density_bytes = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4
	var material_bytes = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4 # uint per voxel
	
	# Create density and material buffers (will persist until readback)
	var dens_buf_terrain = rd.storage_buffer_create(density_bytes)
	var dens_buf_water = rd.storage_buffer_create(density_bytes)
	var mat_buf_terrain = rd.storage_buffer_create(material_bytes) # Material IDs
	
	# --- Dispatch Terrain Density (no sync) ---
	var u_density_t = RDUniform.new()
	u_density_t.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density_t.binding = 0
	u_density_t.add_id(dens_buf_terrain)
	
	var u_material_t = RDUniform.new()
	u_material_t.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_material_t.binding = 1
	u_material_t.add_id(mat_buf_terrain)
	
	var set_gen_t = rd.uniform_set_create([u_density_t, u_material_t], sid_gen, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_gen)
	rd.compute_list_bind_uniform_set(list, set_gen_t, 0)
	# Pass 0.0 for road spacing if disabled
	var actual_road_spacing = procedural_road_spacing if procedural_roads_enabled else 0.0
	var push_data_t = PackedFloat32Array([chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0, noise_frequency, terrain_height, actual_road_spacing, procedural_road_width])
	rd.compute_list_set_push_constant(list, push_data_t.to_byte_array(), push_data_t.size() * 4)
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	# NO sync here!
	
	# --- Dispatch Water Density (no sync) ---
	var u_density_w = RDUniform.new()
	u_density_w.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density_w.binding = 0
	u_density_w.add_id(dens_buf_water)
	
	var set_gen_w = rd.uniform_set_create([u_density_w], sid_gen_water, 0)
	list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_gen_water)
	rd.compute_list_bind_uniform_set(list, set_gen_w, 0)
	var push_data_w = PackedFloat32Array([chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0, noise_frequency, water_level, 0.0, 0.0])
	rd.compute_list_set_push_constant(list, push_data_w.to_byte_array(), push_data_w.size() * 4)
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	# NO sync here!
	
	# Apply stored modifications (these need sync, but we batch them)
	mutex.lock()
	var mods_for_chunk = stored_modifications.get(coord, []).duplicate()
	mutex.unlock()
	
	if mods_for_chunk.size() > 0:
		# Debug: show when mods are applied to underground chunks
		# Need to sync before modifications since they read/write density
		rd.submit()
		rd.sync()
		for mod in mods_for_chunk:
			var target_buffer = dens_buf_terrain if mod.layer == 0 else dens_buf_water
			_apply_modification_to_buffer(rd, sid_mod, pipe_mod, target_buffer, mat_buf_terrain, chunk_pos, mod)
	
	# Free uniform sets
	if set_gen_t.is_valid(): rd.free_rid(set_gen_t)
	if set_gen_w.is_valid(): rd.free_rid(set_gen_w)
	
	# Return in-flight data for later readback
	return {
		"coord": coord,
		"chunk_pos": chunk_pos,
		"dens_buf_terrain": dens_buf_terrain,
		"dens_buf_water": dens_buf_water,
		"mat_buf_terrain": mat_buf_terrain
	}

# Complete readback and queue to CPU workers (called after density sync)
# OPTIMIZED: Uses separate buffers for terrain/water to enable batch dispatch with single sync
func _complete_chunk_readback(rd: RenderingDevice, flight_data: Dictionary, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, vertex_buffer_water, counter_buffer_water):
	var coord = flight_data.coord
	var chunk_pos = flight_data.chunk_pos
	var dens_buf_terrain = flight_data.dens_buf_terrain
	var dens_buf_water = flight_data.dens_buf_water
	var mat_buf_terrain = flight_data.mat_buf_terrain
	
	# BATCH DISPATCH: Dispatch BOTH mesh shaders, THEN sync ONCE (reduces GPU stalls by 50%)
	# Terrain mesh (uses material buffer for vertex colors) -> terrain buffers
	var set_mesh_t = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, dens_buf_terrain, mat_buf_terrain, chunk_pos, vertex_buffer_terrain, counter_buffer_terrain)
	
	# Water mesh (uses terrain's material buffer for now) -> water buffers
	var set_mesh_w = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, dens_buf_water, mat_buf_terrain, chunk_pos, vertex_buffer_water, counter_buffer_water)
	
	# SINGLE SYNC for both dispatches (was 2 syncs before!)
	rd.submit()
	rd.sync()
	
	# Readback both meshes (GPU work already complete)
	var vert_floats_terrain = run_gpu_meshing_readback(rd, vertex_buffer_terrain, counter_buffer_terrain, set_mesh_t)
	var vert_floats_water = run_gpu_meshing_readback(rd, vertex_buffer_water, counter_buffer_water, set_mesh_w)
	
	# Readback density for physics
	var cpu_density_bytes_w = rd.buffer_get_data(dens_buf_water)
	var cpu_density_floats_w = cpu_density_bytes_w.to_float32_array()
	var cpu_density_bytes_t = rd.buffer_get_data(dens_buf_terrain)
	var cpu_density_floats_t = cpu_density_bytes_t.to_float32_array()
	
	# Readback material buffer for 3D texture creation
	var cpu_material_bytes = rd.buffer_get_data(mat_buf_terrain)
	
	# Queue to CPU workers for mesh building

	cpu_mutex.lock()
	cpu_task_queue.append({
		"coord": coord,
		"chunk_pos": chunk_pos,
		"vert_floats_terrain": vert_floats_terrain,
		"vert_floats_water": vert_floats_water,
		"cpu_dens_w": cpu_density_floats_w,
		"cpu_dens_t": cpu_density_floats_t,
		"cpu_mat_t": cpu_material_bytes, # Material data for 3D texture
		"dens_buf_terrain": dens_buf_terrain,
		"dens_buf_water": dens_buf_water,
		"mat_buf_terrain": mat_buf_terrain # Material buffer for modify path
	})
	cpu_mutex.unlock()
	cpu_semaphore.post()

# GPU meshing dispatch only - NO sync, returns uniform set for later cleanup
func run_gpu_meshing_dispatch(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer) -> RID:
	# Reset Counter to 0
	var zero_data = PackedByteArray()
	zero_data.resize(4)
	zero_data.encode_u32(0, 0)
	rd.buffer_update(counter_buffer, 0, 4, zero_data)
	
	var u_vert = RDUniform.new()
	u_vert.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_vert.binding = 0
	u_vert.add_id(vertex_buffer)
	
	var u_count = RDUniform.new()
	u_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_count.binding = 1
	u_count.add_id(counter_buffer)
	
	var u_dens = RDUniform.new()
	u_dens.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_dens.binding = 2
	u_dens.add_id(density_buffer)
	
	var u_mat = RDUniform.new()
	u_mat.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_mat.binding = 3
	u_mat.add_id(material_buffer)
	
	var set_mesh = rd.uniform_set_create([u_vert, u_count, u_dens, u_mat], sid_mesh, 0)
	
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mesh)
	rd.compute_list_bind_uniform_set(list, set_mesh, 0)
	
	var push_data = PackedFloat32Array([
		chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0,
		noise_frequency, terrain_height, 0.0, 0.0
	])
	rd.compute_list_set_push_constant(list, push_data.to_byte_array(), push_data.size() * 4)
	
	var groups = CHUNK_SIZE / 8
	rd.compute_list_dispatch(list, groups, groups, groups)
	rd.compute_list_end()
	# NO submit/sync here - caller handles it
	
	return set_mesh

# Readback mesh data AFTER sync has been called
func run_gpu_meshing_readback(rd: RenderingDevice, vertex_buffer, counter_buffer, set_mesh: RID) -> PackedFloat32Array:
	# Read back vertex data
	var count_bytes = rd.buffer_get_data(counter_buffer)
	var tri_count = count_bytes.decode_u32(0)
	
	var vert_floats = PackedFloat32Array()
	if tri_count > 0:
		var total_floats = tri_count * 3 * 9 # 9 floats per vertex: pos(3) + normal(3) + color(3)
		var vert_bytes = rd.buffer_get_data(vertex_buffer, 0, total_floats * 4)
		vert_floats = vert_bytes.to_float32_array()
		
	if set_mesh.is_valid(): rd.free_rid(set_mesh)
	
	return vert_floats

# Legacy function for modify path (still needs sync inline)
func run_gpu_meshing(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer) -> PackedFloat32Array:
	var set_mesh = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer)
	rd.submit()
	rd.sync()
	return run_gpu_meshing_readback(rd, vertex_buffer, counter_buffer, set_mesh)

# CPU Worker Thread - builds meshes and collision shapes (CPU intensive, parallelized)
func _cpu_thread_function():
	while true:
		cpu_semaphore.wait()
		
		mutex.lock()
		var should_exit = exit_thread
		mutex.unlock()
		
		if should_exit:
			break
		
		cpu_mutex.lock()
		if cpu_task_queue.is_empty():
			cpu_mutex.unlock()
			continue
		
		var task = cpu_task_queue.pop_front()
		cpu_mutex.unlock()
		
		# Initialize builder once per task if available
		var builder = null
		if ClassDB.class_exists("MeshBuilder"):
			builder = ClassDB.instantiate("MeshBuilder")

		# Build terrain mesh and collision (CPU intensive)
		var mesh_terrain = null
		var shape_terrain = null
		if task.vert_floats_terrain.size() > 0:
			mesh_terrain = build_mesh(task.vert_floats_terrain, material_terrain)
			
			# Use optimized GDExtension for collision if available
			if builder:
				shape_terrain = builder.build_collision_shape(task.vert_floats_terrain, 9)
			elif mesh_terrain:
				shape_terrain = mesh_terrain.create_trimesh_shape()
		
		# Build water mesh and collision (CPU intensive)
		var mesh_water = null
		var shape_water = null
		if task.vert_floats_water.size() > 0:
			mesh_water = build_mesh(task.vert_floats_water, material_water)
			
			# Use optimized GDExtension for collision if available
			if builder:
				shape_water = builder.build_collision_shape(task.vert_floats_water, 9)
			elif mesh_water:
				shape_water = mesh_water.create_trimesh_shape()
		
		# Package results
		var result_t = {"mesh": mesh_terrain, "shape": shape_terrain}
		var result_w = {"mesh": mesh_water, "shape": shape_water}
		
		# Send to main thread
		call_deferred("complete_generation", task.coord, result_t, task.dens_buf_terrain, result_w, task.dens_buf_water, task.cpu_dens_w, task.cpu_dens_t, task.mat_buf_terrain, task.cpu_mat_t)

# Helper to apply a single modification to a density buffer (used during generation replay)
func _apply_modification_to_buffer(rd: RenderingDevice, sid_mod, pipe_mod, density_buffer: RID, material_buffer: RID, chunk_pos: Vector3, mod: Dictionary):
	var u_density = RDUniform.new()
	u_density.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density.binding = 0
	u_density.add_id(density_buffer)
	
	# Add material buffer binding
	var u_material = RDUniform.new()
	u_material.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_material.binding = 1
	if material_buffer.is_valid():
		u_material.add_id(material_buffer)
	else:
		u_material.add_id(density_buffer) # Fallback
	
	var set_mod = rd.uniform_set_create([u_density, u_material], sid_mod, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mod)
	rd.compute_list_bind_uniform_set(list, set_mod, 0)
	
	var push_data = PackedByteArray()
	push_data.resize(48)
	var buffer = StreamPeerBuffer.new()
	buffer.data_array = push_data
	
	buffer.put_float(chunk_pos.x)
	buffer.put_float(chunk_pos.y)
	buffer.put_float(chunk_pos.z)
	buffer.put_float(0.0)
	
	buffer.put_float(mod.brush_pos.x)
	buffer.put_float(mod.brush_pos.y)
	buffer.put_float(mod.brush_pos.z)
	buffer.put_float(mod.radius)
	
	buffer.put_float(mod.value)
	buffer.put_32(mod.get("shape", 0))
	buffer.put_32(mod.get("material_id", -1)) # Material ID
	buffer.put_float(0.0) # Padding
	
	rd.compute_list_set_push_constant(list, buffer.data_array, buffer.data_array.size())
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	if set_mod.is_valid(): rd.free_rid(set_mod)

func process_modify(rd: RenderingDevice, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, vertex_buffer, counter_buffer):
	var density_buffer = task.rid
	var material_buffer = task.get("material_rid", RID()) # Material buffer from chunk
	var chunk_pos = task.pos
	var layer = task.get("layer", 0)
	var material_id = task.get("material_id", -1)
	DebugManager.log_chunk("process_modify: coord=%s layer=%d value=%.2f mat_id=%d mat_buf_valid=%s dens_buf_valid=%s" % [task.coord, layer, task.value, material_id, material_buffer.is_valid(), density_buffer.is_valid()])

	
	var u_density = RDUniform.new()
	u_density.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density.binding = 0
	u_density.add_id(density_buffer)
	
	# Add material buffer binding
	var u_material = RDUniform.new()
	u_material.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_material.binding = 1
	if material_buffer.is_valid():
		u_material.add_id(material_buffer)
	else:
		u_material.add_id(density_buffer) # Fallback
	
	var set_mod = rd.uniform_set_create([u_density, u_material], sid_mod, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mod)
	rd.compute_list_bind_uniform_set(list, set_mod, 0)
	
	var push_data = PackedByteArray()
	push_data.resize(48)
	var buffer = StreamPeerBuffer.new()
	buffer.data_array = push_data
	
	# For Column shape (type=2), y_min is passed in chunk_offset.w
	var y_min_val = task.get("y_min", 0.0) if task.get("shape", 0) == 2 else 0.0
	
	buffer.put_float(chunk_pos.x)
	buffer.put_float(chunk_pos.y)
	buffer.put_float(chunk_pos.z)
	buffer.put_float(y_min_val) # chunk_offset.w = y_min for Column shape
	
	buffer.put_float(task.brush_pos.x)
	buffer.put_float(task.brush_pos.y)
	buffer.put_float(task.brush_pos.z)
	buffer.put_float(task.radius)
	
	# For Column shape (type=2), y_max is passed in last float
	var y_max_val = task.get("y_max", 0.0) if task.get("shape", 0) == 2 else 0.0
	
	buffer.put_float(task.value)
	buffer.put_32(task.get("shape", 0))
	buffer.put_32(material_id) # Material ID (int32)
	buffer.put_float(y_max_val) # y_max for Column shape
	
	rd.compute_list_set_push_constant(list, buffer.data_array, buffer.data_array.size())
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	if set_mod.is_valid(): rd.free_rid(set_mod)
	
	var material = material_terrain if layer == 0 else material_water
	var result = run_meshing(rd, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, material, vertex_buffer, counter_buffer)
	
	var cpu_density_floats = PackedFloat32Array()
	# Read back density for this layer
	var cpu_density_bytes = rd.buffer_get_data(density_buffer)
	cpu_density_floats = cpu_density_bytes.to_float32_array()
	
	# Read back material buffer for 3D texture recreation
	var cpu_material_bytes = PackedByteArray()
	if material_buffer.is_valid():
		cpu_material_bytes = rd.buffer_get_data(material_buffer)
	
	var b_id = task.get("batch_id", -1)
	var b_count = task.get("batch_count", 1)
	var start_mod_version = task.get("start_mod_version", 0)
	
	call_deferred("complete_modification", task.coord, result, layer, b_id, b_count, cpu_density_floats, cpu_material_bytes, start_mod_version)

var _meshbuilder_logged: bool = false

func build_mesh(data: PackedFloat32Array, material_instance: Material) -> ArrayMesh:
	if data.size() == 0:
		return null
	
	var vertex_count = data.size() / 9 # 9 floats per vertex: pos(3) + normal(3) + color(3)
	
	# Try using GDExtension "MeshBuilder" for extreme speed (10-50x faster)
	if ClassDB.class_exists("MeshBuilder"):
		if not _meshbuilder_logged:
			_meshbuilder_logged = true
			print("[ChunkManager] ✓ MeshBuilder GDExtension LOADED - using fast C++ path")
		var builder = ClassDB.instantiate("MeshBuilder")
		# 9 stride = pos(3) + norm(3) + col(3)
		var mesh = builder.build_mesh_native(data, 9)
		if mesh:
			mesh.surface_set_material(0, material_instance)
			return mesh
	
	# Fallback (slow GDScript path)
	# Pre-allocate arrays
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var colors = PackedColorArray()
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)
	
	# Fill arrays directly (much faster than SurfaceTool)
	for i in range(vertex_count):
		var idx = i * 9
		vertices[i] = Vector3(data[idx], data[idx + 1], data[idx + 2])
		normals[i] = Vector3(data[idx + 3], data[idx + 4], data[idx + 5])
		colors[i] = Color(data[idx + 6], data[idx + 7], data[idx + 8])
	
	# Build ArrayMesh directly
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material_instance)
	
	return mesh

func run_meshing(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, material_instance: Material, vertex_buffer, counter_buffer):
	# Reset Counter to 0
	var zero_data = PackedByteArray()
	zero_data.resize(4)
	zero_data.encode_u32(0, 0)
	rd.buffer_update(counter_buffer, 0, 4, zero_data)
	
	var u_vert = RDUniform.new()
	u_vert.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_vert.binding = 0
	u_vert.add_id(vertex_buffer)
	
	var u_count = RDUniform.new()
	u_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_count.binding = 1
	u_count.add_id(counter_buffer)
	
	var u_dens = RDUniform.new()
	u_dens.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_dens.binding = 2
	u_dens.add_id(density_buffer)
	
	var u_mat = RDUniform.new()
	u_mat.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_mat.binding = 3
	if material_buffer.is_valid():
		u_mat.add_id(material_buffer)
	else:
		# Fallback: use density buffer as placeholder (won't look right but won't crash)
		u_mat.add_id(density_buffer)
	
	var set_mesh = rd.uniform_set_create([u_vert, u_count, u_dens, u_mat], sid_mesh, 0)
	
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mesh)
	rd.compute_list_bind_uniform_set(list, set_mesh, 0)
	
	var push_data = PackedFloat32Array([
		chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0,
		noise_frequency, terrain_height, 0.0, 0.0
	])
	rd.compute_list_set_push_constant(list, push_data.to_byte_array(), push_data.size() * 4)
	
	var groups = CHUNK_SIZE / 8
	rd.compute_list_dispatch(list, groups, groups, groups)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	# Read back
	var count_bytes = rd.buffer_get_data(counter_buffer)
	var tri_count = count_bytes.decode_u32(0)
	
	var mesh = null
	var shape = null
	
	if tri_count > 0:
		var total_floats = tri_count * 3 * 9 # 9 floats per vertex
		var vert_bytes = rd.buffer_get_data(vertex_buffer, 0, total_floats * 4)
		var vert_floats = vert_bytes.to_float32_array()
		mesh = build_mesh(vert_floats, material_instance)
		if mesh:
			shape = mesh.create_trimesh_shape()
		
	if set_mesh.is_valid(): rd.free_rid(set_mesh)
	
	return {"mesh": mesh, "shape": shape}

func complete_generation(coord: Vector3i, result_t: Dictionary, dens_t: RID, result_w: Dictionary, dens_w: RID, cpu_dens_w: PackedFloat32Array, cpu_dens_t: PackedFloat32Array, mat_t: RID = RID(), cpu_mat_t: PackedByteArray = PackedByteArray()):
	if not active_chunks.has(coord):
		var tasks = []
		tasks.append({"type": "free", "rid": dens_t})
		tasks.append({"type": "free", "rid": dens_w})
		if mat_t.is_valid():
			tasks.append({"type": "free", "rid": mat_t})
		mutex.lock()
		for t in tasks: task_queue.append(t)
		mutex.unlock()
		for t in tasks: semaphore.post()
		return
	
	pending_nodes_mutex.lock()
	
	# Split into two separate tasks to spread main-thread load
	# Task 1: Terrain (Heavier - ~4ms)
	# Task 1: Terrain (Heavier ~4ms - NOW ~0ms on Main Thread)
	# Optimize: Create Physics Body ON THREAD to avoid Main Thread spike
	var body_rid = RID()
	var shape_rid = RID()
	
	if result_t.shape:
		# 1. Create Body
		body_rid = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
		
		# 2. Create and Add Shape
		shape_rid = result_t.shape.get_rid() # Get RID from the Shape3D resource
		# Note: We need to keep the Shape3D resource alive or the RID might become invalid if ref count hits 0? 
		# Actually, Shape3D resource holds the RID. As long as we hold 'result_t.shape', it's fine.
		# But wait, we can't share Shape3D RID usage easily if we want to be safe?
		# Actually, 'mesh.create_trimesh_shape()' creates a new ConcavePolygonShape3D.
		
		PhysicsServer3D.body_add_shape(body_rid, shape_rid)
		
		# 3. Set Layer/Mask (Layer 1 = Terrain)
		PhysicsServer3D.body_set_collision_layer(body_rid, 1 | 512)
		PhysicsServer3D.body_set_collision_mask(body_rid, 1)
		
		# 4. Add to Space (The heavy part - Done on Thread!)
		var space = get_world_3d().space
		PhysicsServer3D.body_set_space(body_rid, space)
		
		# 5. Set Position (Chunk Origin)
		var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
		var transform = Transform3D(Basis(), chunk_pos)
		PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, transform)

	pending_nodes.append({
		"type": "final_terrain",
		"coord": coord,
		"result": result_t,
		"dens": dens_t,
		"mat_buf": mat_t,
		"cpu_dens": cpu_dens_t,
		"cpu_mat": cpu_mat_t,
		"body_rid": body_rid # Pass the pre-cooked body
	})
	
	# Task 2: Water (Lighter - ~2ms)
	pending_nodes.append({
		"type": "final_water",
		"coord": coord,
		"result": result_w,
		"dens": dens_w,
		"cpu_dens": cpu_dens_w
	})
	
	pending_nodes_mutex.unlock()

func _finalize_chunk_creation(item: Dictionary):
	if item.type == "final_terrain":
		var start = Time.get_ticks_usec()
		var coord = item.coord
		
		if not active_chunks.has(coord):
			# Cleanup orphan RIDs if chunk was cancelled
			if item.get("body_rid", RID()).is_valid():
				PhysicsServer3D.free_rid(item.body_rid)
			return
			
		var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
		
		# Create Material
		PerformanceMonitor.start_measure("Finalize: Mat")
		var chunk_material = _create_chunk_material(chunk_pos, item.get("cpu_mat", PackedByteArray()))
		PerformanceMonitor.end_measure("Finalize: Mat", 0.1)
		
		# Create Node (VISUALS ONLY)
		PerformanceMonitor.start_measure("Finalize: Node")
		# Pass defer_collision=true to prevent create_chunk_node from creating a StaticBody3D/CollisionShape3D
		var result = create_chunk_node(item.result.mesh, null, chunk_pos, false, chunk_material, true)
		PerformanceMonitor.end_measure("Finalize: Node", 0.1)
		
		# Update Data
		PerformanceMonitor.start_measure("Finalize: Data")
		var data = active_chunks[coord]
		if data == null:
			data = ChunkData.new()
			active_chunks[coord] = data
			
		data.node_terrain = result.node if not result.is_empty() else null
		
		# Link Visual Node to Physics Body (for Raycasts/Interaction)
		var body_rid = item.get("body_rid", RID())
		if body_rid.is_valid() and data.node_terrain:
			# This links the RID to the InstanceID of the visual mesh instance/node
			# So that when raycast hits the RID, we can find the Node.
			PhysicsServer3D.body_attach_object_instance_id(body_rid, data.node_terrain.get_instance_id())
			data.body_rid_terrain = body_rid
		
		# CRITICAL: Keep Shape3D resource alive!
		# If we don't store this, the RefCount goes to 0 -> RID freed -> No Collision
		if item.result.get("shape"):
			data.terrain_shape = item.result.shape
			
		data.density_buffer_terrain = item.dens
		data.material_buffer_terrain = item.get("mat_buf", RID())
		DebugManager.log_chunk("finalize_chunk: coord=%s mat_buf_valid=%s has_mat_buf_key=%s" % [coord, data.material_buffer_terrain.is_valid(), item.has("mat_buf")])
		data.cpu_density_terrain = item.cpu_dens
		data.chunk_material = chunk_material
		data.cpu_material_terrain = item.get("cpu_mat", PackedByteArray())
		
		PerformanceMonitor.end_measure("Finalize: Data", 0.1)
		
		# Spawn Zones
		PerformanceMonitor.start_measure("Finalize: Spawn")
		call_deferred("emit_signal", "chunk_generated", coord, data.node_terrain)
		_check_spawn_zone_readiness(coord)
		PerformanceMonitor.end_measure("Finalize: Spawn", 0.1)
		
		var dt = (Time.get_ticks_usec() - start) / 1000.0
		if dt > 8.0 and DebugManager.LOG_CHUNK: DebugManager.log_chunk("SPIKE Finalize Terrain: %.2f ms" % dt)
		
	# REMOVED: final_collision block - handled in worker thread now!
		
	elif item.type == "final_water":
		var start = Time.get_ticks_usec()
		var coord = item.coord
		
		if not active_chunks.has(coord): return
		var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
		
		# Create Node
		var result = create_chunk_node(item.result.mesh, item.result.shape, chunk_pos, true)
		
		# Update Data
		var data = active_chunks[coord]
		if data == null:
			data = ChunkData.new()
			active_chunks[coord] = data
			
		data.node_water = result.node if not result.is_empty() else null
		data.density_buffer_water = item.dens
		data.cpu_density_water = item.cpu_dens
		
		var dt = (Time.get_ticks_usec() - start) / 1000.0
		if dt > 8.0 and DebugManager.LOG_CHUNK: DebugManager.log_chunk("SPIKE Finalize Water: %.2f ms" % dt)

## Create per-chunk ShaderMaterial with 3D material texture
func _create_chunk_material(chunk_pos: Vector3, cpu_mat: PackedByteArray) -> ShaderMaterial:
	# Clone base material
	var mat = material_terrain.duplicate() as ShaderMaterial
	
	# Set chunk origin for world-space to local-space conversion
	mat.set_shader_parameter("chunk_origin", chunk_pos)
	
	# Create 3D texture from material data if available
	if cpu_mat.size() > 0:
		var tex3d = _create_material_texture_3d(cpu_mat)
		if tex3d:
			mat.set_shader_parameter("material_map", tex3d)
			mat.set_shader_parameter("has_material_map", true)
	
	return mat

## Create ImageTexture3D from material buffer (uint8 per voxel)
func _create_material_texture_3d(cpu_mat: PackedByteArray) -> ImageTexture3D:
	# Material buffer is 33x33x33 uints (4 bytes each)
	# We only need the first byte (material ID 0-255)
	if cpu_mat.size() < DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4:
		return null
	
	# Create array of 2D slices (33 images of 33x33)
	var images: Array[Image] = []
	
	# Check if MeshBuilder is available for fast texture generation
	if ClassDB.class_exists("MeshBuilder"):
		var builder = ClassDB.instantiate("MeshBuilder")
		# Returns ImageTexture3D directly from raw bytes, skipping 35k GDScript calls and binding overheads
		var tex3d = builder.create_material_texture(cpu_mat, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE)
		return tex3d

	# Slow Fallback
	push_warning("GDScript texture fallback used - stutter expected")
	for z in range(DENSITY_GRID_SIZE):
		var img = Image.create(DENSITY_GRID_SIZE, DENSITY_GRID_SIZE, false, Image.FORMAT_R8)
		for y in range(DENSITY_GRID_SIZE):
			for x in range(DENSITY_GRID_SIZE):
				var index = x + (y * DENSITY_GRID_SIZE) + (z * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
				var byte_offset = index * 4 # uint is 4 bytes
				var mat_id = cpu_mat[byte_offset] if byte_offset < cpu_mat.size() else 0
				img.set_pixel(x, y, Color(float(mat_id) / 255.0, 0, 0))
		images.append(img)
	
	# Create 3D texture from image slices
	var tex3d = ImageTexture3D.new()
	tex3d.create(Image.FORMAT_R8, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE, false, images)
	
	return tex3d

func complete_modification(coord: Vector3i, result: Dictionary, layer: int, batch_id: int = -1, batch_count: int = 1, cpu_dens: PackedFloat32Array = PackedFloat32Array(), cpu_mat: PackedByteArray = PackedByteArray(), start_mod_version: int = 0):
	# For non-batched updates, do stale check here
	if batch_id == -1:
		# STALE CHECK for non-batched updates
		if active_chunks.has(coord):
			var chunk_data = active_chunks[coord]
			if chunk_data != null and start_mod_version > 0 and start_mod_version < chunk_data.mod_version:
				DebugManager.log_chunk("STALE: Skipping non-batched update for %s (v%d < v%d)" % [coord, start_mod_version, chunk_data.mod_version])
				return
		_apply_chunk_update(coord, result, layer, cpu_dens, cpu_mat, start_mod_version)
		return
	
	# BATCHED UPDATES: Must track batch counter even for stale updates
	if not pending_batches.has(batch_id):
		pending_batches[batch_id] = {"received": 0, "expected": batch_count, "updates": []}
	
	var batch = pending_batches[batch_id]
	batch.received += 1  # Always increment, even if stale (to complete the batch)
	
	# Only add to updates list if not stale
	var is_stale = false
	if active_chunks.has(coord):
		var chunk_data = active_chunks[coord]
		if chunk_data != null and start_mod_version > 0 and start_mod_version < chunk_data.mod_version:
			DebugManager.log_chunk("STALE: Skipping batched update for %s (v%d < v%d)" % [coord, start_mod_version, chunk_data.mod_version])
			is_stale = true
	
	if not is_stale and active_chunks.has(coord):
		batch.updates.append({"coord": coord, "result": result, "layer": layer, "cpu_dens": cpu_dens, "cpu_mat": cpu_mat, "start_mod_version": start_mod_version})
		
	if batch.received >= batch.expected:
		for update in batch.updates:
			_apply_chunk_update(update.coord, update.result, update.layer, update.cpu_dens, update.get("cpu_mat", PackedByteArray()), update.get("start_mod_version", 0))
		pending_batches.erase(batch_id)

func _apply_chunk_update(coord: Vector3i, result: Dictionary, layer: int, cpu_dens: PackedFloat32Array, cpu_mat: PackedByteArray = PackedByteArray(), start_mod_version: int = 0):
	if not active_chunks.has(coord):
		return
	var data = active_chunks[coord]
	
	# STALE CHECK: Secondary check at application time (for batched updates)
	if data != null and start_mod_version > 0 and start_mod_version < data.mod_version:
		DebugManager.log_chunk("STALE APPLY: Skipping update for %s (v%d < v%d)" % [coord, start_mod_version, data.mod_version])
		return
	
	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
	
	if layer == 0: # Terrain
		# CRITICAL: Free the PhysicsServer body RID first (contains stale collision)
		if data.body_rid_terrain.is_valid():
			PhysicsServer3D.free_rid(data.body_rid_terrain)
			data.body_rid_terrain = RID() # Clear to prevent double-free
		if data.node_terrain: data.node_terrain.queue_free()
		
		# Recreate chunk material with updated 3D texture
		var chunk_material = _create_chunk_material(chunk_pos, cpu_mat)
		
		var result_node = create_chunk_node(result.mesh, result.shape, chunk_pos, false, chunk_material)
		data.node_terrain = result_node.node if not result_node.is_empty() else null
		data.collision_shape_terrain = result_node.collision_shape if not result_node.is_empty() else null
		data.chunk_material = chunk_material
		if not cpu_dens.is_empty():
			data.cpu_density_terrain = cpu_dens
		if not cpu_mat.is_empty():
			data.cpu_material_terrain = cpu_mat
		# Signal vegetation manager that chunk node changed (update references, don't regenerate)
		chunk_modified.emit(coord, data.node_terrain)
	else: # Water
		DebugManager.log_chunk("Applying water update to %s, has_mesh=%s" % [coord, result.mesh != null])
		if data.node_water: data.node_water.queue_free()
		var result_node = create_chunk_node(result.mesh, result.shape, chunk_pos, true)
		data.node_water = result_node.node if not result_node.is_empty() else null
		if not cpu_dens.is_empty():
			data.cpu_density_water = cpu_dens

func create_chunk_node(mesh: ArrayMesh, shape: Shape3D, position: Vector3, is_water: bool = false, custom_material: Material = null, defer_collision: bool = false) -> Dictionary:
	if mesh == null:
		return {}
		
	var node: CollisionObject3D
	
	if is_water:
		node = Area3D.new()
		node.add_to_group("water")
		# Ensure it's monitorable so the player can detect it
		node.monitorable = true
		node.monitoring = false # Terrain chunks don't need to monitor others
	else:
		node = StaticBody3D.new()
		node.collision_layer = 1 | 512 # Terrain layer + Special layer for pickups
		node.add_to_group("terrain")
		
	node.position = position
	
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = mesh
	
	# Apply per-chunk material if provided, otherwise mesh uses its surface material
	if custom_material:
		mesh_instance.material_override = custom_material
	
	# If water, we might want to ensure it's not casting shadows or has specific render flags if needed, 
	# but the material handles most transparency.
	if is_water:
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		
	node.add_child(mesh_instance)
	
	var collision_shape = CollisionShape3D.new()
	if shape:
		collision_shape.shape = shape
	
	if not defer_collision:
		node.add_child(collision_shape)
	
	# Optimization: Add to tree LAST to perform single update
	add_child(node)
	
	# Return both node and collision_shape for tracking
	return {"node": node, "collision_shape": collision_shape}

# ============ SPAWN ZONE API ============
# These methods enable save/load to wait for terrain before spawning players/entities

## Request priority loading of chunks around a spawn position
## The spawn_zones_ready signal will be emitted when all chunks are loaded
func request_spawn_zone(position: Vector3, radius: int = 2):
	var chunk_x = int(floor(position.x / CHUNK_STRIDE))
	var chunk_y = int(floor(position.y / CHUNK_STRIDE))
	var chunk_z = int(floor(position.z / CHUNK_STRIDE))
	
	var pending_coords: Array[Vector3i] = []
	
	# Collect chunks in radius and request generation for any not loaded
	for dx in range(-radius, radius + 1):
		for dy in range(-1, 2): # Only check Y layers -1, 0, +1 around spawn
			for dz in range(-radius, radius + 1):
				var coord = Vector3i(chunk_x + dx, chunk_y + dy, chunk_z + dz)
				
				# Skip if already loaded with data
				if active_chunks.has(coord) and active_chunks[coord] != null:
					continue
				
				# Mark as pending
				if not active_chunks.has(coord):
					active_chunks[coord] = null
					var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
					var task = {
						"type": "generate",
						"coord": coord,
						"pos": chunk_pos
					}
					mutex.lock()
					task_queue.push_front(task) # Priority: push to front
					mutex.unlock()
					semaphore.post()
				
				pending_coords.append(coord)
	
	if pending_coords.is_empty():
		# All chunks already loaded - emit immediately
		call_deferred("emit_signal", "spawn_zones_ready", [position])
	else:
		# Track this spawn zone
		pending_spawn_zones.append({
			"position": position,
			"radius": radius,
			"pending_coords": pending_coords
		})
		DebugManager.log_chunk("SpawnZone requested %d chunks at %s" % [pending_coords.size(), position])

## Check if chunks around a position are ready (loaded with data)
func are_chunks_ready_around(position: Vector3, radius: int = 2) -> bool:
	var chunk_x = int(floor(position.x / CHUNK_STRIDE))
	var chunk_y = int(floor(position.y / CHUNK_STRIDE))
	var chunk_z = int(floor(position.z / CHUNK_STRIDE))
	
	for dx in range(-radius, radius + 1):
		for dy in range(-1, 2):
			for dz in range(-radius, radius + 1):
				var coord = Vector3i(chunk_x + dx, chunk_y + dy, chunk_z + dz)
				# Not loaded or still pending (null)
				if not active_chunks.has(coord) or active_chunks[coord] == null:
					return false
	return true

## Called when a chunk completes generation - checks if any spawn zones are now ready
func _check_spawn_zone_readiness(completed_coord: Vector3i):
	if pending_spawn_zones.is_empty():
		return
	
	var zones_to_remove: Array[int] = []
	var ready_positions: Array[Vector3] = []
	
	for i in range(pending_spawn_zones.size()):
		var zone = pending_spawn_zones[i]
		zone.pending_coords.erase(completed_coord)
		
		if zone.pending_coords.is_empty():
			zones_to_remove.append(i)
			ready_positions.append(zone.position)
	
	# Remove completed zones (reverse order to preserve indices)
	for i in range(zones_to_remove.size() - 1, -1, -1):
		pending_spawn_zones.remove_at(zones_to_remove[i])
	
	# Emit signal if any zones completed
	if not ready_positions.is_empty():
		DebugManager.log_chunk("SpawnZone %d zones ready" % ready_positions.size())
		spawn_zones_ready.emit(ready_positions)

## Request multiple spawn zones at once (for batch loading player + entities)
func request_spawn_zones(positions: Array[Vector3], radius: int = 2):
	for pos in positions:
		request_spawn_zone(pos, radius)
