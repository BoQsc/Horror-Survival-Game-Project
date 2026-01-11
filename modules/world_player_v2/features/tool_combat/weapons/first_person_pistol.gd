extends Node
class_name FirstPersonPistolV2
## FirstPersonPistol - Handles first-person pistol visuals with sway, bobbing, shooting animation
## Shows pistol when equipped, hides when other items selected.

const PISTOL_SOUND = preload("res://game/sound/pistol-shot-233473.mp3")
const RELOAD_SOUND = preload("res://game/sound/mag-reload-81594.mp3")
const PISTOL_SCENE_PATH = "res://models/pistol/heavy_pistol_animated.glb"

@export var sway_amount: float = 0.002
@export var sway_smoothing: float = 10.0
@export var bob_freq: float = 10.0
@export var bob_amp: float = 0.01

@export var ads_origin: Vector3 = Vector3(0.002, -0.06, -0.19)
@export var ads_rotation: Vector3 = Vector3(-0.955, 180.735, 0.0)

@export var pistol_scale: Vector3 = Vector3(0.005, 0.005, 0.005)
@export var pistol_position: Vector3 = Vector3(0.093, -0.094, -0.155)
@export var pistol_rotation: Vector3 = Vector3(0, 170, 0)

var player: CharacterBody3D = null
var camera: Camera3D = null
var hand_holder: Node3D = null
var pistol_mesh: Node3D = null
var anim_player: AnimationPlayer = null
var shot_player: AudioStreamPlayer3D = null
var reload_player: AudioStreamPlayer3D = null

var pistol_origin: Vector3 = Vector3.ZERO
var mouse_input: Vector2 = Vector2.ZERO
var sway_time: float = 0.0
var is_aiming: bool = false
var is_reloading: bool = false
var should_show_pending: bool = false

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("FirstPersonPistol: Must be child of Player/Components node")
		return
	
	camera = player.get_node_or_null("Camera3D")
	if not camera:
		push_error("FirstPersonPistol: Could not find Camera3D")
		return
	
	call_deferred("_setup_pistol")
	
	if has_node("/root/PlayerSignals"):
		PlayerSignals.item_changed.connect(_on_item_changed)
		PlayerSignals.pistol_fired.connect(_on_pistol_fired)
		PlayerSignals.pistol_reload.connect(_on_pistol_reload)

func _setup_pistol() -> void:
	hand_holder = Node3D.new()
	hand_holder.name = "PistolHolder"
	camera.add_child(hand_holder)
	
	if ResourceLoader.exists(PISTOL_SCENE_PATH):
		var pistol_scene = load(PISTOL_SCENE_PATH)
		if pistol_scene:
			pistol_mesh = pistol_scene.instantiate()
			hand_holder.add_child(pistol_mesh)
			
			pistol_mesh.scale = pistol_scale
			pistol_mesh.position = pistol_position
			pistol_mesh.rotation_degrees = pistol_rotation
			
			pistol_origin = pistol_position
			
			anim_player = _find_anim_player(pistol_mesh)
	
	shot_player = AudioStreamPlayer3D.new()
	shot_player.name = "PistolShotAudio"
	shot_player.stream = PISTOL_SOUND
	shot_player.max_polyphony = 10
	player.add_child(shot_player)
	
	reload_player = AudioStreamPlayer3D.new()
	reload_player.name = "PistolReloadAudio"
	reload_player.stream = RELOAD_SOUND
	player.add_child(reload_player)
	
	if not should_show_pending:
		var hotbar = player.get_node_or_null("Systems/Hotbar")
		if hotbar and hotbar.has_method("get_selected_item"):
			var item = hotbar.get_selected_item()
			if item.get("id", "") == "heavy_pistol":
				should_show_pending = true
	
	if pistol_mesh:
		pistol_mesh.visible = should_show_pending

func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found = _find_anim_player(child)
		if found:
			return found
	return null

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_input = event.relative
	
	if event is InputEventKey and event.pressed and event.keycode == KEY_R:
		if pistol_mesh and pistol_mesh.visible and not is_reloading:
			if has_node("/root/PlayerSignals"):
				PlayerSignals.pistol_reload.emit()

func _process(delta: float) -> void:
	if not pistol_mesh or not pistol_mesh.visible:
		return
	
	is_aiming = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
	
	_update_sway_and_bob(delta)

func _update_sway_and_bob(delta: float) -> void:
	if not hand_holder:
		return
	
	var current_sway = sway_amount * (0.1 if is_aiming else 1.0)
	var current_bob = bob_amp * (0.1 if is_aiming else 1.0)
	
	var target_pos = ads_origin if is_aiming else pistol_origin
	var target_rot = ads_rotation if is_aiming else pistol_rotation
	
	var target_sway = Vector3(
		-mouse_input.x * current_sway,
		mouse_input.y * current_sway,
		0
	)
	
	var bob_offset = Vector3.ZERO
	if player.is_on_floor() and player.velocity.length() > 1.0:
		sway_time += delta
		bob_offset.y = sin(sway_time * bob_freq) * current_bob
		bob_offset.x = cos(sway_time * bob_freq * 2.0) * current_bob * 0.5
	
	var total_target = target_sway + bob_offset
	hand_holder.position = hand_holder.position.lerp(total_target, delta * sway_smoothing)
	
	var smooth_speed = 20.0 if is_aiming else sway_smoothing
	pistol_mesh.position = pistol_mesh.position.lerp(target_pos, delta * smooth_speed)
	pistol_mesh.rotation_degrees = pistol_mesh.rotation_degrees.lerp(target_rot, delta * smooth_speed)
	
	mouse_input = Vector2.ZERO

func _on_item_changed(_slot: int, item: Dictionary) -> void:
	var item_id = item.get("id", "")
	var should_show = (item_id == "heavy_pistol")
	should_show_pending = should_show
	
	if pistol_mesh:
		pistol_mesh.visible = should_show

func _on_pistol_fired() -> void:
	if not shot_player:
		return
	
	shot_player.play()
	_play_shoot_animation()

func _play_shoot_animation() -> void:
	if not anim_player:
		await get_tree().create_timer(0.1).timeout
		if has_node("/root/PlayerSignals"):
			PlayerSignals.pistol_fire_ready.emit()
		return
	
	var anim_name = ""
	for name in anim_player.get_animation_list():
		if "allanim" in name.to_lower() or "shoot" in name.to_lower():
			anim_name = name
			break
	
	if anim_name == "":
		await get_tree().create_timer(0.1).timeout
		if has_node("/root/PlayerSignals"):
			PlayerSignals.pistol_fire_ready.emit()
		return
	
	anim_player.stop()
	anim_player.play(anim_name)
	
	await get_tree().create_timer(0.4).timeout
	
	if is_instance_valid(anim_player) and not is_reloading:
		anim_player.stop()
	
	if has_node("/root/PlayerSignals"):
		PlayerSignals.pistol_fire_ready.emit()

func _on_pistol_reload() -> void:
	if is_reloading or not reload_player:
		return
	
	is_reloading = true
	reload_player.play()
	
	if anim_player:
		_play_reload_animation()
	else:
		await get_tree().create_timer(2.45).timeout
		is_reloading = false

func _play_reload_animation() -> void:
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
	anim_player.seek(0.4, true)
	
	await get_tree().create_timer(2.45).timeout
	
	if is_instance_valid(anim_player):
		anim_player.stop()
	
	is_reloading = false
