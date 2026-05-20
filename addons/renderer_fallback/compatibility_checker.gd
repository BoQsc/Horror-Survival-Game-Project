extends Control
## Pre-loader that tests Vulkan compatibility before loading the game.
## The project is Forward+ Vulkan only; unsupported renderers fail instead of falling back.

@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var progress: ProgressBar = $VBoxContainer/ProgressBar

func _ready():
	if _forbidden_renderer_requested():
		_fail_vulkan_only("Non-Vulkan renderer requested.")
		return

	if not _using_forward_plus():
		_fail_vulkan_only("Forward+ renderer is required.")
		return

	# If running from editor (detected by --path arg), skip the exported-build preflight.
	var running_from_editor = false
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--path"):
			running_from_editor = true
			break

	if running_from_editor:
		_load_game()
		return

	status_label.text = "Testing Vulkan compatibility..."
	progress.value = 30

	# Defer the test to next frame so UI updates.
	await get_tree().process_frame

	if _test_vulkan_compute():
		status_label.text = "Vulkan compute OK"
		progress.value = 100
		_load_game()
	else:
		status_label.text = "Vulkan compute unavailable. Exiting."
		progress.value = 100
		await get_tree().create_timer(1.0).timeout
		get_tree().quit()

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
	"""Test if Vulkan supports the marching cubes shader."""
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("[VulkanGuard] Failed to create RenderingDevice")
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
	status_label.text = "Vulkan-only guard blocked startup."
	progress.value = 100
	push_error("=".repeat(80))
	push_error("VULKAN ONLY RENDERING GUARD")
	push_error(message)
	push_error("No fallback renderer will be selected or launched.")
	push_error("=".repeat(80))
	get_tree().quit()

func _load_game():
	"""Load the actual game scene."""
	get_tree().change_scene_to_file.call_deferred("res://modules/world_module/world_test_world_player_v2.tscn")
