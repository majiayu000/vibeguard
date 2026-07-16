# Task Plan: GH623 self-application harness 拆分

## Linked Issue

GH-623

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP623-T1` Owner: `/root` — 扩展 `scripts/verify/check-test-file-sizes.sh`，对 aggregate 与 `tests/self_application/*.sh` 传入 inclusive `max_lines=399` 以执行 `<400` 合同，并在拆分前保存当前 854 行 aggregate 的具名失败证据。Depends on: Spec PR merged and implementation route allowed。Covers: B-005。Done when: canonical guard 确定性指出 `tests/test_self_application_ci.sh` 超限，且未弱化其他既有 test-size 边界。Verify: `bash scripts/verify/check-test-file-sizes.sh`（预期红）。
- [ ] `SP623-T2` Owner: `/root` — 逐段机械提取 wrapper、package-correction、policy、SEC-14 四个 focused fragments，并让 aggregate 在原位置按原顺序显式 source；共享 helpers、temp root、trap、preflight 与 summary 留在 aggregate。Depends on: SP623-T1。Covers: B-001, B-002, B-003, B-004, B-008。Done when: aggregate/children 均 `<400`；四个原 section block 文本与 base snapshot 一致；child 无重复 harness/trap；source path/order 确定。Verify: shell syntax、line counts、base-vs-split block comparison、ordered assertion-description inventory。
- [ ] `SP623-T3` Owner: `/root` — 运行全部 68 个既有 mutation/assertion，逐域确认 wrapper、package、SEC-13/U-29 与 SEC-14 production checkers 仍被真实 good/bad fixtures 覆盖。Depends on: SP623-T2。Covers: B-001, B-004, B-006, B-007, B-008。Done when: assertion 清单无新增/删除/改名，aggregate 输出 68/68，任一 child/checker 失败不可被 aggregate 吞掉，changed-file audit 无 production checker 或 workflow 变更。Verify: `bash tests/test_self_application_ci.sh`；`bash scripts/ci/self-application/run-all.sh .`。
- [ ] `SP623-T4` Owner: `/root` — 执行 full/quick regression 与独立审查。Depends on: SP623-T3。Covers: B-001-B-008。Done when: syntax、size guard、68/68 aggregate、run-all、quick、diff checks fresh 通过；独立 reviewer 无 blocker；current-head CI、review threads 与 SpecRail PR gate 全部通过。Verify: tech spec 测试计划中的全部命令。

## 顺序与所有权

本变更必须由单一 writer 逐段人工移动 heredoc-heavy fixtures；禁止脚本批量生成或两个 writer 同时编辑
aggregate/children。独立 reviewer 只读比较 `origin/main@337750e`、linked specs、section/assertion
inventory、size guard 与当前 PR diff，不写共享文件。

## 验证证据

- Red evidence：canonical size guard 在 split 前具名拒绝 854 行 aggregate。
- Structural evidence：五个 shell 文件 syntax、每文件 `<400`、四个 source path/order、唯一 trap/helper
  owner、base section block 对比。
- Inventory evidence：拆分前后 ordered 68 assertion descriptions 完全一致。
- Behavior evidence：aggregate 68/68，各 domain good/bad mutation 继续运行原 production checker。
- Gate evidence：fresh local commands、current-head CI、零 unresolved review threads、independent review 与
  SpecRail required PR gate。

## Handoff Notes

- `mode`: `specrail-implement`
- `artifacts`: `docs/specs/GH623/product.md`, `docs/specs/GH623/tech.md`,
  `docs/specs/GH623/tasks.md`
- `runtime_pinning_snapshot`: None；test-only structural split，不改变 runtime/tool inventory。
- `verification_owner`: `/root`
- `stop_conditions`: 任一现有 fixture/assertion 文本需要非机械修改；assertion 数量或 ordered description
  变化；production checker/workflow 必须修改；child 需要独立 temp/trap/counter；source order 产生
  cross-domain 依赖；任一 aggregate/child 不低于 400 行；任一 focused/run-all/quick gate 失败；独立
  review 有 blocker；current-head CI、threads 或 PR gate 未通过。
- `lane_map`: specification `/root` 独占 `docs/specs/GH623/` 与 spec index；implementation `/root`
  独占 `tests/test_self_application_ci.sh`, `tests/self_application/`,
  `scripts/verify/check-test-file-sizes.sh`；independent reviewer `/root/review_pr612` 只读，无可写文件。
- Spec PR 只 `Refs #623`；只有独立 Impl PR 合并后才关闭 Issue。
