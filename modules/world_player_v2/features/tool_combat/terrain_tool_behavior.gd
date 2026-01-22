extends Resource
class_name TerrainToolBehavior

## Shape types matching modify_density.glsl
enum ShapeType {
	SPHERE = 0,
	BOX = 1,
	COLUMN = 2
}

@export_group("Tool Settings")
@export var display_name: String = "Tool"
@export var shape_type: ShapeType = ShapeType.SPHERE
@export var radius: float = 1.0
@export var strength: float = 1.0 ## Positive = Dig (Air), Negative = Place (Ground)

@export_group("Targeting")
@export var snap_to_grid: bool = false
@export var raycast_distance: float = 3.5
@export var use_raycast_normal: bool = false ## If true, offsets target by normal (useful for placing ON faces)

@export_group("Material")
@export var material_id: int = -1 ## -1 = Don't change material

## Apply this tool's effect to the terrain
func apply(terrain_manager: Node, hit_position: Vector3, hit_normal: Vector3) -> void:
	if not terrain_manager:
		return
		
	var target_pos = hit_position
	
	if snap_to_grid:
		# Grid snapping logic
		var offset = Vector3.ZERO
		if use_raycast_normal:
			offset = hit_normal * 0.1 # Small offset to push into/out of block
			
		var snapped = target_pos - offset
		target_pos = Vector3(floor(snapped.x) + 0.5, floor(snapped.y) + 0.5, floor(snapped.z) + 0.5)
	
	# Execute
	# Note: ChunkManager modify_terrain signature: (pos, radius, value, shape, layer, material_id)
	terrain_manager.modify_terrain(target_pos, radius, strength, int(shape_type), 0, material_id)
