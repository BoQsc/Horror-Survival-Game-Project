extends CanvasLayer
class_name LoadingScreen
## LoadingScreen - Displays loading progress during game startup
## Shows progress bar and current loading step in corner

@onready var panel: PanelContainer = $Panel
@onready var progress_bar: ProgressBar = $Panel/VBox/ProgressBar
@onready var status_label: Label = $Panel/VBox/StatusLabel

var is_loading: bool = true
var fade_timer: float = 0.0
const FADE_DURATION: float = 0.5

# Loading stages
enum Stage { TERRAIN, PREFABS, COMPLETE }
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
	
	if not terrain_manager:
		# No terrain manager, hide after short delay
		update_progress(100.0, "Ready!")
		await get_tree().create_timer(0.5).timeout
		_start_fade_out()
		return
	
	# Stage 1: Terrain chunks (vegetation loads automatically with terrain)
	current_stage = Stage.TERRAIN
	while is_loading and current_stage == Stage.TERRAIN:
		if terrain_manager and is_instance_valid(terrain_manager):
			var initial_phase = terrain_manager.get("initial_load_phase")
			var chunks_loaded = terrain_manager.get("chunks_loaded_initial")
			var target_chunks = terrain_manager.get("initial_load_target_chunks")
			
			if initial_phase == false:
				# Terrain loading complete, move to next stage
				update_progress(100.0, "Terrain loaded!")
				current_stage = Stage.PREFABS
				break
			elif target_chunks != null and target_chunks > 0:
				var percent = (float(chunks_loaded) / float(target_chunks)) * 100.0
				update_progress(percent, "Loading terrain: %d/%d" % [chunks_loaded, target_chunks])
		
		await get_tree().create_timer(0.1).timeout
	
	# Stage 2: Prefab buildings (poll queue until empty or timeout)
	if is_loading and current_stage == Stage.PREFABS:
		if building_generator and is_instance_valid(building_generator):
			var initial_queue_size = building_generator.get("spawn_queue")
			if initial_queue_size is Array:
				initial_queue_size = initial_queue_size.size()
			else:
				initial_queue_size = 0
			
			if initial_queue_size > 0:
				var timeout = 5.0  # Max wait time
				var elapsed = 0.0
				while is_loading and elapsed < timeout:
					var queue = building_generator.get("spawn_queue")
					var remaining = queue.size() if queue is Array else 0
					
					if remaining == 0:
						break
					
					var spawned = initial_queue_size - remaining
					var percent = (float(spawned) / float(initial_queue_size)) * 100.0
					update_progress(percent, "Spawning buildings: %d/%d" % [spawned, initial_queue_size])
					
					await get_tree().create_timer(0.2).timeout
					elapsed += 0.2
		
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

func _process(delta: float) -> void:
	if not is_loading and fade_timer > 0:
		fade_timer -= delta
		if panel:
			panel.modulate.a = fade_timer / FADE_DURATION
		if fade_timer <= 0:
			visible = false
			queue_free()  # Remove from scene when done
