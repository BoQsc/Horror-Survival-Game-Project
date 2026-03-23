extends SceneTree

func _init():
	var WorldMapGen = load("res://world_editor/world_map_generator.gd").new()
	var prefabs = WorldMapGen._get_available_prefabs()
	var output = "PREFABS_IN_FOLDER:\n"
	for p in prefabs:
		output += "  - " + p + "\n"
	
	var catalog = WorldMapGen._build_prefab_catalog(prefabs)
	output += "CATALOG_ENTRIES:\n"
	for pname in catalog:
		output += "  - " + pname + " Size: " + str(catalog[pname].footprint) + "\n"
		
	if not catalog.has("large_church_with_basement"):
		var validation = load("res://world_building_system/prefab_geometry.gd").get_prefab_validation("large_church_with_basement")
		output += "CHURCH_VALIDATION_FAILURE:\n"
		output += JSON.stringify(validation, "  ") + "\n"
	else:
		output += "CHURCH_IN_CATALOG_SUCCESS\n"
		
	var f = FileAccess.open("res://debug_map_gen_output.txt", FileAccess.WRITE)
	f.store_string(output)
	f.close()
	quit()
