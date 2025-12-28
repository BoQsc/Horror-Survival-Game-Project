extends Node
## Modes Feature Signals - Game mode state changes

signal mode_changed(old_mode: String, new_mode: String)
signal editor_submode_changed(submode: int, submode_name: String)
