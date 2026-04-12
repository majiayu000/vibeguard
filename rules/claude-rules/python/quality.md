---
paths: **/*.py,**/pyproject.toml,**/setup.py
---

# Python 质量规则

## PY-01: 可变默认参数（高）
`def f(x=[])` 导致跨调用共享状态。修复：`def f(x=None): if x is None: x = []`

## PY-02: except 裸捕获（中）
`except:` 或 `except Exception` 无 logging/re-raise。修复：捕获具体异常类型，配合 logging 或 re-raise。

## PY-03: 循环内 await 无 gather/TaskGroup（中）
串行等待浪费时间。修复：改为 `asyncio.gather()` 或 `asyncio.TaskGroup` 并发执行。

## PY-04: 上帝类 > 500 行（中）
超过 10 个公开方法。修复：拆分为多个职责单一的类，提取 mixin 或独立服务。

## PY-05: 多处相同的 try/except 模式（中）
修复：提取公共 error handler 函数或装饰器。

## PY-06: 循环内重复创建正则（低）
修复：在模块级或类初始化时用 `re.compile()` 预编译，循环内复用。

## PY-07: 字符串拼接在循环中（低）
修复：改用 list 收集后 `''.join(parts)`。

## PY-08: 使用 eval() / exec() / __import__()（高）
动态执行不可信代码。修复：替换为安全替代方案。必须使用时严格限制输入来源和执行环境。

## PY-09: 函数超过 50 行（中）
修复：提取子函数，单函数不超过 50 行。

## PY-10: 嵌套超过 4 层（中）
修复：用 guard return 提前退出，或提取内层为独立函数。

## PY-11: 文件操作未使用 with 上下文管理器（中）
修复：所有文件 open 改用 `with open(...) as f:`。

## PY-12: 循环内重复调用 len()/keys()/values()（低）
修复：循环前将结果缓存到变量，循环内复用。

## PY-13: 死兼容垫片（中）
仅从另一模块 re-export 符号、不添加行为的文件，迁移完成后应删除。
修复：将陈旧垫片的 import 替换为规范模块路径，无调用方残留后删除垫片文件。
