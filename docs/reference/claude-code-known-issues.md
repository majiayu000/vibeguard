# Claude Code known issues and VibeGuard response

> Claude Code platform-level bug affecting VibeGuard rules/hooks/skills loading.
> Last updated: 2026-03-28

## Rules

### 1. User-level paths precondition parsing failed

| field | value |
|------|------|
| Issue | [#21858](https://github.com/anthropics/claude-code/issues/21858) |
| STATUS | OPEN (not fixed) |
| Impact | Rules using YAML array format `paths:` under `~/.claude/rules/` are not loaded |
| Root cause | `yaml.parse()` returns JS Array, the CSV parser iterates element by element instead of character by character, resulting in invalid glob |

**Trigger conditions**:

```yaml
# ❌ Not valid — YAML array format
---
paths:
  - "**/*.ts"
  - "**/*.tsx"
---

# ❌ Not valid — with quotes
---
paths: "**/*.ts"
---
```

**VibeGuard responds**:

```yaml
# ✅ CSV single line, no quotes
---
paths: **/*.ts,**/*.tsx,**/*.js,**/*.jsx
---
```

This workaround has been applied to 4 language rules files in `rules/claude-rules/`.

---

### 2. Global loading of project-level paths rules

| field | value |
|------|------|
| Issue | [#16299](https://github.com/anthropics/claude-code/issues/16299) |
| STATUS | OPEN (not fixed) |
| Impact | Rules with `paths:` under `.claude/rules/` are all loaded when the session starts, regardless of whether they match |
| Consequences | Context bloat — all 28 rules may be loaded instead of only 5 |

**VibeGuard Impact**: Low. VibeGuard uses `~/.claude/rules/` (user level), and the three files under common/ have no paths (valid globally). Language rules can be filtered normally using the CSV workaround.

---

### 3. YAML precondition syntax is invalid

| field | value |
|------|------|
| Issue | [#13905](https://github.com/anthropics/claude-code/issues/13905) |
| Status | OPEN |
| Impact | The YAML syntax of the official documentation example is invalid in the YAML specification (`*` is a reserved character and cannot be used naked) |

**VibeGuard Countermeasure**: Same as #1, using CSV format bypass.

---

### 4. paths are ignored in Git Worktree

| field | value |
|------|------|
| Issue | [#23569](https://github.com/anthropics/claude-code/issues/23569) |
| STATUS | CLOSED (NOT PLANED, filed under #16299) |
| Impact | Worktree path resolution rules do not use paths filtering |

**VibeGuard Impact**: Low. VibeGuard's `worktree-guard.sh` is a git-level isolation tool that does not rely on Claude Code's rule loading mechanism.

---

### 8. paths rule is not triggered during Write/Edit

| field | value |
|------|------|
| Issue | [#23478](https://github.com/anthropics/claude-code/issues/23478) |
| STATUS | OPEN (not fixed) |
| Severity | **Medium** |
| Impact | `paths:` filtering only takes effect when Claude reads the file, Write/Edit operations do not trigger path scope rules |

**Problem Description**: Path scope rules are only loaded and evaluated when the Read tool is called, not when Write/Edit. This means that path-qualified rules may not take effect during the most critical operation (writing code).

**VibeGuard Impact**: Medium. Language-specific rules (such as `typescript/*.md`) expect to take effect when a TS file is modified, but Write/Edit bypasses path filtering.

**VibeGuard response**: PreToolUse hook forces Read before Write/Edit, indirectly triggering rule loading. Detect the root cause of this issue in `scripts/verify/compliance_check.sh` Layer 7 (YAML array and quoted paths syntax).

---

### 9. Quoted paths values are retained intact

| field | value |
|------|------|
| Issue | [#17204](https://github.com/anthropics/claude-code/issues/17204) |
| STATUS | OPEN (not fixed) |
| Severity | Medium |
| Impact | Quotes in `paths: "**/*.ts"` are retained into the glob string, causing the match to fail |

**Trigger conditions**:

```yaml
# ❌ Not effective - quotes are preserved, glob cannot match
---
paths: "**/*.ts,**/*.tsx"
---
```

**VibeGuard response**: Same as #1, CSV format without any quotes. `compliance_check.sh` Layer 7 automatically detects this issue.

---

## Hooks System

### 7. Stop Hook exit 2 leads to infinite loop

| field | value |
|------|------|
| Date of discovery | 2026-03-12 |
| Status | Fixed (VibeGuard side) |
| Impact | Stop hook triggers an infinite loop when using `exit 2`, and the Claude Code interface continues to execute repeatedly |

**Root cause**:

Claude Code’s hook exit code semantics:
- `exit 0` — Pass silently, no feedback to the model
- `exit 1` — hook fails and does not feed back to the model
- `exit 2` — Inject stderr as feedback to Claude, expecting Claude to process it and try again

`stop-guard.sh` uses `exit 2` when it detects that the source code file has not been submitted, triggering the following infinite loop:

```
Claude reply completed
  → Stop hooks execution
    → stop-guard.sh detects uncommitted files → exit 2 + stderr
      → Claude Code returns stderr to Claude
        → Claude generates a reply (even if it is empty)
          → Reply completed → Stop hooks and execute again
            → Uncommitted files are still there → exit 2 → infinite loop
```

**Key contradiction**: `exit 2` expects Claude to solve the problem, but Claude has no tools available in the Stop context (cannot call git commit), so the triggering condition can never be eliminated.

**VibeGuard Fix**:

`stop-guard.sh` changes `exit 2` to `exit 0`, only records uncommitted files through `vg_log`, and does not block the end of the session.

**Design principle**: `exit 2` should not be used in a Stop hook unless the triggering condition can be resolved by Claude himself in the Stop context. It is safe to use `exit 2` in PreToolUse/PostToolUse because Claude has full tool access in these contexts.

---

### 10. exit 2 is displayed as "Error" in the UI instead of blocking prompts

| field | value |
|------|------|
| Issue | [#34600](https://github.com/anthropics/claude-code/issues/34600) |
| STATUS | OPEN (not fixed) |
| Severity | Low |
| Impact | When Hook returns `exit 2`, Claude Code UI displays it as red "Error" instead of the expected blocking feedback prompt |

**Problem Description**: The design intention of `exit 2` is to inject stderr as feedback to Claude and block the current operation. But at the UI layer, this is rendered as an error state, potentially leading the user to believe that the hook itself is in error.

**VibeGuard response**: Add the `[BLOCKED]` prefix to hook stderr to make the UI display clearer:

```bash
# in hook script
echo "[BLOCKED] Dangerous operation detected: ${tool_name}" >&2
exit 2
```

**VibeGuard Impact**: Low. The function is normal and only affects the UI display. PreToolUse hooks have been unified to use the `[BLOCKED]` prefix.

---

## Skills System

### 5. SKILL.md validator rejects extended fields

| field | value |
|------|------|
| Issue | [#25380](https://github.com/anthropics/claude-code/issues/25380) |
| STATUS | CLOSED (duplicate of #23330, not fixed) |
| Impact | The VS Code extended validator only recognizes Agent Skills standard fields and rejects `hooks`, `allowed-tools`, `context` and other Claude Code extended fields |

**VibeGuard Impact**: Only affects warning display in VS Code. VibeGuard's SKILL.md uses standard fields such as `name`, `description`, `tags`, etc. and is not affected. If you see a yellow warning in VS Code, you can ignore it.

---

### 6. Skill-Scoped Hooks in the plug-in are not triggered

| field | value |
|------|------|
| Issue | [#17688](https://github.com/anthropics/claude-code/issues/17688) |
| STATUS | OPEN (not fixed) |
| Impact | For plugins installed via `--plugin-dir` or marketplace, the hooks in their SKILL.md frontmatter are not executed |
| Works fine | Hooks in `.claude/skills/` and `.claude/agents/` work fine |

**VibeGuard Impact**: None. VibeGuard hooks are registered via `settings.json` (`hooks.PreToolUse`/`PostToolUse`) and do not use SKILL.md frontmatter hooks. If VibeGuard is distributed as a plug-in in the future, this bug needs attention.

---

## Summary: VibeGuard’s impact

| Problem | Severity | Addressed |
|------|--------|--------|
| #21858 User-level paths YAML parsing | **HIGH** | ✅ CSV format workaround |
| #16299 Global loading of project-level paths | Low | — Does not affect user-level |
| #13905 Invalid YAML syntax | Medium | ✅ CSV format workaround |
| #23569 Worktree paths ignored | Low | — Do not rely on this mechanism |
| #23478 paths are not triggered in Write/Edit | **Medium** | ✅ PreToolUse hook forces Read prefix |
| #17204 Failed to match quoted paths | Medium | ✅ CSV unquoted + Layer 7 detection |
| #7 Stop hook exit 2 infinite loop | **High** | ✅ Change to exit 0 to log only |
| #34600 exit 2 UI displays as Error | Low | ✅ [BLOCKED] prefix workaround |
| #25380 SKILL.md validator | Low | — VS Code warnings only |
| #17688 Plugin hooks are not triggered | None | — Do not use this mechanism |

## Monitoring suggestions

Regularly check the fix status of the following issues:
- **#21858** — Fixed to change back to YAML array format (more readable)
- **#23478** — Fixed paths rule to fire correctly on Write/Edit
- **#16299** — Fixed project-level rules having lower context overhead
- **#17688** — If VibeGuard plans to distribute plug-ins, please pay attention

## Automated monitoring

`scripts/verify/compliance_check.sh` Layer 7 automatically detects common rule syntax issues:

```bash
bash scripts/verify/compliance_check.sh
# Output: --- Layer 7: Rule YAML Syntax ---
#   [PASS] No YAML array syntax in paths frontmatter
#   [PASS] No quoted paths in rules frontmatter
```
