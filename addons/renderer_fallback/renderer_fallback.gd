extends Node
## Tests if Vulkan compute pipelines work at startup
## Immediately switches to D3D12 if they fail - BEFORE game loads

func _enter_tree():
	# Check if we're already using D3D12
	if _using_d3d12():
		print("[RendererFallback] Running with D3D12 ✓")
		return
	
	# Test if Vulkan compute works
	print("[RendererFallback] Testing Vulkan compute compatibility...")
	if not _test_vulkan_compute():
		print("[RendererFallback] ❌ Vulkan compute FAILED - switching to D3D12")
		# TEMPORARILY DISABLED - keep logs connected
		#_restart_with_d3d12()
		push_error("ERROR: Vulkan compute failed - D3D12 required")
		push_error("Plugin should have configured this automatically")
	else:
		print("[RendererFallback] ✓ Vulkan compute works")

func _using_d3d12() -> bool:
	"""Check if already running with D3D12"""
	for arg in OS.get_cmdline_user_args():
		if "d3d12" in arg.to_lower():
			return true
	return false

func _test_vulkan_compute() -> bool:
	"""Test if Vulkan supports compute pipelines using the ACTUAL marching_cubes shader"""
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("[RendererFallback] Failed to create RenderingDevice")
		return false
	
	# Use the ACTUAL marching_cubes shader that's causing problems
	# If this succeeds, the game will likely work. If it fails, we MUST use D3D12.
	var shader_file = RDShaderFile.new()
	shader_file.set_bytecode(preload("res://world_marching_cubes/marching_cubes.glsl").get_spirv())
	
	# Try to create shader and pipeline
	var shader = rd.shader_create_from_spirv(shader_file.get_spirv())
	if not shader.is_valid():
		print("[RendererFallback] ❌ Marching Cubes shader compilation FAILED")
		rd.free()
		return false
	
	var pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		print("[RendererFallback] ❌ Marching Cubes pipeline creation FAILED (Error -13)")
		if shader.is_valid():
			rd.free_rid(shader)
		rd.free()
		return false
	
	# Success - cleanup
	print("[RendererFallback] ✓ Marching Cubes pipeline created successfully")
	if pipeline.is_valid():
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)
	rd.free()
	
	return true

func _restart_with_d3d12():
	"""Restart game with D3D12 renderer"""
	print("[RendererFallback] Restarting with --rendering-driver d3d12...")
	
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
	
	await get_tree().create_timer(0.3).timeout
	get_tree().quit()
