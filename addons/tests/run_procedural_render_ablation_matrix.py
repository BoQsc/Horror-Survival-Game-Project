import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import run_procedural_power_test as procedural_runner
from windows_error_dialogs import suppress_windows_error_dialogs


PROJECT_PATH = procedural_runner.PROJECT_PATH
SUMMARY_FILE = PROJECT_PATH / ".agent" / "procedural-render-ablation-summary.json"

CASES: dict[str, dict[str, str]] = {
    "baseline": {},
    "legacy_vegetation_lod": {
        "TOWN_STALL_VEGETATION_RENDER_EXTRA_CULL_MARGIN": "1000",
        "TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "100",
    },
    "no_water": {"TOWN_STALL_DISABLE_WATER_RENDER": "1"},
    "no_vegetation": {"PROCEDURAL_POWER_DISABLE_VEGETATION": "1"},
    "no_entities": {"PROCEDURAL_POWER_DISABLE_ENTITIES": "1"},
    "no_glow": {"PROCEDURAL_POWER_DISABLE_GLOW": "1"},
    "shadow_radius_1": {"TOWN_STALL_TERRAIN_SHADOW_LOD_RADIUS": "1"},
    "shadow_radius_0": {"TOWN_STALL_TERRAIN_SHADOW_LOD_RADIUS": "0"},
}


def _selected_case_names() -> list[str]:
    raw = os.environ.get(
        "PROCEDURAL_ABLATION_CASES",
        "baseline,legacy_vegetation_lod,no_water,no_vegetation",
    )
    names = [name.strip() for name in raw.split(",") if name.strip()]
    selected: list[str] = []
    for name in names:
        if name not in CASES:
            print(f"WARNING: Unknown procedural ablation case '{name}', skipping.")
            continue
        selected.append(name)
    return selected or ["baseline"]


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    try:
        return int(raw)
    except ValueError:
        return default


def _read_json(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"error": repr(exc), "path": str(path)}


def _phase_samples(snapshot: dict[str, Any], phase: str) -> list[dict[str, Any]]:
    samples = snapshot.get("samples", [])
    if not isinstance(samples, list):
        return []
    return [sample for sample in samples if isinstance(sample, dict) and sample.get("phase") == phase]


def _avg(samples: list[dict[str, Any]], key: str) -> float:
    values = [float(sample.get(key, 0.0) or 0.0) for sample in samples]
    return round(sum(values) / len(values), 3) if values else 0.0


def _min(samples: list[dict[str, Any]], key: str) -> float:
    values = [float(sample.get(key, 0.0) or 0.0) for sample in samples]
    return round(min(values), 3) if values else 0.0


def _max(samples: list[dict[str, Any]], key: str) -> float:
    values = [float(sample.get(key, 0.0) or 0.0) for sample in samples]
    return round(max(values), 3) if values else 0.0


def _pipeline_delta(samples: list[dict[str, Any]], key: str = "pipeline_compilations_total") -> int:
    if len(samples) < 2:
        return 0
    return max(0, int(samples[-1].get(key, 0) or 0) - int(samples[0].get(key, 0) or 0))


def _gpu_phase(snapshot: dict[str, Any], phase: str) -> dict[str, Any]:
    raw_phase = snapshot.get("raw_gpu_phase_summary", {})
    if not isinstance(raw_phase, dict):
        return {}
    summary = raw_phase.get(phase, {})
    if not isinstance(summary, dict):
        return {}
    power = summary.get("power_w", {}) if isinstance(summary.get("power_w"), dict) else {}
    temp = summary.get("temp_c", {}) if isinstance(summary.get("temp_c"), dict) else {}
    util = summary.get("gpu_util_percent", {}) if isinstance(summary.get("gpu_util_percent"), dict) else {}
    return {
        "raw_gpu_sample_count": int(power.get("count", 0) or 0),
        "raw_gpu_power_avg_w": float(power.get("avg", 0.0) or 0.0),
        "raw_gpu_power_max_w": float(power.get("max", 0.0) or 0.0),
        "raw_gpu_temp_avg_c": float(temp.get("avg", 0.0) or 0.0),
        "raw_gpu_temp_max_c": float(temp.get("max", 0.0) or 0.0),
        "raw_gpu_util_avg_percent": float(util.get("avg", 0.0) or 0.0),
    }


def _phase_summary(snapshot: dict[str, Any], phase: str) -> dict[str, Any]:
    samples = _phase_samples(snapshot, phase)
    summary = {
        "sample_count": len(samples),
        "fps_avg": _avg(samples, "fps"),
        "fps_min": _min(samples, "fps"),
        "process_ms_avg": _avg(samples, "process_ms"),
        "physics_ms_avg": _avg(samples, "physics_ms"),
        "draw_calls_avg": _avg(samples, "draw_calls"),
        "draw_calls_max": _max(samples, "draw_calls"),
        "objects_avg": _avg(samples, "render_objects"),
        "primitives_avg": _avg(samples, "primitives"),
        "primitives_max": _max(samples, "primitives"),
        "vram_mb_avg": _avg(samples, "vram_mb"),
        "pipeline_compilations_canvas_delta": _pipeline_delta(samples, "pipeline_compilations_canvas"),
        "pipeline_compilations_mesh_delta": _pipeline_delta(samples, "pipeline_compilations_mesh"),
        "pipeline_compilations_surface_delta": _pipeline_delta(samples, "pipeline_compilations_surface"),
        "pipeline_compilations_draw_delta": _pipeline_delta(samples, "pipeline_compilations_draw"),
        "pipeline_compilations_specialization_delta": _pipeline_delta(samples, "pipeline_compilations_specialization"),
        "pipeline_compilations_total_delta": _pipeline_delta(samples),
    }
    summary.update(_gpu_phase(snapshot, phase))
    return summary


def _final_sample_summary(snapshot: dict[str, Any]) -> dict[str, Any]:
    final = snapshot.get("final_sample", {})
    if not isinstance(final, dict):
        return {}
    terrain = final.get("terrain", {}) if isinstance(final.get("terrain"), dict) else {}
    vegetation = final.get("vegetation", {}) if isinstance(final.get("vegetation"), dict) else {}
    entities = final.get("entities", {}) if isinstance(final.get("entities"), dict) else {}
    return {
        "draw_calls": int(final.get("draw_calls", 0) or 0),
        "objects": int(final.get("render_objects", 0) or 0),
        "primitives": int(final.get("primitives", 0) or 0),
        "fps": float(final.get("fps", 0.0) or 0.0),
        "runtime_power_mode": str(terrain.get("runtime_power_mode", "")),
        "runtime_power_target_fps": int(terrain.get("runtime_power_target_fps", 0) or 0),
        "terrain_chunks": int(terrain.get("rendered_terrain_chunk_count", 0) or 0),
        "water_chunks": int(terrain.get("rendered_water_chunk_count", 0) or 0),
        "terrain_shadow_radius": int(terrain.get("terrain_shadow_lod_radius_chunks", 0) or 0),
        "terrain_shadow_on": int(terrain.get("last_terrain_shadow_lod_enabled_count", 0) or 0),
        "terrain_shadow_off": int(terrain.get("last_terrain_shadow_lod_disabled_count", 0) or 0),
        "vegetation_batches": int(vegetation.get("global_render_batch_count", 0) or 0),
        "vegetation_lod_bias": float(vegetation.get("vegetation_render_lod_bias", 0.0) or 0.0),
        "vegetation_extra_cull_margin": float(vegetation.get("vegetation_render_extra_cull_margin", 0.0) or 0.0),
        "vegetation_tree_instances": int(vegetation.get("global_tree_render_instances", 0) or 0),
        "vegetation_grass_instances": int(vegetation.get("global_grass_render_instances", 0) or 0),
        "vegetation_rock_instances": int(vegetation.get("global_rock_render_instances", 0) or 0),
        "entity_active": int(entities.get("active_entities", 0) or 0),
    }


def _set_default_env(env: dict[str, str], target: str, alias: str, default: str) -> None:
    env[target] = os.environ.get(alias, env.get(target, default))


def _run_case(case_name: str, case_env: dict[str, str]) -> dict[str, Any]:
    run_start_mtime = time.time()
    env = os.environ.copy()
    _set_default_env(env, "PROCEDURAL_POWER_MOVE_SECONDS", "PROCEDURAL_ABLATION_MOVE_SECONDS", "8")
    _set_default_env(env, "PROCEDURAL_POWER_HOLD_SECONDS", "PROCEDURAL_ABLATION_HOLD_SECONDS", "2")
    _set_default_env(env, "PROCEDURAL_POWER_SAMPLE_INTERVAL_S", "PROCEDURAL_ABLATION_SAMPLE_INTERVAL_S", "1")
    _set_default_env(env, "TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS", "PROCEDURAL_ABLATION_GPU_SAMPLE_INTERVAL_SECONDS", "1")
    env.setdefault("PROCEDURAL_POWER_REQUIRE_IDLE", "0")
    env.setdefault("PROCEDURAL_POWER_REQUIRE_DEEP_IDLE", "0")
    env.setdefault("TOWN_STALL_ENABLE_RUNTIME_POWER_MODE", "1")
    env.setdefault("PROCEDURAL_POWER_SNAPSHOT_DIR", str(procedural_runner.PROCEDURAL_SNAPSHOT_DIR))

    screenshot_root = os.environ.get("PROCEDURAL_ABLATION_SCREENSHOT_ROOT", "").strip()
    if screenshot_root:
        env["PROCEDURAL_POWER_SCREENSHOT_DIR"] = str(Path(screenshot_root) / case_name)

    env.update(case_env)

    print("\n" + "=" * 50)
    print(f"RUNNING PROCEDURAL ABLATION CASE: {case_name}")
    print("=" * 50)
    result = subprocess.run(
        [sys.executable, str(Path(__file__).with_name("run_procedural_power_test.py"))],
        cwd=PROJECT_PATH,
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    snapshot_path = procedural_runner._latest_snapshot(
        procedural_runner._snapshot_root(env),
        run_start_mtime - 1.0,
    )
    snapshot = _read_json(snapshot_path)
    return {
        "case": case_name,
        "returncode": result.returncode,
        "completed": bool(snapshot.get("completed", False)) if snapshot else False,
        "snapshot": str(snapshot_path) if snapshot_path else "",
        "move": _phase_summary(snapshot, "move"),
        "hold": _phase_summary(snapshot, "hold"),
        "final": _final_sample_summary(snapshot),
        "visual_capture": snapshot.get("visual_capture", {}) if isinstance(snapshot.get("visual_capture"), dict) else {},
        "manager_isolation": snapshot.get("manager_isolation", {}) if isinstance(snapshot.get("manager_isolation"), dict) else {},
    }


def _add_deltas(results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    baseline = next((result for result in results if result.get("case") == "baseline"), None)
    if not baseline:
        return results

    def value(result: dict[str, Any], section: str, metric: str) -> float:
        section_value = result.get(section, {})
        if not isinstance(section_value, dict):
            return 0.0
        return float(section_value.get(metric, 0.0) or 0.0)

    comparisons = [
        ("move", "primitives_avg"),
        ("move", "raw_gpu_power_avg_w"),
        ("hold", "primitives_avg"),
        ("hold", "raw_gpu_power_avg_w"),
        ("final", "primitives"),
        ("final", "draw_calls"),
        ("final", "terrain_chunks"),
        ("final", "water_chunks"),
    ]
    for result in results:
        deltas: dict[str, float] = {}
        for section, metric in comparisons:
            deltas[f"{section}_{metric}"] = round(value(result, section, metric) - value(baseline, section, metric), 3)
        result["delta_from_baseline"] = deltas
    return results


def _print_results(results: list[dict[str, Any]]) -> None:
    print("\n" + "=" * 50)
    print("PROCEDURAL RENDER ABLATION SUMMARY")
    print("=" * 50)
    for result in results:
        move = result.get("move", {}) if isinstance(result.get("move"), dict) else {}
        hold = result.get("hold", {}) if isinstance(result.get("hold"), dict) else {}
        final = result.get("final", {}) if isinstance(result.get("final"), dict) else {}
        delta = result.get("delta_from_baseline", {}) if isinstance(result.get("delta_from_baseline"), dict) else {}
        print(
            "{case:>22} | move prims={move_prims:9.0f} ({dmove_prims:+9.0f}) "
            "watts={move_watts:6.2f} ({dmove_watts:+6.2f}) samples={move_gpu:2d} | "
            "hold prims={hold_prims:9.0f} ({dhold_prims:+9.0f}) watts={hold_watts:6.2f} ({dhold_watts:+6.2f}) "
            "samples={hold_gpu:2d} pipes={pipes:3d} | final draws={draws:4d} prims={final_prims:9d} "
            "chunks={chunks:3d} water={water:3d} veglod={lod:5.1f} margin={margin:5.0f}".format(
                case=str(result.get("case", "")),
                move_prims=float(move.get("primitives_avg", 0.0) or 0.0),
                dmove_prims=float(delta.get("move_primitives_avg", 0.0) or 0.0),
                move_watts=float(move.get("raw_gpu_power_avg_w", 0.0) or 0.0),
                dmove_watts=float(delta.get("move_raw_gpu_power_avg_w", 0.0) or 0.0),
                move_gpu=int(move.get("raw_gpu_sample_count", 0) or 0),
                hold_prims=float(hold.get("primitives_avg", 0.0) or 0.0),
                dhold_prims=float(delta.get("hold_primitives_avg", 0.0) or 0.0),
                hold_watts=float(hold.get("raw_gpu_power_avg_w", 0.0) or 0.0),
                dhold_watts=float(delta.get("hold_raw_gpu_power_avg_w", 0.0) or 0.0),
                hold_gpu=int(hold.get("raw_gpu_sample_count", 0) or 0),
                pipes=int(move.get("pipeline_compilations_total_delta", 0) or 0)
                + int(hold.get("pipeline_compilations_total_delta", 0) or 0),
                draws=int(final.get("draw_calls", 0) or 0),
                final_prims=int(final.get("primitives", 0) or 0),
                chunks=int(final.get("terrain_chunks", 0) or 0),
                water=int(final.get("water_chunks", 0) or 0),
                lod=float(final.get("vegetation_lod_bias", 0.0) or 0.0),
                margin=float(final.get("vegetation_extra_cull_margin", 0.0) or 0.0),
            )
        )
    print("=" * 50)


def _load_summary_results() -> list[dict[str, Any]]:
    summary = _read_json(SUMMARY_FILE)
    results = summary.get("results", []) if isinstance(summary, dict) else []
    return [result for result in results if isinstance(result, dict)]


def _failed_results(results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    require_raw_gpu = os.environ.get("PROCEDURAL_ABLATION_REQUIRE_RAW_GPU", "1") != "0"
    require_comparable_chunks = os.environ.get("PROCEDURAL_ABLATION_REQUIRE_COMPARABLE_CHUNKS", "1") != "0"
    chunk_tolerance = max(0, _env_int("PROCEDURAL_ABLATION_TERRAIN_CHUNK_TOLERANCE", 4))
    baseline = next((result for result in results if result.get("case") == "baseline"), None)
    baseline_final = baseline.get("final", {}) if isinstance(baseline, dict) and isinstance(baseline.get("final"), dict) else {}
    baseline_chunks = int(baseline_final.get("terrain_chunks", 0) or 0)
    failed: list[dict[str, Any]] = []
    for result in results:
        move = result.get("move", {}) if isinstance(result.get("move"), dict) else {}
        final = result.get("final", {}) if isinstance(result.get("final"), dict) else {}
        if int(result.get("returncode", 1)) != 0 or not bool(result.get("completed", False)):
            failed.append(result)
            continue
        if int(move.get("sample_count", 0) or 0) <= 0:
            failed.append(result)
            continue
        if require_raw_gpu and int(move.get("raw_gpu_sample_count", 0) or 0) <= 0:
            failed.append(result)
            continue
        if (
            require_comparable_chunks
            and baseline_chunks > 0
            and result.get("case") != "baseline"
            and abs(int(final.get("terrain_chunks", 0) or 0) - baseline_chunks) > chunk_tolerance
        ):
            failed.append(result)
    return failed


def main() -> int:
    suppress_windows_error_dialogs()
    if os.environ.get("PROCEDURAL_ABLATION_REPLAY_SUMMARY", "0") == "1":
        results = _load_summary_results()
        if not results:
            print(f"ERROR: no procedural ablation summary results found at {SUMMARY_FILE}")
            return 1
    else:
        selected = _selected_case_names()
        results = [_run_case(case_name, CASES[case_name]) for case_name in selected]
        results = _add_deltas(results)
        SUMMARY_FILE.parent.mkdir(parents=True, exist_ok=True)
        SUMMARY_FILE.write_text(json.dumps({"results": results}, indent=2), encoding="utf-8")
    _print_results(results)

    failed = _failed_results(results)
    if failed:
        print("\nPROCEDURAL ABLATION MATRIX FAILED")
        for result in failed:
            move = result.get("move", {}) if isinstance(result.get("move"), dict) else {}
            final = result.get("final", {}) if isinstance(result.get("final"), dict) else {}
            print(
                f"- {result.get('case', 'unknown')} returncode={result.get('returncode')} "
                f"completed={result.get('completed')} move_samples={move.get('sample_count', 0)} "
                f"gpu_samples={move.get('raw_gpu_sample_count', 0)} "
                f"terrain_chunks={final.get('terrain_chunks', 0)}"
            )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
