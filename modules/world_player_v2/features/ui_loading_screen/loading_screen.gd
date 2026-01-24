extends CanvasLayer
class_name LoadingScreen
## LoadingScreen - Displays loading progress during game startup
## Tracks visual completion: terrain meshes, buildings, and vegetation

signal loading_complete
signal terrain_ready  # Emitted when terrain meshes are loaded (before vegetation/buildings)

@onready var panel: PanelContainer = $Panel
@onready var progress_bar: ProgressBar = $Panel/VBox/ProgressBar
@onready var status_label: Label = $Panel/VBox/StatusLabel

var is_loading: bool = true
var fade_timer: float = 0.0
const FADE_DURATION: float = 0.5

var has_emitted_terrain_ready: bool = false  # Track if we've signaled player

# Loading stages
enum Stage { TERRAIN, PREFABS, VEGETATION, COMPLETE }
var current_stage: Stage = Stage.TERRAIN

func _ready() -> void:
	# Start visible
	visible = true
	if panel:
		panel.modulate.a = 1.0
	
	# Find managers and start monitoring
	await get_tree().process_frame
	_start_loading_sequence()

func _start_loading_sequence() -> void:
	var terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	var building_generator = get_tree().root.find_child("BuildingGenerator", true, false)
	var vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	
	if not terrain_manager:
		# No terrain manager, hide after short delay
		update_progress(100.0, "Ready!")
		await get_tree().create_timer(0.5).timeout
		_start_fade_out()
		return
	
	# Stage 1: Terrain chunks - wait for VISUAL completion (pending_nodes empty)
	current_stage = Stage.TERRAIN
	while is_loading and current_stage == Stage.TERRAIN:
		if terrain_manager and is_instance_valid(terrain_manager):
			# Use new helper methods if available
			var is_complete = false
			if terrain_manager.has_method("is_initial_load_complete"):
				is_complete = terrain_manager.is_initial_load_complete()
			else:
				# Fallback to old method
				is_complete = terrain_manager.get("initial_load_phase") == false
			
			if is_complete:
				# Terrain visually complete, move to next stage
				update_progress(100.0, "Terrain loaded!")
				current_stage = Stage.PREFABS
				break
			else:
				# Show progress
				var progress = 0.0
				if terrain_manager.has_method("get_loading_progress"):
					progress = terrain_manager.get_loading_progress() * 100.0
				else:
					var chunks_loaded = terrain_manager.get("chunks_loaded_initial")
					var target = terrain_manager.get("initial_load_target_chunks")
					if target != null and target > 0:
						progress = (float(chunks_loaded) / float(target)) * 100.0
				
				# Emit terrain_ready as soon as first chunks start rendering
				if progress > 0 and not has_emitted_terrain_ready:
					terrain_ready.emit()
					has_emitted_terrain_ready = true
					print("[LoadingScreen] Terrain rendering started - player can move")
				
				var pending = 0
				if terrain_manager.has_method("get_pending_nodes_count"):
					pending = terrain_manager.get_pending_nodes_count()
				
				if pending > 0:
					update_progress(progress, "Rendering terrain... (%d pending)" % pending)
				else:
					update_progress(progress, "Loading terrain...")
		
		await get_tree().create_timer(0.1).timeout
	
	# Stage 2: Prefab buildings - poll queue until empty (no timeout)
	if is_loading and current_stage == Stage.PREFABS:
		if building_generator and is_instance_valid(building_generator):
			var queue = building_generator.get("spawn_queue")
			var initial_queue_size = queue.size() if queue is Array else 0
			
			if initial_queue_size > 0:
				while is_loading:
					queue = building_generator.get("spawn_queue")
					var remaining = queue.size() if queue is Array else 0
					
					if remaining == 0:
						break
					
					var spawned = initial_queue_size - remaining
					var percent = (float(spawned) / float(initial_queue_size)) * 100.0
					update_progress(percent, "Spawning buildings: %d/%d" % [spawned, initial_queue_size])
					
					await get_tree().create_timer(0.2).timeout
		
		current_stage = Stage.VEGETATION
	
	# Stage 3: Vegetation - wait for trees/grass/rocks to spawn
	if is_loading and current_stage == Stage.VEGETATION:
		if vegetation_manager and is_instance_valid(vegetation_manager):
			var is_veg_ready = false
			if vegetation_manager.has_method("is_vegetation_ready"):
				is_veg_ready = vegetation_manager.is_vegetation_ready()
			else:
				is_veg_ready = true # Skip if method not available
			
			if not is_veg_ready:
				update_progress(50.0, "Placing vegetation...")
				while is_loading:
					if vegetation_manager.has_method("is_vegetation_ready"):
						if vegetation_manager.is_vegetation_ready():
							break
					else:
						break
					
					var pending = 0
					if vegetation_manager.has_method("get_pending_chunks_count"):
						pending = vegetation_manager.get_pending_chunks_count()
					update_progress(50.0, "Placing vegetation... (%d chunks)" % pending)
					
					await get_tree().create_timer(0.2).timeout
		
		current_stage = Stage.COMPLETE
	
	# Complete
	update_progress(100.0, "World ready!")
	await get_tree().create_timer(0.3).timeout
	_start_fade_out()

func update_progress(percent: float, message: String) -> void:
	if progress_bar:
		progress_bar.value = percent
	if status_label:
		status_label.text = message

func _start_fade_out() -> void:
	is_loading = false
	fade_timer = FADE_DURATION
	loading_complete.emit()

func _process(delta: float) -> void:
	if not is_loading and fade_timer > 0:
		fade_timer -= delta
		if panel:
			panel.modulate.a = fade_timer / FADE_DURATION
		if fade_timer <= 0:
			visible = false
			queue_free()  # Remove from scene when done
