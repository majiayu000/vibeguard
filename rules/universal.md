# Universal Rules（通用规则）

所有语言适用的扫描和修复规则。

## NEVER 规则（绝对不做）

| ID | 规则 | 理由 |
|----|------|------|
| U-01 | 不修改公开 API 签名 | 除非用户明确要求 breaking change 并接受 MAJOR 版本升级 |
| U-02 | 不为只出现 1 次的代码提取抽象 | 过度设计，3 行重复好过 1 个过早抽象 |
| U-03 | 不用宏替代可读的重复代码 | 宏降低可读性和 IDE 支持，除非重复 > 5 处且模式完全一致 |
| U-04 | 不添加未被要求的功能 | bug fix 不需要顺便重构周围代码 |
| U-05 | 不删除看起来"没用"的代码而不先确认 | 可能是用户正在开发的功能 |
| U-06 | 不引入新依赖来解决可以用标准库解决的问题 | 依赖膨胀 |
| U-07 | 不在修复中改变代码风格 | 风格变更应该是独立的 commit |
| U-08 | 不跳过验证步骤 | 每个 fix 必须独立通过 lint + test |
| U-09 | 不一次性提交多个不相关的修复 | 原子 commit，方便 revert |
| U-10 | 不猜测用户意图 | 不确定就标记为 DEFER |

## 跨入口一致性检查

Monorepo / workspace 中多个 binary 共享数据源时，必须检查配置收敛性。

| ID | 类别 | 检查项 | 严重度 |
|----|------|--------|--------|
| U-11 | Data | 多 binary 默认 DB/缓存路径不一致（数据分裂） | 高 |
| U-12 | Data | 共享数据源的 fallback 路径在首次使用时创建错误文件 | 高 |
| U-13 | Config | 多入口的环境变量名不统一（如 `SERVER_DB_PATH` vs `DESKTOP_DB_PATH` 指向不同默认值） | 中 |
| U-14 | Config | CLI 默认路径与 GUI/Server 默认路径基目录不同 | 中 |

### 扫描方法

1. 在 workspace 内搜索所有 `get_db_path` / `db_path` / `default_value` / `data_dir` 等数据源路径构造函数
2. 对比各 binary 的默认值是否收敛到同一物理路径
3. 检查 fallback 逻辑是否会在特定启动顺序下创建分裂文件

### 典型案例（refine 项目）

```
Server:  ~/.local/share/refine/server.db    ← 总是写这里
Desktop: ~/.local/share/refine/server.db    ← 仅当文件已存在时
         ~/.local/share/refine/data.db      ← fallback，首次启动创建
CLI:     ~/.refine/data.db                  ← 完全不同的基目录
```

用户先启动 Desktop → 创建 `data.db` → 再启动 Server → 创建 `server.db` → 数据分裂，Desktop 读旧库显示空。

### 修复模式

```
// Before: 各入口各自硬编码
fn get_db_path() -> PathBuf { base.join("server.db") }  // server
fn get_db_path() -> PathBuf { base.join("data.db") }    // desktop fallback
#[arg(default_value = "~/.refine/data.db")]              // CLI

// After: 统一到 core 的公共函数
pub fn default_db_path() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("refine")
        .join("refine.db")
}
// 所有入口调用 core::default_db_path()，环境变量统一为 REFINE_DB_PATH
```

## FIX/SKIP 判断矩阵

| 条件 | 判定 |
|------|------|
| 逻辑 bug（死锁、TOCTOU、panic） | FIX — 高优先级 |
| 多 binary 数据路径不一致导致数据分裂 | FIX — 高优先级 |
| 代码重复 > 20 行且语义相同 | FIX — 中优先级 |
| 代码重复但语义不同（如不同组件的相似方法） | SKIP — 不同语义 |
| 命名冲突（同名不同义的类型） | FIX — 中优先级 |
| 多入口环境变量名不统一（用户只配一个就分裂） | FIX — 中优先级 |
| 不支持配置被静默降级（silent fallback） | FIX — 高优先级 |
| 性能问题但不在热路径 | SKIP — 收益不足 |
| 性能问题在热路径（渲染循环、事件处理） | FIX — 中优先级 |
| 缺少测试但代码稳定 | DEFER — 低优先级 |
| 缺少测试且代码有已知 bug | FIX — 高优先级 |
| 风格不一致但功能正确 | SKIP — 独立处理 |
| 触及 > 50% 的文件 | DEFER — 需要用户确认范围 |

## 工程实践规则

| ID | 规则 | 说明 |
|----|------|------|
| U-15 | 不可变性优先 | 创建新对象而非修改现有对象；函数参数视为只读 |
| U-16 | 文件大小控制 | 200-400 行典型，800 行最大；超过 800 行必须拆分 |
| U-17 | 错误处理完整 | 全面处理错误路径，提供用户友好的错误消息；不静默吞异常 |
| U-18 | 输入验证 | 系统边界处验证所有用户输入；内部代码信任框架保证 |
| U-19 | Repository 模式 | 数据访问封装到 Repository 层；业务逻辑不直接操作数据库 |
| U-20 | API 响应格式 | 统一信封结构 `{ data, error, meta }`；错误码标准化 |
| U-21 | 提交消息格式 | `<type>: <description>`，type 为 feat/fix/refactor/docs/test/chore |
| U-22 | 测试覆盖率 | 新代码最低 80% 行覆盖率；关键路径 100% |
| U-23 | 禁止静默降级 | 不支持的策略/配置必须显式报错或标记 DEFER，不得自动降级到默认策略 |
| U-24 | 禁止任何别名 | 禁止函数/类型/命令/目录别名与兼容命名；发现旧名应直接全量替换并删除旧名 |

## 扫描策略

### 并行扫描
按模块分区，每个 sub-agent 负责一个模块：
- 核心模块（类型定义、基础设施）
- 业务逻辑（hooks、组件、命令）
- 渲染/输出（渲染器、布局、输出缓冲）
- 测试/工具（测试框架、示例、基准）

### 问题去重
同一根因的多个表现只记录一次，标注所有受影响的文件。

### 依赖排序
修复顺序：bug fix → 类型/命名 → 代码去重 → 性能 → 测试
同级别内按影响范围从小到大排列（隔离的先修）。
