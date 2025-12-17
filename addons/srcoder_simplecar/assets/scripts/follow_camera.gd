extends Node3D

@export_category("Follow Camera Settings")
# Must be a vehicle body
@export var follow_target : Node3D
@export_range(0.0,10.0) var camera_height : float = 2.0
@export_range(1.0,20.0) var camera_distance : float = 5.0
@export_range(0.0,10.0) var rotation_damping = 1.0


#locals
@onready var pivot : Node3D = $Pivot
@onready var springarm : SpringArm3D = $Pivot/SpringArm3D

func _ready() -> void:
	pivot.position.y = camera_height
	springarm.spring_length = camera_distance


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	global_position = follow_target.global_position
	var target_horizontal_direction = follow_target.global_basis.z.slide(Vector3.UP).normalized()
	var desired_basis = Basis.looking_at(-target_horizontal_direction)
	global_basis = global_basis.slerp(desired_basis,rotation_damping*delta)
