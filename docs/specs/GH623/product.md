# Product Spec: 拆分超限的 self-application CI harness

## Linked Issue

GH-623

## 用户问题

`tests/test_self_application_ci.sh` 在最新 `origin/main@337750e` 上为 854 行，超过 U-16 的
800 行硬上限。该文件从最初的基础 self-application 回归逐步加入 Codex wrapper thinness、
package-correction argv、hook output rewriting、SEC-13、U-29 与 SEC-14 mutation，目前 68 个断言
分布在多个独立安全域中。继续在单文件追加 detector edge case 会增加冲突、审查和故障定位成本，
也没有剩余的行数安全余量。

## 目标

- 保留 `bash tests/test_self_application_ci.sh` 作为唯一稳定入口与 CI 调用面。
- 将现有 mutation 按职责机械提取到有序的 focused test 文件，使 aggregate 与每个 child 均低于
  400 行。
- 保持现有 68 个断言、section 顺序、输出、累计计数、退出码与临时 fixture cleanup 语义。
- 将 aggregate/child 行数纳入 canonical test-file size guard，防止同类超限再次静默发生。

## 非目标

- 不改变任何 `scripts/ci/self-application/` production checker 的检测语义或匹配规则。
- 不新增、删除、合并或弱化现有 mutation/assertion。
- 不改变 `.github/workflows/ci.yml` 的 Self-Application CI 入口或 required-check 名称。
- 不把 sourced focused 文件变成独立公共测试入口，不引入新的测试框架。
- 不顺手重构 fixture 内容、统一变量名或修改与拆分无关的策略规则。

## Behavior Invariants

1. B-001：`bash tests/test_self_application_ci.sh` 仍按原顺序执行全部 68 个具名断言，并保持相同
   section headings、PASS/FAIL 累计、最终 summary 与失败退出语义。
2. B-002：Codex wrapper、package-correction、hook-output/SEC-13/U-29、SEC-14 四组现有测试只做
   机械移动；fixture 内容、checker 命令、expected pass/fail 方向与断言文案不变。
3. B-003：`REPO_DIR`、`SELF_DIR`、`TMP_DIR`、计数器、assert helpers 和唯一 cleanup trap 保留在
   aggregate；focused files 不重复定义共享状态、trap 或 cleanup。
4. B-004：focused files 由 aggregate 确定性、同步、按原 section 顺序 source；任一 child 缺失、
   语法损坏或断言失败都必须使 aggregate 非零，后续 cleanup 仍执行。
5. B-005：aggregate 与每个 `tests/self_application/*.sh` child 均低于 400 行，且
   `scripts/verify/check-test-file-sizes.sh` 明确执行这些边界。
6. B-006：每个提取域继续包含能使对应 production checker 失败的真实 mutation，不允许通过复制
   安全文案、只检查文件存在或只比较断言总数来制造假覆盖。
7. B-007：production checker、CI workflow、公共命令与规则语义不变；这是 test harness 结构优化。
8. B-008：文件拆分前后的具名断言集合必须完全相等；不得因 source 顺序或变量泄漏让 fixture
   依赖前一 domain 的偶然状态。

## 验收标准

- [ ] size-guard contract 在拆分前对 854 行 aggregate 产生确定性红测，拆分后转绿。
- [ ] aggregate 稳定入口不变且 `<400` 行；四个 cohesive focused files 各自 `<400` 行。
- [ ] 拆分前后 `assert_cmd` / `assert_fails` 调用清单与 68 个断言总数完全一致。
- [ ] section 顺序保持：self-application scripts、Codex wrapper、package correction、hook output、
  SEC-13、U-29、SEC-14。
- [ ] 每个 focused domain 的既有正/负 mutation 继续执行对应 checker；无 assertion weakening。
- [ ] child 缺失/语法检查与 aggregate sourcing 由结构合同覆盖，shared cleanup 仍只有一个 owner。
- [ ] `bash tests/test_self_application_ci.sh`、canonical size guard、quick contract 与 fresh CI 全绿。
- [ ] 不修改 production self-application checker、workflow、规则或公共路径。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-004；缺失 child 必须 source 失败 |
| 错误与失败路径 | covered: B-001, B-004, B-006 |
| 授权/权限 | N/A：仅本地测试 fixture 拆分 |
| 并发/竞态 | N/A：aggregate 同步顺序 source |
| 重试/幂等 | covered: B-001, B-003；每次运行创建并清理独立 temp root |
| 非法状态转换 | covered: B-004, B-008 |
| 兼容/迁移 | covered: B-001, B-007；稳定入口不变 |
| 降级/回退 | covered: B-004, B-006；child 或 checker 失败不得被跳过 |
| 证据与审计完整性 | covered: B-005, B-006, B-008 |
| 取消/中断 | covered: B-003；aggregate EXIT trap 继续拥有 cleanup |

## 发布说明

这是内部测试结构优化，不改变用户行为或 VibeGuard policy。维护者继续运行同一条
`bash tests/test_self_application_ci.sh` 命令，但失败会按 focused domain 更容易定位，且后续增长受
400 行边界保护。
