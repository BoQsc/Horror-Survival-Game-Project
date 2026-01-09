@tool
extends Control
## Performance Monitor Panel - Shows performance logs in a dedicated editor panel

const MAX_LOG_ENTRIES = 500
const SEVERITY_COLORS = {
	"SPIKE": Color(1.0, 0.4, 0.3),       # Red-orange for spikes
	"FRAME": Color(1.0, 0.6, 0.2),       # Orange for frame summaries
	"Building": Color(0.5, 0.8, 1.0),    # Light blue for building
	"BatchFlush": Color(0.7, 0.9, 0.7),  # Light green for batch
	"Chunk": Color(0.9, 0.7, 0.5),       # Orange for chunks
	"Vegetation": Color(0.5, 0.9, 0.5),  # Green for vegetation
	"Entities": Color(0.8, 0.6, 0.9),    # Purple for entities
	"Save": Color(0.9, 0.9, 0.5),        # Yellow for save
	"Vehicles": Color(0.6, 0.6, 0.9),    # Blue-purple for vehicles
	"Player": Color(0.5, 0.9, 0.9),      # Cyan for player
	"Roads": Color(0.7, 0.7, 0.7),       # Gray for roads
	"Water": Color(0.4, 0.7, 1.0),       # Blue for water
	"Performance": Color(1.0, 0.6, 0.3), # Orange for performance
	"Config": Color(0.3, 1.0, 0.5),      # Bright green for config
	"Other": Color(0.6, 0.6, 0.6),       # Gray for "Other" time
	"default": Color(0.9, 0.9, 0.9)      # Light gray default
}

# Default thresholds for reference
const DEFAULT_THRESHOLDS = {
	"frame_time": 20.0,
	"chunk_gen": 3.0,
	"vegetation": 2.0
}

@onready var log_list: RichTextLabel = $VBoxContainer/LogList
@onready var filter_option: OptionButton = $VBoxContainer/Toolbar/FilterOption
@onready var clear_button: Button = $VBoxContainer/Toolbar/ClearButton
@onready var spike_count_label: Label = $VBoxContainer/Toolbar/SpikeCountLabel

# Threshold SpinBox references
@onready var frame_time_spinbox: SpinBox = $VBoxContainer/Toolbar/FrameTimeSpinBox
@onready var chunk_spinbox: SpinBox = $VBoxContainer/Toolbar/ChunkSpinBox
@onready var veg_spinbox: SpinBox = $VBoxContainer/Toolbar/VegSpinBox
@onready var reset_button: Button = $VBoxContainer/Toolbar/ResetButton

var all_logs: Array[Dictionary] = []
var spike_count: int = 0
var current_filter: String = "All"

# Categories for filtering (add FRAME for frame summaries)
var categories = ["All", "FRAME", "Building", "Chunk", "Vegetation", "Entities", "Save", "Vehicles", "Player", "Roads", "Water", "Config"]

# Reference to debugger plugin for sending messages
var _debugger_plugin = null


func _ready() -> void:
	# Setup filter dropdown
	filter_option.clear()
	for cat in categories:
		filter_option.add_item(cat)
	filter_option.selected = 0
	filter_option.item_selected.connect(_on_filter_changed)
	
	# Setup clear button
	clear_button.pressed.connect(_on_clear_pressed)
	
	# Setup threshold spinboxes
	frame_time_spinbox.value_changed.connect(_on_frame_time_changed)
	chunk_spinbox.value_changed.connect(_on_chunk_threshold_changed)
	veg_spinbox.value_changed.connect(_on_veg_threshold_changed)
	reset_button.pressed.connect(_on_reset_thresholds)


func set_debugger_plugin(plugin) -> void:
	_debugger_plugin = plugin


func _send_threshold_to_game(threshold_name: String, value: float) -> void:
	# Send threshold change to the running game via debugger plugin
	if _debugger_plugin and _debugger_plugin.has_method("send_threshold"):
		_debugger_plugin.send_threshold(threshold_name, value)


func _on_frame_time_changed(value: float) -> void:
	_send_threshold_to_game("frame_time", value)


func _on_chunk_threshold_changed(value: float) -> void:
	_send_threshold_to_game("chunk_gen", value)


func _on_veg_threshold_changed(value: float) -> void:
	_send_threshold_to_game("vegetation", value)


func _on_reset_thresholds() -> void:
	# Reset UI
	frame_time_spinbox.value = DEFAULT_THRESHOLDS["frame_time"]
	chunk_spinbox.value = DEFAULT_THRESHOLDS["chunk_gen"]
	veg_spinbox.value = DEFAULT_THRESHOLDS["vegetation"]
	
	# Send reset command to game
	if _debugger_plugin and _debugger_plugin.has_method("send_reset_thresholds"):
		_debugger_plugin.send_reset_thresholds()


func _on_filter_changed(index: int) -> void:
	current_filter = categories[index]
	_refresh_display()


func _on_clear_pressed() -> void:
	all_logs.clear()
	spike_count = 0
	_update_spike_count()
	_refresh_display()


func _add_log_entry(category: String, message: String, timestamp_ms: int) -> void:
	var entry = {
		"category": category,
		"message": message,
		"timestamp": timestamp_ms
	}
	all_logs.append(entry)
	
	# Trim if too many
	if all_logs.size() > MAX_LOG_ENTRIES:
		all_logs.pop_front()
	
	# Add to display if filter matches
	if current_filter == "All" or category.contains(current_filter):
		_append_to_display(entry)


func _append_to_display(entry: Dictionary) -> void:
	if not log_list:
		return
	
	var color = SEVERITY_COLORS.get(entry.category, SEVERITY_COLORS["default"])
	var time_str = "%d.%03d" % [entry.timestamp / 1000, entry.timestamp % 1000]
	
	log_list.push_color(Color(0.6, 0.6, 0.6))
	log_list.add_text("[%s] " % time_str)
	log_list.pop()
	
	log_list.push_color(color)
	log_list.add_text(entry.message)
	log_list.pop()
	
	log_list.newline()
	
	# Auto-scroll to bottom
	log_list.scroll_to_line(log_list.get_line_count() - 1)


func _refresh_display() -> void:
	if not log_list:
		return
	
	log_list.clear()
	
	for entry in all_logs:
		if current_filter == "All" or entry.category.contains(current_filter):
			_append_to_display(entry)


func _update_spike_count() -> void:
	if spike_count_label:
		spike_count_label.text = "Frames: %d" % spike_count


## Called by the debugger plugin to add a simple log entry
func add_log(category: String, message: String) -> void:
	_add_log_entry(category, message, Time.get_ticks_msec())


## Called by debugger plugin to add a frame summary (grouped view)
func add_frame_summary(summary: Dictionary) -> void:
	if not log_list:
		return
	
	var frame_num = summary.get("frame", 0)
	var total_ms = summary.get("total_ms", 0.0)
	var measures = summary.get("measures", [])
	
	# Store as log entry
	var entry = {
		"category": "FRAME",
		"message": "Frame #%d: %.1fms" % [frame_num, total_ms],
		"timestamp": Time.get_ticks_msec(),
		"summary": summary
	}
	all_logs.append(entry)
	if all_logs.size() > MAX_LOG_ENTRIES:
		all_logs.pop_front()
	
	# Update spike count
	spike_count += 1
	_update_spike_count()
	
	# Only display if filter matches
	if current_filter != "All" and current_filter != "FRAME":
		return
	
	# Display frame header
	var header_color = SEVERITY_COLORS.get("FRAME", Color.ORANGE)
	var time_str = "%d.%03d" % [entry.timestamp / 1000, entry.timestamp % 1000]
	
	log_list.push_color(Color(0.6, 0.6, 0.6))
	log_list.add_text("[%s] " % time_str)
	log_list.pop()
	
	log_list.push_color(header_color)
	log_list.add_text("▼ Frame #%d - Total: %.1fms" % [frame_num, total_ms])
	log_list.pop()
	log_list.newline()
	
	# Display breakdown (sorted by impact - already sorted in game)
	for i in range(measures.size()):
		var m = measures[i]
		var name = m.get("name", "Unknown")
		var ms = m.get("ms", 0.0)
		var pct = m.get("pct", 0.0)
		
		# Choose color based on measure name or default
		var measure_color = SEVERITY_COLORS.get(name, SEVERITY_COLORS["default"])
		if name == "Other":
			measure_color = SEVERITY_COLORS["Other"]
		
		# Indent and tree-like display
		var prefix = "   └─ " if i == measures.size() - 1 else "   ├─ "
		
		log_list.push_color(Color(0.5, 0.5, 0.5))
		log_list.add_text(prefix)
		log_list.pop()
		
		log_list.push_color(measure_color)
		log_list.add_text("%s: %.1fms (%.0f%%)" % [name, ms, pct])
		log_list.pop()
		log_list.newline()
	
	# Auto-scroll to bottom
	log_list.scroll_to_line(log_list.get_line_count() - 1)

