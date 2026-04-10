import os
import subprocess
import sys
from pathlib import Path

GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
MAIN_SCENE = "res://addons/tests/transvoxel_layout_visual_smoke.tscn"
TIMEOUT = 300
LOG_FILE = Path(PROJECT_PATH) / ".agent" / "transvoxel-layout-visual-smoke.log"


def _safe_text(text: str) -> str:
    return text.encode("ascii", errors="replace").decode("ascii")


def main() -> int:
    print("Running Transvoxel Layout Visual Smoke Test...")
    print(f"   Scene: {MAIN_SCENE}")
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    if LOG_FILE.exists():
        try:
            LOG_FILE.unlink()
        except OSError:
            pass

    cmd = [
        GODOT_BIN,
        "--log-file",
        str(LOG_FILE),
        "--headless",
        "--path",
        PROJECT_PATH,
        MAIN_SCENE,
    ]

    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=TIMEOUT,
    )
    print(_safe_text(proc.stdout))
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
