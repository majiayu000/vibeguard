# rules/ 目录

VibeGuard 规则文件，定义各语言和领域的检查标准。

## 规则 ID 命名规范

| 前缀 | 领域 | 示例 |
|------|------|------|
| `U-XX` | 通用规则（所有语言适用） | U-11 硬编码路径 |
| `RS-XX` | Rust 特定规则 | RS-03 unwrap/expect |
| `TS-XX` | TypeScript 特定规则 | TS-01 any 滥用 |
| `PY-XX` | Python 特定规则 | PY-01 命名规范 |
| `SEC-XX` | 安全规则 | SEC-01 密钥泄露 |

## 文件结构

- `universal.md` — 跨语言通用规则
- `rust.md` — Rust 语言规则
- `typescript.md` — TypeScript 语言规则
- `python.md` — Python 语言规则
- `security.md` — 安全相关规则

## 每条规则包含

1. ID 和名称
2. 严重度（高/中/低）
3. 检查项描述
4. 修复模式（具体的代码修复方法）
5. FIX/SKIP 判断矩阵
