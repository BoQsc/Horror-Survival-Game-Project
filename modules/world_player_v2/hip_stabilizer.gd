@tool
extends Node
class_name HipStabilizer
## Freezes selected bones to a captured pose, preventing animation sway.
##
## On the first frame, captures the animated pose for each bone in the list,
## then forces those exact poses every subsequent frame.
## Attach as a child of the Skeleton3D node.

@export var enabled: bool = true:
	set(value):
		enabled = value
		if not value:
			_captured = false
			# Restore all bones to their animated pose
			if _skeleton:
				for bone_idx in _frozen_positions.keys():
					_skeleton.reset_bone_pose(bone_idx)

## Bones to freeze. Comma-separated names. The sway often lives in the Spine, not just Hips.
@export var bone_names: String = "Hips":
	set(value):
		bone_names = value
		_captured = false
		_resolve_bone_indices()

## Recapture: skips freezing for 1 frame, lets animation play, then re-captures.
@export var recapture: bool = false:
	set(value):
		if value:
			_captured = false
			_skip_frame = true
			print("[HIP_STAB] Recapture requested — skipping 1 frame")
		# Always reset to false so the button is re-clickable
		recapture = false

## Print bone pose every N frames (0 = off). Helps find which bones actually sway.
@export var debug_interval: int = 0

var _skeleton: Skeleton3D = null
var _bone_indices: Array[int] = []
var _frozen_positions: Dictionary = {}  # bone_idx -> Vector3
var _frozen_rotations: Dictionary = {}  # bone_idx -> Quaternion
var _captured: bool = false
var _skip_frame: bool = false
var _frame_count: int = 0

func _ready() -> void:
	process_priority = 90
	
	_skeleton = get_parent() as Skeleton3D
	if not _skeleton:
		push_error("[HIP_STAB] Parent is not a Skeleton3D")
		return
	
	_resolve_bone_indices()
	print("[HIP_STAB] Initialized — bones to freeze: %s" % bone_names)

func _resolve_bone_indices() -> void:
	_bone_indices.clear()
	if not _skeleton:
		return
	for raw_name in bone_names.split(","):
		var bname = raw_name.strip_edges()
		if bname.is_empty():
			continue
		var idx = _skeleton.find_bone(bname)
		if idx >= 0:
			_bone_indices.append(idx)
		else:
			push_warning("[HIP_STAB] Bone '%s' not found" % bname)

func _process(_delta: float) -> void:
	if not _skeleton or _bone_indices.is_empty():
		return
	
	if not enabled:
		return
	
	# Skip one frame after recapture request so the AnimationTree can set real poses
	if _skip_frame:
		_skip_frame = false
		return
	
	_frame_count += 1
	
	# Debug: print bone poses at interval (helps find sway source)
	if debug_interval > 0 and _frame_count % debug_interval == 0:
		_print_bone_debug()
	
	if not _captured:
		# Capture current animated poses
		for idx in _bone_indices:
			_frozen_positions[idx] = _skeleton.get_bone_pose_position(idx)
			_frozen_rotations[idx] = _skeleton.get_bone_pose_rotation(idx)
			var bname = _skeleton.get_bone_name(idx)
			print("[HIP_STAB] Captured '%s' — pos: %s, rot: %s" % [bname, _frozen_positions[idx], _frozen_rotations[idx]])
		_captured = true
	
	# Apply frozen poses
	for idx in _bone_indices:
		_skeleton.set_bone_pose_position(idx, _frozen_positions[idx])
		_skeleton.set_bone_pose_rotation(idx, _frozen_rotations[idx])

func _print_bone_debug() -> void:
	# Show current ANIMATED pose vs our frozen pose for each tracked bone
	# Temporarily read what the animation wants before we override
	var names_to_check = ["Hips", "Spine", "Spine1", "Chest", "UpperChest"]
	for bname in names_to_check:
		var idx = _skeleton.find_bone(bname)
		if idx < 0:
			continue
		var pos = _skeleton.get_bone_pose_position(idx)
		var rot = _skeleton.get_bone_pose_rotation(idx)
		print("[HIP_DEBUG] %s — pos: %s, rot: %s" % [bname, pos, rot])

