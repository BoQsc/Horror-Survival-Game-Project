@tool
extends Camera3D

@export var target: Node3D  # drag Marker3D here in Inspector

# Disabling look_at logic as it prevents player pitch control (mouse look up/down)
func _process(delta):
	if target:
		look_at(target.global_position, Vector3.UP)
