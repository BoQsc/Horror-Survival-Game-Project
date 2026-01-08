extends Node3D
class_name BuildingChunk

# Constants
const SIZE = 16

# Data
var chunk_coord: Vector3i
var voxel_bytes: PackedByteArray # Block IDs (0 = air, 1-127 = blocks, 128+ reserved for object markers)
var voxel_meta: PackedByteArray # Rotation/Meta
var is_empty: bool = true

# Object storage (separate from voxels for multi-cell objects)
var objects: Dictionary = {} # Vector3i (local anchor) -> { object_id: int, rotation: int }
var occupied_by_object: Dictionary = {} # Vector3i (any local cell) -> Vector3i (anchor pos)
var object_nodes: Dictionary = {} # Vector3i (local anchor) -> Node3D (visual instance)

# Visuals
var mesh_instance: MeshInstance3D
var static_body: StaticBody3D
var collision_shape: CollisionShape3D

# Mesher Reference (injected by Manager)
var mesher: Node # BuildingMesher

func _init(coord: Vector3i):
	chunk_coord = coord
	# Resize and init with 0 (Air)
	voxel_bytes.resize(SIZE * SIZE * SIZE)
	voxel_bytes.fill(0)
	voxel_meta.resize(SIZE * SIZE * SIZE)
	voxel_meta.fill(0)

## Reset chunk for pool reuse - clears data without reallocating arrays
func reset(new_coord: Vector3i):
	chunk_coord = new_coord
	voxel_bytes.fill(0) # Clear all voxels to air
	voxel_meta.fill(0) # Clear all metadata
	is_empty = true
	# Clear object data
	for anchor in object_nodes:
		var node = object_nodes[anchor]
		if node and is_instance_valid(node):
			node.queue_free()
	objects.clear()
	occupied_by_object.clear()
	object_nodes.clear()
	# Clear visuals
	if mesh_instance:
		mesh_instance.mesh = null
	if collision_shape:
		collision_shape.shape = null

func _ready():
	# Add to group for detection by player punch system
	add_to_group("building_chunks")
	
	# Setup Node Structure
	static_body = StaticBody3D.new()
	# Layer 1 = Default (Player/Physics)
	# Layer 10 (512) = Terrain Special (for PickupItem detection)
	static_body.collision_layer = 1 + 512 
	add_child(static_body)
	
	mesh_instance = MeshInstance3D.new()
	static_body.add_child(mesh_instance)
	
	collision_shape = CollisionShape3D.new()
	static_body.add_child(collision_shape)

func get_voxel(local_pos: Vector3i) -> int:
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return 0
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return 0
	
	var idx = _get_index(local_pos)
	return voxel_bytes.decode_u8(idx)

func get_voxel_meta(local_pos: Vector3i) -> int:
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return 0
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return 0
	
	var idx = _get_index(local_pos)
	return voxel_meta.decode_u8(idx)

func set_voxel(local_pos: Vector3i, value: int, meta: int = 0):
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return
	
	var idx = _get_index(local_pos)
	voxel_bytes.encode_u8(idx, value)
	voxel_meta.encode_u8(idx, meta)
	
	if value > 0:
		is_empty = false

func rebuild_mesh():
	if mesher:
		mesher.request_mesh_generation(self)

func apply_mesh(arrays: Array, shape: Shape3D = null):
	if not mesh_instance:
		push_warning("BuildingChunk.apply_mesh: mesh_instance is null (chunk not ready yet)")
		return
	
	if arrays.size() > 0:
		var mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		
		var material = StandardMaterial3D.new()
		material.albedo_color = Color(1.0, 1.0, 1.0) # White so texture shows
		material.albedo_texture = load("res://world_greedy_meshing/wood-block-texture.png")
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		
		mesh_instance.material_override = material
		mesh_instance.mesh = mesh
		
		# Generate Physics Shape (Main Thread, since we disabled threading it)
		if collision_shape.shape:
			collision_shape.shape = null
		collision_shape.shape = mesh.create_trimesh_shape()
	else:
		mesh_instance.mesh = null
		collision_shape.shape = null

func _get_index(pos: Vector3i) -> int:
	return pos.x + pos.y * SIZE + pos.z * SIZE * SIZE

## Check if a cell is available (no block, no object)
func is_cell_available(local_pos: Vector3i) -> bool:
	if local_pos.x < 0 or local_pos.y < 0 or local_pos.z < 0: return false
	if local_pos.x >= SIZE or local_pos.y >= SIZE or local_pos.z >= SIZE: return false
	
	# Check block
	if get_voxel(local_pos) > 0:
		return false
	
	# Check object occupation
	if occupied_by_object.has(local_pos):
		return false
	
	return true

## Place an object at the anchor position (assumes cells already validated)
## fractional_pos is the 3D offset from the anchor block's origin (0,0,0)
func place_object(local_anchor: Vector3i, object_id: int, rotation: int, cells: Array[Vector3i], scene_instance: Node3D, fractional_pos: Vector3 = Vector3.ZERO) -> bool:
	# Store object data (include fractional_pos for persistence)
	objects[local_anchor] = {"object_id": object_id, "rotation": rotation, "fractional_pos": fractional_pos}
	
	# Mark all occupied cells
	for cell in cells:
		occupied_by_object[cell] = local_anchor
	
	# Add visual instance with collision
	if scene_instance:
		add_child(scene_instance)
		
		# Position logic:
		# Center the object over its ORIGINAL footprint (unrotated size)
		# The visual rotation is applied to the model, so we use original size for offset
		# For rotations 1 and 3 (90°/270°), swap the offset components to match rotated footprint
		var original_size = ObjectRegistry.get_object(object_id).get("size", Vector3i(1, 1, 1))
		var offset_x = float(original_size.x) / 2.0
		var offset_z = float(original_size.z) / 2.0
		
		# For 90° and 270° rotations, swap offsets since footprint is rotated
		if rotation == 1 or rotation == 3:
			var temp = offset_x
			offset_x = offset_z
			offset_z = temp
		
		# Base position is anchor + centered offset
		var base_pos = Vector3(local_anchor.x + offset_x, local_anchor.y, local_anchor.z + offset_z)
		
		# Add fractional_pos (treated as extra offset, usually 0 for manual placement)
		scene_instance.position = base_pos + fractional_pos
		
		# Apply rotation (90 degree increments)
		scene_instance.rotation_degrees.y = rotation * 90
		
		# Add to group for identification during removal
		scene_instance.add_to_group("placed_objects")
		# Store anchor reference in metadata for removal lookup
		scene_instance.set_meta("anchor", local_anchor)
		scene_instance.set_meta("chunk", self)
		
		# Generate collision for the object (if it has meshes)
		_generate_object_collision(scene_instance, local_anchor)
		
		object_nodes[local_anchor] = scene_instance
	
	is_empty = false
	return true

## Generate collision for an object by finding its meshes
## anchor is passed in since child nodes may not have the meta set
## Skips objects in "interactable" group - they handle their own collision
func _generate_object_collision(obj: Node3D, anchor: Vector3i):
	# Skip collision generation for interactable objects (they manage their own)
	if obj.is_in_group("interactable"):
		DebugManager.log_building("BuildingChunk: Skipping collision for interactable object")
		return
	# Find all MeshInstance3D children and create collision shapes
	for child in obj.get_children():
		if child is MeshInstance3D:
			var mesh_inst = child as MeshInstance3D
			if mesh_inst.mesh:
				# Create StaticBody3D with trimesh collision
				var static_body = StaticBody3D.new()
				static_body.add_to_group("placed_objects")
				static_body.set_meta("anchor", anchor)
				static_body.set_meta("chunk", self)
				
				var collision = CollisionShape3D.new()
				collision.shape = mesh_inst.mesh.create_trimesh_shape()
				static_body.add_child(collision)
				
				# Match the mesh position
				static_body.position = mesh_inst.position
				static_body.rotation = mesh_inst.rotation
				static_body.scale = mesh_inst.scale
				
				mesh_inst.add_child(static_body)
		# Recurse into children
		if child is Node3D:
			_generate_object_collision(child, anchor)

## Remove an object and free its cells
func remove_object(local_anchor: Vector3i) -> bool:
	if not objects.has(local_anchor):
		return false
	
	var obj_data = objects[local_anchor]
	var object_id = obj_data.object_id
	var rotation = obj_data.rotation
	
	# Get all cells to free
	var cells = ObjectRegistry.get_occupied_cells(object_id, local_anchor, rotation)
	for cell in cells:
		occupied_by_object.erase(cell)
	
	# Remove visual
	if object_nodes.has(local_anchor):
		var node = object_nodes[local_anchor]
		if node and is_instance_valid(node):
			node.queue_free()
		object_nodes.erase(local_anchor)
	
	objects.erase(local_anchor)
	return true

## Get object at a cell (returns anchor position, or null if no object)
func get_object_at(local_pos: Vector3i):
	if occupied_by_object.has(local_pos):
		return occupied_by_object[local_pos]
	return null

## Restore visual instances for all stored objects (called after load)
## This spawns the scene instances for objects that were saved to the objects dictionary
func restore_object_visuals():
	for local_anchor in objects:
		# Skip if visual already exists
		if object_nodes.has(local_anchor) and is_instance_valid(object_nodes[local_anchor]):
			continue
		
		var obj_data = objects[local_anchor]
		var object_id = obj_data.object_id
		var rotation = obj_data.rotation
		var fractional_y = obj_data.get("fractional_y", 0.0)
		
		# Load and instantiate the scene
		var obj_def = ObjectRegistry.get_object(object_id)
		if obj_def.is_empty():
			print("BuildingChunk: restore_object_visuals - Unknown object_id: ", object_id)
			continue
		
		var scene_path = obj_def.get("scene", "")
		if scene_path == "":
			continue
		
		var packed = ObjectRegistry.get_preloaded_scene(scene_path)
		if not packed:
			print("BuildingChunk: restore_object_visuals - Failed to load scene: ", scene_path)
			continue
		
		var scene_instance = packed.instantiate()
		
		# Add and position the visual
		add_child(scene_instance)
		var original_size = ObjectRegistry.get_object(object_id).get("size", Vector3i(1, 1, 1))
		var offset_x = float(original_size.x) / 2.0
		var offset_z = float(original_size.z) / 2.0
		
		# For 90° and 270° rotations, swap offsets since footprint is rotated
		if rotation == 1 or rotation == 3:
			var temp = offset_x
			offset_x = offset_z
			offset_z = temp
		
		scene_instance.position = Vector3(local_anchor.x + offset_x, local_anchor.y + fractional_y, local_anchor.z + offset_z)
		scene_instance.rotation_degrees.y = rotation * 90
		
		# Add to group for identification
		scene_instance.add_to_group("placed_objects")
		scene_instance.set_meta("anchor", local_anchor)
		scene_instance.set_meta("chunk", self)
		
		# Generate collision
		_generate_object_collision(scene_instance, local_anchor)
		
		object_nodes[local_anchor] = scene_instance
	
	print("BuildingChunk: Restored %d object visuals" % object_nodes.size())
