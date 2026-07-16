# Product Spec

## Linked Issue

GH-605

## 用户问题

VibeGuard 的 Rust 测试路径分类器不识别常用的 `*_tests.rs` 文件名。RS-03
因此把测试模块中的 `unwrap()` / `expect()` 当作生产代码风险；在当前
`origin/main` 自扫描的 70 条 finding 中有 59 条属于这一类误报。高比例噪声会
掩盖剩余 11 条需要真实审查的生产代码 finding，并让所有复用统一分类器的 hook 与
scanner 行为偏离仓库实际模块布局。

## 目标

- runtime 分类器和无 runtime 的 shell fallback 都识别 `*_tests.rs`。
- RS-03 不再报告这类测试文件，同时继续报告生产文件中的真实命中。
- 用正例、负例和 fallback 测试固定分类边界，避免相似生产文件被排除。

## 非目标

- 不修改 RS-03 对 `unwrap()` / `expect()` 的检测语义或 severity。
- 不清理当前 11 条生产代码 finding。
- 不重命名现有 Rust 测试模块，不改变 U-16 阈值或 hook enforcement mode。
- 不新增新的测试目录约定或通用 filename allowlist。

## Behavior Invariants

1. B-001 对任意 basename 以 `_tests.rs` 结尾的 Rust 路径，runtime
   `test-path-filter --test` 必须保留该路径，`--prod` 必须排除该路径；路径位于
   `src/` 或更深层目录时行为相同。
2. B-002 runtime 不可用或执行失败而进入 shell fallback 时，`*_tests.rs` 必须得到与
   B-001 相同的分类结果；authoritative runtime 与 fallback 不得产生分裂。
3. B-003 新规则只能匹配完整 `_tests.rs` 后缀；`contest.rs`、`latest.rs`、
   `tests_support.rs`、`foo_tests.py` 和普通 `*.rs` 生产文件不得因本变更被排除。
4. B-004 RS-03 standalone 与 staged-file 路径必须复用同一生产路径过滤边界：
   `*_tests.rs` 内的 `unwrap()` / `expect()` 不产生 finding，而等价内容位于普通
   `.rs` 文件时继续产生 finding。
5. B-005 所有现有测试路径约定、大小写/路径分隔符规范化、strict/non-strict exit
   contract 与 hook consumers 必须保持兼容；该修复不得引入第二套分类实现。
6. B-006 验证必须绑定具名路径和 finding presence/absence；当前 59/11 计数只作基线
   证据，不得成为固定阈值或让未来仓库增长导致误判。

## 验收标准

- [ ] runtime `--test`/`--prod` 对临时 fixture `foo_tests.rs` 给出互补且正确的结果。
- [ ] 强制禁用 runtime 后，shell fallback 对同一路径给出相同结果。
- [ ] `foo_tests.rs` 中的 RS-03 命中被忽略，普通 `foo.rs` 中的命中仍可见。
- [ ] 相似生产文件负例与现有 test-path 正例全部通过。
- [ ] focused guard/runtime tests、guard/hook validators、Rust check/test 和 broad local
      contract quick 通过。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-005（现有空行过滤与空项目行为保持兼容） |
| 错误与失败路径 | covered: B-002（runtime 缺失或失败时 fallback 一致） |
| 授权/权限 | N/A：本地只读路径分类与 guard 不处理权限状态 |
| 并发/竞态 | N/A：分类器逐行处理不可变输入，无共享可变状态 |
| 重试/幂等 | covered: B-005, B-006（同一输入重跑得到相同分类） |
| 非法状态转换 | N/A：不持久化 workflow 状态 |
| 兼容/迁移 | covered: B-003, B-005 |
| 降级/回退 | covered: B-002, B-004 |
| 证据与审计完整性 | covered: B-004, B-006 |
| 取消/中断 | N/A：无持久写入，中断后可安全重跑 |

## 发布说明

这是 RS-03 与共享 Rust test-path classifier 的 precision 修复。它只补齐
`*_tests.rs` 后缀，不改变普通生产文件、既有测试约定或 guard enforcement。
