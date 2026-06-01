#!/usr/bin/env python3
"""Audit render and logic work that remains active during town idle.

This script is intentionally analysis-only. It reads an existing town snapshot
or raw baseline telemetry artifact and reports what still renders or ticks while
the player is stationary.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
LOCKED_BASELINE_RAW = REPO_ROOT / ".agent" / "gpu-telemetry" / "town_stall_raw_baseline_20260601_143119.json"


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _float(value: Any, default: float = 0.0) -> float:
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return default
    return default


def _int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        try:
            return int(float(value))
        except ValueError:
            return default
    return default


def _bool(value: Any) -> bool:
    return bool(value)


def _fmt_float(value: Any, digits: int = 3, suffix: str = "") -> str:
    if value is None:
        return "n/a"
    return f"{_float(value):.{digits}f}{suffix}"


def _fmt_int(value: Any) -> str:
    if value is None:
        return "n/a"
    return f"{_int(value):,}"


def _fmt_bool(value: Any) -> str:
    return "yes" if bool(value) else "no"


def _safe_percent(numerator: float, denominator: float) -> float:
    if denominator <= 0.0:
        return 0.0
    return numerator / denominator * 100.0


def _path_from_raw(raw: dict[str, Any]) -> Path | None:
    for run in _list(raw.get("runs")):
        snapshot_path = _dict(_dict(run).get("snapshot")).get("snapshot_path")
        if snapshot_path:
            path = Path(str(snapshot_path))
            if path.exists():
                return path
    return None


def _select_run(raw: dict[str, Any]) -> dict[str, Any]:
    runs = [_dict(run) for run in _list(raw.get("runs"))]
    for run in runs:
        if _int(run.get("returncode"), -1) == 0 and not _list(run.get("failure_reasons")):
            return run
    return runs[0] if runs else {}


def _select_snapshot(args: argparse.Namespace) -> tuple[Path | None, dict[str, Any], Path | None, dict[str, Any]]:
    raw_path = Path(args.raw).resolve() if args.raw else None
    if raw_path is None and not args.snapshot and LOCKED_BASELINE_RAW.exists():
        raw_path = LOCKED_BASELINE_RAW
    if raw_path is None and args.latest_raw:
        matches = sorted((REPO_ROOT / ".agent" / "gpu-telemetry").glob("town_stall_raw_baseline_*.json"), key=lambda p: p.stat().st_mtime)
        raw_path = matches[-1] if matches else None

    raw: dict[str, Any] = {}
    if raw_path is not None:
        raw = _read_json(raw_path)

    snapshot_path = Path(args.snapshot).resolve() if args.snapshot else None
    if snapshot_path is None and raw:
        snapshot_path = _path_from_raw(raw)

    snapshot: dict[str, Any] = {}
    if snapshot_path is not None and snapshot_path.exists():
        snapshot = _read_json(snapshot_path)

    return raw_path, raw, snapshot_path, snapshot


def _raw_baseline_summary(raw: dict[str, Any]) -> dict[str, Any]:
    run = _select_run(raw)
    aggregate = _dict(raw.get("aggregate"))
    aggregate_case = _dict(aggregate.get(str(run.get("case", ""))))
    snapshot_summary = _dict(run.get("snapshot"))
    stationary_gpu = _dict(run.get("stationary_hold_gpu"))
    estimated_hold_gpu = _dict(run.get("estimated_hold_gpu"))
    last20_gpu = _dict(run.get("last_20s_gpu"))
    moving_gpu = _dict(run.get("moving_entry_gpu"))
    efficiency = _dict(run.get("efficiency"))
    town_metrics = _dict(snapshot_summary.get("town_metrics"))
    stationary_metrics = _dict(snapshot_summary.get("stationary_hold_metrics"))
    return {
        "case": run.get("case"),
        "valid": _int(run.get("returncode"), -1) == 0 and not _list(run.get("failure_reasons")),
        "failure_reasons": _list(run.get("failure_reasons")),
        "avg_fps": aggregate_case.get("avg_fps", town_metrics.get("average_fps")),
        "hold_power_w": aggregate_case.get("avg_hold_power_w", estimated_hold_gpu.get("avg_power_w")),
        "stationary_hold_power_w": aggregate_case.get("avg_stationary_hold_power_w", stationary_gpu.get("avg_power_w")),
        "moving_power_w": aggregate_case.get("avg_moving_power_w", moving_gpu.get("avg_power_w")),
        "last20_power_w": aggregate_case.get("avg_last20_power_w", last20_gpu.get("avg_power_w")),
        "stationary_gpu_util_pct": stationary_gpu.get("avg_gpu_util_pct"),
        "stationary_p0_fraction": stationary_gpu.get("p0_fraction"),
        "stationary_max_gpu_temp_c": stationary_gpu.get("max_temp_c"),
        "avg_frame_ms": town_metrics.get("avg_total_ms"),
        "stationary_avg_frame_ms": stationary_metrics.get("avg_total_ms"),
        "stationary_max_frame_ms": stationary_metrics.get("max_total_ms"),
        "frames_over_40ms": stationary_metrics.get("frames_over_40ms", town_metrics.get("frames_over_40ms")),
        "frames_over_50ms": stationary_metrics.get("frames_over_50ms", town_metrics.get("frames_over_50ms")),
        "wpf60": efficiency.get("stationary_hold_wpf60", efficiency.get("hold_wpf60")),
    }


def _render_summary(snapshot: dict[str, Any], raw: dict[str, Any]) -> dict[str, Any]:
    telemetry = _dict(snapshot.get("system_telemetry"))
    terrain = _dict(telemetry.get("terrain_manager"))
    vegetation = _dict(telemetry.get("vegetation_manager"))
    building = _dict(telemetry.get("building_manager"))
    stationary = _dict(snapshot.get("stationary_hold_window"))
    town_window = _dict(snapshot.get("town_entry_window"))

    run = _select_run(raw)
    raw_snapshot = _dict(run.get("snapshot"))
    raw_pressure = _dict(raw_snapshot.get("render_pressure"))
    raw_vegetation = _dict(raw_snapshot.get("vegetation_render"))
    raw_terrain_batch = _dict(raw_snapshot.get("terrain_batch"))

    avg_primitives = stationary.get("avg_primitives", raw_pressure.get("avg_primitives"))
    avg_draw_calls = stationary.get("avg_draw_calls", raw_pressure.get("avg_draw_calls"))
    avg_objects = stationary.get("avg_objects")
    avg_process_ms = stationary.get("avg_process_ms", raw_pressure.get("avg_process_ms"))
    avg_physics_ms = stationary.get("avg_physics_ms", raw_pressure.get("avg_physics_ms"))
    avg_other_ms = stationary.get("avg_other_ms", raw_pressure.get("avg_other_ms"))
    avg_total_ms = stationary.get("avg_total_ms", raw_pressure.get("avg_total_ms"))

    terrain_prims = terrain.get(
        "terrain_visual_batch_primitive_count",
        raw_terrain_batch.get("terrain_visual_batch_primitive_count", raw_pressure.get("terrain_visual_primitives")),
    )
    terrain_visible_prims = terrain.get("terrain_visual_visible_primitive_count", raw_terrain_batch.get("terrain_visual_visible_primitive_count"))
    vegetation_prims = vegetation.get(
        "global_render_estimated_primitives",
        raw_vegetation.get("global_render_estimated_primitives", raw_pressure.get("vegetation_primitives")),
    )
    tree_prims = vegetation.get(
        "global_tree_render_estimated_primitives",
        raw_vegetation.get("global_tree_render_estimated_primitives", raw_pressure.get("tree_primitives")),
    )
    grass_prims = vegetation.get(
        "global_grass_render_estimated_primitives",
        raw_vegetation.get("global_grass_render_estimated_primitives", raw_pressure.get("grass_primitives")),
    )
    rock_prims = vegetation.get(
        "global_rock_render_estimated_primitives",
        raw_vegetation.get("global_rock_render_estimated_primitives", raw_pressure.get("rock_primitives")),
    )
    alpha_empty = vegetation.get(
        "global_render_estimated_alpha_empty_primitive_equivalent",
        raw_vegetation.get("global_render_estimated_alpha_empty_primitive_equivalent", raw_pressure.get("alpha_empty_primitive_equivalent")),
    )
    known_prims = _float(terrain_prims) + _float(vegetation_prims)
    avg_prims_float = _float(avg_primitives)

    return {
        "avg_primitives": avg_primitives,
        "avg_draw_calls": avg_draw_calls,
        "avg_objects": avg_objects,
        "avg_total_ms": avg_total_ms,
        "avg_process_ms": avg_process_ms,
        "avg_physics_ms": avg_physics_ms,
        "avg_other_ms": avg_other_ms,
        "known_render_primitives": known_prims,
        "known_share_of_avg_primitives": _safe_percent(known_prims, avg_prims_float),
        "terrain_primitives": terrain_prims,
        "terrain_visible_primitives": terrain_visible_prims,
        "terrain_batch_nodes": terrain.get("terrain_visual_batch_node_count", raw_terrain_batch.get("terrain_visual_batch_node_count")),
        "terrain_batch_dirty": terrain.get("terrain_visual_batch_dirty_count", raw_terrain_batch.get("terrain_visual_batch_dirty_count")),
        "terrain_batch_in_flight": terrain.get("terrain_visual_batch_async_in_flight_count", raw_terrain_batch.get("terrain_visual_batch_async_in_flight_count")),
        "terrain_batch_completed": terrain.get("terrain_visual_batch_async_completed_count", raw_terrain_batch.get("terrain_visual_batch_async_completed_count")),
        "terrain_chunks": terrain.get("rendered_terrain_chunk_count"),
        "water_chunks": terrain.get("rendered_water_chunk_count"),
        "vegetation_primitives": vegetation_prims,
        "tree_primitives": tree_prims,
        "grass_primitives": grass_prims,
        "rock_primitives": rock_prims,
        "alpha_empty_primitive_equivalent": alpha_empty,
        "vegetation_batches": vegetation.get("global_render_batch_count", raw_vegetation.get("global_render_batch_count")),
        "tree_batches": vegetation.get("global_tree_render_batch_count", raw_vegetation.get("global_tree_render_batch_count")),
        "grass_batches": vegetation.get("global_grass_render_batch_count", raw_vegetation.get("global_grass_render_batch_count")),
        "rock_batches": vegetation.get("global_rock_render_batch_count", raw_vegetation.get("global_rock_render_batch_count")),
        "tree_instances": vegetation.get("global_tree_render_instances", raw_vegetation.get("global_tree_render_instances")),
        "grass_instances": vegetation.get("global_grass_render_instances", raw_vegetation.get("global_grass_render_instances")),
        "rock_instances": vegetation.get("global_rock_render_instances", raw_vegetation.get("global_rock_render_instances")),
        "tree_alpha_coverage": vegetation.get("tree_alpha_texture_coverage_ratio", raw_vegetation.get("tree_alpha_texture_coverage_ratio")),
        "building_objects": building.get("world_map_baked_object_count", building.get("object_count")),
        "building_global_instances": building.get("global_instance_count", building.get("global_instances")),
        "town_avg_primitives": town_window.get("avg_primitives"),
    }


def _runtime_summary(snapshot: dict[str, Any]) -> dict[str, Any]:
    telemetry = _dict(snapshot.get("system_telemetry"))
    terrain = _dict(telemetry.get("terrain_manager"))
    return {
        "mode": terrain.get("runtime_power_mode"),
        "target_fps": terrain.get("runtime_power_target_fps"),
        "active_reason": terrain.get("runtime_power_active_reason"),
        "viewer_moved": terrain.get("runtime_power_viewer_moved"),
        "terrain_busy": terrain.get("runtime_power_terrain_busy"),
        "foreground_terrain_busy": terrain.get("runtime_power_foreground_terrain_busy"),
        "external_world_busy": terrain.get("runtime_power_external_world_busy"),
        "world_work_suspended": terrain.get("runtime_power_world_work_suspended"),
        "world_work_suspended_frames": terrain.get("runtime_power_world_work_suspended_frame_count"),
        "render_loop_enabled": terrain.get("runtime_power_render_loop_enabled"),
        "render_loop_suspended": terrain.get("runtime_power_render_loop_suspended"),
        "render_loop_gate": terrain.get("runtime_power_render_loop_suspend_gate"),
        "viewport_scale": terrain.get("runtime_power_viewport_scale_current"),
        "pending_nodes": terrain.get("pending_node_count"),
        "task_queue": terrain.get("task_queue_count"),
        "cpu_task_queue": terrain.get("cpu_task_queue_count"),
        "completed_generation_queue": terrain.get("completed_generation_queue_count"),
        "stream_gate": terrain.get("last_terrain_stream_update_gate_reason"),
        "stream_idle_skips": terrain.get("terrain_stream_update_idle_skip_count"),
        "last_update_loads": terrain.get("last_update_loads"),
        "last_update_unloads": terrain.get("last_update_unloads"),
        "collision_pending": terrain.get("pending_terrain_collision_create_count"),
        "collision_enabled_chunks": terrain.get("collision_enabled_chunk_count"),
        "collision_last_update_ms": terrain.get("last_collision_proximity_update_ms"),
    }


def _timer_entry(name: str, status: str, interval: Any = None, ticks: Any = None, cost: Any = None, detail: str = "") -> dict[str, Any]:
    return {
        "name": name,
        "status": status,
        "interval": interval,
        "ticks": ticks,
        "cost": cost,
        "detail": detail,
    }


def _logic_summary(snapshot: dict[str, Any]) -> dict[str, Any]:
    telemetry = _dict(snapshot.get("system_telemetry"))
    entities = _dict(telemetry.get("entity_manager"))
    hud = _dict(telemetry.get("player_hud"))
    minimap = _dict(telemetry.get("hud_minimap"))
    interaction = _dict(_dict(telemetry.get("player_interaction")).get("activity"))
    terrain_interaction = _dict(_dict(telemetry.get("terrain_interaction")).get("activity"))
    vegetation = _dict(telemetry.get("vegetation_manager"))
    building = _dict(telemetry.get("building_manager"))
    prefab = _dict(telemetry.get("prefab_spawner"))
    vehicle = _dict(telemetry.get("vehicle_manager"))
    save = _dict(telemetry.get("save_manager"))

    timers = [
        _timer_entry(
            "entity_maintenance",
            "active" if _bool(entities.get("entity_maintenance_timer_active")) else "stopped",
            entities.get("entity_maintenance_timer_interval"),
            entities.get("entity_maintenance_timer_tick_count"),
            f"prox={_fmt_float(entities.get('last_proximity_update_ms'))}ms spawn={_fmt_float(entities.get('last_spawn_queue_update_ms'))}ms dormant={_fmt_float(entities.get('last_dormant_respawn_update_ms'))}ms",
            f"active={_fmt_int(entities.get('active_entities'))} frozen={_fmt_int(entities.get('frozen_entities'))} dormant={_fmt_int(entities.get('dormant_entities'))} pending_spawns={_fmt_int(entities.get('pending_spawns'))}",
        ),
        _timer_entry(
            "player_hud",
            "active" if _bool(hud.get("hud_update_timer_active")) else "stopped",
            hud.get("hud_update_interval"),
            hud.get("hud_update_timer_tick_count"),
            None,
            f"process={_fmt_bool(hud.get('process_enabled'))} notification_visible={_fmt_bool(hud.get('notification_visible'))}",
        ),
        _timer_entry(
            "hud_minimap",
            "active" if _bool(minimap.get("minimap_update_timer_active")) else "stopped",
            minimap.get("minimap_update_interval"),
            minimap.get("minimap_update_timer_tick_count"),
            None,
            f"visible={_fmt_bool(minimap.get('minimap_visible'))} dirty={_fmt_bool(minimap.get('minimap_dirty'))}",
        ),
        _timer_entry(
            "player_interaction_target",
            "active" if _int(interaction.get("target_refresh_ticks")) > 0 else "unknown",
            interaction.get("target_refresh_interval"),
            interaction.get("target_refresh_ticks"),
            None,
            f"awake={_fmt_bool(interaction.get('awake'))} reason={interaction.get('reason', '')} raycasts={_fmt_int(interaction.get('target_raycast_count'))}",
        ),
        _timer_entry(
            "terrain_interaction_target",
            "active" if _int(terrain_interaction.get("target_refresh_ticks")) > 0 else "unknown",
            terrain_interaction.get("target_refresh_interval"),
            terrain_interaction.get("target_refresh_ticks"),
            None,
            f"awake={_fmt_bool(terrain_interaction.get('awake'))} reason={terrain_interaction.get('reason', '')} raycast_ticks={_fmt_int(terrain_interaction.get('target_raycast_ticks'))}",
        ),
    ]

    process_loops = {
        "vegetation_process_awake": vegetation.get("process_loop_awake"),
        "vegetation_physics_enabled": vegetation.get("physics_process_enabled"),
        "building_process_awake": building.get("process_loop_awake"),
        "prefab_process_awake": prefab.get("process_loop_awake"),
        "vehicle_count": vehicle.get("vehicle_count", vehicle.get("vehicles")),
        "save_process_enabled": save.get("process_enabled"),
    }
    return {
        "timers": timers,
        "process_loops": process_loops,
        "entity": {
            "active": entities.get("active_entities"),
            "active_physics": entities.get("active_physics_entities", entities.get("active_physics_count")),
            "frozen": entities.get("frozen_entities"),
            "dormant": entities.get("dormant_entities"),
            "pending_spawns": entities.get("pending_spawns"),
            "deferred_spawn_chunks": entities.get("deferred_spawn_chunks"),
            "last_proximity_ms": entities.get("last_proximity_update_ms"),
            "last_spawn_queue_ms": entities.get("last_spawn_queue_update_ms"),
            "last_dormant_respawn_ms": entities.get("last_dormant_respawn_update_ms"),
        },
    }


def _pressure_ranking(snapshot: dict[str, Any]) -> list[str]:
    rows: list[str] = []
    for entry in _list(snapshot.get("system_pressure_ranking")):
        item = _dict(entry)
        name = str(item.get("name", "")).strip()
        score = item.get("pressure_score", item.get("score"))
        summary = str(item.get("summary", "")).strip()
        if name or summary:
            rows.append(f"{name or 'unknown'} score={_fmt_float(score, 1)} {summary}".strip())
    return rows


def _findings(render: dict[str, Any], runtime: dict[str, Any], logic: dict[str, Any], baseline: dict[str, Any]) -> list[str]:
    findings: list[str] = []
    avg_prims = _float(render.get("avg_primitives"))
    if avg_prims >= 1_000_000.0:
        findings.append(
            f"Render pressure is the primary idle watt driver: {_fmt_int(avg_prims)} primitives/frame at about {_fmt_float(baseline.get('stationary_hold_power_w'), 2, ' W')} stationary."
        )

    vegetation_prims = _float(render.get("vegetation_primitives"))
    tree_prims = _float(render.get("tree_primitives"))
    alpha_empty = _float(render.get("alpha_empty_primitive_equivalent"))
    if vegetation_prims >= 500_000.0:
        findings.append(
            "Vegetation dominates known non-building render cost: "
            f"{_fmt_int(vegetation_prims)} primitives, trees {_fmt_int(tree_prims)}, alpha-empty estimate {_fmt_int(alpha_empty)}."
        )

    terrain_prims = _float(render.get("terrain_primitives"))
    if terrain_prims >= 500_000.0:
        findings.append(
            f"Terrain is also high: {_fmt_int(terrain_prims)} batched terrain primitives across {_fmt_int(render.get('terrain_chunks'))} rendered chunks."
        )

    if _bool(runtime.get("render_loop_enabled")) and not _bool(runtime.get("render_loop_suspended")):
        findings.append(
            "Deep idle still renders every frame because render-loop suspend is not active; "
            f"gate={runtime.get('render_loop_gate')} target_fps={runtime.get('target_fps')}."
        )

    background_count = _int(render.get("terrain_batch_dirty")) + _int(render.get("terrain_batch_in_flight")) + _int(render.get("terrain_batch_completed"))
    if _bool(runtime.get("terrain_busy")) and not _bool(runtime.get("foreground_terrain_busy")) and background_count > 0:
        findings.append(
            "Runtime power sees background terrain batch state while foreground terrain is idle: "
            f"dirty={_fmt_int(render.get('terrain_batch_dirty'))} in_flight={_fmt_int(render.get('terrain_batch_in_flight'))} completed={_fmt_int(render.get('terrain_batch_completed'))}."
        )

    active_timers = [timer for timer in _list(logic.get("timers")) if _dict(timer).get("status") == "active"]
    if active_timers:
        names = ", ".join(str(_dict(timer).get("name", "")) for timer in active_timers)
        findings.append(f"Logic is not fully asleep: active idle timers include {names}.")

    entity = _dict(logic.get("entity"))
    if _int(entity.get("pending_spawns")) > 0 or _int(entity.get("active")) > 0:
        findings.append(
            "Entity manager still has maintenance work: "
            f"active={_fmt_int(entity.get('active'))} frozen={_fmt_int(entity.get('frozen'))} dormant={_fmt_int(entity.get('dormant'))} pending_spawns={_fmt_int(entity.get('pending_spawns'))}."
        )

    if not findings:
        findings.append("No obvious idle work was detected in the snapshot.")
    return findings


def _print_section(title: str) -> None:
    print()
    print(title)
    print("-" * len(title))


def _print_report(raw_path: Path | None, snapshot_path: Path | None, raw: dict[str, Any], snapshot: dict[str, Any]) -> None:
    baseline = _raw_baseline_summary(raw) if raw else {}
    render = _render_summary(snapshot, raw)
    runtime = _runtime_summary(snapshot)
    logic = _logic_summary(snapshot)
    ranking = _pressure_ranking(snapshot)
    findings = _findings(render, runtime, logic, baseline)

    print("Town Idle Work Audit")
    print("====================")
    print(f"raw:      {raw_path if raw_path else 'n/a'}")
    print(f"snapshot: {snapshot_path if snapshot_path else 'n/a'}")

    _print_section("Baseline")
    print(f"case:                  {baseline.get('case', 'n/a')}")
    print(f"valid:                 {_fmt_bool(baseline.get('valid'))}")
    print(f"avg_fps:               {_fmt_float(baseline.get('avg_fps'))}")
    print(f"stationary_power:      {_fmt_float(baseline.get('stationary_hold_power_w'), 3, ' W')}")
    print(f"hold_power:            {_fmt_float(baseline.get('hold_power_w'), 3, ' W')}")
    print(f"moving_power:          {_fmt_float(baseline.get('moving_power_w'), 3, ' W')}")
    print(f"last20_power:          {_fmt_float(baseline.get('last20_power_w'), 3, ' W')}")
    print(f"stationary_gpu_util:   {_fmt_float(baseline.get('stationary_gpu_util_pct'), 1, '%')}")
    print(f"stationary_p0:         {_fmt_float(_float(baseline.get('stationary_p0_fraction')) * 100.0, 1, '%')}")
    print(f"stationary_frame_ms:   avg={_fmt_float(baseline.get('stationary_avg_frame_ms'))} max={_fmt_float(baseline.get('stationary_max_frame_ms'))}")
    print(f"frames_over_40/50ms:   {_fmt_int(baseline.get('frames_over_40ms'))}/{_fmt_int(baseline.get('frames_over_50ms'))}")

    _print_section("Render Pressure")
    print(f"avg_primitives/frame:  {_fmt_int(render.get('avg_primitives'))}")
    print(f"avg_draw_calls/frame:  {_fmt_float(render.get('avg_draw_calls'), 1)}")
    print(f"avg_objects/frame:     {_fmt_float(render.get('avg_objects'), 1)}")
    print(f"avg_frame_breakdown:   total={_fmt_float(render.get('avg_total_ms'))}ms process={_fmt_float(render.get('avg_process_ms'))}ms physics={_fmt_float(render.get('avg_physics_ms'))}ms other/render_wait={_fmt_float(render.get('avg_other_ms'))}ms")
    print(f"known_render_prims:    {_fmt_int(render.get('known_render_primitives'))} ({_fmt_float(render.get('known_share_of_avg_primitives'), 1, '%')} of avg submitted)")
    print(f"terrain_prims:         {_fmt_int(render.get('terrain_primitives'))} visible_source={_fmt_int(render.get('terrain_visible_primitives'))} chunks={_fmt_int(render.get('terrain_chunks'))} water_chunks={_fmt_int(render.get('water_chunks'))}")
    print(f"terrain_batch_state:   nodes={_fmt_int(render.get('terrain_batch_nodes'))} dirty={_fmt_int(render.get('terrain_batch_dirty'))} in_flight={_fmt_int(render.get('terrain_batch_in_flight'))} completed={_fmt_int(render.get('terrain_batch_completed'))}")
    print(f"vegetation_prims:      total={_fmt_int(render.get('vegetation_primitives'))} trees={_fmt_int(render.get('tree_primitives'))} grass={_fmt_int(render.get('grass_primitives'))} rocks={_fmt_int(render.get('rock_primitives'))}")
    print(f"vegetation_batches:    total={_fmt_int(render.get('vegetation_batches'))} trees={_fmt_int(render.get('tree_batches'))} grass={_fmt_int(render.get('grass_batches'))} rocks={_fmt_int(render.get('rock_batches'))}")
    print(f"vegetation_instances:  trees={_fmt_int(render.get('tree_instances'))} grass={_fmt_int(render.get('grass_instances'))} rocks={_fmt_int(render.get('rock_instances'))}")
    print(f"alpha_empty_estimate:  {_fmt_int(render.get('alpha_empty_primitive_equivalent'))} tree_alpha_coverage={_fmt_float(_float(render.get('tree_alpha_coverage')) * 100.0, 1, '%')}")

    _print_section("Runtime Idle State")
    print(f"mode/target_fps:       {runtime.get('mode', 'n/a')} / {runtime.get('target_fps', 'n/a')}")
    print(f"active_reason:         {runtime.get('active_reason', 'n/a')}")
    print(f"viewer_moved:          {_fmt_bool(runtime.get('viewer_moved'))}")
    print(f"terrain_busy:          {_fmt_bool(runtime.get('terrain_busy'))} foreground={_fmt_bool(runtime.get('foreground_terrain_busy'))} external={_fmt_bool(runtime.get('external_world_busy'))}")
    print(f"world_work_suspended:  {_fmt_bool(runtime.get('world_work_suspended'))} frames={_fmt_int(runtime.get('world_work_suspended_frames'))}")
    print(f"render_loop:           enabled={_fmt_bool(runtime.get('render_loop_enabled'))} suspended={_fmt_bool(runtime.get('render_loop_suspended'))} gate={runtime.get('render_loop_gate')}")
    print(f"terrain_stream:        gate={runtime.get('stream_gate')} idle_skips={_fmt_int(runtime.get('stream_idle_skips'))} loads={_fmt_int(runtime.get('last_update_loads'))} unloads={_fmt_int(runtime.get('last_update_unloads'))}")
    print(f"terrain_queues:        pending={_fmt_int(runtime.get('pending_nodes'))} task={_fmt_int(runtime.get('task_queue'))} cpu_task={_fmt_int(runtime.get('cpu_task_queue'))} completed={_fmt_int(runtime.get('completed_generation_queue'))}")
    print(f"collision:             pending={_fmt_int(runtime.get('collision_pending'))} enabled_chunks={_fmt_int(runtime.get('collision_enabled_chunks'))} last_update={_fmt_float(runtime.get('collision_last_update_ms'))}ms")

    _print_section("Idle Timers And Logic")
    for timer in _list(logic.get("timers")):
        item = _dict(timer)
        interval = item.get("interval")
        interval_text = f"{_fmt_float(interval)}s" if interval is not None else "n/a"
        print(
            f"{item.get('name', 'unknown')}: {item.get('status', 'unknown')} "
            f"interval={interval_text} ticks={_fmt_int(item.get('ticks'))} "
            f"cost={item.get('cost') or 'n/a'} {item.get('detail') or ''}".rstrip()
        )
    loops = _dict(logic.get("process_loops"))
    print(
        "process_loops:         "
        f"vegetation_awake={_fmt_bool(loops.get('vegetation_process_awake'))} "
        f"vegetation_physics={_fmt_bool(loops.get('vegetation_physics_enabled'))} "
        f"building_awake={_fmt_bool(loops.get('building_process_awake'))} "
        f"prefab_awake={_fmt_bool(loops.get('prefab_process_awake'))}"
    )

    if ranking:
        _print_section("System Pressure Ranking")
        for row in ranking:
            print(row)

    _print_section("Findings")
    for index, finding in enumerate(findings, start=1):
        print(f"{index}. {finding}")


def _json_report(raw_path: Path | None, snapshot_path: Path | None, raw: dict[str, Any], snapshot: dict[str, Any]) -> dict[str, Any]:
    baseline = _raw_baseline_summary(raw) if raw else {}
    render = _render_summary(snapshot, raw)
    runtime = _runtime_summary(snapshot)
    logic = _logic_summary(snapshot)
    return {
        "raw_path": str(raw_path) if raw_path else None,
        "snapshot_path": str(snapshot_path) if snapshot_path else None,
        "baseline": baseline,
        "render": render,
        "runtime": runtime,
        "logic": logic,
        "pressure_ranking": _pressure_ranking(snapshot),
        "findings": _findings(render, runtime, logic, baseline),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", help="Raw town baseline telemetry JSON. Defaults to locked Baseline V1 when present.")
    parser.add_argument("--snapshot", help="Full town performance snapshot JSON. If omitted, reads the snapshot linked by --raw.")
    parser.add_argument("--latest-raw", action="store_true", help="Use the latest raw baseline JSON instead of the locked Baseline V1 default.")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON.")
    args = parser.parse_args()

    raw_path, raw, snapshot_path, snapshot = _select_snapshot(args)
    if not raw and not snapshot:
        print("No raw telemetry or snapshot was found. Pass --raw or --snapshot.")
        return 2
    if not snapshot:
        print("No full snapshot was found. Pass --snapshot or use a raw artifact with a valid snapshot_path.")
        return 2

    if args.json:
        print(json.dumps(_json_report(raw_path, snapshot_path, raw, snapshot), indent=2, sort_keys=True))
    else:
        _print_report(raw_path, snapshot_path, raw, snapshot)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
