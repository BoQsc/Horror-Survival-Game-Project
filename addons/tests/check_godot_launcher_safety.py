from pathlib import Path


PROJECT_PATH = Path(__file__).resolve().parents[2]

DIRECT_GODOT_LAUNCHERS = {
    Path("launch_editor.py"): {"requires_cwd": True},
    Path("quick_check_project_parse_errors.py"): {"requires_cwd": True},
    Path("addons/tests/run_movement_test.py"): {"requires_cwd": True},
    Path("addons/tests/run_procedural_power_test.py"): {"requires_cwd": True},
    Path("addons/tests/run_town_stall_test.py"): {"requires_cwd": True},
    Path("scripts/auto_fix.py"): {"requires_cwd": True},
    Path("scripts/prefab_builder.py"): {"requires_cwd": True},
}

SKIPPED_PARTS = {".agent", ".git", ".godot", "__pycache__", "trash_scripts"}
GODOT_MARKERS = (
    "godot.windows.opt.tools.64.exe",
    "GODOT_BIN",
    "town_runner.GODOT_BIN",
    "godot_exe",
)


def _is_skipped(path: Path) -> bool:
    return path.name == Path(__file__).name or any(part in SKIPPED_PARTS for part in path.parts)


def _read_text(relative_path: Path) -> str:
    return (PROJECT_PATH / relative_path).read_text(encoding="utf-8")


def _discover_direct_godot_launchers() -> set[Path]:
    launchers: set[Path] = set()
    for path in PROJECT_PATH.rglob("*.py"):
        relative_path = path.relative_to(PROJECT_PATH)
        if _is_skipped(relative_path):
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        if "subprocess." not in text:
            continue
        if any(marker in text for marker in GODOT_MARKERS):
            launchers.add(relative_path)
    return launchers


def _check_policy(relative_path: Path, policy: dict[str, bool]) -> list[str]:
    text = _read_text(relative_path)
    failures: list[str] = []
    if "--path" not in text:
        failures.append(f"{relative_path}: Godot command must pass --path")
    if "PROJECT_PATH" not in text:
        failures.append(f"{relative_path}: Godot command must use PROJECT_PATH")
    if "suppress_windows_error_dialogs" not in text:
        failures.append(f"{relative_path}: launcher must suppress Windows crash dialogs")
    if policy.get("requires_cwd", False) and "cwd=" not in text:
        failures.append(f"{relative_path}: headless launcher must set cwd=PROJECT_PATH")
    return failures


def main() -> int:
    failures: list[str] = []
    discovered = _discover_direct_godot_launchers()
    expected = set(DIRECT_GODOT_LAUNCHERS)

    missing = expected - discovered
    for relative_path in sorted(missing):
        failures.append(f"{relative_path}: expected direct Godot launcher was not discovered")

    unexpected = discovered - expected
    for relative_path in sorted(unexpected):
        failures.append(f"{relative_path}: direct Godot launcher is not covered by safety policy")

    for relative_path, policy in DIRECT_GODOT_LAUNCHERS.items():
        if not (PROJECT_PATH / relative_path).exists():
            failures.append(f"{relative_path}: expected launcher file is missing")
            continue
        failures.extend(_check_policy(relative_path, policy))

    if failures:
        print("Godot launcher safety check failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print(f"Godot launcher safety check passed for {len(DIRECT_GODOT_LAUNCHERS)} direct launchers.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
