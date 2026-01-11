extends Control
class_name RadialMenu
## RadialMenu - Shows options in a circular layout when holding E on interactable

signal option_selected(option: String)
signal menu_cancelled()

# Configuration
const MENU_RADIUS: float = 100.0
const SEGMENT_PADDING: float = 10.0
const FONT_SIZE: int = 16
const CENTER_DEAD_ZONE: float = 30.0

# State
var options: Array[String] = []
var selected_index: int = -1
var target_node: Node = null  # The node being interacted with (e.g., vehicle)
var is_active: bool = false

# Visual elements
var center_label: Label = null


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	# Create center label
	center_label = Label.new()
	center_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	center_label.add_theme_font_size_override("font_size", FONT_SIZE)
	add_child(center_label)


func _draw() -> void:
	if not is_active or options.is_empty():
		return
	
	var center = size / 2.0
	var segment_angle = TAU / options.size()
	
	for i in range(options.size()):
		var start_angle = -PI/2 + (i * segment_angle)
		var end_angle = start_angle + segment_angle
		var mid_angle = start_angle + segment_angle / 2.0
		
		# Draw segment background
		var color = Color(0.2, 0.2, 0.2, 0.8)
		if i == selected_index:
			color = Color(0.3, 0.6, 0.9, 0.9)  # Highlight selected
		
		_draw_arc_segment(center, MENU_RADIUS, start_angle, end_angle, color)
		
		# Draw segment border
		var border_color = Color(0.5, 0.5, 0.5, 1.0)
		if i == selected_index:
			border_color = Color(0.4, 0.7, 1.0, 1.0)
		_draw_arc_outline(center, MENU_RADIUS, start_angle, end_angle, border_color)
		
		# Draw option text
		var text_pos = center + Vector2(cos(mid_angle), sin(mid_angle)) * (MENU_RADIUS * 0.6)
		draw_string(ThemeDB.fallback_font, text_pos - Vector2(30, -5), options[i], 
			HORIZONTAL_ALIGNMENT_CENTER, -1, FONT_SIZE, Color.WHITE)


func _draw_arc_segment(center: Vector2, radius: float, start_angle: float, end_angle: float, color: Color) -> void:
	var points = PackedVector2Array()
	var num_points = 16
	
	points.append(center)
	for i in range(num_points + 1):
		var angle = start_angle + (end_angle - start_angle) * i / num_points
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	points.append(center)
	
	draw_colored_polygon(points, color)


func _draw_arc_outline(center: Vector2, radius: float, start_angle: float, end_angle: float, color: Color) -> void:
	var num_points = 16
	
	for i in range(num_points):
		var angle1 = start_angle + (end_angle - start_angle) * i / num_points
		var angle2 = start_angle + (end_angle - start_angle) * (i + 1) / num_points
		var p1 = center + Vector2(cos(angle1), sin(angle1)) * radius
		var p2 = center + Vector2(cos(angle2), sin(angle2)) * radius
		draw_line(p1, p2, color, 2.0)


func _process(_delta: float) -> void:
	if not is_active:
		return
	
	# Update selection based on mouse position
	var center = size / 2.0
	var mouse_offset = get_local_mouse_position() - center
	var distance = mouse_offset.length()
	
	# Dead zone in center - no selection
	if distance < CENTER_DEAD_ZONE:
		if selected_index != -1:
			selected_index = -1
			center_label.text = "Cancel"
			queue_redraw()
		return
	
	# Calculate which segment mouse is in
	var angle = atan2(mouse_offset.y, mouse_offset.x) + PI/2
	if angle < 0:
		angle += TAU
	
	var segment_angle = TAU / options.size()
	var new_index = int(angle / segment_angle) % options.size()
	
	if new_index != selected_index:
		selected_index = new_index
		center_label.text = options[selected_index]
		queue_redraw()


## Show radial menu with options for a target
func show_menu(opts: Array[String], target: Node = null) -> void:
	options = opts
	target_node = target
	selected_index = -1
	is_active = true
	visible = true
	
	# Display mouse
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	# Center the mouse
	var center = get_viewport_rect().size / 2.0
	warp_mouse(center)
	
	# Setup center label
	center_label.text = "Cancel"
	center_label.position = size / 2.0 - Vector2(50, 10)
	center_label.size = Vector2(100, 20)
	
	queue_redraw()
	print("[RadialMenu] Opened with options: %s" % str(options))


## Hide menu and emit result
func hide_menu(emit_selection: bool = true) -> void:
	is_active = false
	visible = false
	
	# Recapture mouse
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	if emit_selection:
		if selected_index >= 0 and selected_index < options.size():
			var selected = options[selected_index]
			print("[RadialMenu] Selected: %s" % selected)
			option_selected.emit(selected)
		else:
			print("[RadialMenu] Cancelled")
			menu_cancelled.emit()
	
	# Clear state
	options.clear()
	target_node = null
	selected_index = -1
	queue_redraw()
