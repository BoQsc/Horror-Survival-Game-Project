# filename: 3d-first-person-wasd-input-actions.gd
@tool
extends EditorPlugin

const RegexFeatureScript = preload("activate_feature_regex.gd")
const TemplateFeatureScript = preload("add_script_templates.gd") # Added
var regex_feature_instance
var template_feature_instance # Added

func _enable_plugin() -> void:
	regex_feature_instance = RegexFeatureScript.new()
	
	# Activate Script Templates
	template_feature_instance = TemplateFeatureScript.new()
	if template_feature_instance.has_method("install_templates"):
		template_feature_instance.install_templates()
	
	# Input actions here
	add_action("move_forward", KEY_W)
	add_action("move_backward", KEY_S)
	add_action("move_left", KEY_A)
	add_action("move_right", KEY_D)
	
	# Save to project.godot
	ProjectSettings.save()
	print("[3d-first-person-wasd-input-actions] Plugin: Input actions saved to Project Settings.")

	# [Godot Editor Restarting]
	# Works, but restarts entire editor instead of only project settings window
	# Also resets the state of plugin being enabled, this is a restart_editor(true) bug probably.
	# Makes disabling this plugin an impossible thing.
	# get_editor_interface().restart_editor(true)
	# Alternative new syntax: 	EditorInterface.restart_editor()

	# [This is useless, can be removed]
	# Do not seem to do anything
	#InputMap.load_from_project_settings()


	# [This is useless, can be removed]
	# Do not seem to do anything
	# ProjectSettings.settings_changed.emit()
	# emit_signal("project_settings_changed");
	# print("  Emitted ProjectSettings.settings_changed signal.")

	# [This is useless, can be removed]
	# Do not seem to do anything
	# ProjectSettings.set_restart_if_changed("input/move_forward", true)

	


func _disable_plugin() -> void:
	if regex_feature_instance:
		regex_feature_instance.revert_changes()
		regex_feature_instance = null
	
	# Deactivate Script Templates
	if template_feature_instance:
		if template_feature_instance.has_method("remove_templates"):
			template_feature_instance.remove_templates()
		template_feature_instance = null
	
	# [This is useless, can be removed]
	# Do not seem to do anything
	#ProjectSettings.set_restart_if_changed("input/move_forward", true)
	
	# Removal of actions
	remove_action("move_forward", KEY_W)
	remove_action("move_backward", KEY_S)
	remove_action("move_left", KEY_A)
	remove_action("move_right", KEY_D)
	
	# Save to project.godot
	ProjectSettings.save()
	print("[3d-first-person-wasd-input-actions] Plugin: Input actions saved to Project Settings.")
	
	# [This is useless, can be removed]
	# Do not seem to do anything
	#ProjectSettings.settings_changed.emit()
	#emit_signal("project_settings_changed");
	#print("  Emitted ProjectSettings.settings_changed signal.")





func add_action(action_name: String, key_scancode: int):
	var event := InputEventKey.new()
	event.physical_keycode = key_scancode
	
	var property := "input/%s" % action_name
	var action: Dictionary = ProjectSettings.get_setting(property, { "deadzone": 0.5, "events": [] })
	
	# Check for existing events to avoid duplicates
	var event_exists := false
	for existing_event in action["events"]:
		if is_same_key_event(existing_event, event):
			event_exists = true
			break
	
	if not event_exists:
		action["events"].append(event)
		ProjectSettings.set_setting(property, action)
		
		# Update InputMap for immediate effect
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
		InputMap.action_add_event(action_name, event)
		

	
func is_same_key_event(a: InputEvent, b: InputEvent) -> bool:
	if a is InputEventKey and b is InputEventKey:
		return a.physical_keycode == b.physical_keycode
	return false


func remove_action(action_name: String, key_scancode: int):
	var event := InputEventKey.new()
	event.physical_keycode = key_scancode
	
	var property := "input/%s" % action_name
	var action: Dictionary = ProjectSettings.get_setting(property, { "deadzone": 0.5, "events": [] })
	
	# Check for existing events to avoid duplicates
	var event_exists := false
	for existing_event in action["events"]:
		if is_same_key_event(existing_event, event):
			event_exists = true
			break
	
	if event_exists:
		action["events"].append(event)
		ProjectSettings.set_setting(property, null)
		
		# Update InputMap for immediate effect
		if InputMap.has_action(action_name):
			InputMap.erase_action(action_name)
