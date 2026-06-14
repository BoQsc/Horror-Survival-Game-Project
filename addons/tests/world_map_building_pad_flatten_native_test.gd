extends SceneTree

const WorldMapGeneratorScript := preload("res://world_map_generator/world_map_generator.gd")

var _native: Object = null
var _generator: WorldMapGenerator = null


func _init() -> void:
	var exit_code := _run()
	_release_generator()
	_release_native()
	quit(exit_code)


func _release_generator() -> void:
	if _generator != null:
		_generator.release_runtime_resources()
		_generator = null


func _release_native() -> void:
	if _native == null or not is_instance_valid(_native):
		_native = null
		return
	if _native is RefCounted:
		_native.unreference()
		if is_instance_valid(_native):
			_native.free()
	else:
		_native.free()
	_native = null


func _run() -> int:
	if not _expect(ClassDB.class_exists("PrefabGeometryNative"), "PrefabGeometryNative should be available"):
		return 1
	_native = ClassDB.instantiate("PrefabGeometryNative")
	var native := _native
	if not _expect(native != null and native.has_method("flatten_world_map_building_pad"), "native pad flatten backend should be bound"):
		return 1

	_generator = WorldMapGeneratorScript.new()
	var generator := _generator
	var map_size := WorldMapGenerator.MAP_SIZE
	var half := map_size / 2
	var max_h := 25.0
	var base := PackedByteArray()
	base.resize(map_size * map_size)
	base.fill(_encode_height_byte(18.0, max_h))

	var bldg_x := -17.0
	var bldg_z := 23.0
	var footprint := Vector2i(18, 14)
	var bldg_y := 12.0
	var support_info := {"height_range": 2.25}
	var protected_columns := {
		Vector2i(int(floor(bldg_x)) - 2, int(floor(bldg_z)) + 4): true,
		Vector2i(int(floor(bldg_x)) + footprint.x + 3, int(floor(bldg_z)) + 2): true
	}

	var native_height := base.duplicate()
	var native_start_us := Time.get_ticks_usec()
	var native_result: Dictionary = generator._flatten_building_pad(
		native_height,
		bldg_x,
		bldg_z,
		footprint,
		bldg_y,
		max_h,
		half,
		support_info,
		protected_columns
	)
	var native_ms := float(Time.get_ticks_usec() - native_start_us) / 1000.0
	if not _expect(str(native_result.get("backend", "")) == "native", "generator wrapper should use native pad flatten backend"):
		return 1

	var reference_height := base.duplicate()
	var reference_start_us := Time.get_ticks_usec()
	var reference_result := _reference_flatten_building_pad(
		reference_height,
		map_size,
		bldg_x,
		bldg_z,
		footprint,
		bldg_y,
		max_h,
		half,
		support_info,
		protected_columns
	)
	var reference_ms := float(Time.get_ticks_usec() - reference_start_us) / 1000.0

	if not _expect(int(native_result.get("changed_pixel_count", -1)) == int(reference_result.get("changed_pixel_count", -2)), "changed pixel count should match reference"):
		return 1
	if not _expect(_region_matches(native_height, reference_height, map_size, bldg_x, bldg_z, footprint, support_info), "wrapper-mutated height bytes should match reference region"):
		return 1

	print("[WORLD_MAP_BUILDING_PAD_FLATTEN_NATIVE_TEST] PASS native_ms=%.3f reference_ms=%.3f changed=%d" % [
		native_ms,
		reference_ms,
		int(native_result.get("changed_pixel_count", 0))
	])
	return 0


func _reference_flatten_building_pad(height_bytes: PackedByteArray, map_size: int, bldg_x: float, bldg_z: float, footprint: Vector2i, bldg_y: float, max_h: float, half: int, support_info: Dictionary, protected_columns: Dictionary) -> Dictionary:
	var flat_h_byte = _encode_height_byte(bldg_y, max_h)
	var longest_side = max(float(footprint.x), float(footprint.y))
	var support_range = float(support_info.get("height_range", 0.0))
	var pad = max(6, int(ceil(longest_side * 0.5 + support_range * 1.25)))
	var base_world_x := int(floor(bldg_x))
	var base_world_z := int(floor(bldg_z))
	var width = footprint.x + pad * 2
	var depth = footprint.y + pad * 2
	var changed_pixels := 0
	for fz in range(-pad, depth - pad + 1):
		for fx in range(-pad, width - pad + 1):
			var fpx = clampi(int(bldg_x + half) + fx, 0, map_size - 1)
			var fpz = clampi(int(bldg_z + half) + fz, 0, map_size - 1)
			var world_col := Vector2i(base_world_x + fx, base_world_z + fz)
			var inside_surface := fx >= 0 and fx < footprint.x and fz >= 0 and fz < footprint.y
			if not inside_surface and protected_columns.has(world_col):
				continue
			var h_idx = fpz * map_size + fpx
			var orig_h_byte = height_bytes[h_idx]
			var dx = max(0.0, max(0.0 - fx, fx - float(footprint.x)))
			var dz = max(0.0, max(0.0 - fz, fz - float(footprint.y)))
			var dist = sqrt(dx * dx + dz * dz)
			var inner_flat = 1.25 + min(1.5, support_range * 0.3)
			if dist <= inner_flat:
				if height_bytes[h_idx] != flat_h_byte:
					changed_pixels += 1
				height_bytes[h_idx] = flat_h_byte
			elif dist < float(pad):
				var blend_t = (dist - inner_flat) / max(0.001, float(pad) - inner_flat)
				var smooth_t = blend_t * blend_t * (3.0 - 2.0 * blend_t)
				var blended := int(lerp(float(flat_h_byte), float(orig_h_byte), smooth_t))
				if height_bytes[h_idx] != blended:
					changed_pixels += 1
				height_bytes[h_idx] = blended
	return {"changed_pixel_count": changed_pixels}


func _region_matches(native_height: PackedByteArray, reference_height: PackedByteArray, map_size: int, bldg_x: float, bldg_z: float, footprint: Vector2i, support_info: Dictionary) -> bool:
	var longest_side = max(float(footprint.x), float(footprint.y))
	var support_range = float(support_info.get("height_range", 0.0))
	var pad = max(6, int(ceil(longest_side * 0.5 + support_range * 1.25)))
	var half := map_size / 2
	var width = footprint.x + pad * 2
	var depth = footprint.y + pad * 2
	for fz in range(-pad, depth - pad + 1):
		var fpz = clampi(int(bldg_z + half) + fz, 0, map_size - 1)
		for fx in range(-pad, width - pad + 1):
			var fpx = clampi(int(bldg_x + half) + fx, 0, map_size - 1)
			var idx: int = fpz * map_size + fpx
			if native_height[idx] != reference_height[idx]:
				printerr("[WORLD_MAP_BUILDING_PAD_FLATTEN_NATIVE_TEST] mismatch idx=%d native=%d reference=%d" % [
					idx,
					native_height[idx],
					reference_height[idx]
				])
				return false
	return true


func _encode_height_byte(height: float, max_h: float) -> int:
	return int(round(clampf(height / max_h, 0.0, 1.0) * 255.0))


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_BUILDING_PAD_FLATTEN_NATIVE_TEST] FAIL: %s" % message)
	return false
