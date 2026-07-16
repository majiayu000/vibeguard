# Product Spec

## Linked Issue

GH-627

## 用户问题

Codex manifest 暴露 `vibeguard-*` namespaced hook 名，但 `run-hook-codex.sh` 没有
执行文档宣称的名称解析，而是依赖 8 个三行物理 alias shell。该补偿层扩大安装快照、
测试与运行时契约，并允许文档和真实解析逻辑继续分离。

## 目标

- 在单一 Codex wrapper 边界解析 namespaced 名称。
- 删除纯 alias hook 文件而不改变对外 manifest 名称。
- 对未知、畸形或路径型 hook 名保持 fail closed。

## 非目标

- 不重命名 manifest 对外的 `vibeguard-*` hook 名。
- 不改变 canonical Claude hook 文件或 hook decision/output JSON。
- 不重构 Codex adapter、policy 或 timeout 逻辑。

## Behavior Invariants

1. B-001 每个受支持的 `vibeguard-<canonical>.sh` 名称必须在
   `run-hook-codex.sh` 内解析到唯一 canonical `hooks/<canonical>.sh`；解析不依赖
   `hooks/vibeguard-*.sh` 物理文件。
2. B-002 namespaced 输入必须匹配闭集 manifest contract；未知名称、空 canonical
   名、额外前缀、目录分隔符或 traversal 片段必须 fail closed，不能执行任意文件。
3. B-003 repo-linked 与 installed-snapshot 两种运行模式必须应用同一解析规则，并在
   canonical 文件缺失时输出可见 install-incomplete 错误。
4. B-004 manifest 命令、hook event、timeout、policy gate 与最终 Codex output 必须与
   迁移前兼容；只有内部目标路径从 alias 变为 canonical。
5. B-005 删除 alias 文件后，安装模块、manifest/目录同步检查与 focused Codex tests
   必须证明没有残留物理依赖。
6. B-006 诊断证据必须保留外部 requested name，并在路径解析错误时包含稳定原因；
   不得因 canonical 化丢失可审计性。

## 验收标准

- [ ] 8 个 alias shell 删除，全部 namespaced hooks 仍可通过 wrapper 执行。
- [ ] 非法名称负例 fail closed 且没有路径穿越。
- [ ] dev-linked/installed snapshot、manifest 与 adapter regression tests 通过。
- [ ] `hooks/CLAUDE.md` 与实现一致。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-002 |
| 错误与失败路径 | covered: B-002, B-003 |
| 授权/权限 | covered: B-002；名称不能越过允许目录 |
| 并发/竞态 | N/A：每次 hook invocation 独立解析 |
| 重试/幂等 | covered: B-004 |
| 非法状态转换 | N/A：无持久状态机 |
| 兼容/迁移 | covered: B-003, B-004, B-005 |
| 降级/回退 | covered: B-003；缺文件不得 silent fallback |
| 证据与审计完整性 | covered: B-006 |
| 取消/中断 | N/A：单次短进程 |

## 发布说明

内部 hook 分发清理；Codex 用户配置中的 namespaced 命令不变。实现说明应提示旧安装
快照需要正常 setup/repair 刷新，但不要求用户手工改 `hooks.json`。
