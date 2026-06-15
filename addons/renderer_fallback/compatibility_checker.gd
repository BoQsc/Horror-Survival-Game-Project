extends Control
## Pre-loader that tests Vulkan compatibility before loading the game.
## The project is Forward+ Vulkan only; unsupported renderers fail instead of falling back.

@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var progress: ProgressBar = $VBoxContainer/ProgressBar

const UPDATE_CHECK_DISABLED_ENV := "PROJECT_UPDATE_CHECK_DISABLED"
const UPDATE_CHECK_TIMEOUT_LOW_SPEED_LIMIT := "1"
const UPDATE_CHECK_TIMEOUT_LOW_SPEED_TIME := "5"
const UPDATE_STATE_PATH := "user://project_update_state.json"

var _pending_update_info: Dictionary = {}

func _ready():
	if _forbidden_renderer_requested():
		_fail_vulkan_only("Non-Vulkan renderer requested.")
		return

	if not _using_forward_plus():
		_fail_vulkan_only("Forward+ renderer is required.")
		return

	# If running from editor/source checkout, skip exported-build Vulkan preflight
	# but still allow the project updater to check the configured git upstream.
	if _running_from_editor_or_source():
		await _check_for_updates_or_load_game()
		return

	status_label.text = "Testing Vulkan compatibility..."
	progress.value = 30

	# Defer the test to next frame so UI updates.
	await get_tree().process_frame

	if _test_vulkan_compute():
		status_label.text = "Vulkan compute OK"
		progress.value = 100
		await _check_for_updates_or_load_game()
	else:
		status_label.text = "Vulkan compute unavailable. Exiting."
		progress.value = 100
		await get_tree().create_timer(1.0).timeout
		get_tree().quit()

func _forbidden_renderer_requested() -> bool:
	var driver_windows := str(ProjectSettings.get_setting("rendering/rendering_device/driver.windows", "")).to_lower()
	if driver_windows != "" and driver_windows != "vulkan":
		return true

	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for arg in args:
		var lower_arg := str(arg).to_lower()
		if "d3d12" in lower_arg or "direct3d" in lower_arg or "mobile" in lower_arg:
			return true
	return false

func _using_forward_plus() -> bool:
	if not RenderingServer.has_method("get_current_rendering_method"):
		return true
	return str(RenderingServer.call("get_current_rendering_method")) == "forward_plus"

func _test_vulkan_compute() -> bool:
	"""Test if Vulkan supports the marching cubes shader."""
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("[VulkanGuard] Failed to create RenderingDevice")
		return false

	var shader_file = RDShaderFile.new()
	shader_file.set_bytecode(preload("res://world_marching_cubes/marching_cubes.glsl").get_spirv())

	var shader = rd.shader_create_from_spirv(shader_file.get_spirv())
	if not shader.is_valid():
		rd.free()
		return false

	var pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		if shader.is_valid():
			rd.free_rid(shader)
		rd.free()
		return false

	if pipeline.is_valid():
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)
	rd.free()

	return true

func _running_from_editor_or_source() -> bool:
	for arg in OS.get_cmdline_args():
		if str(arg).begins_with("--path"):
			return true
	return false

func _check_for_updates_or_load_game() -> void:
	if not _should_check_project_updates():
		_load_game()
		return

	status_label.text = "Checking for updates..."
	progress.value = 90
	await get_tree().process_frame

	var update_info := _query_git_update_status()
	if bool(update_info.get("update_available", false)):
		_show_update_prompt(update_info)
		return

	_load_game()

func _should_check_project_updates() -> bool:
	if OS.get_environment(UPDATE_CHECK_DISABLED_ENV) == "1":
		return false
	if OS.has_feature("headless") or DisplayServer.get_name().to_lower() == "headless":
		return false
	return _has_git_checkout()

func _has_git_checkout() -> bool:
	var root := _project_root()
	var git_path := root.path_join(".git")
	return DirAccess.dir_exists_absolute(git_path) or FileAccess.file_exists(git_path)

func _query_git_update_status() -> Dictionary:
	var info := {
		"update_available": false,
		"can_update": false,
		"ahead": 0,
		"behind": 0,
		"branch": "",
		"upstream": "",
		"commit": "",
		"reason": ""
	}

	var fetch_result := _run_git(PackedStringArray([
		"-c", "http.lowSpeedLimit=%s" % UPDATE_CHECK_TIMEOUT_LOW_SPEED_LIMIT,
		"-c", "http.lowSpeedTime=%s" % UPDATE_CHECK_TIMEOUT_LOW_SPEED_TIME,
		"fetch", "--prune", "--quiet"
	]))
	if int(fetch_result.get("exit_code", -1)) != 0:
		info["reason"] = "Update check failed: %s" % str(fetch_result.get("output", "")).strip_edges()
		return info

	var branch_result := _run_git(PackedStringArray(["rev-parse", "--abbrev-ref", "HEAD"]))
	if int(branch_result.get("exit_code", -1)) != 0:
		info["reason"] = "Could not read current branch."
		return info
	info["branch"] = str(branch_result.get("output", "")).strip_edges()

	if info["branch"] == "HEAD":
		info["reason"] = "Detached HEAD has no branch upstream."
		return info

	var upstream_result := _run_git(PackedStringArray(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]))
	if int(upstream_result.get("exit_code", -1)) != 0:
		info["reason"] = "Current branch has no upstream."
		return info
	info["upstream"] = str(upstream_result.get("output", "")).strip_edges()

	var commit_result := _run_git(PackedStringArray(["rev-parse", "HEAD"]))
	if int(commit_result.get("exit_code", -1)) == 0:
		info["commit"] = str(commit_result.get("output", "")).strip_edges()

	var count_result := _run_git(PackedStringArray(["rev-list", "--left-right", "--count", "HEAD...@{u}"]))
	if int(count_result.get("exit_code", -1)) != 0:
		info["reason"] = "Could not compare local branch with upstream."
		return info

	var counts := str(count_result.get("output", "")).strip_edges().replace("\t", " ").split(" ", false)
	if counts.size() >= 2:
		info["ahead"] = int(counts[0])
		info["behind"] = int(counts[1])

	if int(info["behind"]) <= 0:
		return info

	info["update_available"] = true

	var status_result := _run_git(PackedStringArray(["status", "--porcelain"]))
	if int(status_result.get("exit_code", -1)) != 0:
		info["reason"] = "Could not inspect working tree."
		return info
	if not str(status_result.get("output", "")).strip_edges().is_empty():
		info["reason"] = "Local changes must be committed or stashed before updating."
		return info
	if int(info["ahead"]) > 0:
		info["reason"] = "Local branch diverged from upstream; fast-forward update is not safe."
		return info

	info["can_update"] = true
	return info

func _show_update_prompt(update_info: Dictionary) -> void:
	_pending_update_info = update_info.duplicate(true)
	status_label.visible = false
	progress.visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	var overlay := ColorRect.new()
	overlay.name = "ProjectUpdatePrompt"
	overlay.color = Color(0.02, 0.025, 0.03, 0.96)
	overlay.anchor_right = 1.0
	overlay.anchor_bottom = 1.0
	add_child(overlay)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(460, 260)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title := Label.new()
	title.text = "Update available"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	box.add_child(title)

	var detail := Label.new()
	detail.text = "%s is %d commit(s) behind %s." % [
		str(update_info.get("branch", "current branch")),
		int(update_info.get("behind", 0)),
		str(update_info.get("upstream", "upstream"))
	]
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(detail)

	var continue_button := Button.new()
	continue_button.text = "Continue"
	continue_button.custom_minimum_size = Vector2(300, 44)
	continue_button.pressed.connect(_load_game)
	box.add_child(continue_button)

	var update_button := Button.new()
	update_button.text = "Update"
	update_button.custom_minimum_size = Vector2(300, 44)
	update_button.disabled = not bool(update_info.get("can_update", false))
	update_button.pressed.connect(_on_update_button_pressed.bind(update_button, continue_button, detail))
	box.add_child(update_button)

	var reason := str(update_info.get("reason", "")).strip_edges()
	if not reason.is_empty():
		var reason_label := Label.new()
		reason_label.text = reason
		reason_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		reason_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(reason_label)

func _on_update_button_pressed(update_button: Button, continue_button: Button, detail: Label) -> void:
	await _apply_project_update(update_button, continue_button, detail)

func _apply_project_update(update_button: Button, continue_button: Button, detail: Label) -> void:
	update_button.disabled = true
	continue_button.disabled = true
	detail.text = "Updating from git..."
	await get_tree().process_frame

	var pull_result := _run_git(PackedStringArray([
		"-c", "http.lowSpeedLimit=%s" % UPDATE_CHECK_TIMEOUT_LOW_SPEED_LIMIT,
		"-c", "http.lowSpeedTime=%s" % UPDATE_CHECK_TIMEOUT_LOW_SPEED_TIME,
		"pull", "--ff-only"
	]))
	if int(pull_result.get("exit_code", -1)) != 0:
		detail.text = "Update failed:\n%s" % str(pull_result.get("output", "")).strip_edges()
		continue_button.disabled = false
		return

	_write_update_state()
	detail.text = "Update applied. Restart the game to use the updated files."
	await get_tree().create_timer(1.5).timeout
	get_tree().quit()

func _write_update_state() -> void:
	var branch := str(_run_git(PackedStringArray(["rev-parse", "--abbrev-ref", "HEAD"])).get("output", "")).strip_edges()
	var commit := str(_run_git(PackedStringArray(["rev-parse", "HEAD"])).get("output", "")).strip_edges()
	var upstream := str(_run_git(PackedStringArray(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])).get("output", "")).strip_edges()
	var metadata := {
		"schema": 1,
		"repo": "BoQsc/gpu-marching-cubes",
		"branch": branch,
		"upstream": upstream,
		"commit": commit,
		"update_method": "git_pull_ff_only",
		"updated_at_unix": Time.get_unix_time_from_system()
	}
	var file := FileAccess.open(UPDATE_STATE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(metadata, "\t"))
		file.close()

func _run_git(args: PackedStringArray) -> Dictionary:
	var full_args := PackedStringArray(["-C", _project_root()])
	full_args.append_array(args)
	var output: Array = []
	var exit_code := OS.execute("git", full_args, output, true, false)
	return {
		"exit_code": exit_code,
		"output": _join_process_output(output)
	}

func _join_process_output(output: Array) -> String:
	var text := ""
	for part in output:
		if not text.is_empty():
			text += "\n"
		text += str(part)
	return text.strip_edges()

func _project_root() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").trim_suffix("\\")

func _fail_vulkan_only(message: String) -> void:
	status_label.text = "Vulkan-only guard blocked startup."
	progress.value = 100
	push_error("=".repeat(80))
	push_error("VULKAN ONLY RENDERING GUARD")
	push_error(message)
	push_error("No fallback renderer will be selected or launched.")
	push_error("=".repeat(80))
	get_tree().quit()

func _load_game():
	"""Load the actual game scene."""
	get_tree().change_scene_to_file.call_deferred("res://modules/world_module/world_test_world_player_v2.tscn")
