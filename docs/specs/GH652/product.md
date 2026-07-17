# Product Spec

## Linked Issue

GH-652

## 用户问题

setup structured-report regression 在首次执行被测 setup 命令前没有建立“当前 source 对应当前
runtime binary”的确定性边界。worktree 中若遗留版本号和命令面相同、但行为早于当前 main 的
debug binary，测试会先消费旧行为；后段测试才执行 `cargo build`，导致同一提交第一次失败、
第二次通过。

## 目标

- 所有 setup health assertions 都使用由当前 worktree source fresh build 的同一个 runtime。
- 测试不受调用者预置 runtime 或 stale same-version artifact 影响。
- runtime build/pin 失败时在任何 setup behavior assertion 前显式失败。

## 非目标

- 不改变生产 runtime resolver 的 installed/repo/release 顺序或 capability semantics。
- 不修改 runtime 版本、release metadata 或发布流程。
- 不弱化或删除 stale hook、unmanaged blocking hook、timeout、JSON 或 exit-code 断言。
- 不修改 GH-631 distribution asset 范围。

## Behavior Invariants

1. B-001 setup structured-report suite 在第一次执行 `setup.sh` 前必须 build 当前 worktree runtime，
   并把本 suite 的全部 setup 调用显式绑定到该 binary。
2. B-002 调用者预置的不存在、stale 或 same-version `VIBEGUARD_SETUP_RUNTIME` 不得接管测试；
   caller `CARGO_TARGET_DIR` 也不得把 fresh build 与 pinned path 分离。suite 必须以显式 worktree
   target dir build，并用对应确定路径覆盖 runtime。
3. B-003 build 失败或当前 binary 不可执行时必须立即非零退出，不得继续并回退 installed、
   release 或 PATH runtime。
4. B-004 runtime-config mode matrix 必须复用 suite 已 pin 的同一个 binary，不得在后段才首次
   build 或建立第二套 runtime 选择逻辑。
5. B-005 现有 260 项 setup health/format/exit-code 行为断言必须保持，不得以删除或放宽断言
   消除 stale-runtime 失败。
6. B-006 生产 `scripts/setup/lib.sh` 和 runtime setup helper semantics 必须保持无修改。

## 验收标准

- [ ] stale caller runtime 与外部 Cargo target dir 环境下，suite 仍 build/pin 当前 worktree runtime
  并全部通过。
- [ ] build/pin 发生在首个 setup behavior invocation 之前，失败时立即停止。
- [ ] 后段 runtime-config matrix 复用同一 pin，无重复/迟到 build owner。
- [ ] 现有 setup assertions 与生产 resolver 均未弱化或改写。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-002, B-003 |
| 错误与失败路径 | covered: B-003 |
| 授权/权限 | N/A：仅本地测试 build，无权限模型变化 |
| 并发/竞态 | covered: B-001；单 suite 在 assertions 前串行建立 binary |
| 重试/幂等 | covered: B-001, B-002；重复运行仍绑定当前 build |
| 非法状态转换 | covered: B-003；build 失败不得进入 behavior assertions |
| 兼容/迁移 | covered: B-005, B-006 |
| 降级/回退 | covered: B-003；测试禁止 fallback |
| 证据与审计完整性 | covered: B-001, B-004, B-005 |
| 取消/中断 | covered: B-003；cargo 中断为非零并停止 |

## 发布说明

测试可靠性修复；无用户 runtime、安装或发布行为变化。
