extends RefCounted
class_name VegetationSpatialGrid

const VegetationChunk = preload("res://world_vegetation/runtime/vegetation_chunk.gd")

var chunks: Dictionary = {}
var record_lookup: Dictionary = {}
var rid_lookup: Dictionary = {}


func clear() -> void:
	chunks.clear()
	record_lookup.clear()
	rid_lookup.clear()


func has_chunk(chunk_coord: Vector2i) -> bool:
	return chunks.has(chunk_coord)


func get_chunk(chunk_coord: Vector2i) -> VegetationChunk:
	return chunks.get(chunk_coord, null) as VegetationChunk


func set_chunk(chunk: VegetationChunk) -> void:
	if chunk == null:
		return
	chunks[chunk.chunk_coord] = chunk


func remove_chunk(chunk_coord: Vector2i) -> VegetationChunk:
	var chunk: VegetationChunk = chunks.get(chunk_coord, null) as VegetationChunk
	if chunk == null:
		return null
	chunks.erase(chunk_coord)
	return chunk


func register_record(kind: StringName, record_id: int, chunk_coord: Vector2i, record: Dictionary) -> void:
	unregister_record(record_id)
	record_lookup[record_id] = {
		"kind": kind,
		"chunk_coord": chunk_coord,
		"record": record
	}
	var instance_rid: RID = record.get("instance_rid", RID())
	if instance_rid.is_valid():
		rid_lookup[int(instance_rid.get_id())] = record_id


func unregister_record(record_id: int) -> void:
	if not record_lookup.has(record_id):
		return
	var entry: Dictionary = record_lookup[record_id]
	var record: Dictionary = entry.get("record", {})
	var instance_rid: RID = record.get("instance_rid", RID())
	if instance_rid.is_valid():
		rid_lookup.erase(int(instance_rid.get_id()))
	record_lookup.erase(record_id)


func get_record_entry(record_id: int) -> Dictionary:
	return record_lookup.get(record_id, {})


func get_record_by_rid(instance_rid: RID) -> Dictionary:
	if not instance_rid.is_valid():
		return {}
	var record_id := int(rid_lookup.get(int(instance_rid.get_id()), -1))
	if record_id < 0:
		return {}
	return get_record_entry(record_id)


func get_records_in_chunk(chunk_coord: Vector2i) -> Array[Dictionary]:
	var chunk := get_chunk(chunk_coord)
	if chunk == null:
		return []
	var records: Array[Dictionary] = []
	for record in chunk.tree_records:
		records.append(record)
	for record in chunk.cosmetic_bushes:
		records.append(record)
	for record in chunk.rock_records:
		records.append(record)
	return records


func query_chunks_in_aabb(bounds: AABB) -> Array[VegetationChunk]:
	var matches: Array[VegetationChunk] = []
	for chunk_variant in chunks.values():
		var chunk: VegetationChunk = chunk_variant as VegetationChunk
		if chunk == null:
			continue
		if _aabb_intersects(chunk.bounds, bounds):
			matches.append(chunk)
	return matches


func query_chunk_coords_in_aabb(bounds: AABB) -> Array[Vector2i]:
	var matches: Array[Vector2i] = []
	for chunk_coord_variant in chunks.keys():
		var chunk_coord := chunk_coord_variant as Vector2i
		var chunk: VegetationChunk = chunks[chunk_coord] as VegetationChunk
		if chunk == null:
			continue
		if _aabb_intersects(chunk.bounds, bounds):
			matches.append(chunk_coord)
	return matches


func _aabb_intersects(a: AABB, b: AABB) -> bool:
	if a.size == Vector3.ZERO or b.size == Vector3.ZERO:
		return a.has_point(b.position) or b.has_point(a.position)
	var a_min := a.position
	var a_max := a.position + a.size
	var b_min := b.position
	var b_max := b.position + b.size
	return not (
		a_max.x < b_min.x or a_min.x > b_max.x or
		a_max.y < b_min.y or a_min.y > b_max.y or
		a_max.z < b_min.z or a_min.z > b_max.z
	)
