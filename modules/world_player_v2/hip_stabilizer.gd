@tool
extends Node
class_name HipStabilizer
## Low-pass filter for skeleton bones — dampens fast sway while
## allowing slow animation transitions (walk→crouch) to pass through.
##
## Every frame:  1) Read animation's desired pose
##               2) Smoothly lerp our stored pose toward it
##               3) Apply the smoothed pose to the bone
##
## No recapture needed — fully automatic.
## Attach as a child of the Skeleton3D node.

@export var enabled: bool = true:
	set(value):
		enabled = value
		if not value and _skeleton:
			# Restore bones to their animated pose
			for idx in _bone_indices:
				_skeleton.reset_bone_pose(idx)
			_initialized = false

## Bones to stabilize. Comma-separated. Try "Hips" first, add "Spine" if sway persists.
@export var bone_names: String = "Hips":
	set(value):
		bone_names = value
		_initialized = false
		_resolve_bone_indices()

## How fast the smoothed pose follows the animation. Lower = more stable but laggier.
## 2.0 = very smooth (heavy damping), 10.0 = responsive, 30.0+ = nearly raw.
@export_range(1.0, 50.0, 0.5) var smoothing_speed: float = 5.0

## Print bone pose every N frames (0 = off). For debugging sway sources.
@export var debug_interval: int = 0

var _skeleton: Skeleton3D = null
var _bone_indices: Array[int] = []
var _smooth_positions: Dictionary = {}  # bone_idx -> Vector3
var _smooth_rotations: Dictionary = {}  # bone_idx -> Quaternion
var _initialized: bool = false
var _frame_count: int = 0

func _ready() -> void:
	process_priority = 90
	
	_skeleton = get_parent() as Skeleton3D
	if not _skeleton:
		push_error("[HIP_STAB] Parent is not a Skeleton3D")
		return
	
	_resolve_bone_indices()
	print("[HIP_STAB] Initialized — filtering bones: %s (speed: %.1f)" % [bone_names, smoothing_speed])

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

func _process(delta: float) -> void:
	if not _skeleton or _bone_indices.is_empty() or not enabled:
		return
	
	_frame_count += 1
	
	# Debug: print bone poses at interval
	if debug_interval > 0 and _frame_count % debug_interval == 0:
		_print_bone_debug()
	
	var t = clampf(smoothing_speed * delta, 0.0, 1.0)
	
	for idx in _bone_indices:
		# Read what the animation wants THIS frame
		var anim_pos = _skeleton.get_bone_pose_position(idx)
		var anim_rot = _skeleton.get_bone_pose_rotation(idx)
		
		if not _initialized:
			# First frame: snap to animation pose (no lerp)
			_smooth_positions[idx] = anim_pos
			_smooth_rotations[idx] = anim_rot
		else:
			# Smoothly follow the animation (low-pass filter)
			_smooth_positions[idx] = _smooth_positions[idx].lerp(anim_pos, t)
			_smooth_rotations[idx] = _smooth_rotations[idx].slerp(anim_rot, t)
		
		# Apply the filtered pose
		_skeleton.set_bone_pose_position(idx, _smooth_positions[idx])
		_skeleton.set_bone_pose_rotation(idx, _smooth_rotations[idx])
	
	if not _initialized:
		_initialized = true

func _print_bone_debug() -> void:
	var names_to_check = ["Hips", "Spine", "Spine1", "Chest", "UpperChest"]
	for bname in names_to_check:
		var idx = _skeleton.find_bone(bname)
		if idx < 0:
			continue
		var pos = _skeleton.get_bone_pose_position(idx)
		var rot = _skeleton.get_bone_pose_rotation(idx)
		var smooth_p = _smooth_positions.get(idx, Vector3.ZERO)
		print("[HIP_DEBUG] %s — anim: %s, smooth: %s, delta: %s" % [bname, pos, smooth_p, (pos - smooth_p)])
