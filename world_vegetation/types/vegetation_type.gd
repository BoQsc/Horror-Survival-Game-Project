extends Resource
class_name VegetationType

enum Category {
	GRASS,
	BUSH,
	TREE,
	STUMP,
	LOG,
	FLOWER,
	WEED,
	ROCK
}

enum RenderMode {
	CHUNK_MESH,
	INDIVIDUAL_INSTANCE
}

enum HarvestMode {
	NONE,
	HAND,
	AXE,
	TOOL
}

enum SupportRule {
	NONE,
	GROUND,
	ROOT_POINTS
}

enum CollisionProxyType {
	NONE,
	CAPSULE,
	AREA,
	BOX
}

static var _source_cache: Dictionary = {}

@export var id: StringName = &""
@export var display_name: String = ""
@export var category: int = Category.GRASS
@export var source_path: String = ""
@export var source_mesh: Mesh
@export var material: Material
@export var mesh_source_transform: Transform3D = Transform3D.IDENTITY
@export var render_mode: int = RenderMode.CHUNK_MESH
@export var harvest_mode: int = HarvestMode.NONE
@export var required_tool: StringName = &""
@export var health: float = 1.0
@export var drops: Array[Dictionary] = []
@export var regrow_seconds: float = 0.0
@export var support_rule: int = SupportRule.GROUND
@export var collision_proxy_type: int = CollisionProxyType.NONE
@export var is_targetable: bool = false
@export var is_choppable: bool = false
@export var is_harvestable: bool = false
@export var alpha_scissor_threshold: float = 0.5
@export var instance_scale: float = 1.0
@export var support_radius: float = 0.75
@export var support_height: float = 1.0
@export var support_points: Array[Vector3] = [Vector3.ZERO]


func is_chunk_mesh() -> bool:
	return render_mode == RenderMode.CHUNK_MESH


func is_individual_instance() -> bool:
	return render_mode == RenderMode.INDIVIDUAL_INSTANCE


func _extract_first_mesh(node: Node, parent_transform: Transform3D = Transform3D.IDENTITY) -> Dictionary:
	var current_transform := parent_transform
	if node is Node3D:
		current_transform = parent_transform * (node as Node3D).transform

	if node is MeshInstance3D:
		return {
			"mesh": (node as MeshInstance3D).mesh,
			"transform": current_transform
		}

	for child in node.get_children():
		var result: Dictionary = _extract_first_mesh(child, current_transform)
		if result.get("mesh", null) != null:
			return result

	return {
		"mesh": null,
		"transform": Transform3D.IDENTITY
	}


func get_source_geometry() -> Dictionary:
	if source_mesh:
		return {
			"mesh": source_mesh,
			"transform": mesh_source_transform
		}

	if source_path.strip_edges().is_empty():
		return {
			"mesh": null,
			"transform": mesh_source_transform
		}

	var cache_key := "%s|%s" % [source_path, str(mesh_source_transform)]
	if _source_cache.has(cache_key):
		return (_source_cache[cache_key] as Dictionary).duplicate(true)

	var loaded := load(source_path)
	if loaded == null:
		var fallback := {
			"mesh": null,
			"transform": mesh_source_transform
		}
		_source_cache[source_path] = fallback
		return fallback.duplicate(true)

	var result: Dictionary = {
		"mesh": null,
		"transform": mesh_source_transform
	}

	if loaded is Mesh:
		result.mesh = loaded
		result.transform = mesh_source_transform
	elif loaded is PackedScene:
		var instance := (loaded as PackedScene).instantiate()
		if instance:
			var extracted := _extract_first_mesh(instance, Transform3D.IDENTITY)
			result.mesh = extracted.get("mesh", null)
			if mesh_source_transform != Transform3D.IDENTITY:
				result.transform = mesh_source_transform
			else:
				result.transform = extracted.get("transform", Transform3D.IDENTITY)
			instance.free()
	elif loaded is ArrayMesh:
		result.mesh = loaded
		result.transform = mesh_source_transform

	_source_cache[cache_key] = result
	return result.duplicate(true)


func get_source_mesh() -> Mesh:
	return get_source_geometry().get("mesh", null)


func get_source_transform() -> Transform3D:
	return get_source_geometry().get("transform", mesh_source_transform)


func get_material_for_surface(surface_index: int = 0) -> Material:
	if material != null:
		return material
	var mesh := get_source_mesh()
	if mesh == null or mesh.get_surface_count() <= surface_index:
		return null
	return mesh.surface_get_material(surface_index)


func get_drop_summary() -> Array[String]:
	var summary: Array[String] = []
	for drop_variant in drops:
		if not (drop_variant is Dictionary):
			continue
		var drop: Dictionary = drop_variant
		var item_id := str(drop.get("id", ""))
		var amount := int(drop.get("amount", 1))
		if item_id.is_empty():
			continue
		summary.append("%s x%d" % [item_id, amount])
	return summary
