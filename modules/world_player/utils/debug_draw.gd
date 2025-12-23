# Debug Draw Utility
# A reusable debug visualization tool for drawing lines, spheres, rays, and shapes
# Enable with `DebugDraw.enabled = true` and use static methods to draw
#
# Usage:
#   DebugDraw.enabled = true
#   DebugDraw.line(start, end, Color.RED)
#   DebugDraw.sphere(center, radius, Color.YELLOW)
#   DebugDraw.ray(origin, direction, length, Color.GREEN)

extends Node3D
class_name DebugDraw

static var instance: DebugDraw = null
static var enabled: bool = false

var mesh_instance: MeshInstance3D
var immediate_mesh: ImmediateMesh

func _ready() -> void:
	instance = self
	
	# Create the mesh for drawing
	immediate_mesh = ImmediateMesh.new()
	mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = immediate_mesh
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	# Unshaded material so debug draws are always visible
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true # Draw on top of everything
	mesh_instance.material_override = mat
	
	add_child(mesh_instance)

func _process(_delta: float) -> void:
	# Clear previous frame's debug draws
	immediate_mesh.clear_surfaces()

## Draw a line between two points
static func line(start: Vector3, end: Vector3, color: Color = Color.RED) -> void:
	if not enabled or not instance:
		return
	instance._draw_line(start, end, color)

## Draw a wireframe sphere
static func sphere(center: Vector3, radius: float, color: Color = Color.YELLOW, segments: int = 16) -> void:
	if not enabled or not instance:
		return
	instance._draw_sphere(center, radius, color, segments)

## Draw a ray from origin in direction
static func ray(origin: Vector3, direction: Vector3, length: float = 5.0, color: Color = Color.GREEN) -> void:
	if not enabled or not instance:
		return
	var end = origin + direction.normalized() * length
	instance._draw_line(origin, end, color)
	# Draw arrowhead
	var arrow_size = length * 0.1
	var perp = direction.cross(Vector3.UP).normalized() * arrow_size
	if perp.length() < 0.01:
		perp = direction.cross(Vector3.RIGHT).normalized() * arrow_size
	instance._draw_line(end, end - direction.normalized() * arrow_size + perp, color)
	instance._draw_line(end, end - direction.normalized() * arrow_size - perp, color)

## Draw a box wireframe
static func box(center: Vector3, size: Vector3, color: Color = Color.BLUE) -> void:
	if not enabled or not instance:
		return
	instance._draw_box(center, size, color)

## Draw a point (small cross)
static func point(pos: Vector3, size: float = 0.1, color: Color = Color.WHITE) -> void:
	if not enabled or not instance:
		return
	instance._draw_line(pos - Vector3(size, 0, 0), pos + Vector3(size, 0, 0), color)
	instance._draw_line(pos - Vector3(0, size, 0), pos + Vector3(0, size, 0), color)
	instance._draw_line(pos - Vector3(0, 0, size), pos + Vector3(0, 0, size), color)

## Clear all debug draws
static func clear() -> void:
	if instance:
		instance.immediate_mesh.clear_surfaces()

#region Internal Drawing Methods

func _draw_line(start: Vector3, end: Vector3, color: Color) -> void:
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	immediate_mesh.surface_set_color(color)
	immediate_mesh.surface_add_vertex(start)
	immediate_mesh.surface_add_vertex(end)
	immediate_mesh.surface_end()

func _draw_sphere(center: Vector3, radius: float, color: Color, segments: int) -> void:
	# Draw 3 circles (XY, XZ, YZ planes)
	_draw_circle(center, radius, color, segments, Vector3.FORWARD) # XY plane
	_draw_circle(center, radius, color, segments, Vector3.UP) # XZ plane
	_draw_circle(center, radius, color, segments, Vector3.RIGHT) # YZ plane

func _draw_circle(center: Vector3, radius: float, color: Color, segments: int, normal: Vector3) -> void:
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	immediate_mesh.surface_set_color(color)
	
	# Get perpendicular vectors
	var up = Vector3.UP if abs(normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var tangent1 = normal.cross(up).normalized()
	var tangent2 = normal.cross(tangent1).normalized()
	
	for i in range(segments + 1):
		var angle = (float(i) / segments) * TAU
		var vertex = center + (tangent1 * cos(angle) + tangent2 * sin(angle)) * radius
		immediate_mesh.surface_add_vertex(vertex)
	
	immediate_mesh.surface_end()

func _draw_box(center: Vector3, size: Vector3, color: Color) -> void:
	var half = size / 2.0
	var corners = [
		center + Vector3(-half.x, -half.y, -half.z),
		center + Vector3(half.x, -half.y, -half.z),
		center + Vector3(half.x, -half.y, half.z),
		center + Vector3(-half.x, -half.y, half.z),
		center + Vector3(-half.x, half.y, -half.z),
		center + Vector3(half.x, half.y, -half.z),
		center + Vector3(half.x, half.y, half.z),
		center + Vector3(-half.x, half.y, half.z),
	]
	
	# Bottom face
	_draw_line(corners[0], corners[1], color)
	_draw_line(corners[1], corners[2], color)
	_draw_line(corners[2], corners[3], color)
	_draw_line(corners[3], corners[0], color)
	# Top face
	_draw_line(corners[4], corners[5], color)
	_draw_line(corners[5], corners[6], color)
	_draw_line(corners[6], corners[7], color)
	_draw_line(corners[7], corners[4], color)
	# Verticals
	_draw_line(corners[0], corners[4], color)
	_draw_line(corners[1], corners[5], color)
	_draw_line(corners[2], corners[6], color)
	_draw_line(corners[3], corners[7], color)

#endregion
