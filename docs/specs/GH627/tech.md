# Tech Spec

## Linked Issue

GH-627

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Codex wrapper input | `hooks/run-hook-codex.sh:7` | 直接把参数保存为 `HOOK_NAME` | 需要区分 requested 与 canonical 名称 |
| Namespace gate | `hooks/run-hook-codex.sh:72` | 只验证 `vibeguard-*` 前缀 | 不足以构成闭集/path 安全验证 |
| Hook lookup | `hooks/run-hook-codex.sh:87` | 用 namespaced 名直接拼接物理路径 | alias 文件存在的根因 |
| Declared behavior | `hooks/CLAUDE.md:30` | 声称 wrapper 解析到实际脚本 | 需要让实现与文档一致 |
| Codex regressions | `tests/codex_runtime/native_permission_patch_tests.sh:24` | fixtures 创建 namespaced 物理脚本 | 需要改为 canonical fixture 并保留输入名 |
| Install audit | `tests/test_guard_packs.sh:515` | 部分 fixture 假定 installed alias 文件 | 需要覆盖 canonical snapshot |
| Guard pack contract | `packs/safe-bash/pack.yaml:10` | source/install 列表分发物理 alias，但配置 audit 使用 namespaced requested name | 需要只删除物理分发项并保留 wrapper 命令 contract |

## 设计方案

在 wrapper 入口保留 `REQUESTED_HOOK_NAME`，通过显式解析函数得到
`CANONICAL_HOOK_NAME`。解析函数先验证外部名称满足单 basename 规则，再从受支持的
manifest namespaced hook 闭集映射到去前缀的 canonical basename。路径拼接只使用
canonical basename，诊断和 policy identity 继续按外部 contract 使用 requested name，
除非现有 policy 明确以 canonical 名为键；该差异由 focused tests 固定。

resolver 必须在任何目标 hook 执行前处理缺失、空、未知和路径型 requested name。失败路径先从
stdin 取得 event，再复用 Codex visible-failure adapter：`PreToolUse` 输出
`permissionDecision: deny`，`PermissionRequest` 输出 `behavior: deny`，`Stop` 输出
`stopReason`，`PostToolUse` 保留现有顶层 `decision: block`/`reason` 与
`hookSpecificOutput.additionalContext`，只有未识别/兜底事件输出 `systemMessage`。每个响应包含
稳定 invalid-hook-name 原因，保留 requested-name diagnostic，确认目标 fixture 未执行，并在
输出 protocol-valid JSON 后以 wrapper exit 0 结束；禁止仅写 diagnostic、空 stdout 后 exit 0。

推荐显式 allowlist/map，而不是只执行 `${name#vibeguard-}`：后者会接受任何新 basename，
无法阻止 prefix-looking traversal/未声明 hook。manifest、install modules 与 map 的集合
必须由同步测试比较，避免产生第四份手工列表。

删除 8 个 alias shell，并更新 test fixtures 使 repo-linked/installed 两种模式只创建
canonical hook 文件。不存在 alias fallback；旧 snapshot 缺 canonical 文件时返回现有
install-incomplete 可见错误，setup repair 负责刷新。

同步从 `packs/safe-bash/pack.yaml` 的 `source_of_truth.hooks` 和 Codex `would_install` 删除
物理 alias 路径，但保留两个 Codex audit check 中的 requested
`vibeguard-pre-bash-guard.sh`，因为它是传给 wrapper 的外部命令参数而不是待安装文件。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | wrapper resolver + canonical path lookup | 遍历 manifest namespaced names，断言执行对应 canonical fixture |
| B-002 | closed-map/name validation + visible failure adapter | 缺失/空名、未知名、`../`、斜杠与双前缀 fixtures 覆盖 PreToolUse/PermissionRequest/Stop/其他已知事件，断言事件级可见拒绝、stable reason、exit 0 与目标未执行 |
| B-003 | repo-linked/installed resolution | 两种模式的 canonical fixture tests；缺文件返回 visible failure |
| B-004 | adapter/policy integration | `bash tests/test_codex_runtime.sh` 与 manifest tests |
| B-005 | file deletion + set-sync + safe-bash pack contract | alias glob 为空，manifest/canonical 集合通过；pack source/install 无 alias，Codex audit 命令仍传 requested name；`bash tests/test_guard_packs.sh` 通过 |
| B-006 | diagnostics | requested name 与 stable error reason assertions |

## 数据流

Codex 命令传入 requested namespaced basename；resolver 验证并映射 canonical basename；
wrapper 从 repo 或 installed snapshot 选择 canonical hook path，读取 stdin，经过 policy 与
adapter 输出 Codex JSON。无新增持久化。

## 风险

- Security: 名称解析属于 OS 路径边界，必须 closed-map，禁止任意 strip 后执行。
- Fail-closed: 非法名称若仅 diagnostic 后空输出 exit 0，会让 Codex 无法观察拒绝；必须输出事件级 deny/visible failure。
- Compatibility: 旧 snapshot 可能只有 alias 文件；必须通过 setup repair 而非 runtime fallback。
- Distribution: safe-bash pack 必须停止列出 alias 文件，同时保留外部 namespaced wrapper 参数。
- Performance: 一次常量集合查找，热路径影响可忽略。
- Maintenance: manifest 与 resolver 集合漂移需 CI 阻断。

## 测试计划

- [ ] Unit/focused: resolver 正反名称 fixtures；所有失败事件断言 visible output、stable reason、exit 0 与零目标执行。
- [ ] Integration: `bash tests/test_codex_runtime.sh`、installed snapshot 与 `bash tests/test_guard_packs.sh`。
- [ ] Required gates: `bash scripts/ci/validate-hooks.sh`、`bash scripts/ci/validate-hooks-manifest.sh`。
- [ ] Manual: 从现有 manifest 命令调用每个 namespaced hook，确认不依赖 alias 文件。

## 回滚方案

恢复 alias 文件与旧 lookup，并把 alias 路径恢复到 `packs/safe-bash/pack.yaml` 的
`source_of_truth.hooks` 与 Codex `would_install`，即可原子回滚。Codex audit command 中的
requested namespaced 参数前后都不改变。不得保留“新 resolver + alias fallback”双机制；若
兼容证据不足，应停止发布并要求用户运行 setup repair。
