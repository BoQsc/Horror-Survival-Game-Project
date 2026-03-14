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
		
		# Robustness: Also connect to the underlying AnimationPlayer.
		# AnimationTree's animation_finished signal doesn't always fire for BlendTree nodes.
		var anim_player = anim_tree.get_animation_player()
		if anim_player:
			anim_player.animation_finished.connect(_on_animation_finished)
			
		print("FullBodyArms: Linked to AnimationTree and AnimationPlayer")
		
	if has_node("/root/PlayerSignals"):
		PlayerSignals.item_changed.connect(_on_item_changed)
		if PlayerSignals.has_signal("punch_triggered"):
			PlayerSignals.punch_triggered.connect(_on_punch_triggered)

func _on_animation_finished(anim_name: StringName) -> void:
	var name_str = str(anim_name)
	if "Transition_From_Idle_To_Attack_001" in name_str:
		if current_category == 0:
			_set_anim_properly("Atack_Hands_Idle_001")
			is_in_combat_stance = true
			
	elif "Attack_Quick_Jab_RH_001" in name_str:
		if current_category == 0:
			_set_anim_properly("Atack_Hands_Idle_001")
		
		# UNBLOCK combat system when the punch animation actually ends
		if has_node("/root/PlayerSignals"):
			PlayerSignals.punch_ready.emit()

func _on_item_changed(_slot: int, item: Dictionary) -> void:
	current_category = int(item.get("category", 0))
	
	# FAILSAVE: Unblock the CombatSystem on every item switch.
	# This ensures we don't get stuck if a punch was interrupted by a fast swap.
	if has_node("/root/PlayerSignals"):
		PlayerSignals.punch_ready.emit()
		
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
		_set_anim_properly("Idle_Hand_001")
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
		# CRITICAL FIX: Custom timeline overrides standard loop logic and can cause infinite restarts
		anim_node.use_custom_timeline = false
		
		var lib_prefix = "First_Person_Animations.001/"
		var full_name = lib_prefix + anim_name
		
		# EXPLICIT LOOP CONTROL:
		# Animation resources are SHARED. If the Previewer (ESC menu) turned on looping,
		# we must turn it off for one-shots, otherwise animation_finished never fires.
		var lib = anim_tree.get_animation_library("First_Person_Animations.001")
		if lib:
			var anim = lib.get_animation(anim_name)
			if anim:
				# Categorize animations: "Idle" animations loop, others are one-shot.
				# CRITICAL: "Transition_From_Idle..." contains "Idle" but MUST NOT loop.
				var should_loop = ("Idle" in anim_name) and not ("Transition" in anim_name)
				
				if should_loop:
					anim.loop_mode = Animation.LOOP_LINEAR
					anim_node.loop_mode = 2 # AnimationNodeAnimation.LOOP_LINEAR
				else:
					anim.loop_mode = Animation.LOOP_NONE
					anim_node.loop_mode = 1 # AnimationNodeAnimation.LOOP_NONE
					
				print("FullBodyArms: Applied ", full_name, " (ResLoop: ", anim.loop_mode, " NodeLoop: ", anim_node.loop_mode, ")")
		
		# Robust Update: Deactivate, set, reactivate
		# This forces the AnimationTree to re-sample from time 0 with the new loop settings
		anim_tree.active = false
		anim_node.animation = full_name
		anim_tree.active = true
