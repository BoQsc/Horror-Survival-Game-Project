extends Node
## Terrain Feature Signals - Mining and placement events

signal target_material_changed(material_name: String)
signal terrain_modified(position: Vector3i, old_value: float, new_value: float)
