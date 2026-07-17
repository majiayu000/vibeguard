# Task Plan

## Linked Issue

GH-631

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；固定删除 awk skill/alerting template、保留 manual sgconfig，spec approval 后执行

## 实现任务

- [ ] `SP631-T1` 删除 awk skill，保留现有 setup portability owner。Covers: B-001, B-004, B-005. Owner: implementation agent. Dependencies: spec approval + `ready_to_implement` + W-20 check. Done when: skill 不存在、无残留引用，setup POSIX awk 正/负例仍通过。Verify: skill format、manifest、setup focused 与 inventory tests。
- [ ] `SP631-T2` 删除不可信 alerting template。Covers: B-002, B-004, B-005. Owner: implementation agent. Dependencies: SP631-T1. Done when: 文件和 copy/install 引用不存在，不新增 Prometheus 安装行为。Verify: doc path、zero-reference 与 inventory tests。
- [ ] `SP631-T3` 文档化并验证 sgconfig manual purpose。Covers: B-003, B-005. Owner: implementation agent. Dependencies: SP631-T2. Done when: `CONTRIBUTING.md` 有明确 manual command，known rule/fixture 可由 config 发现，production guards 仍显式 `--rule`。Verify: ast-grep smoke 与 production command audit。
- [ ] `SP631-T4` 增加窄 inventory gate 并保护 architecture template。Covers: B-006, B-007. Owner: implementation agent. Dependencies: SP631-T3. Done when: tracked top-level scope 被枚举，unknown skill/template/root-config fixtures fail，known architecture consumer passes，CI/local contract 已接线。Verify: inventory/dependency-layer/CI wiring tests。
- [ ] `SP631-T5` 运行 distribution 提交门禁。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007. Owner: verification owner. Dependencies: SP631-T1..T4. Done when: skill/manifest/docs gates 同一提交通过。Verify: root validation table 的 skills、manifest、docs commands。

## 并行拆分

不并行：T1/T2/T3 的删除/保留结果共同定义 T4 inventory contract，coordinator 单 writer 串行
执行；独立 reviewer lane 只读。

## 验证

- Product invariant 集合：B-001..B-007；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH631`

## Handoff Notes

- `mode`: `plan_first`
- `artifacts`: `docs/specs/GH631/{product,tech,tasks}.md`、`docs/specs/GH631/{runtime-pinning.snapshot,tool-inventory.txt}`、`docs/specs/README.md`；implementation 计划删除两个已固定 orphan、文档化 manual sgconfig、增加 distribution inventory validator/fixtures 并接入 CI/local gate
- `runtime_pinning_snapshot`: `docs/specs/GH631/runtime-pinning.snapshot`；coordinator 的唯一 writable implementation lane 开始和每次续跑前必须执行 `VIBEGUARD_MODEL_ID=gpt-5 bash guards/universal/check_runtime_drift.sh check --snapshot docs/specs/GH631/runtime-pinning.snapshot --tool-inventory docs/specs/GH631/tool-inventory.txt --rules-dir rules/claude-rules`，使用 live runtime/PATH capture；reviewer lane 若因 PATH drift 只读报告，不得重写 snapshot
- `verification_owner`: coordinator `/root`；independent reviewer 由 threads lane 指派且只读
- `stop_conditions`: 无 spec approval/`ready_to_implement`、W-20 drift、需要保留或安装 awk/alerting 资产、需要写 `/etc/prometheus`、sgconfig smoke 无法发现 known rule、production guard 需要改为隐式 config、inventory 无法隔离 self/spec/test 假 consumer、architecture template 被误判、或需要扫描 runtime dead code 时停止
- `lane_map`: spec 与 implementation 由 coordinator `/root` 单 writer 串行 T1..T5；independent reviewer `/root/review_pr612` 只读且无 writable files；共享 inventory/CI wiring 文件不委派

三个 keep/remove 决策已由最新 main 证据固定，不再等待 implementation 临时选择。禁止操作
系统 Prometheus 目录，禁止误删 architecture template，禁止用 default install 伪造消费方。
