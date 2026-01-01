extends Node
## Ambient Audio Manager
## Handles background ambient sounds with fade transitions and volume control.

# --- Configuration ---
const DEFAULT_VOLUME_DB: float = -10.0
const FADE_DURATION: float = 2.0

# --- Audio Tracks ---
## Add ambient tracks here as constants for easy reference
const TRACK_GRASSLANDS = "res://game/sound/environment/grasslands/calm-garden-ambience-29993.mp3"

# --- Nodes ---
var _player_a: AudioStreamPlayer
var _player_b: AudioStreamPlayer
var _active_player: AudioStreamPlayer
var _tween: Tween

# --- State ---
var _current_track: String = ""
var _master_volume_db: float = DEFAULT_VOLUME_DB
var _is_playing: bool = false


func _ready() -> void:
	# Create two audio players for crossfading
	_player_a = AudioStreamPlayer.new()
	_player_a.bus = "Master"
	add_child(_player_a)
	
	_player_b = AudioStreamPlayer.new()
	_player_b.bus = "Master"
	add_child(_player_b)
	
	_active_player = _player_a
	
	# Auto-start grasslands ambient
	play_ambient(TRACK_GRASSLANDS)
	print("[AMBIENT_AUDIO] Manager initialized")


## Play an ambient track with optional fade-in
func play_ambient(track_path: String, fade_in: bool = true) -> void:
	if track_path == _current_track and _is_playing:
		print("[AMBIENT_AUDIO] Track already playing: ", track_path)
		return
	
	var stream = load(track_path)
	if stream == null:
		push_error("[AMBIENT_AUDIO] Failed to load track: " + track_path)
		return
	
	_current_track = track_path
	
	# If already playing something, crossfade
	if _is_playing:
		_crossfade_to(stream)
	else:
		_start_fresh(stream, fade_in)
	
	_is_playing = true
	print("[AMBIENT_AUDIO] Playing: ", track_path)


## Stop ambient audio with optional fade-out
func stop_ambient(fade_out: bool = true) -> void:
	if not _is_playing:
		return
	
	if _tween:
		_tween.kill()
	
	if fade_out:
		_tween = create_tween()
		_tween.tween_property(_active_player, "volume_db", -80.0, FADE_DURATION)
		_tween.tween_callback(_on_fade_out_complete)
	else:
		_active_player.stop()
		_is_playing = false
	
	print("[AMBIENT_AUDIO] Stopping ambient")


## Set master volume for ambient audio (in dB)
func set_volume(volume_db: float) -> void:
	_master_volume_db = volume_db
	if _is_playing:
		_active_player.volume_db = _master_volume_db
	print("[AMBIENT_AUDIO] Volume set to: ", volume_db, " dB")


## Get current volume (in dB)
func get_volume() -> float:
	return _master_volume_db


## Check if ambient is currently playing
func is_playing() -> bool:
	return _is_playing


## Get current track path
func get_current_track() -> String:
	return _current_track


# --- Internal Methods ---

func _start_fresh(stream: AudioStream, fade_in: bool) -> void:
	_active_player.stream = stream
	
	if fade_in:
		_active_player.volume_db = -80.0
		_active_player.play()
		
		if _tween:
			_tween.kill()
		_tween = create_tween()
		_tween.tween_property(_active_player, "volume_db", _master_volume_db, FADE_DURATION)
	else:
		_active_player.volume_db = _master_volume_db
		_active_player.play()


func _crossfade_to(stream: AudioStream) -> void:
	# Switch to inactive player
	var old_player = _active_player
	_active_player = _player_b if _active_player == _player_a else _player_a
	
	# Setup new track
	_active_player.stream = stream
	_active_player.volume_db = -80.0
	_active_player.play()
	
	# Crossfade
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(old_player, "volume_db", -80.0, FADE_DURATION)
	_tween.tween_property(_active_player, "volume_db", _master_volume_db, FADE_DURATION)
	_tween.set_parallel(false)
	_tween.tween_callback(old_player.stop)


func _on_fade_out_complete() -> void:
	_active_player.stop()
	_is_playing = false
	_current_track = ""
