# Product Spec: 拆分超限的 runtime 安装编排

## Linked Issue

GH-621

## 用户问题

当前 `scripts/setup/install.sh` 在最新 `origin/main` 上为 871 行，超过 U-16 的
800 行硬上限。该文件在 #375 / #407 拆分后曾为 788 行，随后 runtime 供应链来源
验证、release manifest 与 stale-hook 修复使其重新增长。安全敏感的 runtime 下载、
完整性/来源验证、版本兼容和源码回退逻辑继续与参数解析、安装编排和用户目录写入混在
同一个入口，增加审查成本，也让后续 setup 修复没有安全余量。

## 目标

- 将 install-time runtime 获取与准备逻辑提取到单一内部 helper，使公共安装入口恢复到
  800 行以下。
- 保持 `setup.sh` 的命令、输出、退出码、下载、校验、来源验证、版本检查和源码回退行为
  不变。
- 让 setup、release 和 self-application 验证继续覆盖提取后的完整安装表面，而不是只扫描
  入口文件或依赖重复注释。
- 为后续 setup 变更恢复清晰的职责边界和行数余量。

## 非目标

- 不新增、删除或重命名任何 `setup.sh` CLI 参数。
- 不改变 checksum、release manifest、attestation、版本匹配、fail-closed 或 source-build
  fallback 语义。
- 不合并 `scripts/setup/lib.sh` 中面向 check/clean/bootstrap 的 quiet downloader；它有不同
  消费者和输出合同。
- 不重写 setup 测试框架，不弱化或删除现有断言。
- 不在本 Issue 中修改或拆分 854 行的 `tests/test_self_application_ci.sh`；该独立违规已由
  GH-623 排队，使用独立 Spec/Impl 周期处理。
- 不移动公共 setup 路径或修改安装状态/schema 合同。

## Behavior Invariants

1. B-001：`setup.sh` 的 public dispatch、所有现有参数、默认值、usage、模式输出与最终验证
   保持兼容。
2. B-002：runtime target/tag/hash、prebuilt 下载、checksum/release-manifest 校验、attestation、
   版本验证、source build、fallback 与 provenance-state 函数保持原名称、调用顺序和返回/
   退出语义。
3. B-003：严格来源模式在 verifier 不可用、attestation 失败、下载 runtime 版本不匹配或
   release target/tag 无法解析时继续 fail closed，且不偷偷切换为 source build。
4. B-004：非严格模式只在原先允许的下载不可用、平台不支持或版本不匹配路径执行原有
   source fallback；checksum、manifest 或 provenance 验证失败继续不可降级。
5. B-005：project config 验证、dry-run、snapshot staging、runtime provenance 持久化和正常
   安装继续使用准备好的同一个 runtime，且 persistent write 的先后关系不变。
6. B-006：`scripts/setup/install.sh` 小于 800 行；新的 install-time runtime helper 小于
   400 行，且不向已达 714 行的共享 `scripts/setup/lib.sh` 增加职责。
7. B-007：文本/自应用合同读取 entrypoint 与 helper 组成的完整安装表面，分别用
   entrypoint-only 与 helper-only mutation 证明仍能捕获 Python runtime fallback 和
   no-runtime degradation；不得通过复制安全字符串到注释来让检查通过。
8. B-008：新 helper 在被调用前确定性 source；helper 缺失或语法损坏时 setup 必须在任何
   persistent write、runtime 下载或 source build 前非零失败，不得静默跳过。

## 验收标准

- [ ] setup focused contract 先证明当前缺少 helper wiring/行数边界，再由实现使其通过。
- [ ] runtime 安装函数机械移动到一个 `<400` 行 helper，`install.sh` 降到 `<800` 行。
- [ ] 新 focused matrix 覆盖 attestation verification failure、strict unsupported target、
  strict unresolved tag、non-strict downloaded-version mismatch fallback，以及 helper 缺失/
  语法损坏的 fail-before-side-effect 行为。
- [ ] 既有 prebuilt、checksum/manifest mutation、strict provenance、version override、source
  build、project-config、dry-run 和完整安装回归全部通过。
- [ ] release-workflow 合同与 U-29 self-application 检查覆盖两个安装文件并保持 mutation
  捕获能力。
- [ ] setup 全量测试、release/self-application 测试、quick gate 与 shell syntax fresh 通过。
- [ ] 没有生成文件、高上下文用户文件、公共文档路径或 CLI 行为变化；#621 不修改
  `tests/test_self_application_ci.sh`。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-001, B-008 |
| 错误与失败路径 | covered: B-003, B-004, B-008 |
| 授权/权限 | covered: B-003；attestation/auth 可用性语义保持 |
| 并发/竞态 | N/A：单次 setup 同步执行，提取不引入共享并发状态 |
| 重试/幂等 | covered: B-001, B-005；现有重复安装语义不变 |
| 非法状态转换 | covered: B-003, B-004, B-005 |
| 兼容/迁移 | covered: B-001, B-002, B-005 |
| 降级/回退 | covered: B-003, B-004, B-007 |
| 证据与审计完整性 | covered: B-006, B-007 |
| 取消/中断 | covered: B-005；现有 temp cleanup/trap 顺序不变 |

## 发布说明

这是 setup 内部结构优化，不改变用户命令、安装结果或安全策略。用户无需迁移；维护者将获得
更小的入口文件和仍由既有测试覆盖的独立 runtime 安装职责。
