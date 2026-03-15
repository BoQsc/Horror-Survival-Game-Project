@tool
extends Node3D

# ─────────────────────────────────────────────
# HEAD VISIBILITY TOGGLE — First Person / Third Person
# Uses near-zero bone scale instead of exactly zero
# so BoneAttachment3D (camera holder) stays valid.
# ─────────────────────────────────────────────

@export var skeleton_path: NodePath = "WorldPlayerFullBody/Superhero_Male_FullBody/Armature/GeneralSkeleton"
@export var head_bone_name: String = "Head"
@export var spine_bone_name: String = "Hips" # Root of torso for stable upward masking
@export var neck_cutoff_y: float = 1.55
var _torso_y: float = 0.8
@export var transition_duration: float = 0.15

## Extra nodes to hide in first person (drag Eyebrows, Eyes here)
@export var extra_head_nodes: Array[NodePath] = []

@export var viewmodel_shader: Shader = preload("res://models/entities/player/Universal Base Characters[Standard]/Base Characters/Godot - UE/fp_body.gdshader")

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
var _spine_bone_idx: int = -1
var _cached_meshes: Array[MeshInstance3D] = []
var _cached_materials: Array[ShaderMaterial] = []
var _min_leg_idx: int = -1
var _max_leg_idx: int = -1
var _neck_bone_idx: int = -1
var _instance_id: String = "INIT"
var _last_glob_enabled: bool = true


const HIDDEN_SCALE := Vector3(0.001, 0.001, 0.001)
const VISIBLE_SCALE := Vector3.ONE


func _ready() -> void:
	_instance_id = str(randi() % 9999)
	if Engine.is_editor_hint(): _instance_id = "ED-" + _instance_id
	
	if skeleton_path.is_empty():
		push_error("HeadToggle: skeleton_path is empty.")
		return
	
	_skeleton = get_node(skeleton_path)
	if _skeleton == null:
		return

	# Force-cleanup old junk values from previous versions
	if spine_bone_name == "Spine1" or spine_bone_name == "Neck":
		spine_bone_name = "Hips"

	_head_bone_idx = _skeleton.find_bone(head_bone_name)
	_spine_bone_idx = _skeleton.find_bone(spine_bone_name)
	
	if _head_bone_idx == -1:
		push_error("HeadToggle: Bone '%s' not found." % head_bone_name)
	
	if _spine_bone_idx == -1:
		# Try fallback "Spine"
		_spine_bone_idx = _skeleton.find_bone("Spine")
		if _spine_bone_idx == -1:
			push_error("FP_BODY: Spine/Chest bone not found.")
	else:
		# Find all leg bones and their range
		_min_leg_idx = 999
		_max_leg_idx = -1
		for i in _skeleton.get_bone_count():
			var b_name = _skeleton.get_bone_name(i).to_lower()
			if "leg" in b_name or "foot" in b_name or "toe" in b_name:
				if not "upperarm" in b_name: # Avoid accidental arms
					_min_leg_idx = min(_min_leg_idx, i)
					_max_leg_idx = max(_max_leg_idx, i)
					
		_neck_bone_idx = _skeleton.find_bone("Neck")
		if _neck_bone_idx == -1:
			_neck_bone_idx = _skeleton.find_bone("Neck1")

	# Always start clean
	_skeleton.set_bone_pose_scale(_head_bone_idx, VISIBLE_SCALE)

	_ready_called = true
	_apply_instant(first_person_mode)


var _log_timer: float = 0.0
func _process(_delta: float) -> void:
	if not _ready_called:
		return
		
	if has_node("/root/ToolConfig"):
		var global_enabled = get_node("/root/ToolConfig").fp_viewmodel_enabled
		if global_enabled != _last_glob_enabled:
			_last_glob_enabled = global_enabled
			if first_person_mode:
				_update_shader_params(true)
	
	if not first_person_mode:
		return
	
	if _spine_bone_idx != -1 and _skeleton:
		# Use global pose origin for height relative to model root (feet)
		var pose = _skeleton.get_bone_global_pose(_spine_bone_idx)
		_torso_y = pose.origin.y
		_update_torso_y_only(_torso_y)


func _update_torso_y_only(y: float) -> void:
	for mat in _cached_materials:
		if is_instance_valid(mat):
			mat.set_shader_parameter("torso_y", y)


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
	_update_shader_params(hide_head)


func _tween_head(hide_head: bool) -> void:
	if _skeleton == null or _head_bone_idx == -1:
		return

	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()

	var from_scale: Vector3 = _skeleton.get_bone_pose_scale(_head_bone_idx)
	var to_scale: Vector3 = HIDDEN_SCALE if hide_head else VISIBLE_SCALE
	
	_active_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_active_tween.tween_method(
		func(v: Vector3): _skeleton.set_bone_pose_scale(_head_bone_idx, v),
		from_scale,
		to_scale,
		transition_duration
	)
	_active_tween.finished.connect(func(): if not hide_head: _set_extra_nodes_visible(true))
	
	if hide_head:
		_set_extra_nodes_visible(false)
	
	_update_shader_params(hide_head)


func _set_extra_nodes_visible(show: bool) -> void:
	for path in extra_head_nodes:
		var node := get_node_or_null(path)
		if node:
			node.visible = show


func _update_shader_params(is_fp: bool) -> void:
	var meshes = find_children("*", "MeshInstance3D", true, false)
	_cached_meshes.clear()
	_cached_materials.clear()
	
	var count = 0
	for mesh in meshes:
		_cached_meshes.append(mesh)
		
		# CULLING FIX: Prevent disappearing when vertices are pulled forward/up
		mesh.extra_cull_margin = 10.0
		
		var has_shader_mat = false
		var surface_count = mesh.get_surface_override_material_count()
		var mesh_count = 0
		if mesh.mesh: mesh_count = mesh.mesh.get_surface_count()
		var total_slots = max(surface_count, mesh_count)
		
		for i in total_slots:
			var mat = mesh.get_active_material(i)
			if not mat is ShaderMaterial:
				var new_mat = ShaderMaterial.new()
				new_mat.shader = viewmodel_shader
				
				# MATERIAL POLISH: Copy all common PBR properties from original material
				if mat:
					if "albedo_color" in mat: 
						new_mat.set_shader_parameter("albedo_color", mat.albedo_color)
					if "albedo_texture" in mat: 
						new_mat.set_shader_parameter("albedo_texture", mat.albedo_texture)
					if "roughness" in mat:
						new_mat.set_shader_parameter("roughness", mat.roughness)
					if "roughness_texture" in mat:
						new_mat.set_shader_parameter("roughness_texture", mat.roughness_texture)
					if "metallic" in mat:
						new_mat.set_shader_parameter("metallic", mat.metallic)
					if "metallic_texture" in mat:
						new_mat.set_shader_parameter("metallic_texture", mat.metallic_texture)
					if "normal_enabled" in mat and mat.normal_enabled:
						if "normal_texture" in mat:
							new_mat.set_shader_parameter("normal_texture", mat.normal_texture)
						if "normal_scale" in mat:
							new_mat.set_shader_parameter("normal_scale", mat.normal_scale)
					if "emission_enabled" in mat and mat.emission_enabled:
						if "emission_texture" in mat:
							new_mat.set_shader_parameter("emission_texture", mat.emission_texture)
						if "emission" in mat:
							new_mat.set_shader_parameter("emission_color", mat.emission)
						if "emission_energy_multiplier" in mat:
							new_mat.set_shader_parameter("emission_energy", mat.emission_energy_multiplier)
							
				mesh.set_surface_override_material(i, new_mat)
				mat = new_mat
			
			if mat is ShaderMaterial:
				# Force material unique per Instance ID to avoid "Zombie Rig" fighting
				var expected_name = "LOCAL_" + _instance_id
				if mat.resource_name != expected_name:
					mat = mat.duplicate()
					mat.resource_name = expected_name
					mesh.set_surface_override_material(i, mat)
				
				has_shader_mat = true
				
				# HEAD HIDING: Persistent in First Person
				mat.set_shader_parameter("fp_hide_head", is_fp)
				
				# VIEWMODEL OVERLAY: Configurable toggle
				var overlay_on = is_fp
				if has_node("/root/ToolConfig"):
					overlay_on = is_fp and get_node("/root/ToolConfig").fp_viewmodel_enabled
				mat.set_shader_parameter("fp_overlay_active", overlay_on)
				
				mat.set_shader_parameter("neck_cutoff_y", neck_cutoff_y)
				mat.set_shader_parameter("torso_y", _torso_y)
				
				# HEAD/NECK MASKING
				mat.set_shader_parameter("head_bone_idx", float(_head_bone_idx))
				mat.set_shader_parameter("neck_bone_idx", float(_neck_bone_idx))
				
				# Pass leg bone range for exclusion mask
				mat.set_shader_parameter("min_leg_idx", float(_min_leg_idx))
				mat.set_shader_parameter("max_leg_idx", float(_max_leg_idx))
				
				_cached_materials.append(mat)
		
		if has_shader_mat:
			count += 1
	
	# Optional: add a quiet print for non-editor only
	if not Engine.is_editor_hint():
		print_rich("[color=cyan]FPS Overlay:[/color] Updated %d meshes." % count)


func _get_all_bone_names() -> Array:
	if _skeleton == null:
		return []
	var names := []
	for i in _skeleton.get_bone_count():
		names.append(_skeleton.get_bone_name(i))
	return names
