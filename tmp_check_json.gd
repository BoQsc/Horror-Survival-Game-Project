@tool
extends SceneTree

func _init() -> void:
	var base_dir = "user://worlds/"
	var dir = DirAccess.open(base_dir)
	if not dir:
		quit()
		return
		
	dir.list_dir_begin()
	var file_name = dir.get_next()
	var latest_world = ""
	while file_name != "":
		if dir.current_is_dir() and file_name != "." and file_name != "..":
			latest_world = file_name
		file_name = dir.get_next()
	dir.list_dir_end()
	
	if latest_world == "":
		quit()
		return
		
	var path = base_dir + latest_world + "/world_meta.json"
	
	if FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.READ)
		var text = f.get_as_text()
		var p = JSON.parse_string(text)
		if p is Dictionary and p.has("buildings"):
			var b = p["buildings"]
			print("Buildings in JSON: %d" % b.size())
			for i in range(min(10, b.size())):
				print(b[i])
		else:
			print("No buildings key found in %s" % path)
	else:
		print("Missing world meta file: %s" % path)
		
	quit()
