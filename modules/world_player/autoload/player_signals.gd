extends Node
## PlayerSignals - Global event bus for player-related events
## This autoload provides decoupled communication between player components and other systems.

# Item events
signal item_used(item_data: Dictionary, action: String)
signal item_changed(slot: int, item_data: Dictionary)
signal hotbar_slot_selected(slot: int)

# Mode events
signal mode_changed(old_mode: String, new_mode: String)
signal editor_submode_changed(submode: int, submode_name: String)

# Combat events
signal damage_dealt(target: Node, amount: int)
signal damage_received(amount: int, source: Node)
signal player_died()

# Interaction events
signal interaction_available(target: Node, prompt: String)
signal interaction_unavailable()
signal interaction_performed(target: Node, action: String)

# Inventory events
signal inventory_changed()
signal inventory_toggled(is_open: bool)

# UI events
signal game_menu_toggled(is_open: bool)

# Movement events
signal player_jumped()
signal player_landed()

func _ready() -> void:
	print("PlayerSignals: Autoload initialized")
