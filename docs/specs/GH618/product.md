# Product Spec: compliance checker 遵循声明语言的 guard 矩阵

## Linked Issue

GH-618

## 用户问题

`scripts/verify/compliance_check.sh` 当前无条件检查 Python duplicate、naming、ruff
和 architecture guard。对只声明 Rust、Go、TypeScript 或 JavaScript 的项目，这会把无关的
Python 表面报告为合规证据或建议，同时完全不展示对应语言的 guard pack。由于
auto-optimize 把该脚本作为收尾基线，这种错配会让优化报告产生错误的覆盖感。

## 目标

- compliance 输出只反映项目在 `.vibeguard.json` 中声明的语言，不猜测源码语言。
- 语言到 guard pack 的选择与 VibeGuard 现有 manifest/schema 合同保持单一事实源。
- 保留 Python 项目的既有 duplicate、naming、ruff 与 architecture guard 检查。
- 无声明、混合语言和非法配置都有确定、可测试且不会静默降级的结果。

## 非目标

- 不改变 setup、hook、runtime、guard 脚本或实际安装行为。
- 不新增语言自动探测，也不把文件扩展名、Cargo/npm/Go 配置当作隐式声明。
- 不要求本次优化让 VibeGuard 仓库自身达到 full compliance。
- 不用 `setup.sh verify-dev-repo` 或其他安装状态检查替换 compliance checker。

## Behavior Invariants

1. B-001：当项目声明且仅声明 Rust 时，compliance 输出展示 Rust guard pack，且不输出 Python duplicate、naming、ruff 或 Python architecture guard 的检查结果。
2. B-002：当项目声明 Python 时，compliance 继续检查并报告现有 duplicate guard、naming guard、ruff 配置和 Python architecture guard，不弱化现有 PASS/WARN/FAIL 语义。
3. B-003：当项目声明 Go、TypeScript 或 JavaScript 时，compliance 展示 manifest 为该语言声明的 guard pack；JavaScript 使用 manifest 中与 TypeScript 共享的 pack。
4. B-004：当项目同时声明多种语言时，每个匹配的 manifest guard module 最多报告一次；TypeScript 与 JavaScript 同时出现时不得重复报告共享 module。
5. B-005：语言选择只来自目标项目根目录的 `.vibeguard.json`，允许值只来自项目 schema，guard module 映射只来自 install-modules manifest，不维护重复的语言或 module 对照表。
6. B-006：当 `.vibeguard.json` 缺失、未包含 `languages` 或 `languages` 为空时，compliance 明确报告语言范围未声明的 WARN，仅继续通用检查，不猜测语言，也不声称任何语言 pack 已覆盖。
7. B-007：当项目配置 JSON 非法、类型错误或包含不支持的语言时，compliance 产生可见 FAIL 并返回非零；不得回退为 Python 或其他语言检查。
8. B-008：当 manifest 的语言/module 数据无法读取或不满足查询合同，compliance 产生可见 FAIL 并返回非零，不静默跳过该错误。
9. B-009：现有通用检查、summary 计数语义、`VIBEGUARD_DIR` 显式 guard 根覆盖和 auto-optimize 使用的命令入口保持兼容。

## 验收标准

- [ ] 隔离 fixture 分别覆盖 Rust、Python、JavaScript、TypeScript+JavaScript、混合语言、未声明语言和非法配置。
- [ ] Rust/Go/TypeScript/JavaScript fixture 不出现任何 Python 专属检查文案，且出现 manifest 对应 guard module。
- [ ] Python fixture 继续覆盖现有四类 Python 检查与显式 `VIBEGUARD_DIR` 覆盖。
- [ ] 非法配置与损坏 manifest 均有具名 FAIL、非零退出码，并证明没有 Python fallback。
- [ ] focused test、unit runner、manifest/schema 合同、workflow 合同与 quick gate 全部通过。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-006 |
| 错误与失败路径 | covered: B-007, B-008 |
| 授权/权限 | N/A：只读取调用者指定项目和仓库内合同，不执行外部写入 |
| 并发/竞态 | N/A：单次同步只读检查，不共享可变状态 |
| 重试/幂等 | covered: B-009；相同输入产生相同分类与退出语义 |
| 非法状态转换 | N/A：无持久化状态机 |
| 兼容/迁移 | covered: B-002, B-009 |
| 降级/回退 | covered: B-006, B-007, B-008 |
| 证据与审计完整性 | covered: B-001, B-003, B-004, B-005 |
| 取消/中断 | N/A：短时本地命令，无独立取消协议 |

## 发布说明

这是开发验证工具的输出精度修复，不改变生产安装或 hook 路径。未声明语言的项目会看到新的
WARN，且不再收到 Python 专属结果；需要语言覆盖时应在项目根 `.vibeguard.json` 中显式设置
`languages`。
