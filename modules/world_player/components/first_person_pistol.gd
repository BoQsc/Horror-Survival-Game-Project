extends Node
class_name FirstPersonPistol
## FirstPersonPistol - Handles first-person pistol visuals with sway, bobbing, shooting animation
## Shows pistol when equipped, hides when other items selected.

# Preload resources
const PISTOL_SOUND = preload("res://sound/pistol-shot-233473.mp3")
const RELOAD_SOUND = preload("res://sound/mag-reload-81594.mp3")
const PISTOL_SCENE_PATH = "res://models/pistol/heavy_pistol_without_hands.tscn"

# Sway & Bobbing Settings - matched to FirstPersonArms
@export var sway_amount: float = 0.002
@export var sway_smoothing: float = 10.0
@export var bob_freq: float = 10.0
@export var bob_amp: float = 0.01

# ADS Settings (from original project)
@export var ads_origin: Vector3 = Vector3(0.002, -0.06, -0.19)
@export var ads_rotation: Vector3 = Vector3(-0.955, 180.735, 0.0)

# Adjustable transform - tweak in editor!
@export var pistol_scale: Vector3 = Vector3(0.02, 0.02, 0.02)
@export var pistol_position: Vector3 = Vector3(0.1, -0.15, -0.25)
@export var pistol_rotation: Vector3 = Vector3(0, 180, 0)

# References
var player: CharacterBody3D = null
var camera: Camera3D = null
var hand_holder: Node3D = null
var pistol_mesh: Node3D = null
var anim_player: AnimationPlayer = null
var audio_player: AudioStreamPlayer3D = null

# State
var pistol_origin: Vector3 = Vector3.ZERO
var mouse_input: Vector2 = Vector2.ZERO
var sway_time: float = 0.0
var is_aiming: bool = false
var is_reloading: bool = false

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("FirstPersonPistol: Must be child of Player/Components node")
		return
	
	camera = player.get_node_or_null("Camera3D")
	if not camera:
		push_error("FirstPersonPistol: Could not find Camera3D")
		return
	
	# Defer setup to ensure player is in scene tree
	call_deferred("_setup_pistol")
	
	# Connect to signals
	PlayerSignals.item_changed.connect(_on_item_changed)
	PlayerSignals.pistol_fired.connect(_on_pistol_fired)
	PlayerSignals.pistol_reload.connect(_on_pistol_reload)

func _setup_pistol() -> void:
	# Create hand holder as child of camera (for sway/bob)
	hand_holder = Node3D.new()
	hand_holder.name = "PistolHolder"
	camera.add_child(hand_holder)
	
	# Load pistol scene
	if ResourceLoader.exists(PISTOL_SCENE_PATH):
		var pistol_scene = load(PISTOL_SCENE_PATH)
		if pistol_scene:
			pistol_mesh = pistol_scene.instantiate()
			hand_holder.add_child(pistol_mesh)
			
			# Apply transform
			pistol_mesh.scale = pistol_scale
			pistol_mesh.position = pistol_position
			pistol_mesh.rotation_degrees = pistol_rotation
			
			# Store origin for sway calculations
			pistol_origin = pistol_position
			
			# Find animation player
			anim_player = _find_anim_player(pistol_mesh)
			
			DebugSettings.log_player("FirstPersonPistol: Loaded model, AnimPlayer: %s" % ("OK" if anim_player else "NONE"))
	else:
		push_error("FirstPersonPistol: Could not find %s" % PISTOL_SCENE_PATH)
	
	# Create audio player
	audio_player = AudioStreamPlayer3D.new()
	audio_player.name = "PistolAudio"
	audio_player.max_polyphony = 5  # Allow overlapping shots!
	player.add_child(audio_player)
	
	# Start hidden (only show when pistol equipped)
	if pistol_mesh:
		pistol_mesh.visible = false
	
	DebugSettings.log_player("FirstPersonPistol: Component initialized")

func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found = _find_anim_player(child)
		if found:
			return found
	return null

func _input(event: InputEvent) -> void:
	# Capture mouse movement for sway
	if event is InputEventMouseMotion:
		mouse_input = event.relative
	
	# Reload on R key
	if event is InputEventKey and event.pressed and event.keycode == KEY_R:
		if pistol_mesh and pistol_mesh.visible and not is_reloading:
			PlayerSignals.pistol_reload.emit()

func _process(delta: float) -> void:
	if not pistol_mesh or not pistol_mesh.visible:
		return
	
	# Check ADS (right mouse button)
	is_aiming = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
	
	# Update sway and bobbing
	_update_sway_and_bob(delta)

func _update_sway_and_bob(delta: float) -> void:
	if not hand_holder:
		return
	
	# Reduce sway/bob during ADS
	var current_sway = sway_amount * (0.1 if is_aiming else 1.0)
	var current_bob = bob_amp * (0.1 if is_aiming else 1.0)
	
	# Target position (ADS or normal)
	var target_pos = ads_origin if is_aiming else pistol_origin
	var target_rot = ads_rotation if is_aiming else pistol_rotation
	
	# Mouse sway
	var target_sway = Vector3(
		-mouse_input.x * current_sway,
		mouse_input.y * current_sway,
		0
	)
	
	# Movement bobbing
	var bob_offset = Vector3.ZERO
	if player.is_on_floor() and player.velocity.length() > 1.0:
		sway_time += delta
		bob_offset.y = sin(sway_time * bob_freq) * current_bob
		bob_offset.x = cos(sway_time * bob_freq * 2.0) * current_bob * 0.5
	
	# Apply to hand holder
	var total_target = target_sway + bob_offset
	hand_holder.position = hand_holder.position.lerp(total_target, delta * sway_smoothing)
	
	# Apply pistol transform (with ADS smoothing)
	var smooth_speed = 20.0 if is_aiming else sway_smoothing
	pistol_mesh.position = pistol_mesh.position.lerp(target_pos, delta * smooth_speed)
	pistol_mesh.rotation_degrees = pistol_mesh.rotation_degrees.lerp(target_rot, delta * smooth_speed)
	
	# Reset mouse input
	mouse_input = Vector2.ZERO

func _on_item_changed(_slot: int, item: Dictionary) -> void:
	# Show pistol only when heavy_pistol is equipped
	var item_id = item.get("id", "")
	var should_show = (item_id == "heavy_pistol")
	
	if pistol_mesh:
		pistol_mesh.visible = should_show

func _on_pistol_fired() -> void:
	if not audio_player:
		return
	
	# Play gunshot sound (even if pistol not visible, for feedback)
	audio_player.stream = PISTOL_SOUND
	audio_player.pitch_scale = randf_range(0.95, 1.05)
	audio_player.play()
	
	# Play shoot animation (0-0.4s segment) - always call to ensure signal is emitted
	_play_shoot_animation()

func _play_shoot_animation() -> void:
	if not anim_player:
		# No animation player - just signal ready immediately
		await get_tree().create_timer(0.1).timeout
		PlayerSignals.pistol_fire_ready.emit()
		return
	
	# Find the animation (could be "allanims", "shoot", etc.)
	var anim_name = ""
	for name in anim_player.get_animation_list():
		if "allanim" in name.to_lower() or "shoot" in name.to_lower():
			anim_name = name
			break
	
	if anim_name == "":
		# No animation found - signal ready immediately
		await get_tree().create_timer(0.1).timeout
		PlayerSignals.pistol_fire_ready.emit()
		return
	
	# Play segment 0-0.4s (original project style)
	anim_player.stop()
	anim_player.play(anim_name)
	
	await get_tree().create_timer(0.4).timeout
	
	if is_instance_valid(anim_player) and not is_reloading:
		anim_player.stop()
	
	PlayerSignals.pistol_fire_ready.emit()

func _on_pistol_reload() -> void:
	if is_reloading or not audio_player:
		return
	
	is_reloading = true
	
	# Play reload sound
	audio_player.stream = RELOAD_SOUND
	audio_player.play()
	
	# Play reload animation (0.4s-2.85s segment)
	if anim_player:
		_play_reload_animation()
	else:
		# No animation - just wait reload time
		await get_tree().create_timer(2.45).timeout
		is_reloading = false

func _play_reload_animation() -> void:
	# Find animation
	var anim_name = ""
	for name in anim_player.get_animation_list():
		if "allanim" in name.to_lower() or "reload" in name.to_lower():
			anim_name = name
			break
	
	if anim_name == "":
		await get_tree().create_timer(2.45).timeout
		is_reloading = false
		return
	
	anim_player.stop()
	anim_player.play(anim_name)
	anim_player.seek(0.4, true)  # Start at reload segment
	
	# Wait reload duration (2.85 - 0.4 = 2.45s)
	await get_tree().create_timer(2.45).timeout
	
	if is_instance_valid(anim_player):
		anim_player.stop()
	
	is_reloading = false
	DebugSettings.log_player("FirstPersonPistol: Reload complete")
