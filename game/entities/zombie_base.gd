extends EntityBase
class_name ZombieBase
## Zombie enemy entity with chase/attack AI, animations, and sounds
## Based on old reference patterns - uses time-slice animation looping

# --- Health ---
@export var max_health: int = 20
var current_health: int

# --- State ---
var current_state: String = "IDLE"
var attack_timer: float = 0.0
var stuck_timer: float = 0.0
var hit_anim_variant: int = 0
var chase_anim_variant: int = 0 # 0 = Run, 1 = Calm Walk Alerted

# --- Movement (overrides EntityBase) ---
@export var chase_speed_multiplier: float = 2.5
@export var detection_radius: float = 20.0
@export var attack_range: float = 1.5
@export var lose_interest_range: float = 50.0
@export var attack_cooldown: float = 1.0
@export var attack_damage: int = 1

# --- References ---
var anim_player: AnimationPlayer = null
var wall_detector: RayCast3D = null

# --- Sound ---
const CHASE_SOUND = preload("res://game/sound/zombie-sound-2-357976.mp3")
const HIT_SOUND = preload("res://game/sound/player-hitting-zombie/blade-piercing-body-352462.mp3")
var chase_audio_player: AudioStreamPlayer3D = null
var hit_audio_player: AudioStreamPlayer3D = null

# --- Player reference ---
var player: Node3D = null

signal zombie_died(zombie: ZombieBase)
signal zombie_attacked(target: Node3D)

func _ready():
	super._ready()
	
	# Disable EntityBase wander - we handle movement ourselves
	wander_enabled = false
	
	# Initialize health
	current_health = max_health
	
	# Add to zombies group
	add_to_group("zombies")
	add_to_group("enemies")
	
	# Find AnimationPlayer in the model
	_find_animation_player(self)
	
	# Setup animation if found
	if anim_player:
		DebugManager.log_entities("Zombie: Found AnimationPlayer with animations: %s" % [anim_player.get_animation_list()])
		if anim_player.has_animation("Take 001"):
			anim_player.play("Take 001")
			anim_player.get_animation("Take 001").loop_mode = Animation.LOOP_NONE
		anim_player.callback_mode_process = AnimationPlayer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	else:
		DebugManager.log_entities("Zombie: No AnimationPlayer found - will work without animations")
	
	# Setup chase sound
	chase_audio_player = AudioStreamPlayer3D.new()
	add_child(chase_audio_player)
	chase_audio_player.stream = CHASE_SOUND
	chase_audio_player.volume_db = -5.0
	chase_audio_player.max_distance = 20.0
	chase_audio_player.autoplay = false
	
	# Setup hit sound
	hit_audio_player = AudioStreamPlayer3D.new()
	add_child(hit_audio_player)
	hit_audio_player.stream = HIT_SOUND
	hit_audio_player.volume_db = -2.0
	hit_audio_player.max_distance = 15.0
	
	# Setup wall detector
	wall_detector = RayCast3D.new()
	wall_detector.name = "WallDetector"
	add_child(wall_detector)
	wall_detector.position = Vector3(0, 1.0, 0.6)
	wall_detector.enabled = true
	wall_detector.target_position = Vector3(0, 0, 1.0)
	
	# Collision settings (low safe_margin to minimize floating gap)
	# Collision settings (low safe_margin to minimize floating gap)
	safe_margin = 0.04
	wall_min_slide_angle = deg_to_rad(15)
	floor_max_angle = deg_to_rad(60)
	
	# Speed adjustments requested by user:
	move_speed = 1.5
	chase_speed_multiplier = 2.4
	
	# Safety start - wait for physics to settle
	# Pause animation during this time to prevent drift
	set_physics_process(false)
	if anim_player:
		anim_player.pause()
	await get_tree().create_timer(0.3).timeout
	set_physics_process(true)
	if anim_player:
		anim_player.play("Take 001")
	
	change_state("IDLE")

func _find_animation_player(node: Node):
	if node is AnimationPlayer:
		anim_player = node
		return
	for child in node.get_children():
		if anim_player:
			return
		_find_animation_player(child)

func _physics_process(delta):
	PerformanceMonitor.start_measure("Zombie AI")
	if current_state == "DEAD":
		PerformanceMonitor.end_measure("Zombie AI", 0.5)
		return
	
	# Find player if needed
	if not player or not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player")
	
	# Apply gravity (from EntityBase pattern)
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = -0.1
		# Step-up logic - hop when hitting walls while moving
		if is_on_wall() and velocity.length() > 0.5:
			velocity.y = 4.0
	
	# Animation time-slice looping
	_update_animation()
	
	# State machine
	match current_state:
		"IDLE":
			_process_idle(delta)
		"WALK":
			_process_walk(delta)
		"CHASE":
			_process_chase(delta)
		"ATTACK":
			_process_attack(delta)
		"HIT":
			_process_hit(delta)
	
	move_and_slide()
	
	# Fall-through-terrain safety: if we fall below reasonable terrain level,
	# freeze ourselves instead of teleporting (which causes sky-falling issue)
	if global_position.y < -10:
		set_physics_process(false)
		if anim_player:
			anim_player.pause() # Stop animation drift during freeze
		velocity = Vector3.ZERO
		# Don't teleport to Y=50 - that causes sky falling
		# EntityManager will respawn us at correct height
	PerformanceMonitor.end_measure("Zombie AI", 0.5)

func _update_animation():
	if not anim_player:
		return
		
	# Ensure animation is playing
	if not anim_player.is_playing():
		anim_player.play("Take 001")
	
	var t = anim_player.current_animation_position
	
	# Safety: if animation drifted past valid ranges (e.g., was playing while paused),
	# reset it to the correct position for current state
	if t > 13.0: # Animation is way past any valid state range
		match current_state:
			"IDLE":
				anim_player.seek(0.0)
				return
			"WALK":
				anim_player.seek(1.0)
				return
			"CHASE":
				anim_player.seek(11.6 if chase_anim_variant == 0 else 2.07, true)
				return
			"ATTACK":
				anim_player.seek(3.5)
				return
			"HIT":
				anim_player.seek(4.5 if hit_anim_variant == 0 else 5.2)
				return
			# DEAD state doesn't need reset - it's meant to stay at death pose
	
	match current_state:
		"IDLE":
			if t >= 1.0:
				anim_player.seek(t - 1.0)
		"WALK":
			# Walk: 1.0s to 2.0s
			if t < 1.0 or t >= 2.0:
				anim_player.seek(1.0 + fmod(t - 1.0, 1.0) if t >= 2.0 else 1.0)
		"CHASE":
			if chase_anim_variant == 0:
				# Run: 11.6s to 12.3s
				if t < 11.6 or t >= 12.3:
					anim_player.seek(11.6 + fmod(t - 11.6, 0.7) if t >= 12.3 else 11.6, true)
			else:
				# Calm Walk Alerted: 2.07s to 3.0s
				if t < 2.07 or t >= 3.0:
					anim_player.seek(2.07 + fmod(t - 2.07, 0.93) if t >= 3.0 else 2.07)
		"ATTACK":
			if t < 3.5 or t >= 4.5:
				anim_player.seek(3.5 + fmod(t - 3.5, 1.0) if t >= 4.5 else 3.5)
		"HIT":
			# Variant 0: 4.5s to 5.2s
			# Variant 1: 5.2s to 5.9s
			# Hit animations don't loop, they exit state when done. 
			# But we clamp here just in case.
			if hit_anim_variant == 0:
				if t < 4.5: anim_player.seek(4.5)
			else:
				if t < 5.2: anim_player.seek(5.2)

func _process_idle(delta):
	# Friction when idle
	velocity.x = move_toward(velocity.x, 0, 10.0 * delta)
	velocity.z = move_toward(velocity.z, 0, 10.0 * delta)
	
	# Wander timer (reuse from EntityBase)
	wander_timer -= delta
	if wander_timer <= 0:
		_pick_random_direction()
		change_state("WALK")
	
	# Check for player
	if player and _can_see_player():
		var dist = global_position.distance_to(player.global_position)
		if dist < detection_radius:
			change_state("CHASE")

func _process_walk(delta):
	# Move forward
	var forward_dir = - transform.basis.z.normalized()
	velocity.x = forward_dir.x * move_speed
	velocity.z = forward_dir.z * move_speed
	
	wander_timer -= delta
	
	# Check for walls or timer expiring
	if (wall_detector and wall_detector.is_colliding()) or wander_timer <= 0:
		change_state("IDLE")
	
	# Check for player
	if player and _can_see_player():
		var dist = global_position.distance_to(player.global_position)
		if dist < detection_radius:
			change_state("CHASE")

func _process_chase(delta):
	if not player:
		change_state("IDLE")
		return
	
	var dist = global_position.distance_to(player.global_position)
	
	if dist > lose_interest_range:
		change_state("IDLE")
	elif dist < attack_range:
		change_state("ATTACK")
	else:
		# Face player (only if not at same position)
		var look_pos = Vector3(player.global_position.x, global_position.y, player.global_position.z)
		if global_position.distance_to(look_pos) > 0.01:
			look_at(look_pos, Vector3.UP)
		
		# Move toward player at increased speed
		var dir = (player.global_position - global_position).normalized()
		
		# Apply speed based on variant (Calm Alerted is 60% slower)
		var current_speed_mult = chase_speed_multiplier
		if chase_anim_variant == 1:
			current_speed_mult *= 0.4
			
		velocity.x = dir.x * move_speed * current_speed_mult
		velocity.z = dir.z * move_speed * current_speed_mult

func _process_attack(delta):
	if not player:
		change_state("IDLE")
		return
	
	var dist = global_position.distance_to(player.global_position)
	
	if dist > attack_range + 1.0:
		change_state("CHASE")
	else:
		# Face player (only if not at same position)
		var look_pos = Vector3(player.global_position.x, global_position.y, player.global_position.z)
		if global_position.distance_to(look_pos) > 0.01:
			look_at(look_pos, Vector3.UP)
		velocity.x = 0
		velocity.z = 0
		
		# Attack on cooldown
		attack_timer -= delta
		if attack_timer <= 0:
			_do_attack()
			attack_timer = attack_cooldown

func _do_attack():
	if not player:
		return
	
	DebugManager.log_entities("Zombie attacked player!")
	zombie_attacked.emit(player)
	
	if player.has_method("take_damage"):
		player.take_damage(attack_damage)

func _process_hit(delta):
	# Apply friction
	velocity.x = move_toward(velocity.x, 0, 5.0 * delta)
	velocity.z = move_toward(velocity.z, 0, 5.0 * delta)
	
	if not anim_player:
		change_state("CHASE")
		return

	var t = anim_player.current_animation_position
	var finished = false
	
	if hit_anim_variant == 0:
		if t >= 5.2: finished = true
	else:
		if t >= 5.9: finished = true
		
	if finished:
		change_state("CHASE")

func _can_see_player() -> bool:
	# Simple check - could add raycast for line of sight
	return player != null and is_instance_valid(player)

func _pick_random_direction():
	rotate_y(deg_to_rad(randf_range(90, 270)))

func change_state(new_state: String):
	if current_state == "DEAD":
		return
		
	if current_state == new_state:
		return
	
	var old_state = current_state
	current_state = new_state
	
	# Handle sound
	if new_state == "CHASE":
		if chase_audio_player and not chase_audio_player.playing:
			chase_audio_player.play()
	else:
		if chase_audio_player and chase_audio_player.playing:
			chase_audio_player.stop()
	
	# Handle animation seek
	if anim_player:
		match new_state:
			"IDLE":
				anim_player.seek(0.0)
			"WALK":
				anim_player.seek(1.0)
			"CHASE":
				chase_anim_variant = randi() % 2
				anim_player.seek(11.6 if chase_anim_variant == 0 else 2.07, true)
			"ATTACK":
				anim_player.seek(3.5)
			"HIT":
				anim_player.seek(4.5 if hit_anim_variant == 0 else 5.2)
	
	# Set timers
	match new_state:
		"IDLE":
			wander_timer = randf_range(2.0, 4.0)
		"WALK":
			wander_timer = randf_range(3.0, 6.0)

## Force zombie to start chasing (called externally)
func start_chase():
	if current_state != "DEAD":
		change_state("CHASE")

# --- DAMAGE SYSTEM ---
func take_damage(amount: int, source: String = "generic"):
	if current_state == "DEAD":
		return
	
	current_health -= amount
	DebugManager.log_entities("Zombie took %d damage! HP: %d/%d" % [amount, current_health, max_health])
	
	if hit_audio_player and source != "pistol":
		hit_audio_player.pitch_scale = randf_range(0.9, 1.1)
		hit_audio_player.play()
	
	if current_health <= 0:
		die()
	else:
		# If user wanted hit reaction with physical impulse (e.g. shot), we'd need active ragdoll.
		# For now, sticking to animation hit reaction but keeping structure open.

		# Random hit reaction
		hit_anim_variant = randi() % 2
		
		# If already hit, we might want to restart animation or just let it play.
		# Choosing to restart for better responsiveness.
		if current_state == "HIT":
			if anim_player:
				anim_player.seek(4.5 if hit_anim_variant == 0 else 5.2)
		else:
			change_state("HIT")

func die():
	change_state("DEAD")
	DebugManager.log_entities("Zombie died!")
	zombie_died.emit(self)
	velocity = Vector3.ZERO
	
	# Disable collision
	var col = get_node_or_null("CollisionShape3D")
	if col:
		col.disabled = true
	
	# Start ragdoll
	var skeleton = get_node_or_null("ZombieModel/Armature/Skeleton3D")
	if skeleton:
		# Use physical bones if available
		anim_player.stop()
		skeleton.physical_bones_start_simulation()
	else:
		# Fallback to animation if no skeleton found
		if anim_player and anim_player.has_animation("Take 001"):
			anim_player.play("Take 001")
			anim_player.seek(9.5, true)
			
			await get_tree().create_timer(0.9).timeout
			anim_player.pause()
	
	# Disappear after delay
	await get_tree().create_timer(5.0).timeout
	queue_free()

func apply_hit_impulse(impulse: Vector3, position: Vector3):
	var skeleton = get_node_or_null("ZombieModel/Armature/Skeleton3D")
	if skeleton:
		# Note: This only works if physical bones are active. 
		# For "Active Ragdoll" hit reaction without full ragdoll, 
		# we would need partial simulation which is complex.
		# For now, this is useful if we transition to ragdoll on death.
		pass


## Override EntityBase on_spawn
func on_spawn(manager: Node3D):
	super.on_spawn(manager)
	current_health = max_health
	change_state("IDLE")

## Override EntityBase on_despawn  
func on_despawn():
	super.on_despawn()
	if chase_audio_player and chase_audio_player.playing:
		chase_audio_player.stop()
