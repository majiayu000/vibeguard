# Tech Spec

## Linked Issue

GH-605

## Product Spec

`docs/specs/GH605/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Authoritative classifier | `vibeguard-runtime/src/hook_checks_common.rs:76`, `vibeguard-runtime/src/hook_checks_common.rs:652` | `is_test_path()` normalizes slash/case and recognizes `_test.rs`，但没有 `_tests.rs`；单测也缺该正例 | 所有 runtime hook/scanner consumers 的单一事实源 |
| Shell fallback | `guards/rust/common.sh:12`, `guards/rust/common.sh:32` | runtime 可用时调用 `test-path-filter --prod`，否则用 `VIBEGUARD_TEST_FILE_PATTERN`；fallback 同样遗漏 `_tests.rs` | 必须与 runtime 保持故障降级一致 |
| RS-03 focused harness | `tests/unit/test_rust_check_unwrap_in_prod.sh:37`, `tests/unit/test_rust_check_unwrap_in_prod.sh:87` | 已覆盖生产 finding、`tests/`、`_test.rs`、`tests.rs` 等，但没有 `*_tests.rs` 和相似生产文件负例 | 最接近用户可见误报的回归入口 |
| Classifier self-application | `scripts/ci/self-application/check-rust-test-path-classifier.sh:9` | 防止 Rust hook/guard 重建内联分类器，但不检查 suffix 行为 | 保持单一分类器架构，不新增重复逻辑 |
| Hook test runtime stub | `tests/lib/hook_test_lib.sh:90` | 测试 stub 复制 runtime 的 test-path case，当前也遗漏 `*_tests.rs` | 若不同步，hook tests 会掩盖 runtime/fixture drift |

## 设计方案

1. 在 `is_test_path()` 的 basename 后缀判断中加入精确
   `basename.ends_with("_tests.rs")`，复用现有 slash/case normalization。
2. 在 `VIBEGUARD_TEST_FILE_PATTERN` 的 basename suffix 部分加入
   `_tests\.rs$`，仅作为 runtime 不可用/失败时 fallback。
3. 同步 `hook_test_install_runtime_stub` 的 basename case，使测试替身不再与真实 runtime
   漂移；不在各 hook 中加入新 glob。
4. 扩展既有 Rust unit/focused tests：加入临时 fixture `foo_tests.rs` 正例，并加入
   `contest.rs`、`latest.rs`、`tests_support.rs`、`foo_tests.py` 等负例。使用显式
   `VIBEGUARD_RUNTIME` 选择真实 runtime 与失败 stub，分别证明 authoritative/fallback。
5. RS-03 fixture 同时放置 `foo_tests.rs` 与普通 `foo.rs`，断言前者不报告、后者仍报告；
   不使用 checkout 总 finding 数量作为断言。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 runtime 识别 `_tests.rs` | `is_test_path()` 与 unit/CLI filter | `cargo test --manifest-path vibeguard-runtime/Cargo.toml test_path_matches_rust_guard_exclusions`；具名 `test-path-filter --test/--prod` fixture |
| B-002 fallback 与 runtime 一致 | `VIBEGUARD_TEST_FILE_PATTERN`、forced-failure fixture | `bash tests/unit/test_rust_check_unwrap_in_prod.sh` 中真实 runtime 与失败 runtime 两组断言 |
| B-003 不排除相似生产文件 | runtime unit negatives 与 shell focused negatives | 同一 focused test 对 `contest.rs`、`latest.rs`、`tests_support.rs`、`foo_tests.py` 和普通 `.rs` 断言 finding 保留 |
| B-004 RS-03 standalone/staged 边界 | `filter_rs_prod_paths()`、RS-03 harness | `bash tests/unit/test_rust_check_unwrap_in_prod.sh`；staged fixture 确认 `_tests.rs` 不进入 finding、普通 `.rs` 仍进入 |
| B-005 兼容且无第二套实现 | classifier/stub/self-application checks | `bash scripts/ci/self-application/check-rust-test-path-classifier.sh .`、Rust 全测、hook/guard validators |
| B-006 精确证据，无固定计数 | focused assertions 与 manual self-scan | test source review 不含 `59`/`11` threshold；default self-scan 按具名 `_tests.rs`/production path 核对 |

## 数据流

1. guard 从 git/staged/find 获得 `.rs` 路径列表。
2. `filter_rs_prod_paths()` 优先把路径流交给 runtime `test-path-filter --prod`。
3. runtime 的 `is_test_path()` 规范化路径并按 segment/basename 分类；`*_tests.rs` 进入
   test 集合，不进入 production 输出。
4. runtime 不可用或失败时，shell fallback 对同一路径执行等价 suffix 过滤。
5. RS-03 只扫描 production 输出；finding summary 与 strict exit contract 保持原样。

## 备选方案

- 仅在 RS-03 中排除 `*_tests.rs`：拒绝。会重新制造 #430 已消除的多实现漂移。
- 排除所有文件名包含 `tests` 的路径：拒绝。会误伤 `tests_support.rs` 等生产文件。
- 只修 runtime、不修 fallback/stub：拒绝。运行时缺失与测试环境会继续产生分裂。

## 风险

- Security: 只处理路径字符串，不执行输入；不得引入 `eval` 或命令拼接。
- Compatibility: `_tests.rs` 理论上可能被用作生产文件；Rust 社区与本仓库均把该后缀用作
  测试模块，因此用精确完整后缀限定，并用相似文件负例控制范围。
- Performance: 增加一次固定 suffix 比较/regex alternative，复杂度不变。
- Maintenance: runtime、fallback、test stub 三处必须在同一 implementation PR 同步并由
  focused drift tests 固定；hook consumers 不得复制规则。

## 测试计划

- [ ] Unit: `is_test_path()` 正负例与 `test-path-filter` mode 输出。
- [ ] Focused guard: runtime/fallback、standalone/staged、test/prod finding 精确断言。
- [ ] Integration: self-application classifier、hook/guard validators。
- [ ] Broad: Rust check/test、`bash scripts/local-contract-check.sh --quick`、`git diff --check`。
- [ ] Manual: 当前仓库 RS-03 输出不再含 `src/*_tests.rs`，生产 finding 仍可见。

## 回滚方案

将 runtime suffix、shell fallback、hook-test stub 与所有新增测试作为一个原子变更回滚。
不得只回滚 authoritative classifier 或只保留 fallback，否则会恢复分类分裂。
