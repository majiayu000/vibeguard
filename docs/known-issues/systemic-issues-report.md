# VibeGuard Systemic Issue Report and Improvement Roadmap

> Comprehensive review based on 40 days of operating data (2026-02-18 → 2026-03-23), 39,166 event logs, and 124 commits.
> 10 parallel sub-agents searching industry best practices (ast-grep, Semgrep, Clippy, Claude Code hooks, GaaS papers, OpenAI Baker et al.).
> Generation date: 2026-03-23

## Overview of running data

```
Total events: 39,166
Decision distribution: pass 35,661 (91.0%) | warn 2,238 (5.7%) | escalate 649 (1.7%)
              correction 266 (0.7%) | gate 196 (0.5%) | block 156 (0.4%)
Project coverage: 148 project directories
Hook triggers: pre-bash 21,870 | analysis-paralysis 4,596 | post-edit 4,386
              pre-edit 3,836 | post-write 1,458 | post-build 1,215
```

---

## 1. Guard false alarm (root cause: grep ≠ AST)

**Impact**: 7+ ward false alarms fixed, 2 forced to be disabled/removed

### 1.1 Question list

| Guard | False Alarm Scenario | Root Cause | Status |
|------|---------|------|------|
| RS-14 declaration-execution gap | annotation/variables/external trait mismatch | `rg -A 50` + grep line count ≠ struct field count | disabled (exit 0) |
| U-HARDCODE hard coding detection | `= "POST"`, enumeration, i18n key all false positives | Regular expressions cannot distinguish string semantics | Removed |
| TS-01 any detection | `: any` inside block comments and strings | grep does not recognize comment/string boundaries | Fixed (append filtering) |
| TS-03 console remnant | `console.log` of CLI project is normal output | Project type is not recognized (CLI vs Web) | Fixed (detect bin field) |
| GO-02 goroutine enumeration | All `go func()` full reports | Only enumeration does not detect risks | Fixed (heuristic filtering) |
| GO-01 error handling | False positive of `_` for `for _, v := range` | Regex does not understand range semantics | Fixed (excluding range) |
| TS-13 component duplication | HTML native attributes, standard state management | Features too wide | Fixed (tightened threshold) |

**Unfixed P2** (9): RS-03 multiple cfg(test), RS-01 clone count error, RS-06 string constant, RS-12 TodoList data structure, TASTE-ASYNC-UNWRAP full file mark, post-write directory hit, post-write regular cross-language pollution, post-build cross-project no isolation, doc-file-blocker temporary path

### 1.2 Root cause analysis (5-Why)

```
Superficial reason: Guard output false positives
  ↓ Why?
Direct reason: grep/regular matching cannot distinguish code structure (comments vs code vs strings)
  ↓ Why?
System reason: Guards are based on text matching rather than syntax trees
  ↓ Why?
Design choice: Choose bash + grep at the beginning of the project to maintain zero dependencies and start quickly
  ↓ Why?
Root cause: Missing "Guard Maturity Ladder" — grep guard is suitable for MVP, but requires an upgrade path to AST tools
```

### 1.3 Improvement plan: ast-grep migration path

**Recommended tools**: [ast-grep](https://ast-grep.github.io/) — Multi-language AST search based on tree-sitter, CLI-friendly, zero runtime dependencies.

**Migration Priority**:

| P0 (false positive rate >50%) | Tools | ast-grep rule example |
|-------------------|------|-------------------|
| RS-14 struct field detection | ast-grep | `pattern: "struct $NAME { $$$ }"` |
| TS-01 any detection | ast-grep | `pattern: ": any"`, `kind: type_annotation` |
| TASTE-ASYNC-UNWRAP | ast-grep | `pattern: "$EXPR.unwrap()"`, `inside: { kind: async_block }` |

**Gradual Migration Strategy**:
```
Phase 1: Install ast-grep and write YAML rules for P0 guards
Phase 2: The new guard uses ast-grep by default, and the grep guard is retained.
Phase 3: High false positive grep guards replaced one by one with ast-grep
Phase 4: grep only for plain text detection (file names, configuration values)
```

**ast-grep integrated mode** (called within bash script):
```bash
# Replace the calling method of grep
ast-grep --pattern '$EXPR.unwrap()' --lang rust --json \
  | jq -r '.[] | "\(.file):\(.range.start.line): [RS-03] unwrap in prod code"'
```

### 1.4 Improvement plan: False alarm rate management system

Drawing on Semgrep’s **severity × confidence matrix**:

| | confidence: high | confidence: medium | confidence: low |
|---|---|---|---|
| severity: error | **block** | **warn + review** | warn |
| severity: warning | warn | info | suppress |
| severity: info | info | suppress | suppress |

**Rules Graduation System**:
```
experimental (7 days) → warn (30 days, FP<10%) → error (stable, FP<5%) → downgrade/retire (FP>20%)
```

**Precision Tracking**: Each rule records `{true_positive, false_positive, suppressed}` count, monthly calculation precision = TP / (TP + FP).

---

## 2. Hook system bug

**Impact**: 6 bugs, including 1 infinite loop

### 2.1 Question list

| Problem | Root Cause | Event Data Support | Status |
|------|------|-------------|------|
| Stop hook exit 2 infinite loop | exit 2 feedback to Claude, Claude has no tool to solve | — | Fixed |
| Escalation is triggered by mistake across sessions | warn count does not differentiate between sessions | 649 escalate event | Fixed |
| Subdirectory commit language detection failed | Relative path `Cargo.toml` | 67 block "guard fail" | Fixed |
| git checkout ./path mistakenly blocked | Regular missing line end anchor | 40 block "pre-commit check failed" | Fixed |
| force push mistakenly blocked | allowed at project level but prohibited globally by guards | 6 block "Forbidden force push" | Fixed |
| analysis paralysis noise | 7+ continuous read-only alarms | 437x warn (all paralysis levels) | Requires tuning |

### 2.2 Root cause analysis

```
Surface reason: Hook behaves abnormally (loop, false trigger, cross-boundary)
  ↓ Why?
Direct reason: Hook design lacks three key protections: context awareness, reentrancy protection, and scope isolation
  ↓ Why?
Root cause: Hook exit code semantics are incomplete - exit 2 "asks Claude to fix" but does not check whether Claude is capable of fixing
```

### 2.3 Improvement plan: Hook security design principles

**Principle 1: Exit 2 Availability Prerequisite Check**
```bash
# Exit 2 is prohibited in Stop hook unless the condition can be resolved by Claude in the current context
# Exit 2 in PreToolUse/PostToolUse is safe (Claude has full tool permissions)
hook_context_safe_for_exit2() {
    case "$HOOK_TYPE" in
        Stop) return 1 ;; # Stop context has no tools, disable exit 2
        PreToolUse|PostToolUse) return 0 ;; # There are tools, allowed
    esac
}
```

**Principle 2: Circuit Breaker**
```bash
HOOK_ATTEMPT_FILE="/tmp/vibeguard-${HOOK_NAME}-attempts"
ATTEMPTS=$(cat "$HOOK_ATTEMPT_FILE" 2>/dev/null || echo 0)
if [ "$ATTEMPTS" -ge 3 ]; then
    echo "Circuit breaker: $HOOK_NAME triggered $ATTEMPTS times, degrading to warn" >&2
    exit 0 # Downgrade to non-blocking
fi
echo $((ATTEMPTS + 1)) > "$HOOK_ATTEMPT_FILE"
```

**Principle 3: Session scope isolation**
```bash
# All counters must contain session ID
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%Y%m%d_%H%M%S)_$$}"
COUNTER_FILE="$STATE_DIR/${SESSION_ID}_${HOOK_NAME}_count"
```

---

## 3. State leakage across boundaries

**Impact**: 3 problems, escalation false triggers are the most serious (649 times)

### 3.1 Problem Pattern

| Leak type | Specific manifestations | Incident data |
|----------|---------|---------|
| Cross-session | warn count is accumulated, new session escalates immediately | 649 escalate |
| Cross-project | Build failure count does not differentiate between projects | 197+54+29 build warn |
| Across time | The session count is incremented instead of the real file count | — |

### 3.2 Improvement plan: three-layer state isolation

```
Global state ~/.vibeguard/events.jsonl — appended log of all events
Project status ~/.vibeguard/projects/<hash>/ — project-level metrics
Session status /tmp/vibeguard-<session_id>/ — session-level counter (temporary directory, automatic cleaning)
```

**Status key naming convention**:
```
<scope>_<hook>_<metric>
Example: session_post-build_fail_count
    project_pre-commit_guard_fail_total
    global_events_total
```

**Session ID source priority**:
```
1. $CLAUDE_SESSION_ID (Claude Code injection)
2. $VIBEGUARD_SESSION_ID (User Settings)
3. Derivation based on JSONL file name
4. fallback: date +%Y%m%d_%H%M%S_$$
```

---

## 4. Guard message is literally executed by AI Agent

**Impact**: TS-03 recommends "replace with logger" → Agent creates logger and reconstructs 11 files

### 4.1 Root cause

Guard messages are designed for humans ("use project logger instead"), but the consumer is an AI agent. The agent interprets the suggestions as instructions and performs full reconstruction.

### 4.2 Improvement plan: Agent-Aware message format

**Message template v2**:
```
[GUARD_ID] OBSERVATION: <Objective description of the problem>
SCOPE: <Modify current file only | Modify current line only | No modification required>
ACTION: <REVIEW (manual review) | FIX-LINE (fix this line) | SKIP (this scenario can be ignored)>
REASON: <why mark>
```

**contrast**:
```
# ❌ v1 — Agent when the command is executed
[TS-03] src/cli.ts:42 console remains. Fix: Use project logger instead, or remove debugging code

# ✅ v2 — Agent understands information
[TS-03] OBSERVATION: src/cli.ts:42 uses console.log
SCOPE: REVIEW-ONLY — do NOT create new files or refactor
ACTION: SKIP if this is a CLI project (bin field in package.json)
REASON: console.log may be intentional output in CLI tools
```

**Key Principles**:
1. **OBSERVATION is not INSTRUCTION** — describes the facts and does not give repair instructions
2. **SCOPE limits the scope of action** - clearly tells the Agent "Do not expand the scope"
3. **Provide SKIP conditions** — Let the Agent decide whether action is needed
4. **It is forbidden to write "alternatives" in messages** - Agent will regard alternatives as required reconstructions

---

## 5. Omission of distribution channel documents

**Impact**: npm leaks directories ×2, Docker leaks dependencies ×2, symbolic links are unresolved ×1

### 5.1 Root cause

Manual maintenance of `files` list + no automatic verification = new directories will inevitably be missed.

### 5.2 Improvement plan: four-layer release defense line

| Layers | Tools | Detection Points |
|----|------|--------|
| 1. Statement | `package.json` `files` whitelist | New directories must be added |
| 2. Static verification | `npm pack --dry-run` + `publint` | CI automatic run |
| 3. Smoke test | `npm pack` → Unzip → Check the existence of necessary directories | CI automatic run |
| 4. Post-release verification | `npm install <pkg>@latest` → require test | CI post-release steps |

**CI Integration** (`prepublishOnly`):
```json
{
  "scripts": {
    "prepublishOnly": "bash scripts/verify-package-contents.sh && npx publint ."
  }
}
```

**Required directory check script** (`scripts/verify-package-contents.sh`):
```bash
#!/usr/bin/env bash
set -euo pipefail
REQUIRED_DIRS=("hooks" "guards" "rules" "scripts" ".claude/commands")
TMPDIR=$(mktemp -d)
npm pack --pack-destination "$TMPDIR" --quiet
TARBALL=$(ls "$TMPDIR"/*.tgz)
tar -xzf "$TARBALL" -C "$TMPDIR"
errors=0
for dir in "${REQUIRED_DIRS[@]}"; do
  if [ ! -d "$TMPDIR/package/$dir" ]; then
    echo "ERROR: Missing directory $dir"; errors=$((errors + 1))
  fi
done
rm -rf "$TMPDIR"
[ "$errors" -gt 0 ] && exit 1
echo "PASSED: Package integrity check passed"
```

**Docker build-time integrity check**:
```dockerfile
# Add a verification layer to the runtime stage
RUN node -e " \
  const fs = require('fs'); \
  const required = ['hooks', 'guards', 'rules', 'scripts']; \
  const missing = required.filter(p => !fs.existsSync(p)); \
  if (missing.length) { console.error('MISSING:', missing); process.exit(1); } \
"
```

---

## 6. Cross-platform Shell compatibility

**Impact**: Windows CI failure ×3

### 6.1 Question List

| Problem | Platform | Root Cause |
|------|------|------|
| PowerShell glob expansion | Windows | `*.test.sh` expanded by PowerShell |
| UnicodeEncodeError | Windows | Python stdout default encoding is not UTF-8 |
| CRLF newline | Windows | bash script containing `\r` causes parsing failure |
| `GUARDS_DIR` path contains spaces | All platforms | Variables are not referenced |

### 6.2 Decision Framework: "Fix Shell" vs "Migrate Runtime"

| Dimensions | Repair Shell | Migrate to Node.js/Deno |
|------|---------|-------------------|
| Short-term cost | Low (fix one by one) | High (all rewritten) |
| Long-term maintenance | High (continuously stepping on pitfalls) | Low (native cross-platform) |
| Dependencies | Zero (bash built-in) | Requires Node.js runtime |
| AST capability | None (can only grep) | Can be integrated with tree-sitter |
| User installation | Simple (bash comes with it) | Requires npm install |

**Recommended**: **Mixed Strategy** — bash guards reserved for simple detection (file existence, naming conventions), complex code analysis moved to ast-grep (cross-platform binary).

**Shell hardening that can be done immediately**:
```bash
# 1. All variable references
"${GUARDS_DIR}" instead of ${GUARDS_DIR}

# 2. .gitattributes force LF
*.sh text eol=lf

# 3. Set UTF-8 in CI
env:
  PYTHONIOENCODING: utf-8

# 4. Explicit shell specification
- run: bash scripts/test.sh
  shell: bash
```

---

## 7. Claude Code platform-level bug

**Impact**: 3 OPEN issues require workaround

| Issue | Problem | VibeGuard Response | Monitoring |
|-------|------|---------------|------|
| #21858 | `paths:` YAML array parsing broken | CSV format workaround | Check fix status regularly |
| #16299 | Project-level paths are loaded globally | Does not affect user-level rules | — |
| #13905 | YAML `*` reserved characters are invalid | CSV format bypass | — |

**YAML frontmatter safe writing method**:
```yaml
# ✅ The only reliable format (CSV single line, no quotes, no spaces)
---
paths: **/*.ts,**/*.tsx,**/*.js,**/*.jsx
---

# ❌ All unreliable
paths: ["**/*.ts"] # YAML array — broken
paths: "**/*.ts" # Quote value — broken
paths: # multi-line array — broken
  - "**/*.ts"
```

---

## Improvement roadmap

### P0 (this week)

- [ ] **Guard message format v2**: All guard output is changed to `OBSERVATION + SCOPE + ACTION` format
- [ ] **Session isolation**: Counter plus session ID, escalation only takes effect within the current session
- [ ] **npm publishing defense**: Add `verify-package-contents.sh` + `prepublishOnly` hook

### P1 (within two weeks)

- [ ] **ast-grep introduction**: write ast-grep rules to replace grep for TS-01(any), RS-03(unwrap)
- [ ] **Rule Graduation System**: New rules default to experimental, and will be upgraded/downgraded according to the FP rate after 7 days.
- [ ] **Hook circuit breaker**: All exit 2 hooks reenter the counter (≥3 downgrades)

### P2 (within one month)

- [ ] **Accuracy Tracking System**: TP/FP count per rule, monthly accuracy report
- [ ] **Docker build integrity**: Dockerfile plus RUN verification layer
- [ ] **.gitattributes**: `*.sh text eol=lf` to prevent CRLF
- [ ] **RS-14 rewrite**: Use ast-grep instead of `rg -A 50` Rewrite statement - perform gap detection

### P3 (long term)

- [ ] **Complex guards migrated to ast-grep**: All semantic analysis class guards migrated from grep
- [ ] **Suppression annotation**: Supports `// vibeguard-disable-next-line RS-03`
- [ ] **Baseline mode**: Alert only for new lines in diff and ignore existing problems

---

## Appendix: Event Data Top Warning/Interception

### Top 15 Warn

| Count | Hook | Reason |
|------|------|------|
| 437 | pre-write-guard | New source code file reminder |
| 197 | post-build-check | Build error 1 |
| 104 | analysis-paralysis | paralysis 7x |
| 86 | analysis-paralysis | paralysis 8x |
| 67 | analysis-paralysis | paralysis 9x |
| 61 | analysis-paralysis | paralysis 10x |
| 54 | post-build-check | Build errors 2 |
| 46 | analysis-paralysis | paralysis 11x |
| 34 | analysis-paralysis | paralysis 14x |
| 33 | pre-bash-guard | non-standard .md files |
| 33 | analysis-paralysis | paralysis 12x |
| 32 | analysis-paralysis | paralysis 13x |
| 29 | post-build-check | 3 build errors |
| 26 | analysis-paralysis | paralysis 15x |
| 23 | analysis-paralysis | paralysis 16x |

### Top 10 Block

| Count | Hook | Reason |
|------|------|------|
| 67 | pre-commit-guard | guard fail |
| 40 | pre-bash-guard | pre-commit check failed |
| 18 | pre-write-guard | New source code files not searched |
| 10 | pre-edit-guard | old_string does not exist |
| 6 | pre-bash-guard | disable force push |
| 6 | pre-bash-guard | Disable rm -rf dangerous paths |
| 2 | pre-edit-guard | File does not exist |
| 2 | pre-commit-guard | guard fail, build fail |
| 2 | pre-bash-guard | disable git reset --hard |
| 1 | pre-bash-guard | Disable starting the development server |

### Lessons learned

1. **grep is not an AST parser** - analysis of code structure is unacceptable, complex detection must use AST tools
2. **The guard message is an instruction for the Agent** - You cannot write an "alternative plan", the Agent will execute it seriously
3. **Project type awareness is a basic capability** — CLI/Web/MCP/Library have completely different reasonable models
4. **Enumerator is not a detector** — Only listing without judging risks will lead to developers and Agents developing the habit of ignoring them.
5. **Status must have scope** — Counters without session/project scope = will inevitably leak across boundaries
6. **Whitelist is better than blacklist** — npm `files` is better than `.npmignore`, explicit declaration is better than implicit exclusion

---

## Appendix B: Key findings from the 10 sub-agent searches

> The following are the core conclusions after searching industry best practices through 10 parallel agents. Complete output is saved in session task files.

### Agent 1: ast-grep migration solution

- **ast-grep YAML rules ready**: Complete YAML rules written for RS-03(unwrap), TS-01(any), GO-01(error), TS-03(console)
- **Core Advantages**: `kind: type_annotation` accurately matches code nodes, naturally excludes comments/strings, and eliminates 4 layers of grep `grep -v`
- **Performance**: Scanning 10,000 files ~1-3s (grep ~0.1s, semgrep ~30-60s), which is the optimal balance of accuracy/speed
- **Migration Strategy**: 4-stage gradual migration, about 30min + 15min integration per rule
- **Key limitations**: Cross-language single rules are not supported; CLI project detection still requires outer scripts; `#[cfg(test)]` scope needs to be verified by actual testing

### Agent 2: Hook loop protection

- **5 known Claude Code traps**: Stop hook exit 2 infinite loop, misuse of `continue: true`, CI environment command failure, `stop_hook_active` unchecked, exit 2 displayed as "Error" in UI
- **Circuit Breaker three-state model**: CLOSED (normal) → OPEN (fuse skip) → HALF-OPEN (test), adapted to the hook system
- **Resolvability Matrix**: Determine whether the Agent is capable of repairing before feedback (Stop context cannot be committed → downgraded to log)
- **Source**: Git hooks `--no-verify`, WordPress unhook-execute-rehook, VS Code `inhibit-modification-hooks`

### Agent 3: Session state isolation

- **Specific bug found**: `post-build-check.sh:85-106` Consecutive failure count **Missing session filtering** (P0, 1 line fixed)
- **Session ID file should be changed to project level**: from global `~/.vibeguard/.session_id` to `${PROJECT_LOG_DIR}/.session_id` (P0, line 3)
- **POSIX `>>` append is atomic on single-line writes**: the current vg_log implementation is concurrency-safe as long as the JSON line is < 4KB (PIPE_BUF)

### Agent 4: AI-Friendly message format

- **6 real over-fix cases**: VibeGuard console→refactor 11 files, Clippy→replace the entire rendering library, BitsAI-Fix→modify error message text, Copilot→abandon PR, Claude Code→`--no-verify` bypass
- **Clippy Applicability four-level model**: `MachineApplicable` > `MaybeIncorrect` > `HasPlaceholders` > `Unspecified`
- **DO NOT field is the most critical defense**: every message must contain explicitly prohibited excesses
- **SARIF standard**: severity/applicability/scope three-dimensional separation, VibeGuard can adopt a similar design
- **Research**: BitsAI-Fix paper confirms "constrain edits strictly to locations implicated by the reported issue"

### Agent 5: npm/Docker integrity

- **`files` whitelist is better than `.npmignore`**: Next.js, Vite, TypeScript, esbuild all use `files`
- **Four layers of release defense**: `npm pack --dry-run` → `publint` → `arethetypeswrong` → `pkg-ok`
- **Verdaccio local registry**: Send to local for complete verification before publishing
- **Docker multi-stage + RUN layer verification**: Files are found to be missing when building, without waiting for runtime

### Agent 6: Cross-platform Shell Compatibility

- **Decision**: Mixed strategy optimal - keep bash for simple detection, use ast-grep (cross-platform binary) for complex analysis
- **Do 3 things immediately**: `.gitattributes` (\*.sh eol=lf) + `PYTHONUTF8=1` + CI `shell: bash`
- **`dax` library**: a cross-platform shell for Deno/Node.js, the syntax is close to bash but truly cross-platform (mid-term consideration)
- **macOS vs Linux sed**: Use `sed -i.bak` + delete .bak, or use `sed -E`

### Agent 7: False alarm rate management

- **Semgrep severity × confidence matrix**: severity (impact) and confidence (reliability) are orthogonal, CI blocking should be based on combination
- **Rule graduation ladder**: nursery(off) → warn(precision≥70%) → error(precision≥90%+50 samples+30 days without FP)
- **triage feedback closed loop**: Add `triage.jsonl`, user mark tp/fp/acceptable, feedback to rule-scorecard
- **Suppression comment**: `// vibeguard-disable-next-line RS-03 -- reason`, grep the previous line before detection
- **Baseline scan**: pre-commit only runs guards on `git diff --cached` new lines

### Agent 8: AI coded agent guard architecture

- **OpenAI Baker et al. 7 categories of hack**: VibeGuard W-12 covers the first 4 categories, #5-7 (decompile/extract expected value/library shadow) needs to be added
- **GaaS four-level progressive execution**: Allow → Warn → Block → Escalate, the trust factor decays with compliance behavior
- **Claude Code `updatedInput`**: PreToolUse can transparently modify parameters (such as `npm install` → `pnpm install`), which is better than blocking + retrying
- **Protected file list**: conftest.py/test config/The coverage threshold is set to unmodifiable, and the Agent is immediately blocked when modified.
- **PostToolUse feedback's `suppressOutput`**: controls which feedback enters the Claude context to avoid information overload

### Agent 9: YAML Frontmatter Trap

- **5 confirmed Claude Code bugs**: #19377 (YAML array), #17204 (quotes retained), #21858 (user-level paths ignored), #23478 (not loaded when writing), paths invalid after compaction
- **Only reliable format**: `paths: **/*.ts,**/*.tsx` (bare CSV, no quotes, no spaces)
- **New discovery #23478**: `paths:` rules are only loaded during Read, not during Write/Edit (affects guard scope)
- **Norway Problem**: YAML 1.1 parses `NO` into `false`, there are 22 ways to write Boolean

### Agent 10: Semgrep/Tree-sitter alternative

- Research is covered by Agent 7 (ast-grep), ast-grep is the optimal choice (more accurate than grep, faster than semgrep)
