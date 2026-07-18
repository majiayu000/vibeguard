# Tech Spec

## Linked Issue

GH-589

## Product Spec

`docs/specs/GH589/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| CLI flags and self-scan detection | `guards/universal/check_code_slop.sh:25-84` | `--strict-repo` disables repo-local excludes；VibeGuard target 由 allowlist marker 加 `guards/`、`hooks/` 自动识别，当前只追加目录 excludes | 两项 precision 规则必须复用同一资格条件，不能成为通用行为 |
| Legacy debug category | `guards/universal/check_code_slop.sh:108-120` | 一个跨语言 regex 同时匹配 `println!` 与 `dbg!`，只排除 keep/logger 行 | 需要在 grep 结果上精确过滤 self-scan runtime `println!`，而不是删除通用 Rust 分支 |
| Dead-code category | `guards/universal/check_code_slop.sh:156-168` | 对全部匹配行计数，没有 detector-source line marker 语义 | marker filtering 必须只放在这个 category，并保持未标记 finding |
| Count and exit behavior | `guards/universal/check_code_slop.sh:192-200` | category counts 累加到 `ISSUES`；有剩余 finding 时退出 1 | 不能用硬编码 baseline 替换实际计数或改变 exit contract |
| Common fast-path detector source | `vibeguard-runtime/src/hook_checks_common.rs:149-196`, `vibeguard-runtime/src/hook_checks_common.rs:704-720` | intentional `todo!`/`unimplemented!` substring 与 test literal 会被 shell dead-code regex 自指命中 | 每个实际匹配 source line 需要独立 marker |
| Post-write detector source | `vibeguard-runtime/src/hook_checks_write.rs:186-202` | Rust stub detector 包含 substring、regex 与 label literal | 不得 whole-file 排除；只标记 pattern-source 匹配行 |
| Post-edit detector source | `vibeguard-runtime/src/hook_orchestrator_post_edit.rs:251-261` | edit detector 包含同类 Rust stub patterns | 第三份需要逐行 marker 的 detector source |
| Focused regression harness | `tests/unit/test_universal_check_code_slop.sh:13-35`, `tests/unit/test_universal_check_code_slop.sh:63-135` | 已覆盖 pass/fail、debug、clean、fixtures 与 strict，但没有 fake VibeGuard self-scan 或 marker-category scope | 应扩展现有入口，不新增重复 test harness |

## 写作时基线

在 merge `origin/main` `13636066860eeda6bf32ef11a220e0ae0d7d32d3` 后，对当前
spec branch 执行一次 fresh `bash guards/universal/check_code_slop.sh .` 得到：

- total findings: 424
- legacy debug: 312，其中 `vibeguard-runtime/src/` 精确 192 条，全部是 `println!`
- dead code/suppression: 23，其中三份 detector source 有 13 条 intentional pattern
  literal 命中

旧 planning snapshot 的 353 / 256 / 20 已因 main 新增文件漂移。这些数字只用于解释
问题，不是 acceptance gate、ratchet 或预期 post-fix count。

## 设计方案

### 1. 显式记录 repo-scoped self-scan 资格

保留现有三项 marker auto-detection 与 `--strict-repo` 判断，在命中分支同时设置一个
snake_case boolean（例如 `VIBEGUARD_SELF_SCAN=true`）。目录 exclusions 继续由现有数组
参数构建。后续 category-specific filtering 只读取该 boolean，不通过仓库名称、绝对路径
或任意 `vibeguard-runtime/` 目录名猜测 self-scan。

### 2. 只过滤 runtime CLI `println!` debug finding

legacy-debug 的原始 grep pattern 与语言范围保持不变。得到逐行结果后，仅在
`VIBEGUARD_SELF_SCAN=true` 时删除同时满足以下条件的结果行：

1. path 位于当前 target 的 `vibeguard-runtime/src/` 下；
2. 匹配内容实际以 `println!(` 开始，而不是 `dbg!(` 或其他语言 pattern。

实现使用 path-aware、固定 pattern 的 pipeline/array argument，不使用 `eval` 或拼接可
执行命令。这样不排除整个 runtime/source tree，未来在该目录出现的 `dbg!` 仍是 finding；
ordinary target 即使目录同名也不会进入过滤。

### 3. Dead-code category 的逐行 marker

在以下三份 source 中，每一条会被当前 dead-code regex 独立命中的 intentional detector
pattern/test literal 行末追加 `// slop-pattern-source`：

- `vibeguard-runtime/src/hook_checks_common.rs`
- `vibeguard-runtime/src/hook_checks_write.rs`
- `vibeguard-runtime/src/hook_orchestrator_post_edit.rs`

当前 fresh inventory 为 13 行；实现时必须重新运行 grep 逐行核对，不能把 13 当永久
阈值。`DEAD_CODE` 只在 qualified self-scan 中排除包含 marker 的同一输出行；filter 放在
dead-code branch 内，不加入全局 `EXCLUDE_ARGS`，也不改变 expired-TODO/debug/long-file
结果。`--strict-repo` 因 self-scan boolean 为 false 而恢复 marker lines。

### 4. 精确 fixture，不使用仓库总数断言

扩展 `tests/unit/test_universal_check_code_slop.sh` 的现有临时目录 harness，构造满足三项
self-scan marker 的 fake repo，并放入：

- `vibeguard-runtime/src/main.rs`：一个 `println!` 与一个 `dbg!`；默认只报告 `dbg!`，
  strict 同时报告两者；
- detector fixture：同一文件中一条带 `slop-pattern-source` 的 intentional `todo!`
  literal 与一条未标记真实 `todo!()`；默认只报告真实 stub，strict 恢复两条；
- marker 位于相邻行、non-self-scan 同名目录与其他 category finding 的负例。

测试断言具体 path/content 是否出现，并断言现有 console.log、Python print、fixtures、
clean project 与 exit behavior；不比较 checkout 的 total finding count，也不采用固定计数阈值。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 仅 qualified VibeGuard self-scan 启用 suppression | self-scan auto-detect branch、fake marker repo | `bash tests/unit/test_universal_check_code_slop.sh` 覆盖完整三项 marker、缺任一 marker、ordinary target 与 strict target |
| B-002 只忽略 runtime/src `println!` | legacy-debug result filter | focused test 在同路径并置 `println!`/`dbg!`，断言默认只保留 `dbg!`，并保留路径外 console/print finding |
| B-003 marker 只覆盖 dead-code 同一行 | dead-code result filter、detector fixture | focused test 断言 marked pattern literal 消失，相邻 marker 不覆盖，未标记 `todo!()` 仍出现 |
| B-004 三份 detector source 逐行 review | 三个 Rust detector files、fresh grep inventory | `grep -n -E '(unreachable!|todo!|unimplemented!|#\[allow\(dead_code\)\])'` 对三文件人工逐行核对：intentional source 有 marker，真实 finding 无 marker；independent review 复核 diff |
| B-005 strict 恢复且既有 flags/exit 不变 | `--strict-repo` branch、existing fixture tests | focused test 断言 strict 恢复 runtime println 与 marked line；既有 `--include-fixtures` 和 rc assertions 继续通过 |
| B-006 ordinary target/其他 category/未标记 finding 兼容 | category-local filters 与 non-self fixtures | focused test 使用同名路径但无完整 self marker，确认 println/marker 不被 suppression；empty catch/debug/dead/long existing cases 通过 |
| B-007 actual findings 决定 count/exit，无固定阈值 | `ISSUES` accumulation、precise fixture assertions | focused test 对具名 findings 断言 presence/absence 与 rc；测试和 CI 不含 total/debug/dead 数字阈值 |

## 数据流

1. CLI 解析 target、fixtures/strict flags，并通过现有 marker 判定是否 qualified self-scan。
2. 每个 category 继续独立 grep；全局 excludes 不新增 runtime/src 或 detector file。
3. Debug category 在 qualified self-scan 对逐行结果做 path + macro 精确过滤。
4. Dead-code category 在 qualified self-scan 只过滤带 marker 的同一行。
5. 过滤后的实际行数进入既有 category count 与 `ISSUES`；summary/exit code 不读取固定
   baseline。
6. `--strict-repo` 或 ordinary target 不进入两项 category-local filter，得到原始结果。

## 备选方案

- 全局删除 Rust `println!` detection：拒绝。它改变第三方 repo contract，且 reviewer 已
  选择 repo-scoped 修复。
- 排除整个 `vibeguard-runtime/src` 或三份 detector files：拒绝。会静默隐藏 `dbg!`、
  true stub、dead-code attribute 和未来真实 finding。
- 把 `slop-pattern-source` 做成所有 repo/category 的通用 allowlist：拒绝。marker 只用于
  VibeGuard self-scan dead-code pattern-source。
- 断言 post-fix total/debug/dead 小于固定数字：拒绝。仓库增长会让阈值与 precision
  contract 脱钩。

## 风险

- Security: target path 仍作为参数传给既有工具；新增过滤不得使用 `eval` 或把日志/文件
  内容当命令执行。
- Compatibility: ordinary repo 和 strict mode 必须零行为漂移；通过同名路径负例与 strict
  fixture 固定。
- Performance: 只对已收集的行做一次轻量过滤，不新增全仓第二次扫描。
- Maintenance: 新 detector pattern 行若漏 marker 会作为 visible false positive，而不会
  被 whole-file allowlist 静默吞掉；maintainer 逐行 review 后再添加 marker。
- Precision abuse: marker 可被误加到真实 stub；限制为 self-scan + dead-code-only，并要求
  exact-line test 与 independent review。

## 测试计划

- [ ] Focused: `bash tests/unit/test_universal_check_code_slop.sh` 覆盖 self/non-self、
      println/dbg、same-line/adjacent marker、strict 和现有 fixture contract。
- [ ] Guard validation: `bash scripts/ci/validate-guards.sh`。
- [ ] Rust comments/source integrity: `cargo check --manifest-path vibeguard-runtime/Cargo.toml`
      与 `cargo test --manifest-path vibeguard-runtime/Cargo.toml`。
- [ ] Broad: `bash scripts/local-contract-check.sh --quick` 与 `git diff --check`。
- [ ] Manual evidence: fresh default/strict self-scan 只用于核对具名行差异；其非零退出与
      动态总数本身不作为失败。

## 回滚方案

将 guard 的 self-scan boolean/category filters、三个 detector files 的逐行 marker 与
focused tests 作为一个原子变更回滚。不得只移除 tests 或用 whole-file exclusion 替代；
`--strict-repo` 是即时审计视图，但不替代代码回滚。
