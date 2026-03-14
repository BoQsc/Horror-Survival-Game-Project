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

@export var flare_amount: float = 0.8 # Intensity of elbow flaring
@export var flare_smoothing: float = 5.0

# References
var player: CharacterBody3D = null
var camera: Camera3D = null
var hand_holder: Node3D = null
var arm_marker: Node3D = null
var skeleton: Skeleton3D = null

# Bone Indices
var _l_arm_idx: int = -1
var _r_arm_idx: int = -1

# State
var _bob_time: float = 0.0
var _current_bob: Vector3 = Vector3.ZERO
var _current_sway: Vector3 = Vector3.ZERO
var _current_flare: float = 0.0
var _mouse_input: Vector2 = Vector2.ZERO

func _ready() -> void:
	# Priority 95 so we run AFTER HipStabilizer (90) and AFTER AnimationTree
	process_priority = 95
	
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("FPSVisuals: Must be child of Player/Components node")
		return
	
	camera = player.get_node_or_null("Camera3D")
	if camera:
		hand_holder = camera.get_node_or_null("HandHolder")
	
	arm_marker = player.find_child("Marker3D", true, false)
	
	# Find skeleton: Components -> Player -> WorldPlayerFullBody -> Model -> Armature -> GeneralSkeleton
	skeleton = player.get_node_or_null("WorldPlayerFullBody/Superhero_Male_FullBody/Armature/GeneralSkeleton")
	if skeleton:
		_l_arm_idx = skeleton.find_bone("LeftUpperArm")
		_r_arm_idx = skeleton.find_bone("RightUpperArm")
	
	print("FPSVisuals: Ready. Camera: %s, Skeleton: %s" % [
		"OK" if camera else "MISSING",
		"OK" if skeleton else "MISSING"
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
	_update_flare(delta, config)
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

func _update_flare(delta: float, config: Node) -> void:
	# Calculate flaring based on pitch (looking down)
	var pitch = camera.rotation.x
	var target_flare = 0.0
	
	if config.fp_clipping_prevention_enabled and pitch < 0.0: # Looking down
		# Increase flare as we look down. Scale by crouching.
		var crouch_node = player.get_node_or_null("Components/Crouch")
		var crouch_mult = 2.0 if crouch_node and crouch_node.get("is_crouching") else 1.0
		var base_flare = abs(pitch) * flare_amount * crouch_mult
		target_flare = base_flare * config.fp_clipping_flare_mult
	
	_current_flare = lerp(_current_flare, target_flare, delta * flare_smoothing)

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
		
	# Apply Elbow Flaring to Full Body Skeleton
	if skeleton and _l_arm_idx >= 0 and _r_arm_idx >= 0:
		# L flare: Rotate outward (relative to bone axis, usually local Z or X)
		# For this model, Z outward is usually positive/negative depending on bind pose.
		# We'll flare them "out" away from the thighs.
		var flare_rot_l = Quaternion(Vector3.FORWARD, _current_flare * 0.5)
		var flare_rot_r = Quaternion(Vector3.FORWARD, -_current_flare * 0.5)
		
		# Apply on top of animation pose
		skeleton.set_bone_pose_rotation(_l_arm_idx, skeleton.get_bone_pose_rotation(_l_arm_idx) * flare_rot_l)
		skeleton.set_bone_pose_rotation(_r_arm_idx, skeleton.get_bone_pose_rotation(_r_arm_idx) * flare_rot_r)
