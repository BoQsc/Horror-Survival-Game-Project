extends CharacterBody3D

class_name PlayerController

# Configuration
const WALK_SPEED = 5.0
const SPRINT_SPEED = 8.0 # Added Sprint
const SWIM_SPEED = 4.0
const FLY_SPEED = 15.0
const JUMP_VELOCITY = 4.5
const GRAVITY_MULTIPLIER = 1.0

# Sway & Bobbing Settings
const SWAY_AMOUNT = 0.002 # How much mouse movement affects position
const SWAY_SMOOTHING = 10.0 # How fast it returns to center
const BOB_FREQ = 10.0 # Speed of walking bob
const BOB_AMP = 0.01 # Distance of walking bob

# ADS Settings
@export var ads_origin: Vector3 = Vector3(0.002, -0.06, -0.19)
@export var ads_rotation: Vector3 = Vector3(-0.955, 180.735, 0.0)
@export var debug_keep_aim: bool = false

# Health Settings
var health: int = 10
var max_health: int = 10

# Dependencies
@onready var camera: Camera3D = $Camera3D
# We expect TerrainManager to be in the scene. 
# In the new structure, we might want to find it more robustly or use a global reference.
# For now, we search relative or via group.
var terrain_manager: Node = null

# Visual References (populate via scene or code)
@onready var hand_holder: Node3D = $Camera3D/HandHolder
@onready var hands_mesh: Node3D = null # Set dynamically
@onready var weapon_mesh: Node3D = null # Set dynamically
@onready var block_mesh: MeshInstance3D = null # Set dynamically
@onready var punch_sfx: AudioStreamPlayer3D = null # Set dynamically

# Visual State
var hands_origin: Vector3 = Vector3.ZERO
var weapon_origin: Vector3 = Vector3.ZERO
var weapon_initial_rotation: Vector3 = Vector3.ZERO
var block_origin: Vector3 = Vector3.ZERO
var mouse_input: Vector2 = Vector2.ZERO
var sway_time: float = 0.0
var current_slot: int = 3 # 0=weapon, 1=block, 2=ramp, 3=hands (default to hands)

# Punch SFX resource path (loaded at runtime to avoid import dependency)
var PUNCH_SFX_PATH: String = "res://game/assets/classic-punch-impact-352711.mp3"

# State
enum State {IDLE, WALK, SPRINT, AIR, SWIM, FLY}
var current_state: State = State.IDLE
var is_flying_toggle: bool = false

# System
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

func _ready() -> void:
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if not terrain_manager:
		printerr("PlayerController: TerrainManager not found!")
	
	# Initialize visual node references if HandHolder exists
	if hand_holder:
		hands_origin = hand_holder.position
		# Try to find child nodes by name pattern
		for child in hand_holder.get_children():
			if "hand" in child.name.to_lower() or "arm" in child.name.to_lower():
				hands_mesh = child
				hands_origin = child.position
			elif "weapon" in child.name.to_lower() or "pistol" in child.name.to_lower():
				weapon_mesh = child
				weapon_origin = child.position
				if child is Node3D:
					weapon_initial_rotation = child.rotation_degrees
			elif "block" in child.name.to_lower():
				block_mesh = child
				block_origin = child.position
			elif child is AudioStreamPlayer3D and "punch" in child.name.to_lower():
				punch_sfx = child
		
		# Dynamically load hands model if not found
		if not hands_mesh:
			var hands_path = "res://game/assets/psx_first_person_arms.glb"
			if ResourceLoader.exists(hands_path):
				var hands_scene = load(hands_path)
				if hands_scene:
					hands_mesh = hands_scene.instantiate()
					hands_mesh.name = "HandsMesh"
					hands_mesh.scale = Vector3(0.15, 0.15, 0.15)
					hands_mesh.position = Vector3(-0.025, -0.45, -0.15) # Matched to original project
					hands_mesh.rotation_degrees = Vector3(0, 177, 0) # Face camera
					hands_mesh.visible = true
					hand_holder.add_child(hands_mesh)
					hands_origin = hands_mesh.position
					print("PlayerController: Dynamically loaded hands model")
					# Set camera near clip to allow hands to render close (like original)
					if camera:
						camera.near = 0.04
			else:
				print("PlayerController: Hands model not found at ", hands_path)
	
	# Ensure hands are visible by default (no weapon equipped initially)
	if hands_mesh:
		hands_mesh.visible = true
	
	# Create punch SFX if not found but path is valid
	if not punch_sfx and ResourceLoader.exists(PUNCH_SFX_PATH):
		punch_sfx = AudioStreamPlayer3D.new()
		add_child(punch_sfx)
		punch_sfx.stream = load(PUNCH_SFX_PATH)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F:
		toggle_flight_mode()

func _unhandled_input(event: InputEvent) -> void:
	# Capture mouse motion for weapon sway
	if event is InputEventMouseMotion:
		mouse_input = event.relative

func _process(delta: float) -> void:
	handle_weapon_sway(delta)
	handle_hands_actions(delta)

func _physics_process(delta: float) -> void:
	update_state_logic(delta)
	move_and_slide()

func update_state_logic(delta: float) -> void:
	# 1. Check Environmental Conditions (Water)
	var in_water = check_water_immersion()
	
	# 2. Determine State Transition
	if is_flying_toggle:
		set_state(State.FLY)
	elif in_water:
		set_state(State.SWIM)
	else:
		if is_on_floor():
			if Input.is_action_pressed("move_forward") or Input.is_action_pressed("move_backward") or \
			   Input.is_action_pressed("move_left") or Input.is_action_pressed("move_right"):
				if Input.is_key_pressed(KEY_SHIFT):
					set_state(State.SPRINT)
				else:
					set_state(State.WALK)
			else:
				set_state(State.IDLE)
		else:
			set_state(State.AIR)

	# 3. Apply Forces/Velocity based on State
	match current_state:
		State.IDLE:
			process_ground_movement(delta, 0.0)
		State.WALK:
			process_ground_movement(delta, WALK_SPEED)
		State.SPRINT:
			process_ground_movement(delta, SPRINT_SPEED)
		State.AIR:
			process_air_movement(delta)
		State.SWIM:
			process_swim_movement(delta)
		State.FLY:
			process_fly_movement(delta)

func set_state(new_state: State) -> void:
	if current_state == new_state:
		return
	
	# Exit logic (if any)
	if current_state == State.SWIM and new_state == State.AIR:
		# Jump out of water boost
		if Input.is_action_pressed("ui_accept"):
			velocity.y = JUMP_VELOCITY
			
	if current_state == State.SWIM and new_state != State.SWIM:
		# Reset any water drag if needed?
		pass
		
	# Enter logic (if any)
	if new_state == State.SWIM and current_state != State.SWIM:
		velocity.y *= 0.1 # Dampen entry impact
		
	current_state = new_state

# --- Environmental Checks ---
func check_water_immersion() -> bool:
	if not terrain_manager:
		return false
		
	# Physics CoM approximation
	var center_pos = global_position + Vector3(0, 0.9, 0)
	var body_density = terrain_manager.get_water_density(center_pos)
	
	# Update Camera Underwater Effect
	if camera:
		var cam_check_pos = camera.global_position - Vector3(0, 0.5, 0)
		var cam_density = terrain_manager.get_water_density(cam_check_pos)
		var ui = get_node_or_null("../UI/UnderwaterEffect")
		if ui:
			ui.visible = cam_density < 0.0
			
	return body_density < 0.0

# --- Movement Processors ---
func process_ground_movement(delta: float, speed: float) -> void:
	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * GRAVITY_MULTIPLIER * delta
		
	# Jump
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY
		# Prevent immediate snap back to ground
		set_state(State.AIR)
		return

	# Friction/Movement
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

func process_air_movement(delta: float) -> void:
	# Gravity
	velocity.y -= gravity * GRAVITY_MULTIPLIER * delta
	
	# Air Control (Usually less than ground, but we'll keep it responsive for now)
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		velocity.x = move_toward(velocity.x, direction.x * WALK_SPEED, WALK_SPEED * delta * 2.0)
		velocity.z = move_toward(velocity.z, direction.z * WALK_SPEED, WALK_SPEED * delta * 2.0)

func process_swim_movement(delta: float) -> void:
	# Buoyancy / Drag
	velocity = velocity.move_toward(Vector3.ZERO, 2.0 * delta)
	
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	# Swim in camera direction
	var cam_basis = camera.global_transform.basis
	var direction = (cam_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		velocity += direction * SWIM_SPEED * delta * 5.0
		if velocity.length() > SWIM_SPEED:
			velocity = velocity.normalized() * SWIM_SPEED
			
	# Surface logic
	if Input.is_action_pressed("ui_accept"):
		velocity.y += 5.0 * delta

func process_fly_movement(_delta: float) -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var cam_basis = camera.global_transform.basis
	var direction = (cam_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	velocity = Vector3.ZERO
	if direction:
		velocity = direction * FLY_SPEED
		
	if Input.is_action_pressed("ui_accept"):
		velocity.y = FLY_SPEED
	if Input.is_key_pressed(KEY_SHIFT):
		velocity.y = - FLY_SPEED

func toggle_flight_mode() -> void:
	is_flying_toggle = !is_flying_toggle
	print("Fly mode: ", "ON" if is_flying_toggle else "OFF")

# Hooks for interaction raycast?
# The interaction controller is typically a child node scanning where the camera looks.
# We can expose the viewing direction or camera easily if needed.
func get_view_basis() -> Basis:
	return camera.global_transform.basis

# --- Visual Handlers ---
func handle_weapon_sway(delta: float) -> void:
	if not hand_holder:
		return
	
	# Determine Aiming State
	var is_aiming = false
	var target_origin = hands_origin # Default to holder origin
	var target_rotation = Vector3.ZERO
	
	# Check for ADS (Aim Down Sights (Right Click, if slot 0 has a weapon)
	if debug_keep_aim or (current_slot == 0 and weapon_mesh and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)):
		if debug_keep_aim or (not Input.is_key_pressed(KEY_CTRL) and not Input.is_key_pressed(KEY_SHIFT)):
			is_aiming = true
			target_origin = ads_origin
			target_rotation = ads_rotation
	
	# 1. Mouse Sway (Lag)
	var current_sway_amount = SWAY_AMOUNT * 0.1 if is_aiming else SWAY_AMOUNT
	var target_sway = Vector3(
		- mouse_input.x * current_sway_amount,
		mouse_input.y * current_sway_amount,
		0
	)
	
	# 2. Movement Bobbing (only when moving on floor)
	var speed = velocity.length()
	var bob_offset = Vector3.ZERO
	var current_bob_amp = BOB_AMP * 0.1 if is_aiming else BOB_AMP
	
	if is_on_floor() and speed > 1.0:
		sway_time += delta * speed
		bob_offset.y = sin(sway_time * BOB_FREQ * 0.5) * current_bob_amp
		bob_offset.x = cos(sway_time * BOB_FREQ) * current_bob_amp * 0.5
	
	# Combine and apply
	var total_target = target_origin + target_sway + bob_offset
	var smooth_speed = 20.0 if is_aiming else SWAY_SMOOTHING
	
	# Apply to hand holder (affects all children: hands, weapon, block)
	hand_holder.position = hand_holder.position.lerp(total_target, delta * smooth_speed)
	
	# Apply rotation for weapon ADS
	if weapon_mesh and weapon_mesh.visible and is_aiming:
		weapon_mesh.rotation_degrees = weapon_mesh.rotation_degrees.lerp(target_rotation, delta * smooth_speed)
	elif weapon_mesh and weapon_mesh.visible:
		weapon_mesh.rotation_degrees = weapon_mesh.rotation_degrees.lerp(weapon_initial_rotation, delta * smooth_speed)
	
	# Reset mouse input frame-by-frame
	mouse_input = Vector2.ZERO

func handle_hands_actions(_delta: float) -> void:
	if not hands_mesh or not hands_mesh.visible:
		return
	
	var anim_player = hands_mesh.get_node_or_null("AnimationPlayer")
	if not anim_player:
		return
	
	# Punch on left click while hands are visible
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		# Find a punch animation (common naming patterns)
		var punch_anims = ["punch", "attack", "Combat_punch_right", "arms_armature|Combat_punch_right"]
		var current_anim = anim_player.current_animation
		var is_punching = false
		for punch_name in punch_anims:
			if punch_name.to_lower() in current_anim.to_lower():
				is_punching = true
				break
		
		if not is_punching:
			# Try to play a punch animation
			for punch_name in punch_anims:
				for anim_name in anim_player.get_animation_list():
					if punch_name.to_lower() in anim_name.to_lower():
						anim_player.play(anim_name)
						_play_punch_sfx()
						_do_melee_raycast()
						return

func _play_punch_sfx() -> void:
	if punch_sfx:
		punch_sfx.pitch_scale = randf_range(0.9, 1.1)
		punch_sfx.play()

func _do_melee_raycast() -> void:
	# Perform melee hit detection
	var space_state = get_world_3d().direct_space_state
	var center_screen = get_viewport().get_visible_rect().size / 2
	var from = camera.project_ray_origin(center_screen)
	var to = from + camera.project_ray_normal(center_screen) * 2.5 # 2.5m melee range
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space_state.intersect_ray(query)
	
	if result:
		var collider = result.collider
		if collider.is_in_group("zombies") and collider.has_method("take_damage"):
			collider.take_damage(1)
			print("PlayerController: Punched zombie!")
		elif collider.is_in_group("blocks") and collider.has_method("take_damage"):
			collider.take_damage(1)
			print("PlayerController: Punched block!")
		else:
			# Terrain Interaction (Digging)
			if terrain_manager and terrain_manager.has_method("modify_terrain"):
				terrain_manager.modify_terrain(result.position, 1.0, "sphere", 1.0)
				print("PlayerController: Punched terrain!")

# --- Slot / Equipment System ---
func set_equipped_item(item_name: String) -> void:
	# Called externally (e.g., by PlayerInteraction) to switch visual equipment
	match item_name.to_upper():
		"HANDS":
			_on_slot_changed(3)
		"BLOCK":
			_on_slot_changed(1)
		"WEAPON", "PISTOL":
			_on_slot_changed(0)
		_:
			_on_slot_changed(3) # Default to hands

func _on_slot_changed(index: int) -> void:
	current_slot = index
	
	# Hide all first
	if hands_mesh:
		hands_mesh.visible = false
	if weapon_mesh:
		weapon_mesh.visible = false
	if block_mesh:
		block_mesh.visible = false
	
	# Show appropriate mesh
	match index:
		0: # Weapon
			if weapon_mesh:
				weapon_mesh.visible = true
			elif hands_mesh:
				hands_mesh.visible = true # Fallback to hands if no weapon
		1: # Block (Box)
			if block_mesh:
				block_mesh.visible = true
				if block_mesh is MeshInstance3D:
					block_mesh.mesh = BoxMesh.new()
			elif hands_mesh:
				hands_mesh.visible = true
		2: # Ramp (Prism)
			if block_mesh:
				block_mesh.visible = true
				if block_mesh is MeshInstance3D:
					var prism = PrismMesh.new()
					prism.left_to_right = 0.0
					block_mesh.mesh = prism
			elif hands_mesh:
				hands_mesh.visible = true
		3, _: # Hands (default)
			if hands_mesh:
				hands_mesh.visible = true
				var anim_player = hands_mesh.get_node_or_null("AnimationPlayer")
				if anim_player:
					# Try to play idle animation
					for anim_name in anim_player.get_animation_list():
						if "idle" in anim_name.to_lower():
							anim_player.play(anim_name)
							break

# --- Health System ---
func take_damage(amount: int) -> void:
	health -= amount
	print("PlayerController: Took ", amount, " damage. Health: ", health)
	_update_health_ui()
	
	if health <= 0:
		die()

func die() -> void:
	print("PlayerController: Player died! Reloading scene...")
	get_tree().reload_current_scene()

func _update_health_ui() -> void:
	# Try to find a health bar in common UI locations
	var health_bar = get_node_or_null("../UI/HealthBar")
	if not health_bar:
		health_bar = get_node_or_null("/root/GameWorld/UI/HealthBar")
	if not health_bar:
		health_bar = get_node_or_null("/root/World/UI/HealthBar")
	
	if health_bar and health_bar.has_method("set_value"):
		health_bar.set_value(float(health) / float(max_health) * 100.0)
	elif health_bar and "anchor_right" in health_bar:
		# ColorRect style
		health_bar.anchor_right = float(health) / float(max_health)
