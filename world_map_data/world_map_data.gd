extends RefCounted
class_name WorldMapData
## Shared loader for baked world map data.
## Caches decoded PNGs and metadata in memory, while returning safe copies by default.

const CACHE_LIMIT: int = 4
const WORLD_META_SCHEMA_VERSION_KEY: String = "schema_version"
const WORLD_META_VERSION_KEY: String = "version"
const WORLD_META_CURRENT_SCHEMA_VERSION: int = 7
const WORLD_META_BUILDING_PLACEMENT_SCHEMA_KEY: String = "building_placement_schema"
const WORLD_META_DEFAULT_BUILDING_PLACEMENT_SCHEMA: String = "occupied_min_v1"
const WORLD_META_BUILDINGS_KEY: String = "buildings"
const WORLD_META_TOWNS_KEY: String = "towns"
const WORLD_META_TERRAIN_MODIFICATIONS_KEY: String = "terrain_modifications"
const WORLD_IMAGE_NAMES: Array[String] = ["heightmap", "biomes", "roads", "water", "building_map"]
const WORLD_IMAGE_ALIASES: Dictionary = {
	"water": ["structures"],
	"building_map": ["buildings"],
}
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
static var _last_load_profile: Dictionary = {}
static var _last_load_profiles: Dictionary = {}

static func set_cache_enabled(enabled: bool) -> void:
	cache_enabled = enabled
	if not cache_enabled:
		clear_cache()

static func clear_cache() -> void:
	_world_cache.clear()
	_cache_order.clear()

static func get_baked_image_names() -> Array[String]:
	return WORLD_IMAGE_NAMES.duplicate()

static func get_world_meta_schema_version() -> int:
	return WORLD_META_CURRENT_SCHEMA_VERSION

static func get_world_meta_schema_version_key() -> String:
	return WORLD_META_SCHEMA_VERSION_KEY

static func get_world_meta_version_key() -> String:
	return WORLD_META_VERSION_KEY

static func get_world_meta_building_placement_schema_key() -> String:
	return WORLD_META_BUILDING_PLACEMENT_SCHEMA_KEY

static func get_world_meta_default_building_placement_schema() -> String:
	return WORLD_META_DEFAULT_BUILDING_PLACEMENT_SCHEMA

static func invalidate_world(path: String) -> void:
	var cache_key := _normalize_world_path(path)
	if cache_key == "":
		return
	_world_cache.erase(cache_key)
	_cache_order.erase(cache_key)
	_last_load_profiles.erase(cache_key)

static func get_last_load_profile(path: String = "") -> Dictionary:
	var cache_key := _normalize_world_path(path)
	var profile: Dictionary
	if cache_key == "":
		profile = _last_load_profile
	else:
		profile = _last_load_profiles.get(cache_key, {})
	return profile.duplicate(true)

static func load_world(path: String, use_cache: bool = true, duplicate_on_return: bool = true, profile_out: Variant = null) -> Dictionary:
	var cache_key := _normalize_world_path(path)
	if cache_key == "":
		return {}

	var call_start_us := Time.get_ticks_usec()
	var allow_cache := cache_enabled and use_cache
	var signature := ""
	var profile: Dictionary = {
		"world_path": cache_key,
		"cache_enabled": allow_cache,
		"cache_hit": false,
		"duplicate_on_return": duplicate_on_return,
		"signature_us": 0.0,
		"image_decode_us": 0.0,
		"image_convert_us": 0.0,
		"metadata_parse_us": 0.0,
		"duplicate_us": 0.0,
		"loaded_image_count": 0,
		"metadata_found": false,
		"metadata_valid": false,
		"schema_version": 0,
		"load_total_us": 0.0,
	}
	if allow_cache:
		var signature_start_us := Time.get_ticks_usec()
		signature = _build_world_signature(cache_key)
		profile["signature_us"] = float(Time.get_ticks_usec() - signature_start_us)
		if _world_cache.has(cache_key):
			var cached_entry: Dictionary = _world_cache[cache_key]
			if cached_entry.get("signature", "") == signature:
				_touch_cache_key(cache_key)
				var cached_data: Dictionary = cached_entry.get("data", {})
				profile["cache_hit"] = true
				if duplicate_on_return:
					var duplicate_start_us := Time.get_ticks_usec()
					var duplicated_cached := _duplicate_world_data(cached_data)
					profile["duplicate_us"] = float(Time.get_ticks_usec() - duplicate_start_us)
					profile["load_total_us"] = float(Time.get_ticks_usec() - call_start_us)
					_record_load_profile(cache_key, profile)
					_apply_profile_out(profile_out, profile)
					return duplicated_cached
				profile["load_total_us"] = float(Time.get_ticks_usec() - call_start_us)
				_record_load_profile(cache_key, profile)
				_apply_profile_out(profile_out, profile)
				return cached_data
			_evict_cache_key(cache_key)

	var load_start_us := Time.get_ticks_usec()
	var loaded: Dictionary = _load_world_uncached(cache_key, profile)
	profile["load_total_us"] = float(Time.get_ticks_usec() - call_start_us)
	profile["uncached_load_us"] = float(Time.get_ticks_usec() - load_start_us)
	if loaded.is_empty():
		_record_load_profile(cache_key, profile)
		_apply_profile_out(profile_out, profile)
		return {}

	if allow_cache:
		_store_cache_entry(cache_key, signature, loaded)

	if duplicate_on_return:
		var duplicate_start_us := Time.get_ticks_usec()
		var duplicated_loaded := _duplicate_world_data(loaded)
		profile["duplicate_us"] = float(Time.get_ticks_usec() - duplicate_start_us)
		profile["load_total_us"] = float(Time.get_ticks_usec() - call_start_us)
		_record_load_profile(cache_key, profile)
		_apply_profile_out(profile_out, profile)
		return duplicated_loaded
	_record_load_profile(cache_key, profile)
	_apply_profile_out(profile_out, profile)
	return loaded

static func _load_world_uncached(path: String, profile: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for image_name in WORLD_IMAGE_NAMES:
		var image_path := _resolve_world_image_path(path, image_name)
		if not FileAccess.file_exists(image_path):
			continue
		var decode_start_us := Time.get_ticks_usec()
		var image := Image.load_from_file(image_path)
		profile["image_decode_us"] = float(profile.get("image_decode_us", 0.0)) + float(Time.get_ticks_usec() - decode_start_us)
		if image:
			profile["loaded_image_count"] = int(profile.get("loaded_image_count", 0)) + 1
			if image.get_format() != EXPECTED_IMAGE_FORMATS[image_name]:
				var convert_start_us := Time.get_ticks_usec()
				image.convert(EXPECTED_IMAGE_FORMATS[image_name])
				profile["image_convert_us"] = float(profile.get("image_convert_us", 0.0)) + float(Time.get_ticks_usec() - convert_start_us)
			result[image_name] = image

	var meta_path := path.path_join("world_meta.json")
	if FileAccess.file_exists(meta_path):
		profile["metadata_found"] = true
		var metadata_start_us := Time.get_ticks_usec()
		var file := FileAccess.open(meta_path, FileAccess.READ)
		if file:
			var json := JSON.new()
			var parse_error := json.parse(file.get_as_text())
			if parse_error == OK:
				var metadata = json.get_data()
				if metadata is Dictionary:
					metadata = _normalize_world_metadata(metadata)
					result["metadata"] = metadata
					result["schema_version"] = int(metadata.get(WORLD_META_SCHEMA_VERSION_KEY, 0))
					profile["metadata_valid"] = true
					profile["schema_version"] = int(result["schema_version"])
					profile["metadata_key_count"] = metadata.size()
					if metadata.has(WORLD_META_BUILDINGS_KEY):
						result["buildings"] = metadata.buildings
					if metadata.has(WORLD_META_TOWNS_KEY):
						result["towns"] = metadata.towns
					if metadata.has(WORLD_META_TERRAIN_MODIFICATIONS_KEY):
						result["terrain_modifications"] = metadata.terrain_modifications
			file.close()
		profile["metadata_parse_us"] = float(profile.get("metadata_parse_us", 0.0)) + float(Time.get_ticks_usec() - metadata_start_us)
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

static func _record_load_profile(cache_key: String, profile: Dictionary) -> void:
	var profile_copy := profile.duplicate(true)
	_last_load_profile = profile_copy
	_last_load_profiles[cache_key] = profile_copy

static func _apply_profile_out(profile_out: Variant, profile: Dictionary) -> void:
	if profile_out is Dictionary:
		var out: Dictionary = profile_out
		out.clear()
		for key in profile:
			out[key] = profile[key]

static func _normalize_world_path(path: String) -> String:
	var normalized := path.strip_edges()
	if normalized.ends_with("/"):
		normalized = normalized.substr(0, normalized.length() - 1)
	return normalized

static func _normalize_world_metadata(metadata: Dictionary) -> Dictionary:
	var normalized := metadata.duplicate(true)
	var meta_version := int(normalized.get(WORLD_META_SCHEMA_VERSION_KEY, normalized.get(WORLD_META_VERSION_KEY, 0)))
	normalized[WORLD_META_SCHEMA_VERSION_KEY] = meta_version
	normalized[WORLD_META_VERSION_KEY] = meta_version
	if not normalized.has(WORLD_META_BUILDING_PLACEMENT_SCHEMA_KEY) or str(normalized[WORLD_META_BUILDING_PLACEMENT_SCHEMA_KEY]).is_empty():
		normalized[WORLD_META_BUILDING_PLACEMENT_SCHEMA_KEY] = WORLD_META_DEFAULT_BUILDING_PLACEMENT_SCHEMA
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
	var candidates := _get_world_image_candidates(image_name)
	for candidate_name in candidates:
		var candidate_path := path.path_join(candidate_name + ".png")
		if FileAccess.file_exists(candidate_path):
			return candidate_path
	return path.path_join(image_name + ".png")

static func _get_world_image_candidates(image_name: String) -> Array[String]:
	var candidates: Array[String] = [image_name]
	if WORLD_IMAGE_ALIASES.has(image_name):
		candidates.append_array(WORLD_IMAGE_ALIASES[image_name])
	return candidates

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
