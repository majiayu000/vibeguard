#!/usr/bin/env bash
# VibeGuard document freshness detection
#
# Cross-compare rule IDs defined in rules/claude-rules/ and IDs implemented by guards/hooks.
# Output: Unimplemented rules (with rules and no guards) and undocumented guards (with guards and no rules).
#
# Usage:
# bash doc-freshness-check.sh #Default check
# bash doc-freshness-check.sh --strict # >10% inconsistency returns exit code 1

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STRICT=false

for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
  esac
done

RULES_DIR="${REPO_DIR}/rules/claude-rules"
GUARDS_DIR="${REPO_DIR}/guards"
NATIVE_RULES_DIR="${HOME}/.claude/rules/vibeguard"

if [[ ! -d "$RULES_DIR" ]]; then
  echo "The canonical rules directory does not exist: ${RULES_DIR}"
  exit 1
fi

if [[ ! -d "$GUARDS_DIR" ]]; then
  echo "Guards directory does not exist: ${GUARDS_DIR}"
  exit 1
fi

VG_RULES_DIR="$RULES_DIR" VG_GUARDS_DIR="$GUARDS_DIR" VG_NATIVE_RULES_DIR="$NATIVE_RULES_DIR" \
  VG_STRICT="$STRICT" python3 -c '
import os, re, sys, glob

rules_dir = os.environ["VG_RULES_DIR"]
guards_dir = os.environ["VG_GUARDS_DIR"]
native_rules_dir = os.environ.get("VG_NATIVE_RULES_DIR", "")
strict = os.environ.get("VG_STRICT", "false") == "true"

id_pattern = re.compile(r"\b(RS|GO|TS|PY|U|SEC)-(\d+)\b")

# Extract the rule ID and its description from the rules file
rule_ids = {}  # id -> (file, description)
for md_file in sorted(glob.glob(os.path.join(rules_dir, "**/*.md"), recursive=True)):
    basename = os.path.relpath(md_file, rules_dir)
    try:
        with open(md_file, encoding="utf-8") as f:
            for line in f:
                for m in id_pattern.finditer(line):
                    rule_id = m.group()
                    if rule_id not in rule_ids:
                        # Get a brief description of the row content
                        desc = line.strip()[:80]
                        rule_ids[rule_id] = (basename, desc)
    except (UnicodeDecodeError, PermissionError):
        continue

# Extract the implemented rule ID from the guard script
guard_ids = {}  # id -> set(files)
for guard_file in sorted(glob.glob(os.path.join(guards_dir, "**/*"), recursive=True)):
    if not os.path.isfile(guard_file):
        continue
    try:
        with open(guard_file, encoding="utf-8") as f:
            content = f.read()
    except (UnicodeDecodeError, PermissionError):
        continue
    rel_path = os.path.relpath(guard_file, guards_dir)
    for m in id_pattern.finditer(content):
        gid = m.group()
        guard_ids.setdefault(gid, set()).add(rel_path)

# Also scan from the hooks directory (some rules are also implemented in hooks)
hooks_dir = os.path.join(os.path.dirname(guards_dir), "hooks")
if os.path.isdir(hooks_dir):
    for hook_file in sorted(glob.glob(os.path.join(hooks_dir, "*.sh"))):
        try:
            with open(hook_file, encoding="utf-8") as f:
                content = f.read()
        except (UnicodeDecodeError, PermissionError):
            continue
        rel_path = "hooks/" + os.path.basename(hook_file)
        for m in id_pattern.finditer(content):
            gid = m.group()
            guard_ids.setdefault(gid, set()).add(rel_path)

# AI visible rules: Prioritize ~/.claude/rules/vibeguard/, fall back to repo rules/ if missing (CI friendly)
ai_visible_ids = {}  # id -> set(files)
if native_rules_dir and os.path.isdir(native_rules_dir):
    ai_rules_dir = native_rules_dir
    ai_source_label = "~/.claude/rules/"
    ai_fallback_used = False
else:
    ai_rules_dir = rules_dir
    ai_source_label = "repo/rules (fallback)"
    ai_fallback_used = True

for nr_file in sorted(glob.glob(os.path.join(ai_rules_dir, "**/*.md"), recursive=True)):
    try:
        with open(nr_file, encoding="utf-8") as f:
            content = f.read()
    except (UnicodeDecodeError, PermissionError):
        continue
    rel_path = os.path.relpath(nr_file, ai_rules_dir)
    for m in id_pattern.finditer(content):
        aid = m.group()
        ai_visible_ids.setdefault(aid, set()).add(rel_path)

# Calculate the gap
rule_set = set(rule_ids.keys())
guard_set = set(guard_ids.keys())
ai_set = set(ai_visible_ids.keys())

implemented = sorted(rule_set & guard_set)
ai_visible = sorted(rule_set & ai_set)
dual_covered = sorted(rule_set & guard_set & ai_set)
all_covered = sorted(rule_set & (guard_set | ai_set))
unimplemented = sorted(rule_set - guard_set)
not_ai_visible = sorted(rule_set - ai_set)
fully_uncovered = sorted(rule_set - guard_set - ai_set)
undocumented = sorted(guard_set - rule_set)

total_rules = len(rule_ids)
gap_count = len(fully_uncovered) + len(undocumented)
gap_rate = (gap_count / total_rules * 100) if total_rules > 0 else 0

# Output report
print(f"""
VibeGuard Document Freshness Report
{"=" * 40}
Rule source: {rules_dir}
Total number of rules: {total_rules}
Comprehensive coverage: {len(all_covered)} ({len(all_covered)/total_rules*100:.0f}%)
  Mechanical enforcement: {len(implemented)} (guards/hooks)
  AI visible: {len(ai_visible)} ({ai_source_label})
  Double coverage: {len(dual_covered)}
Fully uncovered: {len(fully_uncovered)}
Undocumented guard: {len(undocumented)}
Inconsistency rate: {gap_rate:.1f}%
""")

if ai_fallback_used:
    print(f"NOTE: native rules dir does not exist and has fallen back to {rules_dir}")
    print()

def print_by_prefix(ids, label):
    if not ids:
        return
    print(f"{label}:")
    by_prefix = {}
    for rid in ids:
        prefix = rid.split("-")[0]
        by_prefix.setdefault(prefix, []).append(rid)
    for prefix in sorted(by_prefix.keys()):
        ids_str = ", ".join(by_prefix[prefix])
        print(f"  {prefix}: {ids_str}")
    print()

dual_set = set(dual_covered)
print_by_prefix(dual_covered, "Double coverage (guard + AI visible)")
print_by_prefix([r for r in implemented if r not in dual_set], "Only mechanical forcing (guards/hooks)")
print_by_prefix([r for r in ai_visible if r not in dual_set], f"Only AI visible ({ai_source_label})")

if fully_uncovered:
    print("Completely uncovered rules:")
    for rid in fully_uncovered:
        if rid in rule_ids:
            src_file, desc = rule_ids[rid]
            print(f"  {rid} ({src_file})")
    print()

if undocumented:
    print("Undocumented guard (referenced in guard, no rule definition):")
    for gid in undocumented:
        files = sorted(guard_ids[gid])
        files_str = ", ".join(files)
        print(f"  {gid} → {files_str}")
    print()

# Judgment
if gap_rate > 20:
    print("FAIL: Inconsistency rate > 20%, it is recommended to complete it immediately")
    status = 2
elif gap_rate > 10:
    print("WARN: Inconsistency rate > 10%, it is recommended to arrange for completion")
    status = 1
else:
    print("PASS: Rule-Guard Consistency Good")
    status = 0

if strict and status > 0:
    sys.exit(1)
'
