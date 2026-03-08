@tool
extends Camera3D

@export var target: Node3D  # drag Marker3D here in Inspector

func _ready():
	# Ensure the camera script runs absolutely last in the frame, 
	# after Skeleton3D, BoneAttachment3D, and RemoteTransform3D have settled
	process_priority = 100

func _process(_delta: float) -> void:
	pass
