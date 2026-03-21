extends RefCounted

const RES_PREFAB_DIR := "res://world_prefabs/"
const USER_PREFAB_DIR := "user://world_prefabs/"

const OBJECT_INFO := {
	1: {
		"name": "Cardboard Box",
		"size": Vector3(1.0, 1.0, 1.0),
		"color": Color(0.71, 0.58, 0.40, 1.0)
	},
	2: {
		"name": "Long Crate",
		"size": Vector3(2.0, 1.0, 1.0),
		"color": Color(0.47, 0.30, 0.16, 1.0)
	},
	3: {
		"name": "Wooden Table",
		"size": Vector3(2.0, 1.0, 1.0),
		"color": Color(0.58, 0.40, 0.23, 1.0)
	},
	4: {
		"name": "Door",
		"size": Vector3(1.0, 2.0, 1.0),
		"color": Color(0.51, 0.67, 0.40, 1.0)
	},
	5: {
		"name": "Window",
		"size": Vector3(1.0, 1.0, 1.0),
		"color": Color(0.42, 0.72, 0.88, 1.0)
	},
	6: {
		"name": "Heavy Pistol",
		"size": Vector3(1.0, 1.0, 1.0),
		"color": Color(0.82, 0.79, 0.24, 1.0)
	}
}


static func list_prefabs() -> Array:
	var prefabs: Array = []
	var seen: Dictionary = {}
	_collect_prefabs_from_dir(RES_PREFAB_DIR, "builtin", prefabs, seen)
	_collect_prefabs_from_dir(USER_PREFAB_DIR, "user", prefabs, seen)
	prefabs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("name", "")) < String(b.get("name", ""))
	)
	return prefabs


static func load_prefab(path: String) -> Dictionary:
	var result := {
		"ok": false,
		"path": path,
		"name": path.get_file().get_basename(),
		"errors": [],
		"warnings": []
	}

	if not FileAccess.file_exists(path):
		result["errors"] = ["Prefab file not found."]
		return result

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		result["errors"] = ["Failed to open prefab file."]
		return result

	var json := JSON.new()
	var parse_err := json.parse(file.get_as_text())
	if parse_err != OK or not json.get_data() is Dictionary:
		result["errors"] = ["Failed to parse prefab JSON."]
		return result

	return _parse_prefab_dict(json.get_data(), path)


static func get_object_info(object_id: int) -> Dictionary:
	if OBJECT_INFO.has(object_id):
		return OBJECT_INFO[object_id]
	return {
		"name": "Object %d" % object_id,
		"size": Vector3.ONE,
		"color": Color(0.88, 0.36, 0.78, 1.0)
	}


static func rotate_block_offset(offset: Vector3i, rotation: int) -> Vector3i:
	match posmod(rotation, 4):
		0:
			return offset
		1:
			return Vector3i(-offset.z, offset.y, offset.x)
		2:
			return Vector3i(-offset.x, offset.y, -offset.z)
		3:
			return Vector3i(offset.z, offset.y, -offset.x)
	return offset


static func rotate_vector_offset(offset: Vector3, rotation: int) -> Vector3:
	match posmod(rotation, 4):
		0:
			return offset
		1:
			return Vector3(-offset.z, offset.y, offset.x)
		2:
			return Vector3(-offset.x, offset.y, -offset.z)
		3:
			return Vector3(offset.z, offset.y, -offset.x)
	return offset


static func get_grid_correction(rotation: int) -> Vector3:
	match posmod(rotation, 4):
		1:
			return Vector3(1.0, 0.0, 0.0)
		2:
			return Vector3(1.0, 0.0, 1.0)
		3:
			return Vector3(0.0, 0.0, 1.0)
	return Vector3.ZERO


static func rotate_directional_meta(block_type: int, meta: int, rotation: int) -> int:
	if block_type == 4 and meta >= 0 and meta <= 3:
		return posmod(meta + rotation, 4)
	return meta


static func get_surface_rect(prefab: Dictionary) -> Dictionary:
	var placement: Dictionary = prefab.get("placement", {})
	var rect: Dictionary = placement.get("surface_footprint", {})
	if not rect.is_empty():
		return rect
	return _rect_from_bounds(prefab.get("bounds", {}))


static func get_reservation_rect(prefab: Dictionary) -> Dictionary:
	var placement: Dictionary = prefab.get("placement", {})
	var rect: Dictionary = placement.get("reservation_footprint", {})
	if not rect.is_empty():
		return rect
	return get_surface_rect(prefab)


static func rotate_rect(rect: Dictionary, rotation: int) -> Dictionary:
	if rect.is_empty():
		return {}

	var min_corner: Vector2i = rect.get("min", Vector2i.ZERO)
	var max_corner: Vector2i = rect.get("max", Vector2i.ZERO)
	var corners := [
		Vector3(float(min_corner.x), 0.0, float(min_corner.y)),
		Vector3(float(max_corner.x), 0.0, float(min_corner.y)),
		Vector3(float(min_corner.x), 0.0, float(max_corner.y)),
		Vector3(float(max_corner.x), 0.0, float(max_corner.y))
	]

	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for corner in corners:
		var rotated := rotate_vector_offset(corner, rotation)
		min_x = min(min_x, rotated.x)
		min_z = min(min_z, rotated.z)
		max_x = max(max_x, rotated.x)
		max_z = max(max_z, rotated.z)

	var min_vec := Vector2i(int(floor(min_x)), int(floor(min_z)))
	var max_vec := Vector2i(int(ceil(max_x)), int(ceil(max_z)))
	return {
		"min": min_vec,
		"max": max_vec,
		"footprint": Vector2i(max_vec.x - min_vec.x + 1, max_vec.y - min_vec.y + 1)
	}


static func rotate_volume(volume: Dictionary, rotation: int) -> Dictionary:
	if volume.is_empty():
		return {}

	var local_min: Vector3i = volume.get("min", Vector3i.ZERO)
	var local_max: Vector3i = volume.get("max", Vector3i.ZERO)
	var corners: Array = []
	for x in [local_min.x, local_max.x]:
		for y in [local_min.y, local_max.y]:
			for z in [local_min.z, local_max.z]:
				corners.append(Vector3i(x, y, z))

	var min_x := 999999
	var min_y := 999999
	var min_z := 999999
	var max_x := -999999
	var max_y := -999999
	var max_z := -999999
	for corner in corners:
		var rotated := rotate_block_offset(corner, rotation)
		min_x = min(min_x, rotated.x)
		min_y = min(min_y, rotated.y)
		min_z = min(min_z, rotated.z)
		max_x = max(max_x, rotated.x)
		max_y = max(max_y, rotated.y)
		max_z = max(max_z, rotated.z)

	return {
		"min": Vector3i(min_x, min_y, min_z),
		"max": Vector3i(max_x, max_y, max_z)
	}


static func _collect_prefabs_from_dir(dir_path: String, source: String, output: Array, seen: Dictionary) -> void:
	if dir_path.begins_with("user://") and not DirAccess.dir_exists_absolute(dir_path):
		return

	var dir := DirAccess.open(dir_path)
	if not dir:
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var prefab_name := file_name.get_basename()
			if not seen.has(prefab_name):
				var entry := {
					"name": prefab_name,
					"path": dir_path.path_join(file_name),
					"source": source
				}
				output.append(entry)
				seen[prefab_name] = true
		file_name = dir.get_next()
	dir.list_dir_end()


static func _parse_prefab_dict(data: Dictionary, path: String) -> Dictionary:
	var errors: Array = []
	var warnings: Array = []
	var declared_size := _parse_size(data.get("size", []))
	var layer_result := _parse_layers(data.get("layers", []))
	errors.append_array(layer_result.get("errors", []))
	warnings.append_array(layer_result.get("warnings", []))

	var cells: Array = layer_result.get("cells", [])
	var actual_size: Vector3i = layer_result.get("actual_size", Vector3i.ONE)
	if declared_size != actual_size:
		warnings.append(
			"Declared size %s does not match parsed layers %s." % [declared_size, actual_size]
		)

	var bounds := _compute_bounds(cells)
	var placement := _parse_placement(data.get("placement", {}), declared_size, bounds)
	var objects := _parse_objects(data.get("objects", []))

	return {
		"ok": errors.is_empty(),
		"path": path,
		"name": str(data.get("name", path.get_file().get_basename())),
		"version": int(data.get("version", 0)),
		"size": declared_size,
		"actual_size": actual_size,
		"cells": cells,
		"objects": objects,
		"placement": placement,
		"bounds": bounds,
		"errors": errors,
		"warnings": warnings,
		"stats": {
			"block_count": cells.size(),
			"object_count": objects.size()
		}
	}


static func _parse_size(raw_size: Variant) -> Vector3i:
	if raw_size is Array and raw_size.size() >= 3:
		return Vector3i(
			max(1, int(raw_size[0])),
			max(1, int(raw_size[1])),
			max(1, int(raw_size[2]))
		)
	return Vector3i.ONE


static func _parse_layers(raw_layers: Variant) -> Dictionary:
	var result := {
		"cells": [],
		"actual_size": Vector3i.ONE,
		"errors": [],
		"warnings": []
	}
	if not raw_layers is Array:
		result["errors"] = ["Prefab has no layer array."]
		return result

	var cells: Array = []
	var current_y := 0
	var current_z := 0
	var max_width := 0
	var max_depth := 0
	var saw_row := false

	for raw_row in raw_layers:
		var row := str(raw_row).strip_edges()
		if row.is_empty():
			continue
		if row == "---":
			max_depth = max(max_depth, current_z)
			current_y += 1
			current_z = 0
			continue

		saw_row = true
		var tokens := row.split(" ", false)
		max_width = max(max_width, tokens.size())
		for x in range(tokens.size()):
			var token := tokens[x].strip_edges()
			if token == ".":
				continue
			var parsed := _parse_block_token(token)
			if parsed.is_empty():
				result["warnings"].append("Skipping unrecognized token '%s'." % token)
				continue
			cells.append({
				"pos": Vector3i(x, current_y, current_z),
				"type": int(parsed.get("type", 0)),
				"meta": int(parsed.get("meta", 0))
			})
		current_z += 1

	max_depth = max(max_depth, current_z)
	var actual_height := current_y + (1 if saw_row else 0)
	result["cells"] = cells
	result["actual_size"] = Vector3i(max(1, max_width), max(1, actual_height), max(1, max_depth))
	return result


static func _parse_block_token(token: String) -> Dictionary:
	var trimmed := token.strip_edges()
	if trimmed.begins_with("[") and trimmed.ends_with("]"):
		var content := trimmed.substr(1, trimmed.length() - 2)
		if content.contains(":"):
			var parts := content.split(":")
			if parts.size() >= 2:
				return {
					"type": int(parts[0]),
					"meta": int(parts[1])
				}
		return {
			"type": int(content),
			"meta": 0
		}
	if trimmed.is_valid_int():
		return {
			"type": int(trimmed),
			"meta": 0
		}
	return {}


static func _compute_bounds(cells: Array) -> Dictionary:
	if cells.is_empty():
		return {
			"min": Vector3i.ZERO,
			"max": Vector3i.ZERO
		}

	var min_pos: Vector3i = cells[0].get("pos", Vector3i.ZERO)
	var max_pos: Vector3i = min_pos
	for cell in cells:
		var pos: Vector3i = cell.get("pos", Vector3i.ZERO)
		min_pos.x = min(min_pos.x, pos.x)
		min_pos.y = min(min_pos.y, pos.y)
		min_pos.z = min(min_pos.z, pos.z)
		max_pos.x = max(max_pos.x, pos.x)
		max_pos.y = max(max_pos.y, pos.y)
		max_pos.z = max(max_pos.z, pos.z)
	return {
		"min": min_pos,
		"max": max_pos
	}


static func _parse_objects(raw_objects: Variant) -> Array:
	var result: Array = []
	if not raw_objects is Array:
		return result

	for raw_object in raw_objects:
		if raw_object is Array and raw_object.size() >= 5:
			result.append({
				"object_id": int(raw_object[0]),
				"x": float(raw_object[1]),
				"y": float(raw_object[2]),
				"z": float(raw_object[3]),
				"rotation": int(raw_object[4]),
				"fractional_y": float(raw_object[5]) if raw_object.size() > 5 else 0.0
			})
	return result


static func _parse_placement(raw_placement: Variant, declared_size: Vector3i, bounds: Dictionary) -> Dictionary:
	var default_rect := _rect_from_bounds(bounds)
	var placement := {
		"grade_y": 0,
		"auto_carve_volume": false,
		"excavation_volumes": [],
		"surface_footprint": default_rect,
		"reservation_footprint": default_rect
	}
	if not raw_placement is Dictionary:
		return placement

	var source: Dictionary = raw_placement
	placement["grade_y"] = int(source.get("grade_y", 0))
	placement["auto_carve_volume"] = bool(source.get("auto_carve_volume", false))
	placement["excavation_volumes"] = _parse_volumes(source.get("excavation_volumes", []), declared_size)

	var surface_rect := _parse_rect_2d(source.get("surface_footprint", {}), declared_size)
	if not surface_rect.is_empty():
		placement["surface_footprint"] = surface_rect

	var reservation_rect := _parse_rect_2d(source.get("reservation_footprint", {}), declared_size)
	if not reservation_rect.is_empty():
		placement["reservation_footprint"] = reservation_rect

	return placement


static func _parse_volumes(raw_volumes: Variant, declared_size: Vector3i) -> Array:
	var result: Array = []
	if not raw_volumes is Array:
		return result

	for raw_volume in raw_volumes:
		if not raw_volume is Dictionary:
			continue
		var local_min := _parse_vec3i(raw_volume.get("min", []))
		var local_max := _parse_vec3i(raw_volume.get("max", []))
		if local_min == null or local_max == null:
			continue

		var clamped_min := Vector3i(
			clampi(local_min.x, 0, max(0, declared_size.x - 1)),
			clampi(local_min.y, 0, max(0, declared_size.y - 1)),
			clampi(local_min.z, 0, max(0, declared_size.z - 1))
		)
		var clamped_max := Vector3i(
			clampi(local_max.x, 0, max(0, declared_size.x - 1)),
			clampi(local_max.y, 0, max(0, declared_size.y - 1)),
			clampi(local_max.z, 0, max(0, declared_size.z - 1))
		)

		result.append({
			"min": Vector3i(
				min(clamped_min.x, clamped_max.x),
				min(clamped_min.y, clamped_max.y),
				min(clamped_min.z, clamped_max.z)
			),
			"max": Vector3i(
				max(clamped_min.x, clamped_max.x),
				max(clamped_min.y, clamped_max.y),
				max(clamped_min.z, clamped_max.z)
			)
		})
	return result


static func _parse_rect_2d(raw_rect: Variant, declared_size: Vector3i) -> Dictionary:
	if not raw_rect is Dictionary:
		return {}

	var local_min := _parse_vec2i(raw_rect.get("min", []))
	var local_max := _parse_vec2i(raw_rect.get("max", []))
	if local_min == null or local_max == null:
		return {}

	var clamped_min := Vector2i(
		clampi(local_min.x, 0, max(0, declared_size.x - 1)),
		clampi(local_min.y, 0, max(0, declared_size.z - 1))
	)
	var clamped_max := Vector2i(
		clampi(local_max.x, 0, max(0, declared_size.x - 1)),
		clampi(local_max.y, 0, max(0, declared_size.z - 1))
	)
	var min_vec := Vector2i(min(clamped_min.x, clamped_max.x), min(clamped_min.y, clamped_max.y))
	var max_vec := Vector2i(max(clamped_min.x, clamped_max.x), max(clamped_min.y, clamped_max.y))
	return {
		"min": min_vec,
		"max": max_vec,
		"footprint": Vector2i(max_vec.x - min_vec.x + 1, max_vec.y - min_vec.y + 1)
	}


static func _rect_from_bounds(bounds: Dictionary) -> Dictionary:
	if bounds.is_empty():
		return {
			"min": Vector2i.ZERO,
			"max": Vector2i.ZERO,
			"footprint": Vector2i.ONE
		}
	var min_pos: Vector3i = bounds.get("min", Vector3i.ZERO)
	var max_pos: Vector3i = bounds.get("max", Vector3i.ZERO)
	return {
		"min": Vector2i(min_pos.x, min_pos.z),
		"max": Vector2i(max_pos.x, max_pos.z),
		"footprint": Vector2i(max_pos.x - min_pos.x + 1, max_pos.z - min_pos.z + 1)
	}


static func _parse_vec3i(value: Variant) -> Variant:
	if value is Array and value.size() >= 3:
		return Vector3i(int(value[0]), int(value[1]), int(value[2]))
	return null


static func _parse_vec2i(value: Variant) -> Variant:
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return null
