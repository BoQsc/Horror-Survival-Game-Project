extends Node
## Inventory Feature Signals - Item and hotbar events

signal item_used(item_data: Dictionary, action: String)
signal item_changed(slot: int, item_data: Dictionary)
signal hotbar_slot_selected(slot: int)
signal inventory_changed()
signal inventory_toggled(is_open: bool)
