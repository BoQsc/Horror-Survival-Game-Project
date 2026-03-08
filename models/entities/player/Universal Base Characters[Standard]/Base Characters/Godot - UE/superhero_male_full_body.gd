@tool
extends Node3D

# ─────────────────────────────────────────────
# HEAD VISIBILITY TOGGLE — First Person / Third Person
# Uses near-zero bone scale instead of exactly zero
# so BoneAttachment3D (camera holder) stays valid.
# ─────────────────────────────────────────────

@export var skeleton_path: NodePath = "WorldPlayerFullBody/Superhero_Male_FullBody/Armature/GeneralSkeleton"
@export var head_bone_name: String = "Head"
@export var transition_duration: float = 0.15

## Extra nodes to hide in first person (drag Eyebrows, Eyes here)
@export var extra_head_nodes: Array[NodePath] = []

@export var first_person_mode: bool = false:
	set(value):
		first_person_mode = value
		if not _ready_called:
			return
		if Engine.is_editor_hint():
			_apply_instant(first_person_mode)
		else:
			if transition_duration > 0.0:
				_tween_head(first_person_mode)
			else:
				_apply_instant(first_person_mode)

var _skeleton: Skeleton3D
var _head_bone_idx: int = -1
var _active_tween: Tween = null
var _ready_called: bool = false

# Near-zero scale — visually invisible but det != 0
# so BoneAttachment3D (camera) stays valid
const HIDDEN_SCALE := Vector3(0.001, 0.001, 0.001)
const VISIBLE_SCALE := Vector3.ONE


func _ready() -> void:
	_skeleton = get_node_or_null(skeleton_path)
	if _skeleton == null:
		push_error("HeadToggle: Skeleton3D not found at: '%s'" % skeleton_path)
		return

	_head_bone_idx = _skeleton.find_bone(head_bone_name)
	if _head_bone_idx == -1:
		push_error("HeadToggle: Bone '%s' not found. Bones: %s" % [head_bone_name, _get_all_bone_names()])
		return

	# Always start clean
	_skeleton.set_bone_pose_scale(_head_bone_idx, VISIBLE_SCALE)

	_ready_called = true
	_apply_instant(first_person_mode)


# ─────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────

func set_first_person(enabled: bool) -> void:
	first_person_mode = enabled

func enter_first_person() -> void:
	first_person_mode = true

func exit_first_person() -> void:
	first_person_mode = false

func toggle_first_person() -> void:
	first_person_mode = not first_person_mode


# ─────────────────────────────────────────────
# INTERNAL
# ─────────────────────────────────────────────

func _apply_instant(hide_head: bool) -> void:
	if _skeleton == null or _head_bone_idx == -1:
		return
	_skeleton.set_bone_pose_scale(_head_bone_idx, HIDDEN_SCALE if hide_head else VISIBLE_SCALE)
	_set_extra_nodes_visible(not hide_head)


func _tween_head(hide_head: bool) -> void:
	if _skeleton == null or _head_bone_idx == -1:
		return

	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()

	var from_scale: Vector3 = _skeleton.get_bone_pose_scale(_head_bone_idx)
	var to_scale: Vector3 = HIDDEN_SCALE if hide_head else VISIBLE_SCALE

	# Hide extra nodes immediately when going FP
	if hide_head:
		_set_extra_nodes_visible(false)

	_active_tween = create_tween()
	_active_tween.set_ease(Tween.EASE_IN_OUT)
	_active_tween.set_trans(Tween.TRANS_CUBIC)
	_active_tween.tween_method(
		func(s: Vector3) -> void:
			if _skeleton and _head_bone_idx != -1:
				_skeleton.set_bone_pose_scale(_head_bone_idx, s),
		from_scale,
		to_scale,
		transition_duration
	)

	# Show extra nodes only after tween finishes when returning to 3rd person
	if not hide_head:
		_active_tween.tween_callback(func() -> void:
			_set_extra_nodes_visible(true)
		)


func _set_extra_nodes_visible(show: bool) -> void:
	for path in extra_head_nodes:
		var node := get_node_or_null(path)
		if node:
			node.visible = show


func _get_all_bone_names() -> Array:
	if _skeleton == null:
		return []
	var names := []
	for i in _skeleton.get_bone_count():
		names.append(_skeleton.get_bone_name(i))
	return names
