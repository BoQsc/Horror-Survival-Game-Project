extends Node
class_name FPSVisualsFeature
## FPSVisuals - Procedural View Bobbing
## Applies subtle sinusoidal movement to the camera and arms during locomotion.

# Settings
@export var bob_freq: float = 6.0
@export var bob_amp: float = 0.03
@export var bob_smoothing: float = 10.0

@export var sway_amount: float = 0.4
@export var sway_smoothing: float = 12.0

# References
var player: CharacterBody3D = null
var camera: Camera3D = null
var hand_holder: Node3D = null
var arm_marker: Node3D = null

# State
var _bob_time: float = 0.0
var _current_bob: Vector3 = Vector3.ZERO
var _current_sway: Vector3 = Vector3.ZERO
var _mouse_input: Vector2 = Vector2.ZERO

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("FPSVisuals: Must be child of Player/Components node")
		return
	
	camera = player.get_node_or_null("Camera3D")
	if camera:
		hand_holder = camera.get_node_or_null("HandHolder")
	
	arm_marker = player.find_child("Marker3D", true, false)
	
	print("FPSVisuals: Bobbing & Sway. Camera: %s, HandHolder: %s" % [
		"OK" if camera else "MISSING",
		"OK" if hand_holder else "MISSING"
	])

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_mouse_input = event.relative

func _process(delta: float) -> void:
	if not player or not camera or not has_node("/root/ToolConfig"):
		return
	
	var config = get_node("/root/ToolConfig")
	_update_bob(delta, config)
	_update_sway(delta, config)
	_apply_visuals()

func _update_bob(delta: float, config: Node) -> void:
	if not config.fp_bob_enabled:
		_current_bob = _current_bob.lerp(Vector3.ZERO, delta * bob_smoothing)
		return
		
	# View Bobbing
	var speed = player.velocity.length()
	var target_bob = Vector3.ZERO
	
	if player.is_on_floor() and speed > 0.5:
		var speed_mult = clamp(speed / 5.0, 0.5, 1.5)
		_bob_time += delta * speed_mult
		
		target_bob.y = sin(_bob_time * bob_freq) * bob_amp
		target_bob.x = cos(_bob_time * bob_freq * 2.0) * bob_amp * 0.5
	
	_current_bob = _current_bob.lerp(target_bob, delta * bob_smoothing)

func _update_sway(delta: float, config: Node) -> void:
	if not config.fp_sway_enabled:
		_current_sway = _current_sway.lerp(Vector3.ZERO, delta * sway_smoothing)
		return
		
	# Mouse Movement Sway
	var target_sway = Vector3(
		-_mouse_input.x * sway_amount * 0.005,
		_mouse_input.y * sway_amount * 0.005,
		0
	)
	
	_current_sway = _current_sway.lerp(target_sway, delta * sway_smoothing)
	_mouse_input = Vector2.ZERO

func _apply_visuals() -> void:
	# Keep the camera rotation clean (no procedural tilt)
	camera.rotation.z = 0.0
	
	# View Lag (subtle camera shift) + Walking Bob
	camera.h_offset = (_current_bob.x * 0.2) + (_current_sway.x * 0.4)
	camera.v_offset = (_current_bob.y * 0.2) + (_current_sway.y * 0.4)
	
	# Apply Bob and Sway to legacy Arms (HandHolder)
	if hand_holder:
		hand_holder.position.x = (_current_bob.x * 1.5) + (_current_sway.x * 1.2)
		hand_holder.position.y = (_current_bob.y * 1.5) + (_current_sway.y * 1.2)
