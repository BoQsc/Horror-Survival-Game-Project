extends Node
## Collision Debugger - Shows collision info when holding a key
## Toggle with F10, shows info when holding Left Alt

var enabled: bool = false
var label: Label = null
var last_collider_info: String = ""

func _ready():
	# Create on-screen label
	label = Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.position = Vector2(20, 100)
	label.add_theme_color_override("font_color", Color.YELLOW)
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.visible = false
	
	# Add to CanvasLayer so it's always on top
	var canvas = CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)
	canvas.add_child(label)
	
	print("[CollisionDebugger] Ready - Press F10 to toggle, hold Left Alt to inspect")


func _unhandled_input(event):
	# F10 toggles the debugger
	if event is InputEventKey and event.pressed and event.keycode == KEY_F10:
		enabled = !enabled
		print("[CollisionDebugger] %s" % ("ENABLED" if enabled else "DISABLED"))
		if not enabled:
			label.visible = false


func _process(_delta):
	if not enabled:
		return
	
	# Only show info when holding Left Alt
	if Input.is_key_pressed(KEY_ALT):
		_update_collision_info()
		label.visible = true
	else:
		label.visible = false


func _update_collision_info():
	var camera = get_viewport().get_camera_3d()
	if not camera:
		label.text = "No camera found"
		return
	
	# Cast ray from camera center
	var viewport = get_viewport()
	var screen_center = viewport.get_visible_rect().size / 2
	var from = camera.project_ray_origin(screen_center)
	var to = from + camera.project_ray_normal(screen_center) * 50.0
	
	var space_state = camera.get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	
	var result = space_state.intersect_ray(query)
	
	if result.is_empty():
		label.text = "=== COLLISION DEBUGGER (F10) ===\nNo collision hit\nAim at something..."
		return
	
	var collider = result.collider
	var info_lines = []
	info_lines.append("=== COLLISION DEBUGGER (F10) ===")
	info_lines.append("")
	info_lines.append("COLLIDER: %s" % collider.name)
	info_lines.append("TYPE: %s" % collider.get_class())
	info_lines.append("PATH: %s" % collider.get_path())
	info_lines.append("")
	
	# Show parent hierarchy
	info_lines.append("HIERARCHY:")
	var node = collider
	var depth = 0
	while node and depth < 10:
		var indent = "  ".repeat(depth)
		var type_hint = ""
		if node is StaticBody3D:
			type_hint = " [StaticBody3D]"
		elif node is CollisionShape3D:
			type_hint = " [CollisionShape3D]"
		elif node is AnimationPlayer:
			type_hint = " [AnimationPlayer]"
		elif node is Skeleton3D:
			type_hint = " [Skeleton3D]"
		info_lines.append("%s└ %s%s" % [indent, node.name, type_hint])
		node = node.get_parent()
		depth += 1
	
	info_lines.append("")
	
	# Show collision layers
	if collider is CollisionObject3D:
		info_lines.append("COLLISION LAYER: %d (bits: %s)" % [collider.collision_layer, _format_bits(collider.collision_layer)])
		info_lines.append("COLLISION MASK: %d (bits: %s)" % [collider.collision_mask, _format_bits(collider.collision_mask)])
	
	# Show groups
	var groups = collider.get_groups()
	if groups.size() > 0:
		info_lines.append("GROUPS: %s" % ", ".join(groups))
	
	# Show metadata
	var meta_keys = collider.get_meta_list()
	if meta_keys.size() > 0:
		info_lines.append("META: %s" % ", ".join(meta_keys))
	
	# Show children (collision shapes)
	info_lines.append("")
	info_lines.append("CHILDREN:")
	for child in collider.get_children():
		var shape_info = ""
		if child is CollisionShape3D and child.shape:
			shape_info = " -> %s" % child.shape.get_class()
		info_lines.append("  - %s (%s)%s" % [child.name, child.get_class(), shape_info])
	
	label.text = "\n".join(info_lines)


func _format_bits(value: int) -> String:
	var bits = []
	for i in range(10):
		if value & (1 << i):
			bits.append(str(i + 1))
	return ", ".join(bits) if bits.size() > 0 else "none"
