# Data consistency

## U-11: Resolve shared data consistently across entrypoints (strict)
When entrypoints are intended to use the same dataset, confirm their resolved storage location agrees, including first start and explicit overrides. Different variable names or file names alone do not establish a defect. Independent datasets may use independent paths. Do not mandate a helper name, environment variable or new shared layer.

## U-31: Invalidate caches when result semantics change (strict)
When a change alters the meaning of cached results, update the relevant key or invalidation behavior and verify consumers receive the new result. This applies across languages. Do not add a version field to every key or invent a cache protocol without a concrete need.
