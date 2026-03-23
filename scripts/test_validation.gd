extends SceneTree

func _init():
	var prefab_name = "new_wooden_house_2floor_secret_facility"
	var PrefabGeometry = load("res://world_building_system/prefab_geometry.gd")
	var validation = PrefabGeometry.get_prefab_validation(prefab_name)
	var f = FileAccess.open("res://validation_output.txt", FileAccess.WRITE)
	f.store_string(JSON.stringify(validation, "  "))
	f.close()
	quit()
