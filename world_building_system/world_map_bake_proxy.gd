extends Node3D
class_name WorldMapBakeProxy

@export var world_map_active: bool = true
@export var world_seed: int = 12345
@export var procedural_road_spacing: float = 100.0
@export var procedural_road_width: float = 8.0
@export var terrain_height: float = 10.0
@export var water_level: float = 13.0

var _world_map_buildings: Array = []
var _world_map_building_map: Image = null
