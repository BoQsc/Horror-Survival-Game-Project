extends Node
class_name ModeBuild
## ModeBuild - Handles BUILD mode behaviors
## Block, object, and prop placement/removal

# Preload API scripts
const BuildingAPIScript = preload("res://modules/world_player/api/building_api.gd")
const ItemDefinitions = preload("res://modules/world_player/data/item_definitions.gd")
const ItemCategory = ItemDefinitions.ItemCategory

# References
var player: WorldPlayer = null
var hotbar: Node = null
var mode_manager: Node = null

# Manager references
var building_manager: Node = null

# API reference for selection box visualization
var building_api: Node = null

# Build state
var current_rotation: int = 0
var grid_snap_props: bool = false # Toggle for prop placement

func _ready() -> void:
	# Find player
	player = get_parent().get_parent() as WorldPlayer
	
	# Find siblings - ModeManager is in Systems node
	hotbar = get_node_or_null("../../Systems/Hotbar")
	mode_manager = get_node_or_null("../../Systems/ModeManager")
	
	# Find managers via groups
	await get_tree().process_frame
	building_manager = get_tree().get_first_node_in_group("building_manager")
	
	# Create building API for selection box visualization
	building_api = BuildingAPIScript.new()
	add_child(building_api)
	building_api.initialize(player)
	
	print("ModeBuild: Initialized")

func _process(_delta: float) -> void:
	# Update selection box when in build mode
	if mode_manager and mode_manager.is_build_mode() and building_api:
		# Update targeting from player raycast
		if player:
			var hit = player.raycast(10.0)
			building_api.update_targeting(hit)
			# Sync rotation
			building_api.current_rotation = current_rotation
		
		# MMB Freestyle toggle (continuous check, legacy port)
		var was_freestyle = building_api.is_freestyle
		building_api.is_freestyle = Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)
		if was_freestyle != building_api.is_freestyle:
			print("ModeBuild: Freestyle %s (MMB)" % ("ON" if building_api.is_freestyle else "OFF"))
		
		# Category-aware visuals: preview for OBJECT, selection box for BLOCK
		var item_data = _get_current_item_data()
		if item_data and item_data.get("category") == ItemCategory.OBJECT:
			# OBJECT: show preview, hide selection box (unless object_show_grid)
			building_api.current_object_id = item_data.get("object_id", 1)
			building_api.current_object_rotation = current_rotation
			building_api.update_or_create_preview()
			
			if building_api.object_show_grid:
				if building_api.selection_box:
					building_api.selection_box.visible = true
			else:
				if building_api.selection_box:
					building_api.selection_box.visible = false
		else:
			# BLOCK/PROP: destroy preview, show selection box
			building_api.destroy_preview()
	else:
		# Hide when not in build mode
		if building_api:
			building_api.hide_visuals()
			building_api.destroy_preview()

func _input(event: InputEvent) -> void:
	# Only handle input in BUILD mode
	if not mode_manager or not mode_manager.is_build_mode():
		return
	
	# E key: Hold for freestyle placement (legacy port)
	if event is InputEventKey and event.keycode == KEY_E:
		if building_api:
			if event.pressed and not event.echo:
				building_api.set_freestyle(true)
			elif not event.pressed:
				building_api.set_freestyle(false)
	
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R:
				# Rotate placement
				current_rotation = (current_rotation + 1) % 4
				print("ModeBuild: Rotation -> %d (%.0f°)" % [current_rotation, current_rotation * 90.0])
			KEY_G:
				# Toggle grid visibility 
				# In OBJECT mode: toggle object_show_grid
				# In BLOCK mode: toggle prop grid snap
				var item_data = _get_current_item_data()
				if item_data and item_data.get("category") == ItemCategory.OBJECT:
					building_api.object_show_grid = not building_api.object_show_grid
					print("ModeBuild: Object grid -> %s" % ("ON" if building_api.object_show_grid else "OFF"))
				else:
					grid_snap_props = not grid_snap_props
					print("ModeBuild: Grid snap -> %s" % ("ON" if grid_snap_props else "OFF"))
			KEY_V:
				# Cycle placement mode
				if building_api:
					building_api.cycle_placement_mode()
			KEY_Z:
				# Toggle smart surface align (legacy port)
				if building_api:
					building_api.smart_surface_align = not building_api.smart_surface_align
					print("ModeBuild: Smart align -> %s" % ("ON" if building_api.smart_surface_align else "OFF"))
	
	# Scroll to rotate
	if event is InputEventMouseButton and event.pressed:
		if event.ctrl_pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				current_rotation = (current_rotation + 1) % 4
				print("ModeBuild: Rotation -> %d" % current_rotation)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				current_rotation = (current_rotation - 1 + 4) % 4
				print("ModeBuild: Rotation -> %d" % current_rotation)
		elif event.shift_pressed:
			# Shift+Scroll: adjust Y offset
			if building_api:
				if event.button_index == MOUSE_BUTTON_WHEEL_UP:
					building_api.adjust_y_offset(1)
				elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					building_api.adjust_y_offset(-1)

## Handle primary action (left click) in BUILD mode - Remove
func handle_primary(item: Dictionary) -> void:
	var category = item.get("category", 0)
	
	match category:
		4: # BLOCK
			_do_block_remove()
		5: # OBJECT
			_do_object_remove()
		6: # PROP
			_do_prop_remove()

## Handle secondary action (right click) in BUILD mode - Place
func handle_secondary(item: Dictionary) -> void:
	var category = item.get("category", 0)
	print("ModeBuild: handle_secondary category=%d item=%s" % [category, item.get("name", "?")])
	
	match category:
		4: # BLOCK
			_do_block_place(item)
		5: # OBJECT
			_do_object_place(item)
		6: # PROP
			_do_prop_place(item)

## Helper to get current item data from hotbar
func _get_current_item_data() -> Dictionary:
	if hotbar and hotbar.has_method("get_item_at"):
		return hotbar.get_item_at(hotbar.selected_slot) if hotbar.has_method("get_selected_slot_item") else hotbar.get_item_at(hotbar.get("selected_slot"))
	return {}

## Remove block at target
func _do_block_remove() -> void:
	if not player or not building_manager:
		print("ModeBuild: Remove failed - no player or building_manager")
		return
	
	var hit = player.raycast(10.0)
	if hit.is_empty():
		print("ModeBuild: Remove failed - no raycast hit")
		return
	
	var target = hit.get("collider")
	if not target:
		print("ModeBuild: Remove failed - no collider")
		return
	
	# Walk up the node tree to check if this belongs to BuildingManager
	var node = target
	var is_building_block: bool = false
	for i in range(6):
		if not node:
			break
		# Check if this node IS the BuildingManager or has "BuildingManager" in name
		if node == building_manager or "BuildingManager" in str(node):
			is_building_block = true
			break
		# Also check for BuildingChunk script
		if node.get_script() and ("BuildingChunk" in str(node.get_script()) or "building_chunk" in str(node.get_script())):
			is_building_block = true
			break
		node = node.get_parent()
	
	if is_building_block:
		# Calculate voxel position from hit (slightly inside the block)
		var position = hit.get("position", Vector3.ZERO) - hit.get("normal", Vector3.ZERO) * 0.1
		var voxel_pos = Vector3(floor(position.x), floor(position.y), floor(position.z))
		
		if building_manager.has_method("set_voxel"):
			building_manager.set_voxel(voxel_pos, 0)
			print("ModeBuild: Removed block at %s" % voxel_pos)
	else:
		# Not a building block
		var p1 = target.get_parent() if target else null
		var p2 = p1.get_parent() if p1 else null
		print("ModeBuild: Not a building block. Parents: %s -> %s" % [p1, p2])

## Place block at target - uses building_api's calculated position to match visual
func _do_block_place(item: Dictionary) -> void:
	if not player or not building_manager:
		return
	
	# Use building_api for placement (handles FILL mode terrain gap)
	if building_api and building_api.has_target:
		var block_id = item.get("block_id", 1)
		
		# Sync block_id and rotation to building_api before placing
		building_api.current_block_id = block_id
		building_api.current_rotation = current_rotation
		
		# Call building_api.place_block which handles FILL mode terrain fill
		if building_api.place_block():
			_consume_held_item()
			return
		
		# Fallback: direct placement using building_api's position
		var voxel_pos = building_api.current_voxel_pos
		if building_manager.has_method("set_voxel"):
			building_manager.set_voxel(voxel_pos, block_id, current_rotation)
			print("ModeBuild: Placed %s at %s (rot: %d, direct)" % [item.get("name", "block"), voxel_pos, current_rotation])
		return
	
	# Fallback: old calculation if building_api not available
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var fb_position = hit.get("position", Vector3.ZERO) + hit.get("normal", Vector3.UP) * 0.5
	var fb_voxel_pos = Vector3(floor(fb_position.x), floor(fb_position.y), floor(fb_position.z))
	var fb_block_id = item.get("block_id", 1)
	
	if building_manager.has_method("set_voxel"):
		building_manager.set_voxel(fb_voxel_pos, fb_block_id, current_rotation)
		print("ModeBuild: Placed %s at %s (rot: %d, fallback)" % [item.get("name", "block"), fb_voxel_pos, current_rotation])
		_consume_held_item()

## Remove object at target
func _do_object_remove() -> void:
	if not player or not building_manager:
		return
	
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
				print("ModeBuild: Removed object at %s" % anchor)
				return
	
	# Fallback: position-based removal
	if building_manager.has_method("remove_object_at"):
		var position = hit.get("position", Vector3.ZERO) - hit.get("normal", Vector3.ZERO) * 0.1
		var success = building_manager.remove_object_at(position)
		if success:
			print("ModeBuild: Removed object at %s" % position)

## Place object at target - uses building_api with fractional Y (legacy port)
## Supports: Grid X/Z, fractional Y, freestyle mode, smart surface align, retry
func _do_object_place(item: Dictionary) -> void:
	if not player or not building_api:
		print("ModeBuild: Object place failed - no player or building_api")
		return
	
	var object_id = item.get("object_id", 1)
	
	# Sync object ID and rotation to building_api
	building_api.current_object_id = object_id
	building_api.current_object_rotation = current_rotation
	
	# Use building_api's place_object which handles:
	# - Fractional Y (sits on terrain)
	# - Freestyle mode with size compensation
	# - Smart surface align (sample corners)
	# - Retry logic for occupied cells
	if building_api.has_target:
		var success = building_api.place_object(object_id, current_rotation)
		if success:
			print("ModeBuild: Placed %s (rot: %d)" % [item.get("name", "object"), current_rotation])
			_consume_held_item()
		else:
			print("ModeBuild: Cannot place object - cells occupied")

## Remove prop (same as object for now)
func _do_prop_remove() -> void:
	_do_object_remove()

## Place prop at target (uses building_api if grid snap, else free placement)
func _do_prop_place(item: Dictionary) -> void:
	if not player or not building_manager:
		return
	
	var object_id = item.get("object_id", 1)
	
	# Use building_api's grid-aligned position when grid snap is on
	if grid_snap_props and building_api and building_api.has_target:
		var grid_pos = building_api.current_voxel_pos
		if building_manager.has_method("place_object"):
			var success = building_manager.place_object(grid_pos, object_id, current_rotation)
			if success:
				print("ModeBuild: Placed prop %s at %s (grid snap)" % [item.get("name", "prop"), grid_pos])
				_consume_held_item()
			else:
				print("ModeBuild: Cannot place prop - cells occupied")
		return
	
	# Free placement: use raw raycast position
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var free_pos = hit.get("position", Vector3.ZERO)
	if building_manager.has_method("place_object"):
		var success = building_manager.place_object(free_pos, object_id, current_rotation)
		if success:
			print("ModeBuild: Placed prop %s at %s (free)" % [item.get("name", "prop"), free_pos])
			_consume_held_item()
		else:
			print("ModeBuild: Cannot place prop - cells occupied")

## Get current rotation
func get_rotation() -> int:
	return current_rotation

## Set rotation
func set_rotation(rot: int) -> void:
	current_rotation = rot % 4

## Consume one item from the currently selected hotbar slot
func _consume_held_item() -> void:
	if hotbar and hotbar.has_method("decrement_slot") and hotbar.has_method("get_selected_index"):
		var idx = hotbar.get_selected_index()
		hotbar.decrement_slot(idx, 1)
