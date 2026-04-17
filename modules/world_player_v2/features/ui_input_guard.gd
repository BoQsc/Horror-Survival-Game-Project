extends RefCounted
class_name WorldPlayerUIInputGuard
## WorldPlayerUIInputGuard - Shared helper for blocking gameplay hotkeys while typing in UI.
## Uses the local input lock for modal UI, plus direct focus checks for text entry.

static func is_text_entry_focused(viewport: Viewport = null) -> bool:
	if viewport == null:
		return false

	var focus_owner := viewport.gui_get_focus_owner()
	if not is_instance_valid(focus_owner):
		return false

	return focus_owner is LineEdit or focus_owner is TextEdit

static func release_viewport_focus(viewport: Viewport = null) -> void:
	if viewport == null:
		return

	var focus_owner := viewport.gui_get_focus_owner()
	if is_instance_valid(focus_owner) and focus_owner is Control:
		focus_owner.release_focus()

static func is_game_menu_open(_tree: SceneTree = null) -> bool:
	var input_lock := _get_local_input_lock()
	return input_lock != null and input_lock.has_method("has_reason") and input_lock.has_reason("game_menu")

static func is_gameplay_input_blocked(node: Node = null) -> bool:
	if node == null:
		return false

	var input_lock := _get_local_input_lock()
	return is_text_entry_focused(node.get_viewport()) or (input_lock != null and input_lock.has_method("is_locked") and input_lock.is_locked())

static func _get_local_input_lock() -> Node:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		return main_loop.root.get_node_or_null("LocalInputLock")
	return null
