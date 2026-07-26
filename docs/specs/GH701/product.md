# Product Spec — agent firewall 定位与可扩展 host adapter 契约

## Linked Issue

GH-701

complexity: large

## 用户问题

VibeGuard 的规则、hook、guard 与本地 observability 已经能保护 Claude Code 和
Codex CLI，但公开叙事与安装面仍把产品呈现成“两种工具的规则包”。当前 host
接入也不是一个可复用的公开契约：`hooks/manifest.json` 只表达 `claude` 与
`codex` 两列，安装、配置、输入归一化、输出适配、health 与清理逻辑按 host
分散。新增 Cursor CLI、Gemini CLI 或 opencode 时，很容易复制 rule/guard core、
漏掉 capability 差异，或在未知 host 上显示虚假的“已保护”。

PR #705 已完成本 issue 的第一段：README 首屏已有 agent-firewall 一句话定位、
真实 demo GIF、当前支持的 clone 安装命令与拦截清单。它没有实现 host adapter
seam，也没有证明第三个 host；首屏目标中的免 clone 一命令安装与可复现 benchmark
分别依赖 GH-699 与 GH-700 的真实交付，不能在依赖完成前写成已支持事实。

## 目标

- 建立一个有版本、可验证、可扩展的 host adapter 契约，使 host-specific
  配置、事件与响应留在 adapter 边界，现有 rule/guard core 不因新增 host 分叉。
- 在 Claude Code 与 Codex CLI 之外交付至少一个经维护者选定的新 host adapter，
  用真实安装、真实 host event 与真实 interception 证明 seam。
- 对未知、缺能力、版本不兼容或配置失败的 host 显式降级，绝不把“不支持”显示成
  “已保护”。
- 保持 PR #705 已交付的首屏简化，并只在 GH-699/GH-700 提供可复现证据后替换安装
  与 benchmark 事实。

## 非目标

- 不重写规则、guard、hook decision 语义、profile 或 runtime policy。
- 不承诺 Cursor CLI、Gemini CLI、opencode 三者全部在本 issue 中支持；本 issue
  只要求一个经批准的 proof host，其余 host 必须有 truthful capability 状态。
- 不用模拟器、手工拼 JSON 或 VibeGuard 自己的 demo 命令冒充新 host 的真实接入
  证明。
- 不在 GH-699 完成前发明一命令安装入口，也不在 GH-700 完成前发明 benchmark
  数字或发布表格。
- 不引入 SaaS、远端 telemetry、云端规则执行或凭据收集。
- 不把 PR #705 已完成的 README 重排作为本 issue 的主要实现工作。

## 已完成 slice 与剩余范围

| 范围 | 当前状态 | 本 spec 的处理 |
| --- | --- | --- |
| 一句话 agent-firewall 定位 | PR #705 已合并 | 保持，不回退到 two-tool rule-pack 叙事 |
| 首屏 demo GIF、当前安装命令、拦截清单 | PR #705 已合并 | 保持真实；后续替换必须有依赖证据 |
| 免 clone 一命令安装 | GH-699 `ready_to_implement` | 依赖交付；本 issue 不声明完成 |
| 可复现 benchmark 表 | GH-700 `ready_to_spec` | 依赖交付；本 issue 不声明数字 |
| host adapter seam 与第三 host proof | 未实现 | 本 issue 的主要剩余范围 |

## 实施前人工决策

1. **Proof host 选择**：维护者必须从有可验证 native hook/event surface 的候选中
   明确选一个 host，并记录选定 host、官方协议/配置文档版本、支持的 blocking
   event 与无法支持的能力。当前 issue 只列出 Cursor CLI、Gemini CLI、opencode
   候选，没有足够证据替维护者选定其中之一；未决时实现保持 blocked。
2. **安装触发策略**：维护者需确认 proof host adapter 是“检测到 host 后显式确认
   安装”还是专用 `--host` opt-in。默认建议显式确认，禁止仅凭目录存在就改写
   host 高上下文配置。
3. **stale branch ownership**：远端 `docs/gh701-readme-first-screen` 当前指向
   `c77253b4`，其内容已通过 squash merge PR #705（`48076210`）进入 main，但该
   branch commit 不是 main 的 ancestor。维护者必须决定删除、保留归档，还是由
   指定 owner 重建；在决定前不得复用、rebase、push 或删除该 branch。

## Behavior Invariants

1. B-001 README 与用户可见状态页必须把 VibeGuard 描述为位于 AI coding agent
   与 codebase 之间的本地 firewall，同时把“已支持 host”限制为有当前安装、
   capability 与真实 interception 证据的 host；不得用产品定位暗示所有 agent
   已受保护。
2. B-002 PR #705 已交付的首屏定位、真实 demo 与短安装路径必须保持；GH-699
   尚未通过其验收前，首屏安装命令必须继续显示当前真实受支持路径，不得写成
   clone-free/one-command 已完成。
3. B-003 首屏 benchmark 表或 headline number 只有在 GH-700 提供 released
   command、fixture/version 与可复现结果后才可发布；缺少或过期证据时必须显示
   尚未提供，不得填 0、示例值或历史 CI latency 冒充 effectiveness benchmark。
4. B-004 每个 host 必须有闭集 capability 状态
   `native`、`partial`、`unsupported`、`not_applicable`，并逐项声明 event、
   blocking ability、profile 与协议版本；字段缺失、未知枚举或自相矛盾时契约
   校验必须失败，不能推断为 `native`。
5. B-005 host adapter 只能把 host event 转成 VibeGuard 的 canonical hook
   request，并把 canonical decision 转回 host response；新增 proof host 时，
   相同 canonical fixture 的 rule/guard decision、reason class 与 enforcement
   mode 必须与现有 host 一致，不能复制或改写 rule/guard core。
6. B-006 proof host 必须在真实 CLI/session 中完成至少一个支持的 blocking
   interception：安装/启用成功、host 发出真实 event、VibeGuard 返回该 host
   可执行的 deny/block 与 fix instruction、event log 记录正确 host identity；
   手工调用 wrapper、直接调用 runtime 或 demo transcript 不算 proof。
7. B-007 proof host 的 unsupported event 必须逐项标为 `unsupported` 或
   `partial` 并给出可操作说明；adapter 不得注册 host 不会发送的 event，也不得
   用 pass、空输出或“healthy”掩盖能力缺口。
8. B-008 未知 host、未知协议版本或无法辨认的 event 必须 graceful fail：
   不修改 host 配置、不报告已安装/healthy、不执行 rule/guard core，并返回
   bounded、无敏感内容的 unsupported/incompatible 诊断与下一步；若请求已进入
   一个声明可 blocking 的 adapter 且 payload 无法安全归一化，则保持 fail
   closed。
9. B-009 adapter 对 malformed payload、未知 tool/event 名称、缺字段和错误类型
   不得持久化 raw payload、command、file content、prompt、token、secret 或任意
   host free text；诊断只允许闭集分类与必要的非敏感结构元数据。
10. B-010 proof host adapter 安装必须是幂等的：重复执行产生同一语义配置，不
    重复注册 VibeGuard hook，不改变第三方 hook 的内容或相对顺序；clean/disable
    只移除可证明由 VibeGuard 管理的条目。
11. B-011 host 配置缺失、只读、语法损坏、写入中断或 verification 失败时不得
    留下“安装完成”的部分状态；旧可用配置必须保留或恢复，失败必须可见并给出
    修复动作。
12. B-012 同一机器同时安装多个受支持 host 时，各 host 的配置、wrapper identity
    与 health evidence 必须隔离；并发或任意顺序的重复安装不得让一个 host 的
    event 被归属为另一个 host，也不得覆盖第三方配置。
13. B-013 新 adapter 的默认数据流保持 local-first：不新增网络上报、远端执行、
    analytics 或 secret 读取；host 配置写入只发生在用户确认的目标与 VibeGuard
    owned entry 内，并遵守 host 自身权限边界。
14. B-014 已支持的 Claude Code 与 Codex CLI 安装、profile、capability、
    fail-closed、第三方 hook preservation、doctor/verify-install 与 clean 语义
    必须保持；generalize manifest 或 adapter registry 不得改变它们的有效配置。
15. B-015 adapter 与 core 的 compatibility 必须由 host adapter contract
    version、host protocol/version range 与 VibeGuard runtime version 显式判定；
    不兼容组合必须 fail visible，不能尝试 best-effort 转换后报告成功。
16. B-016 用户中断安装或 adapter update 后重试时，系统必须从已验证的旧状态或
    明确的 incomplete 状态继续；不得复用未验证的 temporary config、伪造成功
    evidence 或产生重复 event registration。
17. B-017 每次 install/check/doctor 必须从当前配置与一次 bounded probe 生成
    host evidence，至少区分 `active`、`partial`、`unsupported`、
    `incompatible`、`broken`、`not_installed`；历史日志或仅检测到可执行文件
    不能单独证明当前 protection active。
18. B-018 在 GH-699 与 GH-700 各自完成后，首屏才可组合展示其已验证的一命令
    安装与 released benchmark；从空环境到安装、verify 与 proof host 真实
    interception 的维护者复核流程应在五分钟目标内完成，任一依赖缺失时必须
    明确显示当前较窄路径而非宣称达标。

## 验收标准

- [ ] 有一份版本化 host adapter/capability 契约，Claude、Codex 与 proof host
  都通过 schema 与 deterministic fixture 验证，未知 host/字段 fail visible。
- [ ] 新 proof host 在真实 session 中完成一次 blocking interception，输出 fix
  instruction，health evidence 显示正确 host/protocol/capability。
- [ ] 同一 canonical fixture 在 Claude、Codex、proof host 的共同能力交集上得到
  等价 decision；新增 host 的 diff 没有复制或修改 rule/guard core。
- [ ] 重复安装、第三方 hook preservation、malformed config/payload、partial
  write、clean 与多 host 顺序/并发 fixture 全部通过。
- [ ] README 只陈述当前可证实事实；GH-699/GH-700 未完成时不提前发布一命令安装
  或 benchmark，完成后五分钟 journey 有新鲜人工证据。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-004, B-008, B-009 |
| 错误与失败路径 | covered: B-007, B-008, B-011, B-015, B-017 |
| 授权/权限 | covered: B-010, B-011, B-013 |
| 并发/竞态 | covered: B-012 |
| 重试/幂等 | covered: B-010, B-016 |
| 非法状态转换 | covered: B-011, B-015, B-016, B-017 |
| 兼容/迁移 | covered: B-004, B-014, B-015 |
| 降级/回退 | covered: B-003, B-007, B-008, B-011, B-018 |
| 证据与审计完整性 | covered: B-001, B-002, B-003, B-006, B-017, B-018 |
| 取消/中断 | covered: B-016 |

## 发布说明

PR #705 的首屏 cut 是已交付 baseline，不需要回滚或重做。host adapter seam 与
proof host 在 spec 获批、proof host/安装策略/stale branch ownership 三项人工
决策记录完成后实施。README 的 one-command install 与 benchmark 更新分别等待
GH-699、GH-700 的 released evidence；adapter 发布说明必须列出 capability matrix、
协议/version range、unsupported event、配置写入面、clean 与隐私边界。
