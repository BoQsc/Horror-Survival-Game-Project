extends Node
## Vulkan-only runtime guard.
## The project is Forward+ Vulkan only; unsupported drivers fail instead of falling back.

func _enter_tree():
	if _is_headless_run():
		return

	if _forbidden_renderer_requested():
		_fail_vulkan_only("Non-Vulkan renderer requested. This project is Forward+ Vulkan only.")
		return

	if not _using_forward_plus():
		_fail_vulkan_only("Forward+ renderer is required. This project must not run with another rendering method.")
		return

	if _test_vulkan_compute():
		return

	_fail_vulkan_only("Vulkan compute check failed. Exiting without changing renderer.")

func _is_headless_run() -> bool:
	if OS.has_feature("headless"):
		return true
	if DisplayServer.get_name().to_lower() == "headless":
		return true
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for arg in args:
		if str(arg).to_lower() == "--headless":
			return true
	return false

func _forbidden_renderer_requested() -> bool:
	var driver_windows := str(ProjectSettings.get_setting("rendering/rendering_device/driver.windows", "")).to_lower()
	if driver_windows != "" and driver_windows != "vulkan":
		return true

	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for arg in args:
		var lower_arg := str(arg).to_lower()
		if "d3d12" in lower_arg or "direct3d" in lower_arg or "mobile" in lower_arg:
			return true
	return false

func _using_forward_plus() -> bool:
	if not RenderingServer.has_method("get_current_rendering_method"):
		return true
	return str(RenderingServer.call("get_current_rendering_method")) == "forward_plus"

func _test_vulkan_compute() -> bool:
	"""Test if Vulkan supports compute pipelines using the marching_cubes shader."""
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		return false

	var shader_file = RDShaderFile.new()
	shader_file.set_bytecode(preload("res://world_marching_cubes/marching_cubes.glsl").get_spirv())

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

func _fail_vulkan_only(message: String) -> void:
	push_error("=".repeat(80))
	push_error("VULKAN ONLY RENDERING GUARD")
	push_error(message)
	push_error("No fallback renderer will be selected or launched.")
	push_error("=".repeat(80))
	get_tree().quit()
