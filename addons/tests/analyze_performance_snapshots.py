import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

import run_town_stall_test as town_runner


PROJECT_PATH = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = PROJECT_PATH / ".agent" / "performance-snapshot-analysis.json"
DEFAULT_RENDER_ABLATION_SUMMARY = PROJECT_PATH / ".agent" / "render-ablation-summary.json"
DEFAULT_GPU_TELEMETRY_DIR = PROJECT_PATH / ".agent" / "gpu-telemetry"
DEFAULT_STABLE_60_MAX_OVER_BUDGET_PCT = 5.0
DEFAULT_STABLE_60_MAX_FRAME_MS = 40.0
DEFAULT_STABLE_60_MAX_FRAMES_OVER_40MS = 0
DEFAULT_STABLE_60_MAX_OVER_BUDGET_STREAK = 5
DEFAULT_MOVEMENT_60_MAX_OVER_BUDGET_PCT = 10.0
DEFAULT_MOVEMENT_60_MAX_FRAME_MS = 45.0
DEFAULT_MOVEMENT_60_MAX_FRAMES_OVER_50MS = 0
DEFAULT_MOVEMENT_MIN_SAMPLES = 600
DEFAULT_MOVEMENT_MIN_GPU_SAMPLES = 5
DEFAULT_STATIONARY_GPU_MIN_SAMPLES = 5
DEFAULT_IDLE_GPU_MIN_SAMPLES = 3
DEFAULT_PRODUCTION_MIN_HOLD_SECONDS = 20.0
FRAME_BUDGET_EPSILON_MS = 0.05
MOVEMENT_CAPTURE_REASONS = {"full_flight", "auto_fly_entry", "repeat_entry_second"}


def _read_json(path: Path) -> dict[str, Any]:
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"error": repr(exc), "path": str(path)}
    return parsed if isinstance(parsed, dict) else {"error": "root JSON value is not an object", "path": str(path)}


def _latest_files(root: Path, pattern: str, count: int) -> list[Path]:
    if not root.exists():
        return []
    candidates = [path for path in root.glob(pattern) if path.is_file()]
    return sorted(candidates, key=lambda path: path.stat().st_mtime, reverse=True)[:count]


def _float(value: Any, default: float = 0.0) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value))
    except (TypeError, ValueError):
        return default


def _int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return default


def _dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _round(value: float) -> float:
    return round(value, 3)


def _format_optional_float(value: Any, available: bool, precision: int = 1) -> str:
    if not available:
        return "n/a"
    return f"{_float(value):.{precision}f}"


def _format_optional_int(value: Any, available: bool) -> str:
    if not available:
        return "n/a"
    return str(_int(value))


def _has_samples(summary: dict[str, Any]) -> bool:
    return _int(summary.get("sample_count")) > 0


def _age_hours(modified_epoch: Any, reference_epoch: float) -> float:
    modified = _float(modified_epoch, 0.0)
    if modified <= 0.0:
        return 0.0
    return max(0.0, (reference_epoch - modified) / 3600.0)


def _window_summary(window: dict[str, Any], target_frame_ms: float) -> dict[str, Any]:
    sample_count = _int(window.get("sample_count"))
    frames_over_budget = _int(window.get("frames_over_budget"))
    longest_over_budget_streak = _int(window.get("longest_over_budget_streak"))
    stall_over_budget_ms = _float(window.get("stall_over_budget_ms"))
    avg_over_budget_ms = stall_over_budget_ms / float(sample_count) if sample_count > 0 else 0.0
    if "stall_over_budget_ms" in window and avg_over_budget_ms <= FRAME_BUDGET_EPSILON_MS:
        frames_over_budget = 0
        longest_over_budget_streak = 0
    render_active_samples = _int(window.get("render_active_sample_count"))
    return {
        "sample_count": sample_count,
        "render_active_sample_count": render_active_samples,
        "avg_fps": _round(_float(window.get("avg_fps"))),
        "avg_total_ms": _round(_float(window.get("avg_total_ms"))),
        "max_total_ms": _round(_float(window.get("max_total_ms"))),
        "frames_over_budget": frames_over_budget,
        "frames_over_budget_pct": _round((float(frames_over_budget) / float(sample_count)) * 100.0) if sample_count > 0 else 0.0,
        "stall_over_budget_ms": _round(stall_over_budget_ms),
        "frames_over_40ms": _int(window.get("frames_over_40ms")),
        "frames_over_50ms": _int(window.get("frames_over_50ms")),
        "longest_over_budget_streak": longest_over_budget_streak,
        "avg_draw_calls": _round(_float(window.get("avg_draw_calls"))),
        "avg_objects": _round(_float(window.get("avg_objects"))),
        "has_primitive_metrics": "avg_primitives" in window,
        "avg_primitives": _round(_float(window.get("avg_primitives"))),
        "has_pipeline_metrics": "pipeline_compilations_total_delta" in window,
        "pipeline_compilations_canvas_delta": _int(window.get("pipeline_compilations_canvas_delta")),
        "pipeline_compilations_mesh_delta": _int(window.get("pipeline_compilations_mesh_delta")),
        "pipeline_compilations_surface_delta": _int(window.get("pipeline_compilations_surface_delta")),
        "pipeline_compilations_draw_delta": _int(window.get("pipeline_compilations_draw_delta")),
        "pipeline_compilations_specialization_delta": _int(window.get("pipeline_compilations_specialization_delta")),
        "pipeline_compilations_total_delta": _int(window.get("pipeline_compilations_total_delta")),
        "stable_top_bucket": str(window.get("stable_top_bucket", "")),
        "peak_top_bucket": str(window.get("peak_top_bucket", "")),
        "stable_60_average": _float(window.get("avg_total_ms")) <= target_frame_ms,
        "render_loop_suspended_samples": _int(window.get("terrain_runtime_power_render_loop_suspended_samples")),
        "world_work_suspended_samples": _int(window.get("terrain_runtime_power_world_work_suspended_samples")),
    }


def _phase_gpu_summary(window: dict[str, Any]) -> dict[str, Any]:
    power = _dict(window.get("raw_gpu_power_w"))
    temp = _dict(window.get("raw_gpu_temp_c"))
    util = _dict(window.get("raw_gpu_util_percent"))
    pstates = _dict(window.get("raw_gpu_pstates"))
    raw_gpu_count = _int(window.get("raw_gpu_available_count"), _int(power.get("count")))
    p0_count = _int(pstates.get("P0"))
    return {
        "available": bool(window.get("available", False)),
        "sample_count": _int(window.get("sample_count")),
        "raw_gpu_available_count": raw_gpu_count,
        "power_sample_count": _int(power.get("count")),
        "avg_power_w": _round(_float(power.get("avg"))),
        "max_power_w": _round(_float(power.get("max"))),
        "avg_temp_c": _round(_float(temp.get("avg"))),
        "max_temp_c": _round(_float(temp.get("max"))),
        "avg_gpu_util_pct": _round(_float(util.get("avg"))),
        "max_gpu_util_pct": _round(_float(util.get("max"))),
        "p0_count": p0_count,
        "p0_fraction": _round(float(p0_count) / float(raw_gpu_count)) if raw_gpu_count > 0 else 0.0,
        "pstates": pstates,
    }


def _town_capture_reason(snapshot: dict[str, Any]) -> str:
    direct = str(snapshot.get("town_entry_capture_reason", "")).strip()
    if direct:
        return direct

    for event in _list(snapshot.get("recent_scope_events")):
        if not isinstance(event, dict):
            continue
        if str(event.get("scope", "")) != "town_stall_test":
            continue
        if str(event.get("label", "")) != "measurement_reset":
            continue
        details = _dict(event.get("details"))
        reason = str(details.get("reason", "")).strip()
        if reason:
            return reason
    return ""


def _summarize_town_snapshot(path: Path, target_frame_ms: float) -> dict[str, Any]:
    snapshot = _read_json(path)
    stationary_hold = _dict(snapshot.get("stationary_hold_window"))
    moving_entry = _dict(snapshot.get("moving_entry_window"))
    town_entry = _dict(snapshot.get("town_entry_window"))
    system_sample_summary = _dict(snapshot.get("system_sample_summary"))
    phase_windows = _dict(system_sample_summary.get("phase_windows"))
    machine_state = _dict(snapshot.get("machine_state"))
    preflight_idle = _dict(machine_state.get("preflight_idle_summary"))
    render_features = _dict(snapshot.get("render_features"))
    render_diagnostics = _dict(snapshot.get("render_diagnostics"))
    final_scene_scan = _dict(render_diagnostics.get("final_scene_scan"))
    telemetry = _dict(snapshot.get("system_telemetry"))
    terrain = _dict(telemetry.get("terrain_manager"))
    building = _dict(telemetry.get("building_manager"))
    prefab = _dict(telemetry.get("prefab_spawner"))
    vegetation = _dict(telemetry.get("vegetation_manager"))
    entities = _dict(telemetry.get("entity_manager"))
    render_distance = _int(terrain.get("render_distance"))
    lod_distance = _int(terrain.get("distant_world_map_lod_distance"))
    lod_overlap = _int(terrain.get("distant_world_map_lod_overlap"))
    lod_inner_distance = max(render_distance - lod_overlap, 0)
    return {
        "path": str(path),
        "modified_epoch": path.stat().st_mtime,
        "runtime_mode": str(snapshot.get("runtime_mode", "")),
        "hold_complete": bool(snapshot.get("benchmark_hold_complete", False)),
        "hold_seconds": _float(snapshot.get("benchmark_hold_seconds")),
        "hold_settle_elapsed_seconds": _round(_float(snapshot.get("hold_settle_elapsed_seconds"))),
        "hold_settle_stable_frames": _int(snapshot.get("hold_settle_stable_frames")),
        "hold_settle_timed_out": bool(snapshot.get("hold_settle_timed_out", False)),
        "town_entry_capture_reason": _town_capture_reason(snapshot),
        "system_sample_summary_available": bool(system_sample_summary),
        "machine_state": {
            "load_percentage": _float(machine_state.get("load_percentage")),
            "percent_processor_utility": _float(machine_state.get("percent_processor_utility")),
            "preflight_cpu_load_median_percent": _float(preflight_idle.get("cpu_load_median_percent")),
            "preflight_raw_gpu_power_median_w": _float(preflight_idle.get("raw_gpu_power_median_w")),
            "preflight_raw_gpu_util_median_percent": _float(preflight_idle.get("raw_gpu_util_median_percent")),
        },
        "render_features": {
            "rendering_method": str(render_features.get("rendering_method", "")),
            "rendering_driver_name": str(render_features.get("rendering_driver_name", "")),
            "project_rendering_method": str(render_features.get("project_rendering_method", "")),
            "project_rendering_driver_windows": str(render_features.get("project_rendering_driver_windows", "")),
            "project_fallback_to_d3d12": bool(render_features.get("project_fallback_to_d3d12", False)),
            "project_fallback_to_opengl3": bool(render_features.get("project_fallback_to_opengl3", False)),
            "vulkan_only_expected": bool(render_features.get("vulkan_only_expected", False)),
            "display_telemetry_available": "runtime_window_mode" in render_features,
            "project_window_mode": _int(render_features.get("project_window_mode"), -1),
            "runtime_window_mode": _int(render_features.get("runtime_window_mode"), -1),
            "runtime_window_width": _int(render_features.get("runtime_window_width"), -1),
            "runtime_window_height": _int(render_features.get("runtime_window_height"), -1),
            "runtime_screen_width": _int(render_features.get("runtime_screen_width"), -1),
            "runtime_screen_height": _int(render_features.get("runtime_screen_height"), -1),
            "project_vsync_mode": _int(render_features.get("project_vsync_mode"), -1),
            "runtime_vsync_mode": _int(render_features.get("runtime_vsync_mode"), -1),
        },
        "render_scene": {
            "available": bool(final_scene_scan),
            "visible_mesh_instances": _int(final_scene_scan.get("visible_mesh_instances")),
            "visible_mesh_surface_count": _int(final_scene_scan.get("visible_mesh_surface_count")),
            "visible_mesh_vertex_count": _int(final_scene_scan.get("visible_mesh_vertex_count")),
            "visible_mesh_index_count": _int(final_scene_scan.get("visible_mesh_index_count")),
            "visible_mesh_triangle_count": _int(final_scene_scan.get("visible_mesh_triangle_count")),
            "visible_terrain_mesh_vertex_count": _int(final_scene_scan.get("visible_terrain_mesh_vertex_count")),
            "visible_terrain_mesh_index_count": _int(final_scene_scan.get("visible_terrain_mesh_index_count")),
            "visible_terrain_mesh_triangle_count": _int(final_scene_scan.get("visible_terrain_mesh_triangle_count")),
            "visible_building_mesh_vertex_count": _int(final_scene_scan.get("visible_building_mesh_vertex_count")),
            "visible_building_mesh_index_count": _int(final_scene_scan.get("visible_building_mesh_index_count")),
            "visible_building_mesh_triangle_count": _int(final_scene_scan.get("visible_building_mesh_triangle_count")),
            "visible_vegetation_mesh_vertex_count": _int(final_scene_scan.get("visible_vegetation_mesh_vertex_count")),
            "visible_vegetation_mesh_index_count": _int(final_scene_scan.get("visible_vegetation_mesh_index_count")),
            "visible_vegetation_mesh_triangle_count": _int(final_scene_scan.get("visible_vegetation_mesh_triangle_count")),
            "visible_multimesh_instances": _int(final_scene_scan.get("visible_multimesh_instances")),
            "visible_multimesh_instance_count": _int(final_scene_scan.get("visible_multimesh_instance_count")),
            "visible_multimesh_rendered_vertex_count": _int(final_scene_scan.get("visible_multimesh_rendered_vertex_count")),
            "visible_multimesh_rendered_index_count": _int(final_scene_scan.get("visible_multimesh_rendered_index_count")),
            "visible_multimesh_rendered_triangle_count": _int(final_scene_scan.get("visible_multimesh_rendered_triangle_count")),
            "frustum_mesh_instances": _int(final_scene_scan.get("frustum_mesh_instances")),
            "frustum_mesh_vertex_count": _int(final_scene_scan.get("frustum_mesh_vertex_count")),
            "frustum_mesh_triangle_count": _int(final_scene_scan.get("frustum_mesh_triangle_count")),
            "frustum_terrain_mesh_vertex_count": _int(final_scene_scan.get("frustum_terrain_mesh_vertex_count")),
            "frustum_terrain_mesh_triangle_count": _int(final_scene_scan.get("frustum_terrain_mesh_triangle_count")),
            "frustum_building_mesh_vertex_count": _int(final_scene_scan.get("frustum_building_mesh_vertex_count")),
            "frustum_building_mesh_triangle_count": _int(final_scene_scan.get("frustum_building_mesh_triangle_count")),
            "frustum_vegetation_mesh_vertex_count": _int(final_scene_scan.get("frustum_vegetation_mesh_vertex_count")),
            "frustum_vegetation_mesh_triangle_count": _int(final_scene_scan.get("frustum_vegetation_mesh_triangle_count")),
            "frustum_multimesh_instances": _int(final_scene_scan.get("frustum_multimesh_instances")),
            "frustum_multimesh_instance_count": _int(final_scene_scan.get("frustum_multimesh_instance_count")),
            "frustum_multimesh_rendered_vertex_count": _int(final_scene_scan.get("frustum_multimesh_rendered_vertex_count")),
            "frustum_multimesh_rendered_triangle_count": _int(final_scene_scan.get("frustum_multimesh_rendered_triangle_count")),
            "frustum_vegetation_multimesh_rendered_triangle_count": _int(
                final_scene_scan.get("frustum_vegetation_multimesh_rendered_triangle_count")
            ),
        },
        "stationary_hold": _window_summary(stationary_hold, target_frame_ms),
        "moving_entry": _window_summary(moving_entry, target_frame_ms),
        "moving_entry_gpu": _phase_gpu_summary(_dict(phase_windows.get("moving_entry"))),
        "stationary_hold_gpu": _phase_gpu_summary(_dict(phase_windows.get("stationary_hold"))),
        "runtime_power_deep_idle_gpu": _phase_gpu_summary(_dict(phase_windows.get("runtime_power_deep_idle"))),
        "runtime_power_render_loop_suspended_gpu": _phase_gpu_summary(
            _dict(phase_windows.get("runtime_power_render_loop_suspended"))
        ),
        "runtime_power_render_loop_suspended_tail_10s_gpu": _phase_gpu_summary(
            _dict(phase_windows.get("runtime_power_render_loop_suspended_tail_10s"))
        ),
        "town_entry": _window_summary(town_entry, target_frame_ms),
        "terrain": {
            "world_map_active": bool(terrain.get("world_map_active", False)),
            "runtime_power_mode": str(terrain.get("runtime_power_mode", "")),
            "runtime_power_target_fps": _int(terrain.get("runtime_power_target_fps")),
            "render_distance": render_distance,
            "active_chunk_count": _int(terrain.get("active_chunk_count")),
            "loaded_chunk_count": _int(terrain.get("loaded_chunk_count")),
            "rendered_terrain_chunk_count": _int(terrain.get("rendered_terrain_chunk_count")),
            "individual_terrain_visible_chunk_count": _int(terrain.get("individual_terrain_visible_chunk_count")),
            "full_res_terrain_drawn_chunk_count": _int(
                terrain.get("full_res_terrain_drawn_chunk_count", terrain.get("rendered_terrain_chunk_count"))
            ),
            "rendered_water_chunk_count": _int(terrain.get("rendered_water_chunk_count")),
            "world_map_lod_chunk_count": _int(terrain.get("world_map_lod_chunk_count")),
            "world_map_lod_node_count": _int(terrain.get("world_map_lod_node_count")),
            "distant_world_map_lod_enabled": bool(terrain.get("distant_world_map_lod_enabled", False)),
            "distant_world_map_lod_defer_until_initial_viewer_move": bool(
                terrain.get("distant_world_map_lod_defer_until_initial_viewer_move", False)
            ),
            "distant_world_map_lod_deferred": bool(terrain.get("distant_world_map_lod_deferred", False)),
            "distant_world_map_lod_throttled_update": bool(terrain.get("distant_world_map_lod_throttled_update", False)),
            "distant_world_map_lod_distance": lod_distance,
            "distant_world_map_lod_overlap": lod_overlap,
            "distant_world_map_lod_inner_distance": lod_inner_distance,
            "distant_world_map_lod_beyond_render_distance": lod_distance > render_distance,
            "distant_world_map_lod_sample_step": _int(terrain.get("distant_world_map_lod_sample_step")),
            "world_map_lod_pending_candidate_count": _int(terrain.get("world_map_lod_pending_candidate_count")),
            "last_world_map_lod_loads": _int(terrain.get("last_world_map_lod_loads")),
            "last_world_map_lod_unloads": _int(terrain.get("last_world_map_lod_unloads")),
            "last_world_map_lod_update_ms": _round(_float(terrain.get("last_world_map_lod_update_ms"))),
            "world_map_terrain_batch_far_lod_enabled": bool(terrain.get("world_map_terrain_batch_far_lod_enabled", False)),
            "world_map_terrain_batch_far_lod_chunk_count": _int(terrain.get("world_map_terrain_batch_far_lod_chunk_count")),
            "world_map_lod_replaced_terrain_chunk_count": _int(
                terrain.get(
                    "world_map_lod_replaced_terrain_chunk_count",
                    terrain.get("world_map_terrain_batch_far_lod_chunk_count"),
                )
            ),
            "world_map_terrain_batch_far_lod_start_chunks": _int(terrain.get("world_map_terrain_batch_far_lod_start_chunks")),
            "world_map_terrain_batch_far_lod_sample_step": _int(terrain.get("world_map_terrain_batch_far_lod_sample_step")),
        },
        "building": {
            "dirty_visible_chunk_count": _int(building.get("dirty_visible_chunk_count")),
            "pending_world_map_baked_building_apply_phases": _int(building.get("pending_world_map_baked_building_apply_phases")),
            "last_world_map_baked_building_apply_queue_ms": _round(_float(building.get("last_world_map_baked_building_apply_queue_ms"))),
            "last_world_map_baked_building_apply_queue_count": _int(building.get("last_world_map_baked_building_apply_queue_count")),
            "visible_world_map_baked_building_visual_nodes": _int(building.get("visible_world_map_baked_building_visual_nodes")),
            "visible_world_map_baked_building_visual_surfaces": _int(building.get("visible_world_map_baked_building_visual_surfaces")),
            "last_world_map_baked_building_visual_batch_backend": str(building.get("last_world_map_baked_building_visual_batch_backend", "")),
            "last_world_map_baked_building_visual_batch_rebuild_ms": _round(_float(building.get("last_world_map_baked_building_visual_batch_rebuild_ms"))),
            "last_world_map_baked_building_visual_batch_source_surfaces": _int(building.get("last_world_map_baked_building_visual_batch_source_surfaces")),
            "last_world_map_baked_building_visual_batch_output_surfaces": _int(building.get("last_world_map_baked_building_visual_batch_output_surfaces")),
            "last_world_map_baked_building_visual_batch_output_vertices": _int(building.get("last_world_map_baked_building_visual_batch_output_vertices")),
            "last_world_map_baked_building_visual_batch_output_indices": _int(building.get("last_world_map_baked_building_visual_batch_output_indices")),
        },
        "prefab_spawner": {
            "world_map_baked_building_payload_signature": str(prefab.get("world_map_baked_building_payload_signature", "")),
            "pending_world_map_baked_payload_build_jobs": _int(prefab.get("pending_world_map_baked_payload_build_jobs")),
            "pending_world_map_baked_payload_jobs": _int(prefab.get("pending_world_map_baked_payload_jobs")),
            "last_world_map_baked_payload_build_queue_ms": _round(_float(prefab.get("last_world_map_baked_payload_build_queue_ms"))),
            "last_world_map_baked_payload_build_queue_count": _int(prefab.get("last_world_map_baked_payload_build_queue_count")),
            "last_world_map_baked_payload_build_queue_success_count": _int(prefab.get("last_world_map_baked_payload_build_queue_success_count")),
            "last_world_map_baked_payload_apply_ms": _round(_float(prefab.get("last_world_map_baked_payload_apply_ms"))),
            "last_world_map_baked_payload_apply_count": _int(prefab.get("last_world_map_baked_payload_apply_count")),
        },
        "vegetation": {
            "global_render_batch_count": _int(vegetation.get("global_render_batch_count")),
            "global_tree_render_batch_count": _int(vegetation.get("global_tree_render_batch_count")),
            "global_grass_render_batch_count": _int(vegetation.get("global_grass_render_batch_count")),
            "global_rock_render_batch_count": _int(vegetation.get("global_rock_render_batch_count")),
            "world_map_vegetation_render_profile_active": bool(vegetation.get("world_map_vegetation_render_profile_active", False)),
            "effective_vegetation_render_cluster_size": _int(vegetation.get("effective_vegetation_render_cluster_size")),
            "effective_vegetation_grass_render_cluster_size": _int(vegetation.get("effective_vegetation_grass_render_cluster_size")),
        },
        "entities": {
            "active_entities": _int(entities.get("active_entities")),
            "frozen_entities": _int(entities.get("frozen_entities")),
            "pending_spawns": _int(entities.get("pending_spawns")),
        },
    }


def _procedural_window_summary(samples: list[Any], phases: set[str]) -> dict[str, Any]:
    rows = [
        _dict(sample)
        for sample in samples
        if str(_dict(sample).get("phase", "")) in phases
    ]
    rows = [row for row in rows if row]
    sample_count = len(rows)
    if sample_count <= 0:
        return {
            "sample_count": 0,
            "avg_fps": 0.0,
            "min_fps": 0.0,
            "avg_draw_calls": 0.0,
            "avg_objects": 0.0,
            "avg_primitives": 0.0,
            "max_terrain_visual_batch_hidden_chunk_count": 0,
            "max_terrain_visual_batch_node_count": 0,
            "max_water_visual_batch_hidden_chunk_count": 0,
            "max_water_visual_batch_node_count": 0,
            "max_terrain_visual_batch_near_cull_chunk_count": 0,
            "max_water_visual_batch_near_cull_chunk_count": 0,
            "max_world_map_terrain_batch_far_lod_chunk_count": 0,
        }

    terrains = [_dict(row.get("terrain")) for row in rows]
    return {
        "sample_count": sample_count,
        "avg_fps": _round(sum(_float(row.get("fps")) for row in rows) / float(sample_count)),
        "min_fps": _round(min(_float(row.get("fps")) for row in rows)),
        "avg_draw_calls": _round(sum(_int(row.get("draw_calls")) for row in rows) / float(sample_count)),
        "avg_objects": _round(sum(_int(row.get("render_objects")) for row in rows) / float(sample_count)),
        "avg_primitives": _round(sum(_int(row.get("primitives")) for row in rows) / float(sample_count)),
        "max_terrain_visual_batch_hidden_chunk_count": max(_int(terrain.get("terrain_visual_batch_hidden_chunk_count")) for terrain in terrains),
        "max_terrain_visual_batch_node_count": max(_int(terrain.get("terrain_visual_batch_node_count")) for terrain in terrains),
        "max_water_visual_batch_hidden_chunk_count": max(_int(terrain.get("water_visual_batch_hidden_chunk_count")) for terrain in terrains),
        "max_water_visual_batch_node_count": max(_int(terrain.get("water_visual_batch_node_count")) for terrain in terrains),
        "max_terrain_visual_batch_near_cull_chunk_count": max(_int(terrain.get("terrain_visual_batch_near_cull_chunk_count")) for terrain in terrains),
        "max_water_visual_batch_near_cull_chunk_count": max(_int(terrain.get("water_visual_batch_near_cull_chunk_count")) for terrain in terrains),
        "max_world_map_terrain_batch_far_lod_chunk_count": max(_int(terrain.get("world_map_terrain_batch_far_lod_chunk_count")) for terrain in terrains),
    }


def _procedural_active_window_summary(samples: list[Any]) -> dict[str, Any]:
    return _procedural_window_summary(samples, {"move", "hold"})


def _procedural_raw_gpu_summary(snapshot: dict[str, Any]) -> dict[str, Any]:
    summary = _dict(snapshot.get("raw_gpu_summary"))
    power = _dict(summary.get("power_w"))
    temp = _dict(summary.get("temp_c"))
    util = _dict(summary.get("gpu_util_percent"))
    return {
        "sample_count": _int(summary.get("sample_count")),
        "duration_s": _round(_float(summary.get("duration_s"))),
        "power_sample_count": _int(power.get("count")),
        "avg_power_w": _round(_float(power.get("avg"))),
        "max_power_w": _round(_float(power.get("max"))),
        "temp_sample_count": _int(temp.get("count")),
        "avg_temp_c": _round(_float(temp.get("avg"))),
        "max_temp_c": _round(_float(temp.get("max"))),
        "gpu_util_sample_count": _int(util.get("count")),
        "avg_gpu_util_pct": _round(_float(util.get("avg"))),
        "max_gpu_util_pct": _round(_float(util.get("max"))),
    }


def _procedural_raw_gpu_phase_summary(snapshot: dict[str, Any], phase: str) -> dict[str, Any]:
    phases = _dict(snapshot.get("raw_gpu_phase_summary"))
    return _procedural_raw_gpu_summary({"raw_gpu_summary": _dict(phases.get(phase))})


def _summarize_procedural_snapshot(path: Path) -> dict[str, Any]:
    snapshot = _read_json(path)
    samples = _list(snapshot.get("samples"))
    final_sample = _dict(snapshot.get("final_sample"))
    render_features = _dict(snapshot.get("render_features"))
    if not render_features:
        render_features = _dict(final_sample.get("render_features"))
    visual_capture = _dict(snapshot.get("visual_capture"))
    terrain = _dict(final_sample.get("terrain"))
    building = _dict(final_sample.get("building"))
    vegetation = _dict(final_sample.get("vegetation"))
    return {
        "path": str(path),
        "modified_epoch": path.stat().st_mtime,
        "completed": bool(snapshot.get("completed", False)),
        "move_seconds": _float(snapshot.get("move_seconds")),
        "hold_seconds": _float(snapshot.get("hold_seconds")),
        "sample_count": len(samples),
        "active_window": _procedural_active_window_summary(samples),
        "move_window": _procedural_window_summary(samples, {"move"}),
        "hold_window": _procedural_window_summary(samples, {"hold"}),
        "raw_gpu": _procedural_raw_gpu_summary(snapshot),
        "raw_gpu_move": _procedural_raw_gpu_phase_summary(snapshot, "move"),
        "raw_gpu_hold": _procedural_raw_gpu_phase_summary(snapshot, "hold"),
        "render_features": {
            "disable_glow": bool(render_features.get("disable_glow", False)),
            "glow_environment_count": _int(render_features.get("glow_environment_count")),
            "scaling_3d_scale_supported": bool(render_features.get("scaling_3d_scale_supported", False)),
            "scaling_3d_scale_requested": _float(render_features.get("scaling_3d_scale_requested"), -1.0),
            "scaling_3d_scale_actual": _float(render_features.get("scaling_3d_scale_actual")),
            "scaling_3d_scale_applied": bool(render_features.get("scaling_3d_scale_applied", False)),
        },
        "visual_capture": {
            "requested": bool(visual_capture.get("requested", False)),
            "saved": bool(visual_capture.get("saved", False)),
            "path": str(visual_capture.get("path", "")),
            "width": _int(visual_capture.get("width")),
            "height": _int(visual_capture.get("height")),
        },
        "final": {
            "draw_calls": _int(final_sample.get("draw_calls")),
            "render_objects": _int(final_sample.get("render_objects")),
            "primitives": _int(final_sample.get("primitives")),
            "world_map_active": bool(terrain.get("world_map_active", False)),
            "runtime_power_mode": str(terrain.get("runtime_power_mode", "")),
            "runtime_power_target_fps": _int(terrain.get("runtime_power_target_fps")),
            "runtime_power_active_reason": str(terrain.get("runtime_power_active_reason", "")),
            "runtime_power_external_world_busy": bool(terrain.get("runtime_power_external_world_busy", False)),
            "runtime_power_world_work_suspended": bool(terrain.get("runtime_power_world_work_suspended", False)),
            "runtime_power_render_loop_suspended": bool(terrain.get("runtime_power_render_loop_suspended", False)),
            "runtime_power_render_loop_enabled": bool(terrain.get("runtime_power_render_loop_enabled", True)),
            "runtime_power_viewport_scale_current": _float(terrain.get("runtime_power_viewport_scale_current")),
            "rendered_terrain_chunk_count": _int(terrain.get("rendered_terrain_chunk_count")),
            "full_res_terrain_drawn_chunk_count": _int(
                terrain.get("full_res_terrain_drawn_chunk_count", terrain.get("rendered_terrain_chunk_count"))
            ),
            "rendered_water_chunk_count": _int(terrain.get("rendered_water_chunk_count")),
            "terrain_visual_batch_active": bool(terrain.get("terrain_visual_batch_active", False)),
            "terrain_visual_batch_node_count": _int(terrain.get("terrain_visual_batch_node_count")),
            "terrain_visual_batch_hidden_chunk_count": _int(terrain.get("terrain_visual_batch_hidden_chunk_count")),
            "terrain_visual_batch_near_cull_chunk_count": _int(terrain.get("terrain_visual_batch_near_cull_chunk_count")),
            "effective_terrain_visual_batch_near_cull_radius_chunks": _int(terrain.get("effective_terrain_visual_batch_near_cull_radius_chunks")),
            "world_map_terrain_batch_far_lod_enabled": bool(terrain.get("world_map_terrain_batch_far_lod_enabled", False)),
            "world_map_terrain_batch_far_lod_chunk_count": _int(terrain.get("world_map_terrain_batch_far_lod_chunk_count")),
            "world_map_terrain_batch_far_lod_sample_step": _int(terrain.get("world_map_terrain_batch_far_lod_sample_step")),
            "terrain_shadow_lod_enabled": bool(terrain.get("terrain_shadow_lod_enabled", False)),
            "terrain_shadow_lod_radius_chunks": _int(terrain.get("terrain_shadow_lod_radius_chunks")),
            "last_terrain_shadow_lod_enabled_count": _int(terrain.get("last_terrain_shadow_lod_enabled_count")),
            "last_terrain_shadow_lod_disabled_count": _int(terrain.get("last_terrain_shadow_lod_disabled_count")),
            "last_gpu_water_density_dispatched": bool(terrain.get("last_gpu_water_density_dispatched", False)),
            "gpu_water_density_skipped_count": _int(terrain.get("gpu_water_density_skipped_count")),
            "last_cpu_mesh_build_water_ms": _float(terrain.get("last_cpu_mesh_build_water_ms")),
            "water_visual_batch_active": bool(terrain.get("water_visual_batch_active", False)),
            "water_visual_batch_node_count": _int(terrain.get("water_visual_batch_node_count")),
            "water_visual_batch_hidden_chunk_count": _int(terrain.get("water_visual_batch_hidden_chunk_count")),
            "water_visual_batch_near_cull_chunk_count": _int(terrain.get("water_visual_batch_near_cull_chunk_count")),
            "effective_water_visual_batch_near_cull_radius_chunks": _int(terrain.get("effective_water_visual_batch_near_cull_radius_chunks")),
            "water_visual_batch_dirty_count": _int(terrain.get("water_visual_batch_dirty_count")),
            "building_dirty_visible_chunk_count": _int(building.get("dirty_visible_chunk_count")),
            "vegetation_pending_chunks": _int(vegetation.get("pending_chunks")),
        },
    }


def _procedural_window_delta(candidate: dict[str, Any], baseline: dict[str, Any], window_name: str) -> dict[str, Any]:
    candidate_window = _dict(candidate.get(window_name))
    baseline_window = _dict(baseline.get(window_name))
    baseline_primitives = _float(baseline_window.get("avg_primitives"))
    candidate_primitives = _float(candidate_window.get("avg_primitives"))
    return {
        "sample_count": _int(candidate_window.get("sample_count")),
        "baseline_sample_count": _int(baseline_window.get("sample_count")),
        "delta_min_fps": _round(_float(candidate_window.get("min_fps")) - _float(baseline_window.get("min_fps"))),
        "delta_avg_fps": _round(_float(candidate_window.get("avg_fps")) - _float(baseline_window.get("avg_fps"))),
        "delta_avg_draw_calls": _round(_float(candidate_window.get("avg_draw_calls")) - _float(baseline_window.get("avg_draw_calls"))),
        "delta_avg_objects": _round(_float(candidate_window.get("avg_objects")) - _float(baseline_window.get("avg_objects"))),
        "delta_avg_primitives": _round(candidate_primitives - baseline_primitives),
        "primitive_ratio": _round(candidate_primitives / baseline_primitives) if baseline_primitives > 0.0 else 0.0,
    }


def _latest_procedural_terrain_batch_comparison(procedural: list[Any]) -> dict[str, Any]:
    entries = [_dict(entry) for entry in procedural]
    latest = next(
        (
            entry
            for entry in entries
            if bool(entry.get("completed", False))
            and not bool(_dict(entry.get("final")).get("world_map_active", False))
            and _int(_dict(entry.get("active_window")).get("max_terrain_visual_batch_node_count")) > 0
        ),
        {},
    )
    if not latest:
        return {}

    latest_final = _dict(latest.get("final"))
    latest_active = _dict(latest.get("active_window"))
    terrain_chunks = _int(latest_final.get("rendered_terrain_chunk_count"))
    water_chunks = _int(latest_final.get("rendered_water_chunk_count"))
    water_batches = _int(latest_active.get("max_water_visual_batch_node_count"))
    baseline = next(
        (
            entry
            for entry in entries
            if entry is not latest
            and bool(entry.get("completed", False))
            and not bool(_dict(entry.get("final")).get("world_map_active", False))
            and _int(_dict(entry.get("active_window")).get("max_terrain_visual_batch_node_count")) == 0
            and _int(_dict(entry.get("final")).get("rendered_terrain_chunk_count")) == terrain_chunks
            and _int(_dict(entry.get("final")).get("rendered_water_chunk_count")) == water_chunks
            and _int(_dict(entry.get("active_window")).get("max_water_visual_batch_node_count")) == water_batches
        ),
        {},
    )
    if not baseline:
        return {"available": False, "reason": "no matching unbatched procedural baseline", "candidate": latest}

    return {
        "available": True,
        "candidate_path": str(latest.get("path", "")),
        "baseline_path": str(baseline.get("path", "")),
        "terrain_chunks": terrain_chunks,
        "water_chunks": water_chunks,
        "water_batches": water_batches,
        "candidate_terrain_batches": _int(latest_active.get("max_terrain_visual_batch_node_count")),
        "candidate_terrain_hidden": _int(latest_active.get("max_terrain_visual_batch_hidden_chunk_count")),
        "move": _procedural_window_delta(latest, baseline, "move_window"),
        "hold": _procedural_window_delta(latest, baseline, "hold_window"),
        "active": _procedural_window_delta(latest, baseline, "active_window"),
    }


def _summarize_render_ablation(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    summary = _read_json(path)
    results = summary.get("results", [])
    if not isinstance(results, list):
        return {"path": str(path), "error": "results is not a list"}
    compact_results: list[dict[str, Any]] = []
    for result in results:
        if not isinstance(result, dict):
            continue
        compact_results.append(
            {
                "case": str(result.get("case", "")),
                "snapshot": str(result.get("snapshot", "")),
                "hold_complete": bool(result.get("hold_complete", False)),
                "avg_total_ms": _round(_float(result.get("avg_total_ms"))),
                "avg_draw_calls": _round(_float(result.get("avg_draw_calls"))),
                "avg_objects": _round(_float(result.get("avg_objects"))),
                "has_primitive_metrics": "avg_primitives" in result,
                "avg_primitives": _round(_float(result.get("avg_primitives"))),
                "delta_avg_total_ms": _round(_float(result.get("delta_avg_total_ms"))),
                "delta_avg_draw_calls": _round(_float(result.get("delta_avg_draw_calls"))),
                "delta_avg_objects": _round(_float(result.get("delta_avg_objects"))),
                "delta_avg_primitives": _round(_float(result.get("delta_avg_primitives"))),
                "has_pipeline_metrics": "pipeline_compilations_total_delta" in result,
                "pipeline_compilations_total_delta": _int(result.get("pipeline_compilations_total_delta")),
                "vegetation_global_batches": _int(result.get("vegetation_global_batches")),
                "vegetation_profile_active": bool(result.get("vegetation_profile_active", False)),
            }
        )
    return {"path": str(path), "results": compact_results}


def _gpu_window_summary(window: dict[str, Any]) -> dict[str, Any]:
    return {
        "sample_count": _int(window.get("sample_count")),
        "failed_sample_count": _int(window.get("failed_sample_count")),
        "avg_power_w": _round(_float(window.get("avg_power_w"))),
        "max_power_w": _round(_float(window.get("max_power_w"))),
        "avg_temp_c": _round(_float(window.get("avg_temp_c"))),
        "max_temp_c": _round(_float(window.get("max_temp_c"))),
        "start_temp_c": _round(_float(window.get("start_temp_c"))),
        "end_temp_c": _round(_float(window.get("end_temp_c"))),
        "temp_delta_c": _round(_float(window.get("temp_delta_c"))),
        "avg_gpu_util_pct": _round(_float(window.get("avg_gpu_util_pct"))),
        "max_gpu_util_pct": _round(_float(window.get("max_gpu_util_pct"))),
        "p0_fraction": _round(_float(window.get("p0_fraction"))),
        "pstates": _dict(window.get("pstates")),
    }


def _summarize_gpu_run(run: dict[str, Any]) -> dict[str, Any]:
    snapshot = _dict(run.get("snapshot"))
    content = _dict(snapshot.get("content"))
    town_metrics = _dict(snapshot.get("town_metrics"))
    return {
        "case": str(run.get("case", "")),
        "repeat_index": _int(run.get("repeat_index")),
        "returncode": _int(run.get("returncode"), -1),
        "failure_reasons": [str(reason) for reason in _list(run.get("failure_reasons"))],
        "thermal_abort_reason": str(run.get("thermal_abort_reason", "")),
        "duration_s": _round(_float(run.get("duration_s"))),
        "content_valid_for_power_compare": bool(content.get("content_valid_for_power_compare", False)),
        "avg_fps": _round(_float(town_metrics.get("average_fps"))),
        "estimated_hold_gpu": _gpu_window_summary(_dict(run.get("estimated_hold_gpu"))),
        "stationary_hold_gpu": _gpu_window_summary(_dict(run.get("stationary_hold_gpu"))),
        "moving_entry_gpu": _gpu_window_summary(_dict(run.get("moving_entry_gpu"))),
        "last_20s_gpu": _gpu_window_summary(_dict(run.get("last_20s_gpu"))),
        "last_30s_gpu": _gpu_window_summary(_dict(run.get("last_30s_gpu"))),
        "all_run_gpu": _gpu_window_summary(_dict(run.get("all_run_gpu"))),
    }


def _summarize_gpu_telemetry(path: Path) -> dict[str, Any]:
    telemetry = _read_json(path)
    runs = [_summarize_gpu_run(run) for run in _list(telemetry.get("runs")) if isinstance(run, dict)]
    invalid_runs = [
        f"{run.get('case')}#{run.get('repeat_index')}"
        for run in runs
        if _int(run.get("returncode"), -1) != 0 or _list(run.get("failure_reasons"))
    ]
    return {
        "path": str(path),
        "modified_epoch": path.stat().st_mtime,
        "cases": [str(case) for case in _list(telemetry.get("cases"))],
        "hold_seconds": _round(_float(telemetry.get("hold_seconds"))),
        "sample_interval_seconds": _round(_float(telemetry.get("sample_interval_seconds"))),
        "run_count": len(runs),
        "invalid_run_count": len(invalid_runs),
        "invalid_runs": invalid_runs,
        "initial_idle_gpu": _gpu_window_summary(_dict(_dict(telemetry.get("initial_idle")).get("gpu"))),
        "final_idle_gpu": _gpu_window_summary(_dict(_dict(telemetry.get("final_idle")).get("gpu"))),
        "runs": runs,
    }


def _summarize_gpu_telemetry_files(args: argparse.Namespace) -> list[dict[str, Any]]:
    root = Path(args.gpu_telemetry_dir)
    return [
        _summarize_gpu_telemetry(path)
        for path in _latest_files(root, "town_stall_raw_baseline_*.json", args.gpu_telemetry_count)
    ]


def _latest_gpu_telemetry(gpu_telemetry: list[dict[str, Any]]) -> dict[str, Any]:
    return gpu_telemetry[0] if gpu_telemetry else {}


def _sampled_hold_windows(latest_gpu: dict[str, Any]) -> list[dict[str, Any]]:
    windows: list[dict[str, Any]] = []
    for run in _list(latest_gpu.get("runs")):
        if not isinstance(run, dict):
            continue
        hold = _dict(run.get("stationary_hold_gpu"))
        if not _has_samples(hold):
            hold = _dict(run.get("estimated_hold_gpu"))
        if _has_samples(hold):
            windows.append(hold)
    return windows


def _gpu_thermal_gate(report: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    latest_gpu = _dict(report.get("latest_gpu_telemetry"))
    enforced = args.require_latest_gpu_telemetry_valid or _gpu_thermal_threshold_requested(args)
    failures: list[str] = []
    if not latest_gpu:
        if enforced:
            failures.append("no raw GPU telemetry files found")
        return {"enforced": enforced, "passed": not failures, "failures": failures}

    invalid_run_count = _int(latest_gpu.get("invalid_run_count"))
    windows = _sampled_hold_windows(latest_gpu)
    observed = {
        "invalid_run_count": invalid_run_count,
        "max_hold_avg_power_w": _round(max((_float(window.get("avg_power_w")) for window in windows), default=0.0)),
        "max_hold_avg_temp_c": _round(max((_float(window.get("avg_temp_c")) for window in windows), default=0.0)),
        "max_hold_peak_temp_c": _round(max((_float(window.get("max_temp_c")) for window in windows), default=0.0)),
        "max_hold_temp_delta_c": _round(max((_float(window.get("temp_delta_c")) for window in windows), default=0.0)),
    }

    if args.require_latest_gpu_telemetry_valid and invalid_run_count > 0:
        failures.append(f"latest raw GPU telemetry has {invalid_run_count} invalid run(s)")
    if _gpu_thermal_threshold_requested(args) and not windows:
        failures.append("latest raw GPU telemetry has no sampled hold windows")
    if args.max_latest_gpu_hold_avg_power_w is not None and observed["max_hold_avg_power_w"] > args.max_latest_gpu_hold_avg_power_w:
        failures.append(
            f"hold average GPU power {observed['max_hold_avg_power_w']:.3f} W exceeds {args.max_latest_gpu_hold_avg_power_w:.3f} W"
        )
    if args.max_latest_gpu_hold_avg_temp_c is not None and observed["max_hold_avg_temp_c"] > args.max_latest_gpu_hold_avg_temp_c:
        failures.append(
            f"hold average GPU temp {observed['max_hold_avg_temp_c']:.3f} C exceeds {args.max_latest_gpu_hold_avg_temp_c:.3f} C"
        )
    if args.max_latest_gpu_hold_peak_temp_c is not None and observed["max_hold_peak_temp_c"] > args.max_latest_gpu_hold_peak_temp_c:
        failures.append(
            f"hold peak GPU temp {observed['max_hold_peak_temp_c']:.3f} C exceeds {args.max_latest_gpu_hold_peak_temp_c:.3f} C"
        )
    return {
        "enforced": enforced,
        "passed": not failures,
        "failures": failures,
        "latest_path": str(latest_gpu.get("path", "")),
        "observed": observed,
    }


def _gpu_thermal_threshold_requested(args: argparse.Namespace) -> bool:
    return (
        args.max_latest_gpu_hold_avg_power_w is not None
        or args.max_latest_gpu_hold_avg_temp_c is not None
        or args.max_latest_gpu_hold_peak_temp_c is not None
    )


def _freshness_threshold_requested(args: argparse.Namespace) -> bool:
    return (
        args.max_latest_production_town_age_hours is not None
        or args.max_latest_procedural_age_hours is not None
        or args.max_latest_gpu_telemetry_age_hours is not None
    )


def _freshness_gate(report: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    reference_epoch = _float(report.get("generated_at_epoch"), time.time())
    latest_production = _dict(report.get("latest_production_town"))
    procedural = report.get("procedural", [])
    latest_procedural = _dict(procedural[0]) if isinstance(procedural, list) and procedural else {}
    latest_gpu = _dict(report.get("latest_gpu_telemetry"))
    observed = {
        "latest_production_town_age_hours": _round(_age_hours(latest_production.get("modified_epoch"), reference_epoch)) if latest_production else None,
        "latest_procedural_age_hours": _round(_age_hours(latest_procedural.get("modified_epoch"), reference_epoch)) if latest_procedural else None,
        "latest_gpu_telemetry_age_hours": _round(_age_hours(latest_gpu.get("modified_epoch"), reference_epoch)) if latest_gpu else None,
    }
    failures: list[str] = []
    if args.max_latest_production_town_age_hours is not None:
        if not latest_production:
            failures.append("no production-like town snapshots found")
        elif float(observed["latest_production_town_age_hours"]) > args.max_latest_production_town_age_hours:
            failures.append(
                "latest production-like town snapshot age "
                f"{observed['latest_production_town_age_hours']:.3f}h exceeds {args.max_latest_production_town_age_hours:.3f}h"
            )
    if args.max_latest_procedural_age_hours is not None:
        if not latest_procedural:
            failures.append("no procedural power snapshots found")
        elif float(observed["latest_procedural_age_hours"]) > args.max_latest_procedural_age_hours:
            failures.append(
                "latest procedural power snapshot age "
                f"{observed['latest_procedural_age_hours']:.3f}h exceeds {args.max_latest_procedural_age_hours:.3f}h"
            )
    if args.max_latest_gpu_telemetry_age_hours is not None:
        if not latest_gpu:
            failures.append("no raw GPU telemetry files found")
        elif float(observed["latest_gpu_telemetry_age_hours"]) > args.max_latest_gpu_telemetry_age_hours:
            failures.append(
                "latest raw GPU telemetry age "
                f"{observed['latest_gpu_telemetry_age_hours']:.3f}h exceeds {args.max_latest_gpu_telemetry_age_hours:.3f}h"
            )
    return {
        "enforced": _freshness_threshold_requested(args),
        "passed": not failures,
        "failures": failures,
        "observed": observed,
    }


def _ablation_cases_by_snapshot(render_ablation: dict[str, Any]) -> dict[str, str]:
    cases: dict[str, str] = {}
    results = render_ablation.get("results", [])
    if not isinstance(results, list):
        return cases
    for result in results:
        if not isinstance(result, dict):
            continue
        snapshot = str(result.get("snapshot", "")).strip()
        case = str(result.get("case", "")).strip()
        if snapshot and case:
            cases[str(Path(snapshot))] = case
    return cases


def _town_render_mismatch(render_features: dict[str, Any]) -> bool:
    rendering_method = str(render_features.get("rendering_method", "")).strip().lower()
    rendering_driver = str(render_features.get("rendering_driver_name", "")).strip().lower()
    project_method = str(render_features.get("project_rendering_method", "")).strip().lower()
    project_driver = str(render_features.get("project_rendering_driver_windows", "")).strip().lower()
    if rendering_method and rendering_method != "forward_plus":
        return True
    if rendering_driver and rendering_driver != "vulkan":
        return True
    if project_method and project_method != "forward_plus":
        return True
    if project_driver and project_driver != "vulkan":
        return True
    return False


def _town_render_unverified(render_features: dict[str, Any]) -> bool:
    if bool(render_features.get("vulkan_only_expected", False)):
        return False
    return not any(
        str(render_features.get(key, "")).strip()
        for key in (
            "rendering_method",
            "rendering_driver_name",
            "project_rendering_method",
            "project_rendering_driver_windows",
        )
    )


def _town_tools_runtime(entry: dict[str, Any]) -> bool:
    runtime_mode = str(entry.get("runtime_mode", "")).strip().lower()
    return runtime_mode == "godot_tools_debug_runner"


def _annotate_town_runs(town: list[dict[str, Any]], render_ablation: dict[str, Any], production_min_hold_seconds: float) -> None:
    cases_by_snapshot = _ablation_cases_by_snapshot(render_ablation)
    min_hold_seconds = max(0.0, production_min_hold_seconds)
    for entry in town:
        path = str(Path(str(entry.get("path", ""))))
        ablation_case = cases_by_snapshot.get(path, "")
        render_features = _dict(entry.get("render_features"))
        terrain = _dict(entry.get("terrain"))
        machine = _dict(entry.get("machine_state"))
        machine_load = _float(machine.get("load_percentage"))
        preflight_cpu_load = _float(machine.get("preflight_cpu_load_median_percent"))
        preflight_gpu_util = _float(machine.get("preflight_raw_gpu_util_median_percent"))
        contaminated = machine_load > 55.0 or preflight_cpu_load > 55.0 or preflight_gpu_util > 30.0
        incomplete = not bool(entry.get("hold_complete", False))
        short_probe = 0.0 < _float(entry.get("hold_seconds")) < min_hold_seconds
        experimental = (
            bool(terrain.get("world_map_terrain_batch_far_lod_enabled", False))
            or _int(terrain.get("world_map_terrain_batch_far_lod_chunk_count")) > 0
        )
        if ablation_case and ablation_case != "baseline":
            run_role = "ablation_control"
        elif _town_tools_runtime(entry):
            run_role = "tools_runtime"
        elif _town_render_unverified(render_features):
            run_role = "renderer_unverified"
        elif _town_render_mismatch(render_features):
            run_role = "renderer_mismatch"
        elif contaminated:
            run_role = "contaminated"
        elif incomplete:
            run_role = "incomplete"
        elif short_probe:
            run_role = "short_probe"
        elif experimental:
            run_role = "experimental"
        elif ablation_case == "baseline":
            run_role = "ablation_baseline"
        else:
            run_role = "production_like"
        entry["ablation_case"] = ablation_case
        entry["run_role"] = run_role
        entry["production_candidate"] = run_role not in {
            "ablation_control",
            "contaminated",
            "experimental",
            "incomplete",
            "renderer_mismatch",
            "renderer_unverified",
            "short_probe",
            "tools_runtime",
        }


def _latest_production_town(town: list[dict[str, Any]]) -> dict[str, Any]:
    for entry in town:
        if bool(entry.get("production_candidate", True)):
            return entry
    return {}


def _production_trend(town: list[dict[str, Any]]) -> dict[str, Any]:
    production_runs = [entry for entry in town if bool(entry.get("production_candidate", True))]
    if len(production_runs) < 2:
        return {}
    latest = production_runs[0]
    previous = production_runs[1]
    latest_hold = _dict(latest.get("stationary_hold"))
    previous_hold = _dict(previous.get("stationary_hold"))
    has_primitive_metrics = bool(latest_hold.get("has_primitive_metrics", False)) and bool(previous_hold.get("has_primitive_metrics", False))
    return {
        "latest_path": str(latest.get("path", "")),
        "previous_path": str(previous.get("path", "")),
        "delta_avg_total_ms": _round(_float(latest_hold.get("avg_total_ms")) - _float(previous_hold.get("avg_total_ms"))),
        "delta_frames_over_budget_pct": _round(
            _float(latest_hold.get("frames_over_budget_pct")) - _float(previous_hold.get("frames_over_budget_pct"))
        ),
        "delta_avg_draw_calls": _round(_float(latest_hold.get("avg_draw_calls")) - _float(previous_hold.get("avg_draw_calls"))),
        "delta_avg_objects": _round(_float(latest_hold.get("avg_objects")) - _float(previous_hold.get("avg_objects"))),
        "has_primitive_metrics": has_primitive_metrics,
        "delta_avg_primitives": _round(_float(latest_hold.get("avg_primitives")) - _float(previous_hold.get("avg_primitives"))),
    }


def _stable_60_gate(report: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    latest_production = _dict(report.get("latest_production_town"))
    failures: list[str] = []
    if not latest_production:
        failures.append("no production-like town snapshots found")
        return {
            "passed": False,
            "failures": failures,
            "target_frame_ms": args.target_frame_ms,
        }

    hold = _dict(latest_production.get("stationary_hold"))
    avg_ms = _float(hold.get("avg_total_ms"))
    over_budget_pct = _float(hold.get("frames_over_budget_pct"))
    max_ms = _float(hold.get("max_total_ms"))
    frames_over_40ms = _int(hold.get("frames_over_40ms"))
    longest_over_budget_streak = _int(hold.get("longest_over_budget_streak"))

    if not bool(latest_production.get("hold_complete", False)):
        failures.append("latest production-like town hold did not complete")
    if avg_ms > args.target_frame_ms + FRAME_BUDGET_EPSILON_MS:
        failures.append(f"avg frame time {avg_ms:.3f} ms exceeds target {args.target_frame_ms:.3f} ms")
    if over_budget_pct > args.max_stable_60_over_budget_pct:
        failures.append(
            f"over-budget frames {over_budget_pct:.3f}% exceed {args.max_stable_60_over_budget_pct:.3f}%"
        )
    if max_ms > args.max_stable_60_frame_ms + FRAME_BUDGET_EPSILON_MS:
        failures.append(f"max frame time {max_ms:.3f} ms exceeds {args.max_stable_60_frame_ms:.3f} ms")
    if frames_over_40ms > args.max_stable_60_frames_over_40ms:
        failures.append(f"frames over 40ms {frames_over_40ms} exceed {args.max_stable_60_frames_over_40ms}")
    if longest_over_budget_streak > args.max_stable_60_over_budget_streak:
        failures.append(
            "longest over-budget streak "
            f"{longest_over_budget_streak} exceeds {args.max_stable_60_over_budget_streak}"
        )

    return {
        "passed": not failures,
        "failures": failures,
        "latest_path": str(latest_production.get("path", "")),
        "target_frame_ms": args.target_frame_ms,
        "max_over_budget_pct": args.max_stable_60_over_budget_pct,
        "max_frame_ms": args.max_stable_60_frame_ms,
        "max_frames_over_40ms": args.max_stable_60_frames_over_40ms,
        "max_over_budget_streak": args.max_stable_60_over_budget_streak,
        "observed": {
            "avg_total_ms": _round(avg_ms),
            "frames_over_budget_pct": _round(over_budget_pct),
            "max_total_ms": _round(max_ms),
            "frames_over_40ms": frames_over_40ms,
            "longest_over_budget_streak": longest_over_budget_streak,
        },
    }


def _movement_gpu_threshold_requested(args: argparse.Namespace) -> bool:
    return (
        args.require_latest_production_movement_gpu_samples
        or args.max_latest_production_movement_gpu_avg_power_w is not None
        or args.max_latest_production_movement_gpu_peak_power_w is not None
        or args.max_latest_production_movement_gpu_peak_temp_c is not None
    )


def _movement_gate(report: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    latest_production = _dict(report.get("latest_production_town"))
    enforced = args.require_latest_production_town_movement_60 or _movement_gpu_threshold_requested(args)
    failures: list[str] = []
    if not latest_production:
        if enforced:
            failures.append("no production-like town snapshots found")
        return {"enforced": enforced, "passed": not failures, "failures": failures}

    movement = _dict(latest_production.get("moving_entry"))
    movement_gpu = _dict(latest_production.get("moving_entry_gpu"))
    capture_reason = str(latest_production.get("town_entry_capture_reason", "")).strip()
    sample_count = _int(movement.get("sample_count"))
    avg_ms = _float(movement.get("avg_total_ms"))
    over_budget_pct = _float(movement.get("frames_over_budget_pct"))
    max_ms = _float(movement.get("max_total_ms"))
    frames_over_50ms = _int(movement.get("frames_over_50ms"))
    gpu_sample_count = _int(movement_gpu.get("power_sample_count"))
    avg_power = _float(movement_gpu.get("avg_power_w"))
    peak_power = _float(movement_gpu.get("max_power_w"))
    peak_temp = _float(movement_gpu.get("max_temp_c"))

    if enforced and capture_reason not in MOVEMENT_CAPTURE_REASONS:
        failures.append(
            "latest production-like town movement capture reason "
            f"'{capture_reason or 'missing'}' is not one of {sorted(MOVEMENT_CAPTURE_REASONS)}"
        )
    if enforced and sample_count < args.min_latest_production_moving_samples:
        failures.append(
            f"movement frame samples {sample_count} below {args.min_latest_production_moving_samples}"
        )

    if args.require_latest_production_town_movement_60:
        if avg_ms > args.target_frame_ms + FRAME_BUDGET_EPSILON_MS:
            failures.append(f"movement avg frame time {avg_ms:.3f} ms exceeds target {args.target_frame_ms:.3f} ms")
        if over_budget_pct > args.max_movement_60_over_budget_pct:
            failures.append(
                f"movement over-budget frames {over_budget_pct:.3f}% exceed {args.max_movement_60_over_budget_pct:.3f}%"
            )
        if max_ms > args.max_movement_60_frame_ms + FRAME_BUDGET_EPSILON_MS:
            failures.append(f"movement max frame time {max_ms:.3f} ms exceeds {args.max_movement_60_frame_ms:.3f} ms")
        if frames_over_50ms > args.max_movement_60_frames_over_50ms:
            failures.append(
                f"movement frames over 50ms {frames_over_50ms} exceed {args.max_movement_60_frames_over_50ms}"
            )

    if _movement_gpu_threshold_requested(args):
        if gpu_sample_count < args.min_latest_production_movement_gpu_samples:
            failures.append(
                "movement raw GPU power samples "
                f"{gpu_sample_count} below {args.min_latest_production_movement_gpu_samples}"
            )
        elif args.max_latest_production_movement_gpu_avg_power_w is not None and avg_power > args.max_latest_production_movement_gpu_avg_power_w:
            failures.append(
                "movement average GPU power "
                f"{avg_power:.3f} W exceeds {args.max_latest_production_movement_gpu_avg_power_w:.3f} W"
            )
        if gpu_sample_count > 0 and args.max_latest_production_movement_gpu_peak_power_w is not None and peak_power > args.max_latest_production_movement_gpu_peak_power_w:
            failures.append(
                "movement peak GPU power "
                f"{peak_power:.3f} W exceeds {args.max_latest_production_movement_gpu_peak_power_w:.3f} W"
            )
        if gpu_sample_count > 0 and args.max_latest_production_movement_gpu_peak_temp_c is not None and peak_temp > args.max_latest_production_movement_gpu_peak_temp_c:
            failures.append(
                "movement peak GPU temp "
                f"{peak_temp:.3f} C exceeds {args.max_latest_production_movement_gpu_peak_temp_c:.3f} C"
            )

    return {
        "enforced": enforced,
        "passed": not failures,
        "failures": failures,
        "latest_path": str(latest_production.get("path", "")),
        "allowed_capture_reasons": sorted(MOVEMENT_CAPTURE_REASONS),
        "target_frame_ms": args.target_frame_ms,
        "min_movement_samples": args.min_latest_production_moving_samples,
        "min_gpu_samples": args.min_latest_production_movement_gpu_samples,
        "observed": {
            "capture_reason": capture_reason,
            "sample_count": sample_count,
            "avg_total_ms": _round(avg_ms),
            "frames_over_budget_pct": _round(over_budget_pct),
            "max_total_ms": _round(max_ms),
            "frames_over_50ms": frames_over_50ms,
            "gpu_power_sample_count": gpu_sample_count,
            "avg_power_w": _round(avg_power),
            "max_power_w": _round(peak_power),
            "max_temp_c": _round(peak_temp),
        },
    }


def _stationary_gpu_threshold_requested(args: argparse.Namespace) -> bool:
    return (
        args.require_latest_production_stationary_gpu_samples
        or args.max_latest_production_stationary_gpu_avg_power_w is not None
        or args.max_latest_production_stationary_gpu_peak_power_w is not None
        or args.max_latest_production_stationary_gpu_peak_temp_c is not None
        or args.max_latest_production_stationary_gpu_p0_fraction is not None
    )


def _stationary_gpu_gate(report: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    latest_production = _dict(report.get("latest_production_town"))
    enforced = _stationary_gpu_threshold_requested(args)
    failures: list[str] = []
    if not latest_production:
        if enforced:
            failures.append("no production-like town snapshots found")
        return {"enforced": enforced, "passed": not failures, "failures": failures}

    stationary = _dict(latest_production.get("stationary_hold"))
    stationary_gpu = _dict(latest_production.get("stationary_hold_gpu"))
    frame_sample_count = _int(stationary.get("sample_count"))
    gpu_sample_count = _int(stationary_gpu.get("power_sample_count"))
    raw_gpu_sample_count = _int(stationary_gpu.get("raw_gpu_available_count"))
    avg_power = _float(stationary_gpu.get("avg_power_w"))
    peak_power = _float(stationary_gpu.get("max_power_w"))
    peak_temp = _float(stationary_gpu.get("max_temp_c"))
    p0_fraction = _float(stationary_gpu.get("p0_fraction"))

    if enforced and gpu_sample_count < args.min_latest_production_stationary_gpu_samples:
        failures.append(
            "stationary raw GPU power samples "
            f"{gpu_sample_count} below {args.min_latest_production_stationary_gpu_samples}"
        )
    if gpu_sample_count > 0 and args.max_latest_production_stationary_gpu_avg_power_w is not None and avg_power > args.max_latest_production_stationary_gpu_avg_power_w:
        failures.append(
            "stationary average GPU power "
            f"{avg_power:.3f} W exceeds {args.max_latest_production_stationary_gpu_avg_power_w:.3f} W"
        )
    if gpu_sample_count > 0 and args.max_latest_production_stationary_gpu_peak_power_w is not None and peak_power > args.max_latest_production_stationary_gpu_peak_power_w:
        failures.append(
            "stationary peak GPU power "
            f"{peak_power:.3f} W exceeds {args.max_latest_production_stationary_gpu_peak_power_w:.3f} W"
        )
    if gpu_sample_count > 0 and args.max_latest_production_stationary_gpu_peak_temp_c is not None and peak_temp > args.max_latest_production_stationary_gpu_peak_temp_c:
        failures.append(
            "stationary peak GPU temp "
            f"{peak_temp:.3f} C exceeds {args.max_latest_production_stationary_gpu_peak_temp_c:.3f} C"
        )
    if raw_gpu_sample_count > 0 and args.max_latest_production_stationary_gpu_p0_fraction is not None and p0_fraction > args.max_latest_production_stationary_gpu_p0_fraction:
        failures.append(
            "stationary P0 fraction "
            f"{p0_fraction:.3f} exceeds {args.max_latest_production_stationary_gpu_p0_fraction:.3f}"
        )

    return {
        "enforced": enforced,
        "passed": not failures,
        "failures": failures,
        "latest_path": str(latest_production.get("path", "")),
        "min_gpu_samples": args.min_latest_production_stationary_gpu_samples,
        "observed": {
            "frame_sample_count": frame_sample_count,
            "gpu_power_sample_count": gpu_sample_count,
            "raw_gpu_sample_count": raw_gpu_sample_count,
            "avg_power_w": _round(avg_power),
            "max_power_w": _round(peak_power),
            "max_temp_c": _round(peak_temp),
            "p0_fraction": _round(p0_fraction),
        },
    }


def _idle_gpu_threshold_requested(args: argparse.Namespace) -> bool:
    return (
        args.require_latest_production_idle_gpu_samples
        or args.max_latest_production_idle_gpu_avg_power_w is not None
        or args.max_latest_production_idle_gpu_peak_power_w is not None
        or args.max_latest_production_idle_gpu_peak_temp_c is not None
        or args.max_latest_production_idle_gpu_p0_fraction is not None
    )


def _select_idle_gpu_phase(latest_production: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    render_loop_suspended_tail = _dict(latest_production.get("runtime_power_render_loop_suspended_tail_10s_gpu"))
    if _int(render_loop_suspended_tail.get("power_sample_count")) > 0:
        return "runtime_power_render_loop_suspended_tail_10s", render_loop_suspended_tail

    render_loop_suspended = _dict(latest_production.get("runtime_power_render_loop_suspended_gpu"))
    if _int(render_loop_suspended.get("power_sample_count")) > 0:
        return "runtime_power_render_loop_suspended", render_loop_suspended

    deep_idle = _dict(latest_production.get("runtime_power_deep_idle_gpu"))
    if _int(deep_idle.get("power_sample_count")) > 0:
        return "runtime_power_deep_idle", deep_idle

    return "missing", {}


def _idle_gpu_gate(report: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    latest_production = _dict(report.get("latest_production_town"))
    enforced = _idle_gpu_threshold_requested(args)
    failures: list[str] = []
    if not latest_production:
        if enforced:
            failures.append("no production-like town snapshots found")
        return {"enforced": enforced, "passed": not failures, "failures": failures}

    phase_name, idle_gpu = _select_idle_gpu_phase(latest_production)
    gpu_sample_count = _int(idle_gpu.get("power_sample_count"))
    raw_gpu_sample_count = _int(idle_gpu.get("raw_gpu_available_count"))
    avg_power = _float(idle_gpu.get("avg_power_w"))
    peak_power = _float(idle_gpu.get("max_power_w"))
    peak_temp = _float(idle_gpu.get("max_temp_c"))
    p0_fraction = _float(idle_gpu.get("p0_fraction"))

    if enforced and gpu_sample_count < args.min_latest_production_idle_gpu_samples:
        failures.append(
            "idle raw GPU power samples "
            f"{gpu_sample_count} below {args.min_latest_production_idle_gpu_samples}"
        )
    if gpu_sample_count > 0 and args.max_latest_production_idle_gpu_avg_power_w is not None and avg_power > args.max_latest_production_idle_gpu_avg_power_w:
        failures.append(
            "idle average GPU power "
            f"{avg_power:.3f} W exceeds {args.max_latest_production_idle_gpu_avg_power_w:.3f} W"
        )
    if gpu_sample_count > 0 and args.max_latest_production_idle_gpu_peak_power_w is not None and peak_power > args.max_latest_production_idle_gpu_peak_power_w:
        failures.append(
            "idle peak GPU power "
            f"{peak_power:.3f} W exceeds {args.max_latest_production_idle_gpu_peak_power_w:.3f} W"
        )
    if gpu_sample_count > 0 and args.max_latest_production_idle_gpu_peak_temp_c is not None and peak_temp > args.max_latest_production_idle_gpu_peak_temp_c:
        failures.append(
            "idle peak GPU temp "
            f"{peak_temp:.3f} C exceeds {args.max_latest_production_idle_gpu_peak_temp_c:.3f} C"
        )
    if raw_gpu_sample_count > 0 and args.max_latest_production_idle_gpu_p0_fraction is not None and p0_fraction > args.max_latest_production_idle_gpu_p0_fraction:
        failures.append(
            "idle P0 fraction "
            f"{p0_fraction:.3f} exceeds {args.max_latest_production_idle_gpu_p0_fraction:.3f}"
        )

    return {
        "enforced": enforced,
        "passed": not failures,
        "failures": failures,
        "latest_path": str(latest_production.get("path", "")),
        "phase": phase_name,
        "min_gpu_samples": args.min_latest_production_idle_gpu_samples,
        "observed": {
            "gpu_power_sample_count": gpu_sample_count,
            "raw_gpu_sample_count": raw_gpu_sample_count,
            "avg_power_w": _round(avg_power),
            "max_power_w": _round(peak_power),
            "max_temp_c": _round(peak_temp),
            "p0_fraction": _round(p0_fraction),
        },
    }


def _build_report(args: argparse.Namespace) -> dict[str, Any]:
    generated_at_epoch = time.time()
    snapshot_dir = Path(args.snapshot_dir)
    town = [_summarize_town_snapshot(path, args.target_frame_ms) for path in _latest_files(snapshot_dir, "snapshot_*.json", args.town_count)]
    procedural = [
        _summarize_procedural_snapshot(path)
        for path in _latest_files(snapshot_dir, "procedural_power_snapshot_*.json", args.procedural_count)
    ]
    render_ablation = _summarize_render_ablation(Path(args.render_ablation_summary))
    gpu_telemetry = _summarize_gpu_telemetry_files(args)
    _annotate_town_runs(town, render_ablation, args.production_min_hold_seconds)
    report = {
        "generated_at_epoch": generated_at_epoch,
        "snapshot_dir": str(snapshot_dir),
        "gpu_telemetry_dir": str(Path(args.gpu_telemetry_dir)),
        "target_frame_ms": args.target_frame_ms,
        "production_min_hold_seconds": args.production_min_hold_seconds,
        "town": town,
        "latest_production_town": _latest_production_town(town),
        "production_trend": _production_trend(town),
        "procedural": procedural,
        "latest_procedural_terrain_batch_comparison": _latest_procedural_terrain_batch_comparison(procedural),
        "render_ablation": render_ablation,
        "gpu_telemetry": gpu_telemetry,
        "latest_gpu_telemetry": _latest_gpu_telemetry(gpu_telemetry),
    }
    report["stable_60_gate"] = _stable_60_gate(report, args)
    report["movement_gate"] = _movement_gate(report, args)
    report["stationary_gpu_gate"] = _stationary_gpu_gate(report, args)
    report["idle_gpu_gate"] = _idle_gpu_gate(report, args)
    report["gpu_thermal_gate"] = _gpu_thermal_gate(report, args)
    report["freshness_gate"] = _freshness_gate(report, args)
    return report


def _latest_procedural_failures(report: dict[str, Any]) -> list[str]:
    procedural = report.get("procedural", [])
    if not isinstance(procedural, list) or not procedural:
        return ["no procedural power snapshots found"]
    latest = procedural[0]
    final = _dict(latest.get("final"))
    failures: list[str] = []
    if not bool(latest.get("completed", False)):
        failures.append("latest procedural power snapshot is incomplete")
    if bool(final.get("world_map_active", False)):
        failures.append("latest procedural power snapshot ended in world-map mode")
    if str(final.get("runtime_power_mode", "")) != "deep_idle":
        failures.append(f"latest procedural power mode is {final.get('runtime_power_mode')}, expected deep_idle")
    if bool(final.get("runtime_power_external_world_busy", False)):
        failures.append("latest procedural power snapshot still reports external_world_busy")
    if _int(final.get("building_dirty_visible_chunk_count")) != 0:
        failures.append("latest procedural power snapshot has dirty visible building chunks")
    return failures


def _threshold_failures(report: dict[str, Any], args: argparse.Namespace) -> list[str]:
    failures: list[str] = []
    if args.require_latest_procedural_deep_idle:
        failures.extend(_latest_procedural_failures(report))
    if (
        args.require_latest_procedural_gpu_samples
        or args.max_latest_procedural_gpu_avg_power_w is not None
        or args.max_latest_procedural_gpu_avg_temp_c is not None
        or args.max_latest_procedural_gpu_peak_temp_c is not None
    ):
        procedural = report.get("procedural", [])
        latest_procedural = _dict(procedural[0]) if isinstance(procedural, list) and procedural else {}
        raw_gpu = _dict(latest_procedural.get("raw_gpu"))
        if not latest_procedural:
            failures.append("no procedural power snapshots found")
        elif _int(raw_gpu.get("power_sample_count")) <= 0 or _int(raw_gpu.get("temp_sample_count")) <= 0:
            failures.append("latest procedural power snapshot has no persisted raw GPU samples")
        else:
            avg_power = _float(raw_gpu.get("avg_power_w"))
            avg_temp = _float(raw_gpu.get("avg_temp_c"))
            peak_temp = _float(raw_gpu.get("max_temp_c"))
            if args.max_latest_procedural_gpu_avg_power_w is not None and avg_power > args.max_latest_procedural_gpu_avg_power_w:
                failures.append(
                    "latest procedural average GPU power "
                    f"{avg_power:.3f} W exceeds {args.max_latest_procedural_gpu_avg_power_w:.3f} W"
                )
            if args.max_latest_procedural_gpu_avg_temp_c is not None and avg_temp > args.max_latest_procedural_gpu_avg_temp_c:
                failures.append(
                    "latest procedural average GPU temp "
                    f"{avg_temp:.3f} C exceeds {args.max_latest_procedural_gpu_avg_temp_c:.3f} C"
                )
            if args.max_latest_procedural_gpu_peak_temp_c is not None and peak_temp > args.max_latest_procedural_gpu_peak_temp_c:
                failures.append(
                    "latest procedural peak GPU temp "
                    f"{peak_temp:.3f} C exceeds {args.max_latest_procedural_gpu_peak_temp_c:.3f} C"
                )
    if args.require_latest_procedural_move_render_improvement:
        comparison = _dict(report.get("latest_procedural_terrain_batch_comparison"))
        if not bool(comparison.get("available", False)):
            failures.append(
                "latest procedural terrain batch comparison unavailable: "
                f"{comparison.get('reason', 'unknown')}"
            )
        else:
            move = _dict(comparison.get("move"))
            if _float(move.get("delta_min_fps")) < 0.0:
                failures.append(
                    "latest procedural terrain batching reduced move min FPS "
                    f"by {_float(move.get('delta_min_fps')):.3f}"
                )
            if _float(move.get("delta_avg_draw_calls")) >= 0.0:
                draw_delta = _float(move.get("delta_avg_draw_calls"))
                failures.append(
                    "latest procedural terrain batching did not reduce move draw calls "
                    f"({draw_delta:+.3f})"
                )
            if _float(move.get("delta_avg_objects")) >= 0.0:
                object_delta = _float(move.get("delta_avg_objects"))
                failures.append(
                    "latest procedural terrain batching did not reduce move render objects "
                    f"({object_delta:+.3f})"
                )
    if args.max_latest_procedural_hold_primitive_ratio is not None:
        comparison = _dict(report.get("latest_procedural_terrain_batch_comparison"))
        if not bool(comparison.get("available", False)):
            failures.append(
                "latest procedural terrain batch comparison unavailable: "
                f"{comparison.get('reason', 'unknown')}"
            )
        else:
            hold = _dict(comparison.get("hold"))
            hold_ratio = _float(hold.get("primitive_ratio"))
            if hold_ratio > float(args.max_latest_procedural_hold_primitive_ratio):
                failures.append(
                    "latest procedural terrain batching hold primitive ratio "
                    f"{hold_ratio:.3f} exceeds {args.max_latest_procedural_hold_primitive_ratio:.3f}"
                )
    if args.max_latest_town_avg_ms is not None:
        town = report.get("town", [])
        if not isinstance(town, list) or not town:
            failures.append("no town snapshots found")
        else:
            latest_hold = _dict(_dict(town[0]).get("stationary_hold"))
            latest_avg = _float(latest_hold.get("avg_total_ms"))
            if latest_avg > float(args.max_latest_town_avg_ms):
                failures.append(f"latest town stationary avg {latest_avg:.3f} ms exceeds {args.max_latest_town_avg_ms:.3f} ms")
    if args.max_latest_production_town_avg_ms is not None:
        latest_production = _dict(report.get("latest_production_town"))
        if not latest_production:
            failures.append("no production-like town snapshots found")
        else:
            latest_hold = _dict(latest_production.get("stationary_hold"))
            latest_avg = _float(latest_hold.get("avg_total_ms"))
            if latest_avg > float(args.max_latest_production_town_avg_ms):
                failures.append(
                    "latest production-like town stationary avg "
                    f"{latest_avg:.3f} ms exceeds {args.max_latest_production_town_avg_ms:.3f} ms"
                )
    if args.max_latest_production_town_primitives is not None:
        latest_production = _dict(report.get("latest_production_town"))
        if not latest_production:
            failures.append("no production-like town snapshots found")
        else:
            latest_hold = _dict(latest_production.get("stationary_hold"))
            if not bool(latest_hold.get("has_primitive_metrics", False)):
                failures.append("latest production-like town snapshot has no primitive metrics")
            else:
                latest_primitives = _float(latest_hold.get("avg_primitives"))
                if latest_primitives > float(args.max_latest_production_town_primitives):
                    failures.append(
                        "latest production-like town avg primitives "
                        f"{latest_primitives:.3f} exceeds {args.max_latest_production_town_primitives:.3f}"
                    )
    if args.max_latest_production_hold_pipeline_compilations is not None:
        latest_production = _dict(report.get("latest_production_town"))
        if not latest_production:
            failures.append("no production-like town snapshots found")
        else:
            latest_hold = _dict(latest_production.get("stationary_hold"))
            if not bool(latest_hold.get("has_pipeline_metrics", False)):
                failures.append("latest production-like town snapshot has no pipeline compilation metrics")
            else:
                latest_compilations = _int(latest_hold.get("pipeline_compilations_total_delta"))
                if latest_compilations > int(args.max_latest_production_hold_pipeline_compilations):
                    failures.append(
                        "latest production-like town hold pipeline compilations "
                        f"{latest_compilations} exceed {args.max_latest_production_hold_pipeline_compilations}"
                    )
    required_payload_fragment = str(args.require_latest_production_payload_signature_fragment or "").strip()
    if required_payload_fragment:
        latest_production = _dict(report.get("latest_production_town"))
        if not latest_production:
            failures.append("no production-like town snapshots found")
        else:
            prefab = _dict(latest_production.get("prefab_spawner"))
            signature = str(prefab.get("world_map_baked_building_payload_signature", ""))
            if required_payload_fragment not in signature:
                failures.append(
                    "latest production-like town payload signature "
                    f"'{signature}' does not contain '{required_payload_fragment}'"
                )
    if args.require_latest_production_building_stream_idle:
        latest_production = _dict(report.get("latest_production_town"))
        if not latest_production:
            failures.append("no production-like town snapshots found")
        else:
            building = _dict(latest_production.get("building"))
            prefab = _dict(latest_production.get("prefab_spawner"))
            pending_apply = _int(building.get("pending_world_map_baked_building_apply_phases"))
            pending_build = _int(prefab.get("pending_world_map_baked_payload_build_jobs"))
            pending_payload = _int(prefab.get("pending_world_map_baked_payload_jobs"))
            if pending_apply > 0 or pending_build > 0 or pending_payload > 0:
                failures.append(
                    "latest production-like town building stream not idle "
                    f"(apply={pending_apply}, payload_build={pending_build}, payload_apply={pending_payload})"
                )
    if args.require_latest_production_town_stable_60:
        stable_gate = _dict(report.get("stable_60_gate"))
        for failure in stable_gate.get("failures", []):
            failures.append(f"stable-60 gate: {failure}")
    if args.require_latest_production_town_movement_60 or _movement_gpu_threshold_requested(args):
        movement_gate = _dict(report.get("movement_gate"))
        for failure in movement_gate.get("failures", []):
            failures.append(f"movement gate: {failure}")
    if _stationary_gpu_threshold_requested(args):
        stationary_gpu_gate = _dict(report.get("stationary_gpu_gate"))
        for failure in stationary_gpu_gate.get("failures", []):
            failures.append(f"stationary GPU gate: {failure}")
    if _idle_gpu_threshold_requested(args):
        idle_gpu_gate = _dict(report.get("idle_gpu_gate"))
        for failure in idle_gpu_gate.get("failures", []):
            failures.append(f"idle GPU gate: {failure}")
    if args.require_latest_gpu_telemetry_valid or _gpu_thermal_threshold_requested(args):
        thermal_gate = _dict(report.get("gpu_thermal_gate"))
        for failure in thermal_gate.get("failures", []):
            failures.append(f"gpu thermal gate: {failure}")
    if _freshness_threshold_requested(args):
        freshness_gate = _dict(report.get("freshness_gate"))
        for failure in freshness_gate.get("failures", []):
            failures.append(f"freshness gate: {failure}")
    return failures


def _print_report(report: dict[str, Any]) -> None:
    print("\nPERFORMANCE SNAPSHOT ANALYSIS")
    print("=" * 50)
    town = report.get("town", [])
    if isinstance(town, list) and town:
        print("Town snapshots:")
        for entry in town:
            hold = _dict(_dict(entry).get("stationary_hold"))
            vegetation = _dict(_dict(entry).get("vegetation"))
            print(
                "  {name} hold={hold_complete} avg={avg:.2f}ms over={over:.1f}% "
                "max={max_ms:.1f}ms draws={draws:.1f} objects={objects:.1f} prims={prims} pipes={pipes} veg={veg_batches} "
                "profile={profile} runtime={runtime_mode} role={role}{case}".format(
                    name=Path(str(entry.get("path", ""))).name,
                    hold_complete=bool(entry.get("hold_complete", False)),
                    avg=_float(hold.get("avg_total_ms")),
                    over=_float(hold.get("frames_over_budget_pct")),
                    max_ms=_float(hold.get("max_total_ms")),
                    draws=_float(hold.get("avg_draw_calls")),
                    objects=_float(hold.get("avg_objects")),
                    prims=_format_optional_float(hold.get("avg_primitives"), bool(hold.get("has_primitive_metrics", False)), 0),
                    pipes=_format_optional_int(
                        hold.get("pipeline_compilations_total_delta"),
                        bool(hold.get("has_pipeline_metrics", False)),
                    ),
                    veg_batches=_int(vegetation.get("global_render_batch_count")),
                    profile=bool(vegetation.get("world_map_vegetation_render_profile_active", False)),
                    runtime_mode=str(entry.get("runtime_mode", "")) or "unknown",
                    role=str(entry.get("run_role", "")),
                    case=f" case={entry.get('ablation_case')}" if str(entry.get("ablation_case", "")) else "",
                )
            )
        latest_production = _dict(report.get("latest_production_town"))
        if latest_production:
            hold = _dict(latest_production.get("stationary_hold"))
            hold_gpu = _dict(latest_production.get("stationary_hold_gpu"))
            movement = _dict(latest_production.get("moving_entry"))
            movement_gpu = _dict(latest_production.get("moving_entry_gpu"))
            idle_phase_name, idle_gpu = _select_idle_gpu_phase(latest_production)
            terrain = _dict(latest_production.get("terrain"))
            render_features = _dict(latest_production.get("render_features"))
            render_scene = _dict(latest_production.get("render_scene"))
            building = _dict(latest_production.get("building"))
            prefab = _dict(latest_production.get("prefab_spawner"))
            machine = _dict(latest_production.get("machine_state"))
            has_display_telemetry = bool(render_features.get("display_telemetry_available", False))
            print(
                "Latest production-like town: {name} runtime={runtime_mode} avg={avg:.2f}ms over={over:.1f}% max={max_ms:.1f}ms "
                "chunks={active}/{terrain_chunks}/{water_chunks} full_res={full_res_chunks} rd={render_distance} prims={prims} pipes={pipes} "
                "world_lod={world_lod} nodes={world_lod_nodes} lod_dist={lod_distance} "
                "lod_beyond_rd={lod_beyond_rd} far_lod={far_lod}/{replaced_lod} renderer={renderer}/{driver} "
                "window={window_mode}->{runtime_window_mode} {window_w}x{window_h} vsync={vsync}->{runtime_vsync}".format(
                    name=Path(str(latest_production.get("path", ""))).name,
                    runtime_mode=str(latest_production.get("runtime_mode", "")) or "unknown",
                    avg=_float(hold.get("avg_total_ms")),
                    over=_float(hold.get("frames_over_budget_pct")),
                    max_ms=_float(hold.get("max_total_ms")),
                    active=_int(terrain.get("active_chunk_count")),
                    terrain_chunks=_int(terrain.get("rendered_terrain_chunk_count")),
                    water_chunks=_int(terrain.get("rendered_water_chunk_count")),
                    full_res_chunks=_int(terrain.get("full_res_terrain_drawn_chunk_count")),
                    render_distance=_int(terrain.get("render_distance")),
                    prims=_format_optional_float(hold.get("avg_primitives"), bool(hold.get("has_primitive_metrics", False)), 0),
                    pipes=_format_optional_int(
                        hold.get("pipeline_compilations_total_delta"),
                        bool(hold.get("has_pipeline_metrics", False)),
                    ),
                    world_lod=_int(terrain.get("world_map_lod_chunk_count")),
                    world_lod_nodes=_int(terrain.get("world_map_lod_node_count")),
                    lod_distance=_int(terrain.get("distant_world_map_lod_distance")),
                    lod_beyond_rd=bool(terrain.get("distant_world_map_lod_beyond_render_distance", False)),
                    far_lod=_int(terrain.get("world_map_terrain_batch_far_lod_chunk_count")),
                    replaced_lod=_int(terrain.get("world_map_lod_replaced_terrain_chunk_count")),
                    renderer=str(render_features.get("rendering_method", "")) or "unknown",
                    driver=str(render_features.get("rendering_driver_name", "")) or str(render_features.get("project_rendering_driver_windows", "")) or "unknown",
                    window_mode=_format_optional_int(render_features.get("project_window_mode"), has_display_telemetry),
                    runtime_window_mode=_format_optional_int(render_features.get("runtime_window_mode"), has_display_telemetry),
                    window_w=_format_optional_int(render_features.get("runtime_window_width"), has_display_telemetry),
                    window_h=_format_optional_int(render_features.get("runtime_window_height"), has_display_telemetry),
                    vsync=_format_optional_int(render_features.get("project_vsync_mode"), has_display_telemetry),
                    runtime_vsync=_format_optional_int(render_features.get("runtime_vsync_mode"), has_display_telemetry),
                )
            )
            print(
                "  Stationary GPU: samples={gpu_samples} power={power:.1f}/{peak_power:.1f}W "
                "temp_peak={temp_peak:.1f}C p0={p0:.2f}".format(
                    gpu_samples=_int(hold_gpu.get("power_sample_count")),
                    power=_float(hold_gpu.get("avg_power_w")),
                    peak_power=_float(hold_gpu.get("max_power_w")),
                    temp_peak=_float(hold_gpu.get("max_temp_c")),
                    p0=_float(hold_gpu.get("p0_fraction")),
                )
            )
            print(
                "  Idle GPU: phase={phase} samples={gpu_samples} power={power:.1f}/{peak_power:.1f}W "
                "temp_peak={temp_peak:.1f}C p0={p0:.2f} preflight={preflight:.1f}W".format(
                    phase=idle_phase_name,
                    gpu_samples=_int(idle_gpu.get("power_sample_count")),
                    power=_float(idle_gpu.get("avg_power_w")),
                    peak_power=_float(idle_gpu.get("max_power_w")),
                    temp_peak=_float(idle_gpu.get("max_temp_c")),
                    p0=_float(idle_gpu.get("p0_fraction")),
                    preflight=_float(machine.get("preflight_raw_gpu_power_median_w")),
                )
            )
            print(
                "  Movement: reason={reason} samples={samples} avg={avg:.2f}ms max={max_ms:.1f}ms "
                "gpu_samples={gpu_samples} power={power:.1f}/{peak_power:.1f}W temp_peak={temp_peak:.1f}C "
                "hold_settle={settle:.1f}s timeout={settle_timeout}".format(
                    reason=str(latest_production.get("town_entry_capture_reason", "")) or "unknown",
                    samples=_int(movement.get("sample_count")),
                    avg=_float(movement.get("avg_total_ms")),
                    max_ms=_float(movement.get("max_total_ms")),
                    gpu_samples=_int(movement_gpu.get("power_sample_count")),
                    power=_float(movement_gpu.get("avg_power_w")),
                    peak_power=_float(movement_gpu.get("max_power_w")),
                    temp_peak=_float(movement_gpu.get("max_temp_c")),
                    settle=_float(latest_production.get("hold_settle_elapsed_seconds")),
                    settle_timeout=bool(latest_production.get("hold_settle_timed_out", False)),
                )
            )
            if bool(render_scene.get("available", False)):
                print(
                    "  Render scene: visible_meshes={meshes} surfaces={surfaces} tris={tris} verts={verts} "
                    "terrain_tris={terrain_tris} building_tris={building_tris} vegetation_tris={vegetation_tris} "
                    "multimesh_instances={mm_instances} multimesh_tris={mm_tris} "
                    "frustum_tris={frustum_tris} frustum_terrain_tris={frustum_terrain_tris} "
                    "frustum_vegetation_mm_tris={frustum_vegetation_mm_tris}".format(
                        meshes=_int(render_scene.get("visible_mesh_instances")),
                        surfaces=_int(render_scene.get("visible_mesh_surface_count")),
                        tris=_int(render_scene.get("visible_mesh_triangle_count")),
                        verts=_int(render_scene.get("visible_mesh_vertex_count")),
                        terrain_tris=_int(render_scene.get("visible_terrain_mesh_triangle_count")),
                        building_tris=_int(render_scene.get("visible_building_mesh_triangle_count")),
                        vegetation_tris=_int(render_scene.get("visible_vegetation_mesh_triangle_count")),
                        mm_instances=_int(render_scene.get("visible_multimesh_instance_count")),
                        mm_tris=_int(render_scene.get("visible_multimesh_rendered_triangle_count")),
                        frustum_tris=_int(render_scene.get("frustum_mesh_triangle_count")),
                        frustum_terrain_tris=_int(render_scene.get("frustum_terrain_mesh_triangle_count")),
                        frustum_vegetation_mm_tris=_int(
                            render_scene.get("frustum_vegetation_multimesh_rendered_triangle_count")
                        ),
                    )
                )
            print(
                "  Building stream: payload_sig={payload_sig} prefab_build={prefab_build} prefab_apply={prefab_apply} building_apply={building_apply}".format(
                    payload_sig=str(prefab.get("world_map_baked_building_payload_signature", "")),
                    prefab_build=_int(prefab.get("pending_world_map_baked_payload_build_jobs")),
                    prefab_apply=_int(prefab.get("pending_world_map_baked_payload_jobs")),
                    building_apply=_int(building.get("pending_world_map_baked_building_apply_phases")),
                )
            )
        elif town:
            latest_town = _dict(town[0])
            print(
                "No production-like town snapshot selected. Latest town snapshot {name} is role={role} runtime={runtime_mode}.".format(
                    name=Path(str(latest_town.get("path", ""))).name,
                    role=str(latest_town.get("run_role", "")) or "unknown",
                    runtime_mode=str(latest_town.get("runtime_mode", "")) or "unknown",
                )
            )
        trend = _dict(report.get("production_trend"))
        if trend:
            print(
                "Production trend vs previous: avg={avg:+.2f}ms over={over:+.1f}% draws={draws:+.1f} objects={objects:+.1f} prims={prims}".format(
                    avg=_float(trend.get("delta_avg_total_ms")),
                    over=_float(trend.get("delta_frames_over_budget_pct")),
                    draws=_float(trend.get("delta_avg_draw_calls")),
                    objects=_float(trend.get("delta_avg_objects")),
                    prims=(
                        f"{_float(trend.get('delta_avg_primitives')):+.1f}"
                        if bool(trend.get("has_primitive_metrics", False))
                        else "n/a"
                    ),
                )
            )
        stable_gate = _dict(report.get("stable_60_gate"))
        if stable_gate:
            observed = _dict(stable_gate.get("observed"))
            print(
                "Stable-60 gate: passed={passed} avg={avg:.2f}/{target:.2f}ms over={over:.1f}/{max_over:.1f}% "
                "max={max_ms:.1f}/{max_allowed:.1f}ms >40ms={over40}/{max_over40} streak={streak}/{max_streak}".format(
                    passed=bool(stable_gate.get("passed", False)),
                    avg=_float(observed.get("avg_total_ms")),
                    target=_float(stable_gate.get("target_frame_ms")),
                    over=_float(observed.get("frames_over_budget_pct")),
                    max_over=_float(stable_gate.get("max_over_budget_pct")),
                    max_ms=_float(observed.get("max_total_ms")),
                    max_allowed=_float(stable_gate.get("max_frame_ms")),
                    over40=_int(observed.get("frames_over_40ms")),
                    max_over40=_int(stable_gate.get("max_frames_over_40ms")),
                    streak=_int(observed.get("longest_over_budget_streak")),
                    max_streak=_int(stable_gate.get("max_over_budget_streak")),
                )
            )
        movement_gate = _dict(report.get("movement_gate"))
        if movement_gate:
            observed = _dict(movement_gate.get("observed"))
            print(
                "Movement gate: enforced={enforced} passed={passed} reason={reason} "
                "samples={samples}/{min_samples} avg={avg:.2f}ms max={max_ms:.1f}ms "
                "gpu_samples={gpu_samples}/{min_gpu} power={power:.1f}/{peak_power:.1f}W temp_peak={temp_peak:.1f}C".format(
                    enforced=bool(movement_gate.get("enforced", False)),
                    passed=bool(movement_gate.get("passed", False)),
                    reason=str(observed.get("capture_reason", "")) or "unknown",
                    samples=_int(observed.get("sample_count")),
                    min_samples=_int(movement_gate.get("min_movement_samples")),
                    avg=_float(observed.get("avg_total_ms")),
                    max_ms=_float(observed.get("max_total_ms")),
                    gpu_samples=_int(observed.get("gpu_power_sample_count")),
                    min_gpu=_int(movement_gate.get("min_gpu_samples")),
                    power=_float(observed.get("avg_power_w")),
                    peak_power=_float(observed.get("max_power_w")),
                    temp_peak=_float(observed.get("max_temp_c")),
                )
            )
        stationary_gpu_gate = _dict(report.get("stationary_gpu_gate"))
        if stationary_gpu_gate:
            observed = _dict(stationary_gpu_gate.get("observed"))
            print(
                "Stationary GPU gate: enforced={enforced} passed={passed} "
                "gpu_samples={gpu_samples}/{min_gpu} power={power:.1f}/{peak_power:.1f}W "
                "temp_peak={temp_peak:.1f}C p0={p0:.2f}".format(
                    enforced=bool(stationary_gpu_gate.get("enforced", False)),
                    passed=bool(stationary_gpu_gate.get("passed", False)),
                    gpu_samples=_int(observed.get("gpu_power_sample_count")),
                    min_gpu=_int(stationary_gpu_gate.get("min_gpu_samples")),
                    power=_float(observed.get("avg_power_w")),
                    peak_power=_float(observed.get("max_power_w")),
                    temp_peak=_float(observed.get("max_temp_c")),
                    p0=_float(observed.get("p0_fraction")),
                )
            )
        idle_gpu_gate = _dict(report.get("idle_gpu_gate"))
        if idle_gpu_gate:
            observed = _dict(idle_gpu_gate.get("observed"))
            print(
                "Idle GPU gate: enforced={enforced} passed={passed} phase={phase} "
                "gpu_samples={gpu_samples}/{min_gpu} power={power:.1f}/{peak_power:.1f}W "
                "temp_peak={temp_peak:.1f}C p0={p0:.2f}".format(
                    enforced=bool(idle_gpu_gate.get("enforced", False)),
                    passed=bool(idle_gpu_gate.get("passed", False)),
                    phase=str(idle_gpu_gate.get("phase", "")) or "unknown",
                    gpu_samples=_int(observed.get("gpu_power_sample_count")),
                    min_gpu=_int(idle_gpu_gate.get("min_gpu_samples")),
                    power=_float(observed.get("avg_power_w")),
                    peak_power=_float(observed.get("max_power_w")),
                    temp_peak=_float(observed.get("max_temp_c")),
                    p0=_float(observed.get("p0_fraction")),
                )
            )
    procedural = report.get("procedural", [])
    if isinstance(procedural, list) and procedural:
        print("Procedural power snapshots:")
        for entry in procedural:
            final = _dict(_dict(entry).get("final"))
            active = _dict(_dict(entry).get("active_window"))
            move = _dict(_dict(entry).get("move_window"))
            hold = _dict(_dict(entry).get("hold_window"))
            raw_gpu = _dict(_dict(entry).get("raw_gpu"))
            raw_gpu_move = _dict(_dict(entry).get("raw_gpu_move"))
            raw_gpu_hold = _dict(_dict(entry).get("raw_gpu_hold"))
            render_features = _dict(_dict(entry).get("render_features"))
            visual_capture = _dict(_dict(entry).get("visual_capture"))
            print(
                "  {name} complete={complete} world_map={world_map} power={mode}@{fps} "
                "external_busy={busy} dirty_visible={dirty} chunks={terrain_chunks}/{water_chunks} "
                "glow_off={glow_off} glow_envs={glow_envs} scale={scale_actual:.2f} "
                "viewport_scale={viewport_scale:.2f} shot={shot_saved} "
                "active_avg={avg_fps:.1f}fps min={min_fps:.1f} "
                "draws={draws:.1f} objects={objects:.1f} prims={prims:.1f} "
                "move={move_draws:.1f}/{move_objects:.1f}/{move_prims:.1f} "
                "hold={hold_draws:.1f}/{hold_objects:.1f}/{hold_prims:.1f} "
                "gpu={gpu_power:.1f}/{gpu_power_max:.1f}W {gpu_temp:.1f}/{gpu_temp_max:.1f}C "
                "gpu_move={gpu_move_power:.1f}W gpu_hold={gpu_hold_power:.1f}W "
                "water_dispatch={water_dispatch} water_skips={water_skips} water_build={water_build:.3f}ms "
                "terrain_batches={terrain_batches} terrain_hidden={terrain_hidden} "
                "terrain_near={terrain_near} terrain_far_lod={terrain_far_lod} water_batches={water_batches} hidden={hidden} "
                "water_near={water_near} shadows={shadow_on}/{shadow_off} dirty={water_dirty}".format(
                    name=Path(str(entry.get("path", ""))).name,
                    complete=bool(entry.get("completed", False)),
                    world_map=bool(final.get("world_map_active", False)),
                    mode=str(final.get("runtime_power_mode", "")),
                    fps=_int(final.get("runtime_power_target_fps")),
                    busy=bool(final.get("runtime_power_external_world_busy", False)),
                    dirty=_int(final.get("building_dirty_visible_chunk_count")),
                    terrain_chunks=_int(final.get("rendered_terrain_chunk_count")),
                    water_chunks=_int(final.get("rendered_water_chunk_count")),
                    glow_off=bool(render_features.get("disable_glow", False)),
                    glow_envs=_int(render_features.get("glow_environment_count")),
                    scale_actual=_float(render_features.get("scaling_3d_scale_actual"), 1.0),
                    viewport_scale=_float(final.get("runtime_power_viewport_scale_current"), 0.0),
                    shot_saved=bool(visual_capture.get("saved", False)),
                    avg_fps=_float(active.get("avg_fps")),
                    min_fps=_float(active.get("min_fps")),
                    draws=_float(active.get("avg_draw_calls")),
                    objects=_float(active.get("avg_objects")),
                    prims=_float(active.get("avg_primitives")),
                    move_draws=_float(move.get("avg_draw_calls")),
                    move_objects=_float(move.get("avg_objects")),
                    move_prims=_float(move.get("avg_primitives")),
                    hold_draws=_float(hold.get("avg_draw_calls")),
                    hold_objects=_float(hold.get("avg_objects")),
                    hold_prims=_float(hold.get("avg_primitives")),
                    gpu_power=_float(raw_gpu.get("avg_power_w")),
                    gpu_power_max=_float(raw_gpu.get("max_power_w")),
                    gpu_temp=_float(raw_gpu.get("avg_temp_c")),
                    gpu_temp_max=_float(raw_gpu.get("max_temp_c")),
                    gpu_move_power=_float(raw_gpu_move.get("avg_power_w")),
                    gpu_hold_power=_float(raw_gpu_hold.get("avg_power_w")),
                    water_dispatch=bool(final.get("last_gpu_water_density_dispatched", False)),
                    water_skips=_int(final.get("gpu_water_density_skipped_count")),
                    water_build=_float(final.get("last_cpu_mesh_build_water_ms")),
                    terrain_batches=_int(active.get("max_terrain_visual_batch_node_count")),
                    terrain_hidden=_int(active.get("max_terrain_visual_batch_hidden_chunk_count")),
                    terrain_near=_int(active.get("max_terrain_visual_batch_near_cull_chunk_count")),
                    terrain_far_lod=_int(active.get("max_world_map_terrain_batch_far_lod_chunk_count")),
                    water_batches=_int(active.get("max_water_visual_batch_node_count")),
                    hidden=_int(active.get("max_water_visual_batch_hidden_chunk_count")),
                    water_near=_int(active.get("max_water_visual_batch_near_cull_chunk_count")),
                    shadow_on=_int(final.get("last_terrain_shadow_lod_enabled_count")),
                    shadow_off=_int(final.get("last_terrain_shadow_lod_disabled_count")),
                    water_dirty=_int(final.get("water_visual_batch_dirty_count")),
                )
            )
        comparison = _dict(report.get("latest_procedural_terrain_batch_comparison"))
        if comparison:
            if bool(comparison.get("available", False)):
                move = _dict(comparison.get("move"))
                hold = _dict(comparison.get("hold"))
                active = _dict(comparison.get("active"))
                print(
                    "Procedural terrain batch comparison: "
                    "move d_fps={move_fps:+.1f} d_draws={move_draws:+.1f} d_objects={move_objects:+.1f} "
                    "d_prims={move_prims:+.1f}; hold d_draws={hold_draws:+.1f} d_objects={hold_objects:+.1f} "
                    "d_prims={hold_prims:+.1f} ratio={hold_ratio:.2f}; active d_draws={active_draws:+.1f}".format(
                        move_fps=_float(move.get("delta_min_fps")),
                        move_draws=_float(move.get("delta_avg_draw_calls")),
                        move_objects=_float(move.get("delta_avg_objects")),
                        move_prims=_float(move.get("delta_avg_primitives")),
                        hold_draws=_float(hold.get("delta_avg_draw_calls")),
                        hold_objects=_float(hold.get("delta_avg_objects")),
                        hold_prims=_float(hold.get("delta_avg_primitives")),
                        hold_ratio=_float(hold.get("primitive_ratio")),
                        active_draws=_float(active.get("delta_avg_draw_calls")),
                    )
                )
            else:
                print(f"Procedural terrain batch comparison: unavailable ({comparison.get('reason', 'unknown')})")
    gpu_telemetry = report.get("gpu_telemetry", [])
    if isinstance(gpu_telemetry, list) and gpu_telemetry:
        print("Raw GPU telemetry:")
        for entry in gpu_telemetry:
            latest = _dict(entry)
            print(
                "  {name} cases={cases} runs={runs} invalid={invalid} hold={hold:.0f}s".format(
                    name=Path(str(latest.get("path", ""))).name,
                    cases=",".join(str(case) for case in _list(latest.get("cases"))),
                    runs=_int(latest.get("run_count")),
                    invalid=_int(latest.get("invalid_run_count")),
                    hold=_float(latest.get("hold_seconds")),
                )
            )
            for run in _list(latest.get("runs"))[:4]:
                if not isinstance(run, dict):
                    continue
                hold = _dict(run.get("stationary_hold_gpu"))
                if not _has_samples(hold):
                    hold = _dict(run.get("estimated_hold_gpu"))
                print(
                    "    {case}#{repeat} rc={returncode} samples={samples} power={power:.1f}W temp={temp:.1f}/{peak:.1f}C failures={failures}".format(
                        case=str(run.get("case", "")),
                        repeat=_int(run.get("repeat_index")),
                        returncode=_int(run.get("returncode"), -1),
                        samples=_int(hold.get("sample_count")),
                        power=_float(hold.get("avg_power_w")),
                        temp=_float(hold.get("avg_temp_c")),
                        peak=_float(hold.get("max_temp_c")),
                        failures=len(_list(run.get("failure_reasons"))),
                    )
                )
        thermal_gate = _dict(report.get("gpu_thermal_gate"))
        if thermal_gate:
            observed = _dict(thermal_gate.get("observed"))
            print(
                "GPU thermal gate: enforced={enforced} passed={passed} invalid={invalid} "
                "hold_power={power:.1f}W hold_temp={temp:.1f}/{peak:.1f}C".format(
                    enforced=bool(thermal_gate.get("enforced", False)),
                    passed=bool(thermal_gate.get("passed", False)),
                    invalid=_int(observed.get("invalid_run_count")),
                    power=_float(observed.get("max_hold_avg_power_w")),
                    temp=_float(observed.get("max_hold_avg_temp_c")),
                    peak=_float(observed.get("max_hold_peak_temp_c")),
                )
            )
    freshness_gate = _dict(report.get("freshness_gate"))
    if freshness_gate:
        observed = _dict(freshness_gate.get("observed"))
        print(
            "Freshness gate: enforced={enforced} passed={passed} town={town}h procedural={procedural}h gpu={gpu}h".format(
                enforced=bool(freshness_gate.get("enforced", False)),
                passed=bool(freshness_gate.get("passed", False)),
                town=observed.get("latest_production_town_age_hours"),
                procedural=observed.get("latest_procedural_age_hours"),
                gpu=observed.get("latest_gpu_telemetry_age_hours"),
            )
        )
    render_ablation = _dict(report.get("render_ablation"))
    results = render_ablation.get("results", [])
    if isinstance(results, list) and results:
        print("Render ablation summary:")
        for result in results:
            if not isinstance(result, dict):
                continue
            print(
                "  {case} avg={avg:.2f}ms draws={draws:.1f} objects={objects:.1f} prims={prims} "
                "pipes={pipes} veg={veg} d_draws={delta_draws:+.1f}".format(
                    case=str(result.get("case", "")),
                    avg=_float(result.get("avg_total_ms")),
                    draws=_float(result.get("avg_draw_calls")),
                    objects=_float(result.get("avg_objects")),
                    prims=_format_optional_float(result.get("avg_primitives"), bool(result.get("has_primitive_metrics", False)), 0),
                    pipes=_format_optional_int(
                        result.get("pipeline_compilations_total_delta"),
                        bool(result.get("has_pipeline_metrics", False)),
                    ),
                    veg=_int(result.get("vegetation_global_batches")),
                    delta_draws=_float(result.get("delta_avg_draw_calls")),
                )
            )
    print("=" * 50)


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze existing Godot performance snapshots without launching Godot.")
    parser.add_argument("--snapshot-dir", default=str(town_runner.SNAPSHOT_DIR))
    parser.add_argument("--town-count", type=int, default=5)
    parser.add_argument("--procedural-count", type=int, default=5)
    parser.add_argument("--target-frame-ms", type=float, default=1000.0 / 60.0)
    parser.add_argument("--production-min-hold-seconds", type=float, default=DEFAULT_PRODUCTION_MIN_HOLD_SECONDS)
    parser.add_argument("--render-ablation-summary", default=str(DEFAULT_RENDER_ABLATION_SUMMARY))
    parser.add_argument("--gpu-telemetry-dir", default=str(DEFAULT_GPU_TELEMETRY_DIR))
    parser.add_argument("--gpu-telemetry-count", type=int, default=3)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--require-latest-procedural-deep-idle", action="store_true")
    parser.add_argument("--require-latest-procedural-gpu-samples", action="store_true")
    parser.add_argument("--max-latest-procedural-gpu-avg-power-w", type=float, default=None)
    parser.add_argument("--max-latest-procedural-gpu-avg-temp-c", type=float, default=None)
    parser.add_argument("--max-latest-procedural-gpu-peak-temp-c", type=float, default=None)
    parser.add_argument("--require-latest-procedural-move-render-improvement", action="store_true")
    parser.add_argument("--max-latest-procedural-hold-primitive-ratio", type=float, default=None)
    parser.add_argument("--max-latest-town-avg-ms", type=float, default=None)
    parser.add_argument("--max-latest-production-town-avg-ms", type=float, default=None)
    parser.add_argument("--max-latest-production-town-primitives", type=float, default=None)
    parser.add_argument("--max-latest-production-hold-pipeline-compilations", type=int, default=None)
    parser.add_argument("--require-latest-production-payload-signature-fragment", default="")
    parser.add_argument("--require-latest-production-building-stream-idle", action="store_true")
    parser.add_argument("--require-latest-production-town-stable-60", action="store_true")
    parser.add_argument("--max-stable-60-over-budget-pct", type=float, default=DEFAULT_STABLE_60_MAX_OVER_BUDGET_PCT)
    parser.add_argument("--max-stable-60-frame-ms", type=float, default=DEFAULT_STABLE_60_MAX_FRAME_MS)
    parser.add_argument("--max-stable-60-frames-over-40ms", type=int, default=DEFAULT_STABLE_60_MAX_FRAMES_OVER_40MS)
    parser.add_argument("--max-stable-60-over-budget-streak", type=int, default=DEFAULT_STABLE_60_MAX_OVER_BUDGET_STREAK)
    parser.add_argument("--require-latest-production-town-movement-60", action="store_true")
    parser.add_argument("--min-latest-production-moving-samples", type=int, default=DEFAULT_MOVEMENT_MIN_SAMPLES)
    parser.add_argument("--max-movement-60-over-budget-pct", type=float, default=DEFAULT_MOVEMENT_60_MAX_OVER_BUDGET_PCT)
    parser.add_argument("--max-movement-60-frame-ms", type=float, default=DEFAULT_MOVEMENT_60_MAX_FRAME_MS)
    parser.add_argument("--max-movement-60-frames-over-50ms", type=int, default=DEFAULT_MOVEMENT_60_MAX_FRAMES_OVER_50MS)
    parser.add_argument("--require-latest-production-movement-gpu-samples", action="store_true")
    parser.add_argument("--min-latest-production-movement-gpu-samples", type=int, default=DEFAULT_MOVEMENT_MIN_GPU_SAMPLES)
    parser.add_argument("--max-latest-production-movement-gpu-avg-power-w", type=float, default=None)
    parser.add_argument("--max-latest-production-movement-gpu-peak-power-w", type=float, default=None)
    parser.add_argument("--max-latest-production-movement-gpu-peak-temp-c", type=float, default=None)
    parser.add_argument("--require-latest-production-stationary-gpu-samples", action="store_true")
    parser.add_argument("--min-latest-production-stationary-gpu-samples", type=int, default=DEFAULT_STATIONARY_GPU_MIN_SAMPLES)
    parser.add_argument("--max-latest-production-stationary-gpu-avg-power-w", type=float, default=None)
    parser.add_argument("--max-latest-production-stationary-gpu-peak-power-w", type=float, default=None)
    parser.add_argument("--max-latest-production-stationary-gpu-peak-temp-c", type=float, default=None)
    parser.add_argument("--max-latest-production-stationary-gpu-p0-fraction", type=float, default=None)
    parser.add_argument("--require-latest-production-idle-gpu-samples", action="store_true")
    parser.add_argument("--min-latest-production-idle-gpu-samples", type=int, default=DEFAULT_IDLE_GPU_MIN_SAMPLES)
    parser.add_argument("--max-latest-production-idle-gpu-avg-power-w", type=float, default=None)
    parser.add_argument("--max-latest-production-idle-gpu-peak-power-w", type=float, default=None)
    parser.add_argument("--max-latest-production-idle-gpu-peak-temp-c", type=float, default=None)
    parser.add_argument("--max-latest-production-idle-gpu-p0-fraction", type=float, default=None)
    parser.add_argument("--require-latest-gpu-telemetry-valid", action="store_true")
    parser.add_argument("--max-latest-gpu-hold-avg-power-w", type=float, default=None)
    parser.add_argument("--max-latest-gpu-hold-avg-temp-c", type=float, default=None)
    parser.add_argument("--max-latest-gpu-hold-peak-temp-c", type=float, default=None)
    parser.add_argument("--max-latest-production-town-age-hours", type=float, default=None)
    parser.add_argument("--max-latest-procedural-age-hours", type=float, default=None)
    parser.add_argument("--max-latest-gpu-telemetry-age-hours", type=float, default=None)
    args = parser.parse_args()

    report = _build_report(args)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    _print_report(report)

    failures = _threshold_failures(report, args)
    if failures:
        print("\nPERFORMANCE SNAPSHOT ANALYSIS FAILED")
        for failure in failures:
            print(f"- {failure}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
