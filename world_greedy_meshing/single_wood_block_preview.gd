@tool
extends Node3D

const BuildingVisuals = preload("res://world_building_system/building_visuals.gd")

@onready var block: MeshInstance3D = $Block
@onready var camera: Camera3D = $Camera3D

var _material: Material

func _ready() -> void:
	_setup_material()
	if is_instance_valid(camera):
		camera.look_at(Vector3.ZERO, Vector3.UP)
	if Engine.is_editor_hint():
		set_process(false)
	else:
		set_process(true)

func _process(delta: float) -> void:
	if is_instance_valid(block):
		block.rotate_y(delta * 0.45)

func _setup_material() -> void:
	if not is_instance_valid(block):
		return

	if _material == null:
		_material = BuildingVisuals.get_shared_building_material()

	block.material_override = _material
