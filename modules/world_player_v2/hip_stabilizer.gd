@tool
extends Node
class_name HipStabilizer
## Super simple hip stabilizer.
## On any animation graph change: instantly simulates 0.5s, captures mid-frame, holds it forever.

@export var enabled: bool = true
@export var bone_name: String = "Hips"

var _skeleton: Skeleton3D = null
var _anim_tree: AnimationTree = null
var _bone_idx: int = -1
var _has_capture: bool = false
var _frozen_pos: Vector3
var _frozen_rot: Quaternion

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
			if not _anim_tree.tree_root.is_connected("changed", _trigger_capture):
				_anim_tree.tree_root.connect("changed", _trigger_capture)
				print("[HIP_STAB] Connected to tree_root changes (Node Connections!)")
		
		# Give the tree a frame to initialize
		call_deferred("_trigger_capture")

func _trigger_capture() -> void:
	if not _skeleton or _bone_idx < 0 or not _anim_tree:
		return
		
	# Instantly simulate 0.5 seconds of animation to find the middle pose
	var was_active = _anim_tree.active
	
	# Force an update step by advancing the tree manually
	_anim_tree.advance(0.5)
	
	# Immediately grab the calculated pose
	_frozen_pos = _skeleton.get_bone_pose_position(_bone_idx)
	_frozen_rot = _skeleton.get_bone_pose_rotation(_bone_idx)
	_has_capture = true
	
	print("[HIP_STAB] Node connection changed! Instantly captured pose 0.5s in: %s" % _frozen_pos)

func _process(delta: float) -> void:
	if not enabled or not _skeleton or _bone_idx < 0:
		return
		
	if _has_capture:
		# Freeze it
		_skeleton.set_bone_pose_position(_bone_idx, _frozen_pos)
		_skeleton.set_bone_pose_rotation(_bone_idx, _frozen_rot)
