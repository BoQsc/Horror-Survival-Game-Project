extends Node
## ContainerRegistry - Global tracking for all container instances
## Uses UUID for unique, persistent identification
## Autoload singleton

# Map of uuid -> ContainerInventory node
var containers: Dictionary = {}

func _ready() -> void:
	add_to_group("container_registry")
	DebugManager.log_save("ContainerRegistry: Initialized")

## Register a container instance with UUID
func register_container(container: Node, uuid: String) -> void:
	containers[uuid] = container
	DebugManager.log_save("ContainerRegistry: Registered container %s" % uuid)

## Unregister a container
func unregister_container(uuid: String) -> void:
	if containers.has(uuid):
		containers.erase(uuid)
		DebugManager.log_save("ContainerRegistry: Unregistered container %s" % uuid)

## Get container by UUID
func get_container(uuid: String) -> Node:
	return containers.get(uuid, null)

## Get save data for all containers
func get_save_data() -> Dictionary:
	var containers_data = []
	
	for uuid in containers.keys():
		var container = containers[uuid]
		if container and container.has_method("serialize"):
			var data = container.serialize()
			data["uuid"] = uuid  # Include UUID in serialized data
			containers_data.append(data)
	
	DebugManager.log_save("ContainerRegistry: Saving %d containers" % containers_data.size())
	return {
		"containers": containers_data
	}

## Restore all containers from save data
func load_save_data(data: Dictionary) -> void:
	if not data.has("containers"):
		return
	
	var containers_data = data.containers
	var matched = 0
	var missing = 0
	
	for container_data in containers_data:
		var uuid = container_data.get("uuid", "")
		if uuid.is_empty():
			push_warning("ContainerRegistry: Container data missing UUID")
			continue
		
		var container = get_container(uuid)
		if container and container.has_method("deserialize"):
			container.deserialize(container_data)
			matched += 1
		else:
			push_warning("ContainerRegistry: Container not found for UUID %s" % uuid)
			missing += 1
	
	DebugManager.log_save("Containers loaded: %d matched, %d missing" % [matched, missing])

