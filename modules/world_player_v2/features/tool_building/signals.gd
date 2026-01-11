extends Node
## Building Feature Signals - Block/object/prop placement events

signal block_placed(position: Vector3i, block_id: int)
signal block_removed(position: Vector3i)
signal object_placed(position: Vector3i, object_id: int, rotation: int)
signal object_removed(position: Vector3i)
