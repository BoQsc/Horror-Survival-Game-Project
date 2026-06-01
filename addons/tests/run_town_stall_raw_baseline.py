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
from windows_error_dialogs import suppress_windows_error_dialogs


PROJECT_PATH = Path(__file__).resolve().parents[2]
OUTPUT_DIR = PROJECT_PATH / ".agent" / "gpu-telemetry"
PYTHON_BIN = sys.executable
NVIDIA_SMI = "nvidia-smi"
DEFAULT_IDLE_MAX_POWER_W = 15.0
DEFAULT_IDLE_MAX_TEMP_C = 85.0
DEFAULT_IDLE_MAX_P0_FRACTION = 0.20
DEFAULT_IDLE_MAX_GPU_UTIL_PCT = 30.0
DEFAULT_IDLE_MAX_CPU_LOAD_PCT = 55
DEFAULT_IDLE_MAX_CPU_PERF_PCT = 115
DEFAULT_IDLE_MAX_CPU_UTIL_PCT = 80
DEFAULT_RUN_MAX_GPU_TEMP_C = 90.0

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
    "runtime_deepidle60": {
        "description": "Runtime power manager with active/idle/deep-idle all capped at 60 FPS for clean gameplay render A/B.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
        },
    },
    "runtime_deepidle60_no_alpha_split": {
        "description": "Runtime 60 FPS power profile with vegetation alpha-scissor surface splitting disabled.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
            "TOWN_STALL_VEGETATION_SPLIT_ALPHA_SCISSOR_OPAQUE_SURFACES": "0",
        },
    },
    "runtime_deepidle60_no_vegetation": {
        "description": "Runtime 60 FPS power profile with vegetation render disabled for full vegetation cost isolation.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
            "TOWN_STALL_DISABLE_VEGETATION_RENDER": "1",
        },
    },
    "runtime_deepidle60_no_trees": {
        "description": "Runtime 60 FPS power profile with tree render disabled for tree cost isolation.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
            "TOWN_STALL_VEGETATION_RENDER_TREES": "0",
        },
    },
    "runtime_deepidle60_no_grass": {
        "description": "Runtime 60 FPS power profile with grass render disabled for grass cost isolation.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
            "TOWN_STALL_VEGETATION_RENDER_GRASS": "0",
        },
    },
    "runtime_deepidle60_no_rocks": {
        "description": "Runtime 60 FPS power profile with rock render disabled for rock cost isolation.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
            "TOWN_STALL_VEGETATION_RENDER_ROCKS": "0",
        },
    },
    "runtime_deepidle60_no_water": {
        "description": "Runtime 60 FPS power profile with water render disabled for water cost isolation.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
            "TOWN_STALL_DISABLE_WATER_RENDER": "1",
        },
    },
    "runtime_deepidle60_tree_clusters_1": {
        "description": "Runtime 60 FPS power profile with 1x1 tree render clusters for tighter frustum culling.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
            "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "1",
        },
    },
    "runtime_deepidle60_tree_clusters_4": {
        "description": "Runtime 60 FPS power profile with 4x4 tree render clusters for lower draw-call overhead.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
            "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "4",
        },
    },
    "runtime_deepidle60_tree_bounds_2": {
        "description": "Runtime 60 FPS power profile with current tree clusters and tighter exact tree render bounds padding.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
            "TOWN_STALL_VEGETATION_TREE_GLOBAL_RENDER_BOUNDS_PADDING": "2",
        },
    },
    "runtime_deepidle60_veg_occlusion_culling": {
        "description": "Runtime 60 FPS power profile with vegetation batches allowed to participate in Godot occlusion culling.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
            "TOWN_STALL_VEGETATION_GLOBAL_RENDER_IGNORE_OCCLUSION_CULLING": "0",
        },
    },
    "runtime_deepidle60_terrain_batch_1": {
        "description": "Runtime 60 FPS power profile with 1x1 world-map terrain visual batches for tighter frustum culling.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "60",
            "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "60",
            "TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_SIZE": "1",
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
    "runtime_no_dry_water_density_skip": {
        "description": "Runtime defaults with dry water-density dispatch skip disabled for A/B isolation.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_SKIP_DRY_WATER_DENSITY_DISPATCH": "0",
        },
    },
    "runtime_no_streaming_batch_async": {
        "description": "Runtime defaults with terrain visual batch async queueing during streaming disabled.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_TERRAIN_BATCH_STREAMING_ASYNC": "0",
        },
    },
    "runtime_terrain_visual_batching": {
        "description": "Runtime defaults with exact-geometry 2x2 terrain visual batching enabled.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_TERRAIN_VISUAL_BATCHING": "1",
            "TOWN_STALL_TERRAIN_VISUAL_BATCH_SIZE": "2",
            "TOWN_STALL_TERRAIN_VISUAL_BATCH_MAX_VERTICES": "80000",
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
    "runtime_no_shared_collision": {
        "description": "Runtime defaults with shared terrain collision body disabled for collision-spike isolation.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_SHARED_TERRAIN_COLLISION_BODY": "0",
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
    "runtime_veg_occlusion_culling": {
        "description": "Runtime defaults with vegetation batches allowed to participate in Godot occlusion culling.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_VEGETATION_GLOBAL_RENDER_IGNORE_OCCLUSION_CULLING": "0",
        },
    },
    "runtime_veg_tree_clusters_1": {
        "description": "Runtime defaults with 1x1 tree render clusters for tighter frustum culling without changing density.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "1",
        },
    },
    "runtime_veg_tree_clusters_4": {
        "description": "Runtime defaults with 4x4 tree render clusters for lower draw-call overhead without changing density.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "4",
        },
    },
    "runtime_veg_no_mesh_lods": {
        "description": "Runtime defaults with generated vegetation mesh LODs disabled for visual/perf A/B isolation.",
        "env": {
            "TOWN_STALL_ENABLE_RUNTIME_POWER_MODE": "1",
            "TOWN_STALL_VEGETATION_GENERATE_MESH_LODS": "0",
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
    "TOWN_STALL_SKIP_DRY_WATER_DENSITY_DISPATCH",
    "TOWN_STALL_TERRAIN_BATCH_STREAMING_ASYNC",
    "TOWN_STALL_TERRAIN_BATCH_STREAMING_ASYNC_QUEUE",
    "TOWN_STALL_SHARED_TERRAIN_COLLISION_CREATE_BUDGET",
    "TOWN_STALL_TERRAIN_VISUAL_BATCHING",
    "TOWN_STALL_TERRAIN_VISUAL_BATCH_SIZE",
    "TOWN_STALL_TERRAIN_VISUAL_BATCH_MAX_VERTICES",
    "TOWN_STALL_DISABLE_TERRAIN_CHUNK_UPDATES",
    "TOWN_STALL_SHARED_TERRAIN_COLLISION_BODY",
    "TOWN_STALL_DISABLE_GLOW",
    "TOWN_STALL_DISABLE_WATER_RENDER",
    "TOWN_STALL_VEGETATION_GLOBAL_RENDER_IGNORE_OCCLUSION_CULLING",
    "TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_SIZE",
    "TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_MAX_VERTICES",
    "TOWN_STALL_VEGETATION_RENDER_CLUSTER_SIZE",
    "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE",
    "TOWN_STALL_VEGETATION_GRASS_RENDER_CLUSTER_SIZE",
    "TOWN_STALL_WORLD_MAP_VEGETATION_GRASS_RENDER_CLUSTER_SIZE",
    "TOWN_STALL_WORLD_MAP_VEGETATION_ROCK_RENDER_CLUSTER_SIZE",
    "TOWN_STALL_VEGETATION_RENDER_EXTRA_CULL_MARGIN",
    "TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING",
    "TOWN_STALL_VEGETATION_TREE_GLOBAL_RENDER_BOUNDS_PADDING",
    "TOWN_STALL_VEGETATION_GRASS_GLOBAL_RENDER_BOUNDS_PADDING",
    "TOWN_STALL_VEGETATION_ROCK_GLOBAL_RENDER_BOUNDS_PADDING",
    "TOWN_STALL_VEGETATION_EXACT_RENDER_BOUNDS",
    "TOWN_STALL_VEGETATION_EXACT_RENDER_BOUNDS_PADDING",
    "TOWN_STALL_VEGETATION_RENDER_LOD_BIAS",
    "TOWN_STALL_VEGETATION_PRESERVE_IMPORTED_MESH_LODS",
    "TOWN_STALL_VEGETATION_GENERATE_MESH_LODS",
    "TOWN_STALL_VEGETATION_MESH_LOD_MIN_PRIMITIVES",
    "TOWN_STALL_VEGETATION_MESH_LOD_NORMAL_MERGE_ANGLE",
    "TOWN_STALL_VEGETATION_SPLIT_ALPHA_SCISSOR_OPAQUE_SURFACES",
    "TOWN_STALL_VEGETATION_CULL_ALPHA_TRANSPARENT_TRIANGLES",
    "TOWN_STALL_VEGETATION_ALPHA_SPLIT_MIN_OPAQUE_FRACTION",
    "TOWN_STALL_ENTITY_MAX_ENTITIES",
    "TOWN_STALL_ENTITY_SPAWN_RADIUS",
    "TOWN_STALL_ENTITY_ACTIVE_PHYSICS_RADIUS",
    "TOWN_STALL_ENTITY_FREEZE_RADIUS",
    "TOWN_STALL_ENTITY_DESPAWN_RADIUS",
    "TOWN_STALL_ENTITY_FREEZE_COLLISION_MARGIN",
    "TOWN_STALL_ENTITY_PROXIMITY_BUDGET_MS",
    "TOWN_STALL_ENTITY_PENDING_SPAWN_CHECKS_PER_FRAME",
    "TOWN_STALL_ENTITY_DORMANT_RESPAWN_CHECKS_PER_FRAME",
    "TOWN_STALL_ENTITY_SPAWN_QUEUE_BUDGET_MS",
    "TOWN_STALL_ENTITY_DORMANT_RESPAWN_BUDGET_MS",
    "TOWN_STALL_ENTITY_MAINTENANCE_BUDGET_MS",
    "TOWN_STALL_ENTITY_PROXIMITY_UPDATE_INTERVAL",
    "TOWN_STALL_ENTITY_SPAWN_QUEUE_UPDATE_INTERVAL",
    "TOWN_STALL_ENTITY_DORMANT_RESPAWN_UPDATE_INTERVAL",
    "TOWN_STALL_ENTITY_DEFERRED_SPAWN_CHUNKS_PER_FRAME",
    "TOWN_STALL_ENTITY_SPAWN_CHANCE_PER_CHUNK",
    "TOWN_STALL_ENTITY_MIN_SPAWN_DISTANCE",
    "TOWN_STALL_ENTITY_MAX_SPAWNS_PER_CHUNK",
    "TOWN_STALL_ENTITY_PRIORITIZE_NEARBY_SPAWNS",
    "TOWN_STALL_ENTITY_BALANCE_SPAWN_DISTANCE_RINGS",
    "TOWN_STALL_ENTITY_SPAWN_DISTANCE_RING_COUNT",
    "TOWN_STALL_ENTITY_BALANCED_RING_FILL",
    "TOWN_STALL_ENTITY_BALANCED_RING_FILL_TARGET",
    "TOWN_STALL_ENTITY_BALANCED_RING_FILL_INTERVAL",
    "TOWN_STALL_ENTITY_BALANCED_RING_FILL_CANDIDATES_PER_TICK",
    "TOWN_STALL_ENTITY_BALANCED_RING_FILL_AREA_WEIGHTED",
    "TOWN_STALL_ENTITY_BALANCED_RING_FILL_RECENTER_DISTANCE",
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
    def __init__(self, phase: str, interval_seconds: float, max_temp_c: Optional[float] = None) -> None:
        self.phase = phase
        self.interval_seconds = interval_seconds
        self.max_temp_c = max_temp_c if max_temp_c is not None and max_temp_c > 0 else None
        self.samples: list[dict[str, Any]] = []
        self.thermal_abort_event = threading.Event()
        self.thermal_abort_sample: Optional[dict[str, Any]] = None
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
                sample = _query_gpu_sample(self.phase)
                self.samples.append(sample)
                temp_c = sample.get("temp_c")
                if self.max_temp_c is not None and isinstance(temp_c, (int, float)) and temp_c >= self.max_temp_c:
                    self.thermal_abort_sample = sample
                    self.thermal_abort_event.set()
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


def _float_env(name: str, default_value: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default_value
    try:
        return float(raw)
    except ValueError:
        return default_value


def _int_env(name: str, default_value: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default_value
    try:
        return int(raw)
    except ValueError:
        return default_value


def _idle_contamination_thresholds() -> dict[str, Any]:
    return {
        "max_idle_power_w": _float_env("TOWN_STALL_IDLE_MAX_POWER_W", DEFAULT_IDLE_MAX_POWER_W),
        "max_idle_temp_c": _float_env("TOWN_STALL_IDLE_MAX_TEMP_C", DEFAULT_IDLE_MAX_TEMP_C),
        "max_idle_p0_fraction": _float_env("TOWN_STALL_IDLE_MAX_P0_FRACTION", DEFAULT_IDLE_MAX_P0_FRACTION),
        "max_idle_gpu_util_pct": _float_env("TOWN_STALL_IDLE_MAX_GPU_UTIL_PCT", DEFAULT_IDLE_MAX_GPU_UTIL_PCT),
        "max_idle_cpu_load_pct": _int_env("TOWN_STALL_IDLE_MAX_CPU_LOAD_PCT", DEFAULT_IDLE_MAX_CPU_LOAD_PCT),
        "max_idle_cpu_perf_pct": _int_env("TOWN_STALL_IDLE_MAX_CPU_PERF_PCT", DEFAULT_IDLE_MAX_CPU_PERF_PCT),
        "max_idle_cpu_util_pct": _int_env("TOWN_STALL_IDLE_MAX_CPU_UTIL_PCT", DEFAULT_IDLE_MAX_CPU_UTIL_PCT),
    }


def _idle_contamination_reasons(idle_sample: dict[str, Any], machine_state: dict[str, Any], thresholds: dict[str, Any]) -> list[str]:
    reasons: list[str] = []
    gpu = idle_sample.get("gpu", {}) if isinstance(idle_sample, dict) else {}
    if not isinstance(gpu, dict) or int(gpu.get("sample_count", 0) or 0) <= 0:
        reasons.append("idle_gpu_samples_missing")
        return reasons

    avg_power = gpu.get("avg_power_w")
    if isinstance(avg_power, (int, float)) and avg_power > float(thresholds["max_idle_power_w"]):
        reasons.append(f"idle_gpu_power_high:{avg_power:.2f}W>{thresholds['max_idle_power_w']:.2f}W")

    max_temp = gpu.get("max_temp_c")
    if isinstance(max_temp, (int, float)) and max_temp > float(thresholds["max_idle_temp_c"]):
        reasons.append(f"idle_gpu_temp_high:{max_temp:.1f}C>{thresholds['max_idle_temp_c']:.1f}C")

    p0_fraction = gpu.get("p0_fraction")
    if isinstance(p0_fraction, (int, float)) and p0_fraction > float(thresholds["max_idle_p0_fraction"]):
        reasons.append(f"idle_gpu_p0_high:{p0_fraction:.3f}>{thresholds['max_idle_p0_fraction']:.3f}")

    avg_gpu_util = gpu.get("avg_gpu_util_pct")
    if isinstance(avg_gpu_util, (int, float)) and avg_gpu_util > float(thresholds["max_idle_gpu_util_pct"]):
        reasons.append(f"idle_gpu_util_high:{avg_gpu_util:.1f}%>{thresholds['max_idle_gpu_util_pct']:.1f}%")

    if isinstance(machine_state, dict):
        cpu_load = machine_state.get("load_percentage")
        if isinstance(cpu_load, (int, float)) and cpu_load > int(thresholds["max_idle_cpu_load_pct"]):
            reasons.append(f"idle_cpu_load_high:{int(cpu_load)}%>{thresholds['max_idle_cpu_load_pct']}%")
        cpu_perf = machine_state.get("percent_processor_performance")
        if isinstance(cpu_perf, (int, float)) and cpu_perf > int(thresholds["max_idle_cpu_perf_pct"]):
            reasons.append(f"idle_cpu_perf_high:{int(cpu_perf)}%>{thresholds['max_idle_cpu_perf_pct']}%")
        cpu_util = machine_state.get("percent_processor_utility")
        if isinstance(cpu_util, (int, float)) and cpu_util > int(thresholds["max_idle_cpu_util_pct"]):
            reasons.append(f"idle_cpu_util_high:{int(cpu_util)}%>{thresholds['max_idle_cpu_util_pct']}%")

    return reasons


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


def _wait_for_preflight_gpu_temperature(
    max_temp_c: float,
    timeout_seconds: float,
    poll_seconds: float,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "enabled": max_temp_c > 0,
        "max_temp_c": max_temp_c,
        "timeout_seconds": timeout_seconds,
        "poll_seconds": poll_seconds,
        "samples": [],
        "reached": True,
    }
    if max_temp_c <= 0:
        return result

    deadline = time.time() + max(0.0, timeout_seconds)
    poll_seconds = max(1.0, poll_seconds)
    print(f"Preflight GPU cooldown gate: waiting for temp <= {max_temp_c:.1f}C")
    while True:
        sample = _query_gpu_sample("preflight_cooldown")
        result["samples"].append(sample)
        temp_c = sample.get("temp_c")
        if isinstance(temp_c, (int, float)):
            power_w = sample.get("power_w")
            pstate = sample.get("pstate", "?")
            power_text = f", {float(power_w):.2f}W" if isinstance(power_w, (int, float)) else ""
            print(f"  GPU temp {float(temp_c):.1f}C{power_text}, {pstate}")
            if float(temp_c) <= max_temp_c:
                break
        elif sample.get("error"):
            print(f"  GPU sample unavailable: {sample.get('error')}")

        if time.time() >= deadline:
            result["reached"] = False
            break
        time.sleep(min(poll_seconds, max(0.0, deadline - time.time())))

    result["summary"] = _summarize_samples(result["samples"])
    result["duration_s"] = max(0.0, time.time() - (deadline - max(0.0, timeout_seconds)))
    return result


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
    explicit_epochs = snapshot.get("phase_epochs", {})
    if isinstance(explicit_epochs, dict):
        for label in ("measurement_reset", "hold_started", "hold_complete", "shutdown_requested"):
            epoch = explicit_epochs.get(label)
            if isinstance(epoch, (int, float)) and float(epoch) >= 0.0:
                phase_epochs[label] = float(epoch)
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


def _summarize_directional_render_gpu(
    samples: list[dict[str, Any]],
    directional_render_sampling: dict[str, Any],
) -> dict[str, Any]:
    windows = directional_render_sampling.get("windows", {})
    if not isinstance(windows, dict):
        return {}
    gpu_windows: dict[str, Any] = {}
    for label, window in windows.items():
        if not isinstance(window, dict):
            continue
        start_epoch = window.get("start_epoch")
        end_epoch = window.get("end_epoch")
        if not isinstance(start_epoch, (int, float)) or not isinstance(end_epoch, (int, float)):
            continue
        gpu_windows[str(label)] = _summarize_time_range(
            samples,
            float(start_epoch),
            float(end_epoch),
            trim_start_seconds=0.0,
            trim_end_seconds=0.0,
        )
    return gpu_windows


def _directional_render_summary_text(snapshot: dict[str, Any]) -> str:
    directional = snapshot.get("directional_render_sampling", {})
    if not isinstance(directional, dict) or not directional.get("enabled"):
        return ""
    windows = directional.get("windows", {})
    if not isinstance(windows, dict):
        return ""
    primitive_values: list[float] = []
    fps_values: list[float] = []
    for window in windows.values():
        if not isinstance(window, dict) or int(window.get("sample_count", 0) or 0) <= 0:
            continue
        primitives = window.get("avg_primitives")
        fps = window.get("avg_fps")
        if isinstance(primitives, (int, float)):
            primitive_values.append(float(primitives))
        if isinstance(fps, (int, float)):
            fps_values.append(float(fps))
    if not primitive_values:
        return " directional=enabled_no_samples"
    text = f" directional_primitives={min(primitive_values):.0f}-{max(primitive_values):.0f}"
    if fps_values:
        text += f" directional_fps={min(fps_values):.1f}-{max(fps_values):.1f}"
    return text


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


def _as_float(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _sum_numeric(values: list[Any]) -> float:
    return sum(float(value) for value in values if isinstance(value, (int, float)) and not isinstance(value, bool))


def _wpf60(power_w: Any, fps: Any) -> Optional[float]:
    """60 FPS equivalent watts; lower is better, target is <= 16 at sustained 60 FPS."""
    if not isinstance(power_w, (int, float)) or isinstance(power_w, bool):
        return None
    if not isinstance(fps, (int, float)) or isinstance(fps, bool) or float(fps) <= 0.0:
        return None
    return float(power_w) * (60.0 / float(fps))


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


def _build_render_pressure_summary(
    town_window: dict[str, Any],
    runtime_power: dict[str, Any],
    content: dict[str, Any],
    terrain_batch: dict[str, Any],
    vegetation_render: dict[str, Any],
) -> dict[str, Any]:
    sample_count = int(town_window.get("sample_count", 0) or 0)
    avg_fps = _as_float(town_window.get("avg_fps"))
    avg_total_ms = _as_float(town_window.get("avg_total_ms"))
    avg_process_ms = _as_float(town_window.get("avg_process_ms"))
    avg_physics_ms = _as_float(town_window.get("avg_physics_ms"))
    avg_other_ms = _as_float(town_window.get("avg_other_ms"))
    avg_draw_calls = _as_float(town_window.get("avg_draw_calls"))
    avg_primitives = _as_float(town_window.get("avg_primitives"))
    end_engine_max_fps = _as_float(town_window.get("end_engine_max_fps"))

    terrain_primitives = _as_float(terrain_batch.get("terrain_visual_batch_primitive_count"))
    vegetation_primitives = _as_float(vegetation_render.get("global_render_estimated_primitives"))
    tree_primitives = _as_float(vegetation_render.get("global_tree_render_estimated_primitives"))
    grass_primitives = _as_float(vegetation_render.get("global_grass_render_estimated_primitives"))
    rock_primitives = _as_float(vegetation_render.get("global_rock_render_estimated_primitives"))
    alpha_empty_primitives = _as_float(vegetation_render.get("global_render_estimated_alpha_empty_primitive_equivalent"))
    known_primitives = _sum_numeric([terrain_primitives, vegetation_primitives])

    world_work_suspended_samples = int(town_window.get("terrain_runtime_power_world_work_suspended_samples", 0) or 0)
    render_loop_suspended_samples = int(town_window.get("terrain_runtime_power_render_loop_suspended_samples", 0) or 0)
    world_work_suspended_fraction = float(world_work_suspended_samples) / float(sample_count) if sample_count > 0 else 0.0
    render_loop_suspended_fraction = float(render_loop_suspended_samples) / float(sample_count) if sample_count > 0 else 0.0
    pending_work_count = int(_sum_numeric([
        content.get("pending_node_count"),
        content.get("task_queue_count"),
        content.get("cpu_task_queue_count"),
        terrain_batch.get("terrain_visual_batch_dirty_count"),
        terrain_batch.get("terrain_visual_batch_async_in_flight_count"),
        terrain_batch.get("terrain_visual_batch_async_completed_count"),
        vegetation_render.get("global_render_dirty_cluster_count"),
    ]))

    runtime_target_fps = _as_float(runtime_power.get("runtime_power_target_fps"))
    runtime_mode = str(runtime_power.get("runtime_power_mode", ""))
    render_loop_suspended = bool(runtime_power.get("runtime_power_render_loop_suspended", False))
    render_loop_active_above_target = (
        avg_fps is not None
        and runtime_target_fps is not None
        and runtime_target_fps > 0
        and avg_fps > runtime_target_fps + 5.0
        and not render_loop_suspended
    )
    engine_cap_above_target = (
        end_engine_max_fps is not None
        and runtime_target_fps is not None
        and runtime_target_fps > 0
        and end_engine_max_fps > runtime_target_fps + 5.0
    )
    background_queues_idle = pending_work_count == 0 \
        and not bool(runtime_power.get("runtime_power_terrain_busy", False)) \
        and not bool(runtime_power.get("runtime_power_foreground_terrain_busy", False)) \
        and not bool(runtime_power.get("runtime_power_external_world_busy", False))

    contributors: list[str] = []
    if render_loop_active_above_target:
        contributors.append("render_loop_active_above_runtime_target")
    if engine_cap_above_target:
        contributors.append("engine_max_fps_above_runtime_target")
    if avg_primitives is not None and avg_primitives >= 1_000_000:
        contributors.append("high_submitted_primitives")
    if terrain_primitives is not None and terrain_primitives >= 500_000:
        contributors.append("high_terrain_primitives")
    if tree_primitives is not None and tree_primitives >= 500_000:
        contributors.append("high_tree_primitives")
    if alpha_empty_primitives is not None and alpha_empty_primitives >= 250_000:
        contributors.append("high_alpha_empty_primitives")
    if background_queues_idle:
        contributors.append("background_work_not_primary")

    return {
        "sample_count": sample_count,
        "avg_fps": avg_fps,
        "avg_total_ms": avg_total_ms,
        "avg_process_ms": avg_process_ms,
        "avg_physics_ms": avg_physics_ms,
        "avg_other_ms": avg_other_ms,
        "avg_draw_calls": avg_draw_calls,
        "avg_primitives": avg_primitives,
        "end_engine_max_fps": end_engine_max_fps,
        "known_render_primitives": known_primitives,
        "terrain_visual_primitives": terrain_primitives,
        "vegetation_primitives": vegetation_primitives,
        "tree_primitives": tree_primitives,
        "grass_primitives": grass_primitives,
        "rock_primitives": rock_primitives,
        "alpha_empty_primitive_equivalent": alpha_empty_primitives,
        "terrain_primitive_share": terrain_primitives / known_primitives if terrain_primitives is not None and known_primitives > 0 else None,
        "vegetation_primitive_share": vegetation_primitives / known_primitives if vegetation_primitives is not None and known_primitives > 0 else None,
        "tree_primitive_share_of_vegetation": tree_primitives / vegetation_primitives if tree_primitives is not None and vegetation_primitives is not None and vegetation_primitives > 0 else None,
        "alpha_empty_share_of_vegetation": alpha_empty_primitives / vegetation_primitives if alpha_empty_primitives is not None and vegetation_primitives is not None and vegetation_primitives > 0 else None,
        "runtime_power_mode": runtime_mode,
        "runtime_power_target_fps": runtime_target_fps,
        "render_loop_suspended": render_loop_suspended,
        "render_loop_suspend_gate": runtime_power.get("runtime_power_render_loop_suspend_gate"),
        "render_loop_active_above_target": render_loop_active_above_target,
        "engine_cap_above_target": engine_cap_above_target,
        "world_work_suspended_fraction": world_work_suspended_fraction,
        "render_loop_suspended_fraction": render_loop_suspended_fraction,
        "pending_background_work_count": pending_work_count,
        "background_queues_idle": background_queues_idle,
        "contributors": contributors,
    }


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
    vegetation_telemetry = snapshot.get("system_telemetry", {}).get("vegetation_manager", {})
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
            "runtime_power_external_world_busy",
            "runtime_power_world_work_suspended",
            "runtime_power_disabled_reason",
            "runtime_power_suspend_render_loop_in_deep_idle",
            "runtime_power_allow_unattended_render_suspend",
            "runtime_power_render_loop_suspend_gate",
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
            "terrain_skip_dry_water_density_dispatch",
            "water_render_enabled",
            "last_gpu_generation_batch_ms",
            "last_gpu_generation_sync_ms",
            "last_gpu_meshing_dispatch_ms",
            "last_gpu_meshing_sync_ms",
            "last_gpu_mesh_readback_ms",
            "last_gpu_mesh_slice_count",
            "last_gpu_mesh_slice_max_sync_ms",
            "last_gpu_water_density_dispatched",
            "gpu_water_density_skipped_count",
            "last_gpu_water_density_skipped_coord",
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
            "rendered_water_y0_chunk_count",
            "rendered_water_non_y0_chunk_count",
            "generated_water_surface_skip_count",
            "last_generated_water_surface_skip_coord",
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
            "world_map_terrain_visual_batch_size",
            "effective_terrain_visual_batch_size",
            "terrain_visual_batch_max_vertices",
            "world_map_terrain_visual_batch_max_vertices",
            "effective_terrain_visual_batch_max_vertices",
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
            "terrain_visual_batch_primitive_count",
            "terrain_visual_visible_primitive_count",
            "terrain_visual_batch_member_count",
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
    vegetation_render = {
        key: vegetation_telemetry.get(key)
        for key in [
            "global_render_batch_count",
            "global_tree_render_batch_count",
            "global_grass_render_batch_count",
            "global_rock_render_batch_count",
            "global_tree_render_instances",
            "global_grass_render_instances",
            "global_rock_render_instances",
            "global_render_estimated_primitives",
            "global_tree_render_estimated_primitives",
            "global_grass_render_estimated_primitives",
            "global_rock_render_estimated_primitives",
            "global_render_estimated_alpha_primitives",
            "global_render_estimated_alpha_empty_primitive_equivalent",
            "tree_alpha_texture_coverage_ratio",
            "tree_global_render_bounds_padding",
            "grass_global_render_bounds_padding",
            "rock_global_render_bounds_padding",
            "effective_vegetation_render_cluster_size",
            "effective_vegetation_grass_render_cluster_size",
            "effective_vegetation_rock_render_cluster_size",
            "vegetation_global_render_ignore_occlusion_culling",
            "global_tree_avg_batch_bounds_horizontal_area",
            "global_tree_max_batch_bounds_horizontal_area",
            "global_tree_max_batch_bounds_height",
            "global_tree_max_batch_bounds_diagonal",
            "global_render_dirty_cluster_count",
        ]
        if key in vegetation_telemetry
    }
    render_pressure = _build_render_pressure_summary(
        town_window,
        runtime_power,
        content,
        terrain_batch,
        vegetation_render,
    )
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
            "avg_process_ms": snapshot.get("avg_process_ms", town_window.get("avg_process_ms")),
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
            "avg_process_ms": moving_entry_window.get("avg_process_ms"),
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
            "avg_process_ms": stationary_hold_window.get("avg_process_ms"),
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
        "vegetation_render": vegetation_render,
        "render_pressure": render_pressure,
        "directional_render_sampling": snapshot.get("directional_render_sampling", {}),
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


def _terminate_godot_processes_for_thermal_abort() -> list[dict[str, Any]]:
    terminated: list[dict[str, Any]] = []
    for process in town_runner._find_running_godot_processes():
        try:
            pid = int(process.get("ProcessId", 0) or 0)
        except (TypeError, ValueError):
            continue
        if pid <= 0:
            continue
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                f"Stop-Process -Id {pid} -Force -ErrorAction SilentlyContinue",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
        )
        terminated.append(
            {
                "pid": pid,
                "name": process.get("Name"),
                "command_line": process.get("CommandLine"),
            }
        )
    return terminated


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


def _write_payload(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def _build_case_env(case_name: str, hold_seconds: float, measure_full_flight: bool) -> dict[str, str]:
    env = os.environ.copy()
    for key in RESET_ENV_KEYS:
        env.pop(key, None)
    default_timeout_seconds = max(420, int(hold_seconds + 300.0))
    env.update(
        {
            "TOWN_STALL_SEED": os.environ.get("TOWN_STALL_SEED", "12345"),
            "TOWN_STALL_AUTO_TELEPORT": os.environ.get("TOWN_STALL_AUTO_TELEPORT", "0"),
            "TOWN_STALL_REPEAT_ENTRY": os.environ.get("TOWN_STALL_REPEAT_ENTRY", "0"),
            "TOWN_STALL_HOLD_SECONDS": f"{hold_seconds:.3f}",
            "TOWN_STALL_TIMEOUT_SECONDS": os.environ.get("TOWN_STALL_TIMEOUT_SECONDS", str(default_timeout_seconds)),
            "TOWN_STALL_MACHINE_WARMUP_DISABLED": os.environ.get("TOWN_STALL_MACHINE_WARMUP_DISABLED", "1"),
            "TOWN_STALL_DISABLE_BUILDINGS": "0",
            "TOWN_STALL_DISABLE_ENTITIES": os.environ.get("TOWN_STALL_DISABLE_ENTITIES", "0"),
            "TOWN_STALL_DISABLE_TERRAIN_CHUNK_UPDATES": "0",
            "TOWN_STALL_DISABLE_EXIT_AUTOSAVE": "1",
            "TOWN_STALL_DISABLE_POSTRUN_IDLE_CHECK": os.environ.get("TOWN_STALL_DISABLE_POSTRUN_IDLE_CHECK", "1"),
            "TOWN_STALL_MEASURE_FULL_FLIGHT": "1" if measure_full_flight else os.environ.get("TOWN_STALL_MEASURE_FULL_FLIGHT", "0"),
            "TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS": os.environ.get("TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS", "1"),
        }
    )
    env.update(CASE_DEFINITIONS[case_name]["env"])
    return env


def _drain_process_stream(stream: Any, sink: list[str], echo_town_progress: bool) -> None:
    if stream is None:
        return
    try:
        for line in stream:
            sink.append(line)
            if echo_town_progress and "[TOWN_STALL_TEST]" in line:
                text = line.strip()
                if text:
                    print(f"  {text}", flush=True)
    except Exception as exc:
        sink.append(f"\n[stream-drain-error] {exc}\n")


def _run_town_case(case_name: str, repeat_index: int, hold_seconds: float, interval_seconds: float, measure_full_flight: bool, max_gpu_temp_c: Optional[float]) -> dict[str, Any]:
    _assert_no_godot_processes()
    print(f"Town run: {case_name} repeat {repeat_index}")
    run_start_mtime = time.time()
    env = _build_case_env(case_name, hold_seconds, measure_full_flight)
    sampler = GpuSampler(f"{case_name}_{repeat_index}", interval_seconds, max_gpu_temp_c)
    cmd = [PYTHON_BIN, str(Path(__file__).with_name("run_town_stall_test.py"))]
    started = time.time()
    sampler.start()
    timeout_seconds = _int_env("TOWN_STALL_RAW_RUN_TIMEOUT_SECONDS", max(420, int(hold_seconds + 300.0)))
    proc = subprocess.Popen(
        cmd,
        cwd=str(PROJECT_PATH),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    stdout_lines: list[str] = []
    stderr_lines: list[str] = []
    stdout_thread = threading.Thread(
        target=_drain_process_stream,
        args=(proc.stdout, stdout_lines, True),
        daemon=True,
    )
    stderr_thread = threading.Thread(
        target=_drain_process_stream,
        args=(proc.stderr, stderr_lines, False),
        daemon=True,
    )
    stdout_thread.start()
    stderr_thread.start()

    thermal_abort_reason: Optional[str] = None
    timeout_reason: Optional[str] = None
    terminated_godot_processes: list[dict[str, Any]] = []
    poll_sleep = min(0.25, max(0.05, interval_seconds / 4.0))
    last_progress_print = started
    while proc.poll() is None:
        if sampler.thermal_abort_event.is_set():
            sample = sampler.thermal_abort_sample or {}
            temp_c = sample.get("temp_c")
            thermal_abort_reason = f"gpu_temp_reached_{temp_c}C_limit_{max_gpu_temp_c}C"
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
            terminated_godot_processes = _terminate_godot_processes_for_thermal_abort()
            break
        if time.time() - started > timeout_seconds:
            timeout_reason = f"runner_timeout_after_{timeout_seconds}s"
            proc.kill()
            terminated_godot_processes = _terminate_godot_processes_for_thermal_abort()
            break
        if time.time() - last_progress_print >= 15.0:
            last_progress_print = time.time()
            latest_sample = sampler.samples[-1] if sampler.samples else {}
            temp_c = latest_sample.get("temp_c", "?") if isinstance(latest_sample, dict) else "?"
            power_w = latest_sample.get("power_w", "?") if isinstance(latest_sample, dict) else "?"
            print(
                f"  [raw-baseline] running {last_progress_print - started:.0f}s "
                f"gpu_power={power_w}W temp={temp_c}C",
                flush=True,
            )
        time.sleep(poll_sleep)

    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
    stdout_thread.join(timeout=5)
    stderr_thread.join(timeout=5)
    stdout = "".join(stdout_lines)
    stderr = "".join(stderr_lines)
    ended = time.time()
    sampler.stop()
    orphaned_godot_processes: list[dict[str, Any]] = []
    orphaned_godot_reason = ""
    try:
        _assert_no_godot_processes()
    except RuntimeError as exc:
        orphaned_godot_reason = repr(exc)
        orphaned_godot_processes = _terminate_godot_processes_for_thermal_abort()

    snapshot_path = _latest_snapshot(run_start_mtime - 1.0)
    snapshot = _load_snapshot_summary(snapshot_path)
    returncode = proc.returncode if proc.returncode is not None else -1
    output = (stdout or "") + "\n" + (stderr or "")
    failure_reasons = town_runner._detect_run_failure(output, returncode)
    if orphaned_godot_reason:
        failure_reasons.append("orphaned_godot_after_run")
    if thermal_abort_reason:
        failure_reasons.append(f"thermal_abort:{thermal_abort_reason}")
    if timeout_reason:
        failure_reasons.append(timeout_reason)
    hold_completed = "[town_stall_test] hold complete, quitting" in output.lower()
    hold_started = "[town_stall_test] hold started" in output.lower()
    if hold_started:
        failure_reasons = [reason for reason in failure_reasons if reason != "town hold never started"]
        if not snapshot:
            failure_reasons.append("snapshot_missing_after_hold_started")
    shutdown_av = returncode == 3221225477
    if shutdown_av and snapshot_path and hold_completed:
        failure_reasons = [reason for reason in failure_reasons if reason != f"process exited with code {returncode}"]

    result: dict[str, Any] = {
        "case": case_name,
        "repeat_index": repeat_index,
        "description": CASE_DEFINITIONS[case_name]["description"],
        "env_overrides": {key: env.get(key, "") for key in sorted(set(RESET_ENV_KEYS + [
            "TOWN_STALL_HOLD_SECONDS",
            "TOWN_STALL_MEASURE_FULL_FLIGHT",
            "TOWN_STALL_REPEAT_ENTRY",
            "TOWN_STALL_DIRECTIONAL_RENDER_SAMPLING",
            "TOWN_STALL_DIRECTIONAL_RENDER_SAMPLE_SECONDS",
            "TOWN_STALL_DIRECTIONAL_RENDER_SETTLE_SECONDS",
            "TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS",
            "TOWN_STALL_PERIODIC_PREHOLD_SNAPSHOTS",
            "TOWN_STALL_PREHOLD_SNAPSHOT_INTERVAL_SECONDS",
        ]))},
        "started_at_epoch": started,
        "ended_at_epoch": ended,
        "duration_s": ended - started,
        "returncode": returncode,
        "failure_reasons": failure_reasons,
        "max_gpu_temp_c": max_gpu_temp_c,
        "thermal_abort_reason": thermal_abort_reason,
        "thermal_abort_sample": sampler.thermal_abort_sample,
        "terminated_godot_processes": terminated_godot_processes,
        "orphaned_godot_reason": orphaned_godot_reason,
        "orphaned_godot_processes": orphaned_godot_processes,
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
    directional_render_sampling = snapshot.get("directional_render_sampling", {}) if isinstance(snapshot, dict) else {}
    if isinstance(directional_render_sampling, dict) and directional_render_sampling.get("enabled"):
        result["directional_render_gpu"] = _summarize_directional_render_gpu(sampler.samples, directional_render_sampling)
    town_metrics = snapshot.get("town_metrics", {}) if isinstance(snapshot, dict) else {}
    moving_metrics = snapshot.get("moving_entry_metrics", {}) if isinstance(snapshot, dict) else {}
    stationary_metrics = snapshot.get("stationary_hold_metrics", {}) if isinstance(snapshot, dict) else {}
    result["efficiency"] = {
        "metric": "wpf60",
        "target_wpf60": 16.0,
        "hold_wpf60": _wpf60(result.get("estimated_hold_gpu", {}).get("avg_power_w"), town_metrics.get("average_fps")),
        "moving_wpf60": _wpf60(result.get("moving_entry_gpu", {}).get("avg_power_w"), moving_metrics.get("average_fps")),
        "stationary_hold_wpf60": _wpf60(result.get("stationary_hold_gpu", {}).get("avg_power_w"), stationary_metrics.get("average_fps")),
        "last20_wpf60": _wpf60(result.get("last_20s_gpu", {}).get("avg_power_w"), town_metrics.get("average_fps")),
    }
    if failure_reasons:
        result["stdout_tail"] = "\n".join((stdout or "").splitlines()[-120:])
        result["stderr_tail"] = "\n".join((stderr or "").splitlines()[-120:])
    return result


def _case_summary_line(run: dict[str, Any]) -> str:
    hold = run.get("estimated_hold_gpu", {})
    last20 = run.get("last_20s_gpu", {})
    moving_gpu = run.get("moving_entry_gpu", {})
    stationary_gpu = run.get("stationary_hold_gpu", {})
    town_metrics = run.get("snapshot", {}).get("town_metrics", {})
    content = run.get("snapshot", {}).get("content", {})
    stream = run.get("snapshot", {}).get("stream_gate", {})
    vegetation = run.get("snapshot", {}).get("vegetation_render", {})
    render_pressure = run.get("snapshot", {}).get("render_pressure", {})
    power = hold.get("avg_power_w")
    last20_power = last20.get("avg_power_w")
    moving_power = moving_gpu.get("avg_power_w") if isinstance(moving_gpu, dict) else None
    stationary_power = stationary_gpu.get("avg_power_w") if isinstance(stationary_gpu, dict) else None
    efficiency = run.get("efficiency", {})
    moving_wpf60 = efficiency.get("moving_wpf60") if isinstance(efficiency, dict) else None
    hold_wpf60 = efficiency.get("hold_wpf60") if isinstance(efficiency, dict) else None
    pstate = hold.get("pstates", {})
    fps = town_metrics.get("average_fps")
    moving = run.get("snapshot", {}).get("moving_entry_metrics", {})
    moving_fps = moving.get("average_fps")
    moving_over_40 = moving.get("frames_over_40ms")
    terrain = content.get("rendered_terrain_chunk_count")
    water = content.get("rendered_water_chunk_count")
    tree_primitives = vegetation.get("global_tree_render_estimated_primitives")
    tree_bounds = vegetation.get("global_tree_avg_batch_bounds_horizontal_area")
    terrain_primitives = render_pressure.get("terrain_visual_primitives")
    alpha_empty = render_pressure.get("alpha_empty_primitive_equivalent")
    pressure_contributors = render_pressure.get("contributors", [])
    pressure_text = ""
    if isinstance(pressure_contributors, list) and pressure_contributors:
        pressure_text = " pressure=" + ",".join(str(value) for value in pressure_contributors[:4])
    valid = content.get("content_valid_for_power_compare")
    reasons = content.get("content_validation_reasons")
    gate = stream.get("last_terrain_stream_update_gate_reason")
    directional_text = _directional_render_summary_text(run.get("snapshot", {}))
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
        f"wpf60={hold_wpf60:.2f} moving_wpf60={moving_wpf60:.2f} "
        if isinstance(hold_wpf60, (int, float)) and isinstance(moving_wpf60, (int, float))
        else "wpf60=? moving_wpf60=? "
    ) + (
        f"pstates={pstate} fps={fps} moving_fps={moving_fps} "
        f"moving_over40={moving_over_40} terrain={terrain} water={water} "
        f"terrain_prims={terrain_primitives} tree_prims={tree_primitives} "
        f"alpha_empty={alpha_empty} tree_avg_bounds_area={tree_bounds} "
        f"valid={valid} gate={gate}{directional_text}{pressure_text}{reason_text}"
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
        hold_wpf60_values = [
            float(run["efficiency"]["hold_wpf60"])
            for run in comparison_runs
            if isinstance(run.get("efficiency", {}).get("hold_wpf60"), (int, float))
        ]
        moving_wpf60_values = [
            float(run["efficiency"]["moving_wpf60"])
            for run in comparison_runs
            if isinstance(run.get("efficiency", {}).get("moving_wpf60"), (int, float))
        ]
        stationary_hold_wpf60_values = [
            float(run["efficiency"]["stationary_hold_wpf60"])
            for run in comparison_runs
            if isinstance(run.get("efficiency", {}).get("stationary_hold_wpf60"), (int, float))
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
            "avg_hold_wpf60": _avg(hold_wpf60_values),
            "avg_moving_wpf60": _avg(moving_wpf60_values),
            "avg_stationary_hold_wpf60": _avg(stationary_hold_wpf60_values),
        }
    return aggregate


def main() -> int:
    suppress_windows_error_dialogs()
    parser = argparse.ArgumentParser(description="Run repeated raw nvidia-smi town-stall baselines.")
    parser.add_argument("--cases", default="fixed60,runtime_default", help="Comma-separated cases; use --cases runtime_deepidle60,runtime_deepidle60_tree_clusters_1,runtime_deepidle60_tree_clusters_4,runtime_deepidle60_veg_occlusion_culling,runtime_deepidle60_terrain_batch_1 for 60 FPS render A/B.")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--hold-seconds", type=float, default=40.0)
    parser.add_argument("--idle-seconds", type=float, default=20.0)
    parser.add_argument("--sample-interval", type=float, default=1.0)
    parser.add_argument("--measure-full-flight", action="store_true")
    parser.add_argument("--allow-contaminated-idle", action="store_true", help="Run even when raw idle telemetry indicates external CPU/GPU load.")
    parser.add_argument("--max-gpu-temp-c", type=float, default=_float_env("TOWN_STALL_MAX_GPU_TEMP_C", DEFAULT_RUN_MAX_GPU_TEMP_C), help="Abort the active run and terminate Godot if raw nvidia-smi temperature reaches this value. Use 0 to disable.")
    parser.add_argument("--preflight-max-gpu-temp-c", type=float, default=_float_env("TOWN_STALL_PREFLIGHT_MAX_GPU_TEMP_C", 0.0), help="Wait before launching until raw nvidia-smi GPU temperature is at or below this value. Use 0 to disable.")
    parser.add_argument("--preflight-cooldown-timeout-seconds", type=float, default=_float_env("TOWN_STALL_PREFLIGHT_COOLDOWN_TIMEOUT_SECONDS", 0.0), help="Maximum seconds to wait for the preflight GPU cooldown gate.")
    parser.add_argument("--preflight-cooldown-poll-seconds", type=float, default=_float_env("TOWN_STALL_PREFLIGHT_COOLDOWN_POLL_SECONDS", 10.0), help="Polling interval for the preflight GPU cooldown gate.")
    args = parser.parse_args()

    case_names = [case.strip() for case in args.cases.split(",") if case.strip()]
    unknown = [case for case in case_names if case not in CASE_DEFINITIONS]
    if unknown:
        print(f"Unknown case(s): {', '.join(unknown)}")
        return 2
    if args.repeats <= 0:
        print("--repeats must be positive")
        return 2
    if args.allow_contaminated_idle:
        os.environ["TOWN_STALL_ALLOW_CONTAMINATED_IDLE"] = "1"

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    started = time.time()
    slug = _timestamp_slug()
    output_path = OUTPUT_DIR / f"town_stall_raw_baseline_{slug}.json"
    print(f"Raw baseline output: {output_path}")
    _assert_no_godot_processes()

    preflight_cooldown = _wait_for_preflight_gpu_temperature(
        args.preflight_max_gpu_temp_c,
        args.preflight_cooldown_timeout_seconds,
        args.preflight_cooldown_poll_seconds,
    )
    if preflight_cooldown.get("enabled") and not preflight_cooldown.get("reached", False):
        payload = {
            "started_at_epoch": started,
            "ended_at_epoch": time.time(),
            "duration_s": time.time() - started,
            "project_path": str(PROJECT_PATH),
            "cases": case_names,
            "repeats": args.repeats,
            "hold_seconds": args.hold_seconds,
            "idle_seconds": args.idle_seconds,
            "sample_interval_seconds": args.sample_interval,
            "measure_full_flight": args.measure_full_flight,
            "allow_contaminated_idle": args.allow_contaminated_idle,
            "max_gpu_temp_c": args.max_gpu_temp_c,
            "preflight_max_gpu_temp_c": args.preflight_max_gpu_temp_c,
            "preflight_cooldown": preflight_cooldown,
            "aborted_reason": "preflight_gpu_temp_not_cooled",
            "runs": [],
        }
        _write_payload(output_path, payload)
        print(f"Preflight GPU temperature did not cool to <= {args.preflight_max_gpu_temp_c:.1f}C; refusing to launch.")
        print(f"Wrote {output_path}")
        return 4

    preflight_machine_state = town_runner._collect_machine_state()
    initial_idle = _run_idle_sample("initial_idle", args.idle_seconds, args.sample_interval)
    contamination_thresholds = _idle_contamination_thresholds()
    initial_contamination_reasons = _idle_contamination_reasons(initial_idle, preflight_machine_state, contamination_thresholds)

    payload: dict[str, Any] = {
        "started_at_epoch": started,
        "project_path": str(PROJECT_PATH),
        "cases": case_names,
        "repeats": args.repeats,
        "hold_seconds": args.hold_seconds,
        "idle_seconds": args.idle_seconds,
        "sample_interval_seconds": args.sample_interval,
        "measure_full_flight": args.measure_full_flight,
        "allow_contaminated_idle": args.allow_contaminated_idle,
        "max_gpu_temp_c": args.max_gpu_temp_c,
        "preflight_max_gpu_temp_c": args.preflight_max_gpu_temp_c,
        "preflight_cooldown": preflight_cooldown,
        "preflight_machine_state": preflight_machine_state,
        "initial_idle": initial_idle,
        "contamination": {
            "thresholds": contamination_thresholds,
            "initial_idle_reasons": initial_contamination_reasons,
            "initial_idle_clean": not initial_contamination_reasons,
        },
        "between_case_cooldowns": [],
        "runs": [],
    }

    if initial_contamination_reasons and not args.allow_contaminated_idle:
        payload["ended_at_epoch"] = time.time()
        payload["duration_s"] = payload["ended_at_epoch"] - started
        payload["aborted_reason"] = "initial_idle_contaminated"
        _write_payload(output_path, payload)
        print(f"Initial idle contaminated: {', '.join(initial_contamination_reasons)}")
        print(f"Wrote {output_path}")
        return 3

    exit_code = 0
    matrix_aborted_reason: Optional[str] = None
    case_run_index = 0
    for repeat_index in range(1, args.repeats + 1):
        for case_name in case_names:
            if case_run_index > 0 and args.preflight_max_gpu_temp_c > 0:
                cooldown = _wait_for_preflight_gpu_temperature(
                    args.preflight_max_gpu_temp_c,
                    args.preflight_cooldown_timeout_seconds,
                    args.preflight_cooldown_poll_seconds,
                )
                cooldown["before_case"] = case_name
                cooldown["repeat_index"] = repeat_index
                payload["between_case_cooldowns"].append(cooldown)
                if not cooldown.get("reached", False):
                    matrix_aborted_reason = "between_case_gpu_temp_not_cooled"
                    payload["aborted_reason"] = matrix_aborted_reason
                    payload["aborted_before_case"] = case_name
                    exit_code = 1
                    _write_payload(output_path, payload)
                    print(f"Stopping matrix before {case_name}: GPU did not cool to <= {args.preflight_max_gpu_temp_c:.1f}C")
                    break
            run = _run_town_case(case_name, repeat_index, args.hold_seconds, args.sample_interval, args.measure_full_flight, args.max_gpu_temp_c)
            case_run_index += 1
            payload["runs"].append(run)
            print(_case_summary_line(run))
            if run.get("failure_reasons"):
                exit_code = 1
            payload["ended_at_epoch"] = time.time()
            payload["duration_s"] = payload["ended_at_epoch"] - started
            payload["aggregate"] = _aggregate_case_runs(payload["runs"])
            if run.get("thermal_abort_reason"):
                matrix_aborted_reason = f"thermal_abort:{run.get('thermal_abort_reason')}"
                payload["aborted_reason"] = matrix_aborted_reason
                payload["aborted_after_case"] = run.get("case")
                exit_code = 1
            _write_payload(output_path, payload)
            if matrix_aborted_reason:
                print(f"Stopping matrix after {matrix_aborted_reason}")
                break
        if matrix_aborted_reason:
            break

    final_contamination_reasons: list[str] = []
    try:
        payload["final_idle"] = _run_idle_sample("final_idle", args.idle_seconds, args.sample_interval)
        final_contamination_reasons = _idle_contamination_reasons(payload["final_idle"], town_runner._collect_machine_state(), contamination_thresholds)
    except RuntimeError as exc:
        final_contamination_reasons = ["final_idle_orphaned_godot"]
        payload["final_idle"] = {
            "label": "final_idle",
            "error": repr(exc),
            "terminated_godot_processes": _terminate_godot_processes_for_thermal_abort(),
        }
        exit_code = 1
    payload["contamination"]["final_idle_reasons"] = final_contamination_reasons
    payload["contamination"]["final_idle_clean"] = not final_contamination_reasons
    payload["contamination"]["comparison_clean"] = not initial_contamination_reasons and not final_contamination_reasons
    if final_contamination_reasons and not args.allow_contaminated_idle:
        exit_code = 1
    if final_contamination_reasons:
        print(f"Final idle contaminated: {', '.join(final_contamination_reasons)}")
    payload["ended_at_epoch"] = time.time()
    payload["duration_s"] = payload["ended_at_epoch"] - started
    payload["aggregate"] = _aggregate_case_runs(payload["runs"])
    _write_payload(output_path, payload)

    print("Aggregate:")
    print(json.dumps(payload["aggregate"], indent=2))
    print(f"Wrote {output_path}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
