# Python Rules（Python 特定规则）

Python 项目扫描和修复的特定规则。

## 扫描检查项

| ID | 类别 | 检查项 | 严重度 | 守卫交叉引用 |
|----|------|--------|--------|-------------|
| PY-01 | Bug | 可变默认参数（def f(x=[])） | 高 | — |
| PY-02 | Bug | except 裸捕获（except: 或 except Exception） | 中 | `guards/python/test_code_quality_guards.py` 规则 1 自动检测 |
| PY-03 | Bug | 循环内 await 无 gather/TaskGroup | 中 | — |
| PY-04 | Design | 上帝类（> 500 行，> 10 个公开方法） | 中 | — |
| PY-05 | Dedup | 多处相同的 try/except 模式 | 中 | — |
| PY-06 | Perf | 循环内重复创建正则（应预编译） | 低 | — |
| PY-07 | Perf | 字符串拼接在循环中（应用 join 或 list） | 低 | — |

> **PY-02 与守卫集成说明**：VibeGuard 的 `guards/python/test_code_quality_guards.py` 中"禁止静默吞异常"规则通过 AST 检测 except 块是否有 logging 或 re-raise。auto-optimize 扫描时应先运行该守卫获取基线，LLM 深度扫描补充守卫无法覆盖的场景（如 except 块有 logging 但异常类型过宽）。

## SKIP 规则（Python 特定）

| 条件 | 判定 | 理由 |
|------|------|------|
| 类型注解不完整但功能正确 | SKIP | 类型注解是渐进式的 |
| 用 dict 而非 dataclass | SKIP | 除非 dict 结构在 > 3 处重复 |
| 缺少 docstring | SKIP | 独立处理，不混入功能修复 |

## ECC 增强规则

| ID | 类别 | 检查项 | 严重度 |
|----|------|--------|--------|
| PY-08 | Safety | 使用 `eval()` / `exec()` / `__import__()` | 高 |
| PY-09 | Design | 函数超过 50 行（应拆分） | 中 |
| PY-10 | Design | 嵌套超过 4 层（应提前返回或提取函数） | 中 |
| PY-11 | Safety | 文件操作未使用 `with` 上下文管理器 | 中 |
| PY-12 | Perf | 循环内重复调用 `len()` / `keys()` / `values()` | 低 |

## 验证命令
```bash
ruff check . && ruff format --check . && pytest
```
