extends CanvasLayer
class_name PlayerHUD
## PlayerHUD - Main HUD for the world_player module
## Displays mode, hotbar, health, stamina, crosshair, interaction prompts

# References
@onready var mode_label: Label = $ModeIndicator
@onready var build_info_label: Label = $BuildInfoLabel
@onready var hotbar_container: HBoxContainer = $HotbarPanel/HotbarContainer
@onready var crosshair: TextureRect = $Crosshair
@onready var interaction_prompt: Label = $InteractionPrompt
@onready var durability_bar: ProgressBar = $DurabilityBar
@onready var health_bar: ProgressBar = $StatusBars/HealthBar
@onready var stamina_bar: ProgressBar = $StatusBars/StaminaBar
@onready var compass: Label = $Compass
@onready var game_menu: Control = $GameMenu
@onready var selected_item_label: Label = $SelectedItemLabel
@onready var target_material_label: Label = $TargetMaterial

# Visual overlays
var underwater_overlay: ColorRect = null

# Hotbar slot controls (InventorySlot instances)
var hotbar_slots: Array = []
var hotbar_ref: Node = null
var inventory_ref: Node = null

const InventorySlotScene = preload("res://modules/world_player/ui/inventory_slot.tscn")

# Editor mode tracking
var is_editor_mode: bool = false
var current_editor_submode: int = 0
const EDITOR_SUBMODE_NAMES = ["Terrain", "Water", "Road", "Prefab", "Fly", "OldDirt"]

# Durability persistence state (3 second memory for MULTIPLE targets)
# Format: { target_key (String) -> { "target_ref": Variant, "hit_time": int, "hp_percent": float } }
var durability_memory: Dictionary = {}
var last_hit_target_key: String = "" # Track last hit for _on_durability_cleared
const DURABILITY_PERSIST_MS: int = 6000


func _ready() -> void:
	# Connect to player signals
	PlayerSignals.mode_changed.connect(_on_mode_changed)
	PlayerSignals.item_changed.connect(_on_item_changed)
	PlayerSignals.hotbar_slot_selected.connect(_on_hotbar_slot_selected)
	PlayerSignals.interaction_available.connect(_on_interaction_available)
	PlayerSignals.interaction_unavailable.connect(_on_interaction_unavailable)
	PlayerSignals.inventory_toggled.connect(_on_inventory_toggled)
	PlayerSignals.game_menu_toggled.connect(_on_game_menu_toggled)
	PlayerSignals.editor_submode_changed.connect(_on_editor_submode_changed)
	PlayerSignals.inventory_changed.connect(_on_inventory_changed)
	PlayerSignals.durability_hit.connect(_on_durability_hit)
	PlayerSignals.durability_cleared.connect(_on_durability_cleared)
	PlayerSignals.target_material_changed.connect(_on_target_material_changed)
	PlayerSignals.camera_underwater_toggled.connect(_on_camera_underwater_toggled)

	
	# Initialize hotbar UI
	_setup_hotbar()
	
	# Connect exit button
	var exit_btn = game_menu.get_node_or_null("ExitButton")
	if exit_btn:
		exit_btn.pressed.connect(_on_exit_pressed)
	
	# Initial state
	mode_label.text = "PLAY"
	interaction_prompt.visible = false
	game_menu.visible = false
	
	print("PlayerHUD: Initialized")
	
	_setup_visual_overlays()

func _setup_visual_overlays() -> void:
	# Create underwater overlay if not in scene
	if not underwater_overlay:
		underwater_overlay = ColorRect.new()
		underwater_overlay.name = "UnderwaterOverlay"
		# Matched to legacy world.tscn (0.05, 0.2, 0.12, 0.4) - Dark greenish/swampy
		underwater_overlay.color = Color(0.05, 0.2, 0.12, 0.4)
		underwater_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		underwater_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		underwater_overlay.visible = false
		add_child(underwater_overlay)
		move_child(underwater_overlay, 0) # Move to back

func _process(_delta: float) -> void:
	# Update compass with player direction
	_update_compass()
	
	# Update health/stamina bars
	_update_status_bars()
	
	# Update mode label with extra build info when in BUILD mode
	_update_build_mode_info()
	
	# Check durability UI visibility (persistence logic)
	_update_durability_visibility()

## Setup hotbar slot display with InventorySlot instances
func _setup_hotbar() -> void:
	hotbar_slots.clear()
	
	# Create 10 InventorySlot instances for hotbar
	for i in range(10):
		var slot = InventorySlotScene.instantiate()
		slot.slot_index = i + 100 # Offset for hotbar (100-109)
		slot.custom_minimum_size = Vector2(80, 60)
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.item_dropped_outside.connect(_on_hotbar_item_dropped_outside.bind(slot))
		hotbar_container.add_child(slot)
		hotbar_slots.append(slot)
	
	# Find player systems
	var player_node = get_tree().get_first_node_in_group("player")
	if player_node:
		hotbar_ref = player_node.get_node_or_null("Systems/Hotbar")
		inventory_ref = player_node.get_node_or_null("Systems/Inventory")
	
	# Populate initial hotbar display
	_refresh_hotbar_display()
	
	# Highlight first slot by default
	if hotbar_slots.size() > 0:
		hotbar_slots[0].modulate = Color.YELLOW
	
	# Set initial selected item label
	if hotbar_ref and selected_item_label:
		var first_item = hotbar_ref.get_item_at(0)
		selected_item_label.text = first_item.get("name", "Fists")

## Refresh all hotbar slot displays
func _refresh_hotbar_display() -> void:
	if not hotbar_ref:
		return
	
	var raw_data = hotbar_ref.get_all_slots() if hotbar_ref.has_method("get_all_slots") else []
	for i in range(min(hotbar_slots.size(), raw_data.size())):
		var slot_data = raw_data[i]
		# Hotbar now stores {item: Dictionary, count: int} format directly
		if slot_data is Dictionary and slot_data.has("item"):
			# New format - pass directly
			hotbar_slots[i].set_slot_data(slot_data, i + 100)
		else:
			# Legacy format - wrap it
			var wrapped = {"item": slot_data, "count": 1 if slot_data.get("id", "empty") != "empty" else 0}
			hotbar_slots[i].set_slot_data(wrapped, i + 100)
	
	# Restore selection highlight
	_restore_slot_selection()

## Restore selection highlight on the currently selected hotbar slot
func _restore_slot_selection() -> void:
	if not hotbar_ref:
		return
	var selected = hotbar_ref.get_selected_index()
	for i in range(hotbar_slots.size()):
		if i == selected:
			hotbar_slots[i].modulate = Color.YELLOW
		else:
			hotbar_slots[i].modulate = Color.WHITE

## Handle item dropped outside hotbar slot - spawn 3D pickup
func _on_hotbar_item_dropped_outside(item: Dictionary, count: int, slot) -> void:
	var slot_idx = slot.slot_index - 100
	
	if hotbar_ref and hotbar_ref.has_method("clear_slot"):
		hotbar_ref.clear_slot(slot_idx)
	
	# Get player position for drop
	var player = get_tree().get_first_node_in_group("player")
	var drop_pos = Vector3.ZERO
	var drop_velocity = Vector3.ZERO
	if player:
		drop_pos = player.global_position - player.global_transform.basis.z * 2.0 + Vector3.UP
		drop_velocity = -player.global_transform.basis.z * 3.0 + Vector3.UP * 2.0
	
	# Spawn pickup
	_spawn_pickup(item, count, drop_pos, drop_velocity)
	_refresh_hotbar_display()

## Spawn a 3D pickup in the world
func _spawn_pickup(item: Dictionary, count: int, pos: Vector3, velocity: Vector3 = Vector3.ZERO) -> void:
	# Check if item has its own physics scene (like pistol) and should spawn directly
	var scene_path = item.get("scene", "")
	var spawned_directly = false
	
	if scene_path != "":
		var item_scene = load(scene_path)
		if item_scene:
			var temp_instance = item_scene.instantiate()
			# Check if the scene is a RigidBody3D (physics prop)
			if temp_instance is RigidBody3D:
				# Spawn directly as physics prop
				get_tree().root.add_child(temp_instance)
				temp_instance.global_position = pos
				
				# Add to interactable group for pickup
				if not temp_instance.is_in_group("interactable"):
					temp_instance.add_to_group("interactable")
				
				# Store item data on the node for re-pickup
				temp_instance.set_meta("item_data", item.duplicate())
				
				# Apply forward velocity
				temp_instance.linear_velocity = velocity
				
				print("[HUD] Dropped %s directly (physics prop)" % item.get("name", "item"))
				spawned_directly = true
			else:
				temp_instance.queue_free()
	
	# Fallback: use PickupItem wrapper
	if not spawned_directly:
		var pickup_scene = load("res://modules/world_player/pickups/pickup_item.tscn")
		if not pickup_scene:
			print("PlayerHUD: Failed to load pickup scene")
			return
		
		var pickup = pickup_scene.instantiate()
		get_tree().root.add_child(pickup)
		pickup.global_position = pos
		pickup.set_item(item, count)
		
		# Apply forward velocity
		pickup.linear_velocity = velocity
		
		print("PlayerHUD: Spawned wrapped pickup for %s x%d" % [item.get("name", "Item"), count])

## Handle drag-drop between HUD hotbar and inventory panel
func handle_slot_drop(source_index: int, target_index: int) -> void:
	if source_index == target_index:
		return
	
	var source_is_hotbar = source_index >= 100
	var target_is_hotbar = target_index >= 100
	var source_idx = source_index % 100
	var target_idx = target_index % 100
	
	var source_system = hotbar_ref if source_is_hotbar else inventory_ref
	var target_system = hotbar_ref if target_is_hotbar else inventory_ref
	
	if not source_system or not target_system:
		return
	
	# Get slot data
	var source_data = source_system.get_slot(source_idx) if source_system.has_method("get_slot") else {}
	var target_data = target_system.get_slot(target_idx) if target_system.has_method("get_slot") else {}
	
	var source_item = source_data.get("item", {})
	var source_count = source_data.get("count", 0)
	var target_item = target_data.get("item", {})
	var target_count = target_data.get("count", 0)
	
	# Swap items
	if source_system.has_method("set_slot") and target_system.has_method("set_slot"):
		target_system.set_slot(target_idx, source_item, source_count)
		source_system.set_slot(source_idx, target_item, target_count)
	
	_refresh_hotbar_display()

## Update compass direction
func _update_compass() -> void:
	var player = get_tree().get_first_node_in_group("player")
	if player:
		var forward = - player.global_transform.basis.z
		var angle = rad_to_deg(atan2(forward.x, forward.z))
		
		var direction = ""
		if angle >= -22.5 and angle < 22.5:
			direction = "N"
		elif angle >= 22.5 and angle < 67.5:
			direction = "NE"
		elif angle >= 67.5 and angle < 112.5:
			direction = "E"
		elif angle >= 112.5 and angle < 157.5:
			direction = "SE"
		elif angle >= 157.5 or angle < -157.5:
			direction = "S"
		elif angle >= -157.5 and angle < -112.5:
			direction = "SW"
		elif angle >= -112.5 and angle < -67.5:
			direction = "W"
		elif angle >= -67.5 and angle < -22.5:
			direction = "NW"
		
		compass.text = direction

## Update health and stamina bars
func _update_status_bars() -> void:
	health_bar.value = PlayerStats.health
	health_bar.max_value = PlayerStats.max_health
	stamina_bar.value = PlayerStats.stamina
	stamina_bar.max_value = PlayerStats.max_stamina

## Mode changed handler
func _on_mode_changed(_old_mode: String, new_mode: String) -> void:
	mode_label.text = new_mode
	
	# Track editor mode state
	is_editor_mode = (new_mode == "EDITOR")
	
	# Change mode label color based on mode
	match new_mode:
		"PLAY":
			mode_label.modulate = Color.WHITE
		"BUILD":
			mode_label.modulate = Color.CYAN
		"EDITOR":
			mode_label.modulate = Color.YELLOW
	
	# Update hotbar display for editor/play mode
	_update_hotbar_display()


## Item changed handler
func _on_item_changed(slot: int, item: Dictionary) -> void:
	# Skip in editor mode - editor has its own display
	if is_editor_mode:
		return
	# Refresh the changed slot in hotbar display
	if slot >= 0 and slot < hotbar_slots.size():
		# Get actual count from hotbar for proper stacking display
		var count = 1
		if hotbar_ref and hotbar_ref.has_method("get_count_at"):
			count = hotbar_ref.get_count_at(slot)
		var wrapped = {"item": item, "count": count}
		hotbar_slots[slot].set_slot_data(wrapped, slot + 100)
	
	# Update selected item label if this is the selected slot
	if hotbar_ref and selected_item_label:
		var selected_slot = hotbar_ref.get_selected_index()
		if slot == selected_slot:
			selected_item_label.text = item.get("name", "Empty")

## Hotbar slot selected handler
func _on_hotbar_slot_selected(slot: int) -> void:
	# Skip hotbar changes in editor mode - editor has its own display
	if is_editor_mode:
		return
	
	# Highlight selected slot
	for i in range(hotbar_slots.size()):
		if i == slot:
			hotbar_slots[i].modulate = Color.YELLOW
		else:
			hotbar_slots[i].modulate = Color.WHITE
	
	# Update selected item label with full name
	var player_node = get_tree().get_first_node_in_group("player")
	if player_node and selected_item_label:
		var hotbar = player_node.get_node_or_null("Systems/Hotbar")
		if hotbar:
			var item = hotbar.get_item_at(slot)
			selected_item_label.text = item.get("name", "Empty")

## Interaction available handler
func _on_interaction_available(_target: Node, prompt: String) -> void:
	interaction_prompt.text = prompt
	interaction_prompt.visible = true

## Interaction unavailable handler
func _on_interaction_unavailable() -> void:
	interaction_prompt.visible = false

## Inventory toggled handler
func _on_inventory_toggled(is_open: bool) -> void:
	# Could show/hide inventory panel here
	print("PlayerHUD: Inventory %s" % ("opened" if is_open else "closed"))

## Game menu toggled handler
func _on_game_menu_toggled(is_open: bool) -> void:
	game_menu.visible = is_open

## Exit button pressed handler
func _on_exit_pressed() -> void:
	get_tree().quit()

## Inventory changed handler - refresh all hotbar slots
func _on_inventory_changed() -> void:
	_refresh_hotbar_display()

## Update mode label with build mode details
func _update_build_mode_info() -> void:
	# Find mode manager to check current mode
	var player_node = get_tree().get_first_node_in_group("player")
	if not player_node:
		if build_info_label:
			build_info_label.visible = false
		return
	
	var mode_manager_node = player_node.get_node_or_null("Systems/ModeManager")
	if not mode_manager_node:
		if build_info_label:
			build_info_label.visible = false
		return
	
	# Only show when in BUILD mode
	if not mode_manager_node.is_build_mode():
		if build_info_label:
			build_info_label.visible = false
		return
	
	# Find the ModeBuild node to get building_api
	var mode_build = player_node.get_node_or_null("Modes/ModeBuild")
	if not mode_build:
		if build_info_label:
			build_info_label.visible = false
		return
	
	# Get building_api from ModeBuild
	var building_api = mode_build.get("building_api")
	if not building_api:
		if build_info_label:
			build_info_label.visible = false
		return
	
	# Get placement mode info
	var placement_modes = ["SNAP", "EMBED", "AUTO", "FILL"]
	var mode_idx = building_api.get("placement_mode")
	var mode_str = placement_modes[mode_idx] if mode_idx != null and mode_idx < 4 else "?"
	
	var curr_rotation = mode_build.get("current_rotation")
	var rot_str = "%d°" % (curr_rotation * 90) if curr_rotation != null else "?"
	
	var y_offset = building_api.get("placement_y_offset")
	var y_str = "Y:%+d" % y_offset if y_offset != null and y_offset != 0 else ""
	
	# Update build info label with build info (below mode label)
	if build_info_label:
		build_info_label.text = "[%s] Rot:%s %s" % [mode_str, rot_str, y_str]
		build_info_label.visible = true

## Editor submode changed handler
func _on_editor_submode_changed(submode: int, _submode_name: String) -> void:
	current_editor_submode = submode
	if is_editor_mode:
		_update_hotbar_display()

## Update hotbar display based on current mode
func _update_hotbar_display() -> void:
	if is_editor_mode:
		# Show editor submodes in hotbar slots
		for i in range(hotbar_slots.size()):
			if i < EDITOR_SUBMODE_NAMES.size():
				var editor_item = {"id": "editor_mode", "name": EDITOR_SUBMODE_NAMES[i]}
				var wrapped = {"item": editor_item, "count": 1}
				hotbar_slots[i].set_slot_data(wrapped, i + 100)
				# Highlight selected submode
				if i == current_editor_submode:
					hotbar_slots[i].modulate = Color.YELLOW
				else:
					hotbar_slots[i].modulate = Color.WHITE
			else:
				# Show empty for unused slots
				var empty_item = {"id": "empty", "name": "Empty"}
				var wrapped = {"item": empty_item, "count": 0}
				hotbar_slots[i].set_slot_data(wrapped, i + 100)
				hotbar_slots[i].modulate = Color.DIM_GRAY
		
		# Update selected item label
		if selected_item_label:
			if current_editor_submode < EDITOR_SUBMODE_NAMES.size():
				selected_item_label.text = EDITOR_SUBMODE_NAMES[current_editor_submode]
			else:
				selected_item_label.text = "Editor"
	else:
		# Restore normal hotbar from items
		_refresh_hotbar_display()
		
		# Restore selected slot highlight
		if hotbar_ref:
			var selected = hotbar_ref.get_selected_index()
			if selected >= 0 and selected < hotbar_slots.size():
				hotbar_slots[selected].modulate = Color.YELLOW
			
			# Update selected item label
			if selected_item_label:
				var item = hotbar_ref.get_item_at(selected)
				selected_item_label.text = item.get("name", "Empty")

#region Durability UI

## Convert a target reference to a string key for dictionary storage
func _target_to_key(target_ref: Variant) -> String:
	if target_ref is RID:
		return "rid:%d" % target_ref.get_id()
	elif target_ref is Vector3i:
		return "v3i:%d,%d,%d" % [target_ref.x, target_ref.y, target_ref.z]
	elif target_ref is Node:
		return "node:%d" % target_ref.get_instance_id()
	else:
		return "unknown:%s" % str(target_ref)

func _on_durability_hit(current_hp: int, max_hp: int, _target_name: String, target_ref: Variant) -> void:
	if not durability_bar:
		return
	# Show remaining HP as percentage (full bar = full health, empty = destroyed)
	var hp_percent = 100.0 * float(current_hp) / float(max_hp)
	
	# Store/update in multi-target memory
	var key = _target_to_key(target_ref)
	print("[DUR_HIT] Storing key=%s type=%s hp=%.1f%%" % [key, typeof(target_ref), hp_percent])
	durability_memory[key] = {
		"target_ref": target_ref,
		"hit_time": Time.get_ticks_msec(),
		"hp_percent": hp_percent
	}
	last_hit_target_key = key
	print("[DUR_HIT] Memory now has %d entries: %s" % [durability_memory.size(), durability_memory.keys()])
	
	durability_bar.value = hp_percent
	durability_bar.visible = true

func _on_durability_cleared() -> void:
	# This is called when target is DESTROYED (HP=0)
	# Remove the last hit target from memory
	if durability_bar:
		durability_bar.visible = false
		durability_bar.value = 0
	if last_hit_target_key != "":
		durability_memory.erase(last_hit_target_key)
		last_hit_target_key = ""

## Check if durability UI should be shown based on look target and time
func _update_durability_visibility() -> void:
	if not durability_bar:
		return
	
	# No remembered targets? Nothing to do.
	if durability_memory.is_empty():
		return
	
	# Clean up expired entries first
	var now = Time.get_ticks_msec()
	var keys_to_remove: Array = []
	for key in durability_memory:
		var entry = durability_memory[key]
		if now - entry.hit_time > DURABILITY_PERSIST_MS:
			keys_to_remove.append(key)
	for key in keys_to_remove:
		durability_memory.erase(key)
	
	if durability_memory.is_empty():
		durability_bar.visible = false
		return
	
	# Get current look target via direct raycast
	var player_node = get_tree().get_first_node_in_group("player")
	if not player_node or not player_node.has_method("raycast"):
		return
	
	var hit = player_node.raycast(5.0, 0xFFFFFFFF, true, true)
	if hit.is_empty():
		# Looking at nothing - hide but keep memory
		durability_bar.visible = false
		return
	
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	
	# Check all remembered targets for a match
	var look_rid = target.get_rid() if target else RID()
	var look_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
	
	for key in durability_memory:
		var entry = durability_memory[key]
		var remembered_target = entry.target_ref
		var is_match = false
		
		if remembered_target is RID:
			# Tree/Object - compare RID
			if target and look_rid == remembered_target:
				is_match = true
			else:
				print("[DUR_CHECK] RID mismatch: looking_at=%d remembered=%d" % [look_rid.get_id() if look_rid.is_valid() else -1, remembered_target.get_id()])
		elif remembered_target is Vector3i:
			# Block/Terrain - compare grid position
			var block_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
			if block_pos == remembered_target:
				is_match = true
		elif remembered_target is Node:
			# Direct node reference (like Door)
			if target == remembered_target or _is_child_of(target, remembered_target):
				is_match = true
		
		if is_match:
			# Looking at a remembered target - show its durability
			durability_bar.value = entry.hp_percent
			durability_bar.visible = true
			return
	
	# No match found - hide but keep memory
	durability_bar.visible = false

## Helper: Check if node is child of another node (for door sub-colliders)
func _is_child_of(node: Node, potential_parent: Node) -> bool:
	if not node or not potential_parent:
		return false
	var current = node.get_parent()
	while current:
		if current == potential_parent:
			return true
		current = current.get_parent()
	return false

func _on_target_material_changed(material_name: String) -> void:
	if target_material_label:
		target_material_label.text = material_name

#endregion

#region Visual Effects

func _on_camera_underwater_toggled(is_underwater: bool) -> void:
	if underwater_overlay:
		underwater_overlay.visible = is_underwater

#endregion
