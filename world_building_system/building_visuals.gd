extends RefCounted
class_name BuildingVisuals

## Shared rendering helpers for building blocks.
## Keep the gameplay chunks and editor addons on the same material path.

const WOOD_BLOCK_TEXTURE: Texture2D = preload("res://world_greedy_meshing/wood-block-texture.png")
const CHURCH_FLOOR_TEXTURE: Texture2D = preload("res://models/objects/church_floor/church_floor_texture.png")
const WOOD_BLOCK_ATLAS_SHADER: Shader = preload("res://world_building_system/wood_block_atlas.gdshader")

static var _shared_wood_block_material: StandardMaterial3D = null
static var _shared_church_floor_material: StandardMaterial3D = null
static var _shared_building_material: Material = null

static func use_legacy_building_shader_override_for_test() -> bool:
	return OS.get_environment("TOWN_STALL_FORCE_LEGACY_BUILDING_ATLAS_MATERIAL") == "1"

static func get_shared_wood_block_material() -> StandardMaterial3D:
	if _shared_wood_block_material:
		return _shared_wood_block_material

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 1.0, 1.0)
	material.albedo_texture = WOOD_BLOCK_TEXTURE
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_shared_wood_block_material = material
	return _shared_wood_block_material

static func get_shared_church_floor_material() -> StandardMaterial3D:
	if _shared_church_floor_material:
		return _shared_church_floor_material

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 1.0, 1.0)
	material.albedo_texture = CHURCH_FLOOR_TEXTURE
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_shared_church_floor_material = material
	return _shared_church_floor_material

static func apply_runtime_surface_materials(mesh_instance: MeshInstance3D, voxel_bytes: PackedByteArray) -> void:
	if not mesh_instance:
		return

	var mesh := mesh_instance.mesh
	if not mesh:
		mesh_instance.material_override = null
		return

	if use_legacy_building_shader_override_for_test():
		mesh_instance.material_override = get_shared_building_material()
		return

	mesh_instance.material_override = null
	var surface_count := mesh.get_surface_count()
	if surface_count <= 0:
		return

	var has_church_floor := false
	var has_non_floor_geometry := false
	for block_id in voxel_bytes:
		if block_id == 8:
			has_church_floor = true
		elif block_id != 0:
			has_non_floor_geometry = true
		if has_church_floor and has_non_floor_geometry:
			break

	if surface_count == 1:
		var single_surface_material := get_shared_church_floor_material() if has_church_floor and not has_non_floor_geometry else get_shared_wood_block_material()
		mesh_instance.set_surface_override_material(0, single_surface_material)
		return

	mesh_instance.set_surface_override_material(0, get_shared_wood_block_material())
	mesh_instance.set_surface_override_material(1, get_shared_church_floor_material())
	for surface_index in range(2, surface_count):
		mesh_instance.set_surface_override_material(surface_index, get_shared_wood_block_material())

static func get_shared_building_material() -> Material:
	if _shared_building_material:
		return _shared_building_material

	var material := ShaderMaterial.new()
	material.shader = WOOD_BLOCK_ATLAS_SHADER
	material.set_shader_parameter("atlas_texture", WOOD_BLOCK_TEXTURE)
	material.set_shader_parameter("church_floor_texture", CHURCH_FLOOR_TEXTURE)
	_shared_building_material = material
	return _shared_building_material
