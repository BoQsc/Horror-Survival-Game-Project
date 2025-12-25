extends PanelContainer
class_name InventorySlot
## InventorySlot - UI component for a single inventory/hotbar slot
## Supports drag-and-drop, displays item icon and count

signal item_dropped_outside(item_data: Dictionary, count: int)
signal slot_clicked(slot_index: int)

@onready var item_label: Label = $ItemLabel
@onready var count_label: Label = $CountLabel

var slot_index: int = 0
var slot_data: Dictionary = {} # {item: Dictionary, count: int}
var is_dragging: bool = false

const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")

func _ready() -> void:
	# Set up for drag-drop
	mouse_filter = MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(48, 48)
	
	# Style for empty slot
	_update_display()

## Set slot data and update display
func set_slot_data(data: Dictionary, index: int) -> void:
	slot_data = data
	slot_index = index
	_update_display()

## Get current slot data
func get_slot_data() -> Dictionary:
	return slot_data

## Check if slot is empty
func is_empty() -> bool:
	return slot_data.get("item", {}).get("id", "empty") == "empty"

## Update visual display
func _update_display() -> void:
	var item = slot_data.get("item", {})
	var count = slot_data.get("count", 0)
	var item_id = item.get("id", "empty")
	
	if item_id == "empty" or count <= 0:
		item_label.text = ""
		count_label.text = ""
		modulate = Color(0.5, 0.5, 0.5, 0.5)
	else:
		# Show full item name with smaller font
		var item_name = item.get("name", "???")
		item_label.text = item_name
		count_label.text = str(count) if count > 1 else ""
		modulate = Color.WHITE

## Handle drag start
func _get_drag_data(_at_position: Vector2) -> Variant:
	if is_empty():
		return null
	
	is_dragging = true
	
	# Create drag preview
	var preview = Label.new()
	preview.text = slot_data.get("item", {}).get("name", "Item")
	preview.add_theme_color_override("font_color", Color.WHITE)
	set_drag_preview(preview)
	
	# Return slot data for drop handling
	return {
		"source_slot": slot_index,
		"item": slot_data.get("item", {}).duplicate(),
		"count": slot_data.get("count", 0)
	}

## Handle item dropped on this slot
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("item")

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not data is Dictionary:
		return
	
	# Find a parent that has handle_slot_drop (could be InventoryPanel or PlayerHUD)
	var node = get_parent()
	while node:
		if node.has_method("handle_slot_drop"):
			node.handle_slot_drop(data.get("source_slot", -1), slot_index)
			return
		node = node.get_parent()

## Handle click
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		slot_clicked.emit(slot_index)

## Called when drag ends (for detecting drops outside UI)
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		if is_dragging:
			is_dragging = false
			# Check if dropped outside any valid target
			var viewport = get_viewport()
			if viewport:
				var drop_target = viewport.gui_get_drag_data()
				# If there's still drag data, it wasn't consumed - dropped outside
				if drop_target != null and not is_empty():
					item_dropped_outside.emit(slot_data.get("item", {}), slot_data.get("count", 0))
