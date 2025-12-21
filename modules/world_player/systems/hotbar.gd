extends Node
class_name Hotbar
## Hotbar - Manages the 10-slot quick access bar
## Keys 1-9 select slots 0-8, key 0 selects slot 9

const SLOT_COUNT: int = 10

# Slot data - array of item dictionaries (or null for empty)
var slots: Array = []
var selected_slot: int = 0

# Preload item definitions
const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")

func _ready() -> void:
	# Initialize with test items
	slots = ItemDefs.get_test_items()
	
	# Ensure we have exactly SLOT_COUNT slots
	while slots.size() < SLOT_COUNT:
		slots.append(_create_empty_slot())
	
	print("Hotbar: Initialized with %d slots" % slots.size())
	
	# Emit initial selection
	_emit_selection_change()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var new_slot = -1
		
		match event.keycode:
			KEY_1: new_slot = 0
			KEY_2: new_slot = 1
			KEY_3: new_slot = 2
			KEY_4: new_slot = 3
			KEY_5: new_slot = 4
			KEY_6: new_slot = 5
			KEY_7: new_slot = 6
			KEY_8: new_slot = 7
			KEY_9: new_slot = 8
			KEY_0: new_slot = 9
		
		if new_slot >= 0 and new_slot != selected_slot:
			select_slot(new_slot)

func select_slot(index: int) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return
	
	var _old_slot = selected_slot
	selected_slot = index
	
	print("Hotbar: Selected slot %d (%s)" % [index, get_selected_item().get("name", "Empty")])
	
	_emit_selection_change()
	PlayerSignals.hotbar_slot_selected.emit(selected_slot)

func _emit_selection_change() -> void:
	var item = get_selected_item()
	PlayerSignals.item_changed.emit(selected_slot, item)

## Get the currently selected item data
func get_selected_item() -> Dictionary:
	if selected_slot >= 0 and selected_slot < slots.size():
		return slots[selected_slot]
	return _create_empty_slot()

## Get item at specific slot
func get_item_at(index: int) -> Dictionary:
	if index >= 0 and index < slots.size():
		return slots[index]
	return _create_empty_slot()

## Set item at specific slot
func set_item_at(index: int, item: Dictionary) -> void:
	if index >= 0 and index < slots.size():
		slots[index] = item
		if index == selected_slot:
			_emit_selection_change()
		PlayerSignals.inventory_changed.emit()

## Clear a slot
func clear_slot(index: int) -> void:
	set_item_at(index, _create_empty_slot())

## Check if selected item is a specific category
func is_selected_category(category: int) -> bool:
	var item = get_selected_item()
	return item.get("category", ItemDefs.ItemCategory.NONE) == category

## Get selected item's category
func get_selected_category() -> int:
	var item = get_selected_item()
	return item.get("category", ItemDefs.ItemCategory.NONE)

## Create an empty slot item
func _create_empty_slot() -> Dictionary:
	return {
		"id": "empty",
		"name": "Empty",
		"category": ItemDefs.ItemCategory.NONE,
		"damage": 0,
		"mining_strength": 0.0,
		"stack_size": 1
	}

## Get all slots (for UI rendering)
func get_all_slots() -> Array:
	return slots

## Get selected slot index
func get_selected_index() -> int:
	return selected_slot
