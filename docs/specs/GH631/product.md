# Product Spec

## Linked Issue

GH-631

## 用户问题

仓库中存在无法从当前分发/使用契约判断生命周期的资产：`awk-posix-compat` skill 没有
安装模块或调用入口；alerting template 没有仓库内消费方；根 `sgconfig.yml` 只可能被人工
裸跑 ast-grep 隐式读取，但没有产品文档说明。维护者无法区分“未接线功能”和“应删除遗留”。

## 目标

- 为每个候选资产作出保留并接线，或删除并清理引用的明确决定。
- 保留项必须有发现入口、使用路径、owner 和验证。
- 建立轻量 inventory gate，防止新的未接线 distribution surface 静默进入主线。

## 非目标

- 不删除已被 `check_dependency_layers.py` 消费的 architecture template。
- 不为保留文件而虚构新的默认安装行为。
- 不改变 production ast-grep guards 的显式 `--rule` 调用模式。
- 不批量审计所有已证明有消费者的 skills/templates。

## Behavior Invariants

1. B-001 删除 `awk-posix-compat` skill 且不得留下安装、调用或产品文档引用；POSIX awk 防回归
   继续由现有 `scripts/setup/check.sh` 与 `tests/test_setup_check.sh` 负责，不新增虚构安装入口。
2. B-002 删除 alerting-rules template 且不得留下复制/安装引用；虽然 exporter 提供模板引用的
   metric names，但模板无外部发现入口，且 `NoRecentEvents` 把事件计数当时间戳，因此不得把
   整体包装成已验证、可用的告警模板保留。
3. B-003 保留根 `sgconfig.yml`，在贡献者文档明确声明“人工 repository-wide ast-grep scan”
   用途和命令，并由可执行检查验证 `ruleDirs` 能发现已知规则；production guards 继续显式
   `--rule`，不得切换到隐式全量配置。
4. B-004 保留决策必须基于用户/维护者可执行路径，而不是为了避免删除而新增无调用方模块。
5. B-005 删除决策必须同步清理 docs、manifest、tests 与生成/安装引用；搜索残留或 broken
   path 必须使验证失败。
6. B-006 architecture template 与 dependency-layer guard 的现有契约必须保持，inventory
   cleanup 不得把它误判为 orphan。
7. B-007 CI 必须枚举 tracked `skills/*/SKILL.md`、`templates/*` 和仓库根
   `*.yml`/`*.yaml`/`*.json`/`*.toml`：每项必须由 install module、`skills-lock.json`、
   非 spec/plan/test 的真实 consumer，或 `CONTRIBUTING.md` 中包含精确仓库相对路径的 manual
   声明证明。实现必须为当前依赖工具约定或人工发现的合法资产补齐精确文档入口；仅自身注释、
   文件名片段、目录/通配符、spec、plan、测试或 validator allowlist 不能算生命周期证据，
   未知项必须非零失败。

## 验收标准

- [ ] awk skill 与 alerting template 删除且无残留引用。
- [ ] `sgconfig.yml` 可从贡献者文档发现，known-rule smoke 通过，production `--rule` 不变。
- [ ] inventory gate 拒绝仅 self/spec/test 引用的未知 skill、template 与 root config fixtures。
- [ ] architecture template/guard contract 不受影响。
- [ ] inventory negative fixture 阻断新的未知资产。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-005, B-007 |
| 错误与失败路径 | covered: B-005, B-007 |
| 授权/权限 | N/A：不执行系统级 Prometheus 安装 |
| 并发/竞态 | N/A：静态 inventory check |
| 重试/幂等 | covered: B-005 |
| 非法状态转换 | covered: B-004（伪接线不算 active） |
| 兼容/迁移 | covered: B-003, B-005, B-006 |
| 降级/回退 | covered: B-007；unknown classification 不假成功 |
| 证据与审计完整性 | covered: B-002, B-004, B-007 |
| 取消/中断 | N/A：文件级变更可重跑验证 |

## 发布说明

删除未分发的 awk skill 与不可信 alerting template；保留的 `sgconfig.yml` 只作为贡献者手工
全仓 ast-grep 扫描入口，不是默认安装或 production guard 调用方式。
