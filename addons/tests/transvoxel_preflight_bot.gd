extends Node

const CHECKS := [
	"res://world_marching_cubes/chunk_manager.gd",
	"res://modules/world_player_v2/features/ui_hud/player_hud.gd",
	"res://world_marching_cubes/transvoxel_layout.gd"
]

func _ready() -> void:
	print("[TRANSVOXEL_PREFLIGHT] Starting parser preflight")
	call_deferred("_run_checks")


func _run_checks() -> void:
	for path in CHECKS:
		var resource := load(path)
		if resource == null:
			print("[TRANSVOXEL_PREFLIGHT] ERROR: failed to load %s" % path)
			get_tree().quit(1)
			return
		print("[TRANSVOXEL_PREFLIGHT] OK: %s" % path)

	if not ClassDB.class_exists("MeshBuilder"):
		print("[TRANSVOXEL_PREFLIGHT] ERROR: MeshBuilder class not available")
		get_tree().quit(1)
		return

	var builder := ClassDB.instantiate("MeshBuilder")
	if builder == null:
		print("[TRANSVOXEL_PREFLIGHT] ERROR: failed to instantiate MeshBuilder")
		get_tree().quit(1)
		return

	print("[TRANSVOXEL_PREFLIGHT] OK: MeshBuilder instantiation")
	print("[TRANSVOXEL_PREFLIGHT] Preflight passed")
	get_tree().quit(0)
