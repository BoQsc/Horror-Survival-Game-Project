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
signal punch_triggered()
signal punch_ready()  # Emitted when punch animation finishes, ready for next attack
signal resource_placed()  # Emitted when resource (dirt/gravel/etc) is placed
signal block_placed()  # Emitted when building block (cube/ramp/stairs) is placed
signal object_placed()  # Emitted when object (door/cardboard/etc) is placed
signal bucket_placed()  # Emitted when water bucket is used
signal vehicle_spawned()  # Emitted when vehicle (car keys) spawns a vehicle
signal player_died()

# Pistol events
signal pistol_fired()  # Trigger shoot animation
signal pistol_fire_ready()  # Animation done, can fire again
signal pistol_reload()  # Trigger reload animation

# Axe events
signal axe_fired() # Trigger swing animation
signal axe_ready() # Animation done, can swing again

# Terraformer events
signal terraformer_material_changed(material_name: String)

# Interaction events
signal interaction_available(target: Node, prompt: String)
signal interaction_unavailable()
signal interaction_performed(target: Node, action: String)

# Durability events (for objects with HP)
signal durability_hit(current_hp: int, max_hp: int, target_name: String, target_ref: Variant)
signal durability_cleared()

# Inventory events
signal inventory_changed()
signal inventory_toggled(is_open: bool)

# UI events
signal game_menu_toggled(is_open: bool)
signal target_material_changed(material_name: String)

# Movement events
signal player_jumped()
signal player_landed()
signal underwater_toggled(is_underwater: bool)
signal camera_underwater_toggled(is_underwater: bool)

# Save/Load signals
signal player_loaded()  # Emitted after player state is loaded from save

func _ready() -> void:
	DebugManager.log_player("PlayerSignals: Autoload initialized")
