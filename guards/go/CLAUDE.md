# guards/go/ 目录

Go 语言守卫脚本，对 Go 项目做静态模式检测。

## 脚本清单

| 脚本 | 规则 ID | 检测内容 |
|------|---------|----------|
| `check_error_handling.sh` | GO-01 | 未检查的 error 返回值（赋值给 _） |
| `check_goroutine_leak.sh` | GO-02 | goroutine 泄漏风险（无退出机制的 go func） |
| `check_defer_in_loop.sh` | GO-08 | 循环内 defer（资源泄漏） |

## common.sh 用法

所有脚本通过 `source common.sh` 引入共享函数：
- `list_go_files <dir>` — 列出 .go 文件（优先 git ls-files，排除 vendor/）
- `parse_guard_args "$@"` — 解析 --strict 和 target_dir
- `create_tmpfile` — 创建自动清理的临时文件

## 输出格式

```
[GO-XX] file:line 问题描述。修复：具体修复方法
```
