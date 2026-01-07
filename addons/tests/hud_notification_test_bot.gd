extends Node
## HUD Notification Test Bot - Verifies save/load notifications appear visually

var test_timer = 0.0
var test_phase = "INIT"
var hud: CanvasLayer = null
var notification_label: Label = null

func _ready():
	print("[HUD_NOTIF_TEST] Starting HUD notification test...")
	await get_tree().create_timer(2.0).timeout
	
	# Find HUD - it's a CanvasLayer in the player scene
	var player = get_tree().get_first_node_in_group("player")
	if player:
		hud = player.get_node_or_null("HUD")
	
	if not hud:
		# Fallback: search all CanvasLayers
		for node in get_tree().get_nodes_in_group("player"):
			var potential_hud = node.get_node_or_null("HUD")
			if potential_hud:
				hud = potential_hud
				break
	
	if not hud:
		print("[HUD_NOTIF_TEST] ERROR: PlayerHUD not found!")
		get_tree().quit(1)
		return
	
	print("[HUD_NOTIF_TEST] HUD found: %s" % hud.name)
	
	# Find notification label
	notification_label = hud.get_node_or_null("SaveLoadNotification")
	if notification_label:
		print("[HUD_NOTIF_TEST] Notification label found!")
		print("[HUD_NOTIF_TEST]   Visible: %s" % notification_label.visible)
		print("[HUD_NOTIF_TEST]   Text: '%s'" % notification_label.text)
	else:
		print("[HUD_NOTIF_TEST] WARNING: Notification label NOT found!")
	
	test_phase = "QUICKSAVE"

func _process(delta):
	if test_phase == "INIT":
		return
	
	test_timer += delta
	
	match test_phase:
		"QUICKSAVE":
			if test_timer < 0.1:
				print("[HUD_NOTIF_TEST] Pressing F5 (QuickSave)...")
				_press_key(KEY_F5)
			if test_timer > 0.5:
				_check_label_state("AFTER_SAVE")
				test_phase = "WAIT"
				test_timer = 0.0
		
		"WAIT":
			if test_timer > 3.0:
				test_phase = "QUICKLOAD"
				test_timer = 0.0
		
		"QUICKLOAD":
			if test_timer < 0.1:
				print("[HUD_NOTIF_TEST] Pressing F8 (QuickLoad)...")
				_press_key(KEY_F8)
			if test_timer > 0.5:
				_check_label_state("AFTER_LOAD")
				test_phase = "REPORT"
				test_timer = 0.0
		
		"REPORT":
			_report_results()
			test_phase = "DONE"
		
		"DONE":
			get_tree().quit(0)

func _check_label_state(phase: String):
	if notification_label:
		print("[HUD_NOTIF_TEST] %s:" % phase)
		print("[HUD_NOTIF_TEST]   Visible: %s" % notification_label.visible)
		print("[HUD_NOTIF_TEST]   Text: '%s'" % notification_label.text)
	else:
		print("[HUD_NOTIF_TEST] %s: Label still not found" % phase)

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
	print("[HUD_NOTIF_TEST] " + separator)
	print("[HUD_NOTIF_TEST] === HUD NOTIFICATION TEST RESULTS ===")
	print("[HUD_NOTIF_TEST] " + separator)
	
	if notification_label:
		print("[HUD_NOTIF_TEST] ✅ Notification label exists")
		print("[HUD_NOTIF_TEST] Final state:")
		print("[HUD_NOTIF_TEST]   Visible: %s" % notification_label.visible)
		print("[HUD_NOTIF_TEST]   Text: '%s'" % notification_label.text)
	else:
		print("[HUD_NOTIF_TEST] ❌ Notification label NOT created")
		print("[HUD_NOTIF_TEST] _setup_visual_overlays() may not have run")
	
	print("[HUD_NOTIF_TEST] " + separator)
