#!/usr/bin/env bash
# Regression tests for the archived specs-index policy.

set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
validator="$repo_dir/scripts/ci/validate-specs-index.sh"
tmp_dir="$(mktemp -d)"
pass=0
fail=0
total=0

cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red() { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_exit() {
  local description="$1" expected="$2"
  shift 2
  local actual=0
  total=$((total + 1))
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    green "$description"
    pass=$((pass + 1))
  else
    red "$description (expected $expected, got $actual)"
    fail=$((fail + 1))
  fi
}

assert_stderr_contains() {
  local description="$1" expected="$2"
  shift 2
  local output
  total=$((total + 1))
  output="$("$@" 2>&1 >/dev/null || true)"
  if [[ "$output" == *"$expected"* ]]; then
    green "$description"
    pass=$((pass + 1))
  else
    red "$description (missing: $expected)"
    fail=$((fail + 1))
  fi
}

make_fixture() {
  local name="$1"
  local fixture="$tmp_dir/$name"
  mkdir -p "$fixture"
  printf '%s' "$fixture"
}

write_valid_index() {
  local destination="$1"
  printf '%s\n' \
    '# Specs' \
    '' \
    '## Archived GitHub Packet Index' \
    '' \
    '| Issue | Outcome |' \
    '|---|---|' \
    '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Fixture outcome |' \
    > "$destination/README.md"
  printf '%s\n' 'GH100' > "$destination/archived-issues.txt"
}

printf '\n=== specs-index archive policy ===\n'

valid="$(make_fixture valid)"
write_valid_index "$valid"
assert_exit "archive index without packet directories passes" 0 bash "$validator" "$valid"

restored="$(make_fixture restored)"
write_valid_index "$restored"
mkdir -p "$restored/GH100"
assert_exit "restored packet directory fails" 1 bash "$validator" "$restored"
assert_stderr_contains "restored packet failure names path" "docs/specs/GH100" bash "$validator" "$restored"

symlinked="$(make_fixture symlinked)"
write_valid_index "$symlinked"
mkdir -p "$symlinked/packet-content"
ln -s packet-content "$symlinked/GH100"
assert_exit "symlinked packet path fails" 1 bash "$validator" "$symlinked"
assert_stderr_contains "symlinked packet failure names path" "docs/specs/GH100" bash "$validator" "$symlinked"

legacy="$(make_fixture legacy)"
write_valid_index "$legacy"
printf '%s\n' '| `GH101/` | Implemented reference | Legacy path row |' >> "$legacy/README.md"
assert_exit "legacy live-directory row fails" 1 bash "$validator" "$legacy"
assert_stderr_contains "legacy row explains issue-link format" "must be issue links" bash "$validator" "$legacy"

duplicate="$(make_fixture duplicate)"
write_valid_index "$duplicate"
printf '%s\n' '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Duplicate |' >> "$duplicate/README.md"
assert_exit "duplicate issue row fails" 1 bash "$validator" "$duplicate"
assert_stderr_contains "duplicate failure names issue" "GH100" bash "$validator" "$duplicate"

mismatch="$(make_fixture mismatch)"
write_valid_index "$mismatch"
printf '%s\n' '| [GH101](https://github.com/majiayu000/vibeguard/issues/102) | Mismatch |' >> "$mismatch/README.md"
assert_exit "issue label and URL mismatch fails" 1 bash "$validator" "$mismatch"
assert_stderr_contains "mismatch failure is explicit" "label/URL mismatch" bash "$validator" "$mismatch"

incomplete="$(make_fixture incomplete)"
write_valid_index "$incomplete"
printf '%s\n' 'GH100' 'GH101' > "$incomplete/archived-issues.txt"
assert_exit "archive inventory requires every index row" 1 bash "$validator" "$incomplete"
assert_stderr_contains "incomplete index names omitted issue" "missing index rows: GH101" bash "$validator" "$incomplete"

scoped="$(make_fixture scoped)"
write_valid_index "$scoped"
printf '%s\n' '## Example Elsewhere' '| [GH999](not-an-issue-link) | Example only |' >> "$scoped/README.md"
assert_exit "GH-like rows outside archive section are ignored" 0 bash "$validator" "$scoped"

h1_boundary="$(make_fixture h1-boundary)"
write_valid_index "$h1_boundary"
printf '%s\n' 'GH100' 'GH101' > "$h1_boundary/archived-issues.txt"
printf '%s\n' '# New Document Section' '| [GH101](https://github.com/majiayu000/vibeguard/issues/101) | Outside |' >> "$h1_boundary/README.md"
assert_exit "visible H1 terminates archive section" 1 bash "$validator" "$h1_boundary"
assert_stderr_contains "H1 boundary keeps outside row out" "missing index rows: GH101" bash "$validator" "$h1_boundary"

fenced_heading="$(make_fixture fenced-heading)"
printf '%s\n' '```markdown' '## Archived GitHub Packet Index' '```' > "$fenced_heading/README.md"
printf '%s\n' 'GH100' > "$fenced_heading/archived-issues.txt"
assert_exit "archive heading inside code fence is ignored" 1 bash "$validator" "$fenced_heading"
assert_stderr_contains "fenced heading failure requires visible section" "expected exactly one visible" bash "$validator" "$fenced_heading"

commented_heading="$(make_fixture commented-heading)"
printf '%s\n' \
  '# Specs' \
  '<!--' \
  '## Archived GitHub Packet Index' \
  '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Hidden |' \
  '-->' \
  > "$commented_heading/README.md"
printf '%s\n' 'GH100' > "$commented_heading/archived-issues.txt"
assert_exit "archive section inside HTML comment is ignored" 1 bash "$validator" "$commented_heading"
assert_stderr_contains "commented heading failure requires visible section" "expected exactly one visible" bash "$validator" "$commented_heading"

fake_closer="$(make_fixture fake-closer)"
printf '%s\n' \
  '# Specs' \
  '```markdown' \
  '``` trailing text is not a closing fence' \
  '## Archived GitHub Packet Index' \
  '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Fenced |' \
  > "$fake_closer/README.md"
printf '%s\n' 'GH100' > "$fake_closer/archived-issues.txt"
assert_exit "fence-like line with trailing text does not close fence" 1 bash "$validator" "$fake_closer"
assert_stderr_contains "fake closer keeps heading fenced" "expected exactly one visible" bash "$validator" "$fake_closer"

missing_section="$(make_fixture missing-section)"
printf '%s\n' '# Specs' > "$missing_section/README.md"
printf '%s\n' 'GH100' > "$missing_section/archived-issues.txt"
assert_exit "missing archive section fails" 1 bash "$validator" "$missing_section"

missing_readme="$(make_fixture missing-readme)"
assert_exit "missing index fails" 1 bash "$validator" "$missing_readme"

assert_exit "live specs index passes" 0 bash "$validator"

printf '\n%d/%d passed\n' "$pass" "$total"
[[ "$fail" -eq 0 ]]
