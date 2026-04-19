extends RefCounted
class_name WorldMapData
## Shared loader for baked world map data.
## Caches decoded PNGs and metadata in memory, while returning safe copies by default.

const CACHE_LIMIT: int = 4
const WORLD_IMAGE_NAMES: Array = ["heightmap", "biomes", "roads", "water", "building_map"]
const EXPECTED_IMAGE_FORMATS := {
	"heightmap": Image.FORMAT_R8,
	"biomes": Image.FORMAT_R8,
	"roads": Image.FORMAT_RG8,
	"water": Image.FORMAT_R8,
	"building_map": Image.FORMAT_R8,
}

static var cache_enabled: bool = true
static var _world_cache: Dictionary = {}
static var _cache_order: Array = []

static func set_cache_enabled(enabled: bool) -> void:
	cache_enabled = enabled
	if not cache_enabled:
		clear_cache()

static func clear_cache() -> void:
	_world_cache.clear()
	_cache_order.clear()

static func invalidate_world(path: String) -> void:
	var cache_key := _normalize_world_path(path)
	if cache_key == "":
		return
	_world_cache.erase(cache_key)
	_cache_order.erase(cache_key)

static func load_world(path: String, use_cache: bool = true, duplicate_on_return: bool = true) -> Dictionary:
	var cache_key := _normalize_world_path(path)
	if cache_key == "":
		return {}

	var allow_cache := cache_enabled and use_cache
	var signature := ""
	if allow_cache:
		signature = _build_world_signature(cache_key)
		if _world_cache.has(cache_key):
			var cached_entry: Dictionary = _world_cache[cache_key]
			if cached_entry.get("signature", "") == signature:
				_touch_cache_key(cache_key)
				var cached_data: Dictionary = cached_entry.get("data", {})
				if duplicate_on_return:
					return _duplicate_world_data(cached_data)
				return cached_data
			_evict_cache_key(cache_key)

	var loaded: Dictionary = _load_world_uncached(cache_key)
	if loaded.is_empty():
		return {}

	if allow_cache:
		_store_cache_entry(cache_key, signature, loaded)

	if duplicate_on_return:
		return _duplicate_world_data(loaded)
	return loaded

static func _load_world_uncached(path: String) -> Dictionary:
	var result: Dictionary = {}
	for image_name in WORLD_IMAGE_NAMES:
		var image_path := _resolve_world_image_path(path, image_name)
		if not FileAccess.file_exists(image_path):
			continue
		var image := Image.load_from_file(image_path)
		if image:
			if image.get_format() != EXPECTED_IMAGE_FORMATS[image_name]:
				image.convert(EXPECTED_IMAGE_FORMATS[image_name])
			result[image_name] = image

	var meta_path := path.path_join("world_meta.json")
	if FileAccess.file_exists(meta_path):
		var file := FileAccess.open(meta_path, FileAccess.READ)
		if file:
			var json := JSON.new()
			json.parse(file.get_as_text())
			var metadata = json.get_data()
			result["metadata"] = metadata
			if metadata.has("buildings"):
				result["buildings"] = metadata.buildings
			if metadata.has("towns"):
				result["towns"] = metadata.towns
			if metadata.has("terrain_modifications"):
				result["terrain_modifications"] = metadata.terrain_modifications
			file.close()
	return result

static func _store_cache_entry(cache_key: String, signature: String, data: Dictionary) -> void:
	_world_cache[cache_key] = {
		"signature": signature,
		"data": data
	}
	_touch_cache_key(cache_key)
	_trim_cache()

static func _touch_cache_key(cache_key: String) -> void:
	_cache_order.erase(cache_key)
	_cache_order.append(cache_key)

static func _trim_cache() -> void:
	if CACHE_LIMIT <= 0:
		return
	while _cache_order.size() > CACHE_LIMIT:
		var evict_key: String = _cache_order[0]
		_cache_order.remove_at(0)
		_world_cache.erase(evict_key)

static func _evict_cache_key(cache_key: String) -> void:
	_world_cache.erase(cache_key)
	_cache_order.erase(cache_key)

static func _normalize_world_path(path: String) -> String:
	var normalized := path.strip_edges()
	if normalized.ends_with("/"):
		normalized = normalized.substr(0, normalized.length() - 1)
	return normalized

static func _build_world_signature(path: String) -> String:
	var signature := ""
	for image_name in WORLD_IMAGE_NAMES:
		if signature != "":
			signature += "|"
		signature += "%s=%s" % [image_name, _file_signature(_resolve_world_image_path(path, image_name))]
	signature += "|meta=%s" % _file_signature(path.path_join("world_meta.json"))
	return signature

static func _resolve_world_image_path(path: String, image_name: String) -> String:
	var direct_path := path.path_join(image_name + ".png")
	if image_name == "water" and not FileAccess.file_exists(direct_path):
		var fallback_path := path.path_join("structures.png")
		if FileAccess.file_exists(fallback_path):
			return fallback_path
	return direct_path

static func _file_signature(file_path: String) -> String:
	if file_path == "" or not FileAccess.file_exists(file_path):
		return "missing"
	return str(FileAccess.get_modified_time(file_path))

static func _duplicate_world_data(world_data: Dictionary) -> Dictionary:
	var duplicated: Dictionary = {}
	for key in world_data:
		duplicated[key] = _duplicate_variant(world_data[key])
	return duplicated

static func _duplicate_variant(value: Variant) -> Variant:
	if value is Image:
		return (value as Image).duplicate()
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	if value is Array:
		return (value as Array).duplicate(true)
	return value
