# Product Spec

## Linked Issue

GH-589

关联规格 PR：#592。

## 用户问题

`check_code_slop.sh` 扫描 VibeGuard 自身仓库时，会把 Rust CLI 的产品 stdout
`println!` 当成遗留调试代码，也会把 detector 实现中用于识别
`todo!`/`unimplemented!` 的 pattern literal 当成 dead-code finding。大量自指型
false positive 会淹没真实 slop 信号，使 weekly GC digest 看似有很多问题但难以采取
行动。

这个问题必须只收窄 VibeGuard 的 repo-scoped self-scan；它不能借机改变任意第三方
Rust 仓库的 `println!` 规则，也不能用 whole-file exclusion 隐藏 detector 文件中的
真实 dead code。

## 目标

- 在 VibeGuard auto-detected self-scan 中忽略 `vibeguard-runtime/src/` 内作为 CLI
  产品输出的 `println!` debug-category 命中。
- 用逐行 `slop-pattern-source` marker 标识三份 detector Rust 文件中的 intentional
  pattern literal，并且只在 dead-code category 忽略这些已标记行。
- 保持 `dbg!`、同一文件中的未标记 dead-code finding、其他 slop categories、
  non-self-scan target 和 `--strict-repo` 审计行为。
- 用精确 finding presence/absence 证明 precision 改善，不使用易漂移的总数阈值。

## 非目标

- 不把 Rust `println!` 的规则泛化修改到任意用户仓库或所有 Rust crate。
- 不排除整个 `vibeguard-runtime/`、`src/`、detector 文件或 dead-code category。
- 不重新调参 empty catch、expired TODO、long file、fixture 或其他 slop category。
- 不改变 Rust detector 的运行逻辑、hook 语义或 CLI stdout 内容。
- 不以“总 finding 少于 N”“debug 少于 N”等固定计数作为验收条件。

## Behavior Invariants

1. B-001 Repo-scoped precision 规则只在 target 同时满足现有 VibeGuard self-scan
   auto-detection 且未启用 `--strict-repo` 时生效；target 缺少任一 self-scan marker、
   指向普通用户仓库或启用 strict 时，不得应用这些 repo-local suppression。
2. B-002 在符合 B-001 的 self-scan 中，legacy-debug category 只忽略 repo-relative
   path 位于 `vibeguard-runtime/src/` 且实际命中宏为 `println!` 的行；同目录的 `dbg!`、
   目录外的 `println!`、Python `print`、JavaScript/TypeScript `console.*` 和其他现有
   debug patterns 仍按原规则报告。
3. B-003 Intentional detector pattern 必须在每个会独立匹配 dead-code regex 的源码行
   上携带 `slop-pattern-source`；符合 B-001 时，dead-code category 只忽略 marker
   所在的同一行。相邻行 marker、文件中任意位置出现一次 marker 或 whole-file/path
   allowlist 都不得覆盖未标记 finding。
4. B-004 初始逐行 marker 范围仅限当前三份 detector source：
   `hook_checks_common.rs`、`hook_checks_write.rs`、
   `hook_orchestrator_post_edit.rs` 中承载 intentional `todo!`/`unimplemented!` pattern
   或 detector fixture literal 的匹配行；新增 marker 必须逐行接受 review，不能用它
   隐藏真实 stub、suppression attribute 或 unreachable code。
5. B-005 `--strict-repo` 必须禁用 B-002 与 B-003 的全部 repo-local suppression，重新
   展示 CLI `println!` 与已标记 pattern-source 的原始 finding；现有
   `--include-fixtures`、基础目录排除和 exit-code 语义保持不变。
6. B-006 Non-self-scan target 的行为完全兼容：`vibeguard-runtime/src/` 只是普通路径，
   `slop-pattern-source` 也不是通用 allowlist。VibeGuard self-scan 中，marker 只影响
   dead-code category，不得让同一行在其他 category 的真实命中消失；同文件未标记的
   dead-code finding 必须继续报告。
7. B-007 输出 count 与最终 exit status 必须继续由实际剩余 findings 计算；验证以具名
   fixture/path/line 的精确出现、消失及 strict 恢复为依据，不得硬编码当前或历史
   total/debug/dead 数量。main 增删文件导致 baseline 漂移时，测试不得因此误报通过或
   失败。

## 验收标准

- [ ] VibeGuard self-scan 不再把 `vibeguard-runtime/src/` 的 `println!` 报为 legacy
      debug，但仍报告同路径 `dbg!` 与路径外现有 debug patterns。
- [ ] 三份 detector Rust 文件的 intentional dead-code pattern literal 逐行标记，默认
      self-scan 只忽略标记行；同文件未标记 true positive 仍可见。
- [ ] `--strict-repo` 重新展示两类被 repo-local suppression 隐藏的 finding。
- [ ] 普通仓库即使使用同名目录或 marker 文本也保持现有扫描行为。
- [ ] empty catch、expired TODO、long file、fixtures 和既有 clean/fail fixture 断言不变。
- [ ] 测试断言精确 finding，而非任何固定计数阈值或相对某次仓库快照的数字。
- [ ] focused guard test、guard validation、Rust check/test 和 broad local contract checks
      通过，并由 independent reviewer 审查 marker 没有隐藏真实 finding。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-001, B-003（缺 self-scan marker 或缺行内 marker 时不 suppression） |
| 错误与失败路径 | covered: B-005, B-007（strict 审计恢复；真实 finding 保持非零退出） |
| 授权/权限 | N/A：本地只读 scanner 不执行授权或权限状态转换 |
| 并发/竞态 | N/A：单次文件快照扫描无共享可变状态；文件在扫描中变化属于下一次重跑输入 |
| 重试/幂等 | covered: B-007（同一 tree 与 flags 重跑得到同一 finding classification） |
| 非法状态转换 | N/A：scanner 不持久化 workflow/product 状态 |
| 兼容/迁移 | covered: B-001, B-005, B-006 |
| 降级/回退 | covered: B-002, B-003, B-005, B-006（precision suppression 不得隐藏 true positive） |
| 证据与审计完整性 | covered: B-003, B-004, B-005, B-007 |
| 取消/中断 | N/A：扫描无持久化写入；中断后可从头安全重跑 |

## 发布说明

该变更只改善 VibeGuard 自扫描 precision。普通用户仓库不会获得新的 Rust
`println!` 或 marker allowlist；maintainer 可用 `--strict-repo` 查看未应用 repo-local
suppression 的完整原始结果。计数会随仓库内容自然变化，因此发布与回归证据只承诺
具名 false positive 消失、具名 true positive 保留。
