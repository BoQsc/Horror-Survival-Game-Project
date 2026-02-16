extends Node

const MAIN_SCENE_PATH = "res://modules/world_module/world_test_world_player_v2.tscn"
const LOADING_SCREEN_PATH = "res://modules/world_player_v2/features/ui_loading_screen/loading_screen.tscn"

var loading_screen_instance: Node = null
var _load_complete: bool = false

func _ready() -> void:
	# 1. Instantiate Loading Screen immediately
	if ResourceLoader.exists(LOADING_SCREEN_PATH):
		var packed = load(LOADING_SCREEN_PATH)
		if packed:
			loading_screen_instance = packed.instantiate()
			# Enable manual mode to prevent auto-close logic
			if "manual_mode" in loading_screen_instance:
				loading_screen_instance.manual_mode = true
				
			add_child(loading_screen_instance)
			
			# Configure it for "Resource Loading" mode
			if loading_screen_instance.has_method("update_progress"):
				loading_screen_instance.update_progress(0.0, "Initializing resources...")
	
	# 2. Request Main Scene load in background
	# Use HIGH priority to get it done fast, but it's still threaded so window won't freeze
	var error = ResourceLoader.load_threaded_request(MAIN_SCENE_PATH, "", true)
	if error != OK:
		push_error("[Bootstrap] Failed to start background load of main scene!")
		return
		
	print("[Bootstrap] Background loading started for: ", MAIN_SCENE_PATH)

func _process(_delta: float) -> void:
	if _load_complete:
		return
		
	# 3. Poll status
	var progress = []
	var status = ResourceLoader.load_threaded_get_status(MAIN_SCENE_PATH, progress)
	
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		if loading_screen_instance and loading_screen_instance.has_method("update_progress"):
			var percent = progress[0] * 100.0
			# Cap at 90% because instantiation takes time too
			loading_screen_instance.update_progress(percent * 0.9, "Loading Game resources... %d%%" % int(percent))
			
	elif status == ResourceLoader.THREAD_LOAD_LOADED:
		_load_complete = true
		_on_load_complete()
		
	elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		_load_complete = true
		push_error("[Bootstrap] Loading failed!")
		if loading_screen_instance and loading_screen_instance.has_method("update_progress"):
			loading_screen_instance.update_progress(0.0, "Critical Error: Loading Failed")

func _on_load_complete() -> void:
	if loading_screen_instance and loading_screen_instance.has_method("update_progress"):
		loading_screen_instance.update_progress(95.0, "Constructing World...")
	
	# Allow UI to update before heavy instantiation
	await get_tree().process_frame
	await get_tree().process_frame
	
	var packed = ResourceLoader.load_threaded_get(MAIN_SCENE_PATH)
	if packed:
		var new_scene = packed.instantiate()
		get_tree().root.add_child(new_scene)
		get_tree().current_scene = new_scene
		
		# Move loading screen to new scene so it persists during transition?
		# actually, if we queue_free ourselves, we might lose the screen.
		# But the new scene has its OWN LoadingScreen instance inside it!
		# So we can just destroy ourselves and let the new one take over (or flash).
		# Better: Keep this loading screen until the new scene says it's ready.
		# However, the user's LoadingScreen script logic expects to find managers... 
		# which NOW exist because we added new_scene to root.
		
		print("[Bootstrap] Main scene instantiated. Switching...")
		
		# Cleanup bootstrap
		queue_free()
