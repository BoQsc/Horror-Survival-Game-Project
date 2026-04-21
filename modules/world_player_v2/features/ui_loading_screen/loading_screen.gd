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
var save_manager_completed: bool = false
const FADE_DURATION: float = 0.5
const TOPMOST_CANVAS_LAYER: int = 4096
const TERRAIN_STAGE_FULL_GRACE_MS: int = 1000
const TERRAIN_STAGE_MAX_WAIT_MS: int = 15000
const BUILDING_STAGE_MAX_WAIT_MS: int = 15000
const MIN_STAGE_VISUAL_HOLD_MS: int = 500

var has_emitted_terrain_ready: bool = false  # Track if we've signaled player
var save_manager_step: String = ""  # Current step from SaveManager
var save_manager_step_index: int = 0
var save_manager_total_steps: int = 10

# Loading stages
enum Stage { TERRAIN, PREFABS, VEGETATION, COMPLETE }
var current_stage: Stage = Stage.TERRAIN

func _ready() -> void:
	# Start visible
	visible = true
	layer = maxi(layer, TOPMOST_CANVAS_LAYER)
	process_mode = Node.PROCESS_MODE_ALWAYS
	if panel:
		panel.modulate.a = 1.0
	
	# Find managers and start monitoring
	_connect_to_save_manager()
	await get_tree().process_frame
	_start_loading_sequence()

func _connect_to_save_manager() -> void:
	if has_node("/root/SaveManager"):
		var sm = get_node("/root/SaveManager")
		if not sm.is_connected("load_completed", _on_save_manager_load_completed):
			sm.load_completed.connect(_on_save_manager_load_completed)
		if sm.has_signal("load_step") and not sm.is_connected("load_step", _on_load_step):
			sm.load_step.connect(_on_load_step)

func _on_save_manager_load_completed(_success: bool, _path: String) -> void:
	# SaveManager completion is only a readiness hint. Let this screen finish
	# its own terrain / prefab / vegetation sequence so the user can actually
	# see the staged loading progress.
	save_manager_completed = true

func _on_load_step(step_name: String, step_index: int, total_steps: int) -> void:
	save_manager_step = step_name
	save_manager_step_index = step_index
	save_manager_total_steps = total_steps
	# Update display with step info
	var step_percent = (float(step_index) / float(total_steps)) * 100.0
	update_progress(step_percent, "%s (%d/%d)" % [step_name, step_index, total_steps])

func _start_loading_sequence() -> void:
	var terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	var save_manager = get_node_or_null("/root/SaveManager")
	var building_generator = get_tree().root.find_child("BuildingGenerator", true, false)
	var building_manager = get_tree().root.find_child("BuildingManager", true, false)
	var prefab_spawner = get_tree().root.find_child("PrefabSpawner", true, false)
	var vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	var terrain_stage_started_ms := Time.get_ticks_msec()
	var terrain_stage_full_since_ms := -1
	
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
				print("[LoadingScreen] Terrain stage complete")
				await _hold_stage_visible(terrain_stage_started_ms)
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

				var now_ms := Time.get_ticks_msec()
				if progress >= 99.9:
					if terrain_stage_full_since_ms < 0:
						terrain_stage_full_since_ms = now_ms
					var full_elapsed_ms := now_ms - terrain_stage_full_since_ms
					var stage_elapsed_ms := now_ms - terrain_stage_started_ms
					if full_elapsed_ms >= TERRAIN_STAGE_FULL_GRACE_MS or stage_elapsed_ms >= TERRAIN_STAGE_MAX_WAIT_MS:
						update_progress(100.0, "Terrain loaded!")
						print("[LoadingScreen] Terrain stage complete")
						await _hold_stage_visible(terrain_stage_started_ms)
						current_stage = Stage.PREFABS
						break
				else:
					terrain_stage_full_since_ms = -1
				
				var pending = 0
				if terrain_manager.has_method("get_pending_nodes_count"):
					pending = terrain_manager.get_pending_nodes_count()
				
				if pending > 0:
					update_progress(progress, "Rendering terrain... (%d pending)" % pending)
				else:
					update_progress(progress, "Loading terrain...")
		
		await get_tree().create_timer(0.1).timeout
	
	# Stage 2: Buildings - wait for the actual building work to settle.
	if is_loading and current_stage == Stage.PREFABS:
		var prefab_stage_started_ms := Time.get_ticks_msec()
		var initial_queue_size := 0
		if building_generator and is_instance_valid(building_generator):
			var queue: Variant = building_generator.get("spawn_queue")
			if queue is Array:
				initial_queue_size = queue.size()

		while is_loading and current_stage == Stage.PREFABS:
			var building_pending := _has_pending_building_stage_work(save_manager, building_manager, prefab_spawner, building_generator)
			if not building_pending:
				update_progress(100.0, "Buildings loaded!")
				print("[LoadingScreen] Buildings stage complete")
				await _hold_stage_visible(prefab_stage_started_ms)
				current_stage = Stage.VEGETATION
				break

			var now_ms := Time.get_ticks_msec()
			var stage_elapsed_ms := now_ms - prefab_stage_started_ms
			if stage_elapsed_ms >= BUILDING_STAGE_MAX_WAIT_MS:
				push_warning("[LoadingScreen] Buildings stage timed out, continuing")
				update_progress(100.0, "Buildings loaded!")
				print("[LoadingScreen] Buildings stage complete")
				await _hold_stage_visible(prefab_stage_started_ms)
				current_stage = Stage.VEGETATION
				break

			var percent := min(99.0, float(stage_elapsed_ms) / float(BUILDING_STAGE_MAX_WAIT_MS) * 100.0)
			var message := "Loading buildings..."
			if initial_queue_size > 0 and building_generator and is_instance_valid(building_generator):
				var queue: Variant = building_generator.get("spawn_queue")
				var remaining := initial_queue_size
				if queue is Array:
					remaining = queue.size()
				var spawned := maxi(0, initial_queue_size - remaining)
				if remaining > 0:
					percent = clamp((float(spawned) / float(initial_queue_size)) * 100.0, 0.0, 99.0)
					message = "Spawning buildings: %d/%d" % [spawned, initial_queue_size]
			if save_manager and bool(save_manager.get("awaiting_buildings_ready")):
				message = "Waiting for buildings..."
			update_progress(percent, message)
			await get_tree().create_timer(0.2).timeout
	
	if is_loading and current_stage == Stage.VEGETATION:
		var vegetation_stage_started_ms := Time.get_ticks_msec()
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
		update_progress(100.0, "Vegetation loaded!")
		print("[LoadingScreen] Vegetation stage complete")
		await _hold_stage_visible(vegetation_stage_started_ms)
		
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

func _hold_stage_visible(stage_started_ms: int) -> void:
	var elapsed_ms := Time.get_ticks_msec() - stage_started_ms
	if elapsed_ms < MIN_STAGE_VISUAL_HOLD_MS:
		await get_tree().create_timer(float(MIN_STAGE_VISUAL_HOLD_MS - elapsed_ms) / 1000.0).timeout
	else:
		await get_tree().process_frame

func _has_pending_building_stage_work(save_manager: Node, building_manager: Node, prefab_spawner: Node, building_generator: Node) -> bool:
	if save_manager and is_instance_valid(save_manager) and bool(save_manager.get("awaiting_buildings_ready")):
		return true
	if building_manager and is_instance_valid(building_manager):
		if building_manager.has_method("has_pending_visible_baked_building_work") and building_manager.has_pending_visible_baked_building_work():
			return true
		if building_manager.has_method("has_pending_building_work") and building_manager.has_pending_building_work():
			return true
		if building_manager.has_method("has_pending_visual_batch_work") and building_manager.has_pending_visual_batch_work():
			return true
	if prefab_spawner and is_instance_valid(prefab_spawner) and prefab_spawner.has_method("has_pending_spawn_jobs") and prefab_spawner.has_pending_spawn_jobs():
		return true
	if building_generator:
		var spawn_queue: Variant = building_generator.get("spawn_queue")
		if spawn_queue is Array and not spawn_queue.is_empty():
			return true
	return false

func _process(delta: float) -> void:
	if not is_loading and fade_timer > 0:
		fade_timer -= delta
		if panel:
			panel.modulate.a = fade_timer / FADE_DURATION
		if fade_timer <= 0:
			visible = false
			queue_free()  # Remove from scene when done
