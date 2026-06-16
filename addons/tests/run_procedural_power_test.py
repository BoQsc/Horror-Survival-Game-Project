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
PROCEDURAL_APPDATA_DIR = PROJECT_PATH / ".agent" / "procedural-power-appdata"
WINDOWS_ACCESS_VIOLATION = 3221225477
GODOT_RENDERING_DRIVER = "vulkan"
GODOT_RENDERING_METHOD = "forward_plus"


def _snapshot_root(env: dict[str, str]) -> Path:
    raw = (env.get("PROCEDURAL_POWER_SNAPSHOT_DIR", "") or "").strip()
    if raw and not raw.startswith("user://"):
        return Path(raw)
    return town_runner.SNAPSHOT_DIR


def _project_name() -> str:
    project_file = PROJECT_PATH / "project.godot"
    try:
        for line in project_file.read_text(encoding="utf-8").splitlines():
            if not line.startswith("config/name="):
                continue
            raw = line.split("=", 1)[1].strip()
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                parsed = raw.strip('"')
            if isinstance(parsed, str) and parsed.strip():
                return parsed.strip()
    except OSError:
        pass
    return PROJECT_PATH.name


def _configure_isolated_user_data(env: dict[str, str]) -> str:
    if not _env_bool(env, "PROCEDURAL_POWER_ISOLATE_USER_DATA", True):
        return ""

    raw_root = (env.get("PROCEDURAL_POWER_APPDATA_DIR", "") or "").strip()
    appdata_root = Path(raw_root) if raw_root else PROCEDURAL_APPDATA_DIR
    project_user_root = appdata_root / "Godot" / "app_userdata" / _project_name()
    (project_user_root / "shader_cache").mkdir(parents=True, exist_ok=True)
    env["APPDATA"] = str(appdata_root)
    return str(appdata_root)


def _shader_cache_failures(output: str, env: dict[str, str]) -> list[str]:
    if not _env_bool(env, "PROCEDURAL_POWER_FAIL_ON_SHADER_CACHE_ERROR", True):
        return []

    failures: list[str] = []
    markers = (
        "unable to create shader cache",
        "can't create shader cache",
        "cant create shader cache",
        "no shader caching will happen",
        "failed to write pipeline cache",
    )
    for line in output.splitlines():
        lowered = line.lower()
        if "shader cache" not in lowered and "pipeline cache" not in lowered:
            continue
        if any(marker in lowered for marker in markers):
            failures.append(line.strip())
    return failures


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
    render_features = snapshot.get("render_features", {}) if isinstance(snapshot, dict) else {}
    visual_capture = snapshot.get("visual_capture", {}) if isinstance(snapshot, dict) else {}
    if not isinstance(render_features, dict) and isinstance(final_sample, dict):
        render_features = final_sample.get("render_features", {})
    if not isinstance(render_features, dict):
        render_features = {}
    if not isinstance(visual_capture, dict):
        visual_capture = {}
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
    print(
        "Render features: "
        f"renderer={render_features.get('rendering_method', '')} "
        f"glow_off={render_features.get('disable_glow', False)} "
        f"glow_envs={render_features.get('glow_environment_count', 0)} "
        f"scale_requested={render_features.get('scaling_3d_scale_requested', -1.0)} "
        f"scale_actual={render_features.get('scaling_3d_scale_actual', 0.0)} "
        f"scale_applied={render_features.get('scaling_3d_scale_applied', False)}"
    )
    if visual_capture:
        print(
            "Visual capture: "
            f"saved={visual_capture.get('saved', False)} "
            f"size={visual_capture.get('width', 0)}x{visual_capture.get('height', 0)} "
            f"path={visual_capture.get('path', '')}"
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
        f"reason={terrain.get('runtime_power_active_reason')} "
        f"viewport_scale={terrain.get('runtime_power_viewport_scale_current')}"
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
    render_features = snapshot.get("render_features", {})
    visual_capture = snapshot.get("visual_capture", {})
    if not isinstance(render_features, dict):
        render_features = final_sample.get("render_features", {})
    if not isinstance(terrain, dict):
        terrain = {}
    if not isinstance(building, dict):
        building = {}
    if not isinstance(render_features, dict):
        render_features = {}
    if not isinstance(visual_capture, dict):
        visual_capture = {}

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

    if _env_bool(env, "PROCEDURAL_POWER_DISABLE_GLOW", _env_bool(env, "TOWN_STALL_DISABLE_GLOW", False)):
        if not bool(render_features.get("disable_glow", False)):
            failures.append("procedural render feature snapshot did not record glow disabled")
        if int(render_features.get("glow_environment_count", 0) or 0) <= 0:
            failures.append("procedural glow disable requested but no WorldEnvironment was updated")

    raw_scale = (env.get("PROCEDURAL_POWER_SCALING_3D_SCALE", "") or "").strip()
    if raw_scale:
        if not bool(render_features.get("scaling_3d_scale_applied", False)):
            failures.append("procedural 3D scaling override was requested but not applied")

    if _env_bool(env, "PROCEDURAL_POWER_REQUIRE_FORWARD_PLUS", True):
        rendering_method = str(render_features.get("rendering_method", "") or "")
        if rendering_method != "forward_plus":
            failures.append(f"procedural power run expected Forward+ renderer, got '{rendering_method or 'unknown'}'")

    if _env_bool(env, "TOWN_STALL_RUNTIME_POWER_VIEWPORT_SCALING", False):
        if not bool(terrain.get("runtime_power_viewport_scaling_enabled", False)):
            failures.append("runtime power viewport scaling was requested but not enabled")
        if not bool(terrain.get("runtime_power_viewport_scale_supported", False)):
            failures.append("runtime power viewport scaling was requested but unsupported")
        mode = str(terrain.get("runtime_power_mode", "active"))
        expected_env = {
            "deep_idle": "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_3D_SCALE",
            "idle": "TOWN_STALL_RUNTIME_POWER_IDLE_3D_SCALE",
        }.get(mode, "TOWN_STALL_RUNTIME_POWER_ACTIVE_3D_SCALE")
        expected_scale = _env_float(env, expected_env, 1.0)
        actual_scale = float(terrain.get("runtime_power_viewport_scale_current", 0.0) or 0.0)
        if abs(actual_scale - expected_scale) > 0.02:
            failures.append(f"runtime power viewport scale mismatch in {mode}: {actual_scale:.3f} != {expected_scale:.3f}")

    raw_screenshot_dir = (env.get("PROCEDURAL_POWER_SCREENSHOT_DIR", "") or "").strip()
    if raw_screenshot_dir:
        if not bool(visual_capture.get("saved", False)):
            failures.append(f"procedural screenshot capture requested but not saved ({visual_capture.get('error', 'unknown_error')})")
        else:
            screenshot_path = Path(str(visual_capture.get("path", "")))
            if not screenshot_path.exists():
                failures.append(f"procedural screenshot path was recorded but does not exist: {screenshot_path}")

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
    isolated_user_data = _configure_isolated_user_data(env)
    rendering_method = (env.get("PROCEDURAL_POWER_RENDERING_METHOD", "") or "").strip()
    if rendering_method and rendering_method != "forward_plus":
        print("ERROR: PROCEDURAL_POWER_RENDERING_METHOD is restricted to forward_plus for this Forward+ project.")
        return 1
    rendering_method = rendering_method or GODOT_RENDERING_METHOD
    rendering_driver = (env.get("PROCEDURAL_POWER_RENDERING_DRIVER", "") or "").strip()
    if rendering_driver and rendering_driver != GODOT_RENDERING_DRIVER:
        print("ERROR: PROCEDURAL_POWER_RENDERING_DRIVER is restricted to vulkan for this Forward+ project.")
        return 1
    rendering_driver = rendering_driver or GODOT_RENDERING_DRIVER

    running_processes = town_runner._find_running_godot_processes()
    if running_processes:
        strict_launch_guards = _env_bool(env, "TOWN_STALL_STRICT_LAUNCH_GUARDS", False)
        if strict_launch_guards:
            print("ERROR: A Godot process is already running.")
            print("Close the existing Godot instance before starting a new procedural power test.")
        else:
            print("WARNING: A Godot process is already running; continuing because strict launch guards are disabled.")
            print("Set TOWN_STALL_STRICT_LAUNCH_GUARDS=1 to make this a fatal preflight error.")
        for process in running_processes[:5]:
            print(f"  PID {int(process.get('ProcessId', 0) or 0)} - {process.get('Name', 'godot')}")
        if strict_launch_guards:
            return 2

    sample_interval_s = float(env.get("TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS", "2") or "2")
    gpu_samples: list[dict[str, Any]] = []
    stop_event = threading.Event()
    sampler = threading.Thread(target=_sample_gpu, args=(stop_event, gpu_samples, sample_interval_s), daemon=True)
    sampler.start()

    PROCEDURAL_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        town_runner.GODOT_BIN,
        "--rendering-driver",
        rendering_driver,
        "--rendering-method",
        rendering_method,
        "--log-file",
        str(PROCEDURAL_LOG_FILE),
    ]
    cmd.extend([
        "--path",
        str(PROJECT_PATH),
        SCENE,
    ])
    print("Running procedural power test...")
    print(f"   Scene: {SCENE}")
    if isolated_user_data:
        print(f"   Godot APPDATA: {isolated_user_data}")
    print(f"   Rendering: {rendering_method} / {rendering_driver}")
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

    shader_cache_failures = _shader_cache_failures(output, env)
    if shader_cache_failures:
        print("ERROR: procedural power run reported shader cache failures:")
        for failure in shader_cache_failures:
            print(f"  - {failure}")
        return 1

    validation_failures = _validate_runtime_power(snapshot, env)
    if validation_failures:
        print("ERROR: procedural power validation failed:")
        for failure in validation_failures:
            print(f"  - {failure}")
        return 1

    completed = bool(snapshot.get("completed", False))
    if result.returncode == WINDOWS_ACCESS_VIOLATION and completed:
        if _env_bool(env, "PROCEDURAL_POWER_ALLOW_SHUTDOWN_ACCESS_VIOLATION", False):
            print("WARNING: Godot exited with an access violation during shutdown after completing the procedural power test; allowed by PROCEDURAL_POWER_ALLOW_SHUTDOWN_ACCESS_VIOLATION=1.")
            return 0
        print("ERROR: Godot exited with an access violation during shutdown after completing the procedural power test.")
        print("Set PROCEDURAL_POWER_ALLOW_SHUTDOWN_ACCESS_VIOLATION=1 only for one-off diagnostics that intentionally tolerate native shutdown crashes.")
        return 1
    if result.returncode != 0:
        print(f"ERROR: Godot exited with code {result.returncode}")
        return result.returncode
    if not snapshot_path or not completed:
        print("ERROR: procedural power snapshot missing or incomplete")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
