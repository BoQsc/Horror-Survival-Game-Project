import json
import tempfile
from pathlib import Path

import audit_world_performance_priority_readiness as readiness_audit


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    with tempfile.TemporaryDirectory() as temp_dir:
        output_path = Path(temp_dir) / "readiness-audit.json"
        exit_code = readiness_audit.main(["--output", str(output_path)])
        _expect(exit_code == 0, "readiness audit should pass when the non-game production plan is valid")
        payload = json.loads(output_path.read_text(encoding="utf-8"))
        _expect(payload.get("safe_non_game_audit") is True, "audit should be explicitly non-game")
        _expect(payload.get("passed") is True, "audit should pass")
        _expect(payload.get("pre_production_plan_ready") is True, "production plan should be ready before heavy evidence")
        _expect(payload.get("production_acceptance_complete") is False, "audit must not claim production acceptance")

        reports = payload.get("reports", {})
        latest_fast = reports.get("latest_fast_proof", {})
        latest_production_dry_run = reports.get("latest_production_plan_dry_run", {})
        latest_production_evidence = reports.get("latest_production_evidence", {})
        _expect("configured_fast_proof" in reports, "audit should include the configured fast proof report")
        _expect("configured_production_plan_dry_run" in reports, "audit should include the configured production dry-run report")
        _expect(latest_fast.get("kind") == "fast_proof" or latest_fast.get("present") is False, "latest fast report should be typed when present")
        _expect(
            latest_production_dry_run.get("kind") == "production_dry_run" or latest_production_dry_run.get("present") is False,
            "latest production dry-run report should be typed when present",
        )
        _expect(
            latest_production_evidence.get("kind") == "production_evidence" or latest_production_evidence.get("present") is False,
            "latest production evidence report should be typed when present",
        )
        _expect(
            latest_production_evidence.get("accepted_production_evidence") in (True, False, None),
            "latest production evidence summary should expose accepted evidence state when present",
        )

        next_commands = payload.get("next_commands", {})
        wrapper_command = " ".join(str(part) for part in next_commands.get("production_evidence_wrapper", []))
        _expect("--run-production" in wrapper_command, "next command should include the production proof flag")
        _expect("priority_full" in wrapper_command, "next command should use the priority_full production suite")
        production_steps = next_commands.get("production_evidence_steps", [])
        _expect(len(production_steps) == 2, "next commands should include the two heavy production proof steps")
        _expect(all(step.get("heavy") is True for step in production_steps), "production evidence steps should be marked heavy")

        production_plan = payload.get("production_plan", {})
        _expect(production_plan.get("missing_scenarios") == [], "priority_full plan should have no missing scenarios")
        _expect(production_plan.get("heavy_step_count") == 2, "priority_full production proof should plan two heavy steps")
        _expect("priority_memory_pressure" in production_plan.get("cases", []), "priority_full should include memory pressure")
        _expect("warm_startup" in production_plan.get("contract_only_scenarios", []), "warm startup should remain contract-only")

        material_gates = "\n".join(payload.get("material_gates_remaining", []))
        _expect("accepted heavy production proof" in material_gates, "accepted production proof should remain a material gate")
        _expect("GPU sync/readback A/B" in material_gates, "GPU readback decision should remain a material gate")
        _expect("rollout/test hooks" in material_gates, "post-evidence cleanup should remain a material gate")

        cleanup = payload.get("cleanup", {})
        _expect(cleanup.get("candidate_count", 0) > 40, "cleanup audit should find direct and helper-based rollout/test hook candidates")
        candidates = cleanup.get("candidates", [])
        candidate_paths = {candidate.get("path") for candidate in candidates}
        candidate_names = {candidate.get("name") for candidate in candidates}
        post_evidence_actions = {candidate.get("post_evidence_action") for candidate in candidates}
        _expect("world_marching_cubes/chunk_manager.gd" in candidate_paths, "terrain manager env overrides should be audited")
        _expect("game/entities/entity_manager.gd" in candidate_paths, "entity manager helper-based env overrides should be audited")
        _expect("TOWN_STALL_ENTITY_MAX_ENTITIES" in candidate_names, "entity helper env override names should be captured")
        _expect("promote_to_default_or_documented_setting_after_evidence" in post_evidence_actions, "tuning overrides should carry a post-evidence action")
        _expect("remove_or_move_to_harness_after_evidence" in post_evidence_actions, "test hooks should carry a post-evidence action")

    print("[AUDIT_WORLD_PERFORMANCE_PRIORITY_READINESS_TEST] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
