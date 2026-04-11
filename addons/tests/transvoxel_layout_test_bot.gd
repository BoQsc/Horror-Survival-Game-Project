extends Node

const LayoutClass := preload("res://world_marching_cubes/transvoxel_layout.gd")

func _ready() -> void:
	print("[TRANSVOXEL_LAYOUT] Starting block-layout validation")
	call_deferred("_run_tests")


func _run_tests() -> void:
	var layout_builder := LayoutClass.new()
	var layout: Dictionary = layout_builder.build_layout(Vector2i(37, -22), 4, 128, 2, 4)
	var blocks: Array = layout.get("blocks", [])

	if int(layout.get("tier_count", 0)) < 3:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected tier_count>=3 got=%s" % [layout.get("tier_count", 0)])
		get_tree().quit(1)
		return

	if int(layout.get("hide_distance", 0)) != 8:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected hide_distance=8 got=%s" % [layout.get("hide_distance", 0)])
		get_tree().quit(1)
		return

	if blocks.size() < 40:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected at least 40 blocks got=%d" % blocks.size())
		get_tree().quit(1)
		return

	var fine_count := 0
	var tier1_count := 0
	var tier2_count := 0
	var tier3_count := 0
	var masked_count := 0
	var fine_block_world := float(layout.get("fine_block_world", 0.0))
	var max_block_world := float(layout.get("max_block_world", 0.0))
	var root_span_units := int(layout.get("root_span_units", 0))

	for block in blocks:
		var lod_level := int(block.get("lod_level", -1))
		var kind := String(block.get("block_kind", ""))
		var span_units: int = 1 << max(0, lod_level)
		if int(block.get("grid_span", 0)) != span_units:
			print("[TRANSVOXEL_LAYOUT] ERROR: grid_span mismatch for lod_level=%d span=%s expected=%d" % [lod_level, block.get("grid_span", 0), span_units])
			get_tree().quit(1)
			return
		if abs(float(block.get("block_size", 0.0)) - (fine_block_world * float(span_units))) > 0.001:
			print("[TRANSVOXEL_LAYOUT] ERROR: block_size mismatch for lod_level=%d size=%s expected=%s" % [lod_level, block.get("block_size", 0.0), fine_block_world * float(span_units)])
			get_tree().quit(1)
			return
		if lod_level == 0:
			fine_count += 1
			if kind != "fine":
				print("[TRANSVOXEL_LAYOUT] ERROR: fine block mislabeled kind=%s" % kind)
				get_tree().quit(1)
				return
			if float(block.get("block_size", 0.0)) != fine_block_world:
				print("[TRANSVOXEL_LAYOUT] ERROR: fine block size mismatch size=%s expected=%s" % [block.get("block_size", 0.0), fine_block_world])
				get_tree().quit(1)
				return
		elif lod_level == 1:
			tier1_count += 1
			if kind != "tier_1":
				print("[TRANSVOXEL_LAYOUT] ERROR: tier_1 block mislabeled kind=%s" % kind)
				get_tree().quit(1)
				return
		elif lod_level == 2:
			tier2_count += 1
			if kind != "tier_2":
				print("[TRANSVOXEL_LAYOUT] ERROR: tier_2 block mislabeled kind=%s" % kind)
				get_tree().quit(1)
				return
		elif lod_level == 3:
			tier3_count += 1
			if kind != "tier_3":
				print("[TRANSVOXEL_LAYOUT] ERROR: tier_3 block mislabeled kind=%s" % kind)
				get_tree().quit(1)
				return
		else:
			print("[TRANSVOXEL_LAYOUT] ERROR: invalid lod_level=%d" % lod_level)
			get_tree().quit(1)
			return

		if int(block.get("transition_mask", 0)) != 0:
			masked_count += 1

	if fine_count < 4:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected at least 4 fine blocks got=%d" % fine_count)
		get_tree().quit(1)
		return

	if tier1_count == 0 or tier2_count == 0 or tier3_count == 0:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected non-zero counts for tiers 1-3 got=%d/%d/%d" % [tier1_count, tier2_count, tier3_count])
		get_tree().quit(1)
		return

	if masked_count < 10:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected at least 10 masked blocks got=%d" % masked_count)
		get_tree().quit(1)
		return

	if root_span_units < 16:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected a wider root span got=%d" % root_span_units)
		get_tree().quit(1)
		return

	print("[TRANSVOXEL_LAYOUT] Layout passed with %d blocks; fine=%d tier1=%d tier2=%d tier3=%d masked=%d" % [blocks.size(), fine_count, tier1_count, tier2_count, tier3_count, masked_count])
	get_tree().quit(0)
