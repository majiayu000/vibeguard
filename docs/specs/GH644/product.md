# Product Spec: runtime-policy diagnostic I/O 测试消除 BrokenPipe 竞态

## Linked Issue

GH-644: https://github.com/majiayu000/vibeguard/issues/644

complexity: small

## 用户问题

`runtime_policy_diag_open_error_is_visible` 已在两个独立远端 CI run 中于测试
helper 写 stdin 时因 `BrokenPipe` 提前 panic，导致测试没有机会检查本来要验证的
子进程失败、stdout 与 stderr。搜索还发现专用 diagnostic I/O 测试中的父目录创建
失败和 Linux `/dev/full` 写失败使用同一 live pipe 模式；继续只修单个用例会把波动
留给相邻失败路径。

## 目标

- 让全部 `runtime-policy-diag` I/O 失败测试以确定、跨平台的 stdin 输入执行。
- 始终收集并断言真正的子进程 status/stdout/stderr，不让父进程 EPIPE 抢先取代证据。
- 把 open-error 用例归入已有专用 diagnostic I/O integration test 文件，并缩小接近
  800 行硬上限的通用 policy test 文件。
- 保持现有失败路径断言与 fixture 完整性，不用降低测试强度换取绿灯。

## 非目标

- 不修改 `runtime-policy-diag` 生产实现、读取顺序、错误语义或公开命令。
- 不修改 schema、配置、hook、setup、安装或持久化行为。
- 不让共享 stdin helper 忽略任意 `BrokenPipe`，也不改无关 stdin-driven tests。
- 不要求把远端调度波动伪造成稳定的本地红态。

## Behavior Invariants

1. B-001：diagnostic I/O 失败测试的固定非空 reason 必须在子进程启动时由确定性
   stdin source 提供；输入传输不得依赖父进程在 child 运行期间向 live pipe 写入。
2. B-002：父目录创建失败、既有目录作为 diag-file 的 open 失败，以及 Linux
   `/dev/full` 写失败必须分别到达并观察其预期的 `runtime-policy-diag` I/O 失败；
   非 Linux 平台继续只运行跨平台的前两类。
3. B-003：每个 diagnostic I/O 失败用例必须断言 child 非成功退出、stdout 为空、
   stderr 非空；父目录 blocker 内容必须不变，open-error 目标必须仍为目录。
4. B-004：任何 parent-side stdin `BrokenPipe` 都不得先于 child output collection
   使这些用例 panic；fixture 创建、打开或 command 启动失败仍必须 fail loudly。
5. B-005：现有共享 `run_runtime_with_stdin` helper 与无关 policy/codex/CLI 测试不变；
   本修复只覆盖 diagnostic I/O failure-test family。
6. B-006：`vibeguard-runtime/src/`、命令参数、输出合同、schema 与生产数据流不变；
   这是纯测试可靠性修复。
7. B-007：通用 `runtime_policy_cli.rs` 必须因职责迁移而缩小并保持 `<800` 行；专用
   diagnostic I/O test 也保持职责单一。实现需通过 200 次 focused repetition、完整
   Rust tests 与 broad contract gate，且不得把重复失败静默视为成功。

## 验收标准

- [ ] 三类 diagnostic I/O error cases 使用同一确定性 stdin fixture；无 live pipe writer。
- [ ] open-error case 从通用 policy test 移入现有 `runtime_policy_diag_io_cli.rs`。
- [ ] status/stdout/stderr、blocker 内容和目录完整性断言保持或加强。
- [ ] 共享 helper、生产 runtime 与无关测试没有 diff。
- [ ] focused diagnostic I/O test 连续 200 次通过，Rust fmt/check/full test 与 quick
      contract 全绿。
- [ ] current-head CI、独立审查、零 unresolved review threads 与 SpecRail PR gate 全绿。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-001, B-004；固定 reason 非空，fixture 缺失或打开失败必须显式失败 |
| 错误与失败路径 | covered: B-002, B-003, B-004 |
| 授权/权限 | N/A：测试不新增权限、secret 或外部系统操作 |
| 并发/竞态 | covered: B-001, B-004, B-007 |
| 重试/幂等 | covered: B-007；重复执行必须稳定且每次独立清理 fixture |
| 非法状态转换 | N/A：测试只启动一次同步 child，不维护状态机 |
| 兼容/迁移 | covered: B-002, B-005, B-006 |
| 降级/回退 | covered: B-003, B-004；禁止用忽略 EPIPE 或弱化断言降级 |
| 证据与审计完整性 | covered: B-003, B-007 |
| 取消/中断 | covered: B-004；中途 fixture/command 失败不得伪装成预期 child failure |

## 发布说明

这是测试基础设施可靠性修复，不改变用户可见 runtime 行为、配置或数据。实现 PR
需记录两次远端 BrokenPipe baseline、focused 200 次结果、文件行数与完整门禁证据。
