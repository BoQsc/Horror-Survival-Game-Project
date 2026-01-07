extends Node
## Early QuickLoad Test Bot - Tests if QuickLoad causes falling through terrain

var test_timer = 0.0
var player: CharacterBody3D = null
var initial_y: float = 0.0
var test_phase = "INIT"
var position_log = []

func _ready():
	print("[QUICKLOAD_FALL_TEST] Starting early QuickLoad test...")
	print("[QUICKLOAD_FALL_TEST] Waiting 2 seconds for minimal initialization...")
	await get_tree().create_timer(2.0).timeout
	
	# Find player
	player = get_tree().get_first_node_in_group("player")
	if not player:
		print("[QUICKLOAD_FALL_TEST] ERROR: Player not found!")
		get_tree().quit(1)
		return
	
	initial_y = player.global_position.y
	print("[QUICKLOAD_FALL_TEST] Player found at Y: %0.2f" % initial_y)
	print("[QUICKLOAD_FALL_TEST] Expected terrain level: ~14-16")
	test_phase = "QUICKLOAD"

func _process(delta):
	if test_phase == "INIT":
		return
	
	test_timer += delta
	
	# Log position every 0.5 seconds
	if int(test_timer * 2) != int((test_timer - delta) * 2):
		if player:
			var pos = player.global_position
			var log_entry = "T+%0.1fs: Y=%0.2f" % [test_timer, pos.y]
			position_log.append(log_entry)
			print("[QUICKLOAD_FALL_TEST] %s" % log_entry)
	
	match test_phase:
		"QUICKLOAD":
			if test_timer < 0.1:
				print("[QUICKLOAD_FALL_TEST] Pressing F8 (QuickLoad) at game start...")
				_press_key(KEY_F8)
			if test_timer > 1.0:
				test_phase = "MONITOR"
				test_timer = 0.0
		
		"MONITOR":
			# Monitor for 10 seconds after QuickLoad
			if player:
				var current_y = player.global_position.y
				var y_change = current_y - initial_y
				
				# Check if player fell significantly
				if current_y < 10.0:  # Below terrain level
					print("[QUICKLOAD_FALL_TEST] ⚠️  PLAYER FELL THROUGH TERRAIN!")
					print("[QUICKLOAD_FALL_TEST] Current Y: %0.2f (started at %0.2f)" % [current_y, initial_y])
					print("[QUICKLOAD_FALL_TEST] Fell: %0.2f units" % y_change)
					test_phase = "REPORT_FAIL"
				elif test_timer > 10.0:
					print("[QUICKLOAD_FALL_TEST] ✅ Player stable at Y: %0.2f" % current_y)
					test_phase = "REPORT_PASS"
		
		"REPORT_FAIL":
			_report_results(false)
			test_phase = "DONE"
		
		"REPORT_PASS":
			_report_results(true)
			test_phase = "DONE"
		
		"DONE":
			get_tree().quit(0 if test_timer > 1.0 else 1)

func _press_key(keycode: int):
	var event = InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	Input.parse_input_event(event)
	
	await get_tree().process_frame
	event.pressed = false
	Input.parse_input_event(event)

func _report_results(passed: bool):
	var separator = "=================================================="
	print("")
	print("[QUICKLOAD_FALL_TEST] " + separator)
	print("[QUICKLOAD_FALL_TEST] === EARLY QUICKLOAD TEST RESULTS ===")
	print("[QUICKLOAD_FALL_TEST] " + separator)
	print("[QUICKLOAD_FALL_TEST]")
	
	print("[QUICKLOAD_FALL_TEST] Position Log:")
	for entry in position_log:
		print("[QUICKLOAD_FALL_TEST]   %s" % entry)
	print("[QUICKLOAD_FALL_TEST]")
	
	if passed:
		print("[QUICKLOAD_FALL_TEST] ✅ TEST PASSED - Player did NOT fall through terrain")
		print("[QUICKLOAD_FALL_TEST] QuickLoad on game start is working correctly")
	else:
		print("[QUICKLOAD_FALL_TEST] ❌ TEST FAILED - Player FELL THROUGH TERRAIN")
		print("[QUICKLOAD_FALL_TEST] Bug confirmed: Early QuickLoad causes fall-through")
		if player:
			var pos = player.global_position
			print("[QUICKLOAD_FALL_TEST] Final position: (%0.2f, %0.2f, %0.2f)" % [pos.x, pos.y, pos.z])
	
	print("[QUICKLOAD_FALL_TEST]")
	print("[QUICKLOAD_FALL_TEST] " + separator)
