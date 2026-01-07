extends Node
## Complex Terrain Persistence Test Bot - Tests terrain modifications with entities present

var test_timer = 0.0
var player: CharacterBody3D = null
var camera: Camera3D = null
var test_phase = "INIT"

var terrain_manager: Node = null
var entity_manager: Node = null
var mining_positions: Array[Vector3i] = []
var blocks_destroyed: int = 0
var zombie_count_before: int = 0
var zombie_count_after: int = 0
var terrain_state_matches: bool = false

func _ready():
	print("[COMPLEX_TERRAIN_TEST] Starting complex terrain persistence test...")
	print("[COMPLEX_TERRAIN_TEST] Testing: Terrain mods + Entities scenario")
	await get_tree().create_timer(5.0).timeout  # Wait longer for entities to spawn
	
	# Find components
	player = get_tree().get_first_node_in_group("player")
	if player:
		camera = player.get_node_or_null("Camera3D")
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	entity_manager = get_tree().get_first_node_in_group("entity_manager")
	
	if not player or not camera or not terrain_manager:
		print("[COMPLEX_TERRAIN_TEST] ERROR: Missing required components!")
		get_tree().quit(1)
		return
	
	print("[COMPLEX_TERRAIN_TEST] Components found!")
	print("[COMPLEX_TERRAIN_TEST] EntityManager: %s" % (entity_manager != null))
	test_phase = "COUNT_ZOMBIES_BEFORE"

func _process(delta):
	if test_phase == "INIT":
		return
	
	test_timer += delta
	
	match test_phase:
		"COUNT_ZOMBIES_BEFORE":
			if test_timer < 0.1:
				print("[COMPLEX_TERRAIN_TEST] Phase 1: Counting zombies...")
				_count_zombies("BEFORE_MINING")
			if test_timer > 0.5:
				test_phase = "POSITION"
				test_timer = 0.0
		
		"POSITION":
			if test_timer < 0.1:
				print("[COMPLEX_TERRAIN_TEST] Phase 2: Positioning...")
			_rotate_camera_pitch(-delta * 0.8)
			if test_timer > 1.0:
				test_phase = "EXTENSIVE_MINING"
				test_timer = 0.0
		
		"EXTENSIVE_MINING":
			if test_timer < 0.1:
				print("[COMPLEX_TERRAIN_TEST] Phase 3: EXTENSIVE mining (10 attempts, 1s interval)...")
			
			# Mine slower - 1 click per second for better hit registration
			if int(test_timer) != int(test_timer - delta):  # Every 1 second
				if blocks_destroyed < 10:
					_mine_and_record()
					blocks_destroyed += 1
					print("[COMPLEX_TERRAIN_TEST]   Mining attempt %d/10 (waiting for hit...)" % blocks_destroyed)
			
			if test_timer > 11.0:  # 10 seconds mining + 1 second buffer
				print("[COMPLEX_TERRAIN_TEST] Mining complete - %d attempts made" % blocks_destroyed)
				test_phase = "WAIT_FOR_ENTITIES"
				test_timer = 0.0
		
		"WAIT_FOR_ENTITIES":
			if test_timer < 0.1:
				print("[COMPLEX_TERRAIN_TEST] Phase 4: Waiting for entities to move/spawn...")
			# Wait to give entities time to move around mined terrain
			if test_timer > 3.0:
				_count_zombies("BEFORE_SAVE")
				test_phase = "CHECK_TERRAIN_BEFORE"
				test_timer = 0.0
		
		"CHECK_TERRAIN_BEFORE":
			if test_timer < 0.1:
				print("[COMPLEX_TERRAIN_TEST] Phase 5: Checking terrain state...")
				_check_multiple_blocks("BEFORE_SAVE")
			if test_timer > 1.0:
				test_phase = "QUICKSAVE"
				test_timer = 0.0
		
		"QUICKSAVE":
			if test_timer < 0.1:
				print("[COMPLEX_TERRAIN_TEST] Phase 6: QuickSaving WITH entities nearby...")
				_press_key(KEY_F5)
			if test_timer > 2.0:
				test_phase = "QUICKLOAD"
				test_timer = 0.0
		
		"QUICKLOAD":
			if test_timer < 0.1:
				print("[COMPLEX_TERRAIN_TEST] Phase 7: QuickLoading...")
				_press_key(KEY_F8)
			if test_timer > 6.0:  # Wait for full load
				test_phase = "COUNT_ZOMBIES_AFTER"
				test_timer = 0.0
		
		"COUNT_ZOMBIES_AFTER":
			if test_timer < 0.1:
				print("[COMPLEX_TERRAIN_TEST] Phase 8: Counting zombies AFTER load...")
				_count_zombies("AFTER_LOAD")
			if test_timer > 1.0:
				print("[COMPLEX_TERRAIN_TEST] Moving to CHECK_TERRAIN_AFTER phase")
				test_phase = "CHECK_TERRAIN_AFTER"
				test_timer = 0.0
		
		"CHECK_TERRAIN_AFTER":
			if test_timer < 0.1:
				print("[COMPLEX_TERRAIN_TEST] Phase 9: Verifying terrain after load...")
				_check_multiple_blocks("AFTER_LOAD")
			if test_timer > 1.0:
				print("[COMPLEX_TERRAIN_TEST] Moving to REPORT phase")
				test_phase = "REPORT"
				test_timer = 0.0
		
		"REPORT":
			print("[COMPLEX_TERRAIN_TEST] Generating final report...")
			_report_results()
			test_phase = "DONE"
		
		"DONE":
			print("[COMPLEX_TERRAIN_TEST] Test complete, exiting...")
			get_tree().quit(0)

func _rotate_camera_pitch(amount: float):
	if camera:
		camera.rotation.x = clamp(camera.rotation.x + amount, -PI/2, PI/2)

func _mine_and_record():
	var event_down = InputEventMouseButton.new()
	event_down.button_index = MOUSE_BUTTON_LEFT
	event_down.pressed = true
	Input.parse_input_event(event_down)
	
	await get_tree().process_frame
	
	var event_up = InputEventMouseButton.new()
	event_up.button_index = MOUSE_BUTTON_LEFT
	event_up.pressed = false
	Input.parse_input_event(event_up)

func _count_zombies(phase: String):
	var zombie_count = 0
	
	# Count zombies in the world
	if entity_manager and entity_manager.has_method("get_entity_count"):
		zombie_count = entity_manager.get_entity_count()
	else:
		# Fallback: count nodes in group
		zombie_count = get_tree().get_nodes_in_group("zombie").size()
	
	print("[COMPLEX_TERRAIN_TEST] %s: Zombie count = %d" % [phase, zombie_count])
	
	if phase == "BEFORE_SAVE":
		zombie_count_before = zombie_count
	elif phase == "AFTER_LOAD":
		zombie_count_after = zombie_count

func _check_multiple_blocks(phase: String):
	if not camera or not terrain_manager:
		return
	
	# Raycast to find terrain blocks
	var origin = camera.global_position
	var direction = -camera.global_transform.basis.z
	var space_state = get_tree().root.get_world_3d().direct_space_state
	
	var query = PhysicsRayQueryParameters3D.create(origin, origin + direction * 15.0)
	query.collision_mask = 0xFFFFFFFF
	if player:
		query.exclude = [player.get_rid()]
	
	var result = space_state.intersect_ray(query)
	
	if result:
		var hit_pos = result.position
		var center = Vector3i(floor(hit_pos.x), floor(hit_pos.y), floor(hit_pos.z))
		
		# Check area around hit point
		var modified_count = 0
		var total_checked = 0
		
		for x in range(-2, 3):
			for y in range(-1, 2):
				for z in range(-2, 3):
					var check_pos = center + Vector3i(x, y, z)
					total_checked += 1
					
					if terrain_manager.has_method("get_voxel"):
						var voxel = terrain_manager.get_voxel(check_pos)
						if voxel == 0:  # Air/removed block
							modified_count += 1
		
		var modification_percent = (float(modified_count) / total_checked) * 100.0
		print("[COMPLEX_TERRAIN_TEST] %s: %d/%d blocks modified (%.1f%%)" % [phase, modified_count, total_checked, modification_percent])
		
		if phase == "AFTER_LOAD":
			# Check if significant terrain is still modified
			terrain_state_matches = (modified_count > 5)  # At least some modifications should persist

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
	print("[COMPLEX_TERRAIN_TEST] " + separator)
	print("[COMPLEX_TERRAIN_TEST] === COMPLEX TERRAIN PERSISTENCE TEST ===")
	print("[COMPLEX_TERRAIN_TEST] " + separator)
	print("[COMPLEX_TERRAIN_TEST]")
	print("[COMPLEX_TERRAIN_TEST] Mining attempts: %d" % blocks_destroyed)
	print("[COMPLEX_TERRAIN_TEST] Zombies before save: %d" % zombie_count_before)
	print("[COMPLEX_TERRAIN_TEST] Zombies after load: %d" % zombie_count_after)
	print("[COMPLEX_TERRAIN_TEST] Terrain state persisted: %s" % terrain_state_matches)
	print("[COMPLEX_TERRAIN_TEST]")
	
	if terrain_state_matches and zombie_count_after > 0:
		print("[COMPLEX_TERRAIN_TEST] ✅ TEST PASSED - Terrain mods persist WITH entities!")
	elif not terrain_state_matches and zombie_count_after > 0:
		print("[COMPLEX_TERRAIN_TEST] ❌ TEST FAILED - Terrain mods LOST with entities present")
		print("[COMPLEX_TERRAIN_TEST] BUG CONFIRMED: Zombies loaded but terrain not restored!")
	else:
		print("[COMPLEX_TERRAIN_TEST] ⚠️  TEST INCONCLUSIVE - No entities to test with")
	
	print("[COMPLEX_TERRAIN_TEST]")
	print("[COMPLEX_TERRAIN_TEST] " + separator)
