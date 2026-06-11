extends RefCounted
## Disk-backed store for base terrain artifacts.

const STORE_MAGIC: String = "terrain_artifact"
const STORE_VERSION: int = 1
const FILE_EXTENSION: String = ".var"
const RESOURCE_EXTENSION: String = ".res"

var enabled: bool = true
var root_path: String = "user://terrain_artifacts"
var max_entries_per_signature: int = 4096
var max_bytes_per_signature: int = 0

var _hit_count: int = 0
var _miss_count: int = 0
var _disabled_lookup_count: int = 0
var _invalid_count: int = 0
var _read_error_count: int = 0
var _write_error_count: int = 0
var _store_count: int = 0
var _store_skipped_count: int = 0
var _store_skipped_reasons: Dictionary = {}
var _eviction_count: int = 0
var _last_lookup_ms: float = 0.0
var _last_store_ms: float = 0.0
var _last_signature_hash: String = ""
var _last_path: String = ""
var _last_signature_entry_count: int = 0
var _last_signature_bytes: int = 0
var _max_observed_signature_bytes: int = 0
var _last_trim_removed_bytes: int = 0
var _mutex: Mutex = Mutex.new()


func configure(
	store_enabled: bool,
	store_root_path: String,
	store_max_entries_per_signature: int,
	store_max_bytes_per_signature: int = 0
) -> void:
	_mutex.lock()
	_configure_locked(
		store_enabled,
		store_root_path,
		store_max_entries_per_signature,
		store_max_bytes_per_signature
	)
	_mutex.unlock()


func _configure_locked(
	store_enabled: bool,
	store_root_path: String,
	store_max_entries_per_signature: int,
	store_max_bytes_per_signature: int
) -> void:
	enabled = store_enabled
	root_path = store_root_path if not store_root_path.is_empty() else "user://terrain_artifacts"
	max_entries_per_signature = maxi(store_max_entries_per_signature, 0)
	max_bytes_per_signature = maxi(store_max_bytes_per_signature, 0)


func lookup(coord: Vector3i, settings_signature: String) -> Dictionary:
	_mutex.lock()
	var artifact := _lookup_locked(coord, settings_signature)
	_mutex.unlock()
	return artifact


func _lookup_locked(coord: Vector3i, settings_signature: String) -> Dictionary:
	var start_usec := Time.get_ticks_usec()
	if not enabled or max_entries_per_signature <= 0:
		_disabled_lookup_count += 1
		_last_lookup_ms = _elapsed_ms(start_usec)
		return {}

	var path := _artifact_path(coord, settings_signature)
	_last_path = path
	if not FileAccess.file_exists(path):
		_miss_count += 1
		_last_lookup_ms = _elapsed_ms(start_usec)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_read_error_count += 1
		_last_lookup_ms = _elapsed_ms(start_usec)
		return {}

	var payload_variant: Variant = file.get_var(false)
	file.close()
	if not (payload_variant is Dictionary):
		_invalid_count += 1
		_remove_file(path)
		_last_lookup_ms = _elapsed_ms(start_usec)
		return {}

	var payload: Dictionary = payload_variant
	if not _is_valid_payload(payload, coord, settings_signature):
		_invalid_count += 1
		_remove_file(path)
		_last_lookup_ms = _elapsed_ms(start_usec)
		return {}

	var artifact_variant: Variant = payload.get("artifact", {})
	if not (artifact_variant is Dictionary):
		_invalid_count += 1
		_remove_file(path)
		_last_lookup_ms = _elapsed_ms(start_usec)
		return {}

	var artifact: Dictionary = artifact_variant
	_hit_count += 1
	_last_lookup_ms = _elapsed_ms(start_usec)
	return artifact.duplicate(true)


func store(coord: Vector3i, settings_signature: String, artifact: Dictionary) -> bool:
	_mutex.lock()
	var stored := _store_locked(coord, settings_signature, artifact)
	_mutex.unlock()
	return stored


func _store_locked(coord: Vector3i, settings_signature: String, artifact: Dictionary) -> bool:
	var start_usec := Time.get_ticks_usec()
	if not enabled or max_entries_per_signature <= 0:
		_record_store_skipped_locked("disabled")
		_last_store_ms = _elapsed_ms(start_usec)
		return false
	if int(artifact.get("stored_mod_version", -1)) != 0:
		_record_store_skipped_locked("modified_chunk")
		_last_store_ms = _elapsed_ms(start_usec)
		return false
	if str(artifact.get("settings_signature", "")) != settings_signature:
		_record_store_skipped_locked("settings_signature")
		_last_store_ms = _elapsed_ms(start_usec)
		return false
	var artifact_bytes := int(artifact.get("byte_size", 0))
	if artifact_bytes <= 0:
		_record_store_skipped_locked("invalid_byte_size")
		_last_store_ms = _elapsed_ms(start_usec)
		return false
	if max_bytes_per_signature > 0 and artifact_bytes > max_bytes_per_signature:
		_record_store_skipped_locked("oversize")
		_last_store_ms = _elapsed_ms(start_usec)
		return false

	var signature_dir := _signature_dir(settings_signature)
	if not _ensure_dir(signature_dir):
		_write_error_count += 1
		_last_store_ms = _elapsed_ms(start_usec)
		return false

	var path := _artifact_path(coord, settings_signature)
	_last_path = path
	var temp_path := path + ".tmp"
	var artifact_to_store := _prepare_artifact_for_store_locked(coord, settings_signature, artifact)
	var payload := {
		"magic": STORE_MAGIC,
		"version": STORE_VERSION,
		"coord": coord,
		"settings_signature": settings_signature,
		"stored_at_usec": Time.get_ticks_usec(),
		"artifact": artifact_to_store
	}
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		_write_error_count += 1
		_last_store_ms = _elapsed_ms(start_usec)
		return false

	file.store_var(payload, false)
	file.close()
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null or dir.rename(temp_path, path) != OK:
		_write_error_count += 1
		_remove_file(temp_path)
		_last_store_ms = _elapsed_ms(start_usec)
		return false
	_store_count += 1
	_trim_signature_dir(signature_dir)
	_last_store_ms = _elapsed_ms(start_usec)
	return FileAccess.file_exists(path)


func record_store_skipped(reason: String) -> void:
	_mutex.lock()
	_record_store_skipped_locked(reason)
	_mutex.unlock()


func prepare_artifact_for_store(coord: Vector3i, settings_signature: String, artifact: Dictionary) -> Dictionary:
	_mutex.lock()
	var prepared := _prepare_artifact_for_store_locked(coord, settings_signature, artifact)
	_mutex.unlock()
	return prepared


func _record_store_skipped_locked(reason: String) -> void:
	var normalized_reason := reason if not reason.is_empty() else "unknown"
	_store_skipped_count += 1
	_store_skipped_reasons[normalized_reason] = int(_store_skipped_reasons.get(normalized_reason, 0)) + 1


func clear_all() -> void:
	_mutex.lock()
	_remove_dir_contents(root_path)
	_mutex.unlock()


func get_snapshot() -> Dictionary:
	_mutex.lock()
	var snapshot := _get_snapshot_locked()
	_mutex.unlock()
	return snapshot


func _get_snapshot_locked() -> Dictionary:
	var lookup_count := _hit_count + _miss_count
	return {
		"enabled": enabled,
		"root_path": root_path,
		"resolved_root_path": ProjectSettings.globalize_path(root_path),
		"max_entries_per_signature": max_entries_per_signature,
		"max_bytes_per_signature": max_bytes_per_signature,
		"hit_count": _hit_count,
		"miss_count": _miss_count,
		"disabled_lookup_count": _disabled_lookup_count,
		"hit_ratio": float(_hit_count) / float(maxi(lookup_count, 1)),
		"invalid_count": _invalid_count,
		"read_error_count": _read_error_count,
		"write_error_count": _write_error_count,
		"store_count": _store_count,
		"store_skipped_count": _store_skipped_count,
		"store_skipped_reasons": _store_skipped_reasons.duplicate(true),
		"eviction_count": _eviction_count,
		"last_lookup_ms": _last_lookup_ms,
		"last_store_ms": _last_store_ms,
		"last_signature_hash": _last_signature_hash,
		"last_path": _last_path,
		"resolved_last_path": ProjectSettings.globalize_path(_last_path) if not _last_path.is_empty() else "",
		"last_signature_entry_count": _last_signature_entry_count,
		"last_signature_bytes": _last_signature_bytes,
		"last_signature_byte_budget_used_ratio": (
			float(_last_signature_bytes) / float(max_bytes_per_signature)
			if max_bytes_per_signature > 0
			else 0.0
		),
		"max_observed_signature_bytes": _max_observed_signature_bytes,
		"last_trim_removed_bytes": _last_trim_removed_bytes
	}


func _is_valid_payload(payload: Dictionary, coord: Vector3i, settings_signature: String) -> bool:
	if str(payload.get("magic", "")) != STORE_MAGIC:
		return false
	if int(payload.get("version", 0)) != STORE_VERSION:
		return false
	if payload.get("coord", Vector3i.ZERO) != coord:
		return false
	if str(payload.get("settings_signature", "")) != settings_signature:
		return false

	var artifact_variant: Variant = payload.get("artifact", {})
	if not (artifact_variant is Dictionary):
		return false
	var artifact: Dictionary = artifact_variant
	return (
		str(artifact.get("settings_signature", "")) == settings_signature
		and int(artifact.get("stored_mod_version", -1)) == 0
		and int(artifact.get("byte_size", 0)) > 0
	)


func _artifact_path(coord: Vector3i, settings_signature: String) -> String:
	return _signature_dir(settings_signature).path_join("%d_%d_%d%s" % [coord.x, coord.y, coord.z, FILE_EXTENSION])


func _signature_dir(settings_signature: String) -> String:
	var signature_hash := settings_signature.sha256_text()
	_last_signature_hash = signature_hash
	return root_path.path_join(signature_hash)


func _ensure_dir(path: String) -> bool:
	if path.is_empty():
		return false
	if DirAccess.dir_exists_absolute(path):
		return true
	return DirAccess.make_dir_recursive_absolute(path) == OK


func _prepare_artifact_for_store_locked(coord: Vector3i, settings_signature: String, artifact: Dictionary) -> Dictionary:
	var artifact_path := _artifact_path(coord, settings_signature)
	var sanitized: Dictionary = _strip_resource_objects(artifact)
	if not enabled or max_entries_per_signature <= 0:
		return sanitized
	var signature_dir := artifact_path.get_base_dir()
	if not _ensure_dir(signature_dir):
		return sanitized
	if _artifact_has_resource_sidecar_objects(artifact):
		_remove_artifact_sidecars(artifact_path)
		_prepare_result_resource_sidecars(artifact, sanitized, artifact_path, "result_t", "terrain")
		_prepare_result_resource_sidecars(artifact, sanitized, artifact_path, "result_w", "water")
	elif not _artifact_has_resource_sidecar_paths(sanitized):
		_remove_artifact_sidecars(artifact_path)
	return sanitized


func _artifact_has_resource_sidecar_objects(artifact: Dictionary) -> bool:
	for result_key in ["result_t", "result_w"]:
		var result_variant: Variant = artifact.get(result_key, {})
		if not (result_variant is Dictionary):
			continue
		var result: Dictionary = result_variant
		var mesh_variant: Variant = result.get("mesh_resource", null)
		if mesh_variant is ArrayMesh and (mesh_variant as ArrayMesh).get_surface_count() > 0:
			return true
		var shape_variant: Variant = result.get("shape_resource", null)
		if shape_variant is ConcavePolygonShape3D:
			return true
	return false


func _artifact_has_resource_sidecar_paths(artifact: Dictionary) -> bool:
	for result_key in ["result_t", "result_w"]:
		var result_variant: Variant = artifact.get(result_key, {})
		if not (result_variant is Dictionary):
			continue
		var result: Dictionary = result_variant
		if not str(result.get("mesh_resource_path", "")).is_empty():
			return true
		if not str(result.get("shape_resource_path", "")).is_empty():
			return true
	return false


func _prepare_result_resource_sidecars(source_artifact: Dictionary, sanitized_artifact: Dictionary, artifact_path: String, result_key: String, layer_name: String) -> void:
	var source_variant: Variant = source_artifact.get(result_key, {})
	var sanitized_variant: Variant = sanitized_artifact.get(result_key, {})
	if not (source_variant is Dictionary) or not (sanitized_variant is Dictionary):
		return
	var source_result: Dictionary = source_variant
	var sanitized_result: Dictionary = sanitized_variant
	var mesh_variant: Variant = source_result.get("mesh_resource", null)
	if mesh_variant is ArrayMesh and (mesh_variant as ArrayMesh).get_surface_count() > 0:
		var mesh_path := _artifact_resource_sidecar_path(artifact_path, layer_name, "mesh")
		if _save_sidecar_resource(mesh_variant as Resource, mesh_path):
			sanitized_result["mesh_resource_path"] = mesh_path
			sanitized_result["ready_mesh_resource"] = true
		else:
			sanitized_result.erase("ready_mesh_resource")
			sanitized_result.erase("mesh_resource_path")
	var shape_variant: Variant = source_result.get("shape_resource", null)
	if shape_variant is ConcavePolygonShape3D:
		var shape_path := _artifact_resource_sidecar_path(artifact_path, layer_name, "shape")
		if _save_sidecar_resource(shape_variant as Resource, shape_path):
			sanitized_result["shape_resource_path"] = shape_path
			sanitized_result["ready_collision_resource"] = true
		else:
			sanitized_result.erase("ready_collision_resource")
			sanitized_result.erase("shape_resource_path")
	sanitized_artifact[result_key] = sanitized_result


func _strip_resource_objects(value: Variant) -> Variant:
	if value is Dictionary:
		var source: Dictionary = value
		var stripped := {}
		for key in source.keys():
			var key_text := str(key)
			if key_text == "mesh_resource" or key_text == "shape_resource":
				continue
			stripped[key] = _strip_resource_objects(source[key])
		return stripped
	if value is Array:
		var source_array: Array = value
		var stripped_array: Array = []
		for item in source_array:
			stripped_array.append(_strip_resource_objects(item))
		return stripped_array
	if value is Resource:
		return null
	return value


func _artifact_resource_sidecar_path(artifact_path: String, layer_name: String, resource_name: String) -> String:
	var base_path := artifact_path
	if base_path.ends_with(FILE_EXTENSION):
		base_path = base_path.substr(0, base_path.length() - FILE_EXTENSION.length())
	return "%s_%s_%s%s" % [base_path, layer_name, resource_name, RESOURCE_EXTENSION]


func _artifact_sidecar_paths(artifact_path: String) -> Array[String]:
	return [
		_artifact_resource_sidecar_path(artifact_path, "terrain", "mesh"),
		_artifact_resource_sidecar_path(artifact_path, "terrain", "shape"),
		_artifact_resource_sidecar_path(artifact_path, "water", "mesh"),
		_artifact_resource_sidecar_path(artifact_path, "water", "shape")
	]


func _save_sidecar_resource(resource: Resource, path: String) -> bool:
	if resource == null or path.is_empty():
		return false
	return ResourceSaver.save(resource, path) == OK


func _trim_signature_dir(signature_dir: String) -> void:
	if max_entries_per_signature <= 0:
		return
	var dir := DirAccess.open(signature_dir)
	if dir == null:
		return

	var files: Array[Dictionary] = []
	var total_bytes := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.ends_with(FILE_EXTENSION):
			var file_path := signature_dir.path_join(file_name)
			var file_bytes := _read_file_size(file_path) + _read_sidecar_bytes(file_path)
			total_bytes += file_bytes
			files.append({
				"name": file_name,
				"modified": FileAccess.get_modified_time(file_path),
				"bytes": file_bytes
			})
		file_name = dir.get_next()
	dir.list_dir_end()

	_max_observed_signature_bytes = maxi(_max_observed_signature_bytes, total_bytes)
	_last_trim_removed_bytes = 0
	var over_entry_budget := files.size() > max_entries_per_signature
	var over_byte_budget := max_bytes_per_signature > 0 and total_bytes > max_bytes_per_signature
	if not over_entry_budget and not over_byte_budget:
		_last_signature_entry_count = files.size()
		_last_signature_bytes = total_bytes
		return

	files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var modified_a := int(a.get("modified", 0))
		var modified_b := int(b.get("modified", 0))
		if modified_a == modified_b:
			return str(a.get("name", "")) < str(b.get("name", ""))
		return modified_a < modified_b
	)
	var remaining_count := files.size()
	for file in files:
		if remaining_count <= max_entries_per_signature \
			and (max_bytes_per_signature <= 0 or total_bytes <= max_bytes_per_signature):
			break
		var file_bytes := int(file.get("bytes", 0))
		var file_path := signature_dir.path_join(str(file.get("name", "")))
		_remove_file(file_path)
		if not FileAccess.file_exists(file_path):
			_eviction_count += 1
			remaining_count -= 1
			total_bytes = maxi(total_bytes - file_bytes, 0)
			_last_trim_removed_bytes += file_bytes
	_last_signature_entry_count = remaining_count
	_last_signature_bytes = total_bytes


func _read_file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var length := int(file.get_length())
	file.close()
	return length


func _read_sidecar_bytes(artifact_path: String) -> int:
	var total := 0
	for sidecar_path in _artifact_sidecar_paths(artifact_path):
		total += _read_file_size(sidecar_path)
	return total


func _remove_dir_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue
		var child_path := path.path_join(file_name)
		if dir.current_is_dir():
			_remove_dir_contents(child_path)
			dir.remove(file_name)
		else:
			dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()


func _remove_file(path: String) -> void:
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return
	dir.remove(path.get_file())
	_remove_artifact_sidecars(path)


func _remove_artifact_sidecars(artifact_path: String) -> void:
	for sidecar_path in _artifact_sidecar_paths(artifact_path):
		var dir := DirAccess.open(sidecar_path.get_base_dir())
		if dir:
			dir.remove(sidecar_path.get_file())


func _elapsed_ms(start_usec: int) -> float:
	return float(Time.get_ticks_usec() - start_usec) / 1000.0
