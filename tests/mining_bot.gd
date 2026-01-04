extends Node
## Bot that moves, looks around, and mines

var move_timer = 0.0
var camera: Camera3D = null
var player: CharacterBody3D = null

func _ready():
	print("[BOT] Mining test bot starting...")
	await get_tree().create_timer(3.0).timeout
	
	# Find player and camera
	player = get_tree().get_first_node_in_group("player")
	if player:
		camera = player.get_node_or_null("Camera3D")
	
	print("[BOT] Player found: %s, Camera found: %s" % [player != null, camera != null])
	if camera:
		print("[BOT] Camera path: %s" % camera.get_path())
	print("[BOT] Starting test sequence")

func _process(delta):
	if not player or not camera:
		return
	
	move_timer += delta
	
	# Test sequence:
	# 0-3s: Move forward
	# 3-4s: Look down (to see ground)
	# 4-6s: Mine (left-click repeatedly)
	# 6-8s: Look up
	# 8-10s: Move backward
	# 10s: Done
	
	if move_timer < 3.0:
		if move_timer < 0.1:
			print("[BOT] Phase 1: Moving forward")
		Input.action_press("move_forward")
	
	elif move_timer < 4.0:
		Input.action_release("move_forward")
		if move_timer < 3.1:
			print("[BOT] Phase 2: Looking down at ground")
		# Rotate camera down
		_rotate_camera_pitch(-delta * 0.5)  # Look down
	
	elif move_timer < 6.0:
		if move_timer < 4.1:
			print("[BOT] Phase 3: Mining (left-clicking)")
		# Click every 0.5 seconds
		if int(move_timer * 2) != int((move_timer - delta) * 2):
			_click_left()
			print("[BOT]   *click* (mining)")
	
	elif move_timer < 8.0:
		if move_timer < 6.1:
			print("[BOT] Phase 4: Looking back up")
		# Rotate camera up
		_rotate_camera_pitch(delta * 0.5)  # Look up
	
	elif move_timer < 10.0:
		if move_timer < 8.1:
			print("[BOT] Phase 5: Moving backward")
		Input.action_press("move_backward")
	
	else:
		Input.action_release("move_backward")
		print("[BOT] Test complete!")
		get_tree().quit()

func _rotate_camera_pitch(amount: float):
	if camera:
		camera.rotation.x = clamp(camera.rotation.x + amount, -PI/2, PI/2)

func _click_left():
	# Simulate left mouse button
	var event_down = InputEventMouseButton.new()
	event_down.button_index = MOUSE_BUTTON_LEFT
	event_down.pressed = true
	Input.parse_input_event(event_down)
	
	# Release on next frame
	await get_tree().process_frame
	var event_up = InputEventMouseButton.new()
	event_up.button_index = MOUSE_BUTTON_LEFT
	event_up.pressed = false
	Input.parse_input_event(event_up)
