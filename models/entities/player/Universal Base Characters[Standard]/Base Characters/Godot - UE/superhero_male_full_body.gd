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
var _active_tween: Tween = null
var _ready_called: bool = false
var _player: CharacterBody3D = null
var _overlay_meshes: Array[MeshInstance3D] = []
var _original_material_overrides: Dictionary = {}
var _original_meshes: Dictionary = {}
var _masked_meshes: Dictionary = {}
var _overlay_material: ShaderMaterial = null
var _shader: Shader = null
var _last_debug_colors: bool = false
var _last_mode_enabled: bool = false
var _legacy_holders: Array[Node] = []
var _upper_joint_index_set: Dictionary = {}

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
	_build_upper_body_bone_index_set()
	_prepare_masked_overlay_meshes()
	_head_bone_idx = _skeleton.find_bone(head_bone_name)
	if _head_bone_idx == -1:
		push_error("HeadToggle: Bone '%s' not found. Bones: %s" % [head_bone_name, _get_all_bone_names()])
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
			if _masked_meshes.has(id):
				mesh.mesh = _masked_meshes[id]
				print("HeadToggle: applied masked mesh to %s" % mesh.name)
			if not _original_material_overrides.has(id):
				_original_material_overrides[id] = mesh.material_override
			mesh.material_override = _overlay_material
		else:
			if _original_meshes.has(id):
				mesh.mesh = _original_meshes[id]
				print("HeadToggle: restored original mesh on %s" % mesh.name)
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
	_overlay_material.set_shader_parameter("upper_body_mask_threshold", chest_clip_feather)
	_overlay_material.set_shader_parameter("upper_body_z_clip_scale", maxf(0.72, 0.82 + chest_clip_bias))


func _update_overlay_material() -> void:
	if not _overlay_material:
		return

	if debug_colors != _last_debug_colors:
		_overlay_material.set_shader_parameter("debug_colors", debug_colors)
		_last_debug_colors = debug_colors

	if first_person_mode != _last_mode_enabled:
		_overlay_material.set_shader_parameter("is_first_person", first_person_mode)
		_last_mode_enabled = first_person_mode

	_overlay_material.set_shader_parameter("upper_body_mask_threshold", chest_clip_feather)
	_overlay_material.set_shader_parameter("upper_body_z_clip_scale", maxf(0.72, 0.82 + chest_clip_bias))


func _get_all_bone_names() -> Array:
	if _skeleton == null:
		return []
	var names: Array[String] = []
	for i in _skeleton.get_bone_count():
		names.append(_skeleton.get_bone_name(i))
	return names


func _build_upper_body_bone_index_set() -> void:
	_upper_joint_index_set.clear()

	var joint_order: Array[String] = [
		"root",
		"pelvis",
		"spine_01",
		"spine_02",
		"spine_03",
		"neck_01",
		"Head",
		"clavicle_l",
		"upperarm_l",
		"lowerarm_l",
		"hand_l",
		"index_01_l",
		"index_02_l",
		"index_03_l",
		"index_04_leaf_l",
		"middle_01_l",
		"middle_02_l",
		"middle_03_l",
		"middle_04_leaf_l",
		"pinky_01_l",
		"pinky_02_l",
		"pinky_03_l",
		"pinky_04_leaf_l",
		"ring_01_l",
		"ring_02_l",
		"ring_03_l",
		"ring_04_leaf_l",
		"thumb_01_l",
		"thumb_02_l",
		"thumb_03_l",
		"thumb_04_leaf_l",
		"clavicle_r",
		"upperarm_r",
		"lowerarm_r",
		"hand_r",
		"index_01_r",
		"index_02_r",
		"index_03_r",
		"index_04_leaf_r",
		"middle_01_r",
		"middle_02_r",
		"middle_03_r",
		"middle_04_leaf_r",
		"pinky_01_r",
		"pinky_02_r",
		"pinky_03_r",
		"pinky_04_leaf_r",
		"ring_01_r",
		"ring_02_r",
		"ring_03_r",
		"ring_04_leaf_r",
		"thumb_01_r",
		"thumb_02_r",
		"thumb_03_r",
		"thumb_04_leaf_r",
	]

	var upper_body_bone_names: Array[String] = [
		chest_bone_name,
		"UpperChest",
		"spine_03",
		"spine_02",
		"spine_01",
		"neck_01",
		"Head",
		"clavicle_l",
		"upperarm_l",
		"lowerarm_l",
		"hand_l",
		"thumb_01_l",
		"thumb_02_l",
		"thumb_03_l",
		"index_01_l",
		"index_02_l",
		"index_03_l",
		"middle_01_l",
		"middle_02_l",
		"middle_03_l",
		"ring_01_l",
		"ring_02_l",
		"ring_03_l",
		"pinky_01_l",
		"pinky_02_l",
		"pinky_03_l",
		"clavicle_r",
		"upperarm_r",
		"lowerarm_r",
		"hand_r",
		"thumb_01_r",
		"thumb_02_r",
		"thumb_03_r",
		"index_01_r",
		"index_02_r",
		"index_03_r",
		"middle_01_r",
		"middle_02_r",
		"middle_03_r",
		"ring_01_r",
		"ring_02_r",
		"ring_03_r",
		"pinky_01_r",
		"pinky_02_r",
		"pinky_03_r",
	]

	for bone_name in upper_body_bone_names:
		var joint_idx: int = joint_order.find(bone_name)
		if joint_idx != -1:
			_upper_joint_index_set[joint_idx] = true


func _prepare_masked_overlay_meshes() -> void:
	_original_meshes.clear()
	_masked_meshes.clear()

	for mesh in _overlay_meshes:
		if not is_instance_valid(mesh) or mesh.mesh == null:
			continue
		if not (mesh.mesh is ArrayMesh):
			continue

		var source_mesh: ArrayMesh = mesh.mesh
		var masked_mesh: ArrayMesh = _create_masked_mesh(source_mesh)
		if masked_mesh:
			var id: int = mesh.get_instance_id()
			_original_meshes[id] = source_mesh
			_masked_meshes[id] = masked_mesh


func _create_masked_mesh(source_mesh: ArrayMesh) -> ArrayMesh:
	if source_mesh == null:
		return null

	var masked_mesh := ArrayMesh.new()

	for surface_idx in range(source_mesh.get_surface_count()):
		var arrays: Array = source_mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue

		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if vertices.is_empty() or bones.is_empty() or weights.is_empty():
			continue

		var colors := PackedColorArray()
		colors.resize(vertices.size())
		var min_mask: float = 1.0
		var max_mask: float = 0.0
		var upper_count: int = 0

		for i in range(vertices.size()):
			var mask := _compute_upper_body_mask(bones, weights, i)
			min_mask = minf(min_mask, mask)
			max_mask = maxf(max_mask, mask)
			if mask >= chest_clip_feather:
				upper_count += 1
			colors[i] = Color(mask, mask, mask, 1.0)

		arrays[Mesh.ARRAY_COLOR] = colors
		masked_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var original_material: Material = source_mesh.surface_get_material(surface_idx)
		if original_material:
			masked_mesh.surface_set_material(masked_mesh.get_surface_count() - 1, original_material)
		print("HeadToggle: masked surface %d verts=%d upper=%d min=%.3f max=%.3f" % [surface_idx, vertices.size(), upper_count, min_mask, max_mask])

	return masked_mesh


func _compute_upper_body_mask(bones: PackedInt32Array, weights: PackedFloat32Array, vertex_index: int) -> float:
	var base_idx: int = vertex_index * 4
	var mask: float = 0.0

	for j in range(4):
		var bone_idx: int = bones[base_idx + j]
		if _upper_joint_index_set.has(bone_idx):
			mask += weights[base_idx + j]

	return clamp(mask, 0.0, 1.0)
