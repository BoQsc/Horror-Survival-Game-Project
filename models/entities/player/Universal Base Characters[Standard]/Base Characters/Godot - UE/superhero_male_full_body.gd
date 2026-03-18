@tool
extends Node3D

const FP_BODY_SHADER_PATH: String = "res://models/entities/player/Universal Base Characters[Standard]/Base Characters/Godot - UE/fp_body.gdshader"
const FP_BODY_ALBEDO_PATH: String = "res://models/entities/player/Universal Base Characters[Standard]/Base Characters/Godot - UE/T_Superhero_Male_Dark.png"
const FP_BODY_NORMAL_PATH: String = "res://models/entities/player/Universal Base Characters[Standard]/Base Characters/Godot - UE/T_Superhero_Male_Normal.png"
const FP_BODY_ROUGHNESS_PATH: String = "res://models/entities/player/Universal Base Characters[Standard]/Base Characters/Godot - UE/T_Superhero_Male_Roughness.png"

@export var skeleton_path: NodePath = "WorldPlayerFullBody/Superhero_Male_FullBody/Armature/GeneralSkeleton"
@export var chest_bone_name: String = "Chest"
@export var head_bone_name: String = "Head"
@export var transition_duration: float = 0.15

## Controls how high the first-person clip plane sits above the chest bone.
@export var chest_clip_bias: float = 0.02

## Softens the band near the clip plane so debug colors are easier to read.
@export var chest_clip_feather: float = 0.08

## When true, the body shader uses bright debug colors in first-person mode.
@export var debug_colors: bool = false

## Legacy head hiding support. Leave off for the new chest-up overlay mode.
@export var hide_head_in_first_person: bool = false

## Extra nodes to hide in first person (drag Eyebrows, Eyes here)
@export var extra_head_nodes: Array[NodePath] = []

var _first_person_mode: bool = true

@export var first_person_mode: bool:
	get:
		return _first_person_mode
	set(value):
		_first_person_mode = value
		if _ready_called:
			_apply_overlay_state()

var _skeleton: Skeleton3D
var _head_bone_idx: int = -1
var _chest_bone_idx: int = -1
var _active_tween: Tween = null
var _ready_called: bool = false
var _player: CharacterBody3D = null
var _overlay_meshes: Array[MeshInstance3D] = []
var _original_material_overrides: Dictionary = {}
var _overlay_material: ShaderMaterial = null
var _shader: Shader = null
var _upper_body_bone_groups: Array[Vector4] = []
var _last_debug_colors: bool = false
var _last_mode_enabled: bool = false
var _legacy_holders: Array[Node] = []

const HIDDEN_SCALE := Vector3(0.001, 0.001, 0.001)
const VISIBLE_SCALE := Vector3.ONE


func _ready() -> void:
	set_process(true)

	_player = get_parent().get_parent() as CharacterBody3D
	_skeleton = get_node_or_null(skeleton_path)
	if _skeleton == null:
		push_error("HeadToggle: Skeleton3D not found at: '%s'" % skeleton_path)
		return

	_shader = load(FP_BODY_SHADER_PATH)
	_collect_overlay_meshes(self)
	_cache_legacy_holders()

	_head_bone_idx = _skeleton.find_bone(head_bone_name)
	if _head_bone_idx == -1:
		push_error("HeadToggle: Bone '%s' not found. Bones: %s" % [head_bone_name, _get_all_bone_names()])
	else:
		_chest_bone_idx = _skeleton.find_bone(chest_bone_name)
		if _chest_bone_idx == -1:
			push_error("HeadToggle: Chest bone '%s' not found. Bones: %s" % [chest_bone_name, _get_all_bone_names()])

	_cache_upper_body_bones()

	_setup_overlay_material()

	_ready_called = true
	_apply_overlay_state()


func set_first_person(enabled: bool) -> void:
	first_person_mode = enabled


func enter_first_person() -> void:
	first_person_mode = true


func exit_first_person() -> void:
	first_person_mode = false


func toggle_first_person() -> void:
	first_person_mode = not first_person_mode


func _process(_delta: float) -> void:
	if not _ready_called:
		return

	_sync_from_config()
	_update_overlay_material()


func _sync_from_config() -> void:
	var config: Node = get_node_or_null("/root/ToolConfig")
	if not config:
		return

	if "full_body_first_person_enabled" in config:
		var enabled: bool = bool(config.full_body_first_person_enabled)
		if enabled != _first_person_mode:
			first_person_mode = enabled
	if "full_body_first_person_debug_colors" in config:
		debug_colors = bool(config.full_body_first_person_debug_colors)
	if "full_body_first_person_chest_bias" in config:
		chest_clip_bias = float(config.full_body_first_person_chest_bias)
	if "full_body_first_person_chest_feather" in config:
		chest_clip_feather = float(config.full_body_first_person_chest_feather)


func _apply_overlay_state() -> void:
	if _overlay_material:
		_overlay_material.set_shader_parameter("is_first_person", first_person_mode)
		_overlay_material.set_shader_parameter("debug_colors", debug_colors)

	for mesh in _overlay_meshes:
		if not is_instance_valid(mesh):
			continue

		var id: int = mesh.get_instance_id()
		if first_person_mode:
			if not _original_material_overrides.has(id):
				_original_material_overrides[id] = mesh.material_override
			mesh.material_override = _overlay_material
		else:
			if _original_material_overrides.has(id):
				mesh.material_override = _original_material_overrides[id]

	_set_legacy_holders_visible(not first_person_mode)
	_set_extra_nodes_visible(not first_person_mode or not hide_head_in_first_person)

	if hide_head_in_first_person and _skeleton and _head_bone_idx != -1:
		_apply_head_visibility(first_person_mode)


func _apply_head_visibility(hide_head: bool) -> void:
	if _skeleton == null or _head_bone_idx == -1:
		return

	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()

	if Engine.is_editor_hint() or transition_duration <= 0.0:
		_skeleton.set_bone_pose_scale(_head_bone_idx, HIDDEN_SCALE if hide_head else VISIBLE_SCALE)
		return

	var from_scale: Vector3 = _skeleton.get_bone_pose_scale(_head_bone_idx)
	var to_scale: Vector3 = HIDDEN_SCALE if hide_head else VISIBLE_SCALE
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


func _set_extra_nodes_visible(show: bool) -> void:
	for path in extra_head_nodes:
		var node: Node = get_node_or_null(path)
		if node:
			node.visible = show


func _set_legacy_holders_visible(show: bool) -> void:
	for node in _legacy_holders:
		if is_instance_valid(node):
			node.visible = show


func _cache_legacy_holders() -> void:
	if _player == null:
		return

	_legacy_holders.clear()
	for holder_path in [
		"Camera3D/HandHolder",
		"Camera3D/ShovelHolder",
		"Camera3D/PickaxeHolder",
		"Camera3D/AxeHolder",
		"Camera3D/PistolHolder"
	]:
		var node: Node = _player.get_node_or_null(holder_path)
		if node:
			_legacy_holders.append(node)


func _collect_overlay_meshes(root: Node) -> void:
	if root is MeshInstance3D and _should_use_overlay(root):
		_overlay_meshes.append(root)

	for child in root.get_children():
		_collect_overlay_meshes(child)


func _should_use_overlay(mesh: MeshInstance3D) -> bool:
	var name: String = mesh.name.to_lower()
	if name.contains("debug") or name.contains("sphere") or name.contains("marker") or name.contains("eye") or name.contains("hair") or name.contains("brow") or name.contains("lash") or name.contains("beard"):
		return false
	return true


func _setup_overlay_material() -> void:
	if not _shader:
		push_error("HeadToggle: Could not load first-person body shader at %s" % FP_BODY_SHADER_PATH)
		return

	_overlay_material = ShaderMaterial.new()
	_overlay_material.shader = _shader
	_overlay_material.set_shader_parameter("albedo_texture", load(FP_BODY_ALBEDO_PATH))
	_overlay_material.set_shader_parameter("normal_texture", load(FP_BODY_NORMAL_PATH))
	_overlay_material.set_shader_parameter("roughness_texture", load(FP_BODY_ROUGHNESS_PATH))
	_overlay_material.set_shader_parameter("albedo_color", Color.WHITE)
	_overlay_material.set_shader_parameter("roughness", 1.0)
	_overlay_material.set_shader_parameter("metallic", 0.0)
	_overlay_material.set_shader_parameter("normal_scale", 1.0)
	_apply_upper_body_uniforms()


func _update_overlay_material() -> void:
	if not _overlay_material:
		return

	if debug_colors != _last_debug_colors:
		_overlay_material.set_shader_parameter("debug_colors", debug_colors)
		_last_debug_colors = debug_colors

	if first_person_mode != _last_mode_enabled:
		_overlay_material.set_shader_parameter("is_first_person", first_person_mode)
		_last_mode_enabled = first_person_mode

	_apply_upper_body_uniforms()


func _cache_upper_body_bones() -> void:
	_upper_body_bone_groups.clear()
	if _skeleton == null:
		return

	var upper_indices: Array[int] = []
	for i in _skeleton.get_bone_count():
		var bone_name: String = _skeleton.get_bone_name(i).to_lower()
		if _is_upper_body_bone_name(bone_name):
			upper_indices.append(i)

	for idx in upper_indices:
		_add_upper_body_index(float(idx))
	while _upper_body_bone_groups.size() < 6:
		_upper_body_bone_groups.append(Vector4(-1.0, -1.0, -1.0, -1.0))


func _is_upper_body_bone_name(bone_name: String) -> bool:
	return bone_name.contains("chest") or bone_name.contains("upperchest") or bone_name.contains("neck") or bone_name.contains("head") or bone_name.contains("shoulder") or bone_name.contains("upperarm") or bone_name.contains("lowerarm") or bone_name.contains("hand") or bone_name.contains("thumb") or bone_name.contains("index") or bone_name.contains("middle") or bone_name.contains("ring") or bone_name.contains("little") or bone_name.contains("finger")


func _add_upper_body_index(bone_index: float) -> void:
	if _upper_body_bone_groups.is_empty() or int(_upper_body_bone_groups.back().w) != -1:
		_upper_body_bone_groups.append(Vector4(-1.0, -1.0, -1.0, -1.0))

	var last_idx: int = _upper_body_bone_groups.size() - 1
	var group: Vector4 = _upper_body_bone_groups[last_idx]
	if group.x == -1.0:
		group.x = bone_index
	elif group.y == -1.0:
		group.y = bone_index
	elif group.z == -1.0:
		group.z = bone_index
	else:
		group.w = bone_index
	_upper_body_bone_groups[last_idx] = group


func _apply_upper_body_uniforms() -> void:
	if not _overlay_material:
		return

	var body_scale: float = float(clamp(0.82 + chest_clip_bias, 0.65, 0.95))
	_overlay_material.set_shader_parameter("upper_body_z_clip_scale", body_scale)
	for i in range(6):
		var group: Vector4 = Vector4(-1.0, -1.0, -1.0, -1.0)
		if i < _upper_body_bone_groups.size():
			group = _upper_body_bone_groups[i]
		_overlay_material.set_shader_parameter("upper_body_bone_group_%d" % i, group)


func _get_all_bone_names() -> Array:
	if _skeleton == null:
		return []
	var names: Array[String] = []
	for i in _skeleton.get_bone_count():
		names.append(_skeleton.get_bone_name(i))
	return names
