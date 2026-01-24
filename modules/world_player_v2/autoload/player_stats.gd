extends Node
## PlayerStats - Global player state that persists across scenes
## This autoload stores health, stamina, and other persistent player data.

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
	DebugManager.log_player("PlayerStats: Autoload initialized")

func take_damage(amount: int, source: Node = null) -> void:
	if is_dead:
		return
	
	health -= amount
	health = max(0, health)
	DebugManager.log_player("PlayerStats: Took %d damage. Health: %d/%d" % [amount, health, max_health])
	
	PlayerSignals.damage_received.emit(amount, source)
	
	if health <= 0:
		die()

func heal(amount: int) -> void:
	if is_dead:
		return
	
	health += amount
	health = min(health, max_health)
	DebugManager.log_player("PlayerStats: Healed %d. Health: %d/%d" % [amount, health, max_health])

func die() -> void:
	is_dead = true
	DebugManager.log_player("PlayerStats: Player died!")
	PlayerSignals.player_died.emit()

func reset() -> void:
	health = max_health
	stamina = max_stamina
	is_dead = false
	DebugManager.log_player("PlayerStats: Reset to full")

func use_stamina(amount: float) -> bool:
	if stamina >= amount:
		stamina -= amount
		return true
	return false

func regen_stamina(delta: float) -> void:
	if stamina < max_stamina:
		stamina = min(stamina + stamina_regen_rate * delta, max_stamina)

func get_health_percent() -> float:
	return float(health) / float(max_health)

func get_stamina_percent() -> float:
	return stamina / max_stamina
