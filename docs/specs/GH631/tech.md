# Tech Spec

## Linked Issue

GH-631

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Candidate skill | awk-posix-compat skill | 存在 skill metadata，但 install modules 未列入 | setup 已有相同 portability owner |
| Skill distribution | `schemas/install-modules.json:150` | `skills-core` 使用显式 paths | 无 wildcard 自动安装候选 skill |
| Alert template | alerting-rules.yaml template | 只在文件内说明手工 copy；exporter 提供所引用的 metric names，但 `NoRecentEvents` 用 `vibeguard_events_total` count 计算 elapsed time | 不能把整体作为已验证的可信样例保留 |
| Root ast-grep config | `sgconfig.yml:1` | 仅声明 `guards/ast-grep-rules` | production scripts 未显式使用 |
| Valid architecture template | `templates/vibeguard-architecture.yaml:1` | 提供 dependency layer 示例 | 已有真实 consumer，不得误删 |
| Architecture consumer | `guards/universal/check_dependency_layers.py:31` | 读取用户项目 `.vibeguard-architecture.yaml` | B-006 保护证据 |
| Public template guidance | `templates/AGENTS.md:78` | 给出 dependency-layer guard 命令 | architecture discoverability 已成立 |

## 设计方案

最终决策固定如下，不再留给 implementation 临时选择：

- 删除 awk-posix-compat skill。它既不在 install modules/`skills-lock.json`，也没有调用者；
  最新 main 已由 `scripts/setup/check.sh:717-740` 与 `tests/test_setup_check.sh:335-350`
  提供 POSIX awk 检查和负例，保留 skill 只会形成重复、未分发的知识资产。
- 删除 alerting-rules.yaml template。仓库有真实 Prometheus exporter，但该模板无外部发现入口，
  且表达式不符合 exporter 当前 metric contract；本 issue 不扩展外部告警产品面，也不执行
  `/etc/prometheus` 写入。以后若重建告警样例，必须由新的 issue/spec 基于真实 series 设计。
- 保留 `sgconfig.yml` 作为 maintainer-only 手工入口。在 `CONTRIBUTING.md` 写明
  `ast-grep scan --config sgconfig.yml`，focused smoke 用该 config 发现
  `rs-14-config-default` 并扫描 fixture；production guard 的显式 `--rule` 命令由静态断言保护。

在现有 `scripts/ci/` 下新增 distribution asset Python validator 和 focused shell regression。validator 只枚举
tracked 顶层 `skills/*/SKILL.md`、`templates/*` 以及根目录 `*.yml`/`*.yaml`/`*.json`/`*.toml`。
生命周期证据限于 `schemas/install-modules.json`、`skills-lock.json`、候选文件之外的非
`docs/specs/`、非 `plan/`、非 `tests/` tracked consumer，或 `CONTRIBUTING.md` 中包含候选
精确仓库相对路径的 manual 说明。实现必须在 `CONTRIBUTING.md` 补齐当前仅由工具文件名约定
或人工复制使用的合法资产（包括 `rust-toolchain.toml`、language/project-rule templates 与
`templates/vibeguard-config.README.md`）的精确发现入口。validator 必须匹配完整路径 token；
validator 自身、候选自述、文件名片段、目录/通配符、spec/plan/test 或代码 allowlist 都不能
自证。实现接入 CI 与 local contract gate，并用隔离 git fixture 证明未知
skill/template/root-config 均非零、architecture template 通过。它不是通用 dead-code 检测器，
不扫描 runtime files。

实现需阅读候选子树的 scoped instructions。删除时用 inventory、doc path、skill format 与
manifest checks 证明无残留；保留 `vibeguard-architecture.yaml` 的 consumer fixture。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | 删除 awk skill；复用 setup portability gate | absence+zero-reference assertions；setup focused regression |
| B-002 | 删除 alerting template | absence+zero-reference assertions；metric contract 不扩展 |
| B-003 | `CONTRIBUTING.md` manual entry + sgconfig smoke | known-rule fixture；production `--rule` audit |
| B-004 | 固定 spec decision evidence | inventory rejects self-reference-only fixture |
| B-005 | cleanup validators | doc path、skill format、manifest tests |
| B-006 | architecture exclusion | dependency-layer focused test 与 template reference assertion |
| B-007 | narrow inventory gate + exact-path contributor discovery for convention/manual assets | retained inventory passes；unknown skill/template/root-config fixtures fail |

## 数据流

静态 inventory 从 tracked paths、install modules、skills lock 与外部 consumer/manual docs
读取证据，输出 pass/fail；保留的 manual sgconfig 由开发者显式运行 ast-grep。无运行时
持久化或安装副作用。

## 风险

- Security: alerting copy 指向系统目录；规格不授权 agent 执行系统安装。
- Compatibility: Git history/release/docs 搜索只证明 awk skill 来自 learn 产物、alert template
  没有公开入口；删除不改变已声明安装模块。sgconfig 仅新增文档，不改变 production guard。
- Performance: inventory 只扫描小型声明集合。
- Maintenance: 当前 convention/manual assets 通过精确贡献者文档入口说明，不构建无法解释的
  宽 allowlist；新增同目录文件不会自动继承证据。

## 测试计划

- [ ] Focused inventory positive/negative fixtures（完整 retained inventory；unknown
  skill/template/root config；basename/glob/self/spec/test/validator allowlist 均不能自证）。
- [ ] sgconfig known-rule smoke 与 production `--rule` audit。
- [ ] `bash tests/test_setup_check.sh` 保持 awk portability coverage。
- [ ] `bash scripts/ci/validate-skill-format.sh`。
- [ ] `bash tests/test_manifest_contract.sh`。
- [ ] `bash scripts/ci/validate-doc-paths.sh` 与 command-path validator。
- [ ] dependency-layer focused test，证明 architecture template 未受损。

## 回滚方案

删除资产可由单独 commit 恢复，但恢复前必须补真实 consumer 与验证；sgconfig 文档/验证可
整体回滚。回滚不得留下 manifest 指向不存在文件，亦不得把候选提升为默认安装来规避
inventory failure。
