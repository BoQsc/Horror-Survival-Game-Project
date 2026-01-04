extends CharacterBody3D
class_name WorldPlayer
## WorldPlayer - Main player coordinator script
## Wires components together and provides external interface.

# Component references (populated in _ready)
var movement_component: PlayerMovement = null
var camera_component: PlayerCamera = null

# Manager references (found via groups)
var terrain_manager: Node = null
var building_manager: Node = null
var vegetation_manager: Node = null

func _ready() -> void:
	# Find components
	var components_node = get_node_or_null("Components")
	if components_node:
		movement_component = components_node.get_node_or_null("Movement")
		camera_component = components_node.get_node_or_null("Camera")
	
	# Find managers via groups
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	building_manager = get_tree().get_first_node_in_group("building_manager")
	vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	
	# Log initialization status
	DebugManager.log_player("WorldPlayer: Initialized")
	DebugManager.log_player("  - Movement: %s" % ("OK" if movement_component else "MISSING"))
	DebugManager.log_player("  - Camera: %s" % ("OK" if camera_component else "MISSING"))
	DebugManager.log_player("  - TerrainManager: %s" % ("OK" if terrain_manager else "NOT FOUND"))
	DebugManager.log_player("  - BuildingManager: %s" % ("OK" if building_manager else "NOT FOUND"))
	DebugManager.log_player("  - VegetationManager: %s" % ("OK" if vegetation_manager else "NOT FOUND"))

## Get look direction from camera component
func get_look_direction() -> Vector3:
	if camera_component:
		return camera_component.get_look_direction()
	return Vector3.FORWARD

## Get camera position from camera component
func get_camera_position() -> Vector3:
	if camera_component:
		return camera_component.get_camera_position()
	return global_position + Vector3(0, 1.6, 0)

## Perform raycast from camera
func raycast(distance: float = 10.0, mask: int = 0xFFFFFFFF, collide_with_areas: bool = false, exclude_water: bool = false) -> Dictionary:
	if camera_component:
		return camera_component.raycast(distance, mask, collide_with_areas, exclude_water)
	return {}

## Take damage (delegates to PlayerStats autoload)
func take_damage(amount: int, source: Node = null) -> void:
	PlayerStats.take_damage(amount, source)

## Heal (delegates to PlayerStats autoload)
func heal(amount: int) -> void:
	PlayerStats.heal(amount)
