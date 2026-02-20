extends Node
## PlayerSignals - Global event bus for player-related events
## This autoload provides decoupled communication between player components and other systems.
##
## NOTE: All signals have @warning_ignore("unused_signal") annotations.
## This is intentional and correct for the Event Bus pattern:
## - Signals are declared here but emitted from other scripts (emitters)
## - Signals are connected to from other scripts (listeners)
## - Godot's static analyzer only checks if signals are used within THIS file
## - This creates false positive warnings, which we suppress
##
## This pattern is industry-standard and used by professional Godot plugins
## like Dialogue Manager (3,300+ stars on GitHub).
##
## References:
## - Godot Issue #95403: https://github.com/godotengine/godot/issues/95403
## - Godot Issue #27576: https://github.com/godotengine/godot/issues/27576


# Item events
@warning_ignore("unused_signal")
signal item_used(item_data: Dictionary, action: String)
@warning_ignore("unused_signal")
signal item_changed(slot: int, item_data: Dictionary)
@warning_ignore("unused_signal")
signal item_added(item_data: Dictionary, amount: int)
@warning_ignore("unused_signal")
signal hotbar_slot_selected(slot: int)

# Mode events
@warning_ignore("unused_signal")
signal mode_changed(old_mode: String, new_mode: String)
@warning_ignore("unused_signal")
signal editor_submode_changed(submode: int, submode_name: String)

# Combat events
@warning_ignore("unused_signal")
signal damage_dealt(target: Node, amount: int)
@warning_ignore("unused_signal")
signal damage_received(amount: int, source: Node)
@warning_ignore("unused_signal")
signal punch_triggered()
@warning_ignore("unused_signal")
signal punch_ready()  # Emitted when punch animation finishes, ready for next attack
@warning_ignore("unused_signal")
signal resource_placed()  # Emitted when resource (dirt/gravel/etc) is placed
@warning_ignore("unused_signal")
signal block_placed()  # Emitted when building block (cube/ramp/stairs) is placed
@warning_ignore("unused_signal")
signal object_placed()  # Emitted when object (door/cardboard/etc) is placed
@warning_ignore("unused_signal")
signal bucket_placed()  # Emitted when water bucket is used
@warning_ignore("unused_signal")
signal vehicle_spawned()  # Emitted when vehicle (car keys) spawns a vehicle
@warning_ignore("unused_signal")
signal player_died()

# Pistol events
@warning_ignore("unused_signal")
signal pistol_fired()  # Trigger shoot animation
@warning_ignore("unused_signal")
signal pistol_fire_ready()  # Animation done, can fire again
@warning_ignore("unused_signal")
signal pistol_reload()  # Trigger reload animation

# Axe events
@warning_ignore("unused_signal")
signal axe_fired() # Trigger swing animation
@warning_ignore("unused_signal")
signal axe_ready() # Animation done, can swing again

# Terraformer events
@warning_ignore("unused_signal")
signal terraformer_material_changed(material_name: String)

# Interaction events
@warning_ignore("unused_signal")
signal interaction_available(target: Node, prompt: String)
@warning_ignore("unused_signal")
signal interaction_unavailable()
@warning_ignore("unused_signal")
signal interaction_performed(target: Node, action: String)

# Durability events (for objects with HP)
@warning_ignore("unused_signal")
signal durability_hit(current_hp: int, max_hp: int, target_name: String, target_ref: Variant)
@warning_ignore("unused_signal")
signal durability_cleared()

# Inventory events
@warning_ignore("unused_signal")
signal inventory_changed()
@warning_ignore("unused_signal")
signal inventory_toggled(is_open: bool)

# UI events
@warning_ignore("unused_signal")
signal game_menu_toggled(is_open: bool)
@warning_ignore("unused_signal")
signal target_material_changed(material_name: String)

# Movement events
@warning_ignore("unused_signal")
signal player_jumped()
@warning_ignore("unused_signal")
signal player_landed()
@warning_ignore("unused_signal")
signal underwater_toggled(is_underwater: bool)
@warning_ignore("unused_signal")
signal camera_underwater_toggled(is_underwater: bool)

# Save/Load signals
@warning_ignore("unused_signal")
signal player_loaded()  # Emitted after player state is loaded from save

func _ready() -> void:
	DebugManager.log_player("PlayerSignals: Autoload initialized")
