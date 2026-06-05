import argparse
import json
import os
import tempfile
from pathlib import Path

import run_town_stall_raw_baseline as raw_runner


def _args(**overrides) -> argparse.Namespace:
    values = {
        "require_startup_readiness_proof": True,
        "min_startup_completed_stages": len(raw_runner.town_runner.STARTUP_PROOF_STAGE_IDS),
        "max_startup_elapsed_ms": 1500.0,
        "max_startup_stage_ms": 100.0,
        "min_startup_trace_events": 8.0,
        "require_world_bake_proof": True,
        "require_world_bake_export_signature": True,
        "require_world_bake_height_biome_backend": "native",
        "min_world_bake_layers": 5,
        "max_world_bake_ms": 6000.0,
        "max_world_bake_hash_ms": 5.0,
        "max_world_bake_unaccounted_ms": 100.0,
        "require_runtime_idle_proof": True,
        "min_runtime_idle_proof_samples": 3,
        "min_runtime_idle_ratio": 1.0,
        "max_runtime_pending_work": 0.0,
        "max_runtime_awake_process_count": 0.0,
        "require_terrain_artifact_cache_proof": True,
        "min_terrain_artifact_cache_proof_samples": 3,
        "min_terrain_artifact_cache_hit_ratio": 0.9,
        "min_terrain_artifact_cache_disk_hit_delta": 2.0,
        "max_terrain_artifact_cache_byte_budget_ratio": 0.8,
        "max_terrain_artifact_cache_eviction_delta": 0.0,
        "max_terrain_artifact_disk_cache_byte_budget_ratio": 0.9,
        "max_terrain_artifact_disk_cache_eviction_delta": 0.0,
        "preflight_idle_retry_timeout_seconds": 300.0,
        "preflight_idle_retry_poll_seconds": 15.0,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def _snapshot_payload() -> dict:
    stationary_hold_window = {
        "sample_count": 3,
        "avg_fps": 60.0,
        "avg_total_ms": 16.0,
        "world_runtime_monitor_available_samples": 3,
        "world_runtime_idle_samples": 3,
        "world_runtime_busy_samples": 0,
        "world_runtime_idle_sample_ratio": 1.0,
        "max_world_runtime_pending_work": 0.0,
        "max_world_runtime_awake_process_count": 0.0,
        "avg_terrain_artifact_cache_hit_ratio": 0.92,
        "end_terrain_artifact_cache_hit_ratio": 0.95,
        "max_terrain_artifact_cache_entries": 12.0,
        "end_terrain_artifact_cache_entries": 11.0,
        "max_terrain_artifact_cache_byte_budget_ratio": 0.5,
        "terrain_artifact_cache_eviction_delta": 0.0,
        "max_terrain_artifact_disk_cache_byte_budget_ratio": 0.4,
        "terrain_artifact_cache_disk_hit_delta": 3.0,
        "terrain_artifact_disk_cache_eviction_delta": 0.0,
    }
    return {
        "benchmark_hold_complete": True,
        "benchmark_hold_seconds": 30.0,
        "town_entry_window": stationary_hold_window,
        "moving_entry_window": {"sample_count": 1, "avg_fps": 60.0},
        "stationary_hold_window": stationary_hold_window,
        "startup_readiness_verdict": {
            "available": True,
            "completed": True,
            "loading_screen_available": True,
            "startup_coordinator_available": True,
            "loading_active": False,
            "failed": False,
            "cancelled": False,
            "playable_ready": True,
            "world_monitor_completed": True,
            "progress_percent": 100.0,
            "elapsed_ms": 1000.0,
            "completed_stage_count": len(raw_runner.town_runner.STARTUP_PROOF_STAGE_IDS),
            "incomplete_stage_count": 0,
            "missing_stage_count": 0,
            "max_stage_duration_ms": 80.0,
            "trace_event_count": 12,
        },
        "world_bake_proof": {
            "available": True,
            "success": True,
            "height_biome_backend": "native",
            "expected_baked_layer_count": 5,
            "baked_layer_count": 5,
            "missing_layers": [],
            "invalid_layers": [],
            "content_signature": "content-sig",
            "generation_total_ms": 5000.0,
            "generation_unaccounted_ms": 50.0,
            "total_hash_ms": 3.0,
            "generation_profile": {
                "height_biome_backend": "native",
                "height_biome_ms": 1000.0,
                "layout_ms": 2500.0,
                "lakes_ms": 800.0,
                "finalize_ms": 650.0,
                "total_ms": 5000.0,
            },
            "save_profile": {
                "success": True,
                "cache_signature": "export-sig",
                "world_cache_signature_file_written": True,
                "total_ms": 250.0,
            },
        },
        "stationary_runtime_idle_verdict": {
            "monitor_available_samples": 3,
            "idle_samples": 3,
            "busy_samples": 0,
            "idle_sample_ratio": 1.0,
            "max_pending_work": 0.0,
            "max_awake_process_count": 0.0,
        },
        "stationary_terrain_artifact_cache_verdict": {
            "monitor_available_samples": 3,
            "end_hit_ratio": 0.95,
            "disk_hit_delta": 3.0,
            "max_byte_budget_ratio": 0.5,
            "eviction_delta": 0.0,
            "disk_max_byte_budget_ratio": 0.4,
            "disk_eviction_delta": 0.0,
        },
        "system_telemetry": {
            "terrain_manager": {
                "rendered_terrain_chunk_count": 10,
                "rendered_water_chunk_count": 2,
                "active_chunk_count": 10,
                "pending_node_count": 0,
                "task_queue_count": 0,
                "cpu_task_queue_count": 0,
                "completed_generation_queue_count": 0,
                "render_distance": 3,
                "last_terrain_stream_update_gate_reason": "idle_same_chunk",
            },
            "vegetation_manager": {},
        },
    }


def _write_snapshot(root: Path) -> Path:
    path = root / "snapshot_raw_proof.json"
    path.write_text(json.dumps(_snapshot_payload()), encoding="utf-8")
    return path


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    proof_env = raw_runner._proof_gate_env_from_args(_args())
    _expect(proof_env["TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF"] == "1", "startup proof env should be enabled")
    _expect(proof_env["TOWN_STALL_MAX_STARTUP_ELAPSED_MS"] == "1500", "startup elapsed limit should propagate")
    _expect(proof_env["TOWN_STALL_REQUIRE_WORLD_BAKE_PROOF"] == "1", "world bake proof env should be enabled")
    _expect(proof_env["TOWN_STALL_REQUIRE_WORLD_BAKE_EXPORT_SIGNATURE"] == "1", "world bake export proof env should be enabled")
    _expect(proof_env["TOWN_STALL_REQUIRE_WORLD_BAKE_HEIGHT_BIOME_BACKEND"] == "native", "world bake backend should propagate")
    _expect(proof_env["TOWN_STALL_MAX_WORLD_BAKE_MS"] == "6000", "world bake generation limit should propagate")
    _expect(proof_env["TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF"] == "1", "runtime proof env should be enabled")
    _expect(proof_env["TOWN_STALL_MIN_RUNTIME_IDLE_RATIO"] == "1", "runtime idle ratio should propagate")
    _expect(proof_env["TOWN_STALL_REQUIRE_TERRAIN_ARTIFACT_CACHE_PROOF"] == "1", "cache proof env should be enabled")
    _expect(proof_env["TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_BYTE_BUDGET_RATIO"] == "0.8", "memory budget ratio should propagate")
    _expect(proof_env["TOWN_STALL_PREFLIGHT_IDLE_RETRY_TIMEOUT_SECONDS"] == "300", "child preflight retry timeout should propagate")
    _expect(proof_env["TOWN_STALL_PREFLIGHT_IDLE_RETRY_POLL_SECONDS"] == "15", "child preflight retry poll should propagate")

    original_collect_machine_state = raw_runner.town_runner._collect_machine_state
    original_run_idle_sample = raw_runner._run_idle_sample
    original_sleep = raw_runner.time.sleep
    attempt = {"count": 0}

    def fake_collect_machine_state() -> dict:
        attempt["count"] += 1
        return {
            "load_percentage": 1,
            "percent_processor_performance": 129 if attempt["count"] == 1 else 100,
            "percent_processor_utility": 1,
        }

    def fake_run_idle_sample(label: str, idle_seconds: float, sample_interval: float) -> dict:
        return {
            "label": label,
            "gpu": {
                "sample_count": 1,
                "avg_power_w": 5.0,
                "max_temp_c": 60.0,
                "p0_fraction": 0.0,
                "avg_gpu_util_pct": 0.0,
            },
        }

    try:
        raw_runner.town_runner._collect_machine_state = fake_collect_machine_state
        raw_runner._run_idle_sample = fake_run_idle_sample
        raw_runner.time.sleep = lambda _seconds: None
        preflight_idle = raw_runner._collect_initial_idle_until_clean(
            0.0,
            1.0,
            raw_runner._idle_contamination_thresholds(),
            5.0,
            1.0,
        )
        _expect(preflight_idle.get("clean") is True, "preflight idle retry should accept a later clean attempt")
        _expect(preflight_idle.get("attempt_count") == 2, "preflight idle retry should record contaminated and clean attempts")
        _expect(preflight_idle.get("attempts", [])[0].get("clean") is False, "first preflight attempt should remain recorded as contaminated")
    finally:
        raw_runner.town_runner._collect_machine_state = original_collect_machine_state
        raw_runner._run_idle_sample = original_run_idle_sample
        raw_runner.time.sleep = original_sleep

    previous = os.environ.get("TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF")
    try:
        os.environ["TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF"] = "1"
        env = raw_runner._build_case_env("runtime_default", 30.0, False, {})
        _expect("TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF" not in env, "ambient proof env should be reset without raw proof args")
        env = raw_runner._build_case_env("runtime_default", 30.0, False, proof_env)
        _expect(env["TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF"] == "1", "explicit proof env should reach child run")
        _expect(env["TOWN_STALL_PREFLIGHT_IDLE_RETRY_TIMEOUT_SECONDS"] == "300", "child run should receive preflight retry timeout")
        revisit_env = raw_runner._build_case_env("priority_revisit", 30.0, False, proof_env)
        _expect(revisit_env["TOWN_STALL_REPEAT_ENTRY"] == "1", "priority revisit case should enable repeat entry")
        _expect(revisit_env["TOWN_STALL_AUTO_TELEPORT"] == "0", "priority revisit case should use auto-fly phases")
        _expect(revisit_env["TOWN_STALL_ENABLE_RUNTIME_POWER_MODE"] == "1", "priority revisit case should keep runtime power mode")
        render_env = raw_runner._build_case_env("priority_render_distance_15", 30.0, False, proof_env)
        _expect(render_env["TOWN_STALL_RENDER_DISTANCE"] == "15", "render-distance case should set global render distance")
        _expect(render_env["TOWN_STALL_TERRAIN_RENDER_DISTANCE"] == "15", "render-distance case should set terrain distance")
        _expect(render_env["TOWN_STALL_BUILDING_RENDER_DISTANCE"] == "15", "render-distance case should set building distance")
        memory_env = raw_runner._build_case_env("priority_memory_pressure", 30.0, False, proof_env)
        _expect(memory_env["TOWN_STALL_TERRAIN_ARTIFACT_CACHE_MEMORY_BUDGET_MB"] == "64", "memory-pressure case should reduce memory budget")
        _expect(memory_env["TOWN_STALL_TERRAIN_ARTIFACT_CACHE_ENTRY_LIMIT"] == "128", "memory-pressure case should reduce memory entries")
        _expect(memory_env["TOWN_STALL_TERRAIN_ARTIFACT_DISK_CACHE_BUDGET_MB"] == "512", "memory-pressure case should reduce disk budget")
        _expect(memory_env["TOWN_STALL_TERRAIN_ARTIFACT_DISK_WRITE_QUEUE_MAX_ENTRIES"] == "64", "memory-pressure case should reduce disk queue entries")
    finally:
        if previous is None:
            os.environ.pop("TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF", None)
        else:
            os.environ["TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF"] = previous

    with tempfile.TemporaryDirectory() as temp_dir:
        summary = raw_runner._load_snapshot_summary(_write_snapshot(Path(temp_dir)))
        startup = summary.get("startup_readiness_verdict", {})
        bake = summary.get("world_bake_proof", {})
        idle = summary.get("stationary_runtime_idle_verdict", {})
        cache = summary.get("stationary_terrain_artifact_cache_verdict", {})
        _expect(float(startup.get("elapsed_ms", 0.0)) == 1000.0, "raw summary should preserve startup verdict")
        _expect(float(bake.get("generation_total_ms", 0.0)) == 5000.0, "raw summary should preserve bake generation proof")
        _expect(str(bake.get("height_biome_backend", "")) == "native", "raw summary should preserve bake backend proof")
        _expect(float(idle.get("idle_sample_ratio", 0.0)) == 1.0, "raw summary should preserve idle verdict")
        _expect(float(cache.get("max_byte_budget_ratio", 0.0)) == 0.5, "raw summary should preserve cache budget verdict")

        aggregate = raw_runner._aggregate_case_runs([
            {
                "case": "runtime_default",
                "snapshot": {
                    "content": {"content_valid_for_power_compare": True},
                    "startup_readiness_verdict": startup,
                    "world_bake_proof": bake,
                    "stationary_runtime_idle_verdict": idle,
                    "stationary_terrain_artifact_cache_verdict": cache,
                },
                "estimated_hold_gpu": {"avg_power_w": 10.0, "p0_fraction": 0.0},
                "last_20s_gpu": {"avg_power_w": 9.0},
                "moving_entry_gpu": {"avg_power_w": 12.0},
                "stationary_hold_gpu": {"avg_power_w": 8.0},
                "efficiency": {
                    "hold_wpf60": 10.0,
                    "moving_wpf60": 12.0,
                    "stationary_hold_wpf60": 8.0,
                },
            }
        ])
        case = aggregate.get("runtime_default", {})
        _expect(float(case.get("max_startup_elapsed_ms", 0.0)) == 1000.0, "aggregate should include startup elapsed proof")
        _expect(float(case.get("max_world_bake_generation_ms", 0.0)) == 5000.0, "aggregate should include bake generation proof")
        _expect(float(case.get("min_world_bake_layer_count", 0.0)) == 5.0, "aggregate should include bake layer proof")
        _expect(float(case.get("avg_runtime_idle_sample_ratio", 0.0)) == 1.0, "aggregate should include idle proof ratio")
        _expect(float(case.get("max_artifact_cache_byte_budget_ratio", 0.0)) == 0.5, "aggregate should include cache budget proof")

    print("[RUN_TOWN_STALL_RAW_BASELINE_PROOF_TEST] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
