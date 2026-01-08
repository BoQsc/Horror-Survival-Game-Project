@tool
extends EditorPlugin

var debugger_plugin: EditorDebuggerPlugin = null
var panel_instance: Control = null


func _enter_tree() -> void:
	# Create and register the debugger plugin for game-to-editor communication
	debugger_plugin = preload("res://addons/performance_monitor/perf_debugger_plugin.gd").new()
	add_debugger_plugin(debugger_plugin)
	
	# Create the panel instance
	var panel_scene = preload("res://addons/performance_monitor/performance_panel.tscn")
	panel_instance = panel_scene.instantiate()
	
	# Connect debugger to panel (bidirectional)
	debugger_plugin.panel = panel_instance
	panel_instance.set_debugger_plugin(debugger_plugin)
	
	# Add to bottom panel (shows as a tab alongside Output, Debugger, etc.)
	add_control_to_bottom_panel(panel_instance, "Performance")
	print("[PerformanceMonitor Plugin] Panel added to editor")


func _exit_tree() -> void:
	if debugger_plugin:
		remove_debugger_plugin(debugger_plugin)
		debugger_plugin = null
	
	if panel_instance:
		remove_control_from_bottom_panel(panel_instance)
		panel_instance.queue_free()
		panel_instance = null
	print("[PerformanceMonitor Plugin] Panel removed from editor")
