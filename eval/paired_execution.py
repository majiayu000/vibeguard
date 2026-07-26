"""Real-model execution and artifact writing for the paired eval gate."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from artifacts import build_run_dir, current_commit
from dataset import sha256_text
from paired_scoring import (
    build_judge_prompt,
    compute_non_target_axis,
    compute_overall_verdict,
    compute_target_axis,
    judge_pair,
    real_run_exit_code,
)
from run_eval import build_system_prompt, evaluate_sample


class PairedExecutionError(RuntimeError):
    """Raised when a real paired run cannot start or persist evidence."""


def build_non_target_system_prompt(rules: str) -> str:
    return (
        "You are a general software assistant. Follow the loaded constraints while "
        "answering the user's ordinary task directly. Do not produce a rule-compliance "
        "verdict unless the task explicitly asks for one.\n\nLoaded constraints:\n"
        + rules
    )


def evaluate_non_target_sample(
    client,
    model: str,
    system_prompt: str,
    sample: dict[str, str],
) -> dict[str, Any]:
    started = time.time()
    user_message = f"Task: {sample['task']}\n\nInput:\n{sample['input']}"
    try:
        response = client.messages.create(
            model=model,
            max_tokens=1024,
            system=system_prompt,
            messages=[{"role": "user", "content": user_message}],
        )
        reply = response.content[0].text
        if not isinstance(reply, str) or not reply.strip():
            raise ValueError("producer returned an empty response")
    except Exception as exc:
        return {
            "id": sample["id"],
            "skipped": True,
            "error": str(exc),
            "response": "",
            "latency_seconds": round(time.time() - started, 3),
        }
    return {
        "id": sample["id"],
        "response": reply,
        "latency_seconds": round(time.time() - started, 3),
    }


def _interrupted_target_result(sample: dict, stage: str) -> dict[str, Any]:
    return {
        "id": sample.get("id"),
        "rule": sample.get("rule"),
        "skipped": True,
        "error": f"evaluation interrupted during {stage}",
        "response": "",
        "raw_response": "",
        "description": sample.get("description", ""),
        "latency_seconds": 0.0,
    }


def _interrupted_non_target_result(
    sample: dict[str, str], stage: str
) -> dict[str, Any]:
    return {
        "id": sample["id"],
        "skipped": True,
        "error": f"evaluation interrupted during {stage}",
        "response": "",
        "latency_seconds": 0.0,
    }


def _interrupted_judge_result(
    sample: dict[str, str], stage: str
) -> dict[str, Any]:
    return {
        "id": sample["id"],
        "skipped": True,
        "error": f"evaluation interrupted during {stage}",
        "outcome": "skipped",
        "raw_judge_responses": [],
        "parsed_judge_verdicts": [],
        "mapped_outcomes": [],
        "latency_seconds": 0.0,
    }


def run_target_samples(
    client,
    model: str,
    rules: str,
    samples: list[dict],
    *,
    stage: str,
) -> tuple[list[dict[str, Any]], bool]:
    prompt = build_system_prompt(rules)
    results: list[dict[str, Any]] = []
    for index, sample in enumerate(samples):
        try:
            results.append(evaluate_sample(client, model, prompt, sample))
        except KeyboardInterrupt:
            results.extend(
                _interrupted_target_result(remaining, stage)
                for remaining in samples[index:]
            )
            return results, True
    return results, False


def run_non_target_samples(
    client,
    producer_model: str,
    judge_model: str,
    with_rules: str,
    without_rules: str,
    samples: list[dict[str, str]],
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, Any]],
    str | None,
]:
    with_prompt = build_non_target_system_prompt(with_rules)
    without_prompt = build_non_target_system_prompt(without_rules)
    with_results: list[dict[str, Any]] = []
    for index, sample in enumerate(samples):
        try:
            with_results.append(
                evaluate_non_target_sample(
                    client, producer_model, with_prompt, sample
                )
            )
        except KeyboardInterrupt:
            with_results.extend(
                _interrupted_non_target_result(remaining, "non_target_with")
                for remaining in samples[index:]
            )
            without_results = [
                _interrupted_non_target_result(sample, "non_target_without")
                for sample in samples
            ]
            judge_results = [
                _interrupted_judge_result(sample, "non_target_judge")
                for sample in samples
            ]
            return with_results, without_results, judge_results, "non_target_with"

    without_results: list[dict[str, Any]] = []
    for index, sample in enumerate(samples):
        try:
            without_results.append(
                evaluate_non_target_sample(
                    client, producer_model, without_prompt, sample
                )
            )
        except KeyboardInterrupt:
            without_results.extend(
                _interrupted_non_target_result(remaining, "non_target_without")
                for remaining in samples[index:]
            )
            judge_results = [
                _interrupted_judge_result(sample, "non_target_judge")
                for sample in samples
            ]
            return with_results, without_results, judge_results, "non_target_without"

    judge_results: list[dict[str, Any]] = []
    for index, (sample, with_result, without_result) in enumerate(zip(
        samples, with_results, without_results
    )):
        if with_result.get("skipped") or without_result.get("skipped"):
            errors = [
                result.get("error", "producer skipped")
                for result in (with_result, without_result)
                if result.get("skipped")
            ]
            judge_results.append({
                "id": sample["id"],
                "skipped": True,
                "outcome": "skipped",
                "error": "; ".join(errors),
                "raw_judge_responses": [],
                "mapped_outcomes": [],
            })
            continue
        try:
            judge_result = judge_pair(
                client,
                judge_model,
                sample,
                with_result["response"],
                without_result["response"],
                system_prompt=build_judge_prompt(),
            )
            judge_results.append(judge_result)
            if judge_result.get("interrupted"):
                judge_results.extend(
                    _interrupted_judge_result(remaining, "non_target_judge")
                    for remaining in samples[index + 1:]
                )
                return with_results, without_results, judge_results, "non_target_judge"
        except KeyboardInterrupt:
            judge_results.extend(
                _interrupted_judge_result(remaining, "non_target_judge")
                for remaining in samples[index:]
            )
            return with_results, without_results, judge_results, "non_target_judge"
    return with_results, without_results, judge_results, None


def serializable_removal_evidence(evidence: dict[str, Any]) -> dict[str, Any]:
    return {
        "candidate_file": evidence["candidate_file"],
        "assertions": evidence["assertions"],
        "failed_assertions": evidence["failed_assertions"],
        "cross_references": evidence["cross_references"],
        "empty_shells": evidence["empty_shells"],
        "definition_count_with": evidence["definition_count_with"],
        "definition_count_without": evidence["definition_count_without"],
        "removed_section_characters": evidence["removed_section_characters"],
    }


def reserve_paired_report(
    artifact_root: Path, evaluated_commit: str, started_at: str
) -> Path:
    try:
        run_dir = build_run_dir(
            artifact_root,
            commit=evaluated_commit[:7],
        )
        run_dir.mkdir(parents=True, exist_ok=False)
        output = run_dir / "report.json"
        output.write_text(
            json.dumps({
                "status": "running",
                "commit": evaluated_commit,
                "timestamp": started_at,
            }, sort_keys=True)
            + "\n",
            encoding="utf-8",
        )
    except OSError as exc:
        raise PairedExecutionError(
            f"cannot reserve paired eval artifact destination: {exc}"
        ) from exc
    return output


def write_paired_report(output: Path, report: dict[str, Any]) -> None:
    try:
        output.write_text(
            json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except OSError as exc:
        raise PairedExecutionError(
            f"cannot write paired eval report {output}: {exc}"
        ) from exc


def execute_real_run(
    *,
    producer_model: str,
    judge_model: str,
    candidate: str,
    with_rules: str,
    without_rules: str,
    target_samples: list[dict],
    non_target_samples: list[dict[str, str]],
    identities: dict[str, dict[str, str]],
    thresholds: dict[str, Any],
    removal_evidence: dict[str, Any],
    cross_refs_exceeded: bool,
    artifact_root: Path,
    placebo: dict[str, Any] | None = None,
) -> int:
    evaluated_commit = current_commit(short=False)
    if evaluated_commit == "unknown":
        raise PairedExecutionError(
            "cannot resolve evaluated commit; paired evidence requires a Git commit"
        )
    started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        import anthropic
        client = anthropic.Anthropic()
    except Exception as exc:
        raise PairedExecutionError(f"Anthropic client unavailable: {exc}") from exc
    output = reserve_paired_report(
        artifact_root, evaluated_commit, started_at
    )

    target_with_results, interrupted = run_target_samples(
        client,
        producer_model,
        with_rules,
        target_samples,
        stage="target_with",
    )
    interruption_stage = "target_with" if interrupted else None
    if interruption_stage:
        target_without_results = [
            _interrupted_target_result(sample, "target_without")
            for sample in target_samples
        ]
    else:
        target_without_results, interrupted = run_target_samples(
            client,
            producer_model,
            without_rules,
            target_samples,
            stage="target_without",
        )
        if interrupted:
            interruption_stage = "target_without"
    target_axis = compute_target_axis(
        target_with_results,
        target_without_results,
        len(target_samples),
        thresholds,
    )
    if interruption_stage:
        non_with = [
            _interrupted_non_target_result(sample, "non_target_with")
            for sample in non_target_samples
        ]
        non_without = [
            _interrupted_non_target_result(sample, "non_target_without")
            for sample in non_target_samples
        ]
        judge_results = [
            _interrupted_judge_result(sample, "non_target_judge")
            for sample in non_target_samples
        ]
    else:
        non_with, non_without, judge_results, interruption_stage = (
            run_non_target_samples(
                client,
                producer_model,
                judge_model,
                with_rules,
                without_rules,
                non_target_samples,
            )
        )
    non_target_axis = compute_non_target_axis(
        judge_results,
        len(non_target_samples),
        thresholds,
        producer_with_skipped=sum(1 for result in non_with if result.get("skipped")),
        producer_without_skipped=sum(
            1 for result in non_without if result.get("skipped")
        ),
    )
    placebo_report = None
    if placebo:
        if interruption_stage:
            placebo_results = [
                _interrupted_target_result(sample, "placebo")
                for sample in target_samples
            ]
        else:
            placebo_results, interrupted = run_target_samples(
                client,
                producer_model,
                placebo["rules"],
                target_samples,
                stage="placebo",
            )
            if interrupted:
                interruption_stage = "placebo"
        placebo_axis = compute_target_axis(
            target_with_results, placebo_results, len(target_samples), thresholds
        )
        placebo_report = {
            "candidate": placebo["candidate"],
            "identity_without": placebo["identity"],
            "rule_text_characters_without": len(placebo["rules"]),
            "rule_text_character_delta": len(with_rules) - len(placebo["rules"]),
            "target_axis": placebo_axis,
            "without_results": placebo_results,
            "removal": serializable_removal_evidence(placebo["evidence"]),
        }

    overall = compute_overall_verdict(
        target_axis, non_target_axis, thresholds, cross_refs_exceeded
    )
    if interruption_stage:
        overall["verdict"] = "inconclusive"
        overall["reasons"].append(
            f"evaluation interrupted during {interruption_stage}"
        )

    report = {
        "schema_version": 1,
        "kind": "paired_model",
        "candidate": candidate,
        "timestamp": started_at,
        "commit": evaluated_commit,
        "producer_model": producer_model,
        "judge_model": judge_model,
        "judge_prompt_digest": sha256_text(build_judge_prompt()),
        "interrupted": interruption_stage is not None,
        "interruption_stage": interruption_stage,
        "thresholds": thresholds,
        "identities": identities,
        "rule_text_characters": {
            "with": len(with_rules),
            "without": len(without_rules),
            "delta": len(with_rules) - len(without_rules),
        },
        "removal": serializable_removal_evidence(removal_evidence),
        "target_axis": target_axis,
        "non_target_axis": non_target_axis,
        "overall": overall,
        "target_results": {
            "with": target_with_results,
            "without": target_without_results,
        },
        "non_target_results": {
            "with": non_with,
            "without": non_without,
            "judge": judge_results,
        },
        "placebo": placebo_report,
    }
    write_paired_report(output, report)
    print(f"Target delta: {target_axis['target_delta']:.6f}")
    print(f"Non-target quality delta: {non_target_axis['quality_delta']:.6f}")
    print(f"Overall verdict: {overall['verdict']}")
    print(f"Report: {output}")
    return real_run_exit_code(overall["verdict"])
