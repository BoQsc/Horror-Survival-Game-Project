extends Node
class_name DebugTeleporter

## Automatically teleports player to the first spawned prefab for testing.
## Attach this to the scene (e.g., under Managers) to enable.

@export var enabled: bool = true
var _has_teleported: bool = false
var _prefab_spawner: Node = null
var _player: Node3D = null

func _ready():
	if not enabled:
		return
		
	# Find PrefabSpawner
	# It might not be ready immediately, so we can search by group or path
	_prefab_spawner = get_tree().get_first_node_in_group("prefab_spawner")
	if not _prefab_spawner:
		# Try finding by name in main scene
		_prefab_spawner = get_tree().root.find_child("PrefabSpawner", true, false)
		
	if _prefab_spawner:
		if _prefab_spawner.has_signal("prefab_spawned"):
			_prefab_spawner.prefab_spawned.connect(_on_prefab_spawned)
			print("[DebugTeleporter] Connected to PrefabSpawner")
		else:
			print("[DebugTeleporter] PrefabSpawner found but no signal 'prefab_spawned'")
	else:
		print("[DebugTeleporter] PrefabSpawner not found")

func _on_prefab_spawned(prefab_name: String, pos: Vector3):
	if _has_teleported or not enabled:
		return
		
	_player = get_tree().get_first_node_in_group("player")
	if _player:
		_has_teleported = true
		_player.global_position = pos + Vector3(0, 5, 10)
		# Face the house
		_player.look_at(pos, Vector3.UP)
		print("[DebugTeleporter] Teleported player to %s at %v" % [prefab_name, pos])
