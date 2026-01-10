extends Node
class_name ContainerInventory
## ContainerInventory - Storage system for container objects
## Each container instance has its own inventory

const MAX_STACK_SIZE: int = 3

## Number of slots in this container
@export var slot_count: int = 6

## Item stacks - array of {item: Dictionary, count: int}
var slots: Array = []

## Unique ID for this container instance (for persistence)
var container_id: String = ""

func _ready() -> void:
	# Generate UUID if not set (ensures uniqueness)
	if container_id.is_empty():
		container_id = _generate_uuid()
	
	# Initialize slots based on slot_count
	_initialize_slots()
	
	# Auto-register with global registry
	if has_node("/root/ContainerRegistry"):
		ContainerRegistry.register_container(self, container_id)

func _exit_tree() -> void:
	# Unregister when destroyed
	if has_node("/root/ContainerRegistry"):
		ContainerRegistry.unregister_container(container_id)

## Generate a unique UUID for this container
func _generate_uuid() -> String:
	# Simple UUID generation using time + random + instance ID
	return "%s-%s-%s" % [
		Time.get_ticks_msec(),
		randi(),
		get_instance_id()
	]

func _initialize_slots() -> void:
	slots.clear()
	for i in range(slot_count):
		slots.append(_create_empty_stack())

## Add item to container, returns leftover count
func add_item(item: Dictionary, count: int = 1) -> int:
	var stack_size = min(MAX_STACK_SIZE, item.get("stack_size", MAX_STACK_SIZE))
	var remaining = count
	
	# First, try to stack with existing items
	for i in range(slot_count):
		if remaining <= 0:
			break
		
		var slot = slots[i]
		if slot.item.get("id") == item.get("id"):
			var space = stack_size - slot.count
			var to_add = min(remaining, space)
			if to_add > 0:
				slot.count += to_add
				remaining -= to_add
	
	# Then, try to fill empty slots
	for i in range(slot_count):
		if remaining <= 0:
			break
		
		if slots[i].item.get("id") == "empty":
			var to_add = min(remaining, stack_size)
			slots[i] = {"item": item.duplicate(), "count": to_add}
			remaining -= to_add
	
	return remaining

## Remove item from container by item ID
func remove_item(item_id: String, count: int = 1) -> int:
	var remaining = count
	
	# Remove from slots in reverse order (LIFO)
	for i in range(slot_count - 1, -1, -1):
		if remaining <= 0:
			break
		
		var slot = slots[i]
		if slot.item.get("id") == item_id:
			var to_remove = min(remaining, slot.count)
			slot.count -= to_remove
			remaining -= to_remove
			
			if slot.count <= 0:
				slots[i] = _create_empty_stack()
	
	return count - remaining # Return how many were actually removed

## Get slot data at index
func get_slot(index: int) -> Dictionary:
	if index >= 0 and index < slot_count:
		return slots[index]
	return _create_empty_stack()

## Set slot data at index
func set_slot(index: int, item: Dictionary, count: int) -> void:
	if index >= 0 and index < slot_count:
		slots[index] = {"item": item.duplicate(), "count": count}

## Clear a slot
func clear_slot(index: int) -> void:
	if index >= 0 and index < slot_count:
		slots[index] = _create_empty_stack()

## Get all slots (for UI)
func get_all_slots() -> Array:
	return slots

## Check if container is empty
func is_empty() -> bool:
	for slot in slots:
		if slot.item.get("id") != "empty":
			return false
	return true

## Check if container is full
func is_full() -> bool:
	for slot in slots:
		if slot.item.get("id") == "empty":
			return false
	return true

## Create empty stack
func _create_empty_stack() -> Dictionary:
	return {
		"item": {
			"id": "empty",
			"name": "Empty",
			"category": 0
		},
		"count": 0
	}

## Serialize container contents for saving
func serialize() -> Dictionary:
	var data = {
		"container_id": container_id,
		"slot_count": slot_count,
		"slots": []
	}
	for slot in slots:
		data.slots.append({
			"item": slot.item.duplicate(),
			"count": slot.count
		})
	return data

## Deserialize container contents from save data
func deserialize(data: Dictionary) -> void:
	container_id = data.get("container_id", str(randi()))
	slot_count = data.get("slot_count", 6)
	
	_initialize_slots()
	
	var saved_slots = data.get("slots", [])
	for i in range(min(saved_slots.size(), slot_count)):
		var saved = saved_slots[i]
		slots[i] = {
			"item": saved.get("item", {}).duplicate(),
			"count": saved.get("count", 0)
		}
