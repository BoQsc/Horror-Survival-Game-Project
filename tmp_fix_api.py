import os

content = """extends Node

# STANDALONE DIAGNOSTIC FOR NVIDIA 4090 PIPELINE REJECTION (Error -13)
# This script tests several configurations to see which one the driver accepts.

func _ready():
	print("\\n[4090 DIAGNOSTIC] Starting Hardware Compatibility Tests...")
	
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		print("[4090 DIAGNOSTIC] FAILED: Could not create RenderingDevice.")
		return

	# Load the actual shader sources
	var shader_path = "res://world_marching_cubes/marching_cubes.glsl"
	var file = FileAccess.open(shader_path, FileAccess.READ)
	if not file:
		print("[4090 DIAGNOSTIC] FAILED: Could not find marching_cubes.glsl at %s" % shader_path)
		return
	var base_source = file.get_as_text()
	file.close()

	# Test Scenarios
	var s1 = func(src): return src
	var s2 = func(src): return src.replace("local_size_x = 8", "local_size_x = 4").replace("local_size_y = 8", "local_size_y = 4").replace("local_size_z = 8", "local_size_z = 4")
	var s3 = func(src):
		var s = src
		if not "float _pad" in s:
			s = s.replace("float terrain_height;", "float terrain_height;\\n	float _pad0, _pad1, _pad2, _pad3, _pad4, _pad5, _pad6, _pad7, _pad8, _pad9;")
		return s
	var s4 = func(src): 
		return src.replace("uint triangle_count;", "uvec4 data; // x = triangle_count")

	var scenarios = [
		{ "name": "Current File (Baseline)", "desc": "Testing the shader exactly as it is on disk", "patch_fn": s1 },
		{ "name": "Workgroup 4x4x4 (Reduced Pressure)", "desc": "Testing if reducing threads from 512 to 64 helps", "patch_fn": s2 },
		{ "name": "Padded Push Constants (64 bytes)", "desc": "Testing if 16-float PC block improves NVIDIA stability", "patch_fn": s3 },
		{ "name": "16-byte Counter Alignment", "desc": "Testing if uvec4 counter vs uint helps", "patch_fn": s4 }
	]

	for i in range(scenarios.size()):
		var s = scenarios[i]
		print("\\n--- Test %d: %s ---" % [i+1, s.name])
		print("Details: %s" % s.desc)
		
		var patched_source = s.patch_fn.call(base_source)
		var result = test_pipeline(rd, patched_source)
		
		if result == OK:
			print("RESULT: SUCCESS ✓")
		else:
			print("RESULT: FAILED ✗ (Error %d)" % result)

	print("\\n[4090 DIAGNOSTIC] All tests complete. Please provide the log above.")
	get_tree().quit()

func test_pipeline(rd: RenderingDevice, glsl_source: String) -> int:
	var shader_src = RDShaderSource.new()
	shader_src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_src.source_compute = glsl_source
	
	var spirv = rd.shader_compile_spirv_from_source(shader_src)
	if spirv.compile_error_compute != "":
		print("  Compilation Error: %s" % spirv.compile_error_compute)
		return ERR_CANT_CREATE
		
	var shader_rid = rd.shader_create_from_spirv(spirv)
	if not shader_rid.is_valid():
		print("  Shader RID is invalid.")
		return ERR_CANT_CREATE
		
	var pipeline_rid = rd.compute_pipeline_create(shader_rid)
	var status = OK if pipeline_rid.is_valid() else ERR_CANT_CREATE
	
	# Cleanup
	if pipeline_rid.is_valid(): rd.free_rid(pipeline_rid)
	rd.free_rid(shader_rid)
	
	return status
"""

target_path = r"c:\Users\Windows10_new\Documents\gpu-marching-cubes\world_marching_cubes\marching_cubes_diagnostics.gd"
with open(target_path, "w", encoding="utf-8") as f:
    f.write(content.replace("    ", "\t"))
