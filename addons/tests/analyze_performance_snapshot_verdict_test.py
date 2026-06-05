import tempfile
from argparse import Namespace
from pathlib import Path

import analyze_performance_snapshots as analyzer


def _startup_system_telemetry() -> dict:
    stage_states = {}
    started = 1_000_000
    for index, stage_id in enumerate(analyzer.STARTUP_PROOF_STAGE_IDS):
        stage_started = started + index * 100_000
        stage_states[stage_id] = {
            "started": True,
            "completed": True,
            "progress": 1.0,
            "started_usec": stage_started,
            "completed_usec": stage_started + 80_000,
        }
    return {
        "loading_screen": {
            "is_loading": False,
            "stage": "complete",
            "stage_label": "World ready",
            "stage_progress_percent": 100.0,
            "stage_completed": 1,
            "stage_total": 1,
            "stage_detail_text": "World ready 100% (1/1)",
            "stage_details": {"message": "World ready!"},
            "progress_percent": 100.0,
            "failure_message": "",
            "cancellation_message": "",
            "elapsed_seconds": 1.0,
            "terrain_ready_emitted": True,
            "startup_coordinator": {
                "active": False,
                "failed": False,
                "cancelled": False,
                "playable_ready": True,
                "world_monitor_running": False,
                "world_monitor_completed": True,
                "overall_progress_percent": 100.0,
                "elapsed_ms": 1000.0,
                "current_stage_id": "complete",
                "current_stage_label": "World ready",
                "current_stage_progress_percent": 100.0,
                "current_stage_completed": 1,
                "current_stage_total": 1,
                "current_stage_details": {"message": "World ready!"},
                "stage_states": stage_states,
                "trace": {"event_count": 12},
            },
        }
    }


def _world_bake_proof(success: bool = True) -> dict:
    return {
        "available": True,
        "success": success,
        "world_seed": 4242,
        "map_size": 2048,
        "layout_mode": "town",
        "height_biome_backend": "native",
        "expected_baked_layer_count": 5,
        "baked_layer_count": 5 if success else 4,
        "missing_layers": [] if success else ["water"],
        "invalid_layers": [],
        "image_byte_count": 25_165_824,
        "image_pixel_count": 20_971_520,
        "image_signature": "image-sig",
        "metadata_signature": "metadata-sig",
        "content_signature": "content-sig",
        "image_hash_ms": 2.0,
        "metadata_hash_ms": 1.0,
        "total_hash_ms": 3.0,
        "generation_total_ms": 5000.0,
        "generation_stage_total_ms": 4950.0,
        "generation_unaccounted_ms": 50.0,
        "generation_profile": {
            "height_biome_backend": "native",
            "height_biome_ms": 1000.0,
            "layout_ms": 2500.0,
            "lakes_ms": 800.0,
            "finalize_ms": 650.0,
            "total_ms": 5000.0,
        },
        "save_profile": {
            "success": success,
            "cache_signature": "export-sig" if success else "",
            "world_cache_signature_file_written": success,
            "total_ms": 250.0,
            "png_write_ms": 225.0,
            "meta_write_ms": 5.0,
            "world_meta_schema_version": 7,
            "world_cache_version": 1,
        },
    }


def _snapshot_payload(top_level_verdicts: bool = True) -> dict:
    stationary_hold_window = {
        "sample_count": 2,
        "avg_total_ms": 12.0,
        "max_total_ms": 15.0,
        "frames_over_budget": 0,
        "render_active_sample_count": 2,
        "world_runtime_monitor_available_samples": 2,
        "world_runtime_idle_samples": 2,
        "world_runtime_busy_samples": 0,
        "world_runtime_idle_sample_ratio": 1.0,
        "world_runtime_all_idle": True,
        "max_world_runtime_pending_work": 0.0,
        "max_world_runtime_awake_process_count": 0.0,
        "avg_terrain_artifact_cache_hit_ratio": 0.8,
        "end_terrain_artifact_cache_hit_ratio": 0.9,
        "max_terrain_artifact_cache_entries": 7.0,
        "end_terrain_artifact_cache_entries": 6.0,
        "max_terrain_artifact_cache_bytes": 8192.0,
        "end_terrain_artifact_cache_bytes": 4096.0,
        "max_terrain_artifact_cache_byte_budget_ratio": 0.5,
        "end_terrain_artifact_cache_byte_budget_ratio": 0.25,
        "terrain_artifact_cache_eviction_delta": 1.0,
        "max_terrain_artifact_disk_cache_bytes": 16384.0,
        "end_terrain_artifact_disk_cache_bytes": 12288.0,
        "max_terrain_artifact_disk_cache_byte_budget_ratio": 0.4,
        "end_terrain_artifact_disk_cache_byte_budget_ratio": 0.3,
        "terrain_artifact_cache_disk_hit_delta": 3.0,
        "terrain_artifact_disk_cache_eviction_delta": 2.0,
    }
    payload = {
        "runtime_mode": "production",
        "benchmark_hold_complete": True,
        "benchmark_hold_seconds": 30.0,
        "stationary_hold_window": stationary_hold_window,
        "moving_entry_window": {},
        "town_entry_window": stationary_hold_window,
        "render_features": {
            "vulkan_only_expected": True,
            "rendering_method": "forward_plus",
            "rendering_driver_name": "vulkan",
        },
        "system_telemetry": {
            "terrain_manager": {
                "render_distance": 5,
            },
            "world_generator": {
                "last_bake_proof": _world_bake_proof(),
            },
            **_startup_system_telemetry(),
        },
    }
    if top_level_verdicts:
        payload["world_bake_proof"] = _world_bake_proof()
        payload["startup_readiness_verdict"] = {
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
            "completed_stage_count": 5,
            "incomplete_stage_count": 0,
            "missing_stage_count": 0,
            "max_stage_duration_ms": 80.0,
            "trace_event_count": 12,
            "stage": "complete",
            "current_stage_id": "complete",
            "current_stage_label": "World ready",
            "current_stage_progress_percent": 100.0,
            "current_stage_completed": 1,
            "current_stage_total": 1,
            "stage_detail_text": "World ready 100% (1/1)",
            "current_stage_details": {"message": "World ready!"},
        }
        payload["stationary_runtime_idle_verdict"] = {
            "monitor_available_samples": 2,
            "idle_samples": 2,
            "busy_samples": 0,
            "idle_sample_ratio": 1.0,
            "all_idle": True,
            "max_pending_work": 0.0,
            "max_awake_process_count": 0.0,
        }
        payload["stationary_terrain_artifact_cache_verdict"] = {
            "monitor_available_samples": 2,
            "avg_hit_ratio": 0.8,
            "end_hit_ratio": 0.9,
            "max_entries": 7.0,
            "end_entries": 6.0,
            "max_bytes": 8192.0,
            "end_bytes": 4096.0,
            "max_byte_budget_ratio": 0.5,
            "end_byte_budget_ratio": 0.25,
            "eviction_delta": 1.0,
            "disk_hit_delta": 3.0,
            "disk_max_bytes": 16384.0,
            "disk_end_bytes": 12288.0,
            "disk_max_byte_budget_ratio": 0.4,
            "disk_end_byte_budget_ratio": 0.3,
            "disk_eviction_delta": 2.0,
        }
    return payload


def _write_snapshot(root: Path, payload: dict) -> Path:
    path = root / "snapshot_test.json"
    path.write_text(analyzer.json.dumps(payload), encoding="utf-8")
    return path


def _gate_args(**overrides) -> Namespace:
    values = {
        "require_latest_production_startup_readiness": True,
        "min_latest_production_startup_completed_stages": len(analyzer.STARTUP_PROOF_STAGE_IDS),
        "max_latest_production_startup_elapsed_ms": 1500.0,
        "max_latest_production_startup_stage_ms": 100.0,
        "min_latest_production_startup_trace_events": 8.0,
        "require_latest_production_world_bake_proof": True,
        "require_latest_production_world_bake_export_signature": True,
        "require_latest_production_world_bake_height_biome_backend": "native",
        "min_latest_production_world_bake_layers": 5,
        "max_latest_production_world_bake_ms": 6000.0,
        "max_latest_production_world_bake_hash_ms": 5.0,
        "max_latest_production_world_bake_unaccounted_ms": 100.0,
        "require_latest_production_runtime_idle": True,
        "min_latest_production_runtime_idle_samples": 1,
        "min_latest_production_runtime_idle_ratio": None,
        "max_latest_production_runtime_pending_work": None,
        "max_latest_production_runtime_awake_process_count": None,
        "require_latest_production_terrain_artifact_cache_samples": True,
        "min_latest_production_terrain_artifact_cache_samples": 1,
        "min_latest_production_terrain_artifact_cache_hit_ratio": 0.75,
        "min_latest_production_terrain_artifact_cache_disk_hit_delta": 2.0,
        "max_latest_production_terrain_artifact_cache_byte_budget_ratio": 0.6,
        "max_latest_production_terrain_artifact_cache_eviction_delta": 1.0,
        "max_latest_production_terrain_artifact_disk_cache_byte_budget_ratio": 0.5,
        "max_latest_production_terrain_artifact_disk_cache_eviction_delta": 2.0,
    }
    values.update(overrides)
    return Namespace(**values)


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    with tempfile.TemporaryDirectory() as temp_dir:
        snapshot_path = _write_snapshot(Path(temp_dir), _snapshot_payload())
        summary = analyzer._summarize_town_snapshot(snapshot_path, 1000.0 / 60.0)

        startup = analyzer._dict(summary.get("startup_readiness_verdict"))
        bake = analyzer._dict(summary.get("world_bake_proof"))
        idle = analyzer._dict(summary.get("stationary_runtime_idle_verdict"))
        cache = analyzer._dict(summary.get("stationary_terrain_artifact_cache_verdict"))
        _expect(startup.get("available") is True, "startup verdict should be available")
        _expect(startup.get("completed") is True, "startup verdict should be complete")
        _expect(analyzer._int(startup.get("completed_stage_count")) == 5, "startup completed stage count should be summarized")
        _expect(str(startup.get("current_stage_label")) == "World ready", "startup current stage label should be summarized")
        _expect(analyzer._float(startup.get("current_stage_progress_percent")) == 100.0, "startup current stage progress should be summarized")
        _expect(analyzer._int(startup.get("current_stage_completed")) == 1, "startup current stage completed count should be summarized")
        _expect(str(analyzer._dict(startup.get("current_stage_details")).get("message")) == "World ready!", "startup current stage details should be preserved")
        _expect(bake.get("available") is True, "world bake proof should be available")
        _expect(bake.get("success") is True, "world bake proof should be successful")
        _expect(bake.get("save_success") is True, "world bake save proof should be successful")
        _expect(analyzer._int(bake.get("baked_layer_count")) == 5, "world bake layer count should be summarized")
        _expect(str(bake.get("height_biome_backend")) == "native", "world bake backend should be summarized")
        _expect(str(bake.get("export_cache_signature")) == "export-sig", "world bake export signature should be summarized")
        _expect(idle.get("available") is True, "runtime idle verdict should be available")
        _expect(analyzer._int(idle.get("monitor_available_samples")) == 2, "runtime idle sample count should be summarized")
        _expect(analyzer._float(idle.get("idle_sample_ratio")) == 1.0, "runtime idle ratio should be summarized")
        _expect(cache.get("available") is True, "artifact cache verdict should be available")
        _expect(analyzer._float(cache.get("end_hit_ratio")) == 0.9, "artifact cache ending hit ratio should be summarized")
        _expect(analyzer._float(cache.get("disk_hit_delta")) == 3.0, "artifact cache disk-hit delta should be summarized")
        _expect(analyzer._float(cache.get("max_byte_budget_ratio")) == 0.5, "artifact cache max memory ratio should be summarized")
        _expect(analyzer._float(cache.get("disk_max_byte_budget_ratio")) == 0.4, "artifact cache max disk ratio should be summarized")

        report = {"latest_production_town": summary}
        startup_gate = analyzer._startup_readiness_gate(report, _gate_args())
        _expect(startup_gate.get("passed") is True, "startup readiness gate should pass clean verdict")
        bake_gate = analyzer._world_bake_proof_gate(report, _gate_args())
        _expect(bake_gate.get("passed") is True, "world bake proof gate should pass clean verdict")
        idle_gate = analyzer._stationary_runtime_idle_gate(report, _gate_args())
        _expect(idle_gate.get("passed") is True, "runtime idle gate should pass clean verdict")
        cache_gate = analyzer._terrain_artifact_cache_gate(report, _gate_args())
        _expect(cache_gate.get("passed") is True, "artifact cache gate should pass clean verdict")

        failing_report = {"latest_production_town": dict(summary)}
        failing_report["latest_production_town"]["startup_readiness_verdict"] = {
            "available": True,
            "completed": False,
            "startup_coordinator_available": True,
            "loading_active": True,
            "failed": False,
            "cancelled": False,
            "playable_ready": False,
            "completed_stage_count": 2,
            "incomplete_stage_count": 3,
            "missing_stage_count": 1,
            "elapsed_ms": 3000.0,
            "max_stage_duration_ms": 800.0,
            "trace_event_count": 2,
            "current_stage_id": "world_content",
            "current_stage_label": "Preparing world content",
            "current_stage_progress_percent": 40.0,
            "current_stage_completed": 4,
            "current_stage_total": 10,
            "stage_detail_text": "Preparing world content 40% (4/10) | blocked by entity_manager (6 pending)",
            "current_stage_details": {
                "message": "Preparing entities: 6 startup pending",
                "blocking_component": "entity_manager",
                "blocking_component_pending": 6,
            },
        }
        failing_startup_gate = analyzer._startup_readiness_gate(failing_report, _gate_args())
        _expect(failing_startup_gate.get("passed") is False, "startup readiness gate should fail incomplete verdict")
        failing_startup_text = "\n".join(str(item) for item in failing_startup_gate.get("failures", []))
        _expect("startup active stage" in failing_startup_text, "startup readiness failure should include active stage context")
        _expect("blocked by entity_manager" in failing_startup_text, "startup readiness failure should include blocking detail")
        failing_observed = analyzer._dict(failing_startup_gate.get("observed"))
        _expect(str(failing_observed.get("current_stage_id")) == "world_content", "startup gate observed stage id should be preserved")
        _expect(
            str(analyzer._dict(failing_observed.get("current_stage_details")).get("blocking_component")) == "entity_manager",
            "startup gate observed stage details should be preserved",
        )

        failing_bake_report = {"latest_production_town": dict(summary)}
        failing_bake_report["latest_production_town"]["world_bake_proof"] = _world_bake_proof(False)
        failing_bake_gate = analyzer._world_bake_proof_gate(failing_bake_report, _gate_args())
        _expect(failing_bake_gate.get("passed") is False, "world bake proof gate should fail incomplete export proof")

        failing_report = {"latest_production_town": dict(summary)}
        failing_report["latest_production_town"]["stationary_runtime_idle_verdict"] = {
            "monitor_available_samples": 2,
            "idle_sample_ratio": 0.5,
            "max_pending_work": 4.0,
            "max_awake_process_count": 1.0,
        }
        failing_idle_gate = analyzer._stationary_runtime_idle_gate(failing_report, _gate_args())
        _expect(failing_idle_gate.get("passed") is False, "runtime idle gate should fail busy verdict")

        failing_cache_report = {"latest_production_town": dict(summary)}
        failing_cache_report["latest_production_town"]["stationary_terrain_artifact_cache_verdict"] = {
            "monitor_available_samples": 2,
            "end_hit_ratio": 0.9,
            "disk_hit_delta": 3.0,
            "max_byte_budget_ratio": 0.9,
            "eviction_delta": 4.0,
            "disk_max_byte_budget_ratio": 0.8,
            "disk_eviction_delta": 6.0,
        }
        failing_cache_gate = analyzer._terrain_artifact_cache_gate(failing_cache_report, _gate_args())
        _expect(failing_cache_gate.get("passed") is False, "artifact cache gate should fail memory-pressure verdict")

        fallback_path = _write_snapshot(Path(temp_dir), _snapshot_payload(False))
        fallback_summary = analyzer._summarize_town_snapshot(fallback_path, 1000.0 / 60.0)
        fallback_startup = analyzer._dict(fallback_summary.get("startup_readiness_verdict"))
        fallback_bake = analyzer._dict(fallback_summary.get("world_bake_proof"))
        fallback_idle = analyzer._dict(fallback_summary.get("stationary_runtime_idle_verdict"))
        fallback_cache = analyzer._dict(fallback_summary.get("stationary_terrain_artifact_cache_verdict"))
        _expect(analyzer._int(fallback_startup.get("completed_stage_count")) == 5, "startup fallback should use coordinator stage fields")
        _expect(str(fallback_startup.get("current_stage_label")) == "World ready", "startup fallback should preserve current stage label")
        _expect(str(fallback_startup.get("stage_detail_text")) == "World ready 100% (1/1)", "startup fallback should preserve stage detail text")
        _expect(str(fallback_bake.get("content_signature")) == "content-sig", "world bake fallback should use generator telemetry fields")
        _expect(analyzer._int(fallback_idle.get("monitor_available_samples")) == 2, "runtime idle fallback should use window fields")
        _expect(analyzer._float(fallback_cache.get("end_hit_ratio")) == 0.9, "artifact cache fallback should use window fields")
        _expect(analyzer._float(fallback_cache.get("eviction_delta")) == 1.0, "artifact cache eviction fallback should use window fields")

    print("[ANALYZE_PERFORMANCE_SNAPSHOT_VERDICT_TEST] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
