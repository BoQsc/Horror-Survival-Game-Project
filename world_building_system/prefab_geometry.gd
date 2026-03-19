extends RefCounted
class_name PrefabGeometry

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

static func get_spawn_origin_for_occupied_min(prefab_name: String, occupied_min: Vector3, rotation: int) -> Vector3:
	var bounds := get_rotated_bounds(prefab_name, rotation)
	var min_offset: Vector3i = bounds.get("min", Vector3i.ZERO)
	return occupied_min - Vector3(min_offset.x, 0.0, min_offset.z)

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
			"offsets": offsets
		}

	var data := _load_prefab_json(prefab_name)
	if data.is_empty():
		return {
			"name": prefab_name,
			"offsets": [Vector3i.ZERO]
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

	return {
		"name": prefab_name,
		"offsets": offsets
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
