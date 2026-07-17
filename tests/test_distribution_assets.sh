#!/usr/bin/env bash
# Focused regression tests for distribution asset lifecycle evidence.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="${REPO_DIR}/scripts/ci/validate_distribution_assets.py"
PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_fails_with() {
  local desc="$1" expected="$2"
  shift 2
  TOTAL=$((TOTAL + 1))
  local output
  if output="$("$@" 2>&1)"; then
    red "$desc (expected failure)"
    FAIL=$((FAIL + 1))
  elif grep -qF -- "$expected" <<< "$output"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected output to contain: $expected)"
    printf '%s\n' "$output"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_live_reference() {
  local needle="$1"
  ! git -C "$REPO_DIR" grep -F -- "$needle" -- \
    ':!docs/specs/**' \
    ':!tests/test_distribution_assets.sh'
}

new_fixture() {
  local name="$1"
  local root="${TMP_DIR}/${name}"
  mkdir -p "$root/schemas"
  printf '{"modules": []}\n' > "$root/schemas/install-modules.json"
  printf '{}\n' > "$root/skills-lock.json"
  printf '# Fixture contributing guide\n' > "$root/CONTRIBUTING.md"
  git -C "$root" init -q
  git -C "$root" add .
  printf '%s\n' "$root"
}

sgconfig_smoke() {
  local fixture="${TMP_DIR}/config_default.rs"
  printf '%s\n' \
    'struct AppConfig;' \
    'impl Default for AppConfig { fn default() -> Self { Self } }' \
    'fn main() { let _config = AppConfig::default(); }' > "$fixture"
  local output
  output="$(ast-grep scan --config "$REPO_DIR/sgconfig.yml" "$fixture" 2>&1)"
  grep -qF 'rs-14-config-default' <<< "$output"
}

production_ast_grep_uses_explicit_rules() {
  python3 - "$REPO_DIR" <<'PY'
from pathlib import Path
import re
import sys

repo = Path(sys.argv[1])
scans = 0
for path in sorted((repo / "guards").rglob("*.sh")):
    lines = path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        stripped = line.lstrip()
        if not re.match(r"(?:if\s+!?)?ast-grep\s+scan(?:\s|\\)", stripped):
            continue
        scans += 1
        if not any("--rule" in candidate for candidate in lines[index:index + 8]):
            relative = path.relative_to(repo)
            raise SystemExit(f"{relative}:{index + 1}: ast-grep scan lacks explicit --rule")
if scans == 0:
    raise SystemExit("no production ast-grep scan invocations found")
PY
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

assert_cmd "current distribution inventory is fully owned" python3 "$VALIDATOR" "$REPO_DIR"
assert_cmd "retired awk skill is absent" test ! -e "$REPO_DIR/skills/awk-posix-compat/SKILL.md"
assert_cmd "retired awk skill has no live references" assert_no_live_reference "skills/awk-posix-compat"
assert_cmd "retired alerting template is absent" test ! -e "$REPO_DIR/templates/alerting-rules.yaml"
assert_cmd "retired alerting template has no live references" assert_no_live_reference "templates/alerting-rules.yaml"
assert_cmd "ast-grep is available for the sgconfig smoke" command -v ast-grep
assert_cmd "sgconfig discovers the known RS-14 rule" sgconfig_smoke
assert_cmd "production ast-grep scans retain explicit rule files" production_ast_grep_uses_explicit_rules

architecture_fixture="${TMP_DIR}/architecture"
mkdir -p "$architecture_fixture"
cp "$REPO_DIR/templates/vibeguard-architecture.yaml" \
  "$architecture_fixture/.vibeguard-architecture.yaml"
assert_cmd "architecture template remains consumable by dependency guard" \
  python3 "$REPO_DIR/guards/universal/check_dependency_layers.py" "$architecture_fixture"

unknown_skill_fixture="$(new_fixture unknown-skill)"
mkdir -p "$unknown_skill_fixture/skills/orphan"
printf '%s\n' '---' 'name: orphan' '---' '# orphan' > \
  "$unknown_skill_fixture/skills/orphan/SKILL.md"
git -C "$unknown_skill_fixture" add .
assert_fails_with "unknown skill fails" \
  "unowned distribution asset: skills/orphan/SKILL.md" \
  python3 "$VALIDATOR" "$unknown_skill_fixture"

unknown_template_fixture="$(new_fixture unknown-template)"
mkdir -p "$unknown_template_fixture/templates"
printf '# orphan template\n' > "$unknown_template_fixture/templates/orphan.yaml"
git -C "$unknown_template_fixture" add .
assert_fails_with "unknown template fails" \
  "unowned distribution asset: templates/orphan.yaml" \
  python3 "$VALIDATOR" "$unknown_template_fixture"

unknown_config_fixture="$(new_fixture unknown-config)"
printf 'enabled: true\n' > "$unknown_config_fixture/orphan.yml"
git -C "$unknown_config_fixture" add .
assert_fails_with "unknown root config fails" \
  "unowned distribution asset: orphan.yml" \
  python3 "$VALIDATOR" "$unknown_config_fixture"

false_evidence_fixture="$(new_fixture false-evidence)"
mkdir -p \
  "$false_evidence_fixture/templates" \
  "$false_evidence_fixture/docs/specs/GH1" \
  "$false_evidence_fixture/plan" \
  "$false_evidence_fixture/tests" \
  "$false_evidence_fixture/scripts/ci" \
  "$false_evidence_fixture/scripts/runtime"
printf '# self reference: templates/orphan.yaml\n' > \
  "$false_evidence_fixture/templates/orphan.yaml"
printf '%s\n' '`templates/orphan.yaml`' > \
  "$false_evidence_fixture/docs/specs/GH1/product.md"
printf '%s\n' '`templates/orphan.yaml`' > "$false_evidence_fixture/plan/history.md"
printf '%s\n' '`templates/orphan.yaml`' > "$false_evidence_fixture/tests/test_orphan.sh"
printf '%s\n' 'This page merely mentions templates/orphan.yaml.' > \
  "$false_evidence_fixture/README.md"
printf '%s\n' 'This operational-directory page mentions templates/orphan.yaml.' > \
  "$false_evidence_fixture/scripts/README.md"
printf '%s\n' '# templates/orphan.yaml is only a source comment' > \
  "$false_evidence_fixture/scripts/runtime/comment.py"
printf '%s\n' '"""templates/orphan.yaml is only a module docstring."""' > \
  "$false_evidence_fixture/scripts/runtime/docstring.py"
printf '%s\n' '`templates/orphan.yaml`' > \
  "$false_evidence_fixture/scripts/ci/validate_distribution_assets.py"
printf '%s\n' 'Manual assets: `templates/*` and `orphan.yaml`.' > \
  "$false_evidence_fixture/CONTRIBUTING.md"
git -C "$false_evidence_fixture" add .
assert_fails_with "self/spec/plan/test/validator/doc/docstring/comment evidence fails" \
  "unowned distribution asset: templates/orphan.yaml" \
  python3 "$VALIDATOR" "$false_evidence_fixture"

positive_fixture="$(new_fixture positive)"
mkdir -p \
  "$positive_fixture/skills/installed" \
  "$positive_fixture/skills/locked" \
  "$positive_fixture/templates" \
  "$positive_fixture/guards/universal" \
  "$positive_fixture/tools"
printf '# installed\n' > "$positive_fixture/skills/installed/SKILL.md"
printf '# locked\n' > "$positive_fixture/skills/locked/SKILL.md"
printf 'layers: []\n' > "$positive_fixture/templates/vibeguard-architecture.yaml"
printf 'ruleDirs: []\n' > "$positive_fixture/sgconfig.yml"
printf '{"modules": [{"paths": ["skills/installed/"]}]}\n' > \
  "$positive_fixture/schemas/install-modules.json"
printf '{"skills/locked/SKILL.md": {}}\n' > "$positive_fixture/skills-lock.json"
printf '%s\n' 'Path("templates/vibeguard-architecture.yaml").read_text()' > \
  "$positive_fixture/guards/universal/check_dependency_layers.py"
printf '%s\n' 'skills-lock.json' > "$positive_fixture/tools/install.py"
printf '%s\n' 'Manual config: `sgconfig.yml`.' > "$positive_fixture/CONTRIBUTING.md"
git -C "$positive_fixture" add .
assert_cmd "install, lock, consumer, and exact manual evidence pass" \
  python3 "$VALIDATOR" "$positive_fixture"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
