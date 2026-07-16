# Task Plan: GH621 runtime 安装职责拆分

## Linked Issue

GH-621

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP621-T1` Owner: `/root` — 在 setup focused contracts 中先增加 helper existence/source wiring、entrypoint/helper syntax 与 `<800` / `<400` 行边界，并把 no-cargo-metadata 断言指向 canonical helper。Depends on: Spec PR merged and implementation route allowed。Covers: B-006, B-008。Done when: 未实现分支因缺少 helper 或入口仍超限确定性失败，原 cargo-metadata 禁止断言未弱化。Verify: `bash tests/test_setup.sh`（production extraction 前保留预期失败证据）。
- [ ] `SP621-T2` Owner: `/root` — 在 `scripts/setup/` 新增无 source-time 副作用的 `runtime-install.sh`，机械移动九个 install-time runtime 函数，并让 entrypoint 在调用前 source。Depends on: SP621-T1。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-008。Done when: 函数名/顺序/函数体/全局读写和调用点保持，entrypoint `<800`、helper `<400`，两者 syntax 通过。Verify: `bash -n scripts/setup/install.sh scripts/setup/runtime-install.sh`; `wc -l scripts/setup/install.sh scripts/setup/runtime-install.sh`; focused setup contracts。
- [ ] `SP621-T3` Owner: `/root` — 让 release contract 与 U-29 self-application 扫描 entrypoint + helper 的完整安装表面，并增加 helper-only forbidden fallback mutation。Depends on: SP621-T2。Covers: B-003, B-004, B-007。Done when: 原安全文案断言继续通过，bad entrypoint 与 bad helper mutations 均使 U-29 检查失败，不添加复制安全字符串的注释。Verify: `bash tests/test_release_workflow.sh`; `bash tests/test_self_application_ci.sh`。
- [ ] `SP621-T4` Owner: `/root` — 执行 setup/runtime supply-chain 全回归并审查 mechanical extraction。Depends on: SP621-T3。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008。Done when: setup、release、self-application、hooks/manifest、quick、diff checks fresh 通过；独立 reviewer 无 blocker；current-head CI、review threads 与 SpecRail PR gate 全部通过。Verify: tech spec 测试计划中的全部命令。

## 顺序与所有权

本变更的入口 source wiring、runtime 函数移动和静态合同强耦合，采用单一 writer 逐步执行。
独立 reviewer 只读比较 `origin/main` 原函数体、linked specs、失败语义、测试 mutation 与当前 PR
head，不写共享文件。

## 验证证据

- Red evidence：新 focused contract 在 production extraction 前因缺 helper/entrypoint 871 行失败。
- Structural evidence：entrypoint/helper 行数和 `bash -n` 输出；函数体机械对比。
- Behavior evidence：完整 setup flow 覆盖 prebuilt、checksum/manifest、strict provenance、version、
  source build、config、dry-run 和 install。
- Security evidence：release assertions 与 U-29 entrypoint/helper mutation tests。
- Gate evidence：fresh local commands、current-head CI、零 review threads、independent review 与
  SpecRail PR gate。

## Handoff Notes

- `mode`: `specrail-implement`
- `artifacts`: `docs/specs/GH621/product.md`, `docs/specs/GH621/tech.md`,
  `docs/specs/GH621/tasks.md`
- `runtime_pinning_snapshot`: None；短周期机械 setup 拆分，不改变 runtime binary 或 tool inventory。
- `verification_owner`: `/root`
- `stop_conditions`: 任一 runtime 函数体/错误语义需要非机械修改；公共 CLI 或安装顺序改变；
  必须弱化/删除现有断言；helper source-time 产生副作用；任一 focused/full/quick gate 失败；
  独立 review 有 blocker；current-head CI、review threads 或 PR gate 未通过。
- `lane_map`: implementation `/root` 独占 `scripts/setup/install.sh`, `scripts/setup/` 下计划新增的
  `runtime-install.sh`, `tests/test_setup.sh`,
  `tests/setup/syntax_manifest_tests.sh`, `tests/test_release_workflow.sh`,
  `scripts/ci/self-application/check-u29-no-silent-degrade.sh`,
  `tests/test_self_application_ci.sh`；independent reviewer `/root/review_pr612` 只读，无可写文件。
- Spec PR 只 `Refs #621`；只有独立 Impl PR 合并后才关闭 Issue。
