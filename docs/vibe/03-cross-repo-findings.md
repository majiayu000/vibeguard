# 跨库问题复盘：对 VibeGuard 的优化建议（2026-02-26）

## 数据来源

- `/Users/apple/.codex/sessions/2026/02/26/rollout-2026-02-26T21-12-26-019c9a14-4a6f-7391-a915-404caf9135dc.jsonl`（`litellm-rs`）
- `/Users/apple/.codex/sessions/2026/02/26/rollout-2026-02-26T21-12-49-019c9a14-a1c3-78e2-b97c-bdfc819a6381.jsonl`（`sage`）
- `/Users/apple/.codex/sessions/2026/02/26/rollout-2026-02-26T21-12-58-019c9a14-c6c9-7fd2-8df7-62fbb701b21b.jsonl`（`tink/rnk`）

## 各库高频问题（按会话归纳）

1. `litellm-rs`
- 配置声明与运行时装配脱节（配置可写但链路未接线）。
- 多路由/多 provider 语义存在静默降级或不生效路径。
- 示例配置与真实 schema 漂移，导致“看文档配置但运行异常”。
- 错误被吞或误导性 fallback，降低可观测性。

2. `sage`
- 同一领域存在双任务系统并行，状态源冲突（单一事实源被破坏）。
- `TaskDone` 语义与实现不一致（声明“完成任务”但不落状态）。
- Prompt 体系存在新旧双轨，存在重复/死代码路径。
- 分层边界弱（core/sdk/tools 耦合），版本治理不一致。

3. `tink/rnk`
- 新架构（reconciler）未真正接入主循环，仍全量重建。
- 节点 ID 跨帧不稳定，影响测量/调试/增量更新。
- hook 规则不一致（部分 hook 不占 slot），语义不统一。
- 线程模型偏重（高频场景线程创建成本高），存在“上帝对象”风险。

## 跨库共性根因

1. 配置合同漂移：配置/文档/运行时三者不同步。
2. 双轨系统未收敛：新旧路径并存且同时生效。
3. 语义-行为不一致：命名承诺与实际副作用不一致。
4. 静默降级和吞错：错误未 fail-fast，或日志语义误导。
5. 架构债晚暴露：关键模块“看起来存在”，但未接入主链路。

## 对 VibeGuard 的优化结论

结论：这些发现可以直接优化 VibeGuard，而且是高价值优化。  
理由：当前 guards 更擅长“语法/重复/明显坏味道”，但对“合同一致性、系统收敛、语义正确性”覆盖偏弱，而这正是今天三库反复出现的问题。

## 建议新增能力（P0-P2）

1. `P0` 合同一致性守卫（Contract Drift Guard）
- 目标：检测“配置 schema / example / runtime 支持矩阵”不一致。
- 最小实现：新增 `scripts/ci/validate-config-contract.sh`，比较 example 字段与模型定义；对未接线路由策略输出失败。

2. `P0` 禁止静默降级规则（No Silent Fallback）
- 目标：不允许将不支持策略悄悄降级为默认策略。
- 最小实现：在 `rules/universal.md` 增加规则：不支持必须显式报错或标记为 DEFER，不得 silent downgrade。

3. `P1` 单一事实源守卫（Single Source of Truth）
- 目标：检测同一职责被两套系统同时注册/持久化。
- 最小实现：新增脚本扫描“同域工具注册点 + 多状态存储写入点”，输出冲突告警。

4. `P1` 语义副作用一致性检查（Semantic Effect Check）
- 目标：识别 `Done/Update/Delete` 这类动作函数是否真的写状态或触发事件。
- 最小实现：在 workflow 审查模板中加入“动作动词必须有可验证副作用”的检查项。

5. `P1` 主链路接线验证（Wiring Guard）
- 目标：防止“模块已实现但未接入主路径”。
- 最小实现：为关键模块定义启动期 smoke test，验证入口到目标模块的实际调用。

6. `P2` 热路径资源预算守卫（Hot Path Budget）
- 目标：限制全量扫描/线程爆炸/重操作并发。
- 最小实现：统一并发与扫描预算环境变量，并在日志中输出降级原因。

## 与当前仓库已做改动的关系

- 已完成：`setup` 入口拆分、`post-write` 扫描预算、`mcp` 增加 `javascript` 支持、`setup` 最小回归测试。
- 已完成：`mcp` 并发上限与异常隔离、`mcp-server` 基础测试、CI workflow（含 build/test）。
- 本次新增：`scripts/ci/validate-config-contract.sh`（合同一致性守卫）与 `U-23`（禁止静默降级）规则落地。
- 本次新增：Rust 守卫 `single_source_of_truth` / `semantic_effect`，用于拦截双轨系统和动作语义失真。
- 本次新增：`scripts/ci/validate-wiring-contract.sh`，防止“守卫实现了但未接入 MCP/文档”。
- 已完成：仓库设置层启用“PR 必须通过 CI 才可合并”（required check=`validate-and-test`）。
- 仍待完成：命名债务（`plan-flow` 到 `plan-flow` 的文档迁移收口）。

## 推荐落地顺序

1. 先补 `P0`（合同一致性 + 禁止静默降级），优先阻断“配置可写但不生效”。
2. 再补 `P1`（单一事实源 + 语义副作用 + 主链路接线），优先阻断“看起来修了但其实没接上”。
3. 最后补 `P2`（资源预算统一与命名债务），降低长期维护成本。

---

## 2026-03-01 增量补强（waoowaoo 守卫回灌）

本轮把跨库验证过的守卫模式抽象回灌到 VibeGuard（非项目私有逻辑直拷）：

1. 新增 `TS-13`：`check_no_api_direct_ai_call.sh`
- 目标：拦截 API 路由层直接 import/调用模型 SDK 的行为，强制经统一任务层。

2. 新增 `TS-14`：`check_no_dual_track_fallback.sh`
- 目标：拦截双轨执行标记（如 sync fallback 分支），防止“看起来可用、实际掩盖错误”。

3. 升级 `TS-15`：`check_duplicate_constants.sh`
- 修复计数作用域缺陷（明细和 summary 不一致）。
- 忽略 Next.js Route Handler 的 `GET/POST/...` 合法重复导出，降低误报。

4. 配套接线同步
- MCP `guard_check` 新增 `no_api_direct_ai_call / no_dual_track_fallback / duplicate_constants`。
- `/vibeguard:check` 与 `/vibeguard:preflight` 命令文档同步新增 TS 守卫。
- `setup --check` 与 `metrics_collector.sh` 同步新增 TS 守卫可见性与指标输出。
- `compliance_check.sh` 支持 `AGENTS.md` 作为项目级规则源（不再强依赖 `CLAUDE.md`）。
