import json
import os
import subprocess
import sys
import time
import atexit
import msvcrt
import threading
from pathlib import Path
from typing import Any, Optional

from windows_error_dialogs import suppress_windows_error_dialogs

# Configuration
DEFAULT_GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
GODOT_BIN = os.environ.get("TOWN_STALL_GODOT_BIN", DEFAULT_GODOT_BIN)
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
MAIN_SCENE = "res://addons/tests/town_stall_test_harness.tscn"
GODOT_RENDERING_DRIVER = "vulkan"
GODOT_RENDERING_METHOD = "forward_plus"
FPS_60_FRAME_MS = 1000.0 / 60.0
TARGET_WPF60_BASELINE = 16.0
DEFAULT_TIMEOUT = 420
TOWN_STALL_APPDATA_DIR = Path(os.environ.get("TOWN_STALL_APPDATA_DIR", str(Path(PROJECT_PATH) / ".agent" / "town-stall-appdata")))
TOWN_STALL_PROJECT_USER_DIR = TOWN_STALL_APPDATA_DIR / "Godot" / "app_userdata" / "Horror Survival Game Project"
SNAPSHOT_DIR = TOWN_STALL_PROJECT_USER_DIR / "debug" / "performance"
LOG_DIR = SNAPSHOT_DIR.parent.parent / "logs"
LOG_FILE = Path(PROJECT_PATH) / ".agent" / "town-stall-godot.log"
RUN_LOCK_FILE = Path(PROJECT_PATH) / ".agent" / "town-stall-test.lock"
SYSTEM_SAMPLE_FILE = Path(PROJECT_PATH) / ".agent" / "town-stall-system-samples.jsonl"
SYSTEM_SAMPLE_SUMMARY_FILE = Path(PROJECT_PATH) / ".agent" / "town-stall-system-summary.json"
_RUN_LOCK_HANDLE = None
NVIDIA_SMI = os.environ.get("NVIDIA_SMI", "nvidia-smi")
RAW_GPU_QUERY_FIELDS = [
    "timestamp",
    "name",
    "pstate",
    "power.draw",
    "temperature.gpu",
    "clocks.gr",
    "clocks.mem",
    "utilization.gpu",
    "utilization.memory",
    "memory.used",
    "memory.total",
]
STARTUP_PROOF_STAGE_IDS = [
    "save_load",
    "terrain",
    "world_content",
    "vegetation",
    "complete",
]


def _runtime_mode_label() -> str:
    if os.environ.get("TOWN_STALL_EXPORTED_RUNTIME", "0") == "1":
        return "godot_exported_runtime"
    godot_name = Path(GODOT_BIN).name.lower()
    if ".tools." in godot_name or godot_name.endswith(".tools.exe"):
        return "godot_tools_debug_runner"
    return "godot_runtime_runner"


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


def _godot_display_args_from_env() -> list[str]:
    args: list[str] = []
    if os.environ.get("TOWN_STALL_GODOT_WINDOWED", "0") == "1":
        args.append("--windowed")

    resolution = os.environ.get("TOWN_STALL_GODOT_RESOLUTION", "").strip().lower()
    if resolution:
        parts = resolution.split("x", 1)
        if len(parts) == 2:
            try:
                width = int(parts[0])
                height = int(parts[1])
            except ValueError:
                width = 0
                height = 0
            if width > 0 and height > 0:
                args.extend(["--resolution", f"{width}x{height}"])

    return args


def _float_from_env(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default

    try:
        return float(raw)
    except ValueError:
        return default


def _optional_float_from_env(name: str) -> Optional[float]:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return None

    try:
        return float(raw)
    except ValueError:
        return None


def _bool_from_env(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "on"}


def _parse_optional_float(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip()
    if not text or text.upper() == "N/A":
        return None
    try:
        return float(text)
    except ValueError:
        return None


def _run_powershell_json(command: str, timeout_seconds: int = 20) -> Any:
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

    return parsed


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


def _find_running_godot_processes() -> list[dict]:
    command = r"""
Get-CimInstance Win32_Process | Where-Object {
  $_.Name -like "godot*.exe" -or $_.Name -like "Godot*.exe"
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


def _collect_top_cpu_processes(limit: int = 8) -> list[dict]:
    command = rf"""
Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
  Where-Object {{ $_.Name -ne "_Total" -and $_.Name -ne "Idle" }} |
  Sort-Object PercentProcessorTime -Descending |
  Select-Object -First {max(1, int(limit))} IDProcess,Name,PercentProcessorTime,WorkingSetPrivate |
  ConvertTo-Json -Compress -Depth 3
""".strip()

    payload = _run_powershell_json(command)
    if not payload:
        return []

    raw_entries: list[dict] = []
    if isinstance(payload, dict):
        raw_entries = [payload]
    elif isinstance(payload, list):
        raw_entries = [entry for entry in payload if isinstance(entry, dict)]

    entries: list[dict] = []
    for entry in raw_entries:
        entries.append({
            "pid": int(entry.get("IDProcess", 0) or 0),
            "name": str(entry.get("Name", "")),
            "cpu_percent": float(entry.get("PercentProcessorTime", 0.0) or 0.0),
            "working_set_private_mb": round(float(entry.get("WorkingSetPrivate", 0.0) or 0.0) / (1024.0 * 1024.0), 2),
        })
    return entries


def _print_top_cpu_processes(processes: list[dict]) -> None:
    if not processes:
        print("Top CPU processes: unavailable")
        return
    print("Top CPU processes:")
    for process in processes:
        print(
            "  PID {pid} {name}: cpu={cpu}% private_ws={memory} MB".format(
                pid=int(process.get("pid", 0) or 0),
                name=str(process.get("name", "")),
                cpu=round(float(process.get("cpu_percent", 0.0) or 0.0), 1),
                memory=round(float(process.get("working_set_private_mb", 0.0) or 0.0), 2),
            )
        )


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


def _collect_process_state(pid: int) -> dict:
    command = rf"""
$targetPid = {pid}
$process = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object {{ $_.IDProcess -eq $targetPid }} | Select-Object -First 1 IDProcess,Name,PercentProcessorTime,WorkingSetPrivate,WorkingSet,ThreadCount
$gpuEngines = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -like ("pid_" + $targetPid + "_*") }}
$gpuMemory = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -like ("pid_" + $targetPid + "_*") }} | Select-Object -First 1 Name,DedicatedUsage,LocalUsage,NonLocalUsage,SharedUsage,TotalCommitted
$gpuEngineTotal = 0.0
$gpuEngineMax = 0.0
$gpuEngineCount = 0
foreach ($engine in $gpuEngines) {{
  $value = [double]$engine.UtilizationPercentage
  $gpuEngineTotal += $value
  if ($value -gt $gpuEngineMax) {{ $gpuEngineMax = $value }}
  $gpuEngineCount += 1
}}
[ordered]@{{
  process = $process
  gpu = [ordered]@{{
    engine_count = $gpuEngineCount
    utilization_total_percent = $gpuEngineTotal
    utilization_max_engine_percent = $gpuEngineMax
    memory = $gpuMemory
  }}
}} | ConvertTo-Json -Compress -Depth 5
""".strip()

    payload = _run_powershell_json(command)
    if not isinstance(payload, dict):
        return {"available": False}

    process = payload.get("process", {})
    gpu = payload.get("gpu", {})
    if not isinstance(process, dict):
        process = {}
    if not isinstance(gpu, dict):
        gpu = {}

    memory = gpu.get("memory", {})
    if not isinstance(memory, dict):
        memory = {}

    return {
        "available": bool(process),
        "pid": pid,
        "name": str(process.get("Name", "")),
        "cpu_percent": float(process.get("PercentProcessorTime", 0.0) or 0.0),
        "working_set_private_mb": round(float(process.get("WorkingSetPrivate", 0.0) or 0.0) / (1024.0 * 1024.0), 2),
        "working_set_mb": round(float(process.get("WorkingSet", 0.0) or 0.0) / (1024.0 * 1024.0), 2),
        "thread_count": int(process.get("ThreadCount", 0) or 0),
        "gpu_engine_count": int(gpu.get("engine_count", 0) or 0),
        "gpu_utilization_total_percent": float(gpu.get("utilization_total_percent", 0.0) or 0.0),
        "gpu_utilization_max_engine_percent": float(gpu.get("utilization_max_engine_percent", 0.0) or 0.0),
        "gpu_dedicated_mb": round(float(memory.get("DedicatedUsage", 0.0) or 0.0) / (1024.0 * 1024.0), 2),
        "gpu_local_mb": round(float(memory.get("LocalUsage", 0.0) or 0.0) / (1024.0 * 1024.0), 2),
        "gpu_nonlocal_mb": round(float(memory.get("NonLocalUsage", 0.0) or 0.0) / (1024.0 * 1024.0), 2),
        "gpu_shared_mb": round(float(memory.get("SharedUsage", 0.0) or 0.0) / (1024.0 * 1024.0), 2),
        "gpu_committed_mb": round(float(memory.get("TotalCommitted", 0.0) or 0.0) / (1024.0 * 1024.0), 2),
    }


def _collect_raw_gpu_state() -> dict:
    query = ",".join(RAW_GPU_QUERY_FIELDS)
    try:
        result = subprocess.run(
            [
                NVIDIA_SMI,
                f"--query-gpu={query}",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=8,
        )
    except Exception as exc:
        return {
            "available": False,
            "error": repr(exc),
        }

    raw_output = (result.stdout or "").strip()
    first_line = raw_output.splitlines()[0].strip() if raw_output else ""
    if result.returncode != 0:
        return {
            "available": False,
            "returncode": result.returncode,
            "error": (result.stderr or "").strip(),
            "raw": first_line,
        }

    parts = [part.strip() for part in first_line.split(",")]
    if len(parts) < len(RAW_GPU_QUERY_FIELDS):
        return {
            "available": False,
            "returncode": result.returncode,
            "error": f"Expected {len(RAW_GPU_QUERY_FIELDS)} fields, got {len(parts)}",
            "raw": first_line,
        }

    return {
        "available": True,
        "returncode": result.returncode,
        "raw": first_line,
        "timestamp": parts[0],
        "name": parts[1],
        "pstate": parts[2],
        "power_w": _parse_optional_float(parts[3]),
        "temp_c": _parse_optional_float(parts[4]),
        "graphics_clock_mhz": _parse_optional_float(parts[5]),
        "memory_clock_mhz": _parse_optional_float(parts[6]),
        "gpu_util_percent": _parse_optional_float(parts[7]),
        "memory_util_percent": _parse_optional_float(parts[8]),
        "vram_used_mb": _parse_optional_float(parts[9]),
        "vram_total_mb": _parse_optional_float(parts[10]),
    }


def _raw_gpu_state_summary(raw_gpu: dict) -> str:
    if not bool(raw_gpu.get("available", False)):
        error = str(raw_gpu.get("error", "")).strip()
        return f"unavailable ({error})" if error else "unavailable"

    power_w = raw_gpu.get("power_w", None)
    temp_c = raw_gpu.get("temp_c", None)
    gpu_util = raw_gpu.get("gpu_util_percent", None)
    pstate = str(raw_gpu.get("pstate", "unknown")).strip() or "unknown"
    graphics_clock = raw_gpu.get("graphics_clock_mhz", None)
    memory_clock = raw_gpu.get("memory_clock_mhz", None)
    vram_used = raw_gpu.get("vram_used_mb", None)
    return (
        f"{power_w if power_w is not None else '?'} W | "
        f"{temp_c if temp_c is not None else '?'} C | "
        f"{pstate} | gpu={gpu_util if gpu_util is not None else '?'}% | "
        f"clocks={graphics_clock if graphics_clock is not None else '?'}/"
        f"{memory_clock if memory_clock is not None else '?'} MHz | "
        f"vram={vram_used if vram_used is not None else '?'} MB"
    )


def _preflight_contamination_reasons(machine_state: dict, raw_gpu: dict) -> list[str]:
    max_cpu_load = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_CPU_LOAD_PERCENT", 55.0)
    max_cpu_perf = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_CPU_PERF_PERCENT", 115.0)
    max_cpu_utility = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_CPU_UTILITY_PERCENT", 80.0)
    max_gpu_power = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_GPU_POWER_W", 15.0)
    max_gpu_util = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_GPU_UTIL_PERCENT", 30.0)
    max_gpu_temp = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_GPU_TEMP_C", 85.0)

    reasons: list[str] = []
    if isinstance(machine_state, dict) and machine_state.get("available", False):
        cpu_load = float(machine_state.get("load_percentage", 0.0) or 0.0)
        cpu_perf = float(machine_state.get("percent_processor_performance", 0.0) or 0.0)
        cpu_utility = float(machine_state.get("percent_processor_utility", 0.0) or 0.0)
        if cpu_load > max_cpu_load:
            reasons.append(f"CPU load {cpu_load:.1f}% > {max_cpu_load:.1f}%")
        if cpu_perf > max_cpu_perf:
            reasons.append(f"CPU processor performance {cpu_perf:.1f}% > {max_cpu_perf:.1f}%")
        if cpu_utility > max_cpu_utility:
            reasons.append(f"CPU processor utility {cpu_utility:.1f}% > {max_cpu_utility:.1f}%")

    if isinstance(raw_gpu, dict) and raw_gpu.get("available", False):
        power_w = raw_gpu.get("power_w", None)
        gpu_util = raw_gpu.get("gpu_util_percent", None)
        temp_c = raw_gpu.get("temp_c", None)
        if power_w is not None and float(power_w) > max_gpu_power:
            reasons.append(f"GPU power {float(power_w):.2f} W > {max_gpu_power:.2f} W")
        if gpu_util is not None and float(gpu_util) > max_gpu_util:
            reasons.append(f"GPU utilization {float(gpu_util):.1f}% > {max_gpu_util:.1f}%")
        if temp_c is not None and float(temp_c) > max_gpu_temp:
            reasons.append(f"GPU temperature {float(temp_c):.1f} C > {max_gpu_temp:.1f} C")

    return reasons


def _median(values: list[float]) -> Optional[float]:
    if not values:
        return None
    sorted_values = sorted(values)
    middle = len(sorted_values) // 2
    if len(sorted_values) % 2 == 1:
        return sorted_values[middle]
    return (sorted_values[middle - 1] + sorted_values[middle]) / 2.0


def _idle_machine_values(samples: list[dict], key: str) -> list[float]:
    values: list[float] = []
    for sample in samples:
        machine = sample.get("machine", {}) if isinstance(sample.get("machine", {}), dict) else {}
        if not machine.get("available", False):
            continue
        value = machine.get(key, None)
        if isinstance(value, (int, float)):
            values.append(float(value))
    return values


def _idle_raw_gpu_values(samples: list[dict], key: str) -> list[float]:
    values: list[float] = []
    for sample in samples:
        raw_gpu = sample.get("raw_gpu", {}) if isinstance(sample.get("raw_gpu", {}), dict) else {}
        if not raw_gpu.get("available", False):
            continue
        value = raw_gpu.get(key, None)
        if isinstance(value, (int, float)):
            values.append(float(value))
    return values


def _summarize_preflight_idle_samples(samples: list[dict]) -> dict:
    cpu_load_values = _idle_machine_values(samples, "load_percentage")
    cpu_perf_values = _idle_machine_values(samples, "percent_processor_performance")
    cpu_utility_values = _idle_machine_values(samples, "percent_processor_utility")
    gpu_power_values = _idle_raw_gpu_values(samples, "power_w")
    gpu_util_values = _idle_raw_gpu_values(samples, "gpu_util_percent")
    gpu_temp_values = _idle_raw_gpu_values(samples, "temp_c")
    return {
        "sample_count": len(samples),
        "cpu_load_percent": _summarize_numeric(cpu_load_values),
        "cpu_load_median_percent": _median(cpu_load_values),
        "cpu_processor_performance_percent": _summarize_numeric(cpu_perf_values),
        "cpu_processor_performance_median_percent": _median(cpu_perf_values),
        "cpu_processor_utility_percent": _summarize_numeric(cpu_utility_values),
        "cpu_processor_utility_median_percent": _median(cpu_utility_values),
        "raw_gpu_power_w": _summarize_numeric(gpu_power_values),
        "raw_gpu_power_median_w": _median(gpu_power_values),
        "raw_gpu_util_percent": _summarize_numeric(gpu_util_values),
        "raw_gpu_util_median_percent": _median(gpu_util_values),
        "raw_gpu_temp_c": _summarize_numeric(gpu_temp_values),
    }


def _preflight_contamination_reasons_for_idle_samples(samples: list[dict]) -> list[str]:
    if not samples:
        return ["idle samples unavailable"]

    max_cpu_load = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_CPU_LOAD_PERCENT", 55.0)
    max_cpu_perf = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_CPU_PERF_PERCENT", 115.0)
    max_cpu_utility = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_CPU_UTILITY_PERCENT", 80.0)
    max_gpu_power = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_GPU_POWER_W", 15.0)
    max_gpu_util = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_GPU_UTIL_PERCENT", 30.0)
    max_gpu_temp = _float_from_env("TOWN_STALL_PREFLIGHT_MAX_GPU_TEMP_C", 85.0)

    summary = _summarize_preflight_idle_samples(samples)
    reasons: list[str] = []

    cpu_load_median = summary.get("cpu_load_median_percent", None)
    cpu_perf_median = summary.get("cpu_processor_performance_median_percent", None)
    cpu_utility_median = summary.get("cpu_processor_utility_median_percent", None)
    gpu_power_median = summary.get("raw_gpu_power_median_w", None)
    gpu_util_median = summary.get("raw_gpu_util_median_percent", None)
    gpu_temp = summary.get("raw_gpu_temp_c", {})
    gpu_temp_max = gpu_temp.get("max", None) if isinstance(gpu_temp, dict) else None

    if cpu_load_median is not None and float(cpu_load_median) > max_cpu_load:
        reasons.append(f"median CPU load {float(cpu_load_median):.1f}% > {max_cpu_load:.1f}%")
    if cpu_perf_median is not None and float(cpu_perf_median) > max_cpu_perf:
        reasons.append(f"median CPU processor performance {float(cpu_perf_median):.1f}% > {max_cpu_perf:.1f}%")
    if cpu_utility_median is not None and float(cpu_utility_median) > max_cpu_utility:
        reasons.append(f"median CPU processor utility {float(cpu_utility_median):.1f}% > {max_cpu_utility:.1f}%")
    if gpu_power_median is not None and float(gpu_power_median) > max_gpu_power:
        reasons.append(f"median GPU power {float(gpu_power_median):.2f} W > {max_gpu_power:.2f} W")
    if gpu_util_median is not None and float(gpu_util_median) > max_gpu_util:
        reasons.append(f"median GPU utilization {float(gpu_util_median):.1f}% > {max_gpu_util:.1f}%")
    if gpu_temp_max is not None and float(gpu_temp_max) > max_gpu_temp:
        reasons.append(f"GPU temperature max {float(gpu_temp_max):.1f} C > {max_gpu_temp:.1f} C")

    return reasons


def _print_preflight_idle_sample_summary(summary: dict) -> None:
    cpu_load = summary.get("cpu_load_percent", {})
    cpu_utility = summary.get("cpu_processor_utility_percent", {})
    gpu_power = summary.get("raw_gpu_power_w", {})
    gpu_util = summary.get("raw_gpu_util_percent", {})
    print(
        "Preflight idle samples: "
        f"count={int(summary.get('sample_count', 0) or 0)} "
        f"cpu_load_median={summary.get('cpu_load_median_percent', 0.0)}% "
        f"cpu_load_avg/max={cpu_load.get('avg', 0.0)}/{cpu_load.get('max', 0.0)}% "
        f"cpu_utility_median={summary.get('cpu_processor_utility_median_percent', 0.0)}% "
        f"cpu_utility_avg/max={cpu_utility.get('avg', 0.0)}/{cpu_utility.get('max', 0.0)}% "
        f"gpu_power_median={summary.get('raw_gpu_power_median_w', 0.0)}W "
        f"gpu_power_avg/max={gpu_power.get('avg', 0.0)}/{gpu_power.get('max', 0.0)}W "
        f"gpu_util_median={summary.get('raw_gpu_util_median_percent', 0.0)}% "
        f"gpu_util_avg/max={gpu_util.get('avg', 0.0)}/{gpu_util.get('max', 0.0)}%"
    )


def _write_system_sample(sample_file: Path, sample: dict) -> None:
    sample_file.parent.mkdir(parents=True, exist_ok=True)
    with sample_file.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(sample, separators=(",", ":")) + "\n")


def _sample_system_until(stop_event: threading.Event, pid: int, interval_seconds: float, sample_file: Path) -> None:
    raw_gpu_only = os.environ.get("TOWN_STALL_SYSTEM_SAMPLE_RAW_GPU_ONLY", "0") == "1"
    full_sample_every = _positive_int_from_env("TOWN_STALL_SYSTEM_SAMPLE_FULL_EVERY", 1)
    interval = max(0.1, interval_seconds)
    sample_index = 0
    while not stop_event.is_set():
        sample_start = time.perf_counter()
        sample_mode = "raw_gpu_only" if raw_gpu_only else "full"
        if not raw_gpu_only and full_sample_every > 1 and sample_index % full_sample_every != 0:
            sample_mode = "raw_gpu"

        machine = {"available": False, "skipped": True, "reason": sample_mode}
        process = {"available": False, "skipped": True, "reason": sample_mode, "pid": pid}
        if sample_mode == "full":
            machine = _collect_machine_state()
            process = _collect_process_state(pid)

        sample = {
            "epoch": time.time(),
            "sample_index": sample_index,
            "sample_mode": sample_mode,
            "machine": machine,
            "process": process,
            "raw_gpu": _collect_raw_gpu_state(),
        }
        sample["probe_seconds"] = round(time.perf_counter() - sample_start, 3)
        _write_system_sample(sample_file, sample)
        sample_index += 1
        stop_event.wait(max(0.0, interval - (time.perf_counter() - sample_start)))


def _collect_idle_state_samples(delay_seconds: float, sample_count: int, interval_seconds: float) -> list[dict]:
    if delay_seconds > 0.0:
        time.sleep(delay_seconds)

    samples: list[dict] = []
    count = max(1, sample_count)
    interval = max(0.1, interval_seconds)
    for index in range(count):
        sample_start = time.perf_counter()
        samples.append({
            "epoch": time.time(),
            "sample_index": index,
            "sample_mode": "idle_probe",
            "machine": _collect_machine_state(),
            "raw_gpu": _collect_raw_gpu_state(),
            "probe_seconds": round(time.perf_counter() - sample_start, 3),
        })
        if index < count - 1:
            time.sleep(interval)
    return samples


def _collect_preflight_idle_until_clean(
    sample_count: int,
    interval_seconds: float,
    retry_timeout_seconds: float,
    retry_poll_seconds: float,
) -> tuple[list[dict], list[str], dict]:
    started = time.time()
    deadline = started + max(0.0, retry_timeout_seconds)
    retry_enabled = retry_timeout_seconds > 0.0
    retry_poll_seconds = max(1.0, retry_poll_seconds)
    attempts: list[dict] = []

    while True:
        attempt_started = time.time()
        samples = _collect_idle_state_samples(0.0, sample_count, interval_seconds)
        summary = _summarize_preflight_idle_samples(samples)
        reasons = _preflight_contamination_reasons_for_idle_samples(samples)
        attempts.append({
            "attempt": len(attempts) + 1,
            "started_at_epoch": attempt_started,
            "ended_at_epoch": time.time(),
            "duration_s": time.time() - attempt_started,
            "summary": summary,
            "reasons": reasons,
            "clean": not reasons,
        })
        if not reasons:
            return samples, reasons, {
                "enabled": retry_enabled,
                "timeout_seconds": retry_timeout_seconds,
                "poll_seconds": retry_poll_seconds,
                "attempt_count": len(attempts),
                "attempts": attempts,
                "selected_attempt": len(attempts),
                "clean": True,
                "duration_s": time.time() - started,
            }

        print(f"Preflight idle contaminated: {', '.join(reasons)}")
        if not retry_enabled or time.time() >= deadline:
            return samples, reasons, {
                "enabled": retry_enabled,
                "timeout_seconds": retry_timeout_seconds,
                "poll_seconds": retry_poll_seconds,
                "attempt_count": len(attempts),
                "attempts": attempts,
                "selected_attempt": len(attempts),
                "clean": False,
                "duration_s": time.time() - started,
            }

        sleep_seconds = min(retry_poll_seconds, max(0.0, deadline - time.time()))
        print(f"Retrying town preflight idle in {sleep_seconds:.1f}s")
        if sleep_seconds > 0.0:
            time.sleep(sleep_seconds)


def _idle_state_contamination_reasons(samples: list[dict]) -> list[str]:
    return _preflight_contamination_reasons_for_idle_samples(samples)


def _collect_postrun_idle_state_samples(
    delay_seconds: float,
    sample_count: int,
    interval_seconds: float,
    settle_timeout_seconds: float,
) -> tuple[list[dict], list[str], dict]:
    if delay_seconds > 0.0:
        time.sleep(delay_seconds)

    start_time = time.time()
    all_samples: list[dict] = []
    latest_batch: list[dict] = []
    latest_reasons: list[str] = ["post-run idle samples unavailable"]
    attempts = 0
    count = max(1, sample_count)
    interval = max(0.1, interval_seconds)
    deadline = start_time + max(0.0, settle_timeout_seconds)

    while True:
        latest_batch = []
        attempts += 1
        for index in range(count):
            sample_start = time.perf_counter()
            sample = {
                "epoch": time.time(),
                "sample_index": len(all_samples),
                "sample_mode": "postrun_idle_probe",
                "postrun_idle_attempt": attempts,
                "machine": _collect_machine_state(),
                "raw_gpu": _collect_raw_gpu_state(),
            }
            sample["probe_seconds"] = round(time.perf_counter() - sample_start, 3)
            all_samples.append(sample)
            latest_batch.append(sample)
            if index < count - 1:
                time.sleep(interval)

        latest_reasons = _idle_state_contamination_reasons(latest_batch)
        if not latest_reasons:
            return all_samples, [], {
                "attempts": attempts,
                "settled": True,
                "settle_seconds": round(time.time() - start_time, 3),
                "settle_timeout_seconds": settle_timeout_seconds,
                "latest_batch_summary": _summarize_system_sample_list(latest_batch),
            }

        if settle_timeout_seconds <= 0.0 or time.time() >= deadline:
            return all_samples, latest_reasons, {
                "attempts": attempts,
                "settled": False,
                "settle_seconds": round(time.time() - start_time, 3),
                "settle_timeout_seconds": settle_timeout_seconds,
                "latest_batch_summary": _summarize_system_sample_list(latest_batch),
            }


def _summarize_numeric(values: list[float]) -> dict:
    if not values:
        return {"count": 0, "avg": 0.0, "max": 0.0, "min": 0.0}
    return {
        "count": len(values),
        "avg": round(sum(values) / len(values), 3),
        "max": round(max(values), 3),
        "min": round(min(values), 3),
    }


def _summarize_raw_gpu_pstates(samples: list[dict]) -> dict:
    counts: dict[str, int] = {}
    for sample in samples:
        if not bool(sample.get("available", False)):
            continue
        pstate = str(sample.get("pstate", "")).strip() or "unknown"
        counts[pstate] = int(counts.get(pstate, 0)) + 1
    return counts


def _summarize_sample_modes(samples: list[dict]) -> dict:
    counts: dict[str, int] = {}
    for sample in samples:
        mode = str(sample.get("sample_mode", "")).strip() or "unknown"
        counts[mode] = int(counts.get(mode, 0)) + 1
    return counts


def _read_system_samples(sample_file: Path) -> list[dict]:
    if not sample_file.exists():
        return []

    samples: list[dict] = []
    with sample_file.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(parsed, dict):
                samples.append(parsed)
    return samples


def _summarize_system_sample_list(samples: list[dict]) -> dict:
    if not samples:
        return {"available": False, "sample_count": 0}

    epochs = [float(sample.get("epoch", 0.0) or 0.0) for sample in samples]
    process_samples = [sample.get("process", {}) for sample in samples if isinstance(sample.get("process", {}), dict)]
    machine_samples = [sample.get("machine", {}) for sample in samples if isinstance(sample.get("machine", {}), dict)]
    raw_gpu_samples = [sample.get("raw_gpu", {}) for sample in samples if isinstance(sample.get("raw_gpu", {}), dict)]
    available_raw_gpu_samples = [sample for sample in raw_gpu_samples if bool(sample.get("available", False))]
    thermal_values = [
        float(sample.get("thermal_c"))
        for sample in machine_samples
        if isinstance(sample.get("thermal_c", None), (int, float))
    ]

    return {
        "available": True,
        "sample_count": len(samples),
        "sample_modes": _summarize_sample_modes(samples),
        "duration_seconds": round(max(epochs) - min(epochs), 1) if len(epochs) >= 2 else 0.0,
        "probe_seconds": _summarize_numeric([
            float(sample.get("probe_seconds", 0.0) or 0.0)
            for sample in samples
            if isinstance(sample.get("probe_seconds", None), (int, float))
        ]),
        "process_cpu_percent": _summarize_numeric([
            float(sample.get("cpu_percent", 0.0) or 0.0)
            for sample in process_samples
            if bool(sample.get("available", False))
        ]),
        "gpu_total_percent": _summarize_numeric([
            float(sample.get("gpu_utilization_total_percent", 0.0) or 0.0)
            for sample in process_samples
            if bool(sample.get("available", False))
        ]),
        "gpu_max_engine_percent": _summarize_numeric([
            float(sample.get("gpu_utilization_max_engine_percent", 0.0) or 0.0)
            for sample in process_samples
            if bool(sample.get("available", False))
        ]),
        "working_set_private_mb": _summarize_numeric([
            float(sample.get("working_set_private_mb", 0.0) or 0.0)
            for sample in process_samples
            if bool(sample.get("available", False))
        ]),
        "cpu_load_percent": _summarize_numeric([
            float(sample.get("load_percentage", 0.0) or 0.0)
            for sample in machine_samples
            if bool(sample.get("available", False))
        ]),
        "cpu_processor_performance_percent": _summarize_numeric([
            float(sample.get("percent_processor_performance", 0.0) or 0.0)
            for sample in machine_samples
            if bool(sample.get("available", False))
        ]),
        "thermal_c": _summarize_numeric(thermal_values),
        "raw_gpu_available_count": len(available_raw_gpu_samples),
        "raw_gpu_pstates": _summarize_raw_gpu_pstates(raw_gpu_samples),
        "raw_gpu_power_w": _summarize_numeric([
            float(sample.get("power_w", 0.0))
            for sample in available_raw_gpu_samples
            if isinstance(sample.get("power_w", None), (int, float))
        ]),
        "raw_gpu_temp_c": _summarize_numeric([
            float(sample.get("temp_c", 0.0))
            for sample in available_raw_gpu_samples
            if isinstance(sample.get("temp_c", None), (int, float))
        ]),
        "raw_gpu_util_percent": _summarize_numeric([
            float(sample.get("gpu_util_percent", 0.0))
            for sample in available_raw_gpu_samples
            if isinstance(sample.get("gpu_util_percent", None), (int, float))
        ]),
        "raw_gpu_memory_util_percent": _summarize_numeric([
            float(sample.get("memory_util_percent", 0.0))
            for sample in available_raw_gpu_samples
            if isinstance(sample.get("memory_util_percent", None), (int, float))
        ]),
        "raw_gpu_graphics_clock_mhz": _summarize_numeric([
            float(sample.get("graphics_clock_mhz", 0.0))
            for sample in available_raw_gpu_samples
            if isinstance(sample.get("graphics_clock_mhz", None), (int, float))
        ]),
        "raw_gpu_memory_clock_mhz": _summarize_numeric([
            float(sample.get("memory_clock_mhz", 0.0))
            for sample in available_raw_gpu_samples
            if isinstance(sample.get("memory_clock_mhz", None), (int, float))
        ]),
        "raw_gpu_vram_used_mb": _summarize_numeric([
            float(sample.get("vram_used_mb", 0.0))
            for sample in available_raw_gpu_samples
            if isinstance(sample.get("vram_used_mb", None), (int, float))
        ]),
    }


def _summarize_system_samples(sample_file: Path) -> dict:
    return _summarize_system_sample_list(_read_system_samples(sample_file))


def _extract_town_scope_event_epochs(snapshot_path: Path) -> dict[str, float]:
    try:
        snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    except Exception:
        return {}

    events = snapshot.get("recent_scope_events", [])
    if not isinstance(events, list):
        return {}

    epochs: dict[str, float] = {}
    for event in events:
        if not isinstance(event, dict):
            continue
        if str(event.get("scope", "")) != "town_stall_test":
            continue
        label = str(event.get("label", ""))
        epoch = event.get("epoch")
        if label and isinstance(epoch, (int, float)):
            epochs[label] = float(epoch)
    return epochs


def _extract_terrain_runtime_power_events(snapshot_path: Path) -> list[dict]:
    try:
        snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    except Exception:
        return []

    terrain = (
        snapshot.get("system_telemetry", {})
        .get("terrain_manager", {})
        if isinstance(snapshot.get("system_telemetry", {}), dict)
        else {}
    )
    if not isinstance(terrain, dict):
        return []

    raw_events = terrain.get("runtime_power_recent_events", [])
    if not isinstance(raw_events, list):
        return []

    events: list[dict] = []
    for event in raw_events:
        if not isinstance(event, dict):
            continue
        epoch = event.get("epoch")
        label = str(event.get("label", ""))
        if not label or not isinstance(epoch, (int, float)):
            continue
        events.append(event)
    events.sort(key=lambda item: float(item.get("epoch", 0.0) or 0.0))
    return events


def _find_runtime_power_event_epoch(
    events: list[dict],
    label: str,
    after_epoch: Optional[float] = None,
    before_epoch: Optional[float] = None,
    detail_key: str = "",
    detail_value: object = None,
) -> Optional[float]:
    for event in events:
        if str(event.get("label", "")) != label:
            continue
        epoch = event.get("epoch")
        if not isinstance(epoch, (int, float)):
            continue
        epoch_float = float(epoch)
        if after_epoch is not None and epoch_float <= after_epoch:
            continue
        if before_epoch is not None and epoch_float >= before_epoch:
            continue
        if detail_key:
            details = event.get("details", {})
            if not isinstance(details, dict) or details.get(detail_key) != detail_value:
                continue
        return epoch_float
    return None


def _summarize_system_samples_in_epoch_range(
    samples: list[dict],
    name: str,
    start_epoch: Optional[float],
    end_epoch: Optional[float],
) -> dict:
    summary = {
        "available": False,
        "sample_count": 0,
        "window_name": name,
        "window_start_epoch": start_epoch,
        "window_end_epoch": end_epoch,
        "requested_duration_seconds": 0.0,
    }
    if start_epoch is None or end_epoch is None or end_epoch <= start_epoch:
        return summary

    summary["requested_duration_seconds"] = round(end_epoch - start_epoch, 3)
    window_samples = [
        sample
        for sample in samples
        if start_epoch <= float(sample.get("epoch", 0.0) or 0.0) <= end_epoch
    ]
    window_summary = _summarize_system_sample_list(window_samples)
    summary.update(window_summary)
    summary["window_name"] = name
    summary["window_start_epoch"] = start_epoch
    summary["window_end_epoch"] = end_epoch
    summary["requested_duration_seconds"] = round(end_epoch - start_epoch, 3)
    return summary


def _attach_phase_system_sample_summary(system_summary: dict, sample_file: Path, snapshot_path: Optional[Path]) -> dict:
    if not snapshot_path or not system_summary or not bool(system_summary.get("available", False)):
        return system_summary

    samples = _read_system_samples(sample_file)
    if not samples:
        return system_summary

    epochs = _extract_town_scope_event_epochs(snapshot_path)
    reset_epoch = epochs.get("measurement_reset")
    hold_start_epoch = epochs.get("hold_started")
    hold_complete_epoch = epochs.get("hold_complete")
    shutdown_epoch = epochs.get("shutdown_requested")
    last_sample_epoch = max(float(sample.get("epoch", 0.0) or 0.0) for sample in samples)
    last_process_sample_epoch = max(
        (
            float(sample.get("epoch", 0.0) or 0.0)
            for sample in samples
            if isinstance(sample.get("process"), dict)
            and bool(sample.get("process", {}).get("available", False))
        ),
        default=last_sample_epoch,
    )
    hold_measure_end_epoch = hold_complete_epoch
    hold_measure_end_source = "hold_complete"
    if hold_measure_end_epoch is None:
        hold_measure_end_epoch = shutdown_epoch
        hold_measure_end_source = "shutdown_requested"
    if hold_measure_end_epoch is None:
        # Manual long-play runs can be closed before the harness emits hold_complete.
        # Use the last live process sample so power attribution excludes post-exit idle.
        hold_measure_end_epoch = last_process_sample_epoch
        hold_measure_end_source = "last_process_sample"
    runtime_power_events = _extract_terrain_runtime_power_events(snapshot_path)
    deep_idle_start_epoch = _find_runtime_power_event_epoch(
        runtime_power_events,
        "runtime_power_mode_changed",
        hold_start_epoch,
        hold_measure_end_epoch,
        "to",
        "deep_idle",
    )
    deep_idle_end_epoch = None
    if deep_idle_start_epoch is not None:
        deep_idle_end_epoch = _find_runtime_power_event_epoch(
            runtime_power_events,
            "runtime_power_mode_changed",
            deep_idle_start_epoch,
            hold_measure_end_epoch,
            "from",
            "deep_idle",
        ) or hold_measure_end_epoch
    render_loop_suspend_start_epoch = _find_runtime_power_event_epoch(
        runtime_power_events,
        "runtime_power_render_loop_suspended",
        hold_start_epoch,
        hold_measure_end_epoch,
    )
    render_loop_suspend_end_epoch = None
    if render_loop_suspend_start_epoch is not None:
        render_loop_suspend_end_epoch = _find_runtime_power_event_epoch(
            runtime_power_events,
            "runtime_power_render_loop_resumed",
            render_loop_suspend_start_epoch,
            hold_measure_end_epoch,
        ) or hold_measure_end_epoch
    render_loop_suspend_tail_start_epoch = None
    if render_loop_suspend_start_epoch is not None and render_loop_suspend_end_epoch is not None:
        render_loop_suspend_tail_start_epoch = max(render_loop_suspend_start_epoch, render_loop_suspend_end_epoch - 10.0)

    phase_windows = {
        "moving_entry": _summarize_system_samples_in_epoch_range(samples, "moving_entry", reset_epoch, hold_start_epoch),
        "stationary_hold": _summarize_system_samples_in_epoch_range(samples, "stationary_hold", hold_start_epoch, hold_measure_end_epoch),
        "stationary_hold_tail_30s": _summarize_system_samples_in_epoch_range(
            samples,
            "stationary_hold_tail_30s",
            max(hold_start_epoch, hold_measure_end_epoch - 30.0) if hold_start_epoch is not None and hold_measure_end_epoch is not None else None,
            hold_measure_end_epoch,
        ),
        "measurement_to_shutdown": _summarize_system_samples_in_epoch_range(
            samples,
            "measurement_to_shutdown",
            reset_epoch,
            shutdown_epoch if shutdown_epoch is not None else last_sample_epoch,
        ),
        "runtime_power_deep_idle": _summarize_system_samples_in_epoch_range(
            samples,
            "runtime_power_deep_idle",
            deep_idle_start_epoch,
            deep_idle_end_epoch,
        ),
        "runtime_power_render_loop_suspended": _summarize_system_samples_in_epoch_range(
            samples,
            "runtime_power_render_loop_suspended",
            render_loop_suspend_start_epoch,
            render_loop_suspend_end_epoch,
        ),
        "runtime_power_render_loop_suspended_tail_10s": _summarize_system_samples_in_epoch_range(
            samples,
            "runtime_power_render_loop_suspended_tail_10s",
            render_loop_suspend_tail_start_epoch,
            render_loop_suspend_end_epoch,
        ),
    }
    system_summary["phase_event_epochs"] = epochs
    system_summary["stationary_hold_end_source"] = hold_measure_end_source
    if runtime_power_events:
        system_summary["runtime_power_events"] = runtime_power_events
    system_summary["phase_windows"] = phase_windows
    return system_summary


def _persist_system_sample_summary_to_snapshot(snapshot_path: Optional[Path], system_sample_summary: dict) -> None:
    if not snapshot_path or not system_sample_summary:
        return

    try:
        snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return

    if not isinstance(snapshot, dict):
        return

    snapshot["system_sample_summary"] = system_sample_summary
    snapshot["efficiency_metrics"] = _build_efficiency_metrics(snapshot, system_sample_summary)
    try:
        snapshot_path.write_text(json.dumps(snapshot, indent=2), encoding="utf-8")
    except OSError:
        pass


def _metric_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _metric_dict(value: Any) -> dict:
    return value if isinstance(value, dict) else {}


def _wpf60(power_w: float, frame_ms: float) -> float:
    if power_w <= 0.0 or frame_ms <= 0.0:
        return 0.0
    return power_w * frame_ms / FPS_60_FRAME_MS


def _phase_avg_power_w(system_sample_summary: dict, phase_name: str) -> float:
    phase_windows = _metric_dict(system_sample_summary.get("phase_windows"))
    phase = _metric_dict(phase_windows.get(phase_name))
    power = _metric_dict(phase.get("raw_gpu_power_w"))
    return _metric_float(power.get("avg"))


def _build_efficiency_metric_entry(frame_window: dict, avg_power_w: float) -> dict:
    avg_frame_ms = _metric_float(frame_window.get("avg_total_ms"))
    metric = _wpf60(avg_power_w, avg_frame_ms)
    return {
        "avg_frame_ms": round(avg_frame_ms, 3),
        "avg_fps_estimate": round(1000.0 / avg_frame_ms, 3) if avg_frame_ms > 0.0 else 0.0,
        "avg_power_w": round(avg_power_w, 3),
        "wpf60": round(metric, 3),
        "target_wpf60": TARGET_WPF60_BASELINE,
        "over_target_wpf60": round(metric - TARGET_WPF60_BASELINE, 3) if metric > 0.0 else 0.0,
    }


def _build_efficiency_metrics(snapshot: dict, system_sample_summary: dict) -> dict:
    town_window = _metric_dict(snapshot.get("town_entry_window"))
    moving_window = _metric_dict(snapshot.get("moving_entry_window"))
    stationary_window = _metric_dict(snapshot.get("stationary_hold_window"))
    overall_power = _metric_float(_metric_dict(system_sample_summary.get("raw_gpu_power_w")).get("avg"))
    moving_power = _phase_avg_power_w(system_sample_summary, "moving_entry")
    stationary_power = _phase_avg_power_w(system_sample_summary, "stationary_hold")
    return {
        "unit": "WPF60",
        "target_baseline_wpf60": TARGET_WPF60_BASELINE,
        "formula": "avg_gpu_watts * avg_frame_ms / 16.6667ms",
        "stationary_hold_end_source": str(system_sample_summary.get("stationary_hold_end_source", "")),
        "town_total": _build_efficiency_metric_entry(town_window, overall_power),
        "moving_entry": _build_efficiency_metric_entry(moving_window, moving_power),
        "stationary_hold": _build_efficiency_metric_entry(stationary_window, stationary_power),
    }


def _print_system_sample_summary(summary: dict) -> None:
    if not summary or not bool(summary.get("available", False)):
        print("System sampling: unavailable")
        return
    print("\nSystem sampling:")
    print(f"  Samples: {int(summary.get('sample_count', 0))} over {float(summary.get('duration_seconds', 0.0)):.1f}s")
    sample_modes = summary.get("sample_modes", {})
    if isinstance(sample_modes, dict) and sample_modes:
        modes = ", ".join(f"{key}={value}" for key, value in sorted(sample_modes.items()))
        print(f"  Sample modes: {modes}")
    probe_seconds = summary.get("probe_seconds", {})
    if isinstance(probe_seconds, dict) and int(probe_seconds.get("count", 0) or 0) > 0:
        print(f"  Probe seconds: avg {probe_seconds.get('avg', 0.0)} max {probe_seconds.get('max', 0.0)}")
    settle = summary.get("settle", {})
    if isinstance(settle, dict) and settle:
        print(
            "  Idle settle: {state} after {seconds}s attempts={attempts} timeout={timeout}s".format(
                state="settled" if bool(settle.get("settled", False)) else "not settled",
                seconds=settle.get("settle_seconds", 0.0),
                attempts=int(settle.get("attempts", 0) or 0),
                timeout=settle.get("settle_timeout_seconds", 0.0),
            )
        )
    process_cpu = summary.get("process_cpu_percent", {})
    gpu_total = summary.get("gpu_total_percent", {})
    gpu_max_engine = summary.get("gpu_max_engine_percent", {})
    working_set = summary.get("working_set_private_mb", {})
    cpu_load = summary.get("cpu_load_percent", {})
    cpu_perf = summary.get("cpu_processor_performance_percent", {})
    thermal = summary.get("thermal_c", {})
    raw_gpu_power = summary.get("raw_gpu_power_w", {})
    raw_gpu_temp = summary.get("raw_gpu_temp_c", {})
    raw_gpu_util = summary.get("raw_gpu_util_percent", {})
    print(f"  Godot CPU: avg {process_cpu.get('avg', 0.0)}% max {process_cpu.get('max', 0.0)}%")
    print(f"  GPU total: avg {gpu_total.get('avg', 0.0)}% max {gpu_total.get('max', 0.0)}%")
    print(f"  GPU max engine: avg {gpu_max_engine.get('avg', 0.0)}% max {gpu_max_engine.get('max', 0.0)}%")
    if int(raw_gpu_power.get("count", 0) or 0) > 0:
        print(f"  Raw GPU watts: avg {raw_gpu_power.get('avg', 0.0)} W max {raw_gpu_power.get('max', 0.0)} W")
    else:
        print("  Raw GPU watts: unavailable")
    if int(raw_gpu_temp.get("count", 0) or 0) > 0:
        print(f"  Raw GPU temp: avg {raw_gpu_temp.get('avg', 0.0)} C max {raw_gpu_temp.get('max', 0.0)} C")
    else:
        print("  Raw GPU temp: unavailable")
    if int(raw_gpu_util.get("count", 0) or 0) > 0:
        print(f"  Raw GPU util: avg {raw_gpu_util.get('avg', 0.0)}% max {raw_gpu_util.get('max', 0.0)}%")
    print(f"  Working set: avg {working_set.get('avg', 0.0)} MB max {working_set.get('max', 0.0)} MB")
    print(f"  CPU load: avg {cpu_load.get('avg', 0.0)}% max {cpu_load.get('max', 0.0)}%")
    print(f"  CPU perf: avg {cpu_perf.get('avg', 0.0)}% max {cpu_perf.get('max', 0.0)}%")
    if int(thermal.get("count", 0) or 0) > 0:
        print(f"  Thermal: avg {thermal.get('avg', 0.0)} C max {thermal.get('max', 0.0)} C")
    else:
        print("  Thermal: unavailable")


def _print_phase_system_sample_summary(summary: dict) -> None:
    windows = summary.get("phase_windows", {}) if isinstance(summary, dict) else {}
    if not isinstance(windows, dict) or not windows:
        return

    print("\nSystem sampling phase windows:")
    for key in [
        "moving_entry",
        "stationary_hold",
        "stationary_hold_tail_30s",
        "runtime_power_deep_idle",
        "runtime_power_render_loop_suspended",
        "runtime_power_render_loop_suspended_tail_10s",
    ]:
        window = windows.get(key, {})
        if not isinstance(window, dict):
            continue
        raw_gpu_power = window.get("raw_gpu_power_w", {})
        raw_gpu_temp = window.get("raw_gpu_temp_c", {})
        raw_gpu_util = window.get("raw_gpu_util_percent", {})
        raw_gpu_pstates = window.get("raw_gpu_pstates", {})
        if int(window.get("sample_count", 0) or 0) <= 0:
            print(f"  {key}: no samples")
            continue
        pstate_summary = ""
        if isinstance(raw_gpu_pstates, dict) and raw_gpu_pstates:
            pstate_summary = " pstates=" + ",".join(
                f"{pstate}:{count}" for pstate, count in sorted(raw_gpu_pstates.items())
            )
        print(
            "  {key}: samples={samples} raw_gpu={raw_samples} "
            "watts_avg/max={watts_avg}/{watts_max} temp_avg/max={temp_avg}/{temp_max} "
            "util_avg/max={util_avg}/{util_max}{pstates}".format(
                key=key,
                samples=int(window.get("sample_count", 0) or 0),
                raw_samples=int(window.get("raw_gpu_available_count", 0) or 0),
                watts_avg=raw_gpu_power.get("avg", 0.0),
                watts_max=raw_gpu_power.get("max", 0.0),
                temp_avg=raw_gpu_temp.get("avg", 0.0),
                temp_max=raw_gpu_temp.get("max", 0.0),
                util_avg=raw_gpu_util.get("avg", 0.0),
                util_max=raw_gpu_util.get("max", 0.0),
                pstates=pstate_summary,
            )
        )


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
    efficiency_metrics = data.get("efficiency_metrics", {})
    if isinstance(efficiency_metrics, dict) and efficiency_metrics:
        print("Efficiency metrics:")
        print(f"  Unit: {efficiency_metrics.get('unit', 'WPF60')} target={efficiency_metrics.get('target_baseline_wpf60', TARGET_WPF60_BASELINE)}")
        for key in ("moving_entry", "stationary_hold", "town_total"):
            entry = efficiency_metrics.get(key, {})
            if not isinstance(entry, dict) or float(entry.get("wpf60", 0.0) or 0.0) <= 0.0:
                continue
            print(
                "  {key}: WPF60={wpf60} avg_ms={avg_ms} fps~{fps} watts={watts}".format(
                    key=key,
                    wpf60=entry.get("wpf60", 0.0),
                    avg_ms=entry.get("avg_frame_ms", 0.0),
                    fps=entry.get("avg_fps_estimate", 0.0),
                    watts=entry.get("avg_power_w", 0.0),
                )
            )
    _print_snapshot_proof_summary(data)
    print("=" * 50)


def _as_dict(value: Any) -> dict:
    return value if isinstance(value, dict) else {}


def _int_value(value: Any, default: int = 0) -> int:
    parsed = _parse_optional_float(value)
    if parsed is None:
        return default
    return int(parsed)


def _float_value(value: Any, default: float = 0.0) -> float:
    parsed = _parse_optional_float(value)
    if parsed is None:
        return default
    return float(parsed)


def _stationary_runtime_idle_verdict_from_snapshot(data: dict) -> dict:
    direct = _as_dict(data.get("stationary_runtime_idle_verdict"))
    stationary_hold = _as_dict(data.get("stationary_hold_window"))
    sample_count = _int_value(
        direct.get("monitor_available_samples", stationary_hold.get("world_runtime_monitor_available_samples"))
    )
    idle_samples = _int_value(direct.get("idle_samples", stationary_hold.get("world_runtime_idle_samples")))
    busy_samples = _int_value(direct.get("busy_samples", stationary_hold.get("world_runtime_busy_samples")))
    return {
        "available": sample_count > 0,
        "monitor_available_samples": sample_count,
        "idle_samples": idle_samples,
        "busy_samples": busy_samples,
        "idle_sample_ratio": _float_value(
            direct.get("idle_sample_ratio", stationary_hold.get("world_runtime_idle_sample_ratio"))
        ),
        "max_pending_work": _float_value(
            direct.get("max_pending_work", stationary_hold.get("max_world_runtime_pending_work"))
        ),
        "max_awake_process_count": _float_value(
            direct.get("max_awake_process_count", stationary_hold.get("max_world_runtime_awake_process_count"))
        ),
    }


def _stationary_terrain_artifact_cache_verdict_from_snapshot(data: dict) -> dict:
    direct = _as_dict(data.get("stationary_terrain_artifact_cache_verdict"))
    stationary_hold = _as_dict(data.get("stationary_hold_window"))
    sample_count = _int_value(
        direct.get("monitor_available_samples", stationary_hold.get("world_runtime_monitor_available_samples"))
    )
    return {
        "available": sample_count > 0,
        "monitor_available_samples": sample_count,
        "avg_hit_ratio": _float_value(
            direct.get("avg_hit_ratio", stationary_hold.get("avg_terrain_artifact_cache_hit_ratio"))
        ),
        "end_hit_ratio": _float_value(
            direct.get("end_hit_ratio", stationary_hold.get("end_terrain_artifact_cache_hit_ratio"))
        ),
        "max_entries": _float_value(direct.get("max_entries", stationary_hold.get("max_terrain_artifact_cache_entries"))),
        "end_entries": _float_value(direct.get("end_entries", stationary_hold.get("end_terrain_artifact_cache_entries"))),
        "max_bytes": _float_value(direct.get("max_bytes", stationary_hold.get("max_terrain_artifact_cache_bytes"))),
        "end_bytes": _float_value(direct.get("end_bytes", stationary_hold.get("end_terrain_artifact_cache_bytes"))),
        "max_byte_budget_ratio": _float_value(
            direct.get("max_byte_budget_ratio", stationary_hold.get("max_terrain_artifact_cache_byte_budget_ratio"))
        ),
        "end_byte_budget_ratio": _float_value(
            direct.get("end_byte_budget_ratio", stationary_hold.get("end_terrain_artifact_cache_byte_budget_ratio"))
        ),
        "eviction_delta": _float_value(
            direct.get("eviction_delta", stationary_hold.get("terrain_artifact_cache_eviction_delta"))
        ),
        "disk_hit_delta": _float_value(
            direct.get("disk_hit_delta", stationary_hold.get("terrain_artifact_cache_disk_hit_delta"))
        ),
        "disk_max_bytes": _float_value(
            direct.get("disk_max_bytes", stationary_hold.get("max_terrain_artifact_disk_cache_bytes"))
        ),
        "disk_end_bytes": _float_value(
            direct.get("disk_end_bytes", stationary_hold.get("end_terrain_artifact_disk_cache_bytes"))
        ),
        "disk_max_byte_budget_ratio": _float_value(
            direct.get("disk_max_byte_budget_ratio", stationary_hold.get("max_terrain_artifact_disk_cache_byte_budget_ratio"))
        ),
        "disk_end_byte_budget_ratio": _float_value(
            direct.get("disk_end_byte_budget_ratio", stationary_hold.get("end_terrain_artifact_disk_cache_byte_budget_ratio"))
        ),
        "disk_eviction_delta": _float_value(
            direct.get("disk_eviction_delta", stationary_hold.get("terrain_artifact_disk_cache_eviction_delta"))
        ),
    }


def _stage_duration_ms_from_snapshot(stage_state: dict) -> float:
    started_usec = _int_value(stage_state.get("started_usec"))
    completed_usec = _int_value(stage_state.get("completed_usec"))
    if started_usec <= 0 or completed_usec <= started_usec:
        return 0.0
    return float(completed_usec - started_usec) / 1000.0


def _startup_stage_summary_from_snapshot(coordinator: dict) -> dict:
    stage_states = _as_dict(coordinator.get("stage_states"))
    if not stage_states:
        return {
            "stage_count": 0,
            "completed_stage_count": 0,
            "incomplete_stage_count": len(STARTUP_PROOF_STAGE_IDS),
            "missing_stage_count": len(STARTUP_PROOF_STAGE_IDS),
            "max_stage_duration_ms": 0.0,
            "slowest_stage_id": "",
        }

    completed_count = 0
    incomplete_count = 0
    missing_count = 0
    max_duration_ms = 0.0
    slowest_stage_id = ""
    for stage_id in STARTUP_PROOF_STAGE_IDS:
        stage_state = _as_dict(stage_states.get(stage_id))
        if not stage_state:
            missing_count += 1
            incomplete_count += 1
            continue
        if bool(stage_state.get("completed", False)):
            completed_count += 1
        else:
            incomplete_count += 1
        duration_ms = _stage_duration_ms_from_snapshot(stage_state)
        if duration_ms > max_duration_ms:
            max_duration_ms = duration_ms
            slowest_stage_id = stage_id

    return {
        "stage_count": len(stage_states),
        "completed_stage_count": completed_count,
        "incomplete_stage_count": incomplete_count,
        "missing_stage_count": missing_count,
        "max_stage_duration_ms": max_duration_ms,
        "slowest_stage_id": slowest_stage_id,
    }


def _startup_readiness_verdict_from_snapshot(data: dict) -> dict:
    direct = _as_dict(data.get("startup_readiness_verdict"))
    if direct:
        return {
            "available": bool(direct.get("available", False)),
            "completed": bool(direct.get("completed", False)),
            "loading_screen_available": bool(direct.get("loading_screen_available", False)),
            "startup_coordinator_available": bool(direct.get("startup_coordinator_available", False)),
            "loading_active": bool(direct.get("loading_active", False)),
            "failed": bool(direct.get("failed", False)),
            "cancelled": bool(direct.get("cancelled", False)),
            "playable_ready": bool(direct.get("playable_ready", False)),
            "world_monitor_completed": bool(direct.get("world_monitor_completed", False)),
            "progress_percent": _float_value(direct.get("progress_percent")),
            "elapsed_ms": _float_value(direct.get("elapsed_ms")),
            "completed_stage_count": _int_value(direct.get("completed_stage_count")),
            "incomplete_stage_count": _int_value(direct.get("incomplete_stage_count")),
            "missing_stage_count": _int_value(direct.get("missing_stage_count")),
            "max_stage_duration_ms": _float_value(direct.get("max_stage_duration_ms")),
            "trace_event_count": _int_value(direct.get("trace_event_count")),
            "stage": str(direct.get("stage", "")),
            "current_stage_id": str(direct.get("current_stage_id", "")),
            "current_stage_label": str(direct.get("current_stage_label", "")),
            "current_stage_progress_percent": _float_value(
                direct.get("current_stage_progress_percent", direct.get("progress_percent"))
            ),
            "current_stage_completed": _int_value(direct.get("current_stage_completed")),
            "current_stage_total": _int_value(direct.get("current_stage_total")),
            "stage_detail_text": str(direct.get("stage_detail_text", "")),
            "current_stage_details": _as_dict(direct.get("current_stage_details")),
            "slowest_stage_id": str(direct.get("slowest_stage_id", "")),
        }

    system_telemetry = _as_dict(data.get("system_telemetry"))
    loading_screen = _as_dict(system_telemetry.get("loading_screen"))
    coordinator = _as_dict(loading_screen.get("startup_coordinator"))
    if not coordinator:
        coordinator = _as_dict(system_telemetry.get("startup_coordinator"))
    stage_summary = _startup_stage_summary_from_snapshot(coordinator)
    trace = _as_dict(coordinator.get("trace"))
    loading_screen_available = bool(loading_screen)
    coordinator_available = bool(coordinator)
    loading_active = bool(loading_screen.get("is_loading", False))
    failed = bool(str(loading_screen.get("failure_message", "")))
    cancelled = bool(str(loading_screen.get("cancellation_message", "")))
    if coordinator_available:
        loading_active = loading_active or bool(coordinator.get("active", False)) or bool(coordinator.get("world_monitor_running", False))
        failed = failed or bool(coordinator.get("failed", False))
        cancelled = cancelled or bool(coordinator.get("cancelled", False))

    playable_ready = bool(loading_screen.get("terrain_ready_emitted", False))
    if coordinator_available:
        playable_ready = bool(coordinator.get("playable_ready", playable_ready))
    progress_percent = max(
        _float_value(loading_screen.get("progress_percent")),
        _float_value(coordinator.get("overall_progress_percent")),
    )
    elapsed_ms = _float_value(coordinator.get("elapsed_ms"))
    if elapsed_ms <= 0.0:
        elapsed_ms = _float_value(loading_screen.get("elapsed_seconds")) * 1000.0
    current_stage_label = str(coordinator.get("current_stage_label", loading_screen.get("stage_label", "")))
    current_stage_progress_percent = max(
        _float_value(loading_screen.get("stage_progress_percent")),
        _float_value(coordinator.get("current_stage_progress_percent")),
    )
    current_stage_completed = max(
        _int_value(loading_screen.get("stage_completed")),
        _int_value(coordinator.get("current_stage_completed")),
    )
    current_stage_total = max(
        _int_value(loading_screen.get("stage_total")),
        _int_value(coordinator.get("current_stage_total")),
    )
    current_stage_details = _as_dict(loading_screen.get("stage_details"))
    coordinator_stage_details = _as_dict(coordinator.get("current_stage_details"))
    if coordinator_stage_details:
        current_stage_details = coordinator_stage_details
    completed = (loading_screen_available or coordinator_available) and not loading_active and not failed and not cancelled
    if coordinator_available:
        completed = (
            completed
            and playable_ready
            and bool(coordinator.get("world_monitor_completed", False))
            and _int_value(stage_summary.get("incomplete_stage_count")) == 0
            and _int_value(stage_summary.get("missing_stage_count")) == 0
        )

    return {
        "available": loading_screen_available or coordinator_available,
        "completed": completed,
        "loading_screen_available": loading_screen_available,
        "startup_coordinator_available": coordinator_available,
        "loading_active": loading_active,
        "failed": failed,
        "cancelled": cancelled,
        "playable_ready": playable_ready,
        "world_monitor_completed": bool(coordinator.get("world_monitor_completed", False)),
        "progress_percent": progress_percent,
        "elapsed_ms": elapsed_ms,
        "completed_stage_count": _int_value(stage_summary.get("completed_stage_count")),
        "incomplete_stage_count": _int_value(stage_summary.get("incomplete_stage_count")),
        "missing_stage_count": _int_value(stage_summary.get("missing_stage_count")),
        "max_stage_duration_ms": _float_value(stage_summary.get("max_stage_duration_ms")),
        "trace_event_count": _int_value(trace.get("event_count")),
        "stage": str(loading_screen.get("stage", "")),
        "current_stage_id": str(coordinator.get("current_stage_id", "")),
        "current_stage_label": current_stage_label,
        "current_stage_progress_percent": current_stage_progress_percent,
        "current_stage_completed": current_stage_completed,
        "current_stage_total": current_stage_total,
        "stage_detail_text": str(loading_screen.get("stage_detail_text", "")),
        "current_stage_details": current_stage_details,
        "slowest_stage_id": str(stage_summary.get("slowest_stage_id", "")),
    }


def _compact_startup_stage_text(value: Any, max_len: int = 240) -> str:
    text = " ".join(str(value or "").split())
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."


def _startup_stage_failure_context(verdict: dict) -> str:
    stage_id = str(verdict.get("current_stage_id", "") or verdict.get("stage", "") or "unknown")
    label = _compact_startup_stage_text(verdict.get("current_stage_label", ""))
    progress = _float_value(verdict.get("current_stage_progress_percent", verdict.get("progress_percent")))
    completed = _int_value(verdict.get("current_stage_completed"))
    total = _int_value(verdict.get("current_stage_total"))
    detail = _compact_startup_stage_text(verdict.get("stage_detail_text", ""))
    details = _as_dict(verdict.get("current_stage_details"))
    if not detail and details:
        message = _compact_startup_stage_text(details.get("message", ""))
        blocker = _compact_startup_stage_text(details.get("blocking_component", ""))
        pending = _int_value(details.get("blocking_component_pending"))
        detail_parts = []
        if message:
            detail_parts.append(message)
        if blocker and pending > 0:
            detail_parts.append(f"blocked by {blocker} ({pending} pending)")
        elif blocker:
            detail_parts.append(f"blocked by {blocker}")
        detail = "; ".join(detail_parts)

    parts = [f"current={stage_id}"]
    if label:
        parts.append(f"label={label}")
    if progress > 0.0:
        parts.append(f"progress={progress:.1f}%")
    if total > 0:
        parts.append(f"items={completed}/{total}")
    if detail:
        parts.append(f"detail={detail}")
    return "; ".join(parts)


def _world_bake_proof_from_snapshot(data: dict) -> dict:
    direct = _as_dict(data.get("world_bake_proof"))
    if direct:
        return direct
    generation_telemetry = _as_dict(data.get("world_generation_telemetry"))
    proof = _as_dict(generation_telemetry.get("last_bake_proof"))
    if proof:
        return proof
    system_telemetry = _as_dict(data.get("system_telemetry"))
    telemetry_proof = _as_dict(_as_dict(system_telemetry.get("world_generator")).get("last_bake_proof"))
    if telemetry_proof:
        return telemetry_proof
    events = data.get("recent_scope_events", [])
    if isinstance(events, list):
        for event in events:
            event_dict = _as_dict(event)
            if str(event_dict.get("scope", "")) != "town_stall_test":
                continue
            if str(event_dict.get("label", "")) != "generation_complete":
                continue
            event_proof = _as_dict(_as_dict(event_dict.get("details")).get("bake_proof"))
            if event_proof:
                return event_proof
    return {}


def _world_bake_proof_verdict_from_snapshot(data: dict) -> dict:
    proof = _world_bake_proof_from_snapshot(data)
    if not proof:
        return {
            "available": False,
            "success": False,
            "save_success": False,
            "height_biome_backend": "",
            "baked_layer_count": 0,
            "expected_baked_layer_count": 0,
            "missing_layer_count": 0,
            "invalid_layer_count": 0,
            "content_signature": "",
            "export_cache_signature": "",
            "export_signature_file_written": False,
            "generation_total_ms": 0.0,
            "total_hash_ms": 0.0,
            "generation_unaccounted_ms": 0.0,
            "save_total_ms": 0.0,
        }
    save_profile = _as_dict(proof.get("save_profile"))
    generation_profile = _as_dict(proof.get("generation_profile"))
    missing_layers = proof.get("missing_layers", [])
    invalid_layers = proof.get("invalid_layers", [])
    return {
        "available": bool(proof.get("available", True)),
        "success": bool(proof.get("success", False)),
        "save_success": bool(save_profile.get("success", False)),
        "height_biome_backend": str(proof.get("height_biome_backend", generation_profile.get("height_biome_backend", ""))),
        "baked_layer_count": _int_value(proof.get("baked_layer_count")),
        "expected_baked_layer_count": _int_value(proof.get("expected_baked_layer_count")),
        "missing_layer_count": len(missing_layers) if isinstance(missing_layers, list) else 0,
        "invalid_layer_count": len(invalid_layers) if isinstance(invalid_layers, list) else 0,
        "content_signature": str(proof.get("content_signature", "")),
        "export_cache_signature": str(save_profile.get("cache_signature", "")),
        "export_signature_file_written": bool(save_profile.get("world_cache_signature_file_written", False)),
        "generation_total_ms": _float_value(proof.get("generation_total_ms", generation_profile.get("total_ms"))),
        "height_biome_ms": _float_value(generation_profile.get("height_biome_ms")),
        "layout_ms": _float_value(generation_profile.get("layout_ms")),
        "lakes_ms": _float_value(generation_profile.get("lakes_ms")),
        "finalize_ms": _float_value(generation_profile.get("finalize_ms")),
        "total_hash_ms": _float_value(proof.get("total_hash_ms")),
        "generation_unaccounted_ms": _float_value(proof.get("generation_unaccounted_ms")),
        "save_total_ms": _float_value(save_profile.get("total_ms")),
    }


def _print_snapshot_proof_summary(data: dict) -> None:
    startup = _startup_readiness_verdict_from_snapshot(data)
    world_bake = _world_bake_proof_verdict_from_snapshot(data)
    runtime_idle = _stationary_runtime_idle_verdict_from_snapshot(data)
    artifact_cache = _stationary_terrain_artifact_cache_verdict_from_snapshot(data)
    print(
        "Startup readiness proof: available={available} completed={completed} "
        "coordinator={coordinator} stages={stages}/{expected} progress={progress:.1f}% "
        "elapsed={elapsed:.1f}ms failed={failed} cancelled={cancelled}".format(
            available=startup["available"],
            completed=startup["completed"],
            coordinator=startup["startup_coordinator_available"],
            stages=startup["completed_stage_count"],
            expected=len(STARTUP_PROOF_STAGE_IDS),
            progress=startup["progress_percent"],
            elapsed=startup["elapsed_ms"],
            failed=startup["failed"],
            cancelled=startup["cancelled"],
        )
    )
    print(
        "World bake proof: available={available} success={success} backend={backend} "
        "layers={layers}/{expected} gen={generation:.1f}ms save={save:.1f}ms "
        "hash={hash_ms:.1f}ms sig={signature} export_sig={export_signature}".format(
            available=world_bake["available"],
            success=world_bake["success"],
            backend=world_bake["height_biome_backend"] or "unknown",
            layers=world_bake["baked_layer_count"],
            expected=world_bake["expected_baked_layer_count"],
            generation=world_bake["generation_total_ms"],
            save=world_bake["save_total_ms"],
            hash_ms=world_bake["total_hash_ms"],
            signature=world_bake["content_signature"][:12],
            export_signature=world_bake["export_cache_signature"][:12],
        )
    )
    print(
        "Runtime idle proof: samples={samples} idle_ratio={idle_ratio:.3f} "
        "max_pending={pending:.1f} max_awake={awake:.1f} busy={busy}".format(
            samples=runtime_idle["monitor_available_samples"],
            idle_ratio=runtime_idle["idle_sample_ratio"],
            pending=runtime_idle["max_pending_work"],
            awake=runtime_idle["max_awake_process_count"],
            busy=runtime_idle["busy_samples"],
        )
    )
    print(
        "Terrain artifact cache proof: samples={samples} end_hit={hit:.3f} "
        "entries={entries:.0f} budget_max={budget:.3f} evict_delta={evict:.0f} "
        "disk_delta={disk_delta:.0f} disk_budget_max={disk_budget:.3f} disk_evict_delta={disk_evict:.0f}".format(
            samples=artifact_cache["monitor_available_samples"],
            hit=artifact_cache["end_hit_ratio"],
            entries=artifact_cache["end_entries"],
            budget=artifact_cache["max_byte_budget_ratio"],
            evict=artifact_cache["eviction_delta"],
            disk_delta=artifact_cache["disk_hit_delta"],
            disk_budget=artifact_cache["disk_max_byte_budget_ratio"],
            disk_evict=artifact_cache["disk_eviction_delta"],
        )
    )


def _snapshot_startup_readiness_proof_failures(data: dict) -> list[str]:
    enforced = (
        _bool_from_env("TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF")
        or os.environ.get("TOWN_STALL_MIN_STARTUP_COMPLETED_STAGES", "").strip() != ""
        or _optional_float_from_env("TOWN_STALL_MAX_STARTUP_ELAPSED_MS") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_STARTUP_STAGE_MS") is not None
        or _optional_float_from_env("TOWN_STALL_MIN_STARTUP_TRACE_EVENTS") is not None
    )
    if not enforced:
        return []

    verdict = _startup_readiness_verdict_from_snapshot(data)
    failures: list[str] = []
    min_completed_stages = _positive_int_from_env("TOWN_STALL_MIN_STARTUP_COMPLETED_STAGES", len(STARTUP_PROOF_STAGE_IDS))
    max_elapsed_ms = _optional_float_from_env("TOWN_STALL_MAX_STARTUP_ELAPSED_MS")
    max_stage_ms = _optional_float_from_env("TOWN_STALL_MAX_STARTUP_STAGE_MS")
    min_trace_events = _optional_float_from_env("TOWN_STALL_MIN_STARTUP_TRACE_EVENTS")

    if not bool(verdict["available"]):
        failures.append("startup readiness telemetry missing")
    if _bool_from_env("TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF") and not bool(verdict["startup_coordinator_available"]):
        failures.append("startup coordinator telemetry missing")
    if _bool_from_env("TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF") and not bool(verdict["completed"]):
        failures.append("startup readiness did not complete")
    if bool(verdict["loading_active"]):
        failures.append("startup loading still active")
    if bool(verdict["failed"]):
        failures.append("startup reported failure")
    if bool(verdict["cancelled"]):
        failures.append("startup reported cancellation")
    if _bool_from_env("TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF") and not bool(verdict["playable_ready"]):
        failures.append("startup playable-ready signal missing")
    if int(verdict["completed_stage_count"]) < min_completed_stages:
        failures.append(f"startup completed stages {int(verdict['completed_stage_count'])} below {min_completed_stages}")
    if int(verdict["missing_stage_count"]) > 0:
        failures.append(f"startup missing stage telemetry count {int(verdict['missing_stage_count'])}")
    if int(verdict["incomplete_stage_count"]) > 0:
        failures.append(f"startup incomplete stage count {int(verdict['incomplete_stage_count'])}")
    if max_elapsed_ms is not None and float(verdict["elapsed_ms"]) > max_elapsed_ms:
        failures.append(f"startup elapsed {float(verdict['elapsed_ms']):.3f} ms exceeds {max_elapsed_ms:.3f} ms")
    if max_stage_ms is not None and float(verdict["max_stage_duration_ms"]) > max_stage_ms:
        failures.append(
            "startup max stage duration "
            f"{float(verdict['max_stage_duration_ms']):.3f} ms exceeds {max_stage_ms:.3f} ms"
        )
    if min_trace_events is not None and float(verdict["trace_event_count"]) + 0.000001 < min_trace_events:
        failures.append(f"startup trace events {int(verdict['trace_event_count'])} below {int(min_trace_events)}")
    stage_context = _startup_stage_failure_context(verdict)
    if failures and stage_context:
        failures.append(f"startup active stage: {stage_context}")
    return failures


def _snapshot_world_bake_proof_failures(data: dict) -> list[str]:
    enforced = (
        _bool_from_env("TOWN_STALL_REQUIRE_WORLD_BAKE_PROOF")
        or _bool_from_env("TOWN_STALL_REQUIRE_WORLD_BAKE_EXPORT_SIGNATURE")
        or os.environ.get("TOWN_STALL_REQUIRE_WORLD_BAKE_HEIGHT_BIOME_BACKEND", "").strip() != ""
        or os.environ.get("TOWN_STALL_MIN_WORLD_BAKE_LAYERS", "").strip() != ""
        or _optional_float_from_env("TOWN_STALL_MAX_WORLD_BAKE_MS") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_WORLD_BAKE_HASH_MS") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_WORLD_BAKE_UNACCOUNTED_MS") is not None
    )
    if not enforced:
        return []

    verdict = _world_bake_proof_verdict_from_snapshot(data)
    failures: list[str] = []
    min_layers = _positive_int_from_env(
        "TOWN_STALL_MIN_WORLD_BAKE_LAYERS",
        max(5, int(verdict["expected_baked_layer_count"])),
    )
    if _bool_from_env("TOWN_STALL_REQUIRE_WORLD_BAKE_PROOF") and not bool(verdict["available"]):
        failures.append("world bake proof missing")
    if _bool_from_env("TOWN_STALL_REQUIRE_WORLD_BAKE_PROOF") and not bool(verdict["success"]):
        failures.append("world bake proof did not succeed")
    if int(verdict["baked_layer_count"]) < min_layers:
        failures.append(f"world bake layer count {int(verdict['baked_layer_count'])} below {min_layers}")
    if int(verdict["missing_layer_count"]) > 0:
        failures.append(f"world bake missing layer count {int(verdict['missing_layer_count'])}")
    if int(verdict["invalid_layer_count"]) > 0:
        failures.append(f"world bake invalid layer count {int(verdict['invalid_layer_count'])}")
    if not str(verdict["content_signature"]):
        failures.append("world bake content signature missing")

    required_backend = os.environ.get("TOWN_STALL_REQUIRE_WORLD_BAKE_HEIGHT_BIOME_BACKEND", "").strip()
    if required_backend and str(verdict["height_biome_backend"]) != required_backend:
        failures.append(
            "world bake height/biome backend "
            f"{verdict['height_biome_backend']} does not match {required_backend}"
        )

    if _bool_from_env("TOWN_STALL_REQUIRE_WORLD_BAKE_EXPORT_SIGNATURE"):
        if not bool(verdict["save_success"]):
            failures.append("world bake save profile did not report success")
        if not str(verdict["export_cache_signature"]):
            failures.append("world bake export cache signature missing")
        if not bool(verdict["export_signature_file_written"]):
            failures.append("world bake export signature file was not written")

    max_generation_ms = _optional_float_from_env("TOWN_STALL_MAX_WORLD_BAKE_MS")
    if max_generation_ms is not None and float(verdict["generation_total_ms"]) > max_generation_ms:
        failures.append(
            "world bake generation total "
            f"{float(verdict['generation_total_ms']):.3f} ms exceeds {max_generation_ms:.3f} ms"
        )
    max_hash_ms = _optional_float_from_env("TOWN_STALL_MAX_WORLD_BAKE_HASH_MS")
    if max_hash_ms is not None and float(verdict["total_hash_ms"]) > max_hash_ms:
        failures.append(
            "world bake proof hash time "
            f"{float(verdict['total_hash_ms']):.3f} ms exceeds {max_hash_ms:.3f} ms"
        )
    max_unaccounted_ms = _optional_float_from_env("TOWN_STALL_MAX_WORLD_BAKE_UNACCOUNTED_MS")
    if max_unaccounted_ms is not None and float(verdict["generation_unaccounted_ms"]) > max_unaccounted_ms:
        failures.append(
            "world bake unaccounted generation time "
            f"{float(verdict['generation_unaccounted_ms']):.3f} ms exceeds {max_unaccounted_ms:.3f} ms"
        )
    return failures


def _snapshot_runtime_idle_proof_failures(data: dict) -> list[str]:
    enforced = (
        _bool_from_env("TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF")
        or _optional_float_from_env("TOWN_STALL_MIN_RUNTIME_IDLE_RATIO") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_RUNTIME_PENDING_WORK") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_RUNTIME_AWAKE_PROCESS_COUNT") is not None
    )
    if not enforced:
        return []

    verdict = _stationary_runtime_idle_verdict_from_snapshot(data)
    failures: list[str] = []
    sample_count = int(verdict["monitor_available_samples"])
    min_samples = _positive_int_from_env("TOWN_STALL_MIN_RUNTIME_IDLE_PROOF_SAMPLES", 1)
    min_idle_ratio = _optional_float_from_env("TOWN_STALL_MIN_RUNTIME_IDLE_RATIO")
    if min_idle_ratio is None:
        min_idle_ratio = 1.0
    max_pending_work = _optional_float_from_env("TOWN_STALL_MAX_RUNTIME_PENDING_WORK")
    if max_pending_work is None:
        max_pending_work = 0.0
    max_awake_process_count = _optional_float_from_env("TOWN_STALL_MAX_RUNTIME_AWAKE_PROCESS_COUNT")
    if max_awake_process_count is None:
        max_awake_process_count = 0.0

    if sample_count < min_samples:
        failures.append(f"runtime idle monitor samples {sample_count} below {min_samples}")
    if float(verdict["idle_sample_ratio"]) + 0.000001 < min_idle_ratio:
        failures.append(
            "runtime idle sample ratio "
            f"{float(verdict['idle_sample_ratio']):.3f} below {min_idle_ratio:.3f}"
        )
    if float(verdict["max_pending_work"]) > max_pending_work:
        failures.append(
            "runtime max pending work "
            f"{float(verdict['max_pending_work']):.3f} exceeds {max_pending_work:.3f}"
        )
    if float(verdict["max_awake_process_count"]) > max_awake_process_count:
        failures.append(
            "runtime max awake process count "
            f"{float(verdict['max_awake_process_count']):.3f} exceeds {max_awake_process_count:.3f}"
        )
    return failures


def _snapshot_terrain_artifact_cache_proof_failures(data: dict) -> list[str]:
    enforced = (
        _bool_from_env("TOWN_STALL_REQUIRE_TERRAIN_ARTIFACT_CACHE_PROOF")
        or _optional_float_from_env("TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_HIT_RATIO") is not None
        or _optional_float_from_env("TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_DISK_HIT_DELTA") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_BYTE_BUDGET_RATIO") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_EVICTION_DELTA") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_BYTE_BUDGET_RATIO") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_EVICTION_DELTA") is not None
    )
    if not enforced:
        return []

    verdict = _stationary_terrain_artifact_cache_verdict_from_snapshot(data)
    failures: list[str] = []
    sample_count = int(verdict["monitor_available_samples"])
    min_samples = _positive_int_from_env("TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_PROOF_SAMPLES", 1)
    min_hit_ratio = _optional_float_from_env("TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_HIT_RATIO")
    min_disk_hit_delta = _optional_float_from_env("TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_DISK_HIT_DELTA")
    max_byte_budget_ratio = _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_BYTE_BUDGET_RATIO")
    max_eviction_delta = _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_EVICTION_DELTA")
    max_disk_byte_budget_ratio = _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_BYTE_BUDGET_RATIO")
    max_disk_eviction_delta = _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_EVICTION_DELTA")

    if sample_count < min_samples:
        failures.append(f"terrain artifact cache monitor samples {sample_count} below {min_samples}")
    if min_hit_ratio is not None and float(verdict["end_hit_ratio"]) + 0.000001 < min_hit_ratio:
        failures.append(
            "terrain artifact cache ending hit ratio "
            f"{float(verdict['end_hit_ratio']):.3f} below {min_hit_ratio:.3f}"
        )
    if min_disk_hit_delta is not None and float(verdict["disk_hit_delta"]) + 0.000001 < min_disk_hit_delta:
        failures.append(
            "terrain artifact cache disk-hit delta "
            f"{float(verdict['disk_hit_delta']):.3f} below {min_disk_hit_delta:.3f}"
        )
    if max_byte_budget_ratio is not None and float(verdict["max_byte_budget_ratio"]) > max_byte_budget_ratio:
        failures.append(
            "terrain artifact memory cache max byte-budget ratio "
            f"{float(verdict['max_byte_budget_ratio']):.3f} exceeds {max_byte_budget_ratio:.3f}"
        )
    if max_eviction_delta is not None and float(verdict["eviction_delta"]) > max_eviction_delta:
        failures.append(
            "terrain artifact memory cache eviction delta "
            f"{float(verdict['eviction_delta']):.3f} exceeds {max_eviction_delta:.3f}"
        )
    if max_disk_byte_budget_ratio is not None and float(verdict["disk_max_byte_budget_ratio"]) > max_disk_byte_budget_ratio:
        failures.append(
            "terrain artifact disk cache max byte-budget ratio "
            f"{float(verdict['disk_max_byte_budget_ratio']):.3f} exceeds {max_disk_byte_budget_ratio:.3f}"
        )
    if max_disk_eviction_delta is not None and float(verdict["disk_eviction_delta"]) > max_disk_eviction_delta:
        failures.append(
            "terrain artifact disk cache eviction delta "
            f"{float(verdict['disk_eviction_delta']):.3f} exceeds {max_disk_eviction_delta:.3f}"
        )
    return failures


def _snapshot_proof_gates_requested() -> bool:
    return (
        _bool_from_env("TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF")
        or os.environ.get("TOWN_STALL_MIN_STARTUP_COMPLETED_STAGES", "").strip() != ""
        or _optional_float_from_env("TOWN_STALL_MAX_STARTUP_ELAPSED_MS") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_STARTUP_STAGE_MS") is not None
        or _optional_float_from_env("TOWN_STALL_MIN_STARTUP_TRACE_EVENTS") is not None
        or _bool_from_env("TOWN_STALL_REQUIRE_WORLD_BAKE_PROOF")
        or _bool_from_env("TOWN_STALL_REQUIRE_WORLD_BAKE_EXPORT_SIGNATURE")
        or os.environ.get("TOWN_STALL_REQUIRE_WORLD_BAKE_HEIGHT_BIOME_BACKEND", "").strip() != ""
        or os.environ.get("TOWN_STALL_MIN_WORLD_BAKE_LAYERS", "").strip() != ""
        or _optional_float_from_env("TOWN_STALL_MAX_WORLD_BAKE_MS") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_WORLD_BAKE_HASH_MS") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_WORLD_BAKE_UNACCOUNTED_MS") is not None
        or _bool_from_env("TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF")
        or _optional_float_from_env("TOWN_STALL_MIN_RUNTIME_IDLE_RATIO") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_RUNTIME_PENDING_WORK") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_RUNTIME_AWAKE_PROCESS_COUNT") is not None
        or _bool_from_env("TOWN_STALL_REQUIRE_TERRAIN_ARTIFACT_CACHE_PROOF")
        or _optional_float_from_env("TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_HIT_RATIO") is not None
        or _optional_float_from_env("TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_DISK_HIT_DELTA") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_BYTE_BUDGET_RATIO") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_EVICTION_DELTA") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_BYTE_BUDGET_RATIO") is not None
        or _optional_float_from_env("TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_EVICTION_DELTA") is not None
    )


def _snapshot_proof_gate_failures(snapshot_path: Path) -> list[str]:
    if not _snapshot_proof_gates_requested():
        return []

    try:
        data = json.loads(snapshot_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return [f"could not parse snapshot proof verdicts: {exc}"]

    failures: list[str] = []
    failures.extend(_snapshot_startup_readiness_proof_failures(data))
    failures.extend(_snapshot_world_bake_proof_failures(data))
    failures.extend(_snapshot_runtime_idle_proof_failures(data))
    failures.extend(_snapshot_terrain_artifact_cache_proof_failures(data))
    return failures


def _snapshot_rendering_failures(snapshot_path: Path) -> list[str]:
    try:
        data = json.loads(snapshot_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return [f"could not parse snapshot render features: {exc}"]

    render_features = data.get("render_features", {})
    if not isinstance(render_features, dict):
        return ["snapshot render features missing"]

    reasons: list[str] = []
    rendering_method = str(render_features.get("rendering_method", "")).strip().lower()
    rendering_driver = str(render_features.get("rendering_driver_name", "")).strip().lower()
    if rendering_method and rendering_method != GODOT_RENDERING_METHOD:
        reasons.append(f"runtime rendering method {rendering_method!r} is not {GODOT_RENDERING_METHOD!r}")
    if rendering_driver and rendering_driver != GODOT_RENDERING_DRIVER:
        reasons.append(f"runtime rendering driver {rendering_driver!r} is not {GODOT_RENDERING_DRIVER!r}")
    if not rendering_method:
        reasons.append("runtime rendering method was not reported")
    if not rendering_driver:
        reasons.append("runtime rendering driver was not reported")
    return reasons


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
    for line in lowered.splitlines():
        if "low-fps safety abort:" in line and " over " in line and "ms/frame" in line:
            reasons.append("low-FPS safety abort triggered")
            break
    if "[town_stall_test] hold started" not in lowered:
        reasons.append("town hold never started")
    if returncode is not None and returncode != 0:
        reasons.append(f"process exited with code {returncode}")
    return reasons


def main() -> int:
    suppress_windows_error_dialogs()
    if not _acquire_run_lock():
        print("ERROR: Another town stall benchmark launcher is already running.")
        print("Close the existing launcher before starting a new one.")
        return 2

    print("Running Town Stall Automation Test...")
    print(f"   Scene: {MAIN_SCENE}")
    print(f"   Runtime mode: {_runtime_mode_label()} ({Path(GODOT_BIN).name})")
    print(f"   Rendering: {GODOT_RENDERING_METHOD} / {GODOT_RENDERING_DRIVER}")
    print(f"   Godot APPDATA: {TOWN_STALL_APPDATA_DIR}")
    exported_runtime = os.environ.get("TOWN_STALL_EXPORTED_RUNTIME", "0") == "1"
    if exported_runtime:
        print("   Runtime launch: embedded exported project")
    display_args = _godot_display_args_from_env()
    if display_args:
        print(f"   Display args: {' '.join(display_args)}")
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
    for sample_path in [SYSTEM_SAMPLE_FILE, SYSTEM_SAMPLE_SUMMARY_FILE]:
        if sample_path.exists():
            try:
                sample_path.unlink()
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
        "--rendering-driver",
        GODOT_RENDERING_DRIVER,
        "--rendering-method",
        GODOT_RENDERING_METHOD,
        "--log-file",
        str(LOG_FILE),
    ]
    if not exported_runtime:
        cmd.extend([
            "--path",
            PROJECT_PATH,
            MAIN_SCENE,
        ])
    if display_args:
        cmd[1:1] = display_args

    env = os.environ.copy()
    env["APPDATA"] = str(TOWN_STALL_APPDATA_DIR)
    env["TOWN_STALL_SEED"] = os.environ.get("TOWN_STALL_SEED", "12345")
    env["TOWN_STALL_AUTO_TELEPORT"] = os.environ.get("TOWN_STALL_AUTO_TELEPORT", "0")
    default_measure_full_flight = "0" if env["TOWN_STALL_AUTO_TELEPORT"] != "0" else "1"
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
    env["TOWN_STALL_DISABLE_TERRAIN_MANAGER_VISUALS"] = os.environ.get("TOWN_STALL_DISABLE_TERRAIN_MANAGER_VISUALS", "0")
    env["TOWN_STALL_DISABLE_VEGETATION_RENDER"] = os.environ.get("TOWN_STALL_DISABLE_VEGETATION_RENDER", "0")
    env["TOWN_STALL_DISABLE_ENTITIES"] = os.environ.get("TOWN_STALL_DISABLE_ENTITIES", "0")
    env["TOWN_STALL_DISABLE_EXIT_AUTOSAVE"] = os.environ.get("TOWN_STALL_DISABLE_EXIT_AUTOSAVE", "1")
    env["TOWN_STALL_HOLD_SECONDS"] = os.environ.get("TOWN_STALL_HOLD_SECONDS", "")
    env["TOWN_STALL_MAX_FPS"] = os.environ.get("TOWN_STALL_MAX_FPS", "")
    env["TOWN_STALL_MEASURE_FULL_FLIGHT"] = os.environ.get("TOWN_STALL_MEASURE_FULL_FLIGHT", default_measure_full_flight)
    env["TOWN_STALL_RUNTIME_MODE"] = _runtime_mode_label()
    machine_warmup_disabled = os.environ.get("TOWN_STALL_MACHINE_WARMUP_DISABLED", "1") == "1"
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

    configured_hold_seconds = _positive_float_from_env("TOWN_STALL_HOLD_SECONDS", 40.0)
    timeout = _positive_int_from_env("TOWN_STALL_TIMEOUT_SECONDS", max(DEFAULT_TIMEOUT, int(configured_hold_seconds + 300.0)))
    system_sample_interval_seconds = _positive_float_from_env("TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS", 0.0)
    postrun_idle_check_disabled = os.environ.get("TOWN_STALL_DISABLE_POSTRUN_IDLE_CHECK", "0") == "1"
    postrun_idle_delay_seconds = _float_from_env("TOWN_STALL_POSTRUN_IDLE_DELAY_SECONDS", 2.0)
    postrun_idle_sample_count = _positive_int_from_env("TOWN_STALL_POSTRUN_IDLE_SAMPLE_COUNT", 3)
    postrun_idle_sample_interval_seconds = _positive_float_from_env("TOWN_STALL_POSTRUN_IDLE_SAMPLE_INTERVAL_SECONDS", 1.0)
    postrun_idle_settle_timeout_seconds = _float_from_env("TOWN_STALL_POSTRUN_IDLE_SETTLE_TIMEOUT_SECONDS", 30.0)
    preflight_idle_sample_count = _positive_int_from_env("TOWN_STALL_PREFLIGHT_IDLE_SAMPLE_COUNT", 3)
    preflight_idle_sample_interval_seconds = _positive_float_from_env("TOWN_STALL_PREFLIGHT_IDLE_SAMPLE_INTERVAL_SECONDS", 1.0)
    preflight_idle_retry_timeout_seconds = _float_from_env("TOWN_STALL_PREFLIGHT_IDLE_RETRY_TIMEOUT_SECONDS", 0.0)
    preflight_idle_retry_poll_seconds = _positive_float_from_env("TOWN_STALL_PREFLIGHT_IDLE_RETRY_POLL_SECONDS", 10.0)

    preflight_idle_samples, preflight_reasons, preflight_idle_retry = _collect_preflight_idle_until_clean(
        preflight_idle_sample_count,
        preflight_idle_sample_interval_seconds,
        preflight_idle_retry_timeout_seconds,
        preflight_idle_retry_poll_seconds,
    )
    raw_gpu_preflight: dict = {}
    preflight_idle_summary = _summarize_preflight_idle_samples(preflight_idle_samples)
    if preflight_idle_samples:
        last_preflight_sample = preflight_idle_samples[-1]
        sampled_machine = last_preflight_sample.get("machine", {})
        if isinstance(sampled_machine, dict) and sampled_machine:
            warmup_state = machine_state.get("warmup_state", "unknown")
            warmup_note = machine_state.get("warmup_note", "")
            warmup_gate = machine_state.get("warmup_gate", {})
            machine_state = sampled_machine
            machine_state["warmup_state"] = warmup_state
            machine_state["warmup_note"] = warmup_note
            if warmup_gate:
                machine_state["warmup_gate"] = warmup_gate
        sampled_raw_gpu = last_preflight_sample.get("raw_gpu", {})
        if isinstance(sampled_raw_gpu, dict):
            raw_gpu_preflight = sampled_raw_gpu
    else:
        raw_gpu_preflight = _collect_raw_gpu_state()
    machine_state["preflight_idle_summary"] = preflight_idle_summary
    machine_state["preflight_idle_retry"] = preflight_idle_retry
    env["TOWN_STALL_MACHINE_STATE_JSON"] = json.dumps(machine_state)

    print("\nMachine state probe:")
    _print_machine_state_summary(machine_state)
    print(f"Raw GPU preflight: {_raw_gpu_state_summary(raw_gpu_preflight)}")
    _print_preflight_idle_sample_summary(preflight_idle_summary)

    allow_contaminated_idle = os.environ.get("TOWN_STALL_ALLOW_CONTAMINATED_IDLE", "0") == "1"
    if preflight_reasons and not allow_contaminated_idle:
        print("ERROR: Preflight idle state is contaminated; refusing to launch town benchmark.")
        for reason in preflight_reasons:
            print(f"  - {reason}")
        _print_top_cpu_processes(_collect_top_cpu_processes())
        print("Close unrelated CPU/GPU work or set TOWN_STALL_ALLOW_CONTAMINATED_IDLE=1 to run anyway.")
        return 3
    if preflight_reasons:
        print("WARNING: Running despite contaminated preflight idle state because TOWN_STALL_ALLOW_CONTAMINATED_IDLE=1.")
        for reason in preflight_reasons:
            print(f"  - {reason}")

    running_processes = _find_running_godot_processes()
    if running_processes:
        print("ERROR: A Godot process is already running.")
        print("Close the existing Godot instance before starting a new town test.")
        for process in running_processes[:5]:
            process_id = int(process.get("ProcessId", 0) or 0)
            process_name = str(process.get("Name", "godot"))
            print(f"  PID {process_id} - {process_name}")
            command_line = str(process.get("CommandLine", "")).strip()
            if command_line:
                print(f"    {command_line}")
        return 2

    system_sample_stop: Optional[threading.Event] = None
    system_sample_thread: Optional[threading.Thread] = None
    system_sample_summary: dict = {}
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            cwd=PROJECT_PATH,
        )
        if system_sample_interval_seconds > 0.0:
            system_sample_stop = threading.Event()
            system_sample_thread = threading.Thread(
                target=_sample_system_until,
                args=(system_sample_stop, int(proc.pid), system_sample_interval_seconds, SYSTEM_SAMPLE_FILE),
                daemon=True,
            )
            system_sample_thread.start()
        returncode = proc.returncode
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
            returncode = proc.returncode
        except subprocess.TimeoutExpired:
            print(f"WARNING: Timeout after {timeout}s (bot may still be running)")
            proc.kill()
            stdout, stderr = proc.communicate()
            returncode = proc.returncode
        finally:
            if system_sample_stop is not None:
                system_sample_stop.set()
            if system_sample_thread is not None:
                system_sample_thread.join(timeout=max(5.0, system_sample_interval_seconds + 5.0))
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

    postrun_idle_summary: dict = {}
    postrun_idle_reasons: list[str] = []
    if not postrun_idle_check_disabled:
        postrun_idle_samples, postrun_idle_reasons, postrun_idle_settle = _collect_postrun_idle_state_samples(
            postrun_idle_delay_seconds,
            postrun_idle_sample_count,
            postrun_idle_sample_interval_seconds,
            postrun_idle_settle_timeout_seconds,
        )
        postrun_idle_summary = _summarize_system_sample_list(postrun_idle_samples)
        postrun_idle_summary["settle"] = postrun_idle_settle

    if system_sample_interval_seconds > 0.0:
        system_sample_summary = _summarize_system_samples(SYSTEM_SAMPLE_FILE)
        if postrun_idle_summary:
            system_sample_summary["postrun_idle"] = postrun_idle_summary
            system_sample_summary["postrun_idle_reasons"] = postrun_idle_reasons
        try:
            SYSTEM_SAMPLE_SUMMARY_FILE.write_text(json.dumps(system_sample_summary, indent=2), encoding="utf-8")
        except OSError:
            pass

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

    if system_sample_interval_seconds > 0.0:
        _print_system_sample_summary(system_sample_summary)
    if postrun_idle_summary:
        print("Post-run idle check:")
        _print_system_sample_summary(postrun_idle_summary)
        if postrun_idle_reasons:
            print("  Contamination:")
            for reason in postrun_idle_reasons:
                print(f"    - {reason}")

    failure_reasons = _detect_run_failure(output, returncode)
    if postrun_idle_reasons and not allow_contaminated_idle:
        failure_reasons.extend([f"postrun idle contaminated: {reason}" for reason in postrun_idle_reasons])
    snapshot = _latest_snapshot(run_start_mtime - 1.0)
    hold_started = "[town_stall_test] hold started" in output.lower()
    hold_completed = "[town_stall_test] hold complete, quitting" in output.lower()
    shutdown_av = returncode == 3221225477
    if shutdown_av and snapshot and hold_started and hold_completed:
        print("WARNING: Godot exited with an access violation during shutdown after completing the benchmark; treating this as non-fatal because the hold finished and a snapshot was written.")
        failure_reasons = [reason for reason in failure_reasons if reason != f"process exited with code {returncode}"]
    if snapshot:
        if system_sample_interval_seconds > 0.0:
            system_sample_summary = _attach_phase_system_sample_summary(system_sample_summary, SYSTEM_SAMPLE_FILE, snapshot)
            try:
                SYSTEM_SAMPLE_SUMMARY_FILE.write_text(json.dumps(system_sample_summary, indent=2), encoding="utf-8")
            except OSError:
                pass
            _persist_system_sample_summary_to_snapshot(snapshot, system_sample_summary)
            _print_phase_system_sample_summary(system_sample_summary)
        _print_snapshot_summary(snapshot)
        failure_reasons.extend(_snapshot_rendering_failures(snapshot))
        failure_reasons.extend(_snapshot_proof_gate_failures(snapshot))
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
