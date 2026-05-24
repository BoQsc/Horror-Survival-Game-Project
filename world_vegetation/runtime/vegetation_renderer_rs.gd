extends Node
class_name VegetationRendererRS

var _scenario_rid: RID = RID()
var _chunk_mesh_rids: Dictionary = {}
var _chunk_instance_rids: Dictionary = {}
var _multimesh_rids: Dictionary = {}
var _multimesh_instance_rids: Dictionary = {}
var _multimesh_instance_counts: Dictionary = {}
var _multimesh_mesh_rids: Dictionary = {}
var _multimesh_metadata: Dictionary = {}
var _multimesh_visible: Dictionary = {}
var _individual_instance_rids: Dictionary = {}
var _last_free_count: int = 0


func _exit_tree() -> void:
	clear_all(true)


func bind_world_3d(world: World3D) -> void:
	if world == null:
		_scenario_rid = RID()
		return
	_scenario_rid = world.scenario
	_rebind_existing_instances()


func has_world_scenario() -> bool:
	return _scenario_rid.is_valid()


func create_chunk_mesh(chunk_key: String, arrays: Array, material: Material = null, custom_aabb: AABB = AABB()) -> RID:
	var surface_arrays: Array = [arrays]
	var surface_materials: Array = []
	if material != null:
		surface_materials.append(material)
	return create_chunk_mesh_surfaces(chunk_key, surface_arrays, surface_materials, custom_aabb)


func create_chunk_mesh_surfaces(chunk_key: String, surface_arrays: Array, surface_materials: Array = [], custom_aabb: AABB = AABB()) -> RID:
	destroy_chunk_mesh(chunk_key)
	var mesh_rid := RenderingServer.mesh_create()
	for surface_index in range(surface_arrays.size()):
		var arrays: Array = surface_arrays[surface_index]
		if arrays.is_empty():
			continue
		RenderingServer.mesh_add_surface_from_arrays(mesh_rid, RenderingServer.PRIMITIVE_TRIANGLES, arrays)
		if surface_index < surface_materials.size():
			var material_variant: Variant = surface_materials[surface_index]
			if material_variant is Material:
				RenderingServer.mesh_surface_set_material(mesh_rid, surface_index, (material_variant as Material).get_rid())
	if custom_aabb.size != Vector3.ZERO:
		RenderingServer.mesh_set_custom_aabb(mesh_rid, custom_aabb)
	_chunk_mesh_rids[chunk_key] = mesh_rid
	return mesh_rid


func update_chunk_mesh(chunk_key: String, arrays: Array, material: Material = null, custom_aabb: AABB = AABB()) -> RID:
	return create_chunk_mesh(chunk_key, arrays, material, custom_aabb)


func update_chunk_mesh_surfaces(chunk_key: String, surface_arrays: Array, surface_materials: Array = [], custom_aabb: AABB = AABB()) -> RID:
	return create_chunk_mesh_surfaces(chunk_key, surface_arrays, surface_materials, custom_aabb)


func destroy_chunk_mesh(chunk_key: String) -> void:
	if not _chunk_mesh_rids.has(chunk_key):
		return
	var mesh_rid: RID = _chunk_mesh_rids[chunk_key]
	_chunk_mesh_rids.erase(chunk_key)
	free_rid_safely(mesh_rid)


func create_instance(base_rid: RID, transform: Transform3D, scenario_rid: RID = RID(), key: String = "") -> RID:
	if not base_rid.is_valid():
		return RID()
	var target_scenario := scenario_rid
	if not target_scenario.is_valid():
		target_scenario = _scenario_rid
	var instance_rid := RenderingServer.instance_create2(base_rid, target_scenario)
	RenderingServer.instance_set_transform(instance_rid, transform)
	_individual_instance_rids[str(instance_rid.get_id())] = instance_rid
	return instance_rid


func set_instance_visible(instance_rid: RID, visible: bool) -> void:
	if instance_rid.is_valid():
		RenderingServer.instance_set_visible(instance_rid, visible)


func set_instance_transform(instance_rid: RID, transform: Transform3D) -> void:
	if instance_rid.is_valid():
		RenderingServer.instance_set_transform(instance_rid, transform)


func set_instance_base(instance_rid: RID, base_rid: RID) -> void:
	if instance_rid.is_valid() and base_rid.is_valid():
		RenderingServer.instance_set_base(instance_rid, base_rid)


func set_instance_material_override(instance_rid: RID, material: Material, surface_index: int = 0) -> void:
	if instance_rid.is_valid() and material != null:
		RenderingServer.instance_geometry_set_material_override(instance_rid, material.get_rid())


func destroy_instance(instance_rid: RID) -> void:
	if not instance_rid.is_valid():
		return
	_individual_instance_rids.erase(str(instance_rid.get_id()))
	free_rid_safely(instance_rid)


func destroy_chunk(chunk_key: String) -> void:
	var instance_rid: RID = _chunk_instance_rids.get(chunk_key, RID())
	if instance_rid.is_valid():
		_chunk_instance_rids.erase(chunk_key)
		free_rid_safely(instance_rid)
	destroy_chunk_mesh(chunk_key)


func create_or_update_multimesh_instance(
		key: String,
		mesh_rid: RID,
		buffer: PackedFloat32Array,
		instance_count: int,
		custom_aabb: AABB = AABB(),
		material: Material = null,
		metadata: Dictionary = {}
) -> RID:
	if not mesh_rid.is_valid() or instance_count <= 0 or buffer.is_empty():
		destroy_multimesh_instance(key)
		return RID()
	var multimesh_rid: RID = _multimesh_rids.get(key, RID())
	if not multimesh_rid.is_valid():
		multimesh_rid = RenderingServer.multimesh_create()
		_multimesh_rids[key] = multimesh_rid
	var previous_count := int(_multimesh_instance_counts.get(key, -1))
	var previous_mesh: RID = _multimesh_mesh_rids.get(key, RID())
	if previous_count != instance_count or previous_mesh != mesh_rid:
		RenderingServer.multimesh_allocate_data(
			multimesh_rid,
			instance_count,
			RenderingServer.MULTIMESH_TRANSFORM_3D,
			false,
			false
		)
		RenderingServer.multimesh_set_mesh(multimesh_rid, mesh_rid)
		_multimesh_instance_counts[key] = instance_count
		_multimesh_mesh_rids[key] = mesh_rid
	RenderingServer.multimesh_set_buffer(multimesh_rid, buffer)
	RenderingServer.multimesh_set_visible_instances(multimesh_rid, instance_count)
	if custom_aabb.size != Vector3.ZERO:
		RenderingServer.multimesh_set_custom_aabb(multimesh_rid, custom_aabb)
	var instance_rid: RID = _multimesh_instance_rids.get(key, RID())
	if not instance_rid.is_valid():
		instance_rid = RenderingServer.instance_create2(multimesh_rid, _scenario_rid)
		_multimesh_instance_rids[key] = instance_rid
	else:
		RenderingServer.instance_set_base(instance_rid, multimesh_rid)
		RenderingServer.instance_set_scenario(instance_rid, _scenario_rid)
	RenderingServer.instance_set_transform(instance_rid, Transform3D.IDENTITY)
	if material != null:
		RenderingServer.instance_geometry_set_material_override(instance_rid, material.get_rid())
	_multimesh_metadata[key] = metadata.duplicate(true)
	_multimesh_visible[key] = true
	return instance_rid


func destroy_multimesh_instance(key: String) -> void:
	var instance_rid: RID = _multimesh_instance_rids.get(key, RID())
	if instance_rid.is_valid():
		free_rid_safely(instance_rid)
	_multimesh_instance_rids.erase(key)
	_multimesh_visible.erase(key)
	var multimesh_rid: RID = _multimesh_rids.get(key, RID())
	if multimesh_rid.is_valid():
		free_rid_safely(multimesh_rid)
	_multimesh_rids.erase(key)
	_multimesh_instance_counts.erase(key)
	_multimesh_mesh_rids.erase(key)
	_multimesh_metadata.erase(key)


func set_multimesh_visible(key: String, visible: bool) -> void:
	var instance_rid: RID = _multimesh_instance_rids.get(key, RID())
	if instance_rid.is_valid():
		_multimesh_visible[key] = visible
		RenderingServer.instance_set_visible(instance_rid, visible)


func create_chunk_instance(chunk_key: String, mesh_rid: RID, transform: Transform3D = Transform3D.IDENTITY) -> RID:
	if not mesh_rid.is_valid():
		return RID()
	destroy_chunk_instance(chunk_key)
	var instance_rid := RenderingServer.instance_create2(mesh_rid, _scenario_rid)
	RenderingServer.instance_set_transform(instance_rid, transform)
	_chunk_instance_rids[chunk_key] = instance_rid
	return instance_rid


func destroy_chunk_instance(chunk_key: String) -> void:
	if not _chunk_instance_rids.has(chunk_key):
		return
	var instance_rid: RID = _chunk_instance_rids[chunk_key]
	_chunk_instance_rids.erase(chunk_key)
	free_rid_safely(instance_rid)


func set_chunk_visible(chunk_key: String, visible: bool) -> void:
	var instance_rid: RID = _chunk_instance_rids.get(chunk_key, RID())
	if instance_rid.is_valid():
		RenderingServer.instance_set_visible(instance_rid, visible)


func rebind_instance(chunk_key: String, transform: Transform3D) -> void:
	var instance_rid: RID = _chunk_instance_rids.get(chunk_key, RID())
	if instance_rid.is_valid():
		RenderingServer.instance_set_transform(instance_rid, transform)


func clear_all(immediate_free: bool = false) -> void:
	var chunk_mesh_values := _chunk_mesh_rids.values()
	var chunk_instance_values := _chunk_instance_rids.values()
	var multimesh_values := _multimesh_rids.values()
	var multimesh_instance_values := _multimesh_instance_rids.values()
	var individual_values := _individual_instance_rids.values()
	for rid_variant in chunk_instance_values:
		var rid: RID = rid_variant
		free_rid_safely(rid, immediate_free)
	for rid_variant in multimesh_instance_values:
		var rid: RID = rid_variant
		free_rid_safely(rid, immediate_free)
	for rid_variant in individual_values:
		var rid: RID = rid_variant
		free_rid_safely(rid, immediate_free)
	for rid_variant in chunk_mesh_values:
		var rid: RID = rid_variant
		free_rid_safely(rid, immediate_free)
	for rid_variant in multimesh_values:
		var rid: RID = rid_variant
		free_rid_safely(rid, immediate_free)
	_chunk_mesh_rids.clear()
	_chunk_instance_rids.clear()
	_multimesh_rids.clear()
	_multimesh_instance_rids.clear()
	_multimesh_instance_counts.clear()
	_multimesh_mesh_rids.clear()
	_multimesh_metadata.clear()
	_multimesh_visible.clear()
	_individual_instance_rids.clear()


func free_rid_safely(rid: RID, _immediate_free: bool = false) -> void:
	if not rid.is_valid():
		return
	RenderingServer.free_rid(rid)
	_last_free_count += 1


func get_stats() -> Dictionary:
	var chunk_mesh_count := 0
	for rid_variant in _chunk_mesh_rids.values():
		var rid: RID = rid_variant
		if rid.is_valid():
			chunk_mesh_count += 1
	var chunk_instance_count := 0
	for rid_variant in _chunk_instance_rids.values():
		var rid: RID = rid_variant
		if rid.is_valid():
			chunk_instance_count += 1
	var individual_instance_count := 0
	for rid_variant in _individual_instance_rids.values():
		var rid: RID = rid_variant
		if rid.is_valid():
			individual_instance_count += 1
	var multimesh_count := 0
	var multimesh_total_instance_count := 0
	var visible_multimesh_count := 0
	var visible_multimesh_total_instance_count := 0
	var multimesh_batch_counts_by_kind: Dictionary = {}
	var multimesh_instance_counts_by_kind: Dictionary = {}
	var visible_multimesh_batch_counts_by_kind: Dictionary = {}
	var visible_multimesh_instance_counts_by_kind: Dictionary = {}
	for rid_variant in _multimesh_rids.values():
		var rid: RID = rid_variant
		if rid.is_valid():
			multimesh_count += 1
	for key_variant in _multimesh_rids.keys():
		var key := str(key_variant)
		var rid: RID = _multimesh_rids.get(key, RID())
		if not rid.is_valid():
			continue
		var metadata: Dictionary = _multimesh_metadata.get(key, {})
		var kind := str(metadata.get("kind", "unknown"))
		var instance_count := int(_multimesh_instance_counts.get(key, 0))
		var visible := bool(_multimesh_visible.get(key, true))
		multimesh_total_instance_count += instance_count
		_increment_stat_dict(multimesh_batch_counts_by_kind, kind, 1)
		_increment_stat_dict(multimesh_instance_counts_by_kind, kind, instance_count)
		if visible:
			visible_multimesh_count += 1
			visible_multimesh_total_instance_count += instance_count
			_increment_stat_dict(visible_multimesh_batch_counts_by_kind, kind, 1)
			_increment_stat_dict(visible_multimesh_instance_counts_by_kind, kind, instance_count)
	var multimesh_instance_count := 0
	for rid_variant in _multimesh_instance_rids.values():
		var rid: RID = rid_variant
		if rid.is_valid():
			multimesh_instance_count += 1
	return {
		"chunk_mesh_count": chunk_mesh_count,
		"chunk_instance_count": chunk_instance_count,
		"multimesh_count": multimesh_count,
		"multimesh_instance_count": multimesh_instance_count,
		"multimesh_total_instance_count": multimesh_total_instance_count,
		"visible_multimesh_count": visible_multimesh_count,
		"visible_multimesh_total_instance_count": visible_multimesh_total_instance_count,
		"multimesh_batch_counts_by_kind": multimesh_batch_counts_by_kind,
		"multimesh_instance_counts_by_kind": multimesh_instance_counts_by_kind,
		"visible_multimesh_batch_counts_by_kind": visible_multimesh_batch_counts_by_kind,
		"visible_multimesh_instance_counts_by_kind": visible_multimesh_instance_counts_by_kind,
		"individual_instance_count": individual_instance_count,
		"render_rid_count": chunk_mesh_count + chunk_instance_count + multimesh_count + multimesh_instance_count + individual_instance_count,
		"free_count": _last_free_count,
		"scenario_bound": _scenario_rid.is_valid()
	}


func _increment_stat_dict(counts: Dictionary, key: String, amount: int) -> void:
	counts[key] = int(counts.get(key, 0)) + amount


func _rebind_existing_instances() -> void:
	for chunk_key_variant in _chunk_instance_rids.keys():
		var chunk_key := str(chunk_key_variant)
		var instance_rid: RID = _chunk_instance_rids.get(chunk_key, RID())
		if instance_rid.is_valid():
			RenderingServer.instance_set_scenario(instance_rid, _scenario_rid)
	for key_variant in _multimesh_instance_rids.keys():
		var instance_rid: RID = _multimesh_instance_rids.get(key_variant, RID())
		if instance_rid.is_valid():
			RenderingServer.instance_set_scenario(instance_rid, _scenario_rid)
	for instance_key_variant in _individual_instance_rids.keys():
		var instance_rid: RID = _individual_instance_rids.get(instance_key_variant, RID())
		if instance_rid.is_valid():
			RenderingServer.instance_set_scenario(instance_rid, _scenario_rid)
