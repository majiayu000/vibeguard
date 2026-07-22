# Tech Spec — U-16 baseline-aware enforcement

## Linked Issue

GH-671

## Product Spec

`docs/specs/GH671/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Shared policy | `vibeguard-runtime/src/u16_baseline.rs:30` | 新增 `evaluate_u16_baseline`，返回 allow / legacy debt / block reason | 防止 pre-edit、pre-write、Git 和 CI 判定漂移 |
| Pre-write runtime | `vibeguard-runtime/src/hook_checks.rs:74`, `vibeguard-runtime/src/hook_orchestrator.rs:200` | Write hook 读取已存在文件行数并使用 shared baseline decision | 修复 full replacement shrinking 被误阻断 |
| Pre-edit runtime | `vibeguard-runtime/src/hook_checks.rs:323`, `vibeguard-runtime/src/hook_orchestrator_pre_edit.rs:148` | Edit hook 用当前行数与 estimated line count 比较 | 修复 `vibeguard_line_delta < 0` 被误阻断 |
| Git hook | `hooks/pre-commit-guard.sh:53`, `hooks/pre-commit-guard.sh:102` | pre-commit 在语言/build 检查前调用 `u16-baseline-check --staged` | 捕获 IDE、copy、generator、initial commit 等非 AI 写入路径 |
| CI hook | `scripts/ci/validate-u16-baseline.sh:1`, `.github/workflows/ci.yml:65` | CI 对 merge-base/base-before 与 HEAD 调用同一 runtime command | 捕获 PR/push changed-file oversized import |

## 设计方案

1. 在 `vibeguard-runtime/src/u16_baseline.rs` 中集中实现基线判定：
   - 新文件 `new_lines > limit` 阻断。
   - 旧文件 `old_lines <= limit && new_lines > limit` 阻断。
   - 遗留超大文件 `new_lines > old_lines` 阻断。
   - 遗留超大文件 `limit < new_lines <= old_lines` 允许并输出
     `U16_LEGACY_DEBT`。
2. pre-edit 和 pre-write 只负责提供 old/new 行数；阻断/告警语义交给 shared policy。
3. 新增 `u16-baseline-check` runtime command：
   - `--staged` 读取 staged index 并与 `HEAD` 比较，initial commit 视为无旧基线。
   - `--base <ref> --head <ref>` 先计算 merge-base，再比较 base/head blobs。
   - `git diff -M --diff-filter=AMR` 保留 rename 基线，copy/import 仍按新增文件处理。
4. pre-commit 和 CI 只调用 runtime command，不在 shell 中复制判定逻辑。
5. hard limit 继续通过 `project_u16_limit` 解析，保留显式 `U-16 exempt` 配置。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | `u16_baseline.rs` + pre-commit/CI command | `cargo test --manifest-path vibeguard-runtime/Cargo.toml u16_baseline`; `bash tests/hooks/test_u16_baseline.sh` |
| B-002 | shared decision + staged diff | `bash tests/hooks/test_u16_baseline.sh` |
| B-003 | pre-edit/pre-write/staged decision | `bash tests/hooks/test_pre_edit_guard.sh`; `bash tests/hooks/test_pre_write_guard.sh`; `bash tests/hooks/test_u16_baseline.sh` |
| B-004 | legacy debt advisory output | focused hook tests above |
| B-005 | allow below hard limit without `U16_LEGACY_DEBT` | `bash tests/hooks/test_u16_baseline.sh` |
| B-006 | changed-file-only Git diff | `bash tests/hooks/test_u16_baseline.sh` |
| B-007 | rename-aware diff parsing | `bash tests/hooks/test_u16_baseline.sh` |
| B-008 | `project_u16_limit` in shared Git command | `bash tests/hooks/test_u16_baseline.sh` |

## 数据流

AI hook 路径从 hook payload 得到 file path 与 replacement/delta，读取当前文件，
计算 old/new 行数后调用 shared decision。Git/CI 路径从 `git diff --name-status -z -M`
得到 changed paths，从 index/base/head blob 读取内容，计算行数后调用同一
decision。输出是 stdout 机器信号；只有 hook event log 会写本地 JSONL。

## 备选方案

- 在 shell 中实现 pre-commit 判定：拒绝，容易和 runtime hook 漂移。
- 对 generated/vendor path 做隐式跳过：拒绝，issue 要求显式 reviewed exemption。
- 对所有遗留超大文件静默允许：拒绝，需要 `U16_LEGACY_DEBT` 保留审计证据。

## 风险

- Security: 只用参数数组调用 `git`，不拼接 shell 命令。
- Compatibility: 已存在超大文件的修复路径放宽，但增长仍阻断。
- Performance: Git check 只读取 changed source blobs；pre-commit 仍保持 staged-file 范围。
- Maintenance: shared decision 的新增 reason code 必须同步测试矩阵。

## 测试计划

- [ ] Unit tests: `cargo test --manifest-path vibeguard-runtime/Cargo.toml u16_baseline`
- [ ] Integration tests: pre-edit、pre-write、pre-commit/CI focused shards。
- [ ] Contract tests: hook validators、workflow/spec validators、local quick check。
- [ ] Manual verification: 复跑 GH-671 issue 中的三条 reproduction。

## 回滚方案

回滚本 PR，并从 CI workflow 移除 `validate-u16-baseline.sh` step。用户端已安装
pre-commit wrapper 如需回滚，重新运行上一版本的 `setup.sh`。
