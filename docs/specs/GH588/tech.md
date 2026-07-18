# Tech Spec

## Linked Issue

GH-588

## Product Spec

`docs/specs/GH588/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Check modes and aggregation | `scripts/setup/check.sh:41-109`, `scripts/setup/check.sh:667-712`, `scripts/lib/status_report.sh:282-305` | default、strict、JSON、install 已按状态行聚合为不同退出码；WARN 在 strict/JSON 为 1，在 default/install 为 0 | 新 freshness 只需发出正确的 `[OK]`/`[WARN]` 行并保持既有聚合器，不应复制模式逻辑 |
| launchd registration check | `scripts/setup/check.sh:130-205` | 读取 loaded job 的 active target，区分目标漂移/缺失/不可执行、plist-only 和未安装；只有有效 active target 报 OK | freshness 调用必须放在有效 active target 分支，不能让 drift/plist-only 状态产生执行健康结论 |
| systemd registration check | `scripts/setup/check.sh:524-535` | active user timer 报 OK；unit 文件存在但 inactive 报 WARN；未安装报 INFO | freshness 仅从 active timer 分支调用；仓库没有 cron install/check 分支 |
| State/config writer | `scripts/gc/gc-scheduled.sh:18-26`, `scripts/gc/gc-scheduled.sh:59-75`, `scripts/gc/gc-scheduled.sh:165-192` | 脚本读取 catch-up interval，成功后写 `gc-last-success`，每次脚本完成后写 `gc-last-attempt`；pre-exec failure 无法到达这些写入 | checker 要复用同一配置边界，但必须把 attempt 当可选证据并保持状态文件只读 |
| Config resolution | `scripts/lib/project_config.sh:107-142`, `schemas/vibeguard-project.schema.json:190-194` | 环境值优先于项目配置，非正整数回退默认值；schema 默认 interval 为 168 | checker 与 scheduler 必须共享 `vg_config_positive_int` 和相同 key/default，避免阈值漂移 |
| launchd wrapper log | `scripts/setup/com.vibeguard.gc.plist:7-29` | `/bin/bash` 启动 scheduled script，stdout/stderr 都追加到 `gc-launchd.log` | TCC/EPERM 可在脚本启动前只留下 wrapper evidence |
| systemd wrapper log | `scripts/systemd/vibeguard-gc.service:5-10` | oneshot service 的 stdout/stderr 都追加到 `gc-systemd.log` | systemd wrapper evidence 不能错误地从内部 `gc-cron.log` 读取 |
| Installer boundary | `scripts/setup/install.sh:717-753`, `scripts/install-systemd.sh:46-88` | scheduler 默认不安装；显式 opt-in 后只走 Darwin launchd 或 Linux systemd | 本 issue 不新增 cron、自动修复或安装器写入 |
| Setup test harness | `tests/test_setup.sh:226-250`, `tests/test_setup.sh:363-482`, `tests/setup/install_flow_tests.sh:390-470` | 已有 fake launchctl/systemctl、scheduler 安装/缺失/active/target-drift 断言 | 在既有 fixture 上扩展 freshness、日志来源、边界与模式矩阵，避免另建重复 harness |

## 设计方案

### 1. 单一 freshness helper 与资格门槛

在 `scripts/setup/check.sh` 增加一个 snake_case helper，输入 scheduler kind，内部只读
状态与对应日志。调用点严格位于注册检查的 active-valid 分支：

- launchd：loaded job 的 active target 等于当前仓库 canonical
  `scripts/gc/gc-scheduled.sh` 且可执行后调用；persisted plist 的单独漂移 WARN 不
  改变 active target 的资格。
- systemd：`systemctl --user is-active vibeguard-gc.timer` 成功后调用。
- plist-only、unit-only/inactive、active target drift/missing/non-executable 或未安装
  分支不调用 helper，保持既有注册输出。

不修改 `scripts/setup/install.sh`、launchd plist、systemd units 或清理逻辑，也不
增加 cron 分支。

### 2. 严格 freshness 计算

helper 通过
`vg_config_positive_int VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS gc.catchup_interval_hours 168`
解析阈值，并在一次调用开始时捕获 `now=$(date +%s)`。仅接受
`gc-last-success` 的十进制 epoch 内容；计算 `age=now-last_success` 后使用半开区间：

```text
healthy := last_success_is_decimal && 0 <= age && age < interval_hours * 3600
```

healthy 输出包含 age 的 `[OK]`。缺失、空、非十进制、不可读、未来值、精确命中
阈值或更旧均输出 `[WARN]`；未来/损坏状态按无效状态报告，不能通过负 age 冒充
fresh。读取到并发写入的短暂空值同样保守 WARN，用户可安全重跑。

### 3. 平台 wrapper 与公共内部日志证据

只在 freshness WARN 路径读取日志：

| Scheduler | Wrapper log | Internal log |
| --- | --- | --- |
| launchd | `~/.vibeguard/gc-launchd.log` | `~/.vibeguard/gc-cron.log` |
| systemd | `~/.vibeguard/gc-systemd.log` | `~/.vibeguard/gc-cron.log` |

对每个存在且可读的文件先做固定行数的 `tail`，再选尾部最后一条匹配
`Operation not permitted`、`Permission denied`、`[ERROR]` 或
`GC completed with errors` 的行；输出明确标注 wrapper/internal 来源。文件不存在、
不可读或无匹配行不是 helper failure：保留通用 freshness WARN 并说明没有可用的匹配
证据，不把旧日志行断言为确定根因。

`gc-last-attempt` 仅在严格解析成功时补充关联信息。`attempt > success` 可说明最近
一次脚本内尝试未成功；attempt 缺失/损坏不得阻止读取 wrapper 日志，因为 launchd/
systemd 可在 shell 脚本开始前失败。

### 4. Remediation 与模式契约

所有不健康结果包含重新注册命令；匹配权限/TCC 文本时增加“移动受保护目录中的
checkout 或授予 scheduler 磁盘访问权限”的提示。helper 只打印既有 reporter 能识别
的单行 `[OK]`/`[WARN]` 事件，不自行决定进程退出码：

- default human：WARN 可见，整体无其他问题时退出 0；
- strict：WARN 进入 DEGRADED，退出 1；
- JSON：同一 WARN 进入 events，verdict 为 degraded，退出 1，stdout 仍只有单个 JSON；
- install：WARN 作为可选降级可见，整体无 required failure 时退出 0。

helper 不创建/修改 scheduler、state 或 log；检查前后文件 digest 与注册 mock 状态可
用于证明只读性。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 active-valid registration 才检查 freshness | `scripts/setup/check.sh` launchd helper 与 systemd active branch；既有 fake launchctl/systemctl | `bash tests/test_setup.sh`：launchd valid active/systemd active 产生 freshness；未安装、inactive、plist/unit-only、active target drift/missing/non-executable 均无 freshness 行 |
| B-002 严格 fresh 半开区间与配置优先级 | freshness helper、`scripts/lib/project_config.sh` | `bash tests/test_setup.sh`：固定 now 下覆盖 age 0、interval-1 秒为 OK，interval 秒为 WARN，并覆盖 env/project/default interval |
| B-003 缺失/损坏/未来/过期 success 保守 WARN | freshness helper state parser | `bash tests/test_setup.sh`：missing、empty、garbled、unreadable、future、exact-boundary、stale fixtures 均 WARN 且 checker 不崩溃 |
| B-004 正确双层日志来源与有界尾部 | freshness helper platform log selector | `bash tests/test_setup.sh`：launchd 只把 `gc-launchd.log` 标为 wrapper，systemd 只把 `gc-systemd.log` 标为 wrapper；两者读取公共 `gc-cron.log`，只输出各来源尾部最后一条匹配行 |
| B-005 pre-exec 无 attempt 仍展示 wrapper failure | optional attempt parser、wrapper log branch | `bash tests/test_setup.sh`：缺少 `gc-last-attempt` 且 wrapper 含 `Operation not permitted` 时仍输出证据；attempt 晚于 success 时输出失败尝试关联信息 |
| B-006 无日志证据仍 fail-visible 且有 remediation | generic WARN 与 hint branch | `bash tests/test_setup.sh`：日志 missing/unreadable/no-match 仍 WARN；EPERM 场景包含 re-register 与 checkout/permission 提示，不出现伪造 error line |
| B-007 default/strict/JSON/install 契约一致 | status line emission、既有 `status_report.sh` 聚合 | `bash tests/test_setup.sh`：在仅有 freshness WARN 的 fixture 中断言 default rc=0、strict rc=1/DEGRADED、JSON rc=1/valid single JSON WARN event、install rc=0；四种模式分类一致 |
| B-008 只读、幂等、无 cron 路径 | freshness helper、未安装分支、scheduler installer boundary | `bash tests/test_setup.sh` 前后比较 state/log/registration fixture、重复检查输出分类一致，并通过其加载的 install-flow cases 保持 launchd/systemd-only 与 absent INFO 断言 |

## 数据流

1. 现有 registration probe 先判断当前平台是否 active-valid；失败/缺失路径直接输出
   既有状态并停止该 scheduler 的 freshness 流程。
2. 合格路径读取 interval、捕获 now、只读解析 last-success 与可选 last-attempt。
3. 严格半开区间得到 fresh 或 unhealthy；fresh 输出 OK 后结束。
4. unhealthy 先输出通用 WARN，再从平台 wrapper 和公共 internal 日志的有界尾部
   提取可用证据，追加来源标记与 remediation。
5. 现有 status reporter 捕获状态行，并按 default/strict/JSON/install 计算展示、
   verdict 与退出码；helper 不写任何持久化状态。

## 备选方案

- 只检查 `gc-last-attempt`：拒绝。pre-exec TCC/权限失败不会写 attempt，会复现 silent
  degradation。
- 把 `gc-cron.log` 当作所有 scheduler 的 wrapper 日志：拒绝。它是脚本内部日志，
  不能覆盖脚本启动前的 launchd/systemd failure。
- 在 check 中自动 re-register：拒绝。`--check` 必须只读，权限与 checkout 位置也需要
  操作者决定。
- 新增 cron fallback：拒绝。仓库当前安装面只有 launchd/systemd，超出 GH-588。

## 风险

- Security: 日志是本地诊断输入；只读固定尾部且不执行其内容，避免把日志文本拼入
  shell 命令。权限 remediation 不自动提权。
- Compatibility: 新 WARN 会让 strict/JSON 从 0 变为 1，这是目标行为；default/install
  保持兼容退出码。未安装/inactive/invalid registration 不增加 freshness noise。
- Performance: 每次检查只读取两个小状态文件与最多两个日志的固定尾部，不扫描完整
  日志。
- Maintenance: wrapper 与 internal 日志容易混淆；平台映射表和两平台 fixture 固定来源
  契约。
- Clock/state race: 系统时钟回拨或读到部分状态会保守 WARN；不会输出虚假 OK，重跑
  可在稳定后恢复。

## 测试计划

- [ ] Unit/fixture tests: 在既有 setup harness 中覆盖 success age 半开区间、无效/未来
      state、attempt 可选语义、bounded log selection 和 remediation。
- [ ] Integration tests: 覆盖 launchd/systemd active-valid 与 inactive/drift/absent gate，
      并执行 default/strict/JSON/install 模式矩阵及只读 digest 检查。
- [ ] Regression tests: `bash tests/test_setup.sh` 与 `bash tests/test_gc_scheduled.sh` 均
      通过，证明 checker 与 writer 的状态契约一致且未弱化现有 scheduler 测试。
- [ ] Contract checks: `bash scripts/local-contract-check.sh --quick` 与文档/SpecRail checks
      通过。

## 回滚方案

回滚 `scripts/setup/check.sh` 的 freshness helper/call sites 与对应 setup fixtures，即可恢复
registration-only 检查。无需迁移或删除状态文件、日志、plist、systemd units；不得通过
降低既有 status reporter 的 WARN 语义来回滚。
