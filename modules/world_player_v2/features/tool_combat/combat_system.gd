extends Node
class_name CombatSystemFeature
## CombatSystem - Extracted combat and durability logic from ModePlay
## Handles damage dealing, durability tracking, and resource collection

# Local signals reference
var signals: Node = null

# References (set by parent)
var player: Node = null
var terrain_manager: Node = null
var vegetation_manager: Node = null
var building_manager: Node = null
var terrain_interaction: Node = null
var hotbar: Node = null
var terraformer: Node = null  # FirstPersonTerraformer component

# Combat state
var attack_cooldown: float = 0.0
const ATTACK_COOLDOWN_TIME: float = 0.3

# Durability system - blocks/objects require multiple hits
const BLOCK_HP: int = 10  # Building blocks take 10 damage to destroy
const OBJECT_HP: int = 5   # Placed objects take 5 damage to destroy
const TREE_HP: int = 8     # Trees take 8 damage to chop
const TERRAIN_HP: int = 5  # Terrain takes 5 punches to break a grid cube

var block_damage: Dictionary = {}    # Vector3i -> accumulated damage
var object_damage: Dictionary = {}   # RID -> accumulated damage
var tree_damage: Dictionary = {}     # collider RID -> accumulated damage
var terrain_damage: Dictionary = {}  # Vector3i -> accumulated damage for terrain
var durability_target: Variant = null # Current target being damaged

# Weapon readiness state
var fist_punch_ready: bool = true
var pistol_fire_ready: bool = true
var axe_ready: bool = true
var pickaxe_ready: bool = true
var pending_axe_item: Dictionary = {}  # Store item data when axe swing starts
var pending_pickaxe_hit: Dictionary = {}  # Store hit data when pickaxe swing starts
var is_reloading: bool = false

# Mode manager reference
var mode_manager: Node = null

# Prop grab/drop system
var held_prop_instance: Node = null
var held_prop_id: int = -1
var held_prop_rotation: int = 0

# Preload item definitions
const ItemDefs = preload("res://modules/world_player_v2/features/data_inventory/item_definitions.gd")

# Sound effects
const TREE_HIT_SOUND_PATH: String = "res://game/sound/player-hitting-tree-wood/giant-axe-strike-hitting-solid-wood-3-450247.mp3"
const TREE_FALL_SOUND_PATH: String = "res://game/sound/player-hitting-tree-wood/falling-tree-ai-generated-431321.mp3"
const WOOD_BLOCK_HIT_SOUND_PATH: String = "res://game/sound/player-hitting-wood-block/wooden_crate_smash-1-387904.mp3"
# Audio ranges for wood hit/break: [start, duration]
const WOOD_AUDIO_RANGES = {
	"hit_1": [0.00, 0.86],
	"hit_2": [2.45, 0.70], # 3.15 - 2.45
	"hit_3": [4.21, 0.90], # 5.11 - 4.21
	"break": [6.40, 1.64]  # 8.04 - 6.40
}
const PLANT_HIT_SOUND_PATH: String = "res://game/sound/player-hitting-grass-plant-or-rock/leafpilehit-107714.mp3"
const ROCK_HIT_SOUND_PATH: String = "res://game/sound/player-hitting-grass-plant-or-rock/hit-rock-03-266305.mp3"
const TERRAIN_HIT_SOUND_PATH: String = "res://game/sound/player-hitting-terrain/ground-impact-352053.mp3"
const TERRAIN_BREAK_SOUND_PATH: String = "res://game/sound/player-hitting-terrain-breaks/impact-109588.mp3"
var tree_hit_audio_player: AudioStreamPlayer3D = null
var tree_fall_audio_player: AudioStreamPlayer3D = null
var wood_block_hit_audio_player: AudioStreamPlayer3D = null
var plant_hit_audio_player: AudioStreamPlayer3D = null
var rock_hit_audio_player: AudioStreamPlayer3D = null
var terrain_hit_audio_player: AudioStreamPlayer3D = null
var terrain_break_audio_player: AudioStreamPlayer3D = null
var hit_marker_player: AudioStreamPlayer = null

func _ready() -> void:
	# Try to find local signals node
	signals = get_node_or_null("../signals")
	if not signals:
		signals = get_node_or_null("signals")
	
	# Auto-discover player (CombatSystem is at Modes/CombatSystem, parent.parent = WorldPlayerV2)
	player = get_parent().get_parent()
	
	# Auto-discover mode manager
	if player:
		mode_manager = player.get_node_or_null("Systems/ModeManager")
		hotbar = player.get_node_or_null("Systems/Hotbar")
	
	# Find managers via groups (deferred)
	call_deferred("_find_managers")
	call_deferred("_setup_audio")
	
	# Connect to weapon ready signals (backward compat)
	if has_node("/root/PlayerSignals"):
		PlayerSignals.punch_ready.connect(_on_punch_ready)
		PlayerSignals.pistol_fire_ready.connect(_on_pistol_fire_ready)
		PlayerSignals.axe_ready.connect(_on_axe_ready)
	
	DebugManager.log_player("CombatSystemFeature: Initialized")

func _find_managers() -> void:
	if not terrain_manager:
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	if not vegetation_manager:
		vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	if not building_manager:
		building_manager = get_tree().get_first_node_in_group("building_manager")
	if not terrain_interaction and player:
		terrain_interaction = player.get_node_or_null("Modes/TerrainInteraction")
	if not terraformer and player:
		terraformer = player.get_node_or_null("Components/FirstPersonTerraformer")

func _setup_audio() -> void:
	# Load tree hit sound
	if ResourceLoader.exists(TREE_HIT_SOUND_PATH):
		var stream = load(TREE_HIT_SOUND_PATH)
		if stream and player:
			tree_hit_audio_player = AudioStreamPlayer3D.new()
			tree_hit_audio_player.name = "TreeHitAudio"
			tree_hit_audio_player.stream = stream
			tree_hit_audio_player.max_distance = 20.0
			player.add_child(tree_hit_audio_player)
			print("[COMBAT_AUDIO] Tree hit sound loaded successfully")
	else:
		print("[COMBAT_AUDIO] Tree hit sound not found: %s" % TREE_HIT_SOUND_PATH)
	
	# Load tree fall sound
	if ResourceLoader.exists(TREE_FALL_SOUND_PATH):
		var fall_stream = load(TREE_FALL_SOUND_PATH)
		if fall_stream and player:
			tree_fall_audio_player = AudioStreamPlayer3D.new()
			tree_fall_audio_player.name = "TreeFallAudio"
			tree_fall_audio_player.stream = fall_stream
			tree_fall_audio_player.max_distance = 30.0
			player.add_child(tree_fall_audio_player)
			print("[COMBAT_AUDIO] Tree fall sound loaded successfully")
	
	# Load wood block hit sound (multipart file)
	if ResourceLoader.exists(WOOD_BLOCK_HIT_SOUND_PATH):
		var block_stream = load(WOOD_BLOCK_HIT_SOUND_PATH)
		if block_stream and player:
			wood_block_hit_audio_player = AudioStreamPlayer3D.new()
			wood_block_hit_audio_player.name = "WoodBlockHitAudio"
			wood_block_hit_audio_player.stream = block_stream
			wood_block_hit_audio_player.max_distance = 25.0
			player.add_child(wood_block_hit_audio_player)
			print("[COMBAT_AUDIO] Wood multipart sound loaded successfully")
			
	# Load plant hit sound
	if ResourceLoader.exists(PLANT_HIT_SOUND_PATH):
		var plant_stream = load(PLANT_HIT_SOUND_PATH)
		if plant_stream and player:
			plant_hit_audio_player = AudioStreamPlayer3D.new()
			plant_hit_audio_player.name = "PlantHitAudio"
			plant_hit_audio_player.stream = plant_stream
			plant_hit_audio_player.max_distance = 15.0
			player.add_child(plant_hit_audio_player)
			print("[COMBAT_AUDIO] Plant hit sound loaded successfully")

	# Load rock hit sound
	if ResourceLoader.exists(ROCK_HIT_SOUND_PATH):
		var rock_stream = load(ROCK_HIT_SOUND_PATH)
		if rock_stream and player:
			rock_hit_audio_player = AudioStreamPlayer3D.new()
			rock_hit_audio_player.name = "RockHitAudio"
			rock_hit_audio_player.stream = rock_stream
			rock_hit_audio_player.max_distance = 20.0
			player.add_child(rock_hit_audio_player)

			print("[COMBAT_AUDIO] Rock hit sound loaded successfully")

	# Load terrain hit sound
	if ResourceLoader.exists(TERRAIN_HIT_SOUND_PATH):
		var terrain_stream = load(TERRAIN_HIT_SOUND_PATH)
		if terrain_stream and player:
			terrain_hit_audio_player = AudioStreamPlayer3D.new()
			terrain_hit_audio_player.name = "TerrainHitAudio"
			terrain_hit_audio_player.stream = terrain_stream
			terrain_hit_audio_player.max_distance = 20.0
			player.add_child(terrain_hit_audio_player)
			print("[COMBAT_AUDIO] Terrain hit sound loaded successfully")

	# Setup hit marker (2D)
	hit_marker_player = AudioStreamPlayer.new()
	hit_marker_player.name = "HitMarkerAudio"
	hit_marker_player.volume_db = -5.0
	hit_marker_player.max_polyphony = 5
	player.add_child(hit_marker_player)

	# Load terrain hit sound
	# Load terrain break sound
	if ResourceLoader.exists(TERRAIN_BREAK_SOUND_PATH):
		var break_stream = load(TERRAIN_BREAK_SOUND_PATH)
		if break_stream and player:
			terrain_break_audio_player = AudioStreamPlayer3D.new()
			terrain_break_audio_player.name = "TerrainBreakAudio"
			terrain_break_audio_player.stream = break_stream
			terrain_break_audio_player.max_distance = 25.0
			player.add_child(terrain_break_audio_player)
			print("[COMBAT_AUDIO] Terrain break sound loaded successfully")

func _process(delta: float) -> void:
	PerformanceMonitor.start_measure("Combat System")
	if attack_cooldown > 0:
		attack_cooldown -= delta
	
	_update_held_prop(delta)
	_check_durability_target()
	PerformanceMonitor.end_measure("Combat System", 1.0)

## Initialize references (called by parent after scene ready)
func initialize(p_player: Node, p_terrain: Node, p_vegetation: Node, p_building: Node, p_hotbar: Node) -> void:
	player = p_player
	terrain_manager = p_terrain
	vegetation_manager = p_vegetation
	building_manager = p_building
	hotbar = p_hotbar
	
	# Find mode manager
	mode_manager = player.get_node_or_null("Systems/ModeManager") if player else null

# ============================================================================
# MODE INTERFACE (called by ModeManager)
# ============================================================================

## Handle primary action (left click) - mode dispatch (V1 EXACT)
func handle_primary(item: Dictionary) -> void:

	
	# V1: If grabbing a prop, don't do other actions
	if is_grabbing_prop():
		DebugManager.log_player("CombatSystem: Grabbing prop, ignoring primary action")
		return
	
	# V1: Attack cooldown check
	if attack_cooldown > 0:

		return
	
	# BUG FIX: JSON deserialization converts all numbers to floats (1.0 vs 1)
	# The match statement requires exact type match, so we must cast to int
	var category = int(item.get("category", 0))

	
	match category:
		0:  # NONE - Fists

			do_punch(item)
		1:  # TOOL

			do_tool_attack(item)
		2:  # BUCKET - V1 routes to _do_bucket_collect

			if terrain_interaction and terrain_interaction.has_method("do_bucket_collect"):
				terrain_interaction.do_bucket_collect()
		3:  # RESOURCE - no primary action (V1: pass)

			pass
		6:  # PROP (pistol, etc.)

			_do_prop_primary(item)
		7:  # TERRAFORMER - grid-snapped dig

			if terraformer and terraformer.has_method("do_primary_action"):
				terraformer.do_primary_action()
		_:

			# Other categories handled by terrain_interaction or building
			pass

## Handle secondary action (right click)
func handle_secondary(item: Dictionary) -> void:
	var category = item.get("category", 0)
	
	# TERRAFORMER - grid-snapped fill with material
	if category == 7:
		if terraformer and terraformer.has_method("do_secondary_action"):
			terraformer.do_secondary_action()
		return
	
	# Combat system has no other secondary actions
	# Resource/bucket placement is handled by terrain_interaction
	pass

## Handle PROP primary action (pistol, etc.)
func _do_prop_primary(item: Dictionary) -> void:
	var item_id = item.get("id", "")
	if item_id == "heavy_pistol":
		do_pistol_fire()

# ============================================================================
# PROP GRAB/DROP SYSTEM
# ============================================================================

func _input(event: InputEvent) -> void:
	# Only process in PLAY mode (if mode_manager is null, assume PLAY mode)
	if mode_manager and not mode_manager.is_play_mode():
		return
	
	# Also try to find mode_manager if not set
	if not mode_manager and player:
		mode_manager = player.get_node_or_null("Systems/ModeManager")
	
	# T key for prop grab/drop
	if event is InputEventKey and event.keycode == KEY_T:
		# Ignore echo (key repeat) events
		if event.echo:
			return
		
		if event.pressed:
			# T pressed down - grab prop
			if not is_grabbing_prop():
				print("CombatSystem: T pressed - attempting grab")
				_try_grab_prop()
		else:
			# T released - drop prop
			if is_grabbing_prop():
				print("CombatSystem: T released - dropping")
				_drop_grabbed_prop()
## Update held prop position (follows camera) - V1 port with smooth lerp
func _update_held_prop(delta: float) -> void:
	if not held_prop_instance or not is_instance_valid(held_prop_instance):
		return
	
	# Get camera from player - V1 uses "Head/Camera3D" path
	var cam: Camera3D = null
	if player and player.has_node("Head/Camera3D"):
		cam = player.get_node("Head/Camera3D")
	if not cam and player and player.has_node("Camera3D"):
		cam = player.get_node("Camera3D")
	if not cam:
		cam = get_viewport().get_camera_3d()
	if not cam:
		return
	
	# Float 2 meters in front of camera
	var target_pos = cam.global_position - cam.global_transform.basis.z * 2.0
	# Smoothly interpolate position (V1 uses delta * 15.0)
	held_prop_instance.global_position = held_prop_instance.global_position.lerp(target_pos, delta * 15.0)
	# Match camera rotation (yaw only) with smooth interpolation
	var cam_rot_y = cam.global_rotation.y
	held_prop_instance.rotation.y = lerp_angle(held_prop_instance.rotation.y, cam_rot_y + deg_to_rad(held_prop_rotation * 90.0), delta * 10.0)
	
	# V1 debug every 60 frames
	if Engine.get_process_frames() % 60 == 0:
		print("PropHold: Prop at %s (visible: %s)" % [held_prop_instance.global_position, held_prop_instance.visible])

## Try to grab a prop (building_manager object OR dropped physics prop) - V1 EXACT
func _try_grab_prop() -> void:
	var target = _get_pickup_target()
	if not target:
		return
	
	DebugManager.log_player("PropGrab: Trying to grab %s" % target.name)
	
	# Check if this is a dropped physics prop (has item_data OR is interactable RigidBody3D)
	# V1: Routes ALL RigidBody3D through _grab_dropped_prop for proper collision handling
	if target is RigidBody3D and (target.has_meta("item_data") or target.is_in_group("interactable")):
		_grab_dropped_prop(target)
		return
	
	# Otherwise, try building_manager object path
	if not target.has_meta("anchor") or not target.has_meta("chunk"):
		DebugManager.log_player("PropGrab: Target has no anchor/chunk metadata")
		return
	
	var anchor = target.get_meta("anchor")
	var chunk = target.get_meta("chunk")
	
	if not chunk or not chunk.objects.has(anchor):
		DebugManager.log_player("PropPickup: No object data at anchor")
		return
	
	# Read object data before removing
	var data = chunk.objects[anchor]
	held_prop_id = data["object_id"]
	held_prop_rotation = data.get("rotation", 0)
	
	# Remove from world
	chunk.remove_object(anchor)
	
	# Spawn temporary held visual
	var obj_def = ObjectRegistry.get_object(held_prop_id)
	if obj_def.has("scene"):
		var packed = load(obj_def.scene)
		held_prop_instance = packed.instantiate()
		
		# Strip physics for holding
		if held_prop_instance is RigidBody3D:
			held_prop_instance.freeze = true
			held_prop_instance.collision_layer = 0
			held_prop_instance.collision_mask = 0
		
		# Disable all collisions
		_disable_preview_collisions(held_prop_instance)
		
		get_tree().root.add_child(held_prop_instance)
		
		# Position at camera
		var cam: Camera3D = null
		if player and player.has_node("Head/Camera3D"):
			cam = player.get_node("Head/Camera3D")
		if not cam and player and player.has_node("Camera3D"):
			cam = player.get_node("Camera3D")
		if not cam:
			cam = get_viewport().get_camera_3d()
		if cam:
			held_prop_instance.global_position = cam.global_position - cam.global_transform.basis.z * 2.0
			DebugManager.log_player("PropPickup: Picked up prop ID %d at %s" % [held_prop_id, held_prop_instance.global_position])
		else:
			DebugManager.log_player("PropPickup: WARNING - No camera, prop may be mispositioned")

## Grab a dropped physics prop (RigidBody3D with item_data meta) - V1 port
func _grab_dropped_prop(target: RigidBody3D) -> void:
	# Store reference directly - don't need to respawn, just move it (V1 approach)
	held_prop_instance = target
	held_prop_id = -1  # No object registry ID for dropped items
	held_prop_rotation = 0
	
	# Store item data for later drop (V1: grabbed_item_data)
	if target.has_meta("item_data"):
		held_prop_instance.set_meta("grabbed_item_data", target.get_meta("item_data"))
	
	# Freeze physics and disable collisions for holding (V1 sets layer/mask to 0)
	target.freeze = true
	target.collision_layer = 0
	target.collision_mask = 0
	_disable_preview_collisions(target)
	
	# Position at camera immediately
	var cam = get_viewport().get_camera_3d()
	if cam:
		held_prop_instance.global_position = cam.global_position - cam.global_transform.basis.z * 2.0
		print("CombatSystem: Grabbed dropped prop %s" % target.name)
	else:
		print("CombatSystem: WARNING - No camera for initial prop position")

## Drop the grabbed prop - V1 port with collision layer restore
func _drop_grabbed_prop() -> void:
	if not held_prop_instance:
		return
	
	print("CombatSystem: Dropping prop (held_prop_id=%d)" % held_prop_id)
	
	# Check if this was a grabbed dropped prop (not a building_manager object)
	if held_prop_id == -1:
		# Re-enable physics and drop naturally (V1 approach)
		if held_prop_instance is RigidBody3D:
			# Re-enable collision shapes first!
			_enable_preview_collisions(held_prop_instance)
			held_prop_instance.freeze = false
			held_prop_instance.collision_layer = 1  # Default layer (V1)
			held_prop_instance.collision_mask = 1   # Default mask (V1)
			# Give a small drop velocity (V1)
			held_prop_instance.linear_velocity = Vector3(0, -1, 0)
			print("CombatSystem: Released dropped prop with physics")
		held_prop_instance = null
		held_prop_id = -1
		held_prop_rotation = 0
		return
	
	# For building objects, place via building_manager
	var drop_pos = held_prop_instance.global_position
	
	if building_manager and building_manager.has_method("place_object"):
		building_manager.place_object(drop_pos, held_prop_id, held_prop_rotation)
		print("CombatSystem: Placed building object via building_manager")
	else:
		print("CombatSystem: No building_manager - placement failed")
	
	# Cleanup held prop
	if held_prop_instance:
		held_prop_instance.queue_free()
	held_prop_instance = null
	held_prop_id = -1
	held_prop_rotation = 0

## Find a prop that can be picked up (building_manager objects OR dropped physics props)
func _get_pickup_target() -> Node:
	var cam = get_viewport().get_camera_3d()
	if not cam:
		print("CombatSystem: _get_pickup_target - no camera")
		return null
	
	var origin = cam.global_position
	var forward = -cam.global_transform.basis.z
	
	# Option A: Precise raycast using player.raycast
	var hit = player.raycast(5.0, 0xFFFFFFFF, true, true) if player and player.has_method("raycast") else {}
	
	if hit and hit.has("collider"):
		var col = hit.collider
		# Check for building_manager placed objects
		if col.is_in_group("placed_objects") and col.has_meta("anchor"):
			print("CombatSystem: Direct hit on placed object %s" % col.name)
			return col
		# Check for dropped physics props (RigidBody3D with item_data or interactable)
		if col is RigidBody3D and (col.has_meta("item_data") or col.is_in_group("interactable")):
			print("CombatSystem: Direct hit on dropped prop %s" % col.name)
			return col
	
	# Option B: Sphere assist for forgiveness
	var search_origin = hit.position if hit and hit.has("position") else (origin + forward * 2.0)
	
	var space_state = cam.get_world_3d().direct_space_state
	var params = PhysicsShapeQueryParameters3D.new()
	params.shape = SphereShape3D.new()
	params.shape.radius = 0.4 # 40cm forgiveness
	params.transform = Transform3D(Basis(), search_origin)
	params.collision_mask = 0xFFFFFFFF
	if player:
		params.exclude = [player.get_rid()]
	
	var results = space_state.intersect_shape(params, 5)
	var best_target = null
	var best_dist = 999.0
	
	for result in results:
		var col = result.collider
		var is_valid = false
		# Check for building_manager placed objects
		if col.is_in_group("placed_objects") and col.has_meta("anchor"):
			is_valid = true
		# Check for dropped physics props
		elif col is RigidBody3D and (col.has_meta("item_data") or col.is_in_group("interactable")):
			is_valid = true
		
		if is_valid:
			var d = col.global_position.distance_to(search_origin)
			if d < best_dist:
				best_dist = d
				best_target = col
	
	if best_target:
		print("CombatSystem: Assisted hit on %s" % best_target.name)
	else:
		print("CombatSystem: No pickup target found")
	return best_target

func _disable_preview_collisions(node: Node) -> void:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		node.disabled = true
	for child in node.get_children():
		_disable_preview_collisions(child)

func _enable_preview_collisions(node: Node) -> void:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		node.disabled = false
	for child in node.get_children():
		_enable_preview_collisions(child)

func is_grabbing_prop() -> bool:
	return held_prop_instance != null and is_instance_valid(held_prop_instance)

func _exit_tree() -> void:
	# Cleanup held props
	if held_prop_instance and is_instance_valid(held_prop_instance):
		held_prop_instance.queue_free()

# ============================================================================
# WEAPON READY CALLBACKS
# ============================================================================

func _on_punch_ready() -> void:
	fist_punch_ready = true

func _on_pistol_fire_ready() -> void:
	pistol_fire_ready = true

func _on_axe_ready() -> void:
	axe_ready = true
	pickaxe_ready = true
	# Note: damage now happens at 0.83s via _on_axe_hit_moment, not here

## Axe hit moment - called at 0.83s into swing animation
func _on_axe_hit_moment() -> void:
	if not pending_axe_item.is_empty():
		_do_axe_damage(pending_axe_item)
		pending_axe_item = {}

## Pickaxe hit moment - called at 0.30s into swing animation
func _on_pickaxe_hit_moment() -> void:
	if not pending_pickaxe_hit.is_empty():
		_do_pickaxe_damage_delayed(pending_pickaxe_hit)
		pending_pickaxe_hit = {}

# ============================================================================
# PRIMARY ACTIONS
# ============================================================================

## Punch attack with fists (synced with animation)
func do_punch(item: Dictionary) -> void:
	if not player:
		return
	
	if not fist_punch_ready:
		return
	
	fist_punch_ready = false
	_emit_punch_triggered()
	
	var hit = _raycast(5.0, true, true)
	if hit.is_empty():
		DebugManager.log_player("CombatSystem: Punch - miss")
		return
	
	var damage = item.get("damage", 1)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	# Try to damage entity
	var damageable = _find_damageable(target)
	if damageable:
		damageable.take_damage(damage)
		durability_target = target.get_rid()
		_emit_damage_dealt(damageable, damage)
		return
	
	# Try vegetation
	if _try_harvest_vegetation(target, item, position):
		return
	
	# Try placed objects
	if _try_damage_placed_object(target, item, position):
		return
	
	# Try building blocks
	if _try_damage_building_block(target, item, position, hit):
		return
	
	# Default: terrain with durability
	_do_terrain_punch(item, position)

## Tool attack/mine
func do_tool_attack(item: Dictionary) -> void:
	if not player:
		return
	
	attack_cooldown = ATTACK_COOLDOWN_TIME
	
	var item_id = item.get("id", "")
	
	# Handle axe - damage happens at 0.83s into animation (the visual hit moment)
	if "axe" in item_id and not "pickaxe" in item_id:
		if not axe_ready:
			return
		axe_ready = false
		pending_axe_item = item.duplicate()  # Store for damage at hit moment
		_emit_axe_fired()
		# Delay damage to 0.30s (when axe visually connects)
		get_tree().create_timer(0.30).timeout.connect(_on_axe_hit_moment)
		return  # Exit - damage will happen after delay
	
	# Handle pickaxe - delay raycast AND damage to match animation (Option A: Raycast at Impact)
	if "pickaxe" in item_id:
		if not pickaxe_ready:
			print("PICKAXE_HIT_DEBUG: Attack ignored - not ready (still in cooldown)")
			return
		pickaxe_ready = false
		_emit_axe_fired()  # Trigger visual animation (pickaxe reuses axe signal)
		
		# Store ONLY item data - raycast will happen at impact moment (0.30s)
		pending_pickaxe_hit = {
			"item": item.duplicate()
		}
		print("PICKAXE_HIT_DEBUG: Swing started - raycast will happen at impact (0.30s)")
		
		# Delay BOTH raycast and damage to 0.30s (when pickaxe visually connects)
		get_tree().create_timer(0.30).timeout.connect(_on_pickaxe_hit_moment)
		
		# Pickaxe ready state will be reset by axe_ready signal (from first_person_pickaxe.gd)
		return  # Exit - raycast and damage will happen after delay
	
	var hit = _raycast(3.5, true, true)
	if hit.is_empty():
		return
	
	var damage = item.get("damage", 1)
	var mining_strength = item.get("mining_strength", 1.0)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	# Priority 1: Generic Damageable
	var damageable = _find_damageable(target)
	if damageable:
		if ("axe" in item_id or "pickaxe" in item_id) and damageable.is_in_group("zombies"):
			damage = 10  # Axe/Pickaxe bonus vs zombies
		damageable.take_damage(damage)
		durability_target = target.get_rid()
		_emit_damage_dealt(damageable, damage)
		return
	
	# Priority 2: Vegetation
	if _try_harvest_vegetation(target, item, position):
		return
	
	# Priority 3: Placed objects
	if _try_damage_placed_object(target, item, position):
		return
	
	# Priority 4: Building blocks
	if _try_damage_building_block(target, item, position, hit):
		return
	
	# Priority 5: Terrain mine
	if terrain_manager:
		# --- STRATEGY PATTERN REFACTOR ---
		# Get the behavior strategy for this tool
		var behavior = null
		
		# Resolve behavior via Registry (using the simplified singleton-like access for now)
		# In a full Autoload setup, this would be global.
		var registry_script = load("res://modules/world_player_v2/features/tool_combat/terrain_tool_registry.gd")
		if registry_script:
			# Instantiate strictly to query defaults/overrides
			# Ideally this is a persistent node, but for this refactor we instantiate-dump or use static if possible.
			# To remain efficient, we should have cached this. But let's keep it safe.
			var registry = registry_script.new()
			registry._load_defaults() # Ensure defaults are loaded
			
			# Check global overrides
			if "pickaxe" in item_id:
				var enhanced_enabled = false
				if has_node("/root/PickaxeDigConfig") and get_node("/root/PickaxeDigConfig").enabled:
					enhanced_enabled = true
				
				# Map legacy globals to specific presets
				if enhanced_enabled:
					behavior = registry.get_tool_behavior("pickaxe_enhanced")
				else:
					behavior = registry.get_tool_behavior("pickaxe_classic")
			else:
				# Generic lookup
				behavior = registry.get_tool_behavior(item_id)
				
			registry.free() # Cleanup
		
		# Fallback if no behavior found (e.g. unknown tool)
		if not behavior:
			# Create a temporary default behavior
			behavior = TerrainToolBehavior.new()
			behavior.radius = max(item.get("mining_strength", 1.0), 0.8)
			behavior.shape_type = TerrainToolBehavior.ShapeType.SPHERE
		
		# Now apply the behavior (handling durability logic here in CombatSystem)
		var hit_normal = hit.get("normal", Vector3.UP)
		var mat_id = _get_material_at_hit(target, position, hit_normal)
		
		# Check durability config
		var use_durability = false
		if "pickaxe" in item_id and has_node("/root/PickaxeDurabilityConfig"):
			use_durability = get_node("/root/PickaxeDurabilityConfig").enabled
			
		# Snap for durability tracking based on COMPATIBILITY mode
		# We must track grid damage even if using sphere tool, if durability is ON.
		var snapped_pos = position - hit_normal * 0.1
		snapped_pos = Vector3(floor(snapped_pos.x) + 0.5, floor(snapped_pos.y) + 0.5, floor(snapped_pos.z) + 0.5)
		var block_pos = Vector3i(floor(snapped_pos.x), floor(snapped_pos.y), floor(snapped_pos.z))
		
		if use_durability:
			# DURABILITY MODE: Track hits
			if not terrain_damage.has(block_pos):
				terrain_damage[block_pos] = 0
			
			terrain_damage[block_pos] += damage
			var current_hp = TERRAIN_HP - terrain_damage[block_pos]
			durability_target = block_pos
			
			_emit_durability_hit(max(0, current_hp), TERRAIN_HP, "Terrain", block_pos)
			
			if terrain_hit_audio_player:
				terrain_hit_audio_player.pitch_scale = randf_range(0.9, 1.1)
				terrain_hit_audio_player.play()
			
			if terrain_damage[block_pos] >= TERRAIN_HP:
				# DESTROYED
				if terrain_break_audio_player:
					terrain_break_audio_player.pitch_scale = randf_range(0.95, 1.05)
					terrain_break_audio_player.play()
				
				# EXECUTE STRATEGY
				behavior.apply(terrain_manager, position, hit_normal)
				
				terrain_damage.erase(block_pos)
				_emit_durability_cleared()
				
				if mat_id >= 0:
					_collect_terrain_resource(mat_id)
		else:
			# INSTANT MODE
			_emit_durability_hit(0, TERRAIN_HP, "Terrain", block_pos)
			
			# EXECUTE STRATEGY
			behavior.apply(terrain_manager, position, hit_normal)
			
			_emit_durability_cleared()
			if mat_id >= 0:
				_collect_terrain_resource(mat_id)



## Axe damage - called when animation completes (from _on_axe_ready)
func _do_axe_damage(item: Dictionary) -> void:
	if not player:
		return
	
	var item_id = item.get("id", "")
	var hit = _raycast(3.5, true, true)
	if hit.is_empty():
		print("AXE_DAMAGE_DEBUG: No hit on animation complete")
		return
	
	var damage = item.get("damage", 1)
	var mining_strength = item.get("mining_strength", 1.0)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	print("AXE_DAMAGE_DEBUG: Hit %s at %s" % [target.name if target else "nothing", position])
	
	# Priority 1: Generic Damageable
	var damageable = _find_damageable(target)
	if damageable:
		if damageable.is_in_group("zombies"):
			damage = 10  # Axe/Pickaxe bonus vs zombies
		damageable.take_damage(damage)
		durability_target = target.get_rid()
		_emit_damage_dealt(damageable, damage)
		return
	
	# Priority 2: Vegetation
	if _try_harvest_vegetation(target, item, position):
		return
	
	# Priority 3: Placed objects
	if _try_damage_placed_object(target, item, position):
		return
	
	# Priority 4: Building blocks
	if _try_damage_building_block(target, item, position, hit):
		return
	
	# Priority 5: Terrain mining
	if terrain_manager and terrain_manager.has_method("modify_terrain"):
		var use_enhanced_mode = false
		if "pickaxe" in item_id and has_node("/root/PickaxeDigConfig"):
			use_enhanced_mode = get_node("/root/PickaxeDigConfig").enabled
		
		var use_durability = false
		if "pickaxe" in item_id and has_node("/root/PickaxeDurabilityConfig"):
			use_durability = get_node("/root/PickaxeDurabilityConfig").enabled
		
		var hit_normal = hit.get("normal", Vector3.UP)
		var mat_id = _get_material_at_hit(target, position, hit_normal)
		
		var snapped_pos = position - hit_normal * 0.1
		snapped_pos = Vector3(floor(snapped_pos.x) + 0.5, floor(snapped_pos.y) + 0.5, floor(snapped_pos.z) + 0.5)
		var block_pos = Vector3i(floor(snapped_pos.x), floor(snapped_pos.y), floor(snapped_pos.z))
		
		if use_durability:
			if not terrain_damage.has(block_pos):
				terrain_damage[block_pos] = 0
			terrain_damage[block_pos] += damage
			var current_hp = TERRAIN_HP - terrain_damage[block_pos]
			durability_target = block_pos
			_emit_durability_hit(max(0, current_hp), TERRAIN_HP, "Terrain", block_pos)
			print("AXE_DAMAGE_DEBUG: Pickaxe hit %s (%d/%d HP)" % [block_pos, current_hp, TERRAIN_HP])
			
			if terrain_hit_audio_player:
				terrain_hit_audio_player.pitch_scale = randf_range(0.9, 1.1)
				terrain_hit_audio_player.play()
			
			if terrain_damage[block_pos] >= TERRAIN_HP:
				if use_enhanced_mode:
					terrain_manager.modify_terrain(snapped_pos, 0.6, 1.0, 1, 0)
				else:
					var actual_radius = max(mining_strength, 0.8)
					terrain_manager.modify_terrain(position, actual_radius, 1.0, 0, 0)
				terrain_damage.erase(block_pos)
				_emit_durability_cleared()
				if mat_id >= 0:
					_collect_terrain_resource(mat_id)
		else:
			_emit_durability_hit(0, TERRAIN_HP, "Terrain", block_pos)
			if use_enhanced_mode:
				terrain_manager.modify_terrain(snapped_pos, 0.6, 1.0, 1, 0)
			else:
				var actual_radius = max(mining_strength, 0.8)
				terrain_manager.modify_terrain(position, actual_radius, 1.0, 0, 0)
			_emit_durability_cleared()
			if mat_id >= 0:
				_collect_terrain_resource(mat_id)


## Pickaxe damage - called 0.30s after swing starts (Option A: Raycast at Impact)
func _do_pickaxe_damage_delayed(pending_data: Dictionary) -> void:
	print("PICKAXE_HIT_DEBUG: _do_pickaxe_damage_delayed CALLED - performing raycast NOW")
	
	if not player or not terrain_manager:
		print("PICKAXE_HIT_DEBUG: ABORTED - player=%s terrain_manager=%s" % [player != null, terrain_manager != null])
		return
	
	var item = pending_data.get("item", {})
	
	if item.is_empty():
		print("PICKAXE_HIT_DEBUG: ABORTED - item data is empty")
		return
	
	# OPTION A: Perform raycast NOW at impact time (what you're aiming at when pickaxe connects)
	var hit = _raycast(3.5, true, true)
	
	if hit.is_empty():
		print("PICKAXE_HIT_DEBUG: MISS at impact time - no target in crosshair")
		return
	
	var item_id = item.get("id", "")
	var damage = item.get("damage", 1)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	var hit_normal = hit.get("normal", Vector3.UP)
	
	print("PICKAXE_HIT_DEBUG: HIT at impact time | Target: %s | Position: %s" % [target.name if target else "null", position])
	
	# Visual debug: Spawn marker at hit position (if enabled)
	if has_node("/root/HitMarkerConfig") and get_node("/root/HitMarkerConfig").enabled:
		_spawn_hit_marker(position, Color.GREEN)  # Green = impact-time hit
	
	# Priority 1: Generic Damageable
	var damageable = _find_damageable(target)
	if damageable:
		if damageable.is_in_group("zombies"):
			damage = 10  # Axe/Pickaxe bonus vs zombies
		damageable.take_damage(damage)
		durability_target = target.get_rid()
		_emit_damage_dealt(damageable, damage)
		return
	
	# Priority 2: Vegetation
	if _try_harvest_vegetation(target, item, position):
		return
	
	# Priority 3: Placed objects
	if _try_damage_placed_object(target, item, position):
		return
	
	# Priority 4: Building blocks
	if _try_damage_building_block(target, item, position, hit):
		return
	
	# Priority 5: Terrain mine (delayed pickaxe damage)
	if terrain_manager.has_method("modify_terrain"):
		var use_enhanced_mode = false
		if has_node("/root/PickaxeDigConfig"):
			use_enhanced_mode = get_node("/root/PickaxeDigConfig").enabled
		
		var use_durability = false
		if has_node("/root/PickaxeDurabilityConfig"):
			use_durability = get_node("/root/PickaxeDurabilityConfig").enabled
		
		var mat_id = _get_material_at_hit(target, position, hit_normal)
		
		var snapped_pos = position - hit_normal * 0.1
		snapped_pos = Vector3(floor(snapped_pos.x) + 0.5, floor(snapped_pos.y) + 0.5, floor(snapped_pos.z) + 0.5)
		var block_pos = Vector3i(floor(snapped_pos.x), floor(snapped_pos.y), floor(snapped_pos.z))
		
		if use_durability:
			if not terrain_damage.has(block_pos):
				terrain_damage[block_pos] = 0
			terrain_damage[block_pos] += damage
			var current_hp = TERRAIN_HP - terrain_damage[block_pos]
			durability_target = block_pos
			_emit_durability_hit(max(0, current_hp), TERRAIN_HP, "Terrain", block_pos)
			print("PICKAXE_DEBUG: Hit %s (%d/%d HP)" % [block_pos, current_hp, TERRAIN_HP])
			
			if terrain_hit_audio_player:
				terrain_hit_audio_player.pitch_scale = randf_range(0.9, 1.1)
				terrain_hit_audio_player.play()
				
			if terrain_damage[block_pos] >= TERRAIN_HP:
				if terrain_break_audio_player:
					terrain_break_audio_player.pitch_scale = randf_range(0.95, 1.05)
					terrain_break_audio_player.play()
					
				if use_enhanced_mode:
					terrain_manager.modify_terrain(snapped_pos, 0.6, 1.0, 1, 0)
				else:
					var actual_radius = max(item.get("mining_strength", 1.0), 0.8)
					terrain_manager.modify_terrain(position, actual_radius, 1.0, 0, 0)
				terrain_damage.erase(block_pos)
				_emit_durability_cleared()
				if mat_id >= 0:
					_collect_terrain_resource(mat_id)
		else:
			_emit_durability_hit(0, TERRAIN_HP, "Terrain", block_pos)
			if use_enhanced_mode:
				terrain_manager.modify_terrain(snapped_pos, 0.6, 1.0, 1, 0)
			else:
				var actual_radius = max(item.get("mining_strength", 1.0), 0.8)
				terrain_manager.modify_terrain(position, actual_radius, 1.0, 0, 0)
			_emit_durability_cleared()
			if mat_id >= 0:
				_collect_terrain_resource(mat_id)

## Pistol fire
func do_pistol_fire() -> void:
	if not player:
		return
	
	if not pistol_fire_ready or is_reloading:
		return
	
	pistol_fire_ready = false
	_emit_pistol_fired()
	
	var hit = _raycast(50.0, true, true)
	if hit.is_empty():
		return
	
	var target = hit.get("collider", null)
	var position = hit.get("position", Vector3.ZERO)
	
	_spawn_pistol_hit_effect(position)
	
	if target and target.is_in_group("zombies") and target.has_method("take_damage"):
		target.take_damage(5, "pistol")
		_emit_damage_dealt(target, 5)
		return
	
	if target and target.is_in_group("blocks") and target.has_method("take_damage"):
		target.take_damage(2)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

func _raycast(distance: float, collide_with_areas: bool, exclude_water: bool) -> Dictionary:
	if player and player.has_method("raycast"):
		return player.raycast(distance, 0xFFFFFFFF, collide_with_areas, exclude_water)
	return {}

## Get material ID at hit position using mesh vertex colors (most accurate)
## Falls back to voxel buffer lookup if mesh reading fails
func _get_material_at_hit(target: Node, hit_pos: Vector3, hit_normal: Vector3) -> int:
	# Try mesh-based detection first (accurate for small veins like ore)
	var mat_id = _get_material_from_mesh(target, hit_pos)
	
	# Fallback to voxel buffer if mesh reading failed
	if mat_id < 0 and terrain_manager and terrain_manager.has_method("get_material_at"):
		# Sample INSIDE terrain, not at surface
		var sample_pos = hit_pos - hit_normal * 0.3
		mat_id = terrain_manager.get_material_at(sample_pos)
	
	return mat_id

## Get material ID from mesh vertex color at hit point (100% accurate)
## Finds the exact triangle containing the hit point and interpolates vertex colors
func _get_material_from_mesh(terrain_node: Node, hit_pos: Vector3) -> int:
	# Find the MeshInstance3D child of the terrain node
	var mesh_instance: MeshInstance3D = null
	for child in terrain_node.get_children():
		if child is MeshInstance3D:
			mesh_instance = child
			break
	
	if not mesh_instance or not mesh_instance.mesh:
		return -1
	
	var mesh = mesh_instance.mesh
	if not mesh is ArrayMesh:
		return -1
	
	# Get mesh data
	var arrays = mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return -1
	
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	var colors = arrays[Mesh.ARRAY_COLOR]
	
	if vertices.is_empty() or colors.is_empty():
		return -1
	
	# Convert hit position to local mesh space
	var local_pos = mesh_instance.global_transform.affine_inverse() * hit_pos
	
	# Find the triangle containing the hit point
	var best_mat_id = -1
	var best_dist = INF
	
	for i in range(0, vertices.size(), 3):
		if i + 2 >= vertices.size():
			break
		
		var v0 = vertices[i]
		var v1 = vertices[i + 1]
		var v2 = vertices[i + 2]
		
		# Quick rejection - skip triangles far from hit
		var tri_center = (v0 + v1 + v2) / 3.0
		var dist_to_center = local_pos.distance_squared_to(tri_center)
		if dist_to_center > 4.0:
			continue
		
		# Compute closest point on triangle
		var closest_on_tri = _closest_point_on_triangle(local_pos, v0, v1, v2)
		var dist = local_pos.distance_squared_to(closest_on_tri)
		
		if dist < best_dist:
			best_dist = dist
			# Get barycentric coordinates for interpolation
			var bary = _barycentric(closest_on_tri, v0, v1, v2)
			var c0 = colors[i]
			var c1 = colors[i + 1]
			var c2 = colors[i + 2]
			# Interpolate color using barycentric weights
			var interp_color = c0 * bary.x + c1 * bary.y + c2 * bary.z
			best_mat_id = int(round(interp_color.r * 255.0))
	
	return best_mat_id

## Compute barycentric coordinates of point P in triangle (A, B, C)
func _barycentric(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 = b - a
	var v1 = c - a
	var v2 = p - a
	
	var d00 = v0.dot(v0)
	var d01 = v0.dot(v1)
	var d11 = v1.dot(v1)
	var d20 = v2.dot(v0)
	var d21 = v2.dot(v1)
	
	var denom = d00 * d11 - d01 * d01
	if abs(denom) < 0.00001:
		return Vector3(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)
	
	var v = (d11 * d20 - d01 * d21) / denom
	var w = (d00 * d21 - d01 * d20) / denom
	var u = 1.0 - v - w
	
	return Vector3(u, v, w)

## Find the closest point on a triangle to a given point
func _closest_point_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab = b - a
	var ac = c - a
	var ap = p - a
	
	var d1 = ab.dot(ap)
	var d2 = ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	
	var bp = p - b
	var d3 = ab.dot(bp)
	var d4 = ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	
	var vc = d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		var v = d1 / (d1 - d3)
		return a + ab * v
	
	var cp = p - c
	var d5 = ab.dot(cp)
	var d6 = ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	
	var vb = d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		var w = d2 / (d2 - d6)
		return a + ac * w
	
	var va = d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		var w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w
	
	var denom = 1.0 / (va + vb + vc)
	var v = vb * denom
	var w = vc * denom
	return a + ab * v + ac * w

func _find_damageable(target: Node) -> Node:
	if not target:
		return null
	
	if target.has_method("take_damage"):
		return target
	
	var node = target.get_parent()
	while node:
		if node.has_method("take_damage"):
			return node
		node = node.get_parent()
	
	return null

func _try_harvest_vegetation(target: Node, item: Dictionary, _position: Vector3) -> bool:
	if not target or not vegetation_manager:
		return false
	
	var damage = item.get("damage", 1)
	var item_id = item.get("id", "")
	
	if target.is_in_group("trees"):
		var tree_dmg = damage
		if "axe" in item_id:
			tree_dmg = 3
		
		var tree_rid = target.get_rid()
		tree_damage[tree_rid] = tree_damage.get(tree_rid, 0) + tree_dmg
		var current_hp = TREE_HP - tree_damage[tree_rid]
		durability_target = tree_rid
		
		# Play wood hit sound
		if tree_hit_audio_player and tree_hit_audio_player.is_inside_tree():
			tree_hit_audio_player.pitch_scale = randf_range(0.9, 1.1)
			tree_hit_audio_player.play()
		
		_emit_durability_hit(current_hp, TREE_HP, "Tree", durability_target)
		
		if tree_damage[tree_rid] >= TREE_HP:
			# Play tree falling sound
			if tree_fall_audio_player and tree_fall_audio_player.is_inside_tree():
				tree_fall_audio_player.pitch_scale = randf_range(0.95, 1.05)
				tree_fall_audio_player.play()
			
			vegetation_manager.chop_tree_by_collider(target)
			tree_damage.erase(tree_rid)
			_emit_durability_cleared()
			_collect_vegetation_resource("wood")
		return true
	
	elif target.is_in_group("grass"):
		if plant_hit_audio_player and plant_hit_audio_player.is_inside_tree():
			plant_hit_audio_player.pitch_scale = randf_range(0.9, 1.1)
			plant_hit_audio_player.play()
			
		vegetation_manager.harvest_grass_by_collider(target)
		_collect_vegetation_resource("fiber")
		return true
	
	elif target.is_in_group("rocks"):
		if rock_hit_audio_player and rock_hit_audio_player.is_inside_tree():
			rock_hit_audio_player.pitch_scale = randf_range(0.9, 1.1)
			rock_hit_audio_player.play()
			
		vegetation_manager.harvest_rock_by_collider(target)
		_collect_vegetation_resource("rock")
		return true
	
	return false

func _try_damage_placed_object(target: Node, item: Dictionary, _position: Vector3) -> bool:
	if not target or not target.is_in_group("placed_objects") or not building_manager:
		return false
	
	var obj_rid = target.get_rid()
	var obj_dmg = item.get("damage", 1)
	var item_id = item.get("id", "")
	
	if "pickaxe" in item_id:
		obj_dmg = 5
	
	object_damage[obj_rid] = object_damage.get(obj_rid, 0) + obj_dmg
	var current_hp = OBJECT_HP - object_damage[obj_rid]
	durability_target = obj_rid
	
	_emit_durability_hit(current_hp, OBJECT_HP, target.name, durability_target)
	
	if object_damage[obj_rid] >= OBJECT_HP:
		if target.has_meta("anchor") and target.has_meta("chunk"):
			var anchor = target.get_meta("anchor")
			var chunk = target.get_meta("chunk")
			chunk.remove_object(anchor)
		object_damage.erase(obj_rid)
		_emit_durability_cleared()
	
	return true

func _try_damage_building_block(target: Node, item: Dictionary, position: Vector3, hit: Dictionary) -> bool:
	if not target or not building_manager:
		return false
	
	var chunk = _find_building_chunk(target)
	if not chunk:
		return false
	
	# Use SAME snapping logic as terrain damage (lines 611-613) for consistency with HUD
	var hit_normal = hit.get("normal", Vector3.UP)
	var snapped_pos = position - hit_normal * 0.1
	snapped_pos = Vector3(floor(snapped_pos.x) + 0.5, floor(snapped_pos.y) + 0.5, floor(snapped_pos.z) + 0.5)
	var block_pos = Vector3i(floor(snapped_pos.x), floor(snapped_pos.y), floor(snapped_pos.z))
	
	var blk_dmg = item.get("damage", 1)
	var item_id = item.get("id", "")
	
	if "pickaxe" in item_id:
		blk_dmg = 5
	
	block_damage[block_pos] = block_damage.get(block_pos, 0) + blk_dmg
	var current_hp = BLOCK_HP - block_damage[block_pos]
	durability_target = block_pos
	
	if block_damage[block_pos] >= BLOCK_HP:
		# Play break sound (range 4)
		_play_audio_range(wood_block_hit_audio_player, WOOD_AUDIO_RANGES["break"])
	else:
		# Play random hit sound (ranges 1-3)
		var rand_idx = randi() % 3 + 1
		_play_audio_range(wood_block_hit_audio_player, WOOD_AUDIO_RANGES["hit_%d" % rand_idx])
	
	print("DURABILITY_DEBUG: Building block hit at %s | Damage: %d | HP: %d/%d" % [block_pos, blk_dmg, current_hp, BLOCK_HP])
	_emit_durability_hit(current_hp, BLOCK_HP, "Block", durability_target)
	
	if block_damage[block_pos] >= BLOCK_HP:
		var voxel_pos = position - hit.get("normal", Vector3.ZERO) * 0.1
		var voxel_coord = Vector3(floor(voxel_pos.x), floor(voxel_pos.y), floor(voxel_pos.z))
		
		var voxel_id = 0
		if building_manager.has_method("get_voxel"):
			voxel_id = building_manager.get_voxel(voxel_pos)
		
		building_manager.set_voxel(voxel_coord, 0.0)
		block_damage.erase(block_pos)
		_emit_durability_cleared()
		
		if voxel_id > 0:
			_collect_building_resource(voxel_id)
	
	return true

func _find_building_chunk(collider: Node) -> Node:
	if not collider:
		return null
	
	if collider.is_in_group("building_chunks"):
		return collider
	
	var node = collider.get_parent()
	while node:
		if node.is_in_group("building_chunks"):
			return node
		node = node.get_parent()
	
	return null

func _do_terrain_punch(item: Dictionary, position: Vector3) -> void:
	if not terrain_manager or not terrain_manager.has_method("modify_terrain"):
		return
	
	var punch_dmg = item.get("damage", 1)
	var terrain_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
	
	terrain_damage[terrain_pos] = terrain_damage.get(terrain_pos, 0) + punch_dmg
	var current_hp = TERRAIN_HP - terrain_damage[terrain_pos]
	durability_target = terrain_pos
	

	
	_emit_durability_hit(current_hp, TERRAIN_HP, "Terrain", durability_target)
	
	if terrain_hit_audio_player:
		terrain_hit_audio_player.pitch_scale = randf_range(0.9, 1.1)
		terrain_hit_audio_player.play()
	
	if terrain_damage[terrain_pos] >= TERRAIN_HP:
		if terrain_break_audio_player:
			terrain_break_audio_player.pitch_scale = randf_range(0.95, 1.05)
			terrain_break_audio_player.play()
			
		var mat_id = -1
		if terrain_manager.has_method("get_material_at"):
			# Sample INSIDE terrain (0.3 units down from surface)
			var sample_pos = position - Vector3(0, 0.3, 0)
			mat_id = terrain_manager.get_material_at(sample_pos)
		
		var center = Vector3(terrain_pos) + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(center, 0.6, 1.0, 1, 0, -1)
		
		if mat_id >= 0:
			_collect_terrain_resource(mat_id)
		
		terrain_damage.erase(terrain_pos)
		_emit_durability_cleared()

func _check_durability_target() -> void:
	if durability_target == null or not player:
		return
	
	var hit = _raycast(5.0, true, true)
	if hit.is_empty():
		durability_target = null
		return
	
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	var hit_normal = hit.get("normal", Vector3.UP)
	
	if durability_target is RID:
		if target and target.get_rid() == durability_target:
			return
	elif durability_target is Vector3i:
		# Use SAME snapping logic as terrain/building damage (lines 611-613, 1114-1117)
		var snapped_pos = position - hit_normal * 0.1
		snapped_pos = Vector3(floor(snapped_pos.x) + 0.5, floor(snapped_pos.y) + 0.5, floor(snapped_pos.z) + 0.5)
		var block_pos = Vector3i(floor(snapped_pos.x), floor(snapped_pos.y), floor(snapped_pos.z))
		if block_pos == durability_target:
			return
	
	durability_target = null

func _spawn_pistol_hit_effect(pos: Vector3) -> void:
	# Check if markers are enabled
	if has_node("/root/PistolHitMarkerConfig"):
		if not get_node("/root/PistolHitMarkerConfig").enabled:
			return
	
	var mesh_instance = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.05
	sphere.height = 0.1
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color.RED
	mat.emission_enabled = true
	mat.emission = Color.RED
	mat.emission_energy_multiplier = 2.0
	
	mesh_instance.mesh = sphere
	mesh_instance.material_override = mat
	
	get_tree().root.add_child(mesh_instance)
	mesh_instance.global_position = pos
	
	await get_tree().create_timer(2.0).timeout.connect(func(): 
		if is_instance_valid(mesh_instance):
			mesh_instance.queue_free()
	)

## Helper to play a specific range of an audio file using a temporary player
func _play_audio_range(template_player: AudioStreamPlayer3D, range_data: Array) -> void:
	if not template_player or range_data.size() < 2:
		return
		
	var start_time = range_data[0]
	var duration = range_data[1]
	
	# Create a temporary player to allow overlapping sounds
	var temp_player = AudioStreamPlayer3D.new()
	temp_player.stream = template_player.stream
	temp_player.max_distance = template_player.max_distance
	temp_player.unit_size = template_player.unit_size
	temp_player.bus = template_player.bus
	temp_player.pitch_scale = randf_range(0.95, 1.05)
	
	# Add to scene
	if player:
		player.add_child(temp_player)
	else:
		get_tree().root.add_child(temp_player)
		temp_player.global_position = template_player.global_position
	
	temp_player.play(start_time)
	print("[COMBAT_AUDIO] Playing range: %.2f to %.2f (Dur: %.2f) [TempPlayer]" % [start_time, start_time + duration, duration])
	
	# Schedule self-destruction
	get_tree().create_timer(duration).timeout.connect(func():
		if is_instance_valid(temp_player):
			temp_player.stop()
			temp_player.queue_free()
	)
# ============================================================================
# RESOURCE COLLECTION
# ============================================================================

func _collect_terrain_resource(mat_id: int) -> void:
	var resource_item = ItemDefs.get_resource_for_material(mat_id)
	if resource_item.is_empty():
		return
	
	# Try to add to hotbar first
	if hotbar and hotbar.has_method("add_item"):
		if hotbar.add_item(resource_item):
			DebugManager.log_player("CombatSystem: Collected 1x %s to hotbar" % resource_item.get("name", "Resource"))
			return
	
	# Fall back to inventory if hotbar is full
	var inventory = player.get_node_or_null("Systems/Inventory") if player else null
	if inventory and inventory.has_method("add_item"):
		var leftover = inventory.add_item(resource_item, 1)
		if leftover == 0:
			DebugManager.log_player("CombatSystem: Collected 1x %s to inventory" % resource_item.get("name", "Resource"))

func _collect_vegetation_resource(veg_type: String) -> void:
	var resource_item = ItemDefs.get_vegetation_resource(veg_type)
	if resource_item.is_empty():
		DebugManager.log_player("CombatSystem: No resource for vegetation type '%s'" % veg_type)
		return
	
	# Try to add to hotbar first (for quick access)
	if hotbar and hotbar.has_method("add_item"):
		if hotbar.add_item(resource_item):
			DebugManager.log_player("CombatSystem: Collected 1x %s to hotbar" % resource_item.get("name", "Resource"))
			return
	
	# Fall back to inventory if hotbar is full
	var inventory = player.get_node_or_null("Systems/Inventory") if player else null
	if inventory and inventory.has_method("add_item"):
		var leftover = inventory.add_item(resource_item, 1)
		if leftover == 0:
			DebugManager.log_player("CombatSystem: Collected 1x %s to inventory" % resource_item.get("name", "Resource"))
		else:
			DebugManager.log_player("CombatSystem: Inventory full, dropped %s" % resource_item.get("name", "Resource"))
	else:
		DebugManager.log_player("CombatSystem: No inventory system found")

func _collect_building_resource(voxel_id: int) -> void:
	var resource_item = ItemDefs.get_item_for_block(voxel_id)
	if resource_item.is_empty():
		return
	
	# Try to add to hotbar first
	if hotbar and hotbar.has_method("add_item"):
		if hotbar.add_item(resource_item):
			DebugManager.log_player("CombatSystem: Collected 1x building resource to hotbar")
			return
	
	# Fall back to inventory if hotbar is full
	var inventory = player.get_node_or_null("Systems/Inventory") if player else null
	if inventory and inventory.has_method("add_item"):
		inventory.add_item(resource_item, 1)

# ============================================================================
# SIGNAL EMISSION (Local + Backward Compat)
# ============================================================================

func _emit_punch_triggered() -> void:
	if signals and signals.has_signal("punch_triggered"):
		signals.punch_triggered.emit()
	if has_node("/root/PlayerSignals"):
		PlayerSignals.punch_triggered.emit()

func _emit_pistol_fired() -> void:
	if signals and signals.has_signal("pistol_fired"):
		signals.pistol_fired.emit()
	if has_node("/root/PlayerSignals"):
		PlayerSignals.pistol_fired.emit()

func _emit_axe_fired() -> void:
	if signals and signals.has_signal("axe_fired"):
		signals.axe_fired.emit()
	if has_node("/root/PlayerSignals"):
		PlayerSignals.axe_fired.emit()

func _emit_damage_dealt(target: Node, amount: int) -> void:
	if signals and signals.has_signal("damage_dealt"):
		signals.damage_dealt.emit(target, amount)
	if has_node("/root/PlayerSignals"):
		PlayerSignals.damage_dealt.emit(target, amount)

func _emit_durability_hit(current_hp: int, max_hp: int, target_name: String, target_ref: Variant) -> void:
	if signals and signals.has_signal("durability_hit"):
		signals.durability_hit.emit(current_hp, max_hp, target_name, target_ref)
	if has_node("/root/PlayerSignals"):
		PlayerSignals.durability_hit.emit(current_hp, max_hp, target_name, target_ref)

func _emit_durability_cleared() -> void:
	if signals and signals.has_signal("durability_cleared"):
		signals.durability_cleared.emit()
	if has_node("/root/PlayerSignals"):
		PlayerSignals.durability_cleared.emit()

## Spawn a visual debug marker at hit position
func _spawn_hit_marker(position: Vector3, color: Color) -> void:
	var marker = MeshInstance3D.new()
	marker.mesh = SphereMesh.new()
	marker.mesh.radius = 0.1
	marker.mesh.height = 0.2
	
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.0
	marker.set_surface_override_material(0, material)
	
	get_tree().root.add_child(marker)
	marker.global_position = position
	
	# Auto-delete after 3 seconds
	get_tree().create_timer(3.0).timeout.connect(func(): 
		if is_instance_valid(marker):
			marker.queue_free()
	)
