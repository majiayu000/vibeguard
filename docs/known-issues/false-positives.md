# Known False Positives

Guard 和 Hook 的已知误报场景及修复状态。**Agent 开发时必读**，避免重复踩坑。

## 已修复

### TS-03: CLI 项目 console 误报
- **场景**: CLI 工具（package.json 含 `bin` 字段）的 `console.log/error` 是正常输出，不是调试残留
- **影响**: 所有 CLI 项目被全量拦截
- **修复**: guard 和 post-edit hook 检测 `package.json` 的 `bin` 字段，CLI 项目跳过 console 检测
- **文件**: `guards/typescript/check_console_residual.sh`, `hooks/post-edit-guard.sh`

### RS-14: 声明-执行鸿沟检测（已用 ast-grep 重写）
- **场景**: 原有 4 个子检测全有严重误报（grep 行数计数、外部 crate trait、save/load 只查主文件、cd 改变 cwd）
- **修复**: 用 ast-grep AST 级别扫描重写，聚焦最高价值的单一检测：`*Config::default()` 调用（而非 `Config::load()`）
  - 精确匹配 `AppConfig::default()`、`ServerConfig::default()` 等模式（通过 `constraints.T.regex: "Config$"`，在 yml 和 Python 后处理层双重校验）
  - 自动排除测试文件目录（`/tests/`、`_test.rs` 等）
  - ast-grep 不可用时优雅跳过（`[RS-14] SKIP`）
- **当前范围**: 仅检测 `*Config::default()` 模式；Trait 无 impl、持久化未接线等复杂跨文件检测需 rust-analyzer 等更重的工具
- **文件**: `guards/rust/check_declaration_execution_gap.sh`, `guards/ast-grep-rules/rs-14-config-default.yml`

### GO-02: goroutine 全量枚举
- **场景**: 所有 `go func()` 都报告，不管有没有 ctx/wg/errgroup 管理
- **影响**: 任何用 goroutine 的 Go 项目噪声极高
- **修复**: 添加启发式过滤，goroutine 后 20 行内有 `ctx.Done/wg.Add/errgroup/ticker` 则跳过
- **文件**: `guards/go/check_goroutine_leak.sh`

### TS-01: any 检测误命中注释和字符串（已用 ast-grep 修复）
- **场景**: 块注释 `/* type: any */` 和字符串 `"schema: any"` 内的 `: any` 被误报
- **影响**: 含注释或字符串描述的 TS 文件误报
- **修复**: 改用 ast-grep AST 级别检测，匹配 `type_annotation` 节点和 `as any` 表达式，自动跳过注释/字符串
- **文件**: `guards/typescript/check_any_abuse.sh`, `guards/ast-grep-rules/ts-01-any.yml`

### GO-01: range 变量误报（已用 ast-grep 修复）
- **场景**: `for _, v := range slice` 中的 `_` 被当作 error 丢弃
- **影响**: 所有用 range 的 Go 文件
- **修复**: 改用 ast-grep 匹配 `_ = $CALL` 模式，AST 自然区分赋值语句和 for range 子句，无需手动排除
- **文件**: `guards/go/check_error_handling.sh`, `guards/ast-grep-rules/go-01-error.yml`

### TS-13: 组件重复特征过宽
- **场景**:
  1. FormField 检测：HTML 原生 `<input required>` 误命中
  2. 排序表格：API 参数 `sortKey` 误命中
  3. 查询 Hook：标准 `isLoading` 状态管理误命中
- **修复**: 收紧 required 为 prop 级（`isRequired/props.required`），sort 限定 `setSortKey`，query 阈值 3→4
- **文件**: `guards/typescript/check_component_duplication.sh`

### U-HARDCODE: 硬编码值检测（已移除）
- **场景**: `= "POST"`、枚举赋值、React props、i18n key、常量定义全误报
- **影响**: 几乎所有 TS/JS 文件
- **修复**: 从 post-edit-guard 移除该检测（信噪比无法接受）
- **文件**: `hooks/post-edit-guard.sh`

### pre-bash: git checkout ./path 误拦
- **场景**: `git checkout ./src/file.ts` 被当作 `git checkout .`（丢弃全部改动）拦截
- **修复**: 正则加行尾锚定，只匹配纯 `.` 后跟分隔符或行尾
- **文件**: `hooks/pre-bash-guard.sh`

### pre-commit: 子目录 commit 语言检测失败
- **场景**: 在子目录执行 `git commit` 时，`[[ -f "Cargo.toml" ]]` 用相对路径检测失败，所有守卫被跳过
- **修复**: 改用 `${REPO_ROOT}/Cargo.toml` 绝对路径
- **文件**: `hooks/pre-commit-guard.sh`

### post-edit: Escalation 跨 session 误触发
- **场景**: warn 计数不区分 session，上周被警告 3 次 → 今天第一次编辑就 escalate
- **修复**: 加 session 过滤 + 路径精确匹配（避免子路径误判）
- **文件**: `hooks/post-edit-guard.sh`

## 已知未修（P2）

以下问题已识别但尚未修复，优先级较低：

| 守卫 | 场景 | 状态 |
|------|------|------|
| RS-03 | 多个 `#[cfg(test)]` 块只取第一个 | 待修 |
| RS-01 | `.clone()` 错误减少锁计数，`}` 无条件减计数 | 待修 |
| RS-06 | 硬编码路径检测误报字符串常量（`"config.toml"`） | 待修 |
| RS-12 | `Todo[A-Z]` 匹配普通 TodoList 数据结构 | 待修 |
| TASTE-ASYNC-UNWRAP | 文件有任意 async fn 就报全部 unwrap | 待修 |
| post-write | 同名文件搜索命中 tests/ 目录 | 待修 |
| post-write | 定义提取正则跨语言污染 | 待修 |
| post-build | 构建失败计数跨项目无隔离 | 待修 |
| doc-file-blocker | `.md` 检测误判临时文件路径 | 待修 |

## 教训

1. **grep 不是 AST 解析器** — 对有嵌套结构的代码（锁作用域、async 函数范围、struct 字段），grep 的误报率不可接受。复杂检测应该用语言工具（rust-analyzer、ESLint、go vet）
2. **守卫的错误修复建议会被 Agent 当真** — TS-03 说"使用项目 logger 替代"，Agent 就真的创建了 logger 并重构了 11 个文件。Guard 消息必须考虑 Agent 消费场景
3. **项目类型感知是基础能力** — CLI vs Web vs MCP vs Library，同一语言的不同项目类型有完全不同的合理模式。Guard 必须先识别项目类型
4. **枚举器不是检测器** — GO-02 之前只列出所有 goroutine，不判断是否有风险。开发者（和 Agent）会养成忽略习惯，丧失守卫价值
