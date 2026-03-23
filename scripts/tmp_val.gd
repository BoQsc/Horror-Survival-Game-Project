extends SceneTree
func _init():
    var PrefabGeometry = load('res://world_building_system/prefab_geometry.gd')
    var validation = PrefabGeometry.get_prefab_validation('large_church_with_basement')
    var f = FileAccess.open('res://validation_output.txt', FileAccess.WRITE)
    f.store_string(JSON.stringify(validation, '  '))
    f.close()
    quit()
