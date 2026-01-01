extends Node
## VehicleManager - Spawns, tracks, and manages all vehicles in the world.
## Provides save/load interface for vehicle persistence.

signal vehicle_spawned(vehicle: Node3D)
signal player_entered_vehicle(vehicle: Node3D)
signal player_exited_vehicle(vehicle: Node3D)

var vehicles: Array[Node3D] = []
var current_player_vehicle: Node3D = null
var vehicle_scene: PackedScene = preload("res://vehicles/drivable_car.tscn")

@export var player: Node3D


func _ready() -> void:
	add_to_group("vehicle_manager")


func spawn_vehicle(pos: Vector3) -> Node3D:
	var v = vehicle_scene.instantiate()
	get_tree().current_scene.add_child(v)
	v.global_position = pos + Vector3(0, 1, 0)  # Spawn slightly above ground
	vehicles.append(v)
	vehicle_spawned.emit(v)
	return v


## Pick up vehicle - despawns vehicle and optionally returns Car Keys to player
func pickup_vehicle(vehicle: Node3D) -> bool:
	if not vehicle in vehicles:
		print("[VehicleManager] pickup_vehicle: Vehicle not tracked")
		return false
	
	# Don't allow pickup if player is in this vehicle
	if current_player_vehicle == vehicle:
		print("[VehicleManager] pickup_vehicle: Player is in vehicle, exit first")
		return false
	
	# Despawn the vehicle
	vehicles.erase(vehicle)
	vehicle.queue_free()
	print("[VehicleManager] Vehicle picked up (Total remaining: %d)" % vehicles.size())
	return true


func despawn_vehicle(vehicle: Node3D) -> void:
	if vehicle in vehicles:
		vehicles.erase(vehicle)
		vehicle.queue_free()


func get_all_vehicles() -> Array[Node3D]:
	return vehicles


## Save data for all vehicles
func get_save_data() -> Dictionary:
	var data = []
	for v in vehicles:
		if is_instance_valid(v):
			data.append({
				"position": [v.global_position.x, v.global_position.y, v.global_position.z],
				"rotation": [v.rotation.x, v.rotation.y, v.rotation.z]
			})
	return {"vehicles": data}


## Load vehicles from save data
func load_save_data(data: Dictionary) -> void:
	# Clear existing vehicles
	for v in vehicles:
		if is_instance_valid(v):
			v.queue_free()
	vehicles.clear()
	current_player_vehicle = null
	
	# Spawn saved vehicles
	for vd in data.get("vehicles", []):
		var pos_arr = vd.get("position", [0, 0, 0])
		var rot_arr = vd.get("rotation", [0, 0, 0])
		var v = spawn_vehicle(Vector3(pos_arr[0], pos_arr[1], pos_arr[2]))
		v.rotation = Vector3(rot_arr[0], rot_arr[1], rot_arr[2])
	
	print("[VehicleManager] Loaded %d vehicles" % vehicles.size())
