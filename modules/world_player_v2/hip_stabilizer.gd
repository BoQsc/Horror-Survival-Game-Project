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

# Standing pose (captured from Walk animation)
var _standing_pos: Vector3
var _standing_rot: Quaternion
var _has_standing: bool = false

# Crouching pose (captured on first crouch frame by reading what animation wants)
var _crouching_pos: Vector3
var _crouching_rot: Quaternion
var _has_crouching: bool = false
var _needs_crouch_capture: bool = false  # Flag: capture on next frame when crouching

# Current blend: 0.0 = standing, 1.0 = crouching
var _crouch_blend: float = 0.0

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
			print("[HIP_STAB] Crouch component found at: %s" % _crouch_node.get_path())
		else:
			print("[HIP_STAB] No Crouch component found")
	else:
		print("[HIP_STAB] Could not find player CharacterBody3D (got: %s)" % (node.name if node else "null"))

func _on_tree_changed() -> void:
	# Only re-capture if we've already done startup capture
	if _startup_frames >= 2:
		_capture_standing_pose("Node Connection Changed")

func _capture_standing_pose(reason: String = "Unknown") -> void:
	if not _skeleton or _bone_idx < 0 or not _anim_tree:
		return
	
	# Simulate 0.5s of Walk animation to find mid-stride pose
	_anim_tree.advance(0.5)
	
	_standing_pos = _skeleton.get_bone_pose_position(_bone_idx)
	_standing_rot = _skeleton.get_bone_pose_rotation(_bone_idx)
	_has_standing = true
	
	# Mark that we need to capture crouch pose on first crouch
	_needs_crouch_capture = true
	
	print("[HIP_STAB] [%s] Standing pose captured: %s" % [reason, _standing_pos])

func _process(delta: float) -> void:
	if not enabled or not _skeleton or _bone_idx < 0:
		return
	
	# Delay startup capture by exactly 2 frames to ensure Skeleton3D is posed
	if _startup_frames < 2:
		_startup_frames += 1
		if _startup_frames == 2:
			_capture_standing_pose("Game Startup")
		return
	
	# Determine crouch state
	var is_crouching = false
	if _crouch_node and "is_crouching" in _crouch_node:
		is_crouching = _crouch_node.is_crouching
	
	# Capture crouch pose on the first frame we're actually crouching
	# At this point the animation system has already computed the crouch pose
	# for the skeleton, so we can read it BEFORE we override
	if is_crouching and _needs_crouch_capture:
		_crouching_pos = _skeleton.get_bone_pose_position(_bone_idx)
		_crouching_rot = _skeleton.get_bone_pose_rotation(_bone_idx)
		_has_crouching = true
		_needs_crouch_capture = false
		print("[HIP_STAB] Crouch pose captured (live): %s (standing was: %s)" % [_crouching_pos, _standing_pos])
	
	# Blend toward target
	var target_blend = 1.0 if is_crouching else 0.0
	_crouch_blend = move_toward(_crouch_blend, target_blend, crouch_blend_speed * delta)
	
	if _has_standing:
		var final_pos = _standing_pos
		var final_rot = _standing_rot
		
		if _has_crouching:
			final_pos = _standing_pos.lerp(_crouching_pos, _crouch_blend)
			final_rot = _standing_rot.slerp(_crouching_rot, _crouch_blend)
		
		# ALWAYS override — hips never get animated directly
		_skeleton.set_bone_pose_position(_bone_idx, final_pos)
		_skeleton.set_bone_pose_rotation(_bone_idx, final_rot)
