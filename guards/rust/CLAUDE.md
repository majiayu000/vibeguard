# guards/rust/ 目录

Rust 语言守卫脚本，对 Rust 项目做静态模式检测。

## 脚本清单

| 脚本 | 规则 ID | 检测内容 |
|------|---------|----------|
| `check_unwrap_in_prod.sh` | RS-03 | 非测试代码中的 unwrap()/expect() |
| `check_duplicate_types.sh` | RS-05 | 跨 crate 重复定义的类型 |
| `check_nested_locks.sh` | RS-01 | 嵌套锁（潜在死锁） |
| `check_workspace_consistency.sh` | RS-06 | 跨入口路径一致性 |
| `check_single_source_of_truth.sh` | RS-12 | 任务系统双轨并存/多状态源分裂 |
| `check_semantic_effect.sh` | RS-13 | 动作语义与副作用不一致 |

## common.sh 用法

所有脚本通过 `source common.sh` 引入共享函数：
- `list_rs_files <dir>` — 列出 .rs 文件（优先 git ls-files）
- `parse_guard_args "$@"` — 解析 --strict 和 target_dir
- `create_tmpfile` — 创建自动清理的临时文件

## 输出格式

```
[RS-XX] file:line 问题描述。修复：具体修复方法
```
