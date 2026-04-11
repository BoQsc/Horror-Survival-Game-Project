extends RefCounted
class_name TransvoxelLayout

const FACE_MASKS := {
	"west": (1 << 1),
	"east": (1 << 0),
	"south": (1 << 5),
	"north": (1 << 4)
}

func _next_power_of_two(value: int) -> int:
	var result: int = 1
	while result < value:
		result <<= 1
	return result

func build_layout(viewer_chunk: Vector2i, inner_chunks: int, outer_chunks: int, chunk_stride: int, subdivisions: int) -> Dictionary:
	var snap: int = max(1, inner_chunks)
	var anchor_chunk := Vector2i(
		int(floor(float(viewer_chunk.x) / float(snap))) * snap,
		int(floor(float(viewer_chunk.y) / float(snap))) * snap
	)

	var fine_block_world: float = float(snap * chunk_stride)
	var desired_root_span_units: int = max(4, int(ceil(float(max(outer_chunks, snap * 2)) / float(snap))))
	var root_span_units: int = _next_power_of_two(desired_root_span_units)
	var root_half_units: int = max(2, root_span_units / 2)
	var root_world_side: float = float(root_span_units) * fine_block_world
	var origin_x: float = float(anchor_chunk.x * chunk_stride) - root_world_side * 0.5
	var origin_z: float = float(anchor_chunk.y * chunk_stride) - root_world_side * 0.5
	var preview_center_units: float = float(root_half_units)

	var blocks: Array = []
	var block_lookup: Dictionary = {}
	var level_count: int = 0
	var level_probe: int = root_half_units
	while level_probe > 1:
		level_probe >>= 1
		level_count += 1

	for level in range(level_count):
		var span_units: int = 1 << level
		var band_inner_units: float = 0.0 if level == 0 else float(1 << level)
		var band_outer_units: float = float(1 << (level + 1))
		var cells_per_side: int = max(1, root_span_units / span_units)

		for cell_z in range(cells_per_side):
			for cell_x in range(cells_per_side):
				var cell_center_x_units: float = float(cell_x * span_units) + float(span_units) * 0.5 - preview_center_units
				var cell_center_z_units: float = float(cell_z * span_units) + float(span_units) * 0.5 - preview_center_units
				var square_distance: float = max(abs(cell_center_x_units), abs(cell_center_z_units))
				if level == 0:
					if square_distance > band_outer_units:
						continue
				else:
					if square_distance <= band_inner_units or square_distance > band_outer_units:
						continue

				var base_x: int = cell_x * span_units
				var base_z: int = cell_z * span_units
				var block_min_x: float = origin_x + float(base_x) * fine_block_world
				var block_min_z: float = origin_z + float(base_z) * fine_block_world
				var block_kind: String = "fine" if level == 0 else "tier_%d" % level
				var block := {
					"lod_level": level,
					"block_kind": block_kind,
					"grid_x": base_x,
					"grid_z": base_z,
					"grid_span": span_units,
					"min_x": block_min_x,
					"max_x": block_min_x + float(span_units) * fine_block_world,
					"min_z": block_min_z,
					"max_z": block_min_z + float(span_units) * fine_block_world,
					"block_size": float(span_units) * fine_block_world,
					"subdivisions": max(1, subdivisions),
					"transition_mask": 0
				}
				var block_index := blocks.size()
				blocks.append(block)
				for covered_z in range(span_units):
					for covered_x in range(span_units):
						block_lookup["%d|%d" % [base_x + covered_x, base_z + covered_z]] = block_index

	for i in range(blocks.size()):
		var block: Dictionary = blocks[i]
		if int(block.get("lod_level", 0)) <= 0:
			continue
		var base_x := int(block.get("grid_x", 0))
		var base_z := int(block.get("grid_z", 0))
		var span := int(block.get("grid_span", 1))
		var mask := 0

		for covered_z in range(span):
			var west_neighbor_index = block_lookup.get("%d|%d" % [base_x - 1, base_z + covered_z], -1)
			if west_neighbor_index >= 0:
				var west_neighbor: Dictionary = blocks[west_neighbor_index]
				if int(west_neighbor.get("lod_level", 0)) < int(block.get("lod_level", 0)):
					mask |= int(FACE_MASKS["west"])
					var west_neighbor_block: Dictionary = blocks[west_neighbor_index]
					west_neighbor_block["transition_mask"] = int(west_neighbor_block.get("transition_mask", 0)) | int(FACE_MASKS["east"])
					blocks[west_neighbor_index] = west_neighbor_block
					break
		for covered_z in range(span):
			var east_neighbor_index = block_lookup.get("%d|%d" % [base_x + span, base_z + covered_z], -1)
			if east_neighbor_index >= 0:
				var east_neighbor: Dictionary = blocks[east_neighbor_index]
				if int(east_neighbor.get("lod_level", 0)) < int(block.get("lod_level", 0)):
					mask |= int(FACE_MASKS["east"])
					var east_neighbor_block: Dictionary = blocks[east_neighbor_index]
					east_neighbor_block["transition_mask"] = int(east_neighbor_block.get("transition_mask", 0)) | int(FACE_MASKS["west"])
					blocks[east_neighbor_index] = east_neighbor_block
					break
		for covered_x in range(span):
			var south_neighbor_index = block_lookup.get("%d|%d" % [base_x + covered_x, base_z - 1], -1)
			if south_neighbor_index >= 0:
				var south_neighbor: Dictionary = blocks[south_neighbor_index]
				if int(south_neighbor.get("lod_level", 0)) < int(block.get("lod_level", 0)):
					mask |= int(FACE_MASKS["south"])
					var south_neighbor_block: Dictionary = blocks[south_neighbor_index]
					south_neighbor_block["transition_mask"] = int(south_neighbor_block.get("transition_mask", 0)) | int(FACE_MASKS["north"])
					blocks[south_neighbor_index] = south_neighbor_block
					break
		for covered_x in range(span):
			var north_neighbor_index = block_lookup.get("%d|%d" % [base_x + covered_x, base_z + span], -1)
			if north_neighbor_index >= 0:
				var north_neighbor: Dictionary = blocks[north_neighbor_index]
				if int(north_neighbor.get("lod_level", 0)) < int(block.get("lod_level", 0)):
					mask |= int(FACE_MASKS["north"])
					var north_neighbor_block: Dictionary = blocks[north_neighbor_index]
					north_neighbor_block["transition_mask"] = int(north_neighbor_block.get("transition_mask", 0)) | int(FACE_MASKS["south"])
					blocks[north_neighbor_index] = north_neighbor_block
					break

		block["transition_mask"] = mask
		blocks[i] = block

	return {
		"anchor_chunk": anchor_chunk,
		"hide_distance": max(1, inner_chunks * 2),
		"blocks": blocks,
		"coarse_block_world": fine_block_world * 2.0,
		"fine_block_world": fine_block_world,
		"root_span_units": root_span_units,
		"root_half_units": root_half_units,
		"tier_count": level_count,
		"max_block_world": fine_block_world * float(1 << max(0, level_count - 1)),
		"expected_block_count": blocks.size()
	}
