extends RefCounted
## Bounded single-writer queue that keeps terrain artifact disk I/O off gameplay frames.

var enabled: bool = true
var max_pending_entries: int = 256
var max_pending_bytes: int = 512 * 1024 * 1024
var max_write_bytes_per_second: int = 0

var _store: Object = null
var _thread: Thread = null
var _semaphore: Semaphore = Semaphore.new()
var _mutex: Mutex = Mutex.new()
var _pending_by_key: Dictionary = {}
var _pending_order: Array[String] = []
var _pending_bytes: int = 0
var _started: bool = false
var _exit_requested: bool = false
var _in_flight: bool = false
var _next_write_allowed_usec: int = 0

var _enqueue_count: int = 0
var _replacement_count: int = 0
var _completed_count: int = 0
var _completed_bytes: int = 0
var _failed_count: int = 0
var _failed_bytes: int = 0
var _dropped_count: int = 0
var _dropped_bytes: int = 0
var _drop_reasons: Dictionary = {}
var _rate_limit_wait_count: int = 0
var _rate_limit_total_wait_ms: float = 0.0
var _rate_limit_max_wait_ms: float = 0.0
var _last_store_ms: float = 0.0
var _max_store_ms: float = 0.0
var _last_completed_coord: Vector3i = Vector3i.ZERO
var _last_completed_bytes: int = 0


func configure(
	queue_enabled: bool,
	queue_max_pending_entries: int,
	queue_max_pending_bytes: int,
	queue_max_write_bytes_per_second: int = 0
) -> void:
	_mutex.lock()
	enabled = queue_enabled
	max_pending_entries = maxi(queue_max_pending_entries, 0)
	max_pending_bytes = maxi(queue_max_pending_bytes, 0)
	var new_max_write_bytes_per_second := maxi(queue_max_write_bytes_per_second, 0)
	if max_write_bytes_per_second != new_max_write_bytes_per_second:
		_next_write_allowed_usec = 0
	max_write_bytes_per_second = new_max_write_bytes_per_second
	if not enabled or max_pending_entries <= 0 or max_pending_bytes <= 0:
		_clear_pending_locked("disabled")
	else:
		_trim_locked()
	_mutex.unlock()


func start(store: Object) -> bool:
	_mutex.lock()
	if _started:
		_mutex.unlock()
		return true
	_store = store
	_exit_requested = false
	_next_write_allowed_usec = 0
	_thread = Thread.new()
	var error := _thread.start(_thread_function)
	if error != OK:
		_thread = null
		_store = null
		_mutex.unlock()
		return false
	_started = true
	_mutex.unlock()
	return true


func enqueue(coord: Vector3i, settings_signature: String, artifact: Dictionary) -> bool:
	var artifact_bytes := int(artifact.get("byte_size", 0))
	_mutex.lock()
	if not _started:
		_record_drop_locked("not_started", artifact_bytes)
		_mutex.unlock()
		return false
	if not enabled or max_pending_entries <= 0 or max_pending_bytes <= 0:
		_record_drop_locked("disabled", artifact_bytes)
		_mutex.unlock()
		return false
	if artifact_bytes <= 0:
		_record_drop_locked("invalid_byte_size", artifact_bytes)
		_mutex.unlock()
		return false
	if artifact_bytes > max_pending_bytes:
		_record_drop_locked("oversize", artifact_bytes)
		_mutex.unlock()
		return false

	var key := _task_key(coord, settings_signature)
	var is_new := not _pending_by_key.has(key)
	if not is_new:
		var previous: Dictionary = _pending_by_key[key]
		_pending_bytes = maxi(_pending_bytes - int(previous.get("byte_size", 0)), 0)
		_pending_order.erase(key)
		_replacement_count += 1

	_pending_by_key[key] = {
		"coord": coord,
		"settings_signature": settings_signature,
		"artifact": artifact,
		"byte_size": artifact_bytes,
		"queued_at_usec": Time.get_ticks_usec()
	}
	_pending_order.append(key)
	_pending_bytes += artifact_bytes
	_enqueue_count += 1
	_trim_locked()
	var accepted := _pending_by_key.has(key)
	_mutex.unlock()

	if is_new and accepted:
		_semaphore.post()
	return accepted


func clear_pending(reason: String = "manual") -> void:
	_mutex.lock()
	_clear_pending_locked(reason)
	_mutex.unlock()


func is_started() -> bool:
	_mutex.lock()
	var result := _started
	_mutex.unlock()
	return result


func shutdown(flush_pending: bool = true) -> void:
	_mutex.lock()
	if not _started:
		_mutex.unlock()
		return
	if not flush_pending:
		_clear_pending_locked("shutdown")
	_exit_requested = true
	var thread := _thread
	_mutex.unlock()

	_semaphore.post()
	if thread:
		thread.wait_to_finish()

	_mutex.lock()
	_thread = null
	_store = null
	_started = false
	_in_flight = false
	_next_write_allowed_usec = 0
	_mutex.unlock()


func get_snapshot() -> Dictionary:
	_mutex.lock()
	var snapshot := {
		"enabled": enabled,
		"started": _started,
		"max_pending_entries": max_pending_entries,
		"max_pending_bytes": max_pending_bytes,
		"max_write_bytes_per_second": max_write_bytes_per_second,
		"pending_entries": _pending_by_key.size(),
		"pending_bytes": _pending_bytes,
		"pending_byte_budget_used_ratio": float(_pending_bytes) / float(maxi(max_pending_bytes, 1)),
		"in_flight": _in_flight,
		"enqueue_count": _enqueue_count,
		"replacement_count": _replacement_count,
		"completed_count": _completed_count,
		"completed_bytes": _completed_bytes,
		"failed_count": _failed_count,
		"failed_bytes": _failed_bytes,
		"dropped_count": _dropped_count,
		"dropped_bytes": _dropped_bytes,
		"drop_reasons": _drop_reasons.duplicate(true),
		"rate_limit_wait_count": _rate_limit_wait_count,
		"rate_limit_total_wait_ms": _rate_limit_total_wait_ms,
		"rate_limit_max_wait_ms": _rate_limit_max_wait_ms,
		"last_store_ms": _last_store_ms,
		"max_store_ms": _max_store_ms,
		"last_completed_coord": str(_last_completed_coord),
		"last_completed_bytes": _last_completed_bytes
	}
	_mutex.unlock()
	return snapshot


func _thread_function() -> void:
	while true:
		_semaphore.wait()

		_mutex.lock()
		if _pending_order.is_empty():
			if _exit_requested:
				_mutex.unlock()
				break
			_mutex.unlock()
			continue

		var key: String = _pending_order.pop_front()
		var task_variant: Variant = _pending_by_key.get(key, {})
		if not (task_variant is Dictionary):
			_mutex.unlock()
			continue
		var task: Dictionary = task_variant
		_pending_by_key.erase(key)
		_pending_bytes = maxi(_pending_bytes - int(task.get("byte_size", 0)), 0)
		_in_flight = true
		var store := _store
		_mutex.unlock()

		var task_bytes := int(task.get("byte_size", 0))
		_wait_for_rate_limit(task_bytes)
		var start_usec := Time.get_ticks_usec()
		var stored := false
		if store and store.has_method("store"):
			stored = bool(store.store(
				task.get("coord", Vector3i.ZERO),
				str(task.get("settings_signature", "")),
				task.get("artifact", {})
			))
		var elapsed_ms := float(Time.get_ticks_usec() - start_usec) / 1000.0

		_mutex.lock()
		_in_flight = false
		_last_store_ms = elapsed_ms
		_max_store_ms = maxf(_max_store_ms, elapsed_ms)
		_last_completed_coord = task.get("coord", Vector3i.ZERO)
		_last_completed_bytes = task_bytes
		if stored:
			_completed_count += 1
			_completed_bytes += task_bytes
		else:
			_failed_count += 1
			_failed_bytes += task_bytes
		var should_exit := _exit_requested and _pending_order.is_empty()
		_mutex.unlock()
		if should_exit:
			break


func _wait_for_rate_limit(task_bytes: int) -> void:
	_mutex.lock()
	var bytes_per_second := max_write_bytes_per_second
	if bytes_per_second <= 0 or _exit_requested:
		_next_write_allowed_usec = 0
		_mutex.unlock()
		return

	var now_usec := Time.get_ticks_usec()
	var scheduled_start_usec := maxi(now_usec, _next_write_allowed_usec)
	var wait_usec := maxi(scheduled_start_usec - now_usec, 0)
	var task_interval_usec := int(ceil(
		float(maxi(task_bytes, 0)) * 1000000.0 / float(bytes_per_second)
	))
	_next_write_allowed_usec = scheduled_start_usec + task_interval_usec
	_mutex.unlock()

	var wait_started_usec := Time.get_ticks_usec()
	var remaining_wait_usec := wait_usec
	while remaining_wait_usec > 0:
		var wait_slice_usec := mini(remaining_wait_usec, 50000)
		OS.delay_usec(wait_slice_usec)
		remaining_wait_usec -= wait_slice_usec
		_mutex.lock()
		var bypass_wait := _exit_requested or max_write_bytes_per_second <= 0
		_mutex.unlock()
		if bypass_wait:
			break
	if wait_usec > 0:
		var actual_wait_ms := float(Time.get_ticks_usec() - wait_started_usec) / 1000.0
		_mutex.lock()
		_rate_limit_wait_count += 1
		_rate_limit_total_wait_ms += actual_wait_ms
		_rate_limit_max_wait_ms = maxf(_rate_limit_max_wait_ms, actual_wait_ms)
		_mutex.unlock()


func _trim_locked() -> void:
	while _pending_order.size() > max_pending_entries or _pending_bytes > max_pending_bytes:
		if _pending_order.is_empty():
			break
		var key: String = _pending_order.pop_front()
		if not _pending_by_key.has(key):
			continue
		var task: Dictionary = _pending_by_key[key]
		_pending_by_key.erase(key)
		var task_bytes := int(task.get("byte_size", 0))
		_pending_bytes = maxi(_pending_bytes - task_bytes, 0)
		_record_drop_locked("budget", task_bytes)


func _clear_pending_locked(reason: String) -> void:
	var removed_count := _pending_by_key.size()
	var removed_bytes := _pending_bytes
	_pending_by_key.clear()
	_pending_order.clear()
	_pending_bytes = 0
	if removed_count <= 0:
		return
	_dropped_count += removed_count
	_dropped_bytes += removed_bytes
	var normalized_reason := reason if not reason.is_empty() else "unknown"
	_drop_reasons[normalized_reason] = int(_drop_reasons.get(normalized_reason, 0)) + removed_count


func _record_drop_locked(reason: String, bytes: int) -> void:
	var normalized_reason := reason if not reason.is_empty() else "unknown"
	_dropped_count += 1
	_dropped_bytes += maxi(bytes, 0)
	_drop_reasons[normalized_reason] = int(_drop_reasons.get(normalized_reason, 0)) + 1


func _task_key(coord: Vector3i, settings_signature: String) -> String:
	return "%s|%d|%d|%d" % [settings_signature.sha256_text(), coord.x, coord.y, coord.z]
