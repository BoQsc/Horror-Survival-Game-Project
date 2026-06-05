extends CanvasLayer
class_name LoadingScreen
## LoadingScreen - Displays loading progress during game startup
## Tracks visual completion: terrain meshes, buildings, and vegetation

const WorldEventTrace = preload("res://world_performance/world_event_trace.gd")
const LOADING_TRACE_EVENT_LIMIT: int = 96
const SAVE_LOAD_STAGE_WEIGHT: float = 5.0
const TERRAIN_STAGE_START: float = 0.0
const TERRAIN_STAGE_WEIGHT: float = 70.0
const WORLD_CONTENT_STAGE_START: float = 70.0
const WORLD_CONTENT_STAGE_WEIGHT: float = 20.0
const VEGETATION_STAGE_START: float = 90.0
const VEGETATION_STAGE_WEIGHT: float = 10.0
const PROGRESS_TRACE_STEP_PERCENT: float = 5.0

signal loading_complete
signal terrain_ready  # Emitted when terrain/collision is safe for player physics

@onready var panel: PanelContainer = $Panel
@onready var progress_bar: ProgressBar = $Panel/VBox/ProgressBar
@onready var status_label: Label = $Panel/VBox/StatusLabel
@onready var stage_detail_label: Label = $Panel/VBox/StageDetailLabel
@onready var elapsed_time_label: Label = $Panel/VBox/ElapsedTimeLabel

var is_loading: bool = true
var fade_timer: float = 0.0
const FADE_DURATION: float = 0.5
var loading_start_msec: int = 0
var completed_elapsed_seconds: float = 0.0

var has_emitted_terrain_ready: bool = false  # Track if we've signaled player
var save_manager_step: String = ""  # Current step from SaveManager
var save_manager_step_index: int = 0
var save_manager_total_steps: int = 10
var max_progress_percent: float = 0.0
var last_progress_message: String = "Initializing..."
var current_stage_label: String = "Loading save data"
var current_stage_progress_percent: float = 0.0
var current_stage_completed: int = 0
var current_stage_total: int = 0
var current_stage_details: Dictionary = {}
var current_stage_detail_text: String = ""
var failure_message: String = ""
var cancellation_message: String = ""
var _loading_trace = WorldEventTrace.new(LOADING_TRACE_EVENT_LIMIT)
var _last_progress_trace_percent: float = -PROGRESS_TRACE_STEP_PERCENT
var startup_coordinator: Node = null

# Loading stages
enum Stage { SAVE_LOAD, TERRAIN, WORLD_CONTENT, VEGETATION, COMPLETE, FAILED, CANCELLED }
var current_stage: Stage = Stage.SAVE_LOAD

func _ready() -> void:
	# Start visible
	visible = true
	loading_start_msec = Time.get_ticks_msec()
	_loading_trace.begin("loading-screen", {})
	if panel:
		panel.modulate.a = 1.0
	_update_elapsed_time_label()
	
	# Find managers and start monitoring
	_connect_to_startup_coordinator()
	_connect_to_save_manager()
	await get_tree().process_frame
	if startup_coordinator:
		startup_coordinator.ensure_load("loading_screen")
		_sync_from_startup_coordinator()
		startup_coordinator.start_world_startup_monitoring()
	else:
		_start_loading_sequence()


func _connect_to_startup_coordinator() -> void:
	startup_coordinator = get_node_or_null("/root/WorldStartupCoordinator")
	if not startup_coordinator:
		return
	if not startup_coordinator.is_connected("load_started", _on_startup_load_started):
		startup_coordinator.load_started.connect(_on_startup_load_started)
	if not startup_coordinator.is_connected("stage_started", _on_startup_stage_started):
		startup_coordinator.stage_started.connect(_on_startup_stage_started)
	if not startup_coordinator.is_connected("stage_progress", _on_startup_stage_progress):
		startup_coordinator.stage_progress.connect(_on_startup_stage_progress)
	if not startup_coordinator.is_connected("playable_ready", _on_startup_playable_ready):
		startup_coordinator.playable_ready.connect(_on_startup_playable_ready)
	if not startup_coordinator.is_connected("load_completed", _on_startup_load_completed):
		startup_coordinator.load_completed.connect(_on_startup_load_completed)
	if not startup_coordinator.is_connected("load_failed", _on_startup_load_failed):
		startup_coordinator.load_failed.connect(_on_startup_load_failed)
	if not startup_coordinator.is_connected("load_cancelled", _on_startup_load_cancelled):
		startup_coordinator.load_cancelled.connect(_on_startup_load_cancelled)


func _on_startup_load_started(_load_id: String) -> void:
	is_loading = true
	current_stage = Stage.SAVE_LOAD
	max_progress_percent = 0.0
	_reset_stage_status()
	failure_message = ""
	cancellation_message = ""
	has_emitted_terrain_ready = false
	loading_start_msec = Time.get_ticks_msec()
	completed_elapsed_seconds = 0.0
	fade_timer = 0.0
	visible = true
	if panel:
		panel.modulate.a = 1.0
	_sync_from_startup_coordinator()


func _on_startup_stage_started(_load_id: String, stage_id: StringName, label: String, _weight: float) -> void:
	current_stage = _stage_from_id(stage_id)
	_apply_stage_status(current_stage, label, 0.0, 0, 0, {})
	_capture_loading_event("coordinator_stage_started", {
		"stage": str(stage_id),
		"label": label,
		"progress_percent": max_progress_percent
	})
	update_progress(max_progress_percent, label)


func _on_startup_stage_progress(
	_load_id: String,
	stage_id: StringName,
	_completed: int,
	_total: int,
	details: Dictionary
) -> void:
	current_stage = _stage_from_id(stage_id)
	var message := str(details.get("message", "Loading..."))
	if startup_coordinator:
		var snapshot: Dictionary = startup_coordinator.get_snapshot()
		_sync_stage_status_from_coordinator_snapshot(snapshot, stage_id, details)
		update_progress(float(snapshot.get("overall_progress_percent", max_progress_percent)), message)
	else:
		var stage_percent := 0.0
		if _total > 0:
			stage_percent = clampf(float(_completed) / float(_total), 0.0, 1.0) * 100.0
		_apply_stage_status(current_stage, _stage_label(current_stage), stage_percent, _completed, _total, details)


func _on_startup_playable_ready(_load_id: String, _duration_ms: float) -> void:
	if has_emitted_terrain_ready:
		return
	has_emitted_terrain_ready = true
	terrain_ready.emit()


func _on_startup_load_completed(load_id: String, _duration_ms: float) -> void:
	if not is_loading:
		return
	_apply_stage_status(Stage.COMPLETE, _stage_label(Stage.COMPLETE), 100.0, 1, 1, {"message": "World ready!"})
	update_progress(100.0, "World ready!")
	_finish_after_startup_complete.call_deferred(load_id)


func _finish_after_startup_complete(completed_load_id: String) -> void:
	await get_tree().create_timer(0.3).timeout
	if is_loading and (
		not startup_coordinator
		or str(startup_coordinator.get_snapshot().get("load_id", "")) == completed_load_id
	):
		_start_fade_out()


func _on_startup_load_failed(_load_id: String, _stage_id: StringName, message: String) -> void:
	_mark_failed(message)


func _on_startup_load_cancelled(_load_id: String, reason: String) -> void:
	_mark_cancelled(reason)


func _sync_from_startup_coordinator() -> void:
	if not startup_coordinator:
		return
	var snapshot: Dictionary = startup_coordinator.get_snapshot()
	if bool(snapshot.get("cancelled", false)):
		_mark_cancelled(str(snapshot.get("cancellation_reason", "Loading cancelled")))
		return
	if bool(snapshot.get("failed", false)):
		_mark_failed(str(snapshot.get("failure_message", "Loading failed")))
		return
	var stage_id := StringName(str(snapshot.get("current_stage_id", "save_load")))
	current_stage = _stage_from_id(stage_id)
	_sync_stage_status_from_coordinator_snapshot(snapshot, stage_id, {})
	update_progress(
		float(snapshot.get("overall_progress_percent", max_progress_percent)),
		str(snapshot.get("message", last_progress_message))
	)


func _stage_from_id(stage_id: StringName) -> Stage:
	match stage_id:
		&"save_load":
			return Stage.SAVE_LOAD
		&"terrain":
			return Stage.TERRAIN
		&"world_content":
			return Stage.WORLD_CONTENT
		&"vegetation":
			return Stage.VEGETATION
		&"complete":
			return Stage.COMPLETE
	return current_stage

func _connect_to_save_manager() -> void:
	if startup_coordinator:
		return
	if has_node("/root/SaveManager"):
		var sm = get_node("/root/SaveManager")
		if not sm.is_connected("load_completed", _on_save_manager_load_completed):
			sm.load_completed.connect(_on_save_manager_load_completed)
		if sm.has_signal("load_step") and not sm.is_connected("load_step", _on_load_step):
			sm.load_step.connect(_on_load_step)

func _on_save_manager_load_completed(_success: bool, _path: String) -> void:
	if not _success:
		_mark_failed("Load failed")
		return
	# Save data completion is not the same as world readiness. Keep the loading
	# screen alive while terrain/building/vegetation startup gates are active.
	if not is_loading:
		return
	var terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if terrain_manager and is_instance_valid(terrain_manager):
		return
	_start_fade_out()

func _on_load_step(step_name: String, step_index: int, total_steps: int) -> void:
	save_manager_step = step_name
	save_manager_step_index = step_index
	save_manager_total_steps = total_steps
	_capture_loading_event("save_manager_step", {
		"step_name": step_name,
		"step_index": step_index,
		"total_steps": total_steps
	})
	if current_stage == Stage.SAVE_LOAD:
		var step_percent := 0.0
		if total_steps > 0:
			step_percent = clampf(float(step_index) / float(total_steps), 0.0, 1.0) * SAVE_LOAD_STAGE_WEIGHT
		_apply_stage_status(
			Stage.SAVE_LOAD,
			_stage_label(Stage.SAVE_LOAD),
			step_percent / maxf(SAVE_LOAD_STAGE_WEIGHT, 0.001) * 100.0,
			step_index,
			total_steps,
			{
				"message": step_name,
				"step_name": step_name,
				"step_index": step_index,
				"total_steps": total_steps
			}
		)
		update_progress(step_percent, "%s (%d/%d)" % [step_name, step_index, total_steps])

func _start_loading_sequence() -> void:
	var terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	var building_generator = get_tree().root.find_child("BuildingGenerator", true, false)
	var prefab_spawner = get_tree().get_first_node_in_group("prefab_spawner")
	var building_manager = get_tree().get_first_node_in_group("building_manager")
	var vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	
	if not terrain_manager:
		# No terrain manager, hide after short delay
		update_progress(100.0, "Ready!")
		await get_tree().create_timer(0.5).timeout
		_start_fade_out()
		return
	
	# Stage 1: Terrain chunks - wait for VISUAL completion (pending_nodes empty)
	_set_stage(Stage.TERRAIN)
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
				# terrain_ready gates player physics, so wait for collision-safe terrain completion.
				if not has_emitted_terrain_ready:
					terrain_ready.emit()
					has_emitted_terrain_ready = true
				_update_stage_progress(Stage.TERRAIN, 100.0, "Terrain loaded!")
				_set_stage(Stage.WORLD_CONTENT)
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
				
				var pending = 0
				if terrain_manager.has_method("get_pending_nodes_count"):
					pending = terrain_manager.get_pending_nodes_count()
				
				if pending > 0:
					_update_stage_progress(Stage.TERRAIN, progress, "Rendering terrain... (%d pending)" % pending)
				else:
					_update_stage_progress(Stage.TERRAIN, progress, "Loading terrain...")
		
		await get_tree().create_timer(0.1).timeout
	
	# Stage 2: Prefab buildings - poll queue until empty (no timeout)
	if is_loading and current_stage == Stage.WORLD_CONTENT:
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
					_update_stage_progress(Stage.WORLD_CONTENT, percent, "Spawning buildings: %d/%d" % [spawned, initial_queue_size])
					
					await get_tree().create_timer(0.2).timeout

		while is_loading:
			var pending_world_content := _get_pending_world_content_count(prefab_spawner, building_manager)
			if pending_world_content <= 0:
				break
			_update_stage_progress(Stage.WORLD_CONTENT, 95.0, "Spawning buildings: %d pending" % pending_world_content)
			await get_tree().create_timer(0.2).timeout
		
		_update_stage_progress(Stage.WORLD_CONTENT, 100.0, "World content ready!")
		_set_stage(Stage.VEGETATION)
	
	# Stage 3: Vegetation - wait for trees/grass/rocks to spawn
	if is_loading and current_stage == Stage.VEGETATION:
		if vegetation_manager and is_instance_valid(vegetation_manager):
			var is_veg_ready = false
			if vegetation_manager.has_method("is_vegetation_ready"):
				is_veg_ready = vegetation_manager.is_vegetation_ready()
			else:
				is_veg_ready = true # Skip if method not available
			
			if not is_veg_ready:
				_update_stage_progress(Stage.VEGETATION, 25.0, "Placing vegetation...")
				while is_loading:
					if vegetation_manager.has_method("is_vegetation_ready"):
						if vegetation_manager.is_vegetation_ready():
							break
					else:
						break
					
					var pending = 0
					if vegetation_manager.has_method("get_pending_chunks_count"):
						pending = vegetation_manager.get_pending_chunks_count()
					var vegetation_progress := 50.0
					var initial_count := int(vegetation_manager.get("initial_load_count")) if "initial_load_count" in vegetation_manager else 0
					if initial_count > 0:
						vegetation_progress = clampf(100.0 - (float(pending) / float(initial_count)) * 100.0, 25.0, 95.0)
					_update_stage_progress(Stage.VEGETATION, vegetation_progress, "Placing vegetation... (%d chunks)" % pending)
					
					await get_tree().create_timer(0.2).timeout
		
		_set_stage(Stage.COMPLETE)
	
	# Complete
	_apply_stage_status(Stage.COMPLETE, _stage_label(Stage.COMPLETE), 100.0, 1, 1, {"message": "World ready!"})
	update_progress(100.0, "World ready!")
	await get_tree().create_timer(0.3).timeout
	_start_fade_out()

func update_progress(percent: float, message: String) -> void:
	var next_percent := clampf(percent, 0.0, 100.0)
	if next_percent < max_progress_percent:
		next_percent = max_progress_percent
	else:
		max_progress_percent = next_percent
	last_progress_message = message
	if progress_bar:
		progress_bar.value = next_percent
	if status_label:
		status_label.text = message
	_maybe_trace_progress(next_percent, message)
	_update_elapsed_time_label()

func _set_stage(stage: Stage) -> void:
	if current_stage == stage:
		return
	current_stage = stage
	_apply_stage_status(stage, _stage_label(stage), 0.0, 0, 0, {})
	_capture_loading_event("stage_started", {
		"stage": _stage_name(stage),
		"progress_percent": max_progress_percent
	})

func _update_stage_progress(stage: Stage, stage_percent: float, message: String) -> void:
	var absolute_percent := _stage_start(stage) + _stage_weight(stage) * clampf(stage_percent, 0.0, 100.0) / 100.0
	_apply_stage_status(stage, _stage_label(stage), stage_percent, int(round(stage_percent)), 100, {"message": message})
	update_progress(absolute_percent, message)

func _stage_start(stage: Stage) -> float:
	match stage:
		Stage.SAVE_LOAD:
			return 0.0
		Stage.TERRAIN:
			return TERRAIN_STAGE_START
		Stage.WORLD_CONTENT:
			return WORLD_CONTENT_STAGE_START
		Stage.VEGETATION:
			return VEGETATION_STAGE_START
		Stage.COMPLETE:
			return 100.0
		Stage.FAILED:
			return max_progress_percent
		Stage.CANCELLED:
			return max_progress_percent
	return 0.0

func _stage_weight(stage: Stage) -> float:
	match stage:
		Stage.SAVE_LOAD:
			return SAVE_LOAD_STAGE_WEIGHT
		Stage.TERRAIN:
			return TERRAIN_STAGE_WEIGHT
		Stage.WORLD_CONTENT:
			return WORLD_CONTENT_STAGE_WEIGHT
		Stage.VEGETATION:
			return VEGETATION_STAGE_WEIGHT
	return 0.0

func _stage_name(stage: Stage) -> String:
	match stage:
		Stage.SAVE_LOAD:
			return "save_load"
		Stage.TERRAIN:
			return "terrain"
		Stage.WORLD_CONTENT:
			return "world_content"
		Stage.VEGETATION:
			return "vegetation"
		Stage.COMPLETE:
			return "complete"
		Stage.FAILED:
			return "failed"
		Stage.CANCELLED:
			return "cancelled"
	return "unknown"


func _stage_label(stage: Stage) -> String:
	match stage:
		Stage.SAVE_LOAD:
			return "Loading save data"
		Stage.TERRAIN:
			return "Preparing terrain"
		Stage.WORLD_CONTENT:
			return "Preparing world content"
		Stage.VEGETATION:
			return "Placing vegetation"
		Stage.COMPLETE:
			return "World ready"
		Stage.FAILED:
			return "Loading failed"
		Stage.CANCELLED:
			return "Loading cancelled"
	return "Loading"


func _reset_stage_status() -> void:
	current_stage_label = _stage_label(current_stage)
	current_stage_progress_percent = 0.0
	current_stage_completed = 0
	current_stage_total = 0
	current_stage_details.clear()
	current_stage_detail_text = _build_stage_detail_text(current_stage_label, 0.0, 0, 0, {})
	_update_stage_detail_label()


func _sync_stage_status_from_coordinator_snapshot(
	snapshot: Dictionary,
	stage_id: StringName,
	fallback_details: Dictionary = {}
) -> void:
	var label := str(snapshot.get("current_stage_label", ""))
	if label.is_empty():
		label = _stage_label(_stage_from_id(stage_id))
	var details: Dictionary = {}
	var details_variant: Variant = snapshot.get("current_stage_details", {})
	if details_variant is Dictionary and not (details_variant as Dictionary).is_empty():
		details = (details_variant as Dictionary).duplicate(true)
	elif not fallback_details.is_empty():
		details = fallback_details.duplicate(true)
	_apply_stage_status(
		_stage_from_id(stage_id),
		label,
		float(snapshot.get("current_stage_progress_percent", 0.0)),
		int(snapshot.get("current_stage_completed", 0)),
		int(snapshot.get("current_stage_total", 0)),
		details
	)


func _apply_stage_status(
	stage: Stage,
	label: String,
	stage_percent: float,
	completed: int,
	total: int,
	details: Dictionary
) -> void:
	current_stage = stage
	current_stage_label = label if not label.is_empty() else _stage_label(stage)
	current_stage_progress_percent = clampf(stage_percent, 0.0, 100.0)
	current_stage_completed = maxi(completed, 0)
	current_stage_total = maxi(total, 0)
	current_stage_details = details.duplicate(true)
	current_stage_detail_text = _build_stage_detail_text(
		current_stage_label,
		current_stage_progress_percent,
		current_stage_completed,
		current_stage_total,
		current_stage_details
	)
	_update_stage_detail_label()


func _build_stage_detail_text(
	label: String,
	stage_percent: float,
	completed: int,
	total: int,
	details: Dictionary
) -> String:
	var base := ""
	if total > 0:
		base = "%s %.0f%% (%d/%d)" % [label, stage_percent, completed, total]
	else:
		base = "%s %.0f%%" % [label, stage_percent]
	var summary := _build_stage_details_summary(details)
	if summary.is_empty():
		return base
	return "%s | %s" % [base, summary]


func _build_stage_details_summary(details: Dictionary) -> String:
	var parts: Array[String] = []
	var pending := int(details.get("pending", -1))
	var blocking_pending := int(details.get("blocking_component_pending", 0))
	var blocking_component := str(details.get("blocking_component", ""))
	if blocking_pending > 0 and not blocking_component.is_empty():
		_append_stage_detail_part(parts, "blocked by %s (%d)" % [blocking_component, blocking_pending])
	elif pending > 0:
		_append_stage_detail_part(parts, "pending %d" % pending)
	var artifact_restore_queue := int(details.get("artifact_restore_queue_count", 0)) \
		+ int(details.get("completed_artifact_restore_count", 0))
	if artifact_restore_queue > 0:
		_append_stage_detail_part(parts, "restoring artifacts %d" % artifact_restore_queue)
	var generation_queue := int(details.get("generation_queue_count", 0)) \
		+ int(details.get("completed_generated_count", 0))
	if generation_queue > 0:
		_append_stage_detail_part(parts, "generating misses %d" % generation_queue)
	var cpu_mesh_queue := int(details.get("cpu_mesh_queue_count", 0))
	if cpu_mesh_queue > 0:
		_append_stage_detail_part(parts, "meshing %d" % cpu_mesh_queue)
	var cache_hits := int(details.get("artifact_cache_hit_count", 0))
	var cache_misses := int(details.get("artifact_cache_miss_count", 0))
	if cache_hits > 0 or cache_misses > 0:
		_append_stage_detail_part(parts, "cache H/M %d/%d" % [cache_hits, cache_misses])
	var restored_artifacts := int(details.get("artifact_cache_restore_count", 0))
	if restored_artifacts > 0:
		_append_stage_detail_part(parts, "restored %d" % restored_artifacts)
	var disk_hits := int(details.get("artifact_disk_cache_hit_count", 0))
	if disk_hits > 0:
		_append_stage_detail_part(parts, "disk hits %d" % disk_hits)
	var pending_nodes := int(details.get("pending_nodes", 0))
	if pending_nodes > 0:
		_append_stage_detail_part(parts, "terrain nodes %d" % pending_nodes)
	var pending_spawn_zones := int(details.get("pending_spawn_zone_count", 0))
	if pending_spawn_zones > 0:
		_append_stage_detail_part(parts, "spawn zones %d" % pending_spawn_zones)
	var pending_entries := int(details.get("artifact_disk_write_pending_entries", details.get("pending_entries", 0)))
	if pending_entries > 0:
		_append_stage_detail_part(parts, "artifact writes %d" % pending_entries)
	var pending_bytes := int(details.get("artifact_disk_write_pending_bytes", details.get("pending_bytes", 0)))
	if pending_bytes > 0:
		_append_stage_detail_part(parts, "artifact queue %s" % _format_short_bytes(pending_bytes))
	var step_index := int(details.get("step_index", 0))
	var total_steps := int(details.get("total_steps", 0))
	if total_steps > 0:
		_append_stage_detail_part(parts, "step %d/%d" % [step_index, total_steps])
	return ", ".join(parts)


func _append_stage_detail_part(parts: Array[String], text: String) -> void:
	if text.is_empty() or parts.size() >= 3:
		return
	parts.append(text)


func _format_short_bytes(byte_count: int) -> String:
	if byte_count >= 1024 * 1024:
		return "%.1f MiB" % (float(byte_count) / float(1024 * 1024))
	if byte_count >= 1024:
		return "%.1f KiB" % (float(byte_count) / 1024.0)
	return "%d B" % byte_count


func _update_stage_detail_label() -> void:
	if stage_detail_label:
		stage_detail_label.text = current_stage_detail_text


func _mark_failed(message: String) -> void:
	failure_message = message if not message.is_empty() else "Loading failed"
	cancellation_message = ""
	current_stage = Stage.FAILED
	_apply_stage_status(Stage.FAILED, _stage_label(Stage.FAILED), current_stage_progress_percent, 0, 0, {"message": failure_message})
	is_loading = false
	completed_elapsed_seconds = _get_elapsed_seconds()
	update_progress(max_progress_percent, failure_message)
	_capture_loading_event("failed", {
		"message": failure_message,
		"progress_percent": max_progress_percent
	})
	_update_elapsed_time_label()


func _mark_cancelled(reason: String) -> void:
	cancellation_message = reason if not reason.is_empty() else "Loading cancelled"
	failure_message = ""
	current_stage = Stage.CANCELLED
	_apply_stage_status(Stage.CANCELLED, _stage_label(Stage.CANCELLED), current_stage_progress_percent, 0, 0, {"message": cancellation_message})
	is_loading = false
	completed_elapsed_seconds = _get_elapsed_seconds()
	update_progress(max_progress_percent, cancellation_message)
	_capture_loading_event("cancelled", {
		"reason": cancellation_message,
		"progress_percent": max_progress_percent
	})
	_update_elapsed_time_label()


func _capture_loading_event(event_name: String, details: Dictionary = {}) -> void:
	if event_name.is_empty():
		return
	_loading_trace.capture(event_name, details)

func _maybe_trace_progress(percent: float, message: String) -> void:
	if percent < _last_progress_trace_percent + PROGRESS_TRACE_STEP_PERCENT and percent < 100.0:
		return
	_last_progress_trace_percent = percent
	_capture_loading_event("progress", {
		"stage": _stage_name(current_stage),
		"stage_label": current_stage_label,
		"stage_progress_percent": current_stage_progress_percent,
		"progress_percent": percent,
		"message": message,
		"stage_detail": current_stage_detail_text
	})

func get_loading_progress_snapshot() -> Dictionary:
	return {
		"is_loading": is_loading,
		"stage": _stage_name(current_stage),
		"stage_label": current_stage_label,
		"stage_progress_percent": current_stage_progress_percent,
		"stage_completed": current_stage_completed,
		"stage_total": current_stage_total,
		"stage_details": current_stage_details.duplicate(true),
		"stage_detail_text": current_stage_detail_text,
		"progress_percent": max_progress_percent,
		"message": last_progress_message,
		"failure_message": failure_message,
		"cancellation_message": cancellation_message,
		"elapsed_seconds": _get_elapsed_seconds() if is_loading else completed_elapsed_seconds,
		"terrain_ready_emitted": has_emitted_terrain_ready,
		"save_manager_step": save_manager_step,
		"save_manager_step_index": save_manager_step_index,
		"save_manager_total_steps": save_manager_total_steps,
		"startup_coordinator": startup_coordinator.get_snapshot() if startup_coordinator else {},
		"trace": _loading_trace.get_snapshot()
	}

func get_telemetry_snapshot() -> Dictionary:
	return get_loading_progress_snapshot()

func _get_elapsed_seconds() -> float:
	if loading_start_msec <= 0:
		return 0.0
	return max(0.0, float(Time.get_ticks_msec() - loading_start_msec) / 1000.0)

func _update_elapsed_time_label() -> void:
	if not elapsed_time_label:
		return
	var seconds: float = completed_elapsed_seconds
	if is_loading or seconds <= 0.0:
		seconds = _get_elapsed_seconds()
	if is_loading:
		elapsed_time_label.text = "Elapsed: %.1fs" % seconds
	elif current_stage == Stage.FAILED:
		elapsed_time_label.text = "Failed after %.1fs" % seconds
	elif current_stage == Stage.CANCELLED:
		elapsed_time_label.text = "Cancelled after %.1fs" % seconds
	else:
		elapsed_time_label.text = "Loaded in %.1fs" % seconds

func _get_startup_readiness_snapshot(manager: Node) -> Dictionary:
	if not manager or not is_instance_valid(manager) or not manager.has_method("get_startup_readiness_snapshot"):
		return {}
	var snapshot_variant: Variant = manager.get_startup_readiness_snapshot()
	if not (snapshot_variant is Dictionary):
		return {}
	return (snapshot_variant as Dictionary).duplicate(true)

func _get_snapshot_pending(snapshot: Dictionary) -> int:
	var pending := maxi(int(snapshot.get("pending", 0)), 0)
	if not bool(snapshot.get("ready", pending <= 0)) and pending <= 0:
		pending = 1
	return pending

func _get_pending_world_content_count(prefab_spawner: Node, building_manager: Node) -> int:
	var pending := 0
	if prefab_spawner and is_instance_valid(prefab_spawner):
		var prefab_snapshot := _get_startup_readiness_snapshot(prefab_spawner)
		if not prefab_snapshot.is_empty():
			pending += _get_snapshot_pending(prefab_snapshot)
		else:
			if prefab_spawner.has_method("has_pending_spawn_jobs") and prefab_spawner.has_pending_spawn_jobs():
				pending += 1
			if prefab_spawner.has_method("has_pending_world_map_baked_payload_jobs") and prefab_spawner.has_pending_world_map_baked_payload_jobs():
				pending += 1
	if building_manager and is_instance_valid(building_manager):
		var building_snapshot := _get_startup_readiness_snapshot(building_manager)
		if not building_snapshot.is_empty():
			pending += _get_snapshot_pending(building_snapshot)
		else:
			if building_manager.has_method("has_pending_world_map_baked_object_spawns") and building_manager.has_pending_world_map_baked_object_spawns():
				pending += 1
			if building_manager.has_method("has_dirty_global_visual_batches") and building_manager.has_dirty_global_visual_batches():
				pending += 1
			if building_manager.has_method("has_dirty_visible_chunks") and building_manager.has_dirty_visible_chunks():
				pending += 1
	var entity_manager := get_tree().get_first_node_in_group("entity_manager")
	var entity_snapshot := _get_startup_readiness_snapshot(entity_manager)
	if not entity_snapshot.is_empty():
		pending += _get_snapshot_pending(entity_snapshot)
	return pending

func _start_fade_out() -> void:
	is_loading = false
	completed_elapsed_seconds = _get_elapsed_seconds()
	_set_stage(Stage.COMPLETE)
	_apply_stage_status(Stage.COMPLETE, _stage_label(Stage.COMPLETE), 100.0, 1, 1, {"message": "World ready!"})
	_update_elapsed_time_label()
	fade_timer = FADE_DURATION
	_capture_loading_event("complete", {
		"elapsed_seconds": completed_elapsed_seconds
	})
	loading_complete.emit()

func _process(delta: float) -> void:
	if is_loading:
		_update_elapsed_time_label()
		return
	if fade_timer > 0:
		fade_timer -= delta
		if panel:
			panel.modulate.a = fade_timer / FADE_DURATION
		if fade_timer <= 0:
			visible = false
			queue_free()  # Remove from scene when done
