@tool
extends Node
class_name HipStabilizer
## Hip stabilizer with dual-pose support (standing + crouching).
## Captures standing pose at startup. Crouching pose is captured on first crouch.
## Hips are ALWAYS frozen — never animated directly.

@export var enabled: bool = true
@export var bone_name: String = "Hips"
@export var crouch_blend_speed: float = 8.0  # How fast to transition to/from crouch pose

var _skeleton: Skeleton3D = null
var _anim_tree: AnimationTree = null
var _bone_idx: int = -1
var _player: CharacterBody3D = null  # Cached player ref
var _crouch_node: Node = null  # Cached crouch component ref

var _pose_positions: Dictionary = {}
var _pose_rotations: Dictionary = {}
var _poses_captured: bool = false
var _current_target_pos: Vector3
var _current_target_rot: Quaternion

# We must wait exactly 2 frames at startup so the AnimationTree 
# fully initializes the skeleton out of its default T-pose.
var _startup_frames: int = 0

func _ready() -> void:
	process_priority = 90
	_skeleton = get_parent() as Skeleton3D
	if not _skeleton:
		push_error("[HIP_STAB] Parent is not a Skeleton3D")
		return
	_bone_idx = _skeleton.find_bone(bone_name)
	if _bone_idx < 0:
		push_error("[HIP_STAB] Bone '%s' not found" % bone_name)
		return
	
	_anim_tree = _skeleton.get_parent().get_parent().get_node_or_null("AnimationTree")
	if _anim_tree:
		print("[HIP_STAB] AnimationTree found.")
		if _anim_tree.tree_root:
			if not _anim_tree.tree_root.is_connected("changed", _on_tree_changed):
				_anim_tree.tree_root.connect("changed", _on_tree_changed)
				print("[HIP_STAB] Connected to tree_root changes")
	
	# Cache player ref: Skeleton -> Armature -> Model -> WorldPlayerFullBody -> WorldPlayerV2
	var node = _skeleton
	for i in range(4):
		node = node.get_parent() if node else null
	if node is CharacterBody3D:
		_player = node
		_crouch_node = _player.get_node_or_null("Components/Crouch")
		if _crouch_node:
			print("[HIP_STAB] Crouch component found.")

func _on_tree_changed() -> void:
	if _startup_frames >= 2:
		_capture_all_poses()

func _capture_all_poses() -> void:
	if not _skeleton or _bone_idx < 0 or not _anim_tree:
		return
		
	var playback = _anim_tree.get("parameters/StateMachine/playback") as AnimationNodeStateMachinePlayback
	if not playback:
		return
		
	var states_to_capture = ["Idle", "Walk", "Sprint", "Crouch_Idle"]
	var original_node = playback.get_current_node()

	for state in states_to_capture:
		playback.start(state)
		# Advance slightly into the animation to capture a settled, mid-stride height
		_anim_tree.advance(0.3)
		
		_pose_positions[state] = _skeleton.get_bone_pose_position(_bone_idx)
		_pose_rotations[state] = _skeleton.get_bone_pose_rotation(_bone_idx)
	
	if original_node:
		playback.start(original_node)
	else:
		playback.start("Idle")
		
	_current_target_pos = _pose_positions["Idle"]
	_current_target_rot = _pose_rotations["Idle"]
	_poses_captured = true
	
	print("[HIP_STAB] Captured static poses: ", _pose_positions)

func _process(delta: float) -> void:
	if not enabled or not _skeleton or _bone_idx < 0:
		return
	
	# Delay startup capture by exactly 2 frames to ensure Skeleton3D is posed
	if _startup_frames < 2:
		_startup_frames += 1
		if _startup_frames == 2:
			_capture_all_poses()
		return
		
	if not _poses_captured:
		return
	
	# 1. Determine the target state the player logically wants to be in
	var target_state = "Idle"
	
	if not Engine.is_editor_hint():
		var is_crouching = false
		if _crouch_node and "is_crouching" in _crouch_node:
			is_crouching = _crouch_node.get("is_crouching")
			
		var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		var is_moving = input_dir.length() > 0.1
		
		if is_crouching:
			target_state = "Crouch_Idle"
		else:
			var is_sprinting = false
			var movement_node = _player.get_node_or_null("Components/Movement")
			if movement_node and "is_sprinting" in movement_node:
				is_sprinting = movement_node.get("is_sprinting")
				
			if is_moving and is_sprinting:
				target_state = "Sprint"
			elif is_moving:
				target_state = "Walk"
			
	# Fallback if state wasn't captured (shouldn't happen)
	if not _pose_positions.has(target_state):
		target_state = "Idle"
		
	# 2. Smoothly blend the frozen hips to that target state's height over time
	var desired_pos = _pose_positions[target_state]
	var desired_rot = _pose_rotations[target_state]
	
	_current_target_pos = _current_target_pos.lerp(desired_pos, crouch_blend_speed * delta)
	_current_target_rot = _current_target_rot.slerp(desired_rot, crouch_blend_speed * delta)
	
	# NEUTRALIZE ROLL: Ensure hips stay horizontal to prevent camera/torso tilt
	var euler = _current_target_rot.get_euler()
	euler.z = 0.0 # Force roll to zero
	_current_target_rot = Quaternion.from_euler(euler)
	
	# 3. OVERRIDE: Freeze the hips exactly at the blended target state, deleting animation bob entirely.
	_skeleton.set_bone_pose_position(_bone_idx, _current_target_pos)
	_skeleton.set_bone_pose_rotation(_bone_idx, _current_target_rot)
