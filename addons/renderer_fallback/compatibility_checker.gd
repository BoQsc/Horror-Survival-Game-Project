extends Control
## Pre-loader that tests Vulkan compatibility BEFORE loading the game
## This prevents loading the heavy game scene when Vulkan is broken

@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var progress: ProgressBar = $VBoxContainer/ProgressBar

func _ready():
	# FIRST: Check if D3D12 is already configured - skip ALL checks if so
	if _using_d3d12():
		print("[CompatibilityChecker] D3D12 already configured - loading game directly")
		_load_game()
		return
	
	# If running from editor (detected by --path arg), skip the runtime check entirely
	# The EditorPlugin should have already configured D3D12 if needed
	var running_from_editor = false
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--path"):
			running_from_editor = true
			break
	
	if running_from_editor:
		print("[CompatibilityChecker] Running from editor - skipping runtime check")
		_load_game()
		return
	
	# Test Vulkan (exported builds only, when NOT using D3D12)
	status_label.text = "Testing graphics compatibility..."
	progress.value = 30
	
	# Defer the test to next frame so UI updates
	await get_tree().process_frame
	
	if _test_vulkan_compute():
		status_label.text = "Vulkan compute works ✓"
		progress.value = 100
		_load_game()
	else:
		status_label.text = "Vulkan not supported - restarting with D3D12..."
		progress.value = 100
		_restart_with_d3d12()

func _using_d3d12() -> bool:
	"""Check if already running with D3D12 (from project settings or command line)"""
	# Check Windows-specific project setting (this is what Godot reads on Windows)
	var driver_windows = ProjectSettings.get_setting("rendering/rendering_device/driver.windows", "")
	if driver_windows == "d3d12":
		return true
	
	# Check command line args (for exported builds with manual override)
	for arg in OS.get_cmdline_user_args():
		if "d3d12" in arg.to_lower():
			return true
	return false

func _test_vulkan_compute() -> bool:
	"""Test if Vulkan supports the marching cubes shader"""
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("[CompatibilityChecker] Failed to create RenderingDevice")
		return false
	
	# Use the actual marching_cubes shader
	var shader_file = RDShaderFile.new()
	shader_file.set_bytecode(preload("res://world_marching_cubes/marching_cubes.glsl").get_spirv())
	
	# Try to create shader and pipeline
	var shader = rd.shader_create_from_spirv(shader_file.get_spirv())
	if not shader.is_valid():
		print("[CompatibilityChecker] ❌ Marching Cubes shader compilation FAILED")
		rd.free()
		return false
	
	var pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		print("[CompatibilityChecker] ❌ Marching Cubes pipeline creation FAILED (Error -13)")
		if shader.is_valid():
			rd.free_rid(shader)
		rd.free()
		return false
	
	# Success - cleanup
	print("[CompatibilityChecker] ✓ Marching Cubes pipeline created successfully")
	if pipeline.is_valid():
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)
	rd.free()
	
	return true

func _restart_with_d3d12():
	"""Restart game with D3D12 renderer"""
	print("[CompatibilityChecker] Restarting with --rendering-driver d3d12...")
	
	# Check if running from Godot editor by looking for --path in command line args
	var running_from_editor = false
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--path"):
			running_from_editor = true
			break
	
	# If running from Godot editor, show error instead of restarting
	if running_from_editor:
		push_error("=".repeat(80))
		push_error("VULKAN COMPUTE NOT SUPPORTED - D3D12 REQUIRED")
		push_error("=".repeat(80))
		push_error("Running from Godot Editor detected!")
		push_error("")
		push_error("Please set D3D12 renderer in Project Settings:")
		push_error("1. Go to Project > Project Settings > General")
		push_error("2. Search for 'rendering/rendering_device/driver'")
		push_error("3. Set it to 'd3d12'")
		push_error("4. Close and restart Godot editor")
		push_error("5. Run the game again (F5)")
		push_error("=".repeat(80))
		
		# Don't auto-restart - let user see the error
		await get_tree().create_timer(5.0).timeout
		get_tree().quit()
		return
	
	# For exported builds, restart normally
	var exe = OS.get_executable_path()
	var args = ["--rendering-driver", "d3d12"]
	OS.create_process(exe, args)
	
	get_tree().quit()




func _load_game():
	"""Load the actual game scene"""
	# Defer to avoid "Parent node is busy" error when called from _ready()
	get_tree().change_scene_to_file.call_deferred("res://modules/world_module/world_test_world_player_v2.tscn")
