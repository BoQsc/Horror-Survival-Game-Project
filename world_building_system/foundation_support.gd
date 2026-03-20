extends RefCounted
class_name FoundationSupport

static func resolve_footprint_support(height_sampler: Callable, origin: Vector2, footprint: Vector2i,
		preferred_y: float, config: Dictionary = {}) -> Dictionary:
	var sample_points: Array = _build_sample_points(footprint, config)
	if sample_points.is_empty():
		return {"valid": false, "reason": "no_samples"}

	var heights := PackedFloat32Array()
	for offset in sample_points:
		var sample_pos: Vector2 = origin + offset
		var sampled = float(height_sampler.call(sample_pos.x, sample_pos.y))
		if is_nan(sampled) or sampled <= -900.0:
			return {"valid": false, "reason": "missing_height"}
		heights.append(sampled)

	var result: Dictionary = resolve_height_samples(heights, preferred_y, config)
	result["origin"] = origin
	result["footprint"] = footprint
	result["sample_count"] = heights.size()
	return result

static func resolve_height_samples(heights: PackedFloat32Array, preferred_y: float, config: Dictionary = {}) -> Dictionary:
	if heights.is_empty():
		return {"valid": false, "reason": "no_heights"}

	var sorted: Array = []
	var min_h := INF
	var max_h := -INF
	var sum_h := 0.0
	for h in heights:
		var hf := float(h)
		sorted.append(hf)
		min_h = min(min_h, hf)
		max_h = max(max_h, hf)
		sum_h += hf
	sorted.sort()

	var mean_h := sum_h / float(heights.size())
	var median_h := float(sorted[int(sorted.size() / 2)])
	if sorted.size() % 2 == 0 and sorted.size() > 1:
		var upper_idx: int = int(sorted.size() / 2)
		var lower_idx: int = maxi(0, upper_idx - 1)
		median_h = (float(sorted[lower_idx]) + float(sorted[upper_idx])) * 0.5

	var candidate_levels: Array = _build_candidate_levels(min_h, max_h, mean_h, median_h, preferred_y, config)
	if candidate_levels.is_empty():
		return {"valid": false, "reason": "no_candidates"}

	var best: Dictionary = {}
	for candidate in candidate_levels:
		var metrics: Dictionary = _score_level(float(candidate), heights, preferred_y, config)
		if best.is_empty() or float(metrics.score) < float(best.score):
			best = metrics

	var max_float_gap = float(config.get("max_float_gap", 0.75))
	var max_embed_depth = float(config.get("max_embed_depth", 1.5))
	var max_height_range = float(config.get("max_height_range", 0.0))
	var height_range = max_h - min_h

	best["preferred_y"] = preferred_y
	best["mean_height"] = mean_h
	best["median_height"] = median_h
	best["min_height"] = min_h
	best["max_height"] = max_h
	best["height_range"] = height_range
	best["valid"] = (
		float(best.max_float_gap) <= max_float_gap and
		float(best.max_embed_depth) <= max_embed_depth and
		(max_height_range <= 0.0 or height_range <= max_height_range)
	)
	return best

static func _build_candidate_levels(min_h: float, max_h: float, mean_h: float, median_h: float,
		preferred_y: float, config: Dictionary) -> Array:
	var search_radius: int = maxi(1, int(config.get("search_radius", 3)))
	var seed_values: Array = [
		int(floor(min_h)),
		int(round(min_h)),
		int(ceil(min_h)),
		int(floor(mean_h)),
		int(round(mean_h)),
		int(ceil(mean_h)),
		int(floor(median_h)),
		int(round(median_h)),
		int(ceil(median_h)),
		int(floor(max_h)),
		int(round(max_h)),
		int(ceil(max_h)),
		int(floor(preferred_y)),
		int(round(preferred_y)),
		int(ceil(preferred_y))
	]

	var unique: Dictionary = {}
	for seed in seed_values:
		for delta in range(-search_radius, search_radius + 1):
			unique[int(seed) + delta] = true

	var candidates: Array = unique.keys()
	candidates.sort()
	return candidates

static func _score_level(level_y: float, heights: PackedFloat32Array, preferred_y: float, config: Dictionary) -> Dictionary:
	var total_float := 0.0
	var total_embed := 0.0
	var max_float := 0.0
	var max_embed := 0.0
	for h in heights:
		var delta := level_y - float(h)
		if delta >= 0.0:
			total_float += delta
			max_float = max(max_float, delta)
		else:
			var embed := -delta
			total_embed += embed
			max_embed = max(max_embed, embed)

	var count: float = maxf(1.0, float(heights.size()))
	var avg_float: float = total_float / count
	var avg_embed: float = total_embed / count
	var float_weight = float(config.get("float_weight", 7.0))
	var embed_weight = float(config.get("embed_weight", 3.5))
	var float_peak_weight = float(config.get("float_peak_weight", 5.5))
	var embed_peak_weight = float(config.get("embed_peak_weight", 4.0))
	var preferred_weight = float(config.get("preferred_weight", 0.35))
	var balance_weight = float(config.get("balance_weight", 0.75))

	return {
		"resolved_y": level_y,
		"avg_float_gap": avg_float,
		"avg_embed_depth": avg_embed,
		"max_float_gap": max_float,
		"max_embed_depth": max_embed,
		"score": (
			total_float * float_weight +
			total_embed * embed_weight +
			max_float * max_float * float_peak_weight +
			max_embed * max_embed * embed_peak_weight +
			abs(level_y - preferred_y) * preferred_weight +
			abs(avg_float - avg_embed) * balance_weight
		)
	}

static func _build_sample_points(footprint: Vector2i, config: Dictionary) -> Array:
	var stride: float = maxf(0.45, float(config.get("sample_stride", 1.0)))
	var edge_inset: float = clampf(float(config.get("edge_inset", 0.18)), 0.0, 0.49)
	var max_samples_per_axis: int = maxi(3, int(config.get("max_samples_per_axis", 5)))
	var span_x: float = maxf(1.0, float(footprint.x))
	var span_z: float = maxf(1.0, float(footprint.y))
	var xs: Array = _build_axis_positions(span_x, stride, edge_inset, max_samples_per_axis)
	var zs: Array = _build_axis_positions(span_z, stride, edge_inset, max_samples_per_axis)

	var points: Array = []
	for z in zs:
		for x in xs:
			points.append(Vector2(float(x), float(z)))
	points.append(Vector2(span_x * 0.5, span_z * 0.5))
	return _dedupe_points(points, 0.04)

static func _build_axis_positions(span: float, stride: float, edge_inset: float, max_samples: int) -> Array:
	if span <= 1.05:
		return [edge_inset, span * 0.5, span - edge_inset]

	var desired: int = clampi(int(ceil(span / stride)) + 1, 3, max_samples)
	var min_pos: float = minf(edge_inset, span * 0.3)
	var max_pos: float = maxf(min_pos, span - min_pos)
	var result: Array = []
	for i in range(desired):
		var t: float = 0.0 if desired <= 1 else float(i) / float(desired - 1)
		result.append(lerp(min_pos, max_pos, t))
	result.append(span * 0.5)
	return _dedupe_scalar_array(result, 0.04)

static func _dedupe_points(points: Array, epsilon: float) -> Array:
	var result: Array = []
	for point in points:
		var p: Vector2 = point
		var duplicate := false
		for existing in result:
			if p.distance_to(existing) <= epsilon:
				duplicate = true
				break
		if not duplicate:
			result.append(p)
	return result

static func _dedupe_scalar_array(values: Array, epsilon: float) -> Array:
	var sorted: Array = values.duplicate()
	sorted.sort()
	var result: Array = []
	var has_last := false
	var last_value := 0.0
	for value in sorted:
		var f := float(value)
		if not has_last or abs(f - last_value) > epsilon:
			result.append(f)
			last_value = f
			has_last = true
	return result
