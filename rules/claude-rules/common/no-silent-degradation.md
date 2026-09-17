# Error semantics

## U-29: Do not present failed work as successful (strict)
Preserve the operation's error contract. Propagate or handle failures so that missing data, malformed input and incorrect results are visible to the responsible caller. A log message alone does not make a failed operation successful.
Expected recovery and explicitly accepted best-effort behavior are valid when their effect is clear. Use the project's error boundaries and logging conventions; do not force every layer to catch, log or attach a fallback field. In Rust, propagating a meaningful Result can be complete handling without an additional log.
