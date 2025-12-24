extends Node
class_name Inventory
## Inventory - Full inventory storage with item stacks
## Works alongside Hotbar for extended storage

const INVENTORY_SIZE: int = 27 # 3 rows of 9

# Item stacks - array of {item: Dictionary, count: int}
var slots: Array = []

# Preload item definitions
const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")

# UI state
var is_open: bool = false

func _ready() -> void:
	# Initialize empty slots
	slots.clear()
	for i in range(INVENTORY_SIZE):
		slots.append(_create_empty_stack())
	
	print("Inventory: Initialized with %d slots" % INVENTORY_SIZE)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_I:
			toggle_inventory()

## Toggle inventory open/closed
func toggle_inventory() -> void:
	is_open = !is_open
	print("Inventory: %s" % ("Opened" if is_open else "Closed"))
	
	# Toggle mouse capture
	if is_open:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	PlayerSignals.inventory_toggled.emit(is_open)

## Add item to inventory, returns leftover count
func add_item(item: Dictionary, count: int = 1) -> int:
	var stack_size = item.get("stack_size", 1)
	var remaining = count
	
	# First, try to stack with existing items
	for i in range(INVENTORY_SIZE):
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
	for i in range(INVENTORY_SIZE):
		if remaining <= 0:
			break
		
		if slots[i].item.get("id") == "empty":
			var to_add = min(remaining, stack_size)
			slots[i] = {"item": item.duplicate(), "count": to_add}
			remaining -= to_add
	
	if remaining < count:
		PlayerSignals.inventory_changed.emit()
		print("Inventory: Added %d x %s (%d leftover)" % [count - remaining, item.get("name", "item"), remaining])
	
	return remaining

## Remove item from inventory by item ID
func remove_item(item_id: String, count: int = 1) -> int:
	var remaining = count
	
	# Remove from slots in reverse order (LIFO)
	for i in range(INVENTORY_SIZE - 1, -1, -1):
		if remaining <= 0:
			break
		
		var slot = slots[i]
		if slot.item.get("id") == item_id:
			var to_remove = min(remaining, slot.count)
			slot.count -= to_remove
			remaining -= to_remove
			
			if slot.count <= 0:
				slots[i] = _create_empty_stack()
	
	if remaining < count:
		PlayerSignals.inventory_changed.emit()
		print("Inventory: Removed %d x %s" % [count - remaining, item_id])
	
	return count - remaining # Return how many were actually removed

## Check if inventory has enough of an item
func has_item(item_id: String, count: int = 1) -> bool:
	var total = 0
	for slot in slots:
		if slot.item.get("id") == item_id:
			total += slot.count
	return total >= count

## Count total of an item in inventory
func count_item(item_id: String) -> int:
	var total = 0
	for slot in slots:
		if slot.item.get("id") == item_id:
			total += slot.count
	return total

## Get slot data at index
func get_slot(index: int) -> Dictionary:
	if index >= 0 and index < INVENTORY_SIZE:
		return slots[index]
	return _create_empty_stack()

## Set slot data at index
func set_slot(index: int, item: Dictionary, count: int) -> void:
	if index >= 0 and index < INVENTORY_SIZE:
		slots[index] = {"item": item.duplicate(), "count": count}
		PlayerSignals.inventory_changed.emit()

## Clear a slot
func clear_slot(index: int) -> void:
	if index >= 0 and index < INVENTORY_SIZE:
		slots[index] = _create_empty_stack()
		PlayerSignals.inventory_changed.emit()

## Get all slots (for UI)
func get_all_slots() -> Array:
	return slots

## Check if inventory is full
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
			"category": ItemDefs.ItemCategory.NONE
		},
		"count": 0
	}
