---
paths: **/*.py,**/pyproject.toml
---

# Data model boundaries

## U-30: Choose unknown-field handling from the data contract (strict)
When changing a boundary model or serialization contract, decide whether unknown fields should be rejected, retained or ignored. Use the appropriate Pydantic extra behavior and verify important callers. Do not force every internal model to repeat an explicit configuration.
