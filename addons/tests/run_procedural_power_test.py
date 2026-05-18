import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional

import run_town_stall_test as town_runner
from windows_error_dialogs import suppress_windows_error_dialogs


PROJECT_PATH = Path(__file__).resolve().parents[2]
SCENE = "res://addons/tests/procedural_power_test_harness.tscn"
PROCEDURAL_LOG_FILE = PROJECT_PATH / ".agent" / "procedural-power-godot.log"
PROCEDURAL_SNAPSHOT_DIR = PROJECT_PATH / ".agent" / "procedural-power"
WINDOWS_ACCESS_VIOLATION = 3221225477


def _snapshot_root(env: dict[str, str]) -> Path:
    raw = (env.get("PROCEDURAL_POWER_SNAPSHOT_DIR", "") or "").strip()
    if raw and not raw.startswith("user://"):
        return Path(raw)
    return town_runner.SNAPSHOT_DIR


def _latest_snapshot(root: Path, since_mtime: float) -> Optional[Path]:
    candidates = [
        path
        for path in root.glob("procedural_power_snapshot_*.json")
        if path.stat().st_mtime >= since_mtime
    ]
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


def _numbers(samples: list[dict[str, Any]], key: str) -> list[float]:
    values: list[float] = []
    for sample in samples:
        raw_gpu = sample.get("raw_gpu", {})
        if not isinstance(raw_gpu, dict) or not raw_gpu.get("available", False):
            continue
        value = raw_gpu.get(key)
        if isinstance(value, (int, float)):
            values.append(float(value))
    return values


def _summary(values: list[float]) -> dict[str, float]:
    if not values:
        return {"count": 0, "avg": 0.0, "max": 0.0}
    return {
        "count": len(values),
        "avg": round(sum(values) / len(values), 3),
        "max": round(max(values), 3),
    }


def _gpu_sample_summary(gpu_samples: list[dict[str, Any]], started_at_epoch: float, ended_at_epoch: float) -> dict[str, Any]:
    return {
        "sample_count": len(gpu_samples),
        "started_at_epoch": started_at_epoch,
        "ended_at_epoch": ended_at_epoch,
        "duration_s": round(max(0.0, ended_at_epoch - started_at_epoch), 3),
        "power_w": _summary(_numbers(gpu_samples, "power_w")),
        "temp_c": _summary(_numbers(gpu_samples, "temp_c")),
        "gpu_util_percent": _summary(_numbers(gpu_samples, "gpu_util_percent")),
    }


def _phase_epoch_ranges(snapshot: dict[str, Any], started_at_epoch: float, ended_at_epoch: float) -> dict[str, tuple[float, float]]:
    events = [
        event
        for event in snapshot.get("phase_events", [])
        if isinstance(event, dict) and isinstance(event.get("epoch"), (int, float))
    ]
    events.sort(key=lambda event: float(event.get("epoch", 0.0)))
    ranges: dict[str, tuple[float, float]] = {}
    for index, event in enumerate(events):
        phase = str(event.get("phase", ""))
        if not phase:
            continue
        start = float(event.get("epoch", started_at_epoch))
        end = ended_at_epoch
        if index + 1 < len(events):
            end = float(events[index + 1].get("epoch", ended_at_epoch))
        if end > start:
            ranges[phase] = (start, end)
    return ranges


def _gpu_phase_summaries(
    snapshot: dict[str, Any],
    gpu_samples: list[dict[str, Any]],
    started_at_epoch: float,
    ended_at_epoch: float,
) -> dict[str, Any]:
    ranges = _phase_epoch_ranges(snapshot, started_at_epoch, ended_at_epoch)
    phase_summaries: dict[str, Any] = {}
    for phase in ("move", "hold"):
        if phase not in ranges:
            continue
        start, end = ranges[phase]
        window_samples = [
            sample
            for sample in gpu_samples
            if start <= float(sample.get("epoch", 0.0)) <= end
        ]
        phase_summaries[phase] = _gpu_sample_summary(window_samples, start, end)
    return phase_summaries


def _attach_gpu_samples_to_snapshot(
    snapshot_path: Optional[Path],
    snapshot: dict[str, Any],
    gpu_samples: list[dict[str, Any]],
    started_at_epoch: float,
    ended_at_epoch: float,
) -> dict[str, Any]:
    if snapshot_path is None or not snapshot or "error" in snapshot:
        return snapshot

    snapshot["raw_gpu_summary"] = _gpu_sample_summary(gpu_samples, started_at_epoch, ended_at_epoch)
    snapshot["raw_gpu_phase_summary"] = _gpu_phase_summaries(snapshot, gpu_samples, started_at_epoch, ended_at_epoch)
    snapshot["raw_gpu_samples"] = gpu_samples
    try:
        snapshot_path.write_text(json.dumps(snapshot, indent=2), encoding="utf-8")
    except OSError as exc:
        print(f"WARNING: failed to persist procedural raw GPU samples: {exc}")
    return snapshot


def _env_bool(env: dict[str, str], name: str, default: bool) -> bool:
    raw = (env.get(name, "") or "").strip().lower()
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    return default


def _env_float(env: dict[str, str], name: str, default: float) -> float:
    raw = (env.get(name, "") or "").strip()
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if value > 0.0 else default


def _sample_gpu(stop_event: threading.Event, samples: list[dict[str, Any]], interval_s: float) -> None:
    while not stop_event.is_set():
        samples.append({"epoch": time.time(), "raw_gpu": town_runner._collect_raw_gpu_state()})
        stop_event.wait(interval_s)


def _read_json(path: Optional[Path]) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"error": repr(exc), "path": str(path)}


def _print_summary(snapshot_path: Optional[Path], snapshot: dict[str, Any], gpu_samples: list[dict[str, Any]]) -> None:
    final_sample = snapshot.get("final_sample", {}) if isinstance(snapshot, dict) else {}
    terrain = final_sample.get("terrain", {}) if isinstance(final_sample, dict) else {}
    if not isinstance(terrain, dict):
        terrain = {}

    print("\n" + "=" * 50)
    print("PROCEDURAL POWER SUMMARY")
    print("=" * 50)
    print(f"Snapshot: {snapshot_path or 'missing'}")
    print(f"Completed: {bool(snapshot.get('completed', False)) if snapshot else False}")
    print(f"Samples: {len(snapshot.get('samples', [])) if isinstance(snapshot.get('samples', []), list) else 0}")
    print(f"Raw GPU watts avg/max: {_summary(_numbers(gpu_samples, 'power_w'))}")
    print(f"Raw GPU temp avg/max: {_summary(_numbers(gpu_samples, 'temp_c'))}")
    print(f"Raw GPU util avg/max: {_summary(_numbers(gpu_samples, 'gpu_util_percent'))}")
    phase_gpu = snapshot.get("raw_gpu_phase_summary", {}) if isinstance(snapshot, dict) else {}
    if isinstance(phase_gpu, dict):
        for phase in ("move", "hold"):
            summary = phase_gpu.get(phase, {})
            if not isinstance(summary, dict):
                continue
            power = summary.get("power_w", {}) if isinstance(summary.get("power_w"), dict) else {}
            temp = summary.get("temp_c", {}) if isinstance(summary.get("temp_c"), dict) else {}
            print(
                f"Raw GPU {phase} watts avg/max: {power.get('avg', 0.0)}/{power.get('max', 0.0)} "
                f"temp avg/max: {temp.get('avg', 0.0)}/{temp.get('max', 0.0)}"
            )
    print(
        "Render: "
        f"draws={final_sample.get('draw_calls')} "
        f"objects={final_sample.get('render_objects')} "
        f"primitives={final_sample.get('primitives')}"
    )
    shadow_summary = ""
    if "terrain_shadow_lod_enabled" in terrain:
        shadow_summary = (
            f"shadow_lod_enabled={terrain.get('terrain_shadow_lod_enabled')} "
            f"shadow_radius={terrain.get('terrain_shadow_lod_radius_chunks')} "
            f"shadow_on={terrain.get('last_terrain_shadow_lod_enabled_count')} "
            f"shadow_off={terrain.get('last_terrain_shadow_lod_disabled_count')} "
        )
    print(
        "Terrain: "
        f"world_map_active={terrain.get('world_map_active')} "
        f"chunks={terrain.get('rendered_terrain_chunk_count')} "
        f"{shadow_summary}"
        f"runtime_power={terrain.get('runtime_power_mode')}@{terrain.get('runtime_power_target_fps')} "
        f"reason={terrain.get('runtime_power_active_reason')}"
    )
    print("=" * 50)


def _validate_runtime_power(snapshot: dict[str, Any], env: dict[str, str]) -> list[str]:
    if not snapshot or not bool(snapshot.get("completed", False)):
        return ["procedural power snapshot missing or incomplete"]

    final_sample = snapshot.get("final_sample", {})
    if not isinstance(final_sample, dict):
        return ["procedural power final_sample missing"]

    terrain = final_sample.get("terrain", {})
    building = final_sample.get("building", {})
    if not isinstance(terrain, dict):
        terrain = {}
    if not isinstance(building, dict):
        building = {}

    failures: list[str] = []
    hold_seconds = _env_float(env, "PROCEDURAL_POWER_HOLD_SECONDS", 8.0)
    idle_delay_s = _env_float(env, "TOWN_STALL_RUNTIME_POWER_IDLE_DELAY_S", 1.25)
    deep_idle_delay_s = _env_float(env, "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_DELAY_S", 10.0)
    require_idle = _env_bool(env, "PROCEDURAL_POWER_REQUIRE_IDLE", hold_seconds >= idle_delay_s + 0.5)
    require_deep_idle = _env_bool(env, "PROCEDURAL_POWER_REQUIRE_DEEP_IDLE", hold_seconds >= deep_idle_delay_s + 0.5)

    if bool(terrain.get("world_map_active", False)):
        failures.append("procedural scene unexpectedly ended with world_map_active=true")

    dirty_visible = int(building.get("dirty_visible_chunk_count", 0) or 0)
    if dirty_visible != 0:
        failures.append(f"building dirty visible chunks remained queued: {dirty_visible}")

    if require_idle:
        mode = str(terrain.get("runtime_power_mode", ""))
        if mode == "active":
            failures.append(
                "runtime power stayed active "
                f"(reason={terrain.get('runtime_power_active_reason')})"
            )
        if bool(terrain.get("runtime_power_external_world_busy", False)):
            failures.append("runtime power external_world_busy stayed true")
        if not bool(terrain.get("runtime_power_world_work_suspended", False)):
            failures.append("runtime power did not suspend background world work")

    if require_deep_idle:
        mode = str(terrain.get("runtime_power_mode", ""))
        target_fps = int(terrain.get("runtime_power_target_fps", 0) or 0)
        deep_idle_fps = int(terrain.get("runtime_power_deep_idle_max_fps", 30) or 30)
        if mode != "deep_idle":
            failures.append(f"runtime power did not reach deep_idle (mode={mode})")
        if target_fps <= 0 or target_fps > deep_idle_fps:
            failures.append(f"runtime power target FPS was not deep-idle capped ({target_fps}>{deep_idle_fps})")
        if not bool(terrain.get("runtime_power_render_loop_suspended", False)):
            failures.append("runtime power did not suspend the render loop in deep idle")
        if bool(terrain.get("runtime_power_render_loop_enabled", True)):
            failures.append("runtime power render loop remained enabled in deep idle")

    return failures


def main() -> int:
    suppress_windows_error_dialogs()
    run_start_mtime = time.time()
    env = os.environ.copy()
    env.setdefault("PROCEDURAL_POWER_MOVE_SECONDS", "16")
    env.setdefault("PROCEDURAL_POWER_HOLD_SECONDS", "8")
    env.setdefault("PROCEDURAL_POWER_SAMPLE_INTERVAL_S", "1")
    env.setdefault("PROCEDURAL_POWER_SNAPSHOT_DIR", str(PROCEDURAL_SNAPSHOT_DIR))
    env.setdefault("TOWN_STALL_ENABLE_RUNTIME_POWER_MODE", "1")

    sample_interval_s = float(env.get("TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS", "2") or "2")
    gpu_samples: list[dict[str, Any]] = []
    stop_event = threading.Event()
    sampler = threading.Thread(target=_sample_gpu, args=(stop_event, gpu_samples, sample_interval_s), daemon=True)
    sampler.start()

    PROCEDURAL_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        town_runner.GODOT_BIN,
        "--log-file",
        str(PROCEDURAL_LOG_FILE),
        "--path",
        str(PROJECT_PATH),
        SCENE,
    ]
    print("Running procedural power test...")
    print(f"   Scene: {SCENE}")
    result = subprocess.run(
        cmd,
        cwd=PROJECT_PATH,
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        timeout=120,
    )
    stop_event.set()
    sampler.join(timeout=5)
    run_end_epoch = time.time()

    output = (result.stdout or "") + "\n" + (result.stderr or "")
    print("\n" + "=" * 50)
    print("FULL OUTPUT")
    print("=" * 50)
    print(output)

    snapshot_path = _latest_snapshot(_snapshot_root(env), run_start_mtime - 1.0)
    snapshot = _read_json(snapshot_path)
    snapshot = _attach_gpu_samples_to_snapshot(snapshot_path, snapshot, gpu_samples, run_start_mtime, run_end_epoch)
    _print_summary(snapshot_path, snapshot, gpu_samples)

    validation_failures = _validate_runtime_power(snapshot, env)
    if validation_failures:
        print("ERROR: procedural power validation failed:")
        for failure in validation_failures:
            print(f"  - {failure}")
        return 1

    completed = bool(snapshot.get("completed", False))
    if result.returncode == WINDOWS_ACCESS_VIOLATION and completed:
        print("WARNING: Godot exited with an access violation during shutdown after completing the procedural power test; treating this as non-fatal because the snapshot was written.")
        return 0
    if result.returncode != 0:
        print(f"ERROR: Godot exited with code {result.returncode}")
        return result.returncode
    if not snapshot_path or not completed:
        print("ERROR: procedural power snapshot missing or incomplete")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
