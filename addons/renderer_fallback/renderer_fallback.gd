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
		_restart_with_d3d12()
	else:
		print("[RendererFallback] ✓ Vulkan compute works")

func _using_d3d12() -> bool:
	"""Check if already running with D3D12"""
	for arg in OS.get_cmdline_user_args():
		if "d3d12" in arg.to_lower():
			return true
	return false

func _test_vulkan_compute() -> bool:
	"""Test if Vulkan supports compute pipelines by creating a minimal test shader"""
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("[RendererFallback] Failed to create RenderingDevice")
		return false
	
	# Create a minimal compute shader to test
	var test_shader_code = """
#[compute]
#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) buffer Data { uint value; } data;
void main() { data.value = 1; }
"""
	
	var shader_file = RDShaderFile.new()
	shader_file.set_bytecode(preload("res://marching_cubes/gen_density.glsl").get_spirv())
	
	# Try to create shader and pipeline
	var shader = rd.shader_create_from_spirv(shader_file.get_spirv())
	if not shader.is_valid():
		rd.free()
		return false
	
	var pipeline = rd.compute_pipeline_create(shader)
	var success = pipeline.is_valid()
	
	# Cleanup
	if pipeline.is_valid():
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)
	rd.free()
	
	return success

func _restart_with_d3d12():
	"""Restart game with D3D12 renderer"""
	print("[RendererFallback] Restarting with --rendering-driver d3d12...")
	
	var exe = OS.get_executable_path()
	OS.create_process(exe, ["--rendering-driver", "d3d12"])
	
	# Wait a moment then quit
	await get_tree().create_timer(0.3).timeout
	get_tree().quit()

