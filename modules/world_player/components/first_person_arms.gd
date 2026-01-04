extends Node
class_name FirstPersonArms
## FirstPersonArms - Handles first-person arm visuals with sway, bobbing, and punch animation
## Shows arms when no item equipped, hides when tools/weapons selected.

# Sway & Bobbing Settings - tweak in editor!
# Set to 0 to disable, increase to enable
@export var sway_amount: float = 0.0  # Was 0.002 - disabled for testing
@export var sway_smoothing: float = 10.0
@export var bob_freq: float = 0.0  # Was 10.0 - disabled for testing
@export var bob_amp: float = 0.0  # Was 0.01 - disabled for testing

# Arms model path
const ARMS_MODEL_PATH: String = "res://game/assets/psx_first_person_arms.glb"
const PUNCH_SFX_PATH: String = "res://game/sound/classic-punch-impact-352711.mp3"

# Adjustable transform - tweak in editor!
@export var arms_scale: Vector3 = Vector3(0.05, 0.05, 0.05)
@export var arms_position: Vector3 = Vector3(0.005, -0.27, 0.0)
@export var arms_rotation: Vector3 = Vector3(-1.345, 189.54, 0.0)

# References
var player: CharacterBody3D = null
var camera: Camera3D = null
var hand_holder: Node3D = null
var arms_mesh: Node3D = null
var anim_player: AnimationPlayer = null
var punch_sfx: AudioStreamPlayer3D = null

# State
var arms_origin: Vector3 = Vector3.ZERO
var mouse_input: Vector2 = Vector2.ZERO
var sway_time: float = 0.0
var is_punching: bool = false
var punch_cooldown: float = 0.0
const PUNCH_COOLDOWN_TIME: float = 0.3

func _ready() -> void:
	# Find player (FirstPersonArms is under Components which is under WorldPlayer)
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("FirstPersonArms: Must be child of Player/Components node")
		return
	
	# Find camera
	camera = player.get_node_or_null("Camera3D")
	if not camera:
		push_error("FirstPersonArms: Camera3D not found")
		return
	
	# Create HandHolder under camera
	_setup_hand_holder()
	
	# Load arms model
	_load_arms_model()
	
	# Create punch SFX
	_setup_punch_sfx()
	
	# Connect to item changes
	PlayerSignals.item_changed.connect(_on_item_changed)
	
	# Connect to punch signal if it exists
	if PlayerSignals.has_signal("punch_triggered"):
		PlayerSignals.punch_triggered.connect(_on_punch_triggered)
	
	DebugManager.log_player("FirstPersonArms: Initialized")

func _setup_hand_holder() -> void:
	hand_holder = Node3D.new()
	hand_holder.name = "HandHolder"
	camera.add_child(hand_holder)
	DebugManager.log_player("FirstPersonArms: HandHolder created under Camera3D")

func _load_arms_model() -> void:
	if not ResourceLoader.exists(ARMS_MODEL_PATH):
		push_error("FirstPersonArms: Arms model not found at " + ARMS_MODEL_PATH)
		return
	
	var arms_scene = load(ARMS_MODEL_PATH)
	if not arms_scene:
		push_error("FirstPersonArms: Failed to load arms model")
		return
	
	arms_mesh = arms_scene.instantiate()
	arms_mesh.name = "ArmsMesh"
	
	# Apply transform from export variables
	arms_mesh.scale = arms_scale
	arms_mesh.position = arms_position
	arms_mesh.rotation_degrees = arms_rotation
	arms_mesh.visible = true
	
	hand_holder.add_child(arms_mesh)
	arms_origin = arms_mesh.position
	
	# Find AnimationPlayer in imported model
	anim_player = arms_mesh.get_node_or_null("AnimationPlayer")
	if not anim_player:
		# Try to find it recursively
		for child in arms_mesh.get_children():
			if child is AnimationPlayer:
				anim_player = child
				break
	
	if anim_player:
		DebugManager.log_player("FirstPersonArms: Found AnimationPlayer with %d animations" % anim_player.get_animation_list().size())
		# Try to play idle animation
		_try_play_idle()
	else:
		DebugManager.log_player("FirstPersonArms: No AnimationPlayer found in model")
	
	# Set camera near clip very small to prevent arms clipping during punch
	# Note: Can't be exactly 0 (causes projection math issues), 0.001 is minimum
	camera.near = 0.001
	
	DebugManager.log_player("FirstPersonArms: Arms model loaded and positioned")

func _setup_punch_sfx() -> void:
	if ResourceLoader.exists(PUNCH_SFX_PATH):
		punch_sfx = AudioStreamPlayer3D.new()
		punch_sfx.name = "PunchSFX"
		punch_sfx.stream = load(PUNCH_SFX_PATH)
		add_child(punch_sfx)
		DebugManager.log_player("FirstPersonArms: Punch SFX loaded")

func _unhandled_input(event: InputEvent) -> void:
	# Capture mouse motion for sway
	if event is InputEventMouseMotion:
		mouse_input = event.relative

func _process(delta: float) -> void:
	if not arms_mesh:
		return
	
	# Update transform from export vars at runtime (for editor tweaking)
	# Position is relative to HandHolder which handles sway/bob
	arms_mesh.scale = arms_scale
	arms_mesh.position = arms_position
	arms_mesh.rotation_degrees = arms_rotation
	
	if not arms_mesh.visible:
		return
	
	# Update cooldown
	if punch_cooldown > 0:
		punch_cooldown -= delta
	
	# Handle sway and bobbing
	_update_sway_and_bob(delta)
	
	# Check for punch input (left click when arms visible)
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			_try_punch()

func _update_sway_and_bob(delta: float) -> void:
	if not hand_holder:
		return
	
	# 1. Mouse Sway (lag behind camera) - applied to hand_holder like original
	var target_sway = Vector3(
		-mouse_input.x * sway_amount,
		mouse_input.y * sway_amount,
		0
	)
	
	# 2. Movement Bobbing (only when moving on floor)
	var bob_offset = Vector3.ZERO
	if player.is_on_floor() and player.velocity.length() > 1.0:
		# Use fixed time step for smooth bob, not velocity-dependent (that was too fast)
		sway_time += delta
		bob_offset.y = sin(sway_time * bob_freq) * bob_amp
		bob_offset.x = cos(sway_time * bob_freq * 2.0) * bob_amp * 0.5
	
	# Combine and apply to hand_holder
	var total_target = target_sway + bob_offset
	hand_holder.position = hand_holder.position.lerp(total_target, delta * sway_smoothing)
	
	# Reset mouse input frame-by-frame
	mouse_input = Vector2.ZERO

func _try_punch() -> void:
	if punch_cooldown > 0 or is_punching:
		return
	
	punch_cooldown = PUNCH_COOLDOWN_TIME
	is_punching = true
	
	# Play punch animation
	if anim_player:
		var punch_anims = ["punch", "attack", "Combat_punch_right", "arms_armature|Combat_punch_right"]
		for punch_name in punch_anims:
			for anim_name in anim_player.get_animation_list():
				if punch_name.to_lower() in anim_name.to_lower():
					anim_player.play(anim_name)
					if not anim_player.animation_finished.is_connected(_on_punch_finished):
						anim_player.animation_finished.connect(_on_punch_finished, CONNECT_ONE_SHOT)
					break
	
	# Play punch sound
	if punch_sfx:
		punch_sfx.pitch_scale = randf_range(0.9, 1.1)
		punch_sfx.play()

func _on_punch_finished(_anim_name: String) -> void:
	is_punching = false
	PlayerSignals.punch_ready.emit()  # Tell ModePlay we're ready for next punch
	_try_play_idle()

func _try_play_idle() -> void:
	if not anim_player:
		return
	
	for anim_name in anim_player.get_animation_list():
		if "idle" in anim_name.to_lower():
			anim_player.play(anim_name)
			return

func _on_punch_triggered() -> void:
	# External trigger for punch (from ModePlay)
	_try_punch()

func _on_item_changed(_slot: int, item: Dictionary) -> void:
	# Show arms only when category is NONE (empty/fists)
	var category = item.get("category", 0)
	var should_show = (category == 0) # ItemCategory.NONE
	
	if arms_mesh:
		arms_mesh.visible = should_show
		if should_show and anim_player:
			_try_play_idle()
	
	DebugManager.log_player("FirstPersonArms: Item changed - category=%d, arms_visible=%s" % [category, should_show])

## Force show/hide arms (for external control)
func set_arms_visible(visible: bool) -> void:
	if arms_mesh:
		arms_mesh.visible = visible
		if visible:
			_try_play_idle()
