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

## 设计方案

在 wrapper 入口保留 `REQUESTED_HOOK_NAME`，通过显式解析函数得到
`CANONICAL_HOOK_NAME`。解析函数先验证外部名称满足单 basename 规则，再从受支持的
manifest namespaced hook 闭集映射到去前缀的 canonical basename。路径拼接只使用
canonical basename，诊断和 policy identity 继续按外部 contract 使用 requested name，
除非现有 policy 明确以 canonical 名为键；该差异由 focused tests 固定。

推荐显式 allowlist/map，而不是只执行 `${name#vibeguard-}`：后者会接受任何新 basename，
无法阻止 prefix-looking traversal/未声明 hook。manifest、install modules 与 map 的集合
必须由同步测试比较，避免产生第四份手工列表。

删除 8 个 alias shell，并更新 test fixtures 使 repo-linked/installed 两种模式只创建
canonical hook 文件。不存在 alias fallback；旧 snapshot 缺 canonical 文件时返回现有
install-incomplete 可见错误，setup repair 负责刷新。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | wrapper resolver + canonical path lookup | 遍历 manifest namespaced names，断言执行对应 canonical fixture |
| B-002 | closed-map/name validation | 空名、未知名、`../`、斜杠与双前缀 negative fixtures 均拒绝 |
| B-003 | repo-linked/installed resolution | 两种模式的 canonical fixture tests；缺文件返回 visible failure |
| B-004 | adapter/policy integration | `bash tests/codex_runtime/test_codex_hooks_adapter.sh` 与 manifest tests |
| B-005 | file deletion + set-sync contract | alias glob 为空且 manifest/canonical 集合检查通过 |
| B-006 | diagnostics | requested name 与 stable error reason assertions |

## 数据流

Codex 命令传入 requested namespaced basename；resolver 验证并映射 canonical basename；
wrapper 从 repo 或 installed snapshot 选择 canonical hook path，读取 stdin，经过 policy 与
adapter 输出 Codex JSON。无新增持久化。

## 风险

- Security: 名称解析属于 OS 路径边界，必须 closed-map，禁止任意 strip 后执行。
- Compatibility: 旧 snapshot 可能只有 alias 文件；必须通过 setup repair 而非 runtime fallback。
- Performance: 一次常量集合查找，热路径影响可忽略。
- Maintenance: manifest 与 resolver 集合漂移需 CI 阻断。

## 测试计划

- [ ] Unit/focused: resolver 正反名称 fixtures。
- [ ] Integration: Codex adapter、guard pack 与 installed snapshot tests。
- [ ] Required gates: `bash scripts/ci/validate-hooks.sh`、`bash scripts/ci/validate-hooks-manifest.sh`。
- [ ] Manual: 从现有 manifest 命令调用每个 namespaced hook，确认不依赖 alias 文件。

## 回滚方案

恢复 alias 文件与旧 lookup 即可回滚。不得保留“新 resolver + alias fallback”双机制；若
兼容证据不足，应停止发布并要求用户运行 setup repair。
