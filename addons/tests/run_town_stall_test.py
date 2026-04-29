import json
import os
import subprocess
import sys
import time
import atexit
import msvcrt
from pathlib import Path
from typing import Optional

# Configuration
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
MAIN_SCENE = "res://addons/tests/town_stall_test_harness.tscn"
DEFAULT_TIMEOUT = 900
SNAPSHOT_DIR = Path(r"C:\Users\Windows10_new\AppData\Roaming\Godot\app_userdata\Horror Survival Game Project\debug\performance")
LOG_DIR = SNAPSHOT_DIR.parent.parent / "logs"
LOG_FILE = Path(PROJECT_PATH) / ".agent" / "town-stall-godot.log"
RUN_LOCK_FILE = Path(PROJECT_PATH) / ".agent" / "town-stall-test.lock"
_RUN_LOCK_HANDLE = None


def _safe_text(text: str) -> str:
    return text.encode("ascii", errors="replace").decode("ascii")


def _latest_snapshot(since_mtime: float = 0.0) -> Optional[Path]:
    if not SNAPSHOT_DIR.exists():
        return None

    candidates = [path for path in SNAPSHOT_DIR.glob("snapshot_*.json") if path.stat().st_mtime >= since_mtime]
    if not candidates:
        return None

    return max(candidates, key=lambda path: path.stat().st_mtime)


def _positive_float_from_env(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default

    try:
        value = float(raw)
    except ValueError:
        return default

    return value if value > 0.0 else default


def _positive_int_from_env(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default

    try:
        value = int(raw)
    except ValueError:
        return default

    return value if value > 0 else default


def _run_powershell_json(command: str, timeout_seconds: int = 20) -> Optional[dict]:
    try:
        result = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                command,
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout_seconds,
        )
    except Exception:
        return None

    if result.returncode != 0:
        return None

    payload = (result.stdout or "").strip()
    if not payload:
        return None

    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError:
        return None

    return parsed if isinstance(parsed, dict) else None


def _release_run_lock() -> None:
    global _RUN_LOCK_HANDLE
    if _RUN_LOCK_HANDLE is None:
        return

    try:
        _RUN_LOCK_HANDLE.seek(0)
        msvcrt.locking(_RUN_LOCK_HANDLE.fileno(), msvcrt.LK_UNLCK, 1)
    except OSError:
        pass

    try:
        _RUN_LOCK_HANDLE.close()
    except OSError:
        pass

    _RUN_LOCK_HANDLE = None


def _acquire_run_lock() -> bool:
    global _RUN_LOCK_HANDLE
    RUN_LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)

    handle = open(RUN_LOCK_FILE, "a+b")
    try:
        handle.seek(0)
        handle.write(b"0")
        handle.flush()
        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        try:
            handle.close()
        except OSError:
            pass
        return False

    _RUN_LOCK_HANDLE = handle
    atexit.register(_release_run_lock)
    return True


def _find_running_town_stall_processes() -> list[dict]:
    command = r"""
$projectPath = "C:\Users\Windows10_new\Documents\gpu-marching-cubes"
$sceneName = "town_stall_test_harness.tscn"
Get-CimInstance Win32_Process | Where-Object {
  $_.Name -ieq "godot.windows.opt.tools.64.exe" -and
  $_.CommandLine -and
  $_.CommandLine -like ("*" + $sceneName + "*") -and
  $_.CommandLine -like ("*" + $projectPath + "*")
} | Select-Object ProcessId, Name, CommandLine | ConvertTo-Json -Compress -Depth 3
""".strip()

    payload = _run_powershell_json(command)
    if not payload:
        return []

    if isinstance(payload, dict):
        return [payload]
    if isinstance(payload, list):
        return [entry for entry in payload if isinstance(entry, dict)]
    return []


def _collect_machine_state() -> dict:
    command = r"""
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 Name,CurrentClockSpeed,MaxClockSpeed,LoadPercentage
$perf = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" | Select-Object -First 1 Name,PercentProcessorPerformance,PercentofMaximumFrequency,PercentProcessorUtility,ProcessorFrequency
$thermal = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue | Select-Object -First 1 InstanceName,CurrentTemperature
[ordered]@{
  cpu = $cpu
  perf = $perf
  thermal = $thermal
} | ConvertTo-Json -Compress -Depth 4
""".strip()

    payload = _run_powershell_json(command)
    if not payload:
        return {
            "available": False,
            "warmup_state": "unknown",
            "warmup_note": "Machine state probe unavailable.",
            "thermal_state": "unavailable",
        }

    cpu = payload.get("cpu", {}) if isinstance(payload.get("cpu", {}), dict) else {}
    perf = payload.get("perf", {}) if isinstance(payload.get("perf", {}), dict) else {}
    thermal = payload.get("thermal", {}) if isinstance(payload.get("thermal", {}), dict) else {}

    cpu_name = str(cpu.get("Name", "Unknown"))
    current_clock_mhz = int(cpu.get("CurrentClockSpeed", 0) or 0)
    max_clock_mhz = int(cpu.get("MaxClockSpeed", 0) or 0)
    load_percentage = int(cpu.get("LoadPercentage", 0) or 0)

    percent_processor_performance = int(perf.get("PercentProcessorPerformance", 0) or 0)
    percent_max_frequency = int(perf.get("PercentofMaximumFrequency", 0) or 0)
    percent_processor_utility = int(perf.get("PercentProcessorUtility", 0) or 0)
    processor_frequency_mhz = int(perf.get("ProcessorFrequency", 0) or 0)

    estimated_effective_clock_mhz = 0
    if processor_frequency_mhz > 0 and percent_processor_performance > 0:
        estimated_effective_clock_mhz = int(round(processor_frequency_mhz * (percent_processor_performance / 100.0)))
    elif current_clock_mhz > 0:
        estimated_effective_clock_mhz = current_clock_mhz

    thermal_c = None
    thermal_state = "unavailable"
    current_temperature = thermal.get("CurrentTemperature", None)
    if isinstance(current_temperature, (int, float)) and current_temperature > 0:
        thermal_c = round(float(current_temperature) / 10.0 - 273.15, 1)
        thermal_state = "available"

    if percent_processor_performance >= 120:
        warmup_state = "boosted"
        warmup_note = f"CPU is boosted at {percent_processor_performance}% of nominal (~{estimated_effective_clock_mhz} MHz effective)."
    elif percent_processor_performance >= 105:
        warmup_state = "warm"
        warmup_note = f"CPU is warm at {percent_processor_performance}% of nominal (~{estimated_effective_clock_mhz} MHz effective)."
    elif load_percentage >= 70:
        warmup_state = "loaded"
        warmup_note = f"CPU is under load ({load_percentage}% load) and may still climb into boost."
    else:
        warmup_state = "baseline"
        warmup_note = f"CPU appears near baseline at {percent_processor_performance}% of nominal."

    machine_state = {
        "available": True,
        "cpu_name": cpu_name,
        "current_clock_mhz": current_clock_mhz,
        "max_clock_mhz": max_clock_mhz,
        "load_percentage": load_percentage,
        "processor_frequency_mhz": processor_frequency_mhz,
        "percent_processor_performance": percent_processor_performance,
        "percent_max_frequency": percent_max_frequency,
        "percent_processor_utility": percent_processor_utility,
        "estimated_effective_clock_mhz": estimated_effective_clock_mhz,
        "thermal_state": thermal_state,
        "thermal_c": thermal_c,
        "warmup_state": warmup_state,
        "warmup_note": warmup_note,
    }
    return machine_state


def _machine_state_brief_summary(machine_state: dict) -> str:
    if not machine_state:
        return "unavailable"

    cpu_name = str(machine_state.get("cpu_name", "Unknown"))
    current_clock_mhz = int(machine_state.get("current_clock_mhz", 0))
    percent_processor_performance = int(machine_state.get("percent_processor_performance", 0))
    load_percentage = int(machine_state.get("load_percentage", 0))
    warmup_state = str(machine_state.get("warmup_state", "unknown"))
    return (
        f"{cpu_name} current={current_clock_mhz} MHz "
        f"perf={percent_processor_performance}% load={load_percentage}% "
        f"state={warmup_state}"
    )


def _machine_state_is_baseline(
    machine_state: dict,
    max_percent_processor_performance: int,
    max_load_percentage: int,
) -> bool:
    if not machine_state:
        return False

    percent_processor_performance = int(machine_state.get("percent_processor_performance", 0) or 0)
    load_percentage = int(machine_state.get("load_percentage", 0) or 0)
    current_clock_mhz = int(machine_state.get("current_clock_mhz", 0) or 0)
    max_clock_mhz = int(machine_state.get("max_clock_mhz", 0) or 0)

    if percent_processor_performance > max_percent_processor_performance:
        return False
    if load_percentage > max_load_percentage:
        return False
    if max_clock_mhz > 0 and current_clock_mhz >= max_clock_mhz:
        return False

    return True


def _wait_for_machine_baseline(
    required_consecutive_samples: int,
    sample_interval_seconds: float,
    max_wait_seconds: float,
    max_percent_processor_performance: int,
    max_load_percentage: int,
) -> dict:
    start_time = time.time()
    consecutive_ready = 0
    sample_count = 0
    last_state: dict = {}

    print(
        "Machine warmup gate: waiting for "
        f"{required_consecutive_samples} consecutive samples with "
        f"performance <= {max_percent_processor_performance}%, "
        f"load <= {max_load_percentage}%, and current clock below max"
    )

    while True:
        last_state = _collect_machine_state()
        sample_count += 1

        if _machine_state_is_baseline(last_state, max_percent_processor_performance, max_load_percentage):
            consecutive_ready += 1
            print(
                f"  warmup sample {sample_count}: ready "
                f"({consecutive_ready}/{required_consecutive_samples}) - "
                f"{_machine_state_brief_summary(last_state)}"
            )
            if consecutive_ready >= required_consecutive_samples:
                elapsed = time.time() - start_time
                warmup_gate = {
                    "status": "settled",
                    "settled": True,
                    "samples": sample_count,
                    "required_consecutive_samples": required_consecutive_samples,
                    "wait_seconds": round(elapsed, 1),
                    "sample_interval_seconds": sample_interval_seconds,
                    "max_wait_seconds": max_wait_seconds,
                    "max_percent_processor_performance": max_percent_processor_performance,
                    "max_load_percentage": max_load_percentage,
                    "require_current_clock_below_max": True,
                }
                last_state["warmup_gate"] = warmup_gate
                last_state["warmup_state"] = "settled"
                last_state["warmup_note"] = (
                    f"Machine held at baseline for {required_consecutive_samples} consecutive samples "
                    f"before benchmark start ({round(elapsed, 1)}s, {sample_count} samples)."
                )
                return last_state
        else:
            consecutive_ready = 0
            print(
                f"  warmup sample {sample_count}: not ready - "
                f"{_machine_state_brief_summary(last_state)}"
            )

        elapsed = time.time() - start_time
        if elapsed >= max_wait_seconds:
            warmup_gate = {
                "status": "timeout",
                "settled": False,
                "samples": sample_count,
                "required_consecutive_samples": required_consecutive_samples,
                "wait_seconds": round(elapsed, 1),
                "sample_interval_seconds": sample_interval_seconds,
                "max_wait_seconds": max_wait_seconds,
                "max_percent_processor_performance": max_percent_processor_performance,
                "max_load_percentage": max_load_percentage,
                "require_current_clock_below_max": True,
            }
            last_state["warmup_gate"] = warmup_gate
            last_state["warmup_state"] = "timeout"
            last_state["warmup_note"] = (
                f"Machine warmup gate timed out after {round(elapsed, 1)}s and {sample_count} samples; "
                "continuing with the last observed state."
            )
            print(last_state["warmup_note"])
            return last_state

        sleep_seconds = min(sample_interval_seconds, max_wait_seconds - elapsed)
        if sleep_seconds > 0:
            time.sleep(sleep_seconds)


def _print_machine_state_summary(machine_state: dict) -> None:
    if not machine_state:
        print("Machine state: unavailable")
        return

    cpu_name = machine_state.get("cpu_name", "Unknown")
    current_clock_mhz = int(machine_state.get("current_clock_mhz", 0))
    max_clock_mhz = int(machine_state.get("max_clock_mhz", 0))
    processor_frequency_mhz = int(machine_state.get("processor_frequency_mhz", 0))
    percent_processor_performance = int(machine_state.get("percent_processor_performance", 0))
    percent_max_frequency = int(machine_state.get("percent_max_frequency", 0))
    percent_processor_utility = int(machine_state.get("percent_processor_utility", 0))
    estimated_effective_clock_mhz = int(machine_state.get("estimated_effective_clock_mhz", 0))
    load_percentage = int(machine_state.get("load_percentage", 0))
    thermal_state = str(machine_state.get("thermal_state", "unavailable"))
    thermal_c = machine_state.get("thermal_c", None)
    warmup_state = str(machine_state.get("warmup_state", "unknown"))
    warmup_note = str(machine_state.get("warmup_note", ""))
    warmup_gate = machine_state.get("warmup_gate", {})
    warmup_gate_note = ""
    if isinstance(warmup_gate, dict) and warmup_gate:
        warmup_gate_note = " | gate=%s samples=%d wait=%.1fs" % (
            str(warmup_gate.get("status", "unknown")),
            int(warmup_gate.get("samples", 0)),
            float(warmup_gate.get("wait_seconds", 0.0)),
        )

    print("Machine state:")
    print(f"  CPU: {cpu_name}")
    print(
        f"  Clock: current {current_clock_mhz} MHz | max {max_clock_mhz} MHz | "
        f"processor freq {processor_frequency_mhz} MHz"
    )
    print(
        f"  Perf: {percent_processor_performance}% of nominal | "
        f"{percent_max_frequency}% max frequency | utility {percent_processor_utility}% | "
        f"~{estimated_effective_clock_mhz} MHz effective"
    )
    print(f"  Load: {load_percentage}%")
    if thermal_c is None:
        print(f"  Thermal: {thermal_state}")
    else:
        print(f"  Thermal: {thermal_state} ({thermal_c} C)")
    print(f"  Warmup: {warmup_state} - {warmup_note}{warmup_gate_note}")


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
    machine_state = data.get("machine_state", {})
    if isinstance(machine_state, dict) and machine_state:
        _print_machine_state_summary(machine_state)
        warmup_note = str(data.get("warmup_note", machine_state.get("warmup_note", "")))
        if warmup_note:
            print(f"Warmup note: {warmup_note}")
    system_pressure_ranking = data.get("system_pressure_ranking", [])
    if system_pressure_ranking:
        print("System pressure ranking:")
        for index, entry in enumerate(system_pressure_ranking[:5], start=1):
            print(
                f"  {index}. {entry.get('name', 'Unknown')} "
                f"score={float(entry.get('pressure_score', 0.0)):.1f} "
                f"{entry.get('summary', '')}"
            )
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
    if not _acquire_run_lock():
        print("ERROR: Another town stall benchmark launcher is already running.")
        print("Close the existing launcher before starting a new one.")
        return 2

    print("Running Town Stall Automation Test...")
    print(f"   Scene: {MAIN_SCENE}")
    print("-" * 50)
    run_start_mtime = time.time()
    SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    if LOG_FILE.exists():
        try:
            LOG_FILE.unlink()
        except OSError:
            pass
    legacy_log_path = LOG_DIR / "godot.log"
    if legacy_log_path.exists():
        try:
            legacy_log_path.unlink()
        except OSError:
            pass

    cmd = [
        GODOT_BIN,
        "--log-file",
        str(LOG_FILE),
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
    env["TOWN_STALL_DISABLE_ENTITIES"] = os.environ.get("TOWN_STALL_DISABLE_ENTITIES", "0")
    env["TOWN_STALL_DISABLE_EXIT_AUTOSAVE"] = os.environ.get("TOWN_STALL_DISABLE_EXIT_AUTOSAVE", "1")
    env["TOWN_STALL_HOLD_SECONDS"] = os.environ.get("TOWN_STALL_HOLD_SECONDS", "")
    machine_warmup_disabled = os.environ.get("TOWN_STALL_MACHINE_WARMUP_DISABLED", "0") == "1"
    machine_warmup_required_consecutive_samples = _positive_int_from_env("TOWN_STALL_MACHINE_WARMUP_REQUIRED_CONSECUTIVE_SAMPLES", 3)
    machine_warmup_sample_interval_seconds = _positive_float_from_env("TOWN_STALL_MACHINE_WARMUP_SAMPLE_INTERVAL_SECONDS", 15.0)
    machine_warmup_max_wait_seconds = _positive_float_from_env("TOWN_STALL_MACHINE_WARMUP_MAX_WAIT_SECONDS", 180.0)
    machine_warmup_max_percent_processor_performance = _positive_int_from_env("TOWN_STALL_MACHINE_WARMUP_MAX_PERCENT_PROCESSOR_PERFORMANCE", 100)
    machine_warmup_max_load_percentage = _positive_int_from_env("TOWN_STALL_MACHINE_WARMUP_MAX_LOAD_PERCENT", 80)

    if machine_warmup_disabled:
        machine_state = _collect_machine_state()
        machine_state["warmup_state"] = "disabled"
        machine_state["warmup_note"] = "Machine warmup gate disabled via env."
    else:
        machine_state = _wait_for_machine_baseline(
            machine_warmup_required_consecutive_samples,
            machine_warmup_sample_interval_seconds,
            machine_warmup_max_wait_seconds,
            machine_warmup_max_percent_processor_performance,
            machine_warmup_max_load_percentage,
        )

    env["TOWN_STALL_MACHINE_STATE_JSON"] = json.dumps(machine_state)

    configured_hold_seconds = _positive_float_from_env("TOWN_STALL_HOLD_SECONDS", 40.0)
    timeout = max(DEFAULT_TIMEOUT, int(configured_hold_seconds + 900.0))

    print("\nMachine state probe:")
    _print_machine_state_summary(machine_state)

    running_processes = _find_running_town_stall_processes()
    if running_processes:
        print("ERROR: Another town stall game instance is already running.")
        print("Close the existing instance before starting a new town test.")
        for process in running_processes[:5]:
            process_id = int(process.get("ProcessId", 0) or 0)
            process_name = str(process.get("Name", "godot"))
            print(f"  PID {process_id} - {process_name}")
            command_line = str(process.get("CommandLine", "")).strip()
            if command_line:
                print(f"    {command_line}")
        return 2

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
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            print(f"WARNING: Timeout after {timeout}s (bot may still be running)")
            proc.kill()
            stdout, stderr = proc.communicate()
            returncode = proc.returncode
        output = (stdout or "") + "\n" + (stderr or "")
    except subprocess.TimeoutExpired as exc:
        print(f"WARNING: Timeout after {timeout}s (bot may still be running)")
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
    hold_started = "[town_stall_test] hold started" in output.lower()
    hold_completed = "[town_stall_test] hold complete, quitting" in output.lower()
    shutdown_av = returncode == 3221225477
    if shutdown_av and snapshot and hold_started and hold_completed:
        print("WARNING: Godot exited with an access violation during shutdown after completing the benchmark; treating this as non-fatal because the hold finished and a snapshot was written.")
        failure_reasons = [reason for reason in failure_reasons if reason != f"process exited with code {returncode}"]
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
