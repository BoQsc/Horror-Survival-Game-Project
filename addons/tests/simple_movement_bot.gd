extends Node
## Simple movement bot - uses input actions to move player

var move_timer = 0.0
var current_action = ""

func _ready():
	print("[BOT] Starting movement test...")
	await get_tree().create_timer(3.0).timeout
	print("[BOT] Game loaded, starting movement")

func _process(delta):
	move_timer += delta
	
	var new_action = ""
	
	if move_timer < 5.0:
		new_action = "move_forward"
		if current_action != new_action:
			print("[BOT] Moving FORWARD")
	elif move_timer < 10.0:
		new_action = "move_left"
		if current_action != new_action:
			print("[BOT] Moving LEFT")
	elif move_timer < 15.0:
		new_action = "move_backward"
		if current_action != new_action:
			print("[BOT] Moving BACKWARD")
	elif move_timer < 20.0:
		new_action = "move_right"
		if current_action != new_action:
			print("[BOT] Moving RIGHT")
	else:
		if current_action != "":
			Input.action_release(current_action)
			current_action = ""
		print("[BOT] 20-second movement test complete!")
		get_tree().quit()
		return
	
	# Handle action changes
	if new_action != current_action:
		# Release old action
		if current_action != "":
			Input.action_release(current_action)
		# Press new action
		if new_action != "":
			Input.action_press(new_action)
		current_action = new_action
