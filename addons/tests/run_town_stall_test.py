import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# Configuration
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
MAIN_SCENE = "res://addons/tests/town_stall_test_harness.tscn"
TIMEOUT = 900
SNAPSHOT_DIR = Path(r"C:\Users\Windows10_new\AppData\Roaming\Godot\app_userdata\Horror Survival Game Project\debug\performance")


def _safe_text(text: str) -> str:
    return text.encode("ascii", errors="replace").decode("ascii")


def _latest_snapshot(since_mtime: float = 0.0) -> Optional[Path]:
    if not SNAPSHOT_DIR.exists():
        return None

    candidates = [path for path in SNAPSHOT_DIR.glob("snapshot_*.json") if path.stat().st_mtime >= since_mtime]
    if not candidates:
        return None

    return max(candidates, key=lambda path: path.stat().st_mtime)


def _print_snapshot_summary(snapshot_path: Path) -> None:
    try:
        data = json.loads(snapshot_path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"WARNING: Could not parse snapshot {snapshot_path}: {exc}")
        return

    town_window = data.get("town_entry_window", {})
    recent_window = data.get("recent_spike_window", {})

    print("\n" + "=" * 50)
    print("LATEST TOWN STALL SNAPSHOT")
    print("=" * 50)
    print(f"File: {snapshot_path}")
    print(f"Stable bucket: {data.get('stable_top_bucket', 'Unknown')} ({data.get('stable_top_bucket_count', 0)})")
    print(f"Town window: frames {town_window.get('start_frame', '?')}-{town_window.get('end_frame', '?')}")
    print(f"Town samples: {town_window.get('sample_count', '?')}")
    print(f"Town peak ms: {town_window.get('max_total_ms', '?')} @ frame {town_window.get('max_total_frame', '?')}")
    print(f"Town peak top bucket: {town_window.get('peak_top_bucket', 'Unknown')} ({town_window.get('peak_top_measure_name', 'Unknown')})")
    print(f"Town avg total ms: {town_window.get('avg_total_ms', '?')}")
    print(f"Town avg physics ms: {town_window.get('avg_physics_ms', '?')}")
    print(f"Town avg draw calls: {town_window.get('avg_draw_calls', '?')}")
    print(f"Town avg objects: {town_window.get('avg_objects', '?')}")
    print(f"Town frames over budget: {town_window.get('frames_over_budget', '?')}")
    print(f"Town frames over 40ms: {town_window.get('frames_over_40ms', '?')}")
    print(f"Town frames over 50ms: {town_window.get('frames_over_50ms', '?')}")
    print(f"Town stall over budget ms: {town_window.get('stall_over_budget_ms', '?')}")
    print(f"Town longest over-budget streak: {town_window.get('longest_over_budget_streak', '?')}")
    print(f"Recent window stable bucket: {recent_window.get('stable_top_bucket', 'Unknown')} ({recent_window.get('stable_top_bucket_count', 0)})")
    print("=" * 50)


def _detect_run_failure(output: str, returncode: Optional[int]) -> list[str]:
    reasons: list[str] = []
    lowered = output.lower()
    crash_markers = [
        "crashhandlerexception",
        "signal 11",
        "fatal error",
        "parse error",
        "script error:",
        "failed to load script",
        "stack overflow",
    ]
    for marker in crash_markers:
        if marker in lowered:
            reasons.append(f"matched crash marker: {marker}")
    if "[town_stall_test] hold started" not in lowered:
        reasons.append("town hold never started")
    if returncode is not None and returncode != 0:
        reasons.append(f"process exited with code {returncode}")
    return reasons


def main() -> int:
    print("Running Town Stall Automation Test...")
    print(f"   Scene: {MAIN_SCENE}")
    print("-" * 50)
    run_start_mtime = time.time()

    cmd = [
        GODOT_BIN,
        "--path",
        PROJECT_PATH,
        MAIN_SCENE,
    ]

    env = os.environ.copy()
    env["TOWN_STALL_SEED"] = os.environ.get("TOWN_STALL_SEED", "12345")
    env["TOWN_STALL_AUTO_TELEPORT"] = os.environ.get("TOWN_STALL_AUTO_TELEPORT", "0")
    env["TOWN_STALL_REPEAT_ENTRY"] = os.environ.get("TOWN_STALL_REPEAT_ENTRY", "0")
    env["TOWN_STALL_DISABLE_BUILDINGS"] = os.environ.get("TOWN_STALL_DISABLE_BUILDINGS", "0")
    env["TOWN_STALL_DISABLE_BUILDING_OBJECTS"] = os.environ.get("TOWN_STALL_DISABLE_BUILDING_OBJECTS", "0")
    env["TOWN_STALL_DISABLE_BUILDING_BLOCKS"] = os.environ.get("TOWN_STALL_DISABLE_BUILDING_BLOCKS", "0")
    env["TOWN_STALL_DISABLE_BUILDING_CHUNK_MESH_RENDER"] = os.environ.get("TOWN_STALL_DISABLE_BUILDING_CHUNK_MESH_RENDER", "0")
    env["TOWN_STALL_DISABLE_BUILDING_VISUAL_BATCHES"] = os.environ.get("TOWN_STALL_DISABLE_BUILDING_VISUAL_BATCHES", "0")
    env["TOWN_STALL_DISABLE_BUILDING_CARVE"] = os.environ.get("TOWN_STALL_DISABLE_BUILDING_CARVE", "0")
    env["TOWN_STALL_DISABLE_BUILDING_OBJECT_COLLISIONS"] = os.environ.get("TOWN_STALL_DISABLE_BUILDING_OBJECT_COLLISIONS", "0")
    env["TOWN_STALL_DISABLE_BUILDING_CHUNK_FLUSH"] = os.environ.get("TOWN_STALL_DISABLE_BUILDING_CHUNK_FLUSH", "0")
    env["TOWN_STALL_DISABLE_BUILDING_CHUNK_COLLISIONS"] = os.environ.get("TOWN_STALL_DISABLE_BUILDING_CHUNK_COLLISIONS", "0")
    env["TOWN_STALL_DISABLE_TERRAIN_CHUNK_UPDATES"] = os.environ.get("TOWN_STALL_DISABLE_TERRAIN_CHUNK_UPDATES", "0")
    env["TOWN_STALL_DISABLE_EXIT_AUTOSAVE"] = os.environ.get("TOWN_STALL_DISABLE_EXIT_AUTOSAVE", "1")

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
        )
        returncode = proc.returncode
        try:
            stdout, stderr = proc.communicate(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            print(f"WARNING: Timeout after {TIMEOUT}s (bot may still be running)")
            proc.kill()
            stdout, stderr = proc.communicate()
            returncode = proc.returncode
        output = (stdout or "") + "\n" + (stderr or "")
    except subprocess.TimeoutExpired as exc:
        print(f"WARNING: Timeout after {TIMEOUT}s (bot may still be running)")
        output = (exc.stdout if exc.stdout else "") + "\n" + (exc.stderr if exc.stderr else "")
        returncode = None
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 1
    else:
        returncode = proc.returncode

    print("\n" + "=" * 50)
    print("FULL OUTPUT:")
    print("=" * 50)
    print(_safe_text(output))
    print("=" * 50)

    print("\nTOWN STALL DEBUG:")
    print("=" * 50)
    found = False
    for line in output.splitlines():
        if "[TOWN_STALL_TEST]" in line:
            print(_safe_text(line))
            found = True

    if not found:
        print("(No town stall debug output found)")

    print("=" * 50)

    failure_reasons = _detect_run_failure(output, returncode)
    snapshot = _latest_snapshot(run_start_mtime - 1.0)
    if snapshot:
        _print_snapshot_summary(snapshot)
    else:
        print("No performance snapshot found.")
        failure_reasons.append("no performance snapshot found")

    if failure_reasons:
        print("\n" + "=" * 50)
        print("RUN FAILED")
        print("=" * 50)
        for reason in failure_reasons:
            print(f"- {reason}")
        print("=" * 50)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
