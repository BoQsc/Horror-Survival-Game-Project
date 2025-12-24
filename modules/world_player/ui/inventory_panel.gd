extends PanelContainer
class_name InventoryPanel
## InventoryPanel - Main inventory UI with 27 slots (3x9) + 10 hotbar slots
## Supports drag-and-drop between inventory and hotbar

signal item_dropped_outside(item_data: Dictionary, count: int, world_position: Vector3)

@onready var inventory_grid: GridContainer = $VBox/InventoryGrid
@onready var hotbar_grid: HBoxContainer = $VBox/HotbarSection/HotbarGrid

const InventorySlotScene = preload("res://modules/world_player/ui/inventory_slot.tscn")
const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")

var inventory_slots: Array[InventorySlot] = []
var hotbar_slots: Array[InventorySlot] = []
var inventory_ref: Node = null
var hotbar_ref: Node = null

func _ready() -> void:
	# Create inventory slots (27 = 3 rows x 9 cols)
	for i in range(27):
		var slot = InventorySlotScene.instantiate() as InventorySlot
		slot.slot_index = i
		slot.item_dropped_outside.connect(_on_slot_item_dropped_outside.bind(slot))
		inventory_grid.add_child(slot)
		inventory_slots.append(slot)
	
	# Create hotbar slots (10) - offset by 100 to distinguish
	for i in range(10):
		var slot = InventorySlotScene.instantiate() as InventorySlot
		slot.slot_index = i + 100 # Offset for hotbar
		slot.item_dropped_outside.connect(_on_slot_item_dropped_outside.bind(slot))
		hotbar_grid.add_child(slot)
		hotbar_slots.append(slot)
	
	# Initially hidden
	visible = false
	
	# Connect to inventory toggle signal
	PlayerSignals.inventory_toggled.connect(_on_inventory_toggled)
	PlayerSignals.inventory_changed.connect(refresh_display)

## Show/hide inventory panel
func _on_inventory_toggled(is_open: bool) -> void:
	visible = is_open
	if is_open:
		_find_references()
		refresh_display()

## Find inventory and hotbar nodes
func _find_references() -> void:
	if inventory_ref and hotbar_ref:
		return
	
	var player = get_tree().get_first_node_in_group("player")
	if player:
		inventory_ref = player.get_node_or_null("Systems/Inventory")
		hotbar_ref = player.get_node_or_null("Systems/Hotbar")

## Refresh display from inventory/hotbar data
func refresh_display() -> void:
	_find_references()
	
	# Update inventory slots
	if inventory_ref and inventory_ref.has_method("get_all_slots"):
		var data = inventory_ref.get_all_slots()
		for i in range(min(inventory_slots.size(), data.size())):
			inventory_slots[i].set_slot_data(data[i], i)
	
	# Update hotbar slots - hotbar returns raw items, wrap in {item, count} format
	if hotbar_ref and hotbar_ref.has_method("get_all_slots"):
		var raw_data = hotbar_ref.get_all_slots()
		for i in range(min(hotbar_slots.size(), raw_data.size())):
			var item = raw_data[i]
			var wrapped = {"item": item, "count": 1 if item.get("id", "empty") != "empty" else 0}
			hotbar_slots[i].set_slot_data(wrapped, i + 100)

## Handle drag-drop between any slots (inventory or hotbar)
func handle_slot_drop(source_index: int, target_index: int) -> void:
	if source_index == target_index:
		return
	
	_find_references()
	
	# Determine which system each slot belongs to
	var source_is_hotbar = source_index >= 100
	var target_is_hotbar = target_index >= 100
	var source_idx = source_index % 100
	var target_idx = target_index % 100
	
	var source_system = hotbar_ref if source_is_hotbar else inventory_ref
	var target_system = hotbar_ref if target_is_hotbar else inventory_ref
	
	if not source_system or not target_system:
		return
	
	# Get slot data using get_slot (both systems have this now)
	var source_data = source_system.get_slot(source_idx) if source_system.has_method("get_slot") else {}
	var target_data = target_system.get_slot(target_idx) if target_system.has_method("get_slot") else {}
	
	var source_item = source_data.get("item", {})
	var source_count = source_data.get("count", 0)
	var target_item = target_data.get("item", {})
	var target_count = target_data.get("count", 0)
	
	# Swap items between systems
	if source_system.has_method("set_slot") and target_system.has_method("set_slot"):
		# If same item type and stackable, try to stack
		if source_item.get("id") == target_item.get("id") and source_item.get("id") != "empty":
			var stack_size = source_item.get("stack_size", 64)
			var space = stack_size - target_count
			var to_move = min(source_count, space)
			
			target_system.set_slot(target_idx, target_item, target_count + to_move)
			if source_count - to_move > 0:
				source_system.set_slot(source_idx, source_item, source_count - to_move)
			else:
				source_system.clear_slot(source_idx)
		else:
			# Swap
			target_system.set_slot(target_idx, source_item, source_count)
			source_system.set_slot(source_idx, target_item, target_count)
	
	refresh_display()

## Called when item is dropped outside a slot
func _on_slot_item_dropped_outside(item: Dictionary, count: int, slot: InventorySlot) -> void:
	var slot_idx = slot.slot_index
	var is_hotbar = slot_idx >= 100
	var actual_idx = slot_idx % 100
	var system = hotbar_ref if is_hotbar else inventory_ref
	
	if system and system.has_method("clear_slot"):
		system.clear_slot(actual_idx)
	
	# Get player position for drop
	var player = get_tree().get_first_node_in_group("player")
	var drop_pos = Vector3.ZERO
	if player:
		drop_pos = player.global_position + player.global_transform.basis.z * 2.0 + Vector3.UP
	
	# Spawn pickup
	_spawn_pickup(item, count, drop_pos)
	
	item_dropped_outside.emit(item, count, drop_pos)
	refresh_display()

## Spawn a 3D pickup in the world
func _spawn_pickup(item: Dictionary, count: int, pos: Vector3) -> void:
	var pickup_scene = load("res://modules/world_player/pickups/pickup_item.tscn")
	if not pickup_scene:
		print("InventoryPanel: Failed to load pickup scene")
		return
	
	var pickup = pickup_scene.instantiate()
	get_tree().root.add_child(pickup)
	pickup.global_position = pos
	pickup.set_item(item, count)
	
	# Random toss
	pickup.linear_velocity = Vector3(
		randf_range(-2, 2),
		randf_range(2, 4),
		randf_range(-2, 2)
	)
	
	print("InventoryPanel: Spawned pickup for %s x%d" % [item.get("name", "Item"), count])
