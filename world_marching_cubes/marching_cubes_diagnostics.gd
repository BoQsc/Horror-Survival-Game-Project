extends Node

# BULLETPROOF 4090 DIAGNOSTIC (Ver 4.0)
# Uses RegEx to ensure replacements work regardless of line endings or quotes.

func _ready():
	print("\n[4090 DIAGNOSTIC] Initialized. Waiting 1s before starting tests...")
	get_tree().create_timer(1.0).timeout.connect(run_diagnostics)

func run_diagnostics():
	print("[4090 DIAGNOSTIC] Starting Hardware Compatibility Tests...")
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		print("[4090 DIAGNOSTIC] FAILED: Could not create RenderingDevice.")
		return

	var base_source = load_source("res://world_marching_cubes/marching_cubes.glsl")
	var inc_content = load_source("res://world_marching_cubes/marching_cubes_lookup_table.glslinc")
	
	if base_source == "" or inc_content == "":
		print("[4090 DIAGNOSTIC] FAILED: Could not load shader files.")
		return

	# Regexes for patching
	var re_inc = RegEx.create_from_string("#include\\s+[\"'].*[\"']")
	var re_wg = RegEx.create_from_string("local_size_(x|y|z)\\s*=\\s*8")
	var re_counter_decl = RegEx.create_from_string("uint\\s+triangle_count\\s*;")
	var re_counter_use = RegEx.create_from_string("\\.triangle_count")
	var re_pc_member = RegEx.create_from_string("float\\s+terrain_height\\s*;")
	var re_stride = RegEx.create_from_string("idx\\s*\\*\\s*27")

	# Patch functions
	var patch_inline = func(s): 
		return re_inc.sub(s, inc_content, true)
	
	var patch_ssbo = func(s):
		var sub = "layout(set = 0, binding = 4, std430) readonly buffer LookupTable { int edgeTable[256]; int triTable[4096]; };"
		return re_inc.sub(s, sub, true)

	var patch_wg4 = func(s):
		var tmp = re_wg.sub(s, "local_size_$1 = 4", true)
		return tmp

	var patch_counter16 = func(s):
		var s1 = re_counter_decl.sub(s, "uvec4 data; // x = triangle_count", true)
		return re_counter_use.sub(s1, ".data.x", true)

	var patch_pc64 = func(s):
		return re_pc_member.sub(s, "float terrain_height;\n    float _pad[10];", true)

	var patch_stride12 = func(s):
		return re_stride.sub(s, "idx * 36", true)

	var scenarios = [
		{ "name": "Test 1: Baseline (Laptop/1060 Style)", "fn": func(s): return patch_inline.call(s) },
		{ "name": "Test 2: 4x4x4 WG Only", "fn": func(s): return patch_wg4.call(patch_inline.call(s)) },
		{ "name": "Test 3: Counter-16 Only", "fn": func(s): return patch_counter16.call(patch_inline.call(s)) },
		{ "name": "Test 4: SSBO Lookup (No embedded tables)", "fn": func(s): return patch_ssbo.call(s) },
		{ "name": "Test 5: Hardened (WG4 + SSBO + C16)", "fn": func(s): return patch_wg4.call(patch_counter16.call(patch_ssbo.call(s))) },
		{ "name": "Test 6: Full Madness (WG4 + SSBO + C16 + PC64 + Stride12)", "fn": func(s): return patch_stride12.call(patch_pc64.call(patch_wg4.call(patch_counter16.call(patch_ssbo.call(s))))) }
	]

	for i in range(scenarios.size()):
		var s = scenarios[i]
		print("\n--- %s ---" % s.name)
		await get_tree().process_frame
		
		var processed = s.fn.call(base_source)
		
		# Sanity check include removal
		if "#include" in processed:
			print("  CRITICAL: #include directive was NOT removed by regex!")
			print("  RESULT: FAILED ✗ (Internal Script Error)")
			continue

		var result = test_pipeline(rd, processed)
		if result == OK:
			print("RESULT: SUCCESS ✓")
		else:
			print("RESULT: FAILED ✗ (Error %d)" % result)

	print("\n[4090 DIAGNOSTIC] All tests complete. Please provide the log above.")
	get_tree().quit()

func load_source(path: String) -> String:
	var f = FileAccess.open(path, FileAccess.READ)
	if not f: return ""
	var s = f.get_as_text()
	if s.find("#[compute]") != -1:
		s = s.replace("#[compute]", "")
	f.close()
	return s.strip_edges()

func test_pipeline(rd: RenderingDevice, glsl_source: String) -> int:
	var shader_src = RDShaderSource.new()
	shader_src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_src.source_compute = glsl_source
	
	print("  Compiling SPIR-V...")
	var spirv = rd.shader_compile_spirv_from_source(shader_src)
	if spirv.compile_error_compute != "":
		print("  Compilation Error: %s" % spirv.compile_error_compute)
		return ERR_CANT_CREATE
		
	var shader_rid = rd.shader_create_from_spirv(spirv)
	if not shader_rid.is_valid():
		return ERR_CANT_CREATE
		
	var pipeline_rid = rd.compute_pipeline_create(shader_rid)
	var status = OK if pipeline_rid.is_valid() else ERR_CANT_CREATE
	
	if pipeline_rid.is_valid(): rd.free_rid(pipeline_rid)
	rd.free_rid(shader_rid)
	
	return status
