extends Node
## Simplified Zombie Count Test - Just counts zombies before/after QuickLoad

var test_timer = 0.0
var test_phase = "INIT"
var zombie_count_before: int = 0
var zombie_count_after: int = 0

func _ready():
	print("[ZOMBIE_COUNT_TEST] Starting simplified zombie count test...")
	await get_tree().create_timer(15.0).timeout  # Wait for zombies to spawn
	
	print("[ZOMBIE_COUNT_TEST] Test initialized")
	test_phase = "COUNT_BEFORE"

func _process(delta):
	if test_phase == "INIT":
		return
	
	test_timer += delta
	
	match test_phase:
		"COUNT_BEFORE":
			if test_timer < 0.1:
				zombie_count_before = _count_zombies()
				print("[ZOMBIE_COUNT_TEST] Zombies BEFORE save: %d" % zombie_count_before)
				if zombie_count_before == 0:
					print("[ZOMBIE_COUNT_TEST] WARNING: No zombies spawned!")
			if test_timer > 1.0:
				test_phase = "QUICKSAVE"
				test_timer = 0.0
		
		"QUICKSAVE":
			if test_timer < 0.1:
				print("[ZOMBIE_COUNT_TEST] Pressing F5 (QuickSave)...")
				_press_key(KEY_F5)
			if test_timer > 2.0:
				test_phase = "QUICKLOAD"
				test_timer = 0.0
		
		"QUICKLOAD":
			if test_timer < 0.1:
				print("[ZOMBIE_COUNT_TEST] Pressing F8 (QuickLoad)...")
				_press_key(KEY_F8)
			if test_timer > 8.0:  # Wait longer for load
				test_phase = "COUNT_AFTER"
				test_timer = 0.0
		
		"COUNT_AFTER":
			if test_timer < 0.1:
				zombie_count_after = _count_zombies()
				print("[ZOMBIE_COUNT_TEST] Zombies AFTER load: %d" % zombie_count_after)
			if test_timer > 1.0:
				test_phase = "REPORT"
				test_timer = 0.0
		
		"REPORT":
			_report_results()
			test_phase = "DONE"
		
		"DONE":
			print("[ZOMBIE_COUNT_TEST] Test complete, exiting...")
			get_tree().quit(0)

func _count_zombies() -> int:
	var zombies = get_tree().get_nodes_in_group("zombie")
	return zombies.size()

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
	print("[ZOMBIE_COUNT_TEST] " + separator)
	print("[ZOMBIE_COUNT_TEST] === ZOMBIE COUNT TEST RESULTS ===")
	print("[ZOMBIE_COUNT_TEST] " + separator)
	print("[ZOMBIE_COUNT_TEST]")
	print("[ZOMBIE_COUNT_TEST] Zombies BEFORE save: %d" % zombie_count_before)
	print("[ZOMBIE_COUNT_TEST] Zombies AFTER load:  %d" % zombie_count_after)
	print("[ZOMBIE_COUNT_TEST]")
	
	var difference = zombie_count_after - zombie_count_before
	var percent_change = 0.0
	if zombie_count_before > 0:
		percent_change = (float(difference) / zombie_count_before) * 100.0
	
	print("[ZOMBIE_COUNT_TEST] Difference: %+d (%.1f%%)" % [difference, percent_change])
	print("[ZOMBIE_COUNT_TEST]")
	
	if abs(difference) <= 2:
		print("[ZOMBIE_COUNT_TEST] ✅ PASS - Zombie count stable")
	elif difference > 2:
		print("[ZOMBIE_COUNT_TEST] ❌ FAIL - ZOMBIE DUPLICATION BUG!")
		print("[ZOMBIE_COUNT_TEST] %d extra zombies after QuickLoad" % difference)
	else:
		print("[ZOMBIE_COUNT_TEST] ⚠️  WARNING - Zombies missing")
	
	print("[ZOMBIE_COUNT_TEST]")
	print("[ZOMBIE_COUNT_TEST] " + separator)
