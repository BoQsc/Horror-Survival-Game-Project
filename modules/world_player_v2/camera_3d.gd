@tool
extends Camera3D

@export var target: Node3D  # drag Marker3D here in Inspector

func _ready():
	# Ensure the camera script runs absolutely last in the frame, 
	# after Skeleton3D, BoneAttachment3D, and RemoteTransform3D have settled
	process_priority = 100

func _process(delta):
	if target:
		look_at(target.global_position, Vector3.UP)
