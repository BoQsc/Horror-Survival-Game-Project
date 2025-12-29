extends PanelContainer
class_name ContainerPanelV2
## ContainerPanel - Split-view UI for container + player inventory
## Supports drag-and-drop between container and player inventory

signal closed()

@onready var title_label: Label = $VBox/Header/Title
@onready var close_button: Button = $VBox/Header/CloseButton
@onready var container_grid: GridContainer = $VBox/Content/ContainerSection/ContainerGrid
@onready var inventory_grid: GridContainer = $VBox/Content/InventorySection/InventoryGrid
@onready var container_label: Label = $VBox/Content/ContainerSection/ContainerLabel

# Reuse inventory slot scene
const InventorySlotScene = preload("res://modules/world_player_v2/features/inventory/ui/inventory_slot.tscn")

var container_slots: Array = []
var inventory_slots: Array = []
var current_container: Node = null
var container_inventory: Node = null
var player_inventory: Node = null

func _ready() -> void:
	visible = false
	close_button.pressed.connect(_on_close_pressed)
	
	# Create player inventory slots (27 slots)
	for i in range(27):
		var slot = InventorySlotScene.instantiate()
		slot.slot_index = i + 200  # Offset to distinguish from container slots
		slot.item_dropped_outside.connect(_on_inv_slot_item_dropped_outside.bind(slot))
		inventory_grid.add_child(slot)
		inventory_slots.append(slot)
	
	# Try to connect to signals autoload
	if has_node("/root/ContainerSignals"):
		ContainerSignals.container_opened.connect(_on_container_opened)

func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE or event.keycode == KEY_E:
			close_container()
			get_viewport().set_input_as_handled()

func open_container(container: Node) -> void:
	current_container = container
	
	# Get container inventory
	if container.has_method("get_inventory"):
		container_inventory = container.get_inventory()
	elif container.has_node("ContainerInventory"):
		container_inventory = container.get_node("ContainerInventory")
	
	if not container_inventory:
		DebugSettings.log_player("CONTAINER_UI: No inventory found on container")
		return
	
	# Get container name
	var container_name = "Container"
	if "container_name" in container:
		container_name = container.container_name
	
	title_label.text = container_name.to_upper()
	container_label.text = container_name
	
	# Find player inventory
	var player = get_tree().get_first_node_in_group("player")
	if player:
		player_inventory = player.get_node_or_null("Systems/Inventory")
	
	# Setup container slots based on slot count
	_setup_container_slots(container_inventory.slot_count)
	
	# Refresh both displays
	refresh_display()
	
	# Show panel and capture mouse
	visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	DebugSettings.log_player("CONTAINER_UI: Opened %s with %d slots" % [container_name, container_inventory.slot_count])

func close_container() -> void:
	visible = false
	current_container = null
	container_inventory = null
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	closed.emit()
	
	if has_node("/root/ContainerSignals"):
		ContainerSignals.container_closed.emit()
	
	DebugSettings.log_player("CONTAINER_UI: Closed")

func _setup_container_slots(slot_count: int) -> void:
	# Clear existing container slots
	for slot in container_slots:
		slot.queue_free()
	container_slots.clear()
	
	# Adjust grid columns based on slot count
	if slot_count <= 6:
		container_grid.columns = 3
	else:
		container_grid.columns = 4
	
	# Create new slots
	for i in range(slot_count):
		var slot = InventorySlotScene.instantiate()
		slot.slot_index = i  # Container slots use indices 0-11
		slot.item_dropped_outside.connect(_on_container_slot_item_dropped_outside.bind(slot))
		container_grid.add_child(slot)
		container_slots.append(slot)

func refresh_display() -> void:
	# Refresh container slots
	if container_inventory:
		var data = container_inventory.get_all_slots()
		for i in range(min(container_slots.size(), data.size())):
			container_slots[i].set_slot_data(data[i], i)
	
	# Refresh player inventory slots
	if player_inventory and player_inventory.has_method("get_all_slots"):
		var data = player_inventory.get_all_slots()
		for i in range(min(inventory_slots.size(), data.size())):
			inventory_slots[i].set_slot_data(data[i], i + 200)

func handle_slot_drop(source_index: int, target_index: int) -> void:
	if source_index == target_index:
		return
	
	var source_is_container = source_index < 100
	var target_is_container = target_index < 100
	var source_is_player = source_index >= 200
	var target_is_player = target_index >= 200
	
	# Determine source and target inventories
	var source_inv: Node = null
	var target_inv: Node = null
	var source_idx = source_index
	var target_idx = target_index
	
	if source_is_container:
		source_inv = container_inventory
		source_idx = source_index
	elif source_is_player:
		source_inv = player_inventory
		source_idx = source_index - 200
	
	if target_is_container:
		target_inv = container_inventory
		target_idx = target_index
	elif target_is_player:
		target_inv = player_inventory
		target_idx = target_index - 200
	
	if not source_inv or not target_inv:
		return
	
	# Get source and target data
	var source_data = source_inv.get_slot(source_idx)
	var target_data = target_inv.get_slot(target_idx)
	
	var source_item = source_data.get("item", {})
	var source_count = source_data.get("count", 0)
	var target_item = target_data.get("item", {})
	var target_count = target_data.get("count", 0)
	
	# Handle stacking or swapping
	if source_item.get("id") == target_item.get("id") and source_item.get("id") != "empty":
		# Stack items
		var stack_size = source_item.get("stack_size", 3)
		var space = stack_size - target_count
		var to_move = min(source_count, space)
		
		target_inv.set_slot(target_idx, target_item, target_count + to_move)
		if source_count - to_move > 0:
			source_inv.set_slot(source_idx, source_item, source_count - to_move)
		else:
			source_inv.clear_slot(source_idx)
	else:
		# Swap items
		target_inv.set_slot(target_idx, source_item, source_count)
		source_inv.set_slot(source_idx, target_item, target_count)
	
	refresh_display()
	
	# Emit player inventory changed signal if needed
	if (source_is_player or target_is_player) and has_node("/root/PlayerSignals"):
		PlayerSignals.inventory_changed.emit()

func _on_close_pressed() -> void:
	close_container()

func _on_container_opened(container: Node) -> void:
	open_container(container)

func _on_container_slot_item_dropped_outside(item: Dictionary, count: int, slot) -> void:
	# Item dropped from container to world
	var slot_idx = slot.slot_index
	
	if container_inventory:
		container_inventory.clear_slot(slot_idx)
	
	_spawn_pickup_in_world(item, count)
	refresh_display()

func _on_inv_slot_item_dropped_outside(item: Dictionary, count: int, slot) -> void:
	# Item dropped from player inventory to world
	var slot_idx = slot.slot_index - 200
	
	if player_inventory and player_inventory.has_method("clear_slot"):
		player_inventory.clear_slot(slot_idx)
	
	_spawn_pickup_in_world(item, count)
	refresh_display()
	
	if has_node("/root/PlayerSignals"):
		PlayerSignals.inventory_changed.emit()

func _spawn_pickup_in_world(item: Dictionary, count: int) -> void:
	var player = get_tree().get_first_node_in_group("player")
	var drop_pos = Vector3.ZERO
	var drop_velocity = Vector3.ZERO
	
	if player:
		drop_pos = player.global_position - player.global_transform.basis.z * 2.0 + Vector3.UP
		drop_velocity = -player.global_transform.basis.z * 3.0 + Vector3.UP * 2.0
	
	# Try to spawn from scene path first
	var scene_path = item.get("scene", "")
	if scene_path != "":
		var item_scene = load(scene_path)
		if item_scene:
			var temp_instance = item_scene.instantiate()
			if temp_instance is RigidBody3D:
				get_tree().root.add_child(temp_instance)
				temp_instance.global_position = drop_pos
				if not temp_instance.is_in_group("interactable"):
					temp_instance.add_to_group("interactable")
				temp_instance.set_meta("item_data", item.duplicate())
				temp_instance.linear_velocity = drop_velocity
				return
			else:
				temp_instance.queue_free()
	
	# Fallback to pickup item
	var pickup_scene = load("res://modules/world_player_v2/features/pickups/pickup_item.tscn")
	if pickup_scene:
		var pickup = pickup_scene.instantiate()
		get_tree().root.add_child(pickup)
		pickup.global_position = drop_pos
		pickup.set_item(item, count)
		pickup.linear_velocity = drop_velocity
