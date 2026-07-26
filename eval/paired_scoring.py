"""Scoring primitives for paired with/without model evaluations."""

from __future__ import annotations

import json
import time
from typing import Any


class PairwiseJudgeError(ValueError):
    """Raised when a pairwise judge response violates its JSON contract."""


def build_judge_prompt() -> str:
    return (
        "Compare two anonymous responses against the task and rubric. "
        "Return JSON only: {\"winner\":\"A\"|\"B\"|\"tie\",\"reason\":\"one sentence\"}. "
        "Do not infer how either response was produced."
    )


def parse_pairwise_judge(reply: str) -> dict[str, str]:
    try:
        payload = json.loads(reply.strip())
    except json.JSONDecodeError as exc:
        raise PairwiseJudgeError(f"invalid pairwise judge JSON: {exc.msg}") from exc
    if not isinstance(payload, dict):
        raise PairwiseJudgeError("pairwise judge output must be a JSON object")
    if set(payload) != {"winner", "reason"}:
        raise PairwiseJudgeError("pairwise judge output requires only winner and reason")
    if payload["winner"] not in {"A", "B", "tie"}:
        raise PairwiseJudgeError("pairwise judge winner must be A, B, or tie")
    if not isinstance(payload["reason"], str) or not payload["reason"].strip():
        raise PairwiseJudgeError("pairwise judge reason must be a non-empty string")
    return {"winner": payload["winner"], "reason": payload["reason"].strip()}


def _mapped_winner(winner: str, swapped: bool) -> str:
    if winner == "tie":
        return "tie"
    if (winner == "A") != swapped:
        return "with_win"
    return "without_win"


def _judge_message(
    sample: dict[str, str],
    response_a: str,
    response_b: str,
) -> str:
    return (
        f"Task: {sample['task']}\n"
        f"Input:\n{sample['input']}\n\n"
        f"Quality rubric: {sample['rubric']}\n\n"
        f"Response A:\n{response_a}\n\n"
        f"Response B:\n{response_b}"
    )


def judge_pair(
    client,
    model: str,
    sample: dict[str, str],
    with_response: str,
    without_response: str,
    *,
    system_prompt: str | None = None,
) -> dict[str, Any]:
    """Blindly judge a pair twice, swapping A/B positions on the second call."""
    prompt = system_prompt or build_judge_prompt()
    raw_responses: list[str] = []
    parsed_verdicts: list[dict[str, str]] = []
    mapped: list[str] = []
    started = time.time()
    for swapped in (False, True):
        response_a, response_b = (
            (without_response, with_response)
            if swapped
            else (with_response, without_response)
        )
        try:
            response = client.messages.create(
                model=model,
                max_tokens=512,
                system=prompt,
                messages=[{
                    "role": "user",
                    "content": _judge_message(sample, response_a, response_b),
                }],
            )
            raw = response.content[0].text
            parsed = parse_pairwise_judge(raw)
        except Exception as exc:
            return {
                "id": sample["id"],
                "skipped": True,
                "error": str(exc),
                "outcome": "skipped",
                "raw_judge_responses": raw_responses,
                "parsed_judge_verdicts": parsed_verdicts,
                "mapped_outcomes": mapped,
                "latency_seconds": round(time.time() - started, 3),
            }
        raw_responses.append(raw)
        parsed_verdicts.append(parsed)
        mapped.append(_mapped_winner(parsed["winner"], swapped))
    outcome = mapped[0] if mapped[0] == mapped[1] else "conflict"
    return {
        "id": sample["id"],
        "outcome": outcome,
        "raw_judge_responses": raw_responses,
        "parsed_judge_verdicts": parsed_verdicts,
        "mapped_outcomes": mapped,
        "latency_seconds": round(time.time() - started, 3),
    }


def _skip_reasons(
    with_skipped: int,
    without_skipped: int,
    requested: int,
    thresholds: dict[str, Any],
) -> tuple[list[str], float, float]:
    denominator = max(requested, 1)
    with_rate = with_skipped / denominator
    without_rate = without_skipped / denominator
    reasons: list[str] = []
    if max(with_rate, without_rate) > thresholds["max_skip_rate"]:
        reasons.append("skip rate exceeds max_skip_rate")
    if abs(with_rate - without_rate) > thresholds["max_skip_delta"]:
        reasons.append("paired skip-rate delta exceeds max_skip_delta")
    return reasons, with_rate, without_rate


def compute_target_axis(
    with_results: list[dict[str, Any]],
    without_results: list[dict[str, Any]],
    requested: int,
    thresholds: dict[str, Any],
) -> dict[str, Any]:
    with_skipped = sum(1 for result in with_results if result.get("skipped"))
    without_skipped = sum(1 for result in without_results if result.get("skipped"))
    reasons, with_skip_rate, without_skip_rate = _skip_reasons(
        with_skipped, without_skipped, requested, thresholds
    )
    denominator = max(requested, 1)
    with_pass_rate = (
        sum(1 for result in with_results if result.get("detected")) / denominator
    )
    without_pass_rate = (
        sum(1 for result in without_results if result.get("detected")) / denominator
    )
    delta = with_pass_rate - without_pass_rate
    if requested < thresholds["min_target_samples"]:
        reasons.append("target sample count is below min_target_samples")
    if reasons:
        verdict = "inconclusive"
    elif delta > thresholds["min_target_delta"]:
        verdict = "pass"
    else:
        verdict = "fail"
    return {
        "verdict": verdict,
        "requested_samples": requested,
        "with_pass_rate": with_pass_rate,
        "without_pass_rate": without_pass_rate,
        "target_delta": delta,
        "with_skipped": with_skipped,
        "without_skipped": without_skipped,
        "with_skip_rate": with_skip_rate,
        "without_skip_rate": without_skip_rate,
        "reasons": reasons,
    }


def compute_non_target_axis(
    judge_results: list[dict[str, Any]],
    requested: int,
    thresholds: dict[str, Any],
    *,
    producer_with_skipped: int = 0,
    producer_without_skipped: int = 0,
) -> dict[str, Any]:
    reasons, with_skip_rate, without_skip_rate = _skip_reasons(
        producer_with_skipped,
        producer_without_skipped,
        requested,
        thresholds,
    )
    judge_skipped = sum(1 for result in judge_results if result.get("skipped"))
    conflicts = sum(1 for result in judge_results if result.get("outcome") == "conflict")
    denominator = max(requested, 1)
    judge_skip_rate = judge_skipped / denominator
    if judge_skip_rate > thresholds["max_skip_rate"]:
        reasons.append("judge skip rate exceeds max_skip_rate")
    if conflicts:
        reasons.append(f"judge conflict on {conflicts} sample(s)")
    if requested < thresholds["min_non_target_samples"]:
        reasons.append("non-target sample count is below min_non_target_samples")
    with_wins = sum(1 for result in judge_results if result.get("outcome") == "with_win")
    without_wins = sum(
        1 for result in judge_results if result.get("outcome") == "without_win"
    )
    ties = sum(1 for result in judge_results if result.get("outcome") == "tie")
    delta = (with_wins - without_wins) / denominator
    if reasons:
        verdict = "inconclusive"
    elif delta >= -thresholds["max_non_target_drop"]:
        verdict = "pass"
    else:
        verdict = "fail"
    return {
        "verdict": verdict,
        "requested_samples": requested,
        "with_wins": with_wins,
        "without_wins": without_wins,
        "ties": ties,
        "conflicts": conflicts,
        "judge_skipped": judge_skipped,
        "quality_delta": delta,
        "producer_with_skipped": producer_with_skipped,
        "producer_without_skipped": producer_without_skipped,
        "producer_with_skip_rate": with_skip_rate,
        "producer_without_skip_rate": without_skip_rate,
        "judge_skip_rate": judge_skip_rate,
        "reasons": reasons,
    }


def compute_overall_verdict(
    target_axis: dict[str, Any],
    non_target_axis: dict[str, Any],
    thresholds: dict[str, Any],
    cross_refs_exceeded: bool,
) -> dict[str, Any]:
    reasons: list[str] = []
    if not thresholds["calibrated"]:
        reasons.append("thresholds are not calibrated")
    if cross_refs_exceeded:
        reasons.append("candidate cross references exceed max_cross_refs")
    for name, axis in (("target", target_axis), ("non_target", non_target_axis)):
        if axis["verdict"] == "inconclusive":
            reasons.append(f"{name} axis is inconclusive")

    if reasons:
        verdict = "inconclusive"
    elif target_axis["verdict"] == "pass" and non_target_axis["verdict"] == "pass":
        verdict = "pass"
    else:
        verdict = "fail"
    return {"verdict": verdict, "reasons": reasons}


def real_run_exit_code(verdict: str) -> int:
    return 0 if verdict == "pass" else 1
