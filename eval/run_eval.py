#!/usr/bin/env python3
"""
VibeGuard LLM-as-Judge Assessment

Use Claude API to test the actual detection rate of VibeGuard rules.
What is measured is the true combined effect of "Claude + Rules".

usage:
    uv run python eval/run_eval.py #Run all samples
    uv run python eval/run_eval.py --rules SEC # Only run security rules
    uv run python eval/run_eval.py --model haiku # Use cheap model
    uv run python eval/run_eval.py --dry-run # Just look at the sample without adjusting the API
"""

import argparse
import os
import sys
import time
from pathlib import Path

from artifacts import DEFAULT_RUNS_DIR, build_run_dir, current_commit, write_run_artifacts
from dataset import (
    DEFAULT_DATASET_PATH,
    DatasetError,
    file_digest,
    load_dataset,
    sample_set_digest,
    sha256_text,
)
from scoring import CONFIDENCE_SCORES, ScorerParseError, parse_confidence, parse_scorer_output

MODELS = {
    "haiku": "claude-haiku-4-5-20251001",
    "sonnet": "claude-sonnet-4-6",
    "opus": "claude-opus-4-6",
}

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RULES_DIR = REPO_ROOT / "rules" / "claude-rules"
DEFAULT_CORE_RULES_FILE = REPO_ROOT / "claude-md" / "vibeguard-rules.md"


def load_rules(rules_dir: Path, core_rules_file: Path | None) -> str:
    """Load all VibeGuard rules from the checked-out repository snapshot."""
    rules_text = []

    for rule_file in sorted(rules_dir.rglob("*.md")):
        content = rule_file.read_text(encoding="utf-8")
        if content.startswith("---"):
            parts = content.split("---", 2)
            if len(parts) >= 3:
                content = parts[2].strip()
        rules_text.append(f"# {rule_file.stem}\n\n{content}")

    if core_rules_file and core_rules_file.exists():
        claude_md = core_rules_file.read_text(encoding="utf-8")
        in_vg = False
        vg_lines = []
        for line in claude_md.split("\n"):
            if "vibeguard-start" in line:
                in_vg = True
                continue
            if "vibeguard-end" in line:
                in_vg = False
                continue
            if in_vg:
                vg_lines.append(line)
        if vg_lines:
            rules_text.append("# VibeGuard Core Constraints\n\n" + "\n".join(vg_lines))
        else:
            rules_text.append("# VibeGuard Core Constraints\n\n" + claude_md.strip())

    return "\n\n---\n\n".join(rules_text)


def build_system_prompt(rules: str) -> str:
    return f"""You are a code review assistant. You have loaded the following code quality rules:

{rules}

When a user gives you code, you must:
1. Review all applicable rules one by one
2. Return JSON only, with this exact shape:
   {{"detected": true|false, "rule_ids": ["RULE-ID"], "confidence": "low|medium|high", "reason": "one sentence"}}
3. For clean code, return detected=false and rule_ids=[]
4. Don't suggest improvements - only report rule compliance verdicts"""


def build_user_message(sample: dict) -> str:
    user_prompt = sample.get("prompt") or "Review this code for VibeGuard rule compliance."
    source = sample.get("input", sample.get("code", ""))
    return (
        f"Scenario: {sample.get('context', 'reviewing')}\n"
        f"Expected action: {sample.get('expected_action', 'warn_or_refuse')}\n"
        f"Task: {user_prompt}\n\n"
        f"Review the following {sample['lang']} code:\n\n"
        f"```{sample['lang']}\n{source.strip()}\n```"
    )


def evaluate_sample(
    client,
    model: str,
    system_prompt: str,
    sample: dict,
) -> dict:
    """Run evaluation on a single sample"""
    user_msg = build_user_message(sample)
    started = time.time()

    try:
        response = client.messages.create(
            model=model,
            max_tokens=1024,
            system=system_prompt,
            messages=[{"role": "user", "content": user_msg}],
        )
        reply = response.content[0].text
    except Exception as e:
        return {
            "id": sample.get("id"),
            "rule": "FP-CHECK" if sample["rule"] == "NONE" else sample["rule"],
            "expected": "CLEAN" if sample["rule"] == "NONE" else sample["rule"],
            "severity": sample.get("severity"),
            "expected_action": sample.get("expected_action"),
            "skipped": True,
            "error": str(e),
            "response": "",
            "raw_response": "",
            "description": sample["description"],
            "latency_seconds": round(time.time() - started, 3),
        }

    try:
        scorer = parse_scorer_output(reply)
    except ScorerParseError as e:
        return {
            "id": sample.get("id"),
            "rule": "FP-CHECK" if sample["rule"] == "NONE" else sample["rule"],
            "expected": "CLEAN" if sample["rule"] == "NONE" else sample["rule"],
            "severity": sample.get("severity"),
            "expected_action": sample.get("expected_action"),
            "skipped": True,
            "error": str(e),
            "response": reply,
            "raw_response": reply,
            "description": sample["description"],
            "latency_seconds": round(time.time() - started, 3),
        }

    confidence = scorer.get("confidence")
    expected_rule = sample["rule"]
    is_clean = expected_rule == "NONE"

    if is_clean:
        has_false_positive = bool(scorer["detected"] or scorer["rule_ids"])
        result = {
            "id": sample.get("id"),
            "rule": "FP-CHECK",
            "expected": "CLEAN",
            "expected_action": sample.get("expected_action"),
            "detected_fp": has_false_positive,
            "rule_ids": scorer["rule_ids"],
            "reason": scorer["reason"],
            "response": reply,
            "raw_response": reply,
            "description": sample["description"],
            "severity": "clean",
            "latency_seconds": round(time.time() - started, 3),
        }
        if confidence:
            result["confidence"] = confidence
        return result

    detected = bool(scorer["detected"] and expected_rule.upper() in scorer["rule_ids"])

    result = {
        "id": sample.get("id"),
        "rule": expected_rule,
        "severity": sample["severity"],
        "expected_action": sample.get("expected_action"),
        "detected": detected,
        "rule_ids": scorer["rule_ids"],
        "reason": scorer["reason"],
        "response": reply,
        "raw_response": reply,
        "description": sample["description"],
        "latency_seconds": round(time.time() - started, 3),
    }
    if confidence:
        result["confidence"] = confidence
    return result


def filter_samples(samples: list[dict], args) -> list[dict]:
    filtered = samples
    if args.rules:
        prefix = args.rules.upper()
        filtered = [
            s
            for s in filtered
            if s["rule"].startswith(prefix) or s["rule"] == "NONE"
        ]
        print(f"Number of samples after filtering: {len(filtered)} (prefix: {prefix})")
    if args.type:
        if args.type == "tp":
            filtered = [s for s in filtered if s["type"] == "tp"]
        elif args.type == "fp":
            filtered = [s for s in filtered if s["type"] == "fp"]
        print(f"Number of samples after type filtering: {len(filtered)} (Type: {args.type})")
    return filtered


def run_eval(args):
    rules_dir = Path(args.rules_dir).resolve()
    core_rules_file = Path(args.core_rules_file).resolve() if args.core_rules_file else None
    dataset_path = Path(args.dataset).resolve()
    try:
        all_samples = load_dataset(dataset_path)
    except DatasetError as e:
        print(f"Invalid eval dataset: {e}", file=sys.stderr)
        sys.exit(2)

    rules = load_rules(rules_dir, core_rules_file)
    system_prompt = build_system_prompt(rules)
    rule_digest = sha256_text(rules)
    dataset_digest = file_digest(dataset_path)
    samples = filter_samples(all_samples, args)
    filtered_sample_digest = sample_set_digest(samples)

    if args.dry_run:
        print(f"Rule text length: {len(rules)} characters")
        print(f"Number of samples: {len(samples)}")
        print(f"Dataset source: {dataset_path}")
        print(f"Sample digest: {filtered_sample_digest}")
        print(f"Rules source: {rules_dir}")
        print(f"Rule digest: {rule_digest}")
        if core_rules_file:
            print(f"Core constraint source: {core_rules_file}")
        print(f"\nSample list:")
        for s in samples:
            tag = "FP" if s["type"] == "fp" else s["rule"]
            print(f"  [{tag}] {s['id']}: {s['description']}")
        return

    model = MODELS.get(args.model, args.model)
    try:
        import anthropic
    except ImportError:
        print("Anthropic SDK is required: uv pip install anthropic")
        sys.exit(1)
    client = anthropic.Anthropic()

    print(f"Model: {model}")
    print(f"Number of samples: {len(samples)}")
    print(f"Rule text: {len(rules)} characters")
    print(f"Dataset source: {dataset_path}")
    print(f"Sample digest: {filtered_sample_digest}")
    print(f"Rule digest: {rule_digest}")
    print("=" * 60)

    results = []
    started = time.time()
    for i, sample in enumerate(samples):
        tag = "FP" if sample["type"] == "fp" else sample["rule"]
        print(f"[{i + 1}/{len(samples)}] {tag}: {sample['description']}...", end=" ", flush=True)

        result = evaluate_sample(client, model, system_prompt, sample)
        results.append(result)

        if result.get("skipped"):
            print(f"SKIPPED: {result['error']}")
        elif "detected_fp" in result:
            status = "FALSE POSITIVE" if result["detected_fp"] else "CLEAN OK"
            print(status)
        else:
            status = "DETECTED" if result["detected"] else "MISSED"
            print(status)

        # Avoid rate limiting
        time.sleep(0.5)

    print_report(results, model)

    skipped_count = count_skipped(results)
    metadata = {
        "model": model,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "commit": current_commit(short=False),
        "scorer_version": "structured-json-v1",
        "dataset_source": str(dataset_path),
        "dataset_digest": dataset_digest,
        "sample_set_digest": filtered_sample_digest,
        "sample_count": len(samples),
        "rules_source": str(rules_dir),
        "core_rules_source": str(core_rules_file) if core_rules_file else None,
        "rule_digest": rule_digest,
        "skipped_count": skipped_count,
        "latency_seconds": round(time.time() - started, 3),
    }
    run_dir = build_run_dir(args.artifact_root)
    output_path = write_run_artifacts(
        run_dir,
        metadata=metadata,
        samples=samples,
        results=results,
    )
    print(f"\nResult saved: {output_path}")

    max_api_failures = read_max_api_failures()
    if skipped_count > max_api_failures:
        print(
            f"Eval failed: {skipped_count} skipped sample(s) exceeded "
            f"EVAL_MAX_API_FAILURES={max_api_failures}",
            file=sys.stderr,
        )
        sys.exit(2)


def count_skipped(results: list[dict]) -> int:
    return sum(1 for r in results if r.get("skipped"))


def read_max_api_failures() -> int:
    raw = os.environ.get("EVAL_MAX_API_FAILURES", "0")
    try:
        value = int(raw)
    except ValueError:
        print(
            f"Invalid EVAL_MAX_API_FAILURES={raw!r}; expected a non-negative integer",
            file=sys.stderr,
        )
        sys.exit(2)
    if value < 0:
        print(
            f"Invalid EVAL_MAX_API_FAILURES={raw!r}; expected a non-negative integer",
            file=sys.stderr,
        )
        sys.exit(2)
    return value


def print_report(results: list[dict], model: str):
    print("\n" + "=" * 60)
    print(f"VibeGuard LLM-as-Judge Report ({model})")
    print("=" * 60)

    # Separate true positive tests and false positive tests. Skipped samples
    # are infrastructure/API failures, not genuine misses or false positives.
    skipped_results = [r for r in results if r.get("skipped")]
    valid_results = [r for r in results if not r.get("skipped")]
    tp_results = [r for r in valid_results if "detected" in r]
    fp_results = [r for r in valid_results if "detected_fp" in r]

    if skipped_results:
        print(f"\nSkipped: {len(skipped_results)} infrastructure/API error(s)")
        for r in skipped_results:
            print(f"  [{r['rule']}] {r['description']}")
            print(f"  Error: {r['error']}")

    # True positive statistics
    if tp_results:
        detected = sum(1 for r in tp_results if r["detected"])
        total = len(tp_results)
        rate = detected / total * 100 if total else 0

        print(f"\nDetection rate: {detected}/{total} ({rate:.1f}%)")
        print()

        # Classify by rules
        by_prefix = {}
        for r in tp_results:
            prefix = r["rule"].split("-")[0]
            by_prefix.setdefault(prefix, []).append(r)

        print(f"{'Category':<8} {'Detection':<6} {'Total number':<6} {'Detection rate':<8} {'Details'}")
        print("-" * 60)
        for prefix in sorted(by_prefix):
            items = by_prefix[prefix]
            det = sum(1 for r in items if r["detected"])
            tot = len(items)
            pct = det / tot * 100 if tot else 0
            missed = [r["rule"] for r in items if not r["detected"]]
            missed_str = f"  MISSED: {', '.join(missed)}" if missed else ""
            print(f"{prefix:<8} {det:<6} {tot:<6} {pct:>5.1f}%  {missed_str}")

        # Sort by severity
        print()
        by_sev = {}
        for r in tp_results:
            sev = r.get("severity", "unknown")
            by_sev.setdefault(sev, []).append(r)
        for sev in ["critical", "high", "medium", "low"]:
            if sev in by_sev:
                items = by_sev[sev]
                det = sum(1 for r in items if r["detected"])
                tot = len(items)
                pct = det / tot * 100 if tot else 0
                print(f"  {sev:<10} {det}/{tot} ({pct:.0f}%)")

        # Not checked out list
        missed_all = [r for r in tp_results if not r["detected"]]
        if missed_all:
            print(f"\nNo rules checked out ({len(missed_all)}):")
            for r in missed_all:
                print(f"  [{r['rule']}] {r['description']}")
                print(f" Claude replied: {r['response'][:200]}")

    # False positive statistics
    if fp_results:
        fp_count = sum(1 for r in fp_results if r["detected_fp"])
        fp_total = len(fp_results)
        fp_rate = fp_count / fp_total * 100 if fp_total else 0
        print(f"\nFalse alarm rate: {fp_count}/{fp_total} ({fp_rate:.1f}%)")
        if fp_count:
            for r in fp_results:
                if r["detected_fp"]:
                    print(f" False positive: {r['description']}")
                    print(f" Claude replied: {r['response'][:200]}")

    # SWS (Severity-Weighted Score)
    if tp_results:
        sev_weights = {"critical": 4, "high": 3, "medium": 2, "low": 1}
        weighted_sum = 0.0
        weight_total = 0.0
        for r in tp_results:
            w = sev_weights.get(r.get("severity", "medium"), 2)
            weight_total += w
            if r["detected"]:
                weighted_sum += w
        sws = weighted_sum / weight_total * 100 if weight_total else 0

        fpr = 0.0
        if fp_results:
            fpr = sum(1 for r in fp_results if r["detected_fp"]) / len(fp_results)
        fpr_penalty = max(0, 1 - fpr)

        layer2_score = sws * fpr_penalty
        print(f"\n[Layer 2 Score]")
        print(f"  SWS (Severity-Weighted): {sws:.1f}")
        print(f"  FPR penalty: ×{fpr_penalty:.2f}")
        print(f"  Layer2_Score: {layer2_score:.1f}")

    print_calibration(results)


def calibration_points(results: list[dict]) -> list[dict]:
    points = []
    for r in results:
        if r.get("skipped"):
            continue
        confidence = r.get("confidence")
        if confidence not in CONFIDENCE_SCORES:
            continue
        if "detected" in r:
            correct = bool(r["detected"])
            bucket = r.get("severity", "unknown")
        elif "detected_fp" in r:
            correct = not bool(r["detected_fp"])
            bucket = "clean"
        else:
            continue
        points.append({
            "bucket": bucket,
            "confidence": confidence,
            "score": CONFIDENCE_SCORES[confidence],
            "correct": correct,
        })
    return points


def compute_ece(points: list[dict]) -> float | None:
    if not points:
        return None
    total = len(points)
    by_conf: dict[str, list[dict]] = {}
    for point in points:
        by_conf.setdefault(point["confidence"], []).append(point)

    ece = 0.0
    for confidence, items in by_conf.items():
        avg_conf = CONFIDENCE_SCORES[confidence]
        accuracy = sum(1 for item in items if item["correct"]) / len(items)
        ece += (len(items) / total) * abs(accuracy - avg_conf)
    return ece


def print_calibration(results: list[dict]) -> None:
    points = calibration_points(results)
    ece = compute_ece(points)
    if ece is None:
        print("\n[Calibration]")
        print("  No calibrated samples (confidence missing or all samples skipped)")
        return

    print("\n[Calibration]")
    print(f"  Overall ECE: {ece * 100:.1f} ({len(points)} calibrated samples)")

    buckets = sorted({point["bucket"] for point in points})
    for bucket in buckets:
        bucket_points = [point for point in points if point["bucket"] == bucket]
        bucket_ece = compute_ece(bucket_points)
        if bucket_ece is None:
            continue
        accuracy = sum(1 for point in bucket_points if point["correct"]) / len(bucket_points)
        print(
            f"  {bucket:<10} ECE: {bucket_ece * 100:.1f} "
            f"accuracy: {accuracy * 100:.0f}% n={len(bucket_points)}"
        )


def main():
    parser = argparse.ArgumentParser(description="VibeGuard LLM-as-Judge Evaluation")
    parser.add_argument("--model", default="haiku", help="Model: haiku/sonnet/opus or full ID")
    parser.add_argument("--rules", help="Rule prefix filtering (such as SEC, PY, TS, GO, RS)")
    parser.add_argument("--type", choices=["tp", "fp"], help="Sample type filtering: tp=violation, fp=legal")
    parser.add_argument("--dry-run", action="store_true", help="Only display samples without adjusting API")
    parser.add_argument(
        "--dataset",
        default=str(DEFAULT_DATASET_PATH),
        help="Versioned JSONL dataset to evaluate",
    )
    parser.add_argument(
        "--artifact-root",
        default=str(DEFAULT_RUNS_DIR),
        help="Directory where immutable eval run artifacts are written",
    )
    parser.add_argument(
        "--rules-dir",
        default=str(DEFAULT_RULES_DIR),
        help="Rule directory to load (defaults to repository rules snapshot)",
    )
    parser.add_argument(
        "--core-rules-file",
        default=str(DEFAULT_CORE_RULES_FILE),
        help="Core constraint snippet file to append (defaults to repository snapshot)",
    )
    args = parser.parse_args()
    run_eval(args)


if __name__ == "__main__":
    main()
