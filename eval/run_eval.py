#!/usr/bin/env python3
"""
VibeGuard LLM-as-Judge 评估

用 Claude API 测试 VibeGuard 规则的实际检出率。
测量的是 "Claude + 规则" 的真实组合效果。

用法:
    uv run python eval/run_eval.py                    # 跑全部样本
    uv run python eval/run_eval.py --rules SEC        # 只跑安全规则
    uv run python eval/run_eval.py --model haiku      # 用便宜模型
    uv run python eval/run_eval.py --dry-run          # 只看样本不调 API
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

try:
    import anthropic
except ImportError:
    print("需要 anthropic SDK: uv pip install anthropic")
    sys.exit(1)

from samples import SAMPLES

MODELS = {
    "haiku": "claude-haiku-4-5-20251001",
    "sonnet": "claude-sonnet-4-6",
    "opus": "claude-opus-4-6",
}

RULES_DIR = Path.home() / ".claude" / "rules" / "vibeguard"
CLAUDE_MD = Path.home() / ".claude" / "CLAUDE.md"


def load_rules() -> str:
    """从实际规则文件加载所有 VibeGuard 规则"""
    rules_text = []

    # 加载语言规则
    for rule_file in sorted(RULES_DIR.rglob("*.md")):
        content = rule_file.read_text()
        # 去掉 frontmatter
        if content.startswith("---"):
            parts = content.split("---", 2)
            if len(parts) >= 3:
                content = parts[2].strip()
        rules_text.append(f"# {rule_file.stem}\n\n{content}")

    # 从 CLAUDE.md 提取 VibeGuard 相关部分
    if CLAUDE_MD.exists():
        claude_md = CLAUDE_MD.read_text()
        # 提取 vibeguard 段落
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

    return "\n\n---\n\n".join(rules_text)


def build_system_prompt(rules: str) -> str:
    return f"""你是一个代码审查助手。你已加载以下代码质量规则：

{rules}

当用户给你代码时，你必须：
1. 逐条检查所有适用规则
2. 列出每个违规，格式为 [RULE_ID]: 问题描述
3. 如果代码没有违规，回复 [CLEAN]
4. 不要建议改进——只报告违规"""


def evaluate_sample(
    client: anthropic.Anthropic,
    model: str,
    system_prompt: str,
    sample: dict,
) -> dict:
    """对单个样本运行评估"""
    user_msg = f"审查以下 {sample['lang']} 代码，列出所有违规规则：\n\n```{sample['lang']}\n{sample['code'].strip()}\n```"

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
        # 误报检测：干净代码不应触发任何规则
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

    # 检测规则是否被提及
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
    rules = load_rules()
    system_prompt = build_system_prompt(rules)

    if args.dry_run:
        print(f"规则文本长度: {len(rules)} 字符")
        print(f"样本数: {len(SAMPLES)}")
        print(f"\n样本列表:")
        for s in SAMPLES:
            tag = "FP" if s["rule"] == "NONE" else s["rule"]
            print(f"  [{tag}] {s['description']}")
        return

    # 过滤样本
    samples = SAMPLES
    if args.rules:
        prefix = args.rules.upper()
        samples = [
            s
            for s in SAMPLES
            if s["rule"].startswith(prefix) or s["rule"] == "NONE"
        ]
        print(f"过滤后样本数: {len(samples)} (前缀: {prefix})")

    model = MODELS.get(args.model, args.model)
    client = anthropic.Anthropic()

    print(f"模型: {model}")
    print(f"样本数: {len(samples)}")
    print(f"规则文本: {len(rules)} 字符")
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

        # 避免速率限制
        time.sleep(0.5)

    print_report(results, model)

    # 保存结果
    output_path = Path(__file__).parent / "results.json"
    with open(output_path, "w") as f:
        json.dump(
            {"model": model, "timestamp": time.strftime("%Y-%m-%d %H:%M"), "results": results},
            f,
            indent=2,
            ensure_ascii=False,
        )
    print(f"\n结果已保存: {output_path}")


def print_report(results: list[dict], model: str):
    print("\n" + "=" * 60)
    print(f"VibeGuard LLM-as-Judge 报告 ({model})")
    print("=" * 60)

    # 分离真阳性测试和误报测试
    tp_results = [r for r in results if "detected" in r]
    fp_results = [r for r in results if "detected_fp" in r]

    # 真阳性统计
    if tp_results:
        detected = sum(1 for r in tp_results if r["detected"])
        total = len(tp_results)
        rate = detected / total * 100 if total else 0

        print(f"\n检测率: {detected}/{total} ({rate:.1f}%)")
        print()

        # 按规则分类
        by_prefix = {}
        for r in tp_results:
            prefix = r["rule"].split("-")[0]
            by_prefix.setdefault(prefix, []).append(r)

        print(f"{'类别':<8} {'检出':<6} {'总数':<6} {'检出率':<8} {'详情'}")
        print("-" * 60)
        for prefix in sorted(by_prefix):
            items = by_prefix[prefix]
            det = sum(1 for r in items if r["detected"])
            tot = len(items)
            pct = det / tot * 100 if tot else 0
            missed = [r["rule"] for r in items if not r["detected"]]
            missed_str = f"  MISSED: {', '.join(missed)}" if missed else ""
            print(f"{prefix:<8} {det:<6} {tot:<6} {pct:>5.1f}%  {missed_str}")

        # 按严重程度
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

        # 未检出列表
        missed_all = [r for r in tp_results if not r["detected"]]
        if missed_all:
            print(f"\n未检出规则 ({len(missed_all)}):")
            for r in missed_all:
                print(f"  [{r['rule']}] {r['description']}")
                print(f"    Claude 回复: {r['response'][:200]}")

    # 误报统计
    if fp_results:
        fp_count = sum(1 for r in fp_results if r["detected_fp"])
        fp_total = len(fp_results)
        fp_rate = fp_count / fp_total * 100 if fp_total else 0
        print(f"\n误报率: {fp_count}/{fp_total} ({fp_rate:.1f}%)")
        if fp_count:
            for r in fp_results:
                if r["detected_fp"]:
                    print(f"  误报: {r['description']}")
                    print(f"    Claude 回复: {r['response'][:200]}")


def main():
    parser = argparse.ArgumentParser(description="VibeGuard LLM-as-Judge 评估")
    parser.add_argument("--model", default="haiku", help="模型: haiku/sonnet/opus 或完整 ID")
    parser.add_argument("--rules", help="规则前缀过滤 (如 SEC, PY, TS, GO, RS)")
    parser.add_argument("--dry-run", action="store_true", help="只显示样本不调 API")
    args = parser.parse_args()
    run_eval(args)


if __name__ == "__main__":
    main()
