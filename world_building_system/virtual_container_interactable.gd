extends Node3D
class_name VirtualContainerInteractable

@export var slot_count: int = 6
@export var container_name: String = "Container"

var container_inventory: ContainerInventory = null
var is_open: bool = false
var is_populated: bool = false
var should_populate_loot: bool = false

const ItemDefs = preload("res://modules/world_player_v2/features/data_inventory/item_definitions.gd")
const CONTAINER_OPEN_SOUND = preload("res://game/sound/containers/cardboard/1/plastic-108360.mp3")
const CONTAINER_CLOSE_SOUND = preload("res://game/sound/containers/cardboard/1/object-dropped-on-plastic-bag-81895.mp3")

var container_open_audio: AudioStreamPlayer3D = null
var container_close_audio: AudioStreamPlayer3D = null

func _ready() -> void:
	add_to_group("containers")

	container_inventory = ContainerInventory.new()
	container_inventory.slot_count = slot_count
	container_inventory.name = "ContainerInventory"
	if has_meta("container_id"):
		container_inventory.container_id = str(get_meta("container_id"))
	add_child(container_inventory)

	var container_signals := get_node_or_null("/root/ContainerSignals")
	if container_signals:
		container_signals.container_closed.connect(_on_container_closed)

	if should_populate_loot or (has_meta("should_populate_loot") and get_meta("should_populate_loot")):
		populate_loot()

func get_interaction_prompt() -> String:
	if is_open:
		return "Close %s [E]" % container_name
	return "Open %s [E]" % container_name

func interact() -> void:
	var container_signals := get_node_or_null("/root/ContainerSignals")
	if is_open:
		if _ensure_close_audio():
			container_close_audio.play()
		if container_signals:
			container_signals.container_closed.emit()
		is_open = false
	else:
		if _ensure_open_audio():
			container_open_audio.play()
		is_open = true
		if container_signals:
			container_signals.container_opened.emit(self)
		else:
			var hud = get_tree().get_first_node_in_group("player_hud")
			if hud and hud.has_method("open_container"):
				hud.open_container(self)

func _on_container_closed() -> void:
	if is_open and _ensure_close_audio():
		container_close_audio.play()
	is_open = false

func get_inventory() -> ContainerInventory:
	return container_inventory

func populate_loot() -> void:
	if is_populated or not container_inventory:
		return
	is_populated = true

	var loot_table = [
		{"item": _get_wood_item(), "weight": 50, "min_count": 1, "max_count": 3},
		{"item": _get_dirt_item(), "weight": 30, "min_count": 1, "max_count": 3},
		{"item": _get_stone_item(), "weight": 15, "min_count": 1, "max_count": 2},
		{"item": _get_sand_item(), "weight": 5, "min_count": 1, "max_count": 2},
	]

	var min_items = 1 if slot_count <= 6 else 2
	var max_items = 3 if slot_count <= 6 else 5
	var num_items = randi_range(min_items, max_items)

	var filled_slots: Array[int] = []
	for _i in range(num_items):
		var available_slots: Array[int] = []
		for slot_index in range(slot_count):
			if slot_index not in filled_slots:
				available_slots.append(slot_index)
		if available_slots.is_empty():
			break

		var selected_slot = available_slots.pick_random()
		filled_slots.append(selected_slot)

		var item_entry = _pick_weighted_item(loot_table)
		var count = randi_range(item_entry.min_count, item_entry.max_count)
		container_inventory.set_slot(selected_slot, item_entry.item, count)

func _ensure_open_audio() -> bool:
	if container_open_audio and is_instance_valid(container_open_audio):
		return true
	container_open_audio = AudioStreamPlayer3D.new()
	container_open_audio.stream = CONTAINER_OPEN_SOUND
	container_open_audio.volume_db = -5.0
	container_open_audio.max_distance = 15.0
	add_child(container_open_audio)
	return true

func _ensure_close_audio() -> bool:
	if container_close_audio and is_instance_valid(container_close_audio):
		return true
	container_close_audio = AudioStreamPlayer3D.new()
	container_close_audio.stream = CONTAINER_CLOSE_SOUND
	container_close_audio.volume_db = -5.0
	container_close_audio.max_distance = 15.0
	add_child(container_close_audio)
	return true

func _pick_weighted_item(loot_table: Array) -> Dictionary:
	var total_weight = 0
	for entry in loot_table:
		total_weight += entry.weight

	var roll = randi() % total_weight
	var current = 0
	for entry in loot_table:
		current += entry.weight
		if roll < current:
			return entry

	return loot_table[0]

func _get_wood_item() -> Dictionary:
	return {
		"id": "veg_wood",
		"name": "Wood",
		"category": ItemDefs.ItemCategory.BLOCK,
		"block_id": 1,
		"stack_size": 64
	}

func _get_dirt_item() -> Dictionary:
	return {
		"id": "dirt",
		"name": "Dirt",
		"category": ItemDefs.ItemCategory.RESOURCE,
		"mat_id": 0,
		"stack_size": 64
	}

func _get_stone_item() -> Dictionary:
	return {
		"id": "res_stone",
		"name": "Stone",
		"category": ItemDefs.ItemCategory.RESOURCE,
		"mat_id": 1,
		"stack_size": 64
	}

func _get_sand_item() -> Dictionary:
	return {
		"id": "res_sand",
		"name": "Sand",
		"category": ItemDefs.ItemCategory.RESOURCE,
		"mat_id": 3,
		"stack_size": 64
	}
