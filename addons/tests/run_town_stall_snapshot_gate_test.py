import json
import os
import tempfile
from pathlib import Path

import run_town_stall_test as runner


GATE_ENV_KEYS = [
    "TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF",
    "TOWN_STALL_MIN_STARTUP_COMPLETED_STAGES",
    "TOWN_STALL_MAX_STARTUP_ELAPSED_MS",
    "TOWN_STALL_MAX_STARTUP_STAGE_MS",
    "TOWN_STALL_MIN_STARTUP_TRACE_EVENTS",
    "TOWN_STALL_REQUIRE_WORLD_BAKE_PROOF",
    "TOWN_STALL_REQUIRE_WORLD_BAKE_EXPORT_SIGNATURE",
    "TOWN_STALL_REQUIRE_WORLD_BAKE_HEIGHT_BIOME_BACKEND",
    "TOWN_STALL_MIN_WORLD_BAKE_LAYERS",
    "TOWN_STALL_MAX_WORLD_BAKE_MS",
    "TOWN_STALL_MAX_WORLD_BAKE_HASH_MS",
    "TOWN_STALL_MAX_WORLD_BAKE_UNACCOUNTED_MS",
    "TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF",
    "TOWN_STALL_MIN_RUNTIME_IDLE_PROOF_SAMPLES",
    "TOWN_STALL_MIN_RUNTIME_IDLE_RATIO",
    "TOWN_STALL_MAX_RUNTIME_PENDING_WORK",
    "TOWN_STALL_MAX_RUNTIME_AWAKE_PROCESS_COUNT",
    "TOWN_STALL_REQUIRE_TERRAIN_ARTIFACT_CACHE_PROOF",
    "TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_PROOF_SAMPLES",
    "TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_HIT_RATIO",
    "TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_DISK_HIT_DELTA",
    "TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_BYTE_BUDGET_RATIO",
    "TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_EVICTION_DELTA",
    "TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_BYTE_BUDGET_RATIO",
    "TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_EVICTION_DELTA",
]


def _startup_system_telemetry() -> dict:
    stage_states = {}
    started = 1_000_000
    for index, stage_id in enumerate(runner.STARTUP_PROOF_STAGE_IDS):
        stage_started = started + index * 100_000
        stage_states[stage_id] = {
            "started": True,
            "completed": True,
            "progress": 1.0,
            "started_usec": stage_started,
            "completed_usec": stage_started + 90_000,
        }
    return {
        "loading_screen": {
            "is_loading": False,
            "stage": "complete",
            "progress_percent": 100.0,
            "message": "World ready!",
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
                "stage_states": stage_states,
                "trace": {"event_count": 12},
            },
        }
    }


def _world_bake_proof(success: bool = True) -> dict:
    return {
        "available": True,
        "success": success,
        "height_biome_backend": "native",
        "expected_baked_layer_count": 5,
        "baked_layer_count": 5 if success else 4,
        "missing_layers": [] if success else ["water"],
        "invalid_layers": [],
        "content_signature": "content-sig" if success else "",
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
            "success": success,
            "cache_signature": "export-sig" if success else "",
            "world_cache_signature_file_written": success,
            "total_ms": 250.0,
        },
    }


def _snapshot_payload(top_level_verdicts: bool = True) -> dict:
    stationary_hold_window = {
        "world_runtime_monitor_available_samples": 3,
        "world_runtime_idle_samples": 3,
        "world_runtime_busy_samples": 0,
        "world_runtime_idle_sample_ratio": 1.0,
        "max_world_runtime_pending_work": 0.0,
        "max_world_runtime_awake_process_count": 0.0,
        "avg_terrain_artifact_cache_hit_ratio": 0.86,
        "end_terrain_artifact_cache_hit_ratio": 0.95,
        "max_terrain_artifact_cache_entries": 12.0,
        "end_terrain_artifact_cache_entries": 11.0,
        "max_terrain_artifact_cache_bytes": 8192.0,
        "end_terrain_artifact_cache_bytes": 4096.0,
        "max_terrain_artifact_cache_byte_budget_ratio": 0.5,
        "end_terrain_artifact_cache_byte_budget_ratio": 0.25,
        "terrain_artifact_cache_eviction_delta": 1.0,
        "max_terrain_artifact_disk_cache_bytes": 16384.0,
        "end_terrain_artifact_disk_cache_bytes": 12288.0,
        "max_terrain_artifact_disk_cache_byte_budget_ratio": 0.4,
        "end_terrain_artifact_disk_cache_byte_budget_ratio": 0.3,
        "terrain_artifact_cache_disk_hit_delta": 4.0,
        "terrain_artifact_disk_cache_eviction_delta": 2.0,
    }
    payload = {
        "stationary_hold_window": stationary_hold_window,
        "system_telemetry": {
            **_startup_system_telemetry(),
            "world_generator": {
                "last_bake_proof": _world_bake_proof(),
            },
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
            "max_stage_duration_ms": 90.0,
            "trace_event_count": 12,
        }
        payload["stationary_runtime_idle_verdict"] = {
            "monitor_available_samples": 3,
            "idle_samples": 3,
            "busy_samples": 0,
            "idle_sample_ratio": 1.0,
            "max_pending_work": 0.0,
            "max_awake_process_count": 0.0,
        }
        payload["stationary_terrain_artifact_cache_verdict"] = {
            "monitor_available_samples": 3,
            "avg_hit_ratio": 0.86,
            "end_hit_ratio": 0.95,
            "max_entries": 12.0,
            "end_entries": 11.0,
            "max_bytes": 8192.0,
            "end_bytes": 4096.0,
            "max_byte_budget_ratio": 0.5,
            "end_byte_budget_ratio": 0.25,
            "eviction_delta": 1.0,
            "disk_hit_delta": 4.0,
            "disk_max_bytes": 16384.0,
            "disk_end_bytes": 12288.0,
            "disk_max_byte_budget_ratio": 0.4,
            "disk_end_byte_budget_ratio": 0.3,
            "disk_eviction_delta": 2.0,
        }
    return payload


def _write_snapshot(root: Path, payload: dict) -> Path:
    path = root / "snapshot_test.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def _with_gate_env(values: dict[str, str], callback) -> None:
    previous = {key: os.environ.get(key) for key in GATE_ENV_KEYS}
    try:
        for key in GATE_ENV_KEYS:
            os.environ.pop(key, None)
        for key, value in values.items():
            os.environ[key] = value
        callback()
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        clean_snapshot = _write_snapshot(root, _snapshot_payload())

        def expect_no_requested_gates_are_inert() -> None:
            _expect(
                runner._snapshot_proof_gate_failures(clean_snapshot) == [],
                "proof gate helper should be inert without gate env",
            )

        _with_gate_env({}, expect_no_requested_gates_are_inert)

        def expect_clean_snapshot_passes() -> None:
            failures = runner._snapshot_proof_gate_failures(clean_snapshot)
            _expect(failures == [], f"clean proof snapshot should pass, got {failures}")

        _with_gate_env(
            {
                "TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF": "1",
                "TOWN_STALL_MAX_STARTUP_ELAPSED_MS": "1500",
                "TOWN_STALL_MAX_STARTUP_STAGE_MS": "100",
                "TOWN_STALL_MIN_STARTUP_TRACE_EVENTS": "8",
                "TOWN_STALL_REQUIRE_WORLD_BAKE_PROOF": "1",
                "TOWN_STALL_REQUIRE_WORLD_BAKE_EXPORT_SIGNATURE": "1",
                "TOWN_STALL_REQUIRE_WORLD_BAKE_HEIGHT_BIOME_BACKEND": "native",
                "TOWN_STALL_MAX_WORLD_BAKE_MS": "6000",
                "TOWN_STALL_MAX_WORLD_BAKE_HASH_MS": "5",
                "TOWN_STALL_MAX_WORLD_BAKE_UNACCOUNTED_MS": "100",
                "TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF": "1",
                "TOWN_STALL_REQUIRE_TERRAIN_ARTIFACT_CACHE_PROOF": "1",
                "TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_HIT_RATIO": "0.9",
                "TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_DISK_HIT_DELTA": "2",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_BYTE_BUDGET_RATIO": "0.6",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_EVICTION_DELTA": "1",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_BYTE_BUDGET_RATIO": "0.5",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_EVICTION_DELTA": "2",
            },
            expect_clean_snapshot_passes,
        )

        startup_busy_payload = _snapshot_payload()
        startup_busy_payload["startup_readiness_verdict"] = {
            "available": True,
            "completed": False,
            "loading_screen_available": True,
            "startup_coordinator_available": True,
            "loading_active": True,
            "failed": False,
            "cancelled": False,
            "playable_ready": False,
            "world_monitor_completed": False,
            "progress_percent": 70.0,
            "elapsed_ms": 3000.0,
            "completed_stage_count": 2,
            "incomplete_stage_count": 3,
            "missing_stage_count": 1,
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
        startup_busy_snapshot = _write_snapshot(root, startup_busy_payload)

        def expect_startup_busy_snapshot_fails() -> None:
            failures = runner._snapshot_proof_gate_failures(startup_busy_snapshot)
            text = "\n".join(failures)
            _expect("startup readiness did not complete" in text, "busy startup should fail completion proof")
            _expect("startup loading still active" in text, "busy startup should fail active-loading proof")
            _expect("startup completed stages" in text, "busy startup should fail completed-stage proof")
            _expect("startup elapsed" in text, "busy startup should fail elapsed proof")
            _expect("startup trace events" in text, "busy startup should fail trace proof")
            _expect("startup active stage" in text, "busy startup should report active stage context")
            _expect("blocked by entity_manager" in text, "busy startup should report blocking detail")

        _with_gate_env(
            {
                "TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF": "1",
                "TOWN_STALL_MAX_STARTUP_ELAPSED_MS": "1500",
                "TOWN_STALL_MAX_STARTUP_STAGE_MS": "100",
                "TOWN_STALL_MIN_STARTUP_TRACE_EVENTS": "8",
            },
            expect_startup_busy_snapshot_fails,
        )

        bake_bad_payload = _snapshot_payload()
        bake_bad_payload["world_bake_proof"] = _world_bake_proof(False)
        bake_bad_snapshot = _write_snapshot(root, bake_bad_payload)

        def expect_bad_bake_snapshot_fails() -> None:
            failures = runner._snapshot_proof_gate_failures(bake_bad_snapshot)
            text = "\n".join(failures)
            _expect("world bake proof did not succeed" in text, "bad bake should fail success proof")
            _expect("world bake layer count" in text, "bad bake should fail layer-count proof")
            _expect("world bake content signature missing" in text, "bad bake should fail content-signature proof")
            _expect("world bake export cache signature missing" in text, "bad bake should fail export-signature proof")

        _with_gate_env(
            {
                "TOWN_STALL_REQUIRE_WORLD_BAKE_PROOF": "1",
                "TOWN_STALL_REQUIRE_WORLD_BAKE_EXPORT_SIGNATURE": "1",
                "TOWN_STALL_REQUIRE_WORLD_BAKE_HEIGHT_BIOME_BACKEND": "native",
                "TOWN_STALL_MAX_WORLD_BAKE_MS": "6000",
                "TOWN_STALL_MAX_WORLD_BAKE_HASH_MS": "5",
                "TOWN_STALL_MAX_WORLD_BAKE_UNACCOUNTED_MS": "100",
            },
            expect_bad_bake_snapshot_fails,
        )

        busy_payload = _snapshot_payload()
        busy_payload["stationary_runtime_idle_verdict"] = {
            "monitor_available_samples": 3,
            "idle_samples": 1,
            "busy_samples": 2,
            "idle_sample_ratio": 0.333,
            "max_pending_work": 5.0,
            "max_awake_process_count": 2.0,
        }
        busy_snapshot = _write_snapshot(root, busy_payload)

        def expect_busy_snapshot_fails() -> None:
            failures = runner._snapshot_proof_gate_failures(busy_snapshot)
            text = "\n".join(failures)
            _expect("runtime idle sample ratio" in text, "busy runtime should fail idle-ratio proof")
            _expect("runtime max pending work" in text, "busy runtime should fail pending-work proof")
            _expect("runtime max awake process count" in text, "busy runtime should fail awake-process proof")

        _with_gate_env({"TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF": "1"}, expect_busy_snapshot_fails)

        cold_cache_payload = _snapshot_payload()
        cold_cache_payload["stationary_terrain_artifact_cache_verdict"] = {
            "monitor_available_samples": 3,
            "avg_hit_ratio": 0.2,
            "end_hit_ratio": 0.4,
            "max_entries": 2.0,
            "end_entries": 1.0,
            "max_byte_budget_ratio": 0.9,
            "eviction_delta": 5.0,
            "disk_hit_delta": 0.0,
            "disk_max_byte_budget_ratio": 0.8,
            "disk_eviction_delta": 6.0,
        }
        cold_cache_snapshot = _write_snapshot(root, cold_cache_payload)

        def expect_cold_cache_snapshot_fails() -> None:
            failures = runner._snapshot_proof_gate_failures(cold_cache_snapshot)
            text = "\n".join(failures)
            _expect("terrain artifact cache ending hit ratio" in text, "cold cache should fail hit-ratio proof")
            _expect("terrain artifact cache disk-hit delta" in text, "cold cache should fail disk-hit proof")
            _expect("terrain artifact memory cache max byte-budget ratio" in text, "cold cache should fail memory budget proof")
            _expect("terrain artifact disk cache eviction delta" in text, "cold cache should fail disk eviction proof")

        _with_gate_env(
            {
                "TOWN_STALL_REQUIRE_TERRAIN_ARTIFACT_CACHE_PROOF": "1",
                "TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_HIT_RATIO": "0.9",
                "TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_DISK_HIT_DELTA": "2",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_BYTE_BUDGET_RATIO": "0.6",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_EVICTION_DELTA": "1",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_BYTE_BUDGET_RATIO": "0.5",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_EVICTION_DELTA": "2",
            },
            expect_cold_cache_snapshot_fails,
        )

        fallback_snapshot = _write_snapshot(root, _snapshot_payload(False))

        def expect_window_fallback_passes() -> None:
            failures = runner._snapshot_proof_gate_failures(fallback_snapshot)
            _expect(failures == [], f"window fallback proof should pass, got {failures}")

        _with_gate_env(
            {
                "TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF": "1",
                "TOWN_STALL_REQUIRE_WORLD_BAKE_PROOF": "1",
                "TOWN_STALL_REQUIRE_WORLD_BAKE_EXPORT_SIGNATURE": "1",
                "TOWN_STALL_REQUIRE_WORLD_BAKE_HEIGHT_BIOME_BACKEND": "native",
                "TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF": "1",
                "TOWN_STALL_REQUIRE_TERRAIN_ARTIFACT_CACHE_PROOF": "1",
                "TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_HIT_RATIO": "0.9",
                "TOWN_STALL_MIN_TERRAIN_ARTIFACT_CACHE_DISK_HIT_DELTA": "2",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_BYTE_BUDGET_RATIO": "0.6",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_CACHE_EVICTION_DELTA": "1",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_BYTE_BUDGET_RATIO": "0.5",
                "TOWN_STALL_MAX_TERRAIN_ARTIFACT_DISK_CACHE_EVICTION_DELTA": "2",
            },
            expect_window_fallback_passes,
        )

    print("[RUN_TOWN_STALL_SNAPSHOT_GATE_TEST] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
