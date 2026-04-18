@tool
extends EditorPlugin

func _enter_tree():
	
	# Check current renderer setting (Windows-specific)
	var driver_windows = ProjectSettings.get_setting("rendering/rendering_device/driver.windows", "")
	
	# If already set to D3D12, we're done
	if driver_windows == "d3d12":
		return
	
	# Test Vulkan compute
	if _test_vulkan_compute():
		return
	else:
		_set_d3d12()

func _exit_tree():
	pass

func _test_vulkan_compute() -> bool:
	"""Test if Vulkan compute works with marching cubes shader"""
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("[RendererFallback Plugin] Failed to create RenderingDevice")
		return false
	
	# Load shader
	var shader_path = "res://world_marching_cubes/marching_cubes.glsl"
	if not FileAccess.file_exists(shader_path):
		push_error("[RendererFallback Plugin] Shader not found: %s" % shader_path)
		rd.free()
		return false
	
	var shader_file = RDShaderFile.new()
	var shader_resource = load(shader_path)
	shader_file.set_bytecode(shader_resource.get_spirv())
	
	# Try to compile
	var shader = rd.shader_create_from_spirv(shader_file.get_spirv())
	if not shader.is_valid():
		rd.free()
		return false
	
	# Try to create pipeline
	var pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		if shader.is_valid():
			rd.free_rid(shader)
		rd.free()
		return false
	
	# Success - cleanup
	if pipeline.is_valid():
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)
	rd.free()
	return true

func _set_d3d12():
	"""Set D3D12 renderer by directly modifying project.godot file"""
	var project_path = "res://project.godot"
	var setting_line = 'rendering_device/driver.windows="d3d12"'
	
	# Read the current file
	var file = FileAccess.open(project_path, FileAccess.READ)
	if not file:
		push_error("[RendererFallback Plugin] Cannot open project.godot for reading")
		return
	
	var content = file.get_as_text()
	file.close()
	
	# Check if setting already exists
	if setting_line in content:
		return
	
	# Find [rendering] section and add setting after it
	var lines = content.split("\n")
	var new_lines: Array[String] = []
	var found_rendering = false
	var added = false
	
	for line in lines:
		new_lines.append(line)
		if line.strip_edges() == "[rendering]" and not added:
			found_rendering = true
		elif found_rendering and not added and (line.begins_with("[") or line.begins_with("rendering_device/")):
			# Add our setting right after [rendering] section header or before first rendering_device setting
			if line.begins_with("rendering_device/"):
				# Insert before this line
				new_lines.pop_back()
				new_lines.append(setting_line)
				new_lines.append(line)
				added = true
			elif line.begins_with("["):
				# New section started, insert before it
				new_lines.pop_back()
				new_lines.append(setting_line)
				new_lines.append("")
				new_lines.append(line)
				added = true
	
	# If [rendering] section exists but we didn't add yet, add at end
	if found_rendering and not added:
		new_lines.append(setting_line)
		added = true
	
	# If no [rendering] section, add one at the end
	if not found_rendering:
		new_lines.append("")
		new_lines.append("[rendering]")
		new_lines.append("")
		new_lines.append(setting_line)
		added = true
	
	# Write the modified content
	file = FileAccess.open(project_path, FileAccess.WRITE)
	if not file:
		push_error("[RendererFallback Plugin] Cannot open project.godot for writing")
		return
	
	file.store_string("\n".join(new_lines))
	file.close()
	
	
	# Show dialog
	call_deferred("_show_restart_dialog")

func _show_restart_dialog():
	"""Show dialog asking user to restart editor"""
	var dialog = AcceptDialog.new()
	dialog.title = "Renderer Changed to DirectX 12"
	dialog.dialog_text = """Vulkan compute is not supported on this system.

DirectX 12 has been automatically configured.

Please CLOSE and RESTART Godot editor now."""
	dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_PRIMARY_SCREEN
	
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(func(): dialog.queue_free())
