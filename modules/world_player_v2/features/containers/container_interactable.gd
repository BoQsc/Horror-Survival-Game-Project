extends StaticBody3D
class_name ContainerInteractable
## ContainerInteractable - Attach to container objects to make them interactable
## Handles 'E' key interaction to open container UI

## Number of slots for this container type
@export var slot_count: int = 6

## Container name shown in UI
@export var container_name: String = "Container"

## The container's inventory (created on ready)
var container_inventory: ContainerInventory = null

## Track if this container is currently open
var is_open: bool = false

func _ready() -> void:
	# Add to groups for detection
	add_to_group("interactable")
	add_to_group("containers")
	
	# Create container inventory as child
	container_inventory = ContainerInventory.new()
	container_inventory.slot_count = slot_count
	container_inventory.name = "ContainerInventory"
	add_child(container_inventory)
	
	# Connect to container closed signal
	if has_node("/root/ContainerSignals"):
		ContainerSignals.container_closed.connect(_on_container_closed)
	
	DebugSettings.log_player("CONTAINER: Initialized %s with %d slots" % [container_name, slot_count])

## Called by player interaction system to get prompt text
func get_interaction_prompt() -> String:
	if is_open:
		return "Close %s [E]" % container_name
	return "Open %s [E]" % container_name

## Called when player presses E on this container
func interact() -> void:
	if is_open:
		# Close the container
		DebugSettings.log_player("CONTAINER: Closing %s" % container_name)
		if has_node("/root/ContainerSignals"):
			ContainerSignals.container_closed.emit()
		is_open = false
	else:
		# Open the container
		DebugSettings.log_player("CONTAINER: Opening %s" % container_name)
		is_open = true
		if has_node("/root/ContainerSignals"):
			ContainerSignals.container_opened.emit(self)
		else:
			# Fallback: try to find HUD directly
			var hud = get_tree().get_first_node_in_group("player_hud")
			if hud and hud.has_method("open_container"):
				hud.open_container(self)

func _on_container_closed() -> void:
	is_open = false

## Get the inventory for UI access
func get_inventory() -> ContainerInventory:
	return container_inventory

