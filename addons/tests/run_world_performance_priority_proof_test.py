import json
import tempfile
from pathlib import Path

import run_world_performance_priority_proof as proof_runner


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _command_text(step: proof_runner.ProofStep) -> str:
    return " ".join(str(part) for part in step.command)


def main() -> int:
    smoke_args = proof_runner.parse_args(["--skip-godot"])
    smoke_steps = proof_runner.build_steps(smoke_args)
    smoke_names = [step.name for step in smoke_steps]
    _expect("godot_launcher_safety" in smoke_names, "smoke suite should include launcher safety")
    _expect("third_party_policy" in smoke_names, "smoke suite should include third-party policy")
    _expect("world_performance_priority_readiness_audit" in smoke_names, "smoke suite should include production readiness audit")
    _expect("world_map_bake_proof_contract" not in smoke_names, "skip-godot should remove Godot contract tests")
    _expect("existing_snapshot_analysis_smoke" in smoke_names, "smoke suite should include existing snapshot analysis")
    _expect(not any(step.heavy for step in smoke_steps), "default smoke suite should not include heavy production runs")
    _expect(proof_runner.validate_step_safety(smoke_args, smoke_steps) == [], "skip-godot smoke suite should satisfy proof step safety")

    godot_contract_args = proof_runner.parse_args(["--skip-python"])
    godot_contract_steps = proof_runner.build_steps(godot_contract_args)
    godot_contract_names = [step.name for step in godot_contract_steps]
    _expect(proof_runner.validate_step_safety(godot_contract_args, godot_contract_steps) == [], "Godot contract suite should satisfy proof step safety")
    _expect("world_startup_coordinator_contract" in godot_contract_names, "Godot suite should include startup coordinator contract")
    _expect("loading_screen_progress_contract" in godot_contract_names, "Godot suite should include loading-screen progress contract")
    _expect("player_viewer_signal_contract" in godot_contract_names, "Godot suite should include player viewer signal contract")
    _expect("terrain_startup_readiness_detail_contract" in godot_contract_names, "Godot suite should include terrain startup readiness detail contract")
    _expect("terrain_artifact_cache_contract" in godot_contract_names, "Godot suite should include terrain artifact cache contract")
    _expect("terrain_artifact_disk_store_contract" in godot_contract_names, "Godot suite should include terrain artifact disk store contract")
    _expect("terrain_startup_preheat_contract" in godot_contract_names, "Godot suite should include terrain startup preheat contract")
    _expect("terrain_warm_startup_preheat_contract" in godot_contract_names, "Godot suite should include warm startup preheat contract")
    _expect("terrain_generation_telemetry_contract" in godot_contract_names, "Godot suite should include terrain generation telemetry contract")
    _expect("terrain_height_map_samples_native_contract" in godot_contract_names, "Godot suite should include terrain height-map native sample contract")
    _expect("terrain_mask_sample_telemetry_contract" in godot_contract_names, "Godot suite should include terrain mask sample telemetry contract")
    _expect("terrain_process_sleep_contract" in godot_contract_names, "Godot suite should include terrain process sleep contract")
    _expect("terrain_runtime_setting_wake_contract" in godot_contract_names, "Godot suite should include terrain runtime setting wake contract")
    _expect("terrain_world_definition_change_contract" in godot_contract_names, "Godot suite should include world-definition change contract")
    _expect("town_stall_artifact_budget_override_contract" in godot_contract_names, "Godot suite should include artifact budget override contract")
    _expect("save_manager_terrain_modifications_contract" in godot_contract_names, "Godot suite should include save-manager terrain modifications contract")
    _expect("world_map_preview_builder_contract" in godot_contract_names, "Godot suite should include preview builder contract")
    _expect("entity_startup_readiness_contract" in godot_contract_names, "Godot suite should include entity startup readiness contract")
    _expect("building_viewer_signal_contract" in godot_contract_names, "Godot suite should include building viewer signal contract")
    _expect("vegetation_chunk_placement_cache_contract" in godot_contract_names, "Godot suite should include vegetation placement cache contract")
    _expect("vegetation_viewer_signal_contract" in godot_contract_names, "Godot suite should include vegetation viewer signal contract")
    _expect("entity_pool_reuse_contract" in godot_contract_names, "Godot suite should include entity pool reuse contract")
    _expect("entity_maintenance_driver_contract" in godot_contract_names, "Godot suite should include entity maintenance driver contract")
    _expect("entity_viewer_signal_contract" in godot_contract_names, "Godot suite should include entity viewer signal contract")
    _expect("entity_background_spawn_idle_contract" in godot_contract_names, "Godot suite should include entity background spawn idle contract")
    _expect("building_grouped_merge_native_contract" in godot_contract_names, "Godot suite should include building grouped merge native contract")
    _expect("vegetation_cluster_payload_native_contract" in godot_contract_names, "Godot suite should include vegetation cluster payload native contract")
    _expect("vegetation_generation_timing_contract" in godot_contract_names, "Godot suite should include vegetation generation timing contract")
    _expect("vegetation_native_record_append_contract" in godot_contract_names, "Godot suite should include vegetation native record append contract")
    _expect("vegetation_noise_samples_native_contract" in godot_contract_names, "Godot suite should include vegetation noise native sample contract")
    _expect("vegetation_pending_chunk_scheduler_native_contract" in godot_contract_names, "Godot suite should include vegetation pending chunk native scheduler contract")
    _expect("vegetation_removed_filter_native_contract" in godot_contract_names, "Godot suite should include vegetation removed filter native contract")
    _expect("world_map_mask_samples_native_contract" in godot_contract_names, "Godot suite should include world-map mask native sample contract")

    parse_check_args = proof_runner.parse_args(["--skip-python", "--include-parse-check"])
    parse_check_steps = proof_runner.build_steps(parse_check_args)
    _expect(proof_runner.validate_step_safety(parse_check_args, parse_check_steps) == [], "Godot check-only parse step should satisfy proof step safety")

    unsafe_godot_step = proof_runner.ProofStep(
        name="unsafe_bot_contract",
        command=[
            "godot",
            "--headless",
            "--path",
            str(proof_runner.PROJECT_ROOT),
            "-s",
            "addons/tests/minimal_bot.gd",
        ],
        uses_godot=True,
    )
    unsafe_python_step = proof_runner.ProofStep(
        name="unsafe_python_launcher",
        command=[str(proof_runner.TEST_DIR / "run_town_stall_test.py")],
    )
    safety_text = "\n".join(proof_runner.validate_step_safety(smoke_args, [unsafe_godot_step, unsafe_python_step]))
    _expect("gameplay/bot harness" in safety_text, "proof step safety should reject bot-style Godot scripts")
    _expect("run_town_stall_test.py" in safety_text, "proof step safety should reject non-heavy town launchers")

    production_args = proof_runner.parse_args([
        "--skip-godot",
        "--run-production",
        "--production-cases",
        "runtime_default",
        "--production-repeats",
        "2",
        "--production-mode",
        "pilot",
        "--allow-contaminated-idle",
        "--max-world-bake-ms",
        "7000",
        "--max-world-bake-hash-ms",
        "20",
        "--min-runtime-idle-ratio",
        "1.0",
        "--max-runtime-awake-process-count",
        "0",
        "--min-terrain-artifact-cache-hit-ratio",
        "0.9",
    ])
    production_steps = proof_runner.build_steps(production_args)
    _expect(proof_runner.validate_step_safety(production_args, production_steps) == [], "heavy production launchers should satisfy safety only as heavy steps")
    raw_steps = [step for step in production_steps if step.name == "production_raw_baseline_with_priority_gates"]
    analysis_steps = [step for step in production_steps if step.name == "production_raw_baseline_analysis_gate"]
    _expect(len(raw_steps) == 1, "production suite should include raw baseline step")
    _expect(len(analysis_steps) == 1, "production suite should include raw analyzer gate step")
    raw_command = _command_text(raw_steps[0])
    analysis_command = _command_text(analysis_steps[0])
    _expect("--cases runtime_default" in raw_command, "explicit production cases should override suite expansion")
    _expect("--require-startup-readiness-proof" in raw_command, "raw run should require startup proof")
    _expect("--require-world-bake-proof" in raw_command, "raw run should require bake proof")
    _expect("--require-world-bake-export-signature" in raw_command, "raw run should require bake export proof")
    _expect("--require-world-bake-height-biome-backend native" in raw_command, "raw run should require native bake backend")
    _expect("--allow-contaminated-idle" in raw_command, "raw run should propagate contaminated-idle override")
    _expect("--preflight-max-gpu-temp-c 80" in raw_command, "raw run should wait for GPU cooldown before production cases")
    _expect("--preflight-cooldown-timeout-seconds 600" in raw_command, "raw run should bound GPU cooldown waits")
    _expect("--preflight-idle-retry-timeout-seconds 300" in raw_command, "raw run should use bounded idle preflight retry by default")
    _expect("--max-world-bake-ms 7000" in raw_command, "raw run should propagate bake timing threshold")
    _expect("--min-runtime-idle-ratio 1" in raw_command, "raw run should propagate runtime idle ratio threshold")
    _expect("--require-latest-raw-baseline-startup-readiness-proof" in analysis_command, "analysis should enforce raw startup proof")
    _expect("--require-latest-raw-baseline-world-bake-proof" in analysis_command, "analysis should enforce raw bake proof")
    _expect("--require-latest-raw-baseline-runtime-idle-proof" in analysis_command, "analysis should enforce raw runtime idle proof")
    _expect("--min-latest-raw-baseline-terrain-artifact-cache-hit-ratio 0.9" in analysis_command, "analysis should propagate cache threshold")

    suite_args = proof_runner.parse_args([
        "--skip-godot",
        "--run-production",
        "--production-suite",
        "priority_full",
    ])
    suite_steps = proof_runner.build_steps(suite_args)
    suite_raw_step = next(step for step in suite_steps if step.name == "production_raw_baseline_with_priority_gates")
    suite_command = _command_text(suite_raw_step)
    _expect(
        "--cases runtime_default,priority_revisit,priority_render_distance_5,priority_render_distance_10,priority_render_distance_15,priority_memory_pressure" in suite_command,
        "priority_full suite should expand to revisit, render-distance, and memory-pressure proof cases",
    )
    suite_plan = proof_runner._production_plan(suite_args)
    covered = set(suite_plan.get("covered_scenarios", []))
    missing = set(suite_plan.get("missing_scenarios", []))
    raw_case_covered = set(suite_plan.get("raw_case_covered_scenarios", []))
    _expect("unchanged_revisit" in covered, "priority_full plan should cover unchanged revisit")
    _expect("render_distance_5" in covered, "priority_full plan should cover render distance 5")
    _expect("render_distance_10" in covered, "priority_full plan should cover render distance 10")
    _expect("render_distance_15" in covered, "priority_full plan should cover render distance 15")
    _expect("memory_pressure" in covered, "priority_full plan should cover memory pressure")
    _expect("unchanged_revisit" in raw_case_covered, "priority_full plan should mark unchanged revisit as raw-case-covered")
    _expect("low_resolution_preview" in missing, "skip-godot plan should still flag preview contract as missing")
    _expect("world_switch_cache_isolation" in missing, "skip-godot plan should still flag world-switch contract as missing")
    _expect("edit_revisit" in missing, "skip-godot plan should still flag edit revisit contract as missing")
    _expect("save_reload_modified" in missing, "skip-godot plan should still flag save/reload modified contract as missing")
    _expect("warm_startup" in missing, "priority_full plan should still flag warm startup as requiring external preparation")

    full_plan_args = proof_runner.parse_args([
        "--run-production",
        "--production-suite",
        "priority_full",
    ])
    full_plan = proof_runner._production_plan(full_plan_args)
    full_covered = set(full_plan.get("covered_scenarios", []))
    contract_covered = set(full_plan.get("contract_covered_scenarios", []))
    contract_only = set(full_plan.get("contract_only_scenarios", []))
    full_external = set(full_plan.get("requires_external_preparation", []))
    _expect("low_resolution_preview" in contract_covered, "Godot contract plan should mark preview as contract-covered")
    _expect("warm_startup" in contract_covered, "Godot contract plan should mark warm startup as contract-covered")
    _expect("world_switch_cache_isolation" in contract_covered, "Godot contract plan should mark world switch as contract-covered")
    _expect("edit_revisit" in contract_covered, "Godot contract plan should mark edit revisit as contract-covered")
    _expect("save_reload_modified" in contract_covered, "Godot contract plan should mark save/reload modified as contract-covered")
    _expect("low_resolution_preview" in full_covered, "Godot contract plan should include preview in covered scenarios")
    _expect("warm_startup" in full_covered, "Godot contract plan should include warm startup in covered scenarios")
    _expect("world_switch_cache_isolation" in full_covered, "Godot contract plan should include world switch in covered scenarios")
    _expect("edit_revisit" in full_covered, "Godot contract plan should include edit revisit in covered scenarios")
    _expect("save_reload_modified" in full_covered, "Godot contract plan should include save/reload modified in covered scenarios")
    _expect("world_switch_cache_isolation" not in full_external, "covered world-switch contract should not remain externally prepared")
    _expect("warm_startup" not in full_external, "covered warm startup contract should not remain externally prepared")
    _expect("edit_revisit" not in full_external, "covered edit revisit contract should not remain externally prepared")
    _expect("save_reload_modified" not in full_external, "covered save/reload modified contract should not remain externally prepared")
    _expect("warm_startup" in contract_only, "warm startup should be reported as contract-only until a raw case exists")
    _expect("edit_revisit" in contract_only, "edit revisit should be reported as contract-only until a raw case exists")
    _expect("unchanged_revisit" not in contract_only, "raw-case revisit should not be reported as contract-only")

    planning_audit = proof_runner._completion_audit(full_plan_args, full_plan)
    _expect(planning_audit.get("complete") is False, "completion audit should not mark planning-only work complete")
    _expect(planning_audit.get("production_evidence_status") == "requested_not_completed", "completion audit should report requested-but-missing production results")
    _expect("accepted heavy production proof run has not passed" in planning_audit.get("remaining_blockers", []), "completion audit should require accepted production evidence")

    no_production_args = proof_runner.parse_args([])
    no_production_audit = proof_runner._completion_audit(no_production_args, proof_runner._production_plan(no_production_args), [])
    _expect(no_production_audit.get("production_evidence_status") == "not_requested", "completion audit should report missing production request")

    dry_run_audit_args = proof_runner.parse_args(["--dry-run", "--run-production"])
    dry_run_audit = proof_runner._completion_audit(dry_run_audit_args, proof_runner._production_plan(dry_run_audit_args), [])
    _expect(dry_run_audit.get("production_evidence_status") == "dry_run_only", "completion audit should distinguish dry-run production plans")

    passed_production_audit = proof_runner._completion_audit(
        full_plan_args,
        full_plan,
        [
            {"name": "production_raw_baseline_with_priority_gates", "heavy": True, "status": "passed"},
            {"name": "production_raw_baseline_analysis_gate", "heavy": True, "status": "passed"},
        ],
    )
    _expect(passed_production_audit.get("production_evidence_status") == "executed_passed", "completion audit should detect passed heavy evidence")
    _expect(passed_production_audit.get("complete") is False, "passed production proof alone should not complete cleanup and A/B work")

    invalid_proof_args = proof_runner.parse_args([
        "--skip-godot",
        "--run-production",
        "--allow-contaminated-idle",
        "--world-bake-backend",
        "gdscript",
        "--max-gpu-temp-c",
        "0",
    ])
    validation_errors = proof_runner.validate_args(invalid_proof_args)
    validation_text = "\n".join(validation_errors)
    _expect("--allow-contaminated-idle requires --production-mode pilot" in validation_text, "proof mode should reject contaminated-idle override")
    _expect("--world-bake-backend must be native" in validation_text, "proof mode should reject fallback bake backend")
    _expect("--max-gpu-temp-c must be positive" in validation_text, "proof mode should reject disabled GPU temp gate")

    pilot_args = proof_runner.parse_args([
        "--skip-godot",
        "--run-production",
        "--production-mode",
        "pilot",
        "--allow-contaminated-idle",
        "--world-bake-backend",
        "gdscript",
        "--max-gpu-temp-c",
        "0",
    ])
    _expect(proof_runner.validate_args(pilot_args) == [], "pilot mode should allow exploratory contaminated/fallback diagnostics")
    unknown_case_args = proof_runner.parse_args([
        "--skip-godot",
        "--run-production",
        "--production-mode",
        "pilot",
        "--production-cases",
        "not_a_real_case",
    ])
    _expect("not_a_real_case" in "\n".join(proof_runner.validate_args(unknown_case_args)), "pilot mode should still reject unknown cases")

    with tempfile.TemporaryDirectory() as temp_dir:
        output_path = Path(temp_dir) / "priority-proof-dry-run.json"
        exit_code = proof_runner.main(["--dry-run", "--skip-godot", "--output", str(output_path)])
        _expect(exit_code == 0, "dry-run should pass")
        payload = json.loads(output_path.read_text(encoding="utf-8"))
        _expect(payload.get("dry_run") is True, "dry-run report should be marked")
        _expect(payload.get("production_mode") == "proof", "dry-run report should include production mode")
        _expect("production_plan" in payload, "dry-run report should include production proof plan")
        _expect("completion_audit" in payload, "dry-run report should include completion audit")
        completion_audit = payload.get("completion_audit", {})
        _expect(completion_audit.get("complete") is False, "dry-run completion audit should remain incomplete")
        _expect(completion_audit.get("production_evidence_status") == "dry_run_only", "dry-run completion audit should report dry-run only")
        _expect(payload.get("passed") is True, "dry-run report should pass")
        _expect(int(payload.get("completed_step_count", 0)) == int(payload.get("step_count", -1)), "dry-run should report all planned steps")
        _expect(all(step.get("status") == "skipped" for step in payload.get("steps", [])), "dry-run should skip every command")

    print("[RUN_WORLD_PERFORMANCE_PRIORITY_PROOF_TEST] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
