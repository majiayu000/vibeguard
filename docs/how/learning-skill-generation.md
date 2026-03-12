# 学习与 Skill 生成系统

VibeGuard 的学习系统对标 OpenAI Harness 的反馈循环，实现"操作 → 事件采集 → 信号检测 → 学习提取 → Skill 文件 → 自动加载"的完整闭环。

## 三层架构

```
┌─────────────────────────────────────────────────────────┐
│ 第三层：生成层（/vibeguard:learn 显式调用）               │
│   模式 A：错误 → 守卫规则/hook     防御向，加固防线       │
│   模式 B：发现 → SKILL.md 文件     积累向，沉淀经验       │
├─────────────────────────────────────────────────────────┤
│ 第二层：评估层（自动触发）                                │
│   Stop hook：learn-evaluator.sh → session-metrics.jsonl │
│   GC 定期：gc-scheduled.sh → learn-digest.jsonl         │
├─────────────────────────────────────────────────────────┤
│ 第一层：采集层（每次操作自动记录）                         │
│   11 个 Hook → log.sh vg_log → events.jsonl             │
└─────────────────────────────────────────────────────────┘
```

## 第一层：事件采集

所有 Hook 在执行时通过 `log.sh` 的 `vg_log` 函数写入 `events.jsonl`。

### 日志格式

```json
{
  "ts": "2026-03-02T03:29:41Z",
  "session": "49e12e90",
  "hook": "post-edit-guard",
  "tool": "Edit",
  "decision": "warn",
  "reason": "unwrap detected in non-test code",
  "detail": "src/main.rs",
  "duration_ms": 42
}
```

### 日志隔离

按项目哈希隔离，不同项目的事件完全独立：

```
~/.vibeguard/projects/
├── a1b2c3d4/          # 项目 A（git root 路径的 SHA256 前 8 位）
│   ├── events.jsonl
│   └── session-metrics.jsonl
├── e5f6g7h8/          # 项目 B
│   ├── events.jsonl
│   └── session-metrics.jsonl
└── learn-digest.jsonl  # GC 定期学习产出（跨项目汇总）
```

### 触发链路

| Hook | 触发时机 | 写入内容 |
|------|----------|----------|
| pre-edit-guard | 编辑前 | 文件是否存在检查 |
| pre-write-guard | 新建前 | 先搜索提醒 |
| pre-bash-guard | 命令前 | 危险命令拦截 |
| post-edit-guard | 编辑后 | unwrap/console.log/硬编码/Go error 丢弃/超大 diff |
| post-write-guard | 新建后 | 重复定义检测 |
| skills-loader | 首次 Read | Skill 匹配加载（不写日志） |
| learn-evaluator | Stop | 会话指标聚合 |

### Session ID 机制

通过文件持久化 + 30 分钟续期保证同一会话共享稳定 ID：

```
~/.vibeguard/.session_id    # 存储当前 session ID
  ├─ 文件存在 & mtime < 30min → 复用 + touch 续期
  └─ 否则 → 生成新 8 字符 hex ID
```

## 第二层：评估层

### 2a. 会话结束评估（learn-evaluator.sh）

Stop 事件触发，聚合最近 30 分钟内的事件指标：

```json
{
  "ts": "2026-03-02T11:57:00Z",
  "session": "49e12e90",
  "event_count": 35,
  "decisions": {"warn": 12, "pass": 20, "block": 3},
  "hooks": {"post-edit-guard": 15, "pre-bash-guard": 8},
  "tools": {"Edit": 19, "Bash": 12},
  "top_edited_files": {"src/main.tsx": 19, "app.py": 6},
  "avg_duration_ms": 380,
  "slow_ops": 2
}
```

写入 `session-metrics.jsonl`，始终 `exit 0` 不阻塞。

### 2b. GC 定期学习（gc-scheduled.sh 学习阶段）

每周日凌晨 3 点由 launchd 触发，从**两种信号源**统一采集：

#### 信号源 A：事件日志（agent 行为模式）

| 信号 | 检测逻辑 | 含义 |
|------|----------|------|
| `repeated_warn` | 同一 reason ≥10 次/周 | 反复犯同样的错 |
| `chronic_block` | 同一 reason 被 block ≥5 次/周 | Agent 反复碰壁 |
| `hot_files` | 同一文件编辑 ≥20 次/周 | 高频修改区域 |
| `slow_sessions` | 慢操作 ≥10 次/周 | 复杂场景 |
| `warn_escalation` | 后半周 warn 增长 >50% | 守卫在退化 |

#### 信号源 B：代码扫描（linter 违规，对标 Harness GC Agent）

通过 `.project-root` 映射文件获取项目物理路径，自动检测语言，运行对应 guards：

| 项目类型 | guards |
|---------|--------|
| 所有 | `check_code_slop.sh`（空 catch、调试残留、过期 TODO、死代码、超长文件） |
| Rust | `check_unwrap_in_prod.sh` / `check_nested_locks.sh` / `check_duplicate_types.sh` 等 |
| TypeScript | `check_any_abuse.sh` / `check_console_residual.sh` / `check_duplicate_constants.sh` |
| Go | `check_error_handling.sh` / `check_goroutine_leak.sh` / `check_defer_in_loop.sh` |

≥5 个违规生成 `linter_violations` 信号。

#### 统一产出

```json
{
  "ts": "2026-03-02T03:00:00Z",
  "project": "a1b2c3d4",
  "project_root": "/Users/me/code/my-app",
  "signals": [
    {"type": "repeated_warn", "source": "events", "reason": "unwrap detected", "count": 23},
    {"type": "linter_violations", "source": "code_scan", "guard": "console_residual", "count": 96}
  ]
}
```

**防重复学习（水位线机制）：**

`~/.vibeguard/.learn-watermark` 存储上次消费的最新时间戳。skills-loader 只读取水位线之后的新条目，确认采纳/跳过后更新水位线。同一个信号只推荐一次。

```
learn-digest.jsonl:  ts=T1, ts=T2, ts=T3, ts=T4
                                    ↑
.learn-watermark:                  T3（已处理到这里）
                                         ↑
下次只看:                                T4（新数据）
```

**与 Harness GC Agent 的对标：**

| Harness GC Agent | VibeGuard GC 学习 |
|-----------------|-------------------|
| Codex agent **扫描代码库** | guards 脚本扫描（信号源 B） |
| 同时分析行为日志 | events.jsonl 分析（信号源 A） |
| 扫描对照 Golden Principles | 扫描对照 83 条规则 |
| 违规 → **直接开 PR** | 违规 → learn-digest → 推荐用户处理 |
| 自动审核合并（<1分钟） | 半自动（用户确认后 /vibeguard:learn 执行） |

## 第三层：Skill 生成

通过 `/vibeguard:learn` 命令显式触发，双模式路由。

### 模式路由

| 输入 | 路由 |
|------|------|
| 用户描述了错误/bug/守卫失效 | **模式 A**：错误分析 → 产出 guard/hook/rule |
| 用户说 "extract" / "提取经验" | **模式 B**：经验提取 → 产出 SKILL.md |
| Stop hook 自动触发（无参数） | 先评估 → 按需选择 A 或 B |
| 同时有错误修复和非显而易见发现 | A + B 都执行 |

### 模式 A：错误 → 守卫规则（防御向）

**完整流程（9 步）：**

```
1. 自动模式识别 — 读 events.jsonl，提取 top 5 高频 warn/block 模式
2. 收集错误上下文 — 参数 + 对话 + 自动识别结果
3. 5-Why 根因分析：
   ├─ 表面原因：Agent 做了什么错误操作？
   ├─ 直接原因：现有守卫为什么没拦住？
   └─ 根本原因：系统层面缺了什么？
4. 确定改进类型：
   ├─ 新守卫脚本 → guards/<lang>/check_xxx.sh
   ├─ 增强现有守卫 → 编辑 guards/ 下的脚本
   ├─ 新 hook 规则 → 修改 hooks/ 下的脚本
   ├─ 新规则条目 → 修改 rules/ 下的规则文件
   └─ 新约束 → 修改 vibeguard-rules.md
5. [Stop] AskUserQuestion 确认方案
6. 实施改进
7. 模式识别与规则生成（6 类错误 → 对应规则类型）
8. 验证（原始场景 + 无回归）
9. 输出学习报告
```

**6 类错误模式 → 规则类型映射：**

| 模式 | 生成规则类型 |
|------|-------------|
| 重复创建同功能文件 | 守卫脚本（检测相似文件名/函数名） |
| 路径幻觉（编辑不存在的文件） | Hook 规则（pre-edit 检查文件存在） |
| API 幻觉（调用不存在的方法） | 规则条目（标注真实 API 列表） |
| 过度设计（添加不需要的抽象） | 约束条目（最小改动原则强化） |
| 数据分裂（多入口不同路径） | 守卫脚本（跨入口路径一致性检查） |
| 命名混乱（同概念多个名字） | 命名规范条目 + 别名检测 |

### 模式 B：发现 → SKILL.md（积累向）

**完整流程（8 步）：**

```
1. 自我评估（5 问，任一为"是"才继续）：
   ├─ 涉及非显而易见的调试？
   ├─ 方案可复用于未来？
   ├─ 发现了文档未覆盖的知识？
   ├─ 错误消息有误导性？
   └─ 通过试错才找到方案？
2. 去重检查 — rg 搜索 .claude/skills/ 和 ~/.claude/skills/
3. 提取知识 — 问题 + 非显而易见部分 + 触发条件
4. 条件性 Web 研究（3 类场景需搜索）
5. 结构化为 SKILL.md（按模板 6 个 section）
6. 保存位置决策（项目级 vs 全局）
7. [Stop] AskUserQuestion 确认
8. 输出提取报告（6 项质量检查）
```

**4 条质量门控（全部满足才提取）：**

| 标准 | 定义 | 反例 |
|------|------|------|
| 可复用 | 未来类似任务能用上 | "这个变量名打错了" |
| 非平凡 | 需要探索才能发现 | "npm install 安装依赖" |
| 具体 | 有精确触发条件和步骤 | "React 有时候会报错" |
| 已验证 | 实际测试过 | "应该可以用 XX 解决" |

### SKILL.md 文件结构

```yaml
---
name: descriptive-kebab-case-name
description: |
  [精确描述：(1) 解决什么问题 (2) 触发条件 (3) 涉及的技术/框架]
author: Claude Code
version: 1.0.0
date: YYYY-MM-DD
---
```

正文：Problem → Context/Trigger → Solution(分步) → Verification → Example(Before/After) → Notes → References

### 去重决策表

| 搜索结果 | 动作 |
|----------|------|
| 无相关 | 新建 Skill |
| 相同触发 + 相同方案 | 更新已有（version +minor） |
| 相同触发 + 不同根因 | 新建，双向添加 See also |
| 相同领域 + 不同触发 | 更新已有，加"变体"小节 |
| 已有但过时 | 标记废弃，新建替代 |

## Skill 自动复用

新会话第一次 `Read` 操作时，`skills-loader.sh`（PreToolUse Hook）自动触发两件事：

```
新会话 → 首次 Read
  │
  ├─ [学习推荐] 读 learn-digest.jsonl（水位线之后的新信号）
  │   ├─ 有新信号 → 输出推荐，提示运行 /vibeguard:learn
  │   └─ 更新水位线（~/.vibeguard/.learn-watermark），下次不重复
  │
  ├─ [Skill 匹配] 扫描 ~/.claude/skills/ 和 .claude/skills/
  │   ├─ 读取每个 SKILL.md 的 frontmatter（name + description）
  │   ├─ 打分：语言匹配 +2，项目名匹配 +3，触发关键词匹配 +1
  │   └─ 输出 top 5 匹配 Skill 到会话上下文
  │
  └─ 创建 flag 文件，本会话不再重复加载
```

**实际输出示例：**

```
[VibeGuard 学习推荐] 检测到 3 个跨会话学习信号：
  - 高频警告: 构建错误 1 个 (37次)
  - 热点文件: .../src/scrapers/candidate-scraper.ts (42次)
  - 热点文件: .../src/components/DealDocsTab.tsx (113次)
运行 /vibeguard:learn 可从这些信号中提取守卫规则或 Skill。

[VibeGuard Skills] 检测到 5 个相关 Skill：
  - vibeguard: AI 辅助开发防幻觉规范...
  - eval-harness: 评估驱动开发...
```

## 完整闭环

```
操作 ──→ Hook 检测 ──→ events.jsonl 记录
                              │
              ┌───────────────┼───────────────┐
              ↓               ↓               ↓
      会话结束评估      GC 定期分析      /vibeguard:learn
   (session-metrics)  (learn-digest)    (显式调用)
              │               │               │
              └───────────────┼───────────────┘
                              ↓
                    学习信号 + 用户确认
                              │
                    ┌─────────┴─────────┐
                    ↓                   ↓
              模式 A：守卫         模式 B：Skill
            (guards/hooks/rules)  (SKILL.md)
                    │                   │
                    ↓                   ↓
              Hook 加载执行      skills-loader 匹配
                    │                   │
                    └─────────┬─────────┘
                              ↓
                      指导未来操作
```

## 学习产出历史

### 2026-03-11：构建错误循环分析

**信号源**：57 个项目 3/5~3/11 事件聚合 + learn-digest 积压信号

| 信号 | 次数 | 改进 |
|------|------|------|
| 构建错误 | 435x warn | U-25 规则 + post-build-check escalation |
| L1 重复定义 | 82x warn | 已有检测，暂不升级 |
| RS-03 unwrap | 37x warn | 消息强化（"立即修复"） |
| 文件不存在 | 14x block | 已有效拦截，无需改进 |

**产出**：
- 新规则 **U-25**：构建失败修复优先（严格）
- Hook 增强：`post-build-check.sh` 连续 5 次失败 → escalate
- 新 Skill：`build-error-spiral-breaker`（`~/.claude/skills/`）

**三层触发机制**：
```
U-25 规则（常驻，所有会话生效）
  ↓ 构建失败时
Skill 知识（提供具体的修复策略）
  ↓ 连续 5 次失败
Hook 升级（强制警告，打断 Agent 循环）
```

## 文件清单

| 文件 | 角色 |
|------|------|
| `hooks/log.sh` | 日志基础设施，提供 vg_log 函数 |
| `hooks/learn-evaluator.sh` | Stop 事件时会话指标采集 |
| `hooks/skills-loader.sh` | 首次 Read 时加载匹配 Skill |
| `hooks/post-build-check.sh` | 构建检查 + 连续失败升级（U-25 机械化） |
| `scripts/gc-scheduled.sh` | GC 定期学习（跨会话模式识别） |
| `.claude/commands/vibeguard/learn.md` | /vibeguard:learn 命令（双模式路由） |
| `resources/skill-template.md` | SKILL.md 写作模板 |
| `skills/*/SKILL.md` | 已提取的 Skill 文件 |

## 与 OpenAI Harness 的对标

| Harness 概念 | VibeGuard 实现 |
|-------------|---------------|
| GC 后台定期学习 | gc-scheduled.sh 学习阶段（跨项目信号汇总） |
| Skill 手动提取 | /vibeguard:learn 模式 B |
| 失败驱动改进 | /vibeguard:learn 模式 A（5-Why + 守卫生成） |
| 上下文自动加载 | skills-loader.sh（PreToolUse Read 触发） |
| 知识去重 | 去重决策表（5 种处理路径） |
| 质量门控 | 4 条标准（可复用、非平凡、具体、已验证） |
