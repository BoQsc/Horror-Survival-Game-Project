extends Node
class_name FirstPersonArmsV2
## FirstPersonArms - Handles first-person arm visuals with sway, bobbing, and punch animation
## Shows arms when no item equipped, hides when tools/weapons selected.

# Sway & Bobbing Settings
@export var sway_amount: float = 0.0
@export var sway_smoothing: float = 10.0
@export var bob_freq: float = 0.0
@export var bob_amp: float = 0.0

const ARMS_MODEL_PATH: String = "res://game/assets/psx_first_person_arms.glb"
const PUNCH_SFX_PATH: String = "res://game/sound/classic-punch-impact-352711.mp3"

@export var arms_scale: Vector3 = Vector3(0.05, 0.05, 0.05)
@export var arms_position: Vector3 = Vector3(0.005, -0.27, 0.0)
@export var arms_rotation: Vector3 = Vector3(-1.345, 189.54, 0.0)

var player: CharacterBody3D = null
var camera: Camera3D = null
var hand_holder: Node3D = null
var arms_mesh: Node3D = null
var anim_player: AnimationPlayer = null
var punch_sfx: AudioStreamPlayer3D = null
var hotbar: Node = null
var mode_manager: Node = null

var arms_origin: Vector3 = Vector3.ZERO
var mouse_input: Vector2 = Vector2.ZERO
var sway_time: float = 0.0
var is_punching: bool = false
var punch_cooldown: float = 0.0
const PUNCH_COOLDOWN_TIME: float = 0.3
var is_placing: bool = false
var place_cooldown: float = 0.0
const PLACE_COOLDOWN_TIME: float = 0.5

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("FirstPersonArms: Must be child of Player/Components node")
		return
	
	camera = player.get_node_or_null("Camera3D")
	if not camera:
		push_error("FirstPersonArms: Camera3D not found")
		return
	
	_setup_hand_holder()
	_load_arms_model()
	_setup_punch_sfx()
	
	# Find hotbar and mode manager for checking item category and game mode
	hotbar = player.get_node_or_null("Systems/Hotbar")
	mode_manager = player.get_node_or_null("Systems/ModeManager")
	
	if has_node("/root/PlayerSignals"):
		PlayerSignals.item_changed.connect(_on_item_changed)
		if PlayerSignals.has_signal("punch_triggered"):
			PlayerSignals.punch_triggered.connect(_on_punch_triggered)
		if PlayerSignals.has_signal("resource_placed"):
			PlayerSignals.resource_placed.connect(_on_resource_placed)
		if PlayerSignals.has_signal("block_placed"):
			PlayerSignals.block_placed.connect(_on_block_placed)
		if PlayerSignals.has_signal("object_placed"):
			PlayerSignals.object_placed.connect(_on_object_placed)
		if PlayerSignals.has_signal("bucket_placed"):
			PlayerSignals.bucket_placed.connect(_on_bucket_placed)
		if PlayerSignals.has_signal("vehicle_spawned"):
			PlayerSignals.vehicle_spawned.connect(_on_vehicle_spawned)

func _setup_hand_holder() -> void:
	hand_holder = Node3D.new()
	hand_holder.name = "HandHolder"
	camera.add_child(hand_holder)

func _load_arms_model() -> void:
	if not ResourceLoader.exists(ARMS_MODEL_PATH):
		return
	
	var arms_scene = load(ARMS_MODEL_PATH)
	if not arms_scene:
		return
	
	arms_mesh = arms_scene.instantiate()
	arms_mesh.name = "ArmsMesh"
	arms_mesh.scale = arms_scale
	arms_mesh.position = arms_position
	arms_mesh.rotation_degrees = arms_rotation
	arms_mesh.visible = true
	
	hand_holder.add_child(arms_mesh)
	arms_origin = arms_mesh.position
	
	anim_player = arms_mesh.get_node_or_null("AnimationPlayer")
	if not anim_player:
		for child in arms_mesh.get_children():
			if child is AnimationPlayer:
				anim_player = child
				break
	
	if anim_player:
		_try_play_idle()
	
	camera.near = 0.001

func _setup_punch_sfx() -> void:
	if ResourceLoader.exists(PUNCH_SFX_PATH):
		punch_sfx = AudioStreamPlayer3D.new()
		punch_sfx.name = "PunchSFX"
		punch_sfx.stream = load(PUNCH_SFX_PATH)
		add_child(punch_sfx)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_input = event.relative

func _process(delta: float) -> void:
	if not arms_mesh:
		return
	
	arms_mesh.scale = arms_scale
	arms_mesh.position = arms_position
	arms_mesh.rotation_degrees = arms_rotation
	
	if not arms_mesh.visible:
		return
	
	if punch_cooldown > 0:
		punch_cooldown -= delta
	
	if place_cooldown > 0:
		place_cooldown -= delta
	
	_update_sway_and_bob(delta)
	
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			# Only punch in PLAY mode AND with fists (category 0)
			if mode_manager and mode_manager.has_method("is_play_mode"):
				if mode_manager.is_play_mode():
					# Check if holding fists (category 0), not car keys or other items
					if hotbar and hotbar.has_method("get_selected_item"):
						var item = hotbar.get_selected_item()
						if item.get("category", 0) == 0:  # NONE = Fists only
							_try_punch()
			elif not mode_manager:
				# Fallback: check category even without mode_manager
				if hotbar and hotbar.has_method("get_selected_item"):
					var item = hotbar.get_selected_item()
					if item.get("category", 0) == 0:
						_try_punch()

func _update_sway_and_bob(delta: float) -> void:
	if not hand_holder:
		return
	
	var target_sway = Vector3(
		-mouse_input.x * sway_amount,
		mouse_input.y * sway_amount,
		0
	)
	
	var bob_offset = Vector3.ZERO
	if player.is_on_floor() and player.velocity.length() > 1.0:
		sway_time += delta
		bob_offset.y = sin(sway_time * bob_freq) * bob_amp
		bob_offset.x = cos(sway_time * bob_freq * 2.0) * bob_amp * 0.5
	
	var total_target = target_sway + bob_offset
	hand_holder.position = hand_holder.position.lerp(total_target, delta * sway_smoothing)
	
	mouse_input = Vector2.ZERO

func _try_punch() -> void:
	if punch_cooldown > 0 or is_punching:
		return
	
	punch_cooldown = PUNCH_COOLDOWN_TIME
	is_punching = true
	
	if anim_player:
		var punch_anims = ["punch", "attack", "Combat_punch_right", "arms_armature|Combat_punch_right"]
		for punch_name in punch_anims:
			for anim_name in anim_player.get_animation_list():
				if punch_name.to_lower() in anim_name.to_lower():
					anim_player.play(anim_name)
					if not anim_player.animation_finished.is_connected(_on_punch_finished):
						anim_player.animation_finished.connect(_on_punch_finished, CONNECT_ONE_SHOT)
					break
	
	if punch_sfx:
		punch_sfx.pitch_scale = randf_range(0.9, 1.1)
		punch_sfx.play()

func _on_punch_finished(_anim_name: String) -> void:
	is_punching = false
	if has_node("/root/PlayerSignals"):
		PlayerSignals.punch_ready.emit()
	_try_play_idle()

func _try_play_idle() -> void:
	if not anim_player:
		return
	
	for anim_name in anim_player.get_animation_list():
		if "idle" in anim_name.to_lower():
			anim_player.play(anim_name)
			return

## Play Collect_something pose for holding materials (static pose at 0.15s)
func _play_collect_pose() -> void:
	if not anim_player:
		return
	
	var collect_anims = ["Collect_something", "collect", "arms_armature|Collect_something"]
	for anim_name in anim_player.get_animation_list():
		for collect_pattern in collect_anims:
			if collect_pattern.to_lower() in anim_name.to_lower():
				anim_player.play(anim_name)
				anim_player.seek(0.15, true)  # Seek to 0.15s and update immediately
				anim_player.pause()  # Pause to hold the pose
				return
	
	# Fallback to idle if Collect_something not found
	_try_play_idle()

func _on_punch_triggered() -> void:
	_try_punch()

func _on_resource_placed() -> void:
	_try_place_animation()

func _on_block_placed() -> void:
	_try_place_animation()

func _on_object_placed() -> void:
	_try_place_animation()

func _on_bucket_placed() -> void:
	_try_place_animation()

func _on_vehicle_spawned() -> void:
	_try_place_animation()

## Play the placement (Collect_something) animation (from 0.15s onwards)
func _try_place_animation() -> void:
	if place_cooldown > 0 or is_placing:
		return
	
	place_cooldown = PLACE_COOLDOWN_TIME
	is_placing = true
	
	if anim_player:
		# Look for "Collect_something" animation
		var collect_anims = ["Collect_something", "collect", "place", "arms_armature|Collect_something"]
		for anim_name in anim_player.get_animation_list():
			for collect_pattern in collect_anims:
				if collect_pattern.to_lower() in anim_name.to_lower():
					anim_player.play(anim_name)
					anim_player.seek(0.15, true)  # Start from 0.15s (skip initial windup)
					if not anim_player.animation_finished.is_connected(_on_place_finished):
						anim_player.animation_finished.connect(_on_place_finished, CONNECT_ONE_SHOT)
					return

func _on_place_finished(_anim_name: String) -> void:
	is_placing = false
	# Return to collect pose if still holding placeable items, otherwise idle
	if hotbar and hotbar.has_method("get_selected_item"):
		var item = hotbar.get_selected_item()
		var category = item.get("category", 0)
		# Categories: 2=BUCKET, 3=RESOURCE, 4=BLOCK, 5=OBJECT, 8=VEHICLE
		if category in [2, 3, 4, 5, 8]:
			_play_collect_pose()
			return
	_try_play_idle()

func _on_item_changed(_slot: int, item: Dictionary) -> void:
	var category = item.get("category", 0)
	# Show arms for placeable/usable items: NONE, BUCKET, RESOURCE, BLOCK, OBJECT, VEHICLE
	var should_show = (category in [0, 2, 3, 4, 5, 8]) # 0=NONE, 2=BUCKET, 3=RESOURCE, 4=BLOCK, 5=OBJECT, 8=VEHICLE
	
	# CRITICAL: Reset punch state when switching items to prevent stuck state
	is_punching = false
	punch_cooldown = 0.0
	
	if arms_mesh:
		arms_mesh.visible = should_show
		if should_show and anim_player:
			# Use Collect_something pose for all placeable items, idle for fists
			if category in [2, 3, 4, 5, 8]:
				_play_collect_pose()
			else:
				_try_play_idle()


func set_arms_visible(visible: bool) -> void:
	if arms_mesh:
		arms_mesh.visible = visible
		if visible:
			_try_play_idle()
