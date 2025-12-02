# filename: add_script_templates.gd
@tool
extends RefCounted

# Update "YOUR_ADDON_NAME" if your folder name is different
const ADDON_TEMPLATES = "res://addons/3d-first-person-wasd-input-actions/script_templates/"
const PROJECT_TEMPLATES = "res://script_templates/"

func install_templates():
	# 1. Ensure project templates directory exists for CharacterBody3D
	if not DirAccess.dir_exists_absolute(PROJECT_TEMPLATES + "CharacterBody3D/"):
		var err = DirAccess.open("res://").make_dir_recursive_absolute(PROJECT_TEMPLATES + "CharacterBody3D/")
		if err != OK:
			printerr("[3d-first-person-wasd] Failed to create script_templates directory.")
			return
	
	# 2. Sync templates
	sync_templates()
	print("[3d-first-person-wasd] CharacterBody3D templates installed.")

func remove_templates():
	remove_synced_templates()
	print("[3d-first-person-wasd] CharacterBody3D templates removed.")

func sync_templates():
	var addon_dir = DirAccess.open(ADDON_TEMPLATES + "CharacterBody3D/")
	if addon_dir:
		addon_dir.list_dir_begin()
		var file_name = addon_dir.get_next()
		while file_name != "":
			if file_name.ends_with(".gd") or file_name.ends_with(".txt"):
				copy_template_file(file_name)
			file_name = addon_dir.get_next()
	else:
		printerr("[3d-first-person-wasd] Could not find addon template directory: " + ADDON_TEMPLATES + "CharacterBody3D/")

func copy_template_file(filename: String):
	var source_path = ADDON_TEMPLATES + "CharacterBody3D/" + filename
	var dest_path = PROJECT_TEMPLATES + "CharacterBody3D/" + filename
	
	var source = FileAccess.open(source_path, FileAccess.READ)
	if source:
		var content = source.get_as_text()
		source.close()
		
		var dest = FileAccess.open(dest_path, FileAccess.WRITE)
		if dest:
			dest.store_string(content)
			dest.close()
		else:
			printerr("[3d-first-person-wasd] Failed to write template: " + dest_path)

func remove_synced_templates():
	# Clean up the specific file
	if FileAccess.file_exists(PROJECT_TEMPLATES + "CharacterBody3D/wasd_movement.gd"):
		DirAccess.open("res://").remove_absolute(PROJECT_TEMPLATES + "CharacterBody3D/wasd_movement.gd")
