extends RefCounted
class_name TransvoxelLayout

const FACE_MASKS := {
	"west": (1 << 1),
	"east": (1 << 0),
	"south": (1 << 5),
	"north": (1 << 4)
}

func build_layout(viewer_chunk: Vector2i, inner_chunks: int, outer_chunks: int, chunk_stride: int, subdivisions: int) -> Dictionary:
	var snap: int = max(1, inner_chunks)
	var anchor_chunk := Vector2i(
		int(floor(float(viewer_chunk.x) / float(snap))) * snap,
		int(floor(float(viewer_chunk.y) / float(snap))) * snap
	)

	var fine_block_world: float = float(snap * chunk_stride)
	var coarse_block_world: float = fine_block_world * 2.0
	var coarse_cells_side: int = int(ceil(float(max(outer_chunks, snap * 2)) / float(max(1, snap * 2))))
	coarse_cells_side = max(3, coarse_cells_side)
	if coarse_cells_side % 2 == 0:
		coarse_cells_side += 1

	var total_world: float = float(coarse_cells_side) * coarse_block_world
	var origin_x: float = float(anchor_chunk.x * chunk_stride) - total_world * 0.5
	var origin_z: float = float(anchor_chunk.y * chunk_stride) - total_world * 0.5
	var center_start: int = int(coarse_cells_side / 2)

	var blocks: Array = []
	var block_lookup: Dictionary = {}

	for coarse_z in range(coarse_cells_side):
		for coarse_x in range(coarse_cells_side):
			var coarse_min_x: float = origin_x + float(coarse_x) * coarse_block_world
			var coarse_min_z: float = origin_z + float(coarse_z) * coarse_block_world
			var is_center: bool = coarse_x == center_start and coarse_z == center_start
			if is_center:
				for fine_sub_z in range(2):
					for fine_sub_x in range(2):
						var base_x: int = coarse_x * 2 + fine_sub_x
						var base_z: int = coarse_z * 2 + fine_sub_z
						var block_min_x: float = coarse_min_x + float(fine_sub_x) * fine_block_world
						var block_min_z: float = coarse_min_z + float(fine_sub_z) * fine_block_world
						var fine_block := {
							"lod_level": 0,
							"block_kind": "fine",
							"grid_x": base_x,
							"grid_z": base_z,
							"grid_span": 1,
							"min_x": block_min_x,
							"max_x": block_min_x + fine_block_world,
							"min_z": block_min_z,
							"max_z": block_min_z + fine_block_world,
							"block_size": fine_block_world,
							"subdivisions": max(1, subdivisions),
							"transition_mask": 0
						}
						block_lookup["%d|%d" % [base_x, base_z]] = blocks.size()
						blocks.append(fine_block)
			else:
				var base_x := coarse_x * 2
				var base_z := coarse_z * 2
				var coarse_block := {
					"lod_level": 1,
					"block_kind": "coarse",
					"grid_x": base_x,
					"grid_z": base_z,
					"grid_span": 2,
					"min_x": coarse_min_x,
					"max_x": coarse_min_x + coarse_block_world,
					"min_z": coarse_min_z,
					"max_z": coarse_min_z + coarse_block_world,
					"block_size": coarse_block_world,
					"subdivisions": max(1, subdivisions),
					"transition_mask": 0
				}
				var coarse_index := blocks.size()
				blocks.append(coarse_block)
				for covered_z in range(2):
					for covered_x in range(2):
						block_lookup["%d|%d" % [base_x + covered_x, base_z + covered_z]] = coarse_index

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
		"coarse_block_world": coarse_block_world,
		"fine_block_world": fine_block_world,
		"coarse_cells_side": coarse_cells_side,
		"expected_block_count": blocks.size()
	}
