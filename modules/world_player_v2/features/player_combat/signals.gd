extends Node
## Combat Feature Signals - Damage, weapon readiness events

# Damage events
signal damage_dealt(target: Node, amount: int)
signal damage_received(amount: int, source: Node)

# Fist events
signal punch_triggered()
signal punch_ready()

# Pistol events
signal pistol_fired()
signal pistol_fire_ready()
signal pistol_reload()

# Axe events
signal axe_fired()
signal axe_ready()

# Durability events (for objects with HP like trees, rocks)
signal durability_hit(current_hp: int, max_hp: int, target_name: String, target_ref: Variant)
signal durability_cleared()
