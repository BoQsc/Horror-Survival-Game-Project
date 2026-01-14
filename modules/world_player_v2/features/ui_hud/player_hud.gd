extends CanvasLayer
class_name PlayerHUDV2
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

var underwater_overlay: ColorRect = null
var hotbar_slots: Array = []
var hotbar_ref: Node = null
var inventory_ref: Node = null

# V2 path
const InventorySlotScene = preload("res://modules/world_player_v2/features/data_inventory/ui_inventory/inventory_slot.tscn")

var durability_memory: Dictionary = {}
var last_hit_target_key: String = ""
const DURABILITY_PERSIST_MS: int = 6000

# Terraformer state
var terraformer_material: String = ""

# Save/Load notifications
var notification_label: Label = null
var notification_timer: float = 0.0

func _ready() -> void:
	if has_node("/root/PlayerSignals"):
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
		PlayerSignals.terraformer_material_changed.connect(_on_terraformer_material_changed)
	
	_setup_hotbar()
	
	var exit_btn = game_menu.get_node_or_null("ExitButton")
	if exit_btn:
		exit_btn.pressed.connect(_on_exit_pressed)
	
	# Connect collision debugger toggle
	var collision_toggle = game_menu.get_node_or_null("CollisionDebuggerToggle")
	if collision_toggle:
		collision_toggle.toggled.connect(_on_collision_debugger_toggled)
		# Sync with current state
		if has_node("/root/CollisionDebugger"):
			collision_toggle.button_pressed = get_node("/root/CollisionDebugger").enabled
	
	# Connect pickaxe dig mode toggle
	var pickaxe_toggle = game_menu.get_node_or_null("PickaxeDigModeToggle")
	if pickaxe_toggle:
		pickaxe_toggle.toggled.connect(_on_pickaxe_dig_mode_toggled)
		# Sync with current state
		if has_node("/root/PickaxeDigConfig"):
			pickaxe_toggle.button_pressed = get_node("/root/PickaxeDigConfig").enabled
	
	# Connect pickaxe durability toggle
	var durability_toggle = game_menu.get_node_or_null("PickaxeDurabilityToggle")
	if durability_toggle:
		durability_toggle.toggled.connect(_on_pickaxe_durability_toggled)
		# Sync with current state
		if has_node("/root/PickaxeDurabilityConfig"):
			durability_toggle.button_pressed = get_node("/root/PickaxeDurabilityConfig").enabled
	
	# Connect target visualizer toggle
	var visualizer_toggle = game_menu.get_node_or_null("TargetVisualizerToggle")
	if visualizer_toggle:
		visualizer_toggle.toggled.connect(_on_target_visualizer_toggled)
		# Sync with current state
		if has_node("/root/PickaxeTargetVisualizer"):
			visualizer_toggle.button_pressed = get_node("/root/PickaxeTargetVisualizer").enabled
	
	# Connect hit marker toggle
	var hit_marker_toggle = game_menu.get_node_or_null("HitMarkerToggle")
	if hit_marker_toggle:
		hit_marker_toggle.toggled.connect(_on_hit_marker_toggled)
		# Sync with current state
		if has_node("/root/HitMarkerConfig"):
			hit_marker_toggle.button_pressed = get_node("/root/HitMarkerConfig").enabled
	
	# Connect pistol hit marker toggle
	var pistol_marker_toggle = game_menu.get_node_or_null("PistolHitMarkerToggle")
	if pistol_marker_toggle:
		pistol_marker_toggle.toggled.connect(_on_pistol_hit_marker_toggled)
		# Sync with current state
		if has_node("/root/PistolHitMarkerConfig"):
			pistol_marker_toggle.button_pressed = get_node("/root/PistolHitMarkerConfig").enabled
	
	# Connect QuickSave button (F5)
	var quicksave_btn = game_menu.get_node_or_null("QuickSaveButton")
	if quicksave_btn:
		quicksave_btn.pressed.connect(_on_quicksave_pressed)
	
	# Connect QuickLoad button (F8)
	var quickload_btn = game_menu.get_node_or_null("QuickLoadButton")
	if quickload_btn:
		quickload_btn.pressed.connect(_on_quickload_pressed)
	
	mode_label.text = "PLAY"
	interaction_prompt.visible = false
	game_menu.visible = false
	if target_material_label:
		target_material_label.visible = false  # Hidden until debug preset enables it
	
	_setup_visual_overlays()

func _setup_visual_overlays() -> void:
	if not underwater_overlay:
		underwater_overlay = ColorRect.new()
		underwater_overlay.name = "UnderwaterOverlay"
		underwater_overlay.color = Color(0.05, 0.2, 0.12, 0.4)
		underwater_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		underwater_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		underwater_overlay.visible = false
		add_child(underwater_overlay)
		move_child(underwater_overlay, 0)
	
	# Create save/load notification label
	if not notification_label:
		notification_label = Label.new()
		notification_label.name = "SaveLoadNotification"
		notification_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		notification_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		notification_label.set_anchors_preset(Control.PRESET_CENTER)
		notification_label.offset_top = -100  # Above center
		notification_label.add_theme_font_size_override("font_size", 32)
		notification_label.add_theme_color_override("font_color", Color.YELLOW)
		notification_label.add_theme_color_override("font_outline_color", Color.BLACK)
		notification_label.add_theme_constant_override("outline_size", 4)
		notification_label.visible = false
		notification_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(notification_label)
		print("[HUD_SETUP] Notification label created")
	
	# Connect to SaveManager signals  
	print("[HUD_SETUP] Checking for SaveManager...")
	var save_mgr = get_tree().get_first_node_in_group("save_manager")
	if not save_mgr:
		# Fallback: try autoload path
		if has_node("/root/SaveManagerV2"):
			save_mgr = get_node("/root/SaveManagerV2")
	
	if save_mgr:
		print("[HUD_SETUP] SaveManager found: %s" % save_mgr.name)
		if save_mgr.has_signal("save_completed") and not save_mgr.save_completed.is_connected(_on_save_completed):
			save_mgr.save_completed.connect(_on_save_completed)
			print("[HUD_SETUP] Connected to save_completed signal")
		if save_mgr.has_signal("load_completed") and not save_mgr.load_completed.is_connected(_on_load_completed):
			save_mgr.load_completed.connect(_on_load_completed)
			print("[HUD_SETUP] Connected to load_completed signal")
	else:
		print("[HUD_SETUP] WARNING: SaveManager not found in scene tree!")

func _process(_delta: float) -> void:
	_update_compass()
	_update_status_bars()
	_update_build_mode_info()
	_update_durability_visibility()
	
	# Update notification timer
	if notification_timer > 0:
		notification_timer -= _delta
		if notification_timer <= 0 and notification_label:
			notification_label.visible = false

func _setup_hotbar() -> void:
	hotbar_slots.clear()
	
	for i in range(10):
		var slot = InventorySlotScene.instantiate()
		slot.slot_index = i + 100
		slot.custom_minimum_size = Vector2(80, 60)
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.item_dropped_outside.connect(_on_hotbar_item_dropped_outside.bind(slot))
		hotbar_container.add_child(slot)
		hotbar_slots.append(slot)
	
	var player_node = get_tree().get_first_node_in_group("player")
	if player_node:
		hotbar_ref = player_node.get_node_or_null("Systems/Hotbar")
		inventory_ref = player_node.get_node_or_null("Systems/Inventory")
	
	_refresh_hotbar_display()
	
	if hotbar_slots.size() > 0:
		hotbar_slots[0].modulate = Color.YELLOW
	
	if hotbar_ref and selected_item_label:
		var first_item = hotbar_ref.get_item_at(0)
		selected_item_label.text = first_item.get("name", "Fists")

func _refresh_hotbar_display() -> void:
	if not hotbar_ref:
		return
	
	var raw_data = hotbar_ref.get_all_slots() if hotbar_ref.has_method("get_all_slots") else []
	for i in range(min(hotbar_slots.size(), raw_data.size())):
		var slot_data = raw_data[i]
		if slot_data is Dictionary and slot_data.has("item"):
			hotbar_slots[i].set_slot_data(slot_data, i + 100)
		else:
			var wrapped = {"item": slot_data, "count": 1 if slot_data.get("id", "empty") != "empty" else 0}
			hotbar_slots[i].set_slot_data(wrapped, i + 100)
	
	_restore_slot_selection()

func _restore_slot_selection() -> void:
	if not hotbar_ref:
		return
	var selected = hotbar_ref.get_selected_index()
	for i in range(hotbar_slots.size()):
		if i == selected:
			hotbar_slots[i].modulate = Color.YELLOW
		else:
			hotbar_slots[i].modulate = Color.WHITE

func _on_hotbar_item_dropped_outside(item: Dictionary, count: int, slot) -> void:
	var slot_idx = slot.slot_index - 100
	
	if hotbar_ref and hotbar_ref.has_method("clear_slot"):
		hotbar_ref.clear_slot(slot_idx)
	
	var player = get_tree().get_first_node_in_group("player")
	var drop_pos = Vector3.ZERO
	var drop_velocity = Vector3.ZERO
	if player:
		drop_pos = player.global_position - player.global_transform.basis.z * 2.0 + Vector3.UP
		drop_velocity = -player.global_transform.basis.z * 3.0 + Vector3.UP * 2.0
	
	_spawn_pickup(item, count, drop_pos, drop_velocity)
	_refresh_hotbar_display()

func _spawn_pickup(item: Dictionary, count: int, pos: Vector3, velocity: Vector3 = Vector3.ZERO) -> void:
	var scene_path = item.get("scene", "")
	var spawned_directly = false
	
	if scene_path != "":
		var item_scene = load(scene_path)
		if item_scene:
			var temp_instance = item_scene.instantiate()
			if temp_instance is RigidBody3D:
				get_tree().root.add_child(temp_instance)
				temp_instance.global_position = pos
				if not temp_instance.is_in_group("interactable"):
					temp_instance.add_to_group("interactable")
				temp_instance.set_meta("item_data", item.duplicate())
				temp_instance.linear_velocity = velocity
				spawned_directly = true
			else:
				temp_instance.queue_free()
	
	if not spawned_directly:
		# V2 path
		var pickup_scene = load("res://modules/world_player_v2/features/data_pickups/pickup_item.tscn")
		if not pickup_scene:
			return
		
		var pickup = pickup_scene.instantiate()
		get_tree().root.add_child(pickup)
		pickup.global_position = pos
		pickup.set_item(item, count)
		pickup.linear_velocity = velocity

func handle_slot_drop(source_index: int, target_index: int) -> void:
	if source_index == target_index:
		return
	
	# If container panel is open, delegate to it for 3-way drag-drop
	var container_panel = get_tree().get_first_node_in_group("container_panel")
	if container_panel and container_panel.visible:
		container_panel.handle_slot_drop(source_index, target_index)
		_refresh_hotbar_display()
		return
	
	var source_is_hotbar = source_index >= 100
	var target_is_hotbar = target_index >= 100
	var source_idx = source_index % 100
	var target_idx = target_index % 100
	
	var source_system = hotbar_ref if source_is_hotbar else inventory_ref
	var target_system = hotbar_ref if target_is_hotbar else inventory_ref
	
	if not source_system or not target_system:
		return
	
	var source_data = source_system.get_slot(source_idx) if source_system.has_method("get_slot") else {}
	var target_data = target_system.get_slot(target_idx) if target_system.has_method("get_slot") else {}
	
	var source_item = source_data.get("item", {})
	var source_count = source_data.get("count", 0)
	var target_item = target_data.get("item", {})
	var target_count = target_data.get("count", 0)
	
	if source_system.has_method("set_slot") and target_system.has_method("set_slot"):
		target_system.set_slot(target_idx, source_item, source_count)
		source_system.set_slot(source_idx, target_item, target_count)
	
	_refresh_hotbar_display()

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

func _update_status_bars() -> void:
	if has_node("/root/PlayerStats"):
		health_bar.value = PlayerStats.health
		health_bar.max_value = PlayerStats.max_health
		stamina_bar.value = PlayerStats.stamina
		stamina_bar.max_value = PlayerStats.max_stamina

func _on_mode_changed(_old_mode: String, new_mode: String) -> void:
	mode_label.text = new_mode
	
	match new_mode:
		"PLAY":
			mode_label.modulate = Color.WHITE
		"BUILD":
			mode_label.modulate = Color.CYAN
		"EDITOR":
			mode_label.modulate = Color.YELLOW
	
	_update_hotbar_display()

func _on_item_changed(slot: int, item: Dictionary) -> void:
	# Allow updates in both player and editor modes
	if slot >= 0 and slot < hotbar_slots.size():
		var count = 1
		if hotbar_ref and hotbar_ref.has_method("get_count_at"):
			count = hotbar_ref.get_count_at(slot)
		var wrapped = {"item": item, "count": count}
		hotbar_slots[slot].set_slot_data(wrapped, slot + 100)
	
	if hotbar_ref and selected_item_label:
		var selected_slot = hotbar_ref.get_selected_index()
		if slot == selected_slot:
			selected_item_label.text = item.get("name", "Empty")

func _on_hotbar_slot_selected(slot: int) -> void:
	# Allow updates in both player and editor modes
	
	for i in range(hotbar_slots.size()):
		if i == slot:
			hotbar_slots[i].modulate = Color.YELLOW
		else:
			hotbar_slots[i].modulate = Color.WHITE
	
	var player_node = get_tree().get_first_node_in_group("player")
	if player_node and selected_item_label:
		var hotbar = player_node.get_node_or_null("Systems/Hotbar")
		if hotbar:
			var item = hotbar.get_item_at(slot)
			selected_item_label.text = item.get("name", "Empty")

func _on_interaction_available(_target: Node, prompt: String) -> void:
	interaction_prompt.text = prompt
	interaction_prompt.visible = true

func _on_interaction_unavailable() -> void:
	interaction_prompt.visible = false

func _on_inventory_toggled(_is_open: bool) -> void:
	pass

func _on_game_menu_toggled(is_open: bool) -> void:
	game_menu.visible = is_open

func _on_exit_pressed() -> void:
	get_tree().quit()

func _on_collision_debugger_toggled(is_enabled: bool) -> void:
	if has_node("/root/CollisionDebugger"):
		get_node("/root/CollisionDebugger").enabled = is_enabled

func _on_pickaxe_dig_mode_toggled(is_enabled: bool) -> void:
	if has_node("/root/PickaxeDigConfig"):
		get_node("/root/PickaxeDigConfig").enabled = is_enabled
		print("PlayerHUD: Enhanced Pickaxe Mode -> %s" % ("ON" if is_enabled else "OFF"))

func _on_pickaxe_durability_toggled(is_enabled: bool) -> void:
	if has_node("/root/PickaxeDurabilityConfig"):
		get_node("/root/PickaxeDurabilityConfig").enabled = is_enabled
		print("PlayerHUD: Pickaxe Durability -> %s" % ("ON (5 hits)" if is_enabled else "OFF (Instant)"))


func _on_target_visualizer_toggled(is_enabled: bool) -> void:
	if has_node("/root/PickaxeTargetVisualizer"):
		get_node("/root/PickaxeTargetVisualizer").enabled = is_enabled
		print("PlayerHUD: Target Visualizer -> %s" % ("ON" if is_enabled else "OFF"))

func _on_hit_marker_toggled(is_enabled: bool) -> void:
	if has_node("/root/HitMarkerConfig"):
		get_node("/root/HitMarkerConfig").enabled = is_enabled
		print("PlayerHUD: Hit Markers -> %s" % ("ON" if is_enabled else "OFF"))

func _on_pistol_hit_marker_toggled(is_enabled: bool) -> void:
	if has_node("/root/PistolHitMarkerConfig"):
		get_node("/root/PistolHitMarkerConfig").enabled = is_enabled
		print("PlayerHUD: Pistol Hit Markers -> %s" % ("ON" if is_enabled else "OFF"))

func _on_quicksave_pressed() -> void:
	if has_node("/root/SaveManager"):
		get_node("/root/SaveManager").quick_save()
		print("PlayerHUD: QuickSave triggered (F5)")
	else:
		push_error("PlayerHUD: SaveManager not found!")

func _on_quickload_pressed() -> void:
	if has_node("/root/SaveManager"):
		get_node("/root/SaveManager").quick_load()
		print("PlayerHUD: QuickLoad triggered (F8)")
	else:
		push_error("PlayerHUD: SaveManager not found!")


func _on_inventory_changed() -> void:
	_refresh_hotbar_display()

func _update_build_mode_info() -> void:
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
	
	if not mode_manager_node.is_build_mode():
		if build_info_label:
			build_info_label.visible = false
		return
	
	var mode_build = player_node.get_node_or_null("Modes/ModeBuild")
	if not mode_build:
		if build_info_label:
			build_info_label.visible = false
		return
	
	var building_api = mode_build.get("building_api")
	if not building_api:
		if build_info_label:
			build_info_label.visible = false
		return
	
	var placement_modes = ["SNAP", "EMBED", "AUTO", "FILL"]
	var mode_idx = building_api.get("placement_mode")
	var mode_str = placement_modes[mode_idx] if mode_idx != null and mode_idx < 4 else "?"
	
	var curr_rotation = mode_build.get("current_rotation")
	var rot_str = "%d°" % (curr_rotation * 90) if curr_rotation != null else "?"
	
	var y_offset = building_api.get("placement_y_offset")
	var y_str = "Y:%+d" % y_offset if y_offset != null and y_offset != 0 else ""
	
	if build_info_label:
		build_info_label.text = "[%s] Rot:%s %s" % [mode_str, rot_str, y_str]
		build_info_label.visible = true

func _on_editor_submode_changed(_submode: int, _submode_name: String) -> void:
	_update_hotbar_display()

func _update_hotbar_display() -> void:
	# Use same display logic for both player and editor modes
	_refresh_hotbar_display()
	
	if hotbar_ref:
		var selected = hotbar_ref.get_selected_index()
		if selected >= 0 and selected < hotbar_slots.size():
			hotbar_slots[selected].modulate = Color.YELLOW
		
		if selected_item_label:
			var item = hotbar_ref.get_item_at(selected)
			selected_item_label.text = item.get("name", "Empty")

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
	var hp_percent = 100.0 * float(current_hp) / float(max_hp)
	
	var key = _target_to_key(target_ref)
	durability_memory[key] = {
		"target_ref": target_ref,
		"hit_time": Time.get_ticks_msec(),
		"hp_percent": hp_percent
	}
	last_hit_target_key = key
	
	print("DURABILITY_DEBUG: HUD received hit | Target: %s | HP: %.1f%% | Key: %s" % [_target_name, hp_percent, key])
	durability_bar.value = hp_percent
	durability_bar.visible = true

func _on_durability_cleared() -> void:
	if durability_bar:
		durability_bar.visible = false
		durability_bar.value = 0
	if last_hit_target_key != "":
		durability_memory.erase(last_hit_target_key)
		last_hit_target_key = ""

func _update_durability_visibility() -> void:
	if not durability_bar or durability_memory.is_empty():
		return
	
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
	
	var player_node = get_tree().get_first_node_in_group("player")
	if not player_node or not player_node.has_method("raycast"):
		return
	
	var hit = player_node.raycast(5.0, 0xFFFFFFFF, true, true)
	if hit.is_empty():
		durability_bar.visible = false
		return
	
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	var hit_normal = hit.get("normal", Vector3.UP)
	
	var look_rid = target.get_rid() if target else RID()
	
	for key in durability_memory:
		var entry = durability_memory[key]
		var remembered_target = entry.target_ref
		var is_match = false
		
		if remembered_target is RID:
			if target and look_rid == remembered_target:
				is_match = true
		elif remembered_target is Vector3i:
			# Use SAME snapping logic as combat_system.gd to ensure position matching
			var snapped_pos = position - hit_normal * 0.1
			snapped_pos = Vector3(floor(snapped_pos.x) + 0.5, floor(snapped_pos.y) + 0.5, floor(snapped_pos.z) + 0.5)
			var block_pos = Vector3i(floor(snapped_pos.x), floor(snapped_pos.y), floor(snapped_pos.z))
			if block_pos == remembered_target:
				is_match = true
		elif remembered_target is Node:
			if target == remembered_target or _is_child_of(target, remembered_target):
				is_match = true
		
		if is_match:
			durability_bar.value = entry.hp_percent
			durability_bar.visible = true
			return
	
	print("DURABILITY_DEBUG: HUD hiding bar - no match found (looking at different block)")
	durability_bar.visible = false

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
		# Check if debug preset allows showing this
		var show_label = false
		if has_node("/root/DebugManager"):
			show_label = get_node("/root/DebugManager").should_show_terrain_marker()
		target_material_label.visible = show_label
		
		if show_label:
			# Show terraformer material if equipped, otherwise show looking-at material
			if terraformer_material != "":
				target_material_label.text = "[TF: %s] %s" % [terraformer_material, material_name]
			else:
				target_material_label.text = material_name

func _on_terraformer_material_changed(material_name: String) -> void:
	terraformer_material = material_name
	if target_material_label:
		# Check if debug preset allows showing this
		var show_label = false
		if has_node("/root/DebugManager"):
			show_label = get_node("/root/DebugManager").should_show_terrain_marker()
		target_material_label.visible = show_label
		
		if show_label:
			if material_name == "":
				terraformer_material = ""
			else:
				target_material_label.text = "[TF: %s]" % material_name

func _on_camera_underwater_toggled(is_underwater: bool) -> void:
	if underwater_overlay:
		underwater_overlay.visible = is_underwater

func _on_save_completed(success: bool, path: String) -> void:
	if success and notification_label:
		notification_label.text = "🎮 GAME SAVED!"
		notification_label.visible = true
		notification_timer = 2.0  # Show for 2 seconds
		print("[SAVE_NOTIFICATION] Game saved!")

func _on_load_completed(success: bool, path: String) -> void:
	if success and notification_label:
		notification_label.text = "📂 GAME LOADED!"
		notification_label.visible = true
		notification_timer = 2.0  # Show for 2 seconds
		print("[LOAD_NOTIFICATION] Game loaded!")
