import argparse
import json
import os
import subprocess
import sys
import threading
import time
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

import run_town_stall_test as town_runner


PROJECT_PATH = Path(__file__).resolve().parents[2]
OUTPUT_DIR = PROJECT_PATH / ".agent" / "gpu-telemetry"
PYTHON_BIN = sys.executable
NVIDIA_SMI = "nvidia-smi"

GPU_QUERY_FIELDS = [
    "timestamp",
    "pstate",
    "power.draw",
    "temperature.gpu",
    "clocks.gr",
    "clocks.mem",
    "utilization.gpu",
    "utilization.memory",
]

CASE_DEFINITIONS = {
    "fixed60": {
        "description": "Fixed 60 FPS cap, runtime power manager disabled.",
        "env": {
            "TOWN_STALL_MAX_FPS": "60",
            "TOWN_STALL_DISABLE_RUNTIME_POWER_MODE": "1",
        },
    },
    "fixed70": {
        "description": "Fixed 70 FPS cap, runtime power manager disabled.",
        "env": {
            "TOWN_STALL_MAX_FPS": "70",
            "TOWN_STALL_DISABLE_RUNTIME_POWER_MODE": "1",
        },
    },
    "runtime_default": {
        "description": "Runtime power manager defaults: 60 active, 30 idle, 15 deep idle.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
        },
    },
    "runtime_gpu_meshing": {
        "description": "Runtime power manager with legacy GPU terrain meshing.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_TERRAIN_NATIVE_CPU_MESHING": "0",
        },
    },
    "runtime_native_cpu_meshing": {
        "description": "Runtime power manager with density readback and native CPU terrain meshing.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_TERRAIN_NATIVE_CPU_MESHING": "1",
        },
    },
    "runtime_no_streaming_batch_async": {
        "description": "Runtime defaults with terrain visual batch async queueing during streaming disabled.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_TERRAIN_BATCH_STREAMING_ASYNC": "0",
        },
    },
    "runtime_no_render_suspend": {
        "description": "Runtime power manager defaults with deep-idle render-loop suspension disabled.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_SUSPEND_RENDER_LOOP": "0",
        },
    },
    "runtime_fast_deep_idle": {
        "description": "Runtime power manager with faster deep-idle entry after all activity stops.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_DELAY_S": "2.5",
        },
    },
    "runtime_no_terrain_stream": {
        "description": "Runtime power manager with terrain chunk updates disabled for moving terrain-work isolation.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_DISABLE_TERRAIN_CHUNK_UPDATES": "1",
        },
    },
    "runtime_no_glow": {
        "description": "Runtime power manager with scene glow disabled for render-power isolation.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_DISABLE_GLOW": "1",
        },
    },
    "runtime_no_water_render": {
        "description": "Runtime power manager with water mesh rendering disabled for render-power isolation.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_DISABLE_WATER_RENDER": "1",
        },
    },
    "runtime_joined_water_submit": {
        "description": "Runtime power manager with terrain and water meshing submitted together.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_TERRAIN_GPU_SEPARATE_WATER_MESHING": "0",
        },
    },
    "runtime_separate_water_submit": {
        "description": "Runtime power manager with terrain and water meshing submitted/read back separately.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_TERRAIN_GPU_SEPARATE_WATER_MESHING": "1",
        },
    },
    "runtime_mesh_slices_1": {
        "description": "Runtime power manager with terrain GPU meshing in one Y slice.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_TERRAIN_GPU_MESH_SLICES": "1",
        },
    },
    "runtime_mesh_slices_2": {
        "description": "Runtime power manager with terrain GPU meshing split into two Y slices.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_TERRAIN_GPU_MESH_SLICES": "2",
        },
    },
}

RESET_ENV_KEYS = [
    "TOWN_STALL_MAX_FPS",
    "TOWN_STALL_DISABLE_RUNTIME_POWER_MODE",
    "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE",
    "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS",
    "TOWN_STALL_RUNTIME_POWER_IDLE_FPS",
    "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS",
    "TOWN_STALL_RUNTIME_POWER_IDLE_DELAY_S",
    "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_DELAY_S",
    "TOWN_STALL_RUNTIME_POWER_ACTIVE_GRACE_S",
    "TOWN_STALL_RUNTIME_POWER_SUSPEND_RENDER_LOOP",
    "TOWN_STALL_TERRAIN_GPU_SEPARATE_WATER_MESHING",
    "TOWN_STALL_TERRAIN_GPU_MESH_SLICES",
    "TOWN_STALL_TERRAIN_GPU_MESH_SLICE_DELAY_MS",
    "TOWN_STALL_TERRAIN_NATIVE_CPU_MESHING",
    "TOWN_STALL_TERRAIN_BATCH_STREAMING_ASYNC",
    "TOWN_STALL_TERRAIN_BATCH_STREAMING_ASYNC_QUEUE",
    "TOWN_STALL_SHARED_TERRAIN_COLLISION_CREATE_BUDGET",
    "TOWN_STALL_DISABLE_TERRAIN_CHUNK_UPDATES",
    "TOWN_STALL_DISABLE_GLOW",
    "TOWN_STALL_DISABLE_WATER_RENDER",
]


def _timestamp_slug() -> str:
    return datetime.now().strftime("%Y%m%d_%H%M%S")


def _parse_float(value: str) -> Optional[float]:
    value = value.strip()
    if not value or value.upper() == "N/A":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def _query_gpu_sample(phase: str) -> dict[str, Any]:
    query = ",".join(GPU_QUERY_FIELDS)
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
    raw_output = (result.stdout or "").strip()
    first_line = raw_output.splitlines()[0].strip() if raw_output else ""
    parts = [part.strip() for part in first_line.split(",")]
    sample: dict[str, Any] = {
        "phase": phase,
        "time": time.time(),
        "returncode": result.returncode,
        "raw": first_line,
    }
    if result.returncode != 0:
        sample["error"] = (result.stderr or "").strip()
        return sample
    if len(parts) < len(GPU_QUERY_FIELDS):
        sample["error"] = f"Expected {len(GPU_QUERY_FIELDS)} fields, got {len(parts)}"
        return sample

    sample.update(
        {
            "timestamp": parts[0],
            "pstate": parts[1],
            "power_w": _parse_float(parts[2]),
            "temp_c": _parse_float(parts[3]),
            "graphics_clock_mhz": _parse_float(parts[4]),
            "mem_clock_mhz": _parse_float(parts[5]),
            "gpu_util_pct": _parse_float(parts[6]),
            "mem_util_pct": _parse_float(parts[7]),
        }
    )
    return sample


class GpuSampler:
    def __init__(self, phase: str, interval_seconds: float) -> None:
        self.phase = phase
        self.interval_seconds = interval_seconds
        self.samples: list[dict[str, Any]] = []
        self._stop_event = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        self._thread.join(timeout=self.interval_seconds + 3.0)

    def _run(self) -> None:
        while not self._stop_event.is_set():
            try:
                self.samples.append(_query_gpu_sample(self.phase))
            except Exception as exc:
                self.samples.append(
                    {
                        "phase": self.phase,
                        "time": time.time(),
                        "returncode": -1,
                        "error": repr(exc),
                    }
                )
            self._stop_event.wait(self.interval_seconds)


def _valid_number(sample: dict[str, Any], key: str) -> Optional[float]:
    value = sample.get(key)
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _avg(values: list[float]) -> Optional[float]:
    if not values:
        return None
    return sum(values) / len(values)


def _summarize_samples(samples: list[dict[str, Any]]) -> dict[str, Any]:
    valid = [sample for sample in samples if sample.get("returncode") == 0 and sample.get("power_w") is not None]
    powers = [_valid_number(sample, "power_w") for sample in valid]
    temps = [_valid_number(sample, "temp_c") for sample in valid]
    graphics_clocks = [_valid_number(sample, "graphics_clock_mhz") for sample in valid]
    mem_clocks = [_valid_number(sample, "mem_clock_mhz") for sample in valid]
    gpu_utils = [_valid_number(sample, "gpu_util_pct") for sample in valid]
    mem_utils = [_valid_number(sample, "mem_util_pct") for sample in valid]
    powers = [value for value in powers if value is not None]
    temps = [value for value in temps if value is not None]
    graphics_clocks = [value for value in graphics_clocks if value is not None]
    mem_clocks = [value for value in mem_clocks if value is not None]
    gpu_utils = [value for value in gpu_utils if value is not None]
    mem_utils = [value for value in mem_utils if value is not None]
    pstates = Counter(str(sample.get("pstate", "unknown")) for sample in valid)

    summary: dict[str, Any] = {
        "sample_count": len(valid),
        "failed_sample_count": len(samples) - len(valid),
        "pstates": dict(pstates),
    }
    if powers:
        summary["avg_power_w"] = _avg(powers)
        summary["min_power_w"] = min(powers)
        summary["max_power_w"] = max(powers)
    if temps:
        summary["avg_temp_c"] = _avg(temps)
        summary["min_temp_c"] = min(temps)
        summary["max_temp_c"] = max(temps)
        summary["start_temp_c"] = temps[0]
        summary["end_temp_c"] = temps[-1]
        summary["temp_delta_c"] = temps[-1] - temps[0]
    if graphics_clocks:
        summary["avg_graphics_clock_mhz"] = _avg(graphics_clocks)
        summary["max_graphics_clock_mhz"] = max(graphics_clocks)
    if mem_clocks:
        summary["avg_mem_clock_mhz"] = _avg(mem_clocks)
        summary["max_mem_clock_mhz"] = max(mem_clocks)
    if gpu_utils:
        summary["avg_gpu_util_pct"] = _avg(gpu_utils)
        summary["max_gpu_util_pct"] = max(gpu_utils)
    if mem_utils:
        summary["avg_mem_util_pct"] = _avg(mem_utils)
        summary["max_mem_util_pct"] = max(mem_utils)
    if valid:
        summary["p0_fraction"] = pstates.get("P0", 0) / len(valid)
    return summary


def _summarize_time_window(
    samples: list[dict[str, Any]],
    end_epoch: float,
    window_seconds: float,
    trim_end_seconds: float = 0.0,
) -> dict[str, Any]:
    end_time = end_epoch - trim_end_seconds
    start_time = end_time - window_seconds
    window = [sample for sample in samples if start_time <= float(sample.get("time", 0.0)) <= end_time]
    summary = _summarize_samples(window)
    summary["window_seconds"] = window_seconds
    summary["trim_end_seconds"] = trim_end_seconds
    return summary


def _summarize_time_range(
    samples: list[dict[str, Any]],
    start_epoch: Optional[float],
    end_epoch: Optional[float],
    trim_start_seconds: float = 0.0,
    trim_end_seconds: float = 0.0,
) -> dict[str, Any]:
    if start_epoch is None or end_epoch is None or end_epoch <= start_epoch:
        return {
            "sample_count": 0,
            "failed_sample_count": 0,
            "pstates": {},
            "start_epoch": start_epoch,
            "end_epoch": end_epoch,
            "duration_seconds": 0.0,
            "trim_start_seconds": trim_start_seconds,
            "trim_end_seconds": trim_end_seconds,
        }
    start_time = start_epoch + trim_start_seconds
    end_time = end_epoch - trim_end_seconds
    if end_time <= start_time:
        end_time = end_epoch
    window = [sample for sample in samples if start_time <= float(sample.get("time", 0.0)) <= end_time]
    summary = _summarize_samples(window)
    summary["start_epoch"] = start_epoch
    summary["end_epoch"] = end_epoch
    summary["duration_seconds"] = max(0.0, end_time - start_time)
    summary["trim_start_seconds"] = trim_start_seconds
    summary["trim_end_seconds"] = trim_end_seconds
    return summary


def _extract_town_phase_epochs(snapshot: dict[str, Any]) -> dict[str, float]:
    phase_epochs: dict[str, float] = {}
    for event in snapshot.get("recent_scope_events", []):
        if not isinstance(event, dict):
            continue
        if event.get("scope") != "town_stall_test":
            continue
        label = str(event.get("label", ""))
        if label not in {"measurement_reset", "hold_started", "hold_complete", "shutdown_requested"}:
            continue
        epoch = event.get("epoch")
        if isinstance(epoch, (int, float)):
            phase_epochs[label] = float(epoch)
    return phase_epochs


def _latest_snapshot(since_mtime: float) -> Optional[Path]:
    return town_runner._latest_snapshot(since_mtime)


def _extract_generation_peak(sample: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "total_ms",
        "top_measure_bucket",
        "terrain_last_gpu_generation_batch_ms",
        "terrain_last_gpu_generation_batch_chunk_count",
        "terrain_last_gpu_generation_sync_ms",
        "terrain_last_gpu_meshing_dispatch_ms",
        "terrain_last_gpu_meshing_sync_ms",
        "terrain_last_gpu_mesh_readback_ms",
        "terrain_last_gpu_mesh_readback_chunk_count",
        "terrain_last_gpu_mesh_readback_terrain_vertices",
        "terrain_last_gpu_mesh_readback_water_vertices",
        "terrain_last_gpu_mesh_slice_count",
        "terrain_last_gpu_mesh_slice_max_sync_ms",
        "terrain_last_gpu_generation_batch_event_id",
        "terrain_last_cpu_mesh_build_ms",
        "terrain_last_cpu_mesh_build_terrain_ms",
        "terrain_last_cpu_mesh_build_water_ms",
        "terrain_last_cpu_mesh_build_queue_wait_ms",
        "terrain_last_cpu_mesh_build_terrain_vertices",
        "terrain_last_cpu_mesh_build_water_vertices",
        "terrain_last_cpu_mesh_build_event_id",
        "terrain_last_pending_node_process_ms",
        "terrain_last_pending_node_sort_ms",
        "terrain_last_finalize_terrain_ms",
        "terrain_last_collision_create_ms",
    ]
    return {key: sample.get(key) for key in keys if key in sample}


def _as_int(value: Any) -> Optional[int]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    return None


def _validate_content_for_power_compare(
    content: dict[str, Any],
    stream_gate: dict[str, Any],
) -> dict[str, Any]:
    reasons: list[str] = []
    target = _as_int(content.get("terrain_stream_min_chunk_target"))
    active = _as_int(content.get("active_chunk_count"))
    terrain = _as_int(content.get("rendered_terrain_chunk_count"))
    water = _as_int(content.get("rendered_water_chunk_count"))
    render_distance = _as_int(content.get("render_distance"))

    if target is None or target <= 0:
        reasons.append("missing_or_invalid_stream_target")
    else:
        terrain_min = max(1, int(float(target) * 0.90))
        terrain_max = max(target, int(float(target) * 1.55 + 0.999))
        active_min = terrain_min
        active_max = terrain_max
        water_min = max(1, int(float(target) * 0.20))
        water_max = max(water_min, int(float(target) * 0.60 + 0.999))

        content["rendered_terrain_target_min"] = terrain_min
        content["rendered_terrain_target_max"] = terrain_max
        content["active_chunk_target_min"] = active_min
        content["active_chunk_target_max"] = active_max
        content["rendered_water_target_min"] = water_min
        content["rendered_water_target_max"] = water_max

        if terrain is None:
            reasons.append("missing_rendered_terrain_count")
        elif terrain < terrain_min:
            reasons.append(f"rendered_terrain_below_target:{terrain}<{terrain_min}")
        elif terrain > terrain_max:
            reasons.append(f"rendered_terrain_above_target:{terrain}>{terrain_max}")

        if active is None:
            reasons.append("missing_active_chunk_count")
        elif active < active_min:
            reasons.append(f"active_chunks_below_target:{active}<{active_min}")
        elif active > active_max:
            reasons.append(f"active_chunks_above_target:{active}>{active_max}")

        if water is None:
            reasons.append("missing_rendered_water_count")
        elif water < water_min:
            reasons.append(f"rendered_water_below_target:{water}<{water_min}")
        elif water > water_max:
            reasons.append(f"rendered_water_above_target:{water}>{water_max}")

    if render_distance is None or render_distance <= 0:
        reasons.append("missing_or_invalid_render_distance")

    if content.get("terrain_stream_under_target") is True:
        reasons.append("terrain_stream_under_target")

    for key in [
        "pending_node_count",
        "task_queue_count",
        "cpu_task_queue_count",
        "completed_generation_queue_count",
    ]:
        count = _as_int(content.get(key))
        if count is None:
            reasons.append(f"missing_{key}")
        elif count != 0:
            reasons.append(f"{key}_not_idle:{count}")

    gate = stream_gate.get("last_terrain_stream_update_gate_reason")
    if gate != "idle_same_chunk":
        reasons.append(f"stream_gate_not_idle:{gate}")

    content["content_validation_reasons"] = reasons
    content["content_valid_for_power_compare"] = not reasons
    content["rendered_content_valid_for_power_compare"] = not reasons
    return content


def _load_snapshot_summary(path: Optional[Path]) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        snapshot = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"snapshot_path": str(path), "snapshot_error": repr(exc)}

    phase_epochs = _extract_town_phase_epochs(snapshot)
    town_window = snapshot.get("town_entry_window", {})
    moving_entry_window = snapshot.get("moving_entry_window", {})
    stationary_hold_window = snapshot.get("stationary_hold_window", {})
    moving_peak_sample = moving_entry_window.get("peak_entry_sample", {})
    stationary_peak_sample = stationary_hold_window.get("peak_entry_sample", {})
    telemetry = snapshot.get("system_telemetry", {}).get("terrain_manager", {})
    runtime_power = {
        key: telemetry.get(key)
        for key in [
            "runtime_power_mode_enabled",
            "runtime_power_mode",
            "runtime_power_target_fps",
            "runtime_power_active_max_fps",
            "runtime_power_idle_max_fps",
            "runtime_power_deep_idle_max_fps",
            "runtime_power_idle_seconds",
            "runtime_power_active_reason",
            "runtime_power_terrain_busy",
            "runtime_power_foreground_terrain_busy",
            "runtime_power_disabled_reason",
            "runtime_power_suspend_render_loop_in_deep_idle",
            "runtime_power_render_loop_suspended",
            "runtime_power_render_loop_enabled",
        ]
        if key in telemetry
    }
    terrain_gpu = {
        key: telemetry.get(key)
        for key in [
            "terrain_gpu_separate_water_meshing",
            "terrain_gpu_mesh_slices_per_chunk",
            "terrain_gpu_mesh_slice_delay_ms",
            "terrain_native_cpu_meshing_enabled",
            "water_render_enabled",
            "last_gpu_generation_batch_ms",
            "last_gpu_generation_sync_ms",
            "last_gpu_meshing_dispatch_ms",
            "last_gpu_meshing_sync_ms",
            "last_gpu_mesh_readback_ms",
            "last_gpu_mesh_slice_count",
            "last_gpu_mesh_slice_max_sync_ms",
        ]
        if key in telemetry
    }
    collision = {
        key: telemetry.get(key)
        for key in [
            "shared_collision_body_enabled",
            "shared_terrain_collision_create_budget_per_frame",
            "terrain_collision_create_budget_per_frame",
            "pending_terrain_collision_create_count",
            "last_terrain_collision_create_count",
            "last_terrain_collision_create_ms",
            "last_terrain_collision_create_skipped_far",
            "last_terrain_collision_create_stale",
            "last_terrain_collision_create_deferred_prewarm",
            "last_terrain_collision_candidate_checks",
            "collision_ready_chunk_count",
            "collision_enabled_chunk_count",
            "collision_space_attached_chunk_count",
        ]
        if key in telemetry
    }
    stream_gate = {
        key: telemetry.get(key)
        for key in [
            "last_terrain_stream_update_gate_reason",
            "terrain_stream_update_idle_skip_count",
            "last_update_backend",
            "last_update_loads",
            "last_update_unloads",
            "last_update_duration_ms",
        ]
        if key in telemetry
    }
    content = {
        key: telemetry.get(key)
        for key in [
            "rendered_terrain_chunk_count",
            "rendered_water_chunk_count",
            "active_chunk_count",
            "pending_node_count",
            "task_queue_count",
            "cpu_task_queue_count",
            "completed_generation_queue_count",
            "render_distance",
            "terrain_stream_min_chunk_target",
            "terrain_stream_under_target",
        ]
        if key in telemetry
    }
    content = _validate_content_for_power_compare(content, stream_gate)
    terrain_batch = {
        key: telemetry.get(key)
        for key in [
            "terrain_visual_batching_enabled",
            "terrain_visual_batch_size",
            "terrain_visual_batch_cached_rebuilds_per_frame",
            "terrain_visual_batch_cached_rebuild_budget_ms",
            "terrain_visual_batch_async_build_enabled",
            "terrain_visual_batch_async_during_streaming",
            "terrain_visual_batch_async_builds_per_frame",
            "terrain_visual_batch_streaming_async_queue_per_frame",
            "terrain_visual_batch_async_build_queue_limit",
            "terrain_visual_batch_async_apply_per_frame",
            "terrain_visual_batch_async_apply_budget_ms",
            "terrain_visual_batch_node_count",
            "terrain_visual_batch_dirty_count",
            "terrain_visual_batch_mesh_cache_count",
            "terrain_visual_batch_mesh_cache_hits",
            "terrain_visual_batch_mesh_cache_misses",
            "terrain_visual_batch_async_in_flight_count",
            "terrain_visual_batch_async_completed_count",
            "last_terrain_visual_batch_hidden_chunk_count",
            "last_terrain_visual_batch_rebuild_count",
            "last_terrain_visual_batch_rebuild_ms",
            "last_terrain_visual_batch_cached_rebuild_count",
            "last_terrain_visual_batch_cached_rebuild_ms",
            "last_terrain_visual_batch_cached_rebuild_attempts",
            "last_terrain_visual_batch_async_queued_count",
            "last_terrain_visual_batch_streaming_async_queued_count",
            "last_terrain_visual_batch_async_apply_count",
            "last_terrain_visual_batch_async_apply_ms",
            "last_terrain_visual_batch_async_stale_count",
            "terrain_visual_batch_stream_idle_frames",
            "terrain_visual_batch_total_heavy_skips",
            "terrain_visual_mesh_retire_queue_count",
        ]
        if key in telemetry
    }
    return {
        "snapshot_path": str(path),
        "benchmark": {
            "phase": snapshot.get("benchmark_phase"),
            "phase_time": snapshot.get("benchmark_phase_time"),
            "hold_seconds": snapshot.get("benchmark_hold_seconds"),
            "pending_quit": snapshot.get("benchmark_pending_quit"),
            "hold_complete": snapshot.get("benchmark_hold_complete"),
        },
        "phase_epochs": phase_epochs,
        "town_metrics": {
            "average_fps": snapshot.get("average_fps", town_window.get("average_fps")),
            "avg_total_ms": snapshot.get("avg_total_ms", town_window.get("avg_total_ms")),
            "avg_draw_calls": snapshot.get("avg_draw_calls", town_window.get("avg_draw_calls")),
            "avg_objects": snapshot.get("avg_objects", town_window.get("avg_objects")),
            "frames_over_budget": snapshot.get("frames_over_budget", town_window.get("frames_over_budget")),
            "frames_over_40ms": snapshot.get("frames_over_40ms", town_window.get("frames_over_40ms")),
            "frames_over_50ms": snapshot.get("frames_over_50ms", town_window.get("frames_over_50ms")),
            "max_total_ms": snapshot.get("max_frame_ms", town_window.get("max_total_ms")),
        },
        "moving_entry_metrics": {
            "sample_count": moving_entry_window.get("sample_count"),
            "average_fps": moving_entry_window.get("avg_fps"),
            "avg_total_ms": moving_entry_window.get("avg_total_ms"),
            "frames_over_budget": moving_entry_window.get("frames_over_budget"),
            "frames_over_40ms": moving_entry_window.get("frames_over_40ms"),
            "frames_over_50ms": moving_entry_window.get("frames_over_50ms"),
            "max_total_ms": moving_entry_window.get("max_total_ms"),
            "peak_top_bucket": moving_entry_window.get("peak_top_bucket"),
            "stable_top_bucket": moving_entry_window.get("stable_top_bucket"),
            "peak_generation": _extract_generation_peak(moving_peak_sample),
        },
        "stationary_hold_metrics": {
            "sample_count": stationary_hold_window.get("sample_count"),
            "average_fps": stationary_hold_window.get("avg_fps"),
            "avg_total_ms": stationary_hold_window.get("avg_total_ms"),
            "frames_over_budget": stationary_hold_window.get("frames_over_budget"),
            "frames_over_40ms": stationary_hold_window.get("frames_over_40ms"),
            "frames_over_50ms": stationary_hold_window.get("frames_over_50ms"),
            "max_total_ms": stationary_hold_window.get("max_total_ms"),
            "peak_top_bucket": stationary_hold_window.get("peak_top_bucket"),
            "stable_top_bucket": stationary_hold_window.get("stable_top_bucket"),
            "peak_generation": _extract_generation_peak(stationary_peak_sample),
        },
        "runtime_power": runtime_power,
        "terrain_gpu": terrain_gpu,
        "collision": collision,
        "stream_gate": stream_gate,
        "content": content,
        "terrain_batch": terrain_batch,
    }


def _assert_no_godot_processes() -> None:
    processes = town_runner._find_running_godot_processes()
    if not processes:
        return
    details = []
    for process in processes[:8]:
        details.append(
            {
                "pid": process.get("ProcessId"),
                "name": process.get("Name"),
                "command_line": process.get("CommandLine"),
            }
        )
    raise RuntimeError(f"Refusing to launch because Godot is already running: {details}")


def _run_idle_sample(label: str, seconds: float, interval_seconds: float) -> dict[str, Any]:
    _assert_no_godot_processes()
    print(f"Idle sensor baseline: {label} for {seconds:.1f}s")
    sampler = GpuSampler(label, interval_seconds)
    started = time.time()
    sampler.start()
    time.sleep(seconds)
    sampler.stop()
    ended = time.time()
    return {
        "label": label,
        "started_at_epoch": started,
        "ended_at_epoch": ended,
        "duration_s": ended - started,
        "gpu": _summarize_samples(sampler.samples),
        "samples": sampler.samples,
    }


def _build_case_env(case_name: str, hold_seconds: float, measure_full_flight: bool) -> dict[str, str]:
    env = os.environ.copy()
    for key in RESET_ENV_KEYS:
        env.pop(key, None)
    env.update(
        {
            "TOWN_STALL_SEED": os.environ.get("TOWN_STALL_SEED", "12345"),
            "TOWN_STALL_AUTO_TELEPORT": os.environ.get("TOWN_STALL_AUTO_TELEPORT", "0"),
            "TOWN_STALL_REPEAT_ENTRY": os.environ.get("TOWN_STALL_REPEAT_ENTRY", "0"),
            "TOWN_STALL_HOLD_SECONDS": f"{hold_seconds:.3f}",
            "TOWN_STALL_MACHINE_WARMUP_DISABLED": os.environ.get("TOWN_STALL_MACHINE_WARMUP_DISABLED", "1"),
            "TOWN_STALL_DISABLE_BUILDINGS": "0",
            "TOWN_STALL_DISABLE_ENTITIES": "0",
            "TOWN_STALL_DISABLE_TERRAIN_CHUNK_UPDATES": "0",
            "TOWN_STALL_DISABLE_EXIT_AUTOSAVE": "1",
            "TOWN_STALL_MEASURE_FULL_FLIGHT": "1" if measure_full_flight else os.environ.get("TOWN_STALL_MEASURE_FULL_FLIGHT", "0"),
        }
    )
    env.update(CASE_DEFINITIONS[case_name]["env"])
    return env


def _run_town_case(case_name: str, repeat_index: int, hold_seconds: float, interval_seconds: float, measure_full_flight: bool) -> dict[str, Any]:
    _assert_no_godot_processes()
    print(f"Town run: {case_name} repeat {repeat_index}")
    run_start_mtime = time.time()
    env = _build_case_env(case_name, hold_seconds, measure_full_flight)
    sampler = GpuSampler(f"{case_name}_{repeat_index}", interval_seconds)
    cmd = [PYTHON_BIN, str(Path(__file__).with_name("run_town_stall_test.py"))]
    started = time.time()
    sampler.start()
    proc = subprocess.run(
        cmd,
        cwd=str(PROJECT_PATH),
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=max(1200, int(hold_seconds + 900)),
    )
    ended = time.time()
    sampler.stop()
    _assert_no_godot_processes()

    snapshot_path = _latest_snapshot(run_start_mtime - 1.0)
    snapshot = _load_snapshot_summary(snapshot_path)
    output = (proc.stdout or "") + "\n" + (proc.stderr or "")
    failure_reasons = town_runner._detect_run_failure(output, proc.returncode)
    hold_completed = "[town_stall_test] hold complete, quitting" in output.lower()
    shutdown_av = proc.returncode == 3221225477
    if shutdown_av and snapshot_path and hold_completed:
        failure_reasons = [reason for reason in failure_reasons if reason != f"process exited with code {proc.returncode}"]

    result: dict[str, Any] = {
        "case": case_name,
        "repeat_index": repeat_index,
        "description": CASE_DEFINITIONS[case_name]["description"],
        "env_overrides": {key: env.get(key, "") for key in sorted(set(RESET_ENV_KEYS + ["TOWN_STALL_HOLD_SECONDS", "TOWN_STALL_MEASURE_FULL_FLIGHT", "TOWN_STALL_REPEAT_ENTRY"]))},
        "started_at_epoch": started,
        "ended_at_epoch": ended,
        "duration_s": ended - started,
        "returncode": proc.returncode,
        "failure_reasons": failure_reasons,
        "all_run_gpu": _summarize_samples(sampler.samples),
        "estimated_hold_gpu": _summarize_time_window(sampler.samples, ended, hold_seconds, trim_end_seconds=1.0),
        "last_30s_gpu": _summarize_time_window(sampler.samples, ended, 30.0, trim_end_seconds=1.0),
        "last_20s_gpu": _summarize_time_window(sampler.samples, ended, 20.0, trim_end_seconds=1.0),
        "snapshot": snapshot,
        "samples": sampler.samples,
    }
    phase_epochs = snapshot.get("phase_epochs", {}) if isinstance(snapshot, dict) else {}
    if isinstance(phase_epochs, dict):
        measurement_reset_epoch = phase_epochs.get("measurement_reset")
        hold_started_epoch = phase_epochs.get("hold_started")
        hold_complete_epoch = phase_epochs.get("hold_complete")
        result["moving_entry_gpu"] = _summarize_time_range(
            sampler.samples,
            measurement_reset_epoch if isinstance(measurement_reset_epoch, (int, float)) else None,
            hold_started_epoch if isinstance(hold_started_epoch, (int, float)) else None,
            trim_start_seconds=1.0,
            trim_end_seconds=0.0,
        )
        result["stationary_hold_gpu"] = _summarize_time_range(
            sampler.samples,
            hold_started_epoch if isinstance(hold_started_epoch, (int, float)) else None,
            hold_complete_epoch if isinstance(hold_complete_epoch, (int, float)) else None,
            trim_start_seconds=2.0,
            trim_end_seconds=1.0,
        )
    if failure_reasons:
        result["stdout_tail"] = "\n".join((proc.stdout or "").splitlines()[-120:])
        result["stderr_tail"] = "\n".join((proc.stderr or "").splitlines()[-120:])
    return result


def _case_summary_line(run: dict[str, Any]) -> str:
    hold = run.get("estimated_hold_gpu", {})
    last20 = run.get("last_20s_gpu", {})
    moving_gpu = run.get("moving_entry_gpu", {})
    stationary_gpu = run.get("stationary_hold_gpu", {})
    town_metrics = run.get("snapshot", {}).get("town_metrics", {})
    content = run.get("snapshot", {}).get("content", {})
    stream = run.get("snapshot", {}).get("stream_gate", {})
    power = hold.get("avg_power_w")
    last20_power = last20.get("avg_power_w")
    moving_power = moving_gpu.get("avg_power_w") if isinstance(moving_gpu, dict) else None
    stationary_power = stationary_gpu.get("avg_power_w") if isinstance(stationary_gpu, dict) else None
    pstate = hold.get("pstates", {})
    fps = town_metrics.get("average_fps")
    moving = run.get("snapshot", {}).get("moving_entry_metrics", {})
    moving_fps = moving.get("average_fps")
    moving_over_40 = moving.get("frames_over_40ms")
    terrain = content.get("rendered_terrain_chunk_count")
    water = content.get("rendered_water_chunk_count")
    valid = content.get("content_valid_for_power_compare")
    reasons = content.get("content_validation_reasons")
    gate = stream.get("last_terrain_stream_update_gate_reason")
    reason_text = ""
    if isinstance(reasons, list) and reasons:
        reason_text = " reasons=" + ";".join(str(reason) for reason in reasons[:4])
    return (
        f"{run.get('case')}#{run.get('repeat_index')}: "
        f"hold_power={power:.2f}W " if isinstance(power, (int, float)) else f"{run.get('case')}#{run.get('repeat_index')}: hold_power=? "
    ) + (
        f"last20={last20_power:.2f}W " if isinstance(last20_power, (int, float)) else "last20=? "
    ) + (
        f"moving={moving_power:.2f}W " if isinstance(moving_power, (int, float)) else "moving=? "
    ) + (
        f"hold_segment={stationary_power:.2f}W " if isinstance(stationary_power, (int, float)) else "hold_segment=? "
    ) + (
        f"pstates={pstate} fps={fps} moving_fps={moving_fps} "
        f"moving_over40={moving_over_40} terrain={terrain} water={water} valid={valid} gate={gate}{reason_text}"
    )


def _run_content_valid(run: dict[str, Any]) -> bool:
    content = run.get("snapshot", {}).get("content", {})
    return bool(content.get("content_valid_for_power_compare")) if isinstance(content, dict) else False


def _aggregate_case_runs(runs: list[dict[str, Any]]) -> dict[str, Any]:
    by_case: dict[str, list[dict[str, Any]]] = {}
    for run in runs:
        by_case.setdefault(str(run.get("case", "unknown")), []).append(run)

    aggregate: dict[str, Any] = {}
    for case, case_runs in by_case.items():
        comparison_runs = [run for run in case_runs if _run_content_valid(run)]
        hold_powers = [
            float(run["estimated_hold_gpu"]["avg_power_w"])
            for run in comparison_runs
            if isinstance(run.get("estimated_hold_gpu", {}).get("avg_power_w"), (int, float))
        ]
        last20_powers = [
            float(run["last_20s_gpu"]["avg_power_w"])
            for run in comparison_runs
            if isinstance(run.get("last_20s_gpu", {}).get("avg_power_w"), (int, float))
        ]
        moving_powers = [
            float(run["moving_entry_gpu"]["avg_power_w"])
            for run in comparison_runs
            if isinstance(run.get("moving_entry_gpu", {}).get("avg_power_w"), (int, float))
        ]
        stationary_hold_powers = [
            float(run["stationary_hold_gpu"]["avg_power_w"])
            for run in comparison_runs
            if isinstance(run.get("stationary_hold_gpu", {}).get("avg_power_w"), (int, float))
        ]
        p0_fractions = [
            float(run["estimated_hold_gpu"]["p0_fraction"])
            for run in comparison_runs
            if isinstance(run.get("estimated_hold_gpu", {}).get("p0_fraction"), (int, float))
        ]
        fps_values = [
            float(run["snapshot"]["town_metrics"]["average_fps"])
            for run in comparison_runs
            if isinstance(run.get("snapshot", {}).get("town_metrics", {}).get("average_fps"), (int, float))
        ]
        aggregate[case] = {
            "run_count": len(case_runs),
            "valid_run_count": len(comparison_runs),
            "invalid_run_count": len(case_runs) - len(comparison_runs),
            "invalid_content_reasons": [
                run.get("snapshot", {}).get("content", {}).get("content_validation_reasons", [])
                for run in case_runs
                if not _run_content_valid(run)
            ],
            "avg_hold_power_w": _avg(hold_powers),
            "min_hold_power_w": min(hold_powers) if hold_powers else None,
            "max_hold_power_w": max(hold_powers) if hold_powers else None,
            "avg_last20_power_w": _avg(last20_powers),
            "avg_moving_power_w": _avg(moving_powers),
            "avg_stationary_hold_power_w": _avg(stationary_hold_powers),
            "avg_hold_p0_fraction": _avg(p0_fractions),
            "avg_fps": _avg(fps_values),
        }
    return aggregate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run repeated raw nvidia-smi town-stall baselines.")
    parser.add_argument("--cases", default="fixed60,runtime_default", help="Comma-separated cases: fixed60,fixed70,runtime_default,runtime_gpu_meshing,runtime_native_cpu_meshing,runtime_no_streaming_batch_async,runtime_no_render_suspend,runtime_fast_deep_idle,runtime_no_terrain_stream,runtime_no_glow,runtime_no_water_render,runtime_joined_water_submit,runtime_separate_water_submit,runtime_mesh_slices_1,runtime_mesh_slices_2")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--hold-seconds", type=float, default=40.0)
    parser.add_argument("--idle-seconds", type=float, default=20.0)
    parser.add_argument("--sample-interval", type=float, default=1.0)
    parser.add_argument("--measure-full-flight", action="store_true")
    args = parser.parse_args()

    case_names = [case.strip() for case in args.cases.split(",") if case.strip()]
    unknown = [case for case in case_names if case not in CASE_DEFINITIONS]
    if unknown:
        print(f"Unknown case(s): {', '.join(unknown)}")
        return 2
    if args.repeats <= 0:
        print("--repeats must be positive")
        return 2

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    started = time.time()
    slug = _timestamp_slug()
    output_path = OUTPUT_DIR / f"town_stall_raw_baseline_{slug}.json"
    print(f"Raw baseline output: {output_path}")
    _assert_no_godot_processes()

    payload: dict[str, Any] = {
        "started_at_epoch": started,
        "project_path": str(PROJECT_PATH),
        "cases": case_names,
        "repeats": args.repeats,
        "hold_seconds": args.hold_seconds,
        "idle_seconds": args.idle_seconds,
        "sample_interval_seconds": args.sample_interval,
        "measure_full_flight": args.measure_full_flight,
        "preflight_machine_state": town_runner._collect_machine_state(),
        "initial_idle": _run_idle_sample("initial_idle", args.idle_seconds, args.sample_interval),
        "runs": [],
    }

    exit_code = 0
    for repeat_index in range(1, args.repeats + 1):
        for case_name in case_names:
            payload["runs"].append(_run_town_case(case_name, repeat_index, args.hold_seconds, args.sample_interval, args.measure_full_flight))
            print(_case_summary_line(payload["runs"][-1]))
            if payload["runs"][-1].get("failure_reasons"):
                exit_code = 1

    payload["final_idle"] = _run_idle_sample("final_idle", args.idle_seconds, args.sample_interval)
    payload["ended_at_epoch"] = time.time()
    payload["duration_s"] = payload["ended_at_epoch"] - started
    payload["aggregate"] = _aggregate_case_runs(payload["runs"])
    output_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    print("Aggregate:")
    print(json.dumps(payload["aggregate"], indent=2))
    print(f"Wrote {output_path}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
