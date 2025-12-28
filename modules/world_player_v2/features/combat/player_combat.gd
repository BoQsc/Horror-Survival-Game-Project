extends Node
class_name PlayerCombatV2
## PlayerCombat - Centralized combat logic
## Melee attacks, damage calculation, hit detection

var player: Node = null
var hotbar: Node = null

var attack_cooldown: float = 0.0
var combo_count: int = 0
var combo_timer: float = 0.0

const BASE_ATTACK_COOLDOWN: float = 0.4
const COMBO_WINDOW: float = 0.8
const MAX_COMBO: int = 3
const MELEE_RANGE: float = 2.5
const TOOL_RANGE: float = 3.5

func _ready() -> void:
	player = get_parent().get_parent()
	hotbar = get_node_or_null("../../Systems/Hotbar")

func _process(delta: float) -> void:
	if attack_cooldown > 0:
		attack_cooldown -= delta
	
	if combo_timer > 0:
		combo_timer -= delta
		if combo_timer <= 0:
			combo_count = 0

func can_attack() -> bool:
	return attack_cooldown <= 0

func do_attack(item: Dictionary) -> Dictionary:
	if not can_attack() or not player:
		return {}
	
	attack_cooldown = BASE_ATTACK_COOLDOWN
	
	var attack_range = MELEE_RANGE
	var category = item.get("category", 0)
	if category == 1: # TOOL
		attack_range = TOOL_RANGE
	
	var hit = player.raycast(attack_range) if player.has_method("raycast") else {}
	
	if hit.is_empty():
		_on_attack_miss()
		return {}
	
	var base_damage = item.get("damage", 1)
	var total_damage = _calculate_damage(base_damage)
	
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
	
	_update_combo()
	
	return hit_result

func _calculate_damage(base_damage: int) -> int:
	var multiplier = 1.0
	
	if combo_count > 0:
		multiplier += combo_count * 0.2
	
	if combo_count >= MAX_COMBO:
		multiplier *= 1.5
	
	return int(base_damage * multiplier)

func _update_combo() -> void:
	combo_count = min(combo_count + 1, MAX_COMBO)
	combo_timer = COMBO_WINDOW

func _on_attack_hit(target: Node, damage: int) -> void:
	if has_node("/root/PlayerSignals"):
		PlayerSignals.damage_dealt.emit(target, damage)

func _on_attack_hit_object(_hit: Dictionary) -> void:
	pass

func _on_attack_miss() -> void:
	combo_count = 0
	combo_timer = 0

func get_combo() -> int:
	return combo_count

func is_combo_active() -> bool:
	return combo_count > 0 and combo_timer > 0
