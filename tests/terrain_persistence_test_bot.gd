extends Node
## Terrain Persistence Test Bot - Tests if terrain modifications persist through QuickSave/QuickLoad

var test_timer = 0.0
var player: CharacterBody3D = null
var camera: Camera3D = null
var test_phase = "INIT"

# Track terrain state
var terrain_manager: Node = null
var mining_target_pos: Vector3i = Vector3i.ZERO
var terrain_modified: bool = false
var blocks_mined_before_save: int = 0
var blocks_checked_after_load: int = 0

func _ready():
	print("[TERRAIN_PERSIST_TEST] Starting terrain persistence test...")
	await get_tree().create_timer(3.0).timeout
	
	# Find player and camera
	player = get_tree().get_first_node_in_group("player")
	if player:
		camera = player.get_node_or_null("Camera3D")
	
	# Find terrain manager
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	if not player or not camera or not terrain_manager:
		print("[TERRAIN_PERSIST_TEST] ERROR: Missing components!")
		print("[TERRAIN_PERSIST_TEST]   Player: %s" % (player != null))
		print("[TERRAIN_PERSIST_TEST]   Camera: %s" % (camera != null))
		print("[TERRAIN_PERSIST_TEST]   TerrainManager: %s" % (terrain_manager != null))
		get_tree().quit(1)
		return
	
	print("[TERRAIN_PERSIST_TEST] All components found!")
	print("[TERRAIN_PERSIST_TEST] Player at: %s" % player.global_position)
	test_phase = "POSITION"

func _process(delta):
	if test_phase == "INIT":
		return
	
	test_timer += delta
	
	match test_phase:
		"POSITION":
			if test_timer < 0.1:
				print("[TERRAIN_PERSIST_TEST] Phase 1: Positioning and looking down...")
			# Look down to see ground
			_rotate_camera_pitch(-delta * 0.8)
			if test_timer > 1.0:
				test_phase = "MINE_BLOCKS"
				test_timer = 0.0
		
		"MINE_BLOCKS":
			if test_timer < 0.1:
				print("[TERRAIN_PERSIST_TEST] Phase 2: Mining terrain blocks...")
			
			# Mine blocks (5 clicks)
			if int(test_timer * 3) != int((test_timer - delta) * 3):  # Every 0.33s
				if blocks_mined_before_save < 5:
					_mine_terrain()
					blocks_mined_before_save += 1
					print("[TERRAIN_PERSIST_TEST]   Mining attempt %d/5" % blocks_mined_before_save)
			
			if test_timer > 2.0:
				print("[TERRAIN_PERSIST_TEST] Mining complete - %d attempts made" % blocks_mined_before_save)
				test_phase = "CHECK_BEFORE"
				test_timer = 0.0
		
		"CHECK_BEFORE":
			if test_timer < 0.1:
				print("[TERRAIN_PERSIST_TEST] Phase 3: Checking terrain state BEFORE save...")
				_check_terrain_state("BEFORE_SAVE")
			if test_timer > 0.5:
				test_phase = "QUICKSAVE"
				test_timer = 0.0
		
		"QUICKSAVE":
			if test_timer < 0.1:
				print("[TERRAIN_PERSIST_TEST] Phase 4: QuickSaving (F5)...")
				_press_key(KEY_F5)
			if test_timer > 2.0:
				test_phase = "QUICKLOAD"
				test_timer = 0.0
		
		"QUICKLOAD":
			if test_timer < 0.1:
				print("[TERRAIN_PERSIST_TEST] Phase 5: QuickLoading (F8)...")
				_press_key(KEY_F8)
			if test_timer > 5.0:  # Wait for load
				test_phase = "CHECK_AFTER"
				test_timer = 0.0
		
		"CHECK_AFTER":
			if test_timer < 0.1:
				print("[TERRAIN_PERSIST_TEST] Phase 6: Checking terrain state AFTER load...")
				_check_terrain_state("AFTER_LOAD")
			if test_timer > 0.5:
				test_phase = "REPORT"
				test_timer = 0.0
		
		"REPORT":
			_report_results()
			test_phase = "DONE"
		
		"DONE":
			get_tree().quit(0)

func _rotate_camera_pitch(amount: float):
	if camera:
		camera.rotation.x = clamp(camera.rotation.x + amount, -PI/2, PI/2)

func _mine_terrain():
	# Simulate pickaxe swing
	var event_down = InputEventMouseButton.new()
	event_down.button_index = MOUSE_BUTTON_LEFT
	event_down.pressed = true
	Input.parse_input_event(event_down)
	
	await get_tree().process_frame
	
	var event_up = InputEventMouseButton.new()
	event_up.button_index = MOUSE_BUTTON_LEFT
	event_up.pressed = false
	Input.parse_input_event(event_up)

func _check_terrain_state(phase: String):
	if not camera or not terrain_manager:
		return
	
	# Raycast from camera to find terrain
	var origin = camera.global_position
	var direction = -camera.global_transform.basis.z
	var space_state = get_tree().root.get_world_3d().direct_space_state
	
	var query = PhysicsRayQueryParameters3D.create(origin, origin + direction * 10.0)
	query.collision_mask = 0xFFFFFFFF
	if player:
		query.exclude = [player.get_rid()]
	
	var result = space_state.intersect_ray(query)
	
	if result:
		var hit_pos = result.position
		var grid_pos = Vector3i(floor(hit_pos.x), floor(hit_pos.y), floor(hit_pos.z))
		
		# Check if block exists
		var has_block = false
		if terrain_manager.has_method("get_voxel"):
			var voxel = terrain_manager.get_voxel(grid_pos)
			has_block = (voxel != 0)
		
		print("[TERRAIN_PERSIST_TEST] %s: Target %s - Block exists: %s" % [phase, grid_pos, has_block])
		
		if phase == "BEFORE_SAVE":
			mining_target_pos = grid_pos
			terrain_modified = not has_block  # If block removed, terrain was modified
		elif phase == "AFTER_LOAD":
			# Compare with before state
			var block_exists_now = has_block
			var persistence_ok = (block_exists_now == (not terrain_modified))
			print("[TERRAIN_PERSIST_TEST] Persistence check: Modified=%s, ExistsNow=%s, Match=%s" % [terrain_modified, block_exists_now, persistence_ok])
			blocks_checked_after_load = 1 if persistence_ok else 0

func _press_key(keycode: int):
	var event = InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	Input.parse_input_event(event)
	
	await get_tree().process_frame
	event.pressed = false
	Input.parse_input_event(event)

func _report_results():
	var separator = "=================================================="
	print("")
	print("[TERRAIN_PERSIST_TEST] " + separator)
	print("[TERRAIN_PERSIST_TEST] === TERRAIN PERSISTENCE TEST RESULTS ===")
	print("[TERRAIN_PERSIST_TEST] " + separator)
	print("[TERRAIN_PERSIST_TEST]")
	print("[TERRAIN_PERSIST_TEST] Mining attempts: %d" % blocks_mined_before_save)
	print("[TERRAIN_PERSIST_TEST] Target position: %s" % mining_target_pos)
	print("[TERRAIN_PERSIST_TEST] Terrain modified: %s" % terrain_modified)
	print("[TERRAIN_PERSIST_TEST]")
	
	if blocks_checked_after_load > 0:
		print("[TERRAIN_PERSIST_TEST] ✅ TEST PASSED - Terrain modifications PERSIST after QuickLoad!")
		print("[TERRAIN_PERSIST_TEST] Terrain state correctly restored")
	else:
		print("[TERRAIN_PERSIST_TEST] ❌ TEST FAILED - Terrain modifications LOST after QuickLoad")
		print("[TERRAIN_PERSIST_TEST] Terrain state not preserved")
	
	print("[TERRAIN_PERSIST_TEST]")
	print("[TERRAIN_PERSIST_TEST] " + separator)
