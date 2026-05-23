extends CanvasLayer
class_name VegetationDebugOverlay

@export var manager_path: NodePath
@export var update_interval_seconds: float = 0.25
@export var visible_on_start: bool = true

var _manager: Node = null
var _panel: PanelContainer
var _label: Label
var _time_since_update: float = 0.0


func _ready() -> void:
	visible = visible_on_start
	_manager = get_node_or_null(manager_path)
	_build_ui()
	set_process(true)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "VegetationDebugPanel"
	_panel.anchor_left = 0.0
	_panel.anchor_top = 0.0
	_panel.anchor_right = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left = 12.0
	_panel.offset_top = 12.0
	_panel.offset_right = 420.0
	_panel.offset_bottom = 320.0
	add_child(_panel)

	_label = Label.new()
	_label.name = "VegetationDebugLabel"
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_panel.add_child(_label)


func _process(delta: float) -> void:
	_time_since_update += delta
	if _time_since_update < update_interval_seconds:
		return
	_time_since_update = 0.0
	_refresh()


func _refresh() -> void:
	if _manager == null or not is_instance_valid(_manager):
		_manager = get_node_or_null(manager_path)
	if _manager == null:
		_label.text = "Vegetation debug unavailable"
		return
	var telemetry: Dictionary = {}
	if _manager.has_method("get_telemetry_snapshot"):
		telemetry = _manager.get_telemetry_snapshot()
	var renderer_stats: Dictionary = telemetry.get("renderer", {})
	var text_lines: Array[String] = []
	text_lines.append("Vegetation Runtime")
	text_lines.append("profile: %s" % str(telemetry.get("profile", "")))
	text_lines.append("ready: %s  bootstrapped: %s" % [
		"yes" if bool(telemetry.get("ready", false)) else "no",
		"yes" if bool(telemetry.get("bootstrapped", false)) else "no"
	])
	text_lines.append("chunks: live=%d dirty=%d total=%d pending=%d" % [
		int(telemetry.get("live_chunk_count", 0)),
		int(telemetry.get("dirty_chunk_count", 0)),
		int(telemetry.get("chunk_count", 0)),
		int(telemetry.get("pending_chunk_count", 0))
	])
	text_lines.append("regrowth chunks: %d" % int(telemetry.get("regrowth_chunk_count", 0)))
	text_lines.append("coverage: %.0fm / %.1f render chunks" % [
		float(telemetry.get("vegetation_coverage_radius_world", 0.0)),
		float(telemetry.get("vegetation_coverage_render_distance_equivalent", 0.0))
	])
	text_lines.append("grass: visible=%d cells=%d chunk_batches=%d" % [
		int(telemetry.get("global_grass_render_instances", 0)),
		int(telemetry.get("grass_cell_count", 0)),
		int(telemetry.get("global_chunk_mesh_render_batch_count", 0))
	])
	text_lines.append("trees: visible=%d records=%d  bushes=%d" % [
		int(telemetry.get("global_tree_render_instances", 0)),
		int(telemetry.get("tree_record_count", 0)),
		int(telemetry.get("bush_record_count", 0))
	])
	text_lines.append("rocks: %d  support points: %d" % [
		int(telemetry.get("rock_record_count", 0)),
		int(telemetry.get("support_points_total", 0))
	])
	text_lines.append("RIDs: mesh=%d instance=%d total=%d free=%d" % [
		int(renderer_stats.get("chunk_mesh_count", 0)),
		int(renderer_stats.get("chunk_instance_count", 0)) + int(renderer_stats.get("individual_instance_count", 0)),
		int(renderer_stats.get("render_rid_count", 0)),
		int(renderer_stats.get("free_count", 0))
	])
	text_lines.append("native: builder=%s grid=%s grass_source=%s %.2f ms" % [
		"yes" if bool(telemetry.get("native_chunk_builder_active", false)) else "no",
		"yes" if bool(telemetry.get("native_spatial_grid_active", false)) else "no",
		"yes" if bool(telemetry.get("use_grass_source_meshes", false)) else "no",
		float(telemetry.get("last_native_grass_build_time_ms", 0.0))
	])
	text_lines.append("last rebuild: %.2f ms" % float(telemetry.get("last_rebuild_time_ms", 0.0)))
	text_lines.append("last support: %.2f ms" % float(telemetry.get("last_support_refresh_time_ms", 0.0)))
	text_lines.append("last gen: %.2f ms" % float(telemetry.get("last_generation_time_ms", 0.0)))
	text_lines.append("focus chunk: %s" % str(telemetry.get("last_focus_chunk", "")))
	text_lines.append("carves: %d" % int(telemetry.get("mock_terrain_carve_count", 0)))
	_label.text = "\n".join(text_lines)
