extends Node

const LayoutClass := preload("res://world_marching_cubes/transvoxel_layout.gd")

func _ready() -> void:
	print("[TRANSVOXEL_LAYOUT] Starting block-layout validation")
	call_deferred("_run_tests")


func _run_tests() -> void:
	var layout_builder := LayoutClass.new()
	var layout: Dictionary = layout_builder.build_layout(Vector2i(37, -22), 4, 16, 2, 4)
	var blocks: Array = layout.get("blocks", [])

	if int(layout.get("coarse_cells_side", 0)) != 3:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected coarse_cells_side=3 got=%s" % [layout.get("coarse_cells_side", 0)])
		get_tree().quit(1)
		return

	if int(layout.get("hide_distance", 0)) != 3:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected hide_distance=3 got=%s" % [layout.get("hide_distance", 0)])
		get_tree().quit(1)
		return

	if blocks.size() != 12:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected 12 blocks got=%d" % blocks.size())
		get_tree().quit(1)
		return

	var fine_count := 0
	var coarse_count := 0
	var masked_count := 0
	var fine_block_world := float(layout.get("fine_block_world", 0.0))
	var coarse_block_world := float(layout.get("coarse_block_world", 0.0))

	for block in blocks:
		var lod_level := int(block.get("lod_level", -1))
		var kind := String(block.get("block_kind", ""))
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
			if int(block.get("transition_mask", 0)) != 0:
				print("[TRANSVOXEL_LAYOUT] ERROR: fine block should not have transitions mask=%d" % int(block.get("transition_mask", 0)))
				get_tree().quit(1)
				return
		elif lod_level == 1:
			coarse_count += 1
			if kind != "coarse":
				print("[TRANSVOXEL_LAYOUT] ERROR: coarse block mislabeled kind=%s" % kind)
				get_tree().quit(1)
				return
			if float(block.get("block_size", 0.0)) != coarse_block_world:
				print("[TRANSVOXEL_LAYOUT] ERROR: coarse block size mismatch size=%s expected=%s" % [block.get("block_size", 0.0), coarse_block_world])
				get_tree().quit(1)
				return
			if int(block.get("transition_mask", 0)) != 0:
				masked_count += 1
		else:
			print("[TRANSVOXEL_LAYOUT] ERROR: invalid lod_level=%d" % lod_level)
			get_tree().quit(1)
			return

	if fine_count != 4:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected 4 fine blocks got=%d" % fine_count)
		get_tree().quit(1)
		return

	if coarse_count != 8:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected 8 coarse blocks got=%d" % coarse_count)
		get_tree().quit(1)
		return

	if masked_count < 4:
		print("[TRANSVOXEL_LAYOUT] ERROR: expected at least 4 masked coarse blocks got=%d" % masked_count)
		get_tree().quit(1)
		return

	print("[TRANSVOXEL_LAYOUT] Layout passed with 12 blocks; fine=%d coarse=%d masked=%d" % [fine_count, coarse_count, masked_count])
	get_tree().quit(0)
