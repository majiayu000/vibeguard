# [项目名] — Claude Code Guidelines

## Project Overview

[项目简述]

| Component | Location | Tech Stack |
|-----------|----------|------------|
| Backend | `app/` | FastAPI + Python |

---

## Critical Rules

### 1. NO BACKWARD COMPATIBILITY

直接删除旧代码，不保留兼容层。

```python
# ❌ BAD
import warnings
warnings.warn("Deprecated", DeprecationWarning)

# ✅ GOOD - 直接删除
```

### 2. NO FUNCTION ALIASES

一个函数只能有一个名字，禁止别名。

```python
# ❌ BAD
format_percent = format_percentage

# ✅ GOOD
# 所有调用方统一使用 format_percentage
```

### 3. NO HARDCODING

内容必须来自数据或 AI，不硬编码。

```python
# ❌ BAD
status = "Active"

# ✅ GOOD
status = context.get("status")
```

### 4. NAMING CONVENTION

Python 内部 = snake_case，API 边界 = camelCase。

```python
from app.core.converters import snakeize_obj, camelize_obj

# 入口转换
data = snakeize_obj(raw_data)

# 出口转换
return camelize_obj(result)
```

### 5. SEARCH BEFORE CREATE

新建文件/类/函数前必须先搜索。

```bash
grep -rn "class <ClassName>" app/ --include="*.py"
grep -rn "def <function_name>" app/ --include="*.py"
```

---

## Architecture

```
app/
├── main.py
├── api/
│   └── v1/
│       ├── routes/          # API endpoints (thin)
│       └── schemas/         # API DTOs
├── core/                    # Shared kernel
│   ├── models/
│   ├── interfaces/
│   └── converters.py
├── contexts/                # DDD contexts
│   └── <context>/
│       ├── domain/
│       ├── application/
│       ├── workflows/
│       └── infra/
└── platform/                # Cross-context services
```

---

## Code Quality Guards

### 架构守卫（5 条核心规则）

| # | 规则 | 检测方式 |
|---|------|----------|
| 1 | 禁止静默吞异常 | except 块必须有 logging/re-raise |
| 2 | Facade 禁止 Any 类型 | 公开方法参数和返回值 |
| 3 | 禁止 Re-export Shim | schema 文件必须有实际定义 |
| 4 | 禁止跨模块私有访问 | 不访问 `_private` 属性 |
| 5 | 禁止重复 Protocol | 共享接口放 `core/interfaces/` |

运行守卫：
```bash
pytest tests/architecture/test_code_quality_guards.py -v
python scripts/check_naming_convention.py app/
python scripts/check_duplicates.py --strict
```

---

## Development

| Service | Port | Command |
|---------|------|---------|
| Backend | 5566 | `uvicorn app.main:app --reload --port 5566` |

---

## Key Principles

1. 数据驱动：没有数据就显示空白
2. 先搜后写：新建前必须搜索
3. 最小改动：只做被要求的事
4. 每个修复带测试
5. Spec-Driven：3+ 文件变更先写 spec
