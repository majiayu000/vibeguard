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

# New wrapper is at $EXISTING_HOOK; original content saved to pre-commit.vibeguard-prev
HOOK_CONTENT="$(cat "$EXISTING_HOOK")"
PREV_CONTENT="$(cat "$FAKE_HOOKS/pre-commit.vibeguard-prev" 2>/dev/null || echo "")"
assert_contains "$HOOK_CONTENT" "local-contract-check.sh" "contract gate present in wrapper hook"
assert_contains "$PREV_CONTENT" "existing-guard-ran" "original hook saved to pre-commit.vibeguard-prev"

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
header "install-pre-commit-hook.sh: symlink safety — shared target not mutated"

FAKE_REPO3="$TMPDIR_TEST/repo3"
mkdir -p "$FAKE_REPO3"
git -C "$FAKE_REPO3" init -q
FAKE_HOOKS3="$FAKE_REPO3/.git/hooks"

# Simulate a shared VibeGuard wrapper (e.g. ~/.vibeguard/hooks/pre-commit-guard.sh)
SHARED_TARGET="$TMPDIR_TEST/shared-pre-commit-guard.sh"
cat > "$SHARED_TARGET" <<'HOOK'
#!/usr/bin/env bash
exec bash "$(dirname "$0")/vibeguard-guard.sh" "$@"
HOOK
chmod +x "$SHARED_TARGET"
SHARED_BEFORE="$(cat "$SHARED_TARGET")"

# Point this repo's pre-commit hook at the shared target via a symlink
ln -s "$SHARED_TARGET" "$FAKE_HOOKS3/pre-commit"

cd "$FAKE_REPO3"
bash "$REPO_DIR/scripts/install-pre-commit-hook.sh" > /dev/null 2>&1 || true
cd "$REPO_DIR"

SHARED_AFTER="$(cat "$SHARED_TARGET")"
TOTAL=$((TOTAL + 1))
if [[ "$SHARED_BEFORE" == "$SHARED_AFTER" ]]; then
  green "symlink: shared target not mutated"
  PASS=$((PASS + 1))
else
  red "symlink: shared target was mutated!"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if [[ ! -L "$FAKE_HOOKS3/pre-commit" ]]; then
  green "symlink: symlink replaced with regular file"
  PASS=$((PASS + 1))
else
  red "symlink: hook is still a symlink after install"
  FAIL=$((FAIL + 1))
fi

assert_contains "$(cat "$FAKE_HOOKS3/pre-commit")" "local-contract-check.sh" \
  "symlink: contract gate wired into new regular-file hook"

# ---------------------------------------------------------------------------
header "install-pre-commit-hook.sh: exec-terminated hook — contract gate reachable"

FAKE_REPO4="$TMPDIR_TEST/repo4"
mkdir -p "$FAKE_REPO4"
git -C "$FAKE_REPO4" init -q
FAKE_HOOKS4="$FAKE_REPO4/.git/hooks"

# Simulate the VibeGuard wrapper pattern: hook body ends with exec
cat > "$FAKE_HOOKS4/pre-commit" <<'HOOK'
#!/usr/bin/env bash
exec bash "$(git rev-parse --show-toplevel)/hooks/pre-commit-guard.sh" "$@"
HOOK
chmod +x "$FAKE_HOOKS4/pre-commit"

cd "$FAKE_REPO4"
bash "$REPO_DIR/scripts/install-pre-commit-hook.sh" > /dev/null 2>&1 || true
cd "$REPO_DIR"

INSTALLED4="$(cat "$FAKE_HOOKS4/pre-commit")"
# The call to the original hook must use bash (subprocess), not exec.
# exec would make the contract gate line unreachable.
TOTAL=$((TOTAL + 1))
if echo "$INSTALLED4" | grep -qE '^exec[[:space:]].*vibeguard-prev'; then
  red "exec-chain: original hook called via exec (gate is unreachable)"
  FAIL=$((FAIL + 1))
else
  green "exec-chain: original hook called as subprocess (gate reachable)"
  PASS=$((PASS + 1))
fi
assert_contains "$INSTALLED4" "local-contract-check.sh" \
  "exec-chain: contract gate present after original hook call"

# ---------------------------------------------------------------------------
printf '\n=== Results: %d/%d passed ===\n' "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]] || { echo "FAILED: $FAIL test(s)"; exit 1; }
