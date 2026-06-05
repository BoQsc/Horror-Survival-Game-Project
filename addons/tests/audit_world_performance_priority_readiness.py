import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Optional

import run_world_performance_priority_proof as proof_runner


PROJECT_ROOT = Path(__file__).resolve().parents[2]
AGENT_DIR = PROJECT_ROOT / ".agent"
DEFAULT_OUTPUT = PROJECT_ROOT / ".agent" / "world-performance-priority-readiness-audit.json"
DEFAULT_FAST_PROOF_REPORT = PROJECT_ROOT / ".agent" / "world-performance-priority-proof-fast-after-completion-audit.json"
DEFAULT_PRODUCTION_DRY_RUN_REPORT = PROJECT_ROOT / ".agent" / "world-performance-priority-proof-production-plan-dry-run.json"
DEFAULT_PRODUCTION_EVIDENCE_OUTPUT = PROJECT_ROOT / ".agent" / "world-performance-priority-proof-production-evidence.json"

SOURCE_SCAN_ROOTS = (
    Path("world_marching_cubes"),
    Path("world_map_generator"),
    Path("world_performance"),
    Path("modules/world_player_v2/features/ui_loading_screen"),
    Path("game/entities"),
)
SOURCE_SUFFIXES = {".gd", ".py", ".cpp", ".h", ".hpp"}
ENV_PATTERN = re.compile(r"(?:OS\.get_environment|os\.environ\.get|std::getenv)\(\s*[\"']([^\"']+)[\"']")
TOWN_STALL_STRING_PATTERN = re.compile(r"[\"'](TOWN_STALL_[A-Z0-9_]+)[\"']")
TEST_HOOK_MARKERS = (
    "DISABLE",
    "FORCE",
    "TEST",
    "SMOKE",
    "HARNESS",
    "BYPASS",
    "IGNORE",
)


def _cleanup_action(kind: str) -> str:
    if kind == "test_or_isolation_hook":
        return "remove_or_move_to_harness_after_evidence"
    if kind == "test_hook_marker":
        return "review_for_removal_after_evidence"
    if kind == "rollout_or_tuning_override":
        return "promote_to_default_or_documented_setting_after_evidence"
    return "classify_after_evidence"


def _cleanup_evidence(kind: str) -> str:
    if kind in ("test_or_isolation_hook", "test_hook_marker"):
        return "accepted production proof no longer needs this isolation path"
    if kind == "rollout_or_tuning_override":
        return "accepted captures show which value should become the stable default or project setting"
    return "accepted captures prove whether this override is needed"


def _read_json(path: Path) -> Optional[dict[str, Any]]:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def _relative(path: Path) -> str:
    try:
        return str(path.relative_to(PROJECT_ROOT)).replace("\\", "/")
    except ValueError:
        return str(path).replace("\\", "/")


def _classify_env_override(env_name: str, line: str) -> tuple[str, str]:
    upper_name = env_name.upper()
    upper_line = line.upper()
    if any(marker in upper_name or marker in upper_line for marker in TEST_HOOK_MARKERS) or "_FOR_TEST" in upper_line:
        return (
            "test_or_isolation_hook",
            "Remove after accepted production proof, or keep only inside the test harness if the proof still needs it.",
        )
    if upper_name.startswith("TOWN_STALL_"):
        return (
            "rollout_or_tuning_override",
            "After accepted production proof, convert stable values into defaults or documented project settings.",
        )
    return (
        "environment_override",
        "Review after accepted production proof and keep only if it is a permanent runtime configuration.",
    )


def _append_cleanup_candidate(
    candidates: list[dict[str, Any]],
    seen: set[tuple[str, int, str]],
    relative_path: str,
    line_number: int,
    kind: str,
    name: str,
    action: str,
) -> None:
    key = (relative_path, line_number, name)
    if key in seen:
        return
    seen.add(key)
    candidates.append(
        {
            "path": relative_path,
            "line": line_number,
            "kind": kind,
            "name": name,
            "action": action,
            "post_evidence_action": _cleanup_action(kind),
            "evidence_required": _cleanup_evidence(kind),
        }
    )


def _scan_cleanup_candidates() -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    seen: set[tuple[str, int, str]] = set()
    for root in SOURCE_SCAN_ROOTS:
        absolute_root = PROJECT_ROOT / root
        if not absolute_root.exists():
            continue
        for path in absolute_root.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in SOURCE_SUFFIXES:
                continue
            relative_path = _relative(path)
            text = path.read_text(encoding="utf-8", errors="ignore")
            for line_number, line in enumerate(text.splitlines(), start=1):
                env_names = [match.group(1) for match in ENV_PATTERN.finditer(line)]
                for match in TOWN_STALL_STRING_PATTERN.finditer(line):
                    env_name = match.group(1)
                    if env_name not in env_names:
                        env_names.append(env_name)
                for env_name in env_names:
                    kind, action = _classify_env_override(env_name, line)
                    _append_cleanup_candidate(
                        candidates,
                        seen,
                        relative_path,
                        line_number,
                        kind,
                        env_name,
                        action,
                    )
                if "_for_test" in line or "for test" in line.lower():
                    _append_cleanup_candidate(
                        candidates,
                        seen,
                        relative_path,
                        line_number,
                        "test_hook_marker",
                        "_for_test",
                        "Review after accepted production proof and remove if it is only a harness shortcut.",
                    )
    return candidates


def _build_plan_audit() -> dict[str, Any]:
    args = proof_runner.parse_args(["--run-production", "--production-suite", proof_runner.DEFAULT_PRODUCTION_SUITE])
    production_plan = proof_runner._production_plan(args)
    steps = proof_runner.build_steps(args)
    validation_errors = proof_runner.validate_args(args)
    safety_errors = proof_runner.validate_step_safety(args, steps)
    heavy_steps = [step.name for step in steps if step.heavy]
    fast_steps = [step.name for step in steps if not step.heavy]
    return {
        "suite": production_plan.get("suite"),
        "case_count": len(production_plan.get("cases", [])),
        "cases": production_plan.get("cases", []),
        "missing_scenarios": production_plan.get("missing_scenarios", []),
        "raw_case_covered_scenarios": production_plan.get("raw_case_covered_scenarios", []),
        "contract_only_scenarios": production_plan.get("contract_only_scenarios", []),
        "validation_errors": validation_errors,
        "safety_errors": safety_errors,
        "heavy_steps": heavy_steps,
        "fast_step_count": len(fast_steps),
        "heavy_step_count": len(heavy_steps),
    }


def _report_mtime(path: Path) -> Optional[float]:
    if not path.exists():
        return None
    return path.stat().st_mtime


def _summarize_report(path: Path) -> dict[str, Any]:
    payload = _read_json(path)
    if payload is None:
        return {"path": _relative(path), "present": False}
    completion_audit = payload.get("completion_audit", {})
    dry_run = bool(payload.get("dry_run", False))
    run_production = bool(payload.get("run_production", False))
    passed = bool(payload.get("passed", False))
    evidence_status = completion_audit.get("production_evidence_status")
    accepted_production_evidence = bool(run_production and not dry_run and passed and evidence_status == "executed_passed")
    rejection_reasons: list[str] = []
    if run_production and not dry_run and not accepted_production_evidence:
        if not passed:
            rejection_reasons.append("production report did not pass")
        if evidence_status != "executed_passed":
            rejection_reasons.append("completion audit does not report executed_passed production evidence")
    return {
        "path": _relative(path),
        "present": True,
        "mtime_epoch": _report_mtime(path),
        "passed": passed,
        "dry_run": dry_run,
        "run_production": run_production,
        "step_count": int(payload.get("step_count", 0) or 0),
        "completed_step_count": int(payload.get("completed_step_count", 0) or 0),
        "accepted_production_evidence": accepted_production_evidence,
        "rejection_reasons": rejection_reasons,
        "completion": {
            "complete": bool(completion_audit.get("complete", False)),
            "production_evidence_status": evidence_status,
            "planned_scenarios_missing": completion_audit.get("planned_scenarios_missing", []),
            "remaining_blockers": completion_audit.get("remaining_blockers", []),
        },
    }


def _find_latest_report(kind: str) -> dict[str, Any]:
    candidates: list[tuple[float, Path]] = []
    if AGENT_DIR.exists():
        for path in AGENT_DIR.glob("world-performance-priority-proof*.json"):
            payload = _read_json(path)
            if payload is None:
                continue
            if kind == "fast_proof":
                matches = not bool(payload.get("dry_run", False)) and not bool(payload.get("run_production", False))
            elif kind == "production_dry_run":
                matches = bool(payload.get("dry_run", False)) and bool(payload.get("run_production", False))
            elif kind == "production_evidence":
                matches = (not bool(payload.get("dry_run", False))) and bool(payload.get("run_production", False))
            else:
                matches = False
            if matches:
                candidates.append((path.stat().st_mtime, path))
    if not candidates:
        return {"kind": kind, "present": False}
    _, path = max(candidates, key=lambda item: item[0])
    summary = _summarize_report(path)
    summary["kind"] = kind
    summary["selected_by"] = "latest_mtime"
    return summary


def _relative_command(command: list[str]) -> list[str]:
    converted: list[str] = []
    for part in command:
        text = str(part)
        try:
            path = Path(text)
            if path.is_absolute():
                converted.append(_relative(path))
                continue
        except (OSError, ValueError):
            pass
        converted.append(text)
    return converted


def _build_next_commands() -> dict[str, Any]:
    production_args = proof_runner.parse_args([
        "--run-production",
        "--production-suite",
        proof_runner.DEFAULT_PRODUCTION_SUITE,
        "--output",
        str(DEFAULT_PRODUCTION_EVIDENCE_OUTPUT),
    ])
    production_steps = proof_runner.build_production_steps(production_args)
    return {
        "production_evidence_wrapper": [
            sys.executable,
            "addons/tests/run_world_performance_priority_proof.py",
            "--run-production",
            "--production-suite",
            proof_runner.DEFAULT_PRODUCTION_SUITE,
            "--output",
            _relative(DEFAULT_PRODUCTION_EVIDENCE_OUTPUT),
        ],
        "production_evidence_steps": [
            {
                "name": step.name,
                "heavy": bool(step.heavy),
                "timeout_seconds": step.timeout_seconds,
                "command": _relative_command(step.command),
            }
            for step in production_steps
        ],
        "post_evidence_readiness_audit": [
            sys.executable,
            "addons/tests/audit_world_performance_priority_readiness.py",
            "--output",
            _relative(DEFAULT_OUTPUT),
        ],
    }


def build_audit(args: argparse.Namespace) -> dict[str, Any]:
    plan_audit = _build_plan_audit()
    cleanup_candidates = _scan_cleanup_candidates()
    by_kind: dict[str, int] = {}
    for candidate in cleanup_candidates:
        kind = str(candidate.get("kind", "unknown"))
        by_kind[kind] = by_kind.get(kind, 0) + 1

    fast_report = _summarize_report(args.fast_proof_report)
    production_dry_run_report = _summarize_report(args.production_dry_run_report)
    readiness_errors: list[str] = []
    if plan_audit["missing_scenarios"]:
        readiness_errors.append("priority_full production plan still has missing roadmap scenarios")
    if plan_audit["validation_errors"]:
        readiness_errors.append("priority_full production proof arguments are invalid")
    if plan_audit["safety_errors"]:
        readiness_errors.append("priority_full proof step safety failed")

    material_gates = [
        "accepted heavy production proof run with fresh captures",
        "threshold tuning from accepted production captures",
        "GPU sync/readback A/B decision from accepted cache-miss data",
        "post-evidence cleanup or permanent classification of rollout/test hooks",
    ]
    return {
        "safe_non_game_audit": True,
        "passed": not readiness_errors,
        "readiness_errors": readiness_errors,
        "pre_production_plan_ready": not readiness_errors,
        "production_acceptance_complete": False,
        "material_gates_remaining": material_gates,
        "production_plan": plan_audit,
        "reports": {
            "configured_fast_proof": fast_report,
            "configured_production_plan_dry_run": production_dry_run_report,
            "latest_fast_proof": _find_latest_report("fast_proof"),
            "latest_production_plan_dry_run": _find_latest_report("production_dry_run"),
            "latest_production_evidence": _find_latest_report("production_evidence"),
        },
        "next_commands": _build_next_commands(),
        "cleanup": {
            "candidate_count": len(cleanup_candidates),
            "candidate_count_by_kind": by_kind,
            "candidates": cleanup_candidates,
        },
    }


def _write_report(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Audit non-game readiness for the world performance priority production gate.")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--fast-proof-report", type=Path, default=DEFAULT_FAST_PROOF_REPORT)
    parser.add_argument("--production-dry-run-report", type=Path, default=DEFAULT_PRODUCTION_DRY_RUN_REPORT)
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv)
    payload = build_audit(args)
    _write_report(args.output, payload)
    print(f"[priority-readiness-audit] wrote {args.output}")
    if payload.get("passed", False):
        print("[priority-readiness-audit] pre-production plan ready; production acceptance remains gated")
        return 0
    print("[priority-readiness-audit] failed")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
