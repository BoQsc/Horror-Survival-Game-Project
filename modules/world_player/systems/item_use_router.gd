extends Node
class_name ItemUseRouter
## ItemUseRouter - Routes primary/secondary actions based on held item category
## Delegates to appropriate mode handlers

# References
var hotbar: Hotbar = null
var mode_manager: ModeManager = null
var player: WorldPlayer = null

# Preload item definitions
const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")

# Manager references (found via groups)
var terrain_manager: Node = null
var building_manager: Node = null
var vegetation_manager: Node = null

func _ready() -> void:
	# Find sibling components
	hotbar = get_node_or_null("../Hotbar")
	mode_manager = get_node_or_null("../ModeManager")
	
	# Find player (parent of Systems node)
	player = get_parent().get_parent() as WorldPlayer
	
	# Find managers via groups
	await get_tree().process_frame # Wait for scene to be ready
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	building_manager = get_tree().get_first_node_in_group("building_manager")
	vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	
	print("ItemUseRouter: Initialized")
	print("  - Hotbar: %s" % ("OK" if hotbar else "MISSING"))
	print("  - ModeManager: %s" % ("OK" if mode_manager else "MISSING"))
	print("  - TerrainManager: %s" % ("OK" if terrain_manager else "NOT FOUND"))

func _unhandled_input(event: InputEvent) -> void:
	if not hotbar or not player:
		return
	
	# Only process mouse clicks when captured
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	
	if event is InputEventMouseButton and event.pressed:
		var item = hotbar.get_selected_item()
		
		if event.button_index == MOUSE_BUTTON_LEFT:
			route_primary_action(item)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			route_secondary_action(item)

## Route left-click action based on item category
func route_primary_action(item: Dictionary) -> void:
	var category = item.get("category", ItemDefs.ItemCategory.NONE)
	
	# EDITOR mode has its own handling
	if mode_manager and mode_manager.is_editor_mode():
		_handle_editor_primary(item)
		return
	
	match category:
		ItemDefs.ItemCategory.NONE:
			# Fists - melee punch
			_do_melee_attack(item)
		ItemDefs.ItemCategory.TOOL:
			# Tool - melee attack OR mine terrain (context dependent)
			_do_tool_action(item)
		ItemDefs.ItemCategory.BUCKET:
			# Bucket - remove water
			_do_bucket_remove(item)
		ItemDefs.ItemCategory.RESOURCE:
			# Resource - no primary action (place with right click)
			pass
		ItemDefs.ItemCategory.BLOCK:
			# Block - remove existing block
			_do_block_remove(item)
		ItemDefs.ItemCategory.OBJECT:
			# Object - remove existing object
			_do_object_remove(item)
		ItemDefs.ItemCategory.PROP:
			# Prop - remove existing prop
			_do_prop_remove(item)

## Route right-click action based on item category
func route_secondary_action(item: Dictionary) -> void:
	var category = item.get("category", ItemDefs.ItemCategory.NONE)
	
	# EDITOR mode has its own handling
	if mode_manager and mode_manager.is_editor_mode():
		_handle_editor_secondary(item)
		return
	
	match category:
		ItemDefs.ItemCategory.NONE:
			# Fists - no secondary action
			pass
		ItemDefs.ItemCategory.TOOL:
			# Tool - no secondary action (maybe block later?)
			pass
		ItemDefs.ItemCategory.BUCKET:
			# Bucket - place water
			_do_bucket_place(item)
		ItemDefs.ItemCategory.RESOURCE:
			# Resource - place terrain material
			_do_resource_place(item)
		ItemDefs.ItemCategory.BLOCK:
			# Block - place block
			_do_block_place(item)
		ItemDefs.ItemCategory.OBJECT:
			# Object - place object
			_do_object_place(item)
		ItemDefs.ItemCategory.PROP:
			# Prop - place prop
			_do_prop_place(item)

# =====================
# PLAY MODE ACTIONS
# =====================

func _do_melee_attack(item: Dictionary) -> void:
	var hit = player.raycast(2.5) # Melee range
	if hit.is_empty():
		print("ItemUseRouter: Punch - no target")
		return
	
	var damage = item.get("damage", 1)
	var target = hit.get("collider")
	
	if target and target.has_method("take_damage"):
		target.take_damage(damage)
		print("ItemUseRouter: Punched %s for %d damage" % [target.name, damage])
		PlayerSignals.damage_dealt.emit(target, damage)
	else:
		print("ItemUseRouter: Punched %s (no damage method)" % (target.name if target else "nothing"))

func _do_tool_action(item: Dictionary) -> void:
	var hit = player.raycast(3.0) # Tool range
	if hit.is_empty():
		return
	
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	# Check if we hit an enemy
	if target and target.is_in_group("enemies") and target.has_method("take_damage"):
		var damage = item.get("damage", 1)
		target.take_damage(damage)
		print("ItemUseRouter: Hit %s for %d damage" % [target.name, damage])
		PlayerSignals.damage_dealt.emit(target, damage)
		return
	
	# Check if we hit terrain - mine it
	if terrain_manager and terrain_manager.has_method("modify_terrain"):
		var strength = item.get("mining_strength", 1.0)
		terrain_manager.modify_terrain(position, strength, 1.0, 0, 0) # Dig terrain
		print("ItemUseRouter: Mined terrain at %s (strength: %.1f)" % [position, strength])

func _do_bucket_remove(_item: Dictionary) -> void:
	var hit = player.raycast(5.0)
	if hit.is_empty():
		return
	
	if terrain_manager and terrain_manager.has_method("modify_terrain"):
		var position = hit.get("position", Vector3.ZERO)
		terrain_manager.modify_terrain(position, 1.0, 1.0, 0, 1) # Remove water
		print("ItemUseRouter: Removed water at %s" % position)

func _do_bucket_place(_item: Dictionary) -> void:
	var hit = player.raycast(5.0)
	if hit.is_empty():
		return
	
	if terrain_manager and terrain_manager.has_method("modify_terrain"):
		var position = hit.get("position", Vector3.ZERO) + hit.get("normal", Vector3.UP) * 0.5
		terrain_manager.modify_terrain(position, 1.0, -1.0, 0, 1) # Add water
		print("ItemUseRouter: Placed water at %s" % position)

func _do_resource_place(item: Dictionary) -> void:
	var hit = player.raycast(5.0)
	if hit.is_empty():
		return
	
	if terrain_manager and terrain_manager.has_method("modify_terrain"):
		var position = hit.get("position", Vector3.ZERO) + hit.get("normal", Vector3.UP) * 0.5
		terrain_manager.modify_terrain(position, 1.0, -1.0, 0, 0) # Place terrain
		print("ItemUseRouter: Placed %s at %s" % [item.get("name", "resource"), position])

# =====================
# BUILD MODE ACTIONS
# =====================

func _do_block_remove(_item: Dictionary) -> void:
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var target = hit.get("collider")
	if target and target.get_parent() and target.get_parent().has_method("get_class"):
		# Check if it's a building chunk
		var position = hit.get("position", Vector3.ZERO) - hit.get("normal", Vector3.ZERO) * 0.1
		var voxel_pos = Vector3(floor(position.x), floor(position.y), floor(position.z))
		
		if building_manager and building_manager.has_method("set_voxel"):
			building_manager.set_voxel(voxel_pos, 0)
			print("ItemUseRouter: Removed block at %s" % voxel_pos)

func _do_block_place(item: Dictionary) -> void:
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO) + hit.get("normal", Vector3.UP) * 0.5
	var voxel_pos = Vector3(floor(position.x), floor(position.y), floor(position.z))
	var block_id = item.get("block_id", 1)
	
	if building_manager and building_manager.has_method("set_voxel"):
		building_manager.set_voxel(voxel_pos, block_id, 0)
		print("ItemUseRouter: Placed %s at %s" % [item.get("name", "block"), voxel_pos])

func _do_object_remove(_item: Dictionary) -> void:
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var target = hit.get("collider")
	if target and target.is_in_group("placed_objects"):
		if target.has_meta("anchor") and target.has_meta("chunk"):
			var anchor = target.get_meta("anchor")
			var chunk = target.get_meta("chunk")
			if chunk and chunk.has_method("remove_object"):
				chunk.remove_object(anchor)
				print("ItemUseRouter: Removed object at %s" % anchor)

func _do_object_place(item: Dictionary) -> void:
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var object_id = item.get("object_id", 1)
	
	if building_manager and building_manager.has_method("place_object"):
		var success = building_manager.place_object(position, object_id, 0)
		if success:
			print("ItemUseRouter: Placed %s at %s" % [item.get("name", "object"), position])
		else:
			print("ItemUseRouter: Could not place object - cells occupied")

func _do_prop_remove(item: Dictionary) -> void:
	# Same as object remove for now
	_do_object_remove(item)

func _do_prop_place(item: Dictionary) -> void:
	# Props are free-placed (not grid aligned) - handled same as object for now
	_do_object_place(item)

# =====================
# EDITOR MODE ACTIONS
# =====================

func _handle_editor_primary(_item: Dictionary) -> void:
	if not mode_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	
	match mode_manager.editor_submode:
		ModeManager.EditorSubmode.TERRAIN:
			if terrain_manager and terrain_manager.has_method("modify_terrain"):
				terrain_manager.modify_terrain(position, 4.0, 1.0, 0, 0) # Dig
				print("ItemUseRouter: [EDITOR] Dug terrain at %s" % position)
		ModeManager.EditorSubmode.WATER:
			if terrain_manager and terrain_manager.has_method("modify_terrain"):
				terrain_manager.modify_terrain(position, 4.0, 1.0, 0, 1) # Remove water
				print("ItemUseRouter: [EDITOR] Removed water at %s" % position)
		_:
			print("ItemUseRouter: [EDITOR] Primary action not implemented for submode")

func _handle_editor_secondary(_item: Dictionary) -> void:
	if not mode_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	
	match mode_manager.editor_submode:
		ModeManager.EditorSubmode.TERRAIN:
			if terrain_manager and terrain_manager.has_method("modify_terrain"):
				terrain_manager.modify_terrain(position, 4.0, -1.0, 0, 0) # Place
				print("ItemUseRouter: [EDITOR] Placed terrain at %s" % position)
		ModeManager.EditorSubmode.WATER:
			if terrain_manager and terrain_manager.has_method("modify_terrain"):
				terrain_manager.modify_terrain(position, 4.0, -1.0, 0, 1) # Add water
				print("ItemUseRouter: [EDITOR] Added water at %s" % position)
		_:
			print("ItemUseRouter: [EDITOR] Secondary action not implemented for submode")
