@tool
extends SceneTree

func _init() -> void:
var WorldMapGen = load("res://world_map_generator/world_map_generator.gd")
	if not WorldMapGen:
		quit()
		return
	
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
			latest_world = file_name # Just grab one
		file_name = dir.get_next()
	dir.list_dir_end()
	
	if latest_world == "":
		quit()
		return
		
	var path = base_dir + latest_world
	
	var meta_path = path + "/world_meta.json"
	
	if FileAccess.file_exists(meta_path):
		var f = FileAccess.open(meta_path, FileAccess.READ)
		var j = JSON.parse_string(f.get_as_text())
		if j is Dictionary and j.has("buildings"):
			print("Buildings in meta JSON: %d" % j["buildings"].size())
		else:
			print("No buildings key found in %s" % meta_path)
	
	var fp = path + "/building_map.png"
	if FileAccess.file_exists(fp):
		var img = Image.load_from_file(fp)
		
		# Count white pixels
		var w_count = 0
		for y in img.get_height():
			for x in img.get_width():
				if img.get_pixel(x, y).r > 0.5:
					w_count += 1
		
		img.convert(Image.FORMAT_R8)
		
		var buf = img.get_data()
		w_count = 0
		for i in buf.size():
			if buf[i] > 128:
				w_count += 1
		print("White pixels in building map: %d" % w_count)
	else:
		print("Missing building map image: %s" % fp)
	
	quit()
