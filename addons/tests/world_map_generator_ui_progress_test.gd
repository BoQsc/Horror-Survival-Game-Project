extends SceneTree

const UI_SCENE := preload("res://world_map_generator/world_map_generator_ui.tscn")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var ui := UI_SCENE.instantiate()
	if not _bind_scene_nodes(ui):
		ui.free()
		return 1

	ui.generation_placeholder_size = 64
	ui.terrain_mesh_bake_refresh_world_list_on_complete = false
	ui._set_generation_status("Ready - configure and generate world", 0.0, true)
	if not _expect(ui.canvas.texture != null, "ready state should show a non-gray placeholder texture"):
		ui.free()
		return 1
	var ready_snapshot: Dictionary = ui.get_telemetry_snapshot()
	if not _expect(str(ready_snapshot.get("last_generation_status", "")).begins_with("Ready"), "ready telemetry should expose generation status"):
		ui.free()
		return 1

	ui.last_generation_preview_ready = false
	ui._set_generation_status("Preparing native world-map preview", 5.0, true)
	if not _expect(ui.canvas.texture != null, "generation status should draw a placeholder texture"):
		ui.free()
		return 1
	if not _expect(ui.canvas.texture.get_width() == 64, "placeholder texture should use configured test size"):
		ui.free()
		return 1
	if not _expect(str(ui.progress_label.text).contains("Preparing native world-map preview"), "progress label should describe the active stage"):
		ui.free()
		return 1
	var progress_snapshot: Dictionary = ui.get_telemetry_snapshot()
	if not _expect(str(progress_snapshot.get("last_generation_status", "")) == "Preparing native world-map preview", "progress telemetry should retain the current stage"):
		ui.free()
		return 1
	if not _expect(not bool(progress_snapshot.get("last_generation_preview_ready", true)), "placeholder stage should report preview not ready"):
		ui.free()
		return 1
	var overlay_snapshot: Dictionary = progress_snapshot.get("generation_loading_overlay", {})
	if not _expect(not overlay_snapshot.is_empty(), "generation telemetry should expose the loading overlay snapshot"):
		ui.free()
		return 1
	if not _expect(bool(overlay_snapshot.get("visible", false)), "active generation status should show the loading overlay"):
		ui.free()
		return 1
	if not _expect(str(overlay_snapshot.get("stage", "")).contains("Preparing native world-map preview"), "loading overlay should report active generation stage"):
		ui.free()
		return 1

	ui.is_generating = true
	var preview_images := _preview_images(32)
	preview_images["preview_generation_profile"] = {
		"success": true,
		"backend": "native",
		"output_size": 32,
		"pixel_count": 32 * 32,
		"total_ms": 1.0
	}
	ui._on_generation_preview_ready(preview_images)
	if not _expect(ui.last_generation_preview_ready, "low-resolution preview should mark preview ready"):
		ui.free()
		return 1
	if not _expect(ui.canvas.texture != null and ui.canvas.texture.get_width() == 32, "low-resolution preview should replace the placeholder texture"):
		ui.free()
		return 1
	if not _expect(ui.last_generation_backend == "native", "preview backend should be surfaced in UI telemetry"):
		ui.free()
		return 1
	if not _expect(str(ui.progress_label.text).contains("native"), "preview-ready status should show backend"):
		ui.free()
		return 1
	var preview_snapshot: Dictionary = ui.get_telemetry_snapshot()
	if not _expect(str(preview_snapshot.get("last_preview_backend", "")) == "low_resolution_generation", "preview telemetry should record low-resolution backend"):
		ui.free()
		return 1

	ui.current_images["towns"] = [
		{"x": 0.0, "z": 0.0, "terrain_y": 4.0, "radius": 90.0, "building_count": 10, "score": 0.1},
		{"x": 310.0, "z": -155.0, "terrain_y": 8.0, "radius": 110.0, "building_count": 60, "score": 0.9},
		{"x": -155.0, "z": 310.0, "terrain_y": 7.0, "radius": 105.0, "building_count": 40, "score": 0.7}
	]
	ui.terrain_mesh_bake_include_origin = true
	ui.terrain_mesh_bake_include_town_centers = true
	ui.terrain_mesh_bake_max_town_centers = 2
	var bake_origins: Array[Vector3] = ui._build_terrain_mesh_bake_origins()
	if not _expect(bake_origins.size() == 3, "terrain bake origins should include origin plus the top configured town centers"):
		ui.free()
		return 1
	if not _expect(bake_origins[1].x == 310.0 and bake_origins[1].z == -155.0, "terrain bake origins should prioritize the largest generated towns"):
		ui.free()
		return 1
	var default_full_map_coords: Array[Vector3i] = ui._build_terrain_mesh_full_map_bake_coords()
	if not _expect(default_full_map_coords.is_empty(), "full-map terrain bake should be opt-in, not the default startup gate"):
		ui.free()
		return 1
	var full_map_snapshot: Dictionary = ui.get_telemetry_snapshot()
	if not _expect(not bool(full_map_snapshot.get("terrain_mesh_bake_full_map_enabled", true)), "UI telemetry should expose startup-scope terrain bake mode"):
		ui.free()
		return 1
	ui.terrain_mesh_bake_full_map_enabled = true
	var full_map_coords: Array[Vector3i] = ui._build_terrain_mesh_full_map_bake_coords()
	if not _expect(full_map_coords.size() >= 4000, "explicit full-map terrain bake should still cover thousands of map chunks"):
		ui.free()
		return 1

	ui.generate_btn = ui.get_node_or_null("TopBar/GenerateBtn")
	ui.save_btn = ui.get_node_or_null("TopBar/SaveBtn")
	ui.play_btn = ui.get_node_or_null("TopBar/PlayBtn")
	if not _expect(ui.generate_btn != null and ui.save_btn != null and ui.play_btn != null, "UI scene should expose bake-gated buttons"):
		ui.free()
		return 1
	ui.is_baking_terrain = true
	ui._on_terrain_bake_progress({
		"stage": "baking terrain mesh artifacts",
		"progress_percent": 25.0,
		"artifact_count": 9,
		"stored_artifact_count": 7,
		"reused_disk_artifact_count": 2,
		"expected_chunks": 27,
		"coord_mode": "explicit",
		"explicit_coord_count": 4096,
		"origin_count": 3,
		"artifact_root": "user://worlds/test_world/terrain_artifacts"
	})
	if not _expect(str(ui.progress_label.text).contains("Terrain Mesh Artifacts"), "terrain bake progress should describe the active mesh-artifact stage"):
		ui.free()
		return 1
	if not _expect(str(ui.progress_label.text).contains("coords=4096"), "terrain bake progress should report explicit full-map coordinate coverage"):
		ui.free()
		return 1
	if not _expect(str(ui.progress_label.text).contains("terrain_artifacts=9/27"), "terrain bake progress should separate baked chunk progress from cache reuse"):
		ui.free()
		return 1
	if not _expect(str(ui.progress_label.text).contains("stored_new=7"), "terrain bake progress should report newly stored artifacts"):
		ui.free()
		return 1
	if not _expect(str(ui.progress_label.text).contains("reused_disk=2"), "terrain bake progress should report reused disk artifacts separately"):
		ui.free()
		return 1
	var bake_progress_snapshot: Dictionary = ui.get_telemetry_snapshot()
	if not _expect(bool(bake_progress_snapshot.get("is_baking_terrain", false)), "UI telemetry should expose active terrain bake"):
		ui.free()
		return 1
	var bake_profile: Dictionary = bake_progress_snapshot.get("last_terrain_bake_profile", {})
	if not _expect(int(bake_profile.get("artifact_count", 0)) == 9, "UI telemetry should retain terrain bake artifact progress"):
		ui.free()
		return 1
	var bake_overlay_snapshot: Dictionary = bake_progress_snapshot.get("generation_loading_overlay", {})
	if not _expect(bool(bake_overlay_snapshot.get("visible", false)), "terrain bake should show the loading overlay"):
		ui.free()
		return 1
	var bake_overlay_details_variant: Variant = bake_overlay_snapshot.get("details", {})
	var bake_overlay_details: Dictionary = bake_overlay_details_variant if bake_overlay_details_variant is Dictionary else {}
	if not _expect(int(bake_overlay_details.get("artifact_count", 0)) == 9, "loading overlay should expose terrain artifact count"):
		ui.free()
		return 1
	var bake_overlay_detail_text := str(bake_overlay_snapshot.get("detail_text", ""))
	if not _expect(bake_overlay_detail_text.contains("terrain_artifacts=9/27"), "loading overlay should label terrain artifact progress explicitly"):
		ui.free()
		return 1
	if not _expect(bake_overlay_detail_text.contains("stored_new=7"), "loading overlay should label new artifact stores explicitly"):
		ui.free()
		return 1
	if not _expect(bake_overlay_detail_text.contains("reused_disk=2"), "loading overlay should label disk artifact reuse explicitly"):
		ui.free()
		return 1

	ui._on_terrain_bake_completed({
		"artifact_root": "user://worlds/test_world/terrain_artifacts",
		"artifact_count": 27,
		"expected_chunks": 27,
		"stored_artifact_count": 24,
		"reused_disk_artifact_count": 3,
		"coord_mode": "explicit",
		"explicit_coord_count": 4096,
		"origin_count": 3,
		"elapsed_ms": 123.0
	})
	if not _expect(not ui.is_baking_terrain, "terrain bake completion should clear active bake state"):
		ui.free()
		return 1
	if not _expect(not ui.play_btn.disabled, "terrain bake completion should enable play"):
		ui.free()
		return 1
	if not _expect(str(ui.progress_label.text).contains("baked 27 terrain mesh artifacts"), "completion label should report baked mesh artifacts"):
		ui.free()
		return 1
	if not _expect(str(ui.progress_label.text).contains("stored_new=24"), "completion label should report newly stored artifacts"):
		ui.free()
		return 1
	if not _expect(str(ui.progress_label.text).contains("reused_disk=3"), "completion label should report reused disk artifacts separately"):
		ui.free()
		return 1
	var bake_complete_overlay_snapshot: Dictionary = ui.get_telemetry_snapshot().get("generation_loading_overlay", {})
	if not _expect(not bool(bake_complete_overlay_snapshot.get("visible", true)), "terrain bake completion should hide the loading overlay"):
		ui.free()
		return 1
	if not _expect(str(bake_complete_overlay_snapshot.get("stage", "")).contains("baked 27 terrain mesh artifacts"), "hidden loading overlay should retain the completed stage for telemetry"):
		ui.free()
		return 1

	ui.free()
	print("[WORLD_MAP_GENERATOR_UI_PROGRESS_TEST] PASS")
	return 0


func _bind_scene_nodes(ui: Node) -> bool:
	ui.canvas = ui.get_node_or_null("HSplit/CanvasPanel/Canvas")
	ui.progress_bar = ui.get_node_or_null("TopBar/ProgressBar")
	ui.progress_label = ui.get_node_or_null("TopBar/ProgressLabel")
	ui.seed_input = ui.get_node_or_null("HSplit/SettingsPanel/VBox/SeedRow/SeedInput")
	ui.world_list = ui.get_node_or_null("HSplit/SettingsPanel/VBox/WorldList")
	if not _expect(ui.canvas != null, "UI scene should expose Canvas TextureRect"):
		return false
	if not _expect(ui.progress_bar != null, "UI scene should expose ProgressBar"):
		return false
	if not _expect(ui.progress_label != null, "UI scene should expose ProgressLabel"):
		return false
	if not _expect(ui.seed_input != null, "UI scene should expose SeedInput"):
		return false
	if not _expect(ui.world_list != null, "UI scene should expose WorldList"):
		return false
	ui.seed_input.value = 12345
	return true


func _preview_images(size: int) -> Dictionary:
	var total := size * size
	var height_bytes := PackedByteArray()
	height_bytes.resize(total)
	var biome_bytes := PackedByteArray()
	biome_bytes.resize(total)
	for i in range(total):
		height_bytes[i] = int(i % 255)
		biome_bytes[i] = 0
	return {
		"heightmap": Image.create_from_data(size, size, false, Image.FORMAT_R8, height_bytes),
		"biomes": Image.create_from_data(size, size, false, Image.FORMAT_R8, biome_bytes)
	}


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	printerr("[WORLD_MAP_GENERATOR_UI_PROGRESS_TEST] FAIL: %s" % message)
	return false
