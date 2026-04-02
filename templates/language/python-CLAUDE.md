# [Project Name] — Claude Code Guidelines

## Project Overview

[Project Brief]

| Component | Location | Tech Stack |
|-----------|----------|------------|
| Backend | `app/` | FastAPI + Python |

---

## Critical Rules

### 1. NO BACKWARD COMPATIBILITY

Delete the old code directly without retaining the compatibility layer.

```python
# ❌ BAD
import warnings
warnings.warn("Deprecated", DeprecationWarning)

#✅ GOOD - Delete directly
```

### 2. NO FUNCTION ALIASES

A function can only have one name, and aliases are prohibited.

```python
# ❌ BAD
format_percent = format_percentage

# ✅ GOOD
# All callers use format_percentage uniformly
```

### 3. NO HARDCODING

Content must be derived from data or AI and not hard-coded.

```python
# ❌ BAD
status = "Active"

# ✅ GOOD
status = context.get("status")
```

### 4. NAMING CONVENTION

Python internal = snake_case, API bounds = camelCase.

```python
from app.core.converters import snakeize_obj, camelize_obj

# Entry conversion
data = snakeize_obj(raw_data)

# export conversion
return camelize_obj(result)
```

### 5. SEARCH BEFORE CREATE

You must search before creating a new file/class/function.

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

### Architecture Guards (5 Core Rules)

| # | Rules | Detection methods |
|---|------|----------|
| 1 | Disable silent swallowing of exceptions | except block must have logging/re-raise |
| 2 | Facade prohibits Any type | Public method parameters and return values |
| 3 | Re-export Shim is prohibited | schema files must have actual definitions |
| 4 | Disable cross-module private access | Do not access the `_private` attribute |
| 5 | Duplication is prohibited Protocol | Shared interfaces are placed in `core/interfaces/` |

Run the guard:
```bash
pytest tests/architecture/test_code_quality_guards.py -v
python ${VIBEGUARD_DIR}/guards/python/check_naming_convention.py <APP_ROOT>/
python ${VIBEGUARD_DIR}/guards/python/check_duplicates.py --strict
```

---

## Development

| Service | Port | Command |
|---------|------|---------|
| Backend | 5566 | `uvicorn app.main:app --reload --port 5566` |

---

## Key Principles

1. Data-driven: Display blank if there is no data
2. Search first and then write: you must search before creating a new one.
3. Minimal changes: only do what is asked
4. Test each repair tape
5. Spec-Driven: For 3+ file changes, write spec first
