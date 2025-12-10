extends Node3D

## Road Manager - Controls road placement and terrain shader integration
## Toggle this feature on/off with roads_enabled

signal road_placed(world_position: Vector3)

@export var terrain_manager: Node3D  # ChunkManager reference
@export var roads_enabled: bool = true  # Toggle entire road system

## Road width in meters (wider for vehicle roads)
@export var road_width: float = 10.0
## Trail width in meters (narrower for walking paths)
@export var trail_width: float = 3.0

## Road mask texture size - higher = more detail but more memory
const MASK_SIZE = 2048  # Higher res for smoother roads
## World units per UV - 0.0005 means 2000m coverage centered on origin
const MASK_SCALE = 0.0005  # More coverage and detail

# Road path data - Dictionary of road segments
# Key: segment_id, Value: { points: Array[Vector3], width: float, is_trail: bool }
var road_segments: Dictionary = {}
var next_segment_id: int = 0

# Current road being built (for player placement)
var current_road_points: Array[Vector3] = []
var is_building_road: bool = false

# Road mask texture
var road_mask_image: Image
var road_mask_texture: ImageTexture

func _ready():
	if not terrain_manager:
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	# Create road mask texture
	_create_road_mask()
	
	# Defer shader setup to ensure terrain_manager is ready
	call_deferred("_init_road_shader")

func _create_road_mask():
	# Create empty image - R = road exists, G = encoded road height
	# Using RGBA8 to store height data in G channel
	road_mask_image = Image.create(MASK_SIZE, MASK_SIZE, false, Image.FORMAT_RGBA8)
	road_mask_image.fill(Color.BLACK)
	
	# Create texture from image
	road_mask_texture = ImageTexture.create_from_image(road_mask_image)

func _init_road_shader():
	if terrain_manager and "material_terrain" in terrain_manager:
		var mat = terrain_manager.material_terrain
		if mat:
			mat.set_shader_parameter("road_mask", road_mask_texture)
			mat.set_shader_parameter("road_mask_scale", MASK_SCALE)
			mat.set_shader_parameter("road_mask_offset", Vector2.ZERO)

## Paint road onto mask texture
func _paint_road_on_mask(start: Vector3, end: Vector3, width: float):
	# Shader UV formula: road_uv = world_pos.xz * MASK_SCALE + 0.5
	# So pixel = UV * MASK_SIZE = (world_pos * MASK_SCALE + 0.5) * MASK_SIZE
	#          = world_pos * MASK_SCALE * MASK_SIZE + MASK_SIZE/2
	
	var center = MASK_SIZE / 2.0
	var scale_factor = MASK_SCALE * MASK_SIZE  # pixels per meter
	
	print("Road mask paint: scale_factor=%f, center=%d" % [scale_factor, int(center)])
	print("  Start world: (%f, %f) -> pixel: (%d, %d)" % [start.x, start.z, int(start.x * scale_factor + center), int(start.z * scale_factor + center)])
	print("  End world: (%f, %f) -> pixel: (%d, %d)" % [end.x, end.z, int(end.x * scale_factor + center), int(end.z * scale_factor + center)])
	
	# Paint line from start to end - dense steps for full coverage
	var length = start.distance_to(end)
	var steps = int(length * 2) + 1  # Every 0.5 meters for dense coverage
	
	# Width in pixels - scale_factor converts meters to pixels
	var pixel_radius = int((width / 2.0) * scale_factor)
	if pixel_radius < 2: pixel_radius = 2
	print("  Road width=%fm, pixel_radius=%d" % [width, pixel_radius])
	
	for i in range(steps + 1):
		var t = float(i) / float(steps) if steps > 0 else 0.0
		var pos = start.lerp(end, t)
		
		var px = int(pos.x * scale_factor + center)
		var pz = int(pos.z * scale_factor + center)
		
		# Encode road height: world Y [-50, 150] -> [0, 1]
		var encoded_height = clamp((pos.y + 50.0) / 200.0, 0.0, 1.0)
		var road_color = Color(1.0, encoded_height, 0.0, 1.0)  # R=road, G=height
		
		# Paint circle at this point
		for dx in range(-pixel_radius, pixel_radius + 1):
			for dz in range(-pixel_radius, pixel_radius + 1):
				if dx * dx + dz * dz <= pixel_radius * pixel_radius:
					var x = px + dx
					var z = pz + dz
					if x >= 0 and x < MASK_SIZE and z >= 0 and z < MASK_SIZE:
						road_mask_image.set_pixel(x, z, road_color)
	
	# Update texture
	road_mask_texture.update(road_mask_image)
	
	# Save mask for debugging
	road_mask_image.save_png("user://road_mask_debug.png")
	print("  Saved mask to user://road_mask_debug.png")

## Start building a new road/trail
func start_road(is_trail: bool = false):
	if not roads_enabled:
		return
	current_road_points.clear()
	is_building_road = true

## Add a point to the current road being built
func add_road_point(world_pos: Vector3):
	if not is_building_road:
		return
	current_road_points.append(world_pos)

## Finish the current road and save it
func finish_road(is_trail: bool = false) -> int:
	if current_road_points.size() < 2:
		current_road_points.clear()
		is_building_road = false
		return -1
	
	var segment_id = next_segment_id
	next_segment_id += 1
	
	var width = trail_width if is_trail else road_width
	
	road_segments[segment_id] = {
		"points": current_road_points.duplicate(),
		"width": width,
		"is_trail": is_trail
	}
	
	# Paint road on mask texture
	for i in range(current_road_points.size() - 1):
		_paint_road_on_mask(current_road_points[i], current_road_points[i + 1], width)
	
	current_road_points.clear()
	is_building_road = false
	
	for point in road_segments[segment_id].points:
		road_placed.emit(point)
	
	return segment_id

## Quick place a single road segment between two points
func place_road_segment(start: Vector3, end: Vector3, is_trail: bool = false) -> int:
	start_road(is_trail)
	add_road_point(start)
	add_road_point(end)
	return finish_road(is_trail)

## Check if a world position is on a road
func is_on_road(world_pos: Vector3) -> bool:
	for segment in road_segments.values():
		var points = segment.points
		var width = segment.width
		
		for i in range(points.size() - 1):
			var p1 = points[i]
			var p2 = points[i + 1]
			
			var dist = _point_to_segment_distance(world_pos, p1, p2)
			if dist < width / 2.0:
				return true
	
	return false

func _point_to_segment_distance(point: Vector3, seg_start: Vector3, seg_end: Vector3) -> float:
	var p = Vector2(point.x, point.z)
	var a = Vector2(seg_start.x, seg_start.z)
	var b = Vector2(seg_end.x, seg_end.z)
	
	var ab = b - a
	var ap = p - a
	
	if ab.length_squared() < 0.001:
		return p.distance_to(a)
	
	var t = clamp(ap.dot(ab) / ab.dot(ab), 0.0, 1.0)
	var closest = a + ab * t
	
	return p.distance_to(closest)

## Clear all roads
func clear_all_roads():
	road_segments.clear()
	next_segment_id = 0
	road_mask_image.fill(Color.BLACK)
	road_mask_texture.update(road_mask_image)
