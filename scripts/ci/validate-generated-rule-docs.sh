#!/usr/bin/env bash
# Ensure generated rule summary docs match the canonical rule source.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

cd "$REPO_DIR"
python3 scripts/generate_rule_docs.py --check

expected_l1='| L1 | Search before create | `pre-write-guard.sh` hook (warn by default; block via `VIBEGUARD_WRITE_MODE=block` / `write_mode=block` or escalation) |'
if ! grep -Fq "${expected_l1}" docs/rule-reference.md; then
  echo "docs/rule-reference.md must describe L1 as warn-by-default with explicit block modes" >&2
  exit 1
fi

expected_l7='| L7 | Commit discipline | Agent/review contract + `pre-commit-guard.sh` quality/build gate + git `pre-push` remote-history gate |'
if ! grep -Fq "${expected_l7}" docs/rule-reference.md; then
  echo "docs/rule-reference.md must describe L7 as mixed agent/review, pre-commit, and pre-push coverage" >&2
  exit 1
fi

expected_strict='| Strict | Non-negotiable agent/reviewer rule. If enforcement is not mechanical, violations still need a fix, explicit DEFER, or documented downgrade path. |'
if ! grep -Fq "${expected_strict}" docs/rule-reference.md; then
  echo "docs/rule-reference.md must define Strict as an agent/reviewer contract, not automatic hook blocking" >&2
  exit 1
fi

expected_guideline='| Guideline | Preferred pattern; follow when it helps the current task without expanding scope. |'
if ! grep -Fq "${expected_guideline}" docs/rule-reference.md; then
  echo "docs/rule-reference.md must define Guideline as a preferred pattern, not a required block" >&2
  exit 1
fi

expected_linter_boundary='These rules do not replace native linters. Treat lint-equivalent entries as agent reminders and review triage; use the verification command below for mechanical enforcement.'
for generated_language_doc in rules/python.md rules/typescript.md rules/go.md rules/rust.md; do
  if ! grep -Fq "${expected_linter_boundary}" "${generated_language_doc}"; then
    echo "${generated_language_doc} must state the lint-vs-agent boundary" >&2
    exit 1
  fi
done

expected_u08='| U-08 | Do not skip verification steps | Strict | See W-03 and W-16 for canonical verification guidance. |'
if ! grep -Fq "${expected_u08}" docs/rule-reference.md; then
  echo "docs/rule-reference.md must keep U-08 as a pointer to canonical W-03/W-16 guidance" >&2
  exit 1
fi

expected_u17='| U-17 | Handle errors completely | Strict | See U-29 for canonical error-handling guidance. |'
if ! grep -Fq "${expected_u17}" docs/rule-reference.md; then
  echo "docs/rule-reference.md must keep U-17 as a pointer to canonical U-29 guidance" >&2
  exit 1
fi

expected_u23='| U-23 | No silent degradation | Strict | See U-29 for canonical no-silent-degradation guidance. |'
if ! grep -Fq "${expected_u23}" docs/rule-reference.md; then
  echo "docs/rule-reference.md must keep U-23 as a pointer to canonical U-29 guidance" >&2
  exit 1
fi
