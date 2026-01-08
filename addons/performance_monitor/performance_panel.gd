@tool
extends Control
## Performance Monitor Panel - Shows performance logs in a dedicated editor panel

const MAX_LOG_ENTRIES = 500
const SEVERITY_COLORS = {
	"SPIKE": Color(1.0, 0.4, 0.3),       # Red-orange for spikes
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
	"default": Color(0.9, 0.9, 0.9)      # Light gray default
}

@onready var log_list: RichTextLabel = $VBoxContainer/LogList
@onready var filter_option: OptionButton = $VBoxContainer/Toolbar/FilterOption
@onready var clear_button: Button = $VBoxContainer/Toolbar/ClearButton
@onready var spike_count_label: Label = $VBoxContainer/Toolbar/SpikeCountLabel

var all_logs: Array[Dictionary] = []
var spike_count: int = 0
var current_filter: String = "All"

# Categories for filtering
var categories = ["All", "SPIKE", "Building", "Chunk", "Vegetation", "Entities", "Save", "Vehicles", "Player", "Roads", "Water", "Performance"]


func _ready() -> void:
	# Setup filter dropdown
	filter_option.clear()
	for cat in categories:
		filter_option.add_item(cat)
	filter_option.selected = 0
	filter_option.item_selected.connect(_on_filter_changed)
	
	# Setup clear button
	clear_button.pressed.connect(_on_clear_pressed)
	
	# Try to connect to PerformanceMonitor autoload
	call_deferred("_connect_to_monitor")
	
	# Poll for messages (fallback if signal not available)
	var timer = Timer.new()
	timer.wait_time = 0.1
	timer.autostart = true
	timer.timeout.connect(_poll_monitor)
	add_child(timer)


func _connect_to_monitor() -> void:
	# Try to find the PerformanceMonitor singleton
	if Engine.has_singleton("PerformanceMonitor"):
		var monitor = Engine.get_singleton("PerformanceMonitor")
		if monitor.has_signal("spike_logged"):
			monitor.spike_logged.connect(_on_spike_logged)
			print("[PerfPanel] Connected to PerformanceMonitor signal")
			return
	
	# Try via autoload path
	var root = Engine.get_main_loop()
	if root and root is SceneTree:
		var perf_mon = root.root.get_node_or_null("PerformanceMonitor")
		if perf_mon and perf_mon.has_signal("spike_logged"):
			perf_mon.spike_logged.connect(_on_spike_logged)
			print("[PerfPanel] Connected to PerformanceMonitor autoload")


var _last_poll_buffer: Array = []

func _poll_monitor() -> void:
	# Fallback polling mechanism for when signal isn't available
	# Checks a static buffer in PerformanceMonitor
	var root = Engine.get_main_loop()
	if not root or not root is SceneTree:
		return
	
	var perf_mon = root.root.get_node_or_null("PerformanceMonitor")
	if not perf_mon:
		return
	
	# Check if PerformanceMonitor has a log buffer
	if "log_buffer" in perf_mon:
		var buffer = perf_mon.log_buffer as Array
		if buffer.size() > _last_poll_buffer.size():
			# New entries
			for i in range(_last_poll_buffer.size(), buffer.size()):
				var entry = buffer[i]
				_add_log_entry(entry.category, entry.message, entry.time)
			_last_poll_buffer = buffer.duplicate()


func _on_spike_logged(category: String, message: String, duration_ms: float, threshold_ms: float) -> void:
	var formatted = "[SPIKE] %s took %.2fms (Threshold: %.2fms)" % [category, duration_ms, threshold_ms]
	_add_log_entry("SPIKE", formatted, Time.get_ticks_msec())
	spike_count += 1
	_update_spike_count()


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


func _on_filter_changed(index: int) -> void:
	current_filter = categories[index]
	_refresh_display()


func _on_clear_pressed() -> void:
	all_logs.clear()
	spike_count = 0
	_update_spike_count()
	_refresh_display()


func _refresh_display() -> void:
	if not log_list:
		return
	
	log_list.clear()
	
	for entry in all_logs:
		if current_filter == "All" or entry.category.contains(current_filter):
			_append_to_display(entry)


func _update_spike_count() -> void:
	if spike_count_label:
		spike_count_label.text = "Spikes: %d" % spike_count


## Called by PerformanceMonitor to add a log entry directly
func add_log(category: String, message: String) -> void:
	_add_log_entry(category, message, Time.get_ticks_msec())
	if category == "SPIKE" or message.begins_with("[SPIKE]"):
		spike_count += 1
		_update_spike_count()
