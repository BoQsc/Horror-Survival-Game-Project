@tool
extends EditorPlugin

func _enter_tree():
	print("[RendererFallback Plugin] Checking Vulkan compute support...")
	
	# Test if Vulkan compute works
	if not _test_vulkan_compute():
		print("[RendererFallback Plugin] ❌ Vulkan compute failed - auto-configuring D3D12")
		_configure_d3d12_renderer()
	else:
		print("[RendererFallback Plugin] ✓ Vulkan compute works")
	
	# Add runtime fallback for exported builds
	add_autoload_singleton("RendererFallback", "res://addons/renderer_fallback/renderer_fallback.gd")
	print("[RendererFallback Plugin] Installed")

func _exit_tree():
	remove_autoload_singleton("RendererFallback")
	print("[RendererFallback Plugin] Uninstalled")

func _test_vulkan_compute() -> bool:
	"""Test if Vulkan supports compute pipelines using the marching_cubes shader"""
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("[RendererFallback Plugin] Failed to create RenderingDevice")
		return false
	
	# Use the actual marching_cubes shader
	var shader_file = RDShaderFile.new()
	shader_file.set_bytecode(preload("res://marching_cubes/marching_cubes.glsl").get_spirv())
	
	# Try to create shader and pipeline
	var shader = rd.shader_create_from_spirv(shader_file.get_spirv())
	if not shader.is_valid():
		print("[RendererFallback Plugin] ❌ Marching Cubes shader compilation FAILED")
		rd.free()
		return false
	
	var pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		print("[RendererFallback Plugin] ❌ Marching Cubes pipeline creation FAILED")
		if shader.is_valid():
			rd.free_rid(shader)
		rd.free()
		return false
	
	# Success - cleanup
	print("[RendererFallback Plugin] ✓ Marching Cubes pipeline created successfully")
	if pipeline.is_valid():
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)
	rd.free()
	
	return true

func _configure_d3d12_renderer():
	"""Automatically set D3D12 as the rendering driver in project settings"""
	var setting_path = "rendering/rendering_device/driver"
	
	# Set the project setting
	ProjectSettings.set_setting(setting_path, "d3d12")
	
	# Save the project settings
	var err = ProjectSettings.save()
	if err != OK:
		push_error("[RendererFallback Plugin] Failed to save project settings!")
		return
	
	print("[RendererFallback Plugin] ✓ Set rendering driver to D3D12")
	print("[RendererFallback Plugin] ⚠ Please restart Godot editor for changes to take effect")
	
	# Show a dialog to the user
	var dialog = AcceptDialog.new()
	dialog.dialog_text = """Vulkan compute is not supported on this system.

The project has been automatically configured to use DirectX 12.

Please RESTART the Godot editor for the changes to take effect."""
	dialog.title = "Renderer Configuration Changed"
	dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	
	# Add dialog to editor interface
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()
	
	# Cleanup when closed
	dialog.confirmed.connect(func(): dialog.queue_free())
