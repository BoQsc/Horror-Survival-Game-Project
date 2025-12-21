extends Node
class_name ModeBuild
## ModeBuild - Handles BUILD mode behaviors
## Block, object, and prop placement/removal

# References
var player: WorldPlayer = null
var hotbar: Node = null
var mode_manager: Node = null

# Manager references
var building_manager: Node = null

# Build state
var current_rotation: int = 0
var grid_snap_props: bool = false # Toggle for prop placement

# Preview (future)
var preview_instance: Node3D = null

func _ready() -> void:
	# Find player
	player = get_parent().get_parent() as WorldPlayer
	
	# Find siblings
	hotbar = get_node_or_null("../../Systems/Hotbar")
	mode_manager = get_node_or_null("../ModeManager")
	
	# Find managers via groups
	await get_tree().process_frame
	building_manager = get_tree().get_first_node_in_group("building_manager")
	
	print("ModeBuild: Initialized")

func _input(event: InputEvent) -> void:
	# Only handle input in BUILD mode
	if not mode_manager or not mode_manager.is_build_mode():
		return
	
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R:
				# Rotate placement
				current_rotation = (current_rotation + 1) % 4
				print("ModeBuild: Rotation -> %d (%.0f°)" % [current_rotation, current_rotation * 90.0])
			KEY_G:
				# Toggle grid snap for props
				grid_snap_props = not grid_snap_props
				print("ModeBuild: Grid snap -> %s" % ("ON" if grid_snap_props else "OFF"))
	
	# Scroll to rotate
	if event is InputEventMouseButton and event.pressed:
		if event.ctrl_pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				current_rotation = (current_rotation + 1) % 4
				print("ModeBuild: Rotation -> %d" % current_rotation)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				current_rotation = (current_rotation - 1 + 4) % 4
				print("ModeBuild: Rotation -> %d" % current_rotation)

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
	
	match category:
		4: # BLOCK
			_do_block_place(item)
		5: # OBJECT
			_do_object_place(item)
		6: # PROP
			_do_prop_place(item)

## Remove block at target
func _do_block_remove() -> void:
	if not player or not building_manager:
		return
	
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var target = hit.get("collider")
	
	# Check if we hit a building chunk
	if target and target.get_parent():
		var _parent_class = target.get_parent().get_class() if target.get_parent().has_method("get_class") else ""
		if "BuildingChunk" in str(target.get_parent()):
			var position = hit.get("position", Vector3.ZERO) - hit.get("normal", Vector3.ZERO) * 0.1
			var voxel_pos = Vector3(floor(position.x), floor(position.y), floor(position.z))
			
			if building_manager.has_method("set_voxel"):
				building_manager.set_voxel(voxel_pos, 0)
				print("ModeBuild: Removed block at %s" % voxel_pos)

## Place block at target
func _do_block_place(item: Dictionary) -> void:
	if not player or not building_manager:
		return
	
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO) + hit.get("normal", Vector3.UP) * 0.5
	var voxel_pos = Vector3(floor(position.x), floor(position.y), floor(position.z))
	var block_id = item.get("block_id", 1)
	
	if building_manager.has_method("set_voxel"):
		building_manager.set_voxel(voxel_pos, block_id, current_rotation)
		print("ModeBuild: Placed %s at %s (rot: %d)" % [item.get("name", "block"), voxel_pos, current_rotation])

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

## Place object at target
func _do_object_place(item: Dictionary) -> void:
	if not player or not building_manager:
		return
	
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var object_id = item.get("object_id", 1)
	
	if building_manager.has_method("place_object"):
		var success = building_manager.place_object(position, object_id, current_rotation)
		if success:
			print("ModeBuild: Placed %s at %s" % [item.get("name", "object"), position])
		else:
			print("ModeBuild: Cannot place - cells occupied")

## Remove prop (same as object for now)
func _do_prop_remove() -> void:
	_do_object_remove()

## Place prop at target (free or grid-aligned)
func _do_prop_place(item: Dictionary) -> void:
	if not player or not building_manager:
		return
	
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var object_id = item.get("object_id", 1)
	
	# If grid snap is on, snap to grid
	if grid_snap_props:
		position = Vector3(floor(position.x), position.y, floor(position.z))
	
	if building_manager.has_method("place_object"):
		var success = building_manager.place_object(position, object_id, current_rotation)
		if success:
			print("ModeBuild: Placed prop %s at %s (grid: %s)" % [item.get("name", "prop"), position, grid_snap_props])
		else:
			print("ModeBuild: Cannot place prop - cells occupied")

## Get current rotation
func get_rotation() -> int:
	return current_rotation

## Set rotation
func set_rotation(rot: int) -> void:
	current_rotation = rot % 4
