# Tech Spec

## Linked Issue

GH-608

## Product Spec

`docs/specs/GH608/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Compliance entrypoint | `scripts/verify/compliance_check.sh` | 默认值只从 `scripts/verify/` 向上一级，得到仓库内的 `scripts/`，随后把它作为 `VIBEGUARD_DIR` | 根因所在；bundled guard 搜索因此多出一层 `scripts/` |
| Shared discovery | `scripts/lib/guard_paths.sh` | `find_guard` 先检查 `VIBEGUARD_DIR/guards/`，再检查目标项目本地的 guard 路径 | 其输入 contract 正确，本修复不应复制或改变搜索矩阵 |
| Unit runner | `tests/unit/run_all.sh` | 自动发现同目录所有 `test_*.sh` 并汇总断言结果 | 新聚焦测试无需修改 runner 即可进入 CI |
| CI unit job | `.github/workflows/ci.yml` | unit job 调用 `bash tests/unit/run_all.sh` | 聚焦回归会由现有 CI 路径执行 |

## 根因与复现证据

`compliance_check.sh` 位于 `scripts/verify/`，当前默认表达式只执行一次父目录跳转。fresh
trace 显示 `VIBEGUARD_DIR` 被赋值为仓库的 `scripts/`，共享 discovery 随后探测
错误地在 scripts/guards 下探测 duplicate 与 naming guard。实际 bundled files 位于仓库根目录下的
`guards/python/`，所以两个存在的 guard 被报告为 not found。

## 设计方案

1. 只在 `scripts/verify/compliance_check.sh` 中修正默认根目录表达式：从脚本目录向上两级
   到仓库根目录。保留 `${VIBEGUARD_DIR:-...}`，因此非空显式覆盖继续优先。
2. 保留脚本路径与环境变量引用的完整 quoting，确保脚本或显式根目录包含空格时不会被
   分词。
3. 新增 compliance checker 聚焦单元测试，构造隔离的 HOME 与项目 fixture，使其余
   Layer 的必需文件存在，避免测试结果依赖真实用户配置。
4. 默认路径用例从仓库外临时目录调用检查器的绝对路径，分别断言 duplicate/naming
   guard 为 available、输出来源为仓库 `guards/python/`，且不存在对应 not-found 文案。
5. override 用例创建路径含空格的独立 VibeGuard fixture，并放置两个具名 guard 文件；
   显式设置 `VIBEGUARD_DIR` 后断言输出使用 fixture 路径，从而证明 override precedence
   与 quoting。
6. 测试只对具名行和来源路径作断言，不固定 summary 总数。捕获并显式验证命令退出码，
   不用 `|| true` 掩盖非预期失败。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 默认仓库根解析 | `scripts/verify/compliance_check.sh` 默认 `VIBEGUARD_DIR` | focused harness 断言输出路径位于仓库 `guards/python/` 而非错误的 scripts/guards 目录 |
| B-002 duplicate guard 可用 | Layer 1 调用现有 `find_guard` | focused test 断言 `check_duplicates.py available` 且无对应 not-found 文案 |
| B-003 naming guard 可用 | Layer 2 调用现有 `find_guard` | focused test 断言 `check_naming_convention.py available` 且无对应 not-found 文案 |
| B-004 cwd 无关 | absolute entrypoint invocation | 在仓库外临时工作目录执行 focused fixture |
| B-005 override precedence 与空格路径 | 保留环境变量优先级和 quoting | focused override fixture 断言两项来源均为显式目录 |
| B-006 其余行为兼容 | 单行 production change、现有 shared discovery | focused test 验证预期退出码；unit runner 与 broad local contract 回归 |
| B-007 证据独立完整 | isolated HOME/project fixtures 与具名断言 | test source review + focused output；不使用总 PASS/WARN threshold |

## 数据流

1. 调用者可选传入 project directory，并可选显式设置 `VIBEGUARD_DIR`。
2. 未显式设置时，entrypoint 根据自身目录解析仓库根；显式值存在时直接保留。
3. Layer 1/2 把该根目录与 project directory 交给共享 `find_guard`。
4. `find_guard` 先检查 bundled root，再执行现有 project-local fallback。
5. 每个 Layer 沿用现有 PASS/WARN/FAIL 汇总与最终退出码逻辑。

## 备选方案

- 修改 `find_guard` 让它猜测传入的是仓库根还是 `scripts/`：拒绝。会模糊共享 contract，
  并把 entrypoint 的错误输入扩散成兼容分支。
- 在 compliance checker 中硬编码两个 guard 的绝对相对路径：拒绝。会复制
  `guard_paths.sh` 的搜索矩阵。
- 同时扫描并修复所有脚本的相似表达式：拒绝。超出 GH-608 的已复现范围，其他 finding
  应独立 triage、spec 与实现。
- 只测试默认当前仓库目录：拒绝。无法证明 cwd independence，也容易意外使用开发者 HOME。

## 风险

- Security: 目录值只作为被引用的文件路径使用；不得引入 `eval`、命令拼接或执行 fixture
  guard 内容。
- Compatibility: 若调用者依赖错误的 `scripts/` 默认值，修复会改变 guard 来源；该旧行为
  与公开路径布局冲突，显式 `VIBEGUARD_DIR` 仍提供稳定覆盖。
- Test isolation: compliance checker 会读取 HOME 和 project 配置；fixture 必须覆盖这些
  输入并在退出时清理，防止本机状态造成假阳性。
- Scope drift: 搜索矩阵、support matrix、metrics collector 与 Layer 语义保持不变。

## 测试计划

- [ ] Syntax: `bash -n scripts/verify/compliance_check.sh tests/unit/test_compliance_check.sh`。
- [ ] Focused: `bash tests/unit/test_compliance_check.sh`。
- [ ] Unit integration: `bash tests/unit/run_all.sh`。
- [ ] Docs/contracts: doc path、doc command path validators。
- [ ] Broad: `bash scripts/local-contract-check.sh --quick` 与 `git diff --check`。
- [ ] Review: product-to-test 逐项审查，确认没有改变 shared search matrix 或退出语义。

## 回滚方案

将 entrypoint 的默认根目录修复和新增聚焦测试作为一个原子变更回滚。回滚不会迁移数据，
但会恢复 bundled guards 被错误报告缺失的行为。不得通过删除失败断言或放宽测试来保留错误
实现。
