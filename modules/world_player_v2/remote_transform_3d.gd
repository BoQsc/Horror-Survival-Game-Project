extends RemoteTransform3D

@export_category("Shock Absorber")
## How fast the target catches up to the bone. Lower is smoother but lags more.
@export var position_smoothing: float = 30.0 
## Toggle to easily turn the shock absorber on or off for testing.
@export var enable_smoothing: bool = false

func _ready() -> void:
	# We MUST turn off the native position update, otherwise the engine 
	# will forcefully snap the camera to the bone, fighting our smooth math.
	update_position = false

func _physics_process(delta: float) -> void:
	# Make sure we actually have a valid node assigned in the remote_path
	if remote_path.is_empty():
		return
		
	var target: Node3D = get_node_or_null(remote_path)
	
	if target:
		if enable_smoothing:
			# The Shock Absorber: smoothly glide the target's position to this node's position
			target.global_position = target.global_position.lerp(global_position, position_smoothing * delta)
		else:
			# Fallback: exact snapping if smoothing is turned off
			target.global_position = global_position
