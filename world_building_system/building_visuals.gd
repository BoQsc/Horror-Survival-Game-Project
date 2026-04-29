extends RefCounted
class_name BuildingVisuals

## Shared rendering helpers for building blocks.
## Keep the gameplay chunks and editor addons on the same material path.

const WOOD_BLOCK_TEXTURE: Texture2D = preload("res://world_greedy_meshing/wood-block-texture.png")
const CHURCH_FLOOR_TEXTURE: Texture2D = preload("res://models/objects/church_floor/church_floor_texture.png")
const WOOD_BLOCK_ATLAS_SHADER: Shader = preload("res://world_building_system/wood_block_atlas.gdshader")

static var _shared_wood_block_material: StandardMaterial3D = null
static var _shared_building_material: Material = null
static var _prepared_mesh_surface_materials: Dictionary = {}

static func use_legacy_building_shader_override_for_test() -> bool:
	return OS.get_environment("TOWN_STALL_FORCE_LEGACY_BUILDING_ATLAS_MATERIAL") == "1"

static func get_shared_wood_block_material() -> StandardMaterial3D:
	if _shared_wood_block_material:
		return _shared_wood_block_material

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 1.0, 1.0)
	material.albedo_texture = WOOD_BLOCK_TEXTURE
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_shared_wood_block_material = material
	return _shared_wood_block_material

static func get_shared_church_floor_material() -> Material:
	return get_shared_building_material()

static func _set_surface_override_material_if_needed(mesh_instance: MeshInstance3D, surface_index: int, material: Material) -> void:
	if mesh_instance.get_surface_override_material(surface_index) != material:
		mesh_instance.set_surface_override_material(surface_index, material)

static func apply_shared_surface_materials(mesh: ArrayMesh, voxel_bytes: PackedByteArray, has_church_floor: bool = false) -> void:
	if not mesh:
		return
	if use_legacy_building_shader_override_for_test():
		return

	var mesh_id := mesh.get_instance_id()
	if _prepared_mesh_surface_materials.has(mesh_id):
		return

	var surface_count := mesh.get_surface_count()
	if surface_count <= 0:
		return

	if surface_count == 1:
		if not has_church_floor:
			for block_id in voxel_bytes:
				if block_id == 8:
					has_church_floor = true
					break
		# The shader uses vertex color to separate wood and church-floor faces.
		var single_surface_material := get_shared_church_floor_material() if has_church_floor else get_shared_wood_block_material()
		mesh.surface_set_material(0, single_surface_material)
	else:
		mesh.surface_set_material(0, get_shared_wood_block_material())
		mesh.surface_set_material(1, get_shared_church_floor_material())
		for surface_index in range(2, surface_count):
			mesh.surface_set_material(surface_index, get_shared_wood_block_material())

	_prepared_mesh_surface_materials[mesh_id] = true

static func apply_runtime_surface_materials(mesh_instance: MeshInstance3D, voxel_bytes: PackedByteArray, has_church_floor: bool = false) -> void:
	if not mesh_instance:
		return

	var mesh := mesh_instance.mesh
	if not mesh:
		mesh_instance.material_override = null
		return

	if use_legacy_building_shader_override_for_test():
		mesh_instance.material_override = get_shared_building_material()
		return

	if mesh_instance.material_override != null:
		mesh_instance.material_override = null
	var surface_count := mesh.get_surface_count()
	if surface_count <= 0:
		return

	if surface_count == 1:
		if not has_church_floor:
			for block_id in voxel_bytes:
				if block_id == 8:
					has_church_floor = true
					break
		# The shader uses vertex color to separate wood and church-floor faces.
		var single_surface_material := get_shared_church_floor_material() if has_church_floor else get_shared_wood_block_material()
		_set_surface_override_material_if_needed(mesh_instance, 0, single_surface_material)
		return

	_set_surface_override_material_if_needed(mesh_instance, 0, get_shared_wood_block_material())
	_set_surface_override_material_if_needed(mesh_instance, 1, get_shared_church_floor_material())
	for surface_index in range(2, surface_count):
		_set_surface_override_material_if_needed(mesh_instance, surface_index, get_shared_wood_block_material())

static func get_shared_building_material() -> Material:
	if _shared_building_material:
		return _shared_building_material

	var material := ShaderMaterial.new()
	material.shader = WOOD_BLOCK_ATLAS_SHADER
	material.set_shader_parameter("atlas_texture", WOOD_BLOCK_TEXTURE)
	material.set_shader_parameter("church_floor_texture", CHURCH_FLOOR_TEXTURE)
	_shared_building_material = material
	return _shared_building_material
