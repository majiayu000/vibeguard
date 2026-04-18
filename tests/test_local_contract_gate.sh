#!/usr/bin/env bash
# Tests for scripts/local-contract-check.sh and scripts/install-pre-commit-hook.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF "$unexpected"; then
    red "$desc (expected NOT to contain: $unexpected)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

assert_exit() {
  local expected="$1" actual="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq "$expected" ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected exit $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
header "local-contract-check.sh: --quick flag skips doc-freshness"

OUT=$(bash scripts/local-contract-check.sh --quick 2>&1 || true)
assert_contains "$OUT" "SKIP (--quick): doc-freshness" "--quick skips freshness label"
assert_not_contains "$OUT" "SKIP (not found): doc-freshness" "--quick does not emit 'not found' for freshness"

# ---------------------------------------------------------------------------
header "local-contract-check.sh: doc-freshness run_check uses file path only (not path+args)"

# The script at scripts/verify/doc-freshness-check.sh should be checked with -f
# against just the script path, not the path+' --strict' string.
# We verify by ensuring the output is either RUN/PASS/FAIL/SKIP(not found) — never
# a false SKIP that contains '--strict' as part of the filename message.
OUT=$(bash scripts/local-contract-check.sh 2>&1 || true)
assert_not_contains "$OUT" "SKIP (not found): doc-freshness (--strict)" \
  "doc-freshness is not skipped due to path+args being treated as filename"

# ---------------------------------------------------------------------------
header "local-contract-check.sh: unknown flag exits 2"

set +e
bash scripts/local-contract-check.sh --bogus-flag > /dev/null 2>&1
RC=$?
set -e
assert_exit 2 "$RC" "unknown flag exits with code 2"

# ---------------------------------------------------------------------------
header "install-pre-commit-hook.sh: uses git rev-parse --git-path hooks (not hardcoded .git/hooks)"

# Verify the script text does not hardcode .git/hooks
SCRIPT_CONTENT="$(cat scripts/install-pre-commit-hook.sh)"
TOTAL=$((TOTAL + 1))
if echo "$SCRIPT_CONTENT" | grep -qF 'git rev-parse --git-path hooks'; then
  green "installer uses git rev-parse --git-path hooks"
  PASS=$((PASS + 1))
else
  red "installer does NOT use git rev-parse --git-path hooks"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if echo "$SCRIPT_CONTENT" | grep -qF '\.git/hooks'; then
  red "installer still hardcodes .git/hooks path"
  FAIL=$((FAIL + 1))
else
  green "installer does not hardcode .git/hooks"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
header "install-pre-commit-hook.sh: chains to existing hook rather than overwriting"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Set up a minimal fake git repo so install script has a valid git context
FAKE_REPO="$TMPDIR_TEST/repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q
# git init always creates .git/hooks; compute absolute path directly
FAKE_HOOKS="$FAKE_REPO/.git/hooks"

# Install an existing hook that simulates pre-commit-guard.sh
EXISTING_HOOK="$FAKE_HOOKS/pre-commit"
cat > "$EXISTING_HOOK" <<'HOOK'
#!/usr/bin/env bash
echo "existing-guard-ran"
HOOK
chmod +x "$EXISTING_HOOK"

# Run the installer from inside the fake repo
OUT=$(cd "$FAKE_REPO" && bash "$REPO_DIR/scripts/install-pre-commit-hook.sh" 2>&1 || true)

# The original hook should NOT have been replaced — check content still has existing-guard-ran
HOOK_CONTENT="$(cat "$EXISTING_HOOK")"
assert_contains "$HOOK_CONTENT" "existing-guard-ran" "existing hook content preserved after install"
assert_contains "$HOOK_CONTENT" "local-contract-check.sh" "contract gate appended to existing hook"

# Re-run installer: should detect gate already present and skip
OUT2=$(cd "$FAKE_REPO" && bash "$REPO_DIR/scripts/install-pre-commit-hook.sh" 2>&1 || true)
assert_contains "$OUT2" "already present" "idempotent: re-run detects gate already installed"

# ---------------------------------------------------------------------------
header "install-pre-commit-hook.sh: fresh install (no existing hook)"

FAKE_REPO2="$TMPDIR_TEST/repo2"
mkdir -p "$FAKE_REPO2"
git -C "$FAKE_REPO2" init -q
FAKE_HOOKS2="$FAKE_REPO2/.git/hooks"

cd "$FAKE_REPO2"
bash "$REPO_DIR/scripts/install-pre-commit-hook.sh" > /dev/null 2>&1
cd "$REPO_DIR"

HOOK2_CONTENT="$(cat "$FAKE_HOOKS2/pre-commit")"
assert_contains "$HOOK2_CONTENT" "local-contract-check.sh" "fresh install writes contract gate hook"
assert_contains "$HOOK2_CONTENT" "#!/usr/bin/env bash" "fresh install writes shebang"

# ---------------------------------------------------------------------------
printf '\n=== Results: %d/%d passed ===\n' "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]] || { echo "FAILED: $FAIL test(s)"; exit 1; }
