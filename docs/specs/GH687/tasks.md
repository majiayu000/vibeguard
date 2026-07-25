# Task Plan — GH687

## Linked Issue

GH-687

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [x] `SP687-T1` 新增 W-21 规范源文件 `rules/claude-rules/common/evidence-provenance.md`。Covers: B-001, B-002, B-003, B-004, B-005, B-007. Owner: implementation agent. Done when: 文件含 `## W-21: ... (strict)` 标题、`**Compact guidance:**` 行，以及会话外通道 / 单值信号 / harness 红旗 / 止损判据四个小节。Verify: `bash tests/test_evidence_provenance_rule.sh`。
- [x] `SP687-T2` 在 `rules/claude-rules/common/workflow.md` 的 W-01 中插入 step 0 通道可信性检查并交叉引用 W-21。Covers: B-006. Owner: implementation agent. Done when: 调试协议以 step 0 开头且既有四阶段文本未被删除。Verify: `bash tests/test_evidence_provenance_rule.sh`。
- [x] `SP687-T3` 重新生成派生规则文档。Covers: B-008. Owner: implementation agent. Done when: `scripts/generate_rule_docs.py --check` 无 diff。Verify: `python3 scripts/generate_rule_docs.py --check`; `bash scripts/ci/validate-generated-rule-docs.sh`。
- [x] `SP687-T4` 新增确定性测试 `tests/test_evidence_provenance_rule.sh` 并接入 CI。Covers: B-001..B-008. Owner: implementation agent. Done when: 测试断言全部 B-001..B-007 要素且在 `.github/workflows/ci.yml` 中被调用。Verify: `bash tests/test_evidence_provenance_rule.sh`。
- [x] `SP687-T5` 更新 CHANGELOG 与 spec 索引。Covers: none — documentation/release evidence. Owner: implementation agent. Done when: `docs/specs/README.md` 收录 GH687，CHANGELOG 记录 W-21。Verify: `python3 checks/check_workflow.py --repo . --all-specs`。

## 并行拆分

本实现不使用并行写 lane，所有写入由单个 implementation agent 串行完成（W-14）。
可并行的只读 review lane：规则文本审查、生成器一致性审查。

## 验证

```bash
python3 checks/check_workflow.py --repo . --spec-dir=docs/specs/GH687
python3 checks/check_workflow.py --repo . --all-specs
python3 scripts/generate_rule_docs.py --check
bash scripts/ci/validate-rules.sh
bash scripts/ci/validate-generated-rule-docs.sh
bash tests/test_evidence_provenance_rule.sh
bash tests/test_rule_overload_audit.sh
python3 tests/test_generate_rule_docs.py
bash scripts/verify/doc-freshness-check.sh --strict
```
