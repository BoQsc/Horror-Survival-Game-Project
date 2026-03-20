extends RefCounted
class_name PrefabGeometry

const ObjectRegistry = preload("res://world_building_system/object_registry.gd")
const RES_PREFAB_DIR := "res://world_prefabs/"
const USER_PREFAB_DIR := "user://world_prefabs/"

static var _geometry_cache: Dictionary = {}
static var _rotated_bounds_cache: Dictionary = {}

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

	var offsets := _parse_block_offsets(data.get("layers", []))
	if offsets.is_empty():
		var size_arr: Array = data.get("size", [1, 1, 1])
		var sx := int(size_arr[0]) if size_arr.size() > 0 else 1
		var sy := int(size_arr[1]) if size_arr.size() > 1 else 1
		var sz := int(size_arr[2]) if size_arr.size() > 2 else 1
		for x in range(sx):
			for y in range(sy):
				for z in range(sz):
					offsets.append(Vector3i(x, y, z))

	var placement_profile := _parse_placement_profile(data, offsets)
	var objects := _parse_compact_objects(data.get("objects", []))

	return {
		"name": prefab_name,
		"offsets": offsets,
		"objects": objects,
		"placement_profile": placement_profile,
		"validation": _validate_prefab_geometry(prefab_name, offsets, objects, placement_profile)
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

static func _is_filled_token(token: String) -> bool:
	return token != "" and token != "."

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
		"require_windows": true
	}

static func _parse_placement_profile(data: Dictionary, offsets: Array) -> Dictionary:
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
	return profile

static func _validate_prefab_geometry(prefab_name: String, offsets: Array, objects: Array, placement_profile: Dictionary) -> Dictionary:
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

	var solid_cells: Dictionary = {}
	var min_x: int = offsets[0].x
	var max_x: int = offsets[0].x
	var min_z: int = offsets[0].z
	var max_z: int = offsets[0].z
	for offset in offsets:
		solid_cells[offset] = true
		min_x = mini(min_x, offset.x)
		max_x = maxi(max_x, offset.x)
		min_z = mini(min_z, offset.z)
		max_z = maxi(max_z, offset.z)

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
		var size := ObjectRegistry.get_rotated_size(object_id, rotation)
		var occupied_cells: Array[Vector3i] = []
		for x in range(size.x):
			for y in range(size.y):
				for z in range(size.z):
					var cell := anchor + Vector3i(x, y, z)
					occupied_cells.append(cell)

		if object_id != 4 and object_id != 5:
			for cell in occupied_cells:
				if solid_cells.has(cell):
					result["errors"].append("%s overlaps solid voxel at %s" % [object_name, cell])

		if (object_id == 4 or object_id == 5) and not _object_touches_exterior(occupied_cells, solid_cells, min_x, max_x, min_z, max_z):
			result["warnings"].append("%s is not placed on the prefab exterior shell" % object_name)

	if prefab_name != "small_house" and int(result.get("door_count", 0)) <= 0:
		result["errors"].append("missing door object")
	if int(result.get("window_count", 0)) <= 0:
		result["warnings"].append("no window objects found")

	var errors: Array = result["errors"]
	result["valid_for_spawn"] = errors.is_empty()
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
