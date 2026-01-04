extends Node
class_name PlayerCombat
## PlayerCombat - Centralized combat logic
## Melee attacks, damage calculation, hit detection

# References
var player: WorldPlayer = null
var hotbar: Node = null

# Combat state
var attack_cooldown: float = 0.0
var combo_count: int = 0
var combo_timer: float = 0.0

# Combat settings
const BASE_ATTACK_COOLDOWN: float = 0.4 # Time between attacks
const COMBO_WINDOW: float = 0.8 # Time to chain combo
const MAX_COMBO: int = 3
const MELEE_RANGE: float = 2.5
const TOOL_RANGE: float = 3.5

func _ready() -> void:
	player = get_parent().get_parent() as WorldPlayer
	hotbar = get_node_or_null("../../Systems/Hotbar")
	
	DebugManager.log_player("PlayerCombat: Initialized")

func _process(delta: float) -> void:
	# Update cooldown
	if attack_cooldown > 0:
		attack_cooldown -= delta
	
	# Update combo timer
	if combo_timer > 0:
		combo_timer -= delta
		if combo_timer <= 0:
			combo_count = 0

## Check if can attack
func can_attack() -> bool:
	return attack_cooldown <= 0

## Perform melee attack
func do_attack(item: Dictionary) -> Dictionary:
	if not can_attack() or not player:
		return {}
	
	# Start cooldown
	attack_cooldown = BASE_ATTACK_COOLDOWN
	
	# Get range based on item
	var attack_range = MELEE_RANGE
	var category = item.get("category", 0)
	if category == 1: # TOOL
		attack_range = TOOL_RANGE
	
	# Perform raycast
	var hit = player.raycast(attack_range)
	
	if hit.is_empty():
		_on_attack_miss()
		return {}
	
	# Calculate damage
	var base_damage = item.get("damage", 1)
	var total_damage = _calculate_damage(base_damage)
	
	# Apply damage
	var target = hit.get("collider")
	var hit_result = {
		"target": target,
		"position": hit.get("position", Vector3.ZERO),
		"damage": total_damage,
		"is_crit": combo_count >= MAX_COMBO
	}
	
	if target and target.has_method("take_damage"):
		target.take_damage(total_damage)
		_on_attack_hit(target, total_damage)
	else:
		_on_attack_hit_object(hit)
	
	# Update combo
	_update_combo()
	
	return hit_result

## Calculate damage with modifiers
func _calculate_damage(base_damage: int) -> int:
	var multiplier = 1.0
	
	# Combo multiplier
	if combo_count > 0:
		multiplier += combo_count * 0.2 # 20% per combo hit
	
	# Crit on max combo
	if combo_count >= MAX_COMBO:
		multiplier *= 1.5
	
	return int(base_damage * multiplier)

## Update combo state
func _update_combo() -> void:
	combo_count = min(combo_count + 1, MAX_COMBO)
	combo_timer = COMBO_WINDOW

## Called on successful hit
func _on_attack_hit(target: Node, damage: int) -> void:
	DebugManager.log_player("PlayerCombat: Hit %s for %d damage (combo: %d)" % [target.name, damage, combo_count])
	PlayerSignals.damage_dealt.emit(target, damage)

## Called when hitting non-damageable object
func _on_attack_hit_object(hit: Dictionary) -> void:
	DebugManager.log_player("PlayerCombat: Hit object at %s" % hit.get("position", Vector3.ZERO))

## Called on miss
func _on_attack_miss() -> void:
	# Reset combo on miss
	combo_count = 0
	combo_timer = 0

## Get current combo count
func get_combo() -> int:
	return combo_count

## Check if in combo
func is_combo_active() -> bool:
	return combo_count > 0 and combo_timer > 0
