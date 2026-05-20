@tool
extends EditorPlugin

func _enter_tree():
	if _forbidden_renderer_configured():
		push_error("[VulkanGuard Plugin] Project renderer must stay Forward+ Vulkan.")
		_show_vulkan_only_dialog("Project renderer is not Vulkan. Set rendering/rendering_device/driver.windows to vulkan.")
		return

	if _test_vulkan_compute():
		return

	push_error("[VulkanGuard Plugin] Vulkan compute unavailable. No fallback renderer will be configured.")
	_show_vulkan_only_dialog("Vulkan compute is unavailable. This project cannot run on this machine without Vulkan compute.")

func _exit_tree():
	pass

func _forbidden_renderer_configured() -> bool:
	var driver_windows := str(ProjectSettings.get_setting("rendering/rendering_device/driver.windows", "")).to_lower()
	return driver_windows != "" and driver_windows != "vulkan"

func _test_vulkan_compute() -> bool:
	"""Test if Vulkan compute works with the marching cubes shader."""
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("[VulkanGuard Plugin] Failed to create RenderingDevice")
		return false

	var shader_path = "res://world_marching_cubes/marching_cubes.glsl"
	if not FileAccess.file_exists(shader_path):
		push_error("[VulkanGuard Plugin] Shader not found: %s" % shader_path)
		rd.free()
		return false

	var shader_file = RDShaderFile.new()
	var shader_resource = load(shader_path)
	shader_file.set_bytecode(shader_resource.get_spirv())

	var shader = rd.shader_create_from_spirv(shader_file.get_spirv())
	if not shader.is_valid():
		rd.free()
		return false

	var pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		if shader.is_valid():
			rd.free_rid(shader)
		rd.free()
		return false

	if pipeline.is_valid():
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)
	rd.free()
	return true

func _show_vulkan_only_dialog(message: String):
	"""Show a Vulkan-only error dialog without changing project settings."""
	var dialog = AcceptDialog.new()
	dialog.title = "Vulkan Required"
	dialog.dialog_text = """%s

No fallback renderer was configured.""" % message
	dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_PRIMARY_SCREEN

	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(func(): dialog.queue_free())
