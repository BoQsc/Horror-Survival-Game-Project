extends Node
## Zombie Persistence Test Bot - Tests if zombies duplicate on QuickLoad

var test_timer = 0.0
var test_phase = "INIT"
var entity_manager: Node = null

var zombie_count_initial: int = 0
var zombie_count_before_save: int = 0
var zombie_count_after_load: int = 0
var zombie_positions_before: Array = []
var zombie_positions_after: Array = []

func _ready():
	print("[ZOMBIE_TEST] Starting zombie persistence test...")
	await get_tree().create_timer(5.0).timeout  # Wait for zombies to spawn
	
	entity_manager = get_tree().get_first_node_in_group("entity_manager")
	if not entity_manager:
		print("[ZOMBIE_TEST] ERROR: EntityManager not found!")
		get_tree().quit(1)
		return
	
	print("[ZOMBIE_TEST] EntityManager found!")
	test_phase = "COUNT_INITIAL"

func _process(delta):
	if test_phase == "INIT":
		return
	
	test_timer += delta
	
	match test_phase:
		"COUNT_INITIAL":
			if test_timer < 0.1:
				zombie_count_initial = _count_zombies()
				_record_zombie_positions(zombie_positions_before)
				print("[ZOMBIE_TEST] Initial zombie count: %d" % zombie_count_initial)
				print("[ZOMBIE_TEST] Recorded %d zombie positions" % zombie_positions_before.size())
			if test_timer > 1.0:
				test_phase = "WAIT_STABLE"
				test_timer = 0.0
		
		"WAIT_STABLE":
			# Wait for zombies to stabilize (no more spawning)
			# Check every 3 seconds
			if int(test_timer) % 3 == 0 and int(test_timer - delta) % 3 != 0:
				var current_count = _count_zombies()
				print("[ZOMBIE_TEST] Current zombie count: %d (waiting for stabilization...)" % current_count)
			
			if test_timer > 15.0:  # Wait 15 seconds for zombies to spawn
				zombie_count_before_save = _count_zombies()
				print("[ZOMBIE_TEST] Zombies stabilized at: %d" % zombie_count_before_save)
				
				if zombie_count_before_save == 0:
					print("[ZOMBIE_TEST] WARNING: No zombies spawned! Test may be inconclusive")
				
				test_phase = "QUICKSAVE"
				test_timer = 0.0
		
		"QUICKSAVE":
			if test_timer < 0.1:
				print("[ZOMBIE_TEST] QuickSaving (F5)...")
				_press_key(KEY_F5)
			if test_timer > 2.0:
				test_phase = "QUICKLOAD"
				test_timer = 0.0
		
		"QUICKLOAD":
			if test_timer < 0.1:
				print("[ZOMBIE_TEST] QuickLoading (F8)...")
				_press_key(KEY_F8)
			if test_timer > 6.0:  # Wait for load to complete
				test_phase = "COUNT_AFTER"
				test_timer = 0.0
		
		"COUNT_AFTER":
			if test_timer < 0.1:
				zombie_count_after_load = _count_zombies()
				_record_zombie_positions(zombie_positions_after)
				print("[ZOMBIE_TEST] Zombie count after load: %d" % zombie_count_after_load)
				print("[ZOMBIE_TEST] Recorded %d zombie positions" % zombie_positions_after.size())
			if test_timer > 1.0:
				test_phase = "REPORT"
				test_timer = 0.0
		
		"REPORT":
			_report_results()
			test_phase = "DONE"
		
		"DONE":
			get_tree().quit(0)

func _count_zombies() -> int:
	var zombies = get_tree().get_nodes_in_group("zombie")
	return zombies.size()

func _record_zombie_positions(target_array: Array):
	target_array.clear()
	var zombies = get_tree().get_nodes_in_group("zombie")
	for zombie in zombies:
		if zombie is Node3D:
			target_array.append(zombie.global_position)

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
	print("[ZOMBIE_TEST] " + separator)
	print("[ZOMBIE_TEST] === ZOMBIE PERSISTENCE TEST RESULTS ===")
	print("[ZOMBIE_TEST] " + separator)
	print("[ZOMBIE_TEST]")
	print("[ZOMBIE_TEST] Initial count:      %d" % zombie_count_initial)
	print("[ZOMBIE_TEST] Before save count:  %d" % zombie_count_before_save)
	print("[ZOMBIE_TEST] After load count:   %d" % zombie_count_after_load)
	print("[ZOMBIE_TEST]")
	
	var difference = zombie_count_after_load - zombie_count_before_save
	var percent_change = 0.0
	if zombie_count_before_save > 0:
		percent_change = (float(difference) / zombie_count_before_save) * 100.0
	
	print("[ZOMBIE_TEST] Difference: %+d (%.1f%%)" % [difference, percent_change])
	print("[ZOMBIE_TEST]")
	
	if abs(difference) <= 2:
		print("[ZOMBIE_TEST] ✅ TEST PASSED - Zombie count stable (±2 tolerance)")
		print("[ZOMBIE_TEST] Minor variance acceptable due to async spawning")
	elif difference > 2:
		print("[ZOMBIE_TEST] ❌ TEST FAILED - ZOMBIE DUPLICATION DETECTED!")
		print("[ZOMBIE_TEST] %d extra zombies spawned after QuickLoad" % difference)
		print("[ZOMBIE_TEST] Likely cause: Zombies saved + new zombies spawning")
	else:
		print("[ZOMBIE_TEST] ⚠️  WARNING - Zombies LOST after QuickLoad")
		print("[ZOMBIE_TEST] %d zombies missing" % abs(difference))
	
	print("[ZOMBIE_TEST]")
	print("[ZOMBIE_TEST] " + separator)
