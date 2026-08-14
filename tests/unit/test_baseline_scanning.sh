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

printf '\n=== Baseline Scanning: deletion-only commit (empty linemap) ===\n'

# ---- Test 7: deletion-only staged change should NOT trigger full scan ----
# When staged changes contain only deletions, vg_build_diff_linemap produces an empty
# linemap. Guards must not fall back to full-scan in this case — they should report
# nothing, because the pre-existing goroutine was not introduced by this commit.
repo7="${tmpdir}/go02_deletion_only"
init_repo "$repo7"

cat > "${repo7}/worker.go" <<'EOF'
package worker

func StartWorker() {
    go func() {
        for {
            doWork()
        }
    }()
}

func doWork() {}

func ExtraHelper() string { return "extra" }
EOF
git -C "$repo7" add worker.go
git -C "$repo7" commit -q -m "initial with goroutine and helper"

# Stage a deletion-only change (remove ExtraHelper)
cat > "${repo7}/worker.go" <<'EOF'
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
git -C "$repo7" add worker.go
staged7=$(staged_list "$repo7" worker.go)

TOTAL=$((TOTAL+1))
out7=$(VIBEGUARD_STAGED_FILES="$staged7" bash "${REPO_DIR}/guards/go/check_goroutine_leak.sh" --strict "$repo7" 2>&1 || true)
if echo "$out7" | grep -q '\[GO-02\]'; then
  red "deletion-only commit should NOT report pre-existing goroutine leak via full scan (got: $out7)"
  FAIL=$((FAIL+1))
else
  green "deletion-only commit: empty linemap correctly suppresses full scan"
  PASS=$((PASS+1))
fi
rm -f "$staged7"

# ---- Test 8: defer-in-loop: deletion-only staged change should NOT trigger full scan ----
repo8="${tmpdir}/go08_deletion_only"
init_repo "$repo8"

cat > "${repo8}/files.go" <<'EOF'
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

func ExtraHelper() string { return "extra" }
EOF
git -C "$repo8" add files.go
git -C "$repo8" commit -q -m "initial with defer-in-loop and helper"

# Stage a deletion-only change (remove ExtraHelper)
cat > "${repo8}/files.go" <<'EOF'
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
git -C "$repo8" add files.go
staged8=$(staged_list "$repo8" files.go)

TOTAL=$((TOTAL+1))
if awk '/^\s*for\s/ { found=1 } END { exit !found }' "${repo8}/files.go" 2>/dev/null; then
  out8=$(VIBEGUARD_STAGED_FILES="$staged8" bash "${REPO_DIR}/guards/go/check_defer_in_loop.sh" --strict "$repo8" 2>&1 || true)
  if echo "$out8" | grep -q '\[GO-08\]'; then
    red "deletion-only commit should NOT report pre-existing defer-in-loop via full scan (got: $out8)"
    FAIL=$((FAIL+1))
  else
    green "deletion-only commit: defer-in-loop empty linemap correctly suppresses full scan"
    PASS=$((PASS+1))
  fi
else
  yellow "awk lacks \\s support — skipping defer-in-loop deletion-only test"
  SKIP=$((SKIP+1))
fi
rm -f "$staged8"

printf '\n=== Baseline Scanning: Issue fixes — deleted exit mechanism, wrapped defer, tab parsing ===\n'

# ---- Test A: goroutine with <-ctx.Done() removed IS reported (Issue 1) ----
repoA="${tmpdir}/go02_deleted_exit"
init_repo "$repoA"

cat > "${repoA}/worker.go" <<'EOF'
package worker

import "context"

func StartWorker(ctx context.Context) {
    go func() {
        for {
            select {
            case <-ctx.Done():
                return
            default:
                doWork()
            }
        }
    }()
}

func doWork() {}
EOF
git -C "$repoA" add worker.go
git -C "$repoA" commit -q -m "initial with ctx.Done exit"

# Remove the ctx.Done exit mechanism lines
cat > "${repoA}/worker.go" <<'EOF'
package worker

import "context"

func StartWorker(ctx context.Context) {
    go func() {
        for {
            doWork()
        }
    }()
}

func doWork() {}
EOF
git -C "$repoA" add worker.go
stagedA=$(staged_list "$repoA" worker.go)

TOTAL=$((TOTAL+1))
outA=$(VIBEGUARD_STAGED_FILES="$stagedA" bash "${REPO_DIR}/guards/go/check_goroutine_leak.sh" "$repoA" 2>&1 || true)
if echo "$outA" | grep -q '\[GO-02\]'; then
  green "deleted ctx.Done exit mechanism IS reported (Issue 1 fix)"
  PASS=$((PASS+1))
else
  red "goroutine with deleted ctx.Done should be reported (got: $outA)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedA"

# ---- Test B: for loop added wrapping existing defer IS reported (Issue 2) ----
repoB="${tmpdir}/go08_wrapped_defer"
init_repo "$repoB"

cat > "${repoB}/files.go" <<'EOF'
package files

import "os"

func ProcessFile(path string) error {
    f, err := os.Open(path)
    if err != nil { return err }
    defer f.Close()
    return nil
}
EOF
git -C "$repoB" add files.go
git -C "$repoB" commit -q -m "initial with defer outside loop"

# Add a for loop wrapping the existing defer
cat > "${repoB}/files.go" <<'EOF'
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
git -C "$repoB" add files.go
stagedB=$(staged_list "$repoB" files.go)

TOTAL=$((TOTAL+1))
if awk '/^\s*for\s/ { found=1 } END { exit !found }' "${repoB}/files.go" 2>/dev/null; then
  outB=$(VIBEGUARD_STAGED_FILES="$stagedB" bash "${REPO_DIR}/guards/go/check_defer_in_loop.sh" "$repoB" 2>&1 || true)
  if echo "$outB" | grep -q '\[GO-08\]'; then
    green "for loop added wrapping existing defer IS reported (Issue 2 fix)"
    PASS=$((PASS+1))
  else
    red "wrapping defer with new for loop should be reported (got: $outB)"
    FAIL=$((FAIL+1))
  fi
else
  yellow "awk lacks \\s support — skipping wrapped-defer test"
  SKIP=$((SKIP+1))
fi
rm -f "$stagedB"

# ---- Test C: output format filepath:linenum is correct with tab-based parsing (Issue 3) ----
repoC="${tmpdir}/go08_tab_parsing"
init_repo "$repoC"

cat > "${repoC}/resource.go" <<'EOF'
package resource

import "os"

func OpenAll(paths []string) {
    for _, p := range paths {
        f, _ := os.Open(p)
        defer f.Close()
    }
}
EOF
git -C "$repoC" add resource.go
git -C "$repoC" commit -q -m "initial"

TOTAL=$((TOTAL+1))
if awk '/^\s*for\s/ { found=1 } END { exit !found }' "${repoC}/resource.go" 2>/dev/null; then
  outC=$(bash "${REPO_DIR}/guards/go/check_defer_in_loop.sh" "$repoC" 2>&1 || true)
  # Verify output format is [GO-08] filepath:linenum content (not broken by tab parsing)
  if echo "$outC" | grep -qE '\[GO-08\] .+:[0-9]+ '; then
    green "tab-based parsing produces correct filepath:linenum output format (Issue 3 fix)"
    PASS=$((PASS+1))
  else
    red "output format should be [GO-08] filepath:linenum content (got: $outC)"
    FAIL=$((FAIL+1))
  fi
else
  yellow "awk lacks \\s support — skipping tab-parsing format test"
  SKIP=$((SKIP+1))
fi

printf '\n=== Baseline Scanning: staged renames are not treated as new code ===\n'

# A pathspec-limited `git diff --cached -- <new-path>` cannot pair a staged
# rename, so renamed files used to show as fully added and every pre-existing
# violation looked new (false pre-commit blocks on pure moves).

# ---- Rename test A: pre-existing unwrap in a renamed file is NOT reported ----
repoR1="${tmpdir}/rs03_rename_clean"
init_repo "$repoR1"
mkdir -p "${repoR1}/src"

cat > "${repoR1}/src/old_util.rs" <<'EOF'
pub fn read_value(input: Option<i32>) -> i32 {
    input.unwrap()
}
EOF
git -C "$repoR1" add src/old_util.rs
git -C "$repoR1" commit -q -m "initial with pre-existing unwrap"

git -C "$repoR1" mv src/old_util.rs src/moved_util.rs
cat >> "${repoR1}/src/moved_util.rs" <<'EOF'

pub fn harmless_addition() -> i32 {
    2
}
EOF
git -C "$repoR1" add src/moved_util.rs

stagedR1=$(staged_list "$repoR1" src/moved_util.rs)
TOTAL=$((TOTAL+1))
rcR1=0
outR1=$( (cd "$repoR1" && VIBEGUARD_STAGED_FILES="$stagedR1" bash "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh" --strict .) 2>&1 ) || rcR1=$?
if [[ $rcR1 -eq 0 ]] && ! echo "$outR1" | grep -q '\[RS-03\]'; then
  green "pre-existing unwrap in a staged rename is not reported"
  PASS=$((PASS+1))
else
  red "staged rename should not resurface pre-existing unwrap (rc=$rcR1, got: $outR1)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR1"

# ---- Rename test B: unwrap ADDED during a rename IS still reported ----
repoR2="${tmpdir}/rs03_rename_new_unwrap"
init_repo "$repoR2"
mkdir -p "${repoR2}/src"

cat > "${repoR2}/src/old_core.rs" <<'EOF'
pub fn stable() -> i32 {
    1
}
EOF
git -C "$repoR2" add src/old_core.rs
git -C "$repoR2" commit -q -m "initial clean"

git -C "$repoR2" mv src/old_core.rs src/moved_core.rs
cat >> "${repoR2}/src/moved_core.rs" <<'EOF'

pub fn risky(input: Option<i32>) -> i32 {
    input.unwrap()
}
EOF
git -C "$repoR2" add src/moved_core.rs

stagedR2=$(staged_list "$repoR2" src/moved_core.rs)
TOTAL=$((TOTAL+1))
outR2=$( (cd "$repoR2" && VIBEGUARD_STAGED_FILES="$stagedR2" bash "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh" --strict .) 2>&1 || true )
if echo "$outR2" | grep -q '\[RS-03\]'; then
  green "unwrap added inside a staged rename is still reported"
  PASS=$((PASS+1))
else
  red "unwrap added during a rename must still be reported (got: $outR2)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR2"

# ---- Rename test C: Go linemap only contains edited lines for a rename ----
repoR3="${tmpdir}/linemap_go_rename"
init_repo "$repoR3"

cat > "${repoR3}/old_worker.go" <<'EOF'
package worker

func Existing() {
    go loop()
}

func loop() {}
EOF
git -C "$repoR3" add old_worker.go
git -C "$repoR3" commit -q -m "initial with goroutine"

git -C "$repoR3" mv old_worker.go moved_worker.go
cat >> "${repoR3}/moved_worker.go" <<'EOF'

func Helper() string { return "ok" }
EOF
git -C "$repoR3" add moved_worker.go

stagedR3=$(staged_list "$repoR3" moved_worker.go)
linemapR3=$(mktemp)
(
  cd "$repoR3"
  source "${REPO_DIR}/guards/go/common.sh"
  VIBEGUARD_STAGED_FILES="$stagedR3" vg_build_diff_linemap "$linemapR3" '\.go$'
)

TOTAL=$((TOTAL+1))
repoR3_real=$(canon "$repoR3")
# Line 4 holds the pre-existing `go loop()`; it must not be in the linemap.
if grep -q "${repoR3_real}/moved_worker.go:" "$linemapR3" 2>/dev/null \
    && ! grep -q "${repoR3_real}/moved_worker.go:4$" "$linemapR3" 2>/dev/null; then
  green "Go linemap for a staged rename contains only edited lines"
  PASS=$((PASS+1))
else
  red "Go linemap should pair the rename and keep only edited lines (got: $(cat "$linemapR3" 2>/dev/null))"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR3" "$linemapR3"

# ---- Rename test D: test → production rename is treated as new production code ----
repoR4="${tmpdir}/rs03_rename_test_to_prod"
init_repo "$repoR4"
mkdir -p "${repoR4}/tests" "${repoR4}/src"

cat > "${repoR4}/tests/helper.rs" <<'EOF'
pub fn read_value(input: Option<i32>) -> i32 {
    input.unwrap()
}
EOF
git -C "$repoR4" add tests/helper.rs
git -C "$repoR4" commit -q -m "initial test helper with unwrap"

git -C "$repoR4" mv tests/helper.rs src/helper.rs
git -C "$repoR4" add src/helper.rs

stagedR4=$(staged_list "$repoR4" src/helper.rs)
TOTAL=$((TOTAL+1))
outR4=$( (cd "$repoR4" && VIBEGUARD_STAGED_FILES="$stagedR4" bash "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh" --strict .) 2>&1 || true )
if echo "$outR4" | grep -q '\[RS-03\]'; then
  green "test-to-production rename still reports pre-existing unwrap"
  PASS=$((PASS+1))
else
  red "moving tests/helper.rs into src/ must report unwrap (got: $outR4)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR4"

# ---- Rename test E: Go linemap treats *_test.go → prod as fully added ----
repoR5="${tmpdir}/linemap_go_test_to_prod"
init_repo "$repoR5"

cat > "${repoR5}/helper_test.go" <<'EOF'
package worker

func Existing() {
    go loop()
}

func loop() {}
EOF
git -C "$repoR5" add helper_test.go
git -C "$repoR5" commit -q -m "initial test file with goroutine"

git -C "$repoR5" mv helper_test.go helper.go
git -C "$repoR5" add helper.go

stagedR5=$(staged_list "$repoR5" helper.go)
linemapR5=$(mktemp)
(
  cd "$repoR5"
  source "${REPO_DIR}/guards/go/common.sh"
  VIBEGUARD_STAGED_FILES="$stagedR5" vg_build_diff_linemap "$linemapR5" '\.go$'
)

TOTAL=$((TOTAL+1))
repoR5_real=$(canon "$repoR5")
# Without pairing, the pre-existing `go loop()` on line 4 must appear as added.
if grep -q "${repoR5_real}/helper.go:4$" "$linemapR5" 2>/dev/null; then
  green "Go linemap treats test-to-production rename as newly added lines"
  PASS=$((PASS+1))
else
  red "helper_test.go → helper.go should add pre-existing lines to the linemap (got: $(cat "$linemapR5" 2>/dev/null))"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR5" "$linemapR5"

# ---- Rename test F: vendor/ → production is treated as fully added ----
repoR6="${tmpdir}/go_vendor_to_prod"
init_repo "$repoR6"
mkdir -p "${repoR6}/vendor/pkg" "${repoR6}/src"

cat > "${repoR6}/vendor/pkg/worker.go" <<'EOF'
package worker

func Existing() {
    go loop()
}

func loop() {}
EOF
git -C "$repoR6" add vendor/pkg/worker.go
git -C "$repoR6" commit -q -m "initial vendor file with goroutine"

git -C "$repoR6" mv vendor/pkg/worker.go src/worker.go
git -C "$repoR6" add src/worker.go

stagedR6=$(staged_list "$repoR6" src/worker.go)
TOTAL=$((TOTAL+1))
outR6=$( (cd "$repoR6" && VIBEGUARD_STAGED_FILES="$stagedR6" bash "${REPO_DIR}/guards/go/check_goroutine_leak.sh" --strict .) 2>&1 || true )
if echo "$outR6" | grep -q '\[GO-02\].*/src/worker.go:4:'; then
  green "vendor-to-production rename still reports pre-existing goroutine risk"
  PASS=$((PASS+1))
else
  red "moving vendor/pkg/worker.go into src/ must report GO-02 (got: $outR6)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR6"

# ---- Rename test G: TS logger exemption → production is treated as fully added ----
repoR7="${tmpdir}/ts_logger_to_prod"
init_repo "$repoR7"
mkdir -p "${repoR7}/src"

cat > "${repoR7}/src/logger.ts" <<'EOF'
const value = 1
console.log(value)
EOF
git -C "$repoR7" add src/logger.ts
git -C "$repoR7" commit -q -m "initial logger file with console output"

git -C "$repoR7" mv src/logger.ts src/service.ts
git -C "$repoR7" add src/service.ts

stagedR7=$(staged_list "$repoR7" src/service.ts)
TOTAL=$((TOTAL+1))
outR7=$( (cd "$repoR7" && VIBEGUARD_STAGED_FILES="$stagedR7" bash "${REPO_DIR}/guards/typescript/check_console_residual.sh" --strict .) 2>&1 || true )
if echo "$outR7" | grep -q '\[TS-03\].*/src/service.ts:2'; then
  green "logger-to-production rename still reports pre-existing console residual"
  PASS=$((PASS+1))
else
  red "moving src/logger.ts to src/service.ts must report TS-03 (got: $outR7)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR7"

# ---- Rename test H: root tests/ → production is treated as fully added ----
repoR8="${tmpdir}/ts_root_tests_to_prod"
init_repo "$repoR8"
mkdir -p "${repoR8}/tests" "${repoR8}/src"
printf 'const value: any = 1\n' > "${repoR8}/tests/helper.ts"
git -C "$repoR8" add tests/helper.ts
git -C "$repoR8" commit -q -m "initial root test helper"
git -C "$repoR8" mv tests/helper.ts src/helper.ts
git -C "$repoR8" add src/helper.ts

stagedR8=$(staged_list "$repoR8" src/helper.ts)
linemapR8=$(mktemp)
(
  cd "$repoR8"
  source "${REPO_DIR}/guards/typescript/common.sh"
  VIBEGUARD_STAGED_FILES="$stagedR8" vg_build_diff_linemap "$linemapR8" '\.(ts|tsx|js|jsx)$'
)
TOTAL=$((TOTAL+1))
repoR8_real=$(canon "$repoR8")
if grep -q "${repoR8_real}/src/helper.ts:1$" "$linemapR8" 2>/dev/null; then
  green "root tests-to-production rename is treated as newly added TypeScript"
  PASS=$((PASS+1))
else
  red "tests/helper.ts → src/helper.ts should add pre-existing lines to the linemap (got: $(cat "$linemapR8" 2>/dev/null))"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR8" "$linemapR8"

# ---- Rename test I: TS vendor/ → production is treated as fully added ----
repoR9="${tmpdir}/ts_vendor_to_prod"
init_repo "$repoR9"
mkdir -p "${repoR9}/vendor" "${repoR9}/src"
printf 'const value: any = 1\n' > "${repoR9}/vendor/helper.ts"
git -C "$repoR9" add vendor/helper.ts
git -C "$repoR9" commit -q -m "initial vendor helper"
git -C "$repoR9" mv vendor/helper.ts src/helper.ts
git -C "$repoR9" add src/helper.ts

stagedR9=$(staged_list "$repoR9" src/helper.ts)
linemapR9=$(mktemp)
(
  cd "$repoR9"
  source "${REPO_DIR}/guards/typescript/common.sh"
  VIBEGUARD_STAGED_FILES="$stagedR9" vg_build_diff_linemap "$linemapR9" '\.(ts|tsx|js|jsx)$'
)
TOTAL=$((TOTAL+1))
repoR9_real=$(canon "$repoR9")
if grep -q "${repoR9_real}/src/helper.ts:1$" "$linemapR9" 2>/dev/null; then
  green "vendor-to-production rename is treated as newly added TypeScript"
  PASS=$((PASS+1))
else
  red "vendor/helper.ts → src/helper.ts should add pre-existing lines to the linemap (got: $(cat "$linemapR9" 2>/dev/null))"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR9" "$linemapR9"

# ---- Rename test J: TS rule exclusions are relative to the scan target ----
repoR10="${tmpdir}/ts_monorepo_logger_target"
init_repo "$repoR10"
mkdir -p "${repoR10}/packages/logger-app/src"

cat > "${repoR10}/packages/logger-app/src/logger.ts" <<'EOF'
const value = 1
console.log(value)
EOF
git -C "$repoR10" add packages/logger-app/src/logger.ts
git -C "$repoR10" commit -q -m "initial monorepo logger file"
git -C "$repoR10" mv packages/logger-app/src/logger.ts packages/logger-app/src/service.ts
git -C "$repoR10" add packages/logger-app/src/service.ts

stagedR10=$(staged_list "$repoR10" packages/logger-app/src/service.ts)
TOTAL=$((TOTAL+1))
outR10=$( (cd "$repoR10" && VIBEGUARD_STAGED_FILES="$stagedR10" bash "${REPO_DIR}/guards/typescript/check_console_residual.sh" --strict packages/logger-app) 2>&1 || true )
if echo "$outR10" | grep -q '\[TS-03\].*/packages/logger-app/src/service.ts:2'; then
  green "monorepo scan target name does not mask logger-to-production rename"
  PASS=$((PASS+1))
else
  red "logger-app target must still report src/logger.ts → src/service.ts (got: $outR10)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR10"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m  Skip: \033[33m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
