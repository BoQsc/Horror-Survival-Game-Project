extends Node
class_name PrefabCapture

## Prefab Capture Tool
## Allows capturing player-built structures as reusable prefabs
## Press P to enter selection mode, click two corners to define region

signal prefab_captured(prefab_name: String, path: String)

@export var building_manager: Node3D
@export var player: Node3D

enum State { IDLE, SELECTING_CORNER_A, SELECTING_CORNER_B, NAMING }
var state: State = State.IDLE

var corner_a: Vector3 = Vector3.ZERO
var corner_b: Vector3 = Vector3.ZERO

# Visual markers for corners
var marker_a: MeshInstance3D = null
var marker_b: MeshInstance3D = null
var selection_box: MeshInstance3D = null  # Transparent box showing selection region

const PREFAB_DIR = "user://world_prefabs/"

func _ready():
	# Create prefabs directory
	if not DirAccess.dir_exists_absolute(PREFAB_DIR):
		DirAccess.make_dir_recursive_absolute(PREFAB_DIR)
	
	# Find managers if not assigned
	if not building_manager:
		building_manager = get_tree().get_first_node_in_group("building_manager")
		if not building_manager:
			building_manager = get_node_or_null("/root/MainGame/BuildingManager")
	
	if not player:
		player = get_tree().get_first_node_in_group("player")
	
	# Create corner markers
	marker_a = _create_marker(Color.GREEN)
	marker_b = _create_marker(Color.RED)
	add_child(marker_a)
	add_child(marker_b)
	
	# Create selection box visual
	selection_box = _create_selection_box()
	add_child(selection_box)

func _process(_delta):
	# Update selection box when selecting corner B
	if state == State.SELECTING_CORNER_B:
		var hit = _raycast()
		if hit:
			var current_b = Vector3(floor(hit.position.x), floor(hit.position.y), floor(hit.position.z))
			_update_selection_box(corner_a, current_b)
			selection_box.visible = true
	else:
		selection_box.visible = false

func _create_marker(color: Color) -> MeshInstance3D:
	var mesh_inst = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(0.3, 0.3, 0.3)
	mesh_inst.mesh = box
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.0
	mesh_inst.material_override = mat
	mesh_inst.visible = false
	
	return mesh_inst

func _create_selection_box() -> MeshInstance3D:
	var mesh_inst = MeshInstance3D.new()
	mesh_inst.mesh = BoxMesh.new()
	
	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.2, 0.6, 1.0, 0.3)  # Light blue, 30% opacity
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # See box from inside
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_inst.material_override = mat
	mesh_inst.visible = false
	
	return mesh_inst

func _update_selection_box(c1: Vector3, c2: Vector3):
	# Calculate min/max corners
	var min_c = Vector3(min(c1.x, c2.x), min(c1.y, c2.y), min(c1.z, c2.z))
	var max_c = Vector3(max(c1.x, c2.x), max(c1.y, c2.y), max(c1.z, c2.z))
	
	# Size is difference + 1 (since blocks are 1 unit) + margin to prevent z-fighting
	const MARGIN = 0.05
	var size = (max_c - min_c) + Vector3.ONE + Vector3(MARGIN * 2, MARGIN * 2, MARGIN * 2)
	
	# Center is midpoint
	var center = min_c + (max_c - min_c + Vector3.ONE) / 2.0
	
	# Update mesh size
	var box_mesh = selection_box.mesh as BoxMesh
	box_mesh.size = size
	
	# Position at center
	selection_box.global_position = center


func _input(event):
	if event is InputEventKey and event.pressed and event.keycode == KEY_P:
		if state == State.IDLE:
			_enter_selection_mode()
		else:
			_cancel_selection()
	
	if state != State.IDLE and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_handle_click()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_cancel_selection()

func _enter_selection_mode():
	state = State.SELECTING_CORNER_A
	print("[PrefabCapture] Selection mode: Click to set CORNER A (Green)")

func _cancel_selection():
	state = State.IDLE
	marker_a.visible = false
	marker_b.visible = false
	selection_box.visible = false
	print("[PrefabCapture] Selection cancelled")

func _handle_click():
	var hit = _raycast()
	if not hit:
		print("[PrefabCapture] No valid target - click on terrain or building")
		return
	
	if state == State.SELECTING_CORNER_A:
		corner_a = Vector3(floor(hit.position.x), floor(hit.position.y), floor(hit.position.z))
		marker_a.global_position = corner_a + Vector3(0.5, 0.5, 0.5)
		marker_a.visible = true
		state = State.SELECTING_CORNER_B
		print("[PrefabCapture] Corner A set at %s. Click to set CORNER B (Red)" % corner_a)
	
	elif state == State.SELECTING_CORNER_B:
		corner_b = Vector3(floor(hit.position.x), floor(hit.position.y), floor(hit.position.z))
		marker_b.global_position = corner_b + Vector3(0.5, 0.5, 0.5)
		marker_b.visible = true
		print("[PrefabCapture] Corner B set at %s" % corner_b)
		
		# Capture the prefab
		_capture_region()

func _raycast() -> Dictionary:
	if not player:
		return {}
	
	var camera = player.get_node_or_null("Camera3D")
	if not camera:
		return {}
	
	var space = player.get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from + -camera.global_transform.basis.z * 50.0
	
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 0xFFFFFFFF  # Hit everything
	
	return space.intersect_ray(query)

## Convert a block type and meta to bracket notation token
func _block_to_token(block_type: int, meta: int) -> String:
	if meta == 0:
		return "[%d]" % block_type
	else:
		return "[%d:%d]" % [block_type, meta]

## Convert a 3D grid to layer strings in bracket notation
## Grid is [x][y][z] = {type, meta} or null for empty
func _grid_to_layers(grid: Array, size: Vector3i) -> Array:
	var layers: Array = []
	
	for y in range(size.y):
		# Add Y-level separator (except for first layer)
		if y > 0:
			layers.append("---")
		
		for z in range(size.z):
			var row_tokens: Array = []
			for x in range(size.x):
				var cell = grid[x][y][z]
				if cell == null:
					row_tokens.append(".")
				else:
					row_tokens.append(_block_to_token(cell.type, cell.meta))
			
			# Join tokens with space
			layers.append(" ".join(row_tokens))
	
	return layers

## Convert objects to compact array format [id, x, y, z, rot, frac_y]
func _objects_to_compact(objects: Array) -> Array:
	var compact: Array = []
	for obj in objects:
		compact.append([
			obj.object_id,
			obj.offset[0],
			obj.offset[1],
			obj.offset[2],
			obj.rotation,
			obj.get("fractional_y", 0.0)
		])
	return compact

func _capture_region():
	if not building_manager:
		print("[PrefabCapture] ERROR: No building manager!")
		_cancel_selection()
		return
	
	# Normalize corners (min/max)
	var min_corner = Vector3(
		min(corner_a.x, corner_b.x),
		min(corner_a.y, corner_b.y),
		min(corner_a.z, corner_b.z)
	)
	var max_corner = Vector3(
		max(corner_a.x, corner_b.x),
		max(corner_a.y, corner_b.y),
		max(corner_a.z, corner_b.z)
	)
	
	print("[PrefabCapture] Scanning region from %s to %s" % [min_corner, max_corner])
	
	# Calculate size
	var size = Vector3i(
		int(max_corner.x - min_corner.x) + 1,
		int(max_corner.y - min_corner.y) + 1,
		int(max_corner.z - min_corner.z) + 1
	)
	
	# Build 3D grid [x][y][z]
	var grid: Array = []
	var block_count = 0
	var origin = min_corner
	
	for x in range(size.x):
		var y_slice: Array = []
		for y in range(size.y):
			var z_slice: Array = []
			for z in range(size.z):
				var global_pos = origin + Vector3(x, y, z)
				var block_type = building_manager.get_voxel(global_pos)
				
				if block_type > 0:
					var meta = _get_voxel_meta(global_pos)
					z_slice.append({"type": block_type, "meta": meta})
					block_count += 1
				else:
					z_slice.append(null)
			y_slice.append(z_slice)
		grid.append(y_slice)
	
	# Scan for placed objects in the region
	var raw_objects = _scan_objects_in_region(min_corner, max_corner, origin)
	
	if block_count == 0 and raw_objects.size() == 0:
		print("[PrefabCapture] No blocks or objects found in selection!")
		_cancel_selection()
		return
	
	print("[PrefabCapture] Found %d blocks and %d objects" % [block_count, raw_objects.size()])
	
	# Convert to layer strings
	var layers = _grid_to_layers(grid, size)
	
	# Convert objects to compact format
	var compact_objects = _objects_to_compact(raw_objects)
	
	# Generate prefab name with timestamp
	var timestamp = Time.get_unix_time_from_system()
	var prefab_name = "prefab_%d" % timestamp
	
	# Save prefab in new bracket notation format (version 2)
	var prefab_data = {
		"name": prefab_name,
		"version": 2,
		"size": [size.x, size.y, size.z],
		"layers": layers,
		"objects": compact_objects
	}
	
	var path = PREFAB_DIR + prefab_name + ".json"
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(prefab_data, "\t"))
		file.close()
		print("[PrefabCapture] Saved prefab to: %s" % path)
		print("[PrefabCapture] Prefab contains %d blocks in bracket notation" % block_count)
		prefab_captured.emit(prefab_name, path)
	else:
		print("[PrefabCapture] ERROR: Failed to save prefab!")
	
	_cancel_selection()

func _get_voxel_meta(global_pos: Vector3) -> int:
	# Access chunk directly to get meta value
	if not "chunks" in building_manager:
		return 0
	
	var chunk_size = 16
	var chunk_x = int(floor(global_pos.x / chunk_size))
	var chunk_y = int(floor(global_pos.y / chunk_size))
	var chunk_z = int(floor(global_pos.z / chunk_size))
	var chunk_coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not building_manager.chunks.has(chunk_coord):
		return 0
	
	var chunk = building_manager.chunks[chunk_coord]
	
	var local_x = int(global_pos.x) % chunk_size
	var local_y = int(global_pos.y) % chunk_size
	var local_z = int(global_pos.z) % chunk_size
	if local_x < 0: local_x += chunk_size
	if local_y < 0: local_y += chunk_size
	if local_z < 0: local_z += chunk_size
	
	return chunk.get_voxel_meta(Vector3i(local_x, local_y, local_z))

func _scan_objects_in_region(min_corner: Vector3, max_corner: Vector3, origin: Vector3) -> Array:
	var result: Array = []
	
	if not "chunks" in building_manager:
		return result
	
	# Determine which chunks might contain objects in this region
	var chunk_size = 16
	var min_chunk = Vector3i(
		int(floor(min_corner.x / chunk_size)),
		int(floor(min_corner.y / chunk_size)),
		int(floor(min_corner.z / chunk_size))
	)
	var max_chunk = Vector3i(
		int(floor(max_corner.x / chunk_size)),
		int(floor(max_corner.y / chunk_size)),
		int(floor(max_corner.z / chunk_size))
	)
	
	for cx in range(min_chunk.x, max_chunk.x + 1):
		for cy in range(min_chunk.y, max_chunk.y + 1):
			for cz in range(min_chunk.z, max_chunk.z + 1):
				var chunk_coord = Vector3i(cx, cy, cz)
				if not building_manager.chunks.has(chunk_coord):
					continue
				
				var chunk = building_manager.chunks[chunk_coord]
				if not "objects" in chunk:
					continue
				
				# Check each object in this chunk
				for local_anchor in chunk.objects:
					# Convert local anchor to global position
					var global_anchor = Vector3(
						cx * chunk_size + local_anchor.x,
						cy * chunk_size + local_anchor.y,
						cz * chunk_size + local_anchor.z
					)
					
					# Check if within selection bounds
					if global_anchor.x >= min_corner.x and global_anchor.x <= max_corner.x and \
					   global_anchor.y >= min_corner.y and global_anchor.y <= max_corner.y and \
					   global_anchor.z >= min_corner.z and global_anchor.z <= max_corner.z:
						
						var obj_data = chunk.objects[local_anchor]
						var offset = global_anchor - origin
						
						# Get scene path from ObjectRegistry
						var scene_path = ""
						var obj_def = ObjectRegistry.get_object(obj_data.object_id)
						if obj_def and "scene" in obj_def:
							scene_path = obj_def.scene
						
						result.append({
							"offset": [offset.x, offset.y, offset.z],
							"object_id": obj_data.object_id,
							"rotation": obj_data.rotation,
							"scene": scene_path,
							"fractional_y": obj_data.get("fractional_y", 0.0)
						})
	
	return result

## Get list of available prefab files
func get_available_prefabs() -> Array[String]:
	var prefabs: Array[String] = []
	var dir = DirAccess.open(PREFAB_DIR)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(".json"):
				prefabs.append(file_name.replace(".json", ""))
			file_name = dir.get_next()
		dir.list_dir_end()
	return prefabs

## Load a prefab from file and return its data
func load_prefab(prefab_name: String) -> Dictionary:
	var path = PREFAB_DIR + prefab_name + ".json"
	if not FileAccess.file_exists(path):
		print("[PrefabCapture] Prefab not found: %s" % path)
		return {}
	
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return {}
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	if json.parse(json_string) != OK:
		print("[PrefabCapture] Failed to parse prefab: %s" % prefab_name)
		return {}
	
	return json.get_data()
