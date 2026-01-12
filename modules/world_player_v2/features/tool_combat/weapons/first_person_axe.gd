extends Node
class_name FirstPersonAxeV2
## FirstPersonAxe - Handles first-person axe visuals
## Shows axe when equipped, plays animations on attack

const AXE_SCENE_PATH: String = "res://game/assets/player_axe/1/animated_fps_axe.glb"
const SWAY_AMOUNT: float = 0.002
const SWAY_SMOOTHING: float = 10.0
const BOB_FREQ: float = 10.0
const BOB_AMP: float = 0.01
const ATTACK_SOUND_PATH: String = "res://game/sound/player-weapon-tool-swing/item-swing-sfx-2-409076.mp3"

@export var axe_scale: Vector3 = Vector3(0.6, 0.6, 0.6)
@export var axe_position: Vector3 = Vector3(0.215, -0.785, -0.015)
@export var axe_rotation: Vector3 = Vector3(0.0, 195.14, 0.0)

var player: CharacterBody3D = null
var camera: Camera3D = null
var hand_holder: Node3D = null
var axe_mesh: Node3D = null
var anim_player: AnimationPlayer = null
var audio_player: AudioStreamPlayer3D = null

var mouse_input: Vector2 = Vector2.ZERO
var sway_time: float = 0.0
var is_attacking: bool = false
var cooldown: float = 0.0
const ATTACK_COOLDOWN: float = 0.3

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("FirstPersonAxe: Must be child of Player/Components node")
		return
	
	camera = player.get_node_or_null("Camera3D")
	if not camera:
		push_error("FirstPersonAxe: Camera3D not found")
		return
	
	call_deferred("_setup_deferred")
	
	if has_node("/root/PlayerSignals"):
		PlayerSignals.item_changed.connect(_on_item_changed)
		PlayerSignals.axe_fired.connect(_on_axe_fired)

func _setup_deferred() -> void:
	_setup_axe_holder()
	_load_axe_model()
	_setup_audio()

func _setup_axe_holder() -> void:
	hand_holder = Node3D.new()
	hand_holder.name = "AxeHolder"
	camera.add_child(hand_holder)

func _load_axe_model() -> void:
	if not ResourceLoader.exists(AXE_SCENE_PATH):
		return
	
	var scene = load(AXE_SCENE_PATH)
	if not scene:
		return
	
	axe_mesh = scene.instantiate()
	hand_holder.add_child(axe_mesh)
	
	axe_mesh.scale = axe_scale
	axe_mesh.position = axe_position
	axe_mesh.rotation_degrees = axe_rotation
	axe_mesh.visible = false
	
	anim_player = _find_anim_player(axe_mesh)

func _setup_audio() -> void:
	if not ResourceLoader.exists(ATTACK_SOUND_PATH):
		return
	
	var stream = load(ATTACK_SOUND_PATH)
	if stream:
		audio_player = AudioStreamPlayer3D.new()
		audio_player.name = "AxeAudio"
		audio_player.stream = stream
		player.add_child(audio_player)

func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found = _find_anim_player(child)
		if found:
			return found
	return null

func _process(delta: float) -> void:
	if not axe_mesh or not axe_mesh.visible:
		return
	
	if cooldown > 0:
		cooldown -= delta
	
	axe_mesh.scale = axe_scale
	axe_mesh.position = axe_position
	axe_mesh.rotation_degrees = axe_rotation
	
	_update_sway_and_bob(delta)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_input = event.relative

func _update_sway_and_bob(delta: float) -> void:
	if not hand_holder:
		return
	
	var target_sway = Vector3(
		-mouse_input.x * SWAY_AMOUNT,
		mouse_input.y * SWAY_AMOUNT,
		0
	)
	
	var bob_offset = Vector3.ZERO
	if player.is_on_floor() and player.velocity.length() > 1.0:
		sway_time += delta
		bob_offset.y = sin(sway_time * BOB_FREQ) * BOB_AMP
		bob_offset.x = cos(sway_time * BOB_FREQ * 2.0) * BOB_AMP * 0.5
	
	var total_target = target_sway + bob_offset
	hand_holder.position = hand_holder.position.lerp(total_target, delta * SWAY_SMOOTHING)
	
	mouse_input = Vector2.ZERO

func _on_axe_fired() -> void:
	# Only respond if axe is currently visible
	if axe_mesh and axe_mesh.visible:
		_try_attack()

func _return_to_ready() -> void:
	is_attacking = false
	_try_play_idle()
	if has_node("/root/PlayerSignals"):
		PlayerSignals.axe_ready.emit()

func _try_attack() -> void:
	if cooldown > 0 or is_attacking:
		return
	
	cooldown = ATTACK_COOLDOWN
	is_attacking = true
	
	if audio_player and audio_player.is_inside_tree():
		audio_player.pitch_scale = randf_range(0.9, 1.1)
		audio_player.play()
	
	if anim_player:
		var anims = anim_player.get_animation_list()
		var attack_anim = ""
		
		for a in anims:
			if "attack" in a.to_lower() or "swing" in a.to_lower() or "hit" in a.to_lower():
				attack_anim = a
				break
		
		if attack_anim == "" and anims.size() > 0:
			attack_anim = anims[0]
		
		if attack_anim != "":
			anim_player.stop()
			anim_player.play(attack_anim)
			if not anim_player.animation_finished.is_connected(_on_anim_finished):
				anim_player.animation_finished.connect(_on_anim_finished, CONNECT_ONE_SHOT)
		else:
			get_tree().create_timer(ATTACK_COOLDOWN).timeout.connect(_return_to_ready)
	else:
		get_tree().create_timer(ATTACK_COOLDOWN).timeout.connect(_return_to_ready)

func _on_anim_finished(_anim_name: String) -> void:
	_return_to_ready()

func _try_play_idle() -> void:
	if not anim_player:
		return
	
	for a in anim_player.get_animation_list():
		if "idle" in a.to_lower():
			anim_player.play(a)
			return

func _on_item_changed(_slot: int, item: Dictionary) -> void:
	var item_id = item.get("id", "")
	var should_show = "axe" in item_id and not "pickaxe" in item_id
	
	if axe_mesh:
		axe_mesh.visible = should_show
		if should_show:
			_try_play_idle()
