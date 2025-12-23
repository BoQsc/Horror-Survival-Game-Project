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
@onready var health_bar: ProgressBar = $StatusBars/HealthBar
@onready var stamina_bar: ProgressBar = $StatusBars/StaminaBar
@onready var compass: Label = $Compass
@onready var game_menu: Control = $GameMenu
@onready var selected_item_label: Label = $SelectedItemLabel

# Hotbar slot labels
var slot_labels: Array[Label] = []

# Editor mode tracking
var is_editor_mode: bool = false
var current_editor_submode: int = 0
const EDITOR_SUBMODE_NAMES = ["Terrain", "Water", "Road", "Prefab", "Fly"]


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

func _process(_delta: float) -> void:
	# Update compass with player direction
	_update_compass()
	
	# Update health/stamina bars
	_update_status_bars()
	
	# Update mode label with extra build info when in BUILD mode
	_update_build_mode_info()

## Setup hotbar slot display
func _setup_hotbar() -> void:
	slot_labels.clear()
	
	# Find all slot labels in hotbar container
	for i in range(10):
		var slot = hotbar_container.get_node_or_null("Slot%d" % i)
		if slot and slot is Label:
			slot_labels.append(slot)
	
	# Find hotbar and populate names (signal fires before HUD connects)
	var player_node = get_tree().get_first_node_in_group("player")
	if player_node:
		var hotbar = player_node.get_node_or_null("Systems/Hotbar")
		if hotbar:
			for i in range(slot_labels.size()):
				var item = hotbar.get_item_at(i)
				slot_labels[i].text = "[%s]" % item.get("name", "Empty").substr(0, 3)
			# Set initial selected item label
			if selected_item_label:
				var first_item = hotbar.get_item_at(0)
				selected_item_label.text = first_item.get("name", "Fists")
	
	# Highlight first slot by default
	if slot_labels.size() > 0:
		slot_labels[0].modulate = Color.YELLOW

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
	if slot >= 0 and slot < slot_labels.size():
		slot_labels[slot].text = "[%s]" % item.get("name", "Empty").substr(0, 3)

## Hotbar slot selected handler
func _on_hotbar_slot_selected(slot: int) -> void:
	# Skip hotbar changes in editor mode - editor has its own display
	if is_editor_mode:
		return
	
	# Highlight selected slot
	for i in range(slot_labels.size()):
		if i == slot:
			slot_labels[i].modulate = Color.YELLOW
		else:
			slot_labels[i].modulate = Color.WHITE
	
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
		for i in range(slot_labels.size()):
			if i < EDITOR_SUBMODE_NAMES.size():
				slot_labels[i].text = "[%s]" % EDITOR_SUBMODE_NAMES[i].substr(0, 3)
				# Highlight selected submode
				if i == current_editor_submode:
					slot_labels[i].modulate = Color.YELLOW
				else:
					slot_labels[i].modulate = Color.WHITE
			else:
				# Show empty for unused slots
				slot_labels[i].text = "[Emp]"
				slot_labels[i].modulate = Color.DIM_GRAY
		
		# Update selected item label
		if selected_item_label:
			if current_editor_submode < EDITOR_SUBMODE_NAMES.size():
				selected_item_label.text = EDITOR_SUBMODE_NAMES[current_editor_submode]
			else:
				selected_item_label.text = "Editor"
	else:
		# Restore normal hotbar from items
		var player_node = get_tree().get_first_node_in_group("player")
		if player_node:
			var hotbar = player_node.get_node_or_null("Systems/Hotbar")
			if hotbar:
				for i in range(slot_labels.size()):
					var item = hotbar.get_item_at(i)
					slot_labels[i].text = "[%s]" % item.get("name", "Empty").substr(0, 3)
					slot_labels[i].modulate = Color.WHITE
				
				# Restore selected slot highlight
				var selected = hotbar.get_selected_index()
				if selected >= 0 and selected < slot_labels.size():
					slot_labels[selected].modulate = Color.YELLOW
				
				# Update selected item label
				if selected_item_label:
					var item = hotbar.get_item_at(selected)
					selected_item_label.text = item.get("name", "Empty")
