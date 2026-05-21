import json
import os
import subprocess
import sys
import time
from pathlib import Path

import run_town_stall_test
from windows_error_dialogs import suppress_windows_error_dialogs


SUMMARY_FILE = Path(run_town_stall_test.PROJECT_PATH) / ".agent" / "render-ablation-summary.json"

CASES = {
    "baseline": {},
    "hide_terrain_manager_visuals": {"TOWN_STALL_DISABLE_TERRAIN_MANAGER_VISUALS": "1"},
    "hide_vegetation_render": {"TOWN_STALL_DISABLE_VEGETATION_RENDER": "1"},
    "vegetation_lod_bias_0_5": {"TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.5"},
    "vegetation_lod_bias_0_25": {"TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.25"},
    "vegetation_cluster_3": {
        "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "3",
        "TOWN_STALL_WORLD_MAP_VEGETATION_GRASS_RENDER_CLUSTER_SIZE": "3",
    },
    "vegetation_cluster_3_lod_0_5": {
        "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "3",
        "TOWN_STALL_WORLD_MAP_VEGETATION_GRASS_RENDER_CLUSTER_SIZE": "3",
        "TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.5",
    },
    "vegetation_bounds_padding_48": {"TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "48"},
    "vegetation_bounds_padding_32": {"TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "32"},
    "vegetation_bounds_32_lod_0_5": {
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "32",
        "TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.5",
    },
    "vegetation_bounds_32_lod_0_25": {
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "32",
        "TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.25",
    },
    "tree_cluster_4_bounds_32": {
        "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "4",
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "32",
    },
    "tree_cluster_4_bounds_32_lod_0_5": {
        "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "4",
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "32",
        "TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.5",
    },
    "vegetation_occlusion_culling": {"TOWN_STALL_VEGETATION_GLOBAL_RENDER_IGNORE_OCCLUSION_CULLING": "0"},
    "vegetation_bounds_48_occlusion": {
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "48",
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_IGNORE_OCCLUSION_CULLING": "0",
    },
    "terrain_batch_1": {"TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_SIZE": "1"},
    "terrain_batch_3": {"TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_SIZE": "3"},
    "terrain_batch_4": {"TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_SIZE": "4"},
    "hide_terrain_and_vegetation": {
        "TOWN_STALL_DISABLE_TERRAIN_MANAGER_VISUALS": "1",
        "TOWN_STALL_DISABLE_VEGETATION_RENDER": "1",
    },
    "no_water": {"TOWN_STALL_DISABLE_WATER_RENDER": "1"},
    "no_buildings": {"TOWN_STALL_DISABLE_BUILDINGS": "1"},
    "no_building_objects": {"TOWN_STALL_DISABLE_BUILDING_OBJECTS": "1"},
    "no_entities": {"TOWN_STALL_DISABLE_ENTITIES": "1"},
    "no_glow": {"TOWN_STALL_DISABLE_GLOW": "1"},
    "no_world_map_veg_profile": {"TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_PROFILE": "0"},
}


def _selected_case_names() -> list[str]:
    raw = os.environ.get(
        "TOWN_STALL_ABLATION_CASES",
        "baseline,hide_terrain_manager_visuals,hide_vegetation_render,hide_terrain_and_vegetation,no_water",
    )
    names = [name.strip() for name in raw.split(",") if name.strip()]
    selected: list[str] = []
    for name in names:
        if name not in CASES:
            print(f"WARNING: Unknown ablation case '{name}', skipping.")
            continue
        selected.append(name)
    return selected or ["baseline"]


def _read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _pick_window_metric(stationary_hold: dict, town_window: dict, metric: str) -> float:
    active_metric = f"{metric}_render_active"
    for window in (stationary_hold, town_window):
        if int(window.get("render_active_sample_count", 0) or 0) > 0:
            return float(window.get(active_metric, window.get(metric, 0.0)) or 0.0)
    return float(stationary_hold.get(metric, town_window.get(metric, 0.0)) or 0.0)


def _pick_window_int_metric(stationary_hold: dict, town_window: dict, metric: str) -> int:
    active_metric = f"{metric}_render_active"
    for window in (stationary_hold, town_window):
        if int(window.get("render_active_sample_count", 0) or 0) > 0:
            return int(window.get(active_metric, window.get(metric, 0)) or 0)
    return int(stationary_hold.get(metric, town_window.get(metric, 0)) or 0)


def _pick_active_sample_count(stationary_hold: dict, town_window: dict) -> int:
    stationary_active_samples = int(stationary_hold.get("render_active_sample_count", 0) or 0)
    if stationary_active_samples > 0:
        return stationary_active_samples
    return int(town_window.get("render_active_sample_count", 0) or 0)


def _summary_avg(summary: dict, key: str) -> float:
    value = summary.get(key, {}) if isinstance(summary, dict) else {}
    if not isinstance(value, dict):
        return 0.0
    return float(value.get("avg", 0.0) or 0.0)


def _phase_window(system_summary: dict, phase: str) -> dict:
    windows = system_summary.get("phase_windows", {}) if isinstance(system_summary, dict) else {}
    window = windows.get(phase, {}) if isinstance(windows, dict) else {}
    return window if isinstance(window, dict) else {}


def _run_case(case_name: str, case_env: dict[str, str]) -> dict:
    run_start_mtime = time.time()
    env = os.environ.copy()
    env.setdefault("TOWN_STALL_HOLD_SECONDS", "12")
    env.setdefault("TOWN_STALL_MACHINE_WARMUP_DISABLED", "1")
    env.setdefault("TOWN_STALL_ENABLE_RUNTIME_POWER_MODE", "1")
    env.setdefault("TOWN_STALL_RUNTIME_POWER_SUSPEND_BACKGROUND_WORLD_WORK", "1")
    env.setdefault("TOWN_STALL_RUNTIME_POWER_SUSPEND_RENDER_LOOP", "1")
    env.setdefault("TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS", "1")
    env.setdefault("TOWN_STALL_SYSTEM_SAMPLE_RAW_GPU_ONLY", "1")
    env.setdefault("TOWN_STALL_ALLOW_CONTAMINATED_IDLE", "1")
    env.setdefault("TOWN_STALL_DISABLE_POSTRUN_IDLE_CHECK", "1")
    env.update(case_env)

    print("\n" + "=" * 50)
    print(f"RUNNING ABLATION CASE: {case_name}")
    print("=" * 50)
    result = subprocess.run(
        [sys.executable, str(Path(__file__).with_name("run_town_stall_test.py"))],
        cwd=run_town_stall_test.PROJECT_PATH,
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    snapshot_path = run_town_stall_test._latest_snapshot(run_start_mtime)
    if result.returncode != 0:
        snapshot_path = None
    snapshot = _read_json(snapshot_path) if snapshot_path else {}
    town_window = snapshot.get("town_entry_window", {}) if isinstance(snapshot, dict) else {}
    stationary_hold = snapshot.get("stationary_hold_window", {}) if isinstance(snapshot, dict) else {}
    system_telemetry = snapshot.get("system_telemetry", {}) if isinstance(snapshot, dict) else {}
    system_summary = snapshot.get("system_sample_summary", {}) if isinstance(snapshot, dict) else {}
    terrain = system_telemetry.get("terrain_manager", {}) if isinstance(system_telemetry, dict) else {}
    building = system_telemetry.get("building_manager", {}) if isinstance(system_telemetry, dict) else {}
    vegetation = system_telemetry.get("vegetation_manager", {}) if isinstance(system_telemetry, dict) else {}
    entities = system_telemetry.get("entity_manager", {}) if isinstance(system_telemetry, dict) else {}

    if not isinstance(town_window, dict):
        town_window = {}
    if not isinstance(stationary_hold, dict):
        stationary_hold = {}
    if not isinstance(terrain, dict):
        terrain = {}
    if not isinstance(building, dict):
        building = {}
    if not isinstance(vegetation, dict):
        vegetation = {}
    if not isinstance(entities, dict):
        entities = {}
    if not isinstance(system_summary, dict):
        system_summary = {}

    active_sample_count = _pick_active_sample_count(stationary_hold, town_window)
    moving_entry = snapshot.get("moving_entry_window", {}) if isinstance(snapshot, dict) else {}
    if not isinstance(moving_entry, dict):
        moving_entry = {}
    moving_system = _phase_window(system_summary, "moving_entry")
    hold_system = _phase_window(system_summary, "stationary_hold")
    sample_count = int(stationary_hold.get("sample_count", town_window.get("sample_count", 0)) or 0)
    render_loop_suspended_samples = int(
        stationary_hold.get(
            "terrain_runtime_power_render_loop_suspended_samples",
            town_window.get("terrain_runtime_power_render_loop_suspended_samples", 0),
        )
        or 0
    )
    world_work_suspended_samples = int(
        stationary_hold.get(
            "terrain_runtime_power_world_work_suspended_samples",
            town_window.get("terrain_runtime_power_world_work_suspended_samples", 0),
        )
        or 0
    )

    return {
        "case": case_name,
        "returncode": result.returncode,
        "snapshot": str(snapshot_path) if snapshot_path else "",
        "hold_complete": bool(snapshot.get("benchmark_hold_complete", False)) if snapshot else False,
        "metric_basis": "render_active" if active_sample_count > 0 else "all_samples",
        "sample_count": sample_count,
        "render_active_sample_count": active_sample_count,
        "render_loop_suspended_samples": render_loop_suspended_samples,
        "world_work_suspended_samples": world_work_suspended_samples,
        "avg_total_ms": _pick_window_metric(stationary_hold, town_window, "avg_total_ms"),
        "avg_draw_calls": _pick_window_metric(stationary_hold, town_window, "avg_draw_calls"),
        "avg_objects": _pick_window_metric(stationary_hold, town_window, "avg_objects"),
        "avg_primitives": _pick_window_metric(stationary_hold, town_window, "avg_primitives"),
        "moving_avg_total_ms": float(moving_entry.get("avg_total_ms", 0.0) or 0.0),
        "moving_avg_draw_calls": float(moving_entry.get("avg_draw_calls", 0.0) or 0.0),
        "moving_avg_objects": float(moving_entry.get("avg_objects", 0.0) or 0.0),
        "moving_avg_primitives": float(moving_entry.get("avg_primitives", 0.0) or 0.0),
        "moving_raw_gpu_power_avg_w": _summary_avg(moving_system, "raw_gpu_power_w"),
        "moving_raw_gpu_temp_max_c": float(
            (moving_system.get("raw_gpu_temp_c", {}) if isinstance(moving_system.get("raw_gpu_temp_c", {}), dict) else {}).get("max", 0.0)
            or 0.0
        ),
        "hold_raw_gpu_power_avg_w": _summary_avg(hold_system, "raw_gpu_power_w"),
        "hold_raw_gpu_temp_max_c": float(
            (hold_system.get("raw_gpu_temp_c", {}) if isinstance(hold_system.get("raw_gpu_temp_c", {}), dict) else {}).get("max", 0.0)
            or 0.0
        ),
        "pipeline_compilations_total_delta": int(
            stationary_hold.get(
                "pipeline_compilations_total_delta",
                town_window.get("pipeline_compilations_total_delta", 0),
            )
            or 0
        ),
        "frames_over_budget": _pick_window_int_metric(stationary_hold, town_window, "frames_over_budget"),
        "avg_total_ms_all": float(stationary_hold.get("avg_total_ms", town_window.get("avg_total_ms", 0.0)) or 0.0),
        "avg_draw_calls_all": float(stationary_hold.get("avg_draw_calls", town_window.get("avg_draw_calls", 0.0)) or 0.0),
        "avg_objects_all": float(stationary_hold.get("avg_objects", town_window.get("avg_objects", 0.0)) or 0.0),
        "avg_primitives_all": float(stationary_hold.get("avg_primitives", town_window.get("avg_primitives", 0.0)) or 0.0),
        "rendered_terrain_chunks": int(terrain.get("rendered_terrain_chunk_count", 0) or 0),
        "terrain_visual_visible_primitives": int(terrain.get("terrain_visual_visible_primitive_count", 0) or 0),
        "terrain_visual_chunk_primitives": int(terrain.get("terrain_visual_chunk_primitive_count", 0) or 0),
        "terrain_visual_batch_primitives": int(terrain.get("terrain_visual_batch_primitive_count", 0) or 0),
        "terrain_visual_max_chunk_primitives": int(terrain.get("terrain_visual_max_chunk_primitive_count", 0) or 0),
        "terrain_visual_max_batch_primitives": int(terrain.get("terrain_visual_max_batch_primitive_count", 0) or 0),
        "rendered_water_chunks": int(terrain.get("rendered_water_chunk_count", 0) or 0),
        "building_visible_nodes": int(building.get("visible_world_map_baked_building_visual_nodes", 0) or 0),
        "building_visible_surfaces": int(building.get("visible_world_map_baked_building_visual_surfaces", 0) or 0),
        "vegetation_global_batches": int(vegetation.get("global_render_batch_count", 0) or 0),
        "vegetation_profile_active": bool(vegetation.get("world_map_vegetation_render_profile_active", False)),
        "vegetation_bounds_padding": float(vegetation.get("vegetation_global_render_bounds_padding", 0.0) or 0.0),
        "vegetation_ignore_occlusion_culling": bool(vegetation.get("vegetation_global_render_ignore_occlusion_culling", False)),
        "vegetation_estimated_primitives": int(vegetation.get("global_render_estimated_primitives", 0) or 0),
        "tree_mesh_primitives": int(vegetation.get("tree_mesh_primitives", 0) or 0),
        "grass_mesh_primitives": int(vegetation.get("grass_mesh_primitives", 0) or 0),
        "rock_mesh_primitives": int(vegetation.get("rock_mesh_primitives", 0) or 0),
        "vegetation_tree_estimated_primitives": int(vegetation.get("global_tree_render_estimated_primitives", 0) or 0),
        "vegetation_grass_estimated_primitives": int(vegetation.get("global_grass_render_estimated_primitives", 0) or 0),
        "vegetation_rock_estimated_primitives": int(vegetation.get("global_rock_render_estimated_primitives", 0) or 0),
        "vegetation_tree_max_batch_instances": int(vegetation.get("global_tree_max_batch_instances", 0) or 0),
        "vegetation_grass_max_batch_instances": int(vegetation.get("global_grass_max_batch_instances", 0) or 0),
        "vegetation_rock_max_batch_instances": int(vegetation.get("global_rock_max_batch_instances", 0) or 0),
        "vegetation_tree_batches": int(vegetation.get("global_tree_render_batch_count", 0) or 0),
        "vegetation_grass_batches": int(vegetation.get("global_grass_render_batch_count", 0) or 0),
        "vegetation_rock_batches": int(vegetation.get("global_rock_render_batch_count", 0) or 0),
        "vegetation_cluster_size": int(vegetation.get("effective_vegetation_render_cluster_size", 0) or 0),
        "vegetation_grass_cluster_size": int(vegetation.get("effective_vegetation_grass_render_cluster_size", 0) or 0),
        "entity_active": int(entities.get("active_entities", 0) or 0),
    }


def _add_deltas(results: list[dict]) -> list[dict]:
    baseline = next((result for result in results if result.get("case") == "baseline"), None)
    if not baseline:
        return results
    baseline_ms = float(baseline.get("avg_total_ms", 0.0) or 0.0)
    baseline_draws = float(baseline.get("avg_draw_calls", 0.0) or 0.0)
    baseline_objects = float(baseline.get("avg_objects", 0.0) or 0.0)
    baseline_primitives = float(baseline.get("avg_primitives", 0.0) or 0.0)
    baseline_moving_power = float(baseline.get("moving_raw_gpu_power_avg_w", 0.0) or 0.0)
    baseline_hold_power = float(baseline.get("hold_raw_gpu_power_avg_w", 0.0) or 0.0)
    for result in results:
        result["delta_avg_total_ms"] = round(float(result.get("avg_total_ms", 0.0) or 0.0) - baseline_ms, 3)
        result["delta_avg_draw_calls"] = round(float(result.get("avg_draw_calls", 0.0) or 0.0) - baseline_draws, 3)
        result["delta_avg_objects"] = round(float(result.get("avg_objects", 0.0) or 0.0) - baseline_objects, 3)
        result["delta_avg_primitives"] = round(float(result.get("avg_primitives", 0.0) or 0.0) - baseline_primitives, 3)
        result["delta_moving_raw_gpu_power_avg_w"] = round(float(result.get("moving_raw_gpu_power_avg_w", 0.0) or 0.0) - baseline_moving_power, 3)
        result["delta_hold_raw_gpu_power_avg_w"] = round(float(result.get("hold_raw_gpu_power_avg_w", 0.0) or 0.0) - baseline_hold_power, 3)
    return results


def _print_results(results: list[dict]) -> None:
    print("\n" + "=" * 50)
    print("RENDER ABLATION SUMMARY")
    print("=" * 50)
    for result in results:
        print(
            "{case:>20} | ms={ms:6.2f} ({dms:+6.2f}) | draws={draws:7.1f} ({ddraws:+7.1f}) | "
            "objects={objects:7.1f} ({dobjects:+7.1f}) | prims={prims:9.0f} ({dprims:+9.0f}) pipes={pipes:3d} | "
            "moveW={move_w:5.1f} ({dmove_w:+5.1f}) holdW={hold_w:5.1f} ({dhold_w:+5.1f}) | "
            "terrain={terrain:4d} water={water:4d} "
            "buildings={buildings:4d} veg={veg:3d}({tree}/{grass}/{rock}) cluster={cluster}/{grass_cluster} "
            "profile={profile} entities={entities:3d} | active={active:4d}/{samples:4d} suspended={suspended:4d}".format(
                case=str(result.get("case", "")),
                ms=float(result.get("avg_total_ms", 0.0) or 0.0),
                dms=float(result.get("delta_avg_total_ms", 0.0) or 0.0),
                draws=float(result.get("avg_draw_calls", 0.0) or 0.0),
                ddraws=float(result.get("delta_avg_draw_calls", 0.0) or 0.0),
                objects=float(result.get("avg_objects", 0.0) or 0.0),
                dobjects=float(result.get("delta_avg_objects", 0.0) or 0.0),
                prims=float(result.get("avg_primitives", 0.0) or 0.0),
                dprims=float(result.get("delta_avg_primitives", 0.0) or 0.0),
                pipes=int(result.get("pipeline_compilations_total_delta", 0) or 0),
                move_w=float(result.get("moving_raw_gpu_power_avg_w", 0.0) or 0.0),
                dmove_w=float(result.get("delta_moving_raw_gpu_power_avg_w", 0.0) or 0.0),
                hold_w=float(result.get("hold_raw_gpu_power_avg_w", 0.0) or 0.0),
                dhold_w=float(result.get("delta_hold_raw_gpu_power_avg_w", 0.0) or 0.0),
                terrain=int(result.get("rendered_terrain_chunks", 0) or 0),
                water=int(result.get("rendered_water_chunks", 0) or 0),
                buildings=int(result.get("building_visible_nodes", 0) or 0),
                veg=int(result.get("vegetation_global_batches", 0) or 0),
                tree=int(result.get("vegetation_tree_batches", 0) or 0),
                grass=int(result.get("vegetation_grass_batches", 0) or 0),
                rock=int(result.get("vegetation_rock_batches", 0) or 0),
                cluster=int(result.get("vegetation_cluster_size", 0) or 0),
                grass_cluster=int(result.get("vegetation_grass_cluster_size", 0) or 0),
                profile="on" if bool(result.get("vegetation_profile_active", False)) else "off",
                entities=int(result.get("entity_active", 0) or 0),
                active=int(result.get("render_active_sample_count", 0) or 0),
                samples=int(result.get("sample_count", 0) or 0),
                suspended=int(result.get("render_loop_suspended_samples", 0) or 0),
            )
        )
        print(
            "                     terrainPrims visible={terrain_visible:9d} chunks={terrain_chunks:9d} "
            "batches={terrain_batches:9d} maxChunk={terrain_max_chunk:6d} maxBatch={terrain_max_batch:6d} | "
            "vegEst={veg_est:9d} tree/grass/rock={tree_est}/{grass_est}/{rock_est} "
            "mesh={tree_mesh}/{grass_mesh}/{rock_mesh} maxInst={tree_max}/{grass_max}/{rock_max} "
            "bounds={bounds:4.0f} occIgnore={occ}".format(
                terrain_visible=int(result.get("terrain_visual_visible_primitives", 0) or 0),
                terrain_chunks=int(result.get("terrain_visual_chunk_primitives", 0) or 0),
                terrain_batches=int(result.get("terrain_visual_batch_primitives", 0) or 0),
                terrain_max_chunk=int(result.get("terrain_visual_max_chunk_primitives", 0) or 0),
                terrain_max_batch=int(result.get("terrain_visual_max_batch_primitives", 0) or 0),
                veg_est=int(result.get("vegetation_estimated_primitives", 0) or 0),
                tree_est=int(result.get("vegetation_tree_estimated_primitives", 0) or 0),
                grass_est=int(result.get("vegetation_grass_estimated_primitives", 0) or 0),
                rock_est=int(result.get("vegetation_rock_estimated_primitives", 0) or 0),
                tree_mesh=int(result.get("tree_mesh_primitives", 0) or 0),
                grass_mesh=int(result.get("grass_mesh_primitives", 0) or 0),
                rock_mesh=int(result.get("rock_mesh_primitives", 0) or 0),
                tree_max=int(result.get("vegetation_tree_max_batch_instances", 0) or 0),
                grass_max=int(result.get("vegetation_grass_max_batch_instances", 0) or 0),
                rock_max=int(result.get("vegetation_rock_max_batch_instances", 0) or 0),
                bounds=float(result.get("vegetation_bounds_padding", 0.0) or 0.0),
                occ="on" if bool(result.get("vegetation_ignore_occlusion_culling", False)) else "off",
            )
        )
    print("=" * 50)


def main() -> int:
    suppress_windows_error_dialogs()
    selected = _selected_case_names()
    results = []
    for case_name in selected:
        results.append(_run_case(case_name, CASES[case_name]))
    results = _add_deltas(results)
    SUMMARY_FILE.parent.mkdir(parents=True, exist_ok=True)
    SUMMARY_FILE.write_text(json.dumps({"results": results}, indent=2), encoding="utf-8")
    _print_results(results)

    failed = [
        result
        for result in results
        if int(result.get("returncode", 1)) != 0 or not bool(result.get("hold_complete", False))
    ]
    if failed:
        print("\nABLATION MATRIX FAILED")
        for result in failed:
            print(f"- {result.get('case', 'unknown')} returncode={result.get('returncode')} hold_complete={result.get('hold_complete')}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
