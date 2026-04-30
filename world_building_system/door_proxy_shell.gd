extends StaticBody3D

const CHUNK_SIZE := 16
const INTERACTIVE_DOOR_SCENE := "res://models/objects/interactive_door/interactive_door.tscn"

var _is_swapping_to_full_door: bool = false


func get_interaction_prompt() -> String:
	return "Press E to open"


func interact() -> void:
	if _is_swapping_to_full_door:
		return
	_is_swapping_to_full_door = true

	var chunk: Node = get_meta("chunk", null)
	var anchor: Vector3i = get_meta("anchor", Vector3i.ZERO)
	if not is_instance_valid(chunk):
		return

	_remove_batched_door_visual(chunk, anchor)
	var full_door := _instantiate_full_door()
	if not full_door:
		_is_swapping_to_full_door = false
		return

	full_door.position = position
	full_door.rotation_degrees = rotation_degrees
	full_door.scale = scale
	full_door.set_meta("anchor", anchor)
	full_door.set_meta("chunk", chunk)
	full_door.set_meta("object_id", int(get_meta("object_id", 4)))
	full_door.add_to_group("placed_objects")

	chunk.add_child(full_door)
	if "object_nodes" in chunk:
		chunk.object_nodes[anchor] = full_door

	queue_free()
	if full_door.has_method("interact"):
		full_door.call_deferred("interact")


func take_damage(amount: int) -> void:
	var full_door := _swap_to_full_door_without_opening()
	if full_door and full_door.has_method("take_damage"):
		full_door.call_deferred("take_damage", amount)


func _swap_to_full_door_without_opening() -> Node3D:
	if _is_swapping_to_full_door:
		return null
	_is_swapping_to_full_door = true

	var chunk: Node = get_meta("chunk", null)
	var anchor: Vector3i = get_meta("anchor", Vector3i.ZERO)
	if not is_instance_valid(chunk):
		return null

	_remove_batched_door_visual(chunk, anchor)
	var full_door := _instantiate_full_door()
	if not full_door:
		_is_swapping_to_full_door = false
		return null

	full_door.position = position
	full_door.rotation_degrees = rotation_degrees
	full_door.scale = scale
	full_door.set_meta("anchor", anchor)
	full_door.set_meta("chunk", chunk)
	full_door.set_meta("object_id", int(get_meta("object_id", 4)))
	full_door.add_to_group("placed_objects")

	chunk.add_child(full_door)
	if "object_nodes" in chunk:
		chunk.object_nodes[anchor] = full_door

	queue_free()
	return full_door


func _instantiate_full_door() -> Node3D:
	var packed := ObjectRegistry.get_preloaded_scene(INTERACTIVE_DOOR_SCENE)
	if not packed:
		packed = load(INTERACTIVE_DOOR_SCENE)
	if not packed:
		return null
	return packed.instantiate() as Node3D


func _remove_batched_door_visual(chunk: Node, anchor: Vector3i) -> void:
	if not ("chunk_coord" in chunk):
		return
	if not ("manager" in chunk):
		return
	var manager: Node = chunk.manager
	if not is_instance_valid(manager) or not manager.has_method("remove_global_visual_batch"):
		return

	var chunk_coord: Vector3i = chunk.chunk_coord
	var world_anchor := Vector3i(
		chunk_coord.x * CHUNK_SIZE + anchor.x,
		chunk_coord.y * CHUNK_SIZE + anchor.y,
		chunk_coord.z * CHUNK_SIZE + anchor.z
	)
	if manager.remove_global_visual_batch(world_anchor) and manager.has_method("flush_global_visual_batches"):
		manager.flush_global_visual_batches()
