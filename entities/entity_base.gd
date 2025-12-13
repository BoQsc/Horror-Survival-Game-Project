extends CharacterBody3D
class_name EntityBase
## Base class for all entities - provides basic movement, physics, and terrain interaction

signal entity_died(entity: EntityBase)

# Movement
@export var move_speed: float = 3.0
@export var gravity: float = 20.0
@export var rotation_speed: float = 5.0

# State
var is_active: bool = true
var entity_manager: Node3D  # Reference to EntityManager

# Target for movement
var target_position: Vector3 = Vector3.ZERO
var has_target: bool = false

# Wander behavior (for testing)
@export var wander_enabled: bool = true
@export var wander_radius: float = 10.0
@export var wander_interval: float = 3.0
var wander_timer: float = 0.0

func _ready():
	# Add to entities group for easy querying
	add_to_group("entities")
	
	# Initialize wander
	if wander_enabled:
		_pick_new_wander_target()

func _physics_process(delta):
	if not is_active:
		return
	
	# Apply gravity
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0
	
	# Process wander behavior
	if wander_enabled:
		_process_wander(delta)
	
	# Move toward target
	if has_target:
		_move_toward_target(delta)
	else:
		# No target - just gravity/friction
		velocity.x = move_toward(velocity.x, 0, delta * 5.0)
		velocity.z = move_toward(velocity.z, 0, delta * 5.0)
	
	move_and_slide()

## Move toward the current target position
func _move_toward_target(delta: float):
	var direction = (target_position - global_position)
	direction.y = 0  # Ignore vertical difference
	
	var distance = direction.length()
	if distance < 0.5:
		# Reached target
		has_target = false
		velocity.x = 0
		velocity.z = 0
		return
	
	direction = direction.normalized()
	
	# Set horizontal velocity
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	
	# Rotate to face movement direction
	var target_rotation = atan2(direction.x, direction.z)
	rotation.y = lerp_angle(rotation.y, target_rotation, rotation_speed * delta)

## Set a movement target
func set_target(pos: Vector3):
	target_position = pos
	has_target = true

## Clear the movement target
func clear_target():
	has_target = false

## Called when spawned by EntityManager
func on_spawn(manager: Node3D):
	entity_manager = manager
	is_active = true
	velocity = Vector3.ZERO
	if wander_enabled:
		_pick_new_wander_target()

## Called when despawned by EntityManager
func on_despawn():
	is_active = false
	clear_target()

## Wander behavior - pick random nearby positions
func _process_wander(delta: float):
	wander_timer -= delta
	if wander_timer <= 0:
		_pick_new_wander_target()
		wander_timer = wander_interval + randf_range(-1.0, 1.0)

func _pick_new_wander_target():
	var angle = randf() * TAU
	var distance = randf_range(2.0, wander_radius)
	
	var new_target = global_position
	new_target.x += cos(angle) * distance
	new_target.z += sin(angle) * distance
	
	set_target(new_target)
