extends PanelContainer
class_name CreativeCatalogPanelV2
## CreativeCatalogPanel - Editor-only scrollable catalog of placeable items
## Click an entry to add the matching item to the player's inventory.

@onready var close_button: Button = $VBox/Header/CloseButton
@onready var search_box: LineEdit = $VBox/FilterBar/SearchBox
@onready var category_filter: OptionButton = $VBox/FilterBar/CategoryFilter
@onready var grid: GridContainer = $VBox/ScrollContainer/ItemGrid
@onready var status_label: Label = $VBox/StatusLabel

const ItemDefs = preload("res://modules/world_player_v2/features/data_inventory/item_definitions.gd")
const ObjectRegistry = preload("res://world_building_system/object_registry.gd")

var inventory_ref: Node = null
var catalog_entries: Array = []
var active_search_text: String = ""
var active_category_filter: int = -1

func _ready() -> void:
	visible = false
	if close_button:
		close_button.pressed.connect(_on_close_pressed)
	if search_box:
		search_box.clear_button_enabled = true
		search_box.text_changed.connect(_on_search_text_changed)
	if category_filter:
		_setup_category_filter()
		category_filter.item_selected.connect(_on_category_selected)
	_build_catalog()
	_refresh_visible_catalog()

func open_catalog() -> void:
	_find_inventory()
	visible = true
	_refresh_visible_catalog()
	if search_box:
		search_box.grab_focus()

func close_catalog() -> void:
	if not visible:
		return
	visible = false
	_set_status("Closed.")

func toggle_catalog() -> void:
	if visible:
		close_catalog()
	else:
		open_catalog()

func _build_catalog() -> void:
	catalog_entries.clear()
	_add_tool_entries()
	_add_block_entries()
	_add_object_entries()
	_add_resource_entries()

func _add_block_entries() -> void:
	_add_entry("Wood Cube", {
		"id": "creative_block_cube",
		"name": "Wood Cube",
		"category": ItemDefs.ItemCategory.BLOCK,
		"block_id": 1,
		"stack_size": 64
	}, 3, "Block")
	_add_entry("Ramp", {
		"id": "creative_block_ramp",
		"name": "Ramp",
		"category": ItemDefs.ItemCategory.BLOCK,
		"block_id": 2,
		"stack_size": 64
	}, 3, "Block")
	_add_entry("Sphere", {
		"id": "creative_block_sphere",
		"name": "Sphere",
		"category": ItemDefs.ItemCategory.BLOCK,
		"block_id": 3,
		"stack_size": 64
	}, 3, "Block")
	_add_entry("Stairs", {
		"id": "creative_block_stairs",
		"name": "Stairs",
		"category": ItemDefs.ItemCategory.BLOCK,
		"block_id": 4,
		"stack_size": 64
	}, 3, "Block")
	_add_entry("Stairs (2-Step)", {
		"id": "creative_block_stairs_2",
		"name": "Stairs (2-Step)",
		"category": ItemDefs.ItemCategory.BLOCK,
		"block_id": 5,
		"stack_size": 64
	}, 3, "Block")
	_add_entry("Church Floor", {
		"id": "creative_block_church_floor",
		"name": "Church Floor",
		"category": ItemDefs.ItemCategory.BLOCK,
		"block_id": 8,
		"stack_size": 64
	}, 3, "Block")

func _add_object_entries() -> void:
	var object_ids: Array = ObjectRegistry.get_all_ids()
	object_ids.sort()
	for object_id_variant in object_ids:
		var object_id := int(object_id_variant)
		if object_id == 6:
			continue
		var obj_def := ObjectRegistry.get_object(object_id)
		if obj_def.is_empty():
			continue
		
		_add_entry(
			str(obj_def.get("name", "Object %d" % object_id)),
			{
				"id": "creative_object_%d" % object_id,
				"name": str(obj_def.get("name", "Object %d" % object_id)),
				"category": ItemDefs.ItemCategory.OBJECT,
				"object_id": object_id,
				"scene": str(obj_def.get("scene", "")),
				"stack_size": 1
			},
			1,
			"Object"
		)

func _add_resource_entries() -> void:
	var terrain_resources: Dictionary = ItemDefs.get_terrain_resources()
	var mat_ids: Array = terrain_resources.keys()
	mat_ids.sort()
	for mat_id_variant in mat_ids:
		var mat_id := int(mat_id_variant)
		var resource_def: Dictionary = terrain_resources[mat_id].duplicate(true)
		if resource_def.is_empty():
			continue
		
		var resource_name := str(resource_def.get("name", "Material %d" % mat_id))
		resource_def["stack_size"] = resource_def.get("stack_size", 64)
		
		_add_entry(resource_name, resource_def, 3, "Resource")

	var vegetation_resources: Dictionary = ItemDefs.get_vegetation_resources()
	if vegetation_resources.has("fiber"):
		_add_entry("Plant Fiber", vegetation_resources["fiber"].duplicate(true), 3, "Resource")
	if vegetation_resources.has("rock"):
		_add_entry("Rock", vegetation_resources["rock"].duplicate(true), 3, "Resource")

	_add_entry("Dirt", {
		"id": "dirt",
		"name": "Dirt",
		"category": ItemDefs.ItemCategory.RESOURCE,
		"mat_id": 0,
		"stack_size": 64
	}, 3, "Resource")

func _add_tool_entries() -> void:
	for item in ItemDefs.get_test_items():
		var item_id := str(item.get("id", ""))
		match item_id:
			"pickaxe_stone", "axe_stone", "bucket_water":
				_add_entry(
					str(item.get("name", item_id)),
					item.duplicate(true),
					1 if int(item.get("stack_size", 1)) <= 1 else 3,
					"Tool"
				)
			"shovel":
				_add_entry(
					"Shovel",
					{
						"id": "shovel",
						"name": "Shovel",
						"category": ItemDefs.ItemCategory.SHOVEL,
						"damage": 2,
						"mining_strength": 1.5,
						"stack_size": 1
					},
					1,
					"Tool"
				)
			"car_keys":
				_add_entry(
					"Car Keys",
					ItemDefs.get_car_keys_definition(),
					1,
					"Vehicle"
				)
			_:
				pass

	_add_entry("Heavy Pistol", _get_heavy_pistol_catalog_item(), 1, "Prop")

func _get_heavy_pistol_catalog_item() -> Dictionary:
	var pistol := ItemDefs.get_heavy_pistol_definition().duplicate(true)
	pistol["object_id"] = 6
	return pistol

func _add_entry(name: String, item: Dictionary, grant_count: int, kind: String) -> void:
	if item.is_empty():
		return
	
	var entry := {
		"name": name,
		"item": item,
		"grant_count": grant_count,
		"kind": kind,
		"category": int(item.get("category", ItemDefs.ItemCategory.NONE)),
		"search_blob": _build_search_blob(name, item, kind)
	}
	catalog_entries.append(entry)

func _build_search_blob(name: String, item: Dictionary, kind: String) -> String:
	var pieces: Array[String] = []
	pieces.append(name)
	pieces.append(str(item.get("id", "")))
	pieces.append(kind)
	pieces.append(str(item.get("block_id", "")))
	pieces.append(str(item.get("object_id", "")))
	pieces.append(str(item.get("mat_id", "")))
	pieces.append(ItemDefs.get_category_name(int(item.get("category", ItemDefs.ItemCategory.NONE))))
	return " ".join(pieces).to_lower()

func _setup_category_filter() -> void:
	if not category_filter:
		return
	
	category_filter.clear()
	_add_filter_option("All", -1)
	_add_filter_option("Blocks", ItemDefs.ItemCategory.BLOCK)
	_add_filter_option("Objects", ItemDefs.ItemCategory.OBJECT)
	_add_filter_option("Resources", ItemDefs.ItemCategory.RESOURCE)
	_add_filter_option("Tools", ItemDefs.ItemCategory.TOOL)
	_add_filter_option("Buckets", ItemDefs.ItemCategory.BUCKET)
	_add_filter_option("Shovels", ItemDefs.ItemCategory.SHOVEL)
	_add_filter_option("Vehicles", ItemDefs.ItemCategory.VEHICLE)
	_add_filter_option("Props", ItemDefs.ItemCategory.PROP)
	category_filter.select(0)
	active_category_filter = -1

func _add_filter_option(label: String, category_value: int) -> void:
	var index := category_filter.get_item_count()
	category_filter.add_item(label)
	category_filter.set_item_metadata(index, category_value)

func _refresh_visible_catalog() -> void:
	if not grid:
		return
	
	for child in grid.get_children():
		child.queue_free()
	
	var visible_count := 0
	for entry in catalog_entries:
		if _entry_matches_filters(entry):
			visible_count += 1
			_add_entry_button(entry)
	
	if visible_count == 0:
		_set_status("No items match your filters.")
	else:
		_set_status("Showing %d of %d items." % [visible_count, catalog_entries.size()])

func _entry_matches_filters(entry: Dictionary) -> bool:
	var category := int(entry.get("category", ItemDefs.ItemCategory.NONE))
	if active_category_filter != -1 and category != active_category_filter:
		return false
	
	if active_search_text == "":
		return true
	
	var blob := str(entry.get("search_blob", ""))
	return active_search_text in blob

func _add_entry_button(entry: Dictionary) -> void:
	var button := Button.new()
	button.text = str(entry.get("name", "Item"))
	button.custom_minimum_size = Vector2(200, 44)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.tooltip_text = _build_tooltip(entry)
	button.pressed.connect(_on_entry_pressed.bind(entry))
	grid.add_child(button)

func _build_tooltip(entry: Dictionary) -> String:
	var item: Dictionary = entry.get("item", {})
	var lines: Array[String] = []
	lines.append(str(entry.get("name", item.get("name", "Item"))))
	lines.append("Type: %s" % str(entry.get("kind", "Item")))
	lines.append("Adds x%d to inventory" % int(entry.get("grant_count", 1)))
	lines.append("Category: %s" % ItemDefs.get_category_name(int(entry.get("category", ItemDefs.ItemCategory.NONE))))
	
	if item.has("block_id"):
		lines.append("Block ID: %d" % int(item.get("block_id", -1)))
	elif item.has("object_id"):
		lines.append("Object ID: %d" % int(item.get("object_id", -1)))
	elif item.has("mat_id"):
		lines.append("Material ID: %d" % int(item.get("mat_id", -1)))
	
	return "\n".join(lines)

func _on_entry_pressed(entry: Dictionary) -> void:
	_find_inventory()
	
	if not inventory_ref or not inventory_ref.has_method("add_item"):
		_set_status("Inventory not found.")
		return
	
	var item: Dictionary = entry.get("item", {}).duplicate(true)
	if item.is_empty():
		_set_status("That entry is missing item data.")
		return
	
	var requested_count: int = int(entry.get("grant_count", 1))
	var leftover: int = int(inventory_ref.add_item(item, requested_count))
	var added: int = requested_count - leftover
	var item_name: String = str(item.get("name", entry.get("name", "Item")))
	
	if added > 0:
		_set_status("Added %s x%d" % [item_name, added])
	else:
		_set_status("Inventory full.")

func _find_inventory() -> void:
	if inventory_ref and is_instance_valid(inventory_ref):
		return
	
	var player := get_tree().get_first_node_in_group("player")
	if player:
		inventory_ref = player.get_node_or_null("Systems/Inventory")

func _on_search_text_changed(new_text: String) -> void:
	active_search_text = new_text.strip_edges().to_lower()
	_refresh_visible_catalog()

func _on_category_selected(index: int) -> void:
	if not category_filter:
		return
	
	var meta = category_filter.get_item_metadata(index)
	active_category_filter = int(meta) if meta != null else -1
	_refresh_visible_catalog()

func _set_status(message: String) -> void:
	if status_label:
		status_label.text = message

func _on_close_pressed() -> void:
	close_catalog()
