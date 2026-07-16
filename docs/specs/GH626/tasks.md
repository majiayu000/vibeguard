# Task Plan

## Linked Issue

GH-626

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；执行前必须由维护者批准规格并把 issue 置为 `ready_to_implement`

## 实现任务

- [ ] `SP626-T1` 增加 canonical `Compact guidance` parser、16-row migration fixture 与有序 selection。Covers: B-001, B-002, B-003, B-007. Owner: implementation agent. Dependencies: spec approval. Done when: 16 个 selected records 各有唯一非空 guidance，renderer 不用 `Rule.summary`/旧表 fallback，selection/selected canonical/guidance 的缺失或重复均 fail-visible，迁移前后 16 行逐行一致。Verify: `python3 tests/test_generate_rule_docs.py`。
- [ ] `SP626-T2` 增加唯一 inner markers 与区块限定 replacer。Covers: B-005, B-008. Owner: implementation agent. Dependencies: SP626-T1. Done when: missing/duplicate/misordered markers 非零失败，成功 write 的 marker 外 prefix/suffix 字节不变，连续两次生成无 diff。Verify: `python3 tests/test_generate_rule_docs.py`; 连续运行两次 `python3 scripts/generate_rule_docs.py` 后 `git diff --exit-code`。
- [ ] `SP626-T3` 把 compact output 接入 stale check，更新维护说明并验证 setup/U-32。Covers: B-004, B-006. Owner: implementation agent. Dependencies: SP626-T1, SP626-T2. Done when: canonical guidance/severity/selection 变化会让 `--check` 非零，维护者入口指向 canonical field，默认注入集合与预算不扩大。Verify: `bash scripts/ci/validate-generated-rule-docs.sh`; `bash tests/test_setup.sh`; `bash tests/hooks/test_count_active_constraints.sh`。
- [ ] `SP626-T4` 运行规则文档提交门禁并记录 fresh output。Covers: B-001..B-008. Owner: verification owner. Dependencies: SP626-T1..T3. Done when: 所有必跑命令在同一提交通过，且人工 diff 确认 inner markers 外无生成改动。Verify: `python3 tests/test_generate_rule_docs.py`; `bash scripts/ci/validate-rules.sh`; `bash scripts/ci/validate-generated-rule-docs.sh`; `bash scripts/verify/doc-freshness-check.sh --strict`; `git diff --check`。

## 并行拆分

本项不并行：generator、compact 产物与 tests 属于同一可写契约，单 owner 可避免
生成文件竞态。

## 验证

- Product invariant 集合：B-001..B-008；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH626`
- `git diff --check`

## Handoff Notes

当前仅为 draft task plan。未获得 spec approval 或 `ready_to_implement` 标签时停止；
不得开始 generator/高上下文文件修改，不得使用 `Rule.summary` 或旧表 fallback，不得扩大
inner-marker 写入边界，不得降低 16-row migration、U-32、setup 或 freshness 测试。
