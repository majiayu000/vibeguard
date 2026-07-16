# Tech Spec: manifest 驱动的 compliance 语言范围

## Linked Issue

GH-618

## Product Spec

[`product.md`](product.md)

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Compliance entrypoint | `scripts/verify/compliance_check.sh:11-20`, `scripts/verify/compliance_check.sh:29-78` | 接受 project/root，维护 PASS/FAIL/WARN；前四层无条件检查 Python duplicate、naming、ruff 和 architecture guard | 根因与用户可见输出所在 |
| Project config validation | `scripts/lib/project_config_validate.py:114-150`, `scripts/lib/project_config_validate.py:153-176` | 已按 project schema 验证 `languages`，但成功路径只打印配置文件名 | 可复用验证并增加机器可读语言输出，避免另写 JSON/schema 解析 |
| Manifest language filtering | `scripts/lib/vibeguard_manifest.py:111-139`, `scripts/lib/vibeguard_manifest.py:608-643` | 已规范化语言并验证 module 的 `languages`，CLI 目前只对 rule links/labels 暴露语言过滤 | 可在同一事实源上增加 guard-module 查询，不复制映射表 |
| Canonical contracts | `schemas/vibeguard-project.schema.json:19-25`, `schemas/install-modules.json:210-266` | schema 声明五种语言；manifest 声明 universal 与四个 language guard modules，其中 JS/TS 共享 module | 语言合法性与 pack 映射的唯一来源 |
| Focused regression | `tests/unit/test_compliance_check.sh:58-87`, `tests/unit/test_compliance_check.sh:91-143` | 隔离 HOME/project/cwd，覆盖默认与显式 root，但 fixture 未声明语言且只断言 Python guard | 扩展为语言矩阵与失败路径的最小回归面 |
| Workflow consumer | `workflows/auto-optimize/SKILL.md:203-210` | Phase 5 直接调用 compliance checker | 入口和退出合同必须保持可执行 |
| Python-free boundary | `docs/specs/rust-only-production-path.md:22-35`, `docs/specs/rust-only-production-path.md:98-103` | Python-free 约束只覆盖生产 install/hook；developer validators 可使用 Python | 本改动复用 Python validator 不扩大生产依赖 |

## 设计方案

1. 在 `project_config_validate.py` 的现有成功路径增加显式、互斥的机器可读输出选项，用于按声明顺序输出经 schema 验证的语言。默认 CLI 输出保持不变；缺少 `languages` 与空数组都输出空结果，非法配置仍打印现有错误并返回非零。
2. 在 `vibeguard_manifest.py` 增加公开的 guard-module 查询与 CLI 子命令。查询仅选择 `kind=guards`、语言集合非空且与请求语言相交的 module，要求 module 至少有一个非空、有效的仓库相对 source path，并按 manifest 顺序输出 module id 与 source path；一个 module 即使匹配多个语言也只输出一次。查询还必须核对每个请求语言至少命中一个 language-specific guard module，JS/TS 可以命中同一个共享 module；任一请求语言零命中或 paths 无效时非零失败。现有 `_module_languages`/normalization 负责语言验证，JS/TS 共享关系直接来自 manifest。
3. `compliance_check.sh` 分离两个根：脚本分发根用于定位 schema/helper/manifest，现有 `VIBEGUARD_DIR` 继续作为 guard 文件可用性查找根。这样显式覆盖不改变合同来源，也保留 GH608 的 guard root 语义。
4. checker 在目标项目根查找 `.vibeguard.json`。缺失、缺少 `languages` 或空数组时记录一个具名 WARN，跳过全部语言专属检查。配置验证失败时记录具名 FAIL、保持语言集合为空并继续通用检查，最终由现有 summary 返回 1；不得采用默认语言。
5. 对有效非空语言调用 manifest guard-module 查询。每个返回 module 的所有 source path 在 `VIBEGUARD_DIR` 下可访问时记录 PASS，否则记录 WARN；manifest/helper 查询失败记录 FAIL。shell 捕获并检查每个子命令状态，禁止 `|| true` 吞错。
6. 仅当 Python 在声明集合中时执行现有 duplicate、naming、ruff 与 architecture guard 分支。pre-commit 文件和 gitleaks、skill/workflow、prompt rules 与 rule YAML syntax 仍是通用检查。现有 summary 只计 PASS/WARN/FAIL，不引入隐藏的 SKIP 计数。
7. 扩展现有 focused harness，不新增第二个 compliance 测试入口。fixtures 显式写 `.vibeguard.json`；通过临时 manifest 副本验证 JS/TS 去重、mixed matrix、无声明、非法 JSON/语言、损坏 manifest、删除某个声明语言 guard 映射的 schema/manifest 矛盾与显式 guard root。
8. 控制 `vibeguard_manifest.py` 在 800 行硬上限以内；若最小查询无法在该上限内实现，停止并重新拆分 helper，而不是提交超限文件。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | checker language gate + manifest query | focused Rust fixture 断言 `guards-rust` 且排除四类 Python 文案 |
| B-002 | checker Python branch | focused Python/default-root/override-root fixtures 断言现有 duplicate、naming、ruff、architecture 结果 |
| B-003 | manifest guard-module query | focused Go、JavaScript fixtures与 helper 查询断言对应 manifest module |
| B-004 | manifest module 去重 | focused TypeScript+JavaScript 与 mixed fixture 断言共享 module 仅一次 |
| B-005 | validator + manifest helper | `python3 scripts/lib/vibeguard_manifest.py validate` 与 focused fixture mutation |
| B-006 | checker undeclared branch | 缺文件、缺字段、空数组三个 fixture 断言具名 WARN、零语言 pack/Python 结果 |
| B-007 | validator failure bridge | 非法 JSON、错误类型、不支持语言 fixture 断言 FAIL、status 1、无 fallback |
| B-008 | manifest query completeness + checker failure bridge | 损坏/缺失 manifest 与删除 Rust guard 映射的矛盾 fixture 均断言具名 FAIL、status 1、无 Python fallback |
| B-009 | unchanged global layers/summary/root/consumer | 现有 focused assertions、unit runner、workflow contracts、quick gate |

## 数据流

输入为 checker 的 `project_dir`、脚本分发根、可选 `VIBEGUARD_DIR` 与目标项目
`.vibeguard.json`。project validator 读取 schema 并输出已验证语言；manifest helper 读取
install-modules manifest 并输出去重后的 `module_id + source_path` 行；shell 在 guard 根验证这些
source path 并累加现有 PASS/WARN/FAIL。无文件写入、无网络调用、无持久化状态。

## 备选方案

- 用 shell、`jq` 或文件扩展名直接解析/探测语言：拒绝，会引入依赖或第二套语言语义，并违反“不猜测”。
- 复用 `setup.sh verify-dev-repo`：拒绝，它检查安装/runtime/scheduler 状态，不等价于项目 compliance。
- 把查询迁入 Rust runtime：拒绝，本入口是 developer validator；强制已有 runtime 会扩大执行前置条件，而现有 Python helper 已拥有 schema/manifest 合同。
- 新增独立 Python resolver：拒绝，现有两个 helper 已分别拥有 config 与 manifest 语义，新增文件会复制边界逻辑。

## 风险

- Security：只读取显式路径；manifest source path 必须保持仓库相对路径合同，shell 引用所有路径，不执行 manifest 内容。
- Compatibility：未声明语言的项目不再得到 Python 专属结果，但命令、通用检查、summary 与退出语义保留；这是有意的精度修复。
- Performance：增加两个短生命周期 Python 查询，仅发生在开发 compliance 命令；相对完整检查成本可忽略。
- Maintenance：扩展现有 helper 可能接近 U-16 行数上限，因此验证文件行数并禁止超过 800。

## 测试计划

- [ ] Unit tests：`bash tests/unit/test_compliance_check.sh`; `bash tests/unit/run_all.sh`。
- [ ] Contract tests：`python3 scripts/lib/vibeguard_manifest.py validate`; `bash tests/test_manifest_contract.sh`; `bash tests/test_workflow_contracts.sh`。
- [ ] Static checks：`bash -n scripts/verify/compliance_check.sh tests/unit/test_compliance_check.sh`; `python3 -m py_compile scripts/lib/project_config_validate.py scripts/lib/vibeguard_manifest.py`; `wc -l scripts/lib/vibeguard_manifest.py`。
- [ ] Cross-surface regression：`bash scripts/ci/validate-doc-paths.sh`; `bash scripts/ci/validate-doc-command-paths.sh`; `bash scripts/local-contract-check.sh --quick`; `git diff --check`。
- [ ] Manual verification：从仓库外 cwd 对临时 Rust-only 项目执行 checker，确认显示 Rust pack、无 Python 专属文案，非法 config 返回 1。

## 回滚方案

回滚 checker 的语言 gate、两个 helper 的新 CLI 选项/查询和 focused assertions，即可恢复原先无条件
Python 检查；不涉及 schema、manifest 内容、安装状态或数据迁移。
