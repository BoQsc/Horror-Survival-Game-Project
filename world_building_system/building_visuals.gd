extends RefCounted
class_name BuildingVisuals

## Shared rendering helpers for building blocks.
## Keep the gameplay chunks and editor addons on the same material path.

const WOOD_BLOCK_TEXTURE: Texture2D = preload("res://world_greedy_meshing/wood-block-texture.png")
const CHURCH_FLOOR_TEXTURE: Texture2D = preload("res://models/objects/church_floor/church_floor_texture.png")
const WOOD_BLOCK_ATLAS_SHADER: Shader = preload("res://world_building_system/wood_block_atlas.gdshader")

static var _shared_building_material: Material = null

static func get_shared_building_material() -> Material:
	if _shared_building_material:
		return _shared_building_material

	var material := ShaderMaterial.new()
	material.shader = WOOD_BLOCK_ATLAS_SHADER
	material.set_shader_parameter("atlas_texture", WOOD_BLOCK_TEXTURE)
	material.set_shader_parameter("church_floor_texture", CHURCH_FLOOR_TEXTURE)
	_shared_building_material = material
	return _shared_building_material
