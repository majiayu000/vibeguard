#!/usr/bin/env python3
"""Materialize and verify adopted VibeGuard Learn signals."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from triage_state import append_transition, default_state_file, read_latest_states, utc_now


ACTION_SPACES: dict[str, set[str]] = {
    "runtime_health": {"fix_runtime", "tune_config", "collect_more_evidence"},
    "defense_gap": {"enhance_guard", "add_hook", "add_rule"},
    "defense_friction": {"add_scoped_suppression", "enhance_guard", "tune_config"},
    "project_quality": {"change_project_code", "collect_more_evidence"},
    "workflow_friction": {"create_or_update_skill", "tune_config", "collect_more_evidence"},
    "skill_candidate": {"create_or_update_skill"},
    "noise": {"no_action", "collect_more_evidence"},
}

DEFAULT_ADOPTIONS_FILE = Path.home() / ".vibeguard" / "learn-adoptions.jsonl"


class LearnAdoptionError(ValueError):
    """Raised when a Learn adoption or verification record is invalid."""


def default_adoptions_file() -> Path:
    return Path(os.environ.get("VIBEGUARD_LEARN_ADOPTIONS_FILE", DEFAULT_ADOPTIONS_FILE))


def load_learn_json_object(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise LearnAdoptionError(f"cannot read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise LearnAdoptionError(f"invalid JSON in {path}: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise LearnAdoptionError(f"{path} must contain a JSON object")
    return data


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def iter_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                records.append(item)
    return records


def parse_utc(value: str, field: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise LearnAdoptionError(f"{field} must be an ISO timestamp") from exc
    if parsed.tzinfo is None:
        raise LearnAdoptionError(f"{field} must include timezone")
    return parsed.astimezone(timezone.utc)


def iso_z(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def require_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise LearnAdoptionError(f"{key} is required")
    return value.strip()


def recommended_actions(signal: dict[str, Any]) -> list[dict[str, Any]]:
    raw = signal.get("recommended_actions")
    if not isinstance(raw, list):
        return []
    return [item for item in raw if isinstance(item, dict)]


def select_action(signal: dict[str, Any], requested_type: str | None) -> dict[str, Any]:
    classification = require_string(signal, "classification")
    allowed = ACTION_SPACES.get(classification)
    if allowed is None:
        raise LearnAdoptionError(f"unsupported classification: {classification}")

    candidates = recommended_actions(signal)
    if requested_type:
        action_type = requested_type.strip()
        selected = next((item for item in candidates if item.get("type") == action_type), None)
        action = dict(selected or {"type": action_type, "rationale": f"selected {action_type}"})
    else:
        selected = next((item for item in candidates if item.get("type") in allowed), None)
        if selected is None:
            raise LearnAdoptionError(f"signal has no allowed action for {classification}")
        action = dict(selected)

    action_type = action.get("type")
    if action_type not in allowed:
        allowed_text = ", ".join(sorted(allowed))
        raise LearnAdoptionError(f"{classification} cannot use action {action_type}; allowed: {allowed_text}")
    if not isinstance(action.get("rationale"), str) or not action["rationale"].strip():
        action["rationale"] = f"selected {action_type}"
    return action


def governance_for_action(action: dict[str, Any]) -> dict[str, Any] | None:
    action_type = action.get("type")
    if action_type == "add_scoped_suppression":
        return {
            "config_key": "scoped_suppressions",
            "artifact": ".vibeguard.json",
            "review_focus": "narrow hook/rule/path false-positive governance",
        }
    if action_type == "no_action":
        return {
            "config_key": None,
            "artifact": None,
            "review_focus": "noise path, no project or guard mutation",
        }
    return None


def state_transition(
    state_file: Path,
    signal_id: str,
    to_state: str,
    reason: str,
    now: datetime,
) -> dict[str, Any]:
    latest = read_latest_states(state_file)
    record = {
        "schema_version": 1,
        "signal_id": signal_id,
        "from": latest.get(signal_id, "new"),
        "to": to_state,
        "reason": reason,
        "ts": iso_z(now),
    }
    append_transition(state_file, record)
    return record


def evidence_samples(signal: dict[str, Any]) -> list[dict[str, Any]]:
    samples = signal.get("evidence_samples")
    if isinstance(samples, list) and samples:
        return [item for item in samples if isinstance(item, dict)]
    summary = signal.get("reason") or signal.get("file") or signal.get("type") or "learn signal"
    return [{"summary": str(summary)}]


def build_adoption_record(args: argparse.Namespace, signal: dict[str, Any], now: datetime) -> dict[str, Any]:
    action = select_action(signal, args.action)
    signal_id = require_string(signal, "signal_id")
    observation_id = str(signal.get("observation_id") or "")
    artifact_values = [item for item in args.artifact if item.strip()]
    if not artifact_values and action.get("target"):
        artifact_values = [str(action["target"])]

    to_state = "skipped" if action["type"] == "no_action" else "adopted"
    transition = state_transition(args.state_file, signal_id, to_state, args.reason, now)
    verification_commands = [args.verification_command]
    regression_checks = [args.regression_command]

    record: dict[str, Any] = {
        "schema_version": 1,
        "ts": iso_z(now),
        "signal_id": signal_id,
        "observation_id": observation_id,
        "classification": require_string(signal, "classification"),
        "selected_action": action,
        "files_or_artifacts": artifact_values,
        "original_evidence": evidence_samples(signal),
        "verification_commands": verification_commands,
        "regression_checks": regression_checks,
        "baseline": args.baseline,
        "expected_later_observation": args.expected_observation,
        "rollback_path": args.rollback,
        "state_transition": transition,
    }
    governance = governance_for_action(action)
    if governance is not None:
        record["governance"] = governance
    append_jsonl(args.adoptions_file, record)
    return record


def latest_adoption(path: Path, signal_id: str) -> dict[str, Any]:
    matches = [record for record in iter_jsonl(path) if record.get("signal_id") == signal_id]
    if not matches:
        raise LearnAdoptionError(f"no adoption record found for {signal_id}")
    return matches[-1]


def verification_status(evidence: dict[str, Any], requested_status: str | None) -> str:
    regression_signals = evidence.get("regression_signals", [])
    has_regression = bool(regression_signals)
    recurrence_delta = evidence.get("recurrence_delta")
    recurrence_regressed = isinstance(recurrence_delta, (int, float)) and recurrence_delta > 0
    inferred = "regressed" if has_regression or recurrence_regressed else "verified"
    if requested_status and requested_status != inferred:
        raise LearnAdoptionError(
            f"requested status {requested_status} conflicts with fresh evidence status {inferred}"
        )
    return requested_status or inferred


def build_verify_record(args: argparse.Namespace, now: datetime) -> dict[str, Any]:
    adoption = latest_adoption(args.adoptions_file, args.signal_id)
    evidence = load_learn_json_object(args.evidence)
    evidence_signal_id = evidence.get("signal_id")
    if evidence_signal_id != args.signal_id:
        raise LearnAdoptionError("fresh evidence signal_id must match --signal-id")
    observed_at = require_string(evidence, "observed_at")
    observed_time = parse_utc(observed_at, "observed_at")
    adoption_time = parse_utc(require_string(adoption, "ts"), "adoption ts")
    if observed_time <= adoption_time:
        raise LearnAdoptionError("fresh evidence must be newer than the adoption record")

    status = verification_status(evidence, args.status)
    command = args.verification_command or "; ".join(adoption.get("verification_commands", []))
    if not command:
        raise LearnAdoptionError("verification command is required")
    transition = state_transition(args.state_file, args.signal_id, status, args.reason, now)
    record = {
        "schema_version": 1,
        "ts": iso_z(now),
        "signal_id": args.signal_id,
        "verification": {
            "status": status,
            "commands": [command],
            "evidence_observed_at": iso_z(observed_time),
            "notes": args.reason,
        },
        "state_transition": transition,
        "fresh_evidence": evidence,
    }
    append_jsonl(args.adoptions_file, record)
    return record


def output_for_adoption(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "command": "learn",
        "mode": "adopt",
        "schema_version": 1,
        "signal_id": record["signal_id"],
        "action": record["selected_action"],
        "state_transition": {
            "from": record["state_transition"]["from"],
            "to": record["state_transition"]["to"],
            "reason": record["state_transition"]["reason"],
        },
        "verification": {
            "status": "pending",
            "commands": record["verification_commands"] + record["regression_checks"],
            "notes": record["expected_later_observation"],
        },
        "adoption": record,
    }


def output_for_verification(record: dict[str, Any]) -> dict[str, Any]:
    verification = dict(record["verification"])
    return {
        "command": "learn",
        "mode": "verify",
        "schema_version": 1,
        "signal_id": record["signal_id"],
        "verification": verification,
    }


def build_adoption_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Materialize or verify adopted Learn signals.")
    parser.add_argument("--state-file", type=Path, default=default_state_file())
    parser.add_argument("--adoptions-file", type=Path, default=default_adoptions_file())
    sub = parser.add_subparsers(dest="command", required=True)

    adopt = sub.add_parser("adopt")
    adopt.add_argument("--signal", type=Path, required=True)
    adopt.add_argument("--action")
    adopt.add_argument("--artifact", action="append", default=[])
    adopt.add_argument("--verification-command", required=True)
    adopt.add_argument("--regression-command", required=True)
    adopt.add_argument("--baseline", required=True)
    adopt.add_argument("--expected-observation", required=True)
    adopt.add_argument("--rollback", required=True)
    adopt.add_argument("--reason", required=True)

    verify = sub.add_parser("verify")
    verify.add_argument("--signal-id", required=True)
    verify.add_argument("--evidence", type=Path, required=True)
    verify.add_argument("--status", choices=["verified", "regressed"])
    verify.add_argument("--verification-command")
    verify.add_argument("--reason", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_adoption_parser().parse_args(argv)
    try:
        now = utc_now()
        if args.command == "adopt":
            record = build_adoption_record(args, load_learn_json_object(args.signal), now)
            output = output_for_adoption(record)
        else:
            record = build_verify_record(args, now)
            output = output_for_verification(record)
    except LearnAdoptionError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    sys.stdout.write(json.dumps(output, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
