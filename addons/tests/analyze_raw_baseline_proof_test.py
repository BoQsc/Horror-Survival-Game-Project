import tempfile
from argparse import Namespace
from pathlib import Path

import analyze_performance_snapshots as analyzer


def _raw_payload(
    proof_gate_env: bool = True,
    idle_ratio: float = 1.0,
    cache_hit_ratio: float = 0.95,
    startup_elapsed_ms: float = 1000.0,
    bake_generation_ms: float = 5000.0,
) -> dict:
    payload = {
        "cases": ["runtime_default"],
        "hold_seconds": 30.0,
        "sample_interval_seconds": 1.0,
        "initial_idle": {"gpu": {"sample_count": 2, "avg_power_w": 8.0}},
        "final_idle": {"gpu": {"sample_count": 2, "avg_power_w": 8.0}},
        "runs": [
            {
                "case": "runtime_default",
                "repeat_index": 1,
                "returncode": 0,
                "failure_reasons": [],
                "duration_s": 40.0,
                "estimated_hold_gpu": {"sample_count": 3, "avg_power_w": 10.0, "avg_temp_c": 50.0, "max_temp_c": 52.0},
                "stationary_hold_gpu": {"sample_count": 3, "avg_power_w": 9.0, "avg_temp_c": 49.0, "max_temp_c": 51.0},
                "snapshot": {
                    "content": {"content_valid_for_power_compare": True},
                    "town_metrics": {"average_fps": 60.0},
                    "startup_readiness_verdict": {
                        "available": True,
                        "completed": True,
                        "startup_coordinator_available": True,
                        "loading_active": False,
                        "failed": False,
                        "cancelled": False,
                        "playable_ready": True,
                        "completed_stage_count": len(analyzer.STARTUP_PROOF_STAGE_IDS),
                        "incomplete_stage_count": 0,
                        "missing_stage_count": 0,
                        "elapsed_ms": startup_elapsed_ms,
                        "max_stage_duration_ms": 80.0,
                        "trace_event_count": 12,
                    },
                    "world_bake_proof": {
                        "available": True,
                        "success": True,
                        "save_success": True,
                        "height_biome_backend": "native",
                        "baked_layer_count": 5,
                        "expected_baked_layer_count": 5,
                        "missing_layer_count": 0,
                        "invalid_layer_count": 0,
                        "content_signature": "content-sig",
                        "export_cache_signature": "export-sig",
                        "export_signature_file_written": True,
                        "generation_total_ms": bake_generation_ms,
                        "total_hash_ms": 3.0,
                        "generation_unaccounted_ms": 50.0,
                        "save_total_ms": 250.0,
                    },
                    "stationary_runtime_idle_verdict": {
                        "monitor_available_samples": 3,
                        "idle_samples": 3 if idle_ratio >= 1.0 else 1,
                        "busy_samples": 0 if idle_ratio >= 1.0 else 2,
                        "idle_sample_ratio": idle_ratio,
                        "max_pending_work": 0.0 if idle_ratio >= 1.0 else 3.0,
                        "max_awake_process_count": 0.0 if idle_ratio >= 1.0 else 1.0,
                    },
                    "stationary_terrain_artifact_cache_verdict": {
                        "monitor_available_samples": 3,
                        "end_hit_ratio": cache_hit_ratio,
                        "disk_hit_delta": 2.0,
                        "max_byte_budget_ratio": 0.5,
                        "eviction_delta": 0.0,
                    },
                },
            }
        ],
    }
    if proof_gate_env:
        payload["proof_gate_env"] = {
            "TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF": "1",
            "TOWN_STALL_REQUIRE_WORLD_BAKE_PROOF": "1",
            "TOWN_STALL_REQUIRE_WORLD_BAKE_EXPORT_SIGNATURE": "1",
            "TOWN_STALL_REQUIRE_WORLD_BAKE_HEIGHT_BIOME_BACKEND": "native",
            "TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF": "1",
            "TOWN_STALL_REQUIRE_TERRAIN_ARTIFACT_CACHE_PROOF": "1",
        }
    return payload


def _write_payload(root: Path, payload: dict) -> Path:
    path = root / "town_stall_raw_baseline_test.json"
    path.write_text(analyzer.json.dumps(payload), encoding="utf-8")
    return path


def _gate_args(**overrides) -> Namespace:
    values = {
        "require_latest_raw_baseline_startup_readiness_proof": True,
        "max_latest_raw_baseline_startup_elapsed_ms": 1500.0,
        "max_latest_raw_baseline_startup_stage_ms": 100.0,
        "require_latest_raw_baseline_world_bake_proof": True,
        "require_latest_raw_baseline_world_bake_export_signature": True,
        "require_latest_raw_baseline_world_bake_height_biome_backend": "native",
        "min_latest_raw_baseline_world_bake_layers": 5,
        "max_latest_raw_baseline_world_bake_ms": 6000.0,
        "max_latest_raw_baseline_world_bake_hash_ms": 5.0,
        "max_latest_raw_baseline_world_bake_unaccounted_ms": 100.0,
        "require_latest_raw_baseline_runtime_idle_proof": True,
        "min_latest_raw_baseline_runtime_idle_ratio": 1.0,
        "max_latest_raw_baseline_runtime_busy_samples": 0.0,
        "require_latest_raw_baseline_terrain_artifact_cache_proof": True,
        "min_latest_raw_baseline_terrain_artifact_cache_hit_ratio": 0.9,
        "max_latest_raw_baseline_terrain_artifact_cache_byte_budget_ratio": 0.8,
        "max_latest_raw_baseline_terrain_artifact_cache_eviction_delta": 0.0,
    }
    values.update(overrides)
    return Namespace(**values)


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        summary = analyzer._summarize_gpu_telemetry(_write_payload(root, _raw_payload()))
        run = analyzer._dict(analyzer._list(summary.get("runs"))[0])
        startup = analyzer._dict(run.get("startup_readiness_verdict"))
        bake = analyzer._dict(run.get("world_bake_proof"))
        idle = analyzer._dict(run.get("stationary_runtime_idle_verdict"))
        cache = analyzer._dict(run.get("stationary_terrain_artifact_cache_verdict"))
        _expect(analyzer._float(startup.get("elapsed_ms")) == 1000.0, "raw summary should preserve startup verdict")
        _expect(analyzer._float(bake.get("generation_total_ms")) == 5000.0, "raw summary should preserve world bake proof")
        _expect(str(bake.get("height_biome_backend")) == "native", "raw summary should preserve world bake backend")
        _expect(analyzer._float(idle.get("idle_sample_ratio")) == 1.0, "raw summary should preserve runtime idle verdict")
        _expect(analyzer._float(cache.get("end_hit_ratio")) == 0.95, "raw summary should preserve artifact cache verdict")
        report = {"latest_gpu_telemetry": summary}
        gate = analyzer._raw_baseline_proof_gate(report, _gate_args())
        _expect(gate.get("passed") is True, "raw proof gate should pass clean payload")

        missing_env = analyzer._summarize_gpu_telemetry(_write_payload(root, _raw_payload(False)))
        missing_env_gate = analyzer._raw_baseline_proof_gate({"latest_gpu_telemetry": missing_env}, _gate_args())
        _expect(missing_env_gate.get("passed") is False, "raw proof gate should require proof env when requested")

        failing = analyzer._summarize_gpu_telemetry(_write_payload(root, _raw_payload(True, 0.5, 0.6)))
        failing_gate = analyzer._raw_baseline_proof_gate({"latest_gpu_telemetry": failing}, _gate_args())
        failure_text = "\n".join(str(item) for item in analyzer._list(failing_gate.get("failures")))
        _expect("runtime idle ratio" in failure_text, "raw proof gate should fail low idle ratio")
        _expect("artifact cache hit ratio" in failure_text, "raw proof gate should fail low cache hit ratio")

        slow_startup = analyzer._summarize_gpu_telemetry(_write_payload(root, _raw_payload(True, 1.0, 0.95, 3000.0)))
        slow_startup_gate = analyzer._raw_baseline_proof_gate({"latest_gpu_telemetry": slow_startup}, _gate_args())
        slow_text = "\n".join(str(item) for item in analyzer._list(slow_startup_gate.get("failures")))
        _expect("startup elapsed" in slow_text, "raw proof gate should fail slow startup")

        slow_bake = analyzer._summarize_gpu_telemetry(_write_payload(root, _raw_payload(True, 1.0, 0.95, 1000.0, 8000.0)))
        slow_bake_gate = analyzer._raw_baseline_proof_gate({"latest_gpu_telemetry": slow_bake}, _gate_args())
        slow_bake_text = "\n".join(str(item) for item in analyzer._list(slow_bake_gate.get("failures")))
        _expect("world bake generation" in slow_bake_text, "raw proof gate should fail slow world bake")

    print("[ANALYZE_RAW_BASELINE_PROOF_TEST] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
