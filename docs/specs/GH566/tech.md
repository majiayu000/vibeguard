# Tech Spec

## Linked Issue

GH-566

## Product Spec

`docs/specs/GH566/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Codex hook config helper | `scripts/lib/codex_hooks_json.py` | upsert/remove 只管理 VibeGuard-owned entries；`check-stale-hooks` 只解析部分安装路径；`check-timeouts` 把 unmanaged hook without timeout 报为 warning | 需要在这里区分 “合法第三方 hook” 和 “目标缺失且会阻断 PreToolUse 的 stale hook” |
| Setup status | `scripts/setup/targets/codex-home.sh`, `scripts/setup/check.sh` | 报告 VibeGuard hooks 是否完整、stale installed hooks、timeout drift | 需要把 blocking unmanaged `PreToolUse` 作为更高严重度输出 |
| Setup install/repair | `scripts/setup/install.sh`, `scripts/setup/targets/codex-home.sh` | `setup.sh --yes` upsert VibeGuard hooks 并保留第三方 hooks；`--clean` 只移除 managed entries | 需要显式 repair path，不能静默删除第三方 hooks |
| Setup tests | `tests/setup/install_flow_tests.sh`, `tests/setup/profile_flow_tests.sh`, `tests/test_setup_check.sh` | 使用 'node /existing/non-vibeguard.js' 证明第三方 hook 会保留 | 这个 fixture 代表“保留行为”，但如果进入真实 HOME 会成为不可执行 blocker |
| User docs | `docs/how/troubleshooting.md`, `docs/reference/codex-hook-status.md` | 说明 hook 安装状态和 timeout warning | 需要补充 PreToolUse stale hook 的诊断和修复说明 |

## Proposed Design

### 1. Add explicit Codex hook health classification

Extend `scripts/lib/codex_hooks_json.py` with a shared classifier for hook
commands:

```text
managed_vibeguard
unmanaged_valid
unmanaged_missing_target
unmanaged_unresolved
```

The classifier should parse command tokens with `shlex.split` and identify a
best-effort executable target:

- direct absolute path: `/abs/hook --flag`
- interpreter plus absolute script: `node /abs/hook.js`, `bash /abs/hook.sh`,
  `python3 /abs/hook.py`
- simple `env KEY=value ...` prefix before either form
- existing VibeGuard wrapper and installed hook paths already handled today

If the target cannot be resolved safely, classify as `unmanaged_unresolved`
and do not delete it.

### 2. Severity matrix

Use event severity rather than treating all unmanaged drift equally:

| Event | Missing target | Default check | Strict check |
| --- | --- | --- | --- |
| `PreToolUse` | `unmanaged_missing_target` | `WARN` with repair hint | `BROKEN` / non-zero |
| `PermissionRequest` | `unmanaged_missing_target` | `WARN` with repair hint | `BROKEN` / non-zero |
| `PostToolUse` | `unmanaged_missing_target` | `WARN` | `WARN` unless evidence shows it blocks command completion |
| `Stop` | `unmanaged_missing_target` | `WARN` | `WARN` |

Rationale: `PreToolUse` and `PermissionRequest` run before permission/tool
execution and can block the user's intended command. Post/Stop failures are
still unhealthy but should not be promoted without a separate issue.

### 3. Add explicit repair path

Add a helper subcommand such as:

```sh
python3 scripts/lib/codex_hooks_json.py prune-stale-unmanaged \
  --hooks-file ~/.codex/hooks.json \
  --event PreToolUse
```

Then expose it through a setup flag, for example:

```sh
bash setup.sh --yes --repair-stale-unmanaged-hooks
```

Repair rules:

- Remove only hooks classified as `unmanaged_missing_target`.
- Default to `PreToolUse` and `PermissionRequest`; require an explicit event
  argument before pruning Post/Stop events.
- Preserve valid third-party hooks, unresolved commands, managed VibeGuard
  hooks, and sibling hooks in the same entry.
- Print a summary of removed commands.
- Validate JSON after write.

Do not make ordinary `setup.sh --yes` silently delete unmanaged hooks unless
the implementation introduces an interactive confirmation path and tests it.

### 4. Replace unsafe preserved-hook fixture

Change tests that assert “third-party hook is preserved” to create a real
temporary script under `${TMP_HOME}` and reference it from `hooks.json`.

Keep a separate stale fixture test for '/existing/non-vibeguard.js', but use it
only to assert detection/remediation, not as a valid preserved hook.

Add a small test guard near fixture setup:

```sh
case "${HOME}" in
  "${TMP_HOME}"*) ;;
  *) echo "refusing to write hook fixture outside TMP_HOME" >&2; exit 1 ;;
esac
```

### 5. Documentation

Add troubleshooting guidance:

1. Run `jq '.hooks.PreToolUse' ~/.codex/hooks.json`.
2. Reproduce the configured command directly.
3. Run `bash setup.sh --check --strict`.
4. Use the explicit repair flag when the stale command points to a missing
   file and is not a real third-party integration.

## Product-to-Test Mapping

| Product requirement | Implementation area | Verification |
| --- | --- | --- |
| P1 strict check reports blocking stale `PreToolUse` | `codex_hooks_json.py`, `codex-home.sh`, `check.sh` | `tests/test_setup_check.sh` fixture exits broken and names config/event/matcher/path |
| P2 explicit repair removes only stale hook | `codex_hooks_json.py`, `install.sh` flag wiring | New setup test with stale + valid third-party + managed hooks |
| P3 valid third-party hooks preserved | setup tests | Existing preservation assertions updated to use an existing temp script |
| P4 fixture leak detected | setup check tests | '/existing/non-vibeguard.js' in `PreToolUse` is reported as missing target |
| P5 docs explain recovery | docs | `bash scripts/ci/validate-doc-paths.sh` and `bash scripts/ci/validate-doc-command-paths.sh` |

## Risks

- False positive deletion of third-party hook: mitigated by opt-in repair,
  missing-target-only classification, and preserving unresolved commands.
- Overfitting to 'node /existing/non-vibeguard.js': mitigated by testing
  interpreter, direct absolute path, and `env` prefix forms.
- High-context config mutation: repair command must be explicit and must print
  removed commands before/after in tests.
- User confusion if strict check becomes louder: message must explain that
  unmanaged hooks are preserved by default and the repair is opt-in.

## Test Plan

- [ ] `python3 -m py_compile scripts/lib/codex_hooks_json.py`.
- [ ] Focused helper tests for command classification and prune behavior.
- [ ] `bash tests/test_setup_check.sh` for strict check severity and stale
      detection.
- [ ] Focused setup flow test for `--repair-stale-unmanaged-hooks`.
- [ ] `bash scripts/ci/validate-doc-paths.sh`.
- [ ] `bash scripts/ci/validate-doc-command-paths.sh`.

## Rollback Plan

Rollback is reverting the helper, setup flag, test, and doc changes. Existing
managed hook upsert/remove behavior remains compatible because this spec does
not alter the VibeGuard-managed identity model or Codex `hooks.json` schema.
