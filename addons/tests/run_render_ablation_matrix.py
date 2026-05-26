import json
import os
import subprocess
import sys
import time
from pathlib import Path

import run_town_stall_test
from windows_error_dialogs import suppress_windows_error_dialogs


SUMMARY_FILE = Path(run_town_stall_test.PROJECT_PATH) / ".agent" / "render-ablation-summary.json"
FPS_60_FRAME_MS = 1000.0 / 60.0


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw not in {"0", "false", "off", "no"}


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


CASES = {
    "baseline": {},
    "hide_terrain_manager_visuals": {"TOWN_STALL_DISABLE_TERRAIN_MANAGER_VISUALS": "1"},
    "hide_vegetation_render": {"TOWN_STALL_DISABLE_VEGETATION_RENDER": "1"},
    "no_trees": {"TOWN_STALL_VEGETATION_RENDER_TREES": "0"},
    "no_grass": {"TOWN_STALL_VEGETATION_RENDER_GRASS": "0"},
    "no_rocks": {"TOWN_STALL_VEGETATION_RENDER_ROCKS": "0"},
    "vegetation_trees_only": {
        "TOWN_STALL_VEGETATION_RENDER_TREES": "1",
        "TOWN_STALL_VEGETATION_RENDER_GRASS": "0",
        "TOWN_STALL_VEGETATION_RENDER_ROCKS": "0",
    },
    "vegetation_grass_only": {
        "TOWN_STALL_VEGETATION_RENDER_TREES": "0",
        "TOWN_STALL_VEGETATION_RENDER_GRASS": "1",
        "TOWN_STALL_VEGETATION_RENDER_ROCKS": "0",
    },
    "vegetation_rocks_only": {
        "TOWN_STALL_VEGETATION_RENDER_TREES": "0",
        "TOWN_STALL_VEGETATION_RENDER_GRASS": "0",
        "TOWN_STALL_VEGETATION_RENDER_ROCKS": "1",
    },
    "vegetation_grass_rock_20x_stress": {
        "TOWN_STALL_VEGETATION_DENSE_GRASS": "1",
        "TOWN_STALL_VEGETATION_GRASS_STEP": "1",
        "TOWN_STALL_VEGETATION_GRASS_NOISE_THRESHOLD": "-1",
        "TOWN_STALL_VEGETATION_ROCK_STEP": "2",
        "TOWN_STALL_VEGETATION_ROCK_NOISE_THRESHOLD": "-1",
    },
    "vegetation_lod_bias_0_5": {"TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.5"},
    "vegetation_lod_bias_0_25": {"TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.25"},
    "vegetation_cluster_3": {
        "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "3",
        "TOWN_STALL_WORLD_MAP_VEGETATION_GRASS_RENDER_CLUSTER_SIZE": "3",
    },
    "vegetation_cluster_4": {
        "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "4",
        "TOWN_STALL_WORLD_MAP_VEGETATION_GRASS_RENDER_CLUSTER_SIZE": "6",
    },
    "vegetation_cluster_3_lod_0_5": {
        "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "3",
        "TOWN_STALL_WORLD_MAP_VEGETATION_GRASS_RENDER_CLUSTER_SIZE": "3",
        "TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.5",
    },
    "vegetation_bounds_padding_48": {"TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "48"},
    "vegetation_bounds_padding_32": {"TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "32"},
    "vegetation_exact_bounds_off": {"TOWN_STALL_VEGETATION_EXACT_RENDER_BOUNDS": "0"},
    "vegetation_exact_bounds_padding_0": {"TOWN_STALL_VEGETATION_EXACT_RENDER_BOUNDS_PADDING": "0"},
    "vegetation_opaque_material_opt_off": {"TOWN_STALL_VEGETATION_OPAQUE_MATERIAL_OPTIMIZATION": "0"},
    "vegetation_bounds_32_lod_0_5": {
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "32",
        "TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.5",
    },
    "vegetation_bounds_32_lod_0_25": {
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "32",
        "TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.25",
    },
    "tree_cluster_4_bounds_32": {
        "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "4",
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "32",
    },
    "tree_cluster_4_bounds_32_lod_0_5": {
        "TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_CLUSTER_SIZE": "4",
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "32",
        "TOWN_STALL_VEGETATION_RENDER_LOD_BIAS": "0.5",
    },
    "vegetation_occlusion_culling": {"TOWN_STALL_VEGETATION_GLOBAL_RENDER_IGNORE_OCCLUSION_CULLING": "0"},
    "vegetation_bounds_48_occlusion": {
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_BOUNDS_PADDING": "48",
        "TOWN_STALL_VEGETATION_GLOBAL_RENDER_IGNORE_OCCLUSION_CULLING": "0",
    },
    "terrain_batch_1": {"TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_SIZE": "1"},
    "terrain_batch_3": {"TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_SIZE": "3"},
    "terrain_batch_4": {"TOWN_STALL_WORLD_MAP_TERRAIN_VISUAL_BATCH_SIZE": "4"},
    "terrain_batching_off": {"TOWN_STALL_TERRAIN_VISUAL_BATCHING": "0"},
    "terrain_unload_hysteresis_2": {"TOWN_STALL_TERRAIN_UNLOAD_HYSTERESIS_CHUNKS": "2"},
    "hide_terrain_and_vegetation": {
        "TOWN_STALL_DISABLE_TERRAIN_MANAGER_VISUALS": "1",
        "TOWN_STALL_DISABLE_VEGETATION_RENDER": "1",
    },
    "no_water": {"TOWN_STALL_DISABLE_WATER_RENDER": "1"},
    "no_buildings": {"TOWN_STALL_DISABLE_BUILDINGS": "1"},
    "no_building_objects": {"TOWN_STALL_DISABLE_BUILDING_OBJECTS": "1"},
    "no_entities": {"TOWN_STALL_DISABLE_ENTITIES": "1"},
    "runtime_power_idle30": {
        "TOWN_STALL_RUNTIME_POWER_IDLE_FPS": "30",
        "TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS": "30",
    },
    "entities_radius_10_limit_200": {
        "TOWN_STALL_ENTITY_MAX_ENTITIES": "200",
        "TOWN_STALL_ENTITY_SPAWN_RADIUS": "285",
        "TOWN_STALL_ENTITY_DESPAWN_RADIUS": "360",
        "TOWN_STALL_ENTITY_SPAWN_CHANCE_PER_CHUNK": "1.0",
        "TOWN_STALL_ENTITY_MIN_SPAWN_DISTANCE": "12",
        "TOWN_STALL_ENTITY_MAX_SPAWNS_PER_CHUNK": "4",
        "TOWN_STALL_ENTITY_BALANCE_SPAWN_DISTANCE_RINGS": "1",
        "TOWN_STALL_ENTITY_SPAWN_DISTANCE_RING_COUNT": "10",
        "TOWN_STALL_ENTITY_PENDING_SPAWN_CHECKS_PER_FRAME": "64",
        "TOWN_STALL_ENTITY_DORMANT_RESPAWN_CHECKS_PER_FRAME": "64",
        "TOWN_STALL_ENTITY_DEFERRED_SPAWN_CHUNKS_PER_FRAME": "128",
        "TOWN_STALL_ENTITY_SPAWN_QUEUE_BUDGET_MS": "2.0",
        "TOWN_STALL_ENTITY_DORMANT_RESPAWN_BUDGET_MS": "2.0",
        "TOWN_STALL_ENTITY_MAINTENANCE_BUDGET_MS": "4.0",
    },
    "entities_full_roam_distance_10_limit_200": {
        "TOWN_STALL_TERRAIN_COLLISION_DISTANCE": "10",
        "TOWN_STALL_TERRAIN_COLLISION_GROUND_CENTER": "1",
        "TOWN_STALL_ENTITY_MAX_ENTITIES": "200",
        "TOWN_STALL_ENTITY_SPAWN_RADIUS": "285",
        "TOWN_STALL_ENTITY_ACTIVE_PHYSICS_RADIUS": "310",
        "TOWN_STALL_ENTITY_FREEZE_RADIUS": "310",
        "TOWN_STALL_ENTITY_DESPAWN_RADIUS": "360",
        "TOWN_STALL_ENTITY_FREEZE_COLLISION_MARGIN": "0",
        "TOWN_STALL_ENTITY_SPAWN_CHANCE_PER_CHUNK": "1.0",
        "TOWN_STALL_ENTITY_MIN_SPAWN_DISTANCE": "12",
        "TOWN_STALL_ENTITY_MAX_SPAWNS_PER_CHUNK": "4",
        "TOWN_STALL_ENTITY_BALANCE_SPAWN_DISTANCE_RINGS": "1",
        "TOWN_STALL_ENTITY_SPAWN_DISTANCE_RING_COUNT": "10",
        "TOWN_STALL_ENTITY_PENDING_SPAWN_CHECKS_PER_FRAME": "64",
        "TOWN_STALL_ENTITY_DORMANT_RESPAWN_CHECKS_PER_FRAME": "64",
        "TOWN_STALL_ENTITY_DEFERRED_SPAWN_CHUNKS_PER_FRAME": "128",
        "TOWN_STALL_ENTITY_SPAWN_QUEUE_BUDGET_MS": "2.0",
        "TOWN_STALL_ENTITY_DORMANT_RESPAWN_BUDGET_MS": "2.0",
        "TOWN_STALL_ENTITY_MAINTENANCE_BUDGET_MS": "4.0",
    },
    "no_veg_entities_full_roam_distance_10_limit_200": {
        "TOWN_STALL_DISABLE_VEGETATION_RENDER": "1",
        "TOWN_STALL_TERRAIN_COLLISION_DISTANCE": "10",
        "TOWN_STALL_TERRAIN_COLLISION_GROUND_CENTER": "1",
        "TOWN_STALL_ENTITY_MAX_ENTITIES": "200",
        "TOWN_STALL_ENTITY_SPAWN_RADIUS": "310",
        "TOWN_STALL_ENTITY_ACTIVE_PHYSICS_RADIUS": "310",
        "TOWN_STALL_ENTITY_FREEZE_RADIUS": "310",
        "TOWN_STALL_ENTITY_DESPAWN_RADIUS": "360",
        "TOWN_STALL_ENTITY_FREEZE_COLLISION_MARGIN": "0",
        "TOWN_STALL_ENTITY_SPAWN_CHANCE_PER_CHUNK": "1.0",
        "TOWN_STALL_ENTITY_MIN_SPAWN_DISTANCE": "12",
        "TOWN_STALL_ENTITY_MAX_SPAWNS_PER_CHUNK": "4",
        "TOWN_STALL_ENTITY_BALANCE_SPAWN_DISTANCE_RINGS": "1",
        "TOWN_STALL_ENTITY_SPAWN_DISTANCE_RING_COUNT": "10",
        "TOWN_STALL_ENTITY_PENDING_SPAWN_CHECKS_PER_FRAME": "64",
        "TOWN_STALL_ENTITY_DORMANT_RESPAWN_CHECKS_PER_FRAME": "64",
        "TOWN_STALL_ENTITY_DEFERRED_SPAWN_CHUNKS_PER_FRAME": "128",
        "TOWN_STALL_ENTITY_SPAWN_QUEUE_BUDGET_MS": "2.0",
        "TOWN_STALL_ENTITY_DORMANT_RESPAWN_BUDGET_MS": "2.0",
        "TOWN_STALL_ENTITY_MAINTENANCE_BUDGET_MS": "4.0",
    },
    "no_veg_entities_balanced_distance_10_limit_400": {
        "TOWN_STALL_DISABLE_VEGETATION_RENDER": "1",
        "TOWN_STALL_TERRAIN_COLLISION_DISTANCE": "10",
        "TOWN_STALL_TERRAIN_COLLISION_GROUND_CENTER": "1",
        "TOWN_STALL_SHARED_TERRAIN_COLLISION_CREATE_BUDGET": "16",
        "TOWN_STALL_ENTITY_MAX_ENTITIES": "400",
        "TOWN_STALL_ENTITY_SPAWN_RADIUS": "285",
        "TOWN_STALL_ENTITY_ACTIVE_PHYSICS_RADIUS": "310",
        "TOWN_STALL_ENTITY_FREEZE_RADIUS": "310",
        "TOWN_STALL_ENTITY_DESPAWN_RADIUS": "360",
        "TOWN_STALL_ENTITY_FREEZE_COLLISION_MARGIN": "0",
        "TOWN_STALL_ENTITY_SPAWN_CHANCE_PER_CHUNK": "0.0",
        "TOWN_STALL_ENTITY_MIN_SPAWN_DISTANCE": "12",
        "TOWN_STALL_ENTITY_MAX_SPAWNS_PER_CHUNK": "4",
        "TOWN_STALL_ENTITY_BALANCE_SPAWN_DISTANCE_RINGS": "1",
        "TOWN_STALL_ENTITY_SPAWN_DISTANCE_RING_COUNT": "10",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL": "1",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL_TARGET": "400",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL_INTERVAL": "0.05",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL_CANDIDATES_PER_TICK": "128",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL_AREA_WEIGHTED": "1",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL_RECENTER_DISTANCE": "64",
        "TOWN_STALL_ENTITY_PENDING_SPAWN_CHECKS_PER_FRAME": "128",
        "TOWN_STALL_ENTITY_DORMANT_RESPAWN_CHECKS_PER_FRAME": "128",
        "TOWN_STALL_ENTITY_DEFERRED_SPAWN_CHUNKS_PER_FRAME": "256",
        "TOWN_STALL_ENTITY_SPAWN_QUEUE_BUDGET_MS": "4.0",
        "TOWN_STALL_ENTITY_DORMANT_RESPAWN_BUDGET_MS": "4.0",
        "TOWN_STALL_ENTITY_MAINTENANCE_BUDGET_MS": "6.0",
    },
    "no_veg_entities_balanced_distance_10_limit_400_active80": {
        "TOWN_STALL_DISABLE_VEGETATION_RENDER": "1",
        "TOWN_STALL_TERRAIN_COLLISION_DISTANCE": "10",
        "TOWN_STALL_TERRAIN_COLLISION_GROUND_CENTER": "1",
        "TOWN_STALL_SHARED_TERRAIN_COLLISION_CREATE_BUDGET": "16",
        "TOWN_STALL_ENTITY_MAX_ENTITIES": "400",
        "TOWN_STALL_ENTITY_SPAWN_RADIUS": "285",
        "TOWN_STALL_ENTITY_ACTIVE_PHYSICS_RADIUS": "80",
        "TOWN_STALL_ENTITY_FREEZE_RADIUS": "310",
        "TOWN_STALL_ENTITY_DESPAWN_RADIUS": "360",
        "TOWN_STALL_ENTITY_FREEZE_COLLISION_MARGIN": "0",
        "TOWN_STALL_ENTITY_SPAWN_CHANCE_PER_CHUNK": "0.0",
        "TOWN_STALL_ENTITY_MIN_SPAWN_DISTANCE": "12",
        "TOWN_STALL_ENTITY_MAX_SPAWNS_PER_CHUNK": "4",
        "TOWN_STALL_ENTITY_BALANCE_SPAWN_DISTANCE_RINGS": "1",
        "TOWN_STALL_ENTITY_SPAWN_DISTANCE_RING_COUNT": "10",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL": "1",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL_TARGET": "400",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL_INTERVAL": "0.05",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL_CANDIDATES_PER_TICK": "128",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL_AREA_WEIGHTED": "1",
        "TOWN_STALL_ENTITY_BALANCED_RING_FILL_RECENTER_DISTANCE": "64",
        "TOWN_STALL_ENTITY_PENDING_SPAWN_CHECKS_PER_FRAME": "128",
        "TOWN_STALL_ENTITY_DORMANT_RESPAWN_CHECKS_PER_FRAME": "128",
        "TOWN_STALL_ENTITY_DEFERRED_SPAWN_CHUNKS_PER_FRAME": "256",
        "TOWN_STALL_ENTITY_SPAWN_QUEUE_BUDGET_MS": "4.0",
        "TOWN_STALL_ENTITY_DORMANT_RESPAWN_BUDGET_MS": "4.0",
        "TOWN_STALL_ENTITY_MAINTENANCE_BUDGET_MS": "6.0",
    },
    "no_glow": {"TOWN_STALL_DISABLE_GLOW": "1"},
    "no_world_map_veg_profile": {"TOWN_STALL_WORLD_MAP_VEGETATION_RENDER_PROFILE": "0"},
}


def _selected_case_names() -> list[str]:
    raw = os.environ.get(
        "TOWN_STALL_ABLATION_CASES",
        "baseline,hide_terrain_manager_visuals,hide_vegetation_render,hide_terrain_and_vegetation,no_water",
    )
    names = [name.strip() for name in raw.split(",") if name.strip()]
    # Vegetation LOD is intentionally future work; keep these cases opt-in so
    # routine render tests cannot accidentally validate a visual shortcut.
    allow_vegetation_lod_cases = os.environ.get("TOWN_STALL_ALLOW_VEGETATION_LOD_CASES", "").strip() == "1"
    selected: list[str] = []
    for name in names:
        if name not in CASES:
            print(f"WARNING: Unknown ablation case '{name}', skipping.")
            continue
        if "vegetation" in name and "lod" in name and not allow_vegetation_lod_cases:
            print(f"WARNING: Vegetation LOD ablation case '{name}' requires TOWN_STALL_ALLOW_VEGETATION_LOD_CASES=1; skipping.")
            continue
        selected.append(name)
    return selected or ["baseline"]


def _read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _pick_window_metric(stationary_hold: dict, town_window: dict, metric: str) -> float:
    active_metric = f"{metric}_render_active"
    for window in (stationary_hold, town_window):
        if int(window.get("render_active_sample_count", 0) or 0) > 0:
            return float(window.get(active_metric, window.get(metric, 0.0)) or 0.0)
    return float(stationary_hold.get(metric, town_window.get(metric, 0.0)) or 0.0)


def _pick_window_int_metric(stationary_hold: dict, town_window: dict, metric: str) -> int:
    active_metric = f"{metric}_render_active"
    for window in (stationary_hold, town_window):
        if int(window.get("render_active_sample_count", 0) or 0) > 0:
            return int(window.get(active_metric, window.get(metric, 0)) or 0)
    return int(stationary_hold.get(metric, town_window.get(metric, 0)) or 0)


def _pick_active_sample_count(stationary_hold: dict, town_window: dict) -> int:
    stationary_active_samples = int(stationary_hold.get("render_active_sample_count", 0) or 0)
    if stationary_active_samples > 0:
        return stationary_active_samples
    return int(town_window.get("render_active_sample_count", 0) or 0)


def _summary_avg(summary: dict, key: str) -> float:
    value = summary.get(key, {}) if isinstance(summary, dict) else {}
    if not isinstance(value, dict):
        return 0.0
    return float(value.get("avg", 0.0) or 0.0)


def _wpf60(power_w: float, frame_ms: float) -> float:
    if power_w <= 0.0 or frame_ms <= 0.0:
        return 0.0
    return power_w * frame_ms / FPS_60_FRAME_MS


def _per_scaled_unit(value: float, denominator: float, scale: float) -> float:
    if value <= 0.0 or denominator <= 0.0 or scale <= 0.0:
        return 0.0
    return value / (denominator / scale)


def _phase_window(system_summary: dict, phase: str) -> dict:
    windows = system_summary.get("phase_windows", {}) if isinstance(system_summary, dict) else {}
    window = windows.get(phase, {}) if isinstance(windows, dict) else {}
    return window if isinstance(window, dict) else {}


def _final_scene_scan(snapshot: dict) -> dict:
    diagnostics = snapshot.get("render_diagnostics", {}) if isinstance(snapshot, dict) else {}
    if not isinstance(diagnostics, dict):
        return {}
    scene_scan = diagnostics.get("final_scene_scan", {})
    return scene_scan if isinstance(scene_scan, dict) else {}


def _run_case(case_name: str, case_env: dict[str, str]) -> dict:
    run_start_mtime = time.time()
    env = os.environ.copy()
    env.setdefault("TOWN_STALL_HOLD_SECONDS", "12")
    env.setdefault("TOWN_STALL_MACHINE_WARMUP_DISABLED", "1")
    env.setdefault("TOWN_STALL_ENABLE_RUNTIME_POWER_MODE", "1")
    # Render ablations measure active 60 FPS gameplay cost. Idle/deep-idle
    # throttling has its own case because it intentionally lowers frame rate.
    env.setdefault("TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS", "60")
    env.setdefault("TOWN_STALL_RUNTIME_POWER_IDLE_FPS", "60")
    env.setdefault("TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS", "60")
    env.setdefault("TOWN_STALL_RUNTIME_POWER_SUSPEND_BACKGROUND_WORLD_WORK", "1")
    env.setdefault("TOWN_STALL_RUNTIME_POWER_SUSPEND_RENDER_LOOP", "1")
    env.setdefault("TOWN_STALL_TERRAIN_FORCE_PENDING_NODE_FINALIZATION", "1")
    env.setdefault("TOWN_STALL_TERRAIN_FORCE_STREAM_PROGRESS", "1")
    env.setdefault("TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS", "1")
    env.setdefault("TOWN_STALL_SYSTEM_SAMPLE_RAW_GPU_ONLY", "1")
    env.setdefault("TOWN_STALL_ALLOW_CONTAMINATED_IDLE", "1")
    env.setdefault("TOWN_STALL_DISABLE_POSTRUN_IDLE_CHECK", "1")
    env.update(case_env)

    print("\n" + "=" * 50)
    print(f"RUNNING ABLATION CASE: {case_name}")
    print("=" * 50)
    result = subprocess.run(
        [sys.executable, str(Path(__file__).with_name("run_town_stall_test.py"))],
        cwd=run_town_stall_test.PROJECT_PATH,
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    snapshot_path = run_town_stall_test._latest_snapshot(run_start_mtime)
    if result.returncode != 0:
        snapshot_path = None
    snapshot = _read_json(snapshot_path) if snapshot_path else {}
    town_window = snapshot.get("town_entry_window", {}) if isinstance(snapshot, dict) else {}
    stationary_hold = snapshot.get("stationary_hold_window", {}) if isinstance(snapshot, dict) else {}
    system_telemetry = snapshot.get("system_telemetry", {}) if isinstance(snapshot, dict) else {}
    system_summary = snapshot.get("system_sample_summary", {}) if isinstance(snapshot, dict) else {}
    terrain = system_telemetry.get("terrain_manager", {}) if isinstance(system_telemetry, dict) else {}
    building = system_telemetry.get("building_manager", {}) if isinstance(system_telemetry, dict) else {}
    vegetation = system_telemetry.get("vegetation_manager", {}) if isinstance(system_telemetry, dict) else {}
    entities = system_telemetry.get("entity_manager", {}) if isinstance(system_telemetry, dict) else {}

    if not isinstance(town_window, dict):
        town_window = {}
    if not isinstance(stationary_hold, dict):
        stationary_hold = {}
    if not isinstance(terrain, dict):
        terrain = {}
    if not isinstance(building, dict):
        building = {}
    if not isinstance(vegetation, dict):
        vegetation = {}
    if not isinstance(entities, dict):
        entities = {}
    if not isinstance(system_summary, dict):
        system_summary = {}
    scene_scan = _final_scene_scan(snapshot)

    active_sample_count = _pick_active_sample_count(stationary_hold, town_window)
    moving_entry = snapshot.get("moving_entry_window", {}) if isinstance(snapshot, dict) else {}
    if not isinstance(moving_entry, dict):
        moving_entry = {}
    moving_system = _phase_window(system_summary, "moving_entry")
    hold_system = _phase_window(system_summary, "stationary_hold")
    sample_count = int(stationary_hold.get("sample_count", town_window.get("sample_count", 0)) or 0)
    render_loop_suspended_samples = int(
        stationary_hold.get(
            "terrain_runtime_power_render_loop_suspended_samples",
            town_window.get("terrain_runtime_power_render_loop_suspended_samples", 0),
        )
        or 0
    )
    world_work_suspended_samples = int(
        stationary_hold.get(
            "terrain_runtime_power_world_work_suspended_samples",
            town_window.get("terrain_runtime_power_world_work_suspended_samples", 0),
        )
        or 0
    )
    avg_total_ms = _pick_window_metric(stationary_hold, town_window, "avg_total_ms")
    avg_draw_calls = _pick_window_metric(stationary_hold, town_window, "avg_draw_calls")
    avg_objects = _pick_window_metric(stationary_hold, town_window, "avg_objects")
    avg_primitives = _pick_window_metric(stationary_hold, town_window, "avg_primitives")
    moving_avg_total_ms = float(moving_entry.get("avg_total_ms", 0.0) or 0.0)
    moving_avg_draw_calls = float(moving_entry.get("avg_draw_calls", 0.0) or 0.0)
    moving_avg_objects = float(moving_entry.get("avg_objects", 0.0) or 0.0)
    moving_avg_primitives = float(moving_entry.get("avg_primitives", 0.0) or 0.0)
    moving_raw_gpu_power_avg_w = _summary_avg(moving_system, "raw_gpu_power_w")
    hold_raw_gpu_power_avg_w = _summary_avg(hold_system, "raw_gpu_power_w")
    moving_wpf60 = _wpf60(moving_raw_gpu_power_avg_w, moving_avg_total_ms)
    hold_wpf60 = _wpf60(hold_raw_gpu_power_avg_w, avg_total_ms)

    return {
        "case": case_name,
        "returncode": result.returncode,
        "snapshot": str(snapshot_path) if snapshot_path else "",
        "hold_complete": bool(snapshot.get("benchmark_hold_complete", False)) if snapshot else False,
        "metric_basis": "render_active" if active_sample_count > 0 else "all_samples",
        "sample_count": sample_count,
        "render_active_sample_count": active_sample_count,
        "render_loop_suspended_samples": render_loop_suspended_samples,
        "world_work_suspended_samples": world_work_suspended_samples,
        "runtime_power_mode": str(terrain.get("runtime_power_mode", "")),
        "runtime_power_active_max_fps": int(terrain.get("runtime_power_active_max_fps", 0) or 0),
        "runtime_power_idle_max_fps": int(terrain.get("runtime_power_idle_max_fps", 0) or 0),
        "runtime_power_deep_idle_max_fps": int(terrain.get("runtime_power_deep_idle_max_fps", 0) or 0),
        "avg_total_ms": avg_total_ms,
        "avg_draw_calls": avg_draw_calls,
        "avg_objects": avg_objects,
        "avg_primitives": avg_primitives,
        "moving_avg_total_ms": moving_avg_total_ms,
        "moving_avg_draw_calls": moving_avg_draw_calls,
        "moving_avg_objects": moving_avg_objects,
        "moving_avg_primitives": moving_avg_primitives,
        "moving_raw_gpu_power_avg_w": moving_raw_gpu_power_avg_w,
        "moving_wpf60": moving_wpf60,
        "moving_wpf60_per_million_primitives": _per_scaled_unit(moving_wpf60, moving_avg_primitives, 1_000_000.0),
        "moving_wpf60_per_100_draw_calls": _per_scaled_unit(moving_wpf60, moving_avg_draw_calls, 100.0),
        "moving_wpf60_per_100_objects": _per_scaled_unit(moving_wpf60, moving_avg_objects, 100.0),
        "moving_raw_gpu_temp_max_c": float(
            (moving_system.get("raw_gpu_temp_c", {}) if isinstance(moving_system.get("raw_gpu_temp_c", {}), dict) else {}).get("max", 0.0)
            or 0.0
        ),
        "hold_raw_gpu_power_avg_w": hold_raw_gpu_power_avg_w,
        "hold_wpf60": hold_wpf60,
        "hold_wpf60_per_million_primitives": _per_scaled_unit(hold_wpf60, avg_primitives, 1_000_000.0),
        "hold_wpf60_per_100_draw_calls": _per_scaled_unit(hold_wpf60, avg_draw_calls, 100.0),
        "hold_wpf60_per_100_objects": _per_scaled_unit(hold_wpf60, avg_objects, 100.0),
        "hold_raw_gpu_temp_max_c": float(
            (hold_system.get("raw_gpu_temp_c", {}) if isinstance(hold_system.get("raw_gpu_temp_c", {}), dict) else {}).get("max", 0.0)
            or 0.0
        ),
        "pipeline_compilations_total_delta": int(
            stationary_hold.get(
                "pipeline_compilations_total_delta",
                town_window.get("pipeline_compilations_total_delta", 0),
            )
            or 0
        ),
        "frames_over_budget": _pick_window_int_metric(stationary_hold, town_window, "frames_over_budget"),
        "frames_over_40ms": _pick_window_int_metric(stationary_hold, town_window, "frames_over_40ms"),
        "frames_over_50ms": _pick_window_int_metric(stationary_hold, town_window, "frames_over_50ms"),
        "stall_over_budget_ms": _pick_window_metric(stationary_hold, town_window, "stall_over_budget_ms"),
        "longest_over_budget_streak": _pick_window_int_metric(stationary_hold, town_window, "longest_over_budget_streak"),
        "longest_over_40ms_streak": _pick_window_int_metric(stationary_hold, town_window, "longest_over_40ms_streak"),
        "longest_over_50ms_streak": _pick_window_int_metric(stationary_hold, town_window, "longest_over_50ms_streak"),
        "avg_total_ms_all": float(stationary_hold.get("avg_total_ms", town_window.get("avg_total_ms", 0.0)) or 0.0),
        "avg_draw_calls_all": float(stationary_hold.get("avg_draw_calls", town_window.get("avg_draw_calls", 0.0)) or 0.0),
        "avg_objects_all": float(stationary_hold.get("avg_objects", town_window.get("avg_objects", 0.0)) or 0.0),
        "avg_primitives_all": float(stationary_hold.get("avg_primitives", town_window.get("avg_primitives", 0.0)) or 0.0),
        "scene_scan_available": bool(scene_scan),
        "scene_scan_visible_geometry_instances": int(scene_scan.get("visible_geometry_instances", 0) or 0),
        "scene_scan_frustum_geometry_instances": int(scene_scan.get("frustum_geometry_instances", 0) or 0),
        "scene_scan_visible_multimesh_triangles": int(scene_scan.get("visible_multimesh_rendered_triangle_count", 0) or 0),
        "scene_scan_frustum_multimesh_triangles": int(scene_scan.get("frustum_multimesh_rendered_triangle_count", 0) or 0),
        "scene_scan_visible_terrain_triangles": int(scene_scan.get("visible_terrain_mesh_triangle_count", 0) or 0)
        + int(scene_scan.get("visible_terrain_multimesh_rendered_triangle_count", 0) or 0),
        "scene_scan_frustum_terrain_triangles": int(scene_scan.get("frustum_terrain_mesh_triangle_count", 0) or 0)
        + int(scene_scan.get("frustum_terrain_multimesh_rendered_triangle_count", 0) or 0),
        "scene_scan_visible_vegetation_batches": int(scene_scan.get("visible_vegetation_multimesh_instances", 0) or 0),
        "scene_scan_frustum_vegetation_batches": int(scene_scan.get("frustum_vegetation_multimesh_instances", 0) or 0),
        "scene_scan_visible_vegetation_instances": int(scene_scan.get("visible_vegetation_multimesh_instance_count", 0) or 0),
        "scene_scan_frustum_vegetation_instances": int(scene_scan.get("frustum_vegetation_multimesh_instance_count", 0) or 0),
        "scene_scan_visible_vegetation_triangles": int(scene_scan.get("visible_vegetation_multimesh_rendered_triangle_count", 0) or 0),
        "scene_scan_frustum_vegetation_triangles": int(scene_scan.get("frustum_vegetation_multimesh_rendered_triangle_count", 0) or 0),
        "scene_scan_visible_building_triangles": int(scene_scan.get("visible_building_mesh_triangle_count", 0) or 0)
        + int(scene_scan.get("visible_building_multimesh_rendered_triangle_count", 0) or 0),
        "scene_scan_frustum_building_triangles": int(scene_scan.get("frustum_building_mesh_triangle_count", 0) or 0)
        + int(scene_scan.get("frustum_building_multimesh_rendered_triangle_count", 0) or 0),
        "scene_scan_visible_entity_triangles": int(scene_scan.get("visible_entity_mesh_triangle_count", 0) or 0)
        + int(scene_scan.get("visible_entity_multimesh_rendered_triangle_count", 0) or 0),
        "scene_scan_frustum_entity_triangles": int(scene_scan.get("frustum_entity_mesh_triangle_count", 0) or 0)
        + int(scene_scan.get("frustum_entity_multimesh_rendered_triangle_count", 0) or 0),
        "terrain_active_chunks": int(terrain.get("active_chunk_count", 0) or 0),
        "terrain_native_grid_active_chunks": int(terrain.get("native_grid_active_chunk_count", 0) or 0),
        "terrain_unload_hysteresis_chunks": int(terrain.get("terrain_unload_hysteresis_chunks", 0) or 0),
        "terrain_last_stream_bounds_unloads": int(terrain.get("last_stream_bounds_unloads", 0) or 0),
        "terrain_collision_ground_center": bool(terrain.get("terrain_collision_ground_center_for_test", False)),
        "terrain_force_pending_finalization": bool(terrain.get("terrain_force_pending_node_finalization_for_test", False)),
        "terrain_force_stream_progress": bool(terrain.get("terrain_force_stream_progress_for_test", False)),
        "terrain_world_map_road_block_sample_backend_counts": terrain.get(
            "world_map_road_block_sample_backend_counts", {}
        ),
        "terrain_world_map_water_block_sample_backend_counts": terrain.get(
            "world_map_water_block_sample_backend_counts", {}
        ),
        "terrain_height_map_sample_backend_counts": terrain.get("height_map_sample_backend_counts", {}),
        "rendered_terrain_chunks": int(terrain.get("rendered_terrain_chunk_count", 0) or 0),
        "terrain_visual_visible_primitives": int(terrain.get("terrain_visual_visible_primitive_count", 0) or 0),
        "terrain_visual_chunk_primitives": int(terrain.get("terrain_visual_chunk_primitive_count", 0) or 0),
        "terrain_visual_batch_primitives": int(terrain.get("terrain_visual_batch_primitive_count", 0) or 0),
        "terrain_visual_max_chunk_primitives": int(terrain.get("terrain_visual_max_chunk_primitive_count", 0) or 0),
        "terrain_visual_max_batch_primitives": int(terrain.get("terrain_visual_max_batch_primitive_count", 0) or 0),
        "terrain_visual_source_vertices": int(terrain.get("terrain_visual_source_vertex_count", 0) or 0),
        "terrain_visual_source_indices": int(terrain.get("terrain_visual_source_index_count", 0) or 0),
        "terrain_visual_unique_vertices": int(terrain.get("terrain_visual_unique_vertex_count", 0) or 0),
        "terrain_visual_source_primitives": int(terrain.get("terrain_visual_source_primitive_count", 0) or 0),
        "terrain_visual_avg_chunk_primitives": float(terrain.get("terrain_visual_avg_chunk_primitive_count", 0.0) or 0.0),
        "terrain_visual_avg_source_primitives": float(terrain.get("terrain_visual_avg_source_primitive_count", 0.0) or 0.0),
        "terrain_visual_unique_to_source_ratio": float(terrain.get("terrain_visual_unique_to_source_vertex_ratio", 0.0) or 0.0),
        "terrain_visual_max_source_chunk_primitives": int(terrain.get("terrain_visual_max_source_chunk_primitive_count", 0) or 0),
        "terrain_visual_chunk_primitive_buckets": terrain.get("terrain_visual_chunk_primitive_buckets", {}),
        "terrain_visual_source_primitive_buckets": terrain.get("terrain_visual_source_primitive_buckets", {}),
        "rendered_water_chunks": int(terrain.get("rendered_water_chunk_count", 0) or 0),
        "building_visible_nodes": int(building.get("visible_world_map_baked_building_visual_nodes", 0) or 0),
        "building_visible_surfaces": int(building.get("visible_world_map_baked_building_visual_surfaces", 0) or 0),
        "vegetation_global_batches": int(vegetation.get("global_render_batch_count", 0) or 0),
        "vegetation_profile_active": bool(vegetation.get("world_map_vegetation_render_profile_active", False)),
        "vegetation_bounds_padding": float(vegetation.get("vegetation_global_render_bounds_padding", 0.0) or 0.0),
        "vegetation_tree_bounds_padding": float(vegetation.get("tree_global_render_bounds_padding", 0.0) or 0.0),
        "vegetation_grass_bounds_padding": float(vegetation.get("grass_global_render_bounds_padding", 0.0) or 0.0),
        "vegetation_rock_bounds_padding": float(vegetation.get("rock_global_render_bounds_padding", 0.0) or 0.0),
        "vegetation_exact_render_bounds_enabled": bool(vegetation.get("vegetation_exact_render_bounds_enabled", False)),
        "vegetation_exact_render_bounds_padding": float(vegetation.get("vegetation_exact_render_bounds_padding", 0.0) or 0.0),
        "vegetation_ignore_occlusion_culling": bool(vegetation.get("vegetation_global_render_ignore_occlusion_culling", False)),
        "vegetation_opaque_material_optimization_enabled": bool(
            vegetation.get("vegetation_opaque_material_optimization_enabled", False)
        ),
        "vegetation_opaque_material_optimization_counts": vegetation.get(
            "vegetation_opaque_material_optimization_counts", {}
        ),
        "vegetation_tree_render_enabled": bool(vegetation.get("tree_render_enabled", True)),
        "vegetation_grass_render_enabled": bool(vegetation.get("grass_render_enabled", True)),
        "vegetation_rock_render_enabled": bool(vegetation.get("rock_render_enabled", True)),
        "vegetation_estimated_primitives": int(vegetation.get("global_render_estimated_primitives", 0) or 0),
        "vegetation_estimated_surface_draws": int(vegetation.get("global_render_estimated_surface_draws", 0) or 0),
        "tree_mesh_primitives": int(vegetation.get("tree_mesh_primitives", 0) or 0),
        "grass_mesh_primitives": int(vegetation.get("grass_mesh_primitives", 0) or 0),
        "rock_mesh_primitives": int(vegetation.get("rock_mesh_primitives", 0) or 0),
        "tree_mesh_surfaces": int(vegetation.get("tree_mesh_surfaces", 0) or 0),
        "grass_mesh_surfaces": int(vegetation.get("grass_mesh_surfaces", 0) or 0),
        "rock_mesh_surfaces": int(vegetation.get("rock_mesh_surfaces", 0) or 0),
        "tree_alpha_mesh_primitives": int(vegetation.get("tree_alpha_mesh_primitives", 0) or 0),
        "grass_alpha_mesh_primitives": int(vegetation.get("grass_alpha_mesh_primitives", 0) or 0),
        "rock_alpha_mesh_primitives": int(vegetation.get("rock_alpha_mesh_primitives", 0) or 0),
        "tree_alpha_mesh_surfaces": int(vegetation.get("tree_alpha_mesh_surfaces", 0) or 0),
        "grass_alpha_mesh_surfaces": int(vegetation.get("grass_alpha_mesh_surfaces", 0) or 0),
        "rock_alpha_mesh_surfaces": int(vegetation.get("rock_alpha_mesh_surfaces", 0) or 0),
        "tree_alpha_texture_coverage_ratio": float(vegetation.get("tree_alpha_texture_coverage_ratio", 1.0) or 0.0),
        "grass_alpha_texture_coverage_ratio": float(vegetation.get("grass_alpha_texture_coverage_ratio", 1.0) or 0.0),
        "rock_alpha_texture_coverage_ratio": float(vegetation.get("rock_alpha_texture_coverage_ratio", 1.0) or 0.0),
        "vegetation_tree_estimated_primitives": int(vegetation.get("global_tree_render_estimated_primitives", 0) or 0),
        "vegetation_grass_estimated_primitives": int(vegetation.get("global_grass_render_estimated_primitives", 0) or 0),
        "vegetation_rock_estimated_primitives": int(vegetation.get("global_rock_render_estimated_primitives", 0) or 0),
        "vegetation_estimated_alpha_primitives": int(vegetation.get("global_render_estimated_alpha_primitives", 0) or 0),
        "vegetation_tree_estimated_alpha_primitives": int(vegetation.get("global_tree_estimated_alpha_primitives", 0) or 0),
        "vegetation_grass_estimated_alpha_primitives": int(vegetation.get("global_grass_estimated_alpha_primitives", 0) or 0),
        "vegetation_rock_estimated_alpha_primitives": int(vegetation.get("global_rock_estimated_alpha_primitives", 0) or 0),
        "vegetation_estimated_alpha_empty_primitive_equivalent": float(
            vegetation.get("global_render_estimated_alpha_empty_primitive_equivalent", 0.0) or 0.0
        ),
        "vegetation_tree_estimated_alpha_empty_primitive_equivalent": float(
            vegetation.get("global_tree_estimated_alpha_empty_primitive_equivalent", 0.0) or 0.0
        ),
        "vegetation_grass_estimated_alpha_empty_primitive_equivalent": float(
            vegetation.get("global_grass_estimated_alpha_empty_primitive_equivalent", 0.0) or 0.0
        ),
        "vegetation_rock_estimated_alpha_empty_primitive_equivalent": float(
            vegetation.get("global_rock_estimated_alpha_empty_primitive_equivalent", 0.0) or 0.0
        ),
        "vegetation_tree_max_batch_instances": int(vegetation.get("global_tree_max_batch_instances", 0) or 0),
        "vegetation_grass_max_batch_instances": int(vegetation.get("global_grass_max_batch_instances", 0) or 0),
        "vegetation_rock_max_batch_instances": int(vegetation.get("global_rock_max_batch_instances", 0) or 0),
        "vegetation_tree_batches": int(vegetation.get("global_tree_render_batch_count", 0) or 0),
        "vegetation_grass_batches": int(vegetation.get("global_grass_render_batch_count", 0) or 0),
        "vegetation_rock_batches": int(vegetation.get("global_rock_render_batch_count", 0) or 0),
        "vegetation_cluster_size": int(vegetation.get("effective_vegetation_render_cluster_size", 0) or 0),
        "vegetation_grass_cluster_size": int(vegetation.get("effective_vegetation_grass_render_cluster_size", 0) or 0),
        "vegetation_dense_grass_mode": bool(vegetation.get("dense_grass_mode", False)),
        "vegetation_grass_sample_step": int(vegetation.get("grass_sample_step", 0) or 0),
        "vegetation_grass_noise_threshold": float(vegetation.get("grass_noise_threshold", 0.0) or 0.0),
        "vegetation_rock_sample_step": int(vegetation.get("rock_sample_step", 0) or 0),
        "vegetation_rock_noise_threshold": float(vegetation.get("rock_noise_threshold", 0.0) or 0.0),
        "native_vegetation_generation_available": bool(vegetation.get("native_vegetation_generation_available", False)),
        "native_vegetation_generation_blocked_by_world_map": bool(vegetation.get("native_vegetation_generation_blocked_by_world_map", False)),
        "native_vegetation_generation_world_map_road_mask_supported": bool(vegetation.get("native_vegetation_generation_world_map_road_mask_supported", False)),
        "vegetation_generation_backend_counts": vegetation.get("vegetation_generation_backend_counts", {}),
        "vegetation_generation_time_backend_counts": vegetation.get("vegetation_generation_time_backend_counts", {}),
        "vegetation_noise_sample_backend_counts": vegetation.get("vegetation_noise_sample_backend_counts", {}),
        "vegetation_road_block_sample_backend_counts": vegetation.get("vegetation_road_block_sample_backend_counts", {}),
        "vegetation_water_block_sample_backend_counts": vegetation.get("vegetation_water_block_sample_backend_counts", {}),
        "vegetation_render_payload_backend_counts": vegetation.get("vegetation_render_payload_backend_counts", {}),
        "vegetation_render_cluster_payload_backend_counts": vegetation.get(
            "vegetation_render_cluster_payload_backend_counts", {}
        ),
        "vegetation_removed_filter_backend_counts": vegetation.get("vegetation_removed_filter_backend_counts", {}),
        "vegetation_ray_query_backend_counts": vegetation.get("vegetation_ray_query_backend_counts", {}),
        "vegetation_pending_chunk_selection_backend": str(
            vegetation.get("last_pending_chunk_selection_backend", "")
        ),
        "vegetation_pending_chunk_selection_scan_count": int(
            vegetation.get("last_pending_chunk_selection_scan_count", 0) or 0
        ),
        "vegetation_pending_chunk_selection_native_calls": int(
            vegetation.get("pending_chunk_selection_native_calls", 0) or 0
        ),
        "vegetation_pending_chunk_selection_gdscript_calls": int(
            vegetation.get("pending_chunk_selection_gdscript_calls", 0) or 0
        ),
        "vegetation_last_global_render_sync_instance_count": int(
            vegetation.get("last_global_render_sync_instance_count", 0) or 0
        ),
        "vegetation_last_global_render_upload_bytes": int(vegetation.get("last_global_render_upload_bytes", 0) or 0),
        "vegetation_max_global_render_upload_bytes": int(vegetation.get("max_global_render_upload_bytes", 0) or 0),
        "last_vegetation_generation_kind": str(vegetation.get("last_vegetation_generation_kind", "")),
        "last_vegetation_generation_backend": str(vegetation.get("last_vegetation_generation_backend", "")),
        "last_vegetation_generation_reason": str(vegetation.get("last_vegetation_generation_reason", "")),
        "last_vegetation_generation_ms": float(vegetation.get("last_vegetation_generation_ms", 0.0) or 0.0),
        "last_vegetation_generation_instance_count": int(
            vegetation.get("last_vegetation_generation_instance_count", 0) or 0
        ),
        "max_vegetation_generation_ms": float(vegetation.get("max_vegetation_generation_ms", 0.0) or 0.0),
        "entity_active": int(entities.get("active_entities", 0) or 0),
        "entity_active_distance_ring_counts": entities.get("active_entity_distance_ring_counts", []),
        "entity_frozen": int(entities.get("frozen_entities", 0) or 0),
        "entity_dormant": int(entities.get("dormant_entities", 0) or 0),
        "entity_pending": int(entities.get("pending_spawns", 0) or 0),
        "entity_deferred_chunks": int(entities.get("deferred_spawn_chunks", 0) or 0),
        "entity_deferred_plans": int(entities.get("deferred_spawn_plans", 0) or 0),
        "entity_spawned_chunks": int(entities.get("spawned_chunks", 0) or 0),
        "entity_max": int(entities.get("max_entities", 0) or 0),
        "entity_spawn_radius": float(entities.get("spawn_radius", 0.0) or 0.0),
        "entity_active_physics_radius": float(entities.get("active_physics_radius", 0.0) or 0.0),
        "entity_effective_active_physics_radius": float(entities.get("effective_active_physics_radius", 0.0) or 0.0),
        "entity_freeze_radius": float(entities.get("freeze_radius", 0.0) or 0.0),
        "entity_effective_freeze_radius": float(entities.get("effective_freeze_radius", 0.0) or 0.0),
        "entity_despawn_radius": float(entities.get("despawn_radius", 0.0) or 0.0),
        "entity_collision_range": float(entities.get("collision_range", 0.0) or 0.0),
        "entity_spawn_chance_per_chunk": float(entities.get("spawn_chance_per_chunk", 0.0) or 0.0),
        "entity_min_spawn_distance": float(entities.get("min_spawn_distance_from_player", 0.0) or 0.0),
        "entity_max_spawns_per_chunk": int(entities.get("max_spawns_per_chunk", 0) or 0),
        "entity_balance_spawn_distance_rings": bool(entities.get("balance_spawn_distance_rings", False)),
        "entity_spawn_distance_ring_count": int(entities.get("spawn_distance_ring_count", 0) or 0),
        "entity_pending_distance_ring_counts": entities.get("pending_spawn_distance_ring_counts", []),
        "entity_balanced_ring_fill_enabled": bool(entities.get("balanced_ring_fill_enabled", False)),
        "entity_balanced_ring_fill_target": int(entities.get("balanced_ring_fill_target_entities", 0) or 0),
        "entity_last_balanced_ring_fill_queued": int(entities.get("last_balanced_ring_fill_queued", 0) or 0),
    }


def _add_deltas(results: list[dict]) -> list[dict]:
    baseline = next((result for result in results if result.get("case") == "baseline"), None)
    if not baseline:
        return results
    baseline_ms = float(baseline.get("avg_total_ms", 0.0) or 0.0)
    baseline_draws = float(baseline.get("avg_draw_calls", 0.0) or 0.0)
    baseline_objects = float(baseline.get("avg_objects", 0.0) or 0.0)
    baseline_primitives = float(baseline.get("avg_primitives", 0.0) or 0.0)
    baseline_moving_power = float(baseline.get("moving_raw_gpu_power_avg_w", 0.0) or 0.0)
    baseline_hold_power = float(baseline.get("hold_raw_gpu_power_avg_w", 0.0) or 0.0)
    baseline_moving_wpf60 = float(baseline.get("moving_wpf60", 0.0) or 0.0)
    baseline_hold_wpf60 = float(baseline.get("hold_wpf60", 0.0) or 0.0)
    for result in results:
        result["delta_avg_total_ms"] = round(float(result.get("avg_total_ms", 0.0) or 0.0) - baseline_ms, 3)
        result["delta_avg_draw_calls"] = round(float(result.get("avg_draw_calls", 0.0) or 0.0) - baseline_draws, 3)
        result["delta_avg_objects"] = round(float(result.get("avg_objects", 0.0) or 0.0) - baseline_objects, 3)
        result["delta_avg_primitives"] = round(float(result.get("avg_primitives", 0.0) or 0.0) - baseline_primitives, 3)
        result["delta_moving_raw_gpu_power_avg_w"] = round(float(result.get("moving_raw_gpu_power_avg_w", 0.0) or 0.0) - baseline_moving_power, 3)
        result["delta_hold_raw_gpu_power_avg_w"] = round(float(result.get("hold_raw_gpu_power_avg_w", 0.0) or 0.0) - baseline_hold_power, 3)
        result["delta_moving_wpf60"] = round(float(result.get("moving_wpf60", 0.0) or 0.0) - baseline_moving_wpf60, 3)
        result["delta_hold_wpf60"] = round(float(result.get("hold_wpf60", 0.0) or 0.0) - baseline_hold_wpf60, 3)
    return results


def _performance_gate_failures(result: dict) -> list[str]:
    failures: list[str] = []
    require_60fps = _env_bool("TOWN_STALL_REQUIRE_60FPS", False)
    wpf60_cap_raw = os.environ.get("TOWN_STALL_MAX_HOLD_WPF60", "").strip()
    wpf60_cap_enabled = bool(wpf60_cap_raw)
    if not require_60fps and not wpf60_cap_enabled:
        return failures

    case_name = str(result.get("case", "unknown"))
    if require_60fps:
        max_avg_frame_ms = _env_float("TOWN_STALL_MAX_AVG_FRAME_MS", FPS_60_FRAME_MS)
        max_over_budget_ratio = _env_float("TOWN_STALL_MAX_FRAMES_OVER_BUDGET_RATIO", 0.05)
        max_over_budget_streak = _env_int("TOWN_STALL_MAX_LONGEST_OVER_BUDGET_STREAK", 60)
        max_frames_over_40ms = _env_int("TOWN_STALL_MAX_FRAMES_OVER_40MS", 0)
        sample_count = max(1, int(result.get("sample_count", 0) or 0))
        frames_over_budget = int(result.get("frames_over_budget", 0) or 0)
        over_budget_ratio = float(frames_over_budget) / float(sample_count)
        avg_total_ms = float(result.get("avg_total_ms", 0.0) or 0.0)
        longest_streak = int(result.get("longest_over_budget_streak", 0) or 0)
        frames_over_40ms = int(result.get("frames_over_40ms", 0) or 0)

        if avg_total_ms > max_avg_frame_ms:
            failures.append(
                f"{case_name}: avg frame {avg_total_ms:.2f}ms > {max_avg_frame_ms:.2f}ms"
            )
        if over_budget_ratio > max_over_budget_ratio:
            failures.append(
                f"{case_name}: over-budget frames {frames_over_budget}/{sample_count} "
                f"({over_budget_ratio:.1%}) > {max_over_budget_ratio:.1%}"
            )
        if longest_streak > max_over_budget_streak:
            failures.append(
                f"{case_name}: longest over-budget streak {longest_streak} > {max_over_budget_streak}"
            )
        if frames_over_40ms > max_frames_over_40ms:
            failures.append(
                f"{case_name}: frames over 40ms {frames_over_40ms} > {max_frames_over_40ms}"
            )

    if wpf60_cap_enabled:
        max_hold_wpf60 = _env_float("TOWN_STALL_MAX_HOLD_WPF60", 0.0)
        hold_wpf60 = float(result.get("hold_wpf60", 0.0) or 0.0)
        if max_hold_wpf60 > 0.0 and hold_wpf60 > max_hold_wpf60:
            failures.append(f"{case_name}: hold WPF60 {hold_wpf60:.1f} > {max_hold_wpf60:.1f}")

    return failures


def _print_results(results: list[dict]) -> None:
    print("\n" + "=" * 50)
    print("RENDER ABLATION SUMMARY")
    print("=" * 50)
    for result in results:
        print(
            "{case:>20} | ms={ms:6.2f} ({dms:+6.2f}) | over={over:4d}/{total_samples:<4d} streak={streak:4d} >40={over40:3d} | "
            "draws={draws:7.1f} ({ddraws:+7.1f}) | "
            "objects={objects:7.1f} ({dobjects:+7.1f}) | prims={prims:9.0f} ({dprims:+9.0f}) pipes={pipes:3d} | "
            "holdWPF60={hold_wpf60:5.1f} ({dhold_wpf60:+5.1f}) moveWPF60={move_wpf60:5.1f} ({dmove_wpf60:+5.1f}) "
            "holdW={hold_w:5.1f} ({dhold_w:+5.1f}) moveW={move_w:5.1f} ({dmove_w:+5.1f}) | "
            "terrain={terrain:4d} water={water:4d} "
            "buildings={buildings:4d} veg={veg:3d}({tree}/{grass}/{rock}) cluster={cluster}/{grass_cluster} "
            "profile={profile} gStep={gstep} gThr={gthr:.2f} dense={dense_grass} rStep={rstep} rThr={rthr:.2f} "
            "entities={entities:3d}/{entity_max:<3d} phys={physics:3d} frozen={frozen:3d} pend={pending:3d} | "
            "active={active:4d}/{samples:4d} suspended={suspended:4d} rpmode={rpmode} fps={active_fps}/{idle_fps}/{deep_fps}".format(
                case=str(result.get("case", "")),
                ms=float(result.get("avg_total_ms", 0.0) or 0.0),
                dms=float(result.get("delta_avg_total_ms", 0.0) or 0.0),
                over=int(result.get("frames_over_budget", 0) or 0),
                total_samples=int(result.get("sample_count", 0) or 0),
                streak=int(result.get("longest_over_budget_streak", 0) or 0),
                over40=int(result.get("frames_over_40ms", 0) or 0),
                draws=float(result.get("avg_draw_calls", 0.0) or 0.0),
                ddraws=float(result.get("delta_avg_draw_calls", 0.0) or 0.0),
                objects=float(result.get("avg_objects", 0.0) or 0.0),
                dobjects=float(result.get("delta_avg_objects", 0.0) or 0.0),
                prims=float(result.get("avg_primitives", 0.0) or 0.0),
                dprims=float(result.get("delta_avg_primitives", 0.0) or 0.0),
                pipes=int(result.get("pipeline_compilations_total_delta", 0) or 0),
                hold_wpf60=float(result.get("hold_wpf60", 0.0) or 0.0),
                dhold_wpf60=float(result.get("delta_hold_wpf60", 0.0) or 0.0),
                move_wpf60=float(result.get("moving_wpf60", 0.0) or 0.0),
                dmove_wpf60=float(result.get("delta_moving_wpf60", 0.0) or 0.0),
                move_w=float(result.get("moving_raw_gpu_power_avg_w", 0.0) or 0.0),
                dmove_w=float(result.get("delta_moving_raw_gpu_power_avg_w", 0.0) or 0.0),
                hold_w=float(result.get("hold_raw_gpu_power_avg_w", 0.0) or 0.0),
                dhold_w=float(result.get("delta_hold_raw_gpu_power_avg_w", 0.0) or 0.0),
                terrain=int(result.get("rendered_terrain_chunks", 0) or 0),
                water=int(result.get("rendered_water_chunks", 0) or 0),
                buildings=int(result.get("building_visible_nodes", 0) or 0),
                veg=int(result.get("vegetation_global_batches", 0) or 0),
                tree=int(result.get("vegetation_tree_batches", 0) or 0),
                grass=int(result.get("vegetation_grass_batches", 0) or 0),
                rock=int(result.get("vegetation_rock_batches", 0) or 0),
                cluster=int(result.get("vegetation_cluster_size", 0) or 0),
                grass_cluster=int(result.get("vegetation_grass_cluster_size", 0) or 0),
                profile="on" if bool(result.get("vegetation_profile_active", False)) else "off",
                gstep=int(result.get("vegetation_grass_sample_step", 0) or 0),
                gthr=float(result.get("vegetation_grass_noise_threshold", 0.0) or 0.0),
                dense_grass="on" if bool(result.get("vegetation_dense_grass_mode", False)) else "off",
                rstep=int(result.get("vegetation_rock_sample_step", 0) or 0),
                rthr=float(result.get("vegetation_rock_noise_threshold", 0.0) or 0.0),
                entities=int(result.get("entity_active", 0) or 0),
                entity_max=int(result.get("entity_max", 0) or 0),
                physics=max(
                    0,
                    int(result.get("entity_active", 0) or 0) - int(result.get("entity_frozen", 0) or 0),
                ),
                frozen=int(result.get("entity_frozen", 0) or 0),
                pending=int(result.get("entity_pending", 0) or 0),
                active=int(result.get("render_active_sample_count", 0) or 0),
                samples=int(result.get("sample_count", 0) or 0),
                suspended=int(result.get("render_loop_suspended_samples", 0) or 0),
                rpmode=str(result.get("runtime_power_mode", "")),
                active_fps=int(result.get("runtime_power_active_max_fps", 0) or 0),
                idle_fps=int(result.get("runtime_power_idle_max_fps", 0) or 0),
                deep_fps=int(result.get("runtime_power_deep_idle_max_fps", 0) or 0),
            )
        )
        print(
            "                     efficiency holdWPF60/Mprim={hold_mprim:6.1f} /100draw={hold_draw:5.1f} /100obj={hold_obj:5.1f} "
            "moveWPF60/Mprim={move_mprim:6.1f} /100draw={move_draw:5.1f} /100obj={move_obj:5.1f} | "
            "nativeVeg={native} worldMapBlock={blocked} roadMask={road_mask} "
            "lastGen={last_kind}/{last_backend}/{last_reason}/{last_ms:.2f}ms/{last_instances}inst maxGen={max_ms:.2f}ms "
            "counts={counts} genTime={generation_time} noiseSamples={noise_samples} pendingPick={pending_backend}:{pending_native}/{pending_gdscript}@{pending_scan} "
            "roadSamples={road_samples} waterSamples={water_samples} payloads={payloads} "
            "clusterPayloads={cluster_payloads} removedFilter={removed_filter} rayQueries={ray_queries} "
            "terrainMaskRoad={terrain_road_mask} terrainMaskWater={terrain_water_mask} heightSamples={height_samples}".format(
                hold_mprim=float(result.get("hold_wpf60_per_million_primitives", 0.0) or 0.0),
                hold_draw=float(result.get("hold_wpf60_per_100_draw_calls", 0.0) or 0.0),
                hold_obj=float(result.get("hold_wpf60_per_100_objects", 0.0) or 0.0),
                move_mprim=float(result.get("moving_wpf60_per_million_primitives", 0.0) or 0.0),
                move_draw=float(result.get("moving_wpf60_per_100_draw_calls", 0.0) or 0.0),
                move_obj=float(result.get("moving_wpf60_per_100_objects", 0.0) or 0.0),
                native="yes" if bool(result.get("native_vegetation_generation_available", False)) else "no",
                blocked="yes" if bool(result.get("native_vegetation_generation_blocked_by_world_map", False)) else "no",
                road_mask="yes" if bool(result.get("native_vegetation_generation_world_map_road_mask_supported", False)) else "no",
                last_kind=str(result.get("last_vegetation_generation_kind", "")),
                last_backend=str(result.get("last_vegetation_generation_backend", "")),
                last_reason=str(result.get("last_vegetation_generation_reason", "")),
                last_ms=float(result.get("last_vegetation_generation_ms", 0.0) or 0.0),
                last_instances=int(result.get("last_vegetation_generation_instance_count", 0) or 0),
                max_ms=float(result.get("max_vegetation_generation_ms", 0.0) or 0.0),
                counts=json.dumps(result.get("vegetation_generation_backend_counts", {}), sort_keys=True, separators=(",", ":")),
                generation_time=json.dumps(
                    result.get("vegetation_generation_time_backend_counts", {}),
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                noise_samples=json.dumps(result.get("vegetation_noise_sample_backend_counts", {}), sort_keys=True, separators=(",", ":")),
                pending_backend=str(result.get("vegetation_pending_chunk_selection_backend", "")),
                pending_native=int(result.get("vegetation_pending_chunk_selection_native_calls", 0) or 0),
                pending_gdscript=int(result.get("vegetation_pending_chunk_selection_gdscript_calls", 0) or 0),
                pending_scan=int(result.get("vegetation_pending_chunk_selection_scan_count", 0) or 0),
                road_samples=json.dumps(result.get("vegetation_road_block_sample_backend_counts", {}), sort_keys=True, separators=(",", ":")),
                water_samples=json.dumps(result.get("vegetation_water_block_sample_backend_counts", {}), sort_keys=True, separators=(",", ":")),
                payloads=json.dumps(result.get("vegetation_render_payload_backend_counts", {}), sort_keys=True, separators=(",", ":")),
                cluster_payloads=json.dumps(
                    result.get("vegetation_render_cluster_payload_backend_counts", {}),
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                removed_filter=json.dumps(
                    result.get("vegetation_removed_filter_backend_counts", {}),
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                ray_queries=json.dumps(
                    result.get("vegetation_ray_query_backend_counts", {}),
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                terrain_road_mask=json.dumps(
                    result.get("terrain_world_map_road_block_sample_backend_counts", {}),
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                terrain_water_mask=json.dumps(
                    result.get("terrain_world_map_water_block_sample_backend_counts", {}),
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                height_samples=json.dumps(
                    result.get("terrain_height_map_sample_backend_counts", {}),
                    sort_keys=True,
                    separators=(",", ":"),
                ),
            )
        )
        print(
            "                     materials opaqueOpt={opaque_opt} opaqueCounts={opaque_counts} "
            "alphaMesh={tree_alpha_mesh}/{grass_alpha_mesh}/{rock_alpha_mesh} "
            "alphaSurf={tree_alpha_surfaces}/{grass_alpha_surfaces}/{rock_alpha_surfaces} "
            "alphaCoverage={tree_coverage:.2f}/{grass_coverage:.2f}/{rock_coverage:.2f} "
            "alphaEst={alpha_est} emptyEq={empty_eq:.0f} tree/grass/rockEmpty={tree_empty:.0f}/{grass_empty:.0f}/{rock_empty:.0f}".format(
                opaque_opt="on" if bool(result.get("vegetation_opaque_material_optimization_enabled", False)) else "off",
                opaque_counts=json.dumps(
                    result.get("vegetation_opaque_material_optimization_counts", {}),
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                tree_alpha_mesh=int(result.get("tree_alpha_mesh_primitives", 0) or 0),
                grass_alpha_mesh=int(result.get("grass_alpha_mesh_primitives", 0) or 0),
                rock_alpha_mesh=int(result.get("rock_alpha_mesh_primitives", 0) or 0),
                tree_alpha_surfaces=int(result.get("tree_alpha_mesh_surfaces", 0) or 0),
                grass_alpha_surfaces=int(result.get("grass_alpha_mesh_surfaces", 0) or 0),
                rock_alpha_surfaces=int(result.get("rock_alpha_mesh_surfaces", 0) or 0),
                tree_coverage=float(result.get("tree_alpha_texture_coverage_ratio", 1.0) or 0.0),
                grass_coverage=float(result.get("grass_alpha_texture_coverage_ratio", 1.0) or 0.0),
                rock_coverage=float(result.get("rock_alpha_texture_coverage_ratio", 1.0) or 0.0),
                alpha_est=int(result.get("vegetation_estimated_alpha_primitives", 0) or 0),
                empty_eq=float(result.get("vegetation_estimated_alpha_empty_primitive_equivalent", 0.0) or 0.0),
                tree_empty=float(result.get("vegetation_tree_estimated_alpha_empty_primitive_equivalent", 0.0) or 0.0),
                grass_empty=float(result.get("vegetation_grass_estimated_alpha_empty_primitive_equivalent", 0.0) or 0.0),
                rock_empty=float(result.get("vegetation_rock_estimated_alpha_empty_primitive_equivalent", 0.0) or 0.0),
            )
        )
        print(
            "                     terrainPrims visible={terrain_visible:9d} chunks={terrain_chunks:9d} "
            "batches={terrain_batches:9d} maxChunk={terrain_max_chunk:6d} maxBatch={terrain_max_batch:6d} | "
            "vegEst={veg_est:9d} tree/grass/rock={tree_est}/{grass_est}/{rock_est} "
            "mesh={tree_mesh}/{grass_mesh}/{rock_mesh} surfaces={tree_surfaces}/{grass_surfaces}/{rock_surfaces} "
            "estSurfDraws={surface_draws} maxInst={tree_max}/{grass_max}/{rock_max} "
            "uploadLast={upload_last:.2f}MB/{upload_instances}inst uploadMax={upload_max:.2f}MB "
            "bounds={bounds:4.0f} kindBounds={tree_bounds:.0f}/{grass_bounds:.0f}/{rock_bounds:.0f} occIgnore={occ} collisionGroundCenter={ground_center} "
            "exactBounds={exact_bounds}@{exact_padding:.1f} forcePendingFinalize={force_pending} forceStream={force_stream}".format(
                terrain_visible=int(result.get("terrain_visual_visible_primitives", 0) or 0),
                terrain_chunks=int(result.get("terrain_visual_chunk_primitives", 0) or 0),
                terrain_batches=int(result.get("terrain_visual_batch_primitives", 0) or 0),
                terrain_max_chunk=int(result.get("terrain_visual_max_chunk_primitives", 0) or 0),
                terrain_max_batch=int(result.get("terrain_visual_max_batch_primitives", 0) or 0),
                veg_est=int(result.get("vegetation_estimated_primitives", 0) or 0),
                tree_est=int(result.get("vegetation_tree_estimated_primitives", 0) or 0),
                grass_est=int(result.get("vegetation_grass_estimated_primitives", 0) or 0),
                rock_est=int(result.get("vegetation_rock_estimated_primitives", 0) or 0),
                tree_mesh=int(result.get("tree_mesh_primitives", 0) or 0),
                grass_mesh=int(result.get("grass_mesh_primitives", 0) or 0),
                rock_mesh=int(result.get("rock_mesh_primitives", 0) or 0),
                tree_surfaces=int(result.get("tree_mesh_surfaces", 0) or 0),
                grass_surfaces=int(result.get("grass_mesh_surfaces", 0) or 0),
                rock_surfaces=int(result.get("rock_mesh_surfaces", 0) or 0),
                surface_draws=int(result.get("vegetation_estimated_surface_draws", 0) or 0),
                tree_max=int(result.get("vegetation_tree_max_batch_instances", 0) or 0),
                grass_max=int(result.get("vegetation_grass_max_batch_instances", 0) or 0),
                rock_max=int(result.get("vegetation_rock_max_batch_instances", 0) or 0),
                upload_last=float(result.get("vegetation_last_global_render_upload_bytes", 0) or 0) / (1024.0 * 1024.0),
                upload_instances=int(result.get("vegetation_last_global_render_sync_instance_count", 0) or 0),
                upload_max=float(result.get("vegetation_max_global_render_upload_bytes", 0) or 0) / (1024.0 * 1024.0),
                bounds=float(result.get("vegetation_bounds_padding", 0.0) or 0.0),
                tree_bounds=float(result.get("vegetation_tree_bounds_padding", 0.0) or 0.0),
                grass_bounds=float(result.get("vegetation_grass_bounds_padding", 0.0) or 0.0),
                rock_bounds=float(result.get("vegetation_rock_bounds_padding", 0.0) or 0.0),
                occ="on" if bool(result.get("vegetation_ignore_occlusion_culling", False)) else "off",
                exact_bounds="on" if bool(result.get("vegetation_exact_render_bounds_enabled", False)) else "off",
                exact_padding=float(result.get("vegetation_exact_render_bounds_padding", 0.0) or 0.0),
                ground_center="on" if bool(result.get("terrain_collision_ground_center", False)) else "off",
                force_pending="on" if bool(result.get("terrain_force_pending_finalization", False)) else "off",
                force_stream="on" if bool(result.get("terrain_force_stream_progress", False)) else "off",
            )
        )
        if bool(result.get("scene_scan_available", False)):
            print(
                "                     sceneScan visible/frustum geom={visible_geom}/{frustum_geom} "
                "vegBatch={veg_visible_batches}/{veg_frustum_batches} vegInst={veg_visible_instances}/{veg_frustum_instances} "
                "tri frustum terrain/veg/build/entity={terrain_tri}/{veg_tri}/{building_tri}/{entity_tri} "
                "visibleVegTri={visible_veg_tri}".format(
                    visible_geom=int(result.get("scene_scan_visible_geometry_instances", 0) or 0),
                    frustum_geom=int(result.get("scene_scan_frustum_geometry_instances", 0) or 0),
                    veg_visible_batches=int(result.get("scene_scan_visible_vegetation_batches", 0) or 0),
                    veg_frustum_batches=int(result.get("scene_scan_frustum_vegetation_batches", 0) or 0),
                    veg_visible_instances=int(result.get("scene_scan_visible_vegetation_instances", 0) or 0),
                    veg_frustum_instances=int(result.get("scene_scan_frustum_vegetation_instances", 0) or 0),
                    terrain_tri=int(result.get("scene_scan_frustum_terrain_triangles", 0) or 0),
                    veg_tri=int(result.get("scene_scan_frustum_vegetation_triangles", 0) or 0),
                    building_tri=int(result.get("scene_scan_frustum_building_triangles", 0) or 0),
                    entity_tri=int(result.get("scene_scan_frustum_entity_triangles", 0) or 0),
                    visible_veg_tri=int(result.get("scene_scan_visible_vegetation_triangles", 0) or 0),
                )
            )
        print(
            "                     entities radius spawn={spawn_radius:5.0f} active={active_radius:5.0f} "
            "effectiveActive={effective_active:5.0f} freeze={freeze_radius:5.0f}/{effective_freeze:5.0f} "
            "despawn={despawn_radius:5.0f} collision={collision_range:5.0f} chunks={spawned_chunks}/{deferred_chunks}/{deferred_plans} "
            "dormant={dormant:3d} min={min_spawn:4.0f} chance={spawn_chance:.2f} maxPerChunk={max_per_chunk} "
            "balanced={balanced}/{rings}".format(
                spawn_radius=float(result.get("entity_spawn_radius", 0.0) or 0.0),
                active_radius=float(result.get("entity_active_physics_radius", 0.0) or 0.0),
                effective_active=float(result.get("entity_effective_active_physics_radius", 0.0) or 0.0),
                freeze_radius=float(result.get("entity_freeze_radius", 0.0) or 0.0),
                effective_freeze=float(result.get("entity_effective_freeze_radius", 0.0) or 0.0),
                despawn_radius=float(result.get("entity_despawn_radius", 0.0) or 0.0),
                collision_range=float(result.get("entity_collision_range", 0.0) or 0.0),
                spawned_chunks=int(result.get("entity_spawned_chunks", 0) or 0),
                deferred_chunks=int(result.get("entity_deferred_chunks", 0) or 0),
                deferred_plans=int(result.get("entity_deferred_plans", 0) or 0),
                dormant=int(result.get("entity_dormant", 0) or 0),
                min_spawn=float(result.get("entity_min_spawn_distance", 0.0) or 0.0),
                spawn_chance=float(result.get("entity_spawn_chance_per_chunk", 0.0) or 0.0),
                max_per_chunk=int(result.get("entity_max_spawns_per_chunk", 0) or 0),
                balanced="on" if bool(result.get("entity_balance_spawn_distance_rings", False)) else "off",
                rings=int(result.get("entity_spawn_distance_ring_count", 0) or 0),
            )
        )
        print(
            "                     entityRings active=%s" % json.dumps(
                result.get("entity_active_distance_ring_counts", []),
                separators=(",", ":"),
            )
        )
        print(
            "                     entityRings pending=%s fill=%s target=%d lastQueued=%d" % (
                json.dumps(result.get("entity_pending_distance_ring_counts", []), separators=(",", ":")),
                "on" if bool(result.get("entity_balanced_ring_fill_enabled", False)) else "off",
                int(result.get("entity_balanced_ring_fill_target", 0) or 0),
                int(result.get("entity_last_balanced_ring_fill_queued", 0) or 0),
            )
        )
        print(
            "                     terrainSource srcPrims={source_prims:9d} avgSrc={avg_source:7.1f} "
            "avgMesh={avg_chunk:7.1f} maxSrc={max_source:6d} srcVerts={source_vertices:9d} "
            "uniqVerts={unique_vertices:9d} uniq/src={unique_ratio:5.2f} "
            "active={active}/{native_active} unloadHyst={unload_hyst} boundsUnload={bounds_unload} "
            "meshBuckets={mesh_buckets} srcBuckets={source_buckets}".format(
                source_prims=int(result.get("terrain_visual_source_primitives", 0) or 0),
                avg_source=float(result.get("terrain_visual_avg_source_primitives", 0.0) or 0.0),
                avg_chunk=float(result.get("terrain_visual_avg_chunk_primitives", 0.0) or 0.0),
                max_source=int(result.get("terrain_visual_max_source_chunk_primitives", 0) or 0),
                source_vertices=int(result.get("terrain_visual_source_vertices", 0) or 0),
                unique_vertices=int(result.get("terrain_visual_unique_vertices", 0) or 0),
                unique_ratio=float(result.get("terrain_visual_unique_to_source_ratio", 0.0) or 0.0),
                active=int(result.get("terrain_active_chunks", 0) or 0),
                native_active=int(result.get("terrain_native_grid_active_chunks", 0) or 0),
                unload_hyst=int(result.get("terrain_unload_hysteresis_chunks", 0) or 0),
                bounds_unload=int(result.get("terrain_last_stream_bounds_unloads", 0) or 0),
                mesh_buckets=json.dumps(result.get("terrain_visual_chunk_primitive_buckets", {}), sort_keys=True),
                source_buckets=json.dumps(result.get("terrain_visual_source_primitive_buckets", {}), sort_keys=True),
            )
        )
    print("=" * 50)


def main() -> int:
    suppress_windows_error_dialogs()
    selected = _selected_case_names()
    results = []
    for case_name in selected:
        results.append(_run_case(case_name, CASES[case_name]))
    results = _add_deltas(results)
    SUMMARY_FILE.parent.mkdir(parents=True, exist_ok=True)
    SUMMARY_FILE.write_text(json.dumps({"results": results}, indent=2), encoding="utf-8")
    _print_results(results)

    failed = [
        result
        for result in results
        if int(result.get("returncode", 1)) != 0 or not bool(result.get("hold_complete", False))
    ]
    performance_failures = [failure for result in results for failure in _performance_gate_failures(result)]
    if failed:
        print("\nABLATION MATRIX FAILED")
        for result in failed:
            print(f"- {result.get('case', 'unknown')} returncode={result.get('returncode')} hold_complete={result.get('hold_complete')}")
        return 1
    if performance_failures:
        print("\nABLATION MATRIX PERFORMANCE GATE FAILED")
        for failure in performance_failures:
            print(f"- {failure}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
