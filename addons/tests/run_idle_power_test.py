import json
import os
import sys
import time
from pathlib import Path

import run_town_stall_test


def _read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _set_default_env() -> None:
    defaults = {
        "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
        "TOWN_STALL_RUNTIME_POWER_SUSPEND_BACKGROUND_WORLD_WORK": "1",
        "TOWN_STALL_RUNTIME_POWER_SUSPEND_RENDER_LOOP": "1",
        "TOWN_STALL_RUNTIME_POWER_IDLE_DELAY_S": "1.25",
        "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_DELAY_S": "3.0",
        "TOWN_STALL_HOLD_SECONDS": "25",
        "TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS": "1",
        "TOWN_STALL_MACHINE_WARMUP_DISABLED": "1",
    }
    for key, value in defaults.items():
        os.environ.setdefault(key, value)


def _validate_snapshot(snapshot: dict) -> list[str]:
    failures: list[str] = []
    if not snapshot:
        return ["snapshot was empty or unreadable"]

    if not bool(snapshot.get("benchmark_hold_complete", False)):
        failures.append("town hold did not complete")

    stationary_hold = snapshot.get("stationary_hold_window", {})
    if not isinstance(stationary_hold, dict):
        stationary_hold = {}
    suspended_samples = int(stationary_hold.get("terrain_runtime_power_world_work_suspended_samples", 0) or 0)
    if suspended_samples <= 0:
        failures.append("stationary hold had no samples with suspended terrain world work")
    render_loop_suspended_samples = int(
        stationary_hold.get("terrain_runtime_power_render_loop_suspended_samples", 0) or 0
    )
    if render_loop_suspended_samples <= 0:
        failures.append("stationary hold had no samples with suspended render loop")
    render_active_samples = int(stationary_hold.get("render_active_sample_count", 0) or 0)
    if render_active_samples <= 0:
        failures.append("stationary hold had no render-active samples to compare against suspended idle")

    system_telemetry = snapshot.get("system_telemetry", {})
    terrain = system_telemetry.get("terrain_manager", {}) if isinstance(system_telemetry, dict) else {}
    if not isinstance(terrain, dict):
        terrain = {}

    suspend_count = int(terrain.get("runtime_power_world_work_suspend_count", 0) or 0)
    if suspend_count <= 0:
        failures.append("terrain manager never entered world-work suspension")

    if not bool(terrain.get("runtime_power_suspend_background_world_work", False)):
        failures.append("background world-work suspension was not enabled in telemetry")

    return failures


def _print_idle_summary(snapshot_path: Path, snapshot: dict) -> None:
    stationary_hold = snapshot.get("stationary_hold_window", {})
    system_telemetry = snapshot.get("system_telemetry", {})
    terrain = system_telemetry.get("terrain_manager", {}) if isinstance(system_telemetry, dict) else {}
    if not isinstance(stationary_hold, dict):
        stationary_hold = {}
    if not isinstance(terrain, dict):
        terrain = {}

    print("\n" + "=" * 50)
    print("IDLE POWER REGRESSION SUMMARY")
    print("=" * 50)
    print(f"Snapshot: {snapshot_path}")
    print(f"Hold complete: {bool(snapshot.get('benchmark_hold_complete', False))}")
    print(f"Hold samples: {int(stationary_hold.get('sample_count', 0) or 0)}")
    print(f"Render-active samples: {int(stationary_hold.get('render_active_sample_count', 0) or 0)}")
    print(
        "World-work suspended samples: "
        f"{int(stationary_hold.get('terrain_runtime_power_world_work_suspended_samples', 0) or 0)}"
    )
    print(
        "Render-loop suspended samples: "
        f"{int(stationary_hold.get('terrain_runtime_power_render_loop_suspended_samples', 0) or 0)}"
    )
    print(
        "Terrain suspend count: "
        f"{int(terrain.get('runtime_power_world_work_suspend_count', 0) or 0)}"
    )
    print(
        "Terrain suspended now: "
        f"{bool(terrain.get('runtime_power_world_work_suspended', False))}"
    )
    print(
        "Render loop suspended now: "
        f"{bool(terrain.get('runtime_power_render_loop_suspended', False))}"
    )
    print(
        "Queues: "
        f"gpu={int(terrain.get('task_queue_count', 0) or 0)} "
        f"cpu={int(terrain.get('cpu_task_queue_count', 0) or 0)} "
        f"completed={int(terrain.get('completed_generation_queue_count', 0) or 0)} "
        f"pending_nodes={int(terrain.get('pending_node_count', 0) or 0)}"
    )
    print("=" * 50)


def main() -> int:
    run_start_mtime = time.time()
    _set_default_env()
    result = run_town_stall_test.main()
    if result != 0:
        return result

    snapshot_path = run_town_stall_test._latest_snapshot(run_start_mtime - 1.0)
    if not snapshot_path:
        print("ERROR: No snapshot found after idle power run.")
        return 1

    snapshot = _read_json(snapshot_path)
    _print_idle_summary(snapshot_path, snapshot)

    failures = _validate_snapshot(snapshot)
    if failures:
        print("\nIDLE POWER REGRESSION FAILED")
        for failure in failures:
            print(f"- {failure}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
