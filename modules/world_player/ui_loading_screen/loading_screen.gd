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
enum Stage {TERRAIN, VEGETATION, COMPLETE}
var current_stage: Stage = Stage.TERRAIN

func _ready() -> void:
	# Start visible
	visible = true
	if panel:
		panel.modulate.a = 1.0
	
	# Find terrain manager and start monitoring
	await get_tree().process_frame
	_start_loading_sequence()

func _start_loading_sequence() -> void:
	var terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	var vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	
	if not terrain_manager:
		# No terrain manager, hide after short delay
		update_progress(100.0, "Ready!")
		await get_tree().create_timer(0.5).timeout
		_start_fade_out()
		return
	
	# Stage 1: Terrain chunks
	current_stage = Stage.TERRAIN
	while is_loading and current_stage == Stage.TERRAIN:
		if terrain_manager and is_instance_valid(terrain_manager):
			var initial_phase = terrain_manager.get("initial_load_phase")
			var chunks_loaded = terrain_manager.get("chunks_loaded_initial")
			var target_chunks = terrain_manager.get("initial_load_target_chunks")
			
			if initial_phase == false:
				# Terrain loading complete, move to next stage
				update_progress(100.0, "Terrain loaded!")
				await get_tree().create_timer(0.3).timeout
				current_stage = Stage.VEGETATION
				break
			elif target_chunks != null and target_chunks > 0:
				var percent = (float(chunks_loaded) / float(target_chunks)) * 100.0
				update_progress(percent, "Loading terrain: %d/%d" % [chunks_loaded, target_chunks])
		
		await get_tree().create_timer(0.1).timeout
	
	# Stage 2: Vegetation (happens automatically with terrain, just show brief status)
	if is_loading and current_stage == Stage.VEGETATION:
		update_progress(0.0, "Generating vegetation...")
		await get_tree().create_timer(0.2).timeout
		update_progress(33.0, "Placing trees...")
		await get_tree().create_timer(0.2).timeout
		update_progress(66.0, "Growing grass...")
		await get_tree().create_timer(0.2).timeout
		update_progress(100.0, "Scattering rocks...")
		await get_tree().create_timer(0.2).timeout
		current_stage = Stage.COMPLETE
	
	# Complete
	update_progress(100.0, "World ready!")
	await get_tree().create_timer(0.5).timeout
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
			queue_free() # Remove from scene when done
