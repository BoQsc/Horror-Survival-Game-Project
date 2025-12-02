@tool
extends EditorPlugin

const ADDON_TEMPLATES = "res://addons/camera3d_templates/script_templates/"
const PROJECT_TEMPLATES = "res://script_templates/"

func _enter_tree():
	# Ensure project templates directory exists
	if not DirAccess.dir_exists_absolute(PROJECT_TEMPLATES + "Camera3D/"):
		DirAccess.open("res://").make_dir_recursive_absolute(PROJECT_TEMPLATES + "Camera3D/")
	
	# Sync templates from addon to project location
	sync_templates()
	print("Camera3D templates synced!")

func _exit_tree():
	# Remove synced templates when plugin disabled
	remove_synced_templates()
	print("Camera3D templates removed!")

func sync_templates():
	var addon_dir = DirAccess.open(ADDON_TEMPLATES + "Camera3D/")
	if addon_dir:
		addon_dir.list_dir_begin()
		var file_name = addon_dir.get_next()
		while file_name != "":
			if file_name.ends_with(".gd"):
				copy_template_file(file_name)
			file_name = addon_dir.get_next()

func copy_template_file(filename: String):
	var source = FileAccess.open(ADDON_TEMPLATES + "Camera3D/" + filename, FileAccess.READ)
	if source:
		var content = source.get_as_text()
		source.close()
		
		var dest = FileAccess.open(PROJECT_TEMPLATES + "Camera3D/" + filename, FileAccess.WRITE)
		if dest:
			dest.store_string(content)
			dest.close()

func remove_synced_templates():
	# Remove only the templates we added
	DirAccess.open("res://").remove_absolute(PROJECT_TEMPLATES + "Camera3D/first_person_character.gd")
	DirAccess.open("res://").remove_absolute(PROJECT_TEMPLATES + "Camera3D/first_person_free_floating.gd")
