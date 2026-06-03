extends RefCounted
## Bounded session cache for data-only terrain chunk artifacts.

var enabled: bool = true
var byte_budget: int = 0
var entry_limit: int = 0

var _entries: Dictionary = {}
var _total_bytes: int = 0
var _usage_sequence: int = 0
var _lru_queue: Array[Dictionary] = []
var _lru_cursor: int = 0

var _hit_count: int = 0
var _miss_count: int = 0
var _disabled_lookup_count: int = 0
var _store_count: int = 0
var _replacement_count: int = 0
var _store_skipped_count: int = 0
var _store_skipped_reasons: Dictionary = {}
var _eviction_count: int = 0
var _invalidation_count: int = 0
var _invalidation_reasons: Dictionary = {}
var _restore_count: int = 0
var _restore_discarded_count: int = 0
var _restore_total_ms: float = 0.0
var _last_restore_ms: float = 0.0


func configure(cache_enabled: bool, cache_byte_budget: int, cache_entry_limit: int) -> void:
	enabled = cache_enabled
	byte_budget = maxi(cache_byte_budget, 0)
	entry_limit = maxi(cache_entry_limit, 0)
	_trim_to_budget()


func lookup(coord: Vector3i, settings_signature: String, stored_mod_version: int) -> Dictionary:
	if not enabled or byte_budget <= 0 or entry_limit <= 0:
		_disabled_lookup_count += 1
		return {}
	if not _entries.has(coord):
		_miss_count += 1
		return {}

	var artifact: Dictionary = _entries[coord]
	var invalid_reason := ""
	if str(artifact.get("settings_signature", "")) != settings_signature:
		invalid_reason = "settings_signature"
	elif int(artifact.get("stored_mod_version", -1)) != stored_mod_version:
		invalid_reason = "stored_mod_version"
	elif int(artifact.get("byte_size", 0)) <= 0:
		invalid_reason = "invalid_byte_size"

	if not invalid_reason.is_empty():
		_invalidate_existing(coord, invalid_reason)
		_miss_count += 1
		return {}

	_hit_count += 1
	_touch(coord, artifact)
	return artifact.duplicate(true)


func store(coord: Vector3i, artifact: Dictionary) -> bool:
	if not enabled or byte_budget <= 0 or entry_limit <= 0:
		record_store_skipped("disabled")
		return false

	var artifact_bytes := int(artifact.get("byte_size", 0))
	if artifact_bytes <= 0:
		record_store_skipped("invalid_byte_size")
		return false
	if artifact_bytes > byte_budget:
		_erase_entry(coord)
		record_store_skipped("oversize")
		return false

	if _entries.has(coord):
		_erase_entry(coord)
		_replacement_count += 1

	var stored_artifact := artifact.duplicate(false)
	stored_artifact["coord"] = coord
	stored_artifact["byte_size"] = artifact_bytes
	_entries[coord] = stored_artifact
	_total_bytes += artifact_bytes
	_store_count += 1
	_touch(coord, stored_artifact)
	_trim_to_budget()
	return _entries.has(coord)


func invalidate(coord: Vector3i, reason: String = "manual") -> bool:
	if not _entries.has(coord):
		return false
	_invalidate_existing(coord, reason)
	return true


func clear(reason: String = "clear") -> void:
	var removed_count := _entries.size()
	_entries.clear()
	_total_bytes = 0
	_lru_queue.clear()
	_lru_cursor = 0
	if removed_count > 0:
		_invalidation_count += removed_count
		_invalidation_reasons[reason] = int(_invalidation_reasons.get(reason, 0)) + removed_count


func record_store_skipped(reason: String) -> void:
	var normalized_reason := reason if not reason.is_empty() else "unknown"
	_store_skipped_count += 1
	_store_skipped_reasons[normalized_reason] = int(_store_skipped_reasons.get(normalized_reason, 0)) + 1


func record_restore(duration_ms: float, accepted: bool) -> void:
	_last_restore_ms = maxf(duration_ms, 0.0)
	_restore_total_ms += _last_restore_ms
	if accepted:
		_restore_count += 1
	else:
		_restore_discarded_count += 1


func get_snapshot() -> Dictionary:
	var lookup_count := _hit_count + _miss_count
	return {
		"enabled": enabled,
		"entry_count": _entries.size(),
		"entry_limit": entry_limit,
		"total_bytes": _total_bytes,
		"byte_budget": byte_budget,
		"byte_budget_used_ratio": float(_total_bytes) / float(maxi(byte_budget, 1)),
		"hit_count": _hit_count,
		"miss_count": _miss_count,
		"disabled_lookup_count": _disabled_lookup_count,
		"hit_ratio": float(_hit_count) / float(maxi(lookup_count, 1)),
		"store_count": _store_count,
		"replacement_count": _replacement_count,
		"store_skipped_count": _store_skipped_count,
		"store_skipped_reasons": _store_skipped_reasons.duplicate(true),
		"eviction_count": _eviction_count,
		"invalidation_count": _invalidation_count,
		"invalidation_reasons": _invalidation_reasons.duplicate(true),
		"restore_count": _restore_count,
		"restore_discarded_count": _restore_discarded_count,
		"restore_total_ms": _restore_total_ms,
		"last_restore_ms": _last_restore_ms,
		"generation_avoided_count": _restore_count
	}


func _touch(coord: Vector3i, artifact: Dictionary) -> void:
	_usage_sequence += 1
	artifact["last_used_sequence"] = _usage_sequence
	artifact["last_used_usec"] = Time.get_ticks_usec()
	_entries[coord] = artifact
	_lru_queue.append({
		"coord": coord,
		"sequence": _usage_sequence
	})
	_rebuild_lru_queue_if_needed()


func _trim_to_budget() -> void:
	while _entries.size() > entry_limit or _total_bytes > byte_budget:
		if not _evict_oldest():
			break


func _evict_oldest() -> bool:
	while _lru_cursor < _lru_queue.size():
		var record: Dictionary = _lru_queue[_lru_cursor]
		_lru_cursor += 1
		var coord: Vector3i = record.get("coord", Vector3i.ZERO)
		if not _entries.has(coord):
			continue
		var artifact: Dictionary = _entries[coord]
		if int(artifact.get("last_used_sequence", -1)) != int(record.get("sequence", -2)):
			continue
		_erase_entry(coord)
		_eviction_count += 1
		_compact_lru_queue()
		return true
	_compact_lru_queue()
	return false


func _invalidate_existing(coord: Vector3i, reason: String) -> void:
	_erase_entry(coord)
	var normalized_reason := reason if not reason.is_empty() else "unknown"
	_invalidation_count += 1
	_invalidation_reasons[normalized_reason] = int(_invalidation_reasons.get(normalized_reason, 0)) + 1


func _erase_entry(coord: Vector3i) -> void:
	if not _entries.has(coord):
		return
	var artifact: Dictionary = _entries[coord]
	_total_bytes = maxi(_total_bytes - int(artifact.get("byte_size", 0)), 0)
	_entries.erase(coord)


func _compact_lru_queue() -> void:
	if _lru_cursor < 1024 or _lru_cursor * 2 < _lru_queue.size():
		return
	_lru_queue = _lru_queue.slice(_lru_cursor)
	_lru_cursor = 0


func _rebuild_lru_queue_if_needed() -> void:
	var max_queue_size := maxi(entry_limit * 4, 1024)
	if _lru_queue.size() <= max_queue_size:
		return

	var rebuilt: Array[Dictionary] = []
	for coord_variant in _entries.keys():
		var coord: Vector3i = coord_variant
		var artifact: Dictionary = _entries[coord]
		rebuilt.append({
			"coord": coord,
			"sequence": int(artifact.get("last_used_sequence", 0))
		})
	rebuilt.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("sequence", 0)) < int(b.get("sequence", 0))
	)
	_lru_queue = rebuilt
	_lru_cursor = 0
