extends CanvasLayer
class_name WorldGenerationLoadingOverlay
## Lightweight pre-game loading overlay for world generation and terrain baking.

@export var title: String = "Preparing World"
@export_range(1, 20, 1) var max_log_lines: int = 8
@export_range(0, 2000, 50) var min_update_interval_msec: int = 250

var background: ColorRect = null
var panel: PanelContainer = null
var title_label: Label = null
var status_label: Label = null
var detail_label: Label = null
var progress_bar: ProgressBar = null
var elapsed_label: Label = null
var log_label: Label = null

var overlay_visible: bool = false
var started_msec: int = 0
var last_stage: String = ""
var last_percent: float = -1.0
var last_details: Dictionary = {}
var last_update_msec: int = 0
var log_lines: Array[String] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 1000
	_ensure_built()
	hide_overlay()


func show_stage(stage: String, percent: float, details: Dictionary = {}, force_log: bool = false) -> void:
	_ensure_built()
	var safe_percent := clampf(percent, 0.0, 100.0)
	var now_msec := Time.get_ticks_msec()
	var stage_changed := stage != last_stage
	var percent_changed := last_percent < 0.0 or absf(safe_percent - last_percent) >= 0.5
	var interval_ready := last_update_msec <= 0 or now_msec - last_update_msec >= min_update_interval_msec
	if not force_log and not stage_changed and not percent_changed and not interval_ready:
		return

	if started_msec <= 0:
		started_msec = now_msec
	overlay_visible = true
	visible = true
	if background:
		background.visible = true
	last_stage = stage
	last_percent = safe_percent
	last_details = details.duplicate(true)
	last_update_msec = now_msec

	if title_label:
		title_label.text = title
	if status_label:
		status_label.text = stage
	if detail_label:
		detail_label.text = _format_details(details)
	if progress_bar:
		progress_bar.value = safe_percent
	if elapsed_label:
		elapsed_label.text = "Elapsed %.1fs" % _elapsed_seconds()
	if force_log or stage_changed:
		append_log("%s (%.0f%%)" % [stage, safe_percent])


func append_log(message: String) -> void:
	_ensure_built()
	var line := "[%5.1fs] %s" % [_elapsed_seconds(), message]
	log_lines.append(line)
	while log_lines.size() > max_log_lines:
		log_lines.remove_at(0)
	if log_label:
		var text := ""
		for i in range(log_lines.size()):
			if i > 0:
				text += "\n"
			text += log_lines[i]
		log_label.text = text


func set_complete(message: String = "Ready", details: Dictionary = {}) -> void:
	show_stage(message, 100.0, details, true)
	if title_label:
		title_label.text = "World Ready"


func set_failed(message: String, details: Dictionary = {}) -> void:
	show_stage(message, 100.0, details, true)
	if title_label:
		title_label.text = "World Setup Failed"


func hide_overlay() -> void:
	overlay_visible = false
	visible = false
	if background:
		background.visible = false


func get_snapshot() -> Dictionary:
	return {
		"visible": overlay_visible,
		"stage": last_stage,
		"percent": last_percent,
		"details": last_details.duplicate(true),
		"elapsed_seconds": _elapsed_seconds(),
		"log_lines": log_lines.duplicate()
	}


func _ensure_built() -> void:
	if background:
		return

	background = ColorRect.new()
	background.name = "Background"
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.015, 0.018, 0.022, 0.94)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.add_child(center)

	panel = PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(760, 360)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_bottom", 24)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.name = "VBox"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	title_label = Label.new()
	title_label.name = "Title"
	title_label.text = title
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_label.add_theme_font_size_override("font_size", 28)
	box.add_child(title_label)

	status_label = Label.new()
	status_label.name = "Status"
	status_label.text = "Starting"
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_label.add_theme_font_size_override("font_size", 18)
	box.add_child(status_label)

	progress_bar = ProgressBar.new()
	progress_bar.name = "ProgressBar"
	progress_bar.min_value = 0.0
	progress_bar.max_value = 100.0
	progress_bar.value = 0.0
	progress_bar.show_percentage = true
	progress_bar.custom_minimum_size = Vector2(700, 28)
	progress_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(progress_bar)

	detail_label = Label.new()
	detail_label.name = "Details"
	detail_label.text = ""
	detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.custom_minimum_size = Vector2(700, 54)
	detail_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(detail_label)

	elapsed_label = Label.new()
	elapsed_label.name = "Elapsed"
	elapsed_label.text = "Elapsed 0.0s"
	elapsed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	elapsed_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(elapsed_label)

	log_label = Label.new()
	log_label.name = "Log"
	log_label.text = ""
	log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	log_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	log_label.custom_minimum_size = Vector2(700, 96)
	log_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(log_label)


func _format_details(details: Dictionary) -> String:
	if details.is_empty():
		return ""
	var parts: Array[String] = []
	_append_detail(parts, details, "backend", "backend")
	_append_detail(parts, details, "seed", "seed")
	_append_detail(parts, details, "town_count", "towns")
	_append_detail(parts, details, "world_path", "world")
	_append_detail(parts, details, "artifact_root", "artifacts")
	_append_detail(parts, details, "origin_count", "origins")
	_append_detail(parts, details, "radius_chunks", "radius")
	_append_detail(parts, details, "store_ready_mesh_resources", "ready_mesh")
	_append_detail(parts, details, "synchronous_disk_writes", "sync_writes")
	_append_detail(parts, details, "artifact_count", "artifacts")
	_append_detail(parts, details, "expected_chunks", "chunks")
	_append_detail(parts, details, "pending_work", "pending")
	_append_detail(parts, details, "elapsed_ms", "stage_ms")
	return " | ".join(parts)


func _append_detail(parts: Array[String], details: Dictionary, key: String, label: String) -> void:
	if not details.has(key):
		return
	var value: Variant = details.get(key)
	if value == null:
		return
	var text := str(value)
	if key == "elapsed_ms":
		text = "%.0f" % float(value)
	if text.is_empty():
		return
	parts.append("%s=%s" % [label, text])


func _elapsed_seconds() -> float:
	if started_msec <= 0:
		return 0.0
	return maxf(0.0, float(Time.get_ticks_msec() - started_msec) / 1000.0)
