extends RefCounted
class_name PrefabGeometry

const ObjectRegistry = preload("res://world_building_system/object_registry.gd")
const RES_PREFAB_DIR := "res://world_prefabs/"
const USER_PREFAB_DIR := "user://world_prefabs/"
const EXCAVATION_SAFETY_PADDING: int = 1

static var _geometry_cache: Dictionary = {}
static var _rotated_bounds_cache: Dictionary = {}
static var _rotated_precise_carve_cache: Dictionary = {}
static var _rotated_excavation_segments_cache: Dictionary = {}

static func get_prefab_geometry(prefab_name: String) -> Dictionary:
	if _geometry_cache.has(prefab_name):
		return _geometry_cache[prefab_name]

	var geometry := _build_prefab_geometry(prefab_name)
	_geometry_cache[prefab_name] = geometry
	return geometry

static func get_rotated_bounds(prefab_name: String, rotation: int) -> Dictionary:
	var key := "%s:%d" % [prefab_name, rotation]
	if _rotated_bounds_cache.has(key):
		return _rotated_bounds_cache[key]

	var geometry := get_prefab_geometry(prefab_name)
	var offsets: Array = geometry.get("offsets", [])
	if offsets.is_empty():
		var empty_bounds := {
			"min": Vector3i.ZERO,
			"max": Vector3i.ZERO,
			"footprint": Vector2i.ONE
		}
		_rotated_bounds_cache[key] = empty_bounds
		return empty_bounds

	var min_x := 999999
	var min_y := 999999
	var min_z := 999999
	var max_x := -999999
	var max_y := -999999
	var max_z := -999999
	for offset in offsets:
		var rotated := _rotate_offset(offset, rotation)
		min_x = min(min_x, rotated.x)
		min_y = min(min_y, rotated.y)
		min_z = min(min_z, rotated.z)
		max_x = max(max_x, rotated.x)
		max_y = max(max_y, rotated.y)
		max_z = max(max_z, rotated.z)

	var bounds := {
		"min": Vector3i(min_x, min_y, min_z),
		"max": Vector3i(max_x, max_y, max_z),
		"footprint": Vector2i(max_x - min_x + 1, max_z - min_z + 1)
	}
	_rotated_bounds_cache[key] = bounds
	return bounds

static func get_rotated_footprint(prefab_name: String, rotation: int) -> Vector2i:
	return get_rotated_bounds(prefab_name, rotation).get("footprint", Vector2i.ONE)

static func get_rotated_surface_bounds(prefab_name: String, rotation: int) -> Dictionary:
	var placement := get_placement_profile(prefab_name)
	var local_rect: Dictionary = placement.get("surface_footprint", {})
	if local_rect.is_empty():
		var full_bounds := get_rotated_bounds(prefab_name, rotation)
		var full_min: Vector3i = full_bounds.get("min", Vector3i.ZERO)
		var full_max: Vector3i = full_bounds.get("max", Vector3i.ZERO)
		return {
			"min": Vector2i(full_min.x, full_min.z),
			"max": Vector2i(full_max.x, full_max.z),
			"footprint": full_bounds.get("footprint", Vector2i.ONE)
		}
	return _rotate_local_rect_bounds(local_rect, rotation)

static func get_rotated_surface_footprint(prefab_name: String, rotation: int) -> Vector2i:
	return get_rotated_surface_bounds(prefab_name, rotation).get("footprint", Vector2i.ONE)

static func get_rotated_reservation_bounds(prefab_name: String, rotation: int) -> Dictionary:
	var placement := get_placement_profile(prefab_name)
	var local_rect: Dictionary = placement.get("reservation_footprint", {})
	if local_rect.is_empty():
		return get_rotated_surface_bounds(prefab_name, rotation)
	return _rotate_local_rect_bounds(local_rect, rotation)

static func get_rotated_reservation_footprint(prefab_name: String, rotation: int) -> Vector2i:
	return get_rotated_reservation_bounds(prefab_name, rotation).get("footprint", Vector2i.ONE)

static func get_rotated_precise_carve_segments(prefab_name: String, rotation: int) -> Array:
	var key := "%s:%d" % [prefab_name, rotation]
	if _rotated_precise_carve_cache.has(key):
		return _rotated_precise_carve_cache[key]

	var geometry := get_prefab_geometry(prefab_name)
	var placement_profile: Dictionary = geometry.get("placement_profile", _default_placement_profile())
	var solid_cells: Dictionary = geometry.get("solid_cells", {})
	var stair_cells := _vector3i_array_from_variant(geometry.get("stair_cells", []))
	var declared_size: Vector3i = geometry.get("declared_size", Vector3i.ONE)
	var min_y: int = int(geometry.get("min_y", 0))
	var grade_y: int = int(placement_profile.get("grade_y", min_y))
	if not bool(placement_profile.get("auto_carve_volume", false)) or grade_y <= min_y or solid_cells.is_empty():
		var empty_segments: Array = []
		_rotated_precise_carve_cache[key] = empty_segments
		return empty_segments

	var enclosed_below_grade_cells := _get_enclosed_below_grade_empty_cells(solid_cells, declared_size, min_y, grade_y)
	var required_carve_cell_set := _build_required_below_grade_excavation_cells(enclosed_below_grade_cells, stair_cells, min_y, grade_y)
	var local_carve_cells: Array = []
	for cell in required_carve_cell_set.keys():
		local_carve_cells.append(cell)
	var rotated_segments := _build_rotated_carve_segments(local_carve_cells, rotation)
	_rotated_precise_carve_cache[key] = rotated_segments
	return rotated_segments

static func get_rotated_excavation_segments(prefab_name: String, rotation: int) -> Array:
	var key := "%s:%d" % [prefab_name, rotation]
	if _rotated_excavation_segments_cache.has(key):
		return _rotated_excavation_segments_cache[key]

	var geometry := get_prefab_geometry(prefab_name)
	var placement_profile: Dictionary = geometry.get("placement_profile", _default_placement_profile())
	var excavation_volumes: Array = placement_profile.get("excavation_volumes", [])
	var rotated_segments: Array = []
	if not excavation_volumes.is_empty():
		var excavated_cells := _build_local_cell_set_from_volumes(excavation_volumes)
		rotated_segments = _build_rotated_carve_segments(excavated_cells.keys(), rotation)
	else:
		rotated_segments = get_rotated_precise_carve_segments(prefab_name, rotation)

	_rotated_excavation_segments_cache[key] = rotated_segments
	return rotated_segments

static func get_placement_profile(prefab_name: String) -> Dictionary:
	return get_prefab_geometry(prefab_name).get("placement_profile", _default_placement_profile())

static func get_prefab_validation(prefab_name: String) -> Dictionary:
	return get_prefab_geometry(prefab_name).get("validation", {
		"valid_for_spawn": true,
		"errors": [],
		"warnings": []
	})

static func get_spawn_origin_for_occupied_min(prefab_name: String, occupied_min: Vector3, rotation: int) -> Vector3:
	var bounds := get_rotated_bounds(prefab_name, rotation)
	var min_offset: Vector3i = bounds.get("min", Vector3i.ZERO)
	var placement := get_placement_profile(prefab_name)
	var grade_y := float(placement.get("grade_y", 0))
	return occupied_min - Vector3(min_offset.x, grade_y, min_offset.z)

static func get_spawn_origin_for_surface_min(prefab_name: String, surface_min: Vector3, rotation: int) -> Vector3:
	var bounds := get_rotated_surface_bounds(prefab_name, rotation)
	var min_offset: Vector2i = bounds.get("min", Vector2i.ZERO)
	var placement := get_placement_profile(prefab_name)
	var grade_y := float(placement.get("grade_y", 0))
	return surface_min - Vector3(min_offset.x, grade_y, min_offset.y)

static func get_primary_door_world_center(prefab_name: String, spawn_origin: Vector3, rotation: int) -> Variant:
	var geometry := get_prefab_geometry(prefab_name)
	var objects: Array = geometry.get("objects", [])
	for obj in objects:
		if int(obj.get("object_id", -1)) != 4:
			continue

		var vec_offset := Vector3(
			float(obj.get("x", 0.0)),
			float(obj.get("y", 0.0)),
			float(obj.get("z", 0.0))
		)
		var rotated_corner := _rotate_vector3_offset(vec_offset, rotation)
		var grid_correction := _get_grid_correction(rotation)
		var target_corner := spawn_origin + rotated_corner + grid_correction

		var obj_def := ObjectRegistry.get_object(4)
		var obj_size := Vector3(1.0, 2.0, 1.0)
		if not obj_def.is_empty():
			var size: Vector3i = obj_def.get("size", Vector3i(1, 2, 1))
			obj_size = Vector3(float(size.x), float(size.y), float(size.z))

		var obj_local_rot := int(obj.get("rotation", 0))
		var local_size := obj_size
		if obj_local_rot == 1 or obj_local_rot == 3:
			local_size = Vector3(obj_size.z, obj_size.y, obj_size.x)

		var half_size := local_size * 0.5
		var rotated_half_size := _rotate_vector3_offset(half_size, rotation)
		rotated_half_size.y = 0.0
		return target_corner + rotated_half_size

	if prefab_name == "small_house":
		return spawn_origin + _rotate_vector3_offset(Vector3(1.5, 1.0, 0.0), rotation)

	return null

static func _build_prefab_geometry(prefab_name: String) -> Dictionary:
	if prefab_name == "small_house":
		var offsets: Array = [
			Vector3i(1, 0, -1),
			Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0),
			Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(2, 0, 1),
			Vector3i(0, 0, 2), Vector3i(1, 0, 2), Vector3i(2, 0, 2),
			Vector3i(0, 1, 0), Vector3i(2, 1, 0), Vector3i(0, 1, 1), Vector3i(2, 1, 1),
			Vector3i(0, 1, 2), Vector3i(1, 1, 2), Vector3i(2, 1, 2),
			Vector3i(0, 2, 0), Vector3i(2, 2, 0), Vector3i(0, 2, 1), Vector3i(2, 2, 1),
			Vector3i(0, 2, 2), Vector3i(1, 2, 2), Vector3i(2, 2, 2),
			Vector3i(0, 3, 0), Vector3i(1, 3, 0), Vector3i(2, 3, 0),
			Vector3i(0, 3, 1), Vector3i(1, 3, 1), Vector3i(2, 3, 1),
			Vector3i(0, 3, 2), Vector3i(1, 3, 2), Vector3i(2, 3, 2)
		]
		return {
			"name": prefab_name,
			"offsets": offsets,
			"placement_profile": _default_placement_profile(),
			"validation": {
				"valid_for_spawn": true,
				"errors": [],
				"warnings": []
			},
			"objects": [{
				"object_id": 4,
				"x": 1.0,
				"y": 1.0,
				"z": 0.0,
				"rotation": 0
			}]
		}

	var data := _load_prefab_json(prefab_name)
	if data.is_empty():
		return {
			"name": prefab_name,
			"offsets": [Vector3i.ZERO],
			"placement_profile": _default_placement_profile(),
			"validation": {
				"valid_for_spawn": false,
				"errors": ["missing prefab data"],
				"warnings": []
			}
		}

	var layer_info := _parse_layer_info(data.get("layers", []))
	var offsets: Array = layer_info.get("offsets", [])
	if offsets.is_empty():
		var size_arr: Array = data.get("size", [1, 1, 1])
		var sx := int(size_arr[0]) if size_arr.size() > 0 else 1
		var sy := int(size_arr[1]) if size_arr.size() > 1 else 1
		var sz := int(size_arr[2]) if size_arr.size() > 2 else 1
		for x in range(sx):
			for y in range(sy):
				for z in range(sz):
					offsets.append(Vector3i(x, y, z))

	var declared_size := _parse_declared_size(data)
	var placement_profile := _parse_placement_profile(data, offsets, declared_size)
	var objects := _parse_compact_objects(data.get("objects", []))
	var min_y := 0
	if not offsets.is_empty():
		min_y = offsets[0].y
		for offset in offsets:
			min_y = mini(min_y, offset.y)

	return {
		"name": prefab_name,
		"offsets": offsets,
		"objects": objects,
		"placement_profile": placement_profile,
		"declared_size": declared_size,
		"solid_cells": layer_info.get("solid_cells", {}),
		"min_y": min_y,
		"validation": _validate_prefab_geometry(prefab_name, offsets, objects, placement_profile, layer_info, declared_size)
	}

static func _load_prefab_json(prefab_name: String) -> Dictionary:
	for dir_path in [RES_PREFAB_DIR, USER_PREFAB_DIR]:
		var path: String = dir_path + prefab_name + ".json"
		if not FileAccess.file_exists(path):
			continue
		var file := FileAccess.open(path, FileAccess.READ)
		if not file:
			continue
		var json := JSON.new()
		var parse_err := json.parse(file.get_as_text())
		file.close()
		if parse_err == OK and json.get_data() is Dictionary:
			return json.get_data()
	return {}

static func _parse_block_offsets(layers: Array) -> Array:
	var offsets: Array = []
	var y := 0
	var z := 0
	for layer_str in layers:
		var line := str(layer_str).strip_edges()
		if line == "---":
			y += 1
			z = 0
			continue
		var tokens := line.split(" ", false)
		var x := 0
		for token in tokens:
			if _is_filled_token(token.strip_edges()):
				offsets.append(Vector3i(x, y, z))
			x += 1
		z += 1
	return offsets

static func _parse_declared_size(data: Dictionary) -> Vector3i:
	var size_arr: Array = data.get("size", [1, 1, 1])
	return Vector3i(
		int(size_arr[0]) if size_arr.size() > 0 else 1,
		int(size_arr[1]) if size_arr.size() > 1 else 1,
		int(size_arr[2]) if size_arr.size() > 2 else 1
	)

static func _vector3i_array_from_variant(value: Variant) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if not (value is Array):
		return result
	for item in value:
		if item is Vector3i:
			result.append(item)
	return result

static func _parse_layer_info(layers: Array) -> Dictionary:
	var offsets: Array = []
	var solid_cells: Dictionary = {}
	var stair_cells: Array[Vector3i] = []
	var row_widths: Array = []
	var rows_per_slice: Array = []
	var max_width := 0
	var y := 0
	var z := 0
	var rows_in_slice := 0
	for layer_str in layers:
		var line := str(layer_str).strip_edges()
		if line == "---":
			rows_per_slice.append(rows_in_slice)
			rows_in_slice = 0
			y += 1
			z = 0
			continue
		var tokens := line.split(" ", false)
		row_widths.append(tokens.size())
		max_width = maxi(max_width, tokens.size())
		var x := 0
		for token in tokens:
			var trimmed := token.strip_edges()
			if _is_filled_token(trimmed):
				var cell := Vector3i(x, y, z)
				offsets.append(cell)
				var parsed := _parse_block_token(trimmed)
				solid_cells[cell] = parsed
				if int(parsed.get("type", -1)) == 4:
					stair_cells.append(cell)
			x += 1
		z += 1
		rows_in_slice += 1
	rows_per_slice.append(rows_in_slice)
	var max_rows := 0
	for count in rows_per_slice:
		max_rows = maxi(max_rows, int(count))
	return {
		"offsets": offsets,
		"solid_cells": solid_cells,
		"stair_cells": stair_cells,
		"row_widths": row_widths,
		"rows_per_slice": rows_per_slice,
		"actual_size": Vector3i(max_width, rows_per_slice.size(), max_rows)
	}

static func _is_filled_token(token: String) -> bool:
	return token != "" and token != "."

static func _parse_block_token(token: String) -> Dictionary:
	if token == "" or token == ".":
		return {}
	if token.begins_with("[") and token.ends_with("]"):
		var content := token.substr(1, token.length() - 2)
		if ":" in content:
			var parts := content.split(":")
			return {
				"type": int(parts[0]),
				"meta": int(parts[1])
			}
		return {
			"type": int(content),
			"meta": 0
		}
	return {
		"type": int(token),
		"meta": 0
	}

static func _parse_compact_objects(compact: Array) -> Array:
	var result: Array = []
	for obj in compact:
		if obj is Array and obj.size() >= 5:
			result.append({
				"object_id": int(obj[0]),
				"x": float(obj[1]),
				"y": float(obj[2]),
				"z": float(obj[3]),
				"rotation": int(obj[4])
			})
	return result

static func _default_placement_profile() -> Dictionary:
	return {
		"grade_y": 0,
		"auto_carve_volume": false,
		"seal_foundation": true,
		"max_foundation_gap": 3.0,
		"require_windows": true,
		"excavation_volumes": [],
		"surface_footprint": {},
		"reservation_footprint": {}
	}

static func _parse_placement_profile(data: Dictionary, offsets: Array, declared_size: Vector3i) -> Dictionary:
	var profile := _default_placement_profile()
	var placement: Dictionary = data.get("placement", {})
	if placement.is_empty():
		return profile

	var min_y := 0
	var max_y := 0
	if not offsets.is_empty():
		min_y = offsets[0].y
		max_y = offsets[0].y
		for offset in offsets:
			min_y = mini(min_y, offset.y)
			max_y = maxi(max_y, offset.y)
	var default_rect := _build_local_rect_from_offsets(offsets, declared_size)

	var grade_y := int(placement.get("grade_y", profile.get("grade_y", 0)))
	profile["grade_y"] = clampi(grade_y, min_y, maxi(min_y, max_y))
	profile["auto_carve_volume"] = bool(placement.get("auto_carve_volume", profile.get("grade_y", 0) > min_y))
	profile["seal_foundation"] = bool(placement.get("seal_foundation", profile.get("seal_foundation", true)))
	profile["max_foundation_gap"] = clampf(
		float(placement.get("max_foundation_gap", profile.get("max_foundation_gap", 3.0))),
		0.0,
		12.0
	)
	profile["require_windows"] = bool(placement.get("require_windows", profile.get("require_windows", true)))
	profile["excavation_volumes"] = _parse_local_volumes(
		placement.get("excavation_volumes", []),
		declared_size,
		min_y,
		max_y
	)
	profile["surface_footprint"] = _parse_local_rect_2d(
		placement.get("surface_footprint", {}),
		default_rect,
		declared_size
	)
	profile["reservation_footprint"] = _parse_local_rect_2d(
		placement.get("reservation_footprint", {}),
		default_rect,
		declared_size
	)
	return profile

static func _build_local_rect_from_offsets(offsets: Array, declared_size: Vector3i) -> Dictionary:
	if offsets.is_empty():
		var fallback_w := maxi(1, declared_size.x)
		var fallback_d := maxi(1, declared_size.z)
		return {
			"min": Vector2i.ZERO,
			"max": Vector2i(fallback_w - 1, fallback_d - 1),
			"footprint": Vector2i(fallback_w, fallback_d)
		}

	var first_offset: Vector3i = offsets[0]
	var min_x: int = first_offset.x
	var max_x: int = first_offset.x
	var min_z: int = first_offset.z
	var max_z: int = first_offset.z
	for offset in offsets:
		min_x = mini(min_x, offset.x)
		max_x = maxi(max_x, offset.x)
		min_z = mini(min_z, offset.z)
		max_z = maxi(max_z, offset.z)
	return {
		"min": Vector2i(min_x, min_z),
		"max": Vector2i(max_x, max_z),
		"footprint": Vector2i(max_x - min_x + 1, max_z - min_z + 1)
	}

static func _parse_local_rect_2d(raw_rect: Variant, fallback_rect: Dictionary, declared_size: Vector3i) -> Dictionary:
	if not (raw_rect is Dictionary):
		return fallback_rect
	var rect_in: Dictionary = raw_rect
	var min_arr: Array = rect_in.get("min", [])
	var max_arr: Array = rect_in.get("max", [])
	if min_arr.size() < 2 or max_arr.size() < 2:
		return fallback_rect

	var raw_min := Vector2i(int(min_arr[0]), int(min_arr[1]))
	var raw_max := Vector2i(int(max_arr[0]), int(max_arr[1]))
	var max_x_idx := maxi(0, declared_size.x - 1)
	var max_z_idx := maxi(0, declared_size.z - 1)
	var x0 := clampi(mini(raw_min.x, raw_max.x), 0, max_x_idx)
	var z0 := clampi(mini(raw_min.y, raw_max.y), 0, max_z_idx)
	var x1 := clampi(maxi(raw_min.x, raw_max.x), 0, max_x_idx)
	var z1 := clampi(maxi(raw_min.y, raw_max.y), 0, max_z_idx)
	return {
		"min": Vector2i(x0, z0),
		"max": Vector2i(x1, z1),
		"footprint": Vector2i(x1 - x0 + 1, z1 - z0 + 1)
	}

static func _parse_local_volumes(raw_volumes: Array, declared_size: Vector3i, min_y: int, max_y: int) -> Array:
	var result: Array = []
	if declared_size.x <= 0 or declared_size.y <= 0 or declared_size.z <= 0:
		return result

	for raw_volume in raw_volumes:
		if not (raw_volume is Dictionary):
			continue
		var volume: Dictionary = raw_volume
		var min_arr: Array = volume.get("min", [])
		var max_arr: Array = volume.get("max", [])
		if min_arr.size() < 3 or max_arr.size() < 3:
			continue

		var raw_min := Vector3i(int(min_arr[0]), int(min_arr[1]), int(min_arr[2]))
		var raw_max := Vector3i(int(max_arr[0]), int(max_arr[1]), int(max_arr[2]))
		var x0 := clampi(mini(raw_min.x, raw_max.x), 0, declared_size.x - 1)
		var y0 := clampi(mini(raw_min.y, raw_max.y), min_y, max_y)
		var z0 := clampi(mini(raw_min.z, raw_max.z), 0, declared_size.z - 1)
		var x1 := clampi(maxi(raw_min.x, raw_max.x), 0, declared_size.x - 1)
		var y1 := clampi(maxi(raw_min.y, raw_max.y), min_y, max_y)
		var z1 := clampi(maxi(raw_min.z, raw_max.z), 0, declared_size.z - 1)
		if x1 < x0 or y1 < y0 or z1 < z0:
			continue

		result.append({
			"min": Vector3i(x0, y0, z0),
			"max": Vector3i(x1, y1, z1)
		})
	return result

static func _get_enclosed_below_grade_empty_cells(solid_cells: Dictionary, declared_size: Vector3i, min_y: int, grade_y: int) -> Array:
	var result: Array = []
	if declared_size.x <= 0 or declared_size.z <= 0:
		return result

	for y in range(min_y, grade_y + 1):
		var exterior: Dictionary = {}
		var queue: Array = []

		for x in range(declared_size.x):
			_queue_exterior_empty_cell(Vector2i(x, 0), y, declared_size, solid_cells, exterior, queue)
			_queue_exterior_empty_cell(Vector2i(x, declared_size.z - 1), y, declared_size, solid_cells, exterior, queue)
		for z in range(declared_size.z):
			_queue_exterior_empty_cell(Vector2i(0, z), y, declared_size, solid_cells, exterior, queue)
			_queue_exterior_empty_cell(Vector2i(declared_size.x - 1, z), y, declared_size, solid_cells, exterior, queue)

		var cursor := 0
		while cursor < queue.size():
			var current: Vector2i = queue[cursor]
			cursor += 1
			for step in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var next_cell: Vector2i = current + step
				_queue_exterior_empty_cell(next_cell, y, declared_size, solid_cells, exterior, queue)

		for z in range(declared_size.z):
			for x in range(declared_size.x):
				var cell := Vector3i(x, y, z)
				if solid_cells.has(cell):
					continue
				var column_key := Vector2i(x, z)
				if exterior.has(column_key):
					continue
				result.append(cell)
	return result

static func _queue_exterior_empty_cell(cell_2d: Vector2i, y: int, declared_size: Vector3i, solid_cells: Dictionary,
		exterior: Dictionary, queue: Array) -> void:
	if cell_2d.x < 0 or cell_2d.x >= declared_size.x:
		return
	if cell_2d.y < 0 or cell_2d.y >= declared_size.z:
		return
	if exterior.has(cell_2d):
		return
	if solid_cells.has(Vector3i(cell_2d.x, y, cell_2d.y)):
		return
	exterior[cell_2d] = true
	queue.append(cell_2d)

static func _build_rotated_carve_segments(local_cells: Array, rotation: int) -> Array:
	var levels_by_column: Dictionary = {}
	for cell in local_cells:
		var rotated := _rotate_offset(cell, rotation)
		var key := Vector2i(rotated.x, rotated.z)
		if not levels_by_column.has(key):
			levels_by_column[key] = []
		var levels: Array = levels_by_column[key]
		levels.append(rotated.y)
		levels_by_column[key] = levels

	var result: Array = []
	for key in levels_by_column.keys():
		var levels: Array = levels_by_column[key]
		if levels.is_empty():
			continue
		levels.sort()
		var start_y := int(levels[0])
		var prev_y := start_y
		for idx in range(1, levels.size()):
			var current_y := int(levels[idx])
			if current_y <= prev_y + 1:
				prev_y = current_y
				continue
			result.append({
				"x": key.x,
				"z": key.y,
				"min_y": start_y,
				"max_y": prev_y
			})
			start_y = current_y
			prev_y = current_y
		result.append({
			"x": key.x,
			"z": key.y,
			"min_y": start_y,
			"max_y": prev_y
		})
	return result

static func _build_rotated_segments_from_volumes(volumes: Array, rotation: int) -> Array:
	var local_cells: Array = []
	for volume in volumes:
		var min_cell: Vector3i = volume.get("min", Vector3i.ZERO)
		var max_cell: Vector3i = volume.get("max", Vector3i.ZERO)
		for y in range(min_cell.y, max_cell.y + 1):
			for z in range(min_cell.z, max_cell.z + 1):
				for x in range(min_cell.x, max_cell.x + 1):
					local_cells.append(Vector3i(x, y, z))
	return _build_rotated_carve_segments(local_cells, rotation)

static func _build_local_cell_set_from_volumes(volumes: Array) -> Dictionary:
	var result: Dictionary = {}
	for volume in volumes:
		var min_cell: Vector3i = volume.get("min", Vector3i.ZERO)
		var max_cell: Vector3i = volume.get("max", Vector3i.ZERO)
		for y in range(min_cell.y, max_cell.y + 1):
			for z in range(min_cell.z, max_cell.z + 1):
				for x in range(min_cell.x, max_cell.x + 1):
					result[Vector3i(x, y, z)] = true
	return result

static func _inflate_local_cell_set(cell_set: Dictionary, padding: int) -> Dictionary:
	if padding <= 0 or cell_set.is_empty():
		return cell_set.duplicate()

	var result: Dictionary = {}
	for cell_var in cell_set.keys():
		var cell: Vector3i = cell_var
		for dz in range(-padding, padding + 1):
			for dy in range(-padding, padding + 1):
				for dx in range(-padding, padding + 1):
					result[cell + Vector3i(dx, dy, dz)] = true
	return result

static func _build_required_below_grade_excavation_cells(enclosed_cells: Array, stair_cells: Array, min_y: int, grade_y: int) -> Dictionary:
	var result: Dictionary = {}
	for cell in enclosed_cells:
		result[cell] = true
	var below_grade_stairs: Array[Vector3i] = []
	for cell in stair_cells:
		if cell.y <= 0 or cell.y > grade_y:
			continue
		below_grade_stairs.append(cell)
	for cell in _largest_stair_component(below_grade_stairs):
		result[cell] = true
	var min_y_by_column: Dictionary = {}
	var max_y_by_column: Dictionary = {}
	for cell_var in result.keys():
		var cell: Vector3i = cell_var
		var column := Vector2i(cell.x, cell.z)
		if not min_y_by_column.has(column):
			min_y_by_column[column] = cell.y
			max_y_by_column[column] = cell.y
			continue
		min_y_by_column[column] = mini(int(min_y_by_column[column]), cell.y)
		max_y_by_column[column] = maxi(int(max_y_by_column[column]), cell.y)
	for column in min_y_by_column.keys():
		var from_y := maxi(min_y, int(min_y_by_column[column]) - 1)
		var to_y := int(max_y_by_column[column])
		for y in range(from_y, to_y + 1):
			result[Vector3i(column.x, y, column.y)] = true
	return result

static func _find_surface_breach_excavation_cells(excavated_cells: Dictionary, surface_rect: Dictionary, grade_y: int) -> Array[String]:
	var result: Array[String] = []
	var rect_min: Vector2i = surface_rect.get("min", Vector2i.ZERO)
	var rect_max: Vector2i = surface_rect.get("max", Vector2i.ZERO)
	for cell_var in excavated_cells.keys():
		var cell: Vector3i = cell_var
		if cell.y != grade_y:
			continue
		if cell.x >= rect_min.x and cell.x <= rect_max.x and cell.z >= rect_min.y and cell.z <= rect_max.y:
			continue
		if result.size() >= 6:
			break
		result.append(str(cell))
	return result

static func _rotate_local_rect_bounds(rect: Dictionary, rotation: int) -> Dictionary:
	var min_corner: Vector2i = rect.get("min", Vector2i.ZERO)
	var max_corner: Vector2i = rect.get("max", Vector2i.ZERO)
	var corners := [
		Vector3i(min_corner.x, 0, min_corner.y),
		Vector3i(max_corner.x, 0, min_corner.y),
		Vector3i(min_corner.x, 0, max_corner.y),
		Vector3i(max_corner.x, 0, max_corner.y)
	]
	var rotated_min_x := 999999
	var rotated_max_x := -999999
	var rotated_min_z := 999999
	var rotated_max_z := -999999
	for corner in corners:
		var rotated := _rotate_offset(corner, rotation)
		rotated_min_x = mini(rotated_min_x, rotated.x)
		rotated_max_x = maxi(rotated_max_x, rotated.x)
		rotated_min_z = mini(rotated_min_z, rotated.z)
		rotated_max_z = maxi(rotated_max_z, rotated.z)
	return {
		"min": Vector2i(rotated_min_x, rotated_min_z),
		"max": Vector2i(rotated_max_x, rotated_max_z),
		"footprint": Vector2i(rotated_max_x - rotated_min_x + 1, rotated_max_z - rotated_min_z + 1)
	}

static func _validate_prefab_geometry(prefab_name: String, offsets: Array, objects: Array, placement_profile: Dictionary,
		layer_info: Dictionary, declared_size: Vector3i) -> Dictionary:
	var result := {
		"valid_for_spawn": true,
		"errors": [],
		"warnings": [],
		"door_count": 0,
		"window_count": 0
	}
	if offsets.is_empty():
		result["valid_for_spawn"] = false
		result["errors"].append("no solid voxels found")
		return result

	var solid_cells: Dictionary = layer_info.get("solid_cells", {})
	var stair_cells := _vector3i_array_from_variant(layer_info.get("stair_cells", []))
	var actual_size: Vector3i = layer_info.get("actual_size", Vector3i.ZERO)
	var row_widths: Array = layer_info.get("row_widths", [])
	var rows_per_slice: Array = layer_info.get("rows_per_slice", [])
	var min_x: int = offsets[0].x
	var min_y: int = offsets[0].y
	var max_y: int = offsets[0].y
	var max_x: int = offsets[0].x
	var min_z: int = offsets[0].z
	var max_z: int = offsets[0].z
	for offset in offsets:
		min_x = mini(min_x, offset.x)
		min_y = mini(min_y, offset.y)
		max_y = maxi(max_y, offset.y)
		max_x = maxi(max_x, offset.x)
		min_z = mini(min_z, offset.z)
		max_z = maxi(max_z, offset.z)

	if declared_size.x != actual_size.x:
		result["errors"].append("declared size.x=%d but layer width is %d" % [declared_size.x, actual_size.x])
	if declared_size.y != actual_size.y:
		result["errors"].append("declared size.y=%d but layer count is %d" % [declared_size.y, actual_size.y])
	var bad_slices: Array[String] = []
	for slice_idx in range(rows_per_slice.size()):
		var row_count := int(rows_per_slice[slice_idx])
		if row_count != declared_size.z:
			bad_slices.append("%d:%d" % [slice_idx, row_count])
	if not bad_slices.is_empty():
		result["errors"].append("declared size.z=%d but slice rows are [%s]" % [declared_size.z, ", ".join(bad_slices)])
	var bad_row_widths: Array[int] = []
	for width in row_widths:
		var width_i := int(width)
		if width_i != declared_size.x and not bad_row_widths.has(width_i):
			bad_row_widths.append(width_i)
	if not bad_row_widths.is_empty():
		var width_parts: Array[String] = []
		for width_i in bad_row_widths:
			width_parts.append(str(width_i))
		result["errors"].append("declared size.x=%d but row widths include [%s]" % [declared_size.x, ", ".join(width_parts)])

	var grade_y := int(placement_profile.get("grade_y", min_y))
	var excavation_volumes: Array = placement_profile.get("excavation_volumes", [])
	var enclosed_below_grade_cells := _get_enclosed_below_grade_empty_cells(solid_cells, declared_size, min_y, grade_y)
	if grade_y > min_y:
		var required_excavation_cells := _build_required_below_grade_excavation_cells(enclosed_below_grade_cells, stair_cells, min_y, grade_y)
		if not required_excavation_cells.is_empty():
			if excavation_volumes.is_empty():
				if bool(placement_profile.get("auto_carve_volume", false)):
					result["warnings"].append("below-grade structure relies on inferred excavation; add explicit excavation_volumes for trustworthy world-map placement")
				else:
					result["errors"].append("below-grade structure is missing excavation volumes")
			else:
				var exact_excavated_cells := _build_local_cell_set_from_volumes(excavation_volumes)
				var excavated_cells := _inflate_local_cell_set(
					exact_excavated_cells,
					EXCAVATION_SAFETY_PADDING
				)
				var missing_cells: Array[String] = []
				for cell in required_excavation_cells:
					if excavated_cells.has(cell):
						continue
					if missing_cells.size() < 6:
						missing_cells.append(str(cell))
				if not missing_cells.is_empty():
					result["errors"].append("excavation volumes miss below-grade interior/stair cells [%s]" % ", ".join(missing_cells))
				var surface_breach_cells := _find_surface_breach_excavation_cells(
					exact_excavated_cells,
					placement_profile.get("surface_footprint", {}),
					grade_y
				)
				if not surface_breach_cells.is_empty():
					result["errors"].append("excavation reaches grade outside surface footprint at [%s]" % ", ".join(surface_breach_cells))

	for obj in objects:
		var object_id := int(obj.get("object_id", -1))
		var object_name := str(object_id)
		var obj_def := ObjectRegistry.get_object(object_id)
		if not obj_def.is_empty():
			object_name = str(obj_def.get("name", object_name))
		else:
			result["warnings"].append("unknown object id %d" % object_id)

		if object_id == 4:
			result["door_count"] = int(result["door_count"]) + 1
		elif object_id == 5:
			result["window_count"] = int(result["window_count"]) + 1

		var anchor := Vector3i(
			int(floor(float(obj.get("x", 0.0)))),
			int(floor(float(obj.get("y", 0.0)))),
			int(floor(float(obj.get("z", 0.0))))
		)
		var rotation := int(obj.get("rotation", 0))
		var occupied_cells := _get_object_occupied_cells(object_id, anchor, rotation)

		if object_id != 4 and object_id != 5:
			for cell in occupied_cells:
				if solid_cells.has(cell):
					result["errors"].append("%s overlaps solid voxel at %s" % [object_name, cell])
		else:
			for cell in occupied_cells:
				if solid_cells.has(cell):
					result["errors"].append("%s opening is blocked by solid voxel at %s" % [object_name, cell])
			if object_id == 4 and not _door_has_floor_support(anchor, rotation, solid_cells):
				result["errors"].append("door at %s has missing floor support" % anchor)

		if (object_id == 4 or object_id == 5) and not _object_touches_exterior(occupied_cells, solid_cells, min_x, max_x, min_z, max_z):
			result["warnings"].append("%s is not placed on the prefab exterior shell" % object_name)

	if prefab_name != "small_house" and int(result.get("door_count", 0)) <= 0:
		result["errors"].append("missing door object")
	if bool(placement_profile.get("require_windows", true)) and int(result.get("window_count", 0)) <= 0:
		result["errors"].append("missing window object")
	elif int(result.get("window_count", 0)) <= 0:
		result["warnings"].append("no window objects found")
	var has_internal_stairs := false
	for cell in stair_cells:
		if cell.y > 0:
			has_internal_stairs = true
			break
	if _prefab_requires_internal_stairs(objects, max_y) and not has_internal_stairs:
		result["errors"].append("upper story requires internal stairs")
	elif has_internal_stairs:
		var stair_validation := _validate_internal_stairs(stair_cells, solid_cells)
		for err in stair_validation.get("errors", []):
			result["errors"].append(err)
		for warn in stair_validation.get("warnings", []):
			result["warnings"].append(warn)
	if not enclosed_below_grade_cells.is_empty():
		var basement_access := _validate_below_grade_access(stair_cells, solid_cells, enclosed_below_grade_cells, grade_y)
		for err in basement_access.get("errors", []):
			result["errors"].append(err)
		for warn in basement_access.get("warnings", []):
			result["warnings"].append(warn)

	var errors: Array = result["errors"]
	result["valid_for_spawn"] = errors.is_empty()
	return result

static func _get_object_occupied_cells(object_id: int, anchor: Vector3i, rotation: int) -> Array[Vector3i]:
	var size := ObjectRegistry.get_rotated_size(object_id, rotation)
	var occupied_cells: Array[Vector3i] = []
	for x in range(size.x):
		for y in range(size.y):
			for z in range(size.z):
				occupied_cells.append(anchor + Vector3i(x, y, z))
	return occupied_cells

static func _door_has_floor_support(anchor: Vector3i, rotation: int, solid_cells: Dictionary) -> bool:
	var support_cells: Array[Vector3i] = []
	if rotation == 1 or rotation == 3:
		support_cells = [
			anchor + Vector3i(0, -1, 0),
			anchor + Vector3i(0, -1, -1),
			anchor + Vector3i(0, -1, 1)
		]
	else:
		support_cells = [
			anchor + Vector3i(0, -1, 0),
			anchor + Vector3i(-1, -1, 0),
			anchor + Vector3i(1, -1, 0)
		]
	var support_count := 0
	for cell in support_cells:
		if solid_cells.has(cell):
			support_count += 1
	return support_count >= 2

static func _prefab_requires_internal_stairs(objects: Array, max_y: int) -> bool:
	if max_y < 4:
		return false
	for obj in objects:
		if int(obj.get("object_id", -1)) == 5 and int(floor(float(obj.get("y", 0.0)))) >= 5:
			return true
	return false

static func _validate_internal_stairs(stair_cells: Array[Vector3i], solid_cells: Dictionary) -> Dictionary:
	var result := {
		"errors": [],
		"warnings": []
	}
	var internal_stairs: Array[Vector3i] = []
	for cell in stair_cells:
		if cell.y > 0:
			internal_stairs.append(cell)
	if internal_stairs.is_empty():
		return result

	var component := _largest_stair_component(internal_stairs)
	if component.is_empty():
		return result
	var levels := _sorted_component_levels(component)
	if levels.size() < 2:
		result["errors"].append("internal stairs do not rise to the next level")
		return result
	for i in range(levels.size() - 1):
		if levels[i + 1] != levels[i] + 1:
			result["errors"].append("internal stairs skip levels between y=%d and y=%d" % [levels[i], levels[i + 1]])
			break
	var step := _infer_stair_step(component)
	if step == Vector2i.ZERO:
		result["errors"].append("unable to determine internal stair direction")
		return result
	var headroom: Variant = _find_stair_headroom_block(component, solid_cells)
	if headroom != null:
		result["errors"].append("stairs have blocked headroom at %s" % headroom)
	var approach: Variant = _find_stair_approach_block(component, solid_cells, step)
	if approach != null:
		result["errors"].append("stairs have blocked approach clearance at %s" % approach)
	if not _stairs_have_landing(component, solid_cells, step):
		result["errors"].append("stairs are missing a clear landing at the top")
	return result

static func _largest_stair_component(stair_cells: Array[Vector3i]) -> Array[Vector3i]:
	var stair_set: Dictionary = {}
	for cell in stair_cells:
		stair_set[cell] = true
	var visited: Dictionary = {}
	var best: Array[Vector3i] = []
	for cell in stair_cells:
		if visited.has(cell):
			continue
		var stack: Array[Vector3i] = [cell]
		var component: Array[Vector3i] = []
		visited[cell] = true
		while not stack.is_empty():
			var current: Vector3i = stack.pop_back()
			component.append(current)
			for neighbor in _get_stair_neighbors(current):
				if not stair_set.has(neighbor) or visited.has(neighbor):
					continue
				visited[neighbor] = true
				stack.append(neighbor)
		if component.size() > best.size():
			best = component
	return best

static func _get_stair_neighbors(cell: Vector3i) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				if abs(dx) + abs(dz) > 1:
					continue
				result.append(cell + Vector3i(dx, dy, dz))
	return result

static func _sorted_component_levels(component: Array[Vector3i]) -> Array[int]:
	var levels: Array[int] = []
	for cell in component:
		if not levels.has(cell.y):
			levels.append(cell.y)
	levels.sort()
	return levels

static func _infer_stair_step(component: Array[Vector3i]) -> Vector2i:
	var by_level: Dictionary = {}
	for cell in component:
		if not by_level.has(cell.y):
			by_level[cell.y] = []
		var level_cells: Array = by_level[cell.y]
		level_cells.append(cell)
		by_level[cell.y] = level_cells
	var levels := _sorted_component_levels(component)
	var step_counts: Dictionary = {}
	for i in range(levels.size() - 1):
		var current_level: int = levels[i]
		var next_level: int = levels[i + 1]
		if next_level != current_level + 1:
			continue
		for cell_a in by_level.get(current_level, []):
			for cell_b in by_level.get(next_level, []):
				var dx: int = cell_b.x - cell_a.x
				var dz: int = cell_b.z - cell_a.z
				if abs(dx) + abs(dz) != 1:
					continue
				var step := Vector2i(dx, dz)
				step_counts[step] = int(step_counts.get(step, 0)) + 1
	var best_step := Vector2i.ZERO
	var best_count := 0
	for step in step_counts.keys():
		var count := int(step_counts[step])
		if count > best_count:
			best_step = step
			best_count = count
	return best_step

static func _find_stair_headroom_block(component: Array[Vector3i], solid_cells: Dictionary) -> Variant:
	for cell in component:
		var above := cell + Vector3i(0, 1, 0)
		if solid_cells.has(above) and int(solid_cells[above].get("type", -1)) != 4:
			return above
	return null

static func _find_stair_approach_block(component: Array[Vector3i], solid_cells: Dictionary, step: Vector2i) -> Variant:
	var min_y := component[0].y
	for cell in component:
		min_y = mini(min_y, cell.y)
	for cell in component:
		if cell.y != min_y:
			continue
		for clearance_y in [1, 2]:
			var clearance := cell + Vector3i(-step.x, clearance_y, -step.y)
			if solid_cells.has(clearance):
				return clearance
	return null

static func _stairs_have_landing(component: Array[Vector3i], solid_cells: Dictionary, step: Vector2i) -> bool:
	var max_y := component[0].y
	var component_cells := _vector3i_array_to_set(component)
	var lateral_left := Vector2i(-step.y, step.x)
	var lateral_right := Vector2i(step.y, -step.x)
	var landing_offsets := [step, lateral_left, lateral_right]
	for cell in component:
		max_y = maxi(max_y, cell.y)
	for cell in component:
		if cell.y != max_y:
			continue
		for offset in landing_offsets:
			var landing := cell + Vector3i(offset.x, 0, offset.y)
			if component_cells.has(landing):
				continue
			var landing_above := landing + Vector3i(0, 1, 0)
			if solid_cells.has(landing) and not solid_cells.has(landing_above):
				return true
	return false

static func _stairs_have_bottom_landing(component: Array[Vector3i], solid_cells: Dictionary, step: Vector2i) -> bool:
	var min_y := component[0].y
	var component_cells := _vector3i_array_to_set(component)
	var lateral_left := Vector2i(-step.y, step.x)
	var lateral_right := Vector2i(step.y, -step.x)
	var landing_offsets := [Vector2i(-step.x, -step.y), lateral_left, lateral_right]
	for cell in component:
		min_y = mini(min_y, cell.y)
	for cell in component:
		if cell.y != min_y:
			continue
		for offset in landing_offsets:
			var landing := cell + Vector3i(offset.x, -1, offset.y)
			if component_cells.has(landing):
				continue
			var landing_above := landing + Vector3i(0, 1, 0)
			if solid_cells.has(landing) and not solid_cells.has(landing_above):
				return true
	return false

static func _vector3i_array_to_set(cells: Array[Vector3i]) -> Dictionary:
	var result: Dictionary = {}
	for cell in cells:
		result[cell] = true
	return result

static func _validate_below_grade_access(stair_cells: Array[Vector3i], solid_cells: Dictionary, enclosed_cells: Array, grade_y: int) -> Dictionary:
	var result := {
		"errors": [],
		"warnings": []
	}
	if enclosed_cells.is_empty():
		return result

	var internal_stairs: Array[Vector3i] = []
	for cell in stair_cells:
		if cell.y > 0:
			internal_stairs.append(cell)
	if internal_stairs.is_empty():
		result["errors"].append("below-grade structure is missing stairs")
		return result

	var component := _largest_stair_component(internal_stairs)
	if component.is_empty():
		result["errors"].append("below-grade structure is missing a continuous stair run")
		return result

	var levels := _sorted_component_levels(component)
	var required_min_y := grade_y
	for cell in enclosed_cells:
		required_min_y = mini(required_min_y, cell.y)
	if levels.is_empty() or levels[0] > required_min_y:
		result["errors"].append("stairs do not reach the underground level at y=%d" % required_min_y)
		return result
	if levels[levels.size() - 1] < grade_y:
		result["errors"].append("stairs do not connect back to grade level y=%d" % grade_y)
		return result

	var step := _infer_stair_step(component)
	if step == Vector2i.ZERO:
		result["errors"].append("unable to determine basement stair direction")
		return result
	if not _stairs_have_bottom_landing(component, solid_cells, step):
		result["errors"].append("stairs are missing a clear landing at the bottom")
	return result

static func _object_touches_exterior(occupied_cells: Array[Vector3i], solid_cells: Dictionary,
		min_x: int, max_x: int, min_z: int, max_z: int) -> bool:
	if not _occupied_cells_touch_structure(occupied_cells, solid_cells):
		return false
	var dirs = [
		Vector2i(-1, 0),
		Vector2i(1, 0),
		Vector2i(0, -1),
		Vector2i(0, 1)
	]
	for cell in occupied_cells:
		for dir in dirs:
			if _ray_reaches_exterior(cell, dir, solid_cells, min_x, max_x, min_z, max_z):
				return true
	return false

static func _occupied_cells_touch_structure(occupied_cells: Array[Vector3i], solid_cells: Dictionary) -> bool:
	var dirs = [
		Vector3i(-1, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1)
	]
	for cell in occupied_cells:
		for dir in dirs:
			if solid_cells.has(cell + dir):
				return true
	return false

static func _ray_reaches_exterior(cell: Vector3i, dir: Vector2i, solid_cells: Dictionary,
		min_x: int, max_x: int, min_z: int, max_z: int) -> bool:
	var probe_x := cell.x + dir.x
	var probe_z := cell.z + dir.y
	while probe_x >= min_x and probe_x <= max_x and probe_z >= min_z and probe_z <= max_z:
		if solid_cells.has(Vector3i(probe_x, cell.y, probe_z)):
			return false
		probe_x += dir.x
		probe_z += dir.y
	return true

static func _rotate_offset(offset: Vector3i, rotation: int) -> Vector3i:
	match rotation:
		0:
			return offset
		1:
			return Vector3i(-offset.z, offset.y, offset.x)
		2:
			return Vector3i(-offset.x, offset.y, -offset.z)
		3:
			return Vector3i(offset.z, offset.y, -offset.x)
	return offset

static func _rotate_vector3_offset(offset: Vector3, rotation: int) -> Vector3:
	match rotation:
		0:
			return offset
		1:
			return Vector3(-offset.z, offset.y, offset.x)
		2:
			return Vector3(-offset.x, offset.y, -offset.z)
		3:
			return Vector3(offset.z, offset.y, -offset.x)
	return offset

static func _get_grid_correction(rotation: int) -> Vector3:
	match rotation:
		1:
			return Vector3(1, 0, 0)
		2:
			return Vector3(1, 0, 1)
		3:
			return Vector3(0, 0, 1)
	return Vector3.ZERO
