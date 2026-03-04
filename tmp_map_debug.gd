@tool
extends SceneTree

func _init() -> void:
	print("--- MAP DEBUGGER ---")
	var WorldMapGen = load("res://world_editor/world_map_generator.gd")
	if not WorldMapGen:
		print("Could not load generator")
		quit()
		return
	
	var base_dir = "user://worlds/"
	var dir = DirAccess.open(base_dir)
	if not dir:
		print("No user://worlds/ dir")
		quit()
		return
		
	dir.list_dir_begin()
	var file_name = dir.get_next()
	var latest_world = ""
	while file_name != "":
		if dir.current_is_dir() and file_name != "." and file_name != "..":
			latest_world = file_name # Just grab one
		file_name = dir.get_next()
	dir.list_dir_end()
	
	if latest_world == "":
		print("No worlds found")
		quit()
		return
		
	var path = base_dir + latest_world
	print("Testing world: ", path)
	
	var meta_path = path + "/world_meta.json"
	
	if FileAccess.file_exists(meta_path):
		var f = FileAccess.open(meta_path, FileAccess.READ)
		var j = JSON.parse_string(f.get_as_text())
		if j and j.has("buildings"):
			print("JSON has buildings: ", j.buildings.size())
		else:
			print("JSON has NO buildings")
	
	var fp = path + "/building_map.png"
	if FileAccess.file_exists(fp):
		var img = Image.load_from_file(fp)
		print("building_map.png loaded. Format: ", img.get_format(), " Size: ", img.get_size())
		
		# Count white pixels
		var w_count = 0
		for y in img.get_height():
			for x in img.get_width():
				if img.get_pixel(x, y).r > 0.5:
					w_count += 1
		print("White pixels (before conversion): ", w_count)
		
		img.convert(Image.FORMAT_R8)
		print("After convert FORMAT_R8. Format: ", img.get_format())
		
		var buf = img.get_data()
		w_count = 0
		for i in buf.size():
			if buf[i] > 128:
				w_count += 1
		print("White pixels built (from buf): ", w_count)
	else:
		print("NO building_map.png FOUND")
	
	print("--------------------")
	quit()
