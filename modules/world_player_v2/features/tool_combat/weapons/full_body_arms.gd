extends Node
class_name FullBodyArmsV2
## FullBodyArmsV2 - Controls the character rig's AnimationTree for first-person poses.
## This script is separate from the legacy first_person_arms.gd.

var anim_tree: AnimationTree = null
var current_category: int = -1
var is_in_combat_stance: bool = false

func _ready() -> void:
	# Reference path: Components -> Player -> WorldPlayerFullBody -> Superhero_Male_FullBody -> AnimationTree
	var player = get_parent().get_parent()
	if not player:
		print("FullBodyArms: Could not find player parent")
		return
		
	anim_tree = player.get_node_or_null("WorldPlayerFullBody/Superhero_Male_FullBody/AnimationTree")
	if not anim_tree:
		# Fallback recursive search
		anim_tree = player.find_child("AnimationTree", true, false)
		
	if anim_tree:
		anim_tree.active = true
		anim_tree.animation_finished.connect(_on_animation_finished)
		print("FullBodyArms: Linked to AnimationTree and connected signals")
		
	if has_node("/root/PlayerSignals"):
		PlayerSignals.item_changed.connect(_on_item_changed)
		if PlayerSignals.has_signal("punch_triggered"):
			PlayerSignals.punch_triggered.connect(_on_punch_triggered)

func _on_animation_finished(anim_name: StringName) -> void:
	var name_str = str(anim_name)
	if "Transition_From_Idle_To_Attack_001" in name_str:
		if current_category == 0:
			_set_anim_properly("Attack_Hands_Idle_001")
			is_in_combat_stance = true
			
	elif "Attack_Quick_Jab_RH_001" in name_str:
		if current_category == 0:
			_set_anim_properly("Attack_Hands_Idle_001")
		
		# UNBLOCK combat system when the punch animation actually ends
		if has_node("/root/PlayerSignals"):
			PlayerSignals.punch_ready.emit()

func _on_item_changed(_slot: int, item: Dictionary) -> void:
	current_category = int(item.get("category", 0))
	_update_state()

func _update_state() -> void:
	if not anim_tree: return
	
	# Path to the Blend2 node that overrides upper body
	var blend_path = "parameters/Blend2/blend_amount"
	
	# Categories: 0=NONE (Fists), 3=RESOURCE (Materials)
	if current_category == 0:
		# Combat Mode
		anim_tree.set(blend_path, 1.0)
		_enter_combat_stance()
	elif current_category == 3:
		# Material Hold Mode
		anim_tree.set(blend_path, 1.0)
		_set_anim_properly("Idle_Hands_001")
		is_in_combat_stance = false
	else:
		# Other items (Tools, etc.) - Let locomotion handle it
		anim_tree.set(blend_path, 0.0)
		is_in_combat_stance = false

func _enter_combat_stance() -> void:
	if is_in_combat_stance: return
	_set_anim_properly("Transition_From_Idle_To_Attack_001")
	# Logic continues in _on_animation_finished

func _on_punch_triggered() -> void:
	if current_category == 0:
		_set_anim_properly("Attack_Quick_Jab_RH_001")
		# Logic continues in _on_animation_finished

func _set_anim_properly(anim_name: String) -> void:
	if not anim_tree: return
	
	var root = anim_tree.tree_root
	if not root is AnimationNodeBlendTree:
		print("FullBodyArms: tree_root is not BlendTree")
		return
		
	# Find the target node name
	var target_node_name = ""
	for node_name in root.get_node_list():
		if node_name == "Full Body First Person Animation" or node_name == "PreviewAnim" or node_name == "Animation 2":
			target_node_name = node_name
			break
	
	if target_node_name == "":
		print("FullBodyArms: Could not find animation node in BlendTree")
		return
		
	var anim_node = root.get_node(target_node_name)
	if anim_node is AnimationNodeAnimation:
		var lib_prefix = "First_Person_Animations.001/"
		var full_name = lib_prefix + anim_name
		
		# Ensure one-shot animations are not looping so signals fire
		if "Jab" in anim_name or "Transition" in anim_name:
			var lib = anim_tree.get_animation_library("First_Person_Animations.001")
			if lib:
				var anim = lib.get_animation(anim_name)
				if anim:
					anim.loop_mode = Animation.LOOP_NONE
		
		# Robust Update: Deactivate, set, reactivate
		anim_tree.active = false
		anim_node.animation = full_name
		anim_tree.active = true
