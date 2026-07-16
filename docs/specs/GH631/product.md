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

1. B-001 `skills/awk-posix-compat/` 必须二选一：进入至少一个声明安装/发现 surface 并有
   format/behavior validation，或从仓库删除且没有残留引用。
2. B-002 alerting template 必须二选一：有真实文档入口、安装/复制流程和结构验证，或删除；
   文件内自述 copy 命令不能单独算作 discoverability evidence。
3. B-003 根 `sgconfig.yml` 必须明确声明“人工 repository-wide ast-grep scan”用途并由
   可执行检查验证 `ruleDirs`，或删除；production guards 不得被悄悄切换到隐式全量配置。
4. B-004 保留决策必须基于用户/维护者可执行路径，而不是为了避免删除而新增无调用方模块。
5. B-005 删除决策必须同步清理 docs、manifest、tests 与生成/安装引用；搜索残留或 broken
   path 必须使验证失败。
6. B-006 architecture template 与 dependency-layer guard 的现有契约必须保持，inventory
   cleanup 不得把它误判为 orphan。
7. B-007 新增顶层 skill/template/config 候选时，CI 必须能证明其 install、runtime、manual
   或 explicitly-internal 分类之一；未知分类不得 silent pass。

## 验收标准

- [ ] 三个候选各有明确 keep/remove 结果和证据。
- [ ] 保留项可从仓库文档/安装入口发现且验证通过。
- [ ] 删除项无残留路径或 manifest 引用。
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

若删除未分发资产，记录为维护清理；若保留并接线，发布说明必须写明它是默认安装、可选
安装还是仅人工维护者工具，不能模糊成已自动启用。
