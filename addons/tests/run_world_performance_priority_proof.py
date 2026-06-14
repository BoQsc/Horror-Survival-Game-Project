import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import run_town_stall_test as town_runner
import run_town_stall_raw_baseline as raw_runner
from windows_error_dialogs import suppress_windows_error_dialogs


PROJECT_PATH = Path(__file__).resolve().parents[2]
PROJECT_ROOT = PROJECT_PATH
TEST_DIR = Path(__file__).resolve().parent
DEFAULT_OUTPUT = PROJECT_ROOT / ".agent" / "world-performance-priority-proof.json"
DEFAULT_ANALYSIS_OUTPUT = PROJECT_ROOT / ".agent" / "world-performance-priority-analysis.json"
DEFAULT_SMOKE_ANALYSIS_OUTPUT = PROJECT_ROOT / ".agent" / "world-performance-priority-smoke-analysis.json"
DEFAULT_PRODUCTION_SUITE = "priority_full"
ROADMAP_PRODUCTION_SCENARIOS = [
    "cold_world_bake",
    "low_resolution_preview",
    "cold_startup",
    "warm_startup",
    "first_exploration",
    "unchanged_revisit",
    "edit_revisit",
    "save_reload_modified",
    "world_switch_cache_isolation",
    "stationary_idle",
    "render_distance_5",
    "render_distance_10",
    "render_distance_15",
    "memory_pressure",
    "frame_time",
    "idle_power",
]
PRODUCTION_CASE_SCENARIOS = {
    "runtime_default": {
        "cold_world_bake",
        "cold_startup",
        "first_exploration",
        "stationary_idle",
        "frame_time",
        "idle_power",
    },
    "priority_revisit": {
        "unchanged_revisit",
        "stationary_idle",
        "frame_time",
        "idle_power",
    },
    "priority_warm_disk_restore": {
        "warm_startup",
        "stationary_idle",
        "frame_time",
        "idle_power",
    },
    "priority_render_distance_5": {"render_distance_5", "stationary_idle", "frame_time", "idle_power"},
    "priority_render_distance_10": {"render_distance_10", "stationary_idle", "frame_time", "idle_power"},
    "priority_render_distance_15": {"render_distance_15", "stationary_idle", "frame_time", "idle_power"},
    "priority_memory_pressure": {"memory_pressure", "stationary_idle", "frame_time", "idle_power"},
}
CONTRACT_SCENARIOS = {
    "terrain_warm_startup_preheat_contract": {"warm_startup"},
    "terrain_world_artifact_path_contract": {"cold_world_bake", "warm_startup"},
    "world_terrain_artifact_baker_contract": {"cold_world_bake", "warm_startup"},
    "world_terrain_artifact_baker_live_smoke_contract": {"cold_world_bake", "warm_startup"},
    "terrain_generation_telemetry_contract": {"edit_revisit"},
    "terrain_world_definition_change_contract": {"world_switch_cache_isolation"},
    "save_manager_terrain_modifications_contract": {"save_reload_modified"},
    "world_map_preview_builder_contract": {"low_resolution_preview"},
    "world_map_generator_ui_progress_contract": {"low_resolution_preview"},
    "world_map_lake_native_contract": {"cold_world_bake"},
    "world_map_rasterization_native_contract": {"cold_world_bake"},
    "world_map_road_spatial_index_contract": {"cold_world_bake"},
    "world_map_road_footprint_native_contract": {"cold_world_bake"},
    "world_map_building_support_native_contract": {"cold_world_bake"},
    "world_map_building_pad_flatten_native_contract": {"cold_world_bake"},
    "world_map_excavation_native_contract": {"cold_world_bake"},
    "world_map_compact_terrain_modifications_contract": {"cold_world_bake"},
}
PRODUCTION_CASE_SUITES = {
    "priority_smoke": ["runtime_default"],
    "priority_revisit": ["runtime_default", "priority_revisit"],
    "priority_warm_disk_restore": ["runtime_default", "priority_warm_disk_restore"],
    "priority_render_distance": [
        "priority_render_distance_5",
        "priority_render_distance_10",
        "priority_render_distance_15",
        "priority_memory_pressure",
    ],
    "priority_full": [
        "runtime_default",
        "priority_revisit",
        "priority_warm_disk_restore",
        "priority_render_distance_5",
        "priority_render_distance_10",
        "priority_render_distance_15",
        "priority_memory_pressure",
    ],
}
FORBIDDEN_FAST_GODOT_SCRIPT_MARKERS = (
    "_bot",
    "bot.gd",
    "town_stall_test_harness",
    "procedural_power_test_harness",
    "quickload",
    "movement_bot",
    "zombie",
)
FORBIDDEN_FAST_PYTHON_LAUNCHERS = {
    "run_town_stall_test.py",
    "run_town_stall_raw_baseline.py",
    "run_procedural_power_test.py",
    "run_movement_test.py",
    "run_idle_power_test.py",
    "run_endurance_power_test.py",
}


@dataclass
class ProofStep:
    name: str
    command: list[str]
    timeout_seconds: Optional[float] = None
    env: dict[str, str] = field(default_factory=dict)
    heavy: bool = False
    uses_godot: bool = False


def _fmt_number(value: float) -> str:
    text = f"{float(value):.6f}".rstrip("0").rstrip(".")
    return text if text else "0"


def _optional_float_arg(command: list[str], flag: str, value: Optional[float]) -> None:
    if value is not None:
        command.extend([flag, _fmt_number(value)])


def _optional_int_arg(command: list[str], flag: str, value: Optional[int]) -> None:
    if value is not None:
        command.extend([flag, str(int(value))])


def _python_step(name: str, script: str, args: Optional[list[str]] = None, timeout_seconds: Optional[float] = None) -> ProofStep:
    return ProofStep(
        name=name,
        command=[sys.executable, str(TEST_DIR / script)] + list(args or []),
        timeout_seconds=timeout_seconds,
    )


def _godot_step(name: str, script: str, timeout_seconds: Optional[float] = None) -> ProofStep:
    return ProofStep(
        name=name,
        command=[
            town_runner.GODOT_BIN,
            "--headless",
            "--rendering-driver",
            "vulkan",
            "--rendering-method",
            "forward_plus",
            "--path",
            str(PROJECT_ROOT),
            "-s",
            f"addons/tests/{script}",
        ],
        timeout_seconds=timeout_seconds,
        uses_godot=True,
    )


def _godot_check_only_step(timeout_seconds: Optional[float] = None) -> ProofStep:
    return ProofStep(
        name="godot_editor_parse_check",
        command=[
            town_runner.GODOT_BIN,
            "--headless",
            "--rendering-driver",
            "vulkan",
            "--rendering-method",
            "forward_plus",
            "--path",
            str(PROJECT_ROOT),
            "--quit",
            "--check-only",
        ],
        timeout_seconds=timeout_seconds,
        uses_godot=True,
    )


def build_smoke_steps(args: argparse.Namespace) -> list[ProofStep]:
    steps: list[ProofStep] = [
        _python_step("godot_launcher_safety", "check_godot_launcher_safety.py", timeout_seconds=30.0),
        _python_step("third_party_policy", "check_third_party_policy.py", timeout_seconds=60.0),
        _python_step("world_performance_priority_readiness_audit", "audit_world_performance_priority_readiness.py", timeout_seconds=30.0),
    ]
    if not args.skip_godot:
        steps.extend(
            [
                _godot_step("world_startup_coordinator_contract", "world_startup_coordinator_test.gd", timeout_seconds=120.0),
                _godot_step("loading_screen_progress_contract", "loading_screen_progress_test.gd", timeout_seconds=120.0),
                _godot_step("player_viewer_signal_contract", "player_viewer_signal_test.gd", timeout_seconds=120.0),
                _godot_step("terrain_startup_readiness_detail_contract", "terrain_startup_readiness_detail_test.gd", timeout_seconds=120.0),
                _godot_step("terrain_artifact_cache_contract", "terrain_artifact_cache_test.gd", timeout_seconds=120.0),
                _godot_step("terrain_artifact_disk_store_contract", "terrain_artifact_disk_store_test.gd", timeout_seconds=120.0),
                _godot_step("terrain_startup_preheat_contract", "terrain_startup_preheat_test.gd", timeout_seconds=120.0),
                _godot_step("terrain_warm_startup_preheat_contract", "terrain_warm_startup_preheat_test.gd", timeout_seconds=120.0),
                _godot_step("terrain_world_artifact_path_contract", "terrain_world_artifact_path_test.gd", timeout_seconds=120.0),
                _godot_step("world_terrain_artifact_baker_contract", "world_terrain_artifact_baker_contract_test.gd", timeout_seconds=120.0),
                _godot_step("world_terrain_artifact_baker_live_smoke_contract", "world_terrain_artifact_baker_live_smoke_test.gd", timeout_seconds=180.0),
                _godot_step("terrain_generation_telemetry_contract", "terrain_generation_telemetry_test.gd", timeout_seconds=120.0),
                _godot_step("terrain_height_map_samples_native_contract", "terrain_height_map_samples_native_test.gd", timeout_seconds=120.0),
                _godot_step("terrain_mask_sample_telemetry_contract", "terrain_mask_sample_telemetry_test.gd", timeout_seconds=120.0),
                _godot_step("terrain_process_sleep_contract", "terrain_process_sleep_test.gd", timeout_seconds=120.0),
                _godot_step("terrain_runtime_setting_wake_contract", "terrain_runtime_setting_wake_test.gd", timeout_seconds=120.0),
                _godot_step("terrain_world_definition_change_contract", "terrain_world_definition_change_test.gd", timeout_seconds=120.0),
                _godot_step("town_stall_artifact_budget_override_contract", "town_stall_artifact_budget_override_test.gd", timeout_seconds=120.0),
                _godot_step("save_manager_terrain_modifications_contract", "save_manager_terrain_modifications_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_preview_builder_contract", "world_map_preview_builder_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_generator_ui_progress_contract", "world_map_generator_ui_progress_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_bake_proof_contract", "world_map_bake_proof_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_height_biome_native_contract", "world_map_height_biome_native_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_lake_native_contract", "world_map_lake_native_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_rasterization_native_contract", "world_map_rasterization_native_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_road_spatial_index_contract", "world_map_road_spatial_index_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_road_footprint_native_contract", "world_map_road_footprint_native_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_building_support_native_contract", "world_map_building_support_native_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_building_pad_flatten_native_contract", "world_map_building_pad_flatten_native_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_excavation_native_contract", "world_map_excavation_native_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_compact_terrain_modifications_contract", "world_map_compact_terrain_modifications_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_height_biome_thread_policy_contract", "world_map_height_biome_thread_policy_test.gd", timeout_seconds=120.0),
                _godot_step("world_map_mask_samples_native_contract", "world_map_mask_samples_native_test.gd", timeout_seconds=120.0),
                _godot_step("entity_startup_readiness_contract", "entity_startup_readiness_snapshot_test.gd", timeout_seconds=120.0),
                _godot_step("building_grouped_merge_native_contract", "building_grouped_merge_native_test.gd", timeout_seconds=120.0),
                _godot_step("building_viewer_signal_contract", "building_viewer_signal_test.gd", timeout_seconds=120.0),
                _godot_step("vegetation_cluster_payload_native_contract", "vegetation_cluster_payload_native_test.gd", timeout_seconds=120.0),
                _godot_step("vegetation_chunk_placement_cache_contract", "vegetation_chunk_placement_cache_test.gd", timeout_seconds=120.0),
                _godot_step("vegetation_generation_timing_contract", "vegetation_generation_timing_telemetry_test.gd", timeout_seconds=120.0),
                _godot_step("vegetation_native_record_append_contract", "vegetation_native_record_append_test.gd", timeout_seconds=120.0),
                _godot_step("vegetation_noise_samples_native_contract", "vegetation_noise_samples_native_test.gd", timeout_seconds=120.0),
                _godot_step("vegetation_pending_chunk_scheduler_native_contract", "vegetation_pending_chunk_scheduler_native_test.gd", timeout_seconds=120.0),
                _godot_step("vegetation_removed_filter_native_contract", "vegetation_removed_filter_native_test.gd", timeout_seconds=120.0),
                _godot_step("vegetation_viewer_signal_contract", "vegetation_viewer_signal_test.gd", timeout_seconds=120.0),
                _godot_step("entity_pool_reuse_contract", "entity_pool_reuse_test.gd", timeout_seconds=120.0),
                _godot_step("entity_maintenance_driver_contract", "entity_maintenance_driver_test.gd", timeout_seconds=120.0),
                _godot_step("entity_viewer_signal_contract", "entity_viewer_signal_test.gd", timeout_seconds=120.0),
                _godot_step("entity_background_spawn_idle_contract", "entity_background_spawn_idle_test.gd", timeout_seconds=120.0),
                _godot_step("town_stall_monitor_snapshot_contract", "town_stall_monitor_snapshot_test.gd", timeout_seconds=120.0),
            ]
        )
        if args.include_parse_check:
            steps.append(_godot_check_only_step(timeout_seconds=180.0))
    if not args.skip_python:
        steps.extend(
            [
                _python_step("production_snapshot_verdict_contract", "analyze_performance_snapshot_verdict_test.py", timeout_seconds=30.0),
                _python_step("town_snapshot_gate_contract", "run_town_stall_snapshot_gate_test.py", timeout_seconds=30.0),
                _python_step("raw_baseline_proof_contract", "run_town_stall_raw_baseline_proof_test.py", timeout_seconds=30.0),
                _python_step("raw_baseline_analyzer_contract", "analyze_raw_baseline_proof_test.py", timeout_seconds=30.0),
                _python_step(
                    "existing_snapshot_analysis_smoke",
                    "analyze_performance_snapshots.py",
                    [
                        "--town-count",
                        "1",
                        "--gpu-telemetry-count",
                        "1",
                        "--output",
                        str(args.smoke_analysis_output),
                    ],
                    timeout_seconds=120.0,
                ),
            ]
        )
    return steps


def _split_cases(cases_text: str) -> list[str]:
    return [case.strip() for case in str(cases_text or "").split(",") if case.strip()]


def _resolve_production_case_names(args: argparse.Namespace) -> list[str]:
    explicit_cases = _split_cases(str(args.production_cases or ""))
    if explicit_cases:
        return explicit_cases
    return list(PRODUCTION_CASE_SUITES.get(str(args.production_suite), PRODUCTION_CASE_SUITES[DEFAULT_PRODUCTION_SUITE]))


def _production_plan(args: argparse.Namespace) -> dict:
    case_names = _resolve_production_case_names(args)
    raw_case_covered: set[str] = set()
    for case_name in case_names:
        raw_case_covered.update(PRODUCTION_CASE_SCENARIOS.get(case_name, set()))
    covered: set[str] = set(raw_case_covered)
    contract_covered: set[str] = set()
    if not args.skip_godot:
        for scenarios in CONTRACT_SCENARIOS.values():
            contract_covered.update(scenarios)
    covered.update(contract_covered)
    required = list(ROADMAP_PRODUCTION_SCENARIOS)
    missing = [scenario for scenario in required if scenario not in covered]
    external_preparation_candidates = [
        "warm_startup",
        "edit_revisit",
        "save_reload_modified",
        "world_switch_cache_isolation",
    ]
    return {
        "suite": str(args.production_suite),
        "explicit_cases": bool(_split_cases(str(args.production_cases or ""))),
        "cases": case_names,
        "raw_case_covered_scenarios": [scenario for scenario in required if scenario in raw_case_covered],
        "contract_covered_scenarios": [scenario for scenario in required if scenario in contract_covered],
        "contract_only_scenarios": [scenario for scenario in required if scenario in contract_covered and scenario not in raw_case_covered],
        "covered_scenarios": [scenario for scenario in required if scenario in covered],
        "missing_scenarios": missing,
        "requires_external_preparation": [scenario for scenario in external_preparation_candidates if scenario in missing],
    }


def _completion_audit(args: argparse.Namespace, production_plan: dict, results: Optional[list[dict]] = None) -> dict:
    results = list(results or [])
    heavy_results = [result for result in results if bool(result.get("heavy", False))]
    if args.dry_run:
        production_evidence_status = "dry_run_only"
    elif not args.run_production:
        production_evidence_status = "not_requested"
    elif not heavy_results:
        production_evidence_status = "requested_not_completed"
    elif all(str(result.get("status", "")) == "passed" for result in heavy_results):
        production_evidence_status = "executed_passed"
    else:
        production_evidence_status = "executed_failed_or_incomplete"

    remaining_blockers: list[str] = []
    missing_scenarios = [str(scenario) for scenario in production_plan.get("missing_scenarios", [])]
    if missing_scenarios:
        remaining_blockers.append("scenario coverage plan still has missing roadmap scenarios")
    if production_evidence_status != "executed_passed":
        remaining_blockers.append("accepted heavy production proof run has not passed")
    remaining_blockers.extend(
        [
            "thresholds still need tuning from accepted production captures",
            "GPU sync/readback A/B decision still needs accepted cache-miss production data",
            "temporary rollout and test hooks still need cleanup after accepted production proof",
        ]
    )

    return {
        "complete": False,
        "production_evidence_status": production_evidence_status,
        "planned_scenarios_missing": missing_scenarios,
        "raw_case_covered_scenarios": list(production_plan.get("raw_case_covered_scenarios", [])),
        "contract_only_scenarios": list(production_plan.get("contract_only_scenarios", [])),
        "accepted_production_evidence_required": True,
        "remaining_blockers": remaining_blockers,
    }


def build_production_steps(args: argparse.Namespace) -> list[ProofStep]:
    if not args.run_production:
        return []

    production_cases = ",".join(_resolve_production_case_names(args))
    raw_command = [
        sys.executable,
        str(TEST_DIR / "run_town_stall_raw_baseline.py"),
        "--cases",
        production_cases,
        "--repeats",
        str(args.production_repeats),
        "--hold-seconds",
        _fmt_number(args.production_hold_seconds),
        "--idle-seconds",
        _fmt_number(args.production_idle_seconds),
        "--sample-interval",
        _fmt_number(args.production_sample_interval),
        "--require-startup-readiness-proof",
        "--require-world-bake-proof",
        "--require-world-bake-export-signature",
        "--require-world-bake-height-biome-backend",
        args.world_bake_backend,
        "--min-world-bake-layers",
        str(args.min_world_bake_layers),
        "--require-runtime-idle-proof",
        "--require-terrain-artifact-cache-proof",
    ]
    if args.allow_contaminated_idle:
        raw_command.append("--allow-contaminated-idle")
    _optional_float_arg(raw_command, "--max-gpu-temp-c", args.max_gpu_temp_c)
    _optional_float_arg(raw_command, "--preflight-max-gpu-temp-c", args.preflight_max_gpu_temp_c)
    _optional_float_arg(raw_command, "--preflight-cooldown-timeout-seconds", args.preflight_cooldown_timeout_seconds)
    _optional_float_arg(raw_command, "--preflight-idle-retry-timeout-seconds", args.preflight_idle_retry_timeout_seconds)
    _optional_float_arg(raw_command, "--preflight-idle-retry-poll-seconds", args.preflight_idle_retry_poll_seconds)
    _optional_float_arg(raw_command, "--max-startup-elapsed-ms", args.max_startup_elapsed_ms)
    _optional_float_arg(raw_command, "--max-startup-stage-ms", args.max_startup_stage_ms)
    _optional_float_arg(raw_command, "--min-startup-trace-events", args.min_startup_trace_events)
    _optional_float_arg(raw_command, "--max-world-bake-ms", args.max_world_bake_ms)
    _optional_float_arg(raw_command, "--max-world-bake-hash-ms", args.max_world_bake_hash_ms)
    _optional_float_arg(raw_command, "--max-world-bake-unaccounted-ms", args.max_world_bake_unaccounted_ms)
    _optional_float_arg(raw_command, "--min-runtime-idle-ratio", args.min_runtime_idle_ratio)
    _optional_float_arg(raw_command, "--max-runtime-pending-work", args.max_runtime_pending_work)
    _optional_float_arg(raw_command, "--max-runtime-awake-process-count", args.max_runtime_awake_process_count)
    _optional_float_arg(raw_command, "--min-terrain-artifact-cache-hit-ratio", args.min_terrain_artifact_cache_hit_ratio)
    _optional_float_arg(raw_command, "--min-terrain-artifact-cache-disk-hit-delta", args.min_terrain_artifact_cache_disk_hit_delta)
    _optional_float_arg(raw_command, "--min-terrain-artifact-ready-resource-restore-delta", args.min_terrain_artifact_ready_resource_restore_delta)
    _optional_float_arg(raw_command, "--max-terrain-artifact-cache-byte-budget-ratio", args.max_terrain_artifact_cache_byte_budget_ratio)
    _optional_float_arg(raw_command, "--max-terrain-artifact-cache-eviction-delta", args.max_terrain_artifact_cache_eviction_delta)
    _optional_float_arg(raw_command, "--max-terrain-artifact-disk-cache-byte-budget-ratio", args.max_terrain_artifact_disk_cache_byte_budget_ratio)
    _optional_float_arg(raw_command, "--max-terrain-artifact-disk-cache-eviction-delta", args.max_terrain_artifact_disk_cache_eviction_delta)
    raw_env = {
        "TOWN_STALL_RAW_RUN_TIMEOUT_SECONDS": str(max(420, int(args.production_case_timeout_seconds))),
        "TOWN_STALL_TIMEOUT_SECONDS": str(max(420, int(args.production_case_timeout_seconds))),
    }

    analysis_command = [
        sys.executable,
        str(TEST_DIR / "analyze_performance_snapshots.py"),
        "--town-count",
        str(args.analysis_town_count),
        "--gpu-telemetry-count",
        str(args.analysis_gpu_telemetry_count),
        "--output",
        str(args.analysis_output),
        "--require-latest-raw-baseline-startup-readiness-proof",
        "--require-latest-raw-baseline-world-bake-proof",
        "--require-latest-raw-baseline-world-bake-export-signature",
        "--require-latest-raw-baseline-world-bake-height-biome-backend",
        args.world_bake_backend,
        "--min-latest-raw-baseline-world-bake-layers",
        str(args.min_world_bake_layers),
        "--require-latest-raw-baseline-runtime-idle-proof",
        "--require-latest-raw-baseline-terrain-artifact-cache-proof",
    ]
    _optional_float_arg(analysis_command, "--max-latest-raw-baseline-startup-elapsed-ms", args.max_startup_elapsed_ms)
    _optional_float_arg(analysis_command, "--max-latest-raw-baseline-startup-stage-ms", args.max_startup_stage_ms)
    _optional_float_arg(analysis_command, "--max-latest-raw-baseline-world-bake-ms", args.max_world_bake_ms)
    _optional_float_arg(analysis_command, "--max-latest-raw-baseline-world-bake-hash-ms", args.max_world_bake_hash_ms)
    _optional_float_arg(analysis_command, "--max-latest-raw-baseline-world-bake-unaccounted-ms", args.max_world_bake_unaccounted_ms)
    _optional_float_arg(analysis_command, "--min-latest-raw-baseline-runtime-idle-ratio", args.min_runtime_idle_ratio)
    _optional_float_arg(analysis_command, "--max-latest-raw-baseline-runtime-busy-samples", args.max_runtime_busy_samples)
    _optional_float_arg(analysis_command, "--min-latest-raw-baseline-terrain-artifact-cache-hit-ratio", args.min_terrain_artifact_cache_hit_ratio)
    _optional_float_arg(analysis_command, "--max-latest-raw-baseline-terrain-artifact-cache-byte-budget-ratio", args.max_terrain_artifact_cache_byte_budget_ratio)
    _optional_float_arg(analysis_command, "--max-latest-raw-baseline-terrain-artifact-cache-eviction-delta", args.max_terrain_artifact_cache_eviction_delta)

    return [
        ProofStep(
            name="production_raw_baseline_with_priority_gates",
            command=raw_command,
            timeout_seconds=args.production_timeout_seconds,
            env=raw_env,
            heavy=True,
        ),
        ProofStep(
            name="production_raw_baseline_analysis_gate",
            command=analysis_command,
            timeout_seconds=args.analysis_timeout_seconds,
            heavy=True,
        ),
    ]


def build_steps(args: argparse.Namespace) -> list[ProofStep]:
    return build_smoke_steps(args) + build_production_steps(args)


def _script_arg_from_command(command: list[str], flag: str) -> str:
    for index, part in enumerate(command):
        if str(part) == flag and index + 1 < len(command):
            return str(command[index + 1])
    return ""


def _validate_fast_godot_step_safety(step: ProofStep) -> list[str]:
    script = _script_arg_from_command(step.command, "-s")
    if not script and "--check-only" in [str(part) for part in step.command]:
        return []
    if not script:
        return [f"{step.name}: fast Godot step must use -s addons/tests/*_test.gd or --check-only"]

    normalized_script = script.replace("\\", "/")
    script_name = Path(normalized_script).name
    failures: list[str] = []
    if not normalized_script.startswith("addons/tests/"):
        failures.append(f"{step.name}: fast Godot script must be under addons/tests: {script}")
    if not script_name.endswith("_test.gd"):
        failures.append(f"{step.name}: fast Godot script must be a focused *_test.gd contract: {script}")
    lowered = normalized_script.lower()
    for marker in FORBIDDEN_FAST_GODOT_SCRIPT_MARKERS:
        if marker in lowered:
            failures.append(f"{step.name}: fast Godot proof must not launch gameplay/bot harness script: {script}")
            break
    return failures


def _validate_fast_python_step_safety(step: ProofStep) -> list[str]:
    failures: list[str] = []
    for part in step.command:
        part_text = str(part)
        if not part_text.lower().endswith(".py"):
            continue
        script_name = Path(part_text).name
        if script_name in FORBIDDEN_FAST_PYTHON_LAUNCHERS:
            failures.append(f"{step.name}: non-production proof step must not launch {script_name}")
    return failures


def validate_step_safety(args: argparse.Namespace, steps: list[ProofStep]) -> list[str]:
    failures: list[str] = []
    for step in steps:
        if step.heavy:
            if not args.run_production:
                failures.append(f"{step.name}: heavy step is present without --run-production")
            continue
        if step.uses_godot:
            failures.extend(_validate_fast_godot_step_safety(step))
        else:
            failures.extend(_validate_fast_python_step_safety(step))
    return failures


def validate_args(args: argparse.Namespace) -> list[str]:
    if not args.run_production:
        return []
    failures: list[str] = []
    unknown_suite = str(args.production_suite) not in PRODUCTION_CASE_SUITES
    if unknown_suite:
        failures.append(f"--production-suite must be one of: {', '.join(sorted(PRODUCTION_CASE_SUITES))}")
    known_cases = set(raw_runner.CASE_DEFINITIONS.keys())
    for case_name in _resolve_production_case_names(args):
        if known_cases and case_name not in known_cases:
            failures.append(f"production case {case_name} is not defined by run_town_stall_raw_baseline.py")
    if args.production_mode == "pilot":
        return failures
    if args.allow_contaminated_idle:
        failures.append("--allow-contaminated-idle requires --production-mode pilot")
    if str(args.world_bake_backend).strip().lower() != "native":
        failures.append("--world-bake-backend must be native for production proof mode")
    if args.max_gpu_temp_c is not None and args.max_gpu_temp_c <= 0:
        failures.append("--max-gpu-temp-c must be positive for production proof mode")
    if args.preflight_max_gpu_temp_c is not None and args.preflight_max_gpu_temp_c <= 0:
        failures.append("--preflight-max-gpu-temp-c must be positive for production proof mode")
    return failures


def _tail(text: str, limit: int = 4000) -> str:
    if len(text) <= limit:
        return text
    return text[-limit:]


def _assert_no_godot_processes() -> None:
    running_processes = town_runner._find_running_godot_processes()
    if running_processes:
        details = []
        for process in running_processes[:5]:
            process_id = int(process.get("ProcessId", 0) or 0)
            process_name = str(process.get("Name", "godot"))
            details.append(f"PID {process_id} - {process_name}")
        raise RuntimeError("A Godot process is already running: " + "; ".join(details))


def _run_step(step: ProofStep, dry_run: bool) -> dict:
    started = time.time()
    result = {
        "name": step.name,
        "command": step.command,
        "heavy": step.heavy,
        "timeout_seconds": step.timeout_seconds,
        "started_at_epoch": started,
        "dry_run": dry_run,
    }
    if dry_run:
        result.update({
            "returncode": 0,
            "duration_s": 0.0,
            "status": "skipped",
            "stdout_tail": "",
            "stderr_tail": "",
        })
        return result

    print(f"[priority-proof] running {step.name}")
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env.update(step.env)
    try:
        if step.uses_godot:
            _assert_no_godot_processes()
        completed = subprocess.run(
            step.command,
            cwd=PROJECT_ROOT,
            env=env,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            timeout=step.timeout_seconds,
        )
        duration = time.time() - started
        result.update(
            {
                "returncode": int(completed.returncode),
                "duration_s": duration,
                "status": "passed" if completed.returncode == 0 else "failed",
                "stdout_tail": _tail(completed.stdout or ""),
                "stderr_tail": _tail(completed.stderr or ""),
            }
        )
    except subprocess.TimeoutExpired as exc:
        duration = time.time() - started
        result.update(
            {
                "returncode": None,
                "duration_s": duration,
                "status": "timeout",
                "stdout_tail": _tail(exc.stdout or ""),
                "stderr_tail": _tail(exc.stderr or ""),
            }
        )
    return result


def _write_report(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run executable proof checks for WORLD_PERFORMANCE_EXECUTION_PRIORITY.md.")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--smoke-analysis-output", type=Path, default=DEFAULT_SMOKE_ANALYSIS_OUTPUT)
    parser.add_argument("--analysis-output", type=Path, default=DEFAULT_ANALYSIS_OUTPUT)
    parser.add_argument("--dry-run", action="store_true", help="Write the planned command report without launching anything.")
    parser.add_argument("--skip-godot", action="store_true")
    parser.add_argument("--skip-python", action="store_true")
    parser.add_argument("--include-parse-check", action="store_true")

    parser.add_argument("--run-production", action="store_true", help="Launch the heavy town raw-baseline proof flow with priority gates.")
    parser.add_argument(
        "--production-mode",
        choices=("proof", "pilot"),
        default="proof",
        help="proof rejects contaminated or fallback-backend runs; pilot labels exploratory heavy diagnostics.",
    )
    parser.add_argument("--production-suite", choices=tuple(sorted(PRODUCTION_CASE_SUITES)), default=DEFAULT_PRODUCTION_SUITE)
    parser.add_argument("--production-cases", default=None, help="Comma-separated raw baseline cases. Overrides --production-suite when set.")
    parser.add_argument("--production-repeats", type=int, default=1)
    parser.add_argument("--production-hold-seconds", type=float, default=40.0)
    parser.add_argument("--production-idle-seconds", type=float, default=20.0)
    parser.add_argument("--production-sample-interval", type=float, default=1.0)
    parser.add_argument("--production-timeout-seconds", type=float, default=7200.0)
    parser.add_argument("--production-case-timeout-seconds", type=float, default=900.0)
    parser.add_argument("--allow-contaminated-idle", action="store_true")
    parser.add_argument("--max-gpu-temp-c", type=float, default=None)
    parser.add_argument("--preflight-max-gpu-temp-c", type=float, default=80.0)
    parser.add_argument("--preflight-cooldown-timeout-seconds", type=float, default=600.0)
    parser.add_argument("--preflight-idle-retry-timeout-seconds", type=float, default=300.0)
    parser.add_argument("--preflight-idle-retry-poll-seconds", type=float, default=15.0)

    parser.add_argument("--world-bake-backend", default="native")
    parser.add_argument("--min-world-bake-layers", type=int, default=5)
    parser.add_argument("--max-startup-elapsed-ms", type=float, default=None)
    parser.add_argument("--max-startup-stage-ms", type=float, default=None)
    parser.add_argument("--min-startup-trace-events", type=float, default=None)
    parser.add_argument("--max-world-bake-ms", type=float, default=None)
    parser.add_argument("--max-world-bake-hash-ms", type=float, default=None)
    parser.add_argument("--max-world-bake-unaccounted-ms", type=float, default=None)
    parser.add_argument("--min-runtime-idle-ratio", type=float, default=None)
    parser.add_argument("--max-runtime-pending-work", type=float, default=None)
    parser.add_argument("--max-runtime-awake-process-count", type=float, default=None)
    parser.add_argument("--max-runtime-busy-samples", type=float, default=None)
    parser.add_argument("--min-terrain-artifact-cache-hit-ratio", type=float, default=None)
    parser.add_argument("--min-terrain-artifact-cache-disk-hit-delta", type=float, default=None)
    parser.add_argument("--min-terrain-artifact-ready-resource-restore-delta", type=float, default=None)
    parser.add_argument("--max-terrain-artifact-cache-byte-budget-ratio", type=float, default=None)
    parser.add_argument("--max-terrain-artifact-cache-eviction-delta", type=float, default=None)
    parser.add_argument("--max-terrain-artifact-disk-cache-byte-budget-ratio", type=float, default=None)
    parser.add_argument("--max-terrain-artifact-disk-cache-eviction-delta", type=float, default=None)
    parser.add_argument("--analysis-town-count", type=int, default=3)
    parser.add_argument("--analysis-gpu-telemetry-count", type=int, default=3)
    parser.add_argument("--analysis-timeout-seconds", type=float, default=300.0)
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    suppress_windows_error_dialogs()
    args = parse_args(argv)
    started = time.time()
    validation_errors = validate_args(args)
    if validation_errors:
        production_plan = _production_plan(args)
        payload = {
            "started_at_epoch": started,
            "ended_at_epoch": time.time(),
            "duration_s": time.time() - started,
            "project_root": str(PROJECT_ROOT),
            "dry_run": bool(args.dry_run),
            "run_production": bool(args.run_production),
            "production_mode": str(args.production_mode),
            "production_plan": production_plan,
            "completion_audit": _completion_audit(args, production_plan),
            "passed": False,
            "validation_errors": validation_errors,
            "step_count": 0,
            "completed_step_count": 0,
            "steps": [],
        }
        _write_report(args.output, payload)
        for error in validation_errors:
            print(f"[priority-proof] invalid production proof: {error}")
        print(f"[priority-proof] wrote {args.output}")
        return 2

    steps = build_steps(args)
    step_safety_errors = validate_step_safety(args, steps)
    if step_safety_errors:
        production_plan = _production_plan(args)
        payload = {
            "started_at_epoch": started,
            "ended_at_epoch": time.time(),
            "duration_s": time.time() - started,
            "project_root": str(PROJECT_ROOT),
            "dry_run": bool(args.dry_run),
            "run_production": bool(args.run_production),
            "production_mode": str(args.production_mode),
            "production_plan": production_plan,
            "completion_audit": _completion_audit(args, production_plan),
            "passed": False,
            "validation_errors": step_safety_errors,
            "step_count": len(steps),
            "completed_step_count": 0,
            "steps": [],
        }
        _write_report(args.output, payload)
        for error in step_safety_errors:
            print(f"[priority-proof] unsafe proof step: {error}")
        print(f"[priority-proof] wrote {args.output}")
        return 2

    results: list[dict] = []
    exit_code = 0
    for step in steps:
        result = _run_step(step, args.dry_run)
        results.append(result)
        if result.get("status") not in ("passed", "skipped"):
            exit_code = 1
            break

    production_plan = _production_plan(args)
    payload = {
        "started_at_epoch": started,
        "ended_at_epoch": time.time(),
        "duration_s": time.time() - started,
        "project_root": str(PROJECT_ROOT),
        "dry_run": bool(args.dry_run),
        "run_production": bool(args.run_production),
        "production_mode": str(args.production_mode),
        "production_plan": production_plan,
        "completion_audit": _completion_audit(args, production_plan, results),
        "passed": exit_code == 0,
        "step_count": len(steps),
        "completed_step_count": len(results),
        "steps": results,
    }
    _write_report(args.output, payload)
    print(f"[priority-proof] wrote {args.output}")
    if exit_code == 0:
        print("[priority-proof] passed")
    else:
        print("[priority-proof] failed")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
