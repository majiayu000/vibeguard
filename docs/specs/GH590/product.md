# Product Spec

## Linked Issue

GH-590

关联规范 PR：#593。

complexity: medium

## 用户问题

W-14 会在当前 session/agent 编辑一个刚被其他 session/agent 修改过的文件时发出
可执行的 worktree/single-owner 提示。当前实现对同一冲突组合的每次后续编辑都重复
完整提示；在刻意并行开发的热文件上，这会把一次有价值的 ownership 警告放大为噪声，
并让使用者逐渐忽略 W-14。

降噪不能以静默丢失审计证据为代价，也不能弱化首次冲突、换文件、换 peer session、
反向 session 顺序或其他 post-edit finding。配置、时间边界和历史证据不可信时，系统必须
偏向再次提示，而不是猜测已经提示过。

## 目标

- 对同一有向 `(current_session, peer_session, normalized_file)` 在可配置 cooldown 内只
  展示一次完整 W-14；不同 key 仍各自展示。
- 用 schema-valid event 记录每次被抑制的重复命中，使 raw log 与通用 observability
  仍能统计 W-14 发生频率，同时不增加 warn/escalate 计数。
- 明确定义 `0`、精确时间边界、无效/未来时间、历史窗口截断和 telemetry 写失败行为。
- 保持现有 overlap detection、完整 FIX 文案、W-15/CHURN 和其他 warnings 的语义。

## 非目标

- 不改变 W-14 的 30 分钟 recent-overlap 候选检测、session/agent 判定或路径归一化语义。
- 不对 W-15、CHURN、U-16 或其他 post-edit finding 做 cooldown。
- 不新增 watermark/state 文件，也不自动创建 worktree、修复 ownership 或解决 review thread。
- 不新增 `info` decision；`event_schema.rs` 当前没有该 decision。
- 不为 GC digest 新增展示区块；本次只保证 raw event 与现有通用 observe/rule counters 可见。
- 不把 `hooks/_lib/post_edit_history.sh` 声明为生产 fallback；当前 `hooks/post-edit-guard.sh`
  只执行 Rust runtime，该 shell helper 仅被兼容测试直接 source。

## Behavior Invariants

1. B-001 当现有 W-14 overlap detection 首次为一个有向 key
   `(current_session, peer_session, normalized_file)` 产出 candidate，或该 key 没有有效
   cooldown 证据时，必须展示当前完整 `[W-14]` warning 与 FIX/DO NOT 文案，并记录一次
   可供后续 cooldown 识别的 warn evidence；候选检测本身不得因本功能放宽。
2. B-002 Key 必须同时包含当前 session、candidate 的 peer session 与现有规则归一化后的
   file path。相对/绝对形式指向同一文件时属于同一 key；`(A,B,file)` 与
   `(B,A,file)` 是两个有向 key。
3. B-003 只有同一 key 的 prior shown evidence 满足 `0 <= now - prior_ts < cooldown_seconds`
   时才抑制当前 W-14。年龄恰好等于或大于 cooldown 时重新展示；suppressed event 不延长
   窗口，窗口始终从最近一次实际展示的 W-14 计算。
4. B-004 Cooldown 配置按 `VIBEGUARD_W14_COOLDOWN_SECONDS` 环境变量、
   `w14.cooldown_seconds` user runtime config、内建默认 `3600` 的顺序解析。值 `0` 禁用
   suppression；无效环境值回退到 config，缺失/负数/错误类型 config 值回退到默认，
   不得把无效值解释成无限 suppression。
5. B-005 成功抑制必须追加一个 schema-valid event：`decision=pass`、`status=skipped`、
   `hook=post-edit-guard`，reason 以 `[W-14] overlap suppressed cooldown` 开头，并保留
   当前 session、文件 detail 与 opaque `w14_key`。该 event 必须被 raw log 和现有
   observe rule/hook counters 计入，但不得进入 warn/escalate、prior-warn escalation 或
   agent-visible output。
6. B-006 只有最后 500 条既有 post-edit history 中字段完整、key 精确匹配、timestamp
   可解析且不在未来的 shown evidence 才能授权 suppression。log 读取失败、记录缺失/损坏、
   session 缺失或为 unknown、key 不完整、timestamp 无效/未来、evidence 已过期或已被
   500 行窗口截断时，都必须 fail-open 为完整 W-14；不得用 suppressed event 自证下一次
   suppression。
7. B-007 如果系统无法成功追加 B-005 的 suppressed telemetry event，本次不得静默
   suppression，必须回退为 agent-visible W-14。首次 shown-evidence 写失败也不得隐藏当前
   warning；它只会导致后续调用缺少 suppression 资格并再次提示。
8. B-008 不同 normalized file、不同 peer session、缺少可验证 peer session 或反向 session
   顺序均独立判断并展示首次 W-14，不得因 agent 名相同、basename 相同或 reason 文本相似
   而共享 cooldown。
9. B-009 W-14 被 suppression 时，同一次 hook run 中的 W-15、CHURN、U-16 或其他 finding
   必须继续按原规则展示并决定最终 hook decision；cooldown 不得把整个 hook invocation
   改写成无条件 pass。
10. B-010 存量 user config 缺少 `w14` object 时自动采用默认值，setup 只在首次 seed 时把
    新 key 写入示例 config，继续遵守“不覆盖用户已有 config”。关闭功能只需配置 `0`，
    不要求迁移或删除历史 event。

## 验收标准

- [ ] 同一 current/peer/file key 的首次 W-14 完整可见，cooldown 内重复命中不可见但有
      `pass/skipped` telemetry；精确边界到期后再次可见。
- [ ] 不同 file、peer、反向 session 顺序、unknown/missing session 均不会复用 cooldown。
- [ ] 相对与绝对路径归一到同一文件时复用同一 key。
- [ ] `0`、默认值、env/config precedence 和错误类型回退均有 deterministic fixture。
- [ ] 无效/未来/截断 history 与 telemetry append failure 都不会静默抑制 W-14。
- [ ] suppressed event 可由现有 observe rule counter 识别为 W-14，但不增加 negative
      decision、prior warn 或可见 warning。
- [ ] mixed W-14 + 其他 warning 只移除重复 W-14，其他 warning 与最终 decision 保持。
- [ ] 生产验证只覆盖 Rust hook path；不新增虚假的 shell fallback parity 承诺。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-006, B-008（session/key/evidence 缺失时 fail-open warning） |
| 错误与失败路径 | covered: B-004, B-006, B-007（配置、history、timestamp、append failure） |
| 授权/权限 | N/A：本地 advisory hook 不执行权限或 merge 状态转换 |
| 并发/竞态 | covered: B-001, B-002, B-003, B-007（有向 key、显示证据、写失败不静默） |
| 重试/幂等 | covered: B-003, B-005（窗口从 shown evidence 计算；suppressed event 不续期） |
| 非法状态转换 | covered: B-005, B-006（无有效 shown evidence 不得进入 suppressed 状态） |
| 兼容/迁移 | covered: B-001, B-004, B-010（旧 event/config fail-open；`0` 可关闭） |
| 降级/回退 | covered: B-004, B-006, B-007（所有不确定性回退为 visible W-14） |
| 证据与审计完整性 | covered: B-005, B-006, B-007（schema-valid telemetry、不能自证、写入前提） |
| 取消/中断 | covered: B-007（append 未成功即不授权 suppression；重跑可安全再次警告） |

## 发布说明

默认情况下，同一有向 session pair 对同一文件的重复 W-14 会在一小时内降噪；首次提示、
其他 key 和其他 findings 不变。需要旧行为时在 runtime config 设置
`"w14": {"cooldown_seconds": 0}` 或导出 `VIBEGUARD_W14_COOLDOWN_SECONDS=0`。
升级前缺少 `w14_key` 的旧 event 不会静默授权 suppression，因此升级后可能再看到一次完整
提示，这是刻意的 fail-open 兼容行为。
