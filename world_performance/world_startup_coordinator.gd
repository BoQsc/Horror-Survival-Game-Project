extends Node
## Owns startup stage state, readiness monitoring, and loading progress signals.

const WorldEventTrace = preload("res://world_performance/world_event_trace.gd")
const TRACE_EVENT_LIMIT: int = 128
const STAGE_ORDER: Array[StringName] = [
	&"save_load",
	&"terrain",
	&"world_content",
	&"vegetation",
	&"complete"
]
const STAGE_DEFINITIONS: Dictionary = {
	&"save_load": {"label": "Loading save data", "weight": 5.0},
	&"terrain": {"label": "Preparing terrain", "weight": 65.0},
	&"world_content": {"label": "Preparing world content", "weight": 20.0},
	&"vegetation": {"label": "Placing vegetation", "weight": 10.0},
	&"complete": {"label": "World ready", "weight": 0.0}
}

signal load_started(load_id: String)
signal stage_started(load_id: String, stage_id: StringName, label: String, weight: float)
signal stage_progress(load_id: String, stage_id: StringName, completed: int, total: int, details: Dictionary)
signal stage_completed(load_id: String, stage_id: StringName, duration_ms: float, details: Dictionary)
signal playable_ready(load_id: String, duration_ms: float)
signal load_completed(load_id: String, duration_ms: float)
signal load_failed(load_id: String, stage_id: StringName, message: String)
signal load_cancelled(load_id: String, reason: String)

@export_range(0.05, 1.0, 0.05) var terrain_poll_interval_s: float = 0.1
@export_range(0.05, 1.0, 0.05) var world_content_poll_interval_s: float = 0.2
@export_range(0.05, 1.0, 0.05) var vegetation_poll_interval_s: float = 0.2
@export_range(5.0, 600.0, 5.0) var stage_timeout_s: float = 120.0

var _load_id: String = ""
var _load_started_usec: int = 0
var _active: bool = false
var _failed: bool = false
var _cancelled: bool = false
var _playable_ready_emitted: bool = false
var _world_monitor_running: bool = false
var _world_monitor_completed: bool = false
var _external_completion_requested: bool = false
var _monitor_token: int = 0
var _current_stage_id: StringName = &""
var _overall_progress_percent: float = 0.0
var _last_message: String = "Initializing..."
var _failure_message: String = ""
var _cancellation_reason: String = ""
var _cancellation_details: Dictionary = {}
var _last_cancellation: Dictionary = {}
var _stage_states: Dictionary = {}
var _completion_details: Dictionary = {}
var _trace = WorldEventTrace.new(TRACE_EVENT_LIMIT)


func _ready() -> void:
	add_to_group("world_startup_coordinator")
	set_process(false)


func begin_load(requested_load_id: String = "", details: Dictionary = {}) -> String:
	var next_load_id := requested_load_id if not requested_load_id.is_empty() else "world-startup-%d" % Time.get_ticks_usec()
	if _active:
		cancel_load("superseded", {"replacement_load_id": next_load_id})
	_monitor_token += 1
	_load_id = next_load_id
	_load_started_usec = Time.get_ticks_usec()
	_active = true
	_failed = false
	_cancelled = false
	_playable_ready_emitted = false
	_world_monitor_running = false
	_world_monitor_completed = false
	_external_completion_requested = false
	_current_stage_id = &""
	_overall_progress_percent = 0.0
	_last_message = "Initializing..."
	_failure_message = ""
	_cancellation_reason = ""
	_cancellation_details = {}
	_completion_details = {}
	_reset_stage_states()
	_trace.begin(_load_id, details)
	_trace.capture("load_started", details)
	load_started.emit(_load_id)
	return _load_id


func ensure_load(source: String = "world_startup") -> String:
	if not _load_id.is_empty() and (_active or _failed or _cancelled):
		return _load_id
	return begin_load("", {"source": source})


func start_stage(
	stage_id: StringName,
	label: String = "",
	weight: float = -1.0,
	details: Dictionary = {}
) -> void:
	ensure_load()
	if not _active:
		return
	var state := _get_or_create_stage_state(stage_id)
	if not label.is_empty():
		state["label"] = label
	if weight >= 0.0:
		state["weight"] = weight
	if bool(state.get("started", false)):
		_stage_states[stage_id] = state
		return
	state["started"] = true
	state["started_usec"] = Time.get_ticks_usec()
	_stage_states[stage_id] = state
	_current_stage_id = stage_id
	_last_message = str(details.get("message", state.get("label", "")))
	_trace.capture("stage_started", {
		"stage_id": str(stage_id),
		"label": str(state.get("label", "")),
		"weight": float(state.get("weight", 0.0)),
		"details": details.duplicate(true)
	})
	stage_started.emit(
		_load_id,
		stage_id,
		str(state.get("label", "")),
		float(state.get("weight", 0.0))
	)


func update_stage_progress(
	stage_id: StringName,
	completed: int,
	total: int,
	details: Dictionary = {}
) -> void:
	start_stage(stage_id, "", -1.0, details)
	if not _active:
		return
	var state := _get_or_create_stage_state(stage_id)
	var safe_total := maxi(total, 0)
	var safe_completed := maxi(completed, 0)
	var progress := 0.0
	if safe_total > 0:
		progress = clampf(float(safe_completed) / float(safe_total), 0.0, 1.0)
	progress = maxf(progress, float(state.get("progress", 0.0)))
	state["progress"] = progress
	state["completed_count"] = safe_completed
	state["total_count"] = safe_total
	state["last_details"] = details.duplicate(true)
	_stage_states[stage_id] = state
	_current_stage_id = stage_id
	if details.has("message"):
		_last_message = str(details.get("message", ""))
	_recalculate_overall_progress()
	stage_progress.emit(_load_id, stage_id, safe_completed, safe_total, details.duplicate(true))


func complete_stage(stage_id: StringName, details: Dictionary = {}) -> void:
	start_stage(stage_id, "", -1.0, details)
	if not _active:
		return
	var state := _get_or_create_stage_state(stage_id)
	if bool(state.get("completed", false)):
		return
	state["progress"] = 1.0
	state["completed"] = true
	state["completed_usec"] = Time.get_ticks_usec()
	state["last_details"] = details.duplicate(true)
	_stage_states[stage_id] = state
	_current_stage_id = stage_id
	if details.has("message"):
		_last_message = str(details.get("message", ""))
	_recalculate_overall_progress()
	var duration_ms := _stage_duration_ms(state)
	_trace.capture("stage_completed", {
		"stage_id": str(stage_id),
		"duration_ms": duration_ms,
		"details": details.duplicate(true)
	})
	stage_progress.emit(_load_id, stage_id, 1, 1, details.duplicate(true))
	stage_completed.emit(_load_id, stage_id, duration_ms, details.duplicate(true))


func mark_playable_ready(details: Dictionary = {}) -> void:
	if not _active or _failed or _playable_ready_emitted:
		return
	_playable_ready_emitted = true
	var duration_ms := _load_duration_ms()
	_trace.capture("playable_ready", {
		"duration_ms": duration_ms,
		"details": details.duplicate(true)
	})
	playable_ready.emit(_load_id, duration_ms)


func request_load_completion(details: Dictionary = {}) -> void:
	if not _active:
		return
	_external_completion_requested = true
	_completion_details.merge(details, true)
	_maybe_complete_load()


func complete_load(details: Dictionary = {}) -> void:
	if not _active or _failed:
		return
	_completion_details.merge(details, true)
	for stage_id in STAGE_ORDER:
		if stage_id == &"complete":
			continue
		complete_stage(stage_id, {"message": str(STAGE_DEFINITIONS.get(stage_id, {}).get("label", ""))})
	complete_stage(&"complete", {"message": "World ready"})
	mark_playable_ready()
	_overall_progress_percent = 100.0
	_last_message = "World ready"
	var duration_ms := _load_duration_ms()
	_trace.capture("load_completed", {
		"duration_ms": duration_ms,
		"details": _completion_details.duplicate(true)
	})
	_active = false
	load_completed.emit(_load_id, duration_ms)


func fail_load(stage_id: StringName, message: String, details: Dictionary = {}) -> void:
	if not _active or _failed or _cancelled:
		return
	_failed = true
	_active = false
	_world_monitor_running = false
	_failure_message = message if not message.is_empty() else "Loading failed"
	_last_message = _failure_message
	_current_stage_id = stage_id
	_trace.capture("load_failed", {
		"stage_id": str(stage_id),
		"message": _failure_message,
		"details": details.duplicate(true)
	})
	load_failed.emit(_load_id, stage_id, _failure_message)


func cancel_load(reason: String = "Loading cancelled", details: Dictionary = {}) -> void:
	if not _active:
		return
	_monitor_token += 1
	_cancelled = true
	_active = false
	_world_monitor_running = false
	_cancellation_reason = reason if not reason.is_empty() else "Loading cancelled"
	_cancellation_details = details.duplicate(true)
	_last_message = _cancellation_reason
	var duration_ms := _load_duration_ms()
	_last_cancellation = {
		"load_id": _load_id,
		"reason": _cancellation_reason,
		"duration_ms": duration_ms,
		"details": _cancellation_details.duplicate(true)
	}
	_trace.capture("load_cancelled", {
		"reason": _cancellation_reason,
		"duration_ms": duration_ms,
		"details": _cancellation_details.duplicate(true)
	})
	load_cancelled.emit(_load_id, _cancellation_reason)


func start_world_startup_monitoring() -> void:
	ensure_load("world_startup_monitor")
	if not _active or _world_monitor_running or _world_monitor_completed or _failed or _cancelled:
		return
	_world_monitor_running = true
	_monitor_token += 1
	var token := _monitor_token
	_run_world_startup_monitor.call_deferred(token)


func get_snapshot() -> Dictionary:
	return {
		"load_id": _load_id,
		"active": _active,
		"failed": _failed,
		"cancelled": _cancelled,
		"playable_ready": _playable_ready_emitted,
		"world_monitor_running": _world_monitor_running,
		"world_monitor_completed": _world_monitor_completed,
		"external_completion_requested": _external_completion_requested,
		"current_stage_id": str(_current_stage_id),
		"overall_progress_percent": _overall_progress_percent,
		"message": _last_message,
		"failure_message": _failure_message,
		"cancellation_reason": _cancellation_reason,
		"cancellation_details": _cancellation_details.duplicate(true),
		"last_cancellation": _last_cancellation.duplicate(true),
		"elapsed_ms": _load_duration_ms(),
		"stage_states": _stage_states.duplicate(true),
		"trace": _trace.get_snapshot()
	}


func get_telemetry_snapshot() -> Dictionary:
	return get_snapshot()


func _run_world_startup_monitor(token: int) -> void:
	await get_tree().process_frame
	if not _monitor_is_current(token):
		return

	var terrain_manager := get_tree().get_first_node_in_group("terrain_manager")
	if terrain_manager == null:
		complete_stage(&"save_load", {"message": "No save load required"})
		complete_stage(&"terrain", {"message": "No terrain manager"})
		mark_playable_ready({"reason": "no_terrain_manager"})
		complete_stage(&"world_content", {"message": "No world content manager"})
		complete_stage(&"vegetation", {"message": "No vegetation manager"})
		_finish_world_monitor()
		return

	if not await _monitor_terrain_stage(token, terrain_manager):
		return
	if not await _monitor_world_content_stage(token):
		return
	if not await _monitor_vegetation_stage(token):
		return
	_finish_world_monitor()


func _monitor_terrain_stage(token: int, terrain_manager: Node) -> bool:
	start_stage(&"terrain", "Preparing terrain", -1.0, {"message": "Loading terrain..."})
	var stage_start_msec := Time.get_ticks_msec()
	while _monitor_is_current(token):
		if not is_instance_valid(terrain_manager):
			fail_load(&"terrain", "Terrain manager was removed during startup")
			return false
		var terrain_snapshot := _get_manager_startup_readiness_snapshot(terrain_manager)
		if not terrain_snapshot.is_empty():
			var pending := _get_snapshot_pending(terrain_snapshot)
			var progress := clampf(float(terrain_snapshot.get("progress", 0.0)), 0.0, 1.0)
			var total := maxi(int(terrain_snapshot.get("total", 1000)), 1)
			var completed := int(terrain_snapshot.get("completed", round(progress * float(total))))
			completed = clampi(completed, 0, total)
			var details := _build_stage_details_from_readiness_snapshot(terrain_snapshot, "Loading terrain...")
			if not details.has("pending_nodes"):
				details["pending_nodes"] = pending
			update_stage_progress(&"terrain", completed, total, details)
			if bool(terrain_snapshot.get("ready", pending <= 0)):
				complete_stage(&"terrain", {"message": "Terrain loaded"})
				mark_playable_ready({"stage": "terrain"})
				return true
			if _stage_timeout_reached(stage_start_msec):
				fail_load(&"terrain", "Terrain startup timed out", details)
				return false
			await get_tree().create_timer(terrain_poll_interval_s).timeout
			continue
		var complete := false
		if terrain_manager.has_method("is_initial_load_complete"):
			complete = bool(terrain_manager.is_initial_load_complete())
		elif "initial_load_phase" in terrain_manager:
			complete = not bool(terrain_manager.get("initial_load_phase"))
		var progress := 0.0
		if terrain_manager.has_method("get_loading_progress"):
			progress = clampf(float(terrain_manager.get_loading_progress()), 0.0, 1.0)
		var pending := 0
		if terrain_manager.has_method("get_pending_nodes_count"):
			pending = int(terrain_manager.get_pending_nodes_count())
		var message := "Rendering terrain... (%d pending)" % pending if pending > 0 else "Loading terrain..."
		update_stage_progress(&"terrain", int(round(progress * 1000.0)), 1000, {
			"message": message,
			"pending_nodes": pending
		})
		if complete:
			complete_stage(&"terrain", {"message": "Terrain loaded"})
			mark_playable_ready({"stage": "terrain"})
			return true
		if _stage_timeout_reached(stage_start_msec):
			fail_load(&"terrain", "Terrain startup timed out", {"pending_nodes": pending})
			return false
		await get_tree().create_timer(terrain_poll_interval_s).timeout
	return false


func _monitor_world_content_stage(token: int) -> bool:
	start_stage(&"world_content", "Preparing world content", -1.0, {"message": "Preparing world content..."})
	var building_generator := get_tree().root.find_child("BuildingGenerator", true, false)
	var prefab_spawner := get_tree().get_first_node_in_group("prefab_spawner")
	var building_manager := get_tree().get_first_node_in_group("building_manager")
	var entity_manager := get_tree().get_first_node_in_group("entity_manager")
	var initial_readiness := _get_world_content_readiness_snapshot(building_generator, prefab_spawner, building_manager, entity_manager)
	var initial_pending := int(initial_readiness.get("pending", 0))
	var total := maxi(initial_pending, 1)
	var stage_start_msec := Time.get_ticks_msec()
	while _monitor_is_current(token):
		var readiness := _get_world_content_readiness_snapshot(building_generator, prefab_spawner, building_manager, entity_manager)
		var pending := int(readiness.get("pending", 0))
		total = maxi(total, pending)
		var completed := maxi(total - pending, 0)
		var details: Dictionary = readiness.get("details", {})
		details["message"] = str(readiness.get("message", "Spawning world content: %d pending" % pending))
		details["pending"] = pending
		update_stage_progress(&"world_content", completed, total, details)
		if bool(readiness.get("ready", pending <= 0)) and pending <= 0:
			complete_stage(&"world_content", {"message": "World content ready"})
			return true
		if _stage_timeout_reached(stage_start_msec):
			fail_load(&"world_content", "World content startup timed out", details)
			return false
		await get_tree().create_timer(world_content_poll_interval_s).timeout
	return false


func _monitor_vegetation_stage(token: int) -> bool:
	start_stage(&"vegetation", "Placing vegetation", -1.0, {"message": "Placing vegetation..."})
	var vegetation_manager := get_tree().get_first_node_in_group("vegetation_manager")
	if vegetation_manager == null:
		complete_stage(&"vegetation", {"message": "No vegetation manager"})
		return true
	var initial_pending := _get_pending_vegetation_count(vegetation_manager)
	var total := maxi(initial_pending, 1)
	var stage_start_msec := Time.get_ticks_msec()
	while _monitor_is_current(token):
		if not is_instance_valid(vegetation_manager):
			complete_stage(&"vegetation", {"message": "Vegetation manager removed"})
			return true
		var vegetation_snapshot := _get_manager_startup_readiness_snapshot(vegetation_manager)
		if not vegetation_snapshot.is_empty():
			var pending := _get_snapshot_pending(vegetation_snapshot)
			total = maxi(total, pending)
			var completed := maxi(total - pending, 0)
			if vegetation_snapshot.has("total") and vegetation_snapshot.has("completed"):
				total = maxi(int(vegetation_snapshot.get("total", total)), 1)
				completed = clampi(int(vegetation_snapshot.get("completed", completed)), 0, total)
			var details := _build_stage_details_from_readiness_snapshot(vegetation_snapshot, "Placing vegetation...")
			update_stage_progress(&"vegetation", completed, total, details)
			if bool(vegetation_snapshot.get("ready", pending <= 0)) and pending <= 0:
				complete_stage(&"vegetation", {"message": "Vegetation ready"})
				return true
			if _stage_timeout_reached(stage_start_msec):
				fail_load(&"vegetation", "Vegetation startup timed out", details)
				return false
			await get_tree().create_timer(vegetation_poll_interval_s).timeout
			continue
		var ready := true
		if vegetation_manager.has_method("is_vegetation_ready"):
			ready = bool(vegetation_manager.is_vegetation_ready())
		var pending := _get_pending_vegetation_count(vegetation_manager)
		total = maxi(total, pending)
		var completed := maxi(total - pending, 0)
		update_stage_progress(&"vegetation", completed, total, {
			"message": "Placing vegetation: %d pending" % pending,
			"pending": pending
		})
		if ready and pending <= 0:
			complete_stage(&"vegetation", {"message": "Vegetation ready"})
			return true
		if _stage_timeout_reached(stage_start_msec):
			fail_load(&"vegetation", "Vegetation startup timed out", {"pending": pending})
			return false
		await get_tree().create_timer(vegetation_poll_interval_s).timeout
	return false


func _finish_world_monitor() -> void:
	_world_monitor_running = false
	_world_monitor_completed = true
	_trace.capture("world_monitor_completed", {})
	_maybe_complete_load()


func _maybe_complete_load() -> void:
	if not _active or _failed or not _world_monitor_completed:
		return
	var save_manager := get_node_or_null("/root/SaveManager")
	var save_load_active := save_manager != null and bool(save_manager.get("is_loading_game"))
	if not _external_completion_requested and save_load_active:
		return
	complete_load(_completion_details)

func _get_manager_startup_readiness_snapshot(manager: Node) -> Dictionary:
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


func _build_stage_details_from_readiness_snapshot(snapshot: Dictionary, fallback_message: String) -> Dictionary:
	var details: Dictionary = {}
	var raw_details: Variant = snapshot.get("details", {})
	if raw_details is Dictionary:
		details = (raw_details as Dictionary).duplicate(true)
	var pending := _get_snapshot_pending(snapshot)
	details["message"] = str(snapshot.get("message", fallback_message))
	details["pending"] = pending
	details["ready"] = bool(snapshot.get("ready", pending <= 0))
	details["source"] = "startup_readiness_snapshot"
	return details


func _get_building_generator_pending_count(building_generator: Node) -> int:
	if building_generator and is_instance_valid(building_generator) and "spawn_queue" in building_generator:
		var queue_variant: Variant = building_generator.get("spawn_queue")
		if queue_variant is Array:
			return (queue_variant as Array).size()
	return 0


func _get_world_content_readiness_snapshot(
	building_generator: Node,
	prefab_spawner: Node,
	building_manager: Node,
	entity_manager: Node
) -> Dictionary:
	var components := {}
	var pending := 0
	var ready := true

	var building_generator_pending := _get_building_generator_pending_count(building_generator)
	components["building_generator"] = {
		"ready": building_generator_pending <= 0,
		"pending": building_generator_pending,
		"source": "spawn_queue"
	}
	pending += building_generator_pending
	ready = ready and building_generator_pending <= 0

	var prefab_component := _get_world_content_component_readiness(prefab_spawner, _get_prefab_spawner_fallback_pending(prefab_spawner), "prefab_spawner")
	components["prefab_spawner"] = prefab_component
	pending += int(prefab_component.get("pending", 0))
	ready = ready and bool(prefab_component.get("ready", true))

	var building_component := _get_world_content_component_readiness(building_manager, _get_building_manager_fallback_pending(building_manager), "building_manager")
	components["building_manager"] = building_component
	pending += int(building_component.get("pending", 0))
	ready = ready and bool(building_component.get("ready", true))

	var entity_component := _get_world_content_component_readiness(entity_manager, _get_entity_manager_fallback_pending(entity_manager), "entity_manager")
	components["entity_manager"] = entity_component
	pending += int(entity_component.get("pending", 0))
	ready = ready and bool(entity_component.get("ready", true))

	ready = ready and pending <= 0
	return {
		"ready": ready,
		"pending": pending,
		"completed": 1 if ready else 0,
		"total": 1,
		"progress": 1.0 if ready else 0.0,
		"message": "World content ready" if ready else "Spawning world content: %d pending" % pending,
		"details": {
			"components": components,
			"source": "startup_readiness_snapshot"
		}
	}


func _get_world_content_component_readiness(manager: Node, fallback_pending: int, component_name: String) -> Dictionary:
	var snapshot := _get_manager_startup_readiness_snapshot(manager)
	if snapshot.is_empty():
		var pending := maxi(fallback_pending, 0)
		return {
			"ready": pending <= 0,
			"pending": pending,
			"source": "fallback",
			"name": component_name
		}
	var pending := _get_snapshot_pending(snapshot)
	var component_ready := bool(snapshot.get("ready", pending <= 0)) and pending <= 0
	return {
		"ready": component_ready,
		"pending": pending,
		"source": "startup_readiness_snapshot",
		"name": component_name,
		"message": str(snapshot.get("message", "")),
		"details": (snapshot.get("details", {}) as Dictionary).duplicate(true) if snapshot.get("details", {}) is Dictionary else {}
	}


func _get_pending_world_content_count(
	building_generator: Node,
	prefab_spawner: Node,
	building_manager: Node,
	entity_manager: Node = null
) -> int:
	var snapshot := _get_world_content_readiness_snapshot(building_generator, prefab_spawner, building_manager, entity_manager)
	return int(snapshot.get("pending", 0))


func _get_prefab_spawner_fallback_pending(prefab_spawner: Node) -> int:
	var pending := 0
	if prefab_spawner and is_instance_valid(prefab_spawner):
		if prefab_spawner.has_method("has_pending_spawn_jobs") and prefab_spawner.has_pending_spawn_jobs():
			pending += 1
		if prefab_spawner.has_method("has_pending_world_map_baked_payload_jobs") and prefab_spawner.has_pending_world_map_baked_payload_jobs():
			pending += 1
	return pending


func _get_building_manager_fallback_pending(building_manager: Node) -> int:
	var pending := 0
	if building_manager and is_instance_valid(building_manager):
		if building_manager.has_method("has_pending_world_map_baked_building_apply_phases") and building_manager.has_pending_world_map_baked_building_apply_phases():
			pending += 1
		if building_manager.has_method("has_pending_world_map_baked_object_spawns") and building_manager.has_pending_world_map_baked_object_spawns():
			pending += 1
		if building_manager.has_method("has_pending_visual_batch_work") and building_manager.has_pending_visual_batch_work():
			pending += 1
		if building_manager.has_method("has_dirty_global_visual_batches") and building_manager.has_dirty_global_visual_batches():
			pending += 1
		if building_manager.has_method("has_dirty_visible_chunks") and building_manager.has_dirty_visible_chunks():
			pending += 1
		if building_manager.has_method("is_object_render_prewarm_active") and building_manager.is_object_render_prewarm_active():
			pending += 1
	return pending


func _get_entity_manager_fallback_pending(entity_manager: Node) -> int:
	if entity_manager and is_instance_valid(entity_manager) and entity_manager.has_method("get_telemetry_snapshot"):
		var telemetry_variant: Variant = entity_manager.get_telemetry_snapshot()
		if telemetry_variant is Dictionary:
			var telemetry := telemetry_variant as Dictionary
			return maxi(int(telemetry.get("pending_spawns", 0)), 0) \
				+ maxi(int(telemetry.get("deferred_spawn_chunks", 0)), 0) \
				+ maxi(int(telemetry.get("deferred_spawn_plans", 0)), 0) \
				+ (1 if bool(telemetry.get("entity_render_prewarm_active", false)) else 0)
	return 0


func _get_pending_vegetation_count(vegetation_manager: Node) -> int:
	var snapshot := _get_manager_startup_readiness_snapshot(vegetation_manager)
	if not snapshot.is_empty():
		return _get_snapshot_pending(snapshot)
	if vegetation_manager and vegetation_manager.has_method("get_pending_chunks_count"):
		return maxi(int(vegetation_manager.get_pending_chunks_count()), 0)
	return 0


func _get_or_create_stage_state(stage_id: StringName) -> Dictionary:
	if _stage_states.has(stage_id):
		return _stage_states[stage_id]
	var definition: Dictionary = STAGE_DEFINITIONS.get(stage_id, {
		"label": str(stage_id),
		"weight": 0.0
	})
	var state := {
		"id": stage_id,
		"label": str(definition.get("label", str(stage_id))),
		"weight": float(definition.get("weight", 0.0)),
		"progress": 0.0,
		"started": false,
		"completed": false,
		"started_usec": 0,
		"completed_usec": 0,
		"completed_count": 0,
		"total_count": 0,
		"last_details": {}
	}
	_stage_states[stage_id] = state
	return state


func _reset_stage_states() -> void:
	_stage_states.clear()
	for stage_id in STAGE_ORDER:
		_get_or_create_stage_state(stage_id)


func _recalculate_overall_progress() -> void:
	var weighted_progress := 0.0
	var total_weight := 0.0
	for stage_id in STAGE_ORDER:
		var state := _get_or_create_stage_state(stage_id)
		var weight := float(state.get("weight", 0.0))
		total_weight += weight
		weighted_progress += weight * clampf(float(state.get("progress", 0.0)), 0.0, 1.0)
	var next_progress := 0.0
	if total_weight > 0.0:
		next_progress = weighted_progress / total_weight * 100.0
	_overall_progress_percent = maxf(_overall_progress_percent, next_progress)


func _stage_duration_ms(state: Dictionary) -> float:
	var started_usec := int(state.get("started_usec", 0))
	if started_usec <= 0:
		return 0.0
	var completed_usec := int(state.get("completed_usec", Time.get_ticks_usec()))
	return float(maxi(completed_usec - started_usec, 0)) / 1000.0


func _load_duration_ms() -> float:
	if _load_started_usec <= 0:
		return 0.0
	return float(Time.get_ticks_usec() - _load_started_usec) / 1000.0


func _stage_timeout_reached(stage_start_msec: int) -> bool:
	if stage_timeout_s <= 0.0:
		return false
	return float(Time.get_ticks_msec() - stage_start_msec) / 1000.0 >= stage_timeout_s


func _monitor_is_current(token: int) -> bool:
	return token == _monitor_token and _active and not _failed
