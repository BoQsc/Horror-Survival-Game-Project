extends RefCounted

var world_pos: Vector3 = Vector3.ZERO
var local_pos: Vector3 = Vector3.ZERO
var hit_pos: Vector3 = Vector3.ZERO
var rotation_angle: float = 0.0
var random_scale_factor: float = 1.0
var index: int = -1
var alive: bool = true
var scale: float = 1.0
var placed_by_player: bool = false
var transform: Transform3D = Transform3D.IDENTITY

var rotation: float:
	get:
		return rotation_angle
	set(value):
		rotation_angle = value
