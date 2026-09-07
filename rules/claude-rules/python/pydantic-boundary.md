---
paths: **/*.py,**/pyproject.toml
---

# Data Boundary and Cache Rules

## U-30: Make unknown-field handling explicit at data boundaries (strict)
Choose unknown-field handling from the data contract, and prevent accidental loss of fields the consumer needs.
Use `extra="forbid"` for closed schemas that should reject unknown fields, `extra="allow"` for intentional pass-through data, and `extra="ignore"` only when discarding unknown fields is part of the contract. Preserving extras does not replace declaring and validating required fields.

**FIX / SKIP**: Fix unexpected field loss or acceptance by checking validation, serialization, and the relevant consumer together. Skip changing an intentional policy merely because the model accepts external data. Use a focused round-trip or boundary test for changed fields.

## U-31: Invalidate caches when result semantics change (strict)
When a change alters a cached result's meaning or representation, ensure stale entries cannot be reused as current output.
Use the project's existing invalidation strategy: a schema or builder version, a dependency digest, explicit eviction, or another mechanism that enforces the required freshness. A code-version field in every cache key is not mandatory.

**FIX / SKIP**: Fix stale reuse caused by changed dependencies or output contracts. Skip cache redesign when the existing mechanism already invalidates affected results. Verify a relevant old entry cannot hide the changed behavior.
