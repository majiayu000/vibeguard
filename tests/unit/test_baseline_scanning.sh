#!/usr/bin/env bash
# Unit tests for baseline scanning (issue #30)
#
# Verifies that guards only report issues on newly added lines, not pre-existing ones.
# Tests both VIBEGUARD_STAGED_FILES (pre-commit) mode and --baseline <commit> mode.
#
# Requires: git, python3
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0; FAIL=0; SKIP=0; TOTAL=0

green()  { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()    { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
yellow() { printf '\033[33m  SKIP: %s\033[0m\n' "$1"; }

# Require git and python3
if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  yellow "git or python3 not available — skipping baseline scanning tests"
  exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Helper: initialize a minimal git repo
init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@vibeguard"
  git -C "$dir" config user.name "VibeGuard Test"
}

# Helper: canonical (symlink-resolved) absolute path — matches what git rev-parse returns
canon() { (cd "$1" 2>/dev/null && pwd -P); }

# Helper: build VIBEGUARD_STAGED_FILES with canonical paths (matching pre-commit-guard.sh)
staged_list() {
  local repo="$1"; shift
  local out
  out=$(mktemp)
  local repo_real
  repo_real=$(canon "$repo")
  for f in "$@"; do
    echo "${repo_real}/${f}"
  done > "$out"
  echo "$out"
}

printf '\n=== Baseline Scanning: vg_build_diff_linemap (Go) ===\n'

# ---- Test 1: linemap captures added lines in pre-commit mode ----
repo1="${tmpdir}/linemap_go"
init_repo "$repo1"

cat > "${repo1}/main.go" <<'EOF'
package main

func existing() {}
EOF
git -C "$repo1" add main.go
git -C "$repo1" commit -q -m "initial"

# Add new lines
cat >> "${repo1}/main.go" <<'EOF'

func newFunc() {
    go process()
}
EOF
git -C "$repo1" add main.go

staged1=$(staged_list "$repo1" main.go)
linemap1=$(mktemp)
(
  cd "$repo1"
  source "${REPO_DIR}/guards/go/common.sh"
  VIBEGUARD_STAGED_FILES="$staged1" vg_build_diff_linemap "$linemap1" '\.go$'
)

TOTAL=$((TOTAL+1))
if [[ -s "$linemap1" ]]; then
  green "vg_build_diff_linemap produces non-empty linemap for staged Go file"
  PASS=$((PASS+1))
else
  red "vg_build_diff_linemap should produce non-empty linemap"
  FAIL=$((FAIL+1))
fi

TOTAL=$((TOTAL+1))
repo1_real=$(canon "$repo1")
if grep -q "${repo1_real}/main.go:" "$linemap1" 2>/dev/null; then
  green "linemap contains entries for the staged file"
  PASS=$((PASS+1))
else
  red "linemap should contain entries for ${repo1_real}/main.go"
  FAIL=$((FAIL+1))
fi
rm -f "$staged1" "$linemap1"

printf '\n=== Baseline Scanning: GO-02 goroutine_leak diff-only mode ===\n'

# ---- Test 2: Pre-existing goroutine leak is NOT reported in pre-commit mode ----
repo2="${tmpdir}/go02_preexisting"
init_repo "$repo2"

cat > "${repo2}/worker.go" <<'EOF'
package worker

func StartWorker() {
    go func() {
        for {
            doWork()
        }
    }()
}

func doWork() {}
EOF
git -C "$repo2" add worker.go
git -C "$repo2" commit -q -m "initial with goroutine"

# Add an innocent change (no new goroutine)
cat >> "${repo2}/worker.go" <<'EOF'

func NewHelper() string { return "ok" }
EOF
git -C "$repo2" add worker.go
staged2=$(staged_list "$repo2" worker.go)

TOTAL=$((TOTAL+1))
out2=$(VIBEGUARD_STAGED_FILES="$staged2" bash "${REPO_DIR}/guards/go/check_goroutine_leak.sh" --strict "$repo2" 2>&1 || true)
if echo "$out2" | grep -q '\[GO-02\]'; then
  red "pre-commit mode should NOT report pre-existing goroutine leak (got: $out2)"
  FAIL=$((FAIL+1))
else
  green "pre-commit mode correctly ignores pre-existing goroutine leak"
  PASS=$((PASS+1))
fi
rm -f "$staged2"

# ---- Test 3: Newly added goroutine leak IS reported in pre-commit mode ----
repo3="${tmpdir}/go02_new_leak"
init_repo "$repo3"

cat > "${repo3}/worker.go" <<'EOF'
package worker

func Existing() string { return "clean" }
EOF
git -C "$repo3" add worker.go
git -C "$repo3" commit -q -m "initial clean"

cat >> "${repo3}/worker.go" <<'EOF'

func Leaky() {
    go func() {
        for {
            process()
        }
    }()
}

func process() {}
EOF
git -C "$repo3" add worker.go
staged3=$(staged_list "$repo3" worker.go)

TOTAL=$((TOTAL+1))
out3=$(VIBEGUARD_STAGED_FILES="$staged3" bash "${REPO_DIR}/guards/go/check_goroutine_leak.sh" "$repo3" 2>&1 || true)
if echo "$out3" | grep -q '\[GO-02\]'; then
  green "pre-commit mode reports newly added goroutine leak"
  PASS=$((PASS+1))
else
  red "pre-commit mode should report newly added goroutine leak (got: $out3)"
  FAIL=$((FAIL+1))
fi
rm -f "$staged3"

printf '\n=== Baseline Scanning: GO-08 defer_in_loop diff-only mode ===\n'

# ---- Test 4: Pre-existing defer-in-loop is NOT reported in pre-commit mode ----
repo4="${tmpdir}/go08_preexisting"
init_repo "$repo4"

cat > "${repo4}/files.go" <<'EOF'
package files

import "os"

func ProcessFiles(paths []string) error {
    for _, path := range paths {
        f, err := os.Open(path)
        if err != nil { return err }
        defer f.Close()
    }
    return nil
}
EOF
git -C "$repo4" add files.go
git -C "$repo4" commit -q -m "initial with defer-in-loop"

cat >> "${repo4}/files.go" <<'EOF'

func Helper() string { return "helper" }
EOF
git -C "$repo4" add files.go
staged4=$(staged_list "$repo4" files.go)

TOTAL=$((TOTAL+1))
if awk '/^\s*for\s/ { found=1 } END { exit !found }' "${repo4}/files.go" 2>/dev/null; then
  out4=$(VIBEGUARD_STAGED_FILES="$staged4" bash "${REPO_DIR}/guards/go/check_defer_in_loop.sh" --strict "$repo4" 2>&1 || true)
  if echo "$out4" | grep -q '\[GO-08\]'; then
    red "pre-commit mode should NOT report pre-existing defer-in-loop (got: $out4)"
    FAIL=$((FAIL+1))
  else
    green "pre-commit mode correctly ignores pre-existing defer-in-loop"
    PASS=$((PASS+1))
  fi
else
  yellow "awk lacks \\s support — skipping defer-in-loop pre-commit test"
  SKIP=$((SKIP+1))
fi
rm -f "$staged4"

printf '\n=== Baseline Scanning: --baseline <commit> mode ===\n'

# ---- Test 5: --baseline does NOT report goroutine that existed before baseline ----
repo5="${tmpdir}/go02_baseline"
init_repo "$repo5"

cat > "${repo5}/server.go" <<'EOF'
package server

func Start() {
    go func() {
        for { serve() }
    }()
}

func serve() {}
EOF
git -C "$repo5" add server.go
git -C "$repo5" commit -q -m "initial with goroutine"
baseline5=$(git -C "$repo5" rev-parse HEAD)

cat >> "${repo5}/server.go" <<'EOF'

func Version() string { return "1.0" }
EOF
git -C "$repo5" add server.go
git -C "$repo5" commit -q -m "add Version func"

TOTAL=$((TOTAL+1))
out5=$(cd "$repo5" && bash "${REPO_DIR}/guards/go/check_goroutine_leak.sh" --baseline "$baseline5" . 2>&1 || true)
if echo "$out5" | grep -q '\[GO-02\]'; then
  red "--baseline mode should NOT report goroutine that existed before baseline (got: $out5)"
  FAIL=$((FAIL+1))
else
  green "--baseline mode correctly ignores goroutine introduced before baseline"
  PASS=$((PASS+1))
fi

# ---- Test 6: --baseline DOES report new goroutine leak added after baseline ----
repo6="${tmpdir}/go02_baseline_new"
init_repo "$repo6"

cat > "${repo6}/clean.go" <<'EOF'
package clean

func Existing() string { return "ok" }
EOF
git -C "$repo6" add clean.go
git -C "$repo6" commit -q -m "initial clean"
baseline6=$(git -C "$repo6" rev-parse HEAD)

cat >> "${repo6}/clean.go" <<'EOF'

func Leaky() {
    go func() {
        for { work() }
    }()
}

func work() {}
EOF
git -C "$repo6" add clean.go
git -C "$repo6" commit -q -m "add goroutine leak"

TOTAL=$((TOTAL+1))
out6=$(cd "$repo6" && bash "${REPO_DIR}/guards/go/check_goroutine_leak.sh" --baseline "$baseline6" . 2>&1 || true)
if echo "$out6" | grep -q '\[GO-02\]'; then
  green "--baseline mode reports goroutine leak added after baseline"
  PASS=$((PASS+1))
else
  red "--baseline mode should report goroutine leak added after baseline (got: $out6)"
  FAIL=$((FAIL+1))
fi

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m  Skip: \033[33m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
