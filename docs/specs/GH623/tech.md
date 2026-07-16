# Tech Spec: self-application focused test decomposition

## Linked Issue

GH-623

## Product Spec

[`product.md`](product.md)

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Aggregate harness | `tests/test_self_application_ci.sh:1-854` | 同时定义共享 harness、68 个 assertion、所有 fixtures 与最终 summary | 超过 U-16；稳定 CI 入口必须保留 |
| Wrapper domain | `tests/test_self_application_ci.sh:54-108` | good/bad Codex wrapper fixture 验证 adapter thinness | 可独立机械移动，约 55 行 |
| Package domain | `tests/test_self_application_ci.sh:110-413` | 20 个 argv/taint/eval mutation 保护 package correction | 最大独立域，约 304 行但仍可保持 `<400` |
| Policy domain | `tests/test_self_application_ci.sh:415-568` | hook output rewriting、SEC-13 settings/MCP risk 与 U-29 mutations | 同属 fail-closed/self-application policy sentinels，约 154 行 |
| SEC-14 domain | `tests/test_self_application_ci.sh:570-845` | MCP description/tokenization/registration mutation matrix | 独立 detector surface，约 276 行 |
| Size guard | `scripts/verify/check-test-file-sizes.sh:1-34` | 只限制 `test_hooks.sh`、`tests/hooks/*.sh` 与 Rust integration tests | 当前 854 行 aggregate 仍被报告为 PASS，存在 enforcement gap |
| CI wiring | `.github/workflows/ci.yml`, `scripts/local-contract-check.sh` | 都调用稳定 aggregate 或包含其 regression suite | 无需修改；入口兼容是关键合同 |

## 设计方案

1. 先扩展 `scripts/verify/check-test-file-sizes.sh`：对
   `tests/test_self_application_ci.sh` 与 `tests/self_application/*.sh` 调用现有 `check_file` 时传入
   `max_lines=399`，从而精确执行 `<400` 合同。该变更在
   production split 前必须因当前 854 行 aggregate 失败，形成 red evidence。
2. 新增 `tests/self_application/`，按现有连续 section 边界机械移动到四个 sourced fragments：
   - `codex_wrapper_tests.sh`：原 54-108 行；
   - `package_correction_tests.sh`：原 110-413 行；
   - `policy_sentinel_tests.sh`：原 415-568 行；
   - `sec14_mcp_tests.sh`：原 570-845 行。
   每个文件保留原文本、fixture 赋值、heredoc、assertion 与 header 顺序，不添加独立 harness。
3. `tests/test_self_application_ci.sh` 保留 shebang、`set -euo pipefail`、路径、计数器、输出/assert
   helpers、`TMP_DIR`、唯一 cleanup trap、四个 repository-level preflight assertions 与最终 summary/
   exit。原四组 section 位置替换为按上述顺序的显式 `source`。
4. focused fragments 是 aggregate 的内部组成部分：不重复 `set -euo pipefail`、不创建第二个 temp
   root、不安装 trap、不重置计数器，也不承诺 standalone 执行。这样 PASS/FAIL 聚合与失败后的 EXIT
   cleanup 仍由单一 owner 控制。
5. 添加结构验证，确认 aggregate 显式 source 四个 exact paths、所有五个 shell 文件通过 `bash -n`、
   行数 guard 通过，且拆分后的 headings 与 `assert_cmd` / `assert_fails` 调用文案按执行顺序与 base
   snapshot 做完整清单 diff。不以仅有的总数或无序集合比较替代逐项顺序比较。
6. 使用两个隔离的临时 repository copy 验证 source 负路径：分别删除一个 child、向一个 child 注入
   shell syntax error，在隔离 `TMPDIR` 中运行真实 aggregate，断言非零、对应 source/syntax 错误可见、
   不输出成功 summary，且退出后 `TMPDIR` 中无 aggregate fixture 残留，从而证明原 EXIT trap 仍执行。
7. 运行 aggregate 并确认最终 `Total: 68 Pass: 68 Fail: 0`。现有 mutations 已覆盖四个提取域：
   wrapper inline-Python failure、package eval/argv failures、SEC-13/U-29 failures、SEC-14 poisoned MCP
   failures；无需编造新 mutation 或改变 production checker。
8. 不修改 `scripts/ci/self-application/*.sh`、`.github/workflows/ci.yml`、规则、hook 或 runtime。若机械
   移动暴露 cross-domain fixture 依赖，触发 stop condition 并先修订 spec，而不是静默重写 fixtures。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | aggregate harness + ordered sources | aggregate output、68 个具名 assertion 清单、summary/exit |
| B-002 | four focused fragments | base-vs-split section text comparison、diff review |
| B-003 | aggregate-owned helpers/temp/trap | ownership search、重复定义检查、cleanup regression |
| B-004 | explicit source wiring | exact-path source assertions、`bash -n`、isolated missing/broken-child aggregate failures + empty `TMPDIR` |
| B-005 | canonical size guard | red-before/green-after `check-test-file-sizes.sh` |
| B-006 | unchanged mutation fixtures | aggregate 68/68 + per-domain checker invocation inventory |
| B-007 | read-only production surfaces | changed-file audit and CI entrypoint comparison |
| B-008 | mechanical assertion inventory | ordered description list comparison against `origin/main@337750e` |

## 数据流与依赖顺序

CI 与开发者仍执行 `tests/test_self_application_ci.sh`。aggregate 初始化 `REPO_DIR` / `SELF_DIR`、
计数器、assert helpers 与 `TMP_DIR`，安装唯一 EXIT trap，运行四个 repository preflight assertions，
再依次 source wrapper、package、policy、SEC-14 fragments。每个 fragment 使用共享 assert helpers 与
temp root 累加同一组计数；控制返回 aggregate 后打印原 summary，并在退出时由原 trap 清理全部 fixture。
没有新持久化、网络、runtime 或公共 API。

## 备选方案

- 只压缩空行降到 800：拒绝，不能恢复职责边界或增长余量。
- 只拆最大的 SEC-14 section：拒绝，aggregate 仍约 578 行且 package domain 继续与 harness 混合，
  也无法达到优选 `<400` aggregate 目标。
- 每个 child 复制 assert helpers 与 temp setup：拒绝，会产生多个计数/cleanup owner 并改变输出合同。
- 把每个 child 变成 standalone test 并由 CI 分别调用：拒绝，会改变稳定入口、执行开销与 required-check
  surface。
- 用脚本自动按行号生成 fragments：拒绝；本任务要求逐段人工核对，且生成器会掩盖 heredoc/section
  边界错误。
- 顺手优化 production checker：拒绝，超出 GH-623 的 test-only 范围。

## 风险

- Source coupling：fragments 依赖 aggregate globals；以显式内部合同、固定顺序和单一 harness owner 管理。
- Heredoc boundary：大量 fixtures 含 shell/JS/Python heredoc；必须整段机械移动并执行所有文件 `bash -n`。
- Assertion loss：简单行数下降可能误删 mutation；以 ordered description inventory 与 fresh 68/68 双重验证。
- Cleanup drift：child 不得新增 trap 或 temp root；失败路径仍由 aggregate EXIT trap 清理。
- Test guard false green：现有 size guard 未覆盖该 harness；将 aggregate + glob 以 inclusive max 399
  加入 canonical guard，而不是在测试中写一次性 `wc`。
- Future growth：四个 child 中最大约 304 行，均留出至少约 95 行余量；aggregate 降至约 70 行。
- Reviewability：实现只允许 size-guard coverage、四个新 fragment 与 aggregate source/delete blocks；任何
  fixture/assertion 文本修改都触发 stop condition。

## 测试计划

- [ ] Red evidence：扩展 size guard 后、拆分前运行
  `bash scripts/verify/check-test-file-sizes.sh`，确认具名报告 854 行 aggregate 超限。
- [ ] Syntax：`bash -n tests/test_self_application_ci.sh tests/self_application/*.sh`。
- [ ] Structural：`bash scripts/verify/check-test-file-sizes.sh`；`wc -l` 确认 aggregate/children `<400`；
  ordered source、header 与 assertion-description full-list diff；临时 repo copy 中 missing/broken child
  均使真实 aggregate 非零且隔离 `TMPDIR` 退出后为空。
- [ ] Focused full：`bash tests/test_self_application_ci.sh`，期待 68/68。
- [ ] Self-application production：`bash scripts/ci/self-application/run-all.sh .`。
- [ ] Broad gate：`bash scripts/local-contract-check.sh --quick`；`git diff --check`。
- [ ] Current-head CI：SpecRail、Ubuntu、macOS、Windows、Self-Application 与 Benchmark checks。

## 回滚方案

按原顺序将四个 fragments 内容放回 aggregate 的 source 位置，删除 `tests/self_application/`，并从
size guard 移除 child glob/恢复 aggregate policy。没有 schema、用户数据、runtime 或安装状态迁移。
