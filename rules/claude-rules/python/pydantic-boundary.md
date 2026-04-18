---
paths: **/*.py,**/pyproject.toml
---

# Pydantic Cross-Boundary Model Rules

## U-30: Cross-boundary Pydantic models must use `extra="allow"` (strict)

Any Pydantic model that receives external or cross-boundary data must set `extra="allow"` so `model_validate()` does not silently drop undeclared fields.

**What counts as "external / cross-boundary"**:
- JSON or cache deserialization via `model_validate(json_dict)`
- Parsing LLM output
- Crossing bounded contexts
- Receiving complex nested structures from the frontend or an API

**Cases that do not need `extra="allow"`**:
- Pure internal DTOs created and consumed inside the same module
- API request models, where `extra="forbid"` is often safer
- Configuration models with fixed schemas

```python
# BAD — default extra="ignore" drops undeclared fields silently
class BlockProps(BaseModel):
    model_config = ConfigDict(populate_by_name=True)
    # New block props are not declared here -> model_validate drops them -> frontend renders blank

# GOOD — extra="allow" preserves undeclared fields as a safety net
class BlockProps(BaseModel):
    """extra='allow' prevents model_validate from silently discarding fields."""
    model_config = ConfigDict(populate_by_name=True, extra="allow")
```

**End-to-end checklist for new fields**:

```
1. Creation layer: builder/factory writes the field value                       -> written
2. Model layer: Pydantic model declares the field and alias                    -> declared
3. Serialization layer: model_dump(exclude_none=True) keeps the field          -> emitted
4. Cache layer: cache key includes a version so field changes invalidate cache -> invalidated
5. Consumer layer: TypeScript interface declares the field                     -> rendered
```

**The three most common break points**:

| Break point | Mechanism | Symptom |
|--------|------|------|
| `model_validate` | Undeclared field is dropped by `extra="ignore"` | Frontend receives empty props |
| `FieldResolver` | Field is not declared in `fieldConfig`, so it is never extracted | Builder receives empty context |
| `model_dump(exclude_none=True)` | `None` fields do not enter JSON | Cache/frontend misses the field |

**Mechanical checks (agent execution rules)**:
- When creating a new Pydantic model, check whether any `model_validate()` call feeds it external data. If yes, set `extra="allow"`.
- After editing model fields, search all `model_validate` and `model_dump` call sites and verify the data flow end to end.
- When adding new block props, check whether `BlockProps` explicitly declares them. Even with `extra="allow"`, explicit fields still matter for type checking.
- When adding new section data fields, check whether `fieldConfig` (for example, `asset-noir.json`) declares them.

## U-31: Cache keys must include code version (strict)

When builder or generation logic changes, old cache entries must invalidate automatically. Cache keys therefore need a code-version dimension.

```python
# BAD — cache key only depends on input data
key = hash(section_type + data_hash + prompt_hash)
# Builder logic changes -> key unchanged -> old-format card is returned

# GOOD — includes code version
BUILDER_VERSION = "v3"  # bump whenever builder logic changes
key = hash(section_type + data_hash + prompt_hash + BUILDER_VERSION)
```

**Changes that require a version bump**:
- `build()` logic in `card_builders/*.py`
- Block creation logic in `block_builders.py`
- Model field changes in `docmodel.py`
- `sectionDefaults` changes in template JSON
