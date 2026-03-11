@tool
extends Node
class_name HipStabilizer
## Super simple hip stabilizer.
## On any animation graph change: wait, capture mid-frame, hold it forever.

@export var enabled: bool = true
@export var bone_name: String = "Hips"
@export var capture_delay: float = 0.5

var _skeleton: Skeleton3D = null
var _anim_tree: AnimationTree = null
var _bone_idx: int = -1
var _waiting: bool = false
var _wait_timer: float = 0.0
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
	# Ignore trigger if we're already waiting
	if _waiting:
		return
		
	_waiting = true
	_wait_timer = 0.0
	_has_capture = false
	print("[HIP_STAB] Node connection changed! Unfreezing hips & waiting %.1fs..." % capture_delay)

func _process(delta: float) -> void:
	if not enabled or not _skeleton or _bone_idx < 0:
		return
	
	if _waiting:
		_wait_timer += delta
		if _wait_timer >= capture_delay:
			# Time to capture!
			_frozen_pos = _skeleton.get_bone_pose_position(_bone_idx)
			_frozen_rot = _skeleton.get_bone_pose_rotation(_bone_idx)
			
			_waiting = false
			_has_capture = true
			print("[HIP_STAB] Capured mid-frame! Freezing hips at pos: %s" % _frozen_pos)
		return # Let the animation play freely while we wait
		
	if _has_capture:
		# Freeze it
		_skeleton.set_bone_pose_position(_bone_idx, _frozen_pos)
		_skeleton.set_bone_pose_rotation(_bone_idx, _frozen_rot)
