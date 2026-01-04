extends Node
class_name PlayerStatsFeature
## PlayerStats - Player health, stamina, and death state
## This is the main stats feature script. Can be used as autoload or node.

# Local signals reference
var signals: Node = null

# Health
var health: int = 10
var max_health: int = 10

# Stamina
var stamina: float = 100.0
var max_stamina: float = 100.0
var stamina_regen_rate: float = 10.0 # Per second

# State flags
var is_dead: bool = false

func _ready() -> void:
	# Try to find local signals node (sibling or child)
	signals = get_node_or_null("../signals")
	if not signals:
		signals = get_node_or_null("signals")
	
	DebugManager.log_player("PlayerStatsFeature: Initialized")

func take_damage(amount: int, source: Node = null) -> void:
	if is_dead:
		return
	
	health -= amount
	health = max(0, health)
	DebugManager.log_player("PlayerStats: Took %d damage. Health: %d/%d" % [amount, health, max_health])
	
	# Emit local signal if available
	if signals and signals.has_signal("health_changed"):
		signals.health_changed.emit(health, max_health)
	
	# Also emit to global PlayerSignals for backward compatibility
	if Engine.has_singleton("PlayerSignals") or has_node("/root/PlayerSignals"):
		PlayerSignals.damage_received.emit(amount, source)
	
	if health <= 0:
		die()

func heal(amount: int) -> void:
	if is_dead:
		return
	
	health += amount
	health = min(health, max_health)
	DebugManager.log_player("PlayerStats: Healed %d. Health: %d/%d" % [amount, health, max_health])
	
	if signals and signals.has_signal("health_changed"):
		signals.health_changed.emit(health, max_health)

func die() -> void:
	is_dead = true
	DebugManager.log_player("PlayerStats: Player died!")
	
	if signals and signals.has_signal("player_died"):
		signals.player_died.emit()
	
	# Backward compat
	if Engine.has_singleton("PlayerSignals") or has_node("/root/PlayerSignals"):
		PlayerSignals.player_died.emit()

func reset() -> void:
	health = max_health
	stamina = max_stamina
	is_dead = false
	DebugManager.log_player("PlayerStats: Reset to full")

func use_stamina(amount: float) -> bool:
	if stamina >= amount:
		stamina -= amount
		if signals and signals.has_signal("stamina_changed"):
			signals.stamina_changed.emit(stamina, max_stamina)
		return true
	return false

func regen_stamina(delta: float) -> void:
	if stamina < max_stamina:
		stamina = min(stamina + stamina_regen_rate * delta, max_stamina)

func get_health_percent() -> float:
	return float(health) / float(max_health)

func get_stamina_percent() -> float:
	return stamina / max_stamina

## Serialize stats for saving
func get_save_data() -> Dictionary:
	return {
		"health": health,
		"max_health": max_health,
		"stamina": stamina,
		"max_stamina": max_stamina,
		"is_dead": is_dead
	}

## Deserialize stats from save
func load_save_data(data: Dictionary) -> void:
	health = data.get("health", max_health)
	max_health = data.get("max_health", 10)
	stamina = data.get("stamina", max_stamina)
	max_stamina = data.get("max_stamina", 100.0)
	is_dead = data.get("is_dead", false)
	
	# Emit signals to update UI
	if signals and signals.has_signal("health_changed"):
		signals.health_changed.emit(health, max_health)
	if signals and signals.has_signal("stamina_changed"):
		signals.stamina_changed.emit(stamina, max_stamina)
	
	DebugManager.log_player("PlayerStats: Loaded save data (Health: %d/%d, Stamina: %.1f/%.1f)" % [health, max_health, stamina, max_stamina])

