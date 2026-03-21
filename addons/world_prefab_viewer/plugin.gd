@tool
extends EditorPlugin

var _panel: Control = null


func _enter_tree() -> void:
	var panel_script := preload("res://addons/world_prefab_viewer/prefab_viewer_panel.gd")
	_panel = panel_script.new()
	add_control_to_bottom_panel(_panel, "Prefab Viewer")


func _exit_tree() -> void:
	if _panel:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null
