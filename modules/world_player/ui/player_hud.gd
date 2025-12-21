extends CanvasLayer
class_name PlayerHUD
## PlayerHUD - Main HUD for the world_player module
## Displays mode, hotbar, health, stamina, crosshair, interaction prompts

# References
@onready var mode_label: Label = $ModeIndicator
@onready var hotbar_container: HBoxContainer = $HotbarPanel/HotbarContainer
@onready var crosshair: TextureRect = $Crosshair
@onready var interaction_prompt: Label = $InteractionPrompt
@onready var health_bar: ProgressBar = $StatusBars/HealthBar
@onready var stamina_bar: ProgressBar = $StatusBars/StaminaBar
@onready var compass: Label = $Compass
@onready var game_menu: Control = $GameMenu

# Hotbar slot labels
var slot_labels: Array[Label] = []

func _ready() -> void:
	# Connect to player signals
	PlayerSignals.mode_changed.connect(_on_mode_changed)
	PlayerSignals.item_changed.connect(_on_item_changed)
	PlayerSignals.hotbar_slot_selected.connect(_on_hotbar_slot_selected)
	PlayerSignals.interaction_available.connect(_on_interaction_available)
	PlayerSignals.interaction_unavailable.connect(_on_interaction_unavailable)
	PlayerSignals.inventory_toggled.connect(_on_inventory_toggled)
	PlayerSignals.game_menu_toggled.connect(_on_game_menu_toggled)
	
	# Initialize hotbar UI
	_setup_hotbar()
	
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

## Setup hotbar slot display
func _setup_hotbar() -> void:
	# Get hotbar from player (via autoload signal is fine for now)
	slot_labels.clear()
	
	# Find all slot labels in hotbar container
	for i in range(10):
		var slot = hotbar_container.get_node_or_null("Slot%d" % i)
		if slot and slot is Label:
			slot_labels.append(slot)

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
	
	# Change mode label color based on mode
	match new_mode:
		"PLAY":
			mode_label.modulate = Color.WHITE
		"BUILD":
			mode_label.modulate = Color.CYAN
		"EDITOR":
			mode_label.modulate = Color.YELLOW

## Item changed handler
func _on_item_changed(slot: int, item: Dictionary) -> void:
	if slot >= 0 and slot < slot_labels.size():
		slot_labels[slot].text = "[%s]" % item.get("name", "Empty").substr(0, 3)

## Hotbar slot selected handler
func _on_hotbar_slot_selected(slot: int) -> void:
	# Highlight selected slot
	for i in range(slot_labels.size()):
		if i == slot:
			slot_labels[i].modulate = Color.YELLOW
		else:
			slot_labels[i].modulate = Color.WHITE

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
