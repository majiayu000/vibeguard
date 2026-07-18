# Tech Spec: install-time runtime helper 提取

## Linked Issue

GH-621

## Product Spec

[`product.md`](product.md)

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Setup entrypoint | `scripts/setup/install.sh:1-871` | 同时拥有参数解析、runtime acquisition/provenance/source fallback、snapshot 与安装编排 | 871 行超出 U-16，根因所在 |
| Shared setup library | `scripts/setup/lib.sh:1-714` | 被 install/check/clean 共用，拥有 runtime resolution 与 quiet bootstrap downloader | 已接近上限且消费者/输出合同不同，不适合承接 install-only 函数 |
| Setup focused contracts | `tests/test_setup.sh:308-323`, `tests/setup/syntax_manifest_tests.sh:1-6`, `tests/setup/install_flow_tests.sh:1-281` | 语法检查只覆盖 entrypoint；一个断言直接从 `install.sh` 定位 source-build 函数；runner/flow files 已分别为 793/799 行 | 提取后必须跟随 canonical owner，但不能让近上限文件继续承载新矩阵 |
| Release contract | `tests/test_release_workflow.sh:105-107`, `tests/test_release_workflow.sh:179-187` | 只把 `install.sh` 读入 `install_text`，据此检查来源验证与 manifest 失败文案 | 函数移动后要组合完整 install surface |
| U-29 self-application | `scripts/ci/self-application/check-u29-no-silent-degrade.sh:108-120`, `tests/test_self_application_ci.sh:538-558` | 只扫描 `install.sh` 的 Python/no-runtime fallback；aggregate harness 已 854 行 | checker 必须扫描 entrypoint 与 helper；新 mutation 放在 runtime focused test，不继续修改超限 harness |
| Historical decomposition | `plan/spec-test-file-size-decomposition.md`, GH-375, PR-407 | 旧计划要求 source/test 不超过 800，但实现只拆当时列出的 setup/runtime tests | 本次是后续功能增长造成的新回归，不重开旧 Issue |
| Follow-up ownership | GH-623 | 独立 Issue 已记录 854 行 self-application aggregate 的结构拆分 | #621 不得修改该文件或冒充已解决其超限问题 |

## 设计方案

1. 在 `scripts/setup/` 新增计划文件 `runtime-install.sh`，只定义 install-time runtime 函数，不在 source 时
   执行副作用。机械移动 `runtime_release_target`、`runtime_release_tag`、
   `runtime_sha256_file`、`download_prebuilt_runtime`、`runtime_version_mismatch_reason`、
   `verify_prepared_runtime_version`、`prepare_runtime_from_source`、
   `write_runtime_provenance_state` 与 `prepare_runtime_binary`；保留函数体、顺序、全局变量
   读写和错误文案。
2. `scripts/setup/install.sh` 在现有 shared setup/project/install-state 依赖之后、任何 runtime
   helper 调用之前 source 新文件。参数状态仍由 entrypoint 初始化；shell 函数在调用时读取
   这些全局值，所以 helper 顶层不得读取或改写它们。
3. `validate_project_config_for_install`、temp cleanup、snapshot staging 与其后的 install
   orchestration 留在 entrypoint。`stage_install_snapshot` 继续调用原名
   `prepare_runtime_binary` / `write_runtime_provenance_state`，避免调用图变化。
4. 在 `tests/setup/` 新增计划文件 `runtime_install_tests.sh`，由 793 行 aggregate runner 增加一条
   source 并保持其低于 800 行。该 focused file 承载 helper existence/source wiring、两文件
   `bash -n`、`<800` / `<400` 行合同和本次新增的全部 runtime-install mutations；不得向已
   799 行的 `install_flow_tests.sh` 添加测试。
5. focused file 创建隔离 repo/HOME/command-log fixtures，覆盖：(a) attestation verifier 可用且
   verification 失败时 strict 与 non-strict 都非零且无 source fallback；(b) strict 模式的
   Linux unsupported arch 使 target 无法解析；(c) 隔离 repo 缺少 runtime `VERSION` 使 tag
   无法解析；(d) non-strict downloaded runtime 自报版本不匹配后只按原合同 source fallback；
   (e) helper 缺失与注入 syntax error 时 setup 非零，且 command log 无 gh/curl/cargo 动作、
   隔离 HOME 无 `.vibeguard`/`.claude`/`.codex` persistent writes。每个失败 fixture 断言具名
   输出和无错误完成文案。
6. `tests/test_setup.sh` 的 `assert_prepare_runtime_from_source_no_cargo_metadata` 改读 canonical
   helper；正则仍只检查该函数体，不弱化禁止 `cargo metadata` 的原断言。
7. `tests/test_release_workflow.sh` 新增 helper 路径，将 entrypoint 与 helper 内容拼为
   `install_text` 后运行原有安全文案断言。CLI 参数和模式文案仍来自 entrypoint；runtime
   失败文案来自 helper，组合值代表完整 install surface。
8. `check-u29-no-silent-degrade.sh` 遍历存在的 entrypoint/helper 并扫描相同 forbidden
   phrases，错误包含真实相对路径。新 runtime focused test 以两次独立 fake-repo mutation
   分别只污染 entrypoint 或只污染 helper，两个检查都必须失败；不修改已由 GH-623 排队的
   `tests/test_self_application_ci.sh`。
9. 不修改 `scripts/setup/lib.sh` 中 `setup_runtime_*` / quiet bootstrap 行为，不尝试在本次
   消除其与 install downloader 的相似代码。二者的可见输出、失败分类和调用方不同，合并会
   超出机械提取范围。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | unchanged entrypoint parsing/orchestration | full setup flow + existing CLI assertions |
| B-002 | mechanical function move | diff review + prebuilt/source/version/provenance flow matrix |
| B-003 | runtime helper strict branches | verifier unavailable、attestation failure、unsupported target、unresolved tag、version mismatch tests |
| B-004 | runtime helper fallback branches | checksum/manifest failure、attestation failure、download/version source fallback tests |
| B-005 | unchanged snapshot/config/install callers | invalid/valid config, dry-run, install and provenance-state tests |
| B-006 | focused file-size contract | `wc -l` assertions and final line count |
| B-007 | release/U-29 complete-surface scan | release workflow test + two independent entrypoint/helper mutation fixtures |
| B-008 | entrypoint source + negative load tests | source-line assertion、`bash -n`、missing/broken helper fail-before-side-effect fixtures |

## 数据流与依赖顺序

`setup.sh` 仍进入 `scripts/setup/install.sh`。entrypoint 先 source shared setup/install-state/
project-config/target helpers 与新的 runtime-install helper，再解析参数并初始化全局状态。
`stage_install_snapshot` 调用 helper 中的 runtime preparation，helper 复用 `lib.sh` 的
manifest/provenance primitives 并写回现有 `RUNTIME_PROVENANCE_*` 全局值；entrypoint 随后
持久化 snapshot 和继续安装。没有新网络端点、持久化格式或用户路径。

## 备选方案

- 把函数追加到 `scripts/setup/lib.sh`：拒绝，该文件已有 714 行、消费者更广，追加会直接
  超限并扩大 check/clean 的加载职责。
- 只删除注释/压缩空行以降到 800：拒绝，不解决职责混合且几乎没有增长余量。
- 让静态测试继续只看 entrypoint，并复制 helper 安全文案到注释：拒绝，会制造虚假覆盖。
- 同时合并 quiet bootstrap 与 install downloader：拒绝，两者的输出、错误分类和调用者不同，
  需要独立行为设计与更大风险面。
- 同时拆 `tests/test_self_application_ci.sh`：拒绝，违反一 Issue 一优化的范围约束。

## 风险

- Load-order：helper 依赖由 entrypoint 后续初始化的 globals；以无副作用定义文件和 wiring
  contract 防止 source-time 读取。
- Security：机械移动不得改变 checksum/manifest/provenance fail-closed 分支；完整 flow 与
  mutation tests 必须 fresh 通过。
- Static-evidence drift：原测试按单文件扫描；改为显式组合/遍历两个 canonical 文件并新增
  两次独立 mutation，避免安全检查变成假绿。
- Test-size pressure：aggregate/setup flow/self-application 分别为 793/799/854 行；新增矩阵
  只进入新的 focused file，aggregate 仅增加一条 source，self-application 由 GH-623 独立拆分。
- Portability：保持 Bash 语法和现有 macOS/Linux 工具探测；对两个文件运行 `bash -n`。
- Reviewability：实现 diff 限定为一个新 helper、入口 source/删除块和验证路径更新；任何函数
  体非机械变化触发 stop condition。

## 测试计划

- [ ] Focused runtime install：通过 aggregate 执行新的 runtime-install focused matrix，覆盖
  syntax/size、attestation/target/tag/version 和 missing/broken helper mutations。
- [ ] Full setup：`bash tests/test_setup.sh`。
- [ ] Supply chain：`bash tests/test_release_workflow.sh`。
- [ ] Self application：`bash tests/test_self_application_ci.sh`。
- [ ] Setup contracts：`bash scripts/ci/validate-hooks.sh`；
  `bash scripts/ci/validate-hooks-manifest.sh`。
- [ ] Broad gate：`bash scripts/local-contract-check.sh --quick`；`git diff --check`。
- [ ] Structural review：`wc -l scripts/setup/install.sh scripts/setup/runtime-install.sh`；确认移动
  函数体与 `origin/main` 原块一致，除 source wiring/test ownership 外无行为 diff。

## 回滚方案

将 helper 中的函数按原顺序放回 `scripts/setup/install.sh`，移除 source wiring，并恢复测试的
单文件路径即可回滚。没有 schema、安装状态或数据迁移。
