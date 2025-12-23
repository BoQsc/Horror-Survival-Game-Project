extends Node
class_name ModePlay
## ModePlay - Handles PLAY mode behaviors
## Combat, mining terrain, harvesting vegetation

# References
var player: WorldPlayer = null
var hotbar: Node = null
var mode_manager: Node = null

# Manager references
var terrain_manager: Node = null
var vegetation_manager: Node = null

# Selection box for RESOURCE/BUCKET placement
var selection_box: MeshInstance3D = null
var current_target_pos: Vector3 = Vector3.ZERO
var has_target: bool = false

# Combat state
var attack_cooldown: float = 0.0
const ATTACK_COOLDOWN_TIME: float = 0.3

func _ready() -> void:
	# Find player - ModePlay is child of Modes which is child of WorldPlayer
	player = get_parent().get_parent() as WorldPlayer
	
	# Find hotbar - go up to WorldPlayer, then down to Systems/Hotbar
	hotbar = get_node_or_null("../../Systems/Hotbar")
	mode_manager = get_node_or_null("../../Systems/ModeManager")
	
	# Find managers via groups
	await get_tree().process_frame
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	
	# Create selection box for terrain resource placement
	_create_selection_box()
	
	print("ModePlay: Initialized")
	print("  - Player: %s" % ("OK" if player else "MISSING"))
	print("  - Hotbar: %s" % ("OK" if hotbar else "MISSING"))
	print("  - TerrainManager: %s" % ("OK" if terrain_manager else "NOT FOUND"))
	print("  - VegetationManager: %s" % ("OK" if vegetation_manager else "NOT FOUND"))

func _create_selection_box() -> void:
	selection_box = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.01, 1.01, 1.01)
	selection_box.mesh = box_mesh
	
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.4, 0.8, 0.3, 0.5) # Green/brown for terrain
	selection_box.material_override = material
	selection_box.visible = false
	
	get_tree().root.add_child.call_deferred(selection_box)

func _process(delta: float) -> void:
	if attack_cooldown > 0:
		attack_cooldown -= delta
	
	# Update selection box for RESOURCE/BUCKET items
	_update_terrain_targeting()

func _update_terrain_targeting() -> void:
	if not player or not hotbar or not selection_box:
		return
	
	# Only show when in PLAY mode with RESOURCE or BUCKET selected
	if mode_manager and not mode_manager.is_play_mode():
		selection_box.visible = false
		has_target = false
		return
	
	var item = hotbar.get_selected_item()
	var category = item.get("category", 0)
	
	# Categories: 2=BUCKET, 3=RESOURCE
	if category != 2 and category != 3:
		selection_box.visible = false
		has_target = false
		return
	
	# Raycast to find target
	var hit = player.raycast(5.0)
	if hit.is_empty():
		selection_box.visible = false
		has_target = false
		return
	
	has_target = true
	
	# Calculate adjacent voxel position (where block will be placed)
	var pos = hit.position + hit.normal * 0.1
	current_target_pos = Vector3(floor(pos.x), floor(pos.y), floor(pos.z))
	
	# Update selection box position
	selection_box.global_position = current_target_pos + Vector3(0.5, 0.5, 0.5)
	selection_box.visible = true

## Handle primary action (left click) in PLAY mode
func handle_primary(item: Dictionary) -> void:
	print("ModePlay: handle_primary called with item: %s" % item.get("name", "unknown"))
	
	if attack_cooldown > 0:
		print("ModePlay: Still on cooldown (%.2f)" % attack_cooldown)
		return
	
	var category = item.get("category", 0)
	print("ModePlay: Category = %d" % category)
	
	match category:
		0: # NONE - Fists
			_do_punch(item)
		1: # TOOL
			_do_tool_attack(item)
		2: # BUCKET
			_do_bucket_collect(item)
		3: # RESOURCE
			pass # No primary action for resources

## Handle secondary action (right click) in PLAY mode
func handle_secondary(item: Dictionary) -> void:
	var category = item.get("category", 0)
	
	match category:
		0: # NONE - Fists
			pass # No secondary for fists
		1: # TOOL
			pass # No secondary for tools
		2: # BUCKET
			_do_bucket_place(item)
		3: # RESOURCE
			_do_resource_place(item)

## Punch attack with fists
func _do_punch(item: Dictionary) -> void:
	if not player:
		return
	
	attack_cooldown = ATTACK_COOLDOWN_TIME
	
	var hit = player.raycast(2.5) # Melee range
	if hit.is_empty():
		print("ModePlay: Punch - miss")
		return
	
	var damage = item.get("damage", 1)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	print("ModePlay: Punch - hit %s" % (target.name if target else "nothing"))
	
	# Check for damageable target
	if target and target.has_method("take_damage"):
		target.take_damage(damage)
		print("ModePlay: Punched %s for %d damage" % [target.name, damage])
		PlayerSignals.damage_dealt.emit(target, damage)
		return
	
	# Check for harvestable vegetation
	if target and vegetation_manager:
		if target.is_in_group("trees"):
			vegetation_manager.chop_tree_by_collider(target)
			print("ModePlay: Punched tree")
			return
		elif target.is_in_group("grass"):
			vegetation_manager.harvest_grass_by_collider(target)
			print("ModePlay: Punched grass")
			return
		elif target.is_in_group("rocks"):
			vegetation_manager.harvest_rock_by_collider(target)
			print("ModePlay: Punched rock")
			return
	
	# Default - hit terrain (modify it)
	if terrain_manager and terrain_manager.has_method("modify_terrain"):
		var strength = item.get("mining_strength", 0.5)
		if strength > 0:
			terrain_manager.modify_terrain(position, strength, 1.0, 0, 0)
			print("ModePlay: Punched terrain at %s (strength: %.1f)" % [position, strength])
		else:
			print("ModePlay: Item has no mining strength")
	else:
		print("ModePlay: No terrain_manager or missing modify_terrain method")

## Tool attack/mine
func _do_tool_attack(item: Dictionary) -> void:
	if not player:
		print("ModePlay: Tool attack - no player!")
		return
	
	attack_cooldown = ATTACK_COOLDOWN_TIME
	
	var hit = player.raycast(3.5) # Tool range
	if hit.is_empty():
		print("ModePlay: Tool attack - no hit")
		return
	
	var damage = item.get("damage", 1)
	var mining_strength = item.get("mining_strength", 1.0)
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	print("ModePlay: Tool hit %s at %s (mining_strength: %.1f)" % [target.name if target else "nothing", position, mining_strength])
	
	# Priority 1: Damage enemies
	if target and target.is_in_group("enemies") and target.has_method("take_damage"):
		target.take_damage(damage)
		print("ModePlay: Hit enemy for %d damage" % damage)
		PlayerSignals.damage_dealt.emit(target, damage)
		return
	
	# Priority 2: Harvest vegetation
	if target and vegetation_manager:
		if target.is_in_group("trees"):
			vegetation_manager.chop_tree_by_collider(target)
			print("ModePlay: Chopped tree with %s" % item.get("name", "tool"))
			return
		elif target.is_in_group("grass"):
			vegetation_manager.harvest_grass_by_collider(target)
			print("ModePlay: Harvested grass")
			return
		elif target.is_in_group("rocks"):
			vegetation_manager.harvest_rock_by_collider(target)
			print("ModePlay: Mined rock")
			return
	
	# Priority 3: Mine terrain
	print("ModePlay: Trying to mine terrain... terrain_manager=%s" % (terrain_manager != null))
	if terrain_manager:
		print("ModePlay: terrain_manager.has_method('modify_terrain')=%s" % terrain_manager.has_method("modify_terrain"))
		if terrain_manager.has_method("modify_terrain"):
			print("ModePlay: Calling modify_terrain(%s, %.1f, 1.0, 0, 0)" % [position, mining_strength])
			terrain_manager.modify_terrain(position, mining_strength, 1.0, 0, 0)
			print("ModePlay: Mined terrain at %s (strength: %.1f)" % [position, mining_strength])
		else:
			print("ModePlay: terrain_manager missing modify_terrain method!")
	else:
		print("ModePlay: terrain_manager is NULL!")

## Collect water with bucket
func _do_bucket_collect(_item: Dictionary) -> void:
	if not player or not terrain_manager:
		return
	
	var hit = player.raycast(5.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	
	# Check if there's water at this position
	if terrain_manager.has_method("get_water_density"):
		var density = terrain_manager.get_water_density(position)
		if density < 0: # In water
			terrain_manager.modify_terrain(position, 1.0, 1.0, 0, 1) # Remove water
			print("ModePlay: Collected water")
			# TODO: Switch bucket from empty to full

## Place water from bucket
func _do_bucket_place(_item: Dictionary) -> void:
	if not player or not terrain_manager:
		return
	
	# Use grid-aligned position if targeting is active
	if has_target:
		var center = current_target_pos + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(center, 0.6, -0.5, 1, 1) # Box shape, fill, water layer
		print("ModePlay: Placed water at %s" % current_target_pos)
	else:
		var hit = player.raycast(5.0)
		if hit.is_empty():
			return
		var pos = hit.position + hit.normal * 0.5
		terrain_manager.modify_terrain(pos, 0.6, -0.5, 1, 1)
		print("ModePlay: Placed water at %s" % pos)
	# TODO: Switch bucket from full to empty

## Place resource (terrain material)
func _do_resource_place(item: Dictionary) -> void:
	if not player or not terrain_manager:
		return
	
	# Use grid-aligned position if targeting is active
	if has_target:
		var center = current_target_pos + Vector3(0.5, 0.5, 0.5)
		terrain_manager.modify_terrain(center, 0.6, -0.5, 1, 0) # Box shape, fill, terrain layer
		print("ModePlay: Placed %s at %s" % [item.get("name", "resource"), current_target_pos])
	else:
		var hit = player.raycast(5.0)
		if hit.is_empty():
			return
		var pos = hit.position + hit.normal * 0.5
		terrain_manager.modify_terrain(pos, 0.6, -0.5, 1, 0)
		print("ModePlay: Placed %s at %s" % [item.get("name", "resource"), pos])

func _exit_tree() -> void:
	if selection_box and is_instance_valid(selection_box):
		selection_box.queue_free()
