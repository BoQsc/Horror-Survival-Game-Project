extends StaticBody3D
class_name ContainerInteractable
## ContainerInteractable - Attach to container objects to make them interactable
## Handles 'E' key interaction to open container UI

## Number of slots for this container type
@export var slot_count: int = 6

## Container name shown in UI
@export var container_name: String = "Container"

## The container's inventory (created on ready)
var container_inventory: ContainerInventory = null

## Track if this container is currently open
var is_open: bool = false

## Track if this container has been populated with loot
var is_populated: bool = false

# Item definitions for loot generation
const ItemDefs = preload("res://modules/world_player_v2/features/inventory/item_definitions.gd")

func _ready() -> void:
	# Add to groups for detection
	add_to_group("interactable")
	add_to_group("containers")
	
	# Create container inventory as child
	container_inventory = ContainerInventory.new()
	container_inventory.slot_count = slot_count
	container_inventory.name = "ContainerInventory"
	add_child(container_inventory)
	
	# Connect to container closed signal
	if has_node("/root/ContainerSignals"):
		ContainerSignals.container_closed.connect(_on_container_closed)
	
	DebugSettings.log_player("CONTAINER: Initialized %s with %d slots" % [container_name, slot_count])

## Called by player interaction system to get prompt text
func get_interaction_prompt() -> String:
	if is_open:
		return "Close %s [E]" % container_name
	return "Open %s [E]" % container_name

## Called when player presses E on this container
func interact() -> void:
	if is_open:
		# Close the container
		DebugSettings.log_player("CONTAINER: Closing %s" % container_name)
		if has_node("/root/ContainerSignals"):
			ContainerSignals.container_closed.emit()
		is_open = false
	else:
		# Open the container
		DebugSettings.log_player("CONTAINER: Opening %s" % container_name)
		is_open = true
		if has_node("/root/ContainerSignals"):
			ContainerSignals.container_opened.emit(self)
		else:
			# Fallback: try to find HUD directly
			var hud = get_tree().get_first_node_in_group("player_hud")
			if hud and hud.has_method("open_container"):
				hud.open_container(self)

func _on_container_closed() -> void:
	is_open = false

## Get the inventory for UI access
func get_inventory() -> ContainerInventory:
	return container_inventory

## Populate container with random loot (Called by prefab spawner, NOT player placement)
## This ensures player-placed containers remain empty
func populate_loot() -> void:
	if is_populated or not container_inventory:
		return
	
	is_populated = true
	
	# Define available loot items with weights
	var loot_table = [
		{"item": _get_wood_item(), "weight": 50, "min_count": 1, "max_count": 3},
		{"item": _get_dirt_item(), "weight": 30, "min_count": 1, "max_count": 3},
		{"item": _get_stone_item(), "weight": 15, "min_count": 1, "max_count": 2},
		{"item": _get_sand_item(), "weight": 5, "min_count": 1, "max_count": 2},
	]
	
	# Determine how many slots to fill (1-3 for cardboard, 2-5 for crate)
	var min_items = 1 if slot_count <= 6 else 2
	var max_items = 3 if slot_count <= 6 else 5
	var num_items = randi_range(min_items, max_items)
	
	# Generate loot
	var filled_slots: Array[int] = []
	for i in range(num_items):
		# Pick a random empty slot
		var available_slots: Array[int] = []
		for s in range(slot_count):
			if s not in filled_slots:
				available_slots.append(s)
		
		if available_slots.is_empty():
			break
		
		var slot_idx = available_slots.pick_random()
		filled_slots.append(slot_idx)
		
		# Pick random item from weighted loot table
		var item_entry = _pick_weighted_item(loot_table)
		var count = randi_range(item_entry.min_count, item_entry.max_count)
		
		container_inventory.set_slot(slot_idx, item_entry.item, count)
	
	DebugSettings.log_player("CONTAINER: Populated %s with %d items" % [container_name, num_items])

## Pick item from weighted loot table
func _pick_weighted_item(loot_table: Array) -> Dictionary:
	var total_weight = 0
	for entry in loot_table:
		total_weight += entry.weight
	
	var roll = randi() % total_weight
	var current = 0
	for entry in loot_table:
		current += entry.weight
		if roll < current:
			return entry
	
	return loot_table[0]

## Get wood item definition
func _get_wood_item() -> Dictionary:
	return {
		"id": "veg_wood",
		"name": "Wood",
		"category": ItemDefs.ItemCategory.BLOCK,
		"block_id": 1,
		"stack_size": 64
	}

## Get dirt item definition
func _get_dirt_item() -> Dictionary:
	return {
		"id": "dirt",
		"name": "Dirt",
		"category": ItemDefs.ItemCategory.RESOURCE,
		"mat_id": 0,
		"stack_size": 64
	}

## Get stone item definition
func _get_stone_item() -> Dictionary:
	return {
		"id": "res_stone",
		"name": "Stone",
		"category": ItemDefs.ItemCategory.RESOURCE,
		"mat_id": 1,
		"stack_size": 64
	}

## Get sand item definition
func _get_sand_item() -> Dictionary:
	return {
		"id": "res_sand",
		"name": "Sand",
		"category": ItemDefs.ItemCategory.RESOURCE,
		"mat_id": 3,
		"stack_size": 64
	}
