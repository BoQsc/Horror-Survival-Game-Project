extends Node
class_name Hotbar
## Hotbar - Manages the 10-slot quick access bar with stacking support
## Keys 1-9 select slots 0-8, key 0 selects slot 9

const SLOT_COUNT: int = 10
const MAX_STACK_SIZE: int = 3 # Maximum items per stack

# Slot data - array of {item: Dictionary, count: int}
var slots: Array = []
var selected_slot: int = 0

# Preload item definitions
const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")

func _ready() -> void:
	_load_dev_starter_kit()
	
	DebugManager.log_player("Hotbar: Initialized with %d slots (max stack: %d)" % [slots.size(), MAX_STACK_SIZE])
	
	# Auto-select first slot
	select_slot(0)

## Load default developer starter kit items
func _load_dev_starter_kit() -> void:
	# Initialize slots with test items (each as a stack of 1)
	var test_items = ItemDefs.get_test_items()
	slots.clear()
	for item in test_items:
		slots.append({"item": item, "count": 1 if item.get("id") != "empty" else 0})
	
	# Ensure we have exactly SLOT_COUNT slots
	while slots.size() < SLOT_COUNT:
		slots.append(_create_empty_stack())

func _input(event: InputEvent) -> void:
	# Number keys 1-0 for slots
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
			KEY_G: drop_selected_item()
		
		if new_slot >= 0 and new_slot != selected_slot:
			select_slot(new_slot)
	
	# Scroll wheel to cycle slots (only when not using Ctrl/Shift modifiers)
	if event is InputEventMouseButton and event.pressed:
		if not event.ctrl_pressed and not event.shift_pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				select_slot((selected_slot - 1 + SLOT_COUNT) % SLOT_COUNT)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				select_slot((selected_slot + 1) % SLOT_COUNT)

func select_slot(index: int) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return
	
	var _old_slot = selected_slot
	selected_slot = index
	
	var item = get_selected_item()
	var count = get_selected_count()
	DebugManager.log_player("Hotbar: Selected slot %d (%s x%d)" % [index, item.get("name", "Empty"), count])
	
	_emit_selection_change()
	PlayerSignals.hotbar_slot_selected.emit(selected_slot)

func _emit_selection_change() -> void:
	var item = get_selected_item()
	PlayerSignals.item_changed.emit(selected_slot, item)

## Get the currently selected item data (just the item, not count)
func get_selected_item() -> Dictionary:
	if selected_slot >= 0 and selected_slot < slots.size():
		return slots[selected_slot].get("item", _create_empty_item())
	return _create_empty_item()

## Get the count of the currently selected item
func get_selected_count() -> int:
	if selected_slot >= 0 and selected_slot < slots.size():
		return slots[selected_slot].get("count", 0)
	return 0

## Get item at specific slot (just the item)
func get_item_at(index: int) -> Dictionary:
	if index >= 0 and index < slots.size():
		return slots[index].get("item", _create_empty_item())
	return _create_empty_item()

## Get count at specific slot
func get_count_at(index: int) -> int:
	if index >= 0 and index < slots.size():
		return slots[index].get("count", 0)
	return 0

## Set item at specific slot with count
func set_item_at(index: int, item: Dictionary, count: int = 1) -> void:
	if index >= 0 and index < slots.size():
		if count <= 0:
			slots[index] = _create_empty_stack()
		else:
			slots[index] = {"item": item, "count": count}
		if index == selected_slot:
			_emit_selection_change()
		PlayerSignals.inventory_changed.emit()

## Clear a slot
func clear_slot(index: int) -> void:
	set_item_at(index, _create_empty_item(), 0)

## Decrement count at slot, returns true if item remains, false if slot emptied
func decrement_slot(index: int, amount: int = 1) -> bool:
	if index < 0 or index >= slots.size():
		return false
	
	var current_count = slots[index].get("count", 0)
	var new_count = current_count - amount
	
	if new_count <= 0:
		slots[index] = _create_empty_stack()
		if index == selected_slot:
			_emit_selection_change()
		PlayerSignals.inventory_changed.emit()
		return false
	else:
		slots[index]["count"] = new_count
		if index == selected_slot:
			_emit_selection_change()
		PlayerSignals.inventory_changed.emit()
		return true

## Check if selected item is a specific category
func is_selected_category(category: int) -> bool:
	var item = get_selected_item()
	return item.get("category", ItemDefs.ItemCategory.NONE) == category

## Get selected item's category
func get_selected_category() -> int:
	var item = get_selected_item()
	return item.get("category", ItemDefs.ItemCategory.NONE)

## Create an empty item dictionary (looks empty but acts like fists)
func _create_empty_item() -> Dictionary:
	return {
		"id": "empty",
		"name": "Empty",
		"category": ItemDefs.ItemCategory.NONE,
		"damage": 1,  # Acts like fists for combat
		"mining_strength": 1.0,  # Acts like fists for mining
		"stack_size": 1
	}

## Create an empty stack (count 0 means slot is empty)
func _create_empty_stack() -> Dictionary:
	return {"item": _create_empty_item(), "count": 0}

## Get all slots (for UI rendering)
func get_all_slots() -> Array:
	return slots

## Get selected slot index
func get_selected_index() -> int:
	return selected_slot

## Find first empty slot, returns -1 if none
## Skips the currently selected slot (so fists stay as fists), uses it only as last resort
func find_first_empty_slot() -> int:
	# First pass: find any empty slot that's NOT the selected slot
	for i in range(slots.size()):
		if i == selected_slot:
			continue  # Skip selected slot on first pass
		if slots[i].get("count", 0) == 0:
			return i
	
	# Second pass: only use selected slot if no other empty slots exist
	if slots[selected_slot].get("count", 0) == 0:
		return selected_slot
	
	return -1

## Find slot with matching item that has space for stacking
func find_stackable_slot(item_id: String) -> int:
	for i in range(slots.size()):
		var slot = slots[i]
		if slot.get("item", {}).get("id") == item_id:
			if slot.get("count", 0) < MAX_STACK_SIZE:
				return i
	return -1

## Add item to hotbar, tries stacking first, returns true if successful
func add_item(item: Dictionary) -> bool:
	var item_id = item.get("id", "empty")
	if item_id == "empty":
		return false
	
	# Check if item is stackable (resources are stackable, tools are not)
	var category = item.get("category", 0)
	var is_stackable = category >= 2 # BUCKET, RESOURCE, BLOCK, OBJECT, PROP
	
	if is_stackable:
		# Try to stack with existing item
		var stack_slot = find_stackable_slot(item_id)
		if stack_slot >= 0:
			slots[stack_slot]["count"] += 1
			DebugManager.log_player("Hotbar: Stacked %s in slot %d (now x%d)" % [item.get("name", "item"), stack_slot, slots[stack_slot]["count"]])
			if stack_slot == selected_slot:
				_emit_selection_change()  # Signal arms to update
			PlayerSignals.inventory_changed.emit()
			return true
	
	# Find empty slot
	var empty_slot = find_first_empty_slot()
	if empty_slot >= 0:
		# Use set_item_at to properly emit signals (including item_changed for arms visibility)
		set_item_at(empty_slot, item, 1)
		DebugManager.log_player("Hotbar: Added %s to slot %d" % [item.get("name", "item"), empty_slot])
		return true
	
	DebugManager.log_player("Hotbar: No space for %s" % item.get("name", "item"))
	return false

## Get slot data in inventory-compatible format {item: Dict, count: int}
func get_slot(index: int) -> Dictionary:
	if index >= 0 and index < slots.size():
		return slots[index].duplicate()
	return _create_empty_stack()

## Set slot data from inventory-compatible format
func set_slot(index: int, item: Dictionary, count: int) -> void:
	set_item_at(index, item, count)

## Drop the selected item as 3D pickup
## Hybrid: Items with physics scenes (like pistol) spawn directly, others use PickupItem wrapper
func drop_selected_item() -> void:
	var item = get_selected_item()
	var count = get_selected_count()
	
	if item.get("id", "empty") == "empty" or count <= 0:
		DebugManager.log_player("Hotbar: Nothing to drop")
		return
	
	# Get player position for drop
	var player = get_tree().get_first_node_in_group("player")
	if not player:
		DebugManager.log_player("Hotbar: No player found for drop")
		return
	
	var drop_pos = player.global_position - player.global_transform.basis.z * 2.0 + Vector3.UP
	var drop_velocity = -player.global_transform.basis.z * 3.0 + Vector3.UP * 2.0
	
	# Check if item has its own physics scene (like pistol)
	var scene_path = item.get("scene", "")
	var spawned_directly = false
	
	if scene_path != "":
		var item_scene = load(scene_path)
		if item_scene:
			var temp_instance = item_scene.instantiate()
			# Check if the scene is a RigidBody3D (physics prop)
			if temp_instance is RigidBody3D:
				# Spawn directly as physics prop (old method)
				get_tree().root.add_child(temp_instance)
				temp_instance.global_position = drop_pos
				temp_instance.linear_velocity = drop_velocity
				
				# Add to interactable group for pickup
				if not temp_instance.is_in_group("interactable"):
					temp_instance.add_to_group("interactable")
				
				# Store item data on the node for re-pickup
				temp_instance.set_meta("item_data", item.duplicate())
				temp_instance.set_meta("preferred_slot", selected_slot)
				
				DebugManager.log_player("Hotbar: Dropped %s directly (physics prop)" % item.get("name", "item"))
				spawned_directly = true
			else:
				# Not a RigidBody3D, clean up and use wrapper
				temp_instance.queue_free()
	
	# Fallback: use PickupItem wrapper for non-physics items
	if not spawned_directly:
		var pickup_scene = load("res://modules/world_player/pickups/pickup_item.tscn")
		if pickup_scene:
			var pickup = pickup_scene.instantiate()
			get_tree().root.add_child(pickup)
			pickup.global_position = drop_pos
			pickup.set_item(item, 1) # Drop 1 at a time
			pickup.preferred_slot = selected_slot
			pickup.linear_velocity = drop_velocity
			
			DebugManager.log_player("Hotbar: Dropped 1x %s (wrapped)" % item.get("name", "item"))
		else:
			DebugManager.log_player("Hotbar: Failed to load pickup scene")
			return
	
	# Decrement the slot (drops 1 at a time)
	DebugManager.log_player("Hotbar: Decrementing slot %d (current count: %d)" % [selected_slot, count])
	var success = decrement_slot(selected_slot, 1)
	
	# Verify decrement
	var new_count = get_count_at(selected_slot)
	DebugManager.log_player("Hotbar: Decrement success: %s, New Count: %d" % [success, new_count])
	
	if new_count >= count:
		# Critical failure: count did not decrease!
		DebugManager.log_player("CRITICAL: Hotbar slot count mismatch! Force clearing.")
		# Force decrement
		set_item_at(selected_slot, item, count - 1)
