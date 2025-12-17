extends "res://addons/srcoder_simplecar/assets/scripts/follow_camera.gd"
## Extended follow camera with null safety check.
## Does NOT modify the addon - inherits and overrides.


func _physics_process(delta: float) -> void:
	# Guard against null follow_target
	if not follow_target or not is_instance_valid(follow_target):
		return
	
	# Call parent logic
	global_position = follow_target.global_position
	var target_horizontal_direction = follow_target.global_basis.z.slide(Vector3.UP).normalized()
	var desired_basis = Basis.looking_at(-target_horizontal_direction)
	global_basis = global_basis.slerp(desired_basis, rotation_damping * delta)
