# Tech Spec

## Linked Issue

GH-631

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Candidate skill | `skills/awk-posix-compat/SKILL.md:2` | 存在 skill metadata，但 install modules 未列入 | 需要 keep/remove 决策 |
| Skill distribution | `schemas/install-modules.json:150` | `skills-core` 使用显式 paths | 无 wildcard 自动安装候选 skill |
| Alert template | `templates/alerting-rules.yaml:3` | 只在文件内说明手工 copy | 缺 discoverability/validation |
| Root ast-grep config | `sgconfig.yml:1` | 仅声明 `guards/ast-grep-rules` | production scripts 未显式使用 |
| Valid architecture template | `templates/vibeguard-architecture.yaml:1` | 提供 dependency layer 示例 | 已有真实 consumer，不得误删 |
| Architecture consumer | `guards/universal/check_dependency_layers.py:31` | 读取用户项目 `.vibeguard-architecture.yaml` | B-006 保护证据 |
| Public template guidance | `templates/AGENTS.md:78` | 给出 dependency-layer guard 命令 | architecture discoverability 已成立 |

## 设计方案

实施前先做三项小型 keep/remove ADR-style decision，写入 implementation PR body 或对应
文档，不另建泛化 framework。推荐当前证据下：

- Route A（推荐）：删除 `awk-posix-compat` 与 alerting template，除非维护者在 spec review
  指出真实用户入口；为 `sgconfig.yml` 补一条明确 manual scan 文档与 ruleDirs smoke check，
  因它符合 ast-grep 标准 root config 用途且不进入生产热路径。
- Route B：把候选正式加入可选安装模块。只有存在明确用户需求、目标路径和 focused tests
  时可选；不得 default-install 以制造使用证据。
- Route C：全部删除。最小表面，但会失去方便的 manual repository-wide ast-grep config。

新增 inventory gate 应保持窄范围：对 `skills/` 使用 install modules、repo-local declaration
或 explicit internal classification；对 templates 要求至少一个非自身引用/安装声明；对 root
tool configs 使用一个小 allowlist，记录 manual consumer 和验证命令。它不是通用 dead-code
检测器，不扫描 runtime files。

实现需阅读候选子树的 scoped instructions。删除时用现有 doc path、skill format 与 manifest
checks 证明无残留；保留 `vibeguard-architecture.yaml` 的 consumer fixture。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | skill decision + install/cleanup | install-module membership 或 absence+zero-reference assertions |
| B-002 | template decision | external doc/install reference + YAML check，或 absence+zero refs |
| B-003 | sgconfig decision | documented manual command + `ast-grep scan` dry/smoke，或 clean removal |
| B-004 | decision evidence | PR/spec review confirms real entrypoint；inventory rejects self-reference-only fixture |
| B-005 | cleanup validators | doc path、skill format、manifest tests |
| B-006 | architecture exclusion | dependency-layer focused test 与 template reference assertion |
| B-007 | narrow inventory gate | unknown skill/template/root-config fixtures fail |

## 数据流

静态 inventory 从 tracked paths、install modules 与 explicit classification 读取证据，输出
pass/fail；保留的 manual sgconfig 由开发者显式运行 ast-grep。无运行时持久化或安装副作用。

## 风险

- Security: alerting copy 指向系统目录；规格不授权 agent 执行系统安装。
- Compatibility: 未分发 skill/template 理论上可能有手工用户，删除前以 Git history/release 文档核实。
- Performance: inventory 只扫描小型声明集合。
- Maintenance: 避免构建无法解释例外的宽 allowlist。

## 测试计划

- [ ] Focused inventory positive/negative fixtures。
- [ ] `bash scripts/ci/validate-skill-format.sh`。
- [ ] `bash tests/test_manifest_contract.sh`。
- [ ] `bash scripts/ci/validate-doc-paths.sh` 与 command-path validator。
- [ ] dependency-layer focused test，证明 architecture template 未受损。

## 回滚方案

删除资产可由单独 commit 恢复；保留/注册路径可移除安装声明。回滚不得留下 manifest 指向
不存在文件，亦不得把候选提升为默认安装来规避 inventory failure。
