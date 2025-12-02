@tool
extends RefCounted

# --- Configuration ---
# .GD Files (Standard)
const STR_GD_UI = 'Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")'
const STR_GD_WASD = 'Input.get_vector("move_left", "move_right", "move_forward", "move_backward")'

# .TSCN Files (Escaped Quotes)
const STR_TSCN_UI = 'Input.get_vector(\\"ui_left\\", \\"ui_right\\", \\"ui_up\\", \\"ui_down\\")'
const STR_TSCN_WASD = 'Input.get_vector(\\"move_left\\", \\"move_right\\", \\"move_forward\\", \\"move_backward\\")'

func _init() -> void:
	print("[Plugin] Applying WASD inputs...")
	_scan_and_replace(true)

func revert_changes() -> void:
	print("[Plugin] Reverting to UI inputs...")
	_scan_and_replace(false)

# --- Scanning Logic ---

func _scan_and_replace(use_wasd: bool):
	var dir = DirAccess.open("res://")
	if dir:
		_recursive_scan(dir, use_wasd)

func _recursive_scan(dir: DirAccess, use_wasd: bool):
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		# IGNORE metadata and the addons folder to prevent the script from eating itself
		if dir.current_is_dir():
			if file_name != "." and file_name != ".." and file_name != ".godot" and file_name != "addons":
				var sub_dir = DirAccess.open(dir.get_current_dir().path_join(file_name))
				if sub_dir:
					_recursive_scan(sub_dir, use_wasd)
		else:
			# Use path_join() to avoid "res:///file" errors
			var path = dir.get_current_dir().path_join(file_name)
			var ext = file_name.get_extension()
			
			if ext == "gd":
				_process_gd(path, use_wasd)
			elif ext == "tscn":
				_process_tscn(path, use_wasd)
		
		file_name = dir.get_next()

# --- File Processing ---

func _process_gd(path: String, use_wasd: bool):
	var f = FileAccess.open(path, FileAccess.READ)
	if not f: return
	var content = f.get_as_text()
	f.close()
	
	if not "extends CharacterBody3D" in content: return

	var regex = RegEx.new()
	var replace_with = ""
	
	if use_wasd:
		regex.compile('Input\\.get_vector\\s*\\(\\s*"ui_left"\\s*,\\s*"ui_right"\\s*,\\s*"ui_up"\\s*,\\s*"ui_down"\\s*\\)')
		replace_with = STR_GD_WASD
	else:
		regex.compile('Input\\.get_vector\\s*\\(\\s*"move_left"\\s*,\\s*"move_right"\\s*,\\s*"move_forward"\\s*,\\s*"move_backward"\\s*\\)')
		replace_with = STR_GD_UI
	
	if regex.search(content):
		var new_content = regex.sub(content, replace_with, true)
		_save_and_reload(path, new_content)

func _process_tscn(path: String, use_wasd: bool):
	var f = FileAccess.open(path, FileAccess.READ)
	if not f: return
	var content = f.get_as_text()
	f.close()
	
	# Only touch files containing the specific CharacterBody3D script
	if not "extends CharacterBody3D" in content: return
	
	var target = STR_TSCN_UI if use_wasd else STR_TSCN_WASD
	var replace = STR_TSCN_WASD if use_wasd else STR_TSCN_UI
	
	if content.contains(target):
		var new_content = content.replace(target, replace)
		_save_and_reload(path, new_content)

# --- Safe Reload Logic ---

func _save_and_reload(path: String, new_content: String):
	# 1. Write the file to disk
	var fw = FileAccess.open(path, FileAccess.WRITE)
	if fw:
		fw.store_string(new_content)
		fw.close()
		print("MODIFIED ON DISK: ", path)
		
		# 2. Schedule the reload for the next idle frame.
		# This uses a Callable, which is safe in Godot 4 and avoids "Invalid call".
		call_deferred("_perform_deferred_reload", path)

func _perform_deferred_reload(path: String):
	# Update Godot's internal database so it knows the file changed
	EditorInterface.get_resource_filesystem().update_file(path)
	
	# CASE 1: It is a Script file (.gd)
	# We force the Script Editor to update the text.
	if path.get_extension() == "gd":
		var res = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if res is Script:
			res.reload(true)
			print(" -> Script Editor refreshed.")

	# CASE 2: It is the CURRENTLY OPEN Scene (.tscn)
	# We force the editor to reload the tab. This acts like "Revert to Saved".
	var current_scene = EditorInterface.get_edited_scene_root()
	if current_scene and current_scene.scene_file_path == path:
		print(" -> Reloading active scene tab...")
		EditorInterface.reload_scene_from_path(path)
	else:
		# If it's a scene but NOT open, we do nothing. 
		# When you eventually open it, Godot will load the new file from disk.
		pass
