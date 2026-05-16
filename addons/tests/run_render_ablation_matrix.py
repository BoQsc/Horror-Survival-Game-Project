import json
import os
import subprocess
import sys
import time
from pathlib import Path

import run_town_stall_test


SUMMARY_FILE = Path(run_town_stall_test.PROJECT_PATH) / ".agent" / "render-ablation-summary.json"

CASES = {
    "baseline": {},
    "no_water": {"TOWN_STALL_DISABLE_WATER_RENDER": "1"},
    "no_buildings": {"TOWN_STALL_DISABLE_BUILDINGS": "1"},
    "no_building_objects": {"TOWN_STALL_DISABLE_BUILDING_OBJECTS": "1"},
    "no_entities": {"TOWN_STALL_DISABLE_ENTITIES": "1"},
    "no_glow": {"TOWN_STALL_DISABLE_GLOW": "1"},
}


def _selected_case_names() -> list[str]:
    raw = os.environ.get("TOWN_STALL_ABLATION_CASES", "baseline,no_water,no_buildings,no_entities")
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


def _run_case(case_name: str, case_env: dict[str, str]) -> dict:
    run_start_mtime = time.time()
    env = os.environ.copy()
    env.setdefault("TOWN_STALL_HOLD_SECONDS", "12")
    env.setdefault("TOWN_STALL_MACHINE_WARMUP_DISABLED", "1")
    env.setdefault("TOWN_STALL_ENABLE_RUNTIME_POWER_MODE", "1")
    env.setdefault("TOWN_STALL_RUNTIME_POWER_SUSPEND_BACKGROUND_WORLD_WORK", "1")
    env.setdefault("TOWN_STALL_RUNTIME_POWER_SUSPEND_RENDER_LOOP", "1")
    env.setdefault("TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS", "0")
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
    snapshot_path = run_town_stall_test._latest_snapshot(run_start_mtime - 1.0)
    snapshot = _read_json(snapshot_path) if snapshot_path else {}
    town_window = snapshot.get("town_entry_window", {}) if isinstance(snapshot, dict) else {}
    stationary_hold = snapshot.get("stationary_hold_window", {}) if isinstance(snapshot, dict) else {}
    system_telemetry = snapshot.get("system_telemetry", {}) if isinstance(snapshot, dict) else {}
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

    return {
        "case": case_name,
        "returncode": result.returncode,
        "snapshot": str(snapshot_path) if snapshot_path else "",
        "hold_complete": bool(snapshot.get("benchmark_hold_complete", False)) if snapshot else False,
        "avg_total_ms": float(stationary_hold.get("avg_total_ms", town_window.get("avg_total_ms", 0.0)) or 0.0),
        "avg_draw_calls": float(stationary_hold.get("avg_draw_calls", town_window.get("avg_draw_calls", 0.0)) or 0.0),
        "avg_objects": float(stationary_hold.get("avg_objects", town_window.get("avg_objects", 0.0)) or 0.0),
        "frames_over_budget": int(stationary_hold.get("frames_over_budget", town_window.get("frames_over_budget", 0)) or 0),
        "rendered_terrain_chunks": int(terrain.get("rendered_terrain_chunk_count", 0) or 0),
        "rendered_water_chunks": int(terrain.get("rendered_water_chunk_count", 0) or 0),
        "building_visible_nodes": int(building.get("visible_world_map_baked_building_visual_nodes", 0) or 0),
        "building_visible_surfaces": int(building.get("visible_world_map_baked_building_visual_surfaces", 0) or 0),
        "vegetation_global_batches": int(vegetation.get("global_render_batch_count", 0) or 0),
        "entity_active": int(entities.get("active_entities", 0) or 0),
    }


def _add_deltas(results: list[dict]) -> list[dict]:
    baseline = next((result for result in results if result.get("case") == "baseline"), None)
    if not baseline:
        return results
    baseline_ms = float(baseline.get("avg_total_ms", 0.0) or 0.0)
    baseline_draws = float(baseline.get("avg_draw_calls", 0.0) or 0.0)
    baseline_objects = float(baseline.get("avg_objects", 0.0) or 0.0)
    for result in results:
        result["delta_avg_total_ms"] = round(float(result.get("avg_total_ms", 0.0) or 0.0) - baseline_ms, 3)
        result["delta_avg_draw_calls"] = round(float(result.get("avg_draw_calls", 0.0) or 0.0) - baseline_draws, 3)
        result["delta_avg_objects"] = round(float(result.get("avg_objects", 0.0) or 0.0) - baseline_objects, 3)
    return results


def _print_results(results: list[dict]) -> None:
    print("\n" + "=" * 50)
    print("RENDER ABLATION SUMMARY")
    print("=" * 50)
    for result in results:
        print(
            "{case:>20} | ms={ms:6.2f} ({dms:+6.2f}) | draws={draws:7.1f} ({ddraws:+7.1f}) | "
            "objects={objects:7.1f} ({dobjects:+7.1f}) | terrain={terrain:4d} water={water:4d} "
            "buildings={buildings:4d} veg_batches={veg:3d} entities={entities:3d}".format(
                case=str(result.get("case", "")),
                ms=float(result.get("avg_total_ms", 0.0) or 0.0),
                dms=float(result.get("delta_avg_total_ms", 0.0) or 0.0),
                draws=float(result.get("avg_draw_calls", 0.0) or 0.0),
                ddraws=float(result.get("delta_avg_draw_calls", 0.0) or 0.0),
                objects=float(result.get("avg_objects", 0.0) or 0.0),
                dobjects=float(result.get("delta_avg_objects", 0.0) or 0.0),
                terrain=int(result.get("rendered_terrain_chunks", 0) or 0),
                water=int(result.get("rendered_water_chunks", 0) or 0),
                buildings=int(result.get("building_visible_nodes", 0) or 0),
                veg=int(result.get("vegetation_global_batches", 0) or 0),
                entities=int(result.get("entity_active", 0) or 0),
            )
        )
    print("=" * 50)


def main() -> int:
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
