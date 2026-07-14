# Product Spec

## Linked Issue

GH-588

关联规格 PR：#591。

## 用户问题

`setup.sh --check` 目前只判断定时 GC 是否注册：launchd job 是否加载、目标路径
是否漂移，或 systemd timer 是否 active。它没有消费定时脚本已经写出的
`~/.vibeguard/gc-last-success` 与 `~/.vibeguard/gc-last-attempt`，因此 scheduler
可以持续触发失败数周而检查仍显示 active。macOS TCC 在执行位于受保护目录下的
脚本前就可能拒绝 launchd；这种失败只出现在 wrapper 日志中，甚至不会产生
`gc-last-attempt`。

用户需要 `--check` 区分“已注册”与“近期成功执行”，并在执行不健康时看到正确
平台的日志证据和可操作的修复提示，而不是把 silent degradation 报成健康。

## 目标

- 仅对 active 且当前注册有效的 launchd/systemd 定时 GC 检查执行 freshness。
- 按 `gc.catchup_interval_hours`（默认 168 小时）判定最近成功是否仍健康。
- 在不健康时展示正确 wrapper 日志与公共内部 GC 日志中的有界错误证据，并给出
  重新注册及权限修复提示。
- 保持 default、strict、JSON、install 四种检查模式既有的输出和退出码契约。
- 保持检查只读、可重复，不改变 scheduler、状态文件或日志。

## 非目标

- 不自动修复 macOS TCC、移动 checkout、授予磁盘权限或重新注册 scheduler。
- 不改变 `gc-scheduled.sh` 写入 attempt/success 的时机或 GC catch-up 执行语义。
- 不改变 scheduler 的 opt-in 安装策略，也不新增 cron 安装路径；受支持的安装路径
  仍只有 macOS launchd 与 Linux systemd。
- 不把 inactive、目标漂移、目标不可执行或仅残留 unit/plist 的注册状态升级为执行
  freshness 检查。
- 不把历史日志中的一行错误宣称为已证明的根因；它只是诊断证据。

## Behavior Invariants

1. B-001 Freshness 只在当前平台的 scheduled GC 注册同时满足 active 与有效时
   执行：launchd job 已加载且其 active target 是预期的可执行
   `scripts/gc/gc-scheduled.sh`，或 systemd user timer `vibeguard-gc.timer` 为
   active。未安装、inactive、active target 漂移/缺失或不可执行时只报告既有注册
   状态，不得额外输出 freshness 的 OK/WARN。
2. B-002 对符合 B-001 的注册，检查必须用一次检查捕获的当前 epoch 与正整数
   `gc.catchup_interval_hours`（环境覆盖优先、项目配置其次、默认 168 小时）计算
   `age = now - last_success`；仅当 `last_success` 是十进制 epoch 且
   `0 <= age < interval_hours * 3600` 时输出执行 freshness `[OK]`，并显示成功
   年龄。`age == interval` 已过期，不能算健康。
3. B-003 `gc-last-success` 缺失、为空、非十进制、不可读、位于未来
   （`age < 0`），或年龄达到/超过 interval 时，符合 B-001 的注册必须输出
   `[WARN]`：区分“从未记录/状态无效”和“已过期”，并显示阈值；解析错误或读取
   期间遇到不完整写入不得崩溃或降级成 `[OK]`。
4. B-004 仅当 B-003 产生执行 freshness WARN 时，检查才从正确日志来源的有界
   尾部展示诊断行：launchd 使用 wrapper `~/.vibeguard/gc-launchd.log`，systemd
   使用 wrapper `~/.vibeguard/gc-systemd.log`，两者都另查内部
   `~/.vibeguard/gc-cron.log`。每个存在且可读的来源最多展示其最后一条匹配的
   actionable failure（至少覆盖 `Operation not permitted`、`Permission denied`、
   `[ERROR]`、`GC completed with errors`），并标明来源；不得把 `gc-cron.log` 称为
   systemd wrapper 日志。
5. B-005 `gc-last-attempt` 只可作为可选关联证据，不是展示 wrapper 失败的前提。
   当 attempt 有效且晚于 success 时可报告“最近一次尝试未成功”；当 attempt 缺失、
   损坏或未更新时，仍必须展示 B-004 找到的 wrapper failure，因为权限/TCC 可在
   `gc-scheduled.sh` 写 attempt 前失败。
6. B-006 当 freshness 不健康但相应日志缺失、不可读或没有匹配行时，检查仍必须
   保留 B-003 的通用 WARN，不得伪造证据、静默恢复为健康或崩溃。WARN 必须给出
   `bash setup.sh --yes --with-scheduler` 的重新注册提示；权限类证据还必须提示移动
   受保护目录中的 checkout 或授予相应 scheduler 磁盘访问权限。
7. B-007 在只有 scheduled-GC freshness WARN、没有其他问题时，default human
   `--check` 显示 WARN 但退出 0；`--strict` 显示 WARN、汇总为 DEGRADED 并退出 1；
   `--json` 输出单个有效 JSON、包含 `level: WARN` event、`verdict: degraded` 并退出
   1；`--install` 显示可选 WARN 但退出 0。所有模式对同一输入必须给出同一
   freshness 分类。
8. B-008 检查必须只读且可重复：不得创建、修正或删除 scheduler 注册、
   `gc-last-success`、`gc-last-attempt` 或任何 GC 日志。scheduler 未安装时保持现有
   `[INFO]` 且不产生 freshness noise；重复运行相同输入得到相同分类，并且不得借此
   新增 cron 安装/探测路径。

## 验收标准

- [ ] active 且有效的 launchd/systemd 注册会按严格边界
      `0 <= age < interval` 报告 fresh；精确阈值、未来时间和无效状态均 WARN。
- [ ] inactive、未安装和 active target 无效的注册不执行 freshness 检查，既有
      INFO/WARN/BROKEN 注册结果保持。
- [ ] stale/never-success 场景从正确 wrapper 日志和公共内部日志的有界尾部展示
      failure；pre-exec 无 attempt 的 EPERM/TCC 场景仍可见。
- [ ] 无日志证据时保留通用 WARN 和修复提示，不崩溃、不伪造根因。
- [ ] default、strict、JSON、install 模式分别满足 B-007 的输出和退出码。
- [ ] 检查不修改状态、日志或注册，安装器仍只支持 opt-in launchd/systemd。
- [ ] Linux 与 macOS/launchd fixture、状态边界、日志来源和模式矩阵都有确定性回归
      测试，并通过完整 setup 测试。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-003, B-005, B-006（状态、attempt、日志均可缺失） |
| 错误与失败路径 | covered: B-003, B-004, B-005, B-006 |
| 授权/权限 | covered: B-004, B-005, B-006（TCC/EPERM/磁盘访问失败可见但不自动提权） |
| 并发/竞态 | covered: B-002, B-003（单次 now；读取到中间/无效状态时保守 WARN） |
| 重试/幂等 | covered: B-008 |
| 非法状态转换 | covered: B-001, B-008（诊断不改变注册或 GC 状态） |
| 兼容/迁移 | covered: B-001, B-007, B-008（保留注册和模式契约，无 cron 迁移） |
| 降级/回退 | covered: B-003, B-005, B-006（证据不足仍 WARN，不得貌似成功） |
| 证据与审计完整性 | covered: B-004, B-005, B-006（来源标识、无 attempt、不得伪造根因） |
| 取消/中断 | covered: B-008（只读检查可安全重跑，不产生部分写入） |

## 发布说明

这是现有 `setup.sh --check` 的诊断增强，不迁移已有状态文件，也不自动重装
scheduler。已有 opt-in launchd/systemd 用户会在注册有效但执行过期或从未成功时
看到新的 WARN；默认 human 与 install 模式仍保持兼容退出码，strict/JSON 会把该
WARN 反映为 degraded。
