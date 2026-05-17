import json
import os
import sys
import time
from pathlib import Path

import run_town_stall_test


DEFAULT_ENDURANCE_SECONDS = 12 * 60 * 60


def _set_default_env() -> None:
    defaults = {
        "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
        "TOWN_STALL_RUNTIME_POWER_SUSPEND_BACKGROUND_WORLD_WORK": "1",
        "TOWN_STALL_RUNTIME_POWER_SUSPEND_RENDER_LOOP": "1",
        "TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS": "1",
        "TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS": "10",
        "TOWN_STALL_MACHINE_WARMUP_DISABLED": "0",
        "TOWN_STALL_HOLD_SECONDS": str(DEFAULT_ENDURANCE_SECONDS),
    }
    for key, value in defaults.items():
        os.environ.setdefault(key, value)


def _read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _validate_endurance_outputs(snapshot: dict, system_summary: dict) -> list[str]:
    failures: list[str] = []
    if not snapshot:
        failures.append("snapshot was empty or unreadable")
    elif not bool(snapshot.get("benchmark_hold_complete", False)):
        failures.append("benchmark hold did not complete")

    if not system_summary or not bool(system_summary.get("available", False)):
        failures.append("system sample summary was unavailable")
    elif int(system_summary.get("sample_count", 0) or 0) <= 0:
        failures.append("system sample summary had no samples")
    elif int(system_summary.get("raw_gpu_available_count", 0) or 0) <= 0:
        failures.append("raw GPU watt/temp samples were unavailable")

    if snapshot:
        system_telemetry = snapshot.get("system_telemetry", {})
        terrain = system_telemetry.get("terrain_manager", {}) if isinstance(system_telemetry, dict) else {}
        if not isinstance(terrain, dict):
            terrain = {}
        if not bool(terrain.get("runtime_power_suspend_background_world_work", False)):
            failures.append("background world-work suspension was not enabled")
        if int(terrain.get("runtime_power_world_work_suspend_count", 0) or 0) <= 0:
            failures.append("terrain never entered world-work suspension")

    return failures


def _print_summary(snapshot_path: Path, snapshot: dict, system_summary: dict) -> None:
    stationary_hold = snapshot.get("stationary_hold_window", {}) if snapshot else {}
    if not isinstance(stationary_hold, dict):
        stationary_hold = {}

    print("\n" + "=" * 50)
    print("ENDURANCE POWER SUMMARY")
    print("=" * 50)
    print(f"Snapshot: {snapshot_path if snapshot_path else 'missing'}")
    print(f"Hold complete: {bool(snapshot.get('benchmark_hold_complete', False)) if snapshot else False}")
    print(f"Hold samples: {int(stationary_hold.get('sample_count', 0) or 0)}")
    print(
        "Suspended samples: "
        f"{int(stationary_hold.get('terrain_runtime_power_world_work_suspended_samples', 0) or 0)}"
    )
    if system_summary:
        print(f"System samples: {int(system_summary.get('sample_count', 0) or 0)}")
        print(f"System duration: {float(system_summary.get('duration_seconds', 0.0) or 0.0):.1f}s")
        process_cpu = system_summary.get("process_cpu_percent", {})
        gpu_total = system_summary.get("gpu_total_percent", {})
        raw_gpu_power = system_summary.get("raw_gpu_power_w", {})
        raw_gpu_temp = system_summary.get("raw_gpu_temp_c", {})
        cpu_load = system_summary.get("cpu_load_percent", {})
        print(f"Godot CPU avg/max: {process_cpu.get('avg', 0.0)}% / {process_cpu.get('max', 0.0)}%")
        print(f"GPU total avg/max: {gpu_total.get('avg', 0.0)}% / {gpu_total.get('max', 0.0)}%")
        print(f"Raw GPU watts avg/max: {raw_gpu_power.get('avg', 0.0)} W / {raw_gpu_power.get('max', 0.0)} W")
        print(f"Raw GPU temp avg/max: {raw_gpu_temp.get('avg', 0.0)} C / {raw_gpu_temp.get('max', 0.0)} C")
        print(f"CPU load avg/max: {cpu_load.get('avg', 0.0)}% / {cpu_load.get('max', 0.0)}%")
    print("=" * 50)


def main() -> int:
    run_start_mtime = time.time()
    _set_default_env()
    result = run_town_stall_test.main()
    snapshot_path = run_town_stall_test._latest_snapshot(run_start_mtime - 1.0)
    snapshot = _read_json(snapshot_path) if snapshot_path else {}
    system_summary = _read_json(run_town_stall_test.SYSTEM_SAMPLE_SUMMARY_FILE)
    _print_summary(snapshot_path, snapshot, system_summary)
    if result != 0:
        return result

    failures = _validate_endurance_outputs(snapshot, system_summary)
    if failures:
        print("\nENDURANCE POWER TEST FAILED")
        for failure in failures:
            print(f"- {failure}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
