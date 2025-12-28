extends CharacterBody3D
class_name WorldPlayerV2
## WorldPlayerV2 - Feature-centric player coordinator
## Thin wrapper that wires features together. Each feature is self-contained.

# ============================================================================
# FEATURE REFERENCES (populated in _ready)
# ============================================================================

# Core features
var movement_feature: Node = null
var camera_feature: Node = null
var stats_feature: Node = null

# Gameplay features
var combat_feature: Node = null
var terrain_feature: Node = null
var inventory_feature: Node = null

# Manager references (found via groups)
var terrain_manager: Node = null
var building_manager: Node = null
var vegetation_manager: Node = null

func _ready() -> void:
	add_to_group("player")
	
	# Find features (children of Features node)
	var features_node = get_node_or_null("Features")
	if features_node:
		movement_feature = features_node.get_node_or_null("Movement/player_movement")
		camera_feature = features_node.get_node_or_null("Camera/player_camera")
		stats_feature = features_node.get_node_or_null("Stats/player_stats")
		combat_feature = features_node.get_node_or_null("Combat/combat_system")
		terrain_feature = features_node.get_node_or_null("Terrain/terrain_interaction")
	
	# Find Systems (for inventory/hotbar)
	var systems_node = get_node_or_null("Systems")
	if systems_node:
		inventory_feature = systems_node.get_node_or_null("Hotbar")
	
	# Find managers via groups (deferred to ensure they exist)
	await get_tree().process_frame
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	building_manager = get_tree().get_first_node_in_group("building_manager")
	vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	
	# Initialize features with shared references
	if combat_feature and combat_feature.has_method("initialize"):
		combat_feature.initialize(self, terrain_manager, vegetation_manager, building_manager, inventory_feature)
	
	if terrain_feature and terrain_feature.has_method("initialize"):
		terrain_feature.initialize(self, terrain_manager, inventory_feature)
	
	_log_initialization()

func _log_initialization() -> void:
	DebugSettings.log_player("WorldPlayerV2: Initialized")
	DebugSettings.log_player("  Features:")
	DebugSettings.log_player("    - Movement: %s" % ("OK" if movement_feature else "MISSING"))
	DebugSettings.log_player("    - Camera: %s" % ("OK" if camera_feature else "MISSING"))
	DebugSettings.log_player("    - Stats: %s" % ("OK" if stats_feature else "MISSING"))
	DebugSettings.log_player("    - Combat: %s" % ("OK" if combat_feature else "MISSING"))
	DebugSettings.log_player("    - Terrain: %s" % ("OK" if terrain_feature else "MISSING"))
	DebugSettings.log_player("  Managers:")
	DebugSettings.log_player("    - TerrainManager: %s" % ("OK" if terrain_manager else "NOT FOUND"))
	DebugSettings.log_player("    - BuildingManager: %s" % ("OK" if building_manager else "NOT FOUND"))
	DebugSettings.log_player("    - VegetationManager: %s" % ("OK" if vegetation_manager else "NOT FOUND"))

# ============================================================================
# PUBLIC API (delegated to features)
# ============================================================================

## Get look direction from camera
func get_look_direction() -> Vector3:
	if camera_feature and camera_feature.has_method("get_look_direction"):
		return camera_feature.get_look_direction()
	return Vector3.FORWARD

## Get camera position
func get_camera_position() -> Vector3:
	if camera_feature and camera_feature.has_method("get_camera_position"):
		return camera_feature.get_camera_position()
	return global_position + Vector3(0, 1.6, 0)

## Perform raycast from camera
func raycast(distance: float = 10.0, mask: int = 0xFFFFFFFF, collide_with_areas: bool = false, exclude_water: bool = false) -> Dictionary:
	if camera_feature and camera_feature.has_method("raycast"):
		return camera_feature.raycast(distance, mask, collide_with_areas, exclude_water)
	return {}

## Take damage
func take_damage(amount: int, source: Node = null) -> void:
	if stats_feature and stats_feature.has_method("take_damage"):
		stats_feature.take_damage(amount, source)
	# Backward compat
	elif has_node("/root/PlayerStats"):
		PlayerStats.take_damage(amount, source)

## Heal
func heal(amount: int) -> void:
	if stats_feature and stats_feature.has_method("heal"):
		stats_feature.heal(amount)
	elif has_node("/root/PlayerStats"):
		PlayerStats.heal(amount)

## Get camera component (for movement swimming)
var camera_component: Node:
	get:
		return camera_feature
