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
    render_active_samples = _int(window.get("render_active_sample_count"))
    return {
        "sample_count": sample_count,
        "render_active_sample_count": render_active_samples,
        "avg_fps": _round(_float(window.get("avg_fps"))),
        "avg_total_ms": _round(_float(window.get("avg_total_ms"))),
        "max_total_ms": _round(_float(window.get("max_total_ms"))),
        "frames_over_budget": frames_over_budget,
        "frames_over_budget_pct": _round((float(frames_over_budget) / float(sample_count)) * 100.0) if sample_count > 0 else 0.0,
        "frames_over_40ms": _int(window.get("frames_over_40ms")),
        "frames_over_50ms": _int(window.get("frames_over_50ms")),
        "longest_over_budget_streak": _int(window.get("longest_over_budget_streak")),
        "avg_draw_calls": _round(_float(window.get("avg_draw_calls"))),
        "avg_objects": _round(_float(window.get("avg_objects"))),
        "stable_top_bucket": str(window.get("stable_top_bucket", "")),
        "peak_top_bucket": str(window.get("peak_top_bucket", "")),
        "stable_60_average": _float(window.get("avg_total_ms")) <= target_frame_ms,
        "render_loop_suspended_samples": _int(window.get("terrain_runtime_power_render_loop_suspended_samples")),
        "world_work_suspended_samples": _int(window.get("terrain_runtime_power_world_work_suspended_samples")),
    }


def _summarize_town_snapshot(path: Path, target_frame_ms: float) -> dict[str, Any]:
    snapshot = _read_json(path)
    stationary_hold = _dict(snapshot.get("stationary_hold_window"))
    town_entry = _dict(snapshot.get("town_entry_window"))
    telemetry = _dict(snapshot.get("system_telemetry"))
    terrain = _dict(telemetry.get("terrain_manager"))
    building = _dict(telemetry.get("building_manager"))
    vegetation = _dict(telemetry.get("vegetation_manager"))
    entities = _dict(telemetry.get("entity_manager"))
    return {
        "path": str(path),
        "modified_epoch": path.stat().st_mtime,
        "hold_complete": bool(snapshot.get("benchmark_hold_complete", False)),
        "hold_seconds": _float(snapshot.get("benchmark_hold_seconds")),
        "stationary_hold": _window_summary(stationary_hold, target_frame_ms),
        "town_entry": _window_summary(town_entry, target_frame_ms),
        "terrain": {
            "world_map_active": bool(terrain.get("world_map_active", False)),
            "runtime_power_mode": str(terrain.get("runtime_power_mode", "")),
            "runtime_power_target_fps": _int(terrain.get("runtime_power_target_fps")),
            "rendered_terrain_chunk_count": _int(terrain.get("rendered_terrain_chunk_count")),
            "rendered_water_chunk_count": _int(terrain.get("rendered_water_chunk_count")),
        },
        "building": {
            "dirty_visible_chunk_count": _int(building.get("dirty_visible_chunk_count")),
            "visible_world_map_baked_building_visual_nodes": _int(building.get("visible_world_map_baked_building_visual_nodes")),
            "visible_world_map_baked_building_visual_surfaces": _int(building.get("visible_world_map_baked_building_visual_surfaces")),
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


def _summarize_procedural_snapshot(path: Path) -> dict[str, Any]:
    snapshot = _read_json(path)
    final_sample = _dict(snapshot.get("final_sample"))
    terrain = _dict(final_sample.get("terrain"))
    building = _dict(final_sample.get("building"))
    vegetation = _dict(final_sample.get("vegetation"))
    return {
        "path": str(path),
        "modified_epoch": path.stat().st_mtime,
        "completed": bool(snapshot.get("completed", False)),
        "move_seconds": _float(snapshot.get("move_seconds")),
        "hold_seconds": _float(snapshot.get("hold_seconds")),
        "sample_count": len(snapshot.get("samples", [])) if isinstance(snapshot.get("samples"), list) else 0,
        "final": {
            "world_map_active": bool(terrain.get("world_map_active", False)),
            "runtime_power_mode": str(terrain.get("runtime_power_mode", "")),
            "runtime_power_target_fps": _int(terrain.get("runtime_power_target_fps")),
            "runtime_power_active_reason": str(terrain.get("runtime_power_active_reason", "")),
            "runtime_power_external_world_busy": bool(terrain.get("runtime_power_external_world_busy", False)),
            "runtime_power_world_work_suspended": bool(terrain.get("runtime_power_world_work_suspended", False)),
            "runtime_power_render_loop_suspended": bool(terrain.get("runtime_power_render_loop_suspended", False)),
            "runtime_power_render_loop_enabled": bool(terrain.get("runtime_power_render_loop_enabled", True)),
            "building_dirty_visible_chunk_count": _int(building.get("dirty_visible_chunk_count")),
            "vegetation_pending_chunks": _int(vegetation.get("pending_chunks")),
        },
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
                "delta_avg_total_ms": _round(_float(result.get("delta_avg_total_ms"))),
                "delta_avg_draw_calls": _round(_float(result.get("delta_avg_draw_calls"))),
                "delta_avg_objects": _round(_float(result.get("delta_avg_objects"))),
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


def _annotate_town_runs(town: list[dict[str, Any]], render_ablation: dict[str, Any]) -> None:
    cases_by_snapshot = _ablation_cases_by_snapshot(render_ablation)
    for entry in town:
        path = str(Path(str(entry.get("path", ""))))
        ablation_case = cases_by_snapshot.get(path, "")
        if ablation_case and ablation_case != "baseline":
            run_role = "ablation_control"
        elif ablation_case == "baseline":
            run_role = "ablation_baseline"
        else:
            run_role = "production_like"
        entry["ablation_case"] = ablation_case
        entry["run_role"] = run_role
        entry["production_candidate"] = run_role != "ablation_control"


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
    return {
        "latest_path": str(latest.get("path", "")),
        "previous_path": str(previous.get("path", "")),
        "delta_avg_total_ms": _round(_float(latest_hold.get("avg_total_ms")) - _float(previous_hold.get("avg_total_ms"))),
        "delta_frames_over_budget_pct": _round(
            _float(latest_hold.get("frames_over_budget_pct")) - _float(previous_hold.get("frames_over_budget_pct"))
        ),
        "delta_avg_draw_calls": _round(_float(latest_hold.get("avg_draw_calls")) - _float(previous_hold.get("avg_draw_calls"))),
        "delta_avg_objects": _round(_float(latest_hold.get("avg_objects")) - _float(previous_hold.get("avg_objects"))),
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
    if avg_ms > args.target_frame_ms:
        failures.append(f"avg frame time {avg_ms:.3f} ms exceeds target {args.target_frame_ms:.3f} ms")
    if over_budget_pct > args.max_stable_60_over_budget_pct:
        failures.append(
            f"over-budget frames {over_budget_pct:.3f}% exceed {args.max_stable_60_over_budget_pct:.3f}%"
        )
    if max_ms > args.max_stable_60_frame_ms:
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
    _annotate_town_runs(town, render_ablation)
    report = {
        "generated_at_epoch": generated_at_epoch,
        "snapshot_dir": str(snapshot_dir),
        "gpu_telemetry_dir": str(Path(args.gpu_telemetry_dir)),
        "target_frame_ms": args.target_frame_ms,
        "town": town,
        "latest_production_town": _latest_production_town(town),
        "production_trend": _production_trend(town),
        "procedural": procedural,
        "render_ablation": render_ablation,
        "gpu_telemetry": gpu_telemetry,
        "latest_gpu_telemetry": _latest_gpu_telemetry(gpu_telemetry),
    }
    report["stable_60_gate"] = _stable_60_gate(report, args)
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
    if args.require_latest_production_town_stable_60:
        stable_gate = _dict(report.get("stable_60_gate"))
        for failure in stable_gate.get("failures", []):
            failures.append(f"stable-60 gate: {failure}")
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
                "max={max_ms:.1f}ms draws={draws:.1f} objects={objects:.1f} veg={veg_batches} "
                "profile={profile} role={role}{case}".format(
                    name=Path(str(entry.get("path", ""))).name,
                    hold_complete=bool(entry.get("hold_complete", False)),
                    avg=_float(hold.get("avg_total_ms")),
                    over=_float(hold.get("frames_over_budget_pct")),
                    max_ms=_float(hold.get("max_total_ms")),
                    draws=_float(hold.get("avg_draw_calls")),
                    objects=_float(hold.get("avg_objects")),
                    veg_batches=_int(vegetation.get("global_render_batch_count")),
                    profile=bool(vegetation.get("world_map_vegetation_render_profile_active", False)),
                    role=str(entry.get("run_role", "")),
                    case=f" case={entry.get('ablation_case')}" if str(entry.get("ablation_case", "")) else "",
                )
            )
        latest_production = _dict(report.get("latest_production_town"))
        if latest_production:
            hold = _dict(latest_production.get("stationary_hold"))
            print(
                "Latest production-like town: {name} avg={avg:.2f}ms over={over:.1f}% max={max_ms:.1f}ms".format(
                    name=Path(str(latest_production.get("path", ""))).name,
                    avg=_float(hold.get("avg_total_ms")),
                    over=_float(hold.get("frames_over_budget_pct")),
                    max_ms=_float(hold.get("max_total_ms")),
                )
            )
        trend = _dict(report.get("production_trend"))
        if trend:
            print(
                "Production trend vs previous: avg={avg:+.2f}ms over={over:+.1f}% draws={draws:+.1f} objects={objects:+.1f}".format(
                    avg=_float(trend.get("delta_avg_total_ms")),
                    over=_float(trend.get("delta_frames_over_budget_pct")),
                    draws=_float(trend.get("delta_avg_draw_calls")),
                    objects=_float(trend.get("delta_avg_objects")),
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
    procedural = report.get("procedural", [])
    if isinstance(procedural, list) and procedural:
        print("Procedural power snapshots:")
        for entry in procedural:
            final = _dict(_dict(entry).get("final"))
            print(
                "  {name} complete={complete} world_map={world_map} power={mode}@{fps} "
                "external_busy={busy} dirty_visible={dirty}".format(
                    name=Path(str(entry.get("path", ""))).name,
                    complete=bool(entry.get("completed", False)),
                    world_map=bool(final.get("world_map_active", False)),
                    mode=str(final.get("runtime_power_mode", "")),
                    fps=_int(final.get("runtime_power_target_fps")),
                    busy=bool(final.get("runtime_power_external_world_busy", False)),
                    dirty=_int(final.get("building_dirty_visible_chunk_count")),
                )
            )
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
                "  {case} avg={avg:.2f}ms draws={draws:.1f} objects={objects:.1f} "
                "veg={veg} d_draws={delta_draws:+.1f}".format(
                    case=str(result.get("case", "")),
                    avg=_float(result.get("avg_total_ms")),
                    draws=_float(result.get("avg_draw_calls")),
                    objects=_float(result.get("avg_objects")),
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
    parser.add_argument("--render-ablation-summary", default=str(DEFAULT_RENDER_ABLATION_SUMMARY))
    parser.add_argument("--gpu-telemetry-dir", default=str(DEFAULT_GPU_TELEMETRY_DIR))
    parser.add_argument("--gpu-telemetry-count", type=int, default=3)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--require-latest-procedural-deep-idle", action="store_true")
    parser.add_argument("--max-latest-town-avg-ms", type=float, default=None)
    parser.add_argument("--max-latest-production-town-avg-ms", type=float, default=None)
    parser.add_argument("--require-latest-production-town-stable-60", action="store_true")
    parser.add_argument("--max-stable-60-over-budget-pct", type=float, default=DEFAULT_STABLE_60_MAX_OVER_BUDGET_PCT)
    parser.add_argument("--max-stable-60-frame-ms", type=float, default=DEFAULT_STABLE_60_MAX_FRAME_MS)
    parser.add_argument("--max-stable-60-frames-over-40ms", type=int, default=DEFAULT_STABLE_60_MAX_FRAMES_OVER_40MS)
    parser.add_argument("--max-stable-60-over-budget-streak", type=int, default=DEFAULT_STABLE_60_MAX_OVER_BUDGET_STREAK)
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
