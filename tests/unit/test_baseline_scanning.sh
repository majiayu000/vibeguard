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
if awk '/^[[:space:]]*for([[:space:]]|$)/ { found=1 } END { exit !found }' "${repo4}/files.go" 2>/dev/null; then
  out4=$(VIBEGUARD_STAGED_FILES="$staged4" bash "${REPO_DIR}/guards/go/check_defer_in_loop.sh" --strict "$repo4" 2>&1 || true)
  if echo "$out4" | grep -q '\[GO-08\]'; then
    red "pre-commit mode should NOT report pre-existing defer-in-loop (got: $out4)"
    FAIL=$((FAIL+1))
  else
    green "pre-commit mode correctly ignores pre-existing defer-in-loop"
    PASS=$((PASS+1))
  fi
else
  yellow "awk did not recognize fixture loop — skipping defer-in-loop pre-commit test"
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

TOTAL=$((TOTAL+1))
if echo "$out5" | grep -qF "$baseline5"; then
  red "--baseline validation must not print the resolved commit SHA (got: $out5)"
  FAIL=$((FAIL+1))
else
  green "--baseline validation keeps the resolved commit SHA silent"
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

printf '\n=== Baseline Scanning: deletion-only commit ===\n'

# ---- Test 7: deletion-only staged change should NOT trigger full scan ----
# When staged changes contain only irrelevant deletions, the runtime diff map is
# empty. Guards must not fall back to a full scan or report pre-existing code.
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
  green "deletion-only commit: empty runtime diff correctly suppresses full scan"
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
if awk '/^[[:space:]]*for([[:space:]]|$)/ { found=1 } END { exit !found }' "${repo8}/files.go" 2>/dev/null; then
  out8=$(VIBEGUARD_STAGED_FILES="$staged8" bash "${REPO_DIR}/guards/go/check_defer_in_loop.sh" --strict "$repo8" 2>&1 || true)
  if echo "$out8" | grep -q '\[GO-08\]'; then
    red "deletion-only commit should NOT report pre-existing defer-in-loop via full scan (got: $out8)"
    FAIL=$((FAIL+1))
  else
    green "deletion-only commit: empty runtime diff suppresses defer-in-loop full scan"
    PASS=$((PASS+1))
  fi
else
  yellow "awk did not recognize fixture loop — skipping defer-in-loop deletion-only test"
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
if awk '/^[[:space:]]*for([[:space:]]|$)/ { found=1 } END { exit !found }' "${repoB}/files.go" 2>/dev/null; then
  outB=$(VIBEGUARD_STAGED_FILES="$stagedB" bash "${REPO_DIR}/guards/go/check_defer_in_loop.sh" "$repoB" 2>&1 || true)
  if echo "$outB" | grep -q '\[GO-08\]'; then
    green "for loop added wrapping existing defer IS reported (Issue 2 fix)"
    PASS=$((PASS+1))
  else
    red "wrapping defer with new for loop should be reported (got: $outB)"
    FAIL=$((FAIL+1))
  fi
else
  yellow "awk did not recognize fixture loop — skipping wrapped-defer test"
  SKIP=$((SKIP+1))
fi
rm -f "$stagedB"

# ---- Test C: output format filepath:linenum: content is correct (Issue 3) ----
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
if awk '/^[[:space:]]*for([[:space:]]|$)/ { found=1 } END { exit !found }' "${repoC}/resource.go" 2>/dev/null; then
  outC=$(bash "${REPO_DIR}/guards/go/check_defer_in_loop.sh" "$repoC" 2>&1 || true)
  # The Rust scanner emits a diagnostic followed by a summary. Match the
  # diagnostic's canonical filepath:linenum: content form anywhere in output.
  if echo "$outC" | grep -qE '\[GO-08\] .+:[0-9]+: .+'; then
    green "scanner produces correct filepath:linenum: content output format (Issue 3 fix)"
    PASS=$((PASS+1))
  else
    red "output format should be [GO-08] filepath:linenum: content (got: $outC)"
    FAIL=$((FAIL+1))
  fi
else
  yellow "awk did not recognize fixture loop — skipping tab-parsing format test"
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

# ---- Rename test C: Go scanner only reports edited lines for a rename ----
repoR3="${tmpdir}/runtime_go_rename"
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
TOTAL=$((TOTAL+1))
outR3=$( (cd "$repoR3" && VIBEGUARD_STAGED_FILES="$stagedR3" bash "${REPO_DIR}/guards/go/check_goroutine_leak.sh" --strict .) 2>&1 || true )
if ! echo "$outR3" | grep -q '\[GO-02\]'; then
  green "Go scanner ignores pre-existing findings in an edited rename"
  PASS=$((PASS+1))
else
  red "Go scanner must not resurface the pre-existing renamed line (got: $outR3)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR3"

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

# ---- Rename test E: Go scanner treats *_test.go → prod as fully added ----
repoR5="${tmpdir}/runtime_go_test_to_prod"
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
TOTAL=$((TOTAL+1))
outR5=$( (cd "$repoR5" && VIBEGUARD_STAGED_FILES="$stagedR5" bash "${REPO_DIR}/guards/go/check_goroutine_leak.sh" --strict .) 2>&1 || true )
if echo "$outR5" | grep -q '\[GO-02\].*/helper.go:4:'; then
  green "Go scanner treats test-to-production rename as newly enforced code"
  PASS=$((PASS+1))
else
  red "helper_test.go → helper.go must report the pre-existing goroutine (got: $outR5)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR5"

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
TOTAL=$((TOTAL+1))
outR8=$( (cd "$repoR8" && VIBEGUARD_STAGED_FILES="$stagedR8" bash "${REPO_DIR}/guards/typescript/check_any_abuse.sh" --strict .) 2>&1 || true )
if echo "$outR8" | grep -q '\[TS-01\].*/src/helper.ts:1:'; then
  green "root tests-to-production rename is treated as newly enforced TypeScript"
  PASS=$((PASS+1))
else
  red "tests/helper.ts → src/helper.ts must report the pre-existing any usage (got: $outR8)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR8"

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
TOTAL=$((TOTAL+1))
outR9=$( (cd "$repoR9" && VIBEGUARD_STAGED_FILES="$stagedR9" bash "${REPO_DIR}/guards/typescript/check_any_abuse.sh" --strict .) 2>&1 || true )
if echo "$outR9" | grep -q '\[TS-01\].*/src/helper.ts:1:'; then
  green "vendor-to-production rename is treated as newly enforced TypeScript"
  PASS=$((PASS+1))
else
  red "vendor/helper.ts → src/helper.ts must report the pre-existing any usage (got: $outR9)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR9"

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

# ---- Rename test K: non-Rust source → Rust source is newly enforced ----
repoR11="${tmpdir}/rs03_non_source_to_rust"
init_repo "$repoR11"
printf 'pub fn read(input: Option<i32>) -> i32 { input.unwrap() }\n' > "${repoR11}/worker.txt"
git -C "$repoR11" add worker.txt
git -C "$repoR11" commit -q -m "initial non-Rust source"
git -C "$repoR11" mv worker.txt worker.rs
git -C "$repoR11" add worker.rs

stagedR11=$(staged_list "$repoR11" worker.rs)
TOTAL=$((TOTAL+1))
outR11=$( (cd "$repoR11" && VIBEGUARD_STAGED_FILES="$stagedR11" bash "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh" --strict .) 2>&1 || true )
if echo "$outR11" | grep -q '\[RS-03\].*/worker.rs:1'; then
  green "non-source-to-Rust rename is treated as newly enforced code"
  PASS=$((PASS+1))
else
  red "worker.txt → worker.rs must report RS-03 (got: $outR11)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR11"

# ---- Rename test L: excluded Rust source → production is newly enforced ----
repoR12="${tmpdir}/rs03_target_to_prod"
init_repo "$repoR12"
mkdir -p "${repoR12}/target" "${repoR12}/src"
printf 'pub fn read(input: Option<i32>) -> i32 { input.unwrap() }\n' > "${repoR12}/target/worker.rs"
git -C "$repoR12" add -f target/worker.rs
git -C "$repoR12" commit -q -m "initial excluded Rust source"
git -C "$repoR12" mv target/worker.rs src/worker.rs
git -C "$repoR12" add src/worker.rs

stagedR12=$(staged_list "$repoR12" src/worker.rs)
TOTAL=$((TOTAL+1))
outR12=$( (cd "$repoR12" && VIBEGUARD_STAGED_FILES="$stagedR12" bash "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh" --strict .) 2>&1 || true )
if echo "$outR12" | grep -q '\[RS-03\].*/src/worker.rs:1'; then
  green "excluded-to-production Rust rename is treated as newly enforced code"
  PASS=$((PASS+1))
else
  red "target/worker.rs → src/worker.rs must report RS-03 (got: $outR12)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR12"

# ---- Rename test M: non-Go source → Go source is newly enforced ----
repoR13="${tmpdir}/go_non_source_to_go"
init_repo "$repoR13"
cat > "${repoR13}/worker.txt" <<'EOF'
package worker

func Existing() {
    go loop()
}

func loop() {}
EOF
git -C "$repoR13" add worker.txt
git -C "$repoR13" commit -q -m "initial non-Go source"
git -C "$repoR13" mv worker.txt worker.go
git -C "$repoR13" add worker.go

stagedR13=$(staged_list "$repoR13" worker.go)
TOTAL=$((TOTAL+1))
outR13=$( (cd "$repoR13" && VIBEGUARD_STAGED_FILES="$stagedR13" bash "${REPO_DIR}/guards/go/check_goroutine_leak.sh" --strict .) 2>&1 || true )
if echo "$outR13" | grep -q '\[GO-02\].*/worker.go:4:'; then
  green "non-source-to-Go rename is treated as newly enforced code"
  PASS=$((PASS+1))
else
  red "worker.txt → worker.go must report GO-02 (got: $outR13)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR13"

# ---- Rename test N: non-TypeScript source → TypeScript is newly enforced ----
repoR14="${tmpdir}/ts_non_source_to_ts"
init_repo "$repoR14"
printf 'const value: any = 1\n' > "${repoR14}/worker.txt"
git -C "$repoR14" add worker.txt
git -C "$repoR14" commit -q -m "initial non-TypeScript source"
git -C "$repoR14" mv worker.txt worker.ts
git -C "$repoR14" add worker.ts

stagedR14=$(staged_list "$repoR14" worker.ts)
TOTAL=$((TOTAL+1))
outR14=$( (cd "$repoR14" && VIBEGUARD_STAGED_FILES="$stagedR14" bash "${REPO_DIR}/guards/typescript/check_any_abuse.sh" --strict .) 2>&1 || true )
if echo "$outR14" | grep -q '\[TS-01\].*/worker.ts:1:'; then
  green "non-source-to-TypeScript rename is treated as newly enforced code"
  PASS=$((PASS+1))
else
  red "worker.txt → worker.ts must report the pre-existing any usage (got: $outR14)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR14"

# ---- Rename test O: removing the last MCP marker enables TS-03 enforcement ----
repoR15="${tmpdir}/ts_mcp_to_regular"
init_repo "$repoR15"
mkdir -p "${repoR15}/src"
cat > "${repoR15}/src/mcp.ts" <<'EOF'
console.log("server starting")
const transport = "StdioServerTransport"
const stable_one = 1
const stable_two = 2
EOF
git -C "$repoR15" add src/mcp.ts
git -C "$repoR15" commit -q -m "initial MCP source"
git -C "$repoR15" mv src/mcp.ts src/service.ts
sed -i.bak 's/StdioServerTransport/http/' "${repoR15}/src/service.ts"
rm -f "${repoR15}/src/service.ts.bak"
git -C "$repoR15" add src/service.ts

stagedR15=$(staged_list "$repoR15" src/service.ts)
TOTAL=$((TOTAL+1))
outR15=$( (cd "$repoR15" && VIBEGUARD_STAGED_FILES="$stagedR15" bash "${REPO_DIR}/guards/typescript/check_console_residual.sh" --strict .) 2>&1 || true )
if echo "$outR15" | grep -q '\[TS-03\].*/src/service.ts:1'; then
  green "MCP-to-regular rename re-enables TS-03 for unchanged console usage"
  PASS=$((PASS+1))
else
  red "removing the last MCP marker during rename must report TS-03 (got: $outR15)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR15"

# ---- Rename test P: Unicode Rust paths are parsed without Git quoting ----
repoR16="${tmpdir}/rs03_unicode_rename"
init_repo "$repoR16"
mkdir -p "${repoR16}/src"
printf 'pub fn read(input: Option<i32>) -> i32 { input.unwrap() }\n' > "${repoR16}/src/旧.rs"
git -C "$repoR16" add "src/旧.rs"
git -C "$repoR16" commit -q -m "initial Unicode Rust source"
git -C "$repoR16" mv "src/旧.rs" "src/新.rs"

stagedR16=$(staged_list "$repoR16" "src/新.rs")
TOTAL=$((TOTAL+1))
rcR16=0
outR16=$( (cd "$repoR16" && VIBEGUARD_STAGED_FILES="$stagedR16" bash "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh" --strict .) 2>&1 ) || rcR16=$?
if [[ $rcR16 -eq 0 ]] && ! echo "$outR16" | grep -q '\[RS-03\]'; then
  green "Unicode Rust rename preserves the pre-existing-code baseline"
  PASS=$((PASS+1))
else
  red "src/旧.rs → src/新.rs must not resurface existing unwrap (rc=$rcR16, got: $outR16)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR16"

# ---- Rename test Q: Unicode Go paths use the NUL-delimited rename map ----
repoR17="${tmpdir}/go_unicode_rename"
init_repo "$repoR17"
cat > "${repoR17}/旧_worker.go" <<'EOF'
package worker

func Existing() {
    go loop()
}

func loop() {}
EOF
git -C "$repoR17" add "旧_worker.go"
git -C "$repoR17" commit -q -m "initial Unicode Go source"
git -C "$repoR17" mv "旧_worker.go" "新_worker.go"
printf '\nfunc Helper() string { return "ok" }\n' >> "${repoR17}/新_worker.go"
git -C "$repoR17" add "新_worker.go"

stagedR17=$(staged_list "$repoR17" "新_worker.go")
TOTAL=$((TOTAL+1))
outR17=$( (cd "$repoR17" && VIBEGUARD_STAGED_FILES="$stagedR17" bash "${REPO_DIR}/guards/go/check_goroutine_leak.sh" --strict .) 2>&1 || true )
if ! echo "$outR17" | grep -q '\[GO-02\]'; then
  green "Unicode Go rename preserves only newly edited lines"
  PASS=$((PASS+1))
else
  red "Unicode Go rename must not resurface line 4 (got: $outR17)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR17"

# ---- Rename test R: Unicode TypeScript paths use the NUL-delimited rename map ----
repoR18="${tmpdir}/ts_unicode_rename"
init_repo "$repoR18"
printf 'const existing: any = 1\n' > "${repoR18}/旧.ts"
git -C "$repoR18" add "旧.ts"
git -C "$repoR18" commit -q -m "initial Unicode TypeScript source"
git -C "$repoR18" mv "旧.ts" "新.ts"
printf 'const added = 2\n' >> "${repoR18}/新.ts"
git -C "$repoR18" add "新.ts"

stagedR18=$(staged_list "$repoR18" "新.ts")
TOTAL=$((TOTAL+1))
outR18=$( (cd "$repoR18" && VIBEGUARD_STAGED_FILES="$stagedR18" bash "${REPO_DIR}/guards/typescript/check_any_abuse.sh" --strict .) 2>&1 || true )
if ! echo "$outR18" | grep -q '\[TS-01\].*/新.ts:'; then
  green "Unicode TypeScript rename preserves only newly edited lines"
  PASS=$((PASS+1))
else
  red "Unicode TypeScript rename must not resurface line 1 (got: $outR18)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR18"

# ---- Rename test S: Rust runtime classification does not allocate temp files ----
repoR19="${tmpdir}/rs_classifier_temp"
mkdir -p "${repoR19}/tmp" "${repoR19}/src"
printf 'pub fn clean() {}\n' > "${repoR19}/src/lib.rs"
TOTAL=$((TOTAL+1))
if TMPDIR="${repoR19}/tmp" bash "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh" --strict "$repoR19" >/dev/null 2>&1 \
    && ! find "${repoR19}/tmp" -mindepth 1 -print -quit | grep -q .; then
  green "Rust rename classification leaves no temp directories"
  PASS=$((PASS+1))
else
  red "Rust runtime classification leaked temp state"
  FAIL=$((FAIL+1))
fi

# ---- Rename test T: removing #[cfg(test)] enables RS-03 enforcement ----
repoR20="${tmpdir}/rs03_inline_test_to_prod"
init_repo "$repoR20"
mkdir -p "${repoR20}/src"
cat > "${repoR20}/src/old.rs" <<'EOF'
#[cfg(test)]
mod tests {
    pub fn read(input: Option<i32>) -> i32 { input.unwrap() }
}
EOF
git -C "$repoR20" add src/old.rs
git -C "$repoR20" commit -q -m "initial inline test module"
git -C "$repoR20" mv src/old.rs src/new.rs
sed -i.bak '1d' "${repoR20}/src/new.rs"
rm -f "${repoR20}/src/new.rs.bak"
git -C "$repoR20" add src/new.rs

stagedR20=$(staged_list "$repoR20" src/new.rs)
TOTAL=$((TOTAL+1))
outR20=$( (cd "$repoR20" && VIBEGUARD_STAGED_FILES="$stagedR20" bash "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh" --strict .) 2>&1 || true )
if echo "$outR20" | grep -q '\[RS-03\].*/src/new.rs:2'; then
  green "inline-test-to-production rename reports unchanged unwrap"
  PASS=$((PASS+1))
else
  red "removing #[cfg(test)] during rename must report RS-03 (got: $outR20)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR20"

# ---- Rename test U: editing a preserved test attribute keeps rename pairing ----
repoR21="${tmpdir}/rs03_inline_test_comment"
init_repo "$repoR21"
mkdir -p "${repoR21}/src"
cat > "${repoR21}/src/old.rs" <<'EOF'
pub fn existing(input: Option<i32>) -> i32 { input.unwrap() }

#[cfg(test)]
mod tests {
    fn smoke() {}
}
EOF
git -C "$repoR21" add src/old.rs
git -C "$repoR21" commit -q -m "initial source with inline tests"
git -C "$repoR21" mv src/old.rs src/new.rs
sed -i.bak 's/#\[cfg(test)\]/#[cfg(test)] \/\/ tests/' "${repoR21}/src/new.rs"
rm -f "${repoR21}/src/new.rs.bak"
git -C "$repoR21" add src/new.rs

stagedR21=$(staged_list "$repoR21" src/new.rs)
TOTAL=$((TOTAL+1))
rcR21=0
outR21=$( (cd "$repoR21" && VIBEGUARD_STAGED_FILES="$stagedR21" bash "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh" --strict .) 2>&1 ) || rcR21=$?
if [[ $rcR21 -eq 0 ]] && ! echo "$outR21" | grep -q '\[RS-03\]'; then
  green "preserved inline-test attribute does not resurface production debt"
  PASS=$((PASS+1))
else
  red "editing a preserved #[cfg(test)] must retain rename pairing (rc=$rcR21, got: $outR21)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR21"

# ---- Rename test V: removing the last CLI entry enables TS-03 enforcement ----
repoR22="${tmpdir}/ts_cli_to_regular"
init_repo "$repoR22"
mkdir -p "${repoR22}/src"
cat > "${repoR22}/src/cli.ts" <<'EOF'
console.log("starting")
const stable_one = 1
const stable_two = 2
EOF
git -C "$repoR22" add src/cli.ts
git -C "$repoR22" commit -q -m "initial CLI entry"
git -C "$repoR22" mv src/cli.ts src/service.ts

stagedR22=$(staged_list "$repoR22" src/service.ts)
TOTAL=$((TOTAL+1))
outR22=$( (cd "$repoR22" && VIBEGUARD_STAGED_FILES="$stagedR22" bash "${REPO_DIR}/guards/typescript/check_console_residual.sh" --strict .) 2>&1 || true )
if echo "$outR22" | grep -q '\[TS-03\].*/src/service.ts:1'; then
  green "CLI-to-regular rename re-enables TS-03"
  PASS=$((PASS+1))
else
  red "src/cli.ts → src/service.ts must report unchanged console usage (got: $outR22)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR22"

# ---- Test W: Unicode staged Rust additions are attributed to their real path ----
repoR23="${tmpdir}/rs_unicode_addition"
init_repo "$repoR23"
mkdir -p "${repoR23}/src"
printf 'pub fn clean() {}\n' > "${repoR23}/src/lib.rs"
git -C "$repoR23" add src/lib.rs
git -C "$repoR23" commit -q -m "initial Rust source"
printf 'pub fn read(input: Option<i32>) -> i32 { input.unwrap() }\n' > "${repoR23}/src/新增.rs"
git -C "$repoR23" add "src/新增.rs"
stagedR23=$(staged_list "$repoR23" "src/新增.rs")
TOTAL=$((TOTAL+1))
outR23=$( (cd "$repoR23" && VIBEGUARD_STAGED_FILES="$stagedR23" bash "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh" --strict .) 2>&1 || true )
if echo "$outR23" | grep -q '\[RS-03\].*/src/新增.rs:1'; then
  green "Unicode staged Rust addition is enforced"
  PASS=$((PASS+1))
else
  red "Unicode staged Rust addition must report RS-03 (got: $outR23)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR23"

# ---- Test X: Unicode staged Go additions are attributed to their real path ----
repoR24="${tmpdir}/go_unicode_addition"
init_repo "$repoR24"
printf 'package worker\n' > "${repoR24}/base.go"
git -C "$repoR24" add base.go
git -C "$repoR24" commit -q -m "initial Go source"
cat > "${repoR24}/新增.go" <<'EOF'
package worker
func risky() error { return nil }
func run() {
    _ = risky()
}
EOF
git -C "$repoR24" add "新增.go"
stagedR24=$(staged_list "$repoR24" "新增.go")
TOTAL=$((TOTAL+1))
outR24=$( (cd "$repoR24" && VIBEGUARD_STAGED_FILES="$stagedR24" bash "${REPO_DIR}/guards/go/check_error_handling.sh" --strict .) 2>&1 || true )
if echo "$outR24" | grep -q '\[GO-01\].*/新增.go:4'; then
  green "Unicode staged Go addition is enforced"
  PASS=$((PASS+1))
else
  red "Unicode staged Go addition must report GO-01 (got: $outR24)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR24"

# ---- Test Y: Unicode staged TypeScript additions are attributed to their real path ----
repoR25="${tmpdir}/ts_unicode_addition"
init_repo "$repoR25"
printf 'export const clean: string = "ok"\n' > "${repoR25}/base.ts"
git -C "$repoR25" add base.ts
git -C "$repoR25" commit -q -m "initial TypeScript source"
printf 'export const unsafe: any = 1\n' > "${repoR25}/新增.ts"
git -C "$repoR25" add "新增.ts"
stagedR25=$(staged_list "$repoR25" "新增.ts")
TOTAL=$((TOTAL+1))
outR25=$( (cd "$repoR25" && VIBEGUARD_STAGED_FILES="$stagedR25" bash "${REPO_DIR}/guards/typescript/check_any_abuse.sh" --strict .) 2>&1 || true )
if echo "$outR25" | grep -q '\[TS-01\].*/新增.ts:1'; then
  green "Unicode staged TypeScript addition is enforced"
  PASS=$((PASS+1))
else
  red "Unicode staged TypeScript addition must report TS-01 (got: $outR25)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR25"

# ---- Test Z: identical production/test calls retain occurrence-level scope pairing ----
repoR26="${tmpdir}/rs03_identical_scopes"
init_repo "$repoR26"
mkdir -p "${repoR26}/src"
cat > "${repoR26}/src/lib.rs" <<'EOF'
pub fn production(input: Option<i32>) -> i32 {
    input.unwrap()
}

#[cfg(test)]
mod tests {
    pub fn test_helper(input: Option<i32>) -> i32 {
        input.unwrap()
    }
}
EOF
git -C "$repoR26" add src/lib.rs
git -C "$repoR26" commit -q -m "initial identical calls"
printf '\n// unrelated staged edit\n' >> "${repoR26}/src/lib.rs"
git -C "$repoR26" add src/lib.rs
stagedR26=$(staged_list "$repoR26" src/lib.rs)
TOTAL=$((TOTAL+1))
rcR26=0
outR26=$( (cd "$repoR26" && VIBEGUARD_STAGED_FILES="$stagedR26" bash "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh" --strict .) 2>&1 ) || rcR26=$?
if [[ $rcR26 -eq 0 ]] && ! echo "$outR26" | grep -q '\[RS-03\]'; then
  green "identical production/test calls do not resurface production debt"
  PASS=$((PASS+1))
else
  red "identical scoped calls must preserve occurrence pairing (rc=$rcR26, got: $outR26)"
  FAIL=$((FAIL+1))
fi
rm -f "$stagedR26"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m  Skip: \033[33m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
