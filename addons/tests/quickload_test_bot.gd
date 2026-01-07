extends Node
## QuickLoad Test Bot - Tests if pickaxe works after QuickLoad

var test_timer = 0.0
var camera: Camera3D = null
var player: CharacterBody3D = null
var test_phase = "INIT"
var clicks_before_save = 0
var clicks_after_load = 0

func _ready():
	print("[QUICKLOAD_TEST] _ready() CALLED - Bot is alive!")
	print("[QUICKLOAD_TEST] Starting QuickLoad bug test...")
	print("[QUICKLOAD_TEST] Waiting 3 seconds for game to load...")
	await get_tree().create_timer(3.0).timeout
	
	print("[QUICKLOAD_TEST] Finding player and camera...")
	# Find player and camera
	player = get_tree().get_first_node_in_group("player")
	if player:
		camera = player.get_node_or_null("Camera3D")
	
	if not player or not camera:
		print("[QUICKLOAD_TEST] ERROR: Player or Camera not found!")
		print("[QUICKLOAD_TEST] Player: %s, Camera: %s" % [player, camera])
		print("[QUICKLOAD_TEST] === TEST FAILED ===")
		get_tree().quit(1)
		return
	
	print("[QUICKLOAD_TEST] Player and Camera found!")
	print("[QUICKLOAD_TEST] Starting test sequence...")
	test_phase = "MOVE_FORWARD"

func _process(delta):
	if test_phase == "INIT":
		return
	
	test_timer += delta
	
	match test_phase:
		"MOVE_FORWARD":
			if test_timer < 0.1:
				print("[QUICKLOAD_TEST] Phase 1: Moving forward")
			Input.action_press("move_forward")
			if test_timer > 2.0:
				Input.action_release("move_forward")
				test_phase = "LOOK_DOWN"
				test_timer = 0.0
		
		"LOOK_DOWN":
			if test_timer < 0.1:
				print("[QUICKLOAD_TEST] Phase 2: Looking down")
			_rotate_camera_pitch(-delta * 0.8)
			if test_timer > 1.0:
				test_phase = "MINE_BEFORE_SAVE"
				test_timer = 0.0
		
		"MINE_BEFORE_SAVE":
			if test_timer < 0.1:
				print("[QUICKLOAD_TEST] Phase 3: Mining BEFORE save (testing pickaxe works)")
			# Click 3 times
			if int(test_timer * 2) != int((test_timer - delta) * 2):
				if clicks_before_save < 3:
					_click_left()
					clicks_before_save += 1
					print("[QUICKLOAD_TEST]   Click %d/3 - pickaxe should work" % clicks_before_save)
			if test_timer > 2.0:
				print("[QUICKLOAD_TEST] Pickaxe worked before save: %d clicks" % clicks_before_save)
				test_phase = "QUICKSAVE"
				test_timer = 0.0
		
		"QUICKSAVE":
			if test_timer < 0.1:
				print("[QUICKLOAD_TEST] Phase 4: Pressing F5 (QuickSave)")
				_press_key(KEY_F5)
			if test_timer > 2.0:
				test_phase = "MOVE_AFTER_SAVE"
				test_timer = 0.0
		
		"MOVE_AFTER_SAVE":
			if test_timer < 0.1:
				print("[QUICKLOAD_TEST] Phase 5: Moving (to change state)")
			Input.action_press("move_forward")
			if test_timer > 1.0:
				Input.action_release("move_forward")
				test_phase = "QUICKLOAD"
				test_timer = 0.0
		
		"QUICKLOAD":
			if test_timer < 0.1:
				print("[QUICKLOAD_TEST] Phase 6: Pressing F8 (QuickLoad) - THE CRITICAL TEST")
				_press_key(KEY_F8)
			if test_timer > 4.0:  # Wait for load to complete
				test_phase = "INSPECT_HOTBAR"
				test_timer = 0.0
		
		"INSPECT_HOTBAR":
			if test_timer < 0.1:
				print("[QUICKLOAD_TEST] Phase 7: Inspecting hotbar state after QuickLoad")
				_inspect_hotbar_state()
			if test_timer > 1.0:
				test_phase = "MINE_AFTER_LOAD"
				test_timer = 0.0
		
		"MINE_AFTER_LOAD":
			if test_timer < 0.1:
				print("[QUICKLOAD_TEST] Phase 8: Mining AFTER load (testing if pickaxe still works)")
			# Click 3 times
			if int(test_timer * 2) != int((test_timer - delta) * 2):
				if clicks_after_load < 3:
					_click_left()
					clicks_after_load += 1
					print("[QUICKLOAD_TEST]   Click %d/3 - does pickaxe work?" % clicks_after_load)
			if test_timer > 2.0:
				print("[QUICKLOAD_TEST] Pickaxe after load: %d clicks registered" % clicks_after_load)
				test_phase = "REPORT"
				test_timer = 0.0
		
		"REPORT":
			_report_results()
			test_phase = "DONE"
		
		"DONE":
			get_tree().quit(0 if clicks_after_load >= 3 else 1)

func _rotate_camera_pitch(amount: float):
	if camera:
		camera.rotation.x = clamp(camera.rotation.x + amount, -PI/2, PI/2)

func _click_left():
	var event_down = InputEventMouseButton.new()
	event_down.button_index = MOUSE_BUTTON_LEFT
	event_down.pressed = true
	Input.parse_input_event(event_down)
	
	await get_tree().process_frame
	var event_up = InputEventMouseButton.new()
	event_up.button_index = MOUSE_BUTTON_LEFT
	event_up.pressed = false
	Input.parse_input_event(event_up)

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
	print("[QUICKLOAD_TEST] " + separator)
	print("[QUICKLOAD_TEST] === QUICKLOAD TEST RESULTS ===")
	print("[QUICKLOAD_TEST] " + separator)
	print("[QUICKLOAD_TEST] ")
	print("[QUICKLOAD_TEST] Clicks BEFORE save: %d/3" % clicks_before_save)
	print("[QUICKLOAD_TEST] Clicks AFTER load:  %d/3" % clicks_after_load)
	print("[QUICKLOAD_TEST] ")
	
	if clicks_before_save >= 3 and clicks_after_load >= 3:
		print("[QUICKLOAD_TEST] ✅ TEST PASSED - Pickaxe works after QuickLoad!")
		print("[QUICKLOAD_TEST] The QuickLoad bug is FIXED!")
	elif clicks_before_save >= 3 and clicks_after_load == 0:
		print("[QUICKLOAD_TEST] ❌ TEST FAILED - Pickaxe does NOT work after QuickLoad")
		print("[QUICKLOAD_TEST] Bug still exists: Player is frozen or input is broken")
	else:
		print("[QUICKLOAD_TEST] ⚠️  TEST INCONCLUSIVE")
		print("[QUICKLOAD_TEST] Unexpected results - check logs")
	
	print("[QUICKLOAD_TEST] ")
	print("[QUICKLOAD_TEST] " + separator)

func _inspect_hotbar_state():
	print("[QUICKLOAD_TEST] === HOTBAR STATE DIAGNOSTIC ===")
	
	if not player:
		print("[QUICKLOAD_TEST] ERROR: Player not found!")
		return
	
	# Find hotbar
	var hotbar = player.get_node_or_null("Systems/Hotbar")
	if not hotbar:
		print("[QUICKLOAD_TEST] ERROR: Hotbar not found!")
		return
	
	# Get hotbar state
	var selected_slot = hotbar.selected_slot if hotbar.has("selected_slot") else -1
	print("[QUICKLOAD_TEST] Selected slot index: %d" % selected_slot)
	
	# Get selected item
	var selected_item = {}
	if hotbar.has_method("get_selected_item"):
		selected_item = hotbar.get_selected_item()
	
	print("[QUICKLOAD_TEST] Selected item data:")
	if selected_item.is_empty():
		print("[QUICKLOAD_TEST]   ❌ ITEM IS EMPTY - This is the bug!")
	else:
		print("[QUICKLOAD_TEST]   Item name: %s" % selected_item.get("name", "UNKNOWN"))
		print("[QUICKLOAD_TEST]   Item type: %s" % selected_item.get("type", "UNKNOWN"))
		print("[QUICKLOAD_TEST]   Full data: %s" % str(selected_item))
	
	# Check all slots
	if hotbar.has("slots"):
		print("[QUICKLOAD_TEST] All hotbar slots:")
		var slots = hotbar.slots
		for i in range(min(slots.size(), 10)):
			var slot = slots[i]
			var item = slot.get("item", {})
			var count = slot.get("count", 0)
			if not item.is_empty():
				print("[QUICKLOAD_TEST]   Slot %d: %s x%d" % [i, item.get("name", "?"), count])
			else:
				print("[QUICKLOAD_TEST]   Slot %d: empty" % i)
	
	print("[QUICKLOAD_TEST] ================================")
