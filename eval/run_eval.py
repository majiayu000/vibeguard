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
import json
import os
import sys
import time
from pathlib import Path

from samples import SAMPLES

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
        content = rule_file.read_text()
        if content.startswith("---"):
            parts = content.split("---", 2)
            if len(parts) >= 3:
                content = parts[2].strip()
        rules_text.append(f"# {rule_file.stem}\n\n{content}")

    if core_rules_file and core_rules_file.exists():
        claude_md = core_rules_file.read_text()
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
2. List each violation in the format [RULE_ID]: Problem description
3. If there are no code violations, reply [CLEAN]
4. Don't suggest improvements - only report violations"""


def evaluate_sample(
    client,
    model: str,
    system_prompt: str,
    sample: dict,
) -> dict:
    """Run evaluation on a single sample"""
    user_msg = f"Review the following {sample['lang']} code and list all violating rules:\n\n```{sample['lang']}\n{sample['code'].strip()}\n````"

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
            "rule": sample["rule"],
            "detected": False,
            "error": str(e),
            "response": "",
        }

    expected_rule = sample["rule"]
    is_clean = expected_rule == "NONE"

    if is_clean:
        # False positive detection: clean code should not trigger any rules
        has_false_positive = "[CLEAN]" not in reply and any(
            f"[{r}]" in reply or f"{r}:" in reply or f"{r}]" in reply
            for r in _all_rule_ids()
        )
        return {
            "rule": "FP-CHECK",
            "expected": "CLEAN",
            "detected_fp": has_false_positive,
            "response": reply[:500],
            "description": sample["description"],
        }

    # Check if the rule is mentioned
    detected = (
        f"[{expected_rule}]" in reply
        or f"{expected_rule}:" in reply
        or f"{expected_rule}]" in reply
        or expected_rule.lower() in reply.lower()
    )

    return {
        "rule": expected_rule,
        "severity": sample["severity"],
        "detected": detected,
        "response": reply[:500],
        "description": sample["description"],
    }


def _all_rule_ids() -> list[str]:
    prefixes = ["SEC", "PY", "TS", "GO", "RS", "U", "W", "L", "TASTE"]
    ids = []
    for p in prefixes:
        for i in range(1, 30):
            ids.append(f"{p}-{i:02d}")
            ids.append(f"{p}-{i}")
    return ids


def run_eval(args):
    rules_dir = Path(args.rules_dir).resolve()
    core_rules_file = Path(args.core_rules_file).resolve() if args.core_rules_file else None
    rules = load_rules(rules_dir, core_rules_file)
    system_prompt = build_system_prompt(rules)

    if args.dry_run:
        print(f"Rule text length: {len(rules)} characters")
        print(f"Number of samples: {len(SAMPLES)}")
        print(f"Rules source: {rules_dir}")
        if core_rules_file:
            print(f"Core constraint source: {core_rules_file}")
        print(f"\nSample list:")
        for s in SAMPLES:
            tag = "FP" if s["rule"] == "NONE" else s["rule"]
            print(f"  [{tag}] {s['description']}")
        return

    # Filter samples
    samples = SAMPLES
    if args.rules:
        prefix = args.rules.upper()
        samples = [
            s
            for s in SAMPLES
            if s["rule"].startswith(prefix) or s["rule"] == "NONE"
        ]
        print(f"Number of samples after filtering: {len(samples)} (prefix: {prefix})")
    if args.type:
        if args.type == "tp":
            samples = [s for s in samples if s["rule"] != "NONE"]
        elif args.type == "fp":
            samples = [s for s in samples if s["rule"] == "NONE"]
        print(f"Number of samples after type filtering: {len(samples)} (Type: {args.type})")

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
    print("=" * 60)

    results = []
    for i, sample in enumerate(samples):
        tag = "FP" if sample["rule"] == "NONE" else sample["rule"]
        print(f"[{i + 1}/{len(samples)}] {tag}: {sample['description']}...", end=" ", flush=True)

        result = evaluate_sample(client, model, system_prompt, sample)
        results.append(result)

        if result.get("error"):
            print(f"ERROR: {result['error']}")
        elif "detected_fp" in result:
            status = "FALSE POSITIVE" if result["detected_fp"] else "CLEAN OK"
            print(status)
        else:
            status = "DETECTED" if result["detected"] else "MISSED"
            print(status)

        # Avoid rate limiting
        time.sleep(0.5)

    print_report(results, model)

    # Save results
    output_path = Path(__file__).parent / "results.json"
    with open(output_path, "w") as f:
        json.dump(
            {"model": model, "timestamp": time.strftime("%Y-%m-%d %H:%M"), "results": results},
            f,
            indent=2,
            ensure_ascii=False,
        )
    print(f"\nResult saved: {output_path}")


def print_report(results: list[dict], model: str):
    print("\n" + "=" * 60)
    print(f"VibeGuard LLM-as-Judge Report ({model})")
    print("=" * 60)

    # Separate true positive tests and false positive tests
    tp_results = [r for r in results if "detected" in r]
    fp_results = [r for r in results if "detected_fp" in r]

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


def main():
    parser = argparse.ArgumentParser(description="VibeGuard LLM-as-Judge Evaluation")
    parser.add_argument("--model", default="haiku", help="Model: haiku/sonnet/opus or full ID")
    parser.add_argument("--rules", help="Rule prefix filtering (such as SEC, PY, TS, GO, RS)")
    parser.add_argument("--type", choices=["tp", "fp"], help="Sample type filtering: tp=violation, fp=legal")
    parser.add_argument("--dry-run", action="store_true", help="Only display samples without adjusting API")
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
