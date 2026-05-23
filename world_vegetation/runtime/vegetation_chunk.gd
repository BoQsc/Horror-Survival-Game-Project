extends RefCounted
class_name VegetationChunk

enum State {
	UNLOADED,
	DATA_READY,
	BUILDING_ARRAYS,
	WAITING_UPLOAD,
	LIVE,
	DIRTY,
	EVICTING
}

enum DirtyReason {
	NONE,
	HARVESTED,
	TERRAIN_CHANGED,
	BIOME_CHANGED,
	STREAMED_IN,
	STREAMED_OUT,
	REGROWTH
}

var chunk_coord: Vector2i = Vector2i.ZERO
var bounds: AABB = AABB()
var state: int = State.UNLOADED
var dirty_reason: int = DirtyReason.NONE
var grass_cells: Array[Dictionary] = []
var cosmetic_bushes: Array[Dictionary] = []
var tree_records: Array[Dictionary] = []
var rock_records: Array[Dictionary] = []
var render_chunk_key: String = ""
var grass_mesh_rid: RID = RID()
var grass_instance_rid: RID = RID()
var individual_instance_rids: Dictionary = {}
var visible_grass_cell_count: int = 0
var visible_tree_record_count: int = 0
var visible_bush_record_count: int = 0
var visible_rock_record_count: int = 0
var grass_mesh_primitive_count: int = 0
var tree_mesh_primitive_count: int = 0
var bush_mesh_primitive_count: int = 0
var rock_mesh_primitive_count: int = 0
var grass_estimated_primitive_count: int = 0
var tree_estimated_primitive_count: int = 0
var bush_estimated_primitive_count: int = 0
var rock_estimated_primitive_count: int = 0
var support_points_total: int = 0
var last_rebuild_time_ms: float = 0.0
var last_support_refresh_time_ms: float = 0.0
var last_generated_frame: int = -1
var last_dirty_frame: int = -1
var last_dirtied_reason_name: String = ""


func reset() -> void:
	chunk_coord = Vector2i.ZERO
	bounds = AABB()
	state = State.UNLOADED
	dirty_reason = DirtyReason.NONE
	grass_cells.clear()
	cosmetic_bushes.clear()
	tree_records.clear()
	rock_records.clear()
	render_chunk_key = ""
	grass_mesh_rid = RID()
	grass_instance_rid = RID()
	individual_instance_rids.clear()
	visible_grass_cell_count = 0
	visible_tree_record_count = 0
	visible_bush_record_count = 0
	visible_rock_record_count = 0
	grass_mesh_primitive_count = 0
	tree_mesh_primitive_count = 0
	bush_mesh_primitive_count = 0
	rock_mesh_primitive_count = 0
	grass_estimated_primitive_count = 0
	tree_estimated_primitive_count = 0
	bush_estimated_primitive_count = 0
	rock_estimated_primitive_count = 0
	support_points_total = 0
	last_rebuild_time_ms = 0.0
	last_support_refresh_time_ms = 0.0
	last_generated_frame = -1
	last_dirty_frame = -1
	last_dirtied_reason_name = ""


func is_live() -> bool:
	return state == State.LIVE


func has_pending_rebuild() -> bool:
	return state == State.DIRTY or state == State.WAITING_UPLOAD or state == State.BUILDING_ARRAYS


func set_dirty(reason: int, frame_number: int = -1) -> void:
	state = State.DIRTY
	dirty_reason = reason
	last_dirty_frame = frame_number
	last_dirtied_reason_name = _dirty_reason_name(reason)


func mark_live(frame_number: int = -1) -> void:
	state = State.LIVE
	dirty_reason = DirtyReason.NONE
	last_generated_frame = frame_number


func _dirty_reason_name(reason: int) -> String:
	match reason:
		DirtyReason.HARVESTED:
			return "harvested"
		DirtyReason.TERRAIN_CHANGED:
			return "terrain_changed"
		DirtyReason.BIOME_CHANGED:
			return "biome_changed"
		DirtyReason.STREAMED_IN:
			return "streamed_in"
		DirtyReason.STREAMED_OUT:
			return "streamed_out"
		DirtyReason.REGROWTH:
			return "regrowth"
		_:
			return "none"


func get_grass_cell_count() -> int:
	return grass_cells.size()


func get_tree_record_count() -> int:
	return tree_records.size()


func get_bush_record_count() -> int:
	return cosmetic_bushes.size()


func get_rock_record_count() -> int:
	return rock_records.size()


func get_render_rid_count() -> int:
	var count := 0
	if grass_mesh_rid.is_valid():
		count += 1
	if grass_instance_rid.is_valid():
		count += 1
	count += individual_instance_rids.size()
	return count
