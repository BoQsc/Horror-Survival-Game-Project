@tool
extends Camera3D

@export var target: Node3D  # drag Marker3D here in Inspector

func _ready():
	# Ensure the camera script runs absolutely last in the frame, 
	# after Skeleton3D, BoneAttachment3D, and RemoteTransform3D have settled
	process_priority = 100

func _process(_delta: float) -> void:
	if target:
		# Project the marker far in front of the camera (exactly at the center crosshair)
		# This ensures the body points exactly where the camera is looking.
		# We do this here at priority 100 to ensure we use the final camera 
		# position after the engine's RemoteTransform3D has settled.
		target.global_position = global_position - global_transform.basis.z * 50.0
