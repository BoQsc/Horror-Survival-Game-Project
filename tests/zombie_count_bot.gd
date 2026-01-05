extends Node
## Zombie count test - counts before save, after save, after load

var test_timer = 0.0
var test_phase = "WAIT"
var zombie_before_save = 0
var zombie_after_save = 0
var zombie_after_load = 0

func _ready():
	print("[ZOMBIE_COUNT_TEST] Starting test...")
	await get_tree().create_timer(30.0).timeout
	print("[ZOMBIE_COUNT_TEST] Ready to count")
	test_phase = "COUNT_BEFORE"

func _process(delta):
	if test_phase == "DONE":
		return
	
	test_timer += delta
	
	match test_phase:
		"COUNT_BEFORE":
			if test_timer < 0.1:
				zombie_before_save = get_tree().get_nodes_in_group("zombies").size()
				print("[ZOMBIE_COUNT_TEST] Zombies BEFORE save: %d" % zombie_before_save)
			if test_timer > 1.0:
				test_phase = "SAVE"
				test_timer = 0.0
		
		"SAVE":
			if test_timer < 0.1:
				print("[ZOMBIE_COUNT_TEST] Pressing F5 (QuickSave)...")
				_press_key(KEY_F5)
			if test_timer > 3.0:
				test_phase = "COUNT_AFTER_SAVE"
				test_timer = 0.0
		
		"COUNT_AFTER_SAVE":
			if test_timer < 0.1:
				zombie_after_save = get_tree().get_nodes_in_group("zombies").size()
				print("[ZOMBIE_COUNT_TEST] Zombies AFTER save: %d" % zombie_after_save)
			if test_timer > 1.0:
				test_phase = "LOAD"
				test_timer = 0.0
		
		"LOAD":
			if test_timer < 0.1:
				print("[ZOMBIE_COUNT_TEST] Pressing F8 (QuickLoad)...")
				_press_key(KEY_F8)
			if test_timer > 8.0:
				test_phase = "COUNT_AFTER_LOAD"
				test_timer = 0.0
		
		"COUNT_AFTER_LOAD":
			if test_timer < 0.1:
				zombie_after_load = get_tree().get_nodes_in_group("zombies").size()
				print("[ZOMBIE_COUNT_TEST] Zombies AFTER load: %d" % zombie_after_load)
			if test_timer > 1.0:
				test_phase = "REPORT"
				test_timer = 0.0
		
		"REPORT":
			_report_results()
			test_phase = "DONE"
		
		"DONE":
			get_tree().quit()

func _press_key(keycode: int):
	var event = InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	Input.parse_input_event(event)
	await get_tree().process_frame
	event.pressed = false
	Input.parse_input_event(event)

func _report_results():
	print("")
	print("[ZOMBIE_COUNT_TEST] ==================================================")
	print("[ZOMBIE_COUNT_TEST] === ZOMBIE DUPLICATION TEST RESULTS ===")
	print("[ZOMBIE_COUNT_TEST] ==================================================")
	print("[ZOMBIE_COUNT_TEST]")
	print("[ZOMBIE_COUNT_TEST] Before save:  %d" % zombie_before_save)
	print("[ZOMBIE_COUNT_TEST] After save:   %d" % zombie_after_save)
	print("[ZOMBIE_COUNT_TEST] After load:   %d" % zombie_after_load)
	print("[ZOMBIE_COUNT_TEST]")
	var diff_save = zombie_after_save - zombie_before_save
	var diff_load = zombie_after_load - zombie_after_save
	print("[ZOMBIE_COUNT_TEST] Change at save: %+d" % diff_save)
	print("[ZOMBIE_COUNT_TEST] Change at load: %+d" % diff_load)
	print("[ZOMBIE_COUNT_TEST]")
	
	if abs(diff_save) > 2:
		print("[ZOMBIE_COUNT_TEST] ❌ FAIL - Save corrupted zombies!")
	elif abs(diff_load) > 2:
		print("[ZOMBIE_COUNT_TEST] ❌ FAIL - Load duplicated zombies!")
	else:
		print("[ZOMBIE_COUNT_TEST] ✅ PASS - Zombie count stable")
	
	print("[ZOMBIE_COUNT_TEST] ==================================================")
