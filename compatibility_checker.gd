extends Control
## Pre-loader that tests Vulkan compatibility BEFORE loading the game
## This prevents loading the heavy game scene when Vulkan is broken

@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var progress: ProgressBar = $VBoxContainer/ProgressBar

func _ready():
	# Check if we're already using D3D12
	if _using_d3d12():
		status_label.text = "Running with D3D12 ✓"
		_load_game()
		return
	
	# Test Vulkan
	status_label.text = "Testing graphics compatibility..."
	progress.value = 30
	
	# Defer the test to next frame so UI updates
	await get_tree().process_frame
	
	if _test_vulkan_compute():
		status_label.text = "Vulkan compute works ✓"
		progress.value = 100
		_load_game()  # Instant load
	else:
		status_label.text = "Vulkan not supported - restarting with D3D12..."
		progress.value = 100
		await get_tree().create_timer(0.1).timeout  # Just enough to show message
		_restart_with_d3d12()

func _using_d3d12() -> bool:
	"""Check if already running with D3D12"""
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
	shader_file.set_bytecode(preload("res://marching_cubes/marching_cubes.glsl").get_spirv())
	
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
	
	var exe = OS.get_executable_path()
	OS.create_process(exe, ["--rendering-driver", "d3d12"])
	
	get_tree().quit()

func _load_game():
	"""Load the actual game scene"""
	get_tree().change_scene_to_file("res://modules/world_module/world_test_world_player_v2.tscn")
