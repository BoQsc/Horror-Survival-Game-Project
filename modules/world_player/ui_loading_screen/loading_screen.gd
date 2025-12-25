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

func _ready() -> void:
	# Start visible
	visible = true
	if panel:
		panel.modulate.a = 1.0
	
	# Find terrain manager and connect to its signals
	await get_tree().process_frame
	var terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if terrain_manager:
		# Connect to loading progress if signal exists
		if terrain_manager.has_signal("loading_progress"):
			terrain_manager.loading_progress.connect(_on_loading_progress)
		
		# Poll for loading state if no signal
		_start_polling(terrain_manager)
	else:
		# No terrain manager, hide after short delay
		await get_tree().create_timer(1.0).timeout
		_start_fade_out()

func _start_polling(terrain_manager) -> void:
	# Poll initial_load_phase from chunk_manager
	while is_loading:
		if terrain_manager and is_instance_valid(terrain_manager):
			var initial_phase = terrain_manager.get("initial_load_phase")
			var chunks_loaded = terrain_manager.get("chunks_loaded_initial")
			var target_chunks = terrain_manager.get("initial_load_target_chunks")
			
			if initial_phase == false:
				# Loading complete
				update_progress(100.0, "Loading complete!")
				await get_tree().create_timer(0.5).timeout
				_start_fade_out()
				return
			elif target_chunks != null and target_chunks > 0:
				var percent = (float(chunks_loaded) / float(target_chunks)) * 100.0
				update_progress(percent, "Loading terrain: %d/%d chunks" % [chunks_loaded, target_chunks])
		
		await get_tree().create_timer(0.1).timeout

func _on_loading_progress(percent: float, message: String) -> void:
	update_progress(percent, message)
	if percent >= 100.0:
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
