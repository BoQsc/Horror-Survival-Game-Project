extends Node

func _ready():
	print("[MINIMAL_BOT] Bot _ready() called!")
	print("[MINIMAL_BOT] Starting 3-second countdown...")
	await get_tree().create_timer(1.0).timeout
	print("[MINIMAL_BOT] 1...")
	await get_tree().create_timer(1.0).timeout
	print("[MINIMAL_BOT] 2...")
	await get_tree().create_timer(1.0).timeout
	print("[MINIMAL_BOT] 3...  done!")
	print("[MINIMAL_BOT] Quitting...")
	get_tree().quit()
