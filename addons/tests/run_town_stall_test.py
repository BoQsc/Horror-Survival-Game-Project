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
    print(f"Town avg total ms: {town_window.get('avg_total_ms', '?')}")
    print(f"Town avg physics ms: {town_window.get('avg_physics_ms', '?')}")
    print(f"Town avg draw calls: {town_window.get('avg_draw_calls', '?')}")
    print(f"Town avg objects: {town_window.get('avg_objects', '?')}")
    print(f"Recent window stable bucket: {recent_window.get('stable_top_bucket', 'Unknown')} ({recent_window.get('stable_top_bucket_count', 0)})")
    print("=" * 50)


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
    env["TOWN_STALL_SEED"] = "12345"
    env["TOWN_STALL_AUTO_TELEPORT"] = "0"

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
            encoding="utf-8",
            errors="replace",
            env=env,
        )
        output = result.stdout + "\n" + result.stderr
    except subprocess.TimeoutExpired as exc:
        print(f"WARNING: Timeout after {TIMEOUT}s (bot may still be running)")
        output = (exc.stdout if exc.stdout else "") + "\n" + (exc.stderr if exc.stderr else "")
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 1

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

    snapshot = _latest_snapshot(run_start_mtime - 1.0)
    if snapshot:
        _print_snapshot_summary(snapshot)
    else:
        print("No performance snapshot found.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
