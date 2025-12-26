extends PanelContainer
class_name InventoryPanel
## InventoryPanel - Main inventory UI with 27 slots (3x9)
## Supports drag-and-drop with HUD hotbar via parent handle_slot_drop

signal item_dropped_outside(item_data: Dictionary, count: int, world_position: Vector3)

@onready var inventory_grid: GridContainer = $VBox/InventoryGrid

const InventorySlotScene = preload("res://modules/world_player/ui/inventory_slot.tscn")
const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")

var inventory_slots: Array = []
var inventory_ref: Node = null

func _ready() -> void:
	# Create inventory slots (27 = 3 rows x 9 cols)
	for i in range(27):
		var slot = InventorySlotScene.instantiate()
		slot.slot_index = i
		slot.item_dropped_outside.connect(_on_slot_item_dropped_outside.bind(slot))
		inventory_grid.add_child(slot)
		inventory_slots.append(slot)
	
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

## Find inventory node
func _find_references() -> void:
	if inventory_ref:
		return
	
	var player = get_tree().get_first_node_in_group("player")
	if player:
		inventory_ref = player.get_node_or_null("Systems/Inventory")

## Refresh display from inventory data
func refresh_display() -> void:
	_find_references()
	
	# Update inventory slots
	if inventory_ref and inventory_ref.has_method("get_all_slots"):
		var data = inventory_ref.get_all_slots()
		for i in range(min(inventory_slots.size(), data.size())):
			inventory_slots[i].set_slot_data(data[i], i)

## Handle drag-drop between slots (delegates to parent HUD for cross-system drops)
func handle_slot_drop(source_index: int, target_index: int) -> void:
	if source_index == target_index:
		return
	
	# Check if cross-system drop (inventory <-> hotbar)
	var source_is_hotbar = source_index >= 100
	var target_is_hotbar = target_index >= 100
	
	if source_is_hotbar or target_is_hotbar:
		# Delegate to parent HUD for cross-system drop
		var hud = get_parent()
		if hud and hud.has_method("handle_slot_drop"):
			hud.handle_slot_drop(source_index, target_index)
			refresh_display()
		return
	
	# Both are inventory slots - handle locally
	_find_references()
	
	if not inventory_ref:
		return
	
	# Get slot data
	var source_data = inventory_ref.get_slot(source_index) if inventory_ref.has_method("get_slot") else {}
	var target_data = inventory_ref.get_slot(target_index) if inventory_ref.has_method("get_slot") else {}
	
	var source_item = source_data.get("item", {})
	var source_count = source_data.get("count", 0)
	var target_item = target_data.get("item", {})
	var target_count = target_data.get("count", 0)
	
	# Swap items
	if inventory_ref.has_method("set_slot"):
		# If same item type, try to stack
		if source_item.get("id") == target_item.get("id") and source_item.get("id") != "empty":
			var stack_size = source_item.get("stack_size", 64)
			var space = stack_size - target_count
			var to_move = min(source_count, space)
			
			inventory_ref.set_slot(target_index, target_item, target_count + to_move)
			if source_count - to_move > 0:
				inventory_ref.set_slot(source_index, source_item, source_count - to_move)
			else:
				inventory_ref.clear_slot(source_index)
		else:
			# Swap
			inventory_ref.set_slot(target_index, source_item, source_count)
			inventory_ref.set_slot(source_index, target_item, target_count)
	
	refresh_display()

## Called when item is dropped outside a slot
func _on_slot_item_dropped_outside(item: Dictionary, count: int, slot) -> void:
	var slot_idx = slot.slot_index
	print("[INV_PANEL] _on_slot_item_dropped_outside slot_idx=%d item=%s count=%d" % [slot_idx, item.get("name", "?"), count])
	
	if inventory_ref and inventory_ref.has_method("clear_slot"):
		inventory_ref.clear_slot(slot_idx)
	
	# Get player position for drop
	# Get player position for drop
	var player = get_tree().get_first_node_in_group("player")
	var drop_pos = Vector3.ZERO
	var drop_velocity = Vector3.ZERO
	if player:
		# Use forward vector (negative Z) to drop IN FRONT of player
		drop_pos = player.global_position - player.global_transform.basis.z * 2.0 + Vector3.UP
		drop_velocity = -player.global_transform.basis.z * 3.0 + Vector3.UP * 2.0
	
	# Spawn pickup
	print("[INV_PANEL] Spawning pickup at %s" % drop_pos)
	_spawn_pickup(item, count, drop_pos, drop_velocity)
	
	item_dropped_outside.emit(item, count, drop_pos)
	refresh_display()

## Spawn a 3D pickup in the world
func _spawn_pickup(item: Dictionary, count: int, pos: Vector3, velocity: Vector3 = Vector3.ZERO) -> void:
	# Check if item has its own physics scene (like pistol) and should spawn directly
	var scene_path = item.get("scene", "")
	var spawned_directly = false
	
	if scene_path != "":
		var item_scene = load(scene_path)
		if item_scene:
			var temp_instance = item_scene.instantiate()
			# Check if the scene is a RigidBody3D (physics prop)
			if temp_instance is RigidBody3D:
				# Spawn directly as physics prop
				get_tree().root.add_child(temp_instance)
				temp_instance.global_position = pos
				
				# Add to interactable group for pickup
				if not temp_instance.is_in_group("interactable"):
					temp_instance.add_to_group("interactable")
				
				# Store item data on the node for re-pickup
				temp_instance.set_meta("item_data", item.duplicate())
				
				# Apply forward velocity
				temp_instance.linear_velocity = velocity
				
				print("[INV_PANEL] Dropped %s directly (physics prop)" % item.get("name", "item"))
				spawned_directly = true
			else:
				temp_instance.queue_free()
	
	# Fallback: use PickupItem wrapper
	if not spawned_directly:
		var pickup_scene = load("res://modules/world_player/pickups/pickup_item.tscn")
		if not pickup_scene:
			print("InventoryPanel: Failed to load pickup scene")
			return
		
		var pickup = pickup_scene.instantiate()
		get_tree().root.add_child(pickup)
		pickup.global_position = pos
		pickup.set_item(item, count)
		
		# Apply forward velocity
		pickup.linear_velocity = velocity
		
		print("InventoryPanel: Spawned wrapped pickup for %s x%d" % [item.get("name", "Item"), count])
